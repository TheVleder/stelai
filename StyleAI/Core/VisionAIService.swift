// VisionAIService.swift
// StyleAI — On-Device Vision AI
//
// Wraps Apple's Vision framework for real AI capabilities:
// - Person segmentation (VNGeneratePersonSegmentationRequest)
// - Image classification (VNClassifyImageRequest)
// - Dominant color extraction (CIAreaAverage)
//
// No external models needed — all APIs are built into iOS 15+.

import Vision
import UIKit
import CoreImage
import CoreImage.CIFilterBuiltins

// MARK: - Classification Result

/// Result from AI garment classification.
struct GarmentClassification: Sendable {
    let suggestedType: GarmentType
    let confidence: Float
    let allLabels: [(label: String, confidence: Float)]
    let suggestedThermalIndex: Double
    let suggestedTags: [String]
}

// MARK: - Vision AI Service

/// Central service for on-device AI using Apple Vision framework.
/// All processing happens locally on the Neural Engine — no network required.
@MainActor
final class VisionAIService {

    static let shared = VisionAIService()

    private let ciContext = CIContext(options: [.useSoftwareRenderer: false])

    private init() {
        DebugLogger.shared.log("🧠 VisionAIService initialized (on-device Vision)", level: .info)
    }

    // MARK: - Person Segmentation

    /// Generates a pixel-accurate person segmentation mask from a photo.
    ///
    /// Uses `VNGeneratePersonSegmentationRequest` at `.accurate` quality
    /// to create a mask where person pixels are white (1.0) and background
    /// pixels are black (0.0).
    ///
    /// - Parameter image: The input photo containing a person.
    /// - Returns: A grayscale mask `CGImage`, or `nil` if no person detected.
    func segmentPerson(from image: UIImage) async -> CGImage? {
        guard let cgImage = image.cgImage else {
            DebugLogger.shared.log("❌ VisionAI: No CGImage available for segmentation", level: .error)
            return nil
        }

        return await withCheckedContinuation { continuation in
            let request = VNGeneratePersonSegmentationRequest()
            request.qualityLevel = .accurate
            request.outputPixelFormat = kCVPixelFormatType_OneComponent8

            let handler = VNImageRequestHandler(cgImage: cgImage,
                                                orientation: visionOrientation(from: image),
                                                options: [:])

            do {
                try handler.perform([request])

                guard let result = request.results?.first else {
                    DebugLogger.shared.log("⚠️ VisionAI: No person detected in image", level: .warning)
                    continuation.resume(returning: nil)
                    return
                }

                let pixelBuffer = result.pixelBuffer

                // Convert CVPixelBuffer to CGImage
                let ciImage = CIImage(cvPixelBuffer: pixelBuffer)

                // Scale mask to match original image size
                let scaleX = CGFloat(cgImage.width) / ciImage.extent.width
                let scaleY = CGFloat(cgImage.height) / ciImage.extent.height
                let scaledImage = ciImage.transformed(by: CGAffineTransform(scaleX: scaleX, y: scaleY))

                if let maskCG = ciContext.createCGImage(scaledImage, from: scaledImage.extent) {
                    DebugLogger.shared.log("✅ VisionAI: Person segmentation mask generated (\(maskCG.width)×\(maskCG.height))", level: .success)
                    continuation.resume(returning: maskCG)
                } else {
                    DebugLogger.shared.log("❌ VisionAI: Failed to create CGImage from mask", level: .error)
                    continuation.resume(returning: nil)
                }
            } catch {
                DebugLogger.shared.log("❌ VisionAI: Segmentation error: \(error.localizedDescription)", level: .error)
                continuation.resume(returning: nil)
            }
        }
    }

    // MARK: - Image Classification

