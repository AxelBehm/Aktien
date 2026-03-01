//
//  LocalAuthHelper.swift
//  Aktien
//

import LocalAuthentication

/// Face ID / Touch ID ausführen. Completion auf Main Thread.
func performDeviceAuth(localizedReason: String = "Bitte authentifizieren", completion: @escaping (Bool) -> Void) {
    let context = LAContext()
    var error: NSError?
    if context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &error) {
        context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: localizedReason) { success, _ in
            DispatchQueue.main.async { completion(success) }
        }
    } else {
        DispatchQueue.main.async { completion(false) }
    }
}
