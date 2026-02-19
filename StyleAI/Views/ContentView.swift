// ContentView.swift
// StyleAI — Main Interface (Liquid Glass Design)
//
// Two-phase UI:
// 1. Setup Phase — model download/compile progress with animated visuals.
// 2. Ready Phase — premium hub with "Escanear" and "Mi Armario" action cards.
//
// Uses iOS 26 Liquid Glass materials, spring animations, and glassmorphism.

import SwiftUI

// MARK: - Content View

struct ContentView: View {

    @State private var modelManager = ModelManager.shared
    @State private var showDebugConsole = false
    @State private var logoTapCount = 0
    @State private var showIncompatibleAlert = false
    @State private var compatibilityResult: DeviceCompatibilityResult?

    var body: some View {
        NavigationStack {
            ZStack {
                // Animated background gradient
                backgroundGradient

                // Main content based on model state
                Group {
                    switch modelManager.state {
                    case .ready:
                        readyPhaseView
                            .transition(.opacity.combined(with: .scale(scale: 0.95)))
                    case .error(let message):
                        errorView(message: message)
                            .transition(.opacity)
                    default:
                        setupPhaseView
                            .transition(.opacity)
                    }
                }
                .animation(StyleAnimation.springSmooth, value: modelManager.state == .ready)
            }
            .debugConsoleOverlay(isPresented: $showDebugConsole)
        }
        .preferredColorScheme(.dark)
        .task {
            // Validate hardware first
            let result = DeviceChecker.validate()
            compatibilityResult = result

            if !result.isCompatible {
                showIncompatibleAlert = true
                DebugLogger.shared.log("⛔ Device incompatible: \(result.failureReasons.joined(separator: ", "))", level: .error)
            } else {
                DebugLogger.shared.log("✅ Device OK: \(result.chipName), \(String(format: "%.1f", result.ramGB)) GB RAM", level: .success)
                await modelManager.bootstrapIfNeeded()
            }
        }
        .alert("Dispositivo No Compatible", isPresented: $showIncompatibleAlert) {
            Button("Continuar Igual") {
                Task { await modelManager.bootstrapIfNeeded() }
            }
            Button("Cerrar", role: .cancel) {}
        } message: {
            Text(compatibilityResult?.failureReasons.joined(separator: "\n") ?? "Hardware insuficiente.")
        }
    }

    // MARK: - Background

