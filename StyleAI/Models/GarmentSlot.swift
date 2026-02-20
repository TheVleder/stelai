// GarmentSlot.swift
// StyleAI — Virtual Try-On Garment Slots
//
// Defines the three body zones used by the VTO probador:
// top (torso), bottom (legs), and shoes (feet).

import SwiftUI

// MARK: - Garment Slot

/// The three equip zones in the Virtual Try-On probador.
/// Each slot maps to a carousel in the TryOnView.
enum GarmentSlot: String, CaseIterable, Identifiable, Codable, Sendable {
    case top    = "top"
    case bottom = "bottom"
    case shoes  = "shoes"

    var id: String { rawValue }

    /// SF Symbol icon for each slot.
    var icon: String {
        switch self {
        case .top:    return "tshirt.fill"
        case .bottom: return "figure.walk"
        case .shoes:  return "shoe.fill"
        }
    }

    /// Spanish UI label.
    var label: String {
        switch self {
        case .top:    return "Parte Superior"
        case .bottom: return "Parte Inferior"
        case .shoes:  return "Calzado"
        }
    }

    /// Accent color for the slot category.
    var accentColor: Color {
        switch self {
        case .top:    return StyleColors.primaryMid
        case .bottom: return StyleColors.accentRose
        case .shoes:  return StyleColors.accentMint
        }
    }

    /// The vertical zone on the body photo where this garment appears.
    /// Returns a normalized range (0.0 = top of image, 1.0 = bottom).
    var bodyZone: ClosedRange<CGFloat> {
        switch self {
        case .top:    return 0.23...0.55
        case .bottom: return 0.45...0.78
        case .shoes:  return 0.75...0.95
        }
    }
}