    /// Classifies a garment image and returns type, thermal index, and tag suggestions.
    ///
    /// Uses `VNClassifyImageRequest` with Apple's built-in ~1000-class model.
    /// Maps fashion-relevant labels to `GarmentType` and estimates thermal properties.
    ///
    /// - Parameter image: A photo of a garment.
    /// - Returns: A `GarmentClassification` with suggested type, tags, and confidence.
    func classifyGarment(_ image: UIImage) async -> GarmentClassification? {
        guard let cgImage = image.cgImage else {
            DebugLogger.shared.log("❌ VisionAI: No CGImage for classification", level: .error)
            return nil
        }

        return await withCheckedContinuation { continuation in
            let request = VNClassifyImageRequest()

            let handler = VNImageRequestHandler(cgImage: cgImage,
                                                orientation: visionOrientation(from: image),
                                                options: [:])

            do {
                try handler.perform([request])

                guard let results = request.results, !results.isEmpty else {
                    DebugLogger.shared.log("⚠️ VisionAI: No classification results", level: .warning)
                    continuation.resume(returning: nil)
                    return
                }

                // Filter to top classifications above threshold
                let topResults = results
                    .filter { $0.confidence > 0.05 }
                    .prefix(20)
                    .map { (label: $0.identifier, confidence: $0.confidence) }

                DebugLogger.shared.log("🏷 VisionAI: Top labels: \(topResults.prefix(5).map { "\($0.label) (\(Int($0.confidence * 100))%)" }.joined(separator: ", "))", level: .info)

                // Map to GarmentType
                let (garmentType, typeConfidence) = Self.mapToGarmentType(topResults.map { $0 })

                // Estimate thermal index from labels
                let thermalIndex = Self.estimateThermalIndex(topResults.map { $0 })

                // Suggest style tags
                let tags = Self.suggestTags(topResults.map { $0 })

                let classification = GarmentClassification(
                    suggestedType: garmentType,
                    confidence: typeConfidence,
                    allLabels: topResults.map { ($0.label, $0.confidence) },
                    suggestedThermalIndex: thermalIndex,
                    suggestedTags: tags
                )

                DebugLogger.shared.log("✅ VisionAI: Classified as \(garmentType.label) (\(Int(typeConfidence * 100))% confidence)", level: .success)
                continuation.resume(returning: classification)
            } catch {
                DebugLogger.shared.log("❌ VisionAI: Classification error: \(error.localizedDescription)", level: .error)
                continuation.resume(returning: nil)
            }
        }
    }

    // MARK: - Color Extraction

    /// Extracts the dominant color from an image using CIAreaAverage.
    ///
    /// - Parameter image: The input image.
    /// - Returns: The dominant `UIColor`, or `nil` on failure.
    func extractDominantColor(from image: UIImage) -> UIColor? {
        guard let ciImage = CIImage(image: image) else { return nil }

        let filter = CIFilter.areaAverage()
        filter.inputImage = ciImage
        filter.extent = ciImage.extent

        guard let outputImage = filter.outputImage else { return nil }

        // Read the single pixel
        var bitmap = [UInt8](repeating: 0, count: 4)
        let extent = CGRect(x: 0, y: 0, width: 1, height: 1)
        ciContext.render(
            outputImage,
            toBitmap: &bitmap,
            rowBytes: 4,
            bounds: extent,
            format: .RGBA8,
            colorSpace: CGColorSpaceCreateDeviceRGB()
        )

        let color = UIColor(
            red: CGFloat(bitmap[0]) / 255.0,
            green: CGFloat(bitmap[1]) / 255.0,
            blue: CGFloat(bitmap[2]) / 255.0,
            alpha: 1.0
        )

        DebugLogger.shared.log("🎨 VisionAI: Dominant color extracted (R:\(bitmap[0]) G:\(bitmap[1]) B:\(bitmap[2]))", level: .info)
        return color
    }

    // MARK: - Label Mapping

