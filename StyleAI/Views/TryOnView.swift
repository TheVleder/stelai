// TryOnView.swift
// StyleAI — Virtual Try-On Screen
//
// The core VTO experience:
// 1. User selects their full-body photo (PhotosPicker).
// 2. Three carousels let them pick a top, bottom, and shoes.
// 3. AI engine composites the garments onto the photo in real time.
//
// Layout: User photo on top, three carousels at the bottom.

import SwiftUI
import SwiftData
import PhotosUI

// MARK: - Try-On View

struct TryOnView: View {

    // MARK: State

    @State private var engine = TryOnEngine.shared
    @State private var sdService = StableDiffusionService.shared

    @Environment(\.modelContext) private var modelContext

    /// SwiftData query for wardrobe items (real scanned garments)
    @Query private var wardrobeItems: [WardrobeItem]

    /// User's selected photo.
    @State private var userPhoto: UIImage?

    /// PhotosPicker selection item.
    @State private var photoPickerItem: PhotosPickerItem?

    /// Currently selected garments per slot.
    @State private var selectedTop: CarouselGarment?
    @State private var selectedBottom: CarouselGarment?
    @State private var selectedShoes: CarouselGarment?

    /// Result image from the engine.
    @State private var compositeImage: UIImage?

    /// Animation states
    // Full screen expansion
    @State private var isFullScreen = false
    @State private var showSavedFeedback = false
    @State private var photoScale: CGFloat = 1.0
    @State private var isDownloadingSD = false
    @State private var processingRotation: Double = 0
    @State private var processingPulse = false
    @State private var processingDotIndex = 0

    @Environment(\.dismiss) private var dismiss

    /// File path for persisted user photo
    private static let photoURL: URL = {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        return docs.appendingPathComponent("StyleAI_userPhoto.jpg")
    }()

    // MARK: - Computed

    private var currentOutfit: OutfitSelection {
        OutfitSelection(top: selectedTop, bottom: selectedBottom, shoes: selectedShoes)
    }

    private var hasPhoto: Bool {
        userPhoto != nil
    }

    // MARK: - Body

