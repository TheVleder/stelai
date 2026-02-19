// TryOnEngine.swift
// StyleAI — Virtual Try-On Processing Pipeline
//
// Two rendering modes:
// 1. Fast Preview: Vision AI segmentation + gradient overlays (~200ms)
// 2. AI Generation: Stable Diffusion inpainting for photo-realistic results (~15s)

import SwiftUI
import UIKit

// MARK: - Try-On State

/// Processing state for the VTO pipeline.
enum TryOnState: Equatable, Sendable {
    case idle
    case processing
    case generatingAI(progress: Double)
    case done
    case error(message: String)

    var isProcessing: Bool {
        if case .processing = self { return true }
        return false
    }
}

// MARK: - Outfit Selection

/// Current outfit configuration: one garment per slot.
struct OutfitSelection: Equatable, Sendable {
    var top: CarouselGarment?
    var bottom: CarouselGarment?
    var shoes: CarouselGarment?

    /// Returns the garment for the given slot.
    func garment(for slot: GarmentSlot) -> CarouselGarment? {
        switch slot {
        case .top:    return top
        case .bottom: return bottom
        case .shoes:  return shoes
        }
    }

    /// Sets the garment for the given slot.
    mutating func setGarment(_ garment: CarouselGarment?, for slot: GarmentSlot) {
        switch slot {
        case .top:    top = garment
        case .bottom: bottom = garment
        case .shoes:  shoes = garment
        }
    }

    /// Whether at least one garment is selected.
    var hasAnySelection: Bool {
        top != nil || bottom != nil || shoes != nil
    }

    /// Count of selected garments.
    var count: Int {
        [top, bottom, shoes].compactMap { $0 }.count
    }
}

// MARK: - Try-On Engine

/// Processes Virtual Try-On compositing using real Apple Vision AI.
///
/// Uses `VNGeneratePersonSegmentationRequest` to create a pixel-accurate
/// body mask, then composites garment overlays onto the detected silhouette.
/// Garments follow actual body contours instead of rectangles.
@MainActor
@Observable
final class TryOnEngine {

    // MARK: Singleton

    static let shared = TryOnEngine()

    // MARK: State

    /// Current processing state.
    private(set) var state: TryOnState = .idle

    /// The composited result image (user photo with garments applied).
    private(set) var resultImage: UIImage?

    /// Processing time for the last operation (diagnostic).
    private(set) var lastProcessingTimeMs: Int = 0

    /// Whether person segmentation was used (vs rectangle fallback).
    private(set) var usedRealSegmentation = false

    private init() {}

    // MARK: - Public API

    /// Applies the selected garments onto the user photo.
    ///
    /// - Parameters:
    ///   - userPhoto: The full-body photo of the user.
    ///   - outfit: The current outfit selection with garments for each slot.
    /// - Returns: The composited image with garments applied.
    func applyOutfit(to userPhoto: UIImage, outfit: OutfitSelection) async -> UIImage? {
        guard outfit.hasAnySelection else {
            resultImage = userPhoto
            state = .done
            return userPhoto
        }

        state = .processing
        DebugLogger.shared.log("👗 VTO: Processing outfit (\(outfit.count) garments) with Vision AI...", level: .info)

        let startTime = CFAbsoluteTimeGetCurrent()

        // Step 1: Run real person segmentation via Vision AI
        let personMask = await VisionAIService.shared.segmentPerson(from: userPhoto)
        usedRealSegmentation = personMask != nil

        if personMask != nil {
            DebugLogger.shared.log("🧠 VTO: Person segmentation succeeded — using body contour mask", level: .success)
        } else {
            DebugLogger.shared.log("⚠️ VTO: No person detected — using rectangle fallback", level: .warning)
        }

        // Step 2: Composite garments onto detected body (with minimum display time)
        let photo = userPhoto
        let outfitCopy = outfit
        let mask = personMask

        // Run compositing and minimum delay in parallel
        async let compositeTask = Task.detached(priority: .userInitiated) {
            await Self.compositeOutfit(onto: photo, outfit: outfitCopy, personMask: mask)
        }.value
        async let minimumDelay: Void = Task.sleep(nanoseconds: 600_000_000) // 600ms minimum

        let result = await compositeTask
        _ = try? await minimumDelay

        let elapsed = Int((CFAbsoluteTimeGetCurrent() - startTime) * 1000)
        lastProcessingTimeMs = elapsed

        if let result {
            resultImage = result
            state = .done
            let method = personMask != nil ? "Vision AI" : "fallback"
            DebugLogger.shared.log("✅ VTO: Outfit applied in \(elapsed)ms (\(method))", level: .success)
        } else {
            state = .error(message: "Fallo en composición de imagen")
            DebugLogger.shared.log("❌ VTO: Compositing failed", level: .error)
        }

        return result
    }

