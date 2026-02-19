// TryOnEngine.swift
// StyleAI — Virtual Try-On Processing Pipeline
//
// Handles the AI-powered garment application onto the user's photo.
// Phase 1: Visual simulation using compositing (no real ML models needed).
// Phase 2: Will connect to CoreML Stable Diffusion / ControlNet pipeline.

import SwiftUI
import UIKit

// MARK: - Try-On State

/// Processing state for the VTO pipeline.
enum TryOnState: Equatable, Sendable {
    case idle
    case processing
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
    var top: SampleGarment?
    var bottom: SampleGarment?
    var shoes: SampleGarment?

    /// Returns the garment for the given slot.
    func garment(for slot: GarmentSlot) -> SampleGarment? {
        switch slot {
        case .top:    return top
        case .bottom: return bottom
        case .shoes:  return shoes
        }
    }

    /// Sets the garment for the given slot.
    mutating func setGarment(_ garment: SampleGarment?, for slot: GarmentSlot) {
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

/// Processes Virtual Try-On compositing.
///
/// **Phase 1** (current): Creates a visual composite using colored overlays,
/// blend modes, and transparency to simulate garment application.
///
/// **Phase 2** (future): Will use `ModelManager.shared.model(for: "vto_diffusion")`
/// to run ControlNet-based diffusion inference on the Neural Engine.
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
        DebugLogger.shared.log("👗 VTO: Processing outfit (\(outfit.count) garments)...", level: .info)

        let startTime = CFAbsoluteTimeGetCurrent()

        // Use detached task for compositing work
        let photo = userPhoto
        let outfitCopy = outfit

        let result = await Task.detached(priority: .userInitiated) {
            await Self.compositeOutfit(onto: photo, outfit: outfitCopy)
        }.value

        let elapsed = Int((CFAbsoluteTimeGetCurrent() - startTime) * 1000)
        lastProcessingTimeMs = elapsed

        if let result {
            resultImage = result
            state = .done
            DebugLogger.shared.log("✅ VTO: Outfit applied in \(elapsed)ms", level: .success)
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
    }

    // MARK: - Compositing (Phase 1: Enhanced Simulation)

    /// Creates a visual composite of garments on the user photo.
    ///
    /// Enhanced Phase 1 compositing using Core Graphics with:
    /// - Multi-layer blending (multiply + softLight + overlay)
    /// - Fabric texture simulation (stripes, knit, denim patterns)
    /// - Edge feathering with rounded clips
    /// - Directional lighting / fabric shading
    /// - Inter-garment shadow casting
    /// - Premium vignette
    ///
    /// In Phase 2, this would be replaced by CoreML inference.
    private static func compositeOutfit(onto photo: UIImage, outfit: OutfitSelection) async -> UIImage? {
        let size = photo.size
        let renderer = UIGraphicsImageRenderer(size: size)

        return renderer.image { context in
            let cgContext = context.cgContext
            let rect = CGRect(origin: .zero, size: size)

            // Draw the original photo
            photo.draw(in: rect)

            // Apply each garment overlay with enhanced compositing
            for slot in GarmentSlot.allCases {
                guard let garment = outfit.garment(for: slot) else { continue }

                let zone = slot.bodyZone
                // Body-proportional sizing with natural taper
                let insetX: CGFloat = slot == .shoes ? 0.20 : 0.08
                let garmentRect = CGRect(
                    x: size.width * insetX,
                    y: size.height * zone.lowerBound,
                    width: size.width * (1.0 - 2 * insetX),
                    height: size.height * (zone.upperBound - zone.lowerBound)
                )

                // === Layer 1: Drop Shadow ===
                cgContext.saveGState()
                let shadowRect = garmentRect.offsetBy(dx: 3, dy: 5)
                cgContext.setFillColor(UIColor.black.withAlphaComponent(0.15).cgColor)
                let shadowPath = UIBezierPath(
                    roundedRect: shadowRect,
                    cornerRadius: garmentRect.width * 0.06
                )
                shadowPath.fill()
                cgContext.restoreGState()

                // === Layer 2: Base Garment Shape (Feathered Clip) ===
                cgContext.saveGState()

                let cornerRadius = garmentRect.width * 0.06
                let clipPath = UIBezierPath(roundedRect: garmentRect, cornerRadius: cornerRadius)
                clipPath.addClip()

                // === Layer 3: Gradient Fill (Multiply blend) ===
                let colors = garment.gradientColors.map { UIColor($0).cgColor } as CFArray
                if let gradient = CGGradient(
                    colorsSpace: CGColorSpaceCreateDeviceRGB(),
                    colors: colors,
                    locations: [0.0, 1.0]
                ) {
                    cgContext.setBlendMode(.multiply)
                    cgContext.setAlpha(0.55)
                    cgContext.drawLinearGradient(
                        gradient,
                        start: CGPoint(x: garmentRect.minX, y: garmentRect.minY),
                        end: CGPoint(x: garmentRect.maxX, y: garmentRect.maxY),
                        options: []
                    )
                }

                // === Layer 4: Fabric Texture Pattern ===
                cgContext.setBlendMode(.softLight)
                cgContext.setAlpha(0.25)
                drawFabricTexture(in: cgContext, rect: garmentRect, slot: slot)

                // === Layer 5: Directional Light (Top-left source) ===
                cgContext.setBlendMode(.overlay)
                cgContext.setAlpha(0.20)
                if let lightGrad = CGGradient(
                    colorsSpace: CGColorSpaceCreateDeviceRGB(),
                    colors: [
                        UIColor.white.withAlphaComponent(0.3).cgColor,
                        UIColor.clear.cgColor,
                        UIColor.black.withAlphaComponent(0.15).cgColor
                    ] as CFArray,
                    locations: [0.0, 0.5, 1.0]
                ) {
                    cgContext.drawLinearGradient(
                        lightGrad,
                        start: CGPoint(x: garmentRect.minX, y: garmentRect.minY),
                        end: CGPoint(x: garmentRect.maxX, y: garmentRect.maxY),
                        options: []
                    )
                }

                // === Layer 6: Body Curvature (Radial shading) ===
                cgContext.setBlendMode(.softLight)
                cgContext.setAlpha(0.30)
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

                // === Layer 7: Seam / Edge Highlight ===
                cgContext.setBlendMode(.normal)
                cgContext.setStrokeColor(UIColor.white.withAlphaComponent(0.08).cgColor)
                cgContext.setLineWidth(1.0)
                let seamPath = UIBezierPath(
                    roundedRect: garmentRect.insetBy(dx: 2, dy: 2),
                    cornerRadius: cornerRadius - 2
                )
                seamPath.stroke()

                cgContext.restoreGState()
            }

            // === Premium Vignette ===
            cgContext.saveGState()
            let vignetteGradient = CGGradient(
                colorsSpace: CGColorSpaceCreateDeviceRGB(),
                colors: [
                    UIColor.clear.cgColor,
                    UIColor.black.withAlphaComponent(0.15).cgColor
                ] as CFArray,
                locations: [0.55, 1.0]
            )
            if let vignetteGradient {
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
            // Forward diagonals
            var offset: CGFloat = 0
            while offset < rect.width + rect.height {
                ctx.move(to: CGPoint(x: rect.minX + offset, y: rect.minY))
                ctx.addLine(to: CGPoint(x: rect.minX, y: rect.minY + offset))
                ctx.strokePath()
                offset += spacing
            }
            // Back diagonals
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
