//
//  SubscriptionManager.swift
//  Aktien
//
//  Prüft Abo-Status (StoreKit 2). 1 Woche kostenlos ab erstem Start, danach Premium-Abo nötig.
//

import Foundation
import StoreKit

/// Product-ID des Monats-Abos – muss in App Store Connect exakt so angelegt sein (inkl. 1-Woche-Trial).
private let premiumMonthlyProductID = "premium_monthly"

private let firstLaunchDateKey = "Aktien.SubscriptionManager.firstLaunchDate"
/// Nur sichtbar/wirksam bei Entwicklermodus (Einstellungen). Simuliert „Trial abgelaufen“ für Paywall-Tests.
private let simulateTrialExpiredKey = "Aktien.SubscriptionManager.simulateTrialExpired"
private let entwicklermodusKey = "Entwicklermodus"

@Observable
final class SubscriptionManager {
    static let shared = SubscriptionManager()

    /// Laden der Produkte läuft
    var isLoadingProducts = false
    /// Kauf läuft
    var isPurchasing = false
    /// Fehlermeldung für UI
    var errorMessage: String?

    /// Verfügbares Monats-Abo (nach loadProducts)
    private(set) var monthlyProduct: Product?

    /// true, sobald loadProducts() mindestens einmal durchgelaufen ist (dann wissen wir, ob das Produkt im Store existiert).
    private(set) var productsLoadAttempted = false

    /// Nutzer hat auf „Kostenlos testen“ getippt, obwohl kein Abo-Produkt geladen ist → Zugriff gewähren (z. B. vor Verkaufsversion).
    private(set) var allowAccessTappedWithoutProduct = false

    /// Erstes Öffnen der App (für 7-Tage-Test ohne Abo)
    var firstLaunchDate: Date {
        get {
            if let stored = UserDefaults.standard.object(forKey: firstLaunchDateKey) as? Date {
                return stored
            }
            let now = Date()
            UserDefaults.standard.set(now, forKey: firstLaunchDateKey)
            return now
        }
        set {
            UserDefaults.standard.set(newValue, forKey: firstLaunchDateKey)
        }
    }

    /// 1 Woche (7 Tage) in Sekunden
    private static let trialDuration: TimeInterval = 7 * 24 * 60 * 60

    /// true = Nutzer darf die App nutzen (1 Woche Trial oder aktives Abo). Demo-User (Login) gilt als abgelaufenes Abo → Paywall für App-Store-Prüfung.
    var hasPremiumAccess: Bool {
        if AuthManager.shared.isDemoUser { return false }
        if simulateTrialExpired { return hasActiveSubscription }
        if allowAccessTappedWithoutProduct { return true }
        if productsLoadAttempted && monthlyProduct == nil { return true }
        if isInFreeTrialPeriod { return true }
        return hasActiveSubscription
    }

    /// Im Entwicklermodus: Schalter „Trial abgelaufen simulieren“ (nur für Tests)
    var simulateTrialExpired: Bool {
        get {
            guard UserDefaults.standard.bool(forKey: entwicklermodusKey) else { return false }
            return UserDefaults.standard.bool(forKey: simulateTrialExpiredKey)
        }
        set {
            UserDefaults.standard.set(newValue, forKey: simulateTrialExpiredKey)
        }
    }

    /// Noch innerhalb der 1 Woche ab erstem Start (ohne Abo). Demo-User: immer false (abgelaufenes Abo für Prüfer).
    var isInFreeTrialPeriod: Bool {
        if AuthManager.shared.isDemoUser { return false }
        return Date().timeIntervalSince(firstLaunchDate) < Self.trialDuration
    }

    /// Verbleibende Tage in der kostenlosen Testphase (0 wenn abgelaufen oder Abo aktiv). Für Anzeige „noch X Tage“.
    var trialRemainingDays: Int {
        guard isInFreeTrialPeriod else { return 0 }
        let remaining = Self.trialDuration - Date().timeIntervalSince(firstLaunchDate)
        return max(0, Int(ceil(remaining / (24 * 60 * 60))))
    }

    /// Aktives Abo (inkl. Apple-Trialphase des Abos)
    private(set) var hasActiveSubscription = false

    private var updates: Task<Void, Never>?

    private init() {
        updates = listenForTransactions()
        Task { await refreshSubscriptionStatus() }
    }

    deinit {
        updates?.cancel()
    }

    /// Produkte laden (StoreKit 2)
    func loadProducts() async {
        isLoadingProducts = true
        errorMessage = nil
        defer { isLoadingProducts = false }

        do {
            let products = try await Product.products(for: [premiumMonthlyProductID])
            await MainActor.run {
                monthlyProduct = products.first
                productsLoadAttempted = true
                if monthlyProduct == nil {
                    // Keine Verkaufsversion / Produkt noch nicht in App Store Connect → keine Fehlermeldung, hasPremiumAccess wird true
                } else {
                    errorMessage = nil
                }
            }
        } catch {
            await MainActor.run {
                productsLoadAttempted = true
                monthlyProduct = nil
                // Bei Fehler (z. B. kein Store) Zugriff erlauben, keine blockierende Meldung
            }
        }
    }

    /// Abo abschließen (7 Tage kostenlos, danach 9,99 €/Monat über Apple). Wenn kein Produkt (noch keine Verkaufsversion): Zugriff gewähren und zur App wechseln.
    func purchase() async {
        if monthlyProduct == nil {
            await loadProducts()
        }
        guard let product = monthlyProduct else {
            await MainActor.run {
                productsLoadAttempted = true
                allowAccessTappedWithoutProduct = true
                NotificationCenter.default.post(name: .subscriptionGrantAccessWithoutProduct, object: nil)
            }
            return
        }

        isPurchasing = true
        errorMessage = nil
        defer { isPurchasing = false }

        do {
            let result = try await product.purchase()
            switch result {
            case .success(let verification):
                switch verification {
                case .verified(let transaction):
                    await transaction.finish()
                    await refreshSubscriptionStatus()
                case .unverified(_, let error):
                    await MainActor.run { errorMessage = "Verifizierung fehlgeschlagen: \(error.localizedDescription)" }
                }
            case .userCancelled:
                break
            case .pending:
                await MainActor.run { errorMessage = "Kauf ausstehend (z. B. Freigabe erforderlich)." }
            @unknown default:
                break
            }
        } catch {
            await MainActor.run { errorMessage = error.localizedDescription }
        }
    }

    /// Käufe wiederherstellen (z. B. nach Gerätewechsel)
    func restore() async {
        isPurchasing = true
        errorMessage = nil
        defer { isPurchasing = false }

        do {
            try await AppStore.sync()
            await refreshSubscriptionStatus()
        } catch {
            await MainActor.run { errorMessage = error.localizedDescription }
        }
    }

    /// Abo-Status aus StoreKit lesen
    func refreshSubscriptionStatus() async {
        var hasSubscription = false
        for await result in Transaction.currentEntitlements {
            if case .verified(let transaction) = result {
                if transaction.productID == premiumMonthlyProductID {
                    hasSubscription = true
                    break
                }
            }
        }
        await MainActor.run {
            hasActiveSubscription = hasSubscription
        }
    }

    private func listenForTransactions() -> Task<Void, Never> {
        Task.detached { [weak self] in
            for await result in Transaction.updates {
                if case .verified(let transaction) = result {
                    await transaction.finish()
                }
                await self?.refreshSubscriptionStatus()
            }
        }
    }
}