    /// Clears the current result.
    func reset() {
        resultImage = nil
        state = .idle
        lastProcessingTimeMs = 0
        usedStableDiffusion = false
    }

    /// Whether the last result was generated via Stable Diffusion.
    private(set) var usedStableDiffusion = false

    // MARK: - AI Generation (Stable Diffusion)

    /// Generates a photo-realistic VTO image using Stable Diffusion inpainting.
    ///
    /// Flow:
    /// 1. Segment person → create body mask
    /// 2. Build clothing prompt from selected garments
    /// 3. Create zone mask for clothing areas
    /// 4. Run SD inpainting → photo-realistic result
    ///
    /// - Parameters:
    ///   - userPhoto: Full-body photo of the user.
    ///   - outfit: Selected garments to "wear".
    /// - Returns: AI-generated image or nil on failure.
    func generateWithAI(userPhoto: UIImage, outfit: OutfitSelection) async -> UIImage? {
        guard outfit.hasAnySelection else {
            resultImage = userPhoto
            state = .done
            return userPhoto
        }

        guard StableDiffusionService.shared.state.isReady else {
            state = .error(message: "Motor de IA no disponible. Descarga el modelo primero.")
            DebugLogger.shared.log("❌ VTO AI: SD pipeline not ready", level: .error)
            return nil
        }

        state = .generatingAI(progress: 0.0)
        DebugLogger.shared.log("🎨 VTO AI: Starting Stable Diffusion generation...", level: .info)

        let startTime = CFAbsoluteTimeGetCurrent()

        // Step 1: Get person segmentation mask
        let personMask = await VisionAIService.shared.segmentPerson(from: userPhoto)
        usedRealSegmentation = personMask != nil

        // Step 2: Create zone mask for clothing areas
        let clothingMask = createClothingZoneMask(
            personMask: personMask,
            imageSize: userPhoto.size,
            outfit: outfit
        )

        // Step 3: Build prompt from garment descriptions
        let prompt = buildClothingPrompt(outfit: outfit)
        DebugLogger.shared.log("🎨 VTO AI: Prompt: \"\(prompt)\"", level: .info)

        // Step 4: Run Stable Diffusion inpainting
        let generated = await StableDiffusionService.shared.generateTryOn(
            personImage: userPhoto,
            mask: clothingMask,
            prompt: prompt,
            steps: 20,
            guidanceScale: 7.5
        )

        let elapsed = Int((CFAbsoluteTimeGetCurrent() - startTime) * 1000)
        lastProcessingTimeMs = elapsed

        if let generated {
            resultImage = generated
            state = .done
            usedStableDiffusion = true
            DebugLogger.shared.log("✅ VTO AI: Generated in \(elapsed)ms", level: .success)
        } else {
            state = .error(message: "La generación con IA falló. Intenta de nuevo.")
            DebugLogger.shared.log("❌ VTO AI: Generation failed after \(elapsed)ms", level: .error)
        }

        return generated
    }

    // MARK: - AI Helpers

    /// Builds a text prompt describing the outfit for SD.
    private func buildClothingPrompt(outfit: OutfitSelection) -> String {
        var parts: [String] = ["person wearing"]

        if let top = outfit.top {
            parts.append(top.name.lowercased())
        }

        if let bottom = outfit.bottom {
            parts.append("with \(bottom.name.lowercased())")
        }

        if let shoes = outfit.shoes {
            parts.append("and \(shoes.name.lowercased())")
        }

        parts.append(", professional fashion photo, studio lighting, high quality, detailed clothing texture")

        return parts.joined(separator: " ")
    }

