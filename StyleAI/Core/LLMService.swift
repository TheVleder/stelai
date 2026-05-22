// LLMService.swift
// StyleAI — On-Device LLM via Apple Foundation Models (iOS 26+)
//
// Wraps `LanguageModelSession` to provide two capabilities used by the rest
// of the app: enriching Stable Diffusion prompts from raw garment names, and
// generating natural-language outfit justifications.
//
// Free, on-device, ~3B params. No network, no API key, no cost per call.
// Falls back to deterministic strings when the model is unavailable, so the
// rest of the app never has to special-case missing AI.

import Foundation
@preconcurrency import FoundationModels

// MARK: - LLM Service

@MainActor
@Observable
final class LLMService {

    static let shared = LLMService()

    /// Whether the on-device foundation model is usable right now.
    private(set) var isAvailable: Bool = false

    /// Human-readable reason when `isAvailable` is false.
    private(set) var unavailableReason: String?

    private init() {
        refreshAvailability()
    }

    /// Re-checks model availability. Call after the user toggles Apple
    /// Intelligence in Settings or after waking from background.
    func refreshAvailability() {
        switch SystemLanguageModel.default.availability {
        case .available:
            isAvailable = true
            unavailableReason = nil
            DebugLogger.shared.log("🤖 LLMService: Foundation Models available", level: .success)
        case .unavailable(let reason):
            isAvailable = false
            unavailableReason = Self.describe(reason)
            DebugLogger.shared.log("🤖 LLMService: Foundation Models unavailable — \(unavailableReason ?? "?")", level: .warning)
        @unknown default:
            isAvailable = false
            unavailableReason = "Estado desconocido"
        }
    }

    // MARK: - Public API

    /// Turn a comma-separated garment list into a richer Stable Diffusion
    /// prompt. Returns the original `fallback` string when the model is
    /// unavailable so callers can drop the result straight into `generateTryOn`.
    ///
    /// - Parameters:
    ///   - garments: e.g. `["Camisa blanca", "Vaquero azul", "Botas marrones"]`
    ///   - fallback: the deterministic prompt used today
    func enrichSDPrompt(garments: [String], fallback: String) async -> String {
        guard isAvailable else { return fallback }

        let names = garments.joined(separator: ", ")
        let instructions = """
        You write prompts for a Stable Diffusion fashion photography model.
        Given a list of garment names in Spanish, output a single English \
        prompt under 60 words that describes a photorealistic full-body \
        photograph of a person wearing those garments. Mention fabric, fit, \
        lighting, camera details. Do not add extra garments. Reply with the \
        prompt only — no preamble, no quotes.
        """

        let prompt = "Garments: \(names)"

        do {
            let session = obtainSession(instructions: instructions)
            let response = try await session.respond(to: prompt)
            let enriched = response.content.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !enriched.isEmpty else { return fallback }
            DebugLogger.shared.log("🤖 LLM enriched prompt (\(enriched.count) chars)", level: .info)
            return enriched
        } catch {
            DebugLogger.shared.log("🤖 LLM enrich failed: \(error.localizedDescription) — using fallback", level: .warning)
            return fallback
        }
    }

    /// Generate a short Spanish justification for an outfit suggestion. Returns
    /// `fallback` when the model is unavailable.
    ///
    /// - Parameters:
    ///   - topName: e.g. "Camisa blanca"
    ///   - bottomName: e.g. "Vaquero azul"
    ///   - shoesName: e.g. "Botas marrones"
    ///   - apparentTempC: weather-adjusted temperature in Celsius
    ///   - condition: human description ("Soleado", "Lluvia ligera", …)
    ///   - fallback: the deterministic explanation currently produced
    func outfitJustification(
        topName: String,
        bottomName: String,
        shoesName: String,
        apparentTempC: Double,
        condition: String,
        fallback: String
    ) async -> String {
        guard isAvailable else { return fallback }

        let instructions = """
        Eres un estilista de moda. Recibes un outfit y el clima. Responde en \
        español con UNA sola frase de máximo 25 palabras explicando por qué \
        este outfit funciona hoy. Tono cálido y directo. Sin emojis. Sin \
        listas. Solo la frase.
        """

        let prompt = """
        Outfit: \(topName), \(bottomName), \(shoesName).
        Clima: \(Int(apparentTempC))°C, \(condition).
        """

        do {
            let session = obtainSession(instructions: instructions)
            let response = try await session.respond(to: prompt)
            let text = response.content.trimmingCharacters(in: .whitespacesAndNewlines)
            return text.isEmpty ? fallback : text
        } catch {
            DebugLogger.shared.log("🤖 LLM justification failed: \(error.localizedDescription)", level: .warning)
            return fallback
        }
    }

    // MARK: - Private

    /// Each call uses a fresh session — prompts are short, sessions are cheap,
    /// and this avoids the 4,096-token context filling up across many calls.
    private func obtainSession(instructions: String) -> LanguageModelSession {
        LanguageModelSession(instructions: instructions)
    }

    private static func describe(_ reason: SystemLanguageModel.Availability.UnavailableReason) -> String {
        switch reason {
        case .appleIntelligenceNotEnabled:
            return "Apple Intelligence está desactivado en Ajustes."
        case .deviceNotEligible:
            return "Este dispositivo no soporta Apple Intelligence."
        case .modelNotReady:
            return "El modelo se está preparando, vuelve a intentarlo en un momento."
        @unknown default:
            return "Razón desconocida."
        }
    }
}
