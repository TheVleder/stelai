// FloatingDebugButtonView.swift
// StyleAI — Floating Debug Button
//
// An iOS 26 style draggable floating button that toggles the Debug Console overlay.
// It subscribes to DebugLogger to show the latest log message live.

import SwiftUI

struct FloatingDebugButtonView: View {
    @Binding var showDebugConsole: Bool
    @State private var dragOffset: CGSize = .zero
    @State private var position: CGSize = .zero // Origin is defined by its container
    
    // Subscribe to live logs
    @State private var logger = DebugLogger.shared
    
    var body: some View {
        Button {
            withAnimation(StyleAnimation.springSmooth) {
                showDebugConsole.toggle()
            }
            DebugLogger.shared.log("🐛 Debug console toggled via floating button", level: .info)
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "ant.fill")
                    .foregroundStyle(.orange)
                    .font(.system(size: 16, weight: .bold))
                
                if let lastLog = logger.entries.last {
                    Text(lastLog.message)
                        .font(StyleTypography.captionMono)
                        .foregroundStyle(lastLog.level.color)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .frame(maxWidth: 200, alignment: .leading)
                } else {
                    Text("Debug Logs...")
                        .font(StyleTypography.captionMono)
                        .foregroundStyle(.white.opacity(0.6))
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .background(.ultraThinMaterial)
            .background(StyleColors.surfacePrimary.opacity(0.6))
            .clipShape(Capsule())
            .overlay(
                Capsule()
                    .stroke(Color.white.opacity(0.15), lineWidth: 1)
            )
            .shadow(color: .black.opacity(0.3), radius: 10, y: 5)
        }
        .buttonStyle(.plain)
        .offset(
            x: position.width + dragOffset.width,
            y: position.height + dragOffset.height
        )
        .gesture(
            DragGesture()
                .onChanged { value in
                    dragOffset = value.translation
                }
                .onEnded { value in
                    withAnimation(StyleAnimation.springSnappy) {
                        position.width += value.translation.width
                        position.height += value.translation.height
                        
                        // Mild snapping back to center if dragged too far
                        let maxW = UIScreen.main.bounds.width / 2 - 40
                        let maxH = UIScreen.main.bounds.height / 2 - 100
                        
                        if position.width > maxW { position.width = maxW }
                        if position.width < -maxW { position.width = -maxW }
                        if position.height > maxH { position.height = maxH }
                        if position.height < -maxH { position.height = -maxH }
                        
                        dragOffset = .zero
                    }
                }
        )
    }
}

