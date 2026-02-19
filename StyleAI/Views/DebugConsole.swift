// DebugConsole.swift
// StyleAI — Floating Debug HUD
//
// In-app diagnostic overlay for "blind debugging" without Xcode.
// Shows real-time logs, RAM usage, and system info.
// Activated by hidden gesture (5-tap on logo or 5-finger long press).

import SwiftUI
import os.log

// MARK: - Log Entry Model

/// A single log entry with metadata.
struct DebugLogEntry: Identifiable, Sendable {
    let id = UUID()
    let timestamp: Date
    let message: String
    let level: DebugLogLevel

    var formattedTime: String {
        timestamp.formatted(date: .omitted, time: .standard)
    }
}

/// Severity levels for log entries.
enum DebugLogLevel: String, Sendable {
    case info    = "ℹ️"
    case warning = "⚠️"
    case error   = "❌"
    case success = "✅"

    var color: Color {
        switch self {
        case .info:    return .cyan
        case .warning: return .yellow
        case .error:   return .red
        case .success: return .green
        }
    }
}

// MARK: - Debug Logger (Thread-Safe Singleton)

/// Global, thread-safe logger that collects entries for the debug console.
/// Accessible from anywhere in the app — logs are buffered and displayed in the HUD.
@MainActor
@Observable
final class DebugLogger {

    static let shared = DebugLogger()

    /// All collected log entries (most recent last).
    private(set) var entries: [DebugLogEntry] = []

    /// Maximum entries to retain in memory.
    private let maxEntries = 500

    private let osLogger = Logger(subsystem: "com.styleai.app", category: "Debug")

    private init() {}

    /// Add a log entry. Also forwards to `os_log` for console output when Xcode IS connected.
    func log(_ message: String, level: DebugLogLevel = .info) {
        let entry = DebugLogEntry(timestamp: .now, message: message, level: level)
        entries.append(entry)

        // Trim buffer if needed
        if entries.count > maxEntries {
            entries.removeFirst(entries.count - maxEntries)
        }

        // Also log to system (visible via Console.app or Xcode when available)
        switch level {
        case .info, .success:
            osLogger.info("\(message)")
        case .warning:
            osLogger.warning("\(message)")
        case .error:
            osLogger.error("\(message)")
        }
    }

    /// Clear all entries.
    func clear() {
        entries.removeAll()
        log("🧹 Logs cleared", level: .info)
    }
}

// MARK: - Debug Console View

/// Floating overlay that displays real-time diagnostic information.
///
/// Features:
/// - Scrollable log list with color-coded severity
/// - Real-time RAM / CPU stats
/// - Export logs to clipboard
/// - Dismiss via drag-down gesture or close button
struct DebugConsoleView: View {

    @State private var logger = DebugLogger.shared
    @State private var dragOffset: CGFloat = 0
    @State private var searchText = ""
    @State private var filterLevel: DebugLogLevel? = nil
    @State private var autoScroll = true
    @State private var memoryMB: Int = 0
    @State private var memoryTask: Task<Void, Never>?

    let onDismiss: () -> Void

