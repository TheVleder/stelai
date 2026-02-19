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

            let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])

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

            let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])

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

    // MARK: - Garment Cropping

    /// Crops a garment region from a full-body photo based on the detected garment type.
    ///
    /// Uses vertical body zone proportions:
    /// - **Top**: upper 50% of image
    /// - **Bottom**: middle 35% (from 35% to 70%)
    /// - **Shoes**: lower 30% (from 70% to 100%)
    /// - **Other**: full image
    ///
    /// - Parameters:
    ///   - image: The full-body or garment photo.
    ///   - type: The detected garment type.
    /// - Returns: A cropped `UIImage` of the garment region.
    func cropGarmentRegion(from image: UIImage, type: GarmentType) -> UIImage {
        let size = image.size

        let cropRect: CGRect
        switch type {
        case .top, .outerwear:
            // Upper 50% of image
            cropRect = CGRect(x: 0, y: 0, width: size.width, height: size.height * 0.50)
        case .bottom:
            // Middle zone: 35% to 70%
            let yStart = size.height * 0.35
            cropRect = CGRect(x: 0, y: yStart, width: size.width, height: size.height * 0.35)
        case .shoes:
            // Lower 30%: 70% to 100%
            let yStart = size.height * 0.70
            cropRect = CGRect(x: 0, y: yStart, width: size.width, height: size.height * 0.30)
        default:
            // Full image for accessories, full-body, etc.
            return image
        }

        // Perform the crop
        guard let cgImage = image.cgImage,
              let croppedCG = cgImage.cropping(to: cropRect) else {
            DebugLogger.shared.log("⚠️ VisionAI: Crop failed for \(type.label)", level: .warning)
            return image
        }

        let cropped = UIImage(cgImage: croppedCG, scale: image.scale, orientation: image.imageOrientation)
        DebugLogger.shared.log("✂️ VisionAI: Cropped \(type.label) region: \(Int(cropRect.width))×\(Int(cropRect.height))", level: .info)
        return cropped
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
}
