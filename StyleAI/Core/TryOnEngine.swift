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

    // MARK: - Compositing (Phase 1: Simulated)

    /// Creates a visual composite of garments on the user photo.
    ///
    /// This is the simulated version using Core Graphics.
    /// In Phase 2, this would be replaced by CoreML inference.
    private static func compositeOutfit(onto photo: UIImage, outfit: OutfitSelection) async -> UIImage? {
        let size = photo.size
        let renderer = UIGraphicsImageRenderer(size: size)

        return renderer.image { context in
            let cgContext = context.cgContext
            let rect = CGRect(origin: .zero, size: size)

            // Draw the original photo
            photo.draw(in: rect)

            // Apply each garment overlay
            for slot in GarmentSlot.allCases {
                guard let garment = outfit.garment(for: slot) else { continue }

                let zone = slot.bodyZone
                let garmentRect = CGRect(
                    x: size.width * 0.10,
                    y: size.height * zone.lowerBound,
                    width: size.width * 0.80,
                    height: size.height * (zone.upperBound - zone.lowerBound)
                )

                // Create garment overlay with gradient colors
                cgContext.saveGState()

                // Soft feathered mask for natural blending
                let maskPath = UIBezierPath(
                    roundedRect: garmentRect,
                    cornerRadius: garmentRect.width * 0.08
                )
                maskPath.addClip()

                // Draw gradient overlay
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

                // Apply blend mode for natural integration with the photo
                cgContext.setBlendMode(.softLight)
                cgContext.setAlpha(0.65)
                cgContext.fill(garmentRect)

                // Add a subtle border/seam line
                cgContext.setBlendMode(.normal)
                cgContext.setStrokeColor(UIColor.white.withAlphaComponent(0.15).cgColor)
                cgContext.setLineWidth(1.5)
                cgContext.stroke(garmentRect.insetBy(dx: 2, dy: 2))

                cgContext.restoreGState()
            }

            // Add subtle vignette for premium look
            cgContext.saveGState()
            let vignetteGradient = CGGradient(
                colorsSpace: CGColorSpaceCreateDeviceRGB(),
                colors: [
                    UIColor.clear.cgColor,
                    UIColor.black.withAlphaComponent(0.2).cgColor
                ] as CFArray,
                locations: [0.6, 1.0]
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
}
