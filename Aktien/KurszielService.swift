//
//  KurszielService.swift
//  Aktien
//
//  Created by Axel Behm on 28.01.26.
//

import Foundation

/// Quelle des Kursziels – für Anzeige "Y" (Yahoo), "F" (finanzen.net), "A" (OpenAI), "C" (CSV), "M" (FMP), "K" (KGV), "S" (Snippet), "D" (Demo)
enum KurszielQuelle: String {
    case yahoo = "Y"
    case finanzenNet = "F"
    case openAI = "A"
    case csv = "C"
    case fmp = "M"
    /// Kursziel aus KGV-Methode: EPS × faires KGV (FMP Key-Metrics, Alternative zu Analysten/OpenAI)
    case kgv = "K"
    /// Fonds-Fallback: erster Betrag aus Suchmaschinen-Snippet (DuckDuckGo)
    case suchmaschine = "S"
    /// Demo-Modus: plausible Beispielwerte ohne API-Keys (z. B. für App-Store-Review)
    case demo = "D"
    
    /// Anzeigename für UI (Statistik, Filter, Detail)
    var displayName: String {
        switch self {
        case .csv: return "CSV"
        case .fmp: return "FMP"
        case .openAI: return "OpenAI"
        case .kgv: return "KGV"
        case .finanzenNet: return "finanzen.net"
        case .yahoo: return "Yahoo"
        case .suchmaschine: return "Snippet"
        case .demo: return "Demo"
        }
    }
    
    /// Label für rohen Quell-Code (z. B. aus Aktie.kurszielQuelle), inkl. optional „manuell“
    static func label(for code: String, manuell: Bool = false) -> String {
        let name = KurszielQuelle(rawValue: code)?.displayName ?? code
        return manuell ? "\(name), manuell" : name
    }
}

struct KurszielInfo {
    let kursziel: Double
    let datum: Date?
    /// Durchschnitt Spalte 4 (z. B. Abstand), falls aus Tabelle ermittelt
    let spalte4Durchschnitt: Double?
    /// Quelle: Y = Yahoo, F = finanzen.net
    let quelle: KurszielQuelle
    /// Währung aus Quelldaten (EUR/USD), für Anzeige
    let waehrung: String?
    /// Hoch-/Niedrigziel, Analystenanzahl (FMP)
    let kurszielHigh: Double?
    let kurszielLow: Double?
    let kurszielAnalysten: Int?
    /// true = Wert unverändert übernehmen (nur eine andere Währung, keine Devisenumrechnung)
    let ohneDevisenumrechnung: Bool
    
    init(kursziel: Double, datum: Date?, spalte4Durchschnitt: Double?, quelle: KurszielQuelle, waehrung: String?, kurszielHigh: Double? = nil, kurszielLow: Double? = nil, kurszielAnalysten: Int? = nil, ohneDevisenumrechnung: Bool = false) {
        self.kursziel = kursziel
        self.datum = datum
        self.spalte4Durchschnitt = spalte4Durchschnitt
        self.quelle = quelle
        self.waehrung = waehrung
        self.kurszielHigh = kurszielHigh
        self.kurszielLow = kurszielLow
        self.kurszielAnalysten = kurszielAnalysten
        self.ohneDevisenumrechnung = ohneDevisenumrechnung
    }
}

class KurszielService {
    
    // Debug-Modus
    static var debugMode = true
    static var debugLog: [String] = []
    
    /// Demo-Modus: Kursziele ohne API-Keys (plausible Beispielwerte). Gilt bei Demo-Login; bei kostenlosem Zeitraum ohne FMP/OpenAI-Keys; ansonsten alter Schalter in UserDefaults.
    static let keyDemoMode = "KurszielService.demoMode"
    static var isDemoMode: Bool {
        get {
            if AuthManager.shared.isDemoUser { return true }
            if UserDefaults.standard.bool(forKey: keyDemoMode) { return true }
            // Kostenloser Zeitraum ohne API-Keys → Demo-Kursziele
            let trialOhneKeys = SubscriptionManager.shared.isInFreeTrialPeriod
                && (fmpAPIKey ?? "").trimmingCharacters(in: .whitespaces).isEmpty
                && (openAIAPIKey ?? "").trimmingCharacters(in: .whitespaces).isEmpty
            return trialOhneKeys
        }
        set { UserDefaults.standard.set(newValue, forKey: keyDemoMode) }
    }
    
    /// Liefert ein plausibles Mock-Kursziel (z. B. Referenzkurs × 1,12) für Demo-Modus.
    private static func mockKurszielInfo(for aktie: Aktie) -> KurszielInfo {
        let ref = aktie.kurs ?? aktie.einstandskurs ?? aktie.marktwertEUR.flatMap { aktie.bestand > 0 ? $0 / Double(aktie.bestand) : nil } ?? 100.0
        let ziel = (ref * 1.12 * 100).rounded() / 100
        return KurszielInfo(kursziel: ziel, datum: Date(), spalte4Durchschnitt: 12.0, quelle: .demo, waehrung: "EUR")
    }
    
    /// Zugriffe pro Plattform (für Statistik-Fenster); in UserDefaults persistiert
    private static let keyZugriffeFMP = "KurszielService.zugriffeFMP"
    private static let keyZugriffeFinanzenNet = "KurszielService.zugriffeFinanzenNet"
    private static let keyZugriffeYahoo = "KurszielService.zugriffeYahoo"
    private static let keyZugriffeOpenAI = "KurszielService.zugriffeOpenAI"
    static var zugriffeFMP: Int {
        get { UserDefaults.standard.integer(forKey: keyZugriffeFMP) }
        set { UserDefaults.standard.set(newValue, forKey: keyZugriffeFMP) }
    }
    static var zugriffeFinanzenNet: Int {
        get { UserDefaults.standard.integer(forKey: keyZugriffeFinanzenNet) }
        set { UserDefaults.standard.set(newValue, forKey: keyZugriffeFinanzenNet) }
    }
    static var zugriffeYahoo: Int {
        get { UserDefaults.standard.integer(forKey: keyZugriffeYahoo) }
        set { UserDefaults.standard.set(newValue, forKey: keyZugriffeYahoo) }
    }
    static var zugriffeOpenAI: Int {
        get { UserDefaults.standard.integer(forKey: keyZugriffeOpenAI) }
        set { UserDefaults.standard.set(newValue, forKey: keyZugriffeOpenAI) }
    }
    private static let keyZugriffeKGV = "KurszielService.zugriffeKGV"
    static var zugriffeKGV: Int {
        get { UserDefaults.standard.integer(forKey: keyZugriffeKGV) }
        set { UserDefaults.standard.set(newValue, forKey: keyZugriffeKGV) }
    }
    
    /// Setzt die Zugriffsstatistik auf 0 (wird zu Beginn jedes Kursziel-Durchlaufs aufgerufen, damit pro Durchlauf gezählt wird).
    static func resetZugriffeStatistik() {
        zugriffeFMP = 0
        zugriffeFinanzenNet = 0
        zugriffeYahoo = 0
        zugriffeOpenAI = 0
        zugriffeKGV = 0
    }
    
    /// Zuletzt ermittelte Wechselkurse (Frankfurter API) – nur Puffer für rateUSDtoEUR/rateGBPtoEUR/rateDKKtoEUR; vor jeder Nutzung per fetchAppWechselkurse() direkt neu geladen.
    static var appWechselkursUSDtoEUR: Double?
    static var appWechselkursGBPtoEUR: Double?
    static var appWechselkursDKKtoEUR: Double?
    
    /// Lädt USD→EUR, GBP→EUR und DKK→EUR (direkter API-Zugriff). Setzt appWechselkurs*; Rückgabe für UI-Anzeige.
    static func fetchAppWechselkurse() async -> (usdToEur: Double?, gbpToEur: Double?) {
        async let usd = fetchUSDtoEURRateInternal()
        async let gbp = fetchGBPtoEURRateInternal()
        async let dkk = fetchDKKtoEURRateInternal()
        let (usdVal, gbpVal, dkkVal) = await (usd, gbp, dkk)
        appWechselkursUSDtoEUR = usdVal
        appWechselkursGBPtoEUR = gbpVal
        appWechselkursDKKtoEUR = dkkVal
        debug("   💱 App-Wechselkurse: USD→EUR \(usdVal), GBP→EUR \(gbpVal), DKK→EUR \(dkkVal)")
        return (usdVal, gbpVal)
    }
    
    /// Für Umrechnung: USD→EUR (nach fetchAppWechselkurse oder Fallback 0.92)
    static func rateUSDtoEUR() -> Double {
        appWechselkursUSDtoEUR ?? 0.92
    }
    
    /// Für Umrechnung: GBP→EUR (nach fetchAppWechselkurse oder Fallback 1.17)
    static func rateGBPtoEUR() -> Double {
        appWechselkursGBPtoEUR ?? 1.17
    }
    
    /// Für Umrechnung: DKK→EUR (dänische Kronen, z. B. Novo Nordisk; Fallback ca. 0.13)
    static func rateDKKtoEUR() -> Double {
        appWechselkursDKKtoEUR ?? 0.13
    }
    
    static func clearDebugLog() {
        debugLog = []
    }
    
    /// Vor Abruf von FMP/OpenAI/Wechselkursen etc. aufrufen, damit keine alten URL-/Wechselkurs-Caches genutzt werden („erst beim 2. Mal“ vermeiden).
    static func clearCachesForApiCalls() {
        URLCache.shared.removeAllCachedResponses()
        appWechselkursUSDtoEUR = nil
        appWechselkursGBPtoEUR = nil
    }
    
    static func getDebugLog() -> [String] {
        return debugLog
    }
    
    /// Öffentlich für Debug-Ausgabe aus UI (z.B. vor OpenAI-Aufruf)
    static func debugAppend(_ message: String) {
        debug(message)
    }
    
    private static func debug(_ message: String) {
        if debugMode {
            let timestamp = DateFormatter.localizedString(from: Date(), dateStyle: .none, timeStyle: .medium)
            debugLog.append("[\(timestamp)] \(message)")
            print("[KurszielService] \(message)")
        }
    }
    
    private static let usTicker = Set(["AAPL", "MSFT", "AMZN", "GOOGL", "TSLA", "META"])
    /// UK-Aktien (LSE), FMP liefert GBP – werden in EUR umgerechnet
    private static let gbpTicker = Set(["GLEN", "HSBC", "BP", "SHEL", "VOD", "AZN", "GSK", "ULVR", "DGE", "RIO", "BHP", "NG", "LLOY", "BARC", "STAN"])

    /// US-Ticker: 2–5 Buchstaben, kein Börsensuffix (.DE, .F, .PA etc.) – FMP liefert USD
    private static func isLikelyUSTicker(_ symbol: String) -> Bool {
        let s = symbol.trimmingCharacters(in: .whitespaces).uppercased()
        guard s.count >= 2, s.count <= 5 else { return false }
        if s.contains(".") { return false }
        return s.allSatisfy { $0.isLetter }
    }
    
    /// Ruft Kursziel direkt für eine WKN oder URL ab (für Testzwecke)
    static func fetchKurszielByWKN(_ wkn: String) async -> KurszielInfo? {
        clearDebugLog()
        if isDemoMode {
            let ziel = 118.50
            debug("✅ Demo-Modus: Kursziel \(ziel) EUR")
            return KurszielInfo(kursziel: ziel, datum: Date(), spalte4Durchschnitt: 12.0, quelle: .demo, waehrung: "EUR")
        }
        guard !wkn.isEmpty else { 
            debug("❌ WKN/URL ist leer")
            return nil 
        }
        var wknOrUrl = wkn.trimmingCharacters(in: .whitespaces)
        if wknOrUrl.hasPrefix("https://") || wknOrUrl.hasPrefix("http://") {
            let ohneProtokoll = wknOrUrl.hasPrefix("https://") ? String(wknOrUrl.dropFirst(8)) : String(wknOrUrl.dropFirst(7))
            if !ohneProtokoll.contains("."), ohneProtokoll.count <= 12, ohneProtokoll.allSatisfy({ $0.isNumber || $0.isLetter }) {
                wknOrUrl = ohneProtokoll
                debug("   📌 Als WKN interpretiert: \(wknOrUrl)")
            }
        }
        
        // Prüfe ob es eine vollständige URL ist
        if wknOrUrl.hasPrefix("http://") || wknOrUrl.hasPrefix("https://") {
            debug("🔍 Starte Kursziel-Suche für URL: \(wknOrUrl)")
            if wknOrUrl.contains("financialmodelingprep.com") {
                if let info = await fetchKurszielFromFMPURL(wknOrUrl) {
                    debug("✅ FMP Erfolg: Kursziel = \(info.kursziel) \(info.waehrung ?? "EUR")")
                    return info
                }
                debug("❌ FMP: Kein Kursziel aus Response")
                return nil
            }
            if let info = await fetchKurszielFromURLWithTab(wknOrUrl) {
                debug("✅ Erfolg: Kursziel = \(info.kursziel) €")
                return info
            }
            debug("❌ Kein Kursziel gefunden")
            return nil
        }
        
        debug("🔍 Starte Kursziel-Suche für WKN: \(wknOrUrl)")
        
        // Testroutine: OpenAI zuerst
        debug("1️⃣ Versuche OpenAI für WKN: \(wknOrUrl)")
        if let info = await fetchKurszielVonOpenAI(wkn: wknOrUrl) {
            debug("✅ Erfolg: Kursziel = \(info.kursziel) \(info.waehrung ?? "EUR")")
            return info
        }
        debug("❌ Kein Kursziel gefunden")
        
        debug("2️⃣ Versuche finanzen.net/kursziele/\(wknOrUrl)")
        if let info = await fetchKurszielVonFinanzenNetKursziele(wkn: wknOrUrl) {
            debug("✅ Erfolg: Kursziel = \(info.kursziel) €")
            return info
        }
        debug("❌ Kein Kursziel gefunden")
        
        debug("3️⃣ Versuche finanzen.net/aktien/\(wknOrUrl)")
        if let info = await fetchKurszielVonFinanzenNet(wkn: wknOrUrl) {
            debug("✅ Erfolg: Kursziel = \(info.kursziel) €")
            return info
        }
        debug("❌ Kein Kursziel gefunden")
        
        debug("❌ Keine Methode erfolgreich für WKN \(wknOrUrl)")
        return nil
    }
    
    /// Ruft Kursziel für eine Aktie ab. Automatik nur noch: 1) FMP (wenn API-Key), 2) OpenAI (wenn API-Key). Finanzen.net/Yahoo/Ariva/Snippet aus Automatik entfernt (Lizenz).
    /// fmpResult: optionales Vorab-Ergebnis aus Bulk-FMP (wird zuerst geprüft, kein doppelter Abruf).
    static func fetchKursziel(for aktie: Aktie, fmpResult: KurszielInfo? = nil) async -> KurszielInfo? {
        if isDemoMode {
            let info = mockKurszielInfo(for: aktie)
            debug("✅ Demo-Modus: \(aktie.bezeichnung) → \(info.kursziel) €")
            return info
        }
        _ = await fetchAppWechselkurse()
        return await withTimeout(seconds: 20) {
            let refPrice = aktie.kurs ?? aktie.einstandskurs
            debug("🔍 Kursziel-Suche: \(aktie.bezeichnung) (WKN: \(aktie.wkn))")
            if let ref = refPrice { debug("📊 Referenzkurs: \(ref) €") }
            
            func nehmenWennRealistisch(_ info: KurszielInfo?) async -> KurszielInfo? {
                guard let info = info, info.kursziel > 0 else { return nil }
                let eurInfo = await kurszielZuEUR(info: info, aktie: aktie)
                guard isKurszielRealistisch(kursziel: eurInfo.kursziel, refPrice: refPrice) else { return nil }
                return eurInfo
            }
            
            let letzteQuelle = (aktie.kurszielQuelle?.trimmingCharacters(in: .whitespaces)).flatMap { KurszielQuelle(rawValue: $0) }
            let bereitsErstversuch: KurszielQuelle? = letzteQuelle
            if let q = letzteQuelle, q != .csv {
                debug("   ⏩ Zuerst erneuter Versuch über zuletzt erfolgreiche Quelle: \(q.rawValue)")
                switch q {
                case .fmp:
                    var fmp: KurszielInfo? = (fmpResult != nil && (fmpResult?.kursziel ?? 0) > 0) ? fmpResult : nil
                    if fmp == nil { fmp = await fetchKurszielFromFMP(for: aktie) }
                    if let fmp = fmp, fmp.kursziel > 0 {
                        let eurInfo = await kurszielZuEUR(info: fmp, aktie: aktie)
                        if isKurszielRealistisch(kursziel: eurInfo.kursziel, refPrice: refPrice) {
                            if fmpResult == nil { zugriffeFMP += 1 }
                            debug("   → FMP (Erstversuch): \(eurInfo.kursziel) € (übernommen)")
                            return eurInfo
                        }
                    }
                case .finanzenNet, .yahoo, .suchmaschine:
                    debug("   → Quelle \(q.rawValue) in Automatik deaktiviert (Lizenz), weiter mit FMP/OpenAI")
                case .openAI:
                    let hatOpenAIKey = (openAIAPIKey?.trimmingCharacters(in: .whitespacesAndNewlines)).map { !$0.isEmpty } ?? false
                    if hatOpenAIKey, let info = await fetchKurszielVonOpenAI(wkn: aktie.wkn, bezeichnung: aktie.bezeichnung, isin: aktie.isin),
                       let eurInfo = await nehmenWennRealistisch(info) {
                        debug("   → OpenAI (Erstversuch): \(eurInfo.kursziel) € (übernommen)")
                        return eurInfo
                    }
                case .kgv:
                    if let info = await fetchKurszielFromFMPKGV(for: aktie),
                       let eurInfo = await nehmenWennRealistisch(info) {
                        zugriffeKGV += 1
                        debug("   → KGV (Erstversuch): \(eurInfo.kursziel) € (übernommen)")
                        return eurInfo
                    }
                case .csv, .demo:
                    break
                }
                if letzteQuelle != .finanzenNet, letzteQuelle != .yahoo, letzteQuelle != .suchmaschine {
                    debug("   → Erstversuch über \(letzteQuelle!.rawValue) ohne Treffer, weiter mit fester Reihenfolge")
                }
            }
            
            // 1. FMP – nur wenn API-Key gesetzt
            if bereitsErstversuch != .fmp {
                let hatFMPKey = (fmpAPIKey?.trimmingCharacters(in: .whitespacesAndNewlines)).map { !$0.isEmpty } ?? false
                if hatFMPKey {
                    var fmp: KurszielInfo? = (fmpResult != nil && (fmpResult?.kursziel ?? 0) > 0) ? fmpResult : nil
                    if fmp == nil { fmp = await fetchKurszielFromFMP(for: aktie) }
                    if let fmp = fmp, fmp.kursziel > 0 {
                        let eurInfo = await kurszielZuEUR(info: fmp, aktie: aktie)
                        if isKurszielRealistisch(kursziel: eurInfo.kursziel, refPrice: refPrice) {
                            if fmpResult == nil { zugriffeFMP += 1 }
                            debug("   → FMP: \(eurInfo.kursziel) € (übernommen)")
                            return eurInfo
                        }
                    }
                    debug("   → FMP: nichts oder unrealistisch, weiter mit OpenAI")
                } else {
                    debug("   → Kein FMP-Key, übersprungen")
                }
            }
            
            // 2. OpenAI – nur wenn API-Key gesetzt
            if bereitsErstversuch != .openAI {
                let hatOpenAIKey = (openAIAPIKey?.trimmingCharacters(in: .whitespacesAndNewlines)).map { !$0.isEmpty } ?? false
                if hatOpenAIKey {
                    if let info = await fetchKurszielVonOpenAI(wkn: aktie.wkn, bezeichnung: aktie.bezeichnung, isin: aktie.isin),
                       let eurInfo = await nehmenWennRealistisch(info) {
                        debug("   → OpenAI: \(eurInfo.kursziel) € (übernommen)")
                        return eurInfo
                    }
                    debug("   → OpenAI: nichts oder unrealistisch, weiter mit KGV")
                }
            }
            
            // 3. KGV (FMP Key-Metrics: EPS × faires KGV) – nur wenn FMP-Key als API-Key (nicht Voll-URL) gesetzt
            if bereitsErstversuch != .kgv, fmpKeyMetricsURL(symbol: "AAPL") != nil {
                if let info = await fetchKurszielFromFMPKGV(for: aktie),
                   let eurInfo = await nehmenWennRealistisch(info) {
                    zugriffeKGV += 1
                    debug("   → KGV: \(eurInfo.kursziel) € (übernommen)")
                    return eurInfo
                }
                debug("   → KGV: nichts oder unrealistisch")
            }
            debug("   → Ende (kein Kursziel ermittelt)")
            return nil
        }
    }
    
    /// true wenn Gattung "Fonds" enthält (nur für Fonds wird der Snippet-Fallback genutzt)
    private static func istFonds(_ aktie: Aktie) -> Bool {
        aktie.istFonds
    }
    
    /// Öffentlich für FMP-Bulk/Form: Wendet bei unrealistischem Kursziel OpenAI-Versuch an. Gibt Ersatz oder Original zurück.
    static func applyOpenAIFallbackBeiUnrealistisch(info: KurszielInfo, refPrice: Double?, aktie: Aktie) async -> KurszielInfo {
        if let replacement = await beiUnrealistischOpenAIVersuchen(eurInfo: info, refPrice: refPrice, aktie: aktie) {
            return replacement
        }
        return info
    }
    
    /// Optional: Callback für „Übernehmen?“ wenn OpenAI-Ersatz bei unrealistischem Kursziel (bei automatischer Einlesung nicht aufrufen / false zurückgeben)
    static var onUnrealistischErsatzBestätigen: ((KurszielInfo, KurszielInfo, Aktie) async -> Bool)?
    
