// WardrobeItem.swift
// StyleAI — Wardrobe Data Model
//
// SwiftData model representing a single garment in the user's virtual closet.
// Stores image data, AI-generated metadata, thermal index, and vector embeddings.

import Foundation
import SwiftData

// MARK: - Garment Type Enum

/// Classifies garments into high-level clothing categories.
/// The raw `String` value enables direct SwiftData persistence and JSON interop.
enum GarmentType: String, Codable, CaseIterable, Identifiable {
    case top        = "top"
    case bottom     = "bottom"
    case outerwear  = "outerwear"
    case shoes      = "shoes"
    case accessory  = "accessory"
    case fullBody   = "full_body"

    var id: String { rawValue }

    /// SF Symbol icon for each garment category.
    var icon: String {
        switch self {
        case .top:       return "tshirt.fill"
        case .bottom:    return "figure.walk"
        case .outerwear: return "cloud.snow.fill"
        case .shoes:     return "shoe.fill"
        case .accessory: return "eyeglasses"
        case .fullBody:  return "figure.dress.line.vertical.figure"
        }
    }

    /// Human-readable localized label.
    var label: String {
        switch self {
        case .top:       return "Parte Superior"
        case .bottom:    return "Parte Inferior"
        case .outerwear: return "Abrigo"
        case .shoes:     return "Calzado"
        case .accessory: return "Accesorio"
        case .fullBody:  return "Cuerpo Completo"
        }
    }
}

// MARK: - Thermal Category

/// Maps a continuous thermal index (0.0–1.0) into discrete climate categories.
enum ThermalCategory: String, Codable {
    case cold = "Frío"
    case mild = "Templado"
    case warm = "Cálido"
    case hot  = "Caluroso"

    /// Color hint for UI badges.
    var colorName: String {
        switch self {
        case .cold: return "blue"
        case .mild: return "green"
        case .warm: return "orange"
        case .hot:  return "red"
        }
    }
}

// MARK: - Wardrobe Item Model

/// Core data model for a garment stored in the user's virtual wardrobe.
///
/// Persisted via SwiftData. Each item holds:
/// - The cropped, inpainted garment image as raw `Data`.
/// - AI-classified metadata (type, style tags, thermal index).
/// - Optional vector embeddings for future similarity search / outfit matching.
@Model
final class WardrobeItem {

    // MARK: Identity

    /// Stable unique identifier.
    @Attribute(.unique)
    var id: UUID

    // MARK: Visual Data

    /// PNG/JPEG image data of the segmented and inpainted garment.
    /// Stored as an external binary to keep the database lean.
    @Attribute(.externalStorage)
    var imageData: Data

    /// Optional thumbnail (256×256) for fast grid rendering.
    @Attribute(.externalStorage)
    var thumbnailData: Data?

    // MARK: AI-Generated Metadata

    /// Garment classification produced by the segmentation model.
    var typeRawValue: String

    /// Thermal index from 0.0 (very cold-weather) to 1.0 (very hot-weather).
    /// Used by the Weather Stylist to match garments to forecasted temperatures.
    var thermalIndex: Double

    /// Free-form style tags assigned by the classifier (e.g. "casual", "formal", "sporty").
    var styleTags: [String]

    /// AI-detected primary material (e.g. "cotton", "denim", "synthetic").
    var material: String?

    /// AI-detected dominant color name for outfit color-matching.
    var dominantColor: String?

    // MARK: Vector Embeddings

    /// Dense feature vector produced by the garment encoder.
    /// Used for similarity search and outfit compatibility scoring.
    /// Stored as raw floats; typical dimension: 512.
    var embeddings: [Float]

    // MARK: Timestamps

    var dateAdded: Date
    var lastWorn: Date?

    // MARK: Usage Tracking

    /// Number of times this garment has been included in a suggested outfit.
    var wearCount: Int

    /// User favorite flag for priority suggestions.
    var isFavorite: Bool

    // MARK: - Computed Properties

    /// Strongly-typed garment type derived from the persisted raw value.
    var type: GarmentType {
        get { GarmentType(rawValue: typeRawValue) ?? .accessory }
        set { typeRawValue = newValue.rawValue }
    }

    /// Discrete thermal category based on the continuous thermal index.
    var thermalCategory: ThermalCategory {
        switch thermalIndex {
        case ..<0.25:      return .cold
        case 0.25..<0.50:  return .mild
        case 0.50..<0.75:  return .warm
        default:           return .hot
        }
    }

    /// Indicates whether vector embeddings have been computed for this item.
    var hasEmbeddings: Bool {
        !embeddings.isEmpty
    }

    // MARK: - Initializer

    init(
        imageData: Data,
        type: GarmentType = .top,
        thermalIndex: Double = 0.5,
        styleTags: [String] = [],
        material: String? = nil,
        dominantColor: String? = nil,
        embeddings: [Float] = []
    ) {
        self.id = UUID()
        self.imageData = imageData
        self.thumbnailData = nil
        self.typeRawValue = type.rawValue
        self.thermalIndex = min(max(thermalIndex, 0.0), 1.0) // clamp
        self.styleTags = styleTags
        self.material = material
        self.dominantColor = dominantColor
        self.embeddings = embeddings
        self.dateAdded = .now
        self.lastWorn = nil
        self.wearCount = 0
        self.isFavorite = false
    }
}

// MARK: - Convenience Extensions

extension WardrobeItem {

    /// Formatted date string for display.
    var dateAddedFormatted: String {
        dateAdded.formatted(date: .abbreviated, time: .omitted)
    }

    /// Cosine similarity between this item's embeddings and another vector.
    /// Returns `nil` if either vector is empty or dimensions don't match.
    func cosineSimilarity(to other: [Float]) -> Float? {
        guard !embeddings.isEmpty,
              embeddings.count == other.count else { return nil }

        var dotProduct: Float = 0
        var normA: Float = 0
        var normB: Float = 0

        for i in embeddings.indices {
            dotProduct += embeddings[i] * other[i]
            normA += embeddings[i] * embeddings[i]
            normB += other[i] * other[i]
        }

        let denominator = sqrt(normA) * sqrt(normB)
        guard denominator > 0 else { return nil }

        return dotProduct / denominator
    }
}
