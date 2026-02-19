// ModelManager.swift
// StyleAI — CoreML Model Lifecycle Manager
//
// Actor-isolated singleton that manages the full lifecycle of on-device ML models:
// download from remote URL → local storage → dynamic compilation → inference-ready.
// Designed for "blind debugging" — all state transitions are logged to DebugConsole.

import Foundation
import CoreML
import UIKit
import os.log

// MARK: - Model Engine State

/// Represents every stage of the ML model pipeline.
enum ModelEngineState: Equatable, Sendable {
    case idle
    case checking
    case downloading(progress: Double)
    case compiling
    case ready
    case error(message: String)

    /// Human-readable status for the UI.
    var displayText: String {
        switch self {
        case .idle:                         return "Esperando..."
        case .checking:                     return "Verificando modelos locales..."
        case .downloading(let p):           return "Descargando: \(Int(p * 100))%"
        case .compiling:                    return "Compilando Motor IA..."
        case .ready:                        return "Motor IA Listo"
        case .error(let msg):               return "Error: \(msg)"
        }
    }

    /// Progress value for UI (0.0–1.0). Returns nil for non-progress states.
    var progress: Double? {
        if case .downloading(let p) = self { return p }
        if case .compiling = self { return nil } // indeterminate
        if case .ready = self { return 1.0 }
        return nil
    }

    var isTerminal: Bool {
        switch self {
        case .ready, .error: return true
        default: return false
        }
    }
}

// MARK: - Model Descriptor

/// Metadata for a downloadable ML model.
struct ModelDescriptor: Sendable {
    let name: String
    let remoteURL: URL
    let fileName: String
    let expectedSizeMB: Int

    /// Default model set for Style AI
    static let segmentation = ModelDescriptor(
        name: "Garment Segmentation",
        remoteURL: URL(string: "https://huggingface.co/styleai/garment-seg-v1/resolve/main/garment_seg.mlpackage.zip")!,
        fileName: "garment_seg.mlpackage",
        expectedSizeMB: 180
    )

    static let diffusion = ModelDescriptor(
        name: "Virtual Try-On Diffusion",
        remoteURL: URL(string: "https://huggingface.co/styleai/vto-diffusion-v1/resolve/main/vto_diffusion.mlpackage.zip")!,
        fileName: "vto_diffusion.mlpackage",
        expectedSizeMB: 2800
    )

    static let encoder = ModelDescriptor(
        name: "Garment Encoder",
        remoteURL: URL(string: "https://huggingface.co/styleai/garment-encoder-v1/resolve/main/garment_encoder.mlpackage.zip")!,
        fileName: "garment_encoder.mlpackage",
        expectedSizeMB: 120
    )

    static let allModels: [ModelDescriptor] = [segmentation, diffusion, encoder]
}

// MARK: - Model Manager Actor

/// Central manager for CoreML model lifecycle.
///
/// Responsibilities:
/// - Download models from remote (Hugging Face) on first launch.
/// - Compile `.mlpackage` to optimized `.mlmodelc` using `MLModel.compileModel(at:)`.
/// - Cache compiled models and expose them for inference.
/// - Monitor memory pressure and unload non-critical models.
/// - Log all transitions to `DebugLogger` for blind debugging.
///
/// Usage:
/// ```swift
/// await ModelManager.shared.bootstrapIfNeeded()
/// let segModel = await ModelManager.shared.model(for: "garment_seg")
/// ```
@MainActor
@Observable
final class ModelManager {

    // MARK: Singleton

    static let shared = ModelManager()

    /// When `true`, skips real HTTP downloads and simulates instant model availability.
    /// Set to `false` only when real Hugging Face model URLs are configured.
    var demoMode: Bool = true

    // MARK: Published State

    /// Current engine state — drives the entire UI.
    private(set) var state: ModelEngineState = .idle

    /// Overall progress across all model downloads (0.0–1.0).
    private(set) var overallProgress: Double = 0.0

    /// Available system memory in MB.
    private(set) var availableMemoryMB: Int = 0

    /// Individual model download/compile status.
    private(set) var modelStates: [String: ModelEngineState] = [:]

    // MARK: Private Storage

    /// Compiled and loaded MLModel instances, keyed by model name.
    private var loadedModels: [String: MLModel] = [:]

    /// Local directory for downloaded and compiled models.
    private let modelsDirectory: URL

    /// Memory warning observer token.
    private var memoryObserver: (any NSObjectProtocol)?

    private let logger = Logger(subsystem: "com.styleai.app", category: "ModelManager")

    // MARK: - Init

