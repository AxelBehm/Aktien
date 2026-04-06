//
//  LoginView.swift
//  Aktien
//
//  Einfacher Login für App-Store-Prüfung. Demo-Account führt zu abgelaufenem Abo (Paywall testbar).
//

import SwiftUI

struct LoginView: View {
    @State private var username = ""
    @State private var password = ""
    @State private var errorMessage: String?
    @State private var authManager = AuthManager.shared

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Benutzername", text: $username)
                        .textContentType(.username)
                        .autocorrectionDisabled()
                    SecureField("Passwort", text: $password)
                        .textContentType(.password)
                } header: {
                    Text("Anmeldung")
                } footer: {
                    Text("Zugangsdaten für das Demokonto erhalten Sie vom Entwickler bzw. sind in App Store Connect unter „App-Prüfinformationen“ hinterlegt.")
                }

                if let msg = errorMessage {
                    Section {
                        Text(msg)
                            .foregroundColor(.red)
                            .font(.subheadline)
                    }
                }

                Section {
                    Button("Anmelden") {
                        attemptLogin()
                    }
                    .disabled(username.trimmingCharacters(in: .whitespaces).isEmpty || password.isEmpty)
                }
                Section {
                    Button("Ohne Anmeldung fortfahren") {
                        authManager.continueWithoutLogin()
                    }
                    .foregroundStyle(.secondary)
                } footer: {
                    Text("Normale Nutzer können so direkt in die App. Die Anmeldung dient nur dem Demokonto für die App-Prüfung.")
                }
            }
            .navigationTitle("Aktien-Kursziele")
        }
    }

    private func attemptLogin() {
        errorMessage = nil
        if authManager.login(username: username, password: password) {
            // State updated, RootView will show main app
        } else {
            errorMessage = "Benutzername oder Passwort ungültig. Bitte die Zugangsdaten für das Demokonto verwenden."
        }
    }
}

#Preview {
    LoginView()
}
