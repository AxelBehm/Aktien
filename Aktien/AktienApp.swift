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

/// Beim Start: Bank-Auswahl. Nach Tipp auf „Start“ → Einlese-Seite (mit Premium) oder direkt Seite „Aktien Premium“ (Paywall).
private struct RootView: View {
    @Bindable private var startState = StartState.shared
    @State private var subscriptionManager = SubscriptionManager.shared
    /// „Kostenlos testen“ ohne Produkt getippt → Wechsel zur Aktien-Ansicht (Notification sorgt für zuverlässiges Update).
    @State private var grantedAccessByButton = false

    private var showContentView: Bool {
        subscriptionManager.hasPremiumAccess || grantedAccessByButton
    }

    var body: some View {
        Group {
            if BankStore.loadBanks().isEmpty {
                BankStartView()
            } else if startState.hasStarted {
                if showContentView {
                    ContentView()
                } else {
                    PaywallView()
                }
            } else {
                BankStartView()
            }
        }
        .id(startState.hasStarted)
        .onChange(of: startState.hasStarted) { _, new in
            if !new { grantedAccessByButton = false }
        }
        .onReceive(NotificationCenter.default.publisher(for: .returnToStartAfterImport)) { _ in
            startState.hasStarted = false
        }
        .onReceive(NotificationCenter.default.publisher(for: .subscriptionGrantAccessWithoutProduct)) { _ in
            grantedAccessByButton = true
        }
    }
}
