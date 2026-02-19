// StableDiffusionService.swift
// StyleAI — On-Device Stable Diffusion for Virtual Try-On
//
// Wraps Apple's ml-stable-diffusion Swift package to provide
// image-to-image inpainting for realistic clothing overlay.
// Models are downloaded on-demand from Hugging Face (~2 GB).

import Foundation
import UIKit
import CoreImage
import CoreML
import StableDiffusion

// MARK: - SD Model Descriptor

/// Describes one CoreML model file that must be downloaded for the SD pipeline.
struct SDModelFile: Identifiable {
    let id: String
    let fileName: String
    let remoteURL: URL
    let expectedSizeMB: Int

    /// Base URL for the compiled split_einsum_v2 models on Hugging Face.
    static let baseURL = "https://huggingface.co/apple/coreml-stable-diffusion-2-1-base/resolve/main/split_einsum_v2/compiled/"

    /// All files required for the inpainting pipeline.
    static let requiredFiles: [SDModelFile] = [
        SDModelFile(
            id: "text_encoder",
            fileName: "TextEncoder.mlmodelc",
            remoteURL: URL(string: baseURL + "TextEncoder.mlmodelc.zip")!,
            expectedSizeMB: 250
        ),
        SDModelFile(
            id: "unet_chunk1",
            fileName: "UnetChunk1.mlmodelc",
            remoteURL: URL(string: baseURL + "UnetChunk1.mlmodelc.zip")!,
            expectedSizeMB: 700
        ),
        SDModelFile(
            id: "unet_chunk2",
            fileName: "UnetChunk2.mlmodelc",
            remoteURL: URL(string: baseURL + "UnetChunk2.mlmodelc.zip")!,
            expectedSizeMB: 700
        ),
        SDModelFile(
            id: "vae_decoder",
            fileName: "VAEDecoder.mlmodelc",
            remoteURL: URL(string: baseURL + "VAEDecoder.mlmodelc.zip")!,
            expectedSizeMB: 95
        ),
        SDModelFile(
            id: "vae_encoder",
            fileName: "VAEEncoder.mlmodelc",
            remoteURL: URL(string: baseURL + "VAEEncoder.mlmodelc.zip")!,
            expectedSizeMB: 95
        ),
        // Tokenizer resources (small)
        SDModelFile(
            id: "vocab",
            fileName: "vocab.json",
            remoteURL: URL(string: "https://huggingface.co/apple/coreml-stable-diffusion-2-1-base/resolve/main/split_einsum_v2/compiled/vocab.json")!,
            expectedSizeMB: 1
        ),
        SDModelFile(
            id: "merges",
            fileName: "merges.txt",
            remoteURL: URL(string: "https://huggingface.co/apple/coreml-stable-diffusion-2-1-base/resolve/main/split_einsum_v2/compiled/merges.txt")!,
            expectedSizeMB: 1
        )
    ]

    /// Total expected download size across all model files.
    static var totalSizeMB: Int {
        requiredFiles.reduce(0) { $0 + $1.expectedSizeMB }
    }
}

// MARK: - Service State

/// Tracks the lifecycle of the Stable Diffusion model.
enum SDServiceState: Equatable {
    case notDownloaded
    case downloading(progress: Double)
    case extracting
    case loading
    case ready
    case generating(progress: Double)
    case error(message: String)

    var displayText: String {
        switch self {
        case .notDownloaded: return "No descargado"
        case .downloading(let p): return "Descargando \(Int(p * 100))%"
        case .extracting: return "Extrayendo..."
        case .loading: return "Cargando pipeline..."
        case .ready: return "Listo"
        case .generating(let p): return "Generando \(Int(p * 100))%"
        case .error(let msg): return "Error: \(msg)"
        }
    }

    var isReady: Bool {
        if case .ready = self { return true }
        return false
    }

    var isDownloading: Bool {
        if case .downloading = self { return true }
        return false
    }

    var isGenerating: Bool {
        if case .generating = self { return true }
        return false
    }
}

