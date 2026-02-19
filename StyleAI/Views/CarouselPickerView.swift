// CarouselPickerView.swift
// StyleAI — Horizontal Garment Carousel
//
// Reusable snap-scrolling carousel for selecting garments within a slot.
// Shows garment cards with gradient thumbnails, name, and thermal badge.
// Selected item scales up with a glowing border.

import SwiftUI

// MARK: - Carousel Picker

/// A horizontal snap carousel for choosing a garment from a specific slot.
///
/// Usage:
/// ```swift
/// CarouselPickerView(
///     slot: .top,
///     garments: SampleGarments.allTops,
///     selection: $selectedTop
/// )
/// ```
struct CarouselPickerView: View {

    let slot: GarmentSlot
    let garments: [SampleGarment]
    @Binding var selection: SampleGarment?

    // Internal animation state
    @Namespace private var selectionNamespace
    @State private var scrollPosition: SampleGarment.ID?

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

    private func garmentCard(_ garment: SampleGarment) -> some View {
        let isSelected = selection?.id == garment.id

        return Button {
            withAnimation(StyleAnimation.springSnappy) {
                selection = garment
            }
            // Haptic feedback
            let impact = UIImpactFeedbackGenerator(style: .light)
            impact.impactOccurred()
        } label: {
            VStack(spacing: StyleSpacing.sm) {
                // Garment thumbnail
                ZStack {
                    // Gradient representation of the garment
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

                    // Garment icon overlay
                    Image(systemName: garment.icon)
                        .font(.system(size: 24, weight: .medium))
                        .foregroundStyle(.white.opacity(0.7))
                        .shadow(color: .black.opacity(0.3), radius: 2, y: 1)

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
                garments: SampleGarments.allTops,
                selection: .constant(SampleGarments.whiteTee)
            )

            CarouselPickerView(
                slot: .bottom,
                garments: SampleGarments.allBottoms,
                selection: .constant(nil)
            )

            CarouselPickerView(
                slot: .shoes,
                garments: SampleGarments.allShoes,
                selection: .constant(SampleGarments.whiteSneakers)
            )
        }
    }
}
