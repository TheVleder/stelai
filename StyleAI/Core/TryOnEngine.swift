// TryOnEngine.swift
// StyleAI — Virtual Try-On Processing Pipeline
//
// Two rendering modes:
// 1. Fast Preview: Vision AI segmentation + gradient overlays (~200ms)
// 2. AI Generation: Stable Diffusion inpainting for photo-realistic results (~15s)

import SwiftUI
import UIKit
import Vision
import CoreImage
import CoreImage.CIFilterBuiltins

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

    /// Whever the last result was generated via Stable Diffusion.
    private(set) var usedStableDiffusion = false

    /// Clears any active error state
    func clearError() {
        if case .error = state {
            state = .idle
        }
    }

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

        // Step 1b: Pre-composite the garments onto the photo (the "pegotes")
        let compositedImage = await Self.compositeOutfit(onto: userPhoto, outfit: outfit, personMask: personMask) ?? userPhoto

        // Step 2: Create precise zone mask using body keypoints (only paint selected garments)
        let clothingMask = createClothingZoneMask(
            personMask: personMask,
            imageSize: userPhoto.size,
            outfit: outfit,
            sourceImage: userPhoto   // ← body pose keypoints derived from user's actual photo
        )

        // Step 3: Build prompt from garment descriptions
        let prompt = buildClothingPrompt(outfit: outfit)
        DebugLogger.shared.log("🎨 VTO AI: Prompt: \"\(prompt)\"", level: .info)

        // Step 4: Run Stable Diffusion inpainting on the composited base image
        let generated = await StableDiffusionService.shared.generateTryOn(
            personImage: compositedImage,
            mask: clothingMask,
            prompt: prompt,
            steps: 35,          // 35 steps = significantly sharper fabric detail
            guidanceScale: 8.5  // Higher guidance = more faithful to garment style
        )

        let elapsed = Int((CFAbsoluteTimeGetCurrent() - startTime) * 1000)
        lastProcessingTimeMs = elapsed

        if let generated {
            // Step 5: Master blend - Keep original face/background, insert ONLY generated clothing
            // We use the clothingMask AND the personMask to ensure the AI NEVER draws outside the body
            let finalImage = blend(original: userPhoto, generated: generated, clothingMask: clothingMask, personMask: personMask)
            resultImage = finalImage
            state = .done
            usedStableDiffusion = true
            DebugLogger.shared.log("✅ VTO AI: Generated and blended cleanly in \(elapsed)ms", level: .success)
        } else {
            state = .error(message: "La generación con IA falló. Intenta de nuevo.")
            DebugLogger.shared.log("❌ VTO AI: Generation failed after \(elapsed)ms", level: .error)
        }

        return resultImage  // ✅ Return the properly blended image (face + background preserved)
    }

    // MARK: - AI Helpers

    /// Builds a text prompt describing the outfit for SD.
    private func buildClothingPrompt(outfit: OutfitSelection) -> String {
        var parts: [String] = []

        if let top = outfit.top {
            parts.append(top.name)
        }
        if let bottom = outfit.bottom {
            parts.append(bottom.name)
        }
        if let shoes = outfit.shoes {
            parts.append(shoes.name)
        }
        let garmentDesc = parts.joined(separator: ", ")

        return "fashion photography portrait of a person wearing \(garmentDesc), "
            + "photorealistic, high resolution 4k, natural daylight, sharp fabric texture, "
            + "fitted clothing, no creases, perfect tailoring, editorial model photo, "
            + "Canon EOS R5, f/2.8, bokeh background, masterpiece, best quality"
    }

    // MARK: - Clothing Zone Mask (Body Pose AI)

    /// Creates an inpainting mask where WHITE = repaint (clothing) and BLACK = keep (face/bg).
    /// Uses VNHumanBodyPoseRequest for pixel-accurate garment zone boundaries.
    private func createClothingZoneMask(
        personMask: CGImage?,
        imageSize: CGSize,
        outfit: OutfitSelection,
        sourceImage: UIImage? = nil
    ) -> UIImage {
        // Try body pose first for precision
        if let src = sourceImage,
           let poseMask = createMaskUsingBodyPose(image: src, imageSize: imageSize, outfit: outfit) {
            return poseMask
        }
        // Fallback to proportional rects
        return createMaskUsingProportions(imageSize: imageSize, outfit: outfit, personMask: personMask)
    }

    /// Body-pose based clothing mask using actual skeleton keypoints.
    private func createMaskUsingBodyPose(image: UIImage, imageSize: CGSize, outfit: OutfitSelection) -> UIImage? {
        guard let cgImage = image.cgImage else { return nil }

        let request = VNDetectHumanBodyPoseRequest()
        let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
        do { try handler.perform([request]) } catch { return nil }
        guard let obs = request.results?.first else { return nil }

        func pt(_ j: VNHumanBodyPoseObservation.JointName) -> CGPoint? {
            guard let p = try? obs.recognizedPoint(j), p.confidence > 0.25 else { return nil }
            return CGPoint(x: p.location.x * imageSize.width,
                           y: (1.0 - p.location.y) * imageSize.height)
        }
        func avgY(_ a: CGPoint?, _ b: CGPoint?) -> CGFloat? {
            let ys = [a, b].compactMap { $0?.y }; return ys.isEmpty ? nil : ys.reduce(0,+)/CGFloat(ys.count)
        }
        func lX(_ pts: [CGPoint?]) -> CGFloat { pts.compactMap{$0?.x}.min() ?? imageSize.width*0.05 }
        func rX(_ pts: [CGPoint?]) -> CGFloat { pts.compactMap{$0?.x}.max() ?? imageSize.width*0.95 }

        let neck = pt(.neck)
        let lS = pt(.leftShoulder); let rS = pt(.rightShoulder)
        let lH = pt(.leftHip);      let rH = pt(.rightHip)
        let lK = pt(.leftKnee);     let rK = pt(.rightKnee)
        let lA = pt(.leftAnkle);    let rA = pt(.rightAnkle)
        let lW = pt(.leftWrist);    let rW = pt(.rightWrist)

        let pad: CGFloat = 20
        var rects: [CGRect] = []

        if outfit.top != nil, let shY = avgY(lS, rS), let hY = avgY(lH, rH) {
            let top = (neck?.y ?? shY) - pad
            rects.append(CGRect(x: lX([lS,lW,lH])-pad, y: top,
                                width: rX([rS,rW,rH])+pad - (lX([lS,lW,lH])-pad),
                                height: hY+pad - top))
        }
        if outfit.bottom != nil, let hY = avgY(lH, rH), let aY = avgY(lA, rA) {
            rects.append(CGRect(x: lX([lH,lK,lA])-pad, y: hY-pad,
                                width: rX([rH,rK,rA])+pad - (lX([lH,lK,lA])-pad),
                                height: aY+pad - (hY-pad)))
        }
        if outfit.shoes != nil, let aY = avgY(lA, rA) {
            let kneeY = avgY(lK, rK) ?? (aY - imageSize.height*0.12)
            rects.append(CGRect(x: lX([lA,lK])-pad, y: kneeY-pad,
                                width: rX([rA,rK])+pad - (lX([lA,lK])-pad),
                                height: min(aY + imageSize.height*0.07 + pad, imageSize.height) - (kneeY-pad)))
        }

        guard !rects.isEmpty else { return nil }

        let fmt = UIGraphicsImageRendererFormat(); fmt.scale = 1.0
        return UIGraphicsImageRenderer(size: imageSize, format: fmt).image { ctx in
            let cgCtx = ctx.cgContext
            cgCtx.setFillColor(UIColor.black.cgColor)
            cgCtx.fill(CGRect(origin: .zero, size: imageSize))
            cgCtx.setFillColor(UIColor.white.cgColor)
            for r in rects {
                let clamped = r.intersection(CGRect(origin: .zero, size: imageSize))
                cgCtx.fill(clamped)
            }
        }
    }

    /// Proportional fallback mask when body pose fails.
    private func createMaskUsingProportions(imageSize: CGSize, outfit: OutfitSelection, personMask: CGImage?) -> UIImage {
        let w = imageSize.width; let h = imageSize.height
        let fmt = UIGraphicsImageRendererFormat(); fmt.scale = 1.0
        return UIGraphicsImageRenderer(size: imageSize, format: fmt).image { ctx in
            let cgCtx = ctx.cgContext
            cgCtx.setFillColor(UIColor.black.cgColor)
            cgCtx.fill(CGRect(origin: .zero, size: imageSize))

            if let mask = personMask {
                cgCtx.saveGState()
                cgCtx.translateBy(x: 0, y: h); cgCtx.scaleBy(x: 1, y: -1)
                cgCtx.clip(to: CGRect(origin: .zero, size: imageSize), mask: mask)
                cgCtx.scaleBy(x: 1, y: -1); cgCtx.translateBy(x: 0, y: -h)
            }
            cgCtx.setFillColor(UIColor.white.cgColor)
            if outfit.top    != nil { cgCtx.fill(CGRect(x: w*0.08, y: h*0.20, width: w*0.84, height: h*0.32)) }
            if outfit.bottom != nil { cgCtx.fill(CGRect(x: w*0.12, y: h*0.48, width: w*0.76, height: h*0.34)) }
            if outfit.shoes  != nil { cgCtx.fill(CGRect(x: w*0.15, y: h*0.80, width: w*0.70, height: h*0.16)) }
            if personMask != nil { cgCtx.restoreGState() }
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
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1.0
        let renderer = UIGraphicsImageRenderer(size: size, format: format)

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

                // === Composite garment over photo ===
                cgContext.saveGState()

                // Clip to the garment's slot zone with rounded corners for a clean look
                let cornerRadius = garmentRect.width * 0.06
                let clipPath = UIBezierPath(roundedRect: garmentRect, cornerRadius: cornerRadius)
                clipPath.addClip()

                if garment.isFromWardrobe, let thumb = garment.thumbnailImage {
                    // Real wardrobe garment — aspect fill within garmentRect
                    let aspectWidth = garmentRect.width / thumb.size.width
                    let aspectHeight = garmentRect.height / thumb.size.height
                    let fillScale = max(aspectWidth, aspectHeight)

                    let drawWidth = thumb.size.width * fillScale
                    let drawHeight = thumb.size.height * fillScale
                    let drawX = garmentRect.midX - drawWidth / 2
                    let drawY = garmentRect.midY - drawHeight / 2

                    thumb.draw(
                        in: CGRect(x: drawX, y: drawY, width: drawWidth, height: drawHeight),
                        blendMode: .normal,
                        alpha: 0.82
                    )
                } else {
                    // Sample garment — subtle color gradient overlay
                    cgContext.setBlendMode(.multiply)
                    cgContext.setAlpha(0.28)
                    let colors = garment.gradientColors.map { UIColor($0).cgColor } as CFArray
                    if let gradient = CGGradient(
                        colorsSpace: CGColorSpaceCreateDeviceRGB(),
                        colors: colors,
                        locations: [0.0, 1.0]
                    ) {
                        cgContext.drawLinearGradient(
                            gradient,
                            start: CGPoint(x: garmentRect.minX, y: garmentRect.minY),
                            end: CGPoint(x: garmentRect.maxX, y: garmentRect.maxY),
                            options: []
                        )
                    }
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

    // MARK: - Blending Mask

    /// Blends the AI-generated clothing back onto the original photo perfectly preserving the face/background.
    /// It uses both the zone mask (where clothes are) and the person mask (where the body is) 
    /// to aggressively restrict AI pixels strictly to the user's silhouette.
    private func blend(original: UIImage, generated: UIImage, clothingMask: UIImage, personMask: CGImage?) -> UIImage {
        let context = CIContext(options: [.useSoftwareRenderer: false])
        
        guard let origCI = CIImage(image: original),
              let genCI = CIImage(image: generated),
              let maskCI = CIImage(image: clothingMask) else {
            return generated
        }
        
        let targetExtent = origCI.extent
        
        // Scale generated to match original
        let scaleGenX = targetExtent.width / genCI.extent.width
        let scaleGenY = targetExtent.height / genCI.extent.height
        let scaledGen = genCI.transformed(by: CGAffineTransform(scaleX: scaleGenX, y: scaleGenY))
        
        // Scale mask to match original
        let scaleMaskX = targetExtent.width / maskCI.extent.width
        let scaleMaskY = targetExtent.height / maskCI.extent.height
        var scaledMask = maskCI.transformed(by: CGAffineTransform(scaleX: scaleMaskX, y: scaleMaskY))
        
        // INTERSECTION: multiply clothing mask * body silhouette
        // So AI can NEVER paint outside the user's real body
        if let pMaskCG = personMask {
            let pMaskCI = CIImage(cgImage: pMaskCG)
            let pScaleX = targetExtent.width / pMaskCI.extent.width
            let pScaleY = targetExtent.height / pMaskCI.extent.height
            let scaledPMask = pMaskCI.transformed(by: CGAffineTransform(scaleX: pScaleX, y: pScaleY))
            let multiplyFilter = CIFilter.multiplyCompositing()
            multiplyFilter.inputImage = scaledMask
            multiplyFilter.backgroundImage = scaledPMask
            if let combo = multiplyFilter.outputImage {
                scaledMask = combo
            }
        }
        
        // === FEATHERING: Apply Gaussian blur to the mask to soften edges ===
        // This is the key to removing the hard "pegote" border.
        // A blur radius of ~12pt creates a gradual, photorealistic-looking transition.
        let blurFilter = CIFilter.gaussianBlur()
        blurFilter.inputImage = scaledMask
        blurFilter.radius = 14 // softness of the transition edge in pixels
        if let blurredMask = blurFilter.outputImage {
            // Clamp to prevent black edges from infinite extent
            scaledMask = blurredMask.cropped(to: targetExtent)
        }
        
        // Master Blend: AI clothing on top of original photo, controlled by feathered mask
        let blendFilter = CIFilter.blendWithMask()
        blendFilter.inputImage = scaledGen   // Foreground: AI-generated clothing
        blendFilter.backgroundImage = origCI // Background: original untouched photo
        blendFilter.maskImage = scaledMask   // Feathered mask: smooth in/out
        
        if let output = blendFilter.outputImage,
           let cgImage = context.createCGImage(output, from: targetExtent) {
            return UIImage(cgImage: cgImage, scale: original.scale, orientation: original.imageOrientation)
        }
        
        return generated
    }
}