    /// Prüft, ob ein Kursziel für einen Referenzkurs „realistisch“ ist (Plausibilität + Abstand ≤ Schwellwert wie zeigeAlsUnrealistisch; Abwärts max. 50 %).
    static func isKurszielRealistisch(kursziel: Double, refPrice: Double?) -> Bool {
        guard let k = refPrice, k > 0 else { return true }
        if kursziel < k * 0.5 || kursziel > k * 50 { return false }
        let pct = abs((kursziel - k) / k * 100)
        let schwellwert = kursziel > k ? 200.0 : 50.0
        return pct <= schwellwert
    }
    
    /// Wenn Kursziel unrealistisch wäre (Abstand > Schwellwert) und API-Key da: versucht OpenAI als Ersatz
    private static func beiUnrealistischOpenAIVersuchen(eurInfo: KurszielInfo, refPrice: Double?, aktie: Aktie) async -> KurszielInfo? {
        guard let k = refPrice ?? aktie.devisenkurs, k > 0 else { return nil }
        let kz = eurInfo.kursziel
        if kz < k * 0.5 || kz > k * 50 { return nil }
        let pct = abs((kz - k) / k * 100)
        let schwellwert = kz > k ? 200.0 : 50.0
        if pct <= schwellwert { return nil }
        guard openAIAPIKey != nil else { return nil }
        debug("   ⚠️ Kursziel \(String(format: "%.2f", kz)) würde als unrealistisch gelten (Abstand \(Int(pct))%). Versuche OpenAI.")
        guard let openAIInfo = await fetchKurszielVonOpenAI(wkn: aktie.wkn, bezeichnung: aktie.bezeichnung, isin: aktie.isin) else { return nil }
        let replacement = await kurszielZuEUR(info: openAIInfo, aktie: aktie)
        if let callback = onUnrealistischErsatzBestätigen {
            let ok = await callback(eurInfo, replacement, aktie)
            return ok ? replacement : nil
        }
        return replacement
    }
    
    /// URL für Snippet-Suche (DuckDuckGo) – zum Anzeigen/Öffnen in der UI
    static func snippetSuchergebnisURL(for aktie: Aktie) -> URL? {
        let query = (aktie.isin + " Kursziel").addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? (aktie.isin + " Kursziel")
        return URL(string: "https://html.duckduckgo.com/html/?q=\(query)")
    }
    
    /// Snippet-Test für Fonds (öffentlich, für Test-Sheet)
    static func fetchKurszielFromSnippet(for aktie: Aktie) async -> KurszielInfo? {
        clearDebugLog()
        debug("━━━ Snippet-Test (DuckDuckGo): \(aktie.bezeichnung) ━━━")
        guard let info = await fetchKurszielVonSuchmaschinenSnippet(aktie: aktie) else { return nil }
        return await kurszielZuEUR(info: info, aktie: aktie)
    }
    
    /// Fonds-Fallback: DuckDuckGo HTML-Suche, erster Betrag mit €/$/EUR im Snippet. Gekapselt, nur für Fonds.
    private static func fetchKurszielVonSuchmaschinenSnippet(aktie: Aktie) async -> KurszielInfo? {
        let query = (aktie.isin + " Kursziel").addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? (aktie.isin + " Kursziel")
        guard let url = URL(string: "https://html.duckduckgo.com/html/?q=\(query)") else { return nil }
        do {
            var request = URLRequest(url: url)
            request.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15", forHTTPHeaderField: "User-Agent")
            request.timeoutInterval = 8
            let (data, _) = try await URLSession.shared.data(for: request)
            guard let html = String(data: data, encoding: .utf8) else { return nil }
            // Erste ~100 Zeilen Text (Tags entfernt, grob)
            let text = html
                .replacingOccurrences(of: "<[^>]+>", with: " ", options: .regularExpression)
                .replacingOccurrences(of: "&nbsp;", with: " ")
                .replacingOccurrences(of: "&#x27;", with: "'")
            let lines = text.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            let relevant = Array(lines.prefix(120)).joined(separator: " ")
            // Erster Betrag mit €, $ oder EUR
            if let (betrag, waehrung) = erstesBetragMitWaehrung(in: relevant) {
                debug("   📄 Snippet-Betrag: \(betrag) \(waehrung)")
                return KurszielInfo(kursziel: betrag, datum: Date(), spalte4Durchschnitt: nil, quelle: .suchmaschine, waehrung: waehrung)
            }
        } catch {
            debug("   ❌ Snippet-Abruf Fehler: \(error.localizedDescription)")
        }
        return nil
    }
    
