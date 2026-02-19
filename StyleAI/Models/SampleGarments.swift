// SampleGarments.swift
// StyleAI — Demo Garment Data
//
// Sample garments for testing the VTO UI without real wardrobe photos.
// Each garment has a visual representation using gradients and SF Symbols.

import SwiftUI

// MARK: - Sample Garment

/// A lightweight garment representation for UI showcase and demo mode.
/// In production, these would come from SwiftData `WardrobeItem` records.
struct SampleGarment: Identifiable, Hashable, Sendable {
    let id: UUID
    let name: String
    let slot: GarmentSlot
    let gradientColors: [Color]
    let icon: String
    let thermalIndex: Double

    /// Human-readable thermal label
    var thermalLabel: String {
        switch thermalIndex {
        case ..<0.25:     return "Frío"
        case 0.25..<0.50: return "Templado"
        case 0.50..<0.75: return "Cálido"
        default:          return "Caluroso"
        }
    }

    // Conformance for Hashable
    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }

    static func == (lhs: SampleGarment, rhs: SampleGarment) -> Bool {
        lhs.id == rhs.id
    }
}

// MARK: - Sample Data

/// Pre-built garment catalog for demo / testing.
enum SampleGarments {

    // MARK: Tops

    static let whiteTee = SampleGarment(
        id: UUID(), name: "Camiseta Blanca",
        slot: .top,
        gradientColors: [.white, Color(white: 0.92)],
        icon: "tshirt.fill",
        thermalIndex: 0.70
    )

    static let blackHoodie = SampleGarment(
        id: UUID(), name: "Hoodie Negro",
        slot: .top,
        gradientColors: [Color(white: 0.15), Color(white: 0.25)],
        icon: "tshirt.fill",
        thermalIndex: 0.20
    )

    static let denimJacket = SampleGarment(
        id: UUID(), name: "Chaqueta Denim",
        slot: .top,
        gradientColors: [Color(hue: 0.60, saturation: 0.50, brightness: 0.55),
                         Color(hue: 0.58, saturation: 0.40, brightness: 0.70)],
        icon: "tshirt.fill",
        thermalIndex: 0.30
    )

    static let stripedPolo = SampleGarment(
        id: UUID(), name: "Polo Rayas",
        slot: .top,
        gradientColors: [Color(hue: 0.58, saturation: 0.30, brightness: 0.85),
                         Color.white],
        icon: "tshirt.fill",
        thermalIndex: 0.60
    )

    static let redShirt = SampleGarment(
        id: UUID(), name: "Camisa Roja",
        slot: .top,
        gradientColors: [Color(hue: 0.0, saturation: 0.65, brightness: 0.75),
                         Color(hue: 0.02, saturation: 0.50, brightness: 0.85)],
        icon: "tshirt.fill",
        thermalIndex: 0.55
    )

    // MARK: Bottoms

    static let darkJeans = SampleGarment(
        id: UUID(), name: "Jeans Oscuros",
        slot: .bottom,
        gradientColors: [Color(hue: 0.62, saturation: 0.55, brightness: 0.30),
                         Color(hue: 0.60, saturation: 0.45, brightness: 0.40)],
        icon: "figure.walk",
        thermalIndex: 0.35
    )

    static let beigeChinos = SampleGarment(
        id: UUID(), name: "Chinos Beige",
        slot: .bottom,
        gradientColors: [Color(hue: 0.10, saturation: 0.25, brightness: 0.80),
                         Color(hue: 0.08, saturation: 0.20, brightness: 0.90)],
        icon: "figure.walk",
        thermalIndex: 0.55
    )

    static let blackPants = SampleGarment(
        id: UUID(), name: "Pantalón Negro",
        slot: .bottom,
        gradientColors: [Color(white: 0.12), Color(white: 0.22)],
        icon: "figure.walk",
        thermalIndex: 0.40
    )

    static let cargoShorts = SampleGarment(
        id: UUID(), name: "Cargo Shorts",
        slot: .bottom,
        gradientColors: [Color(hue: 0.25, saturation: 0.30, brightness: 0.50),
                         Color(hue: 0.22, saturation: 0.25, brightness: 0.60)],
        icon: "figure.walk",
        thermalIndex: 0.80
    )

    static let greyJoggers = SampleGarment(
        id: UUID(), name: "Jogger Gris",
        slot: .bottom,
        gradientColors: [Color(white: 0.45), Color(white: 0.60)],
        icon: "figure.walk",
        thermalIndex: 0.45
    )

    // MARK: Shoes

    static let whiteSneakers = SampleGarment(
        id: UUID(), name: "Sneakers Blancas",
        slot: .shoes,
        gradientColors: [.white, Color(white: 0.90)],
        icon: "shoe.fill",
        thermalIndex: 0.60
    )

    static let blackBoots = SampleGarment(
        id: UUID(), name: "Botas Negras",
        slot: .shoes,
        gradientColors: [Color(white: 0.10), Color(white: 0.20)],
        icon: "shoe.fill",
        thermalIndex: 0.15
    )

    static let runningShoes = SampleGarment(
        id: UUID(), name: "Running Naranja",
        slot: .shoes,
        gradientColors: [Color(hue: 0.08, saturation: 0.80, brightness: 0.95),
                         Color(hue: 0.05, saturation: 0.60, brightness: 0.80)],
        icon: "shoe.fill",
        thermalIndex: 0.65
    )

    static let loafers = SampleGarment(
        id: UUID(), name: "Mocasines Marrón",
        slot: .shoes,
        gradientColors: [Color(hue: 0.07, saturation: 0.55, brightness: 0.40),
                         Color(hue: 0.06, saturation: 0.45, brightness: 0.55)],
        icon: "shoe.fill",
        thermalIndex: 0.50
    )

    static let sandals = SampleGarment(
        id: UUID(), name: "Sandalias",
        slot: .shoes,
        gradientColors: [Color(hue: 0.10, saturation: 0.30, brightness: 0.75),
                         Color(hue: 0.08, saturation: 0.25, brightness: 0.85)],
        icon: "shoe.fill",
        thermalIndex: 0.90
    )

    // MARK: Collections

    static let allTops: [SampleGarment] = [whiteTee, blackHoodie, denimJacket, stripedPolo, redShirt]
    static let allBottoms: [SampleGarment] = [darkJeans, beigeChinos, blackPants, cargoShorts, greyJoggers]
    static let allShoes: [SampleGarment] = [whiteSneakers, blackBoots, runningShoes, loafers, sandals]

    /// All sample garments across all slots.
    static let all: [SampleGarment] = allTops + allBottoms + allShoes

    /// Filter by slot.
    static func garments(for slot: GarmentSlot) -> [SampleGarment] {
        switch slot {
        case .top:    return allTops
        case .bottom: return allBottoms
        case .shoes:  return allShoes
        }
    }
}
