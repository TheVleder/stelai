// SettingsView.swift
// StyleAI — Settings & Model Status
//
// Shows AI engine status, model download controls, and app information.
// Allows users to monitor and trigger Stable Diffusion model downloads.

import SwiftUI

// MARK: - Settings View

struct SettingsView: View {

    @State private var modelManager = ModelManager.shared
    @State private var sdService = StableDiffusionService.shared

    var body: some View {
        ZStack {
            // Background
            LinearGradient(
                colors: [
                    StyleColors.surfacePrimary,
                    Color(hue: 0.76, saturation: 0.18, brightness: 0.06)
                ],
                startPoint: .top,
                endPoint: .bottom
            )
            .ignoresSafeArea()

            ScrollView {
                VStack(spacing: StyleSpacing.xl) {

                    // MARK: - Vision AI Status
                    sectionHeader("Vision AI", icon: "eye.fill")

                    visionAICard

                    // MARK: - Stable Diffusion Status
                    sectionHeader("Modelo Stable Diffusion", icon: "wand.and.stars")

                    sdModelCard

                    // MARK: - Device Info
                    sectionHeader("Dispositivo", icon: "iphone")

                    deviceInfoCard

                    // MARK: - About
                    sectionHeader("Acerca de", icon: "info.circle.fill")

                    aboutCard
                }
                .padding(StyleSpacing.lg)
            }
        }
        .navigationTitle("Ajustes")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(.ultraThinMaterial, for: .navigationBar)
    }

    // MARK: - Section Header

    private func sectionHeader(_ title: String, icon: String) -> some View {
        HStack(spacing: StyleSpacing.sm) {
            Image(systemName: icon)
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(StyleColors.accentMint)

            Text(title)
                .font(StyleTypography.headline)
                .foregroundStyle(.white)

            Spacer()
        }
        .padding(.top, StyleSpacing.md)
    }

    // MARK: - Vision AI Card

    private var visionAICard: some View {
        VStack(spacing: StyleSpacing.md) {
            statusRow(
                label: "Segmentación de Personas",
                status: modelManager.state == .ready ? "Activo" : "Cargando...",
                isReady: modelManager.state == .ready
            )

            statusRow(
                label: "Clasificación de Imágenes",
                status: modelManager.state == .ready ? "Activo" : "Cargando...",
                isReady: modelManager.state == .ready
            )

            statusRow(
                label: "Extracción de Colores",
                status: modelManager.state == .ready ? "Activo" : "Cargando...",
                isReady: modelManager.state == .ready
            )

            HStack {
                Image(systemName: "checkmark.seal.fill")
                    .font(.system(size: 12))
                    .foregroundStyle(StyleColors.accentMint)

                Text("Integrado en iOS — sin descargas necesarias")
                    .font(StyleTypography.caption)
                    .foregroundStyle(StyleColors.textTertiary)
            }
            .padding(.top, StyleSpacing.xs)
        }
        .padding(StyleSpacing.lg)
        .glassCard()
    }

    // MARK: - SD Model Card

