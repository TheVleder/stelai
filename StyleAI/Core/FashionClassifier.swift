// FashionClassifier.swift
// StyleAI — Zero-Shot Fashion Classifier using MobileCLIP (CoreML)
//
// Replaces Apple's generic `VNClassifyImageRequest` (ImageNet, 1000 classes,
// pre-2015, no fashion specialization) with zero-shot CLIP-style matching.
//
// At build time, `scripts/prepare_fashion_classifier.py` generates:
//   - StyleAI/MLAssets/FashionClassifier.mlpackage  (MobileCLIP-S0 image encoder, ~25 MB)
//   - StyleAI/MLAssets/garment_label_embeddings.json (precomputed text embeddings)
//
// At runtime: encode the input image once, cosine-similarity vs each label
// embedding, return the top match. Roughly 5 ms per call on A17 Pro.
//
// If the bundle does not yet contain the assets (e.g. the prepare workflow has
// not run yet), `isAvailable` reports `false` and `VisionAIService` falls back
// to the legacy heuristic path.

import Foundation
import CoreML
import UIKit
import Vision

// MARK: - Label record

/// One garment label with its precomputed CLIP text embedding.
private struct LabeledEmbedding: Decodable {
    let name: String          // e.g. "Camiseta blanca"
    let type: String          // raw value of GarmentType (e.g. "top")
    let thermalIndex: Double  // 0.0 = very warm gear, 1.0 = very light
    let tags: [String]        // e.g. ["Casual"]
    let embedding: [Float]    // 512-dim L2-normalized vector
}

private struct EmbeddingFile: Decodable {
    let modelId: String       // e.g. "apple/coreml-mobileclip"
    let variant: String       // e.g. "MobileCLIP-S0"
    let embeddingDim: Int
    let labels: [LabeledEmbedding]
}

// MARK: - Service

@MainActor
final class FashionClassifier {

    static let shared = FashionClassifier()

    private var model: MLModel?
    private var labels: [LabeledEmbedding] = []
    private var didAttemptLoad = false

    private init() {}

    /// Whether the classifier has both model and labels loaded.
    var isAvailable: Bool { model != nil && !labels.isEmpty }

    /// Lazy load — called on first classification attempt.
    private func loadIfNeeded() {
        guard !didAttemptLoad else { return }
        didAttemptLoad = true

        guard
            let modelURL = Bundle.main.url(forResource: "FashionClassifier", withExtension: "mlmodelc"),
            let labelsURL = Bundle.main.url(forResource: "garment_label_embeddings", withExtension: "json")
        else {
            DebugLogger.shared.log("⚠️ FashionClassifier: bundle assets missing — using legacy heuristic classifier", level: .warning)
            return
        }

        do {
            let config = MLModelConfiguration()
            config.computeUnits = .all   // Neural Engine + GPU + CPU
            model = try MLModel(contentsOf: modelURL, configuration: config)

            let data = try Data(contentsOf: labelsURL)
            let decoded = try JSONDecoder().decode(EmbeddingFile.self, from: data)
            labels = decoded.labels

            DebugLogger.shared.log("🧥 FashionClassifier ready (\(decoded.variant), \(labels.count) labels, dim \(decoded.embeddingDim))", level: .success)
        } catch {
            DebugLogger.shared.log("❌ FashionClassifier load failed: \(error.localizedDescription)", level: .error)
            model = nil
            labels = []
        }
    }

    // MARK: - Classification

    /// Returns the top matching garment label for `image`, or nil if the
    /// classifier is unavailable or no label clears the minimum confidence.
    func classify(_ image: UIImage, minConfidence: Float = 0.15) async -> GarmentClassification? {
        loadIfNeeded()
        guard let model, !labels.isEmpty else { return nil }

        guard let embedding = await embed(image: image, model: model) else {
            return nil
        }

        // Cosine similarity against every label. Since both vectors are
        // L2-normalized, cosine == dot product.
        var scored: [(idx: Int, score: Float)] = labels.enumerated().map { (i, label) in
            (i, dot(embedding, label.embedding))
        }
        scored.sort { $0.score > $1.score }

        guard let best = scored.first, best.score >= minConfidence else {
            DebugLogger.shared.log("⚠️ FashionClassifier: top score \(scored.first?.score ?? 0) below threshold \(minConfidence)", level: .warning)
            return nil
        }

        let label = labels[best.idx]
        let garmentType = GarmentType(rawValue: label.type) ?? .top

        // Surface up to 5 top labels for the existing UI (the all-labels list).
        let allLabels: [(label: String, confidence: Float)] = scored.prefix(5).map { entry in
            (labels[entry.idx].name, entry.score)
        }

        DebugLogger.shared.log("🧥 FashionClassifier: \(label.name) — \(garmentType.label) (\(Int(best.score * 100))%)", level: .success)

        return GarmentClassification(
            suggestedType: garmentType,
            confidence: best.score,
            allLabels: allLabels,
            suggestedThermalIndex: label.thermalIndex,
            suggestedTags: label.tags
        )
    }

