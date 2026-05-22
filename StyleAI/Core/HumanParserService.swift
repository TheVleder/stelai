// HumanParserService.swift
// StyleAI — Pixel-accurate human parsing for VTO inpainting masks
//
// Wraps the FASHN Human Parser (SegFormer-B4, 18 fashion-aware classes)
// converted to CoreML by `scripts/prepare_human_parser.py`.
//
// What it gives us over `VNGeneratePersonSegmentationRequest` (the framework
// API used today): per-garment masks. Apple's API returns "this is a person";
// the parser returns "these pixels are the top, these are the pants, these are
// the shoes". Inpainting masks become pixel-accurate, so SD no longer paints
// over the user's face when only the top is selected.
//
// License notice: the upstream FASHN model uses the NVIDIA Source Code License
// for SegFormer — **non-commercial use only**. Fine for personal sideload
// builds, not for App Store distribution. See README for alternatives.

import Foundation
import CoreML
import UIKit
import CoreImage

// MARK: - Region mapping

/// Garment regions we care about for VTO masking. Each maps to one or more of
/// the 18 FASHN parser classes.
enum HumanParserRegion: String, CaseIterable {
    case top      // upper body garments
    case bottom   // lower body garments
    case shoes    // feet
    case head     // face + hair (we explicitly want to EXCLUDE these from masks)
    case hands    // arms + hands (mostly exclude — usually bare skin)

    /// Numeric class IDs returned by the parser.
    var classIDs: [Int] {
        switch self {
        case .top:    return [3, 16]              // top, torso
        case .bottom: return [4, 5, 6, 14]        // dress, skirt, pants, legs
        case .shoes:  return [15]                 // feet
        case .head:   return [1, 2, 9, 10, 11]    // face, hair, hat, scarf, glasses
        case .hands:  return [12, 13]             // arms, hands
        }
    }
}

/// One run of the parser produces a label map (HxW of class IDs 0–17).
struct HumanParseResult {
    let labelMap: [UInt8]   // length = width * height
    let width: Int
    let height: Int
}

extension HumanParseResult {
    /// Renders a binary mask (white = region, black = elsewhere) for the given
    /// region. Returns the mask sized to match the input image — call sites can
    /// use it directly as a Stable Diffusion inpainting mask.
    func mask(for region: HumanParserRegion, targetSize: CGSize? = nil) -> CGImage? {
        let ids = Set(region.classIDs.map { UInt8($0) })
        let pixelCount = width * height
        var bytes = [UInt8](repeating: 0, count: pixelCount)
        for i in 0..<pixelCount {
            bytes[i] = ids.contains(labelMap[i]) ? 255 : 0
        }

        let colorSpace = CGColorSpaceCreateDeviceGray()
        guard let provider = CGDataProvider(data: Data(bytes) as CFData),
              let baseMask = CGImage(
                width: width,
                height: height,
                bitsPerComponent: 8,
                bitsPerPixel: 8,
                bytesPerRow: width,
                space: colorSpace,
                bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue),
                provider: provider,
                decode: nil,
                shouldInterpolate: false,
                intent: .defaultIntent
              )
        else { return nil }

        guard let target = targetSize, Int(target.width) != width || Int(target.height) != height else {
            return baseMask
        }
        return Self.resize(baseMask, to: target)
    }

    private static func resize(_ image: CGImage, to size: CGSize) -> CGImage? {
        let w = Int(size.width.rounded()), h = Int(size.height.rounded())
        guard let ctx = CGContext(
            data: nil, width: w, height: h,
            bitsPerComponent: 8, bytesPerRow: w,
            space: CGColorSpaceCreateDeviceGray(),
            bitmapInfo: CGImageAlphaInfo.none.rawValue
        ) else { return nil }
        ctx.interpolationQuality = .high
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        return ctx.makeImage()
    }
}

// MARK: - Service

@MainActor
final class HumanParserService {

    static let shared = HumanParserService()

    /// Native input size FASHN expects.
    private static let inputWidth = 384
    private static let inputHeight = 576
    /// FASHN class count.
    private static let numClasses = 18

    private var model: MLModel?
    private var didAttemptLoad = false

    private init() {}

    var isAvailable: Bool { model != nil }

    private func loadIfNeeded() {
        guard !didAttemptLoad else { return }
        didAttemptLoad = true

        guard let url = Bundle.main.url(forResource: "HumanParser", withExtension: "mlmodelc") else {
            DebugLogger.shared.log("⚠️ HumanParser: bundle asset missing — falling back to body-pose mask", level: .warning)
            return
        }
        do {
            let config = MLModelConfiguration()
            config.computeUnits = .all
            model = try MLModel(contentsOf: url, configuration: config)
            DebugLogger.shared.log("🧍 HumanParser ready (\(Self.inputWidth)×\(Self.inputHeight), \(Self.numClasses) classes)", level: .success)
        } catch {
            DebugLogger.shared.log("❌ HumanParser load failed: \(error.localizedDescription)", level: .error)
        }
    }

