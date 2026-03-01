//
//  StartState.swift
//  Aktien
//

import SwiftUI

private let requiresAuthOnNextStartKey = "Aktien.RequiresAuthOnNextStart"

@Observable
final class StartState {
    static let shared = StartState()

    /// true = Nutzer hat „Start“ getippt → ContentView anzeigen
    var hasStarted = false

    /// Legacy: Früher genutzt, um in ContentView den Picker zu öffnen. Heute öffnet die Startseite den Picker direkt (pendingImportURLsFromStart).
    var pendingImportFromStart = false

    /// Vom Datei-Picker auf der Startseite gewählte URLs → ContentView verarbeitet sie beim Erscheinen (Picker öffnet sofort, ohne ContentView zu laden)
    var pendingImportURLsFromStart: [URL]?

    /// true = Beim nächsten „Start“ Face ID verlangen (wird nach „App beenden“ gesetzt)
    var requiresAuthOnNextStart: Bool {
        get { UserDefaults.standard.bool(forKey: requiresAuthOnNextStartKey) }
        set { UserDefaults.standard.set(newValue, forKey: requiresAuthOnNextStartKey) }
    }

    /// „App beenden“: Zur Startseite und beim nächsten Start Face ID verlangen
    func requestAuthOnNextStart() {
        requiresAuthOnNextStart = true
        hasStarted = false
    }

    private init() {}
}
