// CarouselPickerView.swift
// StyleAI — Horizontal Garment Carousel
//
// Reusable snap-scrolling carousel for selecting garments within a slot.
// Shows REAL wardrobe items (from SwiftData) with photo thumbnails,
// plus sample garments as fallbacks when the wardrobe is empty.
// Selected item scales up with a glowing border.

import SwiftUI

// MARK: - Carousel Item Protocol

/// Unifies WardrobeItem and SampleGarment for carousel display.
struct CarouselGarment: Identifiable, Hashable, @unchecked Sendable {
    let id: UUID
    let name: String
    let slot: GarmentSlot
    let thermalIndex: Double
    let thumbnailImage: UIImage?         // Real photo (from wardrobe)
    let gradientColors: [Color]          // Fallback gradient (from samples)
    let icon: String
    let isFromWardrobe: Bool

    /// Create from a WardrobeItem
    static func fromWardrobe(_ item: WardrobeItem) -> CarouselGarment {
        let slot: GarmentSlot
        switch item.type {
        case .top, .outerwear: slot = .top
        case .bottom:          slot = .bottom
        case .shoes:           slot = .shoes
        default:               slot = .top
        }

        var thumbnail: UIImage?
        if let data = item.thumbnailData {
            thumbnail = UIImage(data: data)
        } else {
            thumbnail = UIImage(data: item.imageData)
        }

        // Generate default gradient from slot accent color for compositing
        let defaultGradient: [Color] = {
            switch slot {
            case .top:    return [Color(hue: 0.58, saturation: 0.30, brightness: 0.65),
                                  Color(hue: 0.60, saturation: 0.25, brightness: 0.80)]
            case .bottom: return [Color(hue: 0.62, saturation: 0.40, brightness: 0.35),
                                  Color(hue: 0.60, saturation: 0.35, brightness: 0.50)]
            case .shoes:  return [Color(hue: 0.0, saturation: 0.0, brightness: 0.40),
                                  Color(hue: 0.0, saturation: 0.0, brightness: 0.55)]
            }
        }()

        return CarouselGarment(
            id: item.id,
            name: item.type.label,
            slot: slot,
            thermalIndex: item.thermalIndex,
            thumbnailImage: thumbnail,
            gradientColors: defaultGradient,
            icon: item.type.icon,
            isFromWardrobe: true
        )
    }

    /// Create from a SampleGarment
    static func fromSample(_ sample: SampleGarment) -> CarouselGarment {
        CarouselGarment(
            id: sample.id,
            name: sample.name,
            slot: sample.slot,
            thermalIndex: sample.thermalIndex,
            thumbnailImage: nil,
            gradientColors: sample.gradientColors,
            icon: sample.icon,
            isFromWardrobe: false
        )
    }

    var thermalLabel: String {
        switch thermalIndex {
        case ..<0.25:     return "Frío"
        case 0.25..<0.50: return "Templado"
        case 0.50..<0.75: return "Cálido"
        default:          return "Caluroso"
        }
    }

    func hash(into hasher: inout Hasher) { hasher.combine(id) }
    static func == (lhs: CarouselGarment, rhs: CarouselGarment) -> Bool { lhs.id == rhs.id }
}

// MARK: - Carousel Picker

struct CarouselPickerView: View {

    let slot: GarmentSlot
    let garments: [CarouselGarment]
    @Binding var selection: CarouselGarment?
    var onDelete: ((CarouselGarment) -> Void)? = nil  // ← callback for deleting wardrobe items

    // Internal animation state
    @Namespace private var selectionNamespace
    @State private var scrollPosition: CarouselGarment.ID?

