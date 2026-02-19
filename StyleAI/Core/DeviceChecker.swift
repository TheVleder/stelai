// DeviceChecker.swift
// StyleAI — Device Compatibility Gate
//
// Validates that the current device meets minimum hardware requirements
// for on-device ML inference (A17 Pro+, ≥6 GB RAM, iOS 26+).

import Foundation
import UIKit

// MARK: - Compatibility Result

/// Structured result from the device compatibility check.
struct DeviceCompatibilityResult: Sendable {
    let isCompatible: Bool
    let chipName: String
    let ramGB: Double
    let failureReasons: [String]
}

// MARK: - Device Checker

/// Validates hardware requirements for Style AI's on-device ML pipeline.
///
/// The Neural Engine on A17 Pro+ is required for real-time segmentation
/// and diffusion inference. Older chips will produce unacceptable latency.
enum DeviceChecker {

    /// Minimum RAM required for loading segmentation + diffusion models.
    private static let minimumRAMBytes: UInt64 = 6 * 1024 * 1024 * 1024 // 6 GB

    /// Known chip identifiers for A17 Pro and newer.
    /// Maps device machine identifiers to human-readable chip names.
    private static let supportedChips: [String: String] = [
        // iPhone 15 Pro / Pro Max — A17 Pro
        "iPhone16,1": "A17 Pro",
        "iPhone16,2": "A17 Pro",
        // iPhone 16 series — A18 / A18 Pro
        "iPhone17,1": "A18 Pro",
        "iPhone17,2": "A18 Pro",
        "iPhone17,3": "A18",
        "iPhone17,4": "A18",
        "iPhone17,5": "A18",
        // iPhone 17 series (projected) — A19
        "iPhone18,1": "A19 Pro",
        "iPhone18,2": "A19 Pro",
        "iPhone18,3": "A19",
        "iPhone18,4": "A19",
        "iPhone18,5": "A19",
        // Simulator fallback
        "x86_64":     "Simulator",
        "arm64":      "Simulator (Apple Silicon)",
    ]

    // MARK: - Public API

    /// Performs a full device compatibility check.
    ///
    /// - Returns: A `DeviceCompatibilityResult` with pass/fail and diagnostic details.
    static func validate() -> DeviceCompatibilityResult {
        var reasons: [String] = []

        // 1. Chip check
        let machineId = machineIdentifier()
        let chipName: String
        let chipOk: Bool

        if let known = supportedChips[machineId] {
            chipName = known
            chipOk = true
        } else if machineId.hasPrefix("iPhone") {
            // Future iPhones — attempt numeric parse
            let components = machineId.replacingOccurrences(of: "iPhone", with: "")
                .split(separator: ",")
            if let major = components.first.flatMap({ Int($0) }), major >= 16 {
                chipName = "iPhone Gen \(major) (assumed compatible)"
                chipOk = true
            } else {
                chipName = "Unsupported (\(machineId))"
                chipOk = false
                reasons.append("Chip \(machineId) is older than A17 Pro. Neural Engine performance insuficiente.")
            }
        } else {
            // iPad or other devices — allow but warn
            chipName = machineId
            chipOk = machineId.contains("arm64") || machineId.contains("x86_64") // simulator
            if !chipOk {
                reasons.append("Dispositivo no reconocido: \(machineId).")
            }
        }

        // 2. RAM check
        let physicalMemory = ProcessInfo.processInfo.physicalMemory
        let ramGB = Double(physicalMemory) / (1024 * 1024 * 1024)
        let ramOk = physicalMemory >= minimumRAMBytes

        if !ramOk {
            reasons.append(
                String(format: "RAM insuficiente: %.1f GB (mínimo 6 GB).", ramGB)
            )
        }

        // 3. OS check
        let osOk: Bool
        if #available(iOS 26, *) {
            osOk = true
        } else {
            osOk = false
            reasons.append("Se requiere iOS 26 o superior.")
        }

        return DeviceCompatibilityResult(
            isCompatible: chipOk && ramOk && osOk,
            chipName: chipName,
            ramGB: ramGB,
            failureReasons: reasons
        )
    }

    // MARK: - Private Helpers

    /// Reads the hardware machine identifier via `sysctl`.
    private static func machineIdentifier() -> String {
        #if targetEnvironment(simulator)
        return ProcessInfo.processInfo.environment["SIMULATOR_MODEL_IDENTIFIER"]
            ?? "arm64"
        #else
        var systemInfo = utsname()
        uname(&systemInfo)
        return withUnsafePointer(to: &systemInfo.machine) { ptr in
            ptr.withMemoryRebound(to: CChar.self, capacity: 1) { cPtr in
                String(cString: cPtr)
            }
        }
        #endif
    }
}