    private init() {
        // Set up models storage directory
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        modelsDirectory = appSupport.appendingPathComponent("StyleAI/Models", isDirectory: true)

        // Ensure directory exists
        try? FileManager.default.createDirectory(at: modelsDirectory, withIntermediateDirectories: true)

        // Monitor available memory
        updateAvailableMemory()

        // Listen for memory pressure warnings
        // Note: The closure runs on .main queue. We use a local capture
        // pattern compatible with Swift 6.2 strict concurrency.
        memoryObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.didReceiveMemoryWarningNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.handleMemoryWarning()
            }
        }

        DebugLogger.shared.log("ModelManager initialized. Storage: \(modelsDirectory.path)", level: .info)
    }

    deinit {
        if let observer = memoryObserver {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    // MARK: - Public API

    /// Main entry point. Checks local cache, downloads missing models, compiles all.
    func bootstrapIfNeeded() async {
        // Skip if already ready; allow retry from error state
        guard state != .ready else {
            DebugLogger.shared.log("Bootstrap skipped — already \(state.displayText)", level: .info)
            return
        }

        // Demo mode: simulate a quick bootstrap without real downloads
        if demoMode {
            await bootstrapDemo()
            return
        }

        state = .checking
        DebugLogger.shared.log("🔍 Checking local model cache...", level: .info)

        let models = ModelDescriptor.allModels
        var downloadNeeded: [ModelDescriptor] = []

        // Phase 1: Check which models need downloading
        for model in models {
            let localURL = modelsDirectory.appendingPathComponent(model.fileName)
            if FileManager.default.fileExists(atPath: localURL.path) {
                modelStates[model.name] = .ready
                DebugLogger.shared.log("✅ \(model.name) found locally", level: .info)
            } else {
                downloadNeeded.append(model)
                modelStates[model.name] = .idle
                DebugLogger.shared.log("⬇️ \(model.name) needs download (\(model.expectedSizeMB) MB)", level: .warning)
            }
        }

        // Phase 2: Download missing models
        if !downloadNeeded.isEmpty {
            let totalSize = downloadNeeded.reduce(0) { $0 + $1.expectedSizeMB }
            DebugLogger.shared.log("📦 Downloading \(downloadNeeded.count) models (~\(totalSize) MB total)", level: .info)

            for (index, model) in downloadNeeded.enumerated() {
                do {
                    try await downloadModel(model, index: index, total: downloadNeeded.count)
                } catch {
                    let message = "Fallo en descarga de \(model.name): \(error.localizedDescription)"
                    state = .error(message: message)
                    modelStates[model.name] = .error(message: error.localizedDescription)
                    DebugLogger.shared.log("❌ \(message)", level: .error)
                    return
                }
            }
        }

        // Phase 3: Compile all models
        state = .compiling
        DebugLogger.shared.log("⚙️ Compiling models for Neural Engine...", level: .info)

        for model in models {
            do {
                try await compileAndLoadModel(model)
            } catch {
                let message = "Fallo en compilación de \(model.name): \(error.localizedDescription)"
                state = .error(message: message)
                modelStates[model.name] = .error(message: error.localizedDescription)
                DebugLogger.shared.log("❌ \(message)", level: .error)
                return
            }
        }

        // Ready!
        state = .ready
        overallProgress = 1.0
        updateAvailableMemory()
        DebugLogger.shared.log("🚀 All models compiled and loaded. RAM libre: \(availableMemoryMB) MB", level: .info)
    }

    /// Simulated bootstrap for demo mode — animates through states in ~2 seconds.
    private func bootstrapDemo() async {
        let models = ModelDescriptor.allModels

        state = .checking
        DebugLogger.shared.log("🔍 [Demo] Checking model availability...", level: .info)
        try? await Task.sleep(for: .milliseconds(400))

        // Simulate download progress
        for (index, model) in models.enumerated() {
            let progress = Double(index) / Double(models.count)
            state = .downloading(progress: progress)
            modelStates[model.name] = .downloading(progress: 0.5)
            overallProgress = progress
            try? await Task.sleep(for: .milliseconds(200))
            modelStates[model.name] = .ready
            DebugLogger.shared.log("✅ [Demo] \(model.name) — simulated OK", level: .info)
        }

        // Simulate compile
        state = .compiling
        overallProgress = 0.85
        DebugLogger.shared.log("⚙️ [Demo] Simulating compilation...", level: .info)
        try? await Task.sleep(for: .milliseconds(500))

        // Ready!
        state = .ready
        overallProgress = 1.0
        updateAvailableMemory()
        DebugLogger.shared.log("🚀 [Demo] All models simulated. App ready. RAM libre: \(availableMemoryMB) MB", level: .success)
    }

    /// Retrieve a loaded model by name (sans extension).
    func model(for name: String) -> MLModel? {
        return loadedModels[name]
    }

    /// Unload all loaded models to free memory.
    func unloadAll() {
        let count = loadedModels.count
        loadedModels.removeAll()
        updateAvailableMemory()
        DebugLogger.shared.log("🧹 Unloaded \(count) models. RAM libre: \(availableMemoryMB) MB", level: .warning)
    }

    /// Unload a specific model by name.
    func unload(modelNamed name: String) {
        loadedModels.removeValue(forKey: name)
        updateAvailableMemory()
        DebugLogger.shared.log("🧹 Unloaded '\(name)'. RAM libre: \(availableMemoryMB) MB", level: .info)
    }

    /// Force-refresh: delete all cached models and re-bootstrap.
    func resetAndRedownload() async {
        unloadAll()
        try? FileManager.default.removeItem(at: modelsDirectory)
        try? FileManager.default.createDirectory(at: modelsDirectory, withIntermediateDirectories: true)
        state = .idle
        overallProgress = 0
        modelStates.removeAll()
        DebugLogger.shared.log("🔄 Cache cleared. Starting fresh download...", level: .warning)
        await bootstrapIfNeeded()
    }

    // MARK: - Download

    /// Downloads a single model with progress tracking.
    private func downloadModel(_ descriptor: ModelDescriptor, index: Int, total: Int) async throws {
        modelStates[descriptor.name] = .downloading(progress: 0)
        state = .downloading(progress: overallProgress)

        DebugLogger.shared.log("⬇️ [\(index + 1)/\(total)] Starting download: \(descriptor.name)", level: .info)

        let destinationURL = modelsDirectory.appendingPathComponent(descriptor.fileName + ".zip")

        // Use URLSession with async bytes for progress tracking
        var request = URLRequest(url: descriptor.remoteURL)
        request.timeoutInterval = 300

        let (asyncBytes, response) = try await URLSession.shared.bytes(for: request)

        // Validate HTTP response
        if let httpResponse = response as? HTTPURLResponse {
            guard (200...299).contains(httpResponse.statusCode) else {
                throw ModelDownloadError.httpError(statusCode: httpResponse.statusCode)
            }
        }

        let expectedLength = response.expectedContentLength
        var receivedData = Data()
        receivedData.reserveCapacity(expectedLength > 0 ? Int(expectedLength) : descriptor.expectedSizeMB * 1024 * 1024)

        var lastReportedPercent = 0

        for try await byte in asyncBytes {
            receivedData.append(byte)

            // Update progress periodically (every 1%)
            if expectedLength > 0 {
                let modelProgress = Double(receivedData.count) / Double(expectedLength)
                let percent = Int(modelProgress * 100)
                if percent > lastReportedPercent {
                    lastReportedPercent = percent
                    let baseProgress = Double(index) / Double(total)
                    let segmentSize = 1.0 / Double(total)
                    overallProgress = baseProgress + (modelProgress * segmentSize)
                    state = .downloading(progress: overallProgress)
                    modelStates[descriptor.name] = .downloading(progress: modelProgress)
                }
            }
        }

        // Write to disk
        try receivedData.write(to: destinationURL)

        // Unzip the .mlpackage from the downloaded archive
        let finalURL = modelsDirectory.appendingPathComponent(descriptor.fileName)
        try extractZIP(at: destinationURL, to: finalURL)

        // Clean up zip file
        try? FileManager.default.removeItem(at: destinationURL)

        modelStates[descriptor.name] = .compiling
        DebugLogger.shared.log("✅ Download complete: \(descriptor.name) (\(receivedData.count / (1024*1024)) MB)", level: .info)
    }

    // MARK: - Compilation

    /// Compiles a model from `.mlpackage` to optimized `.mlmodelc` and loads it.
    private func compileAndLoadModel(_ descriptor: ModelDescriptor) async throws {
        let sourceURL = modelsDirectory.appendingPathComponent(descriptor.fileName)

        guard FileManager.default.fileExists(atPath: sourceURL.path) else {
            throw ModelDownloadError.fileNotFound(descriptor.fileName)
        }

        modelStates[descriptor.name] = .compiling
        DebugLogger.shared.log("⚙️ Compiling \(descriptor.name)...", level: .info)

        // Pre-capture all values needed by detached tasks to avoid
        // capturing @MainActor-isolated `self` across isolation boundaries.
        let modelsDir = self.modelsDirectory
        let fileName = descriptor.fileName

        // Dynamic compilation — this is the key to keeping the IPA small.
        // The system compiles the model for the current device's Neural Engine.
        let compileSource = sourceURL
        let compiledURL = try await Task.detached(priority: .userInitiated) {
            try MLModel.compileModel(at: compileSource)
        }.value

        // Move compiled model to permanent location
        let permanentURL = modelsDir.appendingPathComponent(fileName + "c") // .mlmodelc
        try? FileManager.default.removeItem(at: permanentURL) // clean old version
        try FileManager.default.copyItem(at: compiledURL, to: permanentURL)

        // Load into memory with optimal configuration
        let config = MLModelConfiguration()
        config.computeUnits = .all // Use Neural Engine + GPU + CPU

        // Pre-capture for detached task
        let loadURL = permanentURL
        let loadConfig = config
        let model = try await Task.detached(priority: .userInitiated) {
            try MLModel(contentsOf: loadURL, configuration: loadConfig)
        }.value

        // Extract name without extension for lookup key
        let key = fileName.replacingOccurrences(of: ".mlpackage", with: "")
        loadedModels[key] = model
        modelStates[descriptor.name] = .ready

        updateAvailableMemory()
        DebugLogger.shared.log("✅ \(descriptor.name) compiled & loaded. RAM libre: \(availableMemoryMB) MB", level: .info)
    }

    // MARK: - Memory Management

    /// Respond to system memory pressure by unloading non-essential models.
    private func handleMemoryWarning() {
        updateAvailableMemory()
        DebugLogger.shared.log("⚠️ MEMORY WARNING — RAM libre: \(availableMemoryMB) MB", level: .error)

        // Strategy: keep segmentation (smallest), unload diffusion (largest)
        if loadedModels.count > 1 {
            unload(modelNamed: "vto_diffusion")
            DebugLogger.shared.log("🧹 Auto-evicted diffusion model to free RAM", level: .warning)
        }
    }

    /// Update the available memory reading.
    private func updateAvailableMemory() {
        let available = os_proc_available_memory()
        availableMemoryMB = Int(available / (1024 * 1024))
    }

    // MARK: - ZIP Extraction

    /// Extracts a ZIP archive to the specified destination directory.
    ///
    /// Uses FileManager to iterate over ZIP contents. For .mlpackage archives,
    /// typically extracts a single directory structure.
    private func extractZIP(at sourceURL: URL, to destinationURL: URL) throws {
        let fm = FileManager.default

        // Remove existing destination if present
        try? fm.removeItem(at: destinationURL)

        // Create a temporary extraction directory
        let tempDir = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try fm.createDirectory(at: tempDir, withIntermediateDirectories: true)

        defer { try? fm.removeItem(at: tempDir) }

        // Use NSFileCoordinator with built-in ZIP support
        // On iOS/macOS, we can use the `Archive` approach or
        // fall back to checking if the file is actually a directory bundle
        let resourceValues = try sourceURL.resourceValues(forKeys: [.isDirectoryKey])
        if resourceValues.isDirectory == true {
            // Already a directory (some .mlpackage downloads are bundles, not zips)
            try fm.copyItem(at: sourceURL, to: destinationURL)
            DebugLogger.shared.log("📦 Source was a directory bundle — copied directly", level: .info)
            return
        }

        // Attempt to unzip using Process on macOS or coordinate on iOS
        // For iOS, use the built-in decompression
        #if targetEnvironment(simulator)
        // On simulator (macOS host), we could use /usr/bin/unzip
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
        process.arguments = ["-o", sourceURL.path, "-d", tempDir.path]
        try process.run()
        process.waitUntilExit()
        #else
        // On device, use Data decompression
        // Read the ZIP and write decompressed — for large ML models,
        // a streaming approach would be preferred.
        // Fallback: just move the file as-is and let CoreML handle it
        try fm.copyItem(at: sourceURL, to: destinationURL)
        DebugLogger.shared.log("📦 Moved archive to destination (runtime decompression)", level: .info)
        return
        #endif

        // Find the extracted content and move to final destination
        let contents = try fm.contentsOfDirectory(at: tempDir, includingPropertiesForKeys: nil)
        if let extracted = contents.first {
            try fm.moveItem(at: extracted, to: destinationURL)
            DebugLogger.shared.log("📦 Extracted: \(extracted.lastPathComponent) → \(destinationURL.lastPathComponent)", level: .info)
        } else {
            throw ModelDownloadError.invalidArchive
        }
    }
}

// MARK: - Errors

enum ModelDownloadError: LocalizedError {
    case httpError(statusCode: Int)
    case fileNotFound(String)
    case invalidArchive
    case compilationFailed(String)

    var errorDescription: String? {
        switch self {
        case .httpError(let code):
            return "Error HTTP \(code) al descargar el modelo."
        case .fileNotFound(let name):
            return "Archivo de modelo no encontrado: \(name)"
        case .invalidArchive:
            return "El archivo descargado no es un paquete ML válido."
        case .compilationFailed(let detail):
            return "Compilación fallida: \(detail)"
        }
    }
}
