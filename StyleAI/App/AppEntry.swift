// AppEntry.swift
// StyleAI — Application Entry Point
//
// @main struct that configures SwiftData, injects dependencies,
// and manages app lifecycle transitions (background model unloading).

import SwiftUI
import SwiftData

// MARK: - App Entry

@main
struct StyleAIApp: App {

    /// SwiftData model container for WardrobeItem persistence.
    private let modelContainer: ModelContainer

    /// Tracks scene phase for lifecycle management.
    @Environment(\.scenePhase) private var scenePhase

    // MARK: - Init

    init() {
        // Configure SwiftData schema and storage
        do {
            let schema = Schema([
                WardrobeItem.self
            ])

            let configuration = ModelConfiguration(
                "StyleAI",
                schema: schema,
                isStoredInMemoryOnly: false,
                allowsSave: true
            )

            modelContainer = try ModelContainer(
                for: schema,
                configurations: [configuration]
            )
        } catch {
            // Fatal: Cannot proceed without data persistence.
            // In production, this would show a recovery UI.
            fatalError("❌ Failed to initialize SwiftData: \(error.localizedDescription)")
        }

        // Configure global UIKit appearance (safe in init, runs on main thread)
        configureAppearance()
    }

    // MARK: - Scene

    var body: some Scene {
        WindowGroup {
            ContentView()
                .task {
                    // Log startup info once on MainActor context
                    DebugLogger.shared.log("💾 SwiftData initialized successfully", level: .success)
                    DebugLogger.shared.log("🚀 StyleAI App launched", level: .info)
                    DebugLogger.shared.log("📱 Device: \(DeviceChecker.validate().chipName)", level: .info)
                }
        }
        .modelContainer(modelContainer)
        .onChange(of: scenePhase) { oldPhase, newPhase in
            handleScenePhaseChange(from: oldPhase, to: newPhase)
        }
    }

    // MARK: - Lifecycle Management

    /// Handles app lifecycle transitions for resource management.
    ///
    /// Key behaviors:
    /// - **Background**: Unloads ML models to free RAM and avoid OOM termination.
    /// - **Active**: Re-loads models if they were evicted.
    private func handleScenePhaseChange(from oldPhase: ScenePhase, to newPhase: ScenePhase) {
        switch newPhase {
        case .background:
            DebugLogger.shared.log("🌙 App entering background — unloading ML models", level: .warning)
            Task { @MainActor in
                ModelManager.shared.unloadAll()
            }

        case .active where oldPhase == .background:
            DebugLogger.shared.log("☀️ App returning to foreground — re-bootstrapping", level: .info)
            Task { @MainActor in
                await ModelManager.shared.bootstrapIfNeeded()
            }

        case .inactive:
            DebugLogger.shared.log("⏸ App inactive", level: .info)

        default:
            break
        }
    }

    // MARK: - Appearance Configuration

    /// Configures global UIKit appearance for navigation bars and UI chrome.
    private func configureAppearance() {
        // Navigation bar — transparent with blur
        let navBarAppearance = UINavigationBarAppearance()
        navBarAppearance.configureWithTransparentBackground()
        navBarAppearance.titleTextAttributes = [
            .foregroundColor: UIColor.white,
            .font: UIFont.systemFont(ofSize: 17, weight: .semibold)
        ]
        navBarAppearance.largeTitleTextAttributes = [
            .foregroundColor: UIColor.white,
            .font: UIFont.systemFont(ofSize: 34, weight: .bold)
        ]
        UINavigationBar.appearance().standardAppearance = navBarAppearance
        UINavigationBar.appearance().scrollEdgeAppearance = navBarAppearance

        // Tab bar — frosted glass style
        let tabBarAppearance = UITabBarAppearance()
        tabBarAppearance.configureWithTransparentBackground()
        tabBarAppearance.backgroundColor = UIColor(white: 0.05, alpha: 0.8)
        UITabBar.appearance().standardAppearance = tabBarAppearance
        UITabBar.appearance().scrollEdgeAppearance = tabBarAppearance
    }
}