    private var filteredEntries: [DebugLogEntry] {
        logger.entries.filter { entry in
            let matchesSearch = searchText.isEmpty
                || entry.message.localizedCaseInsensitiveContains(searchText)
            let matchesLevel = filterLevel == nil || entry.level == filterLevel
            return matchesSearch && matchesLevel
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            // Drag handle
            dragHandle

            // Header bar
            headerBar

            // Filter chips
            filterBar

            // Search
            searchBar

            // Log list
            logList

            // Footer stats
            statsFooter
        }
        .background(.ultraThinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 20))
        .overlay(
            RoundedRectangle(cornerRadius: 20)
                .stroke(Color.white.opacity(0.1), lineWidth: 0.5)
        )
        .shadow(color: .black.opacity(0.5), radius: 20, y: 10)
        .padding(.horizontal, 8)
        .padding(.top, 50)
        .padding(.bottom, 20)
        .offset(y: dragOffset)
        .gesture(
            DragGesture()
                .onChanged { value in
                    if value.translation.height > 0 {
                        dragOffset = value.translation.height
                    }
                }
                .onEnded { value in
                    if value.translation.height > 150 {
                        onDismiss()
                    }
                    withAnimation(StyleAnimation.springSmooth) {
                        dragOffset = 0
                    }
                }
        )
        .transition(.move(edge: .bottom).combined(with: .opacity))
        .onAppear { startMemoryMonitor() }
        .onDisappear { memoryTask?.cancel() }
    }

    // MARK: - Subviews

    private var dragHandle: some View {
        Capsule()
            .fill(Color.white.opacity(0.3))
            .frame(width: 40, height: 5)
            .padding(.top, 10)
            .padding(.bottom, 6)
    }

    private var headerBar: some View {
        HStack {
            Image(systemName: "ant.fill")
                .font(.title3)
                .foregroundStyle(.orange)

            Text("Debug Console")
                .font(StyleTypography.headline)
                .foregroundStyle(.white)

            Spacer()

            // Copy all logs
            Button {
                copyLogsToClipboard()
            } label: {
                Image(systemName: "doc.on.doc")
                    .foregroundStyle(.white.opacity(0.7))
            }

            // Clear logs
            Button {
                logger.clear()
            } label: {
                Image(systemName: "trash")
                    .foregroundStyle(.red.opacity(0.8))
            }

            // Close
            Button {
                onDismiss()
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.title3)
                    .foregroundStyle(.white.opacity(0.6))
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
    }

    private var filterBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                filterChip(label: "All", level: nil)
                filterChip(label: "Info", level: .info)
                filterChip(label: "Warning", level: .warning)
                filterChip(label: "Error", level: .error)
                filterChip(label: "Success", level: .success)
            }
            .padding(.horizontal, 16)
        }
        .padding(.vertical, 4)
    }

    private func filterChip(label: String, level: DebugLogLevel?) -> some View {
        let isActive = filterLevel == level
        return Button(label) {
            withAnimation(StyleAnimation.springSnappy) {
                filterLevel = level
            }
        }
        .font(StyleTypography.caption)
        .foregroundStyle(isActive ? .white : .white.opacity(0.6))
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(
            Capsule()
                .fill(isActive ? (level?.color ?? .white).opacity(0.3) : Color.white.opacity(0.08))
        )
    }

    private var searchBar: some View {
        HStack {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.white.opacity(0.4))
            TextField("Buscar logs...", text: $searchText)
                .font(StyleTypography.footnote)
                .foregroundStyle(.white)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
        }
        .padding(8)
        .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 8))
        .padding(.horizontal, 16)
        .padding(.bottom, 4)
    }

    private var logList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    ForEach(filteredEntries) { entry in
                        logRow(entry)
                            .id(entry.id)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
            }
            .onChange(of: logger.entries.count) { _, _ in
                if autoScroll, let lastEntry = filteredEntries.last {
                    withAnimation {
                        proxy.scrollTo(lastEntry.id, anchor: .bottom)
                    }
                }
            }
        }
    }

    private func logRow(_ entry: DebugLogEntry) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Text(entry.level.rawValue)
                .font(.system(size: 10))

            Text(entry.formattedTime)
                .font(StyleTypography.captionMono)
                .foregroundStyle(.white.opacity(0.4))
                .frame(width: 70, alignment: .leading)

            Text(entry.message)
                .font(StyleTypography.captionMono)
                .foregroundStyle(entry.level.color.opacity(0.9))
                .lineLimit(3)
        }
        .padding(.vertical, 3)
        .padding(.horizontal, 6)
        .background(
            RoundedRectangle(cornerRadius: 4)
                .fill(entry.level.color.opacity(0.05))
        )
    }

    private var statsFooter: some View {
        HStack(spacing: 16) {
            // RAM
            HStack(spacing: 4) {
                Image(systemName: "memorychip")
                    .font(.system(size: 10))
                Text("\(memoryMB) MB free")
                    .font(StyleTypography.captionMono)
            }
            .foregroundStyle(memoryMB < 500 ? .red : memoryMB < 1500 ? .yellow : .green)

            Divider()
                .frame(height: 12)
                .background(Color.white.opacity(0.2))

            // Log count
            HStack(spacing: 4) {
                Image(systemName: "list.bullet")
                    .font(.system(size: 10))
                Text("\(logger.entries.count) entries")
                    .font(StyleTypography.captionMono)
            }
            .foregroundStyle(.white.opacity(0.5))

            Spacer()

            // Auto-scroll toggle
            Button {
                autoScroll.toggle()
            } label: {
                Image(systemName: autoScroll ? "arrow.down.to.line" : "pause")
                    .font(.system(size: 12))
                    .foregroundStyle(autoScroll ? .green : .orange)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(Color.black.opacity(0.2))
    }

    // MARK: - Helpers

    private func copyLogsToClipboard() {
        let text = logger.entries.map { entry in
            "[\(entry.formattedTime)] \(entry.level.rawValue) \(entry.message)"
        }.joined(separator: "\n")
        UIPasteboard.general.string = text
        DebugLogger.shared.log("📋 Copied \(logger.entries.count) log entries to clipboard", level: .success)
    }

    private func startMemoryMonitor() {
        updateMemory()
        memoryTask = Task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(2))
                updateMemory()
            }
        }
    }

    private func updateMemory() {
        let available = os_proc_available_memory()
        memoryMB = Int(available / (1024 * 1024))
    }
}

// MARK: - Debug Console Overlay Modifier

/// View modifier that conditionally overlays the debug console.
/// Use: `.debugConsoleOverlay(isPresented: $showDebug)`
struct DebugConsoleOverlay: ViewModifier {
    @Binding var isPresented: Bool

    func body(content: Content) -> some View {
        content
            .overlay {
                if isPresented {
                    Color.black.opacity(0.3)
                        .ignoresSafeArea()
                        .onTapGesture { isPresented = false }

                    DebugConsoleView {
                        withAnimation(StyleAnimation.springSmooth) {
                            isPresented = false
                        }
                    }
                }
            }
            .animation(StyleAnimation.springSmooth, value: isPresented)
    }
}

extension View {
    /// Adds a debug console overlay activated by the given binding.
    func debugConsoleOverlay(isPresented: Binding<Bool>) -> some View {
        modifier(DebugConsoleOverlay(isPresented: isPresented))
    }
}
