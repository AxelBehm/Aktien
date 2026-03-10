//
//  AktienApp.swift
//  Aktien
//
//  Created by Axel Behm on 28.01.26.
//

import SwiftUI
import SwiftData
#if os(iOS)
import UIKit
#elseif os(macOS)
import AppKit
#endif

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
    @Environment(\.scenePhase) private var scenePhase
    @Bindable private var startState = StartState.shared
    @State private var subscriptionManager = SubscriptionManager.shared
    @State private var authManager = AuthManager.shared
    /// „Kostenlos testen“ ohne Produkt getippt → Wechsel zur Aktien-Ansicht (Notification sorgt für zuverlässiges Update).
    @State private var grantedAccessByButton = false
    /// Nutzer hat auf der Paywall „Weiter“ getippt (Trial) → freie Tage gesehen, jetzt ContentView zeigen.
    @State private var trialPaywallAcknowledged = false
    /// Auf iPhone: Inhalt erst anzeigen, wenn Scene aktiv ist (vermeidet weißen Bildschirm beim manuellen Öffnen).
    @State private var sceneBecameActive = false

    private static var systemBackground: Color {
        #if os(iOS)
        Color(uiColor: .systemBackground)
        #else
        Color(nsColor: .windowBackgroundColor)
        #endif
    }

    /// Auf iPhone oft .inactive beim ersten Frame; erst bei .active zuverlässig layouten.
    private var mayShowContent: Bool {
        #if os(iOS)
        return sceneBecameActive
        #else
        return true
        #endif
    }

    private var showContentView: Bool {
        subscriptionManager.hasPremiumAccess || grantedAccessByButton
    }

    /// Paywall anzeigen: wenn kein Zugriff (blockierend) oder wenn Trial (Nutzer soll freie Tage sehen, dann „Weiter“).
    private var showPaywallBeforeContent: Bool {
        guard startState.hasStarted, showContentView else { return !showContentView && startState.hasStarted }
        return subscriptionManager.isInFreeTrialPeriod && !trialPaywallAcknowledged
    }

    var body: some View {
        ZStack {
            if mayShowContent {
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
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Self.systemBackground)
            }

            if !mayShowContent {
                VStack(spacing: 12) {
                    ProgressView()
                    Text("Laden…")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Self.systemBackground)
            }
        }
        .id("\(authManager.isLoggedIn)-\(startState.hasStarted)")
        .onChange(of: scenePhase) { _, newPhase in
            if newPhase == .active {
                sceneBecameActive = true
            }
        }
        .onAppear {
            if scenePhase == .active {
                sceneBecameActive = true
            }
            #if os(iOS)
            // Fallback: Nach 1,5 s Inhalt anzeigen (falls scenePhase auf iPhone nicht zu .active wechselt).
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                sceneBecameActive = true
            }
            #endif
        }
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