    // MARK: - Inference

    /// Runs the image encoder and returns the L2-normalized embedding vector.
    /// `MLModel` and `CVPixelBuffer` aren't `Sendable` in Swift 6.2 strict
    /// concurrency, but both are documented thread-safe for read operations
    /// — `nonisolated(unsafe)` is the standard escape hatch for this case.
    private func embed(image: UIImage, model: MLModel) async -> [Float]? {
        guard let pixelBuffer = preprocess(image: image, size: 256) else {
            DebugLogger.shared.log("❌ FashionClassifier: failed to preprocess image", level: .error)
            return nil
        }

        nonisolated(unsafe) let unsafeModel = model
        nonisolated(unsafe) let unsafePB = pixelBuffer

        return await Task.detached(priority: .userInitiated) {
            do {
                // The MobileCLIP CoreML input/output names can vary between
                // exports — read them off the model description rather than
                // hardcoding.
                let description = unsafeModel.modelDescription
                let inputName = description.inputDescriptionsByName.keys.first ?? "image"
                let outputName = description.outputDescriptionsByName.keys.first ?? "embeddings"

                let input = try MLDictionaryFeatureProvider(dictionary: [
                    inputName: MLFeatureValue(pixelBuffer: unsafePB)
                ])
                let output = try unsafeModel.prediction(from: input)

                guard let array = output.featureValue(for: outputName)?.multiArrayValue else {
                    return nil
                }

                let count = array.count
                var vec = [Float](repeating: 0, count: count)
                for i in 0..<count {
                    vec[i] = array[i].floatValue
                }
                return Self.l2Normalize(vec)
            } catch {
                await MainActor.run {
                    DebugLogger.shared.log("❌ FashionClassifier inference error: \(error.localizedDescription)", level: .error)
                }
                return nil
            }
        }.value
    }

    /// Resizes to `size × size` and produces a 32-bit BGRA `CVPixelBuffer`.
    /// MobileCLIP's CoreML wrapper handles the per-channel mean/std internally
    /// when the input is declared as an image type.
    private func preprocess(image: UIImage, size: Int) -> CVPixelBuffer? {
        let targetSize = CGSize(width: size, height: size)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true

        let resized = UIGraphicsImageRenderer(size: targetSize, format: format).image { _ in
            image.draw(in: CGRect(origin: .zero, size: targetSize))
        }
        guard let cgImage = resized.cgImage else { return nil }

        var pixelBuffer: CVPixelBuffer?
        let attrs: [CFString: Any] = [
            kCVPixelBufferCGImageCompatibilityKey: true,
            kCVPixelBufferCGBitmapContextCompatibilityKey: true
        ]
        let status = CVPixelBufferCreate(
            kCFAllocatorDefault,
            size, size,
            kCVPixelFormatType_32BGRA,
            attrs as CFDictionary,
            &pixelBuffer
        )
        guard status == kCVReturnSuccess, let buffer = pixelBuffer else { return nil }

        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }

        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let context = CGContext(
            data: CVPixelBufferGetBaseAddress(buffer),
            width: size,
            height: size,
            bitsPerComponent: 8,
            bytesPerRow: CVPixelBufferGetBytesPerRow(buffer),
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        ) else { return nil }

        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: size, height: size))
        return buffer
    }

    private func dot(_ a: [Float], _ b: [Float]) -> Float {
        let n = min(a.count, b.count)
        var sum: Float = 0
        for i in 0..<n { sum += a[i] * b[i] }
        return sum
    }

    private static func l2Normalize(_ v: [Float]) -> [Float] {
        var norm: Float = 0
        for x in v { norm += x * x }
        norm = sqrt(norm)
        guard norm > 0 else { return v }
        return v.map { $0 / norm }
    }
}
