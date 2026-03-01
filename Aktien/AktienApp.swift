//
//  AktienApp.swift
//  Aktien
//
//  Created by Axel Behm on 28.01.26.
//

import SwiftUI
import SwiftData

@main
struct AktienApp: App {
    var sharedModelContainer: ModelContainer = {
        let schema = Schema([
            Aktie.self,
            ImportSummary.self,
            ImportPositionSnapshot.self,
        ])
        let storeURL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("Aktien", isDirectory: true)
        try? FileManager.default.createDirectory(at: storeURL, withIntermediateDirectories: true)
        let dbURL = storeURL.appendingPathComponent("default.sqlite")
        let modelConfiguration = ModelConfiguration(schema: schema, url: dbURL)

        do {
            return try ModelContainer(for: schema, configurations: [modelConfiguration])
        } catch {
            // Schema-Änderung: Alte Datenbank inkompatibel – neu anlegen
            try? FileManager.default.removeItem(at: dbURL)
            try? FileManager.default.removeItem(at: dbURL.deletingLastPathComponent().appendingPathComponent("default.sqlite-wal"))
            try? FileManager.default.removeItem(at: dbURL.deletingLastPathComponent().appendingPathComponent("default.sqlite-shm"))
            do {
                return try ModelContainer(for: schema, configurations: [modelConfiguration])
            } catch {
                fatalError("Could not create ModelContainer: \(error)")
            }
        }
    }()

    var body: some Scene {
        WindowGroup {
            RootView()
        }
        .modelContainer(sharedModelContainer)
        #if os(macOS)
        .defaultSize(width: 1000, height: 700)
        #endif
    }
}

/// Beim Start: Bank-Auswahl. Nach Tipp auf „Start“ → Aktien-App. Keine Bank automatisch – bei leerer Liste immer Startseite.
private struct RootView: View {
    @Bindable private var startState = StartState.shared

    var body: some View {
        Group {
            if BankStore.loadBanks().isEmpty {
                BankStartView()
            } else if startState.hasStarted {
                ContentView()
            } else {
                BankStartView()
            }
        }
        .id(startState.hasStarted)
        .onReceive(NotificationCenter.default.publisher(for: .returnToStartAfterImport)) { _ in
            startState.hasStarted = false
        }
    }
}