    var body: some View {
        VStack(alignment: .leading, spacing: StyleSpacing.sm) {
            // Slot header
            slotHeader

            // Horizontal carousel
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: StyleSpacing.md) {
                    // "None" deselect card
                    noneCard

                    // Garment cards
                    ForEach(garments) { garment in
                        garmentCard(garment)
                    }
                }
                .scrollTargetLayout()
                .padding(.horizontal, StyleSpacing.lg)
            }
            .scrollTargetBehavior(.viewAligned)
            .scrollPosition(id: $scrollPosition)
            .frame(height: 130)
        }
    }

    // MARK: - Slot Header

    private var slotHeader: some View {
        HStack(spacing: StyleSpacing.sm) {
            Image(systemName: slot.icon)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(slot.accentColor)

            Text(slot.label)
                .font(StyleTypography.headline)
                .foregroundStyle(StyleColors.textPrimary)

            Spacer()

            if let selected = selection {
                Text(selected.name)
                    .font(StyleTypography.caption)
                    .foregroundStyle(StyleColors.textSecondary)
                    .transition(.opacity.combined(with: .scale(scale: 0.8)))
            }
        }
        .padding(.horizontal, StyleSpacing.lg)
        .animation(StyleAnimation.springSnappy, value: selection?.id)
    }

    // MARK: - None Card (Deselect)

    private var noneCard: some View {
        Button {
            withAnimation(StyleAnimation.springSnappy) {
                selection = nil
            }
        } label: {
            VStack(spacing: StyleSpacing.sm) {
                ZStack {
                    RoundedRectangle(cornerRadius: 14)
                        .fill(Color.white.opacity(0.04))
                        .frame(width: 80, height: 80)

                    Image(systemName: "xmark.circle")
                        .font(.system(size: 28, weight: .light))
                        .foregroundStyle(StyleColors.textTertiary)
                }

                Text("Ninguna")
                    .font(StyleTypography.caption)
                    .foregroundStyle(StyleColors.textTertiary)
            }
            .frame(width: 90)
            .padding(.vertical, StyleSpacing.xs)
            .overlay {
                if selection == nil {
                    RoundedRectangle(cornerRadius: 16)
                        .stroke(slot.accentColor.opacity(0.5), lineWidth: 2)
                        .padding(-4)
                }
            }
        }
        .buttonStyle(.plain)
        .id("none-\(slot.rawValue)")
    }

    // MARK: - Garment Card

    private func garmentCard(_ garment: CarouselGarment) -> some View {
        let isSelected = selection?.id == garment.id

        return Button {
            withAnimation(StyleAnimation.springSnappy) {
                selection = garment
            }
            let impact = UIImpactFeedbackGenerator(style: .light)
            impact.impactOccurred()
        } label: {
            VStack(spacing: StyleSpacing.sm) {
                // Garment thumbnail
                ZStack {
                    if let photo = garment.thumbnailImage {
                        // REAL photo from wardrobe
                        Image(uiImage: photo)
                            .resizable()
                            .scaledToFill()
                            .frame(width: 80, height: 80)
                            .clipShape(RoundedRectangle(cornerRadius: 14))
                            .shadow(
                                color: slot.accentColor.opacity(isSelected ? 0.4 : 0.1),
                                radius: isSelected ? 12 : 4,
                                y: isSelected ? 4 : 2
                            )
                    } else {
                        // Sample garment gradient fallback
                        RoundedRectangle(cornerRadius: 14)
                            .fill(
                                LinearGradient(
                                    colors: garment.gradientColors,
                                    startPoint: .topLeading,
                                    endPoint: .bottomTrailing
                                )
                            )
                            .frame(width: 80, height: 80)
                            .shadow(
                                color: garment.gradientColors.first?.opacity(0.3) ?? .clear,
                                radius: isSelected ? 12 : 4,
                                y: isSelected ? 4 : 2
                            )

                        Image(systemName: garment.icon)
                            .font(.system(size: 24, weight: .medium))
                            .foregroundStyle(.white.opacity(0.7))
                            .shadow(color: .black.opacity(0.3), radius: 2, y: 1)
                    }

                    // Thermal badge
                    VStack {
                        HStack {
                            Spacer()
                            Text(garment.thermalLabel)
                                .font(.system(size: 8, weight: .bold, design: .rounded))
                                .foregroundStyle(.white)
                                .padding(.horizontal, 5)
                                .padding(.vertical, 2)
                                .background(
                                    Capsule()
                                        .fill(thermalColor(for: garment.thermalIndex).opacity(0.85))
                                )
                        }
                        Spacer()
                    }
                    .frame(width: 80, height: 80)
                    .padding(4)

                    // Wardrobe badge
                    if garment.isFromWardrobe {
                        VStack {
                            Spacer()
                            HStack {
                                Image(systemName: "person.crop.square.filled.and.at.rectangle")
                                    .font(.system(size: 7))
                                    .foregroundStyle(.white)
                                    .padding(3)
                                    .background(StyleColors.accentMint.opacity(0.8), in: Circle())
                                Spacer()
                            }
                        }
                        .frame(width: 80, height: 80)
                        .padding(4)
                    }
                }

                // Name
                Text(garment.name)
                    .font(StyleTypography.caption)
                    .foregroundStyle(isSelected ? .white : StyleColors.textSecondary)
                    .lineLimit(1)
            }
            .frame(width: 90)
            .padding(.vertical, StyleSpacing.xs)
            .scaleEffect(isSelected ? 1.08 : 1.0)
            .overlay {
                if isSelected {
                    RoundedRectangle(cornerRadius: 16)
                        .stroke(
                            LinearGradient(
                                colors: [slot.accentColor, slot.accentColor.opacity(0.4)],
                                startPoint: .top,
                                endPoint: .bottom
                            ),
                            lineWidth: 2.5
                        )
                        .padding(-4)
                        .shadow(color: slot.accentColor.opacity(0.3), radius: 8)
                }
            }
            .animation(StyleAnimation.springSnappy, value: isSelected)
        }
        .buttonStyle(.plain)
        .contextMenu {
            if garment.isFromWardrobe, let onDelete {
                Button(role: .destructive) {
                    withAnimation(.spring(response: 0.3)) {
                        if selection?.id == garment.id { selection = nil }
                        onDelete(garment)
                    }
                } label: {
                    Label("Eliminar prenda", systemImage: "trash")
                }
            }
        }

    // MARK: - Helpers

    private func thermalColor(for index: Double) -> Color {
        switch index {
        case ..<0.25:     return .blue
        case 0.25..<0.50: return .green
        case 0.50..<0.75: return .orange
        default:          return .red
        }
    }
}

// MARK: - Preview

#Preview {
    ZStack {
        Color.black.ignoresSafeArea()

        VStack(spacing: 24) {
            CarouselPickerView(
                slot: .top,
                garments: SampleGarments.allTops.map { CarouselGarment.fromSample($0) },
                selection: .constant(nil)
            )

            CarouselPickerView(
                slot: .bottom,
                garments: SampleGarments.allBottoms.map { CarouselGarment.fromSample($0) },
                selection: .constant(nil)
            )

            CarouselPickerView(
                slot: .shoes,
                garments: SampleGarments.allShoes.map { CarouselGarment.fromSample($0) },
                selection: .constant(nil)
            )
        }
    }
}
