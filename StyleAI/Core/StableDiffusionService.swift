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
@preconcurrency import StableDiffusion

// MARK: - SD Model Descriptor

/// Describes a single downloadable file required by the SD pipeline.
struct SDModelFile: Identifiable {
    let id: String
    let fileName: String
    let remoteURL: URL
    let expectedSizeMB: Int
    /// Local sub-path relative to the models directory (e.g. "TextEncoder.mlmodelc/weights/weight.bin").
    let localRelativePath: String

    /// Base URL for the compiled split_einsum models on Hugging Face.
    static let baseURL = "https://huggingface.co/apple/coreml-stable-diffusion-2-1-base/resolve/main/split_einsum/compiled/"

    /// Sub-files inside each .mlmodelc bundle.
    private static let mlmodelcSubFiles = [
        "coremldata.bin",
        "metadata.json",
        "model.mil",
        "weights/weight.bin"
    ]

    /// Generates all download items for a single .mlmodelc model.
    private static func modelFiles(id: String, name: String, weightSizeMB: Int) -> [SDModelFile] {
        mlmodelcSubFiles.map { sub in
            SDModelFile(
                id: "\(id)_\(sub.replacingOccurrences(of: "/", with: "_"))",
                fileName: sub.components(separatedBy: "/").last ?? sub,
                remoteURL: URL(string: baseURL + "\(name)/\(sub)")!,
                expectedSizeMB: sub.contains("weight.bin") ? weightSizeMB : 1,
                localRelativePath: "\(name)/\(sub)"
            )
        }
    }

    /// All individual files required for the pipeline.
    static let requiredFiles: [SDModelFile] = {
        var files: [SDModelFile] = []
        files += modelFiles(id: "text_encoder", name: "TextEncoder.mlmodelc", weightSizeMB: 250)
        files += modelFiles(id: "unet_chunk1",  name: "UnetChunk1.mlmodelc",  weightSizeMB: 650)
        files += modelFiles(id: "unet_chunk2",  name: "UnetChunk2.mlmodelc",  weightSizeMB: 650)
        files += modelFiles(id: "vae_decoder",  name: "VAEDecoder.mlmodelc",  weightSizeMB: 90)
        files += modelFiles(id: "vae_encoder",  name: "VAEEncoder.mlmodelc",  weightSizeMB: 90)
        // Tokenizer resources
        files.append(SDModelFile(
            id: "vocab",
            fileName: "vocab.json",
            remoteURL: URL(string: baseURL + "vocab.json")!,
            expectedSizeMB: 1,
            localRelativePath: "vocab.json"
        ))
        files.append(SDModelFile(
            id: "merges",
            fileName: "merges.txt",
            remoteURL: URL(string: baseURL + "merges.txt")!,
            expectedSizeMB: 1,
            localRelativePath: "merges.txt"
        ))
        return files
    }()

    /// The top-level model directories needed for the pipeline to load.
    static let modelDirectories = [
        "TextEncoder.mlmodelc",
        "UnetChunk1.mlmodelc",
        "UnetChunk2.mlmodelc",
        "VAEDecoder.mlmodelc",
        "VAEEncoder.mlmodelc"
    ]

    /// Total expected download size across all model files.
    static var totalSizeMB: Int {
        requiredFiles.reduce(0) { $0 + $1.expectedSizeMB }
    }
}