    /// Creates a binary mask image indicating which zones to repaint.
    ///
    /// White = repaint (clothing zone), Black = keep (face, background).
    private func createClothingZoneMask(
        personMask: CGImage?,
        imageSize: CGSize,
        outfit: OutfitSelection
    ) -> UIImage {
        let renderer = UIGraphicsImageRenderer(size: imageSize)
        return renderer.image { ctx in
            let cgContext = ctx.cgContext
            let width = imageSize.width
            let height = imageSize.height

            // Start with all black (keep everything)
            cgContext.setFillColor(UIColor.black.cgColor)
            cgContext.fill(CGRect(origin: .zero, size: imageSize))

            // If we have a person mask, use it to constrain painting to body
            if let mask = personMask {
                cgContext.saveGState()
                cgContext.clip(to: CGRect(origin: .zero, size: imageSize), mask: mask)
            }

            // Paint white in clothing zones (areas to repaint)
            cgContext.setFillColor(UIColor.white.cgColor)

            if outfit.top != nil {
                // Upper body: 20% to 50% of height
                let topRect = CGRect(
                    x: width * 0.1,
                    y: height * 0.2,
                    width: width * 0.8,
                    height: height * 0.30
                )
                cgContext.fill(topRect)
            }

            if outfit.bottom != nil {
                // Lower body: 48% to 78% of height
                let bottomRect = CGRect(
                    x: width * 0.15,
                    y: height * 0.48,
                    width: width * 0.7,
                    height: height * 0.30
                )
                cgContext.fill(bottomRect)
            }

            if outfit.shoes != nil {
                // Feet: 78% to 95% of height
                let shoesRect = CGRect(
                    x: width * 0.15,
                    y: height * 0.78,
                    width: width * 0.7,
                    height: height * 0.17
                )
                cgContext.fill(shoesRect)
            }

            if personMask != nil {
                cgContext.restoreGState()
            }
        }
    }

    // MARK: - Compositing (Vision AI + Core Graphics)

    /// Creates a visual composite of garments on the user photo.
    ///
    /// When a person mask is available (from VNGeneratePersonSegmentationRequest),
    /// garment overlays are clipped to the actual body silhouette. Each slot
    /// (top, bottom, shoes) is restricted to its proportional body zone within
    /// the detected person mask.
    ///
    /// Falls back to rectangle-based compositing if no person was detected.
    private static func compositeOutfit(
        onto photo: UIImage,
        outfit: OutfitSelection,
        personMask: CGImage?
    ) async -> UIImage? {
        let size = photo.size
        let renderer = UIGraphicsImageRenderer(size: size)

        return renderer.image { context in
            let cgContext = context.cgContext
            let fullRect = CGRect(origin: .zero, size: size)

            // Draw the original photo as base
            photo.draw(in: fullRect)

            // Apply each garment overlay
            for slot in GarmentSlot.allCases {
                guard let garment = outfit.garment(for: slot) else { continue }

                let zone = slot.bodyZone
                let insetX: CGFloat = slot == .shoes ? 0.20 : 0.08
                let garmentRect = CGRect(
                    x: size.width * insetX,
                    y: size.height * zone.lowerBound,
                    width: size.width * (1.0 - 2 * insetX),
                    height: size.height * (zone.upperBound - zone.lowerBound)
                )

                // === Layer 1: Clip to Body Mask (Real AI) ===
                cgContext.saveGState()

                if let mask = personMask {
                    cgContext.clip(to: garmentRect, mask: mask)
                } else {
                    let cornerRadius = garmentRect.width * 0.06
                    let clipPath = UIBezierPath(roundedRect: garmentRect, cornerRadius: cornerRadius)
                    clipPath.addClip()
                }

                // === Layer 2: Garment Image or Gradient ===
                if garment.isFromWardrobe, let thumb = garment.thumbnailImage {
                    // Real wardrobe garment — draw the actual photo
                    cgContext.setBlendMode(.normal)
                    cgContext.setAlpha(0.80)
                    thumb.draw(in: garmentRect)
                } else {
                    // Sample garment — subtle color tint only
                    let colors = garment.gradientColors.map { UIColor($0).cgColor } as CFArray
                    if let gradient = CGGradient(
                        colorsSpace: CGColorSpaceCreateDeviceRGB(),
                        colors: colors,
                        locations: [0.0, 1.0]
                    ) {
                        cgContext.setBlendMode(.multiply)
                        cgContext.setAlpha(0.30)
                        cgContext.drawLinearGradient(
                            gradient,
                            start: CGPoint(x: garmentRect.minX, y: garmentRect.minY),
                            end: CGPoint(x: garmentRect.maxX, y: garmentRect.maxY),
                            options: []
                        )
                    }
                }

                // === Layer 3: Body Curvature (Radial shading) ===
                cgContext.setBlendMode(.softLight)
                cgContext.setAlpha(0.20)
                if let bodyGrad = CGGradient(
                    colorsSpace: CGColorSpaceCreateDeviceRGB(),
                    colors: [
                        UIColor.white.withAlphaComponent(0.15).cgColor,
                        UIColor.clear.cgColor,
                        UIColor.black.withAlphaComponent(0.1).cgColor
                    ] as CFArray,
                    locations: [0.0, 0.45, 1.0]
                ) {
                    let center = CGPoint(x: garmentRect.midX, y: garmentRect.midY)
                    let radius = max(garmentRect.width, garmentRect.height) / 2
                    cgContext.drawRadialGradient(
                        bodyGrad,
                        startCenter: center, startRadius: 0,
                        endCenter: center, endRadius: radius,
                        options: []
                    )
                }

                cgContext.restoreGState()
            }

            // === Premium Vignette ===
            cgContext.saveGState()
            if let vignetteGradient = CGGradient(
                colorsSpace: CGColorSpaceCreateDeviceRGB(),
                colors: [
                    UIColor.clear.cgColor,
                    UIColor.black.withAlphaComponent(0.15).cgColor
                ] as CFArray,
                locations: [0.55, 1.0]
            ) {
                let center = CGPoint(x: size.width / 2, y: size.height / 2)
                let radius = max(size.width, size.height) / 2
                cgContext.drawRadialGradient(
                    vignetteGradient,
                    startCenter: center, startRadius: 0,
                    endCenter: center, endRadius: radius,
                    options: []
                )
            }
            cgContext.restoreGState()
        }
    }