    /// Findet ersten Betrag mit €, $ oder EUR im Text. Rückgabe: (Double, "EUR"/"USD")
    private static func erstesBetragMitWaehrung(in text: String) -> (Double, String)? {
        // Muster: 282,78 EUR | 366,49 € | 50.00 $ | 1.234,56 EUR
        let patterns: [(String, String)] = [
            (#"(\d{1,6}[.,]\d{2})\s*€"#, "EUR"),
            (#"(\d{1,6}[.,]\d{2})\s*EUR"#, "EUR"),
            (#"(\d{1,6}[.,]\d{2})\s*\$"#, "USD"),
            (#"(\d{1,3}(?:\.\d{3})*,\d{2})\s*[€$]?"#, "EUR"),
            (#"(\d{1,3}(?:,\d{3})*\.\d{2})\s*\$"#, "USD")
        ]
        for (pattern, waehrung) in patterns {
            if let regex = try? NSRegularExpression(pattern: pattern),
               let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
               let range = Range(match.range(at: 1), in: text) {
                let numStr = String(text[range])
                if let d = parseBetragAusSnippet(numStr), d > 0, d < 1_000_000 {
                    return (d, waehrung)
                }
            }
        }
        return nil
    }
    
    /// Parst "282,78" oder "1.234,56" oder "50.00" zu Double
    private static func parseBetragAusSnippet(_ s: String) -> Double? {
        var cleaned = s.trimmingCharacters(in: .whitespaces)
        if cleaned.contains(".") && cleaned.contains(",") {
            cleaned = cleaned.replacingOccurrences(of: ".", with: "").replacingOccurrences(of: ",", with: ".")
        } else if cleaned.contains(",") {
            cleaned = cleaned.replacingOccurrences(of: ",", with: ".")
        }
        return Double(cleaned)
    }
    
    /// Suchbegriff für Yahoo (z.B. "Amazon.com Inc" -> "Amazon")
    private static func yahooSearchTerm(from bezeichnung: String) -> String? {
        var cleaned = bezeichnung
            .replacingOccurrences(of: " inc.", with: "")
            .replacingOccurrences(of: " inc", with: "")
            .replacingOccurrences(of: " ag", with: "")
            .replacingOccurrences(of: " se", with: "")
            .trimmingCharacters(in: .whitespaces)
        if let dotIndex = cleaned.firstIndex(of: ".") {
            cleaned = String(cleaned[..<dotIndex])
        }
        let parts = cleaned.split(separator: " ")
        return parts.first.map(String.init)
    }
    
    /// Ermittelt Yahoo-Ticker über Such-API (z.B. "Amazon" -> "AMZN")
    private static func fetchYahooTicker(searchTerm: String) async -> String? {
        guard !searchTerm.isEmpty else { return nil }
        let query = searchTerm.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? searchTerm
        let urlString = "https://query1.finance.yahoo.com/v1/finance/search?q=\(query)&quotesCount=5"
        
        guard let url = URL(string: urlString) else { return nil }
        
        do {
            var request = URLRequest(url: url)
            request.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15", forHTTPHeaderField: "User-Agent")
            request.timeoutInterval = 5.0
            
            let (data, _) = try await URLSession.shared.data(for: request)
            
            if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let quotes = json["quotes"] as? [[String: Any]] {
                for quote in quotes {
                    if let symbol = quote["symbol"] as? String,
                       let quoteType = quote["quoteType"] as? String,
                       quoteType == "EQUITY",
                       !symbol.contains(".") || symbol.hasSuffix(".DE") || symbol.hasSuffix(".F") {
                        return symbol
                    }
                }
            }
        } catch { }
        
        return nil
    }
    
    /// Liefert Slug-Kandidaten für Suche – voller Slug + Kurzform (z.B. "eli_lilly" für finanzen.net)
    /// finanzen.net nutzt oft kurze Slugs: "eli_lilly" statt "eli_lilly_and_company"
    /// Slug-Kandidaten für finanzen.net – verkürzte Begriffe (z.B. „Rheinmetall“ statt „Rheinmetall AG“) funktionieren oft besser
    static func slugKandidaten(from bezeichnung: String) -> [String] {
        let voll = slugFromBezeichnung(bezeichnung)
        guard !voll.isEmpty else { return [] }
        let stopWords = ["and", "the", "of", "&", "und", "der", "die", "das"]
        let woerter = voll.split(separator: "_").map(String.init)
        var kurzeWoerter: [String] = []
        for w in woerter {
            if stopWords.contains(w.lowercased()) { continue }
            kurzeWoerter.append(w)
            if kurzeWoerter.count >= 2 { break }  // Max. 2 bedeutungstragende Wörter
        }
        let kurz = kurzeWoerter.joined(separator: "_")
        let erstesWort = kurzeWoerter.first ?? ""
        var kandidaten: [String] = [voll]
        if kurz != voll && !kurz.isEmpty { kandidaten.append(kurz) }
        if !erstesWort.isEmpty && !kandidaten.contains(erstesWort) { kandidaten.append(erstesWort) }
        return kandidaten
    }
    
    /// Erstellt URL-Slug aus Firmenbezeichnung (z.B. "SAP SE" -> "sap_se", "Volkswagen AG VZ" -> "volkswagen_vz")
    /// Öffentlich für Verwendung in UI (z.B. Test-URL aus Bezeichnung bauen)
    static func slugFromBezeichnung(_ bezeichnung: String) -> String {
        var slug = bezeichnung
            .lowercased()
            .replacingOccurrences(of: "ä", with: "ae")
            .replacingOccurrences(of: "ö", with: "oe")
            .replacingOccurrences(of: "ü", with: "ue")
            .replacingOccurrences(of: "ß", with: "ss")
        
        // Typische Börsen-/Wertpapierbezeichnungen entfernen (z. B. Deutsche Bank AG Inhaber-Aktien o.N. -> Deutsche Bank)
        for suffix in [" inhaber-aktien o.n.", " inhaber-aktien", " na o.n.", " o.n.", " vink. namens-aktien", " namens-aktien"] {
            if slug.hasSuffix(suffix) {
                slug = String(slug.dropLast(suffix.count)).trimmingCharacters(in: .whitespaces)
            }
            slug = slug.replacingOccurrences(of: suffix, with: " ")
        }
        slug = slug.trimmingCharacters(in: .whitespaces)
        
        // Firmenrechtsformen entfernen (als Wort, nicht nur am Ende)
        for suffix in [" ag ", " se ", " gmbh ", " kg ", " co. ", " inc. ", " plc "] {
            slug = slug.replacingOccurrences(of: suffix, with: " ")
        }
        // Auch am Ende
        for suffix in [" ag", " se", " gmbh", " kg", " inc", " inc.", " co", " co."] {
            if slug.hasSuffix(suffix) {
                slug = String(slug.dropLast(suffix.count))
            }
        }
        
        // Mehrfache Leerzeichen zusammenführen
        while slug.contains("  ") {
            slug = slug.replacingOccurrences(of: "  ", with: " ")
        }
        slug = slug.trimmingCharacters(in: .whitespaces)
        
        // "amazon.com" -> "amazon" (Teil vor dem Punkt für Domains)
        if let dotIndex = slug.firstIndex(of: ".") {
            slug = String(slug[..<dotIndex])
        }
        
        slug = slug
            .replacingOccurrences(of: " ", with: "_")
            .replacingOccurrences(of: "-", with: "_")
            .filter { $0.isLetter || $0.isNumber || $0 == "_" }
        
        return slug
    }
    
    /// Prüft ob ein Kursziel plausibel ist (filtert z.B. 0,50€ oder 13€ bei Kurs 30€)
    private static func isValidKursziel(_ kursziel: Double, referencePrice: Double?) -> Bool {
        guard kursziel >= 1.0 else { return false }
        
        if let ref = referencePrice, ref > 0 {
            // Kursziel muss mind. 50 % des aktuellen Kurses sein (Abwärts nicht zu extrem)
            guard kursziel >= ref * 0.5 else { return false }
            // Kursziel sollte nicht mehr als 50x des aktuellen Kurses sein
            guard kursziel <= ref * 50 else { return false }
        }
        
        return true
    }
    
    /// Helper: Timeout für async Tasks
    private static func withTimeout<T>(seconds: TimeInterval, operation: @escaping () async -> T?) async -> T? {
        await withTaskGroup(of: T?.self) { group in
            group.addTask {
                await operation()
            }
            
            group.addTask {
                try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                return nil
            }
            
            let result = await group.next()
            group.cancelAll()
            return result ?? nil
        }
    }
    
    /// Ruft Kursziel von Yahoo Finance ab (inoffizielle API)
    private static func fetchKurszielVonYahoo(symbol: String) async -> KurszielInfo? {
        zugriffeYahoo += 1
        // Yahoo Finance verwendet normalerweise Ticker-Symbole
        // Für deutsche Aktien: Versuche verschiedene Formate
        let symbols = [
            symbol,
            "\(symbol).DE",  // Deutsche Börse
            "\(symbol).F",   // Frankfurt
            "\(symbol).XETRA" // XETRA
        ]
        
        let baseURLs = ["https://query1.finance.yahoo.com", "https://query2.finance.yahoo.com"]
        
        for ticker in symbols {
            for baseURL in baseURLs {
                let urlString = "\(baseURL)/v10/finance/quoteSummary/\(ticker)?modules=financialData"
                
                guard let url = URL(string: urlString) else { continue }
                
                do {
                    var request = URLRequest(url: url)
                    request.setValue("Mozilla/5.0", forHTTPHeaderField: "User-Agent")
                    request.timeoutInterval = 10.0
                    
                    let (data, response) = try await URLSession.shared.data(for: request)
                    
                    guard let httpResponse = response as? HTTPURLResponse,
                          httpResponse.statusCode == 200 else { continue }
                    
                    if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                       let quoteSummary = json["quoteSummary"] as? [String: Any],
                       let result = quoteSummary["result"] as? [[String: Any]],
                       let firstResult = result.first,
                       let financialData = firstResult["financialData"] as? [String: Any] {
                        
                        if let targetMeanPrice = financialData["targetMeanPrice"] as? [String: Any],
                           let raw = targetMeanPrice["raw"] as? Double {
                            return KurszielInfo(kursziel: raw, datum: Date(), spalte4Durchschnitt: nil, quelle: .yahoo, waehrung: "USD")
                        }
                        if let targetHighPrice = financialData["targetHighPrice"] as? [String: Any],
                           let raw = targetHighPrice["raw"] as? Double {
                            return KurszielInfo(kursziel: raw, datum: Date(), spalte4Durchschnitt: nil, quelle: .yahoo, waehrung: "USD")
                        }
                    }
                } catch {
                    continue
                }
            }
        }
        
        // Fallback: Versuche Web Scraping
        return await fetchKurszielVonYahooWeb(symbol: symbol)
    }
    
    /// Fallback: Versucht Kursziel von Yahoo Finance Web-Seite zu scrapen
    private static func fetchKurszielVonYahooWeb(symbol: String) async -> KurszielInfo? {
        // Yahoo Finance URL für deutsche Aktien (oft mit .DE oder .F Suffix)
        let urlString = "https://finance.yahoo.com/quote/\(symbol)"
        
        guard let url = URL(string: urlString) else { return nil }
        
        do {
            var request = URLRequest(url: url)
            request.setValue("Mozilla/5.0", forHTTPHeaderField: "User-Agent")
            request.timeoutInterval = 10.0 // 10 Sekunden Timeout
            
            let (data, _) = try await URLSession.shared.data(for: request)
            
            if let html = String(data: data, encoding: .utf8) {
                // Suche nach "target" oder "price target" im HTML
                // Dies ist eine vereinfachte Suche - für robustere Lösung würde man HTML-Parser verwenden
                if let (kursziel, spalte4, waehrung, _) = parseKurszielFromHTML(html) {
                    return KurszielInfo(kursziel: kursziel, datum: Date(), spalte4Durchschnitt: spalte4, quelle: .yahoo, waehrung: waehrung ?? "USD")
                }
            }
        } catch {
            print("Fehler beim Abrufen von Yahoo Finance: \(error)")
        }
        
        return nil
    }
    
    /// Ruft Kursziel von finanzen.net ab (mit Firmen-Slug aus Bezeichnung)
    private static func fetchKurszielVonFinanzenNet(slug: String) async -> KurszielInfo? {
        // finanzen.net/kursziele/{slug} – dedizierte Kursziel-Seite
        let urlString = "https://www.finanzen.net/kursziele/\(slug)"
        return await fetchKurszielFromURL(urlString)
    }
    
    /// Ruft Kursziel von finanzen.net ab (mit WKN – Aktien-Seite)
    private static func fetchKurszielVonFinanzenNet(wkn: String) async -> KurszielInfo? {
        let url = "https://www.finanzen.net/aktien/\(wkn)"
        debug("   📡 HTTP GET: \(url)")
        let result = await fetchKurszielFromURL(url)
        if let info = result {
            debug("   ✅ Kursziel geparst: \(info.kursziel) €")
        } else {
            debug("   ❌ Kein Kursziel aus HTML geparst")
        }
        return result
    }
    
    /// Ermittelt ISIN aus WKN (z. B. für Einlesung ohne ISIN-Spalte). Lädt finanzen.net/aktien/WKN und parst ISIN aus dem HTML.
    static func fetchISINFromWKN(wkn: String) async -> String? {
        let w = wkn.trimmingCharacters(in: .whitespaces)
        guard w.count >= 5, w.count <= 10 else { return nil }
        guard let url = URL(string: "https://www.finanzen.net/aktien/\(w)") else { return nil }
        do {
            var request = URLRequest(url: url)
            request.setValue("Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Mobile/15E148 Safari/604.1", forHTTPHeaderField: "User-Agent")
            request.setValue("de-DE,de;q=0.9,en;q=0.8", forHTTPHeaderField: "Accept-Language")
            request.setValue("https://www.finanzen.net/", forHTTPHeaderField: "Referer")
            request.timeoutInterval = 10.0
            let (data, _) = try await URLSession.shared.data(for: request)
            guard let html = String(data: data, encoding: .utf8) else { return nil }
            let isinPattern = "[A-Z]{2}[A-Z0-9]{9}[0-9]"
            guard let regex = try? NSRegularExpression(pattern: isinPattern) else { return nil }
            let range = NSRange(html.startIndex..., in: html)
            let matches = regex.matches(in: html, options: [], range: range)
            let bekanntePraefixe = ["DE", "US", "XS", "AT", "FR", "LU", "GB", "IE", "CH", "NL"]
            for match in matches {
                guard let r = Range(match.range, in: html) else { continue }
                let candidate = String(html[r])
                if candidate.count == 12, bekanntePraefixe.contains(where: { candidate.hasPrefix($0) }) {
                    return candidate
                }
            }
            if let first = matches.first, let r = Range(first.range, in: html) {
                return String(html[r])
            }
        } catch { }
        return nil
    }
    
    /// Ruft Kursziel von finanzen.net ab (Kursziel-Seite mit Slug, z.B. rheinmetall)
    /// Versucht auch Unterstrich→Bindestrich (finanzen.net nutzt oft Bindestriche)
    private static func fetchKurszielVonFinanzenNetKursziele(slug: String) async -> KurszielInfo? {
        var urls = ["https://www.finanzen.net/kursziele/\(slug)"]
        if slug.contains("_") {
            urls.append("https://www.finanzen.net/kursziele/\(slug.replacingOccurrences(of: "_", with: "-"))")
        }
        for urlString in urls {
            debug("   📡 HTTP GET: \(urlString)")
            if let info = await fetchKurszielFromURL(urlString) { return info }
        }
        return nil
    }
    
    /// Ruft Kursziel von finanzen.net ab (Kursziel-Seite mit WKN)
    private static func fetchKurszielVonFinanzenNetKursziele(wkn: String) async -> KurszielInfo? {
        // Versuche verschiedene URLs für finanzen.net
        let urls = [
            "https://www.finanzen.net/kursziele/\(wkn)",  // Direkte Kursziel-Seite
            "https://www.finanzen.net/aktien/\(wkn)/kursziele",  // Alternative URL
            "https://www.finanzen.net/aktien/\(wkn)#news-analysen"  // Mit Tab-Anker
        ]
        
        for url in urls {
            debug("   📡 HTTP GET: \(url)")
            if let info = await fetchKurszielFromURLWithTab(url) {
                debug("   ✅ Kursziel geparst: \(info.kursziel) €")
                return info
            }
        }
        
        debug("   ❌ Kein Kursziel aus HTML geparst")
        return nil
    }
    
    /// Ruft Kursziel ausschließlich von finanzen.net ab (für Einzeltest mit Debug). Versucht Slug, WKN, Aktien-Seite, Suche.
    static func fetchKurszielFromFinanzenNet(for aktie: Aktie) async -> KurszielInfo? {
        zugriffeFinanzenNet += 1
        clearDebugLog()
        debug("━━━ finanzen.net EINZELTEST: \(aktie.bezeichnung) ━━━")
        debug("   WKN: \(aktie.wkn), ISIN: \(aktie.isin)")
        let slugKandidaten = slugKandidaten(from: aktie.bezeichnung)
        for slugVersuch in slugKandidaten {
            guard !slugVersuch.isEmpty else { continue }
            debug("   Versuche Slug: finanzen.net/kursziele/\(slugVersuch)")
            if let info = await fetchKurszielVonFinanzenNetKursziele(slug: slugVersuch) {
                debug("   ✅ Gefunden via Slug \(slugVersuch)")
                return await kurszielZuEUR(info: info, aktie: aktie)
            }
        }
        if !aktie.wkn.trimmingCharacters(in: .whitespaces).isEmpty {
            debug("   Versuche WKN: finanzen.net/kursziele/\(aktie.wkn)")
            if let info = await fetchKurszielVonFinanzenNetKursziele(wkn: aktie.wkn) {
                debug("   ✅ Gefunden via WKN")
                return await kurszielZuEUR(info: info, aktie: aktie)
            }
            debug("   Versuche finanzen.net/aktien/\(aktie.wkn)")
            if let info = await fetchKurszielVonFinanzenNet(wkn: aktie.wkn) {
                debug("   ✅ Gefunden via Aktien-Seite")
                return await kurszielZuEUR(info: info, aktie: aktie)
            }
            debug("   Versuche finanzen.net Suche")
            if let info = await fetchKurszielVonFinanzenNetSearch(wkn: aktie.wkn) {
                debug("   ✅ Gefunden via Suche")
                return await kurszielZuEUR(info: info, aktie: aktie)
            }
        }
        debug("   ❌ Kein Kursziel von finanzen.net")
        return nil
    }
    
    /// URLs für finanzen.net-Test (Slug + WKN)
    static func finanzenNetBefehlForDisplay(for aktie: Aktie) -> [String] {
        var urls: [String] = []
        let slugs = slugKandidaten(from: aktie.bezeichnung)
        for s in slugs where !s.isEmpty {
            urls.append("https://www.finanzen.net/kursziele/\(s)")
        }
        if !aktie.wkn.trimmingCharacters(in: .whitespaces).isEmpty {
            urls.append("https://www.finanzen.net/kursziele/\(aktie.wkn)")
            urls.append("https://www.finanzen.net/aktien/\(aktie.wkn)")
        }
        return urls
    }
    
    /// Ruft Kursziel von finanzen.net ab (Suchseite mit WKN oder ISIN – leitet oft zur Aktienseite weiter)
    private static func fetchKurszielVonFinanzenNetSearch(wkn: String) async -> KurszielInfo? {
        await fetchKurszielVonFinanzenNetSearch(searchTerm: wkn)
    }
    
    /// Ruft Kursziel von finanzen.net ab (Suchseite mit Suchbegriff, z. B. WKN oder ISIN)
    private static func fetchKurszielVonFinanzenNetSearch(searchTerm: String) async -> KurszielInfo? {
        let encoded = searchTerm.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? searchTerm
        let searchURL = "https://www.finanzen.net/suchergebnis.asp?frmAktiensucheTextfeld=\(encoded)"
        debug("   📡 HTTP GET: \(searchURL)")
        let result = await fetchKurszielFromURL(searchURL)
        if let info = result {
            debug("   ✅ Kursziel geparst: \(info.kursziel) €")
        } else {
            debug("   ❌ Kein Kursziel aus HTML geparst")
        }
        return result
    }
    
    /// Kursziele aus CSV – iCloud Documents/kursziele.csv (Format: Wertpapier;Kursziel_EUR, Trennzeichen ;)
    static let kurszieleCSVFilename = "kursziele.csv"
    
    /// FMP (Financial Modeling Prep) API-Key
    static let fmpAPIKeyKey = "FMP_API_Key"
    static var fmpAPIKey: String? {
        get { UserDefaults.standard.string(forKey: fmpAPIKeyKey)?.trimmingCharacters(in: .whitespaces) }
        set { UserDefaults.standard.set(newValue, forKey: fmpAPIKeyKey) }
    }
    
    /// WKN → FMP-Symbol (XETRA = EUR). DB→DBK, 710000→MBG (Mercedes), 515100→DTE (Telekom).
    private static let fmpSymbolByWKN: [String: String] = [
        "716460": "SAP", "723610": "SIE", "519000": "ALV", "648300": "ADS",
        "604700": "BAS", "703000": "RHM", "710000": "MBG", "556520": "VOW3",
        "575200": "BMW", "623100": "BAYN", "843002": "HEN3", "823212": "MBG",
        "659990": "AM3D", "625409": "PUM", "514000": "DBK", "801440": "CBK",
        "515100": "DTE",  // Deutsche Telekom XETRA (nicht 710000 = Mercedes)
        "517010": "IFX", "587590": "1COV", "521380": "DB1", "520000": "PAH3",
        "865985": "AAPL", "881809": "MSFT", "906866": "AMZN", "883121": "GOOGL",
        "A0YEDG": "TSLA", "A1JWVX": "META",
        "A0D9U0": "VOW3", "A0B4X7": "PAH3",
        "766400": "EOAN", "606214": "CON", "555750": "LHA",
        "A1J0VJ": "GLEN"
    ]
    
    /// WKN aus deutscher ISIN (DE0007164600 → 716460)
    private static func wknFromGermanISIN(_ isin: String) -> String? {
        let s = isin.trimmingCharacters(in: .whitespaces).uppercased()
        guard s.hasPrefix("DE"), s.count >= 11, s.dropFirst(2).allSatisfy({ $0.isNumber }) else { return nil }
        return String(s.dropFirst(5).prefix(6))
    }
    
    /// FMP-Symbol aus WKN/ISIN/Bezeichnung ableiten
    private static func fmpSymbol(for aktie: Aktie) -> String? {
        let wkn = aktie.wkn.trimmingCharacters(in: .whitespaces)
        let wknNorm = wkn.isEmpty ? nil : wkn
        let wknAusIsin = wknFromGermanISIN(aktie.isin)
        for candidate in [wknNorm, wknAusIsin].compactMap({ $0 }) {
            if let sym = fmpSymbolByWKN[candidate] { return sym }
        }
        if aktie.isin.hasPrefix("US"), let ticker = usIsinToTicker[String(aktie.isin.prefix(12))] { return ticker }
        let slug = slugFromBezeichnung(aktie.bezeichnung)
        if slug == "sap" { return "SAP" }
        if slug == "siemens" { return "SIE" }
        if slug == "siemens_energy" || slug == "siemens energy" || slug == "siemensenergy" { return "ENR" }
        if slug == "allianz" { return "ALV" }
        if slug == "adidas" { return "ADS" }
        if slug == "basf" { return "BAS" }
        if slug == "rheinmetall" { return "RHM" }
        if slug == "deutsche_telekom" || slug == "deutsche telekom" || slug == "telekom" { return "DTE" }
        if slug == "volkswagen" || slug == "vw" { return "VOW3" }
        if slug == "bmw" { return "BMW" }
        if slug == "bayer" { return "BAYN" }
        if slug == "henkel" { return "HEN3" }
        if slug == "mercedes" || slug == "daimler" { return "MBG" }
        if slug == "puma" { return "PUM" }
        if slug == "am3d" { return "AM3D" }
        if slug == "deutsche_bank" || slug == "deutsche bank" { return "DBK" }
        if slug == "commerzbank" { return "CBK" }
        if slug == "infineon" { return "IFX" }
        if slug == "covestro" { return "1COV" }
        if slug == "deutsche_boerse" || slug == "deutsche börse" { return "DB1" }
        if slug == "porsche" { return "PAH3" }
        if slug == "glencore" { return "GLEN" }
        if slug == "apple" { return "AAPL" }
        if slug == "microsoft" { return "MSFT" }
        if slug == "amazon" { return "AMZN" }
        if slug == "alphabet" || slug == "google" { return "GOOGL" }
        if slug == "tesla" { return "TSLA" }
        if slug == "meta" || slug == "facebook" { return "META" }
        return nil
    }
    
    private static let usIsinToTicker: [String: String] = [
        "US0378331005": "AAPL", "US5949181045": "MSFT", "US0231351067": "AMZN",
        "US02079K3059": "GOOGL", "US88160R1014": "TSLA", "US30303M1027": "META"
    ]
    
    /// API-Key aus gespeichertem Wert extrahieren (URL mit apikey= oder reiner Key)
    private static func fmpExtractAPIKey() -> String? {
        guard let raw = fmpAPIKey?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else { return nil }
        if let range = raw.range(of: "apikey=") {
            let nachKey = String(raw[range.upperBound...])
            let keyEnd = nachKey.firstIndex(of: "&") ?? nachKey.endIndex
            let key = String(nachKey[..<keyEnd]).trimmingCharacters(in: .whitespaces)
            return key.isEmpty ? nil : key
        }
        return raw
    }
    
    /// FMP search-isin API: ISIN → Symbol. Global (US, DE, JE, …). Nur wenn API-Key hinterlegt. ISIN wird URL-encodiert (Buchstaben z. B. DE000ENER6Y0).
    private static func fmpSymbolFromSearchISIN(isin: String) async -> String? {
        let isinNorm = isin.trimmingCharacters(in: .whitespaces).uppercased()
        guard isinNorm.count >= 12 else { return nil }
        guard let apiKey = fmpExtractAPIKey() else { return nil }
        let isin12 = String(isinNorm.prefix(12))
        let isinEncoded = isin12.addingPercentEncoding(withAllowedCharacters: CharacterSet.urlQueryAllowed.subtracting(CharacterSet(charactersIn: "&"))) ?? isin12
        guard let url = URL(string: "https://financialmodelingprep.com/stable/search-isin?isin=\(isinEncoded)&apikey=\(apiKey)") else { return nil }
        do {
            var request = URLRequest(url: url)
            request.timeoutInterval = 15
            request.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36", forHTTPHeaderField: "User-Agent")
            let (data, _) = try await URLSession.shared.data(for: request)
            let json = try? JSONSerialization.jsonObject(with: data)
            if let arr = json as? [[String: Any]], let first = arr.first {
                if let sym = first["symbol"] as? String, !sym.isEmpty { return sym }
                if let sym = first["ticker"] as? String, !sym.isEmpty { return sym }
            }
            if let obj = json as? [String: Any], let sym = (obj["symbol"] ?? obj["ticker"]) as? String, !sym.isEmpty { return sym }
        } catch {
            debug("   ⚠️ FMP search-isin \(isin12): \(error.localizedDescription)")
        }
        return nil
    }
    
    /// FMP search-name API: Bezeichnung/Name → Symbol (wie Python). Fallback wenn search-isin und WKN-Mapping nichts liefern.
    private static func fmpSymbolFromSearchName(name: String, limit: Int = 12) async -> String? {
        let query = name.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty, let apiKey = fmpExtractAPIKey() else { return nil }
        let encoded = query.addingPercentEncoding(withAllowedCharacters: CharacterSet.urlQueryAllowed.subtracting(CharacterSet(charactersIn: "&"))) ?? query
        guard let url = URL(string: "https://financialmodelingprep.com/stable/search-name?query=\(encoded)&apikey=\(apiKey)") else { return nil }
        do {
            var request = URLRequest(url: url)
            request.timeoutInterval = 15
            request.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36", forHTTPHeaderField: "User-Agent")
            let (data, _) = try await URLSession.shared.data(for: request)
            let json = try? JSONSerialization.jsonObject(with: data)
            guard let arr = json as? [[String: Any]], !arr.isEmpty else { return nil }
            let toCheck = Array(arr.prefix(limit))
            for row in toCheck {
                if let sym = row["symbol"] as? String, !sym.isEmpty { return sym }
                if let sym = row["ticker"] as? String, !sym.isEmpty { return sym }
            }
        } catch {
            debug("   ⚠️ FMP search-name '\(query.prefix(30))…': \(error.localizedDescription)")
        }
        return nil
    }
    
    /// Bulk-Abruf FMP Price Target – eine API-Anfrage für alle Aktien. Rückgabe: [WKN: KurszielInfo]
    /// Bei forceOverwrite: auch Aktien mit bestehendem Kursziel (z. B. aus CSV) abfragen.
    /// Wechselkurse: direkter Zugriff (fetchAppWechselkurse), keine alte Zwischenspeicherung.
    static func fetchKurszieleBulkFMP(aktien: [Aktie], forceOverwrite: Bool = false) async -> [String: KurszielInfo] {
        if isDemoMode {
            let toFetch = aktien.filter { forceOverwrite ? !$0.kurszielManuellGeaendert : (!$0.kurszielManuellGeaendert && $0.kursziel == nil) }
            var result: [String: KurszielInfo] = [:]
            for a in toFetch {
                let wkn = a.wkn.trimmingCharacters(in: .whitespaces)
                if !wkn.isEmpty { result[wkn] = mockKurszielInfo(for: a) }
            }
            debug("━━━ DEMO BULK: \(result.count) Mock-Kursziele ━━━")
            return result
        }
        _ = await fetchAppWechselkurse()
        debug("━━━ FMP BULK START ━━━")
        guard let raw = fmpAPIKey?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else {
            debug("   ❌ FMP: FMP-Feld leer (API-Key oder komplette URL eintragen)")
            return [:]
        }
        let toFetch = aktien.filter { forceOverwrite ? !$0.kurszielManuellGeaendert : (!$0.kurszielManuellGeaendert && $0.kursziel == nil) }
        debug("   📋 FMP: \(toFetch.count) Aktien ohne Kursziel (von \(aktien.count) gesamt)")
        var symbolToWKNs: [String: [String]] = [:]
        var symbols: [String] = []
        var isinToSymbolCache: [String: String] = [:]
        var ohneMapping: [(name: String, wkn: String, isin: String)] = []
        for a in toFetch {
            var sym: String?
            let isinNorm = a.isin.trimmingCharacters(in: .whitespaces)
            if isinNorm.count >= 12 {
                let isin12 = String(isinNorm.uppercased().prefix(12))
                if let cached = isinToSymbolCache[isin12] {
                    sym = (isin12.hasPrefix("DE") && cached == "DB") ? "DBK" : cached
                } else if let resolved = await fmpSymbolFromSearchISIN(isin: a.isin) {
                    var symbolToUse = resolved
                    if isin12.hasPrefix("DE"), resolved == "DB" {
                        symbolToUse = "DBK"
                        debug("   ✅ FMP search-isin: \(isin12) → \(resolved) (Deutsche Bank → DBK für Xetra)")
                    } else {
                        debug("   ✅ FMP search-isin: \(isin12) → \(resolved) (\(a.bezeichnung))")
                    }
                    isinToSymbolCache[isin12] = symbolToUse
                    sym = symbolToUse
                }
            }
            if sym == nil {
                sym = fmpSymbol(for: a)
            }
            if sym == nil, !a.bezeichnung.trimmingCharacters(in: .whitespaces).isEmpty {
                sym = await fmpSymbolFromSearchName(name: a.bezeichnung)
                if let s = sym { debug("   ✅ FMP search-name: \(a.bezeichnung.prefix(40))… → \(s)") }
            }
            if let s = sym {
                if !symbols.contains(s) { symbols.append(s) }
                if symbolToWKNs[s] == nil { symbolToWKNs[s] = [] }
                if !symbolToWKNs[s]!.contains(a.wkn) { symbolToWKNs[s]!.append(a.wkn) }
            } else {
                ohneMapping.append((a.bezeichnung, a.wkn, a.isin))
            }
        }
        if !ohneMapping.isEmpty {
            debug("   ⚠️ FMP: Kein Symbol für \(ohneMapping.count) Aktien (WKN/ISIN nicht in Mapping):")
            for m in ohneMapping.prefix(5) {
                debug("      – \(m.name) (WKN: \(m.wkn), ISIN: \(m.isin))")
            }
            if ohneMapping.count > 5 { debug("      … und \(ohneMapping.count - 5) weitere") }
        }
        guard !symbols.isEmpty else {
            debug("   ❌ FMP: Keine Symbole (ISIN search-isin + Mapping)")
            return [:]
        }
        let fmpNurTest = false // Test: nur 1 Aufruf – auf true setzen zum Testen
        let symbolsToFetch = fmpNurTest ? Array(symbols.prefix(1)) : symbols
        if fmpNurTest {
            debug("   🧪 FMP TEST: Nur 1 Aufruf (\(symbolsToFetch.first ?? "?")), danach in Routine einbauen")
        }
        debug("   📡 FMP: \(symbolsToFetch.count) Symbole – Einzelabruf (price-target-consensus)")
        debug("   🔗 URL: Befehl wie eingegeben, nur Symbol getauscht. USD/GBP→EUR: CSV-Devisenkurs (USD) oder Frankfurter-API.")
        var result: [String: KurszielInfo] = [:]
        for (idx, sym) in symbolsToFetch.enumerated() {
            guard let wknList = symbolToWKNs[sym], !wknList.isEmpty else { continue }
            guard let url = fmpURLForRequest(symbol: sym) else { continue }
            debug("   📡 FMP [\(idx + 1)/\(symbolsToFetch.count)]: \(sym)")
            do {
                var request = URLRequest(url: url)
                request.timeoutInterval = 30
                request.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36", forHTTPHeaderField: "User-Agent")
                let (data, response) = try await URLSession.shared.data(for: request)
                zugriffeFMP += 1
                if let http = response as? HTTPURLResponse {
                    debug("   📥 FMP \(sym) HTTP Status: \(http.statusCode)")
                }
                let json = try? JSONSerialization.jsonObject(with: data)
                if let errDict = json as? [String: Any] {
                    let errMsg = errDict["Error Message"] as? String
                        ?? errDict["error"] as? String
                        ?? errDict["message"] as? String
                        ?? errDict["errors"] as? String
                    if let msg = errMsg, !msg.isEmpty {
                        debug("   ❌ FMP \(sym): \(msg)")
                        if idx == 0 {
                            debug("   💡 Prüfe: API-Key in Einstellungen, Free-Plan-Limit")
                        }
                        continue
                    }
                }
                var item: [String: Any]?
                if let arr = json as? [[String: Any]] { item = arr.first }
                else if let obj = json as? [String: Any] { item = obj }
                guard let it = item, let parsed = parseFMPConsensusItem(it, symbol: sym) else {
                    debug("   ⚠️ FMP \(sym): Keine Daten")
                    continue
                }
                guard parsed.consensus > 0 else {
                    debug("   ⚠️ FMP \(sym): Satz gefunden, aber Kursziel = 0 – bei Einzelabruf wird finanzen.net versucht")
                    continue
                }
                let istUSD = usTicker.contains(sym)
                let istGBP = gbpTicker.contains(sym)
                var consensus = parsed.consensus
                var high = parsed.high
                var low = parsed.low
                var rate: Double = 1.0
                if istUSD {
                    rate = rateUSDtoEUR()
                    debug("   💱 FMP \(sym): USD→EUR mit App-Kurs \(rate)")
                    consensus = parsed.consensus * rate
                    high = parsed.high.map { $0 * rate }
                    low = parsed.low.map { $0 * rate }
                } else if istGBP {
                    rate = rateGBPtoEUR()
                    consensus = parsed.consensus * rate
                    high = parsed.high.map { $0 * rate }
                    low = parsed.low.map { $0 * rate }
                }
                let info = KurszielInfo(kursziel: consensus, datum: parsed.datum, spalte4Durchschnitt: nil, quelle: .fmp, waehrung: "EUR", kurszielHigh: high, kurszielLow: low, kurszielAnalysten: parsed.analysts)
                for wkn in wknList { result[wkn] = info }
                let umrechnung = istUSD ? " (aus USD × \(rate))" : (istGBP ? " (aus GBP × \(rate))" : "")
                debug("   ✅ FMP: \(sym) → Consensus \(String(format: "%.2f", consensus)) EUR\(umrechnung) | High \(high.map { String(format: "%.2f", $0) } ?? "–") | Low \(low.map { String(format: "%.2f", $0) } ?? "–") | Analysten \(parsed.analysts.map { "\($0)" } ?? "–")")
            } catch {
                debug("   ❌ FMP \(sym): \(error.localizedDescription)")
            }
            if idx < symbolsToFetch.count - 1 {
                try? await Task.sleep(nanoseconds: 300_000_000) // 0,3 s Pause zwischen Abrufen (Rate-Limit)
            }
        }
        debug("━━━ FMP ENDE: \(result.count) Kursziele gefunden ━━━")
        return result
    }
    
    /// OpenAI API-Key – zuerst aus iCloud-Datei (openai_key.txt), sonst aus Einstellungen
    static let openAIAPIKeyKey = "OpenAI_API_Key"
    static let openAIICloudFilename = "openai_key.txt"
    static var openAIAPIKey: String? {
        get {
            if let fromFile = openAIAPIKeyFromICloudFile() { return openAICleanKey(fromFile) }
            if let fromStore = UserDefaults.standard.string(forKey: openAIAPIKeyKey) { return openAICleanKey(fromStore) }
            return nil
        }
        set {
            guard let v = newValue, !v.isEmpty else {
                UserDefaults.standard.removeObject(forKey: openAIAPIKeyKey)
                return
            }
            UserDefaults.standard.set(openAICleanKey(v) ?? v, forKey: openAIAPIKeyKey)
        }
    }
    
    /// Öffentlich für Datei-Import: Bereinigt API-Key (BOM, Leerzeichen, unsichtbare Zeichen)
    static func cleanOpenAIKey(_ raw: String) -> String? {
        return openAICleanKey(raw)
    }
    
    /// Bereinigt API-Key: BOM, Leerzeichen, Zeilenumbrüche entfernen; „k-proj“ → „sk-proj“ falls kopierfehler
    private static func openAICleanKey(_ raw: String) -> String? {
        var key = raw
            .replacingOccurrences(of: "\u{FEFF}", with: "")
            .trimmingCharacters(in: CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: "\0\r\n\t")))
        key = key.filter { !$0.isNewline && !$0.isWhitespace }.trimmingCharacters(in: .whitespaces)
        if key.isEmpty { return nil }
        if key.hasPrefix("k-proj-") && !key.hasPrefix("sk-proj-") {
            key = "s" + key
            debug("   🔧 API-Key: fehlendes 's' ergänzt (k-proj → sk-proj)")
        }
        return key
    }
    
    /// URL für kursziele.csv – iCloud Documents (primär) oder App Documents (Fallback)
    static func kurszieleCSVURL() -> URL? {
        if let container = FileManager.default.url(forUbiquityContainerIdentifier: nil) {
            return container.appendingPathComponent("Documents").appendingPathComponent(kurszieleCSVFilename)
        }
        return FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first?
            .appendingPathComponent(kurszieleCSVFilename)
    }
    
    /// Liest Kursziel aus kursziele.csv – direkter Dateizugriff, keine Zwischenspeicherung. Spalten: Wertpapier;Kursziel_EUR. Match nach Bezeichnung (Slug/erster Wort).
    static func fetchKurszielVonCSV(bezeichnung: String) -> KurszielInfo? {
        guard let url = kurszieleCSVURL(), FileManager.default.fileExists(atPath: url.path) else { return nil }
        try? FileManager.default.startDownloadingUbiquitousItem(at: url)
        guard let data = FileManager.default.contents(atPath: url.path) ?? (try? Data(contentsOf: url)),
              let csv = String(data: data, encoding: .utf8) else { return nil }
        let bezeichnungSlug = slugFromBezeichnung(bezeichnung)
        let erstesWort = bezeichnung.split(separator: " ").first.map(String.init) ?? ""
        let lines = csv.components(separatedBy: .newlines)
        guard lines.count >= 2 else { return nil }
        for line in lines.dropFirst() {
            let cols = line.components(separatedBy: ";")
            guard cols.count >= 2 else { continue }
            let wertpapier = cols[0].trimmingCharacters(in: .whitespaces)
            let kurszielStr = cols[1].trimmingCharacters(in: .whitespaces).replacingOccurrences(of: ",", with: ".")
            guard let kursziel = Double(kurszielStr), kursziel > 0 else { continue }
            let wertpapierSlug = slugFromBezeichnung(wertpapier)
            if wertpapierSlug == bezeichnungSlug { return KurszielInfo(kursziel: kursziel, datum: nil, spalte4Durchschnitt: nil, quelle: .csv, waehrung: "EUR") }
            if !wertpapierSlug.isEmpty && bezeichnungSlug.contains(wertpapierSlug) { return KurszielInfo(kursziel: kursziel, datum: nil, spalte4Durchschnitt: nil, quelle: .csv, waehrung: "EUR") }
            if !wertpapierSlug.isEmpty && wertpapierSlug.contains(bezeichnungSlug) { return KurszielInfo(kursziel: kursziel, datum: nil, spalte4Durchschnitt: nil, quelle: .csv, waehrung: "EUR") }
            if wertpapier.lowercased() == bezeichnung.lowercased() { return KurszielInfo(kursziel: kursziel, datum: nil, spalte4Durchschnitt: nil, quelle: .csv, waehrung: "EUR") }
            if erstesWort.lowercased() == wertpapier.lowercased() { return KurszielInfo(kursziel: kursziel, datum: nil, spalte4Durchschnitt: nil, quelle: .csv, waehrung: "EUR") }
        }
        return nil
    }
    
    /// Schreibt oder ergänzt eine Zeile in kursziele.csv (iCloud Documents). Erstellt Datei falls nicht vorhanden.
    static func appendKurszielToCSV(bezeichnung: String, kursziel: Double) {
        guard let url = kurszieleCSVURL() else { return }
        let fileManager = FileManager.default
        if let container = fileManager.url(forUbiquityContainerIdentifier: nil) {
            let docsDir = container.appendingPathComponent("Documents")
            if !fileManager.fileExists(atPath: docsDir.path) {
                try? fileManager.createDirectory(at: docsDir, withIntermediateDirectories: true)
            }
        }
        var lines: [String] = []
        var headerExists = false
        if fileManager.fileExists(atPath: url.path),
           let data = fileManager.contents(atPath: url.path) ?? (try? Data(contentsOf: url)),
           let existing = String(data: data, encoding: .utf8) {
            lines = existing.components(separatedBy: .newlines).filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
            headerExists = lines.first?.contains("Wertpapier") ?? false
        }
        if !headerExists { lines.insert("Wertpapier;Kursziel_EUR", at: 0) }
        let newLine = "\(bezeichnung);\(String(format: "%.2f", kursziel))"
        let slug = slugFromBezeichnung(bezeichnung)
        var found = false
        for i in 1..<lines.count {
            let cols = lines[i].components(separatedBy: ";")
            if cols.count >= 1, slugFromBezeichnung(cols[0]) == slug {
                lines[i] = newLine
                found = true
                break
            }
        }
        if !found { lines.append(newLine) }
        let content = lines.joined(separator: "\n") + "\n"
        try? content.write(to: url, atomically: true, encoding: .utf8)
    }
    
    /// Liest API-Key aus iCloud-Datei – direkter Dateizugriff, keine Zwischenspeicherung (Documents/openai_key.txt im Aktien-iCloud-Container).
    private static func openAIAPIKeyFromICloudFile() -> String? {
        guard let containerURL = FileManager.default.url(forUbiquityContainerIdentifier: nil) else { return nil }
        let fileURL = containerURL.appendingPathComponent("Documents").appendingPathComponent(openAIICloudFilename)
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return nil }
        try? FileManager.default.startDownloadingUbiquitousItem(at: fileURL)
        guard let data = FileManager.default.contents(atPath: fileURL.path) ?? (try? Data(contentsOf: fileURL)),
              let key = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !key.isEmpty else { return nil }
        return key
    }
    
    /// System-Prompt für OpenAI Kursziel (mit web_search)
    private static let openAISystemPrompt = "Rückgabe nur den Wert oder -1 wenn nichts gefunden wird. Es geht um das Kursziel (Analysten-Zielkurs), nicht um den aktuellen Börsenkurs."
    
    /// Entfernt Leerzeichen als Tausendertrennzeichen (z. B. "2 127,25" → "2127,25"), mehrfach für "1 234 567,89".
    private static func openAINormalizeThousandSeparatorSpaces(_ s: String) -> String {
        var t = s
        let pattern = #"(\d+)\s+(\d{3})(?=,\d|\s\d{3}|$)"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return s }
        while true {
            let nsRange = NSRange(t.startIndex..<t.endIndex, in: t)
            let match = regex.firstMatch(in: t, range: nsRange)
            guard let m = match, m.numberOfRanges >= 3,
                  let r1 = Range(m.range(at: 1), in: t),
                  let r2 = Range(m.range(at: 2), in: t) else { break }
            t.replaceSubrange(r1.upperBound..<r2.lowerBound, with: "")
        }
        return t
    }
    
    /// Parst Modellantwort zu Kursziel. Findet plausibelste Zahl (ignoriert Jahre 1990–2030, bevorzugt Werte nahe EUR/€).
    private static func openAIParseKursziel(_ s: String) -> Double? {
        var trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)
        trimmed = openAINormalizeThousandSeparatorSpaces(trimmed)
        if trimmed == "-1" { return nil }
        let pattern = #"-?\d[\d\.,]*"#
        let nsRange = NSRange(trimmed.startIndex..<trimmed.endIndex, in: trimmed)
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let matches = regex.matches(in: trimmed, range: nsRange)
        var best: Double?
        var bestScore = -1.0
        for match in matches {
            guard let range = Range(match.range, in: trimmed) else { continue }
            var numStr = String(trimmed[range])
            if numStr.contains(".") && numStr.contains(",") {
                let lastComma = numStr.lastIndex(of: ",") ?? numStr.startIndex
                let lastDot = numStr.lastIndex(of: ".") ?? numStr.startIndex
                if lastComma > lastDot {
                    numStr = numStr.replacingOccurrences(of: ".", with: "").replacingOccurrences(of: ",", with: ".")
                } else {
                    numStr = numStr.replacingOccurrences(of: ",", with: "")
                }
            } else if numStr.contains(",") {
                numStr = numStr.replacingOccurrences(of: ",", with: ".")
            }
            guard let val = Double(numStr), val > 0 else { continue }
            // Jahre ausfiltern (1990–2030)
            if val >= 1990 && val <= 2030 && val == floor(val) { continue }
            var score = 0.0
            if val >= 0.01 && val <= 500_000 { score += 10 }
            let pos = trimmed.distance(from: trimmed.startIndex, to: range.lowerBound)
            let matchEnd = trimmed.index(range.upperBound, offsetBy: 0)
            let afterMatch = trimmed[matchEnd...].trimmingCharacters(in: .whitespacesAndNewlines)
            let afterMatchLower = afterMatch.lowercased()
            // Starker Bonus: Zahl steht direkt vor USD/EUR/GBP/€ (z. B. "**50,11 USD**") – verhindert, dass ISIN-Ziffern (z. B. 982) gewählt werden
            if afterMatchLower.hasPrefix("usd") || afterMatchLower.hasPrefix("eur") || afterMatchLower.hasPrefix("gbp") || afterMatchLower.hasPrefix("€")
                || afterMatchLower.hasPrefix("*usd") || afterMatchLower.hasPrefix("*eur") || afterMatchLower.hasPrefix("*gbp")
                || afterMatchLower.hasPrefix("**usd") || afterMatchLower.hasPrefix("**eur") || afterMatchLower.hasPrefix("**gbp") {
                score += 25
            }
            let ctxStart = max(0, pos - 40)
            let ctxEnd = min(trimmed.count, pos + numStr.count + 40)
            let startIdx = trimmed.index(trimmed.startIndex, offsetBy: ctxStart)
            let endIdx = trimmed.index(trimmed.startIndex, offsetBy: ctxEnd)
            let context = String(trimmed[startIdx..<endIdx]).lowercased()
            if context.contains("eur") || context.contains("€") || context.contains("kursziel") || context.contains("ziel") || context.contains("angehoben") { score += 5 }
            if context.contains("usd") { score += 5 }
            if val == floor(val) && val < 1000 { score += 2 }
            if score > bestScore { bestScore = score; best = val }
        }
        return best
    }
    
    /// Liefert die zu verwendende FMP-URL. Wenn gespeicherter Wert mit https:// beginnt: URL so verwenden (nur Symbol ggf. ersetzen).
    private static func fmpURLForRequest(symbol: String) -> URL? {
        guard let raw = fmpAPIKey?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else { return nil }
        if raw.hasPrefix("https://") || raw.hasPrefix("http://") {
            return fmpURLByReplacingSymbol(in: raw, newSymbol: symbol)
        }
        let urlStr = "https://financialmodelingprep.com/stable/price-target-consensus?symbol=\(symbol)&apikey=\(raw)"
        return URL(string: urlStr)
    }
    
    /// Öffentlich: Konvertiert KurszielInfo von USD/GBP in EUR (für Button-Flows wie OpenAI, Aus Datei).
    /// usdToEurFromHeader/gbpToEurFromHeader: Wechselkurse aus dem App-Kopf; wenn Service keinen Kurs hat (z. B. nach OpenAI-Button), werden diese verwendet.
    static func kurszielInfoZuEUR(info: KurszielInfo, aktie: Aktie, usdToEurFromHeader: Double? = nil, gbpToEurFromHeader: Double? = nil) async -> KurszielInfo {
        return await kurszielZuEUR(info: info, aktie: aktie, usdToEurFromHeader: usdToEurFromHeader, gbpToEurFromHeader: gbpToEurFromHeader)
    }

    /// Konvertiert KurszielInfo in EUR: USD/GBP mit App-Wechselkurs; andere Währungen mit 1 (keine Umrechnung, manuell zu ändern).
    private static func kurszielZuEUR(info: KurszielInfo, aktie: Aktie, usdToEurFromHeader: Double? = nil, gbpToEurFromHeader: Double? = nil) async -> KurszielInfo {
        if info.ohneDevisenumrechnung {
            debug("   💱 Wert unverändert übernommen (keine Umrechnung)")
            return info
        }
        let w = (info.waehrung ?? "EUR").uppercased()
        if w == "EUR" { return info }
        if w == "USD" {
            let rate = usdToEurFromHeader ?? rateUSDtoEUR()
            debug("   💱 USD→EUR mit App-Kurs: \(rate)" + (usdToEurFromHeader != nil ? " (aus Kopf)" : ""))
            return KurszielInfo(
                kursziel: info.kursziel * rate,
                datum: info.datum,
                spalte4Durchschnitt: info.spalte4Durchschnitt,
                quelle: info.quelle,
                waehrung: "EUR",
                kurszielHigh: info.kurszielHigh.map { $0 * rate },
                kurszielLow: info.kurszielLow.map { $0 * rate },
                kurszielAnalysten: info.kurszielAnalysten
            )
        }
        if w == "GBP" {
            let rate = gbpToEurFromHeader ?? rateGBPtoEUR()
            debug("   💱 GBP→EUR mit App-Kurs: \(rate)" + (gbpToEurFromHeader != nil ? " (aus Kopf)" : ""))
            return KurszielInfo(
                kursziel: info.kursziel * rate,
                datum: info.datum,
                spalte4Durchschnitt: info.spalte4Durchschnitt,
                quelle: info.quelle,
                waehrung: "EUR",
                kurszielHigh: info.kurszielHigh.map { $0 * rate },
                kurszielLow: info.kurszielLow.map { $0 * rate },
                kurszielAnalysten: info.kurszielAnalysten
            )
        }
        if w == "DKK" {
            let rate = rateDKKtoEUR()
            debug("   💱 DKK→EUR mit App-Kurs: \(rate)")
            return KurszielInfo(
                kursziel: info.kursziel * rate,
                datum: info.datum,
                spalte4Durchschnitt: info.spalte4Durchschnitt,
                quelle: info.quelle,
                waehrung: "EUR",
                kurszielHigh: info.kurszielHigh.map { $0 * rate },
                kurszielLow: info.kurszielLow.map { $0 * rate },
                kurszielAnalysten: info.kurszielAnalysten
            )
        }
        // Andere Währung: mit 1 bewerten, keine Umrechnung – manuell zu ändern
        debug("   💱 Andere Währung \(w): keine Umrechnung (manuell anpassen)")
        return KurszielInfo(
            kursziel: info.kursziel,
            datum: info.datum,
            spalte4Durchschnitt: info.spalte4Durchschnitt,
            quelle: info.quelle,
            waehrung: info.waehrung,
            kurszielHigh: info.kurszielHigh,
            kurszielLow: info.kurszielLow,
            kurszielAnalysten: info.kurszielAnalysten,
            ohneDevisenumrechnung: true
        )
    }
    
    /// Frankfurter API: USD → EUR (nur für fetchAppWechselkurse)
    private static func fetchUSDtoEURRateInternal() async -> Double {
        let fallback: Double = 0.92
        guard let url = URL(string: "https://api.frankfurter.dev/v1/latest?base=USD&symbols=EUR") else { return fallback }
        do {
            var request = URLRequest(url: url)
            request.timeoutInterval = 5
            let (data, response) = try await URLSession.shared.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? -1
            if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let rates = json["rates"] as? [String: Any],
               let eur = rates["EUR"] as? Double, eur > 0 {
                debug("   💱 USD→EUR: \(eur) (API HTTP \(status))")
                return eur
            }
        } catch {
            debug("   💱 USD→EUR Fallback 0.92: \(error.localizedDescription)")
        }
        return fallback
    }
    
    /// Frankfurter API: GBP → EUR (nur für fetchAppWechselkurse)
    private static func fetchGBPtoEURRateInternal() async -> Double {
        let fallback: Double = 1.17
        guard let url = URL(string: "https://api.frankfurter.dev/v1/latest?base=GBP&symbols=EUR") else { return fallback }
        do {
            var request = URLRequest(url: url)
            request.timeoutInterval = 5
            let (data, response) = try await URLSession.shared.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? -1
            if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let rates = json["rates"] as? [String: Any],
               let eur = rates["EUR"] as? Double, eur > 0 {
                debug("   💱 GBP→EUR: \(eur) (API HTTP \(status))")
                return eur
            }
        } catch {
            debug("   💱 GBP→EUR Fallback 1.17: \(error.localizedDescription)")
        }
        return fallback
    }
    
    /// Frankfurter API: DKK → EUR (dänische Kronen, z. B. Novo Nordisk)
    private static func fetchDKKtoEURRateInternal() async -> Double {
        let fallback: Double = 0.13
        guard let url = URL(string: "https://api.frankfurter.dev/v1/latest?base=DKK&symbols=EUR") else { return fallback }
        do {
            var request = URLRequest(url: url)
            request.timeoutInterval = 5
            let (data, response) = try await URLSession.shared.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? -1
            if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let rates = json["rates"] as? [String: Any],
               let eur = rates["EUR"] as? Double, eur > 0 {
                debug("   💱 DKK→EUR: \(eur) (API HTTP \(status))")
                return eur
            }
        } catch {
            debug("   💱 DKK→EUR Fallback 0.13: \(error.localizedDescription)")
        }
        return fallback
    }
    
    /// Ersetzt in einer FMP-URL den symbol-Parameter durch newSymbol
    private static func fmpURLByReplacingSymbol(in urlStr: String, newSymbol: String) -> URL? {
        guard let symRange = urlStr.range(of: "symbol=") else { return URL(string: urlStr) }
        let valueStart = symRange.upperBound
        let rest = urlStr[valueStart...]
        let valueEnd = rest.firstIndex(of: "&") ?? rest.endIndex
        let before = String(urlStr[..<valueStart])
        let after = valueEnd == rest.endIndex ? "" : String(rest[valueEnd...])
        let newURL = before + newSymbol + after
        return URL(string: newURL)
    }
    
    /// FMP-Symbol für eine Aktie (für FMP-Test-Anzeige)
    static func fmpSymbolForAktie(_ aktie: Aktie) -> String? {
        return fmpSymbol(for: aktie)
    }
    
    /// FMP-Befehl (URL) für Anzeige. Nutzt Symbol oder search-isin per ISIN.
    static func fmpBefehlForDisplay(for aktie: Aktie) -> (url: String, viaIsin: Bool)? {
        if let sym = fmpSymbol(for: aktie), let url = fmpURLForRequest(symbol: sym) {
            return (maskApiKeyInURL(url.absoluteString), false)
        }
        let isinNorm = aktie.isin.trimmingCharacters(in: .whitespaces).uppercased()
        if isinNorm.count >= 12, let apiKey = fmpExtractAPIKey(),
           let url = URL(string: "https://financialmodelingprep.com/stable/search-isin?isin=\(String(isinNorm.prefix(12)))&apikey=\(apiKey)") {
            return (maskApiKeyInURL(url.absoluteString), true)
        }
        return nil
    }
    
    private static func maskApiKeyInURL(_ urlStr: String) -> String {
        if let range = urlStr.range(of: "apikey=") {
            let after = urlStr[range.upperBound...]
            let keyEnd = after.firstIndex(of: "&") ?? after.endIndex
            let before = String(urlStr[..<range.upperBound])
            let afterKey = String(after[keyEnd...])
            return before + "***" + afterKey
        }
        return urlStr
    }
    
    /// Ruft Kursziel von FMP für eine einzelne Aktie ab. Wie Python: search-isin → WKN-Mapping/Bezeichnung → search-name. Bei DE-ISIN und Symbol „DB“ wird DBK (Xetra) verwendet.
    static func fetchKurszielFromFMP(for aktie: Aktie) async -> KurszielInfo? {
        var sym: String?
        if aktie.isin.trimmingCharacters(in: .whitespaces).count >= 12 {
            sym = await fmpSymbolFromSearchISIN(isin: aktie.isin)
            if sym == "DB", aktie.isin.trimmingCharacters(in: .whitespaces).uppercased().hasPrefix("DE") {
                sym = "DBK"
            }
        }
        if sym == nil {
            sym = fmpSymbol(for: aktie)
        }
        if sym == nil, !aktie.bezeichnung.trimmingCharacters(in: .whitespaces).isEmpty {
            sym = await fmpSymbolFromSearchName(name: aktie.bezeichnung)
        }
        guard let symbol = sym, let url = fmpURLForRequest(symbol: symbol) else { return nil }
        return await fetchKurszielFromFMPURL(url.absoluteString)
    }
    
    /// Ruft eine vollständige FMP-URL auf (z. B. aus WKN-Test) und liefert KurszielInfo
    static func fetchKurszielFromFMPURL(_ urlString: String) async -> KurszielInfo? {
        let trimmed = urlString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed), trimmed.contains("financialmodelingprep.com") else { return nil }
        do {
            var request = URLRequest(url: url)
            request.timeoutInterval = 30
            request.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36", forHTTPHeaderField: "User-Agent")
            let (data, _) = try await URLSession.shared.data(for: request)
            let json = try? JSONSerialization.jsonObject(with: data)
            var item: [String: Any]?
            if let arr = json as? [[String: Any]] { item = arr.first }
            else if let obj = json as? [String: Any] { item = obj }
            guard let it = item else { return nil }
            let symbol = it["symbol"] as? String ?? "?"
            guard let parsed = parseFMPConsensusItem(it, symbol: symbol) else { return nil }
            // FMP liefert manchmal 0 (z. B. Infineon) – dann nil, damit weiter bei Finanzen.net/OpenAI gesucht wird
            guard parsed.consensus > 0 else { return nil }
            var consensus = parsed.consensus
            var high = parsed.high
            var low = parsed.low
            if gbpTicker.contains(symbol) {
                let rate = rateGBPtoEUR()
                consensus = parsed.consensus * rate
                high = parsed.high.map { $0 * rate }
                low = parsed.low.map { $0 * rate }
            } else if usTicker.contains(symbol) || isLikelyUSTicker(symbol) {
                let rate = rateUSDtoEUR()
                consensus = parsed.consensus * rate
                high = parsed.high.map { $0 * rate }
                low = parsed.low.map { $0 * rate }
            }
            let waehrung: String
            if gbpTicker.contains(symbol) || usTicker.contains(symbol) || isLikelyUSTicker(symbol) {
                waehrung = "EUR"
            } else {
                waehrung = "USD"
            }
            return KurszielInfo(kursziel: consensus, datum: parsed.datum, spalte4Durchschnitt: nil, quelle: .fmp, waehrung: waehrung, kurszielHigh: high, kurszielLow: low, kurszielAnalysten: parsed.analysts)
        } catch {
            debug("   ❌ FMP URL Fehler: \(error.localizedDescription)")
            return nil
        }
    }
    
