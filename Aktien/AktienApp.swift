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

/// Beim Start: Login (Demokonto für App-Store-Prüfung). Danach Bank-Auswahl → Einlese-Seite oder Paywall.
private struct RootView: View {
    @Bindable private var startState = StartState.shared
    @State private var subscriptionManager = SubscriptionManager.shared
    @State private var authManager = AuthManager.shared
    /// „Kostenlos testen“ ohne Produkt getippt → Wechsel zur Aktien-Ansicht (Notification sorgt für zuverlässiges Update).
    @State private var grantedAccessByButton = false
    /// Nutzer hat auf der Paywall „Weiter“ getippt (Trial) → freie Tage gesehen, jetzt ContentView zeigen.
    @State private var trialPaywallAcknowledged = false

    private var showContentView: Bool {
        subscriptionManager.hasPremiumAccess || grantedAccessByButton
    }

    /// Paywall anzeigen: wenn kein Zugriff (blockierend) oder wenn Trial (Nutzer soll freie Tage sehen, dann „Weiter“).
    private var showPaywallBeforeContent: Bool {
        guard startState.hasStarted, showContentView else { return !showContentView && startState.hasStarted }
        return subscriptionManager.isInFreeTrialPeriod && !trialPaywallAcknowledged
    }

    var body: some View {
        Group {
            if !authManager.isLoggedIn {
                LoginView()
            } else if BankStore.loadBanks().isEmpty {
                BankStartView()
            } else if startState.hasStarted {
                if showPaywallBeforeContent {
                    PaywallView()
                } else {
                    ContentView()
                }
            } else {
                BankStartView()
            }
        }
        .id("\(authManager.isLoggedIn)-\(startState.hasStarted)")
        .onChange(of: startState.hasStarted) { _, new in
            if !new {
                grantedAccessByButton = false
                trialPaywallAcknowledged = false
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .returnToStartAfterImport)) { _ in
            startState.hasStarted = false
        }
        .onReceive(NotificationCenter.default.publisher(for: .subscriptionGrantAccessWithoutProduct)) { _ in
            grantedAccessByButton = true
        }
        .onReceive(NotificationCenter.default.publisher(for: .paywallTrialAcknowledged)) { _ in
            trialPaywallAcknowledged = true
        }
    }
}