    // MARK: - Fabric Textures

    /// Draws a simulated fabric texture pattern within the given rect.
    private static func drawFabricTexture(in ctx: CGContext, rect: CGRect, slot: GarmentSlot) {
        switch slot {
        case .top:
            // Knit pattern: horizontal wave lines
            ctx.setStrokeColor(UIColor.white.withAlphaComponent(0.10).cgColor)
            ctx.setLineWidth(0.5)
            let spacing: CGFloat = 6
            var y = rect.minY
            while y < rect.maxY {
                ctx.move(to: CGPoint(x: rect.minX, y: y))
                var x = rect.minX
                while x < rect.maxX {
                    let nextX = min(x + spacing, rect.maxX)
                    let cp = CGPoint(x: x + spacing / 2, y: y + 1.5)
                    ctx.addQuadCurve(to: CGPoint(x: nextX, y: y), control: cp)
                    x += spacing
                }
                ctx.strokePath()
                y += spacing
            }

        case .bottom:
            // Denim crosshatch: diagonal lines
            ctx.setStrokeColor(UIColor.white.withAlphaComponent(0.07).cgColor)
            ctx.setLineWidth(0.5)
            let spacing: CGFloat = 8
            var offset: CGFloat = 0
            while offset < rect.width + rect.height {
                ctx.move(to: CGPoint(x: rect.minX + offset, y: rect.minY))
                ctx.addLine(to: CGPoint(x: rect.minX, y: rect.minY + offset))
                ctx.strokePath()
                offset += spacing
            }
            offset = 0
            while offset < rect.width + rect.height {
                ctx.move(to: CGPoint(x: rect.maxX - offset, y: rect.minY))
                ctx.addLine(to: CGPoint(x: rect.maxX, y: rect.minY + offset))
                ctx.strokePath()
                offset += spacing
            }

        case .shoes:
            // Leather grain: subtle noise dots
            ctx.setFillColor(UIColor.white.withAlphaComponent(0.05).cgColor)
            let dotSpacing: CGFloat = 10
            var x = rect.minX
            while x < rect.maxX {
                var y = rect.minY
                while y < rect.maxY {
                    let r = CGFloat.random(in: 0.5...1.5)
                    ctx.fillEllipse(in: CGRect(x: x, y: y, width: r, height: r))
                    y += dotSpacing + CGFloat.random(in: -2...2)
                }
                x += dotSpacing + CGFloat.random(in: -2...2)
            }
        }
    }
}