    private var backgroundGradient: some View {
        ZStack {
            // Base dark gradient
            LinearGradient(
                colors: [
                    StyleColors.surfacePrimary,
                    Color(hue: 0.75, saturation: 0.20, brightness: 0.08)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            .ignoresSafeArea()

            // Animated floating orbs for depth
            floatingOrbs
        }
    }

    private var floatingOrbs: some View {
        GeometryReader { geo in
            Circle()
                .fill(StyleColors.primaryMid.opacity(0.15))
                .frame(width: 300, height: 300)
                .blur(radius: 80)
                .offset(x: geo.size.width * 0.3, y: geo.size.height * 0.1)

            Circle()
                .fill(StyleColors.accentRose.opacity(0.10))
                .frame(width: 250, height: 250)
                .blur(radius: 70)
                .offset(x: -geo.size.width * 0.2, y: geo.size.height * 0.6)

            Circle()
                .fill(StyleColors.accentMint.opacity(0.08))
                .frame(width: 200, height: 200)
                .blur(radius: 60)
                .offset(x: geo.size.width * 0.5, y: geo.size.height * 0.8)
        }
    }

    // MARK: - Setup Phase

    private var setupPhaseView: some View {
        VStack(spacing: StyleSpacing.xxl) {
            Spacer()

            // App logo with hidden debug gesture
            appLogo

            // Status text
            VStack(spacing: StyleSpacing.sm) {
                Text("Preparando Motor IA")
                    .font(StyleTypography.title2)
                    .foregroundStyle(StyleColors.textPrimary)

                Text(modelManager.state.displayText)
                    .font(StyleTypography.subheadline)
                    .foregroundStyle(StyleColors.textSecondary)
                    .animation(.easeInOut, value: modelManager.state.displayText)
            }

            // Progress ring
            progressRing

            // Model detail cards
            modelStatusCards

            Spacer()

            // Storage info
            storageInfoFooter
        }
        .padding(.horizontal, StyleSpacing.xl)
    }

    private var appLogo: some View {
        VStack(spacing: StyleSpacing.md) {
            ZStack {
                // Glow effect
                Circle()
                    .fill(StyleColors.brandGradient)
                    .frame(width: 100, height: 100)
                    .blur(radius: 25)
                    .opacity(0.5)

                // Icon
                Image(systemName: "wand.and.stars")
                    .font(.system(size: 44, weight: .light))
                    .foregroundStyle(
                        LinearGradient(
                            colors: [.white, StyleColors.accentRose],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .frame(width: 90, height: 90)
                    .glassCard(cornerRadius: 24)
            }
            .onTapGesture {
                logoTapCount += 1
                if logoTapCount >= 5 {
                    logoTapCount = 0
                    withAnimation(StyleAnimation.springSmooth) {
                        showDebugConsole.toggle()
                    }
                    DebugLogger.shared.log("🐛 Debug console toggled via hidden tap gesture", level: .info)
                }
                // Reset tap counter after 2 seconds of inactivity
                Task {
                    try? await Task.sleep(for: .seconds(2))
                    logoTapCount = 0
                }
            }

            Text("Style AI")
                .font(StyleTypography.largeTitle)
                .foregroundStyle(
                    LinearGradient(
                        colors: [.white, StyleColors.accentRose],
                        startPoint: .leading,
                        endPoint: .trailing
                    )
                )
        }
    }

    private var progressRing: some View {
        ZStack {
            // Background track
            Circle()
                .stroke(Color.white.opacity(0.08), lineWidth: 6)
                .frame(width: 120, height: 120)

            // Progress arc
            Circle()
                .trim(from: 0, to: modelManager.overallProgress)
                .stroke(
                    StyleColors.brandGradient,
                    style: StrokeStyle(lineWidth: 6, lineCap: .round)
                )
                .frame(width: 120, height: 120)
                .rotationEffect(.degrees(-90))
                .animation(.easeInOut(duration: 0.3), value: modelManager.overallProgress)

            // Percentage text
            VStack(spacing: 2) {
                Text("\(Int(modelManager.overallProgress * 100))%")
                    .font(StyleTypography.title2)
                    .foregroundStyle(.white)
                    .contentTransition(.numericText())

                Text("RAM: \(modelManager.availableMemoryMB) MB")
                    .font(StyleTypography.captionMono)
                    .foregroundStyle(StyleColors.textTertiary)
            }
        }
    }

    private var modelStatusCards: some View {
        VStack(spacing: StyleSpacing.sm) {
            ForEach(ModelDescriptor.allModels, id: \.name) { model in
                if let modelState = modelManager.modelStates[model.name] {
                    HStack {
                        // Status indicator
                        Circle()
                            .fill(statusColor(for: modelState))
                            .frame(width: 8, height: 8)

                        Text(model.name)
                            .font(StyleTypography.footnote)
                            .foregroundStyle(StyleColors.textSecondary)

                        Spacer()

                        Text(statusLabel(for: modelState))
                            .font(StyleTypography.captionMono)
                            .foregroundStyle(StyleColors.textTertiary)

                        Text("\(model.expectedSizeMB) MB")
                            .font(StyleTypography.captionMono)
                            .foregroundStyle(StyleColors.textTertiary)
                    }
                    .padding(.horizontal, StyleSpacing.md)
                    .padding(.vertical, StyleSpacing.sm)
                    .glassCard(cornerRadius: 10)
                }
            }
        }
    }

    private var storageInfoFooter: some View {
        HStack(spacing: StyleSpacing.sm) {
            Image(systemName: "internaldrive")
                .font(.system(size: 12))
            Text("Los modelos se almacenan localmente (~3.1 GB)")
                .font(StyleTypography.caption)
        }
        .foregroundStyle(StyleColors.textTertiary)
        .padding(.bottom, StyleSpacing.xl)
    }

    // MARK: - Ready Phase

    private var readyPhaseView: some View {
        VStack(spacing: StyleSpacing.xxl) {
            // Header
            VStack(spacing: StyleSpacing.xs) {
                Text("Style AI")
                    .font(StyleTypography.largeTitle)
                    .foregroundStyle(.white)
                    .onTapGesture(count: 5) {
                        withAnimation(StyleAnimation.springSmooth) {
                            showDebugConsole.toggle()
                        }
                    }

                Text("Tu estilista personal con IA")
                    .font(StyleTypography.subheadline)
                    .foregroundStyle(StyleColors.textSecondary)
            }
            .padding(.top, StyleSpacing.xxxl)

            Spacer()

            // Action cards
            VStack(spacing: StyleSpacing.lg) {
                actionCard(
                    icon: "camera.viewfinder",
                    title: "Escanear Armario",
                    subtitle: "Fotografía y cataloga tus prendas con IA",
                    gradient: LinearGradient(
                        colors: [StyleColors.primaryMid, StyleColors.primaryLight],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                ) {
                    DebugLogger.shared.log("📸 User tapped: Escanear Armario", level: .info)
                    // TODO: Navigate to scanner view
                }

                actionCard(
                    icon: "tshirt.fill",
                    title: "Mi Armario",
                    subtitle: "Explora y combina tu colección virtual",
                    gradient: LinearGradient(
                        colors: [StyleColors.accentRose, StyleColors.accentGold],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                ) {
                    DebugLogger.shared.log("👔 User tapped: Mi Armario", level: .info)
                    // TODO: Navigate to wardrobe view
                }

                actionCard(
                    icon: "cloud.sun.fill",
                    title: "Estilista Meteorológico",
                    subtitle: "Outfits inteligentes basados en el clima",
                    gradient: LinearGradient(
                        colors: [StyleColors.accentMint, StyleColors.info],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                ) {
                    DebugLogger.shared.log("🌤 User tapped: Estilista Meteorológico", level: .info)
                    // TODO: Navigate to weather stylist view
                }
            }
            .padding(.horizontal, StyleSpacing.lg)

            Spacer()

            // Quick stats bar
            quickStatsBar
        }
    }

    private func actionCard(
        icon: String,
        title: String,
        subtitle: String,
        gradient: LinearGradient,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: StyleSpacing.lg) {
                // Icon circle
                ZStack {
                    Circle()
                        .fill(gradient.opacity(0.3))
                        .frame(width: 56, height: 56)

                    Image(systemName: icon)
                        .font(.system(size: 24, weight: .medium))
                        .foregroundStyle(.white)
                }

                // Text
                VStack(alignment: .leading, spacing: StyleSpacing.xxs) {
                    Text(title)
                        .font(StyleTypography.headline)
                        .foregroundStyle(.white)

                    Text(subtitle)
                        .font(StyleTypography.footnote)
                        .foregroundStyle(StyleColors.textSecondary)
                        .lineLimit(2)
                }

                Spacer()

                Image(systemName: "chevron.right")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(StyleColors.textTertiary)
            }
            .padding(StyleSpacing.lg)
            .glassCard()
        }
        .buttonStyle(.plain)
    }

    private var quickStatsBar: some View {
        HStack(spacing: StyleSpacing.xl) {
            statPill(icon: "cpu", label: "Neural Engine", value: "Active")
            statPill(icon: "memorychip", label: "RAM", value: "\(modelManager.availableMemoryMB) MB")
        }
        .padding(.horizontal, StyleSpacing.lg)
        .padding(.bottom, StyleSpacing.xl)
    }

    private func statPill(icon: String, label: String, value: String) -> some View {
        HStack(spacing: StyleSpacing.sm) {
            Image(systemName: icon)
                .font(.system(size: 11))

            VStack(alignment: .leading, spacing: 0) {
                Text(label)
                    .font(StyleTypography.captionMono)
                    .foregroundStyle(StyleColors.textTertiary)
                Text(value)
                    .font(StyleTypography.caption)
                    .foregroundStyle(StyleColors.textSecondary)
            }
        }
        .padding(.horizontal, StyleSpacing.md)
        .padding(.vertical, StyleSpacing.sm)
        .glassCard(cornerRadius: StyleSpacing.pillCornerRadius)
    }

    // MARK: - Error View

    private func errorView(message: String) -> some View {
        VStack(spacing: StyleSpacing.xl) {
            Spacer()

            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 48))
                .foregroundStyle(StyleColors.warning)

            Text("Error del Motor IA")
                .font(StyleTypography.title2)
                .foregroundStyle(.white)

            Text(message)
                .font(StyleTypography.body)
                .foregroundStyle(StyleColors.textSecondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, StyleSpacing.xxl)

            Button {
                Task { await modelManager.resetAndRedownload() }
            } label: {
                Label("Reintentar Descarga", systemImage: "arrow.clockwise")
            }
            .buttonStyle(PremiumButtonStyle())

            Spacer()
        }
    }

    // MARK: - Helpers

    private func statusColor(for state: ModelEngineState) -> Color {
        switch state {
        case .ready:        return .green
        case .error:        return .red
        case .downloading:  return .blue
        case .compiling:    return .orange
        default:            return .gray
        }
    }

    private func statusLabel(for state: ModelEngineState) -> String {
        switch state {
        case .ready:                    return "Listo"
        case .error:                    return "Error"
        case .downloading(let p):       return "\(Int(p * 100))%"
        case .compiling:                return "Compilando..."
        case .checking:                 return "Verificando..."
        default:                        return "Pendiente"
        }
    }
}

// MARK: - Preview

#Preview {
    ContentView()
}