    /// Nur für Aufrufe, die einen einzelnen Key erwarten (Legacy)
    private static func fmpConsensusURL(symbol: String, apiKey: String) -> URL? {
        let key = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        if key.hasPrefix("https://") || key.hasPrefix("http://") {
            return fmpURLByReplacingSymbol(in: key, newSymbol: symbol)
        }
        let urlStr = "https://financialmodelingprep.com/stable/price-target-consensus?symbol=\(symbol)&apikey=\(key)"
        return URL(string: urlStr)
    }
    
    /// Einstellung: Faires KGV für KGV-Methode (Kursziel = EPS × dieses KGV). Standard 15.
    private static let keyKGVTargetKGV = "KurszielService.kgvTargetKGV"
    static var kgvTargetKGV: Double {
        get {
            let v = UserDefaults.standard.double(forKey: keyKGVTargetKGV)
            return v > 0 ? v : 15
        }
        set { UserDefaults.standard.set(newValue, forKey: keyKGVTargetKGV) }
    }
    
    /// FMP Key-Metrics-URL für Symbol (nur bei reinem API-Key; bei gespeicherter Voll-URL nur price-target).
    private static func fmpKeyMetricsURL(symbol: String) -> URL? {
        guard let raw = fmpAPIKey?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else { return nil }
        if raw.hasPrefix("https://") || raw.hasPrefix("http://") { return nil }
        guard let key = fmpExtractAPIKey(), !key.isEmpty else { return nil }
        return URL(string: "https://financialmodelingprep.com/stable/key-metrics?symbol=\(symbol)&apikey=\(key)")
    }
    