    /// Releases the model. Call before kicking off Stable Diffusion generation
    /// to free a few hundred MB of RAM that A17 Pro needs for the SD pipeline.
    func unload() {
        model = nil
        didAttemptLoad = false
    }

    // MARK: - Parsing

    /// Runs the parser on `image` and returns per-pixel class IDs. Nil when the
    /// model isn't bundled or inference fails.
    func parse(_ image: UIImage) async -> HumanParseResult? {
        loadIfNeeded()
        guard let model else { return nil }

        guard let pixelBuffer = preprocess(image: image) else {
            DebugLogger.shared.log("❌ HumanParser: preprocess failed", level: .error)
            return nil
        }

        // MLModel + CVPixelBuffer are thread-safe for reads but not annotated
        // Sendable; nonisolated(unsafe) is the standard pattern for hopping
        // them into a detached task.
        nonisolated(unsafe) let unsafeModel = model
        nonisolated(unsafe) let unsafePB = pixelBuffer

        return await Task.detached(priority: .userInitiated) {
            do {
                let description = unsafeModel.modelDescription
                let inputName = description.inputDescriptionsByName.keys.first ?? "image"
                let outputName = description.outputDescriptionsByName.keys.first ?? "logits"

                let input = try MLDictionaryFeatureProvider(dictionary: [
                    inputName: MLFeatureValue(pixelBuffer: unsafePB)
                ])
                let output = try await unsafeModel.prediction(from: input)
                guard let logits = output.featureValue(for: outputName)?.multiArrayValue else {
                    return nil
                }
                return Self.argmax(logits: logits)
            } catch {
                await MainActor.run {
                    DebugLogger.shared.log("❌ HumanParser inference error: \(error.localizedDescription)", level: .error)
                }
                return nil
            }
        }.value
    }

    // MARK: - Helpers

    /// Resize the input to 384x576 and produce a 32BGRA pixel buffer. The
    /// CoreML model itself owns the per-channel normalization (declared at
    /// export time in `scripts/prepare_human_parser.py`).
    private func preprocess(image: UIImage) -> CVPixelBuffer? {
        let target = CGSize(width: Self.inputWidth, height: Self.inputHeight)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        let resized = UIGraphicsImageRenderer(size: target, format: format).image { _ in
            image.draw(in: CGRect(origin: .zero, size: target))
        }
        guard let cgImage = resized.cgImage else { return nil }

        var buffer: CVPixelBuffer?
        let status = CVPixelBufferCreate(
            kCFAllocatorDefault,
            Self.inputWidth, Self.inputHeight,
            kCVPixelFormatType_32BGRA,
            [kCVPixelBufferCGImageCompatibilityKey: true,
             kCVPixelBufferCGBitmapContextCompatibilityKey: true] as CFDictionary,
            &buffer
        )
        guard status == kCVReturnSuccess, let pixelBuffer = buffer else { return nil }
        CVPixelBufferLockBaseAddress(pixelBuffer, [])
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, []) }
        let ctx = CGContext(
            data: CVPixelBufferGetBaseAddress(pixelBuffer),
            width: Self.inputWidth,
            height: Self.inputHeight,
            bitsPerComponent: 8,
            bytesPerRow: CVPixelBufferGetBytesPerRow(pixelBuffer),
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        )
        ctx?.draw(cgImage, in: CGRect(x: 0, y: 0, width: Self.inputWidth, height: Self.inputHeight))
        return pixelBuffer
    }

    /// Logits shape: `[1, 18, H, W]`. We pick the argmax class per pixel.
    /// Uses MLMultiArray's subscript (dtype-safe) instead of raw pointer
    /// access — a 6-bit palettized model may report Float16 or Float32 and the
    /// pointer cast would silently read garbage otherwise.
    ///
    /// `nonisolated` so the detached inference task can call it without
    /// hopping back to the main actor.
    nonisolated private static func argmax(logits: MLMultiArray) -> HumanParseResult? {
        let shape = logits.shape.map { $0.intValue }
        guard shape.count == 4, shape[0] == 1, shape[1] == numClasses else { return nil }
        let h = shape[2], w = shape[3]
        var labels = [UInt8](repeating: 0, count: h * w)

        for y in 0..<h {
            for x in 0..<w {
                var best: Float = -.infinity
                var bestClass = 0
                for c in 0..<numClasses {
                    let idx = [0, c, y, x] as [NSNumber]
                    let v = logits[idx].floatValue
                    if v > best { best = v; bestClass = c }
                }
                labels[y * w + x] = UInt8(bestClass)
            }
        }
        return HumanParseResult(labelMap: labels, width: w, height: h)
    }
}
