// ScannerView.swift
// StyleAI — AI-Powered Garment Scanner
//
// Captures garment photos via camera or photo library.
// Uses VisionAIService for automatic garment classification,
// then lets the user verify and save to SwiftData.

import SwiftUI
import SwiftData
import PhotosUI

// MARK: - Scanner View

struct ScannerView: View {

    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss

    // Photo capture
    @State private var showCamera = false
    @State private var showPhotoPicker = false
    @State private var photoPickerItem: PhotosPickerItem?
    @State private var capturedImage: UIImage?

    // Classification form
    @State private var garmentName = ""
    @State private var selectedType: GarmentType = .top
    @State private var thermalIndex: Double = 0.5
    @State private var selectedTags: Set<String> = []
    @State private var material = ""

    // AI classification
    @State private var isClassifying = false
    @State private var aiConfidence: Float = 0
    @State private var dominantColorHex: String?

    // UI state
    @State private var isSaving = false
    @State private var showSavedToast = false
    @State private var showingForm = false

    private let availableTags = [
        "Casual", "Formal", "Deportivo", "Elegante",
        "Streetwear", "Bohemio", "Clásico", "Moderno"
    ]

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
                        // Capture phase
                        captureSection
                    } else {
                        // Classification phase
                        classificationSection
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
                Task { await classifyWithAI(newImage) }
            }
        }
    }

    // MARK: - Capture Section

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
                Text("Escanea tu Prenda")
                    .font(StyleTypography.title)
                    .foregroundStyle(.white)

                Text("Toma una foto o selecciona de tu galería\npara añadirla a tu armario virtual")
                    .font(StyleTypography.subheadline)
                    .foregroundStyle(StyleColors.textSecondary)
                    .multilineTextAlignment(.center)
            }

            // Action buttons
            VStack(spacing: StyleSpacing.md) {
                // Camera button
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

                // Photo library picker
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
                tipRow(icon: "checkmark.circle", text: "Fondo liso y bien iluminado")
                tipRow(icon: "checkmark.circle", text: "Prenda extendida y visible completa")
                tipRow(icon: "checkmark.circle", text: "Sin personas en la foto")
            }
            .padding(StyleSpacing.lg)
            .glassCard()
        }
    }

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

    // MARK: - Classification Section

    private var classificationSection: some View {
        VStack(spacing: StyleSpacing.xl) {
            // Image preview
            if let image = capturedImage {
                ZStack(alignment: .topTrailing) {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFit()
                        .clipShape(RoundedRectangle(cornerRadius: 20))
                        .shadow(color: .black.opacity(0.4), radius: 15, y: 8)
                        .frame(maxHeight: 300)

                    // Retake button
                    Button {
                        withAnimation(StyleAnimation.springSnappy) {
                            capturedImage = nil
                            photoPickerItem = nil
                        }
                    } label: {
                        Image(systemName: "arrow.triangle.2.circlepath.camera")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(.white)
                            .padding(10)
                            .background(.ultraThinMaterial, in: Circle())
                    }
                    .padding(12)
                }
            }

            // AI Classification Badge
            if isClassifying {
                HStack(spacing: StyleSpacing.sm) {
                    ProgressView()
                        .tint(StyleColors.accentMint)
                    Text("Analizando con Vision AI...")
                        .font(StyleTypography.caption)
                        .foregroundStyle(StyleColors.accentMint)
                }
                .padding(StyleSpacing.md)
                .glassCard(cornerRadius: 12)
            } else if aiConfidence > 0 {
                HStack(spacing: StyleSpacing.sm) {
                    Image(systemName: "brain.head.profile")
                        .font(.system(size: 14))
                        .foregroundStyle(StyleColors.accentMint)

                    Text("IA: \(selectedType.label)")
                        .font(StyleTypography.caption)
                        .foregroundStyle(.white)

                    Text("\(Int(aiConfidence * 100))% confianza")
                        .font(StyleTypography.captionMono)
                        .foregroundStyle(aiConfidence > 0.5 ? .green : .yellow)

                    if let hex = dominantColorHex {
                        Circle()
                            .fill(Color(hex: hex))
                            .frame(width: 14, height: 14)
                            .overlay(Circle().stroke(.white.opacity(0.3), lineWidth: 0.5))
                    }
                }
                .padding(StyleSpacing.md)
                .glassCard(cornerRadius: 12)
            }

            // Classification form
            VStack(spacing: StyleSpacing.lg) {
                // Name field
                VStack(alignment: .leading, spacing: StyleSpacing.xs) {
                    Text("Nombre de la Prenda")
                        .font(StyleTypography.caption)
                        .foregroundStyle(StyleColors.textSecondary)

                    TextField("Ej: Camiseta Azul", text: $garmentName)
                        .font(StyleTypography.body)
                        .foregroundStyle(.white)
                        .padding(StyleSpacing.md)
                        .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 10))
                        .autocorrectionDisabled()
                }

                // Type picker
                VStack(alignment: .leading, spacing: StyleSpacing.xs) {
                    Text("Tipo de Prenda")
                        .font(StyleTypography.caption)
                        .foregroundStyle(StyleColors.textSecondary)

                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: StyleSpacing.sm) {
                            ForEach(GarmentType.allCases) { type in
                                typeChip(type)
                            }
                        }
                    }
                }

                // Thermal slider
                VStack(alignment: .leading, spacing: StyleSpacing.xs) {
                    HStack {
                        Text("Índice Térmico")
                            .font(StyleTypography.caption)
                            .foregroundStyle(StyleColors.textSecondary)

                        Spacer()

                        Text(thermalLabel)
                            .font(StyleTypography.caption)
                            .foregroundStyle(thermalColor)
                    }

                    HStack(spacing: StyleSpacing.sm) {
                        Image(systemName: "snowflake")
                            .font(.system(size: 12))
                            .foregroundStyle(.blue)

                        Slider(value: $thermalIndex, in: 0...1, step: 0.05)
                            .tint(thermalColor)

                        Image(systemName: "sun.max.fill")
                            .font(.system(size: 12))
                            .foregroundStyle(.orange)
                    }
                }

                // Style tags
                VStack(alignment: .leading, spacing: StyleSpacing.xs) {
                    Text("Estilo")
                        .font(StyleTypography.caption)
                        .foregroundStyle(StyleColors.textSecondary)

                    FlowLayout(spacing: 8) {
                        ForEach(availableTags, id: \.self) { tag in
                            tagChip(tag)
                        }
                    }
                }

                // Material field
                VStack(alignment: .leading, spacing: StyleSpacing.xs) {
                    Text("Material (opcional)")
                        .font(StyleTypography.caption)
                        .foregroundStyle(StyleColors.textSecondary)

                    TextField("Ej: Algodón, Denim, Poliéster", text: $material)
                        .font(StyleTypography.body)
                        .foregroundStyle(.white)
                        .padding(StyleSpacing.md)
                        .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 10))
                        .autocorrectionDisabled()
                }
            }
            .padding(StyleSpacing.lg)
            .glassCard()

            // Save button
            Button {
                saveGarment()
            } label: {
                HStack(spacing: StyleSpacing.sm) {
                    if isSaving {
                        ProgressView()
                            .tint(.white)
                    } else {
                        Image(systemName: "checkmark.circle.fill")
                    }
                    Text(isSaving ? "Guardando..." : "Guardar en Armario")
                        .font(StyleTypography.headline)
                }
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity)
                .padding(.vertical, StyleSpacing.lg)
                .background(
                    canSave
                        ? AnyShapeStyle(StyleColors.brandGradient)
                        : AnyShapeStyle(Color.gray.opacity(0.3)),
                    in: RoundedRectangle(cornerRadius: StyleSpacing.buttonCornerRadius)
                )
            }
            .disabled(!canSave || isSaving)
        }
    }

    // MARK: - Components

    private func typeChip(_ type: GarmentType) -> some View {
        let isActive = selectedType == type
        return Button {
            withAnimation(StyleAnimation.springSnappy) {
                selectedType = type
            }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: type.icon)
                    .font(.system(size: 11))
                Text(type.label)
                    .font(StyleTypography.caption)
            }
            .foregroundStyle(isActive ? .white : StyleColors.textSecondary)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(
                isActive
                    ? AnyShapeStyle(StyleColors.primaryMid.opacity(0.6))
                    : AnyShapeStyle(Color.white.opacity(0.06)),
                in: Capsule()
            )
        }
        .buttonStyle(.plain)
    }

    private func tagChip(_ tag: String) -> some View {
        let isActive = selectedTags.contains(tag)
        return Button {
            withAnimation(StyleAnimation.springSnappy) {
                if isActive {
                    selectedTags.remove(tag)
                } else {
                    selectedTags.insert(tag)
                }
            }
        } label: {
            Text(tag)
                .font(StyleTypography.caption)
                .foregroundStyle(isActive ? .white : StyleColors.textSecondary)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(
                    isActive
                        ? AnyShapeStyle(StyleColors.accentRose.opacity(0.5))
                        : AnyShapeStyle(Color.white.opacity(0.06)),
                    in: Capsule()
                )
        }
        .buttonStyle(.plain)
    }

    private var savedToast: some View {
        VStack {
            Spacer()
            HStack(spacing: StyleSpacing.sm) {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                Text("¡Prenda guardada!")
                    .font(StyleTypography.headline)
                    .foregroundStyle(.white)
            }
            .padding(.horizontal, StyleSpacing.xl)
            .padding(.vertical, StyleSpacing.md)
            .glassCard(cornerRadius: StyleSpacing.pillCornerRadius)
            .padding(.bottom, 80)
        }
        .transition(.move(edge: .bottom).combined(with: .opacity))
    }

    // MARK: - Computed

    private var canSave: Bool {
        capturedImage != nil && !garmentName.trimmingCharacters(in: .whitespaces).isEmpty
    }

    private var thermalLabel: String {
        switch thermalIndex {
        case ..<0.25:     return "Frío"
        case 0.25..<0.50: return "Templado"
        case 0.50..<0.75: return "Cálido"
        default:          return "Caluroso"
        }
    }

    private var thermalColor: Color {
        switch thermalIndex {
        case ..<0.25:     return .blue
        case 0.25..<0.50: return .green
        case 0.50..<0.75: return .orange
        default:          return .red
        }
    }

    // MARK: - Actions

    private func loadFromPicker(_ item: PhotosPickerItem?) async {
        guard let item else { return }
        if let data = try? await item.loadTransferable(type: Data.self),
           let image = UIImage(data: data) {
            capturedImage = image
            DebugLogger.shared.log("📷 Scanner: Photo loaded from gallery", level: .info)
        }
    }

    /// Runs Vision AI classification on a captured garment photo.
    /// Auto-fills type, thermal index, tags, and dominant color.
    private func classifyWithAI(_ image: UIImage) async {
        isClassifying = true
        DebugLogger.shared.log("🧠 Scanner: Running AI classification...", level: .info)

        if let classification = await VisionAIService.shared.classifyGarment(image) {
            withAnimation(StyleAnimation.springSmooth) {
                selectedType = classification.suggestedType
                thermalIndex = classification.suggestedThermalIndex
                aiConfidence = classification.confidence

                // Auto-select suggested tags
                for tag in classification.suggestedTags {
                    if availableTags.contains(tag) {
                        selectedTags.insert(tag)
                    }
                }
            }

            DebugLogger.shared.log("✅ Scanner: AI classified as \(classification.suggestedType.label) (\(Int(classification.confidence * 100))%)", level: .success)
        } else {
            DebugLogger.shared.log("⚠️ Scanner: AI classification returned no results", level: .warning)
        }

        // Extract dominant color
        if let color = VisionAIService.shared.extractDominantColor(from: image) {
            dominantColorHex = color.hexString
        }

        isClassifying = false
    }

    private func saveGarment() {
        guard let image = capturedImage,
              let imageData = image.jpegData(compressionQuality: 0.85) else { return }

        isSaving = true
        DebugLogger.shared.log("💾 Saving garment: \(garmentName)", level: .info)

        // Create thumbnail
        let thumbnailSize = CGSize(width: 256, height: 256)
        let renderer = UIGraphicsImageRenderer(size: thumbnailSize)
        let thumbnail = renderer.image { _ in
            image.draw(in: CGRect(origin: .zero, size: thumbnailSize))
        }

        // Map GarmentType to slot
        let garmentType: GarmentType = selectedType

        let item = WardrobeItem(
            imageData: imageData,
            type: garmentType,
            thermalIndex: thermalIndex,
            styleTags: Array(selectedTags),
            material: material.isEmpty ? nil : material
        )
        item.thumbnailData = thumbnail.jpegData(compressionQuality: 0.6)

        modelContext.insert(item)

        do {
            try modelContext.save()
            DebugLogger.shared.log("✅ Garment saved: \(garmentName) (\(garmentType.label))", level: .success)
        } catch {
            DebugLogger.shared.log("❌ Save failed: \(error.localizedDescription)", level: .error)
        }

        isSaving = false

        withAnimation(StyleAnimation.springSmooth) {
            showSavedToast = true
        }

        Task {
            try? await Task.sleep(for: .seconds(2))
            withAnimation(StyleAnimation.springSmooth) {
                showSavedToast = false
            }
            try? await Task.sleep(for: .seconds(0.5))
            // Reset for next scan
            capturedImage = nil
            photoPickerItem = nil
            garmentName = ""
            selectedType = .top
            thermalIndex = 0.5
            selectedTags = []
            material = ""
        }
    }
}

// MARK: - Flow Layout

/// Simple flow layout for wrapping tag chips.
struct FlowLayout: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let result = layoutSubviews(proposal: proposal, subviews: subviews)
        return result.size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let result = layoutSubviews(proposal: proposal, subviews: subviews)
        for (index, position) in result.positions.enumerated() {
            subviews[index].place(at: CGPoint(x: bounds.minX + position.x, y: bounds.minY + position.y), proposal: .unspecified)
        }
    }

    private func layoutSubviews(proposal: ProposedViewSize, subviews: Subviews) -> (size: CGSize, positions: [CGPoint]) {
        let maxWidth = proposal.width ?? .infinity
        var positions: [CGPoint] = []
        var currentX: CGFloat = 0
        var currentY: CGFloat = 0
        var lineHeight: CGFloat = 0
        var maxX: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if currentX + size.width > maxWidth && currentX > 0 {
                currentX = 0
                currentY += lineHeight + spacing
                lineHeight = 0
            }
            positions.append(CGPoint(x: currentX, y: currentY))
            lineHeight = max(lineHeight, size.height)
            currentX += size.width + spacing
            maxX = max(maxX, currentX)
        }

        return (CGSize(width: maxX, height: currentY + lineHeight), positions)
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