    var body: some View {
        ZStack {
            // Background
            backgroundGradient

            VStack(spacing: 0) {
                // Photo area
                photoArea
                    .frame(maxHeight: .infinity)

                // Divider
                Rectangle()
                    .fill(Color.white.opacity(0.06))
                    .frame(height: 1)

                // Carousels
                carouselStack
            }

            // Processing overlay
            if engine.state.isProcessing {
                processingOverlay
            }

            // AI Generation overlay
            if case .generatingAI = engine.state {
                aiGenerationOverlay
            }

            // SD Download overlay
            if isDownloadingSD {
                sdDownloadOverlay
            }

            // Saved feedback
            if showSavedFeedback {
                savedToast
            }
            
            // Full Screen Overlay
            if isFullScreen, let image = compositeImage ?? userPhoto {
                fullScreenImageOverlay(image: image)
            }

            // Error overlay
            if case .error(let msg) = engine.state {
                errorOverlay(msg: msg)
            }
        }
        .navigationTitle("Probador Virtual")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(.ultraThinMaterial, for: .navigationBar)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                toolbarMenu
            }
        }
        .onChange(of: photoPickerItem) { _, newItem in
            Task { await loadPhoto(from: newItem) }
        }
        .onChange(of: selectedTop) { _, _ in triggerTryOn() }
        .onChange(of: selectedBottom) { _, _ in triggerTryOn() }
        .onChange(of: selectedShoes) { _, _ in triggerTryOn() }
        .onAppear { loadPersistedPhoto() }
    }

    // MARK: - Background

    private var backgroundGradient: some View {
        LinearGradient(
            colors: [
                StyleColors.surfacePrimary,
                Color(hue: 0.76, saturation: 0.18, brightness: 0.06)
            ],
            startPoint: .top,
            endPoint: .bottom
        )
        .ignoresSafeArea()
    }

    // MARK: - Photo Area

    private var photoArea: some View {
        GeometryReader { geo in
            ZStack {
                if let displayImage = compositeImage ?? userPhoto {
                    // Show user photo (with or without garments applied)
                    Image(uiImage: displayImage)
                        .resizable()
                        .scaledToFit()
                        .clipShape(RoundedRectangle(cornerRadius: 20))
                        .shadow(color: .black.opacity(0.3), radius: 20, y: 10)
                        .scaleEffect(photoScale) // Kept photoScale as it might be used for other animations
                        .padding(StyleSpacing.lg) // Kept padding as it defines the image's inset
                        .overlay(alignment: .bottomTrailing) {
                            if !engine.state.isProcessing {
                                photoOverlayBadges
                                    .padding(StyleSpacing.md)
                            }
                        }
                        .overlay(alignment: .topTrailing) {
                            if !engine.state.isProcessing {
                                Image(systemName: "arrows.out")
                                    .font(.system(size: 14, weight: .bold))
                                    .foregroundStyle(.white.opacity(0.8))
                                    .padding(12)
                                    .background(.ultraThinMaterial, in: Circle())
                                    .padding(StyleSpacing.md)
                            }
                        }
                        .transition(.opacity.combined(with: .scale(scale: 0.95)))
                        .onTapGesture {
                            if hasPhoto {
                                withAnimation(.spring(response: 0.4, dampingFraction: 0.8)) {
                                    isFullScreen = true
                                }
                            }
                        }

                } else {
                    // Empty state — prompt to select photo
                    photoPlaceholder(size: geo.size)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .animation(StyleAnimation.springSmooth, value: userPhoto != nil)
        }
    }

    @MainActor
    private func photoPlaceholder(size: CGSize) -> some View {
        PhotosPicker(selection: $photoPickerItem, matching: .images) {
            VStack(spacing: StyleSpacing.xl) {
                ZStack {
                    // Glow circle
                    Circle()
                        .fill(StyleColors.brandGradient.opacity(0.2))
                        .frame(width: 140, height: 140)
                        .blur(radius: 30)

                    // Icon
                    VStack(spacing: StyleSpacing.md) {
                        Image(systemName: "person.crop.rectangle.badge.plus")
                            .font(.system(size: 52, weight: .light))
                            .foregroundStyle(
                                LinearGradient(
                                    colors: [.white, StyleColors.accentRose],
                                    startPoint: .top,
                                    endPoint: .bottom
                                )
                            )

                        Text("Selecciona tu Foto")
                            .font(StyleTypography.title2)
                            .foregroundStyle(.white)

                        Text("Foto de cuerpo entero para\nmejores resultados")
                            .font(StyleTypography.footnote)
                            .foregroundStyle(StyleColors.textSecondary)
                            .multilineTextAlignment(.center)
                    }
                }
                .frame(width: min(size.width - 60, 280), height: 250)
                .glassCard(cornerRadius: 24)
            }
        }
    }

    private var photoOverlayBadges: some View {
        VStack(alignment: .trailing, spacing: StyleSpacing.sm) {
            // Change photo button
            PhotosPicker(selection: $photoPickerItem, matching: .images) {
                HStack(spacing: 4) {
                    Image(systemName: "arrow.triangle.2.circlepath.camera")
                        .font(.system(size: 11))
                    Text("Cambiar")
                        .font(StyleTypography.caption)
                }
                .foregroundStyle(.white)
                .padding(.horizontal, StyleSpacing.md)
                .padding(.vertical, StyleSpacing.sm)
                .background(.ultraThinMaterial, in: Capsule())
            }

            // AI Generation button
            if currentOutfit.hasAnySelection && hasPhoto {
                if sdService.state.isReady {
                    // SD model ready — show "Generate with AI" button
                    Button {
                        triggerAIGeneration()
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "sparkles")
                                .font(.system(size: 11))
                            Text(engine.usedStableDiffusion ? "Regenerar Look" : "Generar con IA")
                                .font(StyleTypography.caption)
                        }
                        .foregroundStyle(.white)
                        .padding(.horizontal, StyleSpacing.md)
                        .padding(.vertical, StyleSpacing.sm)
                        .background(
                            Capsule()
                                .fill(StyleColors.brandGradient)
                        )
                    }
                } else if !sdService.state.isDownloading {
                    // SD model not downloaded — show download CTA
                    Button {
                        downloadSDModel()
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "arrow.down.circle")
                                .font(.system(size: 11))
                            Text("Descargar IA (~2 GB)")
                                .font(StyleTypography.caption)
                        }
                        .foregroundStyle(.white.opacity(0.8))
                        .padding(.horizontal, StyleSpacing.md)
                        .padding(.vertical, StyleSpacing.sm)
                        .background(.ultraThinMaterial, in: Capsule())
                    }
                }
            }

            // Processing time / method badge
            if engine.lastProcessingTimeMs > 0 {
                HStack(spacing: 4) {
                    Image(systemName: engine.usedStableDiffusion ? "sparkles" : "bolt.fill")
                        .font(.system(size: 9))
                    Text(engine.usedStableDiffusion
                        ? "✨ IA · \(String(format: "%.1f", Double(engine.lastProcessingTimeMs) / 1000.0))s"
                        : "\(engine.lastProcessingTimeMs)ms")
                        .font(StyleTypography.captionMono)
                }
                .foregroundStyle(engine.usedStableDiffusion ? StyleColors.brandPink : StyleColors.accentMint)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(.ultraThinMaterial, in: Capsule())
            }
        }
        .padding(StyleSpacing.xl)
    }

    // MARK: - Carousel Stack

    private var carouselStack: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(spacing: StyleSpacing.lg) {
                CarouselPickerView(
                    slot: .top,
                    garments: garments(for: .top),
                    selection: $selectedTop,
                    onDelete: { deleteWardrobeItem($0) }
                )

                CarouselPickerView(
                    slot: .bottom,
                    garments: garments(for: .bottom),
                    selection: $selectedBottom,
                    onDelete: { deleteWardrobeItem($0) }
                )

                CarouselPickerView(
                    slot: .shoes,
                    garments: garments(for: .shoes),
                    selection: $selectedShoes,
                    onDelete: { deleteWardrobeItem($0) }
                )
            }
            .padding(.vertical, StyleSpacing.lg)
        }
        .frame(height: 460)
        .background(Color.black.opacity(0.15))
        // Add downward drag gesture to the entire carousel area to open full screen
        .gesture(
            DragGesture()
                .onEnded { value in
                    if value.translation.height > 50 && hasPhoto {
                        withAnimation(.spring(response: 0.4, dampingFraction: 0.8)) {
                            isFullScreen = true
                        }
                    }
                }
        )
    }

    /// Merges wardrobe items with sample garments for a given slot.
    /// Wardrobe items appear first (real photos), then samples as fallbacks.
    private func garments(for slot: GarmentSlot) -> [CarouselGarment] {
        // Convert wardrobe items matching this slot
        let matchingTypes: [GarmentType]
        switch slot {
        case .top:    matchingTypes = [.top, .outerwear]
        case .bottom: matchingTypes = [.bottom]
        case .shoes:  matchingTypes = [.shoes]
        }

        let wardrobeGarments = wardrobeItems
            .filter { matchingTypes.contains($0.type) }
            .sorted { $0.dateAdded > $1.dateAdded }
            .map { CarouselGarment.fromWardrobe($0) }

        // Add sample garments as fallbacks
        let sampleGarments = SampleGarments.garments(for: slot)
            .map { CarouselGarment.fromSample($0) }

        return wardrobeGarments + sampleGarments
    }

    // MARK: - Processing Overlay

    private var processingOverlay: some View {
        ZStack {
            Color.black.opacity(0.4)
                .ignoresSafeArea()

            VStack(spacing: StyleSpacing.lg) {
                // Animated clothing icon with pulsing ring
                ZStack {
                    // Outer pulsing ring
                    Circle()
                        .stroke(
                            AngularGradient(
                                colors: [
                                    StyleColors.primaryLight,
                                    StyleColors.primaryMid,
                                    StyleColors.primaryDark,
                                    StyleColors.primaryLight
                                ],
                                center: .center
                            ),
                            lineWidth: 3
                        )
                        .frame(width: 70, height: 70)
                        .rotationEffect(.degrees(processingRotation))

                    // Inner glow
                    Circle()
                        .fill(StyleColors.brandGradient.opacity(0.15))
                        .frame(width: 60, height: 60)
                        .scaleEffect(processingPulse ? 1.1 : 0.9)

                    // Clothing icon
                    Image(systemName: "tshirt.fill")
                        .font(.system(size: 24, weight: .medium))
                        .foregroundStyle(StyleColors.brandGradient)
                        .scaleEffect(processingPulse ? 1.05 : 0.95)
                }

                VStack(spacing: StyleSpacing.xs) {
                    Text("Aplicando prendas...")
                        .font(StyleTypography.headline)
                        .foregroundStyle(.white)

                    // Shimmer dots animation
                    HStack(spacing: 4) {
                        ForEach(0..<3, id: \.self) { i in
                            Circle()
                                .fill(.white)
                                .frame(width: 5, height: 5)
                                .opacity(processingDotIndex == i ? 1.0 : 0.3)
                        }
                    }
                }
            }
            .padding(StyleSpacing.xxl)
            .glassCard(cornerRadius: 20)
        }
        .transition(.opacity)
        .onAppear {
            withAnimation(.linear(duration: 1.5).repeatForever(autoreverses: false)) {
                processingRotation = 360
            }
            withAnimation(.easeInOut(duration: 0.8).repeatForever()) {
                processingPulse = true
            }
            startDotAnimation()
        }
        .onDisappear {
            processingRotation = 0
            processingPulse = false
            processingDotIndex = 0
        }
    }

    /// Cycles the dot index for the shimmer dots animation.
    private func startDotAnimation() {
        Task { @MainActor in
            while engine.state.isProcessing {
                try? await Task.sleep(nanoseconds: 400_000_000)
                processingDotIndex = (processingDotIndex + 1) % 3
            }
        }
    }

    // MARK: - AI Generation Overlay

    private var aiGenerationOverlay: some View {
        ZStack {
            Color.black.opacity(0.65)
                .ignoresSafeArea()

            VStack(spacing: StyleSpacing.xl) {
                // Metal iOS 26 Fluid core
                ZStack {
                    Circle()
                        .fill(
                            AngularGradient(
                                colors: [StyleColors.brandPink, StyleColors.accentMint, StyleColors.accentGold, StyleColors.brandPink],
                                center: .center,
                                startAngle: .degrees(0),
                                endAngle: .degrees(360)
                            )
                        )
                        .frame(width: 90, height: 90)
                        .blur(radius: 15)
                        .rotationEffect(.degrees(processingRotation * 2))

                    Circle()
                        .strokeBorder(
                            LinearGradient(colors: [.white.opacity(0.8), .white.opacity(0.1)], startPoint: .topLeading, endPoint: .bottomTrailing),
                            lineWidth: 1.5
                        )
                        .frame(width: 80, height: 80)

                    Image(systemName: "wand.and.stars.inverse")
                        .font(.system(size: 32, weight: .light))
                        .foregroundStyle(.white)
                        .symbolEffect(.pulse, options: .repeating)
                }

                VStack(spacing: StyleSpacing.sm) {
                    Text("Tejiendo píxeles...")
                        .font(StyleTypography.title3)
                        .foregroundStyle(.white)

                    Text("Stable Diffusion · Ajuste Perfecto")
                        .font(StyleTypography.caption)
                        .foregroundStyle(StyleColors.textTertiary)
                }

                // Custom glowing progress bar
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule()
                            .fill(Color.white.opacity(0.1))
                            .frame(height: 6)

                        Capsule()
                            .fill(
                                LinearGradient(colors: [StyleColors.brandPink, StyleColors.accentGold], startPoint: .leading, endPoint: .trailing)
                            )
                            .frame(width: max(geo.size.width * CGFloat(sdService.generationProgress), 0), height: 6)
                            .shadow(color: StyleColors.brandPink.opacity(0.6), radius: 8, x: 0, y: 0)
                    }
                }
                .frame(width: 220, height: 6)
                .padding(.top, StyleSpacing.sm)

                Text("\(Int(sdService.generationProgress * 100))%")
                    .font(StyleTypography.captionMono)
                    .foregroundStyle(StyleColors.textSecondary)
            }
            .padding(40)
            .background(
                RoundedRectangle(cornerRadius: 32)
                    .fill(.ultraThinMaterial)
                    .environment(\.colorScheme, .dark)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 32)
                    .stroke(
                        LinearGradient(colors: [.white.opacity(0.4), .white.opacity(0.0)], startPoint: .topLeading, endPoint: .bottomTrailing),
                        lineWidth: 1.5
                    )
            )
            .shadow(color: .black.opacity(0.3), radius: 30, y: 15)
        }
        .transition(.opacity.combined(with: .scale(scale: 0.95)))
    }

    // MARK: - SD Download Overlay

    private var sdDownloadOverlay: some View {
        ZStack {
            Color.black.opacity(0.5)
                .ignoresSafeArea()

            VStack(spacing: StyleSpacing.lg) {
                Image(systemName: "arrow.down.circle")
                    .font(.system(size: 36))
                    .foregroundStyle(StyleColors.accentMint)
                    .symbolEffect(.pulse, options: .repeating)

                VStack(spacing: StyleSpacing.sm) {
                    Text("Descargando Motor IA")
                        .font(StyleTypography.headline)
                        .foregroundStyle(.white)

                    Text("Stable Diffusion · ~\(SDModelFile.totalSizeMB) MB total")
                        .font(StyleTypography.caption)
                        .foregroundStyle(StyleColors.textSecondary)
                }

                VStack(spacing: StyleSpacing.sm) {
                    ProgressView(value: sdService.downloadProgress)
                        .progressViewStyle(.linear)
                        .tint(StyleColors.accentMint)

                    // Overall progress
                    HStack {
                        Text("\(Int(sdService.downloadProgress * 100))%")
                            .font(StyleTypography.captionMono)
                            .foregroundStyle(.white)

                        Spacer()

                        if sdService.downloadSpeedMBps > 0 {
                            Text(String(format: "%.1f MB/s", sdService.downloadSpeedMBps))
                                .font(StyleTypography.captionMono)
                                .foregroundStyle(StyleColors.accentMint)
                        }
                    }

                    // Current file info
                    if sdService.downloadFileTotal > 0 {
                        HStack {
                            Text("Archivo \(sdService.downloadFileIndex)/\(sdService.downloadFileTotal)")
                                .font(StyleTypography.captionMono)
                                .foregroundStyle(StyleColors.textSecondary)

                            Spacer()

                            Text(String(format: "%.1f/%.0f MB", sdService.downloadedMB, sdService.currentFileTotalMB))
                                .font(StyleTypography.captionMono)
                                .foregroundStyle(StyleColors.textSecondary)
                        }
                    }

                    // File name
                    if !sdService.currentDownloadFile.isEmpty {
                        Text(sdService.currentDownloadFile)
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(StyleColors.textTertiary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }
                .frame(width: 220)
            }
            .padding(StyleSpacing.xxl)
            .glassCard(cornerRadius: 20)
        }
        .transition(.opacity)
    }

    // MARK: - Saved Toast

    private var savedToast: some View {
        VStack {
            Spacer()

            HStack(spacing: StyleSpacing.sm) {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                Text("Look guardado")
                    .font(StyleTypography.headline)
                    .foregroundStyle(.white)
            }
            .padding(.horizontal, StyleSpacing.xl)
            .padding(.vertical, StyleSpacing.md)
            .glassCard(cornerRadius: StyleSpacing.pillCornerRadius)
            .padding(.bottom, 80)
        }
        .transition(.move(edge: .bottom).combined(with: .opacity))
        .animation(StyleAnimation.springSmooth, value: showSavedFeedback)
    }

    // MARK: - Toolbar

    private var toolbarMenu: some View {
        Menu {
            if currentOutfit.hasAnySelection {
                Button {
                    saveLook()
                } label: {
                    Label("Guardar Look", systemImage: "square.and.arrow.down")
                }
            }

            Button {
                resetOutfit()
            } label: {
                Label("Resetear Outfit", systemImage: "arrow.counterclockwise")
            }

            Divider()

            // Outfit summary
            Section("Outfit Actual") {
                if let top = selectedTop {
                    Label(top.name, systemImage: "tshirt.fill")
                }
                if let bottom = selectedBottom {
                    Label(bottom.name, systemImage: "figure.walk")
                }
                if let shoes = selectedShoes {
                    Label(shoes.name, systemImage: "shoe.fill")
                }
                if !currentOutfit.hasAnySelection {
                    Text("Sin prendas seleccionadas")
                }
            }
        } label: {
            Image(systemName: "ellipsis.circle")
                .font(.system(size: 18))
                .foregroundStyle(.white)
        }
    }

    // MARK: - Actions

    /// Load the selected photo from PhotosPicker.
    private func loadPhoto(from item: PhotosPickerItem?) async {
        guard let item else { return }

        DebugLogger.shared.log("📷 Loading user photo...", level: .info)

        do {
            if let data = try await item.loadTransferable(type: Data.self),
               let image = UIImage(data: data) {
                userPhoto = image
                compositeImage = nil
                engine.reset()
                persistPhoto(image)
                DebugLogger.shared.log("✅ Photo loaded: \(Int(image.size.width))×\(Int(image.size.height))", level: .success)

                // Auto-apply if garments are already selected
                if currentOutfit.hasAnySelection {
                    triggerTryOn()
                }
            }
        } catch {
            DebugLogger.shared.log("❌ Photo load failed: \(error.localizedDescription)", level: .error)
        }
    }

    /// Trigger the VTO engine when a garment selection changes (fast preview).
    private func triggerTryOn() {
        guard let photo = userPhoto, currentOutfit.hasAnySelection else {
            compositeImage = nil
            return
        }

        if sdService.state.isReady {
            triggerAIGeneration()
        } else {
            Task {
                compositeImage = await engine.applyOutfit(to: photo, outfit: currentOutfit)
            }
        }
    }

    /// Trigger AI generation using Stable Diffusion.
    private func triggerAIGeneration() {
        guard let photo = userPhoto, currentOutfit.hasAnySelection else { return }

        Task {
            if let aiResult = await engine.generateWithAI(userPhoto: photo, outfit: currentOutfit) {
                compositeImage = aiResult
            } else {
                DebugLogger.shared.log("⚠️ VTO AI returned nil, keeping previous view", level: .warning)
            }
        }
    }

    /// Download the Stable Diffusion model.
    private func downloadSDModel() {
        isDownloadingSD = true
        Task {
            await ModelManager.shared.downloadSDModel()
            isDownloadingSD = false
        }
    }

    /// Reset all garment selections.
    private func resetOutfit() {
        withAnimation(StyleAnimation.springSmooth) {
            selectedTop = nil
            selectedBottom = nil
            selectedShoes = nil
            compositeImage = nil
            userPhoto = nil
            engine.reset()
            clearPersistedPhoto()
        }
        DebugLogger.shared.log("🔄 Outfit reset", level: .info)
    }

    // MARK: - Photo Persistence

    /// Save photo to disk so it persists across sessions.
    private func persistPhoto(_ image: UIImage) {
        if let data = image.jpegData(compressionQuality: 0.85) {
            try? data.write(to: Self.photoURL)
            DebugLogger.shared.log("💾 Photo persisted to disk", level: .info)
        }
    }

    /// Load persisted photo on view appear.
    private func loadPersistedPhoto() {
        guard userPhoto == nil else { return } // Don't reload if already set
        if let data = try? Data(contentsOf: Self.photoURL),
           let image = UIImage(data: data) {
            userPhoto = image
            DebugLogger.shared.log("📂 Loaded persisted photo: \(Int(image.size.width))×\(Int(image.size.height))", level: .info)
        }
    }

    /// Remove persisted photo from disk.
    private func clearPersistedPhoto() {
        try? FileManager.default.removeItem(at: Self.photoURL)
        DebugLogger.shared.log("🗑️ Persisted photo cleared", level: .info)
    }

    /// Save the current look (composite image).
    private func saveLook() {
        guard let image = compositeImage ?? userPhoto else { return }

        UIImageWriteToSavedPhotosAlbum(image, nil, nil, nil)

        withAnimation(StyleAnimation.springSmooth) {
            showSavedFeedback = true
        }

        DebugLogger.shared.log("💾 Look saved to Photos", level: .success)

        // Hide toast after 2 seconds
        Task {
            try? await Task.sleep(for: .seconds(2))
            withAnimation(StyleAnimation.springSmooth) {
                showSavedFeedback = false
            }
        }
    }

    // MARK: - Error Overlay

    private func errorOverlay(msg: String) -> some View {
        ZStack {
            Color.black.opacity(0.6).ignoresSafeArea()
            VStack(spacing: StyleSpacing.md) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 40))
                    .foregroundStyle(StyleColors.brandPink)
                Text("Error de Try-On")
                    .font(StyleTypography.headline)
                    .foregroundStyle(.white)
                Text(msg)
                    .font(StyleTypography.caption)
                    .foregroundStyle(StyleColors.textSecondary)
                    .multilineTextAlignment(.center)
                    .padding()
                Button {
                    engine.clearError()
                } label: {
                    Text("Cerrar")
                        .font(StyleTypography.headline)
                        .foregroundStyle(.white)
                        .padding(.horizontal, 24)
                        .padding(.vertical, 12)
                        .background(.white.opacity(0.15), in: Capsule())
                }
            }
            .padding(StyleSpacing.xl)
            .glassCard(cornerRadius: 20)
            .padding(40)
        }
        .transition(.opacity)
    }

    // MARK: - Full Screen Overlay

    @State private var currentMagnification: CGFloat = 1.0
    @State private var finalMagnification: CGFloat = 1.0
    @State private var dragOffset: CGSize = .zero

    private func fullScreenImageOverlay(image: UIImage) -> some View {
        ZStack {
            Color.black
                .opacity(max(CGFloat(0), CGFloat(1.0) - (abs(dragOffset.height) / CGFloat(500))))
                .ignoresSafeArea()

            Image(uiImage: image)
                .resizable()
                .scaledToFit()
                .scaleEffect(currentMagnification * finalMagnification)
                .offset(y: dragOffset.height)
                .gesture(
                    MagnifyGesture()
                        .onChanged { value in
                            currentMagnification = value.magnification
                        }
                        .onEnded { value in
                            withAnimation(.spring()) {
                                finalMagnification = max(1.0, finalMagnification * value.magnification)
                                currentMagnification = 1.0
                                // If scaled down too much, snap back
                                if finalMagnification < 1.0 { finalMagnification = 1.0 }
                            }
                        }
                )
                .gesture(
                    DragGesture()
                        .onChanged { value in
                            if finalMagnification == 1.0 {
                                // Only allow dismiss drag if not zoomed in
                                dragOffset = value.translation
                            }
                        }
                        .onEnded { value in
                            if finalMagnification == 1.0 {
                                if abs(dragOffset.height) > 100 {
                                    withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                                        isFullScreen = false
                                        dragOffset = .zero
                                    }
                                } else {
                                    withAnimation(.spring()) {
                                        dragOffset = .zero
                                    }
                                }
                            }
                        }
                )
                .onTapGesture(count: 2) {
                    // Double tap to reset zoom or zoom in
                    withAnimation(.spring()) {
                        if finalMagnification > 1.0 {
                            finalMagnification = 1.0
                            dragOffset = .zero
                        } else {
                            finalMagnification = 2.0
                        }
                    }
                }

            // Overlay controls
            VStack {
                HStack {
                    Spacer()
                    Button {
                        withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                            isFullScreen = false
                            dragOffset = .zero
                            finalMagnification = 1.0
                        }
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 30))
                            .foregroundStyle(.white.opacity(0.8))
                            .padding()
                    }
                }
                Spacer()
            }
        }
        .zIndex(100)
        .transition(.opacity)
    }
}

// MARK: - Wardrobe Deletion

extension TryOnView {
    /// Deletes a wardrobe item that corresponds to the given CarouselGarment.
    func deleteWardrobeItem(_ garment: CarouselGarment) {
        guard garment.isFromWardrobe else { return }
        guard let item = wardrobeItems.first(where: { $0.id == garment.id }) else { return }
        modelContext.delete(item)
        try? modelContext.save()
    }
}

// MARK: - Preview

#Preview {
    NavigationStack {
        TryOnView()
    }
    .preferredColorScheme(.dark)
}