    /// FMP Dividends-URL für Symbol (nur bei reinem API-Key).
    private static func fmpDividendsURL(symbol: String) -> URL? {
        guard let raw = fmpAPIKey?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else { return nil }
        if raw.hasPrefix("https://") || raw.hasPrefix("http://") { return nil }
        guard let key = fmpExtractAPIKey(), !key.isEmpty else { return nil }
        return URL(string: "https://financialmodelingprep.com/stable/dividends?symbol=\(symbol)&apikey=\(key)")
    }
    
    /// Kursziel per KGV-Methode: EPS × faires KGV. Nutzt FMP Key-Metrics (EPS, ggf. P/E). Alternative zu FMP-Analysten/OpenAI.
    static func fetchKurszielFromFMPKGV(for aktie: Aktie) async -> KurszielInfo? {
        var sym: String?
        if aktie.isin.trimmingCharacters(in: .whitespaces).count >= 12 {
            sym = await fmpSymbolFromSearchISIN(isin: aktie.isin)
            if sym == "DB", aktie.isin.trimmingCharacters(in: .whitespaces).uppercased().hasPrefix("DE") { sym = "DBK" }
        }
        if sym == nil { sym = fmpSymbol(for: aktie) }
        if sym == nil, !aktie.bezeichnung.trimmingCharacters(in: .whitespaces).isEmpty {
            sym = await fmpSymbolFromSearchName(name: aktie.bezeichnung)
        }
        guard let symbol = sym, let url = fmpKeyMetricsURL(symbol: symbol) else { return nil }
        do {
            var request = URLRequest(url: url)
            request.timeoutInterval = 20
            request.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36", forHTTPHeaderField: "User-Agent")
            let (data, _) = try await URLSession.shared.data(for: request)
            let json = try? JSONSerialization.jsonObject(with: data)
            var item: [String: Any]?
            if let arr = json as? [[String: Any]], !arr.isEmpty { item = arr.first }
            else if let obj = json as? [String: Any] { item = obj }
            guard let it = item else { return nil }
            let eps: Double? = (it["netIncomePerShare"] as? Double)
                ?? (it["eps"] as? Double)
                ?? (it["earningsPerShare"] as? Double)
                ?? (it["epsTTM"] as? Double)
            guard let epsVal = eps, epsVal > 0 else {
                debug("   ⏭️ KGV: Kein EPS für \(symbol)")
                return nil
            }
            let targetKGV = kgvTargetKGV
            let kursziel = (epsVal * targetKGV * 100).rounded() / 100
            var waehrung = "USD"
            if gbpTicker.contains(symbol) { waehrung = "GBP" }
            else if usTicker.contains(symbol) || isLikelyUSTicker(symbol) { waehrung = "USD" }
            else if (it["currency"] as? String)?.uppercased() == "EUR" { waehrung = "EUR" }
            debug("   📊 KGV \(symbol): EPS \(String(format: "%.2f", epsVal)) × KGV \(String(format: "%.1f", targetKGV)) = \(String(format: "%.2f", kursziel)) \(waehrung)")
            return KurszielInfo(kursziel: kursziel, datum: Date(), spalte4Durchschnitt: nil, quelle: .kgv, waehrung: waehrung)
        } catch {
            debug("   ❌ KGV/Key-Metrics \(symbol): \(error.localizedDescription)")
            return nil
        }
    }
    
    /// Liefert Gewinn pro Aktie (EPS) und optional KGV (P/E) aus FMP Key-Metrics für die Detailansicht. Nil wenn kein API-Key oder kein EPS.
    static func fetchEPSFromFMP(for aktie: Aktie) async -> (eps: Double, peRatio: Double?, waehrung: String)? {
        var sym: String?
        if aktie.isin.trimmingCharacters(in: .whitespaces).count >= 12 {
            sym = await fmpSymbolFromSearchISIN(isin: aktie.isin)
            if sym == "DB", aktie.isin.trimmingCharacters(in: .whitespaces).uppercased().hasPrefix("DE") { sym = "DBK" }
        }
        if sym == nil { sym = fmpSymbol(for: aktie) }
        if sym == nil, !aktie.bezeichnung.trimmingCharacters(in: .whitespaces).isEmpty {
            sym = await fmpSymbolFromSearchName(name: aktie.bezeichnung)
        }
        guard let symbol = sym, let url = fmpKeyMetricsURL(symbol: symbol) else { return nil }
        do {
            var request = URLRequest(url: url)
            request.timeoutInterval = 20
            request.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36", forHTTPHeaderField: "User-Agent")
            let (data, _) = try await URLSession.shared.data(for: request)
            let json = try? JSONSerialization.jsonObject(with: data)
            var item: [String: Any]?
            if let arr = json as? [[String: Any]], !arr.isEmpty { item = arr.first }
            else if let obj = json as? [String: Any] { item = obj }
            guard let it = item else { return nil }
            let eps: Double? = (it["netIncomePerShare"] as? Double)
                ?? (it["eps"] as? Double)
                ?? (it["earningsPerShare"] as? Double)
                ?? (it["epsTTM"] as? Double)
            guard let epsVal = eps, epsVal > 0 else { return nil }
            let pe: Double? = (it["peRatio"] as? Double)
                ?? (it["peRatioTTM"] as? Double)
                ?? (it["priceEarningsRatio"] as? Double)
            var waehrung = "USD"
            if gbpTicker.contains(symbol) { waehrung = "GBP" }
            else if usTicker.contains(symbol) || isLikelyUSTicker(symbol) { waehrung = "USD" }
            else if (it["currency"] as? String)?.uppercased() == "EUR" { waehrung = "EUR" }
            return (epsVal, pe, waehrung)
        } catch {
            return nil
        }
    }
    
    /// Liefert erwartete Dividende pro Aktie aus FMP Dividends-API (letzte/aktuelle Ausschüttung). Nil wenn kein API-Key oder keine Dividende.
    static func fetchDividendeFromFMP(for aktie: Aktie) async -> (dividendeProAktie: Double, waehrung: String, paymentDate: Date?)? {
        var sym: String?
        if aktie.isin.trimmingCharacters(in: .whitespaces).count >= 12 {
            sym = await fmpSymbolFromSearchISIN(isin: aktie.isin)
            if sym == "DB", aktie.isin.trimmingCharacters(in: .whitespaces).uppercased().hasPrefix("DE") { sym = "DBK" }
        }
        if sym == nil { sym = fmpSymbol(for: aktie) }
        if sym == nil, !aktie.bezeichnung.trimmingCharacters(in: .whitespaces).isEmpty {
            sym = await fmpSymbolFromSearchName(name: aktie.bezeichnung)
        }
        guard let symbol = sym, let url = fmpDividendsURL(symbol: symbol) else { return nil }
        do {
            var request = URLRequest(url: url)
            request.timeoutInterval = 20
            request.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36", forHTTPHeaderField: "User-Agent")
            let (data, _) = try await URLSession.shared.data(for: request)
            let json = try? JSONSerialization.jsonObject(with: data)
            guard let arr = json as? [[String: Any]], !arr.isEmpty else { return nil }
            // Erstes Element = neueste Dividende (FMP sortiert oft neueste zuerst)
            let item = arr.first!
            let amount: Double? = (item["dividend"] as? Double)
                ?? (item["adjDividend"] as? Double)
                ?? (item["dividendPerShare"] as? Double)
            guard let div = amount, div > 0 else { return nil }
            var waehrung = "USD"
            if gbpTicker.contains(symbol) { waehrung = "GBP" }
            else if usTicker.contains(symbol) || isLikelyUSTicker(symbol) { waehrung = "USD" }
            else if (item["currency"] as? String)?.uppercased() == "EUR" { waehrung = "EUR" }
            var paymentDate: Date?
            if let pd = (item["paymentDate"] as? String) ?? (item["date"] as? String), !pd.isEmpty {
                let fmt = ISO8601DateFormatter()
                fmt.formatOptions = [.withFullDate, .withDashSeparatorInDate]
                paymentDate = fmt.date(from: String(pd.prefix(10)))
            }
            return (div, waehrung, paymentDate)
        } catch {
            return nil
        }
    }
    
    /// Parst FMP price-target-consensus Response (stable: targetHigh, targetLow, targetConsensus, targetMedian)
    /// FMP: targetConsensus = Durchschnitt aller Analysten, targetMedian = Median (robuster bei Ausreißern)
    /// Bevorzugt targetMedian wenn vorhanden – oft näher am Kurs bei UK-Aktien mit wenigen Analysten.
    /// Liefert bei vorhandenem Satz aber Kursziel 0 ein Tuple mit consensus 0, damit Aufrufer finanzen.net nachziehen kann.
    private static func parseFMPConsensusItem(_ item: [String: Any], symbol: String) -> (consensus: Double, high: Double?, low: Double?, analysts: Int?, datum: Date?)? {
        let median = (item["targetMedian"] as? Double) ?? (item["adjMedian"] as? Double) ?? (item["medianPriceTarget"] as? Double)
        let consensus = (item["targetConsensus"] as? Double) ?? (item["adjConsensus"] as? Double) ?? (item["consensus"] as? Double) ?? (item["mean"] as? Double) ?? (item["targetMean"] as? Double) ?? (item["consensusPriceTarget"] as? Double) ?? (item["publishedPriceTarget"] as? Double)
        let kz: Double?
        if let m = median, m > 0 {
            kz = m
            debug("   📊 FMP \(symbol): Nutze targetMedian (\(String(format: "%.2f", m))) statt targetConsensus (\(consensus.map { String(format: "%.2f", $0) } ?? "–"))")
        } else {
            kz = consensus
        }
        let analysts = item["numberOfAnalysts"] as? Int ?? item["analystCount"] as? Int
        var datum: Date? = nil
        if let d = (item["publishedDate"] as? String) ?? (item["date"] as? String) {
            let fmt = ISO8601DateFormatter()
            fmt.formatOptions = [.withFullDate, .withDashSeparatorInDate]
            datum = fmt.date(from: String(d.prefix(10)))
        }
        if let kursziel = kz, kursziel > 0 {
            let high = (item["targetHigh"] as? Double) ?? (item["adjHighTargetPrice"] as? Double) ?? (item["high"] as? Double) ?? (item["highPriceTarget"] as? Double)
            let low = (item["targetLow"] as? Double) ?? (item["adjLowTargetPrice"] as? Double) ?? (item["low"] as? Double) ?? (item["lowPriceTarget"] as? Double)
            return (kursziel, high, low, analysts, datum)
        }
        // Satz gefunden, aber Kursziel 0 oder fehlend → Aufrufer kann finanzen.net versuchen
        return (0, nil, nil, analysts, datum)
    }
    
    /// Testet mehrere FMP-APIs und schreibt alle Ergebnisse in den Debug-Log
    static func testFMPAlleAPIs() async -> String {
        guard let raw = fmpAPIKey?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else {
            return "FMP-Feld leer (API-Key oder komplette URL eintragen)"
        }
        clearDebugLog()
        debug("━━━ FMP API-TEST ━━━")
        debug("   Eingabe: \(raw.hasPrefix("http") ? "komplette URL" : "API-Key (\(raw.count) Zeichen)")")
        debug("")
        let symbols = ["AAPL", "SAP", "RHM"]
        var ergebnisse: [String] = []
        for symbol in symbols {
            let name = "stable/price-target-consensus \(symbol)"
            guard let url = fmpURLForRequest(symbol: symbol) else {
                debug("   ❌ Ungültige URL")
                ergebnisse.append("\(name): URL-Fehler")
                continue
            }
            debug("─── \(name) ───")
            debug("   URL: https://financialmodelingprep.com/stable/price-target-consensus?symbol=\(symbol)&apikey=***")
            do {
                var request = URLRequest(url: url)
                request.timeoutInterval = 15
                request.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36", forHTTPHeaderField: "User-Agent")
                let (data, response) = try await URLSession.shared.data(for: request)
                let status = (response as? HTTPURLResponse)?.statusCode ?? -1
                debug("   HTTP Status: \(status)")
                debug("   Response: \(data.count) Bytes")
                if let raw = String(data: data, encoding: .utf8) {
                    let preview = raw.prefix(400)
                    debug("   Vorschau: \(preview)\(raw.count > 400 ? "…" : "")")
                    if let errDict = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                       let errMsg = errDict["Error Message"] as? String ?? errDict["error"] as? String ?? errDict["message"] as? String {
                        debug("   ❌ API-Fehler: \(errMsg)")
                        ergebnisse.append("\(name): \(errMsg)")
                    } else if status == 200 {
                        debug("   ✅ OK")
                        ergebnisse.append("\(name): OK (\(data.count) Bytes)")
                    } else {
                        ergebnisse.append("\(name): HTTP \(status)")
                    }
                }
            } catch {
                debug("   ❌ Fehler: \(error.localizedDescription)")
                ergebnisse.append("\(name): \(error.localizedDescription)")
            }
            debug("")
        }
        debug("━━━ FMP API-TEST ENDE ━━━")
        return "Test abgeschlossen.\n\n" + ergebnisse.joined(separator: "\n") + "\n\nDetails im Debug-Log (Toolbar)."
    }
    
    /// Testet die FMP-Verbindung. Wenn im FMP-Feld eine komplette URL steht (https://...), wird sie unverändert aufgerufen.
    static func testFMPVerbindung() async -> String {
        guard let raw = fmpAPIKey?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else {
            return "FMP-Feld ist leer (API-Key oder komplette URL eintragen)"
        }
        let url: URL?
        if raw.hasPrefix("https://") || raw.hasPrefix("http://") {
            url = URL(string: raw)
            debug("━━━ FMP Verbindungstest ━━━")
            debug("   Befehl wird so ausgeführt wie eingegeben (komplette URL)")
        } else {
            url = fmpConsensusURL(symbol: "AAPL", apiKey: raw)
            debug("━━━ FMP Verbindungstest ━━━")
            debug("   Befehl: ...?symbol=AAPL&apikey=***")
        }
        guard let requestURL = url else { return "Ungültige URL" }
        do {
            var request = URLRequest(url: requestURL)
            request.timeoutInterval = 30
            request.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36", forHTTPHeaderField: "User-Agent")
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse else { return "Keine HTTP-Antwort" }
            if http.statusCode == 401 {
                let raw = String(data: data, encoding: .utf8) ?? ""
                var text = "❌ HTTP 401 Unauthorized – API-Key ungültig oder falsch"
                text += "\n\nBefehl (im Browser testen, DEIN_KEY ersetzen):"
                text += "\nhttps://financialmodelingprep.com/stable/price-target-consensus?symbol=AAPL&apikey=DEIN_KEY"
                text += "\n\nPrüfe: Key exakt aus FMP-Dashboard kopiert? Keine Leerzeichen?"
                if !raw.isEmpty { text += "\n\nResponse: \(raw.prefix(200))..." }
                return text
            }
            let json = try? JSONSerialization.jsonObject(with: data)
            if let errDict = json as? [String: Any] {
                let errMsg = errDict["Error Message"] as? String ?? errDict["error"] as? String ?? errDict["message"] as? String ?? errDict["errors"] as? String
                if let msg = errMsg, !msg.isEmpty {
                    var text = "❌ FMP Fehler (HTTP \(http.statusCode)):\n\(msg)"
                    if http.statusCode == 401 {
                        text += "\n\nBefehl zum Testen im Browser:"
                        text += "\nhttps://financialmodelingprep.com/stable/price-target-consensus?symbol=AAPL&apikey=DEIN_KEY"
                        text += "\n\nPrüfe: API-Key exakt kopiert? Keine Leerzeichen am Anfang/Ende?"
                    }
                    return text
                }
            }
            var item: [String: Any]?
            if let arr = json as? [[String: Any]] { item = arr.first }
            else if let obj = json as? [String: Any] { item = obj }
            guard let it = item else {
                return "⚠️ Keine Kursziel-Daten (HTTP \(http.statusCode))"
            }
            let symbolName = it["symbol"] as? String ?? "Symbol"
            guard let parsed = parseFMPConsensusItem(it, symbol: symbolName) else {
                return "⚠️ Kein gültiger Consensus (HTTP \(http.statusCode))"
            }
            var lines = ["✅ Verbindung OK (price-target-consensus)"]
            lines.append("\(symbolName): Consensus \(String(format: "%.2f", parsed.consensus)) EUR")
            if let h = parsed.high { lines.append("Hochziel: \(String(format: "%.2f", h))") }
            if let l = parsed.low { lines.append("Niedrigziel: \(String(format: "%.2f", l))") }
            if let n = parsed.analysts { lines.append("Analysten: \(n)") }
            return lines.joined(separator: "\n")
        } catch {
            return "❌ Fehler: \(error.localizedDescription)"
        }
    }
    
    /// Testet die OpenAI-Verbindung mit beliebigem Befehl – Rückgabe: Antwort-Text oder Fehlermeldung
    /// prompt: z.B. "Gib mir das aktuelle Datum zurück" – nur ein Rückgabewert erwartet
    static func testOpenAIVerbindung(prompt: String) async -> String {
        clearDebugLog()
        guard let apiKey = openAIAPIKey, !apiKey.isEmpty else {
            return "API-Key nicht konfiguriert (Einstellungen)"
        }
        let userPrompt = prompt.trimmingCharacters(in: .whitespaces)
        guard !userPrompt.isEmpty else {
            return "Befehl ist leer"
        }
        let systemPrompt = "Gib nur genau einen Wert zurück. Keine Erklärungen, keine Wörter drumherum. Nur die Antwort."
        let responsesURL = "https://api.openai.com/v1/responses"
        let chatURL = "https://api.openai.com/v1/chat/completions"
        debug("━━━ OpenAI Verbindungstest ━━━")
        debug("   URL (Responses): \(responsesURL)")
        debug("   URL (Fallback Chat): \(chatURL)")
        debug("   Befehl: \(userPrompt)")
        do {
            let content = try await openAICallWithFallback(systemPrompt: systemPrompt, userPrompt: userPrompt, apiKey: apiKey)
            let trimmed = content.trimmingCharacters(in: .whitespaces)
            debug("   Antwort: \(trimmed.isEmpty ? "(leer)" : trimmed)")
            var result = "URL: \(responsesURL)\n(bzw. \(chatURL) bei Fallback)\n\nBefehl (Klartext):\n\"\(userPrompt)\"\n\n✅ Verbindung OK\nAntwort: \(trimmed.isEmpty ? "(leer)" : trimmed)"
            return result
        } catch {
            debug("   ❌ Fehler: \(error.localizedDescription)")
            return "URL: \(responsesURL)\n(bzw. \(chatURL) bei Fallback)\n\nBefehl (Klartext):\n\"\(userPrompt)\"\n\nFehler: \(error.localizedDescription)"
        }
    }
    
    /// Modell: gpt-4o mit web_search (Responses API), Fallback Chat Completions
    private static let openAIModelPrimary = "gpt-4o"
    private static let openAIModelFallback = "gpt-4o"
    
    /// Ruft OpenAI ab – Responses API mit gpt-4o-mini zuerst, bei Fehler Chat Completions
    private static func openAICallWithFallback(systemPrompt: String, userPrompt: String, apiKey: String) async throws -> String {
        do {
            return try await openAICallResponsesAPI(systemPrompt: systemPrompt, userPrompt: userPrompt, apiKey: apiKey, model: openAIModelPrimary)
        } catch {
            return try await openAICallChatCompletions(systemPrompt: systemPrompt, userPrompt: userPrompt, apiKey: apiKey, model: openAIModelFallback)
        }
    }
    
    /// Responses API (v1/responses) – gpt-4o mit web_search. temperature 0 für möglichst gleiche Ergebnisse bei gleichem Prompt (web_search kann trotzdem variieren).
    private static func openAICallResponsesAPI(systemPrompt: String, userPrompt: String, apiKey: String, model: String = openAIModelPrimary) async throws -> String {
        let url = URL(string: "https://api.openai.com/v1/responses")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 60
        let input: [[String: String]] = [
            ["role": "system", "content": systemPrompt],
            ["role": "user", "content": userPrompt]
        ]
        let body: [String: Any] = [
            "model": model,
            "tools": [["type": "web_search"]],
            "tool_choice": ["type": "web_search"],
            "temperature": 0,
            "input": input
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw NSError(domain: "OpenAI", code: -1, userInfo: [NSLocalizedDescriptionKey: "Keine HTTP-Antwort"]) }
        guard http.statusCode == 200 else {
            let errText = String(data: data, encoding: .utf8) ?? "HTTP \(http.statusCode)"
            throw NSError(domain: "OpenAI", code: http.statusCode, userInfo: [NSLocalizedDescriptionKey: errText])
        }
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        if let text = openAIExtractTextFromResponse(json) { return text }
        let rawPreview = String(data: data, encoding: .utf8).map { String($0.prefix(500)) } ?? "–"
        throw NSError(domain: "OpenAI", code: -1, userInfo: [NSLocalizedDescriptionKey: "Antwort konnte nicht geparst werden. Raw: \(rawPreview)"])
    }
    