    private var sdModelCard: some View {
        VStack(spacing: StyleSpacing.md) {
            // State indicator
            HStack {
                sdStateIcon

                VStack(alignment: .leading, spacing: 2) {
                    Text("Virtual Try-On (IA Generativa)")
                        .font(StyleTypography.subheadline)
                        .foregroundStyle(.white)

                    Text(sdStateDescription)
                        .font(StyleTypography.caption)
                        .foregroundStyle(StyleColors.textSecondary)
                }

                Spacer()
            }

            // Progress bar (if downloading)
            if sdService.state.isDownloading {
                VStack(spacing: StyleSpacing.xs) {
                    ProgressView(value: sdService.downloadProgress)
                        .tint(StyleColors.primaryMid)

                    HStack {
                        Text("\(Int(sdService.downloadProgress * 100))%")
                            .font(StyleTypography.captionMono)
                            .foregroundStyle(StyleColors.textSecondary)

                        Spacer()

                        if sdService.downloadSpeedMBps > 0 {
                            Text(String(format: "%.1f MB/s", sdService.downloadSpeedMBps))
                                .font(StyleTypography.captionMono)
                                .foregroundStyle(StyleColors.accentMint)
                        }
                    }

                    if sdService.downloadFileTotal > 0 {
                        HStack {
                            Text("Archivo \(sdService.downloadFileIndex)/\(sdService.downloadFileTotal)")
                                .font(StyleTypography.captionMono)
                                .foregroundStyle(StyleColors.textTertiary)

                            Spacer()

                            Text(String(format: "%.1f/%.0f MB", sdService.downloadedMB, sdService.currentFileTotalMB))
                                .font(StyleTypography.captionMono)
                                .foregroundStyle(StyleColors.textTertiary)
                        }
                    }
                }
            }

            // Generation progress
            if case .generating(let progress) = sdService.state {
                VStack(spacing: StyleSpacing.xs) {
                    ProgressView(value: progress)
                        .tint(StyleColors.accentRose)

                    Text("Generando imagen: \(Int(progress * 100))%")
                        .font(StyleTypography.captionMono)
                        .foregroundStyle(StyleColors.textSecondary)
                }
            }

            // Action buttons
            HStack(spacing: StyleSpacing.md) {
                if !sdService.state.isReady && !sdService.state.isDownloading {
                    Button {
                        Task { await ModelManager.shared.downloadSDModel() }
                    } label: {
                        Label("Descargar Modelo", systemImage: "arrow.down.circle.fill")
                            .font(StyleTypography.subheadline)
                    }
                    .buttonStyle(PremiumButtonStyle())
                }

                if sdService.state.isReady {
                    HStack(spacing: StyleSpacing.sm) {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                        Text("Modelo listo para generar")
                            .font(StyleTypography.subheadline)
                            .foregroundStyle(StyleColors.accentMint)
                    }
                }
            }
            .padding(.top, StyleSpacing.xs)

            // Info note
            HStack(alignment: .top, spacing: StyleSpacing.sm) {
                Image(systemName: "info.circle")
                    .font(.system(size: 12))
                    .foregroundStyle(StyleColors.info)
                    .padding(.top, 2)

                Text("El modelo de IA generativa (~2 GB) es opcional. El modo rápido (Vista Previa) funciona sin descargarlo.")
                    .font(StyleTypography.caption)
                    .foregroundStyle(StyleColors.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(StyleSpacing.lg)
        .glassCard()
    }

    // MARK: - Device Info Card

    private var deviceInfoCard: some View {
        VStack(spacing: StyleSpacing.md) {
            let result = DeviceChecker.validate()

            infoRow(label: "Chip", value: result.chipName)
            infoRow(label: "RAM Total", value: String(format: "%.1f GB", result.ramGB))
            infoRow(label: "RAM Libre", value: "\(modelManager.availableMemoryMB) MB")
            infoRow(label: "Compatible", value: result.isCompatible ? "✅ Sí" : "⚠️ Limitado")
        }
        .padding(StyleSpacing.lg)
        .glassCard()
    }

    // MARK: - About Card

    private var aboutCard: some View {
        VStack(spacing: StyleSpacing.md) {
            infoRow(label: "Versión", value: "1.0.0 Beta")
            infoRow(label: "Motor IA", value: "Vision + Stable Diffusion")
            infoRow(label: "Procesamiento", value: "100% on-device")
            infoRow(label: "Privacidad", value: "Ningún dato sale del iPhone")
        }
        .padding(StyleSpacing.lg)
        .glassCard()
    }

    // MARK: - Helpers

    private func statusRow(label: String, status: String, isReady: Bool) -> some View {
        HStack {
            Circle()
                .fill(isReady ? Color.green : Color.orange)
                .frame(width: 8, height: 8)

            Text(label)
                .font(StyleTypography.footnote)
                .foregroundStyle(StyleColors.textSecondary)

            Spacer()

            Text(status)
                .font(StyleTypography.captionMono)
                .foregroundStyle(isReady ? StyleColors.accentMint : StyleColors.textTertiary)
        }
    }

    private func infoRow(label: String, value: String) -> some View {
        HStack {
            Text(label)
                .font(StyleTypography.footnote)
                .foregroundStyle(StyleColors.textSecondary)

            Spacer()

            Text(value)
                .font(StyleTypography.footnote)
                .foregroundStyle(.white)
        }
    }

    private var sdStateIcon: some View {
        Group {
            switch sdService.state {
            case .notDownloaded:
                Image(systemName: "arrow.down.circle")
                    .foregroundStyle(StyleColors.textTertiary)
            case .downloading:
                ProgressView()
                    .tint(StyleColors.primaryMid)
            case .extracting:
                ProgressView()
                    .tint(.orange)
            case .loading:
                ProgressView()
                    .tint(.orange)
            case .ready:
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            case .generating:
                Image(systemName: "sparkles")
                    .foregroundStyle(StyleColors.accentRose)
                    .symbolEffect(.pulse)
            case .error:
                Image(systemName: "exclamationmark.circle.fill")
                    .foregroundStyle(.red)
            }
        }
        .font(.system(size: 24))
        .frame(width: 40)
    }

    private var sdStateDescription: String {
        switch sdService.state {
        case .notDownloaded: return "No descargado — toca para descargar"
        case .downloading:  return "Descargando modelo..."
        case .extracting:   return "Extrayendo archivos..."
        case .loading:      return "Cargando pipeline..."
        case .ready:       return "Listo para generar looks con IA"
        case .generating:   return "Generando imagen..."
        case .error(let msg):  return "Error: \(msg)"
        }
    }
}

// MARK: - Preview

#Preview {
    NavigationStack {
        SettingsView()
    }
    .preferredColorScheme(.dark)
}