    /// Maps Vision classification labels to GarmentType.
    private static func mapToGarmentType(_ labels: [(label: String, confidence: Float)]) -> (GarmentType, Float) {

        // Label → GarmentType mapping with priority weights
        let topKeywords: Set<String> = [
            "jersey", "sweatshirt", "cardigan", "poncho",
            "vestment", "shirt", "blouse", "tank_top",
            "polo_shirt", "tee_shirt", "t-shirt"
        ]
        let bottomKeywords: Set<String> = [
            "jean", "jeans", "trouser", "pants", "skirt",
            "shorts", "miniskirt", "legging"
        ]
        let outerwearKeywords: Set<String> = [
            "suit", "coat", "jacket", "parka", "trench_coat",
            "fur_coat", "lab_coat", "cloak", "overcoat"
        ]
        let shoeKeywords: Set<String> = [
            "shoe", "sneaker", "boot", "sandal", "loafer",
            "running_shoe", "clog", "slipper", "flip-flop",
            "cowboy_boot", "tennis_shoe"
        ]
        let accessoryKeywords: Set<String> = [
            "sunglasses", "sunglass", "watch", "necklace", "hat",
            "cap", "scarf", "glove", "bag", "purse", "backpack",
            "bow_tie", "necktie", "tie", "bolo_tie", "wallet"
        ]
        let fullBodyKeywords: Set<String> = [
            "dress", "gown", "kimono", "robe",
            "academic_gown", "abaya", "sarong"
        ]

        var scores: [GarmentType: Float] = [:]

        for (label, conf) in labels {
            let lower = label.lowercased()
            if topKeywords.contains(where: { lower.contains($0) }) {
                scores[.top, default: 0] += conf
            }
            if bottomKeywords.contains(where: { lower.contains($0) }) {
                scores[.bottom, default: 0] += conf
            }
            if outerwearKeywords.contains(where: { lower.contains($0) }) {
                scores[.outerwear, default: 0] += conf
            }
            if shoeKeywords.contains(where: { lower.contains($0) }) {
                scores[.shoes, default: 0] += conf
            }
            if accessoryKeywords.contains(where: { lower.contains($0) }) {
                scores[.accessory, default: 0] += conf
            }
            if fullBodyKeywords.contains(where: { lower.contains($0) }) {
                scores[.fullBody, default: 0] += conf
            }
        }

        // Return highest scoring type, or .top as fallback
        if let best = scores.max(by: { $0.value < $1.value }) {
            return (best.key, min(best.value, 1.0))
        }
        return (.top, 0.1)
    }

    /// Estimates thermal index from classification labels.
    private static func estimateThermalIndex(_ labels: [(label: String, confidence: Float)]) -> Double {
        // Cold garments (low thermal index = warm clothing)
        let coldKeywords = ["coat", "parka", "fur", "sweater", "sweatshirt",
                            "boot", "glove", "scarf", "cardigan", "overcoat"]
        let hotKeywords = ["sandal", "tank", "shorts", "flip-flop", "slipper",
                           "bikini", "swimsuit", "sunglasses"]
        let mildKeywords = ["shirt", "jean", "trouser", "sneaker", "dress",
                            "blouse", "loafer"]

        var coldScore: Double = 0
        var hotScore: Double = 0
        var mildScore: Double = 0

        for (label, conf) in labels {
            let lower = label.lowercased()
            let c = Double(conf)
            if coldKeywords.contains(where: { lower.contains($0) }) { coldScore += c }
            if hotKeywords.contains(where: { lower.contains($0) }) { hotScore += c }
            if mildKeywords.contains(where: { lower.contains($0) }) { mildScore += c }
        }

        // Map: 0.0 = very cold gear, 1.0 = very light/hot weather gear
        if coldScore > hotScore && coldScore > mildScore {
            return max(0.05, 0.20 - coldScore * 0.1)
        } else if hotScore > coldScore && hotScore > mildScore {
            return min(0.95, 0.80 + hotScore * 0.1)
        } else {
            return 0.50
        }
    }

    /// Suggests style tags from classification labels.
    private static func suggestTags(_ labels: [(label: String, confidence: Float)]) -> [String] {
        var tags: Set<String> = []

        let formalKeywords = ["suit", "tie", "gown", "vestment", "tuxedo"]
        let casualKeywords = ["jean", "tee", "t-shirt", "sneaker", "hoodie", "sweatshirt"]
        let sportKeywords = ["running", "jersey", "athletic", "track"]
        let elegantKeywords = ["dress", "silk", "satin", "kimono", "fur", "pearl"]

        for (label, conf) in labels where conf > 0.05 {
            let lower = label.lowercased()
            if formalKeywords.contains(where: { lower.contains($0) }) { tags.insert("Formal") }
            if casualKeywords.contains(where: { lower.contains($0) }) { tags.insert("Casual") }
            if sportKeywords.contains(where: { lower.contains($0) }) { tags.insert("Deportivo") }
            if elegantKeywords.contains(where: { lower.contains($0) }) { tags.insert("Elegante") }
        }

        // Fallback
        if tags.isEmpty { tags.insert("Casual") }
        return Array(tags).sorted()
    }

