// DesignTokens.swift
// StyleAI — Design System
//
// Centralized design tokens for the Style AI premium aesthetic.
// All UI components reference these tokens for consistency.

import SwiftUI

// MARK: - Color Palette

/// Premium color palette inspired by high-fashion editorials.
/// Deep purples, rose golds, and frosted whites for a luxury feel.
enum StyleColors {

    // Primary brand gradient
    static let primaryDark   = Color(hue: 0.76, saturation: 0.65, brightness: 0.35)  // Deep Indigo
    static let primaryMid    = Color(hue: 0.76, saturation: 0.55, brightness: 0.55)  // Rich Purple
    static let primaryLight  = Color(hue: 0.78, saturation: 0.40, brightness: 0.75)  // Soft Lavender

    // Accent tones
    static let accentRose    = Color(hue: 0.93, saturation: 0.45, brightness: 0.90)  // Rose Gold
    static let accentGold    = Color(hue: 0.10, saturation: 0.50, brightness: 0.95)  // Warm Gold
    static let accentMint    = Color(hue: 0.45, saturation: 0.35, brightness: 0.85)  // Fresh Mint
    static let brandPink     = Color(hue: 0.90, saturation: 0.55, brightness: 0.85)  // Brand Pink

    // Semantic
    static let success       = Color(hue: 0.38, saturation: 0.60, brightness: 0.70)
    static let warning       = Color(hue: 0.10, saturation: 0.70, brightness: 0.90)
    static let error         = Color(hue: 0.00, saturation: 0.65, brightness: 0.80)
    static let info          = Color(hue: 0.58, saturation: 0.50, brightness: 0.80)

    // Surfaces (dark mode first)
    static let surfacePrimary   = Color(hue: 0.72, saturation: 0.15, brightness: 0.10) // Near-black
    static let surfaceSecondary = Color(hue: 0.72, saturation: 0.12, brightness: 0.15)
    static let surfaceElevated  = Color(hue: 0.72, saturation: 0.10, brightness: 0.20)
    static let surfaceGlass     = Color.white.opacity(0.08)

    // Text
    static let textPrimary   = Color.white.opacity(0.95)
    static let textSecondary = Color.white.opacity(0.60)
    static let textTertiary  = Color.white.opacity(0.35)

    // Gradients
    static let brandGradient = LinearGradient(
        colors: [primaryDark, primaryMid, accentRose],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
    )

    static let cardGradient = LinearGradient(
        colors: [surfaceGlass, Color.white.opacity(0.03)],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
    )

    static let shimmerGradient = LinearGradient(
        colors: [
            Color.white.opacity(0.0),
            Color.white.opacity(0.15),
            Color.white.opacity(0.0)
        ],
        startPoint: .leading,
        endPoint: .trailing
    )
}

// MARK: - Typography

/// SF Pro Rounded typography scale.
/// Uses Dynamic Type for accessibility while maintaining premium aesthetics.
enum StyleTypography {
    static let largeTitle  = Font.system(size: 34, weight: .bold, design: .rounded)
    static let title       = Font.system(size: 28, weight: .bold, design: .rounded)
    static let title2      = Font.system(size: 22, weight: .semibold, design: .rounded)
    static let title3      = Font.system(size: 20, weight: .semibold, design: .rounded)
    static let headline    = Font.system(size: 17, weight: .semibold, design: .rounded)
    static let body        = Font.system(size: 17, weight: .regular, design: .rounded)
    static let callout     = Font.system(size: 16, weight: .regular, design: .rounded)
    static let subheadline = Font.system(size: 15, weight: .regular, design: .rounded)
    static let footnote    = Font.system(size: 13, weight: .regular, design: .rounded)
    static let caption     = Font.system(size: 12, weight: .medium, design: .rounded)
    static let captionMono = Font.system(size: 11, weight: .regular, design: .monospaced)
}

// MARK: - Spacing & Layout

enum StyleSpacing {
    static let xxs: CGFloat = 2
    static let xs:  CGFloat = 4
    static let sm:  CGFloat = 8
    static let md:  CGFloat = 12
    static let lg:  CGFloat = 16
    static let xl:  CGFloat = 24
    static let xxl: CGFloat = 32
    static let xxxl: CGFloat = 48

