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
import PhotosUI

// MARK: - Try-On View

struct TryOnView: View {

    // MARK: State

    @State private var engine = TryOnEngine.shared

    /// User's selected photo.
    @State private var userPhoto: UIImage?

    /// PhotosPicker selection item.
    @State private var photoPickerItem: PhotosPickerItem?

    /// Currently selected garments per slot.
    @State private var selectedTop: SampleGarment?
    @State private var selectedBottom: SampleGarment?
    @State private var selectedShoes: SampleGarment?

    /// Result image from the engine.
    @State private var compositeImage: UIImage?

    /// Animation states
    @State private var showSavedFeedback = false
    @State private var photoScale: CGFloat = 1.0

    @Environment(\.dismiss) private var dismiss

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

            // Saved feedback
            if showSavedFeedback {
                savedToast
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
                        .shadow(color: .black.opacity(0.4), radius: 20, y: 10)
                        .scaleEffect(photoScale)
                        .padding(StyleSpacing.lg)
                        .overlay(alignment: .bottomTrailing) {
                            photoOverlayBadges
                        }
                        .transition(.opacity.combined(with: .scale(scale: 0.95)))

                } else {
                    // Empty state — prompt to select photo
                    photoPlaceholder(size: geo.size)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .animation(StyleAnimation.springSmooth, value: userPhoto != nil)
        }
    }

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

            // Processing time badge
            if engine.lastProcessingTimeMs > 0 {
                HStack(spacing: 4) {
                    Image(systemName: "bolt.fill")
                        .font(.system(size: 9))
                    Text("\(engine.lastProcessingTimeMs)ms")
                        .font(StyleTypography.captionMono)
                }
                .foregroundStyle(StyleColors.accentMint)
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
                    garments: SampleGarments.allTops,
                    selection: $selectedTop
                )

                CarouselPickerView(
                    slot: .bottom,
                    garments: SampleGarments.allBottoms,
                    selection: $selectedBottom
                )

                CarouselPickerView(
                    slot: .shoes,
                    garments: SampleGarments.allShoes,
                    selection: $selectedShoes
                )
            }
            .padding(.vertical, StyleSpacing.lg)
        }
        .frame(height: 460)
        .background(Color.black.opacity(0.15))
    }

    // MARK: - Processing Overlay

    private var processingOverlay: some View {
        ZStack {
            Color.black.opacity(0.3)
                .ignoresSafeArea()

            VStack(spacing: StyleSpacing.lg) {
                ProgressView()
                    .progressViewStyle(.circular)
                    .tint(.white)
                    .scaleEffect(1.3)

                VStack(spacing: StyleSpacing.xs) {
                    Text("Aplicando prendas...")
                        .font(StyleTypography.headline)
                        .foregroundStyle(.white)

                    Text("Procesando con IA")
                        .font(StyleTypography.caption)
                        .foregroundStyle(StyleColors.textSecondary)
                }
            }
            .padding(StyleSpacing.xxl)
            .glassCard(cornerRadius: 20)
        }
        .transition(.opacity)
        .animation(StyleAnimation.fadeIn, value: engine.state.isProcessing)
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

    /// Trigger the VTO engine when a garment selection changes.
    private func triggerTryOn() {
        guard let photo = userPhoto, currentOutfit.hasAnySelection else {
            compositeImage = nil
            return
        }

        Task {
            compositeImage = await engine.applyOutfit(to: photo, outfit: currentOutfit)
        }
    }

    /// Reset all garment selections.
    private func resetOutfit() {
        withAnimation(StyleAnimation.springSmooth) {
            selectedTop = nil
            selectedBottom = nil
            selectedShoes = nil
            compositeImage = nil
            engine.reset()
        }
        DebugLogger.shared.log("🔄 Outfit reset", level: .info)
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
}

// MARK: - Preview

#Preview {
    NavigationStack {
        TryOnView()
    }
    .preferredColorScheme(.dark)
}
