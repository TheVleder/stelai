// OutfitRecommender.swift
// StyleAI — AI Outfit Recommendation Engine
//
// Scores and ranks garments based on weather conditions.
// Matches garment thermal indices to the current temperature
// to suggest the most appropriate outfit.

import Foundation

// MARK: - Outfit Recommendation

/// A complete outfit suggestion with reasoning.
struct OutfitRecommendation: Sendable {
    let top: SampleGarment
    let bottom: SampleGarment
    let shoes: SampleGarment
    let explanation: String
    let matchScore: Double // 0.0–1.0, how well the outfit matches the weather

    /// Outfit selection for use with TryOnEngine.
    var asOutfitSelection: OutfitSelection {
        OutfitSelection(top: top, bottom: bottom, shoes: shoes)
    }
}

// MARK: - Outfit Recommender

/// Recommends outfits based on weather data by matching thermal indices.
enum OutfitRecommender {

    /// Generate the best outfit recommendation for the given weather.
    static func recommend(for weather: WeatherData) -> OutfitRecommendation {
        let target = weather.targetThermalIndex

        // Score each garment in each category by proximity to target thermal
        let bestTop = bestMatch(from: SampleGarments.allTops, target: target)
        let bestBottom = bestMatch(from: SampleGarments.allBottoms, target: target)
        let bestShoes = bestMatch(from: SampleGarments.allShoes, target: target)

        // Calculate overall match score
        let topScore = 1.0 - abs(bestTop.thermalIndex - target)
        let bottomScore = 1.0 - abs(bestBottom.thermalIndex - target)
        let shoesScore = 1.0 - abs(bestShoes.thermalIndex - target)
        let overallScore = (topScore + bottomScore + shoesScore) / 3.0

        // Generate explanation
        let explanation = generateExplanation(
            weather: weather,
            top: bestTop,
            bottom: bestBottom,
            shoes: bestShoes
        )

        return OutfitRecommendation(
            top: bestTop,
            bottom: bestBottom,
            shoes: bestShoes,
            explanation: explanation,
            matchScore: overallScore
        )
    }

    /// Generate multiple recommendations ranked by match score.
    static func recommendMultiple(for weather: WeatherData, count: Int = 3) -> [OutfitRecommendation] {
        let target = weather.targetThermalIndex

        // Rank all garments by thermal proximity
        let rankedTops = SampleGarments.allTops.sorted { abs($0.thermalIndex - target) < abs($1.thermalIndex - target) }
        let rankedBottoms = SampleGarments.allBottoms.sorted { abs($0.thermalIndex - target) < abs($1.thermalIndex - target) }
        let rankedShoes = SampleGarments.allShoes.sorted { abs($0.thermalIndex - target) < abs($1.thermalIndex - target) }

        var recommendations: [OutfitRecommendation] = []

        for i in 0..<min(count, rankedTops.count) {
            let top = rankedTops[i]
            let bottom = rankedBottoms[min(i, rankedBottoms.count - 1)]
            let shoes = rankedShoes[min(i, rankedShoes.count - 1)]

            let score = (
                (1.0 - abs(top.thermalIndex - target)) +
                (1.0 - abs(bottom.thermalIndex - target)) +
                (1.0 - abs(shoes.thermalIndex - target))
            ) / 3.0

            let explanation = generateExplanation(
                weather: weather,
                top: top,
                bottom: bottom,
                shoes: shoes
            )

            recommendations.append(OutfitRecommendation(
                top: top,
                bottom: bottom,
                shoes: shoes,
                explanation: explanation,
                matchScore: score
            ))
        }

        return recommendations.sorted { $0.matchScore > $1.matchScore }
    }

    // MARK: - Private

    /// Find the garment with the closest thermal index to the target.
    private static func bestMatch(from garments: [SampleGarment], target: Double) -> SampleGarment {
        garments.min(by: { abs($0.thermalIndex - target) < abs($1.thermalIndex - target) })
            ?? garments[0]
    }

    /// Generate a human-readable explanation for the outfit recommendation.
    private static func generateExplanation(
        weather: WeatherData,
        top: SampleGarment,
        bottom: SampleGarment,
        shoes: SampleGarment
    ) -> String {
        let temp = Int(weather.apparentTemperature)
        let condition = weather.condition.lowercased()

        var parts: [String] = []

        // Temperature commentary
        switch weather.apparentTemperature {
        case ..<5:
            parts.append("Con \(temp)°C de sensación térmica, necesitas ropa abrigada.")
        case 5..<15:
            parts.append("Con \(temp)°C, te recomendamos capas templadas.")
        case 15..<25:
            parts.append("Con \(temp)°C, el clima es agradable para ropa ligera.")
        default:
            parts.append("Con \(temp)°C, opta por prendas frescas y transpirables.")
        }

        // Garment reasoning
        parts.append("\(top.name) (\(top.thermalLabel.lowercased())) para la parte superior.")

        // Weather-specific advice
        if weather.weatherCode >= 61 && weather.weatherCode <= 67 {
            parts.append("¡Lluvia prevista! Considera calzado resistente al agua.")
        } else if weather.windSpeed > 30 {
            parts.append("Viento fuerte — una chaqueta cortaviento sería ideal.")
        }

        return parts.joined(separator: " ")
    }
}