    /// Chat Completions API (Fallback) – choices[0].message.content. temperature 0 + seed 42 für reproduzierbarere Ergebnisse.
    private static func openAICallChatCompletions(systemPrompt: String, userPrompt: String, apiKey: String, model: String = openAIModelFallback) async throws -> String {
        let url = URL(string: "https://api.openai.com/v1/chat/completions")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 30
        let body: [String: Any] = [
            "model": model,
            "messages": [
                ["role": "system", "content": systemPrompt],
                ["role": "user", "content": userPrompt]
            ],
            "temperature": 0,
            "seed": 42
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            let errText = String(data: data, encoding: .utf8) ?? "HTTP-Fehler"
            throw NSError(domain: "OpenAI", code: (response as? HTTPURLResponse)?.statusCode ?? -1, userInfo: [NSLocalizedDescriptionKey: errText])
        }
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        if let content = openAIExtractTextFromResponse(json) { return content }
        throw NSError(domain: "OpenAI", code: -1, userInfo: [NSLocalizedDescriptionKey: "Antwort konnte nicht geparst werden"])
    }
    
    /// Extrahiert Text aus Responses- oder Chat-Completions-JSON
    private static func openAIExtractTextFromResponse(_ json: [String: Any]?) -> String? {
        guard let json = json else { return nil }
        if let t = json["output_text"] as? String { return t }
        if let output = json["output"] as? [[String: Any]] {
            for item in output {
                if let content = item["content"] as? [[String: Any]] {
                    for c in content {
                        if (c["type"] as? String) == "output_text", let t = c["text"] as? String { return t }
                    }
                }
            }
        }
        if let outputItems = json["output_items"] as? [[String: Any]] {
            for item in outputItems {
                if let content = item["content"] as? [[String: Any]] {
                    for c in content {
                        if (c["type"] as? String) == "output_text", let t = c["text"] as? String { return t }
                    }
                }
            }
        }
        if let choices = json["choices"] as? [[String: Any]],
           let first = choices.first,
           let message = first["message"] as? [String: Any],
           let content = message["content"] as? String { return content }
        return nil
    }
    