// MARK: - Stable Diffusion Service

/// Manages the Stable Diffusion pipeline for realistic Virtual Try-On.
///
/// Architecture:
/// 1. Downloads pre-compiled CoreML models from Hugging Face on first VTO use.
/// 2. Initializes `StableDiffusionPipeline` from Apple's ml-stable-diffusion.
/// 3. Generates dressed images using image-to-image with masking.
///
/// Memory Management:
/// - Uses `reduceMemory: true` to minimize RAM (~2.5 GB peak on A17 Pro).
/// - Pipeline and resources are freed when app backgrounds.
/// - Models persist on disk between launches (~2 GB storage).
@MainActor
@Observable
final class StableDiffusionService {

    // MARK: Singleton

    static let shared = StableDiffusionService()

    // MARK: State

    /// Current state of the SD service.
    private(set) var state: SDServiceState = .notDownloaded

    /// Download progress (0.0–1.0).
    private(set) var downloadProgress: Double = 0.0

    /// Generation progress (0.0–1.0).
    private(set) var generationProgress: Double = 0.0

    // MARK: Private

    /// The loaded SD pipeline (nil until models downloaded + initialized).
    private var pipeline: StableDiffusionPipeline?

    /// Directory where SD model files are stored.
    private let modelsDirectory: URL = {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let dir = docs.appendingPathComponent("SDModels", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    // MARK: - Public API

    /// Whether all SD model files have been downloaded.
    var isModelDownloaded: Bool {
        SDModelFile.requiredFiles.allSatisfy { file in
            FileManager.default.fileExists(
                atPath: modelsDirectory.appendingPathComponent(file.fileName).path
            )
        }
    }

    /// Check local model availability on init.
    func checkAvailability() {
        if isModelDownloaded {
            state = .loading
            DebugLogger.shared.log("📦 SD model files found locally", level: .info)
            Task { await loadPipeline() }
        } else {
            state = .notDownloaded
            DebugLogger.shared.log("⬇️ SD model not downloaded (~\(SDModelFile.totalSizeMB) MB)", level: .info)
        }
    }

    /// Download all required model files from Hugging Face.
    func downloadModels() async {
        guard !isModelDownloaded else {
            await loadPipeline()
            return
        }

        let files = SDModelFile.requiredFiles
        let totalFiles = files.count

        DebugLogger.shared.log("⬇️ Starting SD model download (\(totalFiles) files, ~\(SDModelFile.totalSizeMB) MB)", level: .info)

        for (index, file) in files.enumerated() {
            let destinationURL = modelsDirectory.appendingPathComponent(file.fileName)

            // Skip if already downloaded
            if FileManager.default.fileExists(atPath: destinationURL.path) {
                let progress = Double(index + 1) / Double(totalFiles)
                downloadProgress = progress
                state = .downloading(progress: progress)
                DebugLogger.shared.log("✅ \(file.fileName) — ya descargado", level: .info)
                continue
            }

            do {
                try await downloadFile(file, index: index, total: totalFiles)
            } catch {
                let message = "Error descargando \(file.fileName): \(error.localizedDescription)"
                state = .error(message: message)
                DebugLogger.shared.log("❌ \(message)", level: .error)
                return
            }
        }

        DebugLogger.shared.log("✅ All SD model files downloaded", level: .success)
        await loadPipeline()
    }

    /// Generate a "dressed" image using SD inpainting.
    ///
    /// - Parameters:
    ///   - personImage: Full-body photo of the user.
    ///   - mask: Binary mask of the region to paint (clothing zone).
    ///   - prompt: Description of clothing to generate (e.g. "blue denim jacket, casual style").
    ///   - seed: Random seed for reproducibility.
    ///   - steps: Number of diffusion steps (lower = faster, less quality).
    /// - Returns: The generated image, or nil on failure.
    func generateTryOn(
        personImage: UIImage,
        mask: UIImage,
        prompt: String,
        negativePrompt: String = "deformed, blurry, bad anatomy, extra limbs, watermark, text",
        seed: UInt32 = .random(in: 0...UInt32.max),
        steps: Int = 20,
        guidanceScale: Float = 7.5
    ) async -> UIImage? {

        guard let pipeline else {
            DebugLogger.shared.log("❌ SD pipeline not loaded", level: .error)
            return nil
        }

        state = .generating(progress: 0.0)
        generationProgress = 0.0
        DebugLogger.shared.log("🎨 Starting SD generation: \"\(prompt)\"", level: .info)
        DebugLogger.shared.log("   Steps: \(steps), Seed: \(seed), Guidance: \(guidanceScale)", level: .info)

        let startTime = Date()

        do {
            // Resize input to 512×512 (SD 2.1 native resolution)
            let inputCGImage = resizeTo512(personImage)
            let maskCGImage = resizeTo512(mask)

            // Build SD configuration
            var sdConfig = StableDiffusionPipeline.Configuration(prompt: prompt)
            sdConfig.negativePrompt = negativePrompt
            sdConfig.seed = seed
            sdConfig.stepCount = steps
            sdConfig.guidanceScale = guidanceScale
            sdConfig.startingImage = inputCGImage
            sdConfig.maskImage = maskCGImage
            sdConfig.strength = 0.75 // How much to repaint (0.75 = strong clothing change)
            sdConfig.schedulerType = .dpmSolverMultistepScheduler

            // Run the pipeline on a background thread
            let config = sdConfig
            let pipe = pipeline
            let images = try await Task.detached(priority: .userInitiated) {
                try pipe.generateImages(configuration: config) { progress in
                    Task { @MainActor in
                        let p = Double(progress.step) / Double(progress.stepCount)
                        self.generationProgress = p
                        self.state = .generating(progress: p)
                    }
                    return true // continue generating
                }
            }.value

            let elapsed = Date().timeIntervalSince(startTime)
            DebugLogger.shared.log("✅ SD generation complete in \(String(format: "%.1f", elapsed))s", level: .success)

            state = .ready
            generationProgress = 1.0

            // Return the generated image
            if let cgImage = images.first ?? nil {
                // Scale back to original size
                let generated = UIImage(cgImage: cgImage)
                return scaleToMatch(generated, target: personImage)
            }

            return nil
        } catch {
            state = .error(message: error.localizedDescription)
            DebugLogger.shared.log("❌ SD generation failed: \(error.localizedDescription)", level: .error)
            return nil
        }
    }

    /// Free all SD resources to reclaim memory.
    func unloadPipeline() {
        pipeline = nil
        state = isModelDownloaded ? .notDownloaded : .notDownloaded
        DebugLogger.shared.log("🧹 SD pipeline unloaded", level: .warning)
    }

    // MARK: - Private: Download

    /// Downloads a single model file with progress tracking.
    private func downloadFile(_ file: SDModelFile, index: Int, total: Int) async throws {
        let destinationURL = modelsDirectory.appendingPathComponent(file.fileName)
        let isZip = file.remoteURL.pathExtension == "zip"
        let downloadDest = isZip
            ? modelsDirectory.appendingPathComponent(file.fileName + ".zip")
            : destinationURL

        state = .downloading(progress: downloadProgress)
        DebugLogger.shared.log("⬇️ [\(index + 1)/\(total)] \(file.fileName) (\(file.expectedSizeMB) MB)", level: .info)

        var request = URLRequest(url: file.remoteURL)
        request.timeoutInterval = 600 // 10 min for large files

        let (asyncBytes, response) = try await URLSession.shared.bytes(for: request)

        if let httpResponse = response as? HTTPURLResponse,
           !(200...299).contains(httpResponse.statusCode) {
            throw StableDiffusionError.httpError(statusCode: httpResponse.statusCode)
        }

        let expectedLength = response.expectedContentLength
        var receivedData = Data()
        if expectedLength > 0 {
            receivedData.reserveCapacity(Int(expectedLength))
        }

        var lastReportedPercent = 0

        for try await byte in asyncBytes {
            receivedData.append(byte)

            if expectedLength > 0 {
                let fileProgress = Double(receivedData.count) / Double(expectedLength)
                let percent = Int(fileProgress * 100)
                if percent > lastReportedPercent {
                    lastReportedPercent = percent
                    let baseProgress = Double(index) / Double(total)
                    let segmentSize = 1.0 / Double(total)
                    downloadProgress = baseProgress + (fileProgress * segmentSize)
                    state = .downloading(progress: downloadProgress)
                }
            }
        }

        try receivedData.write(to: downloadDest)

        // Extract ZIP if needed
        if isZip {
            state = .extracting
            DebugLogger.shared.log("📦 Extracting \(file.fileName)...", level: .info)

            let fm = FileManager.default
            // For .mlmodelc ZIPs, unzip to the models directory
            let tempDir = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
            try fm.createDirectory(at: tempDir, withIntermediateDirectories: true)
            defer { try? fm.removeItem(at: tempDir) }

            // Use built-in decompression
            try? fm.removeItem(at: destinationURL)

            // Attempt to decompress the data
            if let decompressed = try? (receivedData as NSData).decompressed(using: .zlib) as Data {
                try decompressed.write(to: destinationURL)
            } else {
                // Fallback: move as-is and let CoreML handle it
                try fm.moveItem(at: downloadDest, to: destinationURL)
            }

            try? fm.removeItem(at: downloadDest)
        }

        DebugLogger.shared.log("✅ \(file.fileName) — \(receivedData.count / (1024*1024)) MB", level: .info)
    }

    // MARK: - Private: Pipeline

    /// Initializes the StableDiffusionPipeline from downloaded model files.
    private func loadPipeline() async {
        state = .loading
        DebugLogger.shared.log("🔄 Loading SD pipeline...", level: .info)

        do {
            let resourceURL = modelsDirectory
            let config = MLModelConfiguration()
            config.computeUnits = .cpuAndNeuralEngine // Best balance for iOS

            let pipe = try await Task.detached(priority: .userInitiated) {
                try StableDiffusionPipeline(
                    resourcesAt: resourceURL,
                    controlNet: [],
                    configuration: config,
                    reduceMemory: true // Critical for iOS — keeps peak RAM manageable
                )
            }.value

            try pipe.loadResources()

            self.pipeline = pipe
            state = .ready
            DebugLogger.shared.log("✅ SD pipeline loaded and ready", level: .success)
        } catch {
            state = .error(message: error.localizedDescription)
            DebugLogger.shared.log("❌ SD pipeline load failed: \(error.localizedDescription)", level: .error)
        }
    }

    // MARK: - Private: Image Utils

    /// Resizes an image to 512×512 (SD 2.1 native resolution).
    private func resizeTo512(_ image: UIImage) -> CGImage? {
        let size = CGSize(width: 512, height: 512)
        let renderer = UIGraphicsImageRenderer(size: size)
        let resized = renderer.image { _ in
            image.draw(in: CGRect(origin: .zero, size: size))
        }
        return resized.cgImage
    }

    /// Scales a generated image back to match the target's dimensions.
    private func scaleToMatch(_ generated: UIImage, target: UIImage) -> UIImage {
        let renderer = UIGraphicsImageRenderer(size: target.size)
        return renderer.image { _ in
            generated.draw(in: CGRect(origin: .zero, size: target.size))
        }
    }
}

// MARK: - Errors

enum StableDiffusionError: LocalizedError {
    case httpError(statusCode: Int)
    case pipelineNotLoaded
    case generationFailed(String)

    var errorDescription: String? {
        switch self {
        case .httpError(let code):
            return "Error HTTP \(code) al descargar modelo SD."
        case .pipelineNotLoaded:
            return "El pipeline de Stable Diffusion no está cargado."
        case .generationFailed(let detail):
            return "Generación fallida: \(detail)"
        }
    }
}