    // MARK: - Garment Cropping (Body Pose AI)

    /// Crops the garment region from a photo using real body skeleton keypoints.
    /// Uses `VNHumanBodyPoseRequest` to locate shoulders, hips, knees, ankles exactly.
    /// Falls back to proportional crop only if pose detection fails.
    func cropSmartGarmentRegion(from image: UIImage, type: GarmentType, personMask: CGImage? = nil) -> UIImage {
        if let result = cropUsingBodyPose(image: image, type: type) {
            return result
        }
        DebugLogger.shared.log("⚠️ VisionAI: Body pose not detected, using proportional fallback for \(type.label)", level: .warning)
        return cropFallback(image: image, type: type)
    }

    /// Uses VNHumanBodyPoseRequest to find skeleton joints and crop the garment zone.
    private func cropUsingBodyPose(image: UIImage, type: GarmentType) -> UIImage? {
        guard let cgImage = image.cgImage else { return nil }
        let size = image.size

        let request = VNDetectHumanBodyPoseRequest()
        let handler = VNImageRequestHandler(cgImage: cgImage,
                                            orientation: visionOrientation(from: image),
                                            options: [:])
        do { try handler.perform([request]) } catch {
            DebugLogger.shared.log("❌ VisionAI: Pose request error: \(error.localizedDescription)", level: .error)
            return nil
        }
        guard let obs = request.results?.first else { return nil }

        // Convert Vision normalized point (y flipped) to UIKit image coords
        func pt(_ joint: VNHumanBodyPoseObservation.JointName) -> CGPoint? {
            guard let p = try? obs.recognizedPoint(joint), p.confidence > 0.25 else { return nil }
            return CGPoint(x: p.location.x * size.width,
                           y: (1.0 - p.location.y) * size.height)
        }

        func avgY(_ a: CGPoint?, _ b: CGPoint?) -> CGFloat? {
            let ys = [a, b].compactMap { $0?.y }
            return ys.isEmpty ? nil : ys.reduce(0, +) / CGFloat(ys.count)
        }
        func leftX(_ pts: [CGPoint?]) -> CGFloat  { pts.compactMap { $0?.x }.min() ?? size.width * 0.05 }
        func rightX(_ pts: [CGPoint?]) -> CGFloat { pts.compactMap { $0?.x }.max() ?? size.width * 0.95 }

        let neck = pt(.neck)
        let lShoulder = pt(.leftShoulder);  let rShoulder = pt(.rightShoulder)
        let lHip = pt(.leftHip);            let rHip = pt(.rightHip)
        let lKnee = pt(.leftKnee);          let rKnee = pt(.rightKnee)
        let lAnkle = pt(.leftAnkle);        let rAnkle = pt(.rightAnkle)
        let lWrist = pt(.leftWrist);        let rWrist = pt(.rightWrist)

        // Use full torso width (from 5% to 95% of image) to avoid cropping sleeves/outlines
        let safeLeft = size.width * 0.05
        let safeRight = size.width * 0.95
        let cropRect: CGRect

        switch type {
        case .top, .outerwear:
            guard let shoulderY = avgY(lShoulder, rShoulder),
                  let hipY = avgY(lHip, rHip) else { return nil }
            let top    = (neck?.y ?? shoulderY) - pad
            let bottom = hipY + pad
            cropRect = CGRect(x: safeLeft, y: top, width: safeRight - safeLeft, height: bottom - top)

        case .bottom:
            guard let hipY = avgY(lHip, rHip),
                  let ankleY = avgY(lAnkle, rAnkle) else { return nil }
            let top    = hipY - pad
            let bottom = ankleY + pad
            cropRect = CGRect(x: safeLeft, y: top, width: safeRight - safeLeft, height: bottom - top)

        case .shoes:
            guard let ankleY = avgY(lAnkle, rAnkle) else { return nil }
            let kneeY = avgY(lKnee, rKnee) ?? (ankleY - size.height * 0.15)
            let top    = kneeY - pad
            let bottom = min(ankleY + size.height * 0.10 + pad, size.height)
            cropRect = CGRect(x: safeLeft, y: top, width: safeRight - safeLeft, height: bottom - top)

        default:
            return nil
        }

        let clamped = cropRect.intersection(CGRect(origin: .zero, size: size))
        guard clamped.width > 10 && clamped.height > 10 else { return nil }

        let fmt = UIGraphicsImageRendererFormat()
        fmt.opaque = true; fmt.scale = image.scale
        let cropped = UIGraphicsImageRenderer(size: clamped.size, format: fmt).image { _ in
            image.draw(in: CGRect(x: -clamped.origin.x, y: -clamped.origin.y,
                                  width: size.width, height: size.height))
        }
        DebugLogger.shared.log("✅ VisionAI: Body-pose crop [\(type.label)] \(Int(clamped.width))×\(Int(clamped.height))px", level: .success)
        return cropped
    }