    /// Ruft Kursziel von OpenAI ab (gpt-4o mit web_search) – benötigt API-Key in Einstellungen
    static func fetchKurszielVonOpenAI(wkn: String, bezeichnung: String? = nil, isin: String? = nil) async -> KurszielInfo? {
        guard let apiKey = openAIAPIKey, !apiKey.isEmpty else {
            debug("   ❌ OpenAI API-Key nicht konfiguriert (Einstellungen)")
            return nil
        }
        zugriffeOpenAI += 1
        debug("   🔑 OpenAI API-Key geladen (Länge \(apiKey.count), Format: \(apiKey.hasPrefix("sk-") ? "sk-... ✓" : "Präfix prüfen"))")
        let isinTrimmed = isin?.trimmingCharacters(in: .whitespaces)
        let hasISIN = (isinTrimmed?.count ?? 0) >= 10
        guard hasISIN || !wkn.isEmpty else {
            debug("   ❌ Weder ISIN (≥10 Zeichen) noch WKN vorhanden")
            return nil
        }
        
        if hasISIN {
            debug("   📌 Verwende ISIN: \(isinTrimmed ?? "")")
        } else {
            debug("   📌 ISIN leer/zu kurz, verwende WKN: \(wkn)")
        }
        
        let prompt: String
        if hasISIN, let isin = isinTrimmed {
            prompt = "ISIN \(isin): durchschnittliches Kursziel (Analysten-Zielkurs) in EUR – nicht der aktuelle Börsenkurs. Rückgabe nur den Wert oder -1 wenn nichts gefunden wird."
        } else {
            prompt = "WKN \(wkn): durchschnittliches Kursziel (Analysten-Zielkurs) in EUR – nicht der aktuelle Börsenkurs. Rückgabe nur den Wert oder -1 wenn nichts gefunden wird."
        }
        debug("   📤 OpenAI Request (Responses API): \(prompt)")
        debug("   📡 Sende an https://api.openai.com/v1/responses ...")
        
        do {
            let content = try await openAICallWithFallback(systemPrompt: openAISystemPrompt, userPrompt: prompt, apiKey: apiKey)
            debug("   📥 OpenAI Response (raw): \(content)")
            var trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
            // BOM und Nicht-Breaking Spaces entfernen, damit "Antwort:" am Anfang erkannt wird
            if trimmed.hasPrefix("\u{FEFF}") { trimmed = String(trimmed.dropFirst()) }
            trimmed = trimmed.replacingOccurrences(of: "\u{00A0}", with: " ")
            trimmed = trimmed.trimmingCharacters(in: .whitespacesAndNewlines)
            // "Antwort:" / "Rückgabe:" / "Ergebnis:" (+ etliche Leerzeichen/Zeilen) + Betrag → alles danach trimmen, Betrag parsen
            for prefix in ["Antwort:", "Antwort :", "Rückgabe:", "Rückgabe :", "Ergebnis:", "Ergebnis :", "Answer:", "Answer :", "Somit lautet die Antwort:"] {
                if let r = trimmed.range(of: prefix, options: [.caseInsensitive, .anchored]) {
                    trimmed = String(trimmed[r.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
                    break
                }
            }
            // Falls "Antwort:" / "Rückgabe:" / "Ergebnis:" nicht am Anfang stand: irgendwo suchen, Rest (etliche Leerzeichen + Wert) übernehmen
            for fallback in ["Antwort:", "Antwort :", "Rückgabe:", "Rückgabe :", "Ergebnis:", "Ergebnis :", "Answer:", "Answer :"] {
                if let r = trimmed.range(of: fallback, options: .caseInsensitive) {
                    trimmed = String(trimmed[r.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
                    break
                }
            }
            // "in Euro beträgt:" + ggf. 1–2 Zeilen nur Leerzeichen + Betrag (EUR) → alles nach "in Euro beträgt:" trimmen und Betrag parsen
            if let euroRange = trimmed.range(of: "in Euro beträgt:", options: .caseInsensitive) {
                trimmed = String(trimmed[euroRange.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
            }
            // Markdown-Bold **Wert** oder *Wert* entfernen, damit z. B. "**10,45**" zu "10,45" wird
            trimmed = trimmed.trimmingCharacters(in: CharacterSet(charactersIn: "*"))
            debug("   📥 OpenAI Response (content): \(trimmed)")
            guard let kursziel = openAIParseKursziel(trimmed), kursziel > 0 else {
                debug("   ❌ OpenAI: Antwort konnte nicht geparst werden oder < 0")
                return nil
            }
            // Verhindern: Modell gibt ISIN/WKN-Ziffern statt Kursziel zurück (z.B. 11821202 aus DE00011821202)
            let kurszielStr = String(format: "%.0f", kursziel)
            if kurszielStr.count >= 7, let isin = isinTrimmed, isin.contains(kurszielStr) {
                debug("   ❌ OpenAI: Rückgabe sieht nach ISIN-Kennung aus (\(kurszielStr)), nicht nach Kursziel – ignoriert")
                return nil
            }
            if kursziel >= 1_000_000, kursziel == floor(kursziel) {
                debug("   ❌ OpenAI: Unplausibel hoher ganzzahliger Wert (\(kursziel)) – evtl. ISIN, ignoriert")
                return nil
            }
            let waehrung = (trimmed.contains("$") || trimmed.uppercased().contains("USD")) ? "USD" : "EUR"
            debug("   ✅ OpenAI: \(kursziel) \(waehrung)")
            return KurszielInfo(kursziel: kursziel, datum: Date(), spalte4Durchschnitt: nil, quelle: .openAI, waehrung: waehrung)
        } catch {
            let nsErr = error as NSError
            debug("   ❌ OpenAI Fehler: \(error.localizedDescription)")
            if nsErr.domain == NSURLErrorDomain {
                debug("   📡 Netzwerk-Code: \(nsErr.code) – prüfe App-Sandbox: com.apple.security.network.client")
            }
            return nil
        }
    }
    
    /// Ruft Kursziel von ariva.de ab
    private static func fetchKurszielVonAriva(slug: String) async -> KurszielInfo? {
        // ariva.de: {slug}-aktie/kursziele
        let arivaSlug = slug.replacingOccurrences(of: "_", with: "-")
        let urlString = "https://www.ariva.de/\(arivaSlug)-aktie/kursziele"
        return await fetchKurszielFromURL(urlString)
    }
    
    /// Gemeinsame HTTP-Anfrage und HTML-Parsing (ohne Tab-Suche)
    private static func fetchKurszielFromURLWithTab(_ urlString: String) async -> KurszielInfo? {
        // Einfach die normale fetchKurszielFromURL verwenden
        return await fetchKurszielFromURL(urlString)
    }
    
    /// Gemeinsame HTTP-Anfrage und HTML-Parsing
    private static func fetchKurszielFromURL(_ urlString: String) async -> KurszielInfo? {
        guard let url = URL(string: urlString) else { 
            debug("   ❌ Ungültige URL: \(urlString)")
            return nil 
        }
        
        do {
            var request = URLRequest(url: url)
            request.setValue("Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Mobile/15E148 Safari/604.1", forHTTPHeaderField: "User-Agent")
            request.setValue("de-DE,de;q=0.9,en;q=0.8", forHTTPHeaderField: "Accept-Language")
            request.setValue("https://www.finanzen.net/", forHTTPHeaderField: "Referer")
            request.setValue("text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8", forHTTPHeaderField: "Accept")
            request.timeoutInterval = 10.0
            
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse else {
                debug("   ❌ Keine HTTP-Antwort")
                return nil
            }
            
            debug("   📥 HTTP Status: \(httpResponse.statusCode)")
            
            guard (200...399).contains(httpResponse.statusCode) else { 
                debug("   ❌ HTTP Fehler: \(httpResponse.statusCode)")
                return nil 
            }
            
            if let html = String(data: data, encoding: .utf8) {
                debug("   📄 HTML-Größe: \(html.count) Zeichen")
                // Zeige ersten 500 Zeichen des HTMLs für Debugging
                let preview = String(html.prefix(500))
                debug("   📋 HTML-Vorschau: \(preview)...")
                
                if let (kursziel, spalte4, waehrung, ohneUmrechnung) = parseKurszielFromHTML(html, urlString: urlString) {
                    debug("   ✅ Kursziel aus HTML geparst: \(kursziel) \(waehrung ?? "EUR")" + (spalte4.map { ", Spalte 4: \($0)" } ?? ""))
                    return KurszielInfo(kursziel: kursziel, datum: Date(), spalte4Durchschnitt: spalte4, quelle: .finanzenNet, waehrung: waehrung ?? "EUR", ohneDevisenumrechnung: ohneUmrechnung)
                } else {
                    debug("   ❌ Kein Kursziel im HTML gefunden")
                }
            } else {
                debug("   ❌ HTML konnte nicht dekodiert werden")
            }
        } catch {
            debug("   ❌ Fehler: \(error.localizedDescription)")
        }
        
        return nil
    }
    
    /// Extrahiert Kursziel aus HTML-Tabellen
    /// Sucht nach Tabellen mit "Analyst"/"Analysten" und "Kursziel" als Überschriftsfeld
    /// urlString für Slug-Extraktion (z. B. /kursziele/allianz → allianz) bei Buy/Hold-Tabelle
    /// Rückgabe: (Kursziel-Durchschnitt, Spalte-4-Durchschnitt?, Währung, ohneDevisenumrechnung wenn nur eine andere Währung)
    private static func extractKurszielFromHTMLTables(_ html: String, urlString: String? = nil) -> (Double, Double?, String?, Bool)? {
        debug("   🔍 Suche nach Tabellen mit 'Analyst'/'Analysten' und 'Kursziel' als Überschrift...")
        
        // Finde alle <table> Tags
        let tablePattern = "<table[^>]*>([\\s\\S]*?)</table>"
        guard let tableRegex = try? NSRegularExpression(pattern: tablePattern, options: [.caseInsensitive, .dotMatchesLineSeparators]) else {
            return nil
        }
        
        let htmlRange = NSRange(html.startIndex..., in: html)
        var tableMatches = tableRegex.matches(in: html, options: [], range: htmlRange)
        
        // WICHTIG: Sortiere nach Tabellengröße absteigend – das nicht-gierige Regex
        // trifft verschachtelte (innere) Tabellen zuerst. Die Haupttabelle ist die größte.
        // So verarbeiten wir die äußere Tabelle mit den echten Kursziel-Daten zuerst.
        tableMatches.sort { $0.range.length > $1.range.length }
        
        debug("   📊 Gefundene Tabellen insgesamt: \(tableMatches.count) (sortiert nach Größe)")
        
        // Durchsuche ALLE Tabellen (größte zuerst)
        for (tableIdx, match) in tableMatches.enumerated() {
            guard let tableRange = Range(match.range, in: html) else { continue }
            let tableHTML = String(html[tableRange])
            
            debug("   🔍 Prüfe Tabelle \(tableIdx+1)")
            
            // Suche nach <thead> oder erste <tr> für Header
            var headers: [String] = []
            
            // Versuche <thead> zu finden
            let theadPattern = "<thead[^>]*>([\\s\\S]*?)</thead>"
            var headerRowIndex = 0
            if let theadRegex = try? NSRegularExpression(pattern: theadPattern, options: [.caseInsensitive, .dotMatchesLineSeparators]),
               let theadMatch = theadRegex.firstMatch(in: tableHTML, options: [], range: NSRange(tableHTML.startIndex..., in: tableHTML)),
               let theadRange = Range(theadMatch.range(at: 1), in: tableHTML) {
                let theadHTML = String(tableHTML[theadRange])
                headers = extractTableHeaders(from: theadHTML)
                debug("   📋 Header aus <thead> extrahiert")
            } else {
                // Versuche Zeilen – suche erste Zeile mit "Analyst" UND "Kursziel" (z. B. Siemens Energy: erste Zeile ist "Kurs|Ø Kursziel|BUY|HOLD|SELL", zweite "Analyst|Kursziel|Abstand Kursziel|Datum")
                let trPattern = "<tr[^>]*>([\\s\\S]*?)</tr>"
                if let trRegex = try? NSRegularExpression(pattern: trPattern, options: [.caseInsensitive, .dotMatchesLineSeparators]) {
                    let range = NSRange(tableHTML.startIndex..., in: tableHTML)
                    let matches = trRegex.matches(in: tableHTML, options: [], range: range)
                    for (idx, trMatch) in matches.enumerated() {
                        guard let trRange = Range(trMatch.range(at: 1), in: tableHTML) else { continue }
                        let rowHTML = String(tableHTML[trRange])
                        let rowHeaders = extractTableHeaders(from: rowHTML)
                        let rowText = rowHeaders.joined(separator: " ").lowercased()
                        let hatAnalyst = rowHeaders.contains { $0.lowercased().contains("analyst") || $0.lowercased().contains("analysten") }
                        let hatKursziel = rowHeaders.contains { h in
                            let l = h.lowercased()
                            return l.contains("kursziel") && !l.contains("marktkap") && !l.contains("kapitalisierung")
                        }
                        if hatAnalyst && hatKursziel {
                            headers = rowHeaders
                            headerRowIndex = idx
                            debug("   📋 Header aus Zeile \(idx+1) extrahiert (Analyst+Kursziel gefunden)")
                            break
                        }
                    }
                    if headers.isEmpty, let firstMatch = matches.first,
                       let trRange = Range(firstMatch.range(at: 1), in: tableHTML) {
                        let firstRowHTML = String(tableHTML[trRange])
                        headers = extractTableHeaders(from: firstRowHTML)
                        debug("   📋 Header aus erster Zeile extrahiert (Fallback)")
                    }
                }
            }
            
            debug("   📋 Tabelle: \(headers.count) Spalten gefunden")
            debug("   📋 Spalten: \(headers.joined(separator: ", "))")
            
            let tableText = tableHTML.lowercased()
            let headersText = headers.joined(separator: " ").lowercased()
            
            // Variant 2: Buy/Hold/Sell-Tabelle mit Ø Kursziel und Abst. Kursziel – Zeile per Firmenname (Slug aus URL)
            let hasBuyHoldSell = tableText.contains("buy") && tableText.contains("sell")
            let hasOderKursziel = headersText.contains("ø kursziel") || headersText.contains("Ø kursziel")
            let hasAbstKursziel = headersText.contains("abst") && headersText.contains("kursziel")
            if hasBuyHoldSell && hasOderKursziel && hasAbstKursziel, let urlStr = urlString {
                let slug = urlStr.components(separatedBy: "/").last?.lowercased().trimmingCharacters(in: .whitespaces) ?? ""
                if !slug.isEmpty {
                    debug("   🔍 Variant 2: Buy/Hold-Tabelle, suche Zeile mit Slug '\(slug)'")
                    let rows = extractTableRows(from: tableHTML)
                    // Ø Kursziel-Spalte (nicht Abst. Kursziel) – eine Spalte weiter als Buy/Hold/Sell
                    let kurszielIdx = headers.firstIndex { h in
                        let l = h.lowercased()
                        return (l.contains("ø") || l.contains("durchschnitt")) && l.contains("kursziel") && !l.contains("abst")
                    }
                    let abstandIdx = headers.firstIndex { h in
                        let l = h.lowercased()
                        return (l.contains("abst") || l.contains("abstand")) && l.contains("kursziel")
                    }
                    if let kIdx = kurszielIdx, let aIdx = abstandIdx, kIdx < headers.count, aIdx < headers.count {
                        for row in rows.dropFirst() {
                            guard row.count > max(kIdx, aIdx) else { continue }
                            let aktieCell = row[0].lowercased()
                            if aktieCell.contains(slug) || slug.contains(aktieCell.replacingOccurrences(of: " ", with: "")) {
                                let betragStr = row[kIdx]
                                let abstandStr = row[aIdx]
                                let naechsteZelle = row.count > kIdx + 1 ? row[kIdx + 1] : ""
                                if let betrag = parseNumberFromTable(betragStr), betrag > 0 {
                                    let w = waehrungAusZelle(betragStr) ?? waehrungAusZelle(naechsteZelle) ?? "EUR"
                                    let abstand = parseNumberFromTable(abstandStr)
                                    debug("   ✅ Variant 2: Zeile gefunden – \(betrag) \(w), Abstand \(abstand.map { "\($0)%" } ?? "–")" + ((w == "USD" || w == "GBP") ? " (wird in EUR umgerechnet)" : ""))
                                    return (betrag, abstand, w, false)
                                }
                            }
                        }
                        debug("   ⚠️  Variant 2: Keine Zeile mit '\(slug)' gefunden")
                    }
                }
                debug("   ⏭️  Variant 2: Kein Slug aus URL, überspringe")
            }
            
            // Variant 1 zuerst prüfen – Analyst/Analysten+Kursziel-Tabelle hat Vorrang (auch wenn „buy“/„sell“ im HTML vorkommt)
            let hasAnalyst = headers.contains { $0.lowercased().contains("analyst") || $0.lowercased().contains("analysten") }
            let hasKursziel = headers.contains { header in
                let h = header.lowercased()
                return h.contains("kursziel") && !h.contains("marktkap") && !h.contains("kapitalisierung")
            }
            if hasAnalyst && hasKursziel {
                // Analyst-Tabelle (Variant 1) – nicht überspringen, auch wenn Buy/Sell irgendwo im HTML steht
                debug("   ✅ Analyst+Kursziel in Header – verarbeite als Variant 1 (ignoriere Buy/Sell im HTML)")
            } else if hasBuyHoldSell && !(hasOderKursziel && hasAbstKursziel) {
                debug("   ⏭️  Überspringe Tabelle \(tableIdx+1) – Buy-Sell ohne Ø/Abst. Kursziel")
                continue
            } else if hasBuyHoldSell {
                continue
            }
            
            // Variant 1: Tabelle mit Analyst UND Kursziel (Abstand optional – kann „Abstand Kursziel“ ohne Ø sein, Zeilen mit „-“)
            let hasAbstand = headersText.contains("abstand")
            
            // Variant 1: Analyst | Kursziel | [Abstand Kursziel] – Abstand optional (z. B. Siemens Energy: „-“ in Zeilen)
            if !(hasAnalyst && hasKursziel) {
                debug("   ⏭️  Überspringe Tabelle \(tableIdx+1) – fehlt Analyst/Kursziel (Variant 1)")
                continue
            }
            debug("   ✅ Variant 1: Analyst + Kursziel in Header" + (hasAbstand ? " (+ Abstand)" : " (ohne Abstand)"))
            
            // Finde Kursziel-Spalten-Index – NUR Durchschnitt/Kursziel, NICHT Höchstziel/Tiefstziel!
                var kurszielColumnIndex: Int? = nil
                for (idx, header) in headers.enumerated() {
                    let headerLower = header.lowercased()
                    // Höchstziel/Tiefstziel ausschließen – die liefern falsche Werte (z.B. 2714 statt 1145)
                    if headerLower.contains("höchst") || headerLower.contains("tiefst") || headerLower.contains("high") || headerLower.contains("low") {
                        continue
                    }
                    // Suche "Kursziel" oder "Durchschnitt" – nicht "Marktkap", nicht "Abstand" (Abstand Kursziel ist eine Spalte weiter)
                    if (headerLower.contains("kursziel") || headerLower.contains("durchschnitt") || headerLower.contains("konsens"))
                        && !headerLower.contains("marktkap") && !headerLower.contains("kapitalisierung")
                        && !headerLower.contains("abstand") && !headerLower.contains("abst") {
                        kurszielColumnIndex = idx
                        debug("   📍 Kursziel-Spalte Index: \(idx), Name: '\(header)'")
                        break
                    }
                }
                // Fallback: "ziel" oder "target", aber weiterhin Höchst/Tiefst ausschließen
                if kurszielColumnIndex == nil {
                    for (idx, header) in headers.enumerated() {
                        let headerLower = header.lowercased()
                        if (headerLower.contains("höchst") || headerLower.contains("tiefst") || headerLower.contains("high") || headerLower.contains("low")) { continue }
                        if (headerLower.contains("ziel") || headerLower.contains("target"))
                            && !headerLower.contains("marktkap") && !headerLower.contains("kapitalisierung") && !headerLower.contains("analyst") {
                            kurszielColumnIndex = idx
                            debug("   📍 Kursziel-Spalte (Variante) Index: \(idx), Name: '\(header)'")
                            break
                        }
                    }
                }
                
                // Falls immer noch keine Kursziel-Spalte gefunden, aber "Analyst" vorhanden ist,
                // suche in den Daten nach Zahlen, die wie Kursziele aussehen
                // Struktur: Analyst | Pfeil | Kursziel | +/- | Abstand
                if kurszielColumnIndex == nil && hasAnalyst {
                    // Finde Analyst-Spalten-Index
                    var analystColumnIndex: Int? = nil
                    for (idx, header) in headers.enumerated() {
                        if header.lowercased().contains("analyst") {
                            analystColumnIndex = idx
                            debug("   📍 Analyst-Spalte Index: \(idx)")
                            break
                        }
                    }
                    
                    // Die Kursziel-Spalte ist wahrscheinlich 2 Spalten nach Analyst (Analyst | Pfeil | Kursziel)
                    if let analystIdx = analystColumnIndex {
                        let rows = extractTableRows(from: tableHTML)
                        
                        // Prüfe verschiedene Positionen nach Analyst
                        // Position analystIdx+1 könnte Pfeil sein, analystIdx+2 könnte Kursziel sein
                        for offset in [1, 2, 3] {
                            let candidateIdx = analystIdx + offset
                            if candidateIdx < headers.count {
                                var hasKurszielFormat = false
                                // Prüfe erste paar Datenzeilen (überspringe Header)
                                for row in rows.dropFirst().prefix(3) {
                                    if row.count > candidateIdx {
                                        let cell = row[candidateIdx]
                                        // Prüfe ob es wie "2060,00 EUR" aussieht
                                        if cell.contains("EUR") || cell.contains("€") || 
                                           (parseNumberFromTable(cell) != nil && parseNumberFromTable(cell)! > 100) {
                                            hasKurszielFormat = true
                                            debug("   🔍 Spalte \(candidateIdx) enthält Kursziel-Format: '\(cell)'")
                                            break
                                        }
                                    }
                                }
                                if hasKurszielFormat {
                                    kurszielColumnIndex = candidateIdx
                                    debug("   📍 Kursziel-Spalte vermutet als Index \(candidateIdx) (Offset \(offset) nach Analyst)")
                                    break
                                }
                            }
                        }
                    }
                }
                
                // Extrahiere alle Zeilen – nutze ermittelten Spaltenindex (nicht feste Spalte 2!)
                // Feste Spalte 2 kann "Höchstziel" o.ä. sein – kurszielColumnIndex ist korrekt
                let allRows = extractTableRows(from: tableHTML)
                // Überspringe Zeilen vor der Header-Zeile (z. B. „Kurs|Ø Kursziel|BUY|HOLD|SELL“)
                let rows = headerRowIndex > 0 ? Array(allRows.dropFirst(headerRowIndex + 1)) : allRows
                debug("   📊 \(allRows.count) Zeilen gesamt, \(rows.count) Datenzeilen (nach Header)")
                debug("   📋 Alle Zeilen (mit |):")
                for (rowIdx, row) in rows.enumerated() {
                    let rowString = row.joined(separator: " | ")
                    debug("      Zeile \(rowIdx+1): \(rowString)")
                }
                
                let spalteBetrag = kurszielColumnIndex ?? 2   // Kursziel-Spalte aus Header, Fallback 2
                debug("   📐 Spalten-Mapping: Kursziel = Index \(spalteBetrag), Abstand % = Spalte direkt danach")
                // Pivot-/Werbungstabellen überspringen (z. B. Schokolade-Werbung) – danach folgen die echten Daten mit |
                let pivotStichwoerter = ["schokolade", "werbung", "pivot", "sponsored", "anzeige", "rabatt", "angebot"]
                var verarbeitungGestartet = false
                var summeEUR: Decimal = 0
                var summeUSD: Decimal = 0
                var summeGBP: Decimal = 0
                var summeDKK: Decimal = 0
                var anzahlEUR = 0
                var anzahlUSD = 0
                var anzahlGBP = 0
                var anzahlDKK = 0
                var summeSpalte4: Decimal = 0
                var anzahlZeilenSpalte4 = 0
                var anzahlSpalten = 0
                
                for (rowIdx, row) in rows.enumerated() {
                    let rowMitPipe = row.joined(separator: " | ")
                    let hatPipe = rowMitPipe.contains("|")
                    let rowLower = rowMitPipe.lowercased()
                    
                    // Pivot/Werbung überspringen (z. B. Schokolade-Anzeige) – darüber hinweglesen
                    if hatPipe && pivotStichwoerter.contains(where: { rowLower.contains($0) }) {
                        debug("   ⏭️  Überspringe Zeile \(rowIdx+1) – Pivot/Werbung erkannt")
                        continue
                    }
                    
                    // Start: Erstes | gefunden → Verarbeitung beginnen
                    if !verarbeitungGestartet {
                        if hatPipe {
                            verarbeitungGestartet = true
                            anzahlSpalten = row.count
                            debug("   ▶️  Start bei Zeile \(rowIdx+1) – erstes | Zeichen gefunden, \(anzahlSpalten) Spalten")
                        } else {
                            debug("   ⏭️  Überspringe Zeile \(rowIdx+1) – noch kein |")
                            continue
                        }
                    }
                    
                    // Stopp: Kein | mehr → Einlesung beenden
                    if verarbeitungGestartet && !hatPipe {
                        debug("   ⏹️  Stopp bei Zeile \(rowIdx+1) – kein | Zeichen mehr")
                        break
                    }
                    
                    // Betrag parsen – Währung pro Zeile aus Zelle (direkt nach Betrag)
                    // Mindestens spalteBetrag+1 Spalten nötig (nicht spalteAbstand – manche Zeilen haben weniger)
                    if row.count > spalteBetrag {
                        let betragStr = row[spalteBetrag]
                        let naechsteSpalteStr = row.count > spalteBetrag + 1 ? row[spalteBetrag + 1] : ""
                        debug("   🔍 Zeile \(rowIdx+1): Kursziel Index \(spalteBetrag)='\(betragStr)' | Abstand Index \(spalteBetrag+1)='\(naechsteSpalteStr)' [erwartet z.B. +8,85%]")
                        
                        // Kursziel: zuerst aus Kursziel-Spalte, falls leer/ungültig aus nächster Spalte (z.B. Eli Lilly)
                        var kurszielWert: Double? = nil
                        var kurszielWaehrung: String? = nil
                        var kurszielSpalteIdx = spalteBetrag
                        
                        if let betrag = parseNumberFromTable(betragStr), betrag > 0 {
                            let w = waehrungAusZelle(betragStr) ?? "EUR"
                            kurszielWert = betrag
                            kurszielWaehrung = w
                            kurszielSpalteIdx = spalteBetrag
                        } else if let wert = parseNumberFromTable(naechsteSpalteStr), wert > 0, let w = waehrungAusZelle(naechsteSpalteStr) {
                            kurszielWert = wert
                            kurszielWaehrung = w
                            kurszielSpalteIdx = spalteBetrag + 1
                            debug("   📍 Kursziel aus Index \(spalteBetrag+1) (Währung in Zelle): \(wert) \(w)")
                        }
                        
                        if let betrag = kurszielWert, let w = kurszielWaehrung {
                            if w == "USD" {
                                summeUSD += Decimal(betrag)
                                anzahlUSD += 1
                                debug("   ✅ Betrag: \(betrag) USD")
                            } else if w == "GBP" {
                                summeGBP += Decimal(betrag)
                                anzahlGBP += 1
                                debug("   ✅ Betrag: \(betrag) GBP")
                            } else if w == "DKK" {
                                summeDKK += Decimal(betrag)
                                anzahlDKK += 1
                                debug("   ✅ Betrag: \(betrag) DKK")
                            } else {
                                summeEUR += Decimal(betrag)
                                anzahlEUR += 1
                                debug("   ✅ Betrag: \(betrag) EUR")
                            }
                            // Abstand: Spalte direkt nach dem Kursziel – %-Wert (z.B. +8,85%)
                            let abstandSpalteIdx = kurszielSpalteIdx + 1
                            let abstandStr = row.count > abstandSpalteIdx ? row[abstandSpalteIdx] : ""
                            if waehrungAusZelle(abstandStr) == nil, let abstand = parseNumberFromTable(abstandStr) {
                                summeSpalte4 += Decimal(abstand)
                                anzahlZeilenSpalte4 += 1
                                debug("   📏 Abstand: \(abstand)% (Index \(abstandSpalteIdx))")
                            }
                        }
                    }
                }
                
                // Bei gemischten Währungen: EUR bevorzugt. USD/GBP/DKK werden immer in EUR umgerechnet.
                let (summeBetrag, anzahlZeilen, erkannteWaehrung, ohneUmrechnung): (Decimal, Int, String?, Bool) = {
                    if anzahlEUR > 0 && (anzahlUSD > 0 || anzahlGBP > 0 || anzahlDKK > 0) {
                        debug("   ⚠️  Gemischte Währungen – nur EUR-Zeilen (\(anzahlEUR)) werden bewertet")
                        return (summeEUR, anzahlEUR, "EUR", false)
                    }
                    if anzahlEUR > 0 { return (summeEUR, anzahlEUR, "EUR", false) }
                    if anzahlGBP > 0 {
                        debug("   📌 Nur GBP-Zeilen – wird in EUR umgerechnet")
                        return (summeGBP, anzahlGBP, "GBP", false)
                    }
                    if anzahlUSD > 0 {
                        debug("   📌 Nur USD-Zeilen – wird in EUR umgerechnet")
                        return (summeUSD, anzahlUSD, "USD", false)
                    }
                    if anzahlDKK > 0 {
                        debug("   📌 Nur DKK-Zeilen – wird in EUR umgerechnet")
                        return (summeDKK, anzahlDKK, "DKK", false)
                    }
                    return (0, 0, nil, false)
                }()
                
                // Ergebnis: Summen getrennt + finale Währung – im Debug anzeigen
                debug("   📊 Ergebnis – EUR: Summe=\(summeEUR), Anzahl=\(anzahlEUR) | GBP: Summe=\(summeGBP), Anzahl=\(anzahlGBP) | USD: Summe=\(summeUSD), Anzahl=\(anzahlUSD) | DKK: Summe=\(summeDKK), Anzahl=\(anzahlDKK)")
                let waehrungDebug = erkannteWaehrung ?? "EUR"
                debug("   📊 Ergebnis – Verwendet: Summe=\(summeBetrag) \(waehrungDebug), Anzahl=\(anzahlZeilen)")
                let durchschnittSp4 = anzahlZeilenSpalte4 > 0 ? summeSpalte4 / Decimal(anzahlZeilenSpalte4) : nil
                debug("   📊 Ergebnis – Spalte 4: Summe=\(summeSpalte4), Anzahl=\(anzahlZeilenSpalte4), Durchschnitt=\(durchschnittSp4.map { "\($0)" } ?? "–")")
                
                if anzahlZeilen > 0 {
                    let durchschnitt = summeBetrag / Decimal(anzahlZeilen)
                    let durchschnittDouble = NSDecimalNumber(decimal: durchschnitt).doubleValue
                    let spalte4Double = durchschnittSp4.map { NSDecimalNumber(decimal: $0).doubleValue }
                    return (durchschnittDouble, spalte4Double, erkannteWaehrung, ohneUmrechnung)
                } else {
                    debug("   ⚠️  Keine gültigen Beträge in Spalte 3 gefunden")
                }
        }
        
        debug("   ❌ Keine passende Tabelle mit Kursziel gefunden")
        return nil
    }
    
    /// Extrahiert Header aus HTML (th oder td Tags)
    private static func extractTableHeaders(from html: String) -> [String] {
        var headers: [String] = []
        let cellPattern = "<(th|td)[^>]*>([\\s\\S]*?)</(th|td)>"
        
        if let regex = try? NSRegularExpression(pattern: cellPattern, options: [.caseInsensitive]) {
            let range = NSRange(html.startIndex..., in: html)
            let matches = regex.matches(in: html, options: [], range: range)
            
            for match in matches {
                if match.numberOfRanges > 2,
                   let contentRange = Range(match.range(at: 2), in: html) {
                    let content = String(html[contentRange])
                    let cleaned = cleanHTMLText(content)
                    if !cleaned.isEmpty {
                        headers.append(cleaned)
                    }
                }
            }
        }
        
        return headers
    }
    
    /// Extrahiert Zeilen aus HTML-Tabelle
    private static func extractTableRows(from html: String) -> [[String]] {
        var rows: [[String]] = []
        let rowPattern = "<tr[^>]*>([\\s\\S]*?)</tr>"
        
        if let regex = try? NSRegularExpression(pattern: rowPattern, options: [.caseInsensitive, .dotMatchesLineSeparators]) {
            let range = NSRange(html.startIndex..., in: html)
            let matches = regex.matches(in: html, options: [], range: range)
            
            for match in matches {
                if match.numberOfRanges > 1,
                   let rowRange = Range(match.range(at: 1), in: html) {
                    let rowHTML = String(html[rowRange])
                    let cells = extractTableCells(from: rowHTML)
                    if !cells.isEmpty {
                        rows.append(cells)
                    }
                }
            }
        }
        
        return rows
    }
    
    /// Extrahiert Zellen aus einer Tabellenzeile
    private static func extractTableCells(from html: String) -> [String] {
        var cells: [String] = []
        let cellPattern = "<(td|th)[^>]*>([\\s\\S]*?)</(td|th)>"
        
        if let regex = try? NSRegularExpression(pattern: cellPattern, options: [.caseInsensitive, .dotMatchesLineSeparators]) {
            let range = NSRange(html.startIndex..., in: html)
            let matches = regex.matches(in: html, options: [], range: range)
            
            for match in matches {
                if match.numberOfRanges > 2,
                   let contentRange = Range(match.range(at: 2), in: html) {
                    let content = String(html[contentRange])
                    let cleaned = cleanHTMLText(content)
                    
                    // Wenn die Zelle Pipe-Zeichen enthält, könnte es mehrere Spalten sein
                    // Teile sie auf
                    if cleaned.contains("|") {
                        let parts = cleaned.split(separator: "|")
                        for part in parts {
                            let trimmed = part.trimmingCharacters(in: .whitespaces)
                            if !trimmed.isEmpty {
                                cells.append(trimmed)
                            }
                        }
                    } else {
                        cells.append(cleaned)
                    }
                }
            }
        }
        
        return cells
    }
    
    /// Bereinigt HTML-Text (entfernt Tags, Entities, etc.)
    private static func cleanHTMLText(_ text: String) -> String {
        var cleaned = text
            .replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
            // HTML-Entities dekodieren
            .replacingOccurrences(of: "&nbsp;", with: " ")
            .replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&quot;", with: "\"")
            // Numerische HTML-Entities (z.B. &#x2B; = +)
            .replacingOccurrences(of: "&#x2B;", with: "+")
            .replacingOccurrences(of: "&#43;", with: "+")
            .replacingOccurrences(of: "&#x2D;", with: "-")
            .replacingOccurrences(of: "&#45;", with: "-")
            // Entferne Pipe-Zeichen am Anfang/Ende (sind Trennzeichen)
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "|"))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned
    }
    
    /// Parst Zahl aus Tabellenzelle (wie Python-Version)
    /// Behandelt Format wie "2060,00 EUR" oder "2.060,00 EUR"
    private static func parseNumberFromTable(_ text: String) -> Double? {
        var cleaned = text.trimmingCharacters(in: .whitespaces)
        
        // Währung/Prozent/Leerzeichen entfernen
        cleaned = cleaned.replacingOccurrences(of: "€", with: "")
        cleaned = cleaned.replacingOccurrences(of: "EUR", with: "")
        cleaned = cleaned.replacingOccurrences(of: "USD", with: "")
        cleaned = cleaned.replacingOccurrences(of: "$", with: "")
        cleaned = cleaned.replacingOccurrences(of: "DKK", with: "")
        cleaned = cleaned.replacingOccurrences(of: "DKR", with: "")
        if cleaned.lowercased().hasSuffix("kr") { cleaned = String(cleaned.dropLast(2)) }
        cleaned = cleaned.replacingOccurrences(of: "%", with: "")
        cleaned = cleaned.replacingOccurrences(of: " ", with: "")
        
        // Entferne + oder - am Anfang (für Abstand, inkl. Unicode-Varianten)
        let plusMinus = CharacterSet(charactersIn: "+-\u{2212}\u{2013}")  // + - − –
        cleaned = cleaned.trimmingCharacters(in: plusMinus)
        cleaned = cleaned.trimmingCharacters(in: .whitespaces)
        
        // Tausenderpunkte entfernen, Dezimalkomma -> Punkt
        if cleaned.contains(".") && cleaned.contains(",") {
            // Deutsche Formatierung: 2.060,00 -> 2060.00
            cleaned = cleaned.replacingOccurrences(of: ".", with: "")
            cleaned = cleaned.replacingOccurrences(of: ",", with: ".")
        } else if cleaned.contains(".") {
            // Prüfe ob Punkt als Tausender-Trennzeichen
            let parts = cleaned.split(separator: ".")
            if parts.count > 2 {
                // Mehrere Punkte = Tausender-Trennzeichen: 2.060 -> 2060
                cleaned = cleaned.replacingOccurrences(of: ".", with: "")
            }
            // Sonst ist es Dezimaltrennzeichen: 2060.00
        } else if cleaned.contains(",") {
            // Nur Komma = Dezimaltrennzeichen: 2060,00 -> 2060.00
            cleaned = cleaned.replacingOccurrences(of: ",", with: ".")
        }
        
        return Double(cleaned)
    }
    
    /// Ermittelt Währung aus Zellinhalt (z. B. "2714,00 USD" -> "USD", "5,20 GBP" -> "GBP", "2060 EUR" -> "EUR")
    private static func waehrungAusZelle(_ text: String) -> String? {
        let upper = text.uppercased()
        if upper.contains("USD") || upper.contains("US$") || text.contains("$") { return "USD" }
        if upper.contains("GBP") || upper.contains("£") || upper.contains("PENCE") { return "GBP" }
        if upper.contains("DKK") || upper.contains("DKR") || upper.contains(" KR") || upper.hasSuffix(" KR") || text.contains(" kr.") || text.contains(" kr,") { return "DKK" }
        if upper.contains("EUR") || upper.contains("€") { return "EUR" }
        return nil
    }
    
    /// Parst Kursziel aus HTML
    /// Rückgabe: (Kursziel, Spalte-4-Durchschnitt?, Währung?, ohneDevisenumrechnung)
    private static func parseKurszielFromHTML(_ html: String, urlString: String? = nil) -> (Double, Double?, String?, Bool)? {
        debug("   🔍 Starte HTML-Parsing...")
        
        // NEUE METHODE: Versuche zuerst HTML-Tabellen zu extrahieren
        if let (kursziel, spalte4, waehrung, ohneUmrechnung) = extractKurszielFromHTMLTables(html, urlString: urlString) {
            debug("   ✅ Kursziel aus HTML-Tabelle extrahiert: \(kursziel) \(waehrung ?? "EUR")" + (spalte4.map { ", Spalte 4: \($0)" } ?? "") + (ohneUmrechnung ? " (ohne Umrechnung)" : ""))
            return (kursziel, spalte4, waehrung, ohneUmrechnung)
        }
        
        debug("   ⚠️  Keine passende Tabelle gefunden, verwende Regex-Parsing...")
        // Helper: Parst eine Zahl mit deutscher oder englischer Formatierung
        func parseNumber(_ str: String) -> Double? {
            var cleaned = str.trimmingCharacters(in: .whitespaces)
            
            // Entferne Tausender-Trennzeichen (Punkte) und ersetze Komma durch Punkt
            if cleaned.contains(".") && cleaned.contains(",") {
                // Deutsche Formatierung: 1.234,56 -> 1234.56
                cleaned = cleaned.replacingOccurrences(of: ".", with: "").replacingOccurrences(of: ",", with: ".")
            } else if cleaned.contains(".") {
                // Prüfe ob Punkt als Tausender-Trennzeichen oder Dezimaltrennzeichen verwendet wird
                let parts = cleaned.split(separator: ".")
                if parts.count == 2 {
                    // Wenn der Teil nach dem Punkt 3 Ziffern hat, könnte es Tausender-Trennzeichen sein
                    if parts[1].count == 3 && !parts[1].contains(",") {
                        // Wahrscheinlich Tausender-Trennzeichen: 2.170 -> 2170
                        cleaned = cleaned.replacingOccurrences(of: ".", with: "")
                    }
                    // Sonst ist es wahrscheinlich Dezimaltrennzeichen: 1234.56
                } else if parts.count > 2 {
                    // Mehrere Punkte = Tausender-Trennzeichen: 1.234.567 -> 1234567
                    cleaned = cleaned.replacingOccurrences(of: ".", with: "")
                }
            } else if cleaned.contains(",") {
                // Nur Komma = Dezimaltrennzeichen: 1234,56 -> 1234.56
                cleaned = cleaned.replacingOccurrences(of: ",", with: ".")
            }
            
            return Double(cleaned)
        }
        
        // PRIORITÄT 1: Suche nach expliziten Mittel/Durchschnitt-Werten (höchste Priorität)
        // Diese sollten bevorzugt werden, da sie den tatsächlichen Durchschnitt darstellen
        debug("   🔍 PRIORITÄT 1: Suche nach Mittel/Durchschnitt-Werten")
        let mittelPatterns = [
            "Mittel[^0-9]*von[^0-9]*[0-9]+[^0-9]*Analysten[^0-9]*von[^0-9]*([0-9]{1,4}[.,0-9]+)",
            "Mittel[^0-9]*([0-9]{1,4}[.,0-9]+)",
            "Durchschnitt[^0-9]*von[^0-9]*[0-9]+[^0-9]*Analysten[^0-9]*([0-9]{1,4}[.,0-9]+)",
            "Durchschnitt[^0-9]*([0-9]{1,4}[.,0-9]+)",
            "Durchschnittliches Kursziel[^0-9]*([0-9]{1,4}[.,0-9]+)",
            "Ø Kursziel[^0-9]*([0-9]{1,4}[.,0-9]+)",
            "Analystenkonsens[^0-9]*([0-9]{1,4}[.,0-9]+)"
        ]
        
        for (index, pattern) in mittelPatterns.enumerated() {
            if let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) {
                let range = NSRange(html.startIndex..., in: html)
                let matches = regex.matches(in: html, options: [], range: range)
                for match in matches {
                    if match.numberOfRanges > 1,
                       let kurszielRange = Range(match.range(at: 1), in: html) {
                        let kurszielString = String(html[kurszielRange])
                        debug("   📌 Pattern \(index+1) gefunden: '\(kurszielString)'")
                        if let kursziel = parseNumber(kurszielString), kursziel >= 1.0 {
                            debug("   ✅ Geparst als: \(kursziel) €")
                            return (kursziel, nil, nil, false)
                        } else {
                            debug("   ❌ Konnte nicht als Zahl geparst werden oder < 1.0")
                        }
                    }
                }
            }
        }
        debug("   ❌ Kein Mittel/Durchschnitt gefunden")
        
        // PRIORITÄT 2: Suche nach Bereichen, aber nur wenn sie plausibel sind (nicht Höchstziel)
        // Ignoriere Bereiche, die zu groß sind (z.B. 2162 - 2714, da 2714 wahrscheinlich Höchstziel ist)
        let bereichPatterns = [
            "Durchschnitt[^0-9]*([0-9]{1,4}[.,0-9]+)[^0-9]*[–-][^0-9]*([0-9]{1,4}[.,0-9]+)",
            "ca\\.?[^0-9]*~?([0-9]{1,4}[.,0-9]+)[^0-9]*[–-][^0-9]*([0-9]{1,4}[.,0-9]+)[^0-9]*€"
        ]
        
        for pattern in bereichPatterns {
            if let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) {
                let range = NSRange(html.startIndex..., in: html)
                let matches = regex.matches(in: html, options: [], range: range)
                for match in matches {
                    if match.numberOfRanges > 2,
                       let minRange = Range(match.range(at: 1), in: html),
                       let maxRange = Range(match.range(at: 2), in: html) {
                        let minString = String(html[minRange])
                        let maxString = String(html[maxRange])
                        
                        if let min = parseNumber(minString), let max = parseNumber(maxString), min > 0, max > min {
                            // Nur verwenden, wenn der Bereich nicht zu groß ist (max. 30% Unterschied)
                            // Dies filtert Höchstziel-Bereiche heraus
                            let differenzProzent = ((max - min) / min) * 100
                            if differenzProzent <= 30 {
                                // Berechne Durchschnitt
                                let durchschnitt = (min + max) / 2.0
                                if durchschnitt >= 1.0 {
                                    return (durchschnitt, nil, nil, false)
                                }
                            }
                        }
                    }
                }
            }
        }
        
        // PRIORITÄT 3: Suche nach einzelnen Kursziel-Werten (Fallback)
        let patterns = [
            "Kursziel[^0-9]*([0-9]{1,4}[.,0-9]+)",
            "Price Target[^0-9]*([0-9]{1,4}[.,0-9]+)",
            "Zielkurs[^0-9]*([0-9]{1,4}[.,0-9]+)",
            "targetMeanPrice[^}]*raw[^0-9]*([0-9]+[.,0-9]+)",
            "data-target-price=\"([0-9]+[.,0-9]+)\""
        ]
        
        for pattern in patterns {
            if let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) {
                let range = NSRange(html.startIndex..., in: html)
                let matches = regex.matches(in: html, options: [], range: range)
                for match in matches {
                    if match.numberOfRanges > 1,
                       let kurszielRange = Range(match.range(at: 1), in: html) {
                        let kurszielString = String(html[kurszielRange])
                        if let kursziel = parseNumber(kurszielString), kursziel >= 1.0 {
                            return (kursziel, nil, nil, false)
                        }
                    }
                }
            }
        }
        
        return nil
    }
    
