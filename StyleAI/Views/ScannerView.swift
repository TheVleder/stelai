// ScannerView.swift
// StyleAI — AI-Powered Auto Garment Scanner
//
// Captures garment photos via camera or photo library.
// VisionAI automatically detects garment type, crops the garment region,
// and saves it to SwiftData — no manual input needed.

import SwiftUI
import SwiftData
import PhotosUI

// MARK: - Detected Garment (for preview before auto-save)

/// A garment detected + cropped from the scanned photo.
struct DetectedGarment: Identifiable {
    let id = UUID()
    let type: GarmentType
    let croppedImage: UIImage
    let thumbnail: UIImage
    let confidence: Float
    let thermalIndex: Double
    let styleTags: [String]
    let dominantColor: String?
    var saved: Bool = false
}

// MARK: - Scanner View

struct ScannerView: View {

    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss

    // Photo capture
    @State private var showCamera = false
    @State private var showPhotoPicker = false
    @State private var photoPickerItem: PhotosPickerItem?
    @State private var capturedImage: UIImage?

    // AI processing
    @State private var isProcessing = false
    @State private var detectedGarments: [DetectedGarment] = []
    @State private var scanComplete = false

    // UI state
    @State private var showSavedToast = false
    @State private var savedCount = 0

    var body: some View {
        ZStack {
            // Background
            LinearGradient(
                colors: [
                    StyleColors.surfacePrimary,
                    Color(hue: 0.93, saturation: 0.15, brightness: 0.08)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            .ignoresSafeArea()

            ScrollView {
                VStack(spacing: StyleSpacing.xl) {
                    if capturedImage == nil {
                        // Phase 1: Capture
                        captureSection
                    } else if isProcessing {
                        // Phase 2: AI Processing
                        processingSection
                    } else if scanComplete {
                        // Phase 3: Results
                        resultsSection
                    }
                }
                .padding(.horizontal, StyleSpacing.lg)
                .padding(.vertical, StyleSpacing.xl)
            }

            // Saved toast
            if showSavedToast {
                savedToast
            }
        }
        .navigationTitle("Escanear Prenda")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(.ultraThinMaterial, for: .navigationBar)
        .sheet(isPresented: $showCamera) {
            ImagePickerView(image: $capturedImage, sourceType: .camera)
                .ignoresSafeArea()
        }
        .onChange(of: photoPickerItem) { _, newItem in
            Task { await loadFromPicker(newItem) }
        }
        .onChange(of: capturedImage) { _, newImage in
            if let newImage {
                Task { await autoDetectAndSave(newImage) }
            }
        }
    }

    // MARK: - Phase 1: Capture Section

    private var captureSection: some View {
        VStack(spacing: StyleSpacing.xxl) {
            Spacer().frame(height: 40)

            // Hero illustration
            ZStack {
                Circle()
                    .fill(StyleColors.accentRose.opacity(0.15))
                    .frame(width: 160, height: 160)
                    .blur(radius: 40)

                Image(systemName: "camera.viewfinder")
                    .font(.system(size: 64, weight: .light))
                    .foregroundStyle(
                        LinearGradient(
                            colors: [StyleColors.accentRose, StyleColors.accentGold],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
            }

            VStack(spacing: StyleSpacing.sm) {
                Text("Escanea tu Outfit")
                    .font(StyleTypography.title)
                    .foregroundStyle(.white)

                Text("Toma una foto y la IA detectará\nautomáticamente cada prenda")
                    .font(StyleTypography.subheadline)
                    .foregroundStyle(StyleColors.textSecondary)
                    .multilineTextAlignment(.center)
            }

            // Action buttons
            VStack(spacing: StyleSpacing.md) {
                Button {
                    showCamera = true
                } label: {
                    HStack(spacing: StyleSpacing.md) {
                        Image(systemName: "camera.fill")
                            .font(.system(size: 20))
                        Text("Abrir Cámara")
                            .font(StyleTypography.headline)
                    }
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, StyleSpacing.lg)
                    .background(
                        LinearGradient(
                            colors: [StyleColors.accentRose, StyleColors.accentGold],
                            startPoint: .leading,
                            endPoint: .trailing
                        ),
                        in: RoundedRectangle(cornerRadius: StyleSpacing.buttonCornerRadius)
                    )
                    .shadow(color: StyleColors.accentRose.opacity(0.3), radius: 12, y: 6)
                }

                PhotosPicker(selection: $photoPickerItem, matching: .images) {
                    HStack(spacing: StyleSpacing.md) {
                        Image(systemName: "photo.on.rectangle")
                            .font(.system(size: 20))
                        Text("Seleccionar de Galería")
                            .font(StyleTypography.headline)
                    }
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, StyleSpacing.lg)
                    .glassCard(cornerRadius: StyleSpacing.buttonCornerRadius)
                }
            }

            // Tips
            VStack(alignment: .leading, spacing: StyleSpacing.sm) {
                tipRow(icon: "sparkles", text: "La IA detecta: top, pantalón y zapatillas")
                tipRow(icon: "scissors", text: "Cada prenda se recorta automáticamente")
                tipRow(icon: "tray.and.arrow.down", text: "Se guardan sin que toques nada")
            }
            .padding(StyleSpacing.lg)
            .glassCard()
        }
    }

    // MARK: - Phase 2: Processing

    private var processingSection: some View {
        VStack(spacing: StyleSpacing.xxl) {
            Spacer().frame(height: 60)

            // Original image preview (small)
            if let image = capturedImage {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFit()
                    .frame(maxHeight: 200)
                    .clipShape(RoundedRectangle(cornerRadius: 16))
                    .overlay(
                        RoundedRectangle(cornerRadius: 16)
                            .stroke(StyleColors.accentMint.opacity(0.3), lineWidth: 1)
                    )
            }

            // Processing indicator
            VStack(spacing: StyleSpacing.md) {
                ProgressView()
                    .controlSize(.large)
                    .tint(StyleColors.accentMint)

                Text("Analizando outfit...")
                    .font(StyleTypography.headline)
                    .foregroundStyle(.white)

                Text("Detectando y recortando prendas con Vision AI")
                    .font(StyleTypography.caption)
                    .foregroundStyle(StyleColors.textSecondary)
            }
            .padding(StyleSpacing.xl)
            .glassCard()

            Spacer()
        }
    }

    // MARK: - Phase 3: Results

    private var resultsSection: some View {
        VStack(spacing: StyleSpacing.xl) {
            // Summary header
            HStack(spacing: StyleSpacing.sm) {
                Image(systemName: "checkmark.seal.fill")
                    .font(.system(size: 20))
                    .foregroundStyle(StyleColors.accentMint)

                Text("\(detectedGarments.count) prenda\(detectedGarments.count == 1 ? "" : "s") detectada\(detectedGarments.count == 1 ? "" : "s")")
                    .font(StyleTypography.headline)
                    .foregroundStyle(.white)
            }

            // Original photo
            if let image = capturedImage {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFit()
                    .frame(maxHeight: 200)
                    .clipShape(RoundedRectangle(cornerRadius: 16))
                    .shadow(color: .black.opacity(0.3), radius: 10, y: 5)
            }

            // Detected garments grid
            ForEach(detectedGarments) { garment in
                detectedGarmentCard(garment)
            }

            // Action buttons
            VStack(spacing: StyleSpacing.md) {
                // Scan another
                Button {
                    resetScanner()
                } label: {
                    HStack(spacing: StyleSpacing.md) {
                        Image(systemName: "camera.viewfinder")
                            .font(.system(size: 18))
                        Text("Escanear Otro Outfit")
                            .font(StyleTypography.headline)
                    }
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, StyleSpacing.lg)
                    .background(
                        LinearGradient(
                            colors: [StyleColors.accentRose, StyleColors.accentGold],
                            startPoint: .leading,
                            endPoint: .trailing
                        ),
                        in: RoundedRectangle(cornerRadius: StyleSpacing.buttonCornerRadius)
                    )
                }

                // Go to Probador
                Button {
                    dismiss()
                } label: {
                    HStack(spacing: StyleSpacing.md) {
                        Image(systemName: "person.crop.rectangle.stack")
                            .font(.system(size: 18))
                        Text("Ir al Probador Virtual")
                            .font(StyleTypography.headline)
                    }
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, StyleSpacing.lg)
                    .glassCard(cornerRadius: StyleSpacing.buttonCornerRadius)
                }
            }
        }
    }