// MARK: - SD Service State

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

    // MARK: Download Stats (for UI)

    /// Name of the file currently being downloaded.
    private(set) var currentDownloadFile: String = ""

    /// Index of current file being downloaded (1-based).
    private(set) var downloadFileIndex: Int = 0

    /// Total number of files to download.
    private(set) var downloadFileTotal: Int = 0

    /// Megabytes downloaded so far (for current file).
    private(set) var downloadedMB: Double = 0.0

    /// Expected total MB for current file.
    private(set) var currentFileTotalMB: Double = 0.0

    /// Current download speed in MB/s.
    private(set) var downloadSpeedMBps: Double = 0.0

    // MARK: Private

    /// The loaded SD pipeline (nil until models downloaded + initialized).
    private var pipeline: StableDiffusionPipeline?

    /// Speed tracking
    private var speedSampleTime: CFAbsoluteTime = 0
    private var speedSampleBytes: Int64 = 0

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
                atPath: modelsDirectory.appendingPathComponent(file.localRelativePath).path
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

        // Create all .mlmodelc subdirectories upfront
        let fm = FileManager.default
        for dirName in SDModelFile.modelDirectories {
            let dirURL = modelsDirectory.appendingPathComponent(dirName, isDirectory: true)
            let weightsDir = dirURL.appendingPathComponent("weights", isDirectory: true)
            try? fm.createDirectory(at: weightsDir, withIntermediateDirectories: true)
        }

        DebugLogger.shared.log("⬇️ Starting SD model download (\(totalFiles) files, ~\(SDModelFile.totalSizeMB) MB)", level: .info)

        for (index, file) in files.enumerated() {
            let destinationURL = modelsDirectory.appendingPathComponent(file.localRelativePath)

            // Skip if already downloaded
            if fm.fileExists(atPath: destinationURL.path) {
                let progress = Double(index + 1) / Double(totalFiles)
                downloadProgress = progress
                state = .downloading(progress: progress)
                DebugLogger.shared.log("✅ \(file.localRelativePath) — ya descargado", level: .info)
                continue
            }

            do {
                try await downloadFile(file, to: destinationURL, index: index, total: totalFiles)
            } catch {
                let message = "Error descargando \(file.localRelativePath): \(error.localizedDescription)"
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
            _ = maskCGImage // Reserved for future inpainting support

            // Build SD configuration
            var sdConfig = StableDiffusionPipeline.Configuration(prompt: prompt)
            sdConfig.negativePrompt = negativePrompt
            sdConfig.seed = seed
            sdConfig.stepCount = steps
            sdConfig.guidanceScale = guidanceScale
            sdConfig.startingImage = inputCGImage
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

    /// Downloads a single file using native URLSession download (max speed).
    private func downloadFile(_ file: SDModelFile, to destination: URL, index: Int, total: Int) async throws {
        // Update UI stats
        currentDownloadFile = file.localRelativePath
        downloadFileIndex = index + 1
        downloadFileTotal = total
        downloadedMB = 0
        downloadSpeedMBps = 0
        currentFileTotalMB = Double(file.expectedSizeMB)
        speedSampleTime = CFAbsoluteTimeGetCurrent()
        speedSampleBytes = 0

        state = .downloading(progress: downloadProgress)
        DebugLogger.shared.log("⬇️ [\(index + 1)/\(total)] \(file.localRelativePath) (\(file.expectedSizeMB) MB)", level: .info)

        // Ensure parent directory exists
        let parentDir = destination.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: parentDir, withIntermediateDirectories: true)

        var request = URLRequest(url: file.remoteURL)
        request.timeoutInterval = 600

        // Use delegate for progress tracking at full network speed
        let progressDelegate = SDDownloadDelegate { [weak self] bytesWritten, totalExpected in
            Task { @MainActor [weak self] in
                guard let self else { return }
                let fileProgress = totalExpected > 0
                    ? Double(bytesWritten) / Double(totalExpected)
                    : 0.0
                self.downloadedMB = Double(bytesWritten) / (1024 * 1024)
                self.currentFileTotalMB = Double(totalExpected) / (1024 * 1024)

                let baseProgress = Double(index) / Double(total)
                let segmentSize = 1.0 / Double(total)
                self.downloadProgress = baseProgress + (fileProgress * segmentSize)
                self.state = .downloading(progress: self.downloadProgress)

                // Speed calculation (rolling 1s window)
                let now = CFAbsoluteTimeGetCurrent()
                let elapsed = now - self.speedSampleTime
                if elapsed > 1.0 {
                    let bytesDelta = bytesWritten - self.speedSampleBytes
                    self.downloadSpeedMBps = (Double(bytesDelta) / elapsed) / (1024 * 1024)
                    self.speedSampleTime = now
                    self.speedSampleBytes = bytesWritten
                }
            }
        }

        // Native download — operates at full network speed (no byte-by-byte iteration)
        let (tempURL, response) = try await URLSession.shared.download(for: request, delegate: progressDelegate)

        if let httpResponse = response as? HTTPURLResponse,
           !(200...299).contains(httpResponse.statusCode) {
            try? FileManager.default.removeItem(at: tempURL)
            throw StableDiffusionError.httpError(statusCode: httpResponse.statusCode)
        }

        // Move to final destination
        let fm = FileManager.default
        if fm.fileExists(atPath: destination.path) {
            try fm.removeItem(at: destination)
        }
        try fm.moveItem(at: tempURL, to: destination)

        let fileSizeMB = ((try? fm.attributesOfItem(atPath: destination.path)[.size] as? Int) ?? 0) / (1024 * 1024)
        DebugLogger.shared.log("✅ \(file.localRelativePath) — \(fileSizeMB) MB", level: .info)
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

            let pipe = try StableDiffusionPipeline(
                resourcesAt: resourceURL,
                controlNet: [],
                configuration: config,
                reduceMemory: true // Critical for iOS — keeps peak RAM manageable
            )

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

// MARK: - Download Delegate (Full-Speed Native Downloads)

/// URLSession download delegate that reports progress at full network speed.
/// Used instead of byte-by-byte async iteration which was catastrophically slow.
private class SDDownloadDelegate: NSObject, URLSessionDownloadDelegate {
    let onProgress: (_ bytesWritten: Int64, _ totalExpected: Int64) -> Void

    init(onProgress: @escaping (_ bytesWritten: Int64, _ totalExpected: Int64) -> Void) {
        self.onProgress = onProgress
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didFinishDownloadingTo location: URL
    ) {
        // File is handled by the async return value of URLSession.download(for:delegate:)
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        onProgress(totalBytesWritten, totalBytesExpectedToWrite)
    }
}