    // MARK: - Watchlist-Lookup (ISIN/WKN → Bezeichnung, Kurs, Kursziel)
    
    /// Ergebnis eines Watchlist-Lookups: Bezeichnung, WKN, ISIN, aktueller Kurs (optional), Kursziel (optional)
    struct WatchlistLookupResult {
        let bezeichnung: String
        let wkn: String
        let isin: String
        let kurs: Double?
        let kursziel: Double?
    }
    
    /// Sucht zu ISIN oder WKN Bezeichnung, aktuellen Kurs und Kursziel (z. B. für Watchlist-Eingabe).
    /// Kurs und Kursziel werden bei Fremdwährung (USD/GBP) in EUR umgerechnet.
    static func lookupWatchlist(searchTerm: String) async -> WatchlistLookupResult? {
        let term = searchTerm.trimmingCharacters(in: .whitespaces)
        guard !term.isEmpty else { return nil }
        _ = await fetchAppWechselkurse()
        let encoded = term.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? term
        let searchURL = "https://www.finanzen.net/suchergebnis.asp?frmAktiensucheTextfeld=\(encoded)"
        guard let url = URL(string: searchURL) else { return nil }
        do {
            var request = URLRequest(url: url)
            request.setValue("Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15", forHTTPHeaderField: "User-Agent")
            request.setValue("de-DE,de;q=0.9", forHTTPHeaderField: "Accept-Language")
            request.timeoutInterval = 10.0
            let (data, _) = try await URLSession.shared.data(for: request)
            guard let html = String(data: data, encoding: .utf8) else { return nil }
            // Suchergebnisse: Link zu /aktien/XXX-aktie oder /kursziele/XXX, Linktext = Bezeichnung (bei reiner WKN oft leer oder nur Ziffern)
            let linkPattern = "<a[^>]+href=\"(/aktien/[^\"]+-aktie|/kursziele/[^\"]+)\"[^>]*>([^<]+)</a>"
            guard let regex = try? NSRegularExpression(pattern: linkPattern, options: .caseInsensitive) else { return nil }
            let range = NSRange(html.startIndex..., in: html)
            let matches = regex.matches(in: html, options: [], range: range)
            var href = ""
            var bezeichnung = ""
            for match in matches {
                guard match.numberOfRanges >= 3,
                      let hrefR = Range(match.range(at: 1), in: html),
                      let textR = Range(match.range(at: 2), in: html) else { continue }
                let h = String(html[hrefR])
                let t = String(html[textR]).trimmingCharacters(in: .whitespaces)
                if isUngueltigeWatchlistBezeichnung(t) { continue }
                // Bevorzuge Linktext, der wie ein Firmenname aussieht (Buchstaben, Länge > 4, nicht nur die WKN)
                let siehtNachNameAus = t.count > 4 && t.contains(where: { $0.isLetter }) && t != term && !t.allSatisfy(\.isNumber)
                if !t.isEmpty && (bezeichnung.isEmpty || siehtNachNameAus) {
                    href = h
                    bezeichnung = t
                    if siehtNachNameAus { break }
                } else if href.isEmpty {
                    href = h
                    if bezeichnung.isEmpty { bezeichnung = t }
                }
            }
            if bezeichnung.isEmpty || isUngueltigeWatchlistBezeichnung(bezeichnung) { bezeichnung = term } else { bezeichnung = bereinigeWatchlistBezeichnung(bezeichnung) }
            var slug = ""
            if href.contains("/aktien/") {
                slug = href.replacingOccurrences(of: "/aktien/", with: "").replacingOccurrences(of: "-aktie", with: "")
            } else if href.contains("/kursziele/") {
                slug = href.replacingOccurrences(of: "/kursziele/", with: "")
            }
            if slug.isEmpty { return WatchlistLookupResult(bezeichnung: bezeichnung, wkn: term, isin: term, kurs: nil, kursziel: nil) }
            let detailURL = "https://www.finanzen.net/kursziele/\(slug)"
            guard let detailUrl = URL(string: detailURL) else { return WatchlistLookupResult(bezeichnung: bezeichnung, wkn: term, isin: term, kurs: nil, kursziel: nil) }
            var req2 = URLRequest(url: detailUrl)
            req2.setValue("Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15", forHTTPHeaderField: "User-Agent")
            req2.timeoutInterval = 10.0
            let (data2, _) = try await URLSession.shared.data(for: req2)
            guard let html2 = String(data: data2, encoding: .utf8) else { return WatchlistLookupResult(bezeichnung: bezeichnung, wkn: term, isin: term, kurs: nil, kursziel: nil) }
            // Bezeichnung aus Detailseite holen, wenn Suchseite nur WKN/leer oder ungültig (z. B. „Snapshot“) geliefert hat
            if bezeichnung.isEmpty || bezeichnung == term || (bezeichnung.count <= 8 && bezeichnung.allSatisfy(\.isNumber)) || isUngueltigeWatchlistBezeichnung(bezeichnung),
               let nameFromPage = parseBezeichnungFromFinanzenNetDetailPage(html2), !nameFromPage.isEmpty, !isUngueltigeWatchlistBezeichnung(nameFromPage) {
                bezeichnung = bereinigeWatchlistBezeichnung(nameFromPage)
                debug("   📌 Watchlist Bezeichnung aus Detailseite: \(bezeichnung)")
            } else if isUngueltigeWatchlistBezeichnung(bezeichnung) {
                bezeichnung = ""
            }
            // Bei WKN-Eingabe (6 Ziffern): ISIN aus Detailseite ermitteln; bei ISIN-Eingabe: WKN aus Detailseite ermitteln
            let termIstWKN = term.count == 6 && term.allSatisfy(\.isNumber)
            let termIstISIN = term.count >= 12 && term.prefix(2).allSatisfy(\.isLetter)
            var isinErmittelt = ""
            var wknErmittelt = ""
            if termIstWKN, let parsedISIN = parseISINFromFinanzenNetHTML(html2), parsedISIN.count >= 12 {
                isinErmittelt = String(parsedISIN.prefix(12))
                debug("   📌 Watchlist ISIN aus Detailseite: \(isinErmittelt)")
            } else if termIstISIN, let parsedWKN = parseWKNFromFinanzenNetHTML(html2), parsedWKN.count == 6 {
                wknErmittelt = parsedWKN
                debug("   📌 Watchlist WKN aus Detailseite: \(wknErmittelt)")
            }
            // Dänische Seite? (DKK/Kopenhagen/Novo) – dann Werte als DKK interpretieren falls nicht erkannt
            let seiteWirktDaenisch = html2.uppercased().contains("DKK") || html2.contains("Kopenhagen") || html2.contains("Copenhagen") || detailURL.lowercased().contains("novo-nordisk")
            // Kursziel: Währung aus HTML nutzen und in EUR umrechnen
            var kurszielEUR: Double?
            if let (kz, _, waehrung, _) = parseKurszielFromHTML(html2, urlString: detailURL) {
                var w = (waehrung ?? "EUR").uppercased()
                if w == "EUR" && seiteWirktDaenisch { w = "DKK" }
                if w == "USD" {
                    kurszielEUR = kz * rateUSDtoEUR()
                    debug("   💱 Watchlist Kursziel: \(kz) USD → \(kurszielEUR.map { String(format: "%.2f", $0) } ?? "?") EUR")
                } else if w == "GBP" {
                    kurszielEUR = kz * rateGBPtoEUR()
                    debug("   💱 Watchlist Kursziel: \(kz) GBP → \(kurszielEUR.map { String(format: "%.2f", $0) } ?? "?") EUR")
                } else if w == "DKK" {
                    kurszielEUR = kz * rateDKKtoEUR()
                    debug("   💱 Watchlist Kursziel: \(kz) DKK → \(kurszielEUR.map { String(format: "%.2f", $0) } ?? "?") EUR")
                } else {
                    kurszielEUR = kz
                }
            }
            // Kurs: mit Währung parsen und in EUR umrechnen
            var kursEUR: Double?
            if let (kursVal, waehrungKurs) = parseAktuellerKursUndWaehrungFromFinanzenNetHTML(html2) {
                var w = (waehrungKurs ?? "EUR").uppercased()
                if w == "EUR" && seiteWirktDaenisch { w = "DKK" }
                if w == "USD" {
                    kursEUR = kursVal * rateUSDtoEUR()
                    debug("   💱 Watchlist Kurs: \(kursVal) USD → \(kursEUR.map { String(format: "%.2f", $0) } ?? "?") EUR")
                } else if w == "GBP" {
                    kursEUR = kursVal * rateGBPtoEUR()
                    debug("   💱 Watchlist Kurs: \(kursVal) GBP → \(kursEUR.map { String(format: "%.2f", $0) } ?? "?") EUR")
                } else {
                    kursEUR = kursVal
                }
            }
            let wknFinal: String
            let isinFinal: String
            if termIstWKN {
                wknFinal = term
                isinFinal = isinErmittelt.isEmpty ? "" : isinErmittelt
            } else {
                wknFinal = wknErmittelt.isEmpty ? "" : wknErmittelt
                isinFinal = term
            }
            let bezBereinigt = bereinigeWatchlistBezeichnung(bezeichnung)
            let bezFinal = isUngueltigeWatchlistBezeichnung(bezBereinigt) ? "" : bezBereinigt
            return WatchlistLookupResult(bezeichnung: bezFinal, wkn: wknFinal, isin: isinFinal, kurs: kursEUR, kursziel: kurszielEUR)
        } catch {
            return nil
        }
    }
    
    /// Bereinigt Bezeichnungen wie „Alle Adidas Kursziele“ → „Adidas“ (finanzen.net-Linktext/Seitentitel).
    private static func bereinigeWatchlistBezeichnung(_ s: String) -> String {
        var t = s.trimmingCharacters(in: .whitespaces)
        if t.isEmpty { return t }
        if t.range(of: "Alle ", options: .caseInsensitive)?.lowerBound == t.startIndex {
            t = String(t.dropFirst(5)).trimmingCharacters(in: .whitespaces)
        }
        if t.hasSuffix(" Kursziele") || t.hasSuffix(" kursziele") {
            t = String(t.dropLast(10)).trimmingCharacters(in: .whitespaces)
        }
        if t.hasSuffix(" - Kursziele") || t.hasSuffix(" - kursziele") {
            t = String(t.dropLast(12)).trimmingCharacters(in: .whitespaces)
        }
        return t
    }
    
    /// Ungültige/generische Bezeichnungen von finanzen.net (z. B. „Snapshot“, „Suche“) – als leer behandeln, damit Fallback „WKN …“ genutzt wird.
    private static func isUngueltigeWatchlistBezeichnung(_ s: String) -> Bool {
        let t = s.trimmingCharacters(in: .whitespaces).lowercased()
        if t.isEmpty { return true }
        let ungueltig = ["snapshot", "suche", "suchergebnis", "suchergebnisse", "finanzen.net", "aktie", "aktien", "kursziele", "übersicht", "search", "results"]
        if ungueltig.contains(t) { return true }
        if t.count <= 2 { return true }
        return false
    }
    
    /// Parst ISIN aus finanzen.net HTML (z. B. in Tabellen oder Meta: DE0007164600). Standard: 2 Buchstaben + 9 alphanumerisch + 1 Ziffer.
    private static func parseISINFromFinanzenNetHTML(_ html: String) -> String? {
        let pattern = "[A-Z]{2}[A-Z0-9]{9}[0-9]"
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: html, range: NSRange(html.startIndex..., in: html)),
              match.numberOfRanges >= 0,
              let r = Range(match.range(at: 0), in: html) else { return nil }
        return String(html[r])
    }
    
    /// Parst WKN (6 Ziffern) aus finanzen.net HTML, z. B. in Tabellen oder nach „WKN“.
    private static func parseWKNFromFinanzenNetHTML(_ html: String) -> String? {
        let patterns = [
            "WKN[^0-9]*([0-9]{6})\\b",
            "\\b([0-9]{6})\\b.*?ISIN",
            ">([0-9]{6})<"
        ]
        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive),
                  let match = regex.firstMatch(in: html, range: NSRange(html.startIndex..., in: html)),
                  match.numberOfRanges >= 1,
                  let r = Range(match.range(at: 1), in: html) else { continue }
            return String(html[r])
        }
        return nil
    }
    
    /// Parst Firmenbezeichnung aus der Titelzeile der finanzen.net Detailseite (z. B. „Kursziele zu Rheinmetall AG“ oder „Rheinmetall AG - Kursziele | Finanzen.net“).
    private static func parseBezeichnungFromFinanzenNetDetailPage(_ html: String) -> String? {
        guard let titleRegex = try? NSRegularExpression(pattern: "<title>([^<]+)</title>", options: .caseInsensitive),
              let match = titleRegex.firstMatch(in: html, range: NSRange(html.startIndex..., in: html)),
              match.numberOfRanges >= 1,
              let r = Range(match.range(at: 1), in: html) else { return nil }
        var title = String(html[r]).trimmingCharacters(in: .whitespaces)
        if title.isEmpty { return nil }
        // "Kursziele zu Rheinmetall AG" oder "Kursziele zu SAP SE | Finanzen.net"
        if title.lowercased().hasPrefix("kursziele zu ") {
            let nachPrefix = title.dropFirst("kursziele zu ".count)
            if let pipe = nachPrefix.range(of: " | ") {
                return String(nachPrefix[..<pipe.lowerBound]).trimmingCharacters(in: .whitespaces)
            }
            return String(nachPrefix).trimmingCharacters(in: .whitespaces)
        }
        // "Rheinmetall AG - Kursziele | Finanzen.net"
        if let dash = title.range(of: " - ") {
            return String(title[..<dash.lowerBound]).trimmingCharacters(in: .whitespaces)
        }
        if let pipe = title.range(of: " | ") {
            return String(title[..<pipe.lowerBound]).trimmingCharacters(in: .whitespaces)
        }
        return title
    }
    
    /// Parst aktuellen Kurs aus finanzen.net HTML (z. B. „31,09 EUR“ in der Kurszeile).
    private static func parseAktuellerKursFromFinanzenNetHTML(_ html: String) -> Double? {
        parseAktuellerKursUndWaehrungFromFinanzenNetHTML(html)?.0
    }
    
    /// Parst aktuellen Kurs inkl. Währung (EUR/USD/GBP/DKK) aus finanzen.net HTML. Rückgabe (Wert, Währung).
    private static func parseAktuellerKursUndWaehrungFromFinanzenNetHTML(_ html: String) -> (Double, String?)? {
        func parseKursZahl(_ raw: String) -> Double? {
            var s = raw.trimmingCharacters(in: .whitespaces)
            // Deutsches Format: 1.234,56 → 1234.56
            if s.contains(".") && s.contains(",") {
                s = s.replacingOccurrences(of: ".", with: "").replacingOccurrences(of: ",", with: ".")
            } else {
                s = s.replacingOccurrences(of: ",", with: ".")
            }
            guard let d = Double(s), d > 0, d < 1_000_000 else { return nil }
            return d
        }
        let patterns: [(String, String)] = [
            (">([0-9]+[.,][0-9]+)\\s*EUR\\s*[+<]", "EUR"),
            ("([0-9]+[.,][0-9]+)\\s*EUR\\s*\\+", "EUR"),
            ("Schlusskurs[^0-9]*([0-9]+[.,][0-9]+)", "EUR"),
            (">([0-9]+[.,][0-9]+)\\s*USD\\s*[+<]", "USD"),
            ("([0-9]+[.,][0-9]+)\\s*USD\\s*\\+", "USD"),
            (">([0-9]+[.,][0-9]+)\\s*GBP\\s*[+<]", "GBP"),
            ("([0-9]+[.,][0-9]+)\\s*GBP\\s*\\+", "GBP"),
            (">([0-9]+[.,][0-9]+)\\s*DKK\\s*[+<\" ]", "DKK"),
            ("([0-9]+[.,][0-9]+)\\s*DKK\\s*\\+", "DKK"),
            (">([0-9]+[.,][0-9]+)\\s*kr\\.?\\s*[+<\" ]", "DKK"),
            ("([0-9]+[.,][0-9]+)\\s*kr\\.?\\s*\\+", "DKK"),
            ("([0-9]+[.,][0-9]+)\\s*kr\\b", "DKK"),
            ("([0-9]{1,3}(?:\\.[0-9]{3})*,[0-9]+)\\s*DKK", "DKK"),
            ("([0-9]{1,3}(?:\\.[0-9]{3})*,[0-9]+)\\s*kr\\.?", "DKK"),
            (">([0-9]+[.,][0-9]+)\\s*\\$\\s*[+<]", "USD"),
            ("([0-9]+[.,][0-9]+)\\s*\\$\\s*\\+", "USD")
        ]
        for (pattern, waehrung) in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive),
                  let match = regex.firstMatch(in: html, range: NSRange(html.startIndex..., in: html)),
                  match.numberOfRanges >= 1,
                  let r = Range(match.range(at: 1), in: html) else { continue }
            let raw = String(html[r])
            guard let d = parseKursZahl(raw) else { continue }
            return (d, waehrung)
        }
        return nil
    }
}