    static let cardCornerRadius: CGFloat = 20
    static let buttonCornerRadius: CGFloat = 14
    static let pillCornerRadius: CGFloat = 50
    static let iconSize: CGFloat = 24
    static let avatarSize: CGFloat = 48
}

// MARK: - Animation Curves

enum StyleAnimation {
    static let springSnappy  = Animation.spring(response: 0.35, dampingFraction: 0.75)
    static let springSmooth  = Animation.spring(response: 0.55, dampingFraction: 0.85)
    static let springBouncy  = Animation.spring(response: 0.45, dampingFraction: 0.60)
    static let fadeIn        = Animation.easeOut(duration: 0.25)
    static let fadeInSlow    = Animation.easeOut(duration: 0.6)
    static let pulse         = Animation.easeInOut(duration: 1.2).repeatForever(autoreverses: true)
}

// MARK: - View Modifiers

/// Glassmorphism card modifier — frosted translucent surface.
struct GlassCard: ViewModifier {
    var cornerRadius: CGFloat = StyleSpacing.cardCornerRadius

    func body(content: Content) -> some View {
        content
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: cornerRadius))
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius)
                    .stroke(Color.white.opacity(0.12), lineWidth: 0.5)
            )
            .shadow(color: .black.opacity(0.25), radius: 12, y: 6)
    }
}

/// Shimmer loading effect modifier.
struct ShimmerEffect: ViewModifier {
    @State private var phase: CGFloat = 0

    func body(content: Content) -> some View {
        content
            .overlay(
                StyleColors.shimmerGradient
                    .offset(x: phase)
                    .mask(content)
            )
            .onAppear {
                withAnimation(.linear(duration: 1.5).repeatForever(autoreverses: false)) {
                    phase = 400
                }
            }
    }
}

/// Premium button style with gradient background and haptic feedback.
struct PremiumButtonStyle: ButtonStyle {
    var gradient: LinearGradient = StyleColors.brandGradient

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(StyleTypography.headline)
            .foregroundStyle(.white)
            .padding(.horizontal, StyleSpacing.xl)
            .padding(.vertical, StyleSpacing.md)
            .background(gradient, in: Capsule())
            .scaleEffect(configuration.isPressed ? 0.96 : 1.0)
            .opacity(configuration.isPressed ? 0.9 : 1.0)
            .shadow(
                color: StyleColors.primaryMid.opacity(0.4),
                radius: configuration.isPressed ? 4 : 10,
                y: configuration.isPressed ? 2 : 5
            )
            .animation(StyleAnimation.springSnappy, value: configuration.isPressed)
    }
}

// MARK: - View Extensions

@MainActor
extension View {
    /// Apply glassmorphism card styling.
    func glassCard(cornerRadius: CGFloat = StyleSpacing.cardCornerRadius) -> some View {
        modifier(GlassCard(cornerRadius: cornerRadius))
    }

    /// Apply shimmer loading animation.
    func shimmer() -> some View {
        modifier(ShimmerEffect())
    }
}

// MARK: - Color Hex Utilities

extension Color {
    /// Creates a Color from a hex string (e.g. "#FF5733" or "FF5733").
    init(hex: String) {
        let hex = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        var int: UInt64 = 0
        Scanner(string: hex).scanHexInt64(&int)
        let r, g, b: Double
        switch hex.count {
        case 6:
            r = Double((int >> 16) & 0xFF) / 255.0
            g = Double((int >> 8) & 0xFF) / 255.0
            b = Double(int & 0xFF) / 255.0
        default:
            r = 1; g = 1; b = 1
        }
        self.init(red: r, green: g, blue: b)
    }
}

extension UIColor {
    /// Returns the hex string representation (e.g. "#FF5733").
    var hexString: String {
        var r: CGFloat = 0
        var g: CGFloat = 0
        var b: CGFloat = 0
        getRed(&r, green: &g, blue: &b, alpha: nil)
        return String(format: "#%02X%02X%02X",
                      Int(r * 255), Int(g * 255), Int(b * 255))
    }
}
