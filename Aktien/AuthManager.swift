//
//  AuthManager.swift
//  Aktien
//
//  Einfacher Login für App-Store-Prüfung: Demo-Account mit abgelaufenem Abo.
//  Zugangsdaten in App Store Connect unter „App-Prüfinformationen“ angeben.
//

import Foundation

/// Demo-Zugangsdaten für App-Store-Review (in App Store Connect eintragen).
private enum DemoCredentials {
    /// Benutzername für das Demokonto (z. B. in „App-Prüfinformationen“ angeben).
    static let username = "demo"
    /// Passwort für das Demokonto.
    static let password = "Review2025!"
}

private let keyIsLoggedIn = "Aktien.Auth.isLoggedIn"
private let keyUsername = "Aktien.Auth.username"
private let keyIsDemoUser = "Aktien.Auth.isDemoUser"

@Observable
final class AuthManager {
    static let shared = AuthManager()

    /// Stored properties, damit @Observable View-Updates auslöst; UserDefaults nur zur Persistenz.
    var isLoggedIn: Bool {
        didSet { UserDefaults.standard.set(isLoggedIn, forKey: keyIsLoggedIn) }
    }
    var loggedInUsername: String? {
        didSet { UserDefaults.standard.set(loggedInUsername, forKey: keyUsername) }
    }
    /// true = als Demo-User eingeloggt → Abo gilt als abgelaufen (Paywall für Prüfer).
    var isDemoUser: Bool {
        didSet { UserDefaults.standard.set(isDemoUser, forKey: keyIsDemoUser) }
    }

    private init() {
        self.isLoggedIn = UserDefaults.standard.bool(forKey: keyIsLoggedIn)
        self.loggedInUsername = UserDefaults.standard.string(forKey: keyUsername)
        self.isDemoUser = UserDefaults.standard.bool(forKey: keyIsDemoUser)
    }

    /// Prüft Anmeldedaten. Aktuell nur Demo-Account unterstützt.
    func login(username: String, password: String) -> Bool {
        let u = username.trimmingCharacters(in: .whitespaces)
        let p = password
        guard !u.isEmpty else { return false }
        if u.lowercased() == DemoCredentials.username.lowercased() && p == DemoCredentials.password {
            isLoggedIn = true
            loggedInUsername = u
            isDemoUser = true
            return true
        }
        return false
    }

    /// Ohne Demo-Anmeldung: Normaler Nutzer (Trial/Abo wie üblich). Für Käufer, die keine Prüfzugangsdaten haben.
    func continueWithoutLogin() {
        isLoggedIn = true
        loggedInUsername = nil
        isDemoUser = false
    }

    func logout() {
        isLoggedIn = false
        loggedInUsername = nil
        isDemoUser = false
    }
}