    // MARK: - Detected Garment Card

    private func detectedGarmentCard(_ garment: DetectedGarment) -> some View {
        HStack(spacing: StyleSpacing.lg) {
            // Cropped garment thumbnail
            Image(uiImage: garment.thumbnail)
                .resizable()
                .scaledToFill()
                .frame(width: 80, height: 80)
                .clipShape(RoundedRectangle(cornerRadius: 12))
                .overlay(
                    RoundedRectangle(cornerRadius: 12)
                        .stroke(Color.white.opacity(0.1), lineWidth: 1)
                )

            // Info
            VStack(alignment: .leading, spacing: StyleSpacing.xs) {
                HStack(spacing: StyleSpacing.sm) {
                    Image(systemName: garment.type.icon)
                        .font(.system(size: 14))
                        .foregroundStyle(slotColor(for: garment.type))

                    Text(garment.type.label)
                        .font(StyleTypography.headline)
                        .foregroundStyle(.white)
                }

                HStack(spacing: StyleSpacing.sm) {
                    Text("\(Int(garment.confidence * 100))% confianza")
                        .font(StyleTypography.captionMono)
                        .foregroundStyle(garment.confidence > 0.5 ? .green : .yellow)

                    if let color = garment.dominantColor {
                        Circle()
                            .fill(Color(hex: color))
                            .frame(width: 12, height: 12)
                            .overlay(Circle().stroke(.white.opacity(0.3), lineWidth: 0.5))
                    }
                }

                // Tags
                HStack(spacing: 4) {
                    ForEach(garment.styleTags, id: \.self) { tag in
                        Text(tag)
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(StyleColors.textSecondary)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color.white.opacity(0.06), in: Capsule())
                    }
                }
            }

            Spacer()

            // Saved indicator
            Image(systemName: garment.saved ? "checkmark.circle.fill" : "circle")
                .font(.system(size: 20))
                .foregroundStyle(garment.saved ? .green : StyleColors.textTertiary)
        }
        .padding(StyleSpacing.md)
        .glassCard()
    }

    // MARK: - Helpers

    private func tipRow(icon: String, text: String) -> some View {
        HStack(spacing: StyleSpacing.sm) {
            Image(systemName: icon)
                .font(.system(size: 12))
                .foregroundStyle(StyleColors.accentMint)
            Text(text)
                .font(StyleTypography.footnote)
                .foregroundStyle(StyleColors.textSecondary)
        }
    }

    private var savedToast: some View {
        VStack {
            Spacer()
            HStack(spacing: StyleSpacing.sm) {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                Text("\(savedCount) prenda\(savedCount == 1 ? "" : "s") guardada\(savedCount == 1 ? "" : "s") en tu armario")
                    .font(StyleTypography.subheadline)
                    .foregroundStyle(.white)
            }
            .padding(StyleSpacing.lg)
            .background(.ultraThinMaterial, in: Capsule())
            .padding(.bottom, 40)
        }
        .transition(.move(edge: .bottom).combined(with: .opacity))
    }

    private func slotColor(for type: GarmentType) -> Color {
        switch type {
        case .top:       return StyleColors.primaryMid
        case .bottom:    return StyleColors.accentRose
        case .shoes:     return StyleColors.accentGold
        case .outerwear: return StyleColors.info
        default:         return StyleColors.accentMint
        }
    }

    // MARK: - AI Auto-Detect Pipeline

    private func loadFromPicker(_ item: PhotosPickerItem?) async {
        guard let item else { return }
        do {
            if let data = try await item.loadTransferable(type: Data.self),
               let image = UIImage(data: data) {
                capturedImage = image
            }
        } catch {
            DebugLogger.shared.log("❌ Scanner: Photo load failed: \(error.localizedDescription)", level: .error)
        }
    }

    /// Main auto-detection pipeline: classify → crop → save for each valid type
    private func autoDetectAndSave(_ image: UIImage) async {
        isProcessing = true
        scanComplete = false
        detectedGarments = []
        DebugLogger.shared.log("🔍 Scanner: Starting auto-detect pipeline...", level: .info)

        let visionAI = VisionAIService.shared

        // Get the person's mask to cleanly separate the background
        let personMask = await visionAI.segmentPerson(from: image)

        // Step 1: Classify the image to detect what type of garment it is
        let classification = await visionAI.classifyGarment(image)

        // Step 2: Determine which garment types to extract
        let typesToExtract: [GarmentType]

        if personMask != nil {
            // User uploaded a photo of themselves — extract the full outfit
            typesToExtract = [.top, .bottom, .shoes]
        } else if let classification {
            let detected = classification.suggestedType

            if detected == .fullBody || detected == .accessory {
                typesToExtract = [.top, .bottom, .shoes]
            } else {
                typesToExtract = [detected]
            }
        } else {
            typesToExtract = [.top, .bottom, .shoes]
        }

        // Step 3: For each type, crop + create garment
        for type in typesToExtract {
            let cropped = visionAI.cropSmartGarmentRegion(from: image, type: type, personMask: personMask)
            let thumbnail = visionAI.generateThumbnail(from: cropped)

            // Classify the cropped region for better accuracy
            let regionClass = await visionAI.classifyGarment(cropped)
            let thermalIndex = regionClass?.suggestedThermalIndex ?? 0.5
            let tags = regionClass?.suggestedTags ?? ["Casual"]
            let confidence = regionClass?.confidence ?? (classification?.confidence ?? 0.3)

            // Extract dominant color
            var dominantHex: String?
            if let color = visionAI.extractDominantColor(from: cropped) {
                dominantHex = color.hexString
            }

            let detected = DetectedGarment(
                type: type,
                croppedImage: cropped,
                thumbnail: thumbnail,
                confidence: confidence,
                thermalIndex: thermalIndex,
                styleTags: tags,
                dominantColor: dominantHex,
                saved: false
            )

            detectedGarments.append(detected)
        }

        // Step 4: Auto-save all detected garments to SwiftData
        var saved = 0
        for i in detectedGarments.indices {
            let garment = detectedGarments[i]

            guard let imageData = garment.croppedImage.jpegData(compressionQuality: 0.85),
                  let thumbData = garment.thumbnail.jpegData(compressionQuality: 0.6) else { continue }

            let item = WardrobeItem(
                imageData: imageData,
                type: garment.type,
                thermalIndex: garment.thermalIndex,
                styleTags: garment.styleTags,
                dominantColor: garment.dominantColor
            )
            item.thumbnailData = thumbData

            modelContext.insert(item)
            detectedGarments[i].saved = true
            saved += 1
        }

        do {
            try modelContext.save()
            DebugLogger.shared.log("✅ Scanner: Auto-saved \(saved) garments", level: .success)
        } catch {
            DebugLogger.shared.log("❌ Scanner: Save failed: \(error.localizedDescription)", level: .error)
        }

        savedCount = saved
        isProcessing = false
        scanComplete = true

        // Show toast
        withAnimation(StyleAnimation.springSmooth) {
            showSavedToast = true
        }
        Task {
            try? await Task.sleep(for: .seconds(3))
            withAnimation(StyleAnimation.springSmooth) {
                showSavedToast = false
            }
        }
    }

    private func resetScanner() {
        withAnimation(StyleAnimation.springSnappy) {
            capturedImage = nil
            photoPickerItem = nil
            detectedGarments = []
            scanComplete = false
            savedCount = 0
        }
    }
}

// MARK: - Image Picker (UIKit Bridge)

/// UIImagePickerController wrapper for camera capture.
struct ImagePickerView: UIViewControllerRepresentable {
    @Binding var image: UIImage?
    var sourceType: UIImagePickerController.SourceType = .camera

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let picker = UIImagePickerController()
        picker.sourceType = sourceType
        picker.delegate = context.coordinator
        picker.allowsEditing = true
        return picker
    }

    func updateUIViewController(_ uiViewController: UIImagePickerController, context: Context) {}

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    class Coordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
        let parent: ImagePickerView

        init(_ parent: ImagePickerView) {
            self.parent = parent
        }

        func imagePickerController(_ picker: UIImagePickerController, didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]) {
            let image = info[.editedImage] as? UIImage ?? info[.originalImage] as? UIImage
            parent.image = image
            picker.dismiss(animated: true)
        }

        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
            picker.dismiss(animated: true)
        }
    }
}

// MARK: - Preview

#Preview {
    NavigationStack {
        ScannerView()
    }
    .preferredColorScheme(.dark)
}