    /// Proportional fallback used when body pose is not detectable.
    private func cropFallback(image: UIImage, type: GarmentType) -> UIImage {
        let size = image.size
        let cropRect: CGRect
        switch type {
        case .top, .outerwear:
            cropRect = CGRect(x: size.width * 0.02, y: size.height * 0.15,
                              width: size.width * 0.96, height: size.height * 0.43)
        case .bottom:
            cropRect = CGRect(x: size.width * 0.05, y: size.height * 0.50,
                              width: size.width * 0.90, height: size.height * 0.40)
        case .shoes:
            cropRect = CGRect(x: size.width * 0.10, y: size.height * 0.82,
                              width: size.width * 0.80, height: size.height * 0.18)
        default: return image
        }
        let c = cropRect.intersection(CGRect(origin: .zero, size: size))
        guard c.width > 0 && c.height > 0 else { return image }
        let fmt = UIGraphicsImageRendererFormat()
        fmt.opaque = true; fmt.scale = image.scale
        return UIGraphicsImageRenderer(size: c.size, format: fmt).image { _ in
            image.draw(in: CGRect(x: -c.origin.x, y: -c.origin.y,
                                  width: size.width, height: size.height))
        }
    }

    /// Generates a square thumbnail of the given size.
    func generateThumbnail(from image: UIImage, size: CGFloat = 256) -> UIImage {
        let targetSize = CGSize(width: size, height: size)
        let renderer = UIGraphicsImageRenderer(size: targetSize)
        return renderer.image { _ in
            // Scale to fill, center-crop
            let aspectWidth = targetSize.width / image.size.width
            let aspectHeight = targetSize.height / image.size.height
            let aspectRatio = max(aspectWidth, aspectHeight)

            let drawSize = CGSize(
                width: image.size.width * aspectRatio,
                height: image.size.height * aspectRatio
            )
            let drawOrigin = CGPoint(
                x: (targetSize.width - drawSize.width) / 2,
                y: (targetSize.height - drawSize.height) / 2
            )

            image.draw(in: CGRect(origin: drawOrigin, size: drawSize))
        }
    }
    /// Translates UIImage orientation to CGImagePropertyOrientation required by Vision.
    /// Without this, Vision processes rotated raw pixels giving wrong skeleton coordinates.
    private func visionOrientation(from image: UIImage) -> CGImagePropertyOrientation {
        switch image.imageOrientation {
        case .up:            return .up
        case .down:          return .down
        case .left:          return .left
        case .right:         return .right
        case .upMirrored:    return .upMirrored
        case .downMirrored:  return .downMirrored
        case .leftMirrored:  return .leftMirrored
        case .rightMirrored: return .rightMirrored
        @unknown default:    return .up
        }
    }
}
