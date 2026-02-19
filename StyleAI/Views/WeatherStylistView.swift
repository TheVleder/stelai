// WeatherStylistView.swift
// StyleAI — Weather-Based Outfit Stylist
//
// Fetches real weather data and recommends outfits based on
// thermal compatibility. Shows weather card + outfit suggestions.

import SwiftUI

// MARK: - Weather Stylist View

struct WeatherStylistView: View {

    @State private var weatherService = WeatherService.shared
    @State private var recommendations: [OutfitRecommendation] = []
    @State private var selectedRecommendation: OutfitRecommendation?
    @State private var hasLoaded = false
    @State private var animateWeather = false

    var body: some View {
        ZStack {
            // Dynamic background based on weather
            weatherBackground
                .ignoresSafeArea()

            ScrollView {
                VStack(spacing: StyleSpacing.xl) {
                    if weatherService.isLoading {
                        loadingView
                    } else if let error = weatherService.errorMessage {
                        errorView(message: error)
                    } else if let weather = weatherService.currentWeather {
                        // Weather card
                        weatherCard(weather)

                        // Match score
                        if let best = recommendations.first {
                            matchScoreBar(score: best.matchScore)
                        }

                        // Recommendations
                        recommendationsList

                        // Explanation
                        if let best = recommendations.first {
                            explanationCard(best.explanation)
                        }
                    } else {
                        emptyState
                    }
                }
                .padding(.horizontal, StyleSpacing.lg)
                .padding(.vertical, StyleSpacing.xl)
            }
        }
        .navigationTitle("Estilista Meteorológico")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(.ultraThinMaterial, for: .navigationBar)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    Task { await fetchWeather() }
                } label: {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 16))
                        .foregroundStyle(.white)
                }
            }
        }
        .task {
            if !hasLoaded {
                await fetchWeather()
                hasLoaded = true
            }
        }
    }

    // MARK: - Background

    private var weatherBackground: some View {
        let colors: [Color] = {
            guard let weather = weatherService.currentWeather else {
                return [StyleColors.surfacePrimary, Color(hue: 0.60, saturation: 0.15, brightness: 0.08)]
            }
            if !weather.isDay {
                return [Color(hue: 0.70, saturation: 0.30, brightness: 0.10), Color(hue: 0.75, saturation: 0.20, brightness: 0.05)]
            }
            switch weather.weatherCode {
            case 0, 1:
                return [Color(hue: 0.55, saturation: 0.40, brightness: 0.20), Color(hue: 0.58, saturation: 0.25, brightness: 0.10)]
            case 2, 3:
                return [Color(hue: 0.60, saturation: 0.15, brightness: 0.15), Color(hue: 0.62, saturation: 0.12, brightness: 0.08)]
            case 61...82:
                return [Color(hue: 0.58, saturation: 0.30, brightness: 0.12), Color(hue: 0.60, saturation: 0.25, brightness: 0.06)]
            default:
                return [StyleColors.surfacePrimary, Color(hue: 0.60, saturation: 0.15, brightness: 0.08)]
            }
        }()

        return LinearGradient(colors: colors, startPoint: .topLeading, endPoint: .bottomTrailing)
    }

    // MARK: - Loading

    private var loadingView: some View {
        VStack(spacing: StyleSpacing.xl) {
            Spacer().frame(height: 80)

            ZStack {
                Circle()
                    .fill(StyleColors.info.opacity(0.15))
                    .frame(width: 120, height: 120)
                    .blur(radius: 30)

                Image(systemName: "cloud.sun.fill")
                    .font(.system(size: 48))
                    .foregroundStyle(StyleColors.accentGold)
                    .symbolEffect(.pulse)
            }

            Text("Consultando el clima...")
                .font(StyleTypography.title2)
                .foregroundStyle(.white)

            ProgressView()
                .tint(.white)
        }
    }

    // MARK: - Weather Card

    private func weatherCard(_ weather: WeatherData) -> some View {
        VStack(spacing: StyleSpacing.lg) {
            // Location
            HStack(spacing: StyleSpacing.xs) {
                Image(systemName: "location.fill")
                    .font(.system(size: 12))
                Text(weather.locationName)
                    .font(StyleTypography.subheadline)
            }
            .foregroundStyle(StyleColors.textSecondary)

            // Main weather display
            HStack(spacing: StyleSpacing.xxl) {
                // Icon
                Image(systemName: weather.symbolName)
                    .font(.system(size: 56))
                    .foregroundStyle(weatherIconGradient(for: weather))
                    .symbolEffect(.breathe, options: .repeating)

                // Temperature
                VStack(alignment: .leading, spacing: StyleSpacing.xxs) {
                    Text("\(Int(weather.temperature))°")
                        .font(.system(size: 52, weight: .thin, design: .rounded))
                        .foregroundStyle(.white)

                    Text(weather.condition)
                        .font(StyleTypography.headline)
                        .foregroundStyle(StyleColors.textSecondary)
                }
            }

            // Detail row
            HStack(spacing: StyleSpacing.xxl) {
                weatherDetailChip(icon: "thermometer.medium", label: "Sensación", value: "\(Int(weather.apparentTemperature))°C")
                weatherDetailChip(icon: "wind", label: "Viento", value: "\(Int(weather.windSpeed)) km/h")
                weatherDetailChip(icon: "humidity.fill", label: "Humedad", value: "\(weather.humidity)%")
            }
        }
        .padding(StyleSpacing.xl)
        .glassCard()
    }

    private func weatherDetailChip(icon: String, label: String, value: String) -> some View {
        VStack(spacing: StyleSpacing.xxs) {
            Image(systemName: icon)
                .font(.system(size: 14))
                .foregroundStyle(StyleColors.textTertiary)
            Text(value)
                .font(StyleTypography.caption)
                .foregroundStyle(.white)
            Text(label)
                .font(.system(size: 9, weight: .regular, design: .rounded))
                .foregroundStyle(StyleColors.textTertiary)
        }
    }

    private func weatherIconGradient(for weather: WeatherData) -> LinearGradient {
        let colors: [Color]
        switch weather.weatherCode {
        case 0, 1:   colors = [.yellow, .orange]
        case 2, 3:   colors = [.gray, .white.opacity(0.7)]
        case 61...82: colors = [.blue, .cyan]
        case 71...86: colors = [.white, .cyan]
        case 95...99: colors = [.purple, .yellow]
        default:      colors = [.white, .gray]
        }
        return LinearGradient(colors: colors, startPoint: .top, endPoint: .bottom)
    }

    // MARK: - Match Score

    private func matchScoreBar(score: Double) -> some View {
        HStack(spacing: StyleSpacing.md) {
            Image(systemName: "sparkles")
                .font(.system(size: 14))
                .foregroundStyle(StyleColors.accentGold)

            Text("Compatibilidad del Outfit")
                .font(StyleTypography.subheadline)
                .foregroundStyle(StyleColors.textSecondary)

            Spacer()

            Text("\(Int(score * 100))%")
                .font(StyleTypography.title3)
                .foregroundStyle(scoreColor(score))
        }
        .padding(StyleSpacing.lg)
        .glassCard()
    }

    private func scoreColor(_ score: Double) -> Color {
        switch score {
        case 0.8...: return .green
        case 0.6..<0.8: return .yellow
        default: return .orange
        }
    }

    // MARK: - Recommendations

    private var recommendationsList: some View {
        VStack(alignment: .leading, spacing: StyleSpacing.md) {
            Text("Outfit Recomendado")
                .font(StyleTypography.title3)
                .foregroundStyle(.white)

            if let best = recommendations.first {
                VStack(spacing: StyleSpacing.md) {
                    recommendedGarmentRow(garment: best.top, slot: .top)
                    recommendedGarmentRow(garment: best.bottom, slot: .bottom)
                    recommendedGarmentRow(garment: best.shoes, slot: .shoes)
                }

                // Try look button
                NavigationLink(destination: TryOnView()) {
                    HStack(spacing: StyleSpacing.sm) {
                        Image(systemName: "person.crop.rectangle.stack")
                        Text("Probar este Look")
                            .font(StyleTypography.headline)
                    }
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, StyleSpacing.md)
                    .background(StyleColors.brandGradient, in: RoundedRectangle(cornerRadius: StyleSpacing.buttonCornerRadius))
                    .shadow(color: StyleColors.primaryMid.opacity(0.3), radius: 10, y: 5)
                }
                .padding(.top, StyleSpacing.sm)
            }

            // Alternative suggestions
            if recommendations.count > 1 {
                Text("Alternativas")
                    .font(StyleTypography.headline)
                    .foregroundStyle(StyleColors.textSecondary)
                    .padding(.top, StyleSpacing.sm)

                ForEach(Array(recommendations.dropFirst().enumerated()), id: \.offset) { _, rec in
                    alternativeOutfitCard(rec)
                }
            }
        }
    }

    private func recommendedGarmentRow(garment: SampleGarment, slot: GarmentSlot) -> some View {
        HStack(spacing: StyleSpacing.md) {
            // Mini gradient preview
            RoundedRectangle(cornerRadius: 10)
                .fill(
                    LinearGradient(
                        colors: garment.gradientColors,
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
                .frame(width: 50, height: 50)
                .overlay(
                    Image(systemName: garment.icon)
                        .font(.system(size: 18))
                        .foregroundStyle(.white.opacity(0.7))
                )
                .shadow(color: garment.gradientColors.first?.opacity(0.3) ?? .clear, radius: 6, y: 3)

            VStack(alignment: .leading, spacing: StyleSpacing.xxs) {
                Text(garment.name)
                    .font(StyleTypography.headline)
                    .foregroundStyle(.white)

                HStack(spacing: StyleSpacing.sm) {
                    Text(slot.label)
                        .font(StyleTypography.caption)
                        .foregroundStyle(slot.accentColor)

                    Text("•")
                        .foregroundStyle(StyleColors.textTertiary)

                    Text(garment.thermalLabel)
                        .font(StyleTypography.caption)
                        .foregroundStyle(StyleColors.textSecondary)
                }
            }

            Spacer()

            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 20))
                .foregroundStyle(.green)
        }
        .padding(StyleSpacing.md)
        .glassCard(cornerRadius: 14)
    }

    private func alternativeOutfitCard(_ rec: OutfitRecommendation) -> some View {
        HStack(spacing: StyleSpacing.md) {
            // Mini garment icons
            HStack(spacing: -8) {
                miniGarmentCircle(rec.top)
                miniGarmentCircle(rec.bottom)
                miniGarmentCircle(rec.shoes)
            }

            VStack(alignment: .leading, spacing: StyleSpacing.xxs) {
                Text("\(rec.top.name) + \(rec.bottom.name)")
                    .font(StyleTypography.subheadline)
                    .foregroundStyle(.white)
                    .lineLimit(1)

                Text("Match: \(Int(rec.matchScore * 100))%")
                    .font(StyleTypography.caption)
                    .foregroundStyle(scoreColor(rec.matchScore))
            }

            Spacer()
        }
        .padding(StyleSpacing.md)
        .glassCard(cornerRadius: 12)
    }

    private func miniGarmentCircle(_ garment: SampleGarment) -> some View {
        Circle()
            .fill(
                LinearGradient(
                    colors: garment.gradientColors,
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            )
            .frame(width: 32, height: 32)
            .overlay(
                Circle()
                    .stroke(StyleColors.surfacePrimary, lineWidth: 2)
            )
    }

    // MARK: - Explanation

    private func explanationCard(_ text: String) -> some View {
        HStack(alignment: .top, spacing: StyleSpacing.md) {
            Image(systemName: "brain.head.profile")
                .font(.system(size: 18))
                .foregroundStyle(StyleColors.accentMint)

            VStack(alignment: .leading, spacing: StyleSpacing.xs) {
                Text("Razonamiento IA")
                    .font(StyleTypography.caption)
                    .foregroundStyle(StyleColors.accentMint)

                Text(text)
                    .font(StyleTypography.footnote)
                    .foregroundStyle(StyleColors.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(StyleSpacing.lg)
        .glassCard()
    }

    // MARK: - Error View

    private func errorView(message: String) -> some View {
        VStack(spacing: StyleSpacing.xl) {
            Spacer().frame(height: 80)

            Image(systemName: "exclamationmark.icloud.fill")
                .font(.system(size: 48))
                .foregroundStyle(StyleColors.warning)

            Text("Error del Clima")
                .font(StyleTypography.title2)
                .foregroundStyle(.white)

            Text(message)
                .font(StyleTypography.subheadline)
                .foregroundStyle(StyleColors.textSecondary)
                .multilineTextAlignment(.center)

            Button {
                Task { await fetchWeather() }
            } label: {
                Label("Reintentar", systemImage: "arrow.clockwise")
            }
            .buttonStyle(PremiumButtonStyle())
        }
    }

    // MARK: - Empty State

    private var emptyState: some View {
        VStack(spacing: StyleSpacing.xl) {
            Spacer().frame(height: 80)

            Image(systemName: "cloud.sun.fill")
                .font(.system(size: 56))
                .foregroundStyle(StyleColors.accentGold)

            Text("Estilista Meteorológico")
                .font(StyleTypography.title2)
                .foregroundStyle(.white)

            Text("Toca el botón de actualizar para\nobtener sugerencias de outfit")
                .font(StyleTypography.subheadline)
                .foregroundStyle(StyleColors.textSecondary)
                .multilineTextAlignment(.center)
        }
    }

    // MARK: - Actions

    private func fetchWeather() async {
        await weatherService.fetchWeather()
        if let weather = weatherService.currentWeather {
            recommendations = OutfitRecommender.recommendMultiple(for: weather, count: 3)
            DebugLogger.shared.log("👗 Generated \(recommendations.count) outfit recommendations", level: .success)
        }
    }
}

// MARK: - Preview

#Preview {
    NavigationStack {
        WeatherStylistView()
    }
    .preferredColorScheme(.dark)
}
