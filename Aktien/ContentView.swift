//
//  ContentView.swift
//  Aktien
//
//  Created by Axel Behm on 28.01.26.
//

import SwiftUI
import SwiftData
import Observation
import UniformTypeIdentifiers
#if os(macOS)
import AppKit
#endif

/// Hilft bei Bestätigung „OpenAI-Ersatz übernehmen?“ wenn Kursziel unrealistisch
@Observable
final class UnrealistischConfirmHelper {
    static let shared = UnrealistischConfirmHelper()
    var isPresented = false
    var original: KurszielInfo?
    var replacement: KurszielInfo?
    var aktienBezeichnung: String = ""
    /// Dialogtitel inkl. Aktienbezeichnung, beim Öffnen gesetzt
    var dialogTitle: String = ""
    private var continuation: CheckedContinuation<Bool, Never>?
    
    @MainActor
    func confirm(original: KurszielInfo, replacement: KurszielInfo, aktie: Aktie) async -> Bool {
        await withCheckedContinuation { cont in
            let name = aktie.bezeichnung.isEmpty ? "Aktie" : aktie.bezeichnung
            self.original = original
            self.replacement = replacement
            self.aktienBezeichnung = name
            self.dialogTitle = "OpenAI-Ersatz übernehmen? – \(name)"
            self.continuation = cont
            self.isPresented = true
        }
    }
    
    @MainActor
    func choose(_ result: Bool) {
        continuation?.resume(returning: result)
        continuation = nil
        isPresented = false
        original = nil
        replacement = nil
        aktienBezeichnung = ""
        dialogTitle = ""
    }
}

/// Gespeichertes manuelles Kursziel für Wiedereinsetzen nach „Alles löschen“ und erneutem Einlesen (Zuordnung über ISIN/WKN)
private struct SavedManualKursziel: Codable {
    var isin: String
    var wkn: String
    var kursziel: Double
    var kurszielDatum: Date?
    var kurszielAbstand: Double?
    var kurszielQuelle: String?
    var kurszielWaehrung: String?
    var kurszielHigh: Double?
    var kurszielLow: Double?
    var kurszielAnalysten: Int?
}
private let savedManualKurszieleUserDefaultsKey = "SavedManualKursziele"

// MARK: - CSV-Spaltenzuordnung (andere Banken)
private let csvColumnMappingUserDefaultsKey = "CSVColumnMapping"
private let csvFieldSeparatorUserDefaultsKey = "CSVFieldSeparator"  // "auto" | "semicolon" | "comma" | "tab"
private let csvDecimalSeparatorUserDefaultsKey = "CSVDecimalSeparator"  // "german" | "english"

/// Eine Spalte unserer App für die CSV-Zuordnung (Vorgabe links, User gibt rechts den CSV-Header ein)
private struct CSVSpaltenField: Identifiable {
    let id: String
    let label: String
    var optional: Bool { id == "kursziel" || id == "kursziel_quelle" || id == "hinweisEinstandskurs" || id == "branche" || id == "risikoklasse" || id == "depotPortfolioName" }
}

private let csvSpaltenFields: [CSVSpaltenField] = [
    CSVSpaltenField(id: "bankleistungsnummer", label: "Bankleistungsnummer / Depotnummer"),
    CSVSpaltenField(id: "bestand", label: "Bestand (Stück)"),
    CSVSpaltenField(id: "bezeichnung", label: "Bezeichnung"),
    CSVSpaltenField(id: "wkn", label: "WKN"),
    CSVSpaltenField(id: "isin", label: "ISIN"),
    CSVSpaltenField(id: "waehrung", label: "Währung"),
    CSVSpaltenField(id: "hinweisEinstandskurs", label: "Hinweis Einstandskurs"),
    CSVSpaltenField(id: "einstandskurs", label: "Einstandskurs"),
    CSVSpaltenField(id: "deviseneinstandskurs", label: "Deviseneinstandskurs"),
    CSVSpaltenField(id: "kurs", label: "Kurs"),
    CSVSpaltenField(id: "devisenkurs", label: "Devisenkurs"),
    CSVSpaltenField(id: "gewinnVerlustEUR", label: "Gewinn/Verlust EUR"),
    CSVSpaltenField(id: "gewinnVerlustProzent", label: "Gewinn/Verlust %"),
    CSVSpaltenField(id: "marktwertEUR", label: "Marktwert EUR"),
    CSVSpaltenField(id: "stueckzinsenEUR", label: "Stückzinsen EUR"),
    CSVSpaltenField(id: "anteilProzent", label: "Anteil %"),
    CSVSpaltenField(id: "datumLetzteBewegung", label: "Datum letzte Bewegung"),
    CSVSpaltenField(id: "gattung", label: "Gattung"),
    CSVSpaltenField(id: "branche", label: "Branche"),
    CSVSpaltenField(id: "risikoklasse", label: "Risikoklasse"),
    CSVSpaltenField(id: "depotPortfolioName", label: "Depot-/Portfolio-Name"),
    CSVSpaltenField(id: "kursziel", label: "Kursziel (optional)"),
    CSVSpaltenField(id: "kursziel_quelle", label: "Kursziel Quelle (optional)"),
]

private func loadCSVColumnMapping() -> [String: String] {
    guard let data = UserDefaults.standard.data(forKey: csvColumnMappingUserDefaultsKey),
          let decoded = try? JSONDecoder().decode([String: String].self, from: data) else { return [:] }
    return decoded
}

private func saveCSVColumnMapping(_ mapping: [String: String]) {
    guard let data = try? JSONEncoder().encode(mapping) else { return }
    UserDefaults.standard.set(data, forKey: csvColumnMappingUserDefaultsKey)
}

/// Dezimal-TextField, das beim Löschen nicht zittert – speichert erst beim Verlassen des Feldes
private struct StableDecimalField: View {
    let placeholder: String
    @Binding var value: Double?
    var onCommit: (() -> Void)?
    
    @State private var text: String = ""
    @FocusState private var isFocused: Bool
    
    private static var formatter: NumberFormatter {
        let f = NumberFormatter()
        f.numberStyle = .decimal
        f.minimumFractionDigits = 0
        f.maximumFractionDigits = 2
        f.decimalSeparator = Locale.current.decimalSeparator ?? "."
        return f
    }
    
    var body: some View {
        TextField(placeholder, text: $text)
            .keyboardType(.decimalPad)
            .multilineTextAlignment(.trailing)
            .focused($isFocused)
            .onAppear { syncFromModel() }
            .onChange(of: value) { _, _ in
                if !isFocused { syncFromModel() }
            }
            .onChange(of: isFocused) { _, focused in
                if !focused { commitToModel() }
            }
            .onSubmit { commitToModel() }
    }
    
    private func syncFromModel() {
        if let v = value {
            text = Self.formatter.string(from: NSNumber(value: v)) ?? ""
        } else {
            text = ""
        }
    }
    
    private func commitToModel() {
        let cleaned = text
            .replacingOccurrences(of: " ", with: "")
            .trimmingCharacters(in: .whitespaces)
        if cleaned.isEmpty {
            value = nil
            text = ""
        } else if let parsed = parseDecimal(cleaned) {
            value = parsed
            text = Self.formatter.string(from: NSNumber(value: parsed)) ?? cleaned
        }
        onCommit?()
    }
    
    /// Parst Dezimalzahl – berücksichtigt deutsche (1.234,56) und englische (1,234.56) Schreibweise
    private func parseDecimal(_ s: String) -> Double? {
        if let n = Self.formatter.number(from: s)?.doubleValue { return n }
        let normalized: String
        if s.contains(",") && s.contains(".") {
            let lastComma = s.lastIndex(of: ",") ?? s.startIndex
            let lastDot = s.lastIndex(of: ".") ?? s.startIndex
            if lastComma > lastDot {
                normalized = s.replacingOccurrences(of: ".", with: "").replacingOccurrences(of: ",", with: ".")
            } else {
                normalized = s.replacingOccurrences(of: ",", with: "")
            }
        } else if s.contains(",") {
            normalized = s.replacingOccurrences(of: ",", with: ".")
        } else {
            normalized = s
        }
        return Double(normalized)
    }
}

private extension Double {
    /// Für Umrechnung: 0 vermeiden (Division), sonst self
    var nonzeroOrOne: Double { self == 0 ? 1 : self }
}

/// Status-Anzeige für Aktien in der Liste
enum AktieStatus {
    case gruen   // Kurs ≥ Kursziel oder mind. 2 % am Kursziel
    case gelb    // Kurs unter Einstandskurs
    case rot     // Kein Kursziel ermittelt
    case grau    // Kursziel vorhanden, Ziel noch nicht erreicht
    case blau    // Kursziel manuell geändert
    
    var color: Color {
        switch self {
        case .gruen: return .green
        case .gelb: return .yellow
        case .rot: return .red
        case .grau: return .gray
        case .blau: return .blue
        }
    }
}

extension Aktie {
    /// true, wenn Gattung oder Bezeichnung Fonds, Fund oder ETF enthält – diese Positionen sind ggf. manuell mit Kurszielen zu versehen.
    var istFonds: Bool {
        func contains(_ s: String) -> Bool {
            let t = s.trimmingCharacters(in: .whitespaces)
            return t.localizedCaseInsensitiveContains("Fonds") || t.localizedCaseInsensitiveContains("Fund") || t.localizedCaseInsensitiveContains("ETF")
        }
        return contains(gattung) || contains(bezeichnung)
    }
    
    /// Prüft ob Kursziel plausibel ist (z.B. nicht 19,77€ bei Amazon ~197€). Abwärts: mind. 50 % des Kurses.
    var isKurszielPlausibel: Bool {
        guard let kz = kursziel, kz >= 1 else { return false }
        let k = self.kurs ?? self.devisenkurs
        guard let kurs = k, kurs > 0 else { return true }
        return kz >= kurs * 0.5 && kz <= kurs * 50
    }
    
    /// Anzeige „Unrealistisch“: nur wenn ein Kursziel existiert und es unplausibel ist oder der Abstand zu groß (Aufwärtspotenzial: 200 %, Abwärts: 50 %). Ohne Kursziel → nicht als unrealistisch.
    var zeigeAlsUnrealistisch: Bool {
        guard kursziel != nil else { return false }
        if !isKurszielPlausibel { return true }
        guard let kz = kursziel, let k = kurs ?? devisenkurs, k > 0 else { return false }
        let pct = abs((kz - k) / k * 100)
        let schwellwert = kz > k ? 200.0 : 50.0
        return pct > schwellwert
    }
    
    /// Ermittelt den Status für die Listenanzeige
    var status: AktieStatus {
        let kurs = self.kurs ?? self.devisenkurs
        if let ek = einstandskurs, let k = kurs, k < ek {
            return .gelb
        }
        if kurszielManuellGeaendert {
            return .blau
        }
        if kursziel == nil || !isKurszielPlausibel {
            return .rot
        }
        if let kz = kursziel, let k = kurs, k > 0 {
            if k >= kz { return .gruen }
            let abstandProzent = ((kz - k) / kz) * 100
            if abstandProzent <= 2 { return .gruen }
        }
        return .grau
    }
}

/// App-weite Anzeige der beim Start geladenen Devisenkurse (USD/EUR, GBP/EUR)
@Observable
final class AppWechselkurse {
    static let shared = AppWechselkurse()
    var usdToEur: Double?
    var gbpToEur: Double?
    var isLoading = true
    func set(usd: Double?, gbp: Double?) {
        usdToEur = usd
        gbpToEur = gbp
        isLoading = false
    }
}

/// Zeile im Kopf: Devisenkurse USD/EUR und GBP/EUR
private struct DevisenkursKopfView: View {
    var usdToEur: Double?
    var gbpToEur: Double?
    var isLoading: Bool
    var body: some View {
        HStack(spacing: 16) {
            if isLoading {
                Text("Devisen: Wird geladen…")
                    .font(.caption)
                    .foregroundColor(.secondary)
            } else {
                Text("USD/EUR: \(usdToEur.map { String(format: "%.4f", $0) } ?? "–")")
                    .font(.caption)
                    .foregroundColor(.secondary)
                Text("GBP/EUR: \(gbpToEur.map { String(format: "%.4f", $0) } ?? "–")")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 8)
        .background(Color(.systemGroupedBackground))
    }
}

/// Einfacher Balken-Chart: Gesamtwert pro Einlesedatum (nutzt nur vorhandene ImportSummary-Daten)
private struct EinlesungenChartView: View {
    var summaries: [ImportSummary]
    var body: some View {
        let values = summaries.map(\.gesamtwertAktuelleEinlesung)
        let minVal = values.min() ?? 0
        let maxVal = values.max() ?? 1
        let range = maxVal - minVal
        VStack(alignment: .leading, spacing: 4) {
            Text("Gesamtwert pro Einlesung")
                .font(.caption2)
                .foregroundColor(.secondary)
            GeometryReader { geo in
                let barAreaHeight = max(20, geo.size.height - 38)
                HStack(alignment: .bottom, spacing: 6) {
                    ForEach(Array(summaries.enumerated()), id: \.element.importDatum) { _, s in
                        let val = s.gesamtwertAktuelleEinlesung
                        let fraction = range > 0 ? (val - minVal) / range : 1.0
                        VStack(spacing: 2) {
                            Text("\(val, specifier: "%.0f") €")
                                .font(.system(size: 9))
                                .foregroundColor(.secondary)
                                .lineLimit(1)
                            RoundedRectangle(cornerRadius: 4)
                                .fill(Color.accentColor.opacity(0.8))
                                .frame(height: max(4, fraction * barAreaHeight))
                            Text(s.datumAktuelleEinlesung.formatted(.dateTime.day().month(.abbreviated)))
                                .font(.system(size: 9))
                                .foregroundColor(.secondary)
                                .lineLimit(1)
                        }
                        .frame(maxWidth: .infinity)
                    }
                }
            }
        }
        .padding(8)
        .background(Color(.systemGroupedBackground))
        .cornerRadius(8)
    }
}

/// Mini-Chart pro Position: Kurs (blau) und Kursziel (grün) über die Einlesungen – pro Datum zwei Balken nebeneinander, alle Balken auf einer Grundlinie; einheitliche Höhe unter den Balken.
/// currentKursziel: Wenn ein Snapshot kein Kursziel hat, wird dieses angezeigt (grüner Balken für jedes Datum).
/// Mit zwei Fingern (Pinch) vergrößern/verkleinern; scaleBinding gibt die aktuelle Skalierung an (z. B. für Section-Höhe).
private struct PositionVerlaufChartView: View {
    var snapshots: [ImportPositionSnapshot]
    var currentKursziel: Double? = nil
    @Binding var zoomScale: CGFloat
    @State private var zoomScaleAnchor: CGFloat = 1.0
    @State private var accumulatedPan: CGSize = .zero
    @State private var currentDrag: CGSize = .zero
    private let minScale: CGFloat = 0.7
    private let maxScale: CGFloat = 2.5
    var body: some View {
        let sorted = snapshots.sorted(by: { $0.importDatum < $1.importDatum })
        let allVals = sorted.compactMap { s -> [Double] in
            var a: [Double] = []
            if let k = s.kurs { a.append(k) }
            let kz = s.kursziel ?? currentKursziel
            if let kz = kz { a.append(kz) }
            return a
        }.flatMap { $0 }
        let minVal = allVals.min() ?? 0
        let maxVal = allVals.max() ?? 1
        let range = max(maxVal - minVal, 0.01)
        let barH: CGFloat = 44
        let unterBalkenH: CGFloat = 32
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Circle().fill(Color.blue).frame(width: 6, height: 6)
                Text("Kurs").font(.caption2).foregroundColor(.secondary)
                Circle().fill(Color.green).frame(width: 6, height: 6)
                Text("Kursziel").font(.caption2).foregroundColor(.secondary)
            }
            GeometryReader { geo in
                let totalW = geo.size.width
                let colCount = CGFloat(max(1, sorted.count))
                let colW = max(10, totalW / colCount - 2)
                VStack(spacing: 0) {
                    // Balken zuerst: gleiche Höhe pro Spalte → alle Balken unten auf einer Linie
                    HStack(alignment: .bottom, spacing: 2) {
                        ForEach(Array(sorted.enumerated()), id: \.offset) { _, s in
                            VStack(spacing: 0) {
                                Spacer(minLength: 0)
                                let kzEffective = s.kursziel ?? currentKursziel
                                HStack(alignment: .bottom, spacing: 2) {
                                    if let kurs = s.kurs, range > 0 {
                                        RoundedRectangle(cornerRadius: 2)
                                            .fill(Color.blue.opacity(0.9))
                                            .frame(width: max(4, (colW - 4) / 2), height: max(3, (kurs - minVal) / range * barH))
                                    }
                                    if let kz = kzEffective, range > 0 {
                                        RoundedRectangle(cornerRadius: 2)
                                            .fill(Color.green.opacity(0.9))
                                            .frame(width: max(4, (colW - 4) / 2), height: max(3, (kz - minVal) / range * barH))
                                    }
                                }
                                .frame(maxWidth: .infinity)
                                .frame(height: barH)
                            }
                            .frame(width: colW)
                        }
                    }
                    .frame(height: barH)
                    // Einheitliche Höhe unter den Balken: Werte + Datum
                    VStack(spacing: 4) {
                        HStack(alignment: .top, spacing: 2) {
                            ForEach(Array(sorted.enumerated()), id: \.offset) { _, s in
                                let kzEffective = s.kursziel ?? currentKursziel
                                VStack(spacing: 1) {
                                    HStack(spacing: 1) {
                                        if let kurs = s.kurs {
                                            Text(String(format: "%.2f", kurs))
                                                .font(.system(size: 6))
                                                .foregroundColor(.blue)
                                                .lineLimit(1)
                                                .minimumScaleFactor(0.6)
                                        }
                                        if s.kurs != nil && (s.kursziel != nil || kzEffective != nil) { Spacer(minLength: 0) }
                                        if let kz = kzEffective {
                                            Text(String(format: "%.2f", kz))
                                                .font(.system(size: 6))
                                                .foregroundColor(.green)
                                                .lineLimit(1)
                                                .minimumScaleFactor(0.6)
                                        }
                                    }
                                    .frame(maxWidth: .infinity)
                                    Text(s.importDatum.formatted(.dateTime.day().month(.abbreviated)))
                                        .font(.system(size: 8))
                                        .foregroundColor(.secondary)
                                }
                                .frame(width: colW)
                            }
                        }
                        Spacer(minLength: 0)
                    }
                    .frame(height: unterBalkenH)
                }
            }
            .frame(height: barH + unterBalkenH)
        }
        .padding(6)
        .scaleEffect(zoomScale, anchor: .center)
        .offset(x: accumulatedPan.width + currentDrag.width, y: accumulatedPan.height + currentDrag.height)
        .contentShape(Rectangle())
        .gesture(
            MagnificationGesture()
                .onChanged { value in
                    let s = min(maxScale, max(minScale, zoomScaleAnchor * value))
                    zoomScale = s
                }
                .onEnded { value in
                    zoomScaleAnchor = zoomScale
                }
        )
        .simultaneousGesture(
            DragGesture()
                .onChanged { value in
                    currentDrag = value.translation
                }
                .onEnded { value in
                    accumulatedPan.width += value.translation.width
                    accumulatedPan.height += value.translation.height
                    currentDrag = .zero
                }
        )
        .onChange(of: zoomScale) { _, newScale in
            if newScale <= 1.0 {
                accumulatedPan = .zero
                currentDrag = .zero
            }
        }
    }
}

struct ContentView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: [SortDescriptor<Aktie>(\.bankleistungsnummer), SortDescriptor<Aktie>(\.bezeichnung)]) private var aktien: [Aktie]
    @Query(sort: \ImportSummary.importDatum, order: .reverse) private var importSummaries: [ImportSummary]
    
    @State private var appWechselkurse = AppWechselkurse.shared
    @State private var isImporting = false
    @State private var importMessage = ""
    @State private var showImportMessage = false
    @State private var showDeleteConfirmation = false
    @State private var einlesungToDelete: ImportSummary? = nil
    @State private var showDeleteEinlesungConfirmation = false
    @State private var isImportingKursziele = false
    @State private var aktuelleKurszielAktie: (bezeichnung: String, wkn: String)? = nil
    @State private var showWKNTester = false
    @State private var showDebugLog = false
    @State private var testWKN = ""
    @State private var testKurszielResult: String? = nil
    @State private var isTestingWKN = false
    @State private var showSettings = false
    @State private var showRechtliches = false
    @State private var showWatchlist = false
    @AppStorage(KurszielService.openAIAPIKeyKey) private var openAIAPIKeyStore: String = ""
    @AppStorage(KurszielService.fmpAPIKeyKey) private var fmpAPIKeyStore: String = ""
    @AppStorage("ForceOverwriteAllKursziele") private var forceOverwriteAllKursziele = false
    @State private var isImportingKurszieleOpenAI = false
    /// Nach CSV-Import: Kurszielermittlung erst starten, wenn der Nutzer den Import-Alert mit OK geschlossen hat (verhindert blockierten OK-Button).
    @State private var pendingKurszielFetchAfterImport = false
    @State private var pendingKurszielForceOverwrite = false
    /// Einlese-Datum der letzten Import-Aktion; nach Kursziel-Fetch Snapshots mit diesem Datum aktualisieren (Kursziel nachtragen).
    @State private var pendingKurszielImportDatum: Date? = nil
    /// Daten liegen vor dem Tagesdatum → nach OK Abfrage anzeigen, ob Kursziele ermittelt werden sollen (zeitaufwendig).
    @State private var showKurszielAbfrageBeiAltemDatum = false
    @State private var showKurszielAbfrageAlert = false
    @State private var unrealistischConfirm = UnrealistischConfirmHelper.shared
    
    /// Filter nach Kursziel-Quelle: Aus = alle, sonst nur die gewählte Quelle
    enum KurszielQuelleFilter: String, CaseIterable {
        case aus = "Aus"
        case openAI = "OpenAI (A)"
        case fmp = "FMP (M)"
        case csv = "CSV (C)"
        case andere = "Andere (Y/F)"
    }
    @State private var kurszielQuelleFilter: KurszielQuelleFilter = .aus
    @State private var filterNurUnrealistischeKursziele = false
    @State private var selectedTab = 0
    @State private var scrollToISIN: String? = nil
    @State private var scrollToISINOnKurszieleTab: String? = nil
    /// Beim Wechsel von Kursziele → Aktien: Aktien-Liste zu dieser ISIN scrollen (letzte bearbeitete Zeile)
    @State private var scrollToISINWhenReturningFromKursziele: String? = nil
    @State private var currentDetailISIN: String? = nil
    @State private var visibleISINsOnAktienList: Set<String> = []
    /// true = Liste nach grösster Differenz Kurs ↔ Kursziel sortieren, mit % zum Ziel
    @State private var sortiereNachAbstandKursziel = false
    /// true = Chart über den 5 Einlesungen (Gesamtwert pro Datum) anzeigen
    @State private var showEinlesungenChart = false
    /// Pfad für Aktien-Detail (nur unser Chevron, kein System-Chevron)
    @State private var aktienDetailPath: [String] = []
    /// Beim Start kurz Splash anzeigen statt weißen Bildschirm
    @State private var showSplash = true
    
    /// Gefilterte Aktien nach gewählter Kursziel-Quelle, optional nur unrealistische
    private var aktienZurAnzeige: [Aktie] {
        let byQuelle: [Aktie]
        switch kurszielQuelleFilter {
        case .aus: byQuelle = aktien
        case .openAI: byQuelle = aktien.filter { $0.kurszielQuelle == KurszielQuelle.openAI.rawValue }
        case .fmp: byQuelle = aktien.filter { $0.kurszielQuelle == KurszielQuelle.fmp.rawValue }
        case .csv: byQuelle = aktien.filter { $0.kurszielQuelle == KurszielQuelle.csv.rawValue }
        case .andere: byQuelle = aktien.filter { let q = $0.kurszielQuelle; return q == KurszielQuelle.yahoo.rawValue || q == KurszielQuelle.finanzenNet.rawValue || q == KurszielQuelle.suchmaschine.rawValue }
        }
        if filterNurUnrealistischeKursziele {
            return byQuelle.filter { $0.kursziel != nil && $0.zeigeAlsUnrealistisch }
        }
        return byQuelle
    }
    
    /// Sortiert nach Abstand (%) zum Kursziel: positive % (Aufwärtspotenzial) oben, grösste zuerst; negative % (Abwärtspotenzial) unten; ohne Kursziel ans Ende
    private var aktienSortiertNachAbstandKursziel: [Aktie] {
        aktienZurAnzeige.sorted { a, b in
            let kursA = a.kurs ?? a.devisenkurs ?? 0
            let kursB = b.kurs ?? b.devisenkurs ?? 0
            let pctA: Double? = (a.kursziel != nil && kursA > 0) ? (a.kursziel! - kursA) / kursA * 100 : nil
            let pctB: Double? = (b.kursziel != nil && kursB > 0) ? (b.kursziel! - kursB) / kursB * 100 : nil
            // Ohne Kursziel ans Ende
            guard let pa = pctA else { return false }
            guard let pb = pctB else { return true }
            // Positive % (Aufwärtspotenzial) vor negative % (Abwärtspotenzial)
            if pa >= 0 && pb < 0 { return true }
            if pa < 0 && pb >= 0 { return false }
            if pa >= 0 && pb >= 0 { return pa > pb }
            return pa > pb  // beide negativ: weniger negativ zuerst (z. B. -5 % vor -20 %)
        }
    }
    
    /// Gruppiert nach Bankleistungsnummer für Zwischensummen
    private var gruppierteAktien: [(bl: String, aktien: [Aktie])] {
        var groups: [(bl: String, aktien: [Aktie])] = []
        var currentBL = ""
        var currentGroup: [Aktie] = []
        for aktie in aktienZurAnzeige {
            let bl = aktie.bankleistungsnummer.isEmpty ? "—" : aktie.bankleistungsnummer
            if bl != currentBL {
                if !currentGroup.isEmpty {
                    groups.append((currentBL, currentGroup))
                }
                currentBL = bl
                currentGroup = [aktie]
            } else {
                currentGroup.append(aktie)
            }
        }
        if !currentGroup.isEmpty {
            groups.append((currentBL, currentGroup))
        }
        return groups
    }
    
    private var gesamtMarktwert: Double {
        aktienZurAnzeige.compactMap { $0.marktwertEUR }.reduce(0, +)
    }
    
    @ViewBuilder
    private func aktienZeileLabel(aktie: Aktie, zeigeProzentZumZiel: Bool) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Circle()
                .fill(aktie.status.color)
                .frame(width: 12, height: 12)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(aktie.bezeichnung)
                        .font(.headline)
                    if aktie.istFonds {
                        Image(systemName: "building.2.fill")
                            .font(.caption2)
                            .foregroundColor(.purple)
                    }
                }
                // Zeile 1: Bestand + Anzahl, Marktwert + Wert (gekürzte Labels)
                HStack(spacing: 12) {
                    Text("Stück \(aktie.bestand, specifier: "%.0f")")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    if let mw = aktie.marktwertEUR {
                        Text("Marktw. \(mw, specifier: "%.2f") €")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
                // Zeile 2: Kurs alt, Kurs neu (nur wenn mindestens einer vorhanden)
                if aktie.previousKurs != nil || (aktie.kurs ?? aktie.devisenkurs) != nil {
                    HStack(spacing: 12) {
                        if let alt = aktie.previousKurs {
                            Text("Kurs alt \(alt, specifier: "%.2f")")
                                .font(.caption2)
                                .foregroundColor(.secondary)
                        }
                        if let neu = aktie.kurs ?? aktie.devisenkurs {
                            Text("Kurs neu \(neu, specifier: "%.2f")")
                                .font(.caption2)
                                .foregroundColor(.secondary)
                        }
                    }
                }
                // Zeile 3: Veränderung in % (auf Marktwert zur Voreinlesung)
                if let prev = aktie.previousMarktwertEUR, let curr = aktie.marktwertEUR, prev > 0 {
                    let pct = ((curr - prev) / prev) * 100
                    HStack(spacing: 4) {
                        Text("Veränd.")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                        Text("\(pct >= 0 ? "+" : "")\(pct, specifier: "%.2f")%")
                            .font(.caption2)
                            .fontWeight(.medium)
                            .foregroundColor(pct >= 0 ? .green : .red)
                    }
                }
                // Zeile 4: Kursziel, Abstand zum Kursziel + Mini-Balken Kurs → Kursziel (immer anzeigen wenn vorhanden)
                if let kurs = aktie.kurs ?? aktie.devisenkurs, let kz = aktie.kursziel, kurs > 0 {
                    let abstandPct = (kz - kurs) / kurs * 100
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: 12) {
                            Text("Kursziel \(kz, specifier: "%.2f")")
                                .font(.caption2)
                                .foregroundColor(.secondary)
                            Text("Abstand \(abstandPct >= 0 ? "+" : "")\(abstandPct, specifier: "%.1f")%")
                                .font(.caption2)
                                .fontWeight(.medium)
                                .foregroundColor(abstandPct >= 0 ? .green : .red)
                        }
                        // Mini-Balken: Länge = Abstand % skaliert auf Referenzbereich (wie Gesamtsummen-Chart mit Faktor), damit nicht alle Balken gleich lang wirken
                        GeometryReader { geo in
                            let refMin: Double = -40   // Abstand -40 % = Balken kurz
                            let refMax: Double = 80   // Abstand +80 % = Balken voll
                            let refSpan = refMax - refMin
                            let fraction = min(1.0, max(0, (abstandPct - refMin) / refSpan))
                            let fillWidth = max(4, fraction * geo.size.width)
                            ZStack(alignment: .leading) {
                                RoundedRectangle(cornerRadius: 2)
                                    .fill(Color.secondary.opacity(0.2))
                                    .frame(height: 6)
                                RoundedRectangle(cornerRadius: 2)
                                    .fill(abstandPct >= 0 ? Color.green : Color.red)
                                    .frame(width: fillWidth, height: 6)
                            }
                        }
                        .frame(height: 6)
                    }
                }
            }
        }
    }

    /// Tab-Wechsel: Kursziele-Tab nur, wenn bereits eine Aktie für Grunddaten angewählt wurde
    private var selectedTabBinding: Binding<Int> {
        Binding(
            get: { selectedTab },
            set: { new in
                if new == 1, currentDetailISIN == nil {
                    return
                }
                selectedTab = new
            }
        )
    }

    @ViewBuilder
    private var aktienTabContent: some View {
        NavigationSplitView {
            NavigationStack(path: $aktienDetailPath) {
                VStack(spacing: 0) {
                    DevisenkursKopfView(usdToEur: appWechselkurse.usdToEur, gbpToEur: appWechselkurse.gbpToEur, isLoading: appWechselkurse.isLoading)
                    ScrollViewReader { proxy in
                        aktienListContent(proxy: proxy)
                            .onChange(of: selectedTab) { _, new in
                                if new == 0 {
                                    let isin = scrollToISINWhenReturningFromKursziele ?? scrollToISIN
                                    scrollToISINWhenReturningFromKursziele = nil
                                    if let isin = isin {
                                        DispatchQueue.main.async {
                                            proxy.scrollTo(isin, anchor: .center)
                                            scrollToISIN = nil
                                        }
                                    }
                                }
                            }
                    }
                }
                .navigationDestination(for: String.self) { isin in
                    if let aktie = aktien.first(where: { $0.isin == isin }) {
                        AktieDetailView(aktie: aktie, onAppearISIN: { currentDetailISIN = $0 })
                    }
                }
            }
            #if os(macOS)
            .navigationSplitViewColumnWidth(min: 300, ideal: 350)
            #endif
            .navigationTitle("Aktien")
            .toolbar { aktienToolbarContent }
            .confirmationDialog("Alles löschen?", isPresented: $showDeleteConfirmation) {
                Button("Löschen und Kursziele merken", role: .destructive) { saveManualKurszieleAndDeleteAll() }
                Button("Löschen (Kursziele nicht merken)", role: .destructive) {
                    UserDefaults.standard.removeObject(forKey: savedManualKurszieleUserDefaultsKey)
                    deleteAllAktien()
                }
                Button("Abbrechen", role: .cancel) { }
            } message: {
                let n = aktien.filter { $0.kurszielManuellGeaendert }.count
                if n > 0 {
                    Text("Alle \(aktien.count) Aktien werden unwiderruflich gelöscht. \(n) manuelle Kursziele können gemerkt und nach dem nächsten Einlesen (über ISIN/WKN) wieder zugeordnet werden.")
                } else {
                    Text("Alle \(aktien.count) Aktien werden unwiderruflich gelöscht.")
                }
            }
            .confirmationDialog("Einlesung löschen?", isPresented: $showDeleteEinlesungConfirmation, presenting: einlesungToDelete) { summary in
                Button("Löschen", role: .destructive) {
                    deleteEinlesung(summary)
                    einlesungToDelete = nil
                }
                Button("Abbrechen", role: .cancel) { einlesungToDelete = nil }
            } message: { summary in
                Text("Einlesung vom \(summary.datumAktuelleEinlesung.formatted(date: .abbreviated, time: .shortened)) löschen? Alle Aktien und Summen für diesen Tag werden aus den Tabellen entfernt.")
            }
            .fileImporter(isPresented: $isImporting, allowedContentTypes: [.commaSeparatedText, .text], allowsMultipleSelection: true) { result in
                handleFileImport(result: result)
            }
            .alert("Import", isPresented: $showImportMessage) {
                Button("OK", role: .cancel) {
                    showImportMessage = false
                    if pendingKurszielFetchAfterImport {
                        pendingKurszielFetchAfterImport = false
                        startPendingKurszielFetch()
                    } else if showKurszielAbfrageBeiAltemDatum {
                        showKurszielAbfrageBeiAltemDatum = false
                        showKurszielAbfrageAlert = true
                    }
                }
            } message: { Text(importMessage) }
            .alert("Kursziele ermitteln?", isPresented: $showKurszielAbfrageAlert) {
                Button("Ja") { showKurszielAbfrageAlert = false; startPendingKurszielFetch() }
                Button("Nein", role: .cancel) { showKurszielAbfrageAlert = false }
            } message: {
                Text("Die eingelesenen Daten liegen vor dem Tagesdatum. Sollen die Kursziele trotzdem ermittelt werden? (Kann zeitaufwendig sein.)")
            }
            .sheet(isPresented: $showSettings) {
                SettingsView(openAIAPIKey: $openAIAPIKeyStore, fmpAPIKey: $fmpAPIKeyStore)
            }
            .sheet(isPresented: $showWKNTester) {
                WKNTesterView(wkn: $testWKN, result: $testKurszielResult, isTesting: $isTestingWKN, urlFromSettings: fmpAPIKeyStore, openAIFromSettings: openAIAPIKeyStore)
                    .onAppear {
                        if testWKN.isEmpty, !fmpAPIKeyStore.trimmingCharacters(in: .whitespaces).isEmpty {
                            testWKN = fmpAPIKeyStore.trimmingCharacters(in: .whitespaces)
                        } else if testWKN.isEmpty {
                            testWKN = "https://www.finanzen.net/kursziele/rheinmetall"
                        }
                    }
            }
            .sheet(isPresented: $showDebugLog) { DebugLogSheet() }
            .sheet(isPresented: $showRechtliches) { RechtlichesSheetView() }
            .sheet(isPresented: $showWatchlist) { WatchlistView() }
        } detail: {
            Text("Aktie auswählen")
        }
    }

    @ToolbarContentBuilder
    private var aktienToolbarContent: some ToolbarContent {
        #if os(iOS)
        ToolbarItem(placement: .navigationBarTrailing) {
            Button("Rechtliches") { showRechtliches = true }
        }
        #endif
        ToolbarItem {
            Button(action: { sortiereNachAbstandKursziel.toggle() }) {
                Label(sortiereNachAbstandKursziel ? "Sortierung: Standard" : "Nach Abstand zum Kursziel", systemImage: sortiereNachAbstandKursziel ? "list.bullet" : "chart.line.uptrend.xyaxis")
            }
        }
        ToolbarItem {
            Button(action: { showWatchlist = true }) { Label("Watchlist", systemImage: "eye") }
        }
        ToolbarItem {
            Button(action: importCSVFiles) { Label("CSV importieren", systemImage: "doc.badge.plus") }
        }
        ToolbarItem {
            Button(role: .destructive, action: { showDeleteConfirmation = true }) {
                Label("Alles löschen", systemImage: "trash")
            }
            .disabled(aktien.isEmpty)
        }
        ToolbarItem {
            Button(action: { showSettings = true }) { Label("Einstellungen", systemImage: "gear") }
        }
        ToolbarItem {
            Button(action: {
                #if os(iOS)
                if let clipboard = UIPasteboard.general.string?.trimmingCharacters(in: .whitespaces), !clipboard.isEmpty {
                    let kandidaten = KurszielService.slugKandidaten(from: clipboard)
                    let slug = kandidaten.last ?? KurszielService.slugFromBezeichnung(clipboard)
                    if !slug.isEmpty { testWKN = "https://www.finanzen.net/kursziele/\(slug)" }
                }
                #elseif os(macOS)
                if let clipboard = NSPasteboard.general.string(forType: .string)?.trimmingCharacters(in: .whitespaces), !clipboard.isEmpty {
                    let kandidaten = KurszielService.slugKandidaten(from: clipboard)
                    let slug = kandidaten.last ?? KurszielService.slugFromBezeichnung(clipboard)
                    if !slug.isEmpty { testWKN = "https://www.finanzen.net/kursziele/\(slug)" }
                }
                #endif
                if testWKN.isEmpty { testWKN = "https://www.finanzen.net/kursziele/rheinmetall" }
                showWKNTester = true
            }) { Label("WKN testen", systemImage: "magnifyingglass") }
        }
        ToolbarItem {
            Button(action: { showDebugLog = true }) { Label("Debug-Log", systemImage: "ladybug") }
        }
    }

    @ViewBuilder
    private func aktienListContent(proxy: ScrollViewProxy) -> some View {
        List {
                // Gesamtsummen der letzten 10 Einlesungen – sortiert nach Datum der Einlesedatei (ältestes zuerst)
                let letzteZehn = Array(importSummaries.prefix(10)).sorted(by: { $0.datumAktuelleEinlesung < $1.datumAktuelleEinlesung })
                Section {
                    if letzteZehn.isEmpty {
                        Text("Keine Einlesungen vorhanden. Nach einem CSV-Import erscheinen hier die Gesamtsummen (bis zu 10).")
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                            .padding(.vertical, 8)
                    } else {
                        if showEinlesungenChart {
                            EinlesungenChartView(summaries: letzteZehn)
                                .frame(height: 160)
                                .listRowBackground(Color.clear)
                                .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))
                        }
                        let ausgangsbasis = letzteZehn.first
                        ForEach(Array(letzteZehn.enumerated()), id: \.element.importDatum) { _, summary in
                            HStack(alignment: .top, spacing: 8) {
                                VStack(alignment: .leading, spacing: 6) {
                                    HStack {
                                        Text(summary.datumAktuelleEinlesung.formatted(date: .abbreviated, time: .shortened))
                                            .font(.caption)
                                            .fontWeight(.medium)
                                        Spacer()
                                    }
                                    HStack {
                                        Text("Gesamtwert:")
                                            .font(.caption)
                                            .foregroundColor(.secondary)
                                        Spacer()
                                        Text("\(summary.gesamtwertAktuelleEinlesung, specifier: "%.2f") €")
                                            .font(.caption)
                                            .fontWeight(.medium)
                                    }
                                    if let basis = ausgangsbasis, basis.importDatum != summary.importDatum, basis.gesamtwertAktuelleEinlesung > 0 {
                                        let differenz = summary.gesamtwertAktuelleEinlesung - basis.gesamtwertAktuelleEinlesung
                                        HStack {
                                            Text("Veränderung zur Ausgangsbasis (\(basis.datumAktuelleEinlesung.formatted(date: .abbreviated, time: .shortened))):")
                                                .font(.caption)
                                                .foregroundColor(.secondary)
                                            Spacer()
                                            Text("\(differenz >= 0 ? "+" : "")\(differenz, specifier: "%.2f") €")
                                                .font(.caption)
                                                .foregroundColor(differenz >= 0 ? .green : .red)
                                        }
                                    } else if summary.gesamtwertVoreinlesung > 0, ausgangsbasis?.importDatum == summary.importDatum {
                                        HStack {
                                            Text("Voreinlesung:")
                                                .font(.caption)
                                                .foregroundColor(.secondary)
                                            Spacer()
                                            Text("\(summary.gesamtwertVoreinlesung, specifier: "%.2f") €")
                                                .font(.caption)
                                        }
                                        let differenz = summary.gesamtwertAktuelleEinlesung - summary.gesamtwertVoreinlesung
                                        HStack {
                                            Text("Veränderung:")
                                                .font(.caption)
                                                .foregroundColor(.secondary)
                                            Spacer()
                                            Text("\(differenz >= 0 ? "+" : "")\(differenz, specifier: "%.2f") €")
                                                .font(.caption)
                                                .foregroundColor(differenz >= 0 ? .green : .red)
                                        }
                                    }
                                }
                                .padding(.vertical, 4)
                                Button(role: .destructive) {
                                    einlesungToDelete = summary
                                    showDeleteEinlesungConfirmation = true
                                } label: {
                                    Image(systemName: "trash")
                                        .font(.body)
                                }
                                .buttonStyle(.borderless)
                            }
                        }
                    }
                } header: {
                    HStack {
                        Text("Gesamtsummen (letzte 10 Einlesungen)")
                        Spacer()
                        if !letzteZehn.isEmpty {
                            Button(showEinlesungenChart ? "Chart aus" : "Chart") {
                                showEinlesungenChart.toggle()
                            }
                            .font(.caption)
                        }
                    }
                } footer: {
                    VStack(alignment: .leading, spacing: 4) {
                        if letzteZehn.isEmpty {
                            Text("Nach einem CSV-Import erscheinen hier die Gesamtsummen pro Einlesung.")
                        } else {
                            Text("Sortierung nach Datum der Einlesedatei (ältestes zuerst). Ausgangsbasis = ältestes Datum (bis zu 10 Einlesungen).")
                        }
                        Text("Bitte alle .csv-Dateien des Tages auf einmal anklicken (wegen der Gesamtsummen-Darstellung).")
                            .fontWeight(.medium)
                    }
                    .font(.caption2)
                }
                
                // Legende oben – Fonds/Fund/ETF-Positionen ggf. manuell mit Kurszielen versehen
                Section {
                    VStack(alignment: .leading, spacing: 6) {
                        HStack(spacing: 8) {
                            Image(systemName: "building.2.fill")
                                .font(.caption)
                                .foregroundColor(.purple)
                            Text("Fonds / Fund / ETF – Kursziel ggf. manuell setzen")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                        HStack(spacing: 8) {
                            Circle().fill(Color.green).frame(width: 10, height: 10)
                            Text("Kursziel erreicht oder mind. 2 % am Ziel")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                        HStack(spacing: 8) {
                            Circle().fill(Color.yellow).frame(width: 10, height: 10)
                            Text("Aktueller Kurs unter Einstandskurs")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                        HStack(spacing: 8) {
                            Circle().fill(Color.red).frame(width: 10, height: 10)
                            Text("Kein Kursziel ermittelt")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                        HStack(spacing: 8) {
                            Circle().fill(Color.blue).frame(width: 10, height: 10)
                            Text("Kursziel manuell geändert")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                        HStack(spacing: 8) {
                            Circle().fill(Color.gray).frame(width: 10, height: 10)
                            Text("Kursziel vorhanden, Ziel noch nicht erreicht")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 4)
                }
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)
                
                Section {
                    Picker("Nur Aktien mit Kursziel von", selection: $kurszielQuelleFilter) {
                        ForEach(ContentView.KurszielQuelleFilter.allCases, id: \.self) { f in
                            Text(f.rawValue).tag(f)
                        }
                    }
                    .pickerStyle(.menu)
                    Toggle("Nur unrealistische Kursziele", isOn: $filterNurUnrealistischeKursziele)
                } header: {
                    Text("Kursziel-Filter")
                } footer: {
                    Text("Aus = alle anzeigen. Sonst nur Aktien der gewählten Quelle. „Nur unrealistische“ zeigt nur Werte, die zum aktuellen Kurs unwahrscheinlich wirken (z. B. 19 € bei Kurs 197 €) – diese können Sie in der Detailansicht korrigieren; manuell korrigierte Kursziele werden beim nächsten Einlesen nicht überschrieben.")
                }
                .listRowBackground(Color.clear)
                
                if sortiereNachAbstandKursziel {
                    Section {
                        ForEach(aktienSortiertNachAbstandKursziel) { aktie in
                            Button {
                                aktienDetailPath.append(aktie.isin)
                            } label: {
                                HStack {
                                    aktienZeileLabel(aktie: aktie, zeigeProzentZumZiel: true)
                                    if aktie.isWatchlist {
                                        Text("Watchlist")
                                            .font(.caption2)
                                            .fontWeight(.medium)
                                            .foregroundColor(.white)
                                            .padding(.horizontal, 6)
                                            .padding(.vertical, 2)
                                            .background(Color.orange.opacity(0.9))
                                            .cornerRadius(4)
                                    }
                                    Spacer(minLength: 8)
                                    Image(systemName: "chevron.right")
                                        .font(.body.weight(.semibold))
                                        .foregroundColor(.secondary)
                                }
                            }
                            .buttonStyle(.plain)
                            .transaction { t in t.animation = .easeOut(duration: 0.22) }
                            .id(aktie.isin)
                            .onAppear { visibleISINsOnAktienList.insert(aktie.isin) }
                            .onDisappear { visibleISINsOnAktienList.remove(aktie.isin) }
                        }
                    } header: {
                        Text("Nach Abstand zum Kursziel (grösste Differenz zuerst)")
                            .font(.caption.weight(.bold))
                            .foregroundColor(.secondary)
                    } footer: {
                        Text("Zwischensummen pro BL: Toolbar-Button „Sortierung: Standard“ tippen.")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                } else {
                    ForEach(Array(gruppierteAktien.enumerated()), id: \.offset) { _, group in
                        Section {
                            ForEach(group.aktien) { aktie in
                                Button {
                                    aktienDetailPath.append(aktie.isin)
                                } label: {
                                    HStack {
                                        aktienZeileLabel(aktie: aktie, zeigeProzentZumZiel: false)
                                        if aktie.isWatchlist {
                                            Text("Watchlist")
                                                .font(.caption2)
                                                .fontWeight(.medium)
                                                .foregroundColor(.white)
                                                .padding(.horizontal, 6)
                                                .padding(.vertical, 2)
                                                .background(Color.orange.opacity(0.9))
                                                .cornerRadius(4)
                                        }
                                        Spacer(minLength: 8)
                                        Image(systemName: "chevron.right")
                                            .font(.body.weight(.semibold))
                                            .foregroundColor(.secondary)
                                    }
                                }
                                .buttonStyle(.plain)
                                .transaction { t in t.animation = .easeOut(duration: 0.22) }
                                .id(aktie.isin)
                                .onAppear { visibleISINsOnAktienList.insert(aktie.isin) }
                                .onDisappear { visibleISINsOnAktienList.remove(aktie.isin) }
                            }
                            .onDelete { offsets in
                                deleteAktienInGroup(group.aktien, offsets: offsets)
                            }
                        } header: {
                            Text(group.bl == watchlistBankleistungsnummer ? "Watchlist" : "BL \(group.bl)")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        } footer: {
                            let zwischensumme = group.aktien.compactMap { $0.marktwertEUR }.reduce(0, +)
                            HStack {
                                Text("Zwischensumme")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                                Spacer()
                                Text("\(zwischensumme, specifier: "%.2f") €")
                                    .font(.caption)
                                    .fontWeight(.medium)
                            }
                        }
                    }
                }
                
                Section {
                    HStack {
                        Text("Gesamtsumme Marktwert")
                            .font(.subheadline)
                            .fontWeight(.semibold)
                        Spacer()
                        Text("\(gesamtMarktwert, specifier: "%.2f") €")
                            .font(.subheadline)
                            .fontWeight(.semibold)
                    }
                    .padding(.vertical, 4)
                }
            }
    }

    var body: some View {
        ZStack {
            contentView
            if showSplash {
                splashOverlay
            }
        }
        .animation(.easeOut(duration: 0.25), value: showSplash)
        .onAppear {
            // Kurz Splash zeigen, damit nie nur ein weißes Bild erscheint
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                showSplash = false
            }
        }
    }
    
    /// Beim Laden anzeigen statt weißem Bildschirm
    private var splashOverlay: some View {
        ZStack {
            Color(.systemGroupedBackground)
                .ignoresSafeArea()
            VStack(spacing: 16) {
                Image(systemName: "chart.line.uptrend.xyaxis")
                    .font(.system(size: 44))
                    .foregroundStyle(.secondary)
                Text("Aktien")
                    .font(.title2.bold())
                ProgressView()
                    .scaleEffect(0.9)
                    .padding(.top, 4)
            }
        }
        .transition(.opacity)
    }

    @ViewBuilder
    private var contentView: some View {
        TabView(selection: selectedTabBinding) {
            aktienTabContent
                .tabItem { Label("Aktien", systemImage: "list.bullet") }
                .tag(0)
                .task {
                    let (usd, gbp) = await KurszielService.fetchAppWechselkurse()
                    await MainActor.run { AppWechselkurse.shared.set(usd: usd, gbp: gbp) }
                }

            NavigationStack {
                KurszielListenView(aktien: aktienZurAnzeige, scrollToISIN: $scrollToISINOnKurszieleTab, markedISIN: currentDetailISIN, onCopyISIN: { scrollToISIN = $0 }, onRowEdited: { scrollToISINWhenReturningFromKursziele = $0 }, onKurszielSuchenTapped: { currentDetailISIN = $0 })
            }
            .tabItem { Label("Kursziele", systemImage: "target") }
            .tag(1)
            .onChange(of: selectedTab) { _, new in
                if new == 1 {
                    scrollToISINOnKurszieleTab = currentDetailISIN ?? gruppierteAktien.flatMap(\.aktien).first(where: { visibleISINsOnAktienList.contains($0.isin) })?.isin
                }
            }
        }
        #if os(iOS)
        .toolbar {
            ToolbarItemGroup(placement: .keyboard) {
                Spacer()
                Button("Fertig") {
                    UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
                }
            }
        }
        #endif
        .overlay { importingOverlay }
        .confirmationDialog(unrealistischConfirm.dialogTitle.isEmpty ? "OpenAI-Ersatz übernehmen?" : unrealistischConfirm.dialogTitle, isPresented: $unrealistischConfirm.isPresented) {
            Button("Ja, übernehmen") { unrealistischConfirm.choose(true) }
            Button("Nein, nicht übernehmen") { unrealistischConfirm.choose(false) }
            Button("Abbrechen", role: .cancel) { unrealistischConfirm.choose(false) }
        } message: {
            if let orig = unrealistischConfirm.original, let repl = unrealistischConfirm.replacement {
                let name = unrealistischConfirm.aktienBezeichnung.isEmpty ? "Aktie" : unrealistischConfirm.aktienBezeichnung
                Text("\(name): Original \(String(format: "%.2f", orig.kursziel)) \(orig.waehrung ?? "EUR"). OpenAI-Ersatz: \(String(format: "%.2f", repl.kursziel)) \(repl.waehrung ?? "EUR"). Übernehmen?")
            }
        }
    }

    @ViewBuilder
    private var importingOverlay: some View {
        if isImportingKursziele || isImportingKurszieleOpenAI {
            VStack {
                Spacer()
                VStack(spacing: 8) {
                    HStack {
                        ProgressView()
                        Text(isImportingKurszieleOpenAI ? "Kursziele werden via OpenAI abgerufen…" : "Kursziele werden abgerufen…")
                            .font(.caption)
                    }
                    if let aktie = aktuelleKurszielAktie {
                        Text(aktie.bezeichnung)
                            .font(.caption)
                            .fontWeight(.medium)
                        if !aktie.wkn.isEmpty {
                            Text("WKN: \(aktie.wkn)")
                                .font(.caption2)
                                .foregroundColor(.secondary)
                        }
                    }
                }
                .padding()
                .background(.ultraThinMaterial)
                .cornerRadius(10)
                .padding(.bottom, 40)
            }
            .allowsHitTesting(false)
        }
    }

    private func importCSVFiles() {
        isImporting = true
    }
    
    private func handleFileImport(result: Result<[URL], Error>) {
        switch result {
        case .success(let urls):
            // Picker zuerst schließen; Import erst in der nächsten Run-Loop starten, damit die Maske wirklich verschwindet
            isImporting = false
            DispatchQueue.main.async { [urls] in
                self.importMultipleCSVFiles(urls: urls)
            }
        case .failure(let error):
            isImporting = false
            importMessage = "Fehler beim Auswählen der Dateien: \(error.localizedDescription)"
            showImportMessage = true
        }
    }
    
    private func importMultipleCSVFiles(urls: [URL]) {
        var alleNeuenAktien: [Aktie] = []
        var zeilenVerarbeitet = 0
        var errors: [String] = []
        var parseHinweise: [String] = []
        
        let erstesFilename = urls.first?.lastPathComponent ?? ""
        let einleseDatum = DateFromFilename.parse(erstesFilename) ?? Date()
        let neuestesDatum = importSummaries.map(\.datumAktuelleEinlesung).max()
        
        // Wenn die Datei ein älteres Datum hat als die bisher neueste Einlesung: nur Gesamtwert für die Vergleichsliste übernehmen, Aktien-Daten nicht überschreiben
        if !importSummaries.isEmpty, !aktien.isEmpty, let neuestes = neuestesDatum, einleseDatum < neuestes {
            var gesamtwertNurVergleich = 0.0
            for url in urls {
                do {
                    _ = url.startAccessingSecurityScopedResource()
                    defer { url.stopAccessingSecurityScopedResource() }
                    let (neueAktien, _, _, _) = try CSVParser.parseCSVWithStats(from: url)
                    gesamtwertNurVergleich += neueAktien.compactMap { $0.marktwertEUR }.reduce(0, +)
                } catch {
                    importMessage = "Fehler beim Einlesen von \(url.lastPathComponent): \(error.localizedDescription)"
                    showImportMessage = true
                    return
                }
            }
            let summary = ImportSummary(gesamtwertVoreinlesung: 0, gesamtwertAktuelleEinlesung: gesamtwertNurVergleich, datumVoreinlesung: nil, datumAktuelleEinlesung: einleseDatum)
            modelContext.insert(summary)
            let ueberzaehlige = Array(importSummaries.dropFirst(10))
            for oldSummary in ueberzaehlige {
                let dateToRemove = oldSummary.datumAktuelleEinlesung
                let descriptor = FetchDescriptor<ImportPositionSnapshot>(predicate: #Predicate<ImportPositionSnapshot> { $0.importDatum == dateToRemove })
                if let toDelete = try? modelContext.fetch(descriptor) {
                    for s in toDelete { modelContext.delete(s) }
                }
                modelContext.delete(oldSummary)
            }
            do {
                try modelContext.save()
            } catch {
                importMessage = "Speicherfehler: \(error.localizedDescription)"
                showImportMessage = true
                return
            }
            let datumStr = einleseDatum.formatted(date: .abbreviated, time: .shortened)
            let neuestStr = neuestes.formatted(date: .abbreviated, time: .shortened)
            importMessage = "Einlesung vom \(datumStr) wurde nur für die Vergleichsliste übernommen (älteres Datum). Die angezeigten Daten stammen weiterhin vom \(neuestStr)."
            showImportMessage = true
            return
        }
        
        let alteAktien = Array(aktien)
        let gesamtwertVoreinlesung = alteAktien.compactMap { $0.marktwertEUR }.reduce(0, +)
        
        // 1. Alle CSV-Daten einlesen und als neue Zeilen einfügen
        var csvHadKursziele = false
        for url in urls {
            do {
                _ = url.startAccessingSecurityScopedResource()
                defer { url.stopAccessingSecurityScopedResource() }
                
                let (neueAktien, zeilenGesamt, zeilenImportiert, hadKursziele) = try CSVParser.parseCSVWithStats(from: url)
                csvHadKursziele = csvHadKursziele || hadKursziele
                zeilenVerarbeitet += zeilenImportiert
                if zeilenGesamt > zeilenImportiert {
                    let u = zeilenGesamt - zeilenImportiert
                    parseHinweise.append("\(url.lastPathComponent): \(zeilenGesamt) Zeilen in Datei, \(zeilenImportiert) als Positionen importiert. \(u) Zeile(n) konnten nicht zugeordnet werden (z. B. anderes Format oder fehlende Pflichtfelder).")
                }
                for neueAktie in neueAktien {
                    let nIsin = neueAktie.isin.trimmingCharacters(in: .whitespaces)
                    let nWkn = neueAktie.wkn.trimmingCharacters(in: .whitespaces)
                    if let watchlist = alteAktien.first(where: { w in
                        w.isWatchlist && ((!nIsin.isEmpty && w.isin.trimmingCharacters(in: .whitespaces) == nIsin) || (!nWkn.isEmpty && w.wkn.trimmingCharacters(in: .whitespaces) == nWkn))
                    }) {
                        watchlist.kurs = neueAktie.kurs
                        watchlist.devisenkurs = neueAktie.devisenkurs
                        watchlist.marktwertEUR = neueAktie.marktwertEUR
                        if neueAktie.bezeichnung.isEmpty == false { watchlist.bezeichnung = neueAktie.bezeichnung }
                        continue
                    }
                    modelContext.insert(neueAktie)
                    alleNeuenAktien.append(neueAktie)
                }
            } catch {
                errors.append("\(url.lastPathComponent): \(error.localizedDescription)")
            }
        }
        
        do {
            try modelContext.save()
        } catch {
            importMessage = "Speicherfehler beim Einlesen: \(error.localizedDescription)"
            showImportMessage = true
            return
        }
        
        // Gespeicherte manuelle Kursziele (nach „Löschen und Kursziele merken“) wieder zuordnen
        let wiederZugeordnet = applySavedManualKursziele(to: alleNeuenAktien)
        
        // Abgleich pro Bankleistungsnummer: Nur Konten, die in der CSV vorkommen, werden aktualisiert.
        // Alte Positionen dieser Konten werden entfernt (Verkäufe) – andere Konten (BL nicht in CSV) bleiben unverändert.
        let csvBankleistungsnummern = Set(alleNeuenAktien.map { $0.bankleistungsnummer.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty })
        
        // 2. Vergleiche alt/neu: previousMarktwertEUR, previousBestand, previousKurs, Kursziel etc. von alter Position übernehmen
        // Matching erfolgt über bankleistungsnummer UND (WKN ODER ISIN)
        // Wichtig: bankleistungsnummer allein reicht nicht, da z.B. Amazon unter mehreren BL-Nummern existieren kann
        for neue in alleNeuenAktien {
            let bl = neue.bankleistungsnummer.trimmingCharacters(in: .whitespaces)
            let wkn = neue.wkn.trimmingCharacters(in: .whitespaces)
            let isin = neue.isin.trimmingCharacters(in: .whitespaces)
            
            // Suche nach passender alter Aktie: bankleistungsnummer muss übereinstimmen UND (WKN ODER ISIN)
            if let alte = alteAktien.first(where: { alteAktie in
                let alteBL = alteAktie.bankleistungsnummer.trimmingCharacters(in: .whitespaces)
                let alteWKN = alteAktie.wkn.trimmingCharacters(in: .whitespaces)
                let alteISIN = alteAktie.isin.trimmingCharacters(in: .whitespaces)
                
                // bankleistungsnummer muss übereinstimmen
                let blMatch = !bl.isEmpty && !alteBL.isEmpty && bl == alteBL
                guard blMatch else { return false }
                
                // Zusätzlich muss WKN ODER ISIN übereinstimmen
                let wknMatch = !wkn.isEmpty && !alteWKN.isEmpty && wkn == alteWKN
                let isinMatch = !isin.isEmpty && !alteISIN.isEmpty && isin == alteISIN
                
                return wknMatch || isinMatch
            }) {
                // Alte Werte speichern
                neue.previousMarktwertEUR = alte.marktwertEUR
                neue.previousBestand = alte.bestand
                neue.previousKurs = alte.kurs ?? alte.devisenkurs
                
                // Kursziel übernehmen, wenn manuell geändert oder aus CSV (C) – sonst beim Abruf neu ermitteln
                // Bei Fonds/Fund/ETF werden keine Kursziele ermittelt; gesetzte Werte bei nächster Einlesung übernehmen
                if let kz = alte.kursziel {
                    if alte.kurszielManuellGeaendert {
                        neue.kursziel = kz
                        neue.kurszielDatum = alte.kurszielDatum
                        neue.kurszielAbstand = alte.kurszielAbstand
                        neue.kurszielQuelle = alte.kurszielQuelle
                        neue.kurszielWaehrung = alte.kurszielWaehrung
                        neue.kurszielManuellGeaendert = true
                    } else if alte.kurszielQuelle == "C", neue.kursziel == nil {
                        // Altes Kursziel aus CSV übernehmen, wenn neue CSV keinen Wert hat
                        neue.kursziel = kz
                        neue.kurszielDatum = alte.kurszielDatum
                        neue.kurszielAbstand = alte.kurszielAbstand
                        neue.kurszielQuelle = "C"
                        neue.kurszielWaehrung = alte.kurszielWaehrung
                    } else if neue.istFonds {
                        // Fonds/Fund/ETF: ermittelte Kursziele gibt es nicht – vorhandenes Kursziel aus Bestand übernehmen
                        neue.kursziel = kz
                        neue.kurszielDatum = alte.kurszielDatum
                        neue.kurszielAbstand = alte.kurszielAbstand
                        neue.kurszielQuelle = alte.kurszielQuelle
                        neue.kurszielWaehrung = alte.kurszielWaehrung
                    }
                }
            }
        }
        
        // 3. Alte Zeilen nur für die in der CSV vorkommenden Bankleistungsnummern löschen (Abgleich: verkaufte/entfernte Positionen weg). Watchlist-Positionen nie löschen.
        for alte in alteAktien {
            if alte.isWatchlist { continue }
            let alteBL = alte.bankleistungsnummer.trimmingCharacters(in: .whitespaces)
            if !alteBL.isEmpty && csvBankleistungsnummern.contains(alteBL) {
                modelContext.delete(alte)
            }
        }
        
        let gesamtwertAktuelleEinlesung = alleNeuenAktien.compactMap { $0.marktwertEUR }.reduce(0, +)
        let datumVoreinlesung = importSummaries.first?.importDatum
        let summary = ImportSummary(gesamtwertVoreinlesung: gesamtwertVoreinlesung, gesamtwertAktuelleEinlesung: gesamtwertAktuelleEinlesung, datumVoreinlesung: datumVoreinlesung, datumAktuelleEinlesung: einleseDatum)
        modelContext.insert(summary)
        // Pro Position Snapshot für Verlauf/Charts (Kurs, Kursziel, Abstand)
        for aktie in alleNeuenAktien {
            let kurs = aktie.kurs ?? aktie.devisenkurs
            let kz = aktie.kursziel
            let abstand: Double? = (kurs != nil && kurs! > 0 && kz != nil) ? ((kz! - kurs!) / kurs! * 100) : nil
            let bl = aktie.bankleistungsnummer.trimmingCharacters(in: .whitespaces)
            let snap = ImportPositionSnapshot(
                importDatum: einleseDatum,
                isin: aktie.isin,
                wkn: aktie.wkn,
                bankleistungsnummer: bl,
                marktwertEUR: aktie.marktwertEUR,
                kurs: kurs,
                kursziel: kz,
                abstandPct: abstand
            )
            modelContext.insert(snap)
        }
        // Nur die letzten 10 Einlesungen behalten; bei der 11. entfällt die älteste (importSummaries hat noch den Stand vor dem Insert)
        let ueberzaehlige = Array(importSummaries.dropFirst(10))
        for oldSummary in ueberzaehlige {
            let dateToRemove = oldSummary.datumAktuelleEinlesung
            let descriptor = FetchDescriptor<ImportPositionSnapshot>(predicate: #Predicate<ImportPositionSnapshot> { $0.importDatum == dateToRemove })
            if let toDelete = try? modelContext.fetch(descriptor) {
                for s in toDelete { modelContext.delete(s) }
            }
            modelContext.delete(oldSummary)
        }
        
        do {
            try modelContext.save()
        } catch {
            importMessage = "Speicherfehler: \(error.localizedDescription)"
            showImportMessage = true
            return
        }
        
        var message = "\(alleNeuenAktien.count) Aktien in der Liste (\(zeilenVerarbeitet) Zeilen aus CSV verarbeitet)."
        if wiederZugeordnet > 0 {
            message += "\n\n\(wiederZugeordnet) manuelle Kursziele wieder zugeordnet (gemerkt nach „Alles löschen“)."
        }
        if !parseHinweise.isEmpty {
            message += "\n\n" + parseHinweise.joined(separator: "\n")
        }
        if !errors.isEmpty {
            message += "\n\nFehler:\n" + errors.joined(separator: "\n")
        }
        
        importMessage = message
        showImportMessage = true
        
        // Kurszielermittlung erst nach OK auf dem Import-Alert starten; bei Daten vor Tagesdatum vorher abfragen.
        // CSV ohne Kursziele: alle Werte neu berechnen (auch mit C gekennzeichnete), daher forceOverwrite.
        let sollAktualisieren: (Aktie) -> Bool = { a in
            if forceOverwriteAllKursziele || !csvHadKursziele { return !a.kurszielManuellGeaendert }
            return !a.kurszielManuellGeaendert && a.kurszielQuelle != "C" && a.kursziel == nil
        }
        let brauchtKursziel = !csvHadKursziele || !alleNeuenAktien.filter(sollAktualisieren).isEmpty
        let hatFMPOderOpenAI = !fmpAPIKeyStore.trimmingCharacters(in: .whitespaces).isEmpty || !openAIAPIKeyStore.trimmingCharacters(in: .whitespaces).isEmpty
        if brauchtKursziel, hatFMPOderOpenAI {
            pendingKurszielForceOverwrite = forceOverwriteAllKursziele || !csvHadKursziele
            pendingKurszielImportDatum = einleseDatum
            let startOfToday = Calendar.current.startOfDay(for: Date())
            if einleseDatum < startOfToday {
                showKurszielAbfrageBeiAltemDatum = true
            } else {
                pendingKurszielFetchAfterImport = true
            }
        }
    }
    
    private func startPendingKurszielFetch() {
        KurszielService.clearCachesForApiCalls()
        let forceOverwrite = pendingKurszielForceOverwrite
        let sollAktualisieren: (Aktie) -> Bool = { a in
            if forceOverwrite { return !a.kurszielManuellGeaendert }
            return !a.kurszielManuellGeaendert && a.kurszielQuelle != "C" && a.kursziel == nil
        }
        let list = aktien.filter(sollAktualisieren)
        let importDate = pendingKurszielImportDatum
        if !list.isEmpty {
            Task { await fetchKurszieleForAktien(list, forceOverwrite: forceOverwrite, snapshotImportDatum: importDate) }
        }
        pendingKurszielImportDatum = nil
    }
    
    private func fetchKurszieleViaOpenAI() {
        KurszielService.clearCachesForApiCalls()
        guard !openAIAPIKeyStore.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        KurszielService.openAIAPIKey = openAIAPIKeyStore.trimmingCharacters(in: .whitespaces)
        isImportingKurszieleOpenAI = true
        aktuelleKurszielAktie = nil
        Task {
            let zuAktualisieren = aktien.filter { forceOverwriteAllKursziele || (!$0.kurszielManuellGeaendert && $0.kurszielQuelle != "C") }
            for aktie in zuAktualisieren {
                await MainActor.run {
                    aktuelleKurszielAktie = (bezeichnung: aktie.bezeichnung, wkn: aktie.wkn)
                }
                if var info = await KurszielService.fetchKurszielVonOpenAI(wkn: aktie.wkn, bezeichnung: aktie.bezeichnung, isin: aktie.isin) {
                    info = await KurszielService.kurszielInfoZuEUR(info: info, aktie: aktie)
                    let refPrice = aktie.kurs ?? aktie.einstandskurs
                    if KurszielService.isKurszielRealistisch(kursziel: info.kursziel, refPrice: refPrice) {
                        await MainActor.run {
                            aktie.kursziel = info.kursziel
                            aktie.kurszielDatum = info.datum
                            aktie.kurszielAbstand = info.spalte4Durchschnitt
                            aktie.kurszielQuelle = info.quelle.rawValue
                            aktie.kurszielWaehrung = info.waehrung
                            aktie.kurszielManuellGeaendert = false
                            try? modelContext.save()
                        }
                    }
                }
            }
            await MainActor.run {
                isImportingKurszieleOpenAI = false
                aktuelleKurszielAktie = nil
            }
        }
    }
    
    private func fetchKurszieleForAktien(_ aktienListe: [Aktie], forceOverwrite: Bool = false, snapshotImportDatum: Date? = nil) async {
        KurszielService.clearCachesForApiCalls()
        await MainActor.run { 
            isImportingKursziele = true
            aktuelleKurszielAktie = nil
        }
        KurszielService.clearDebugLog()
        // Bei automatischer Einlesung: keinen Dialog anzeigen, OpenAI-Ersatz nicht übernehmen (nur Werte übernehmen, die realistisch sind)
        KurszielService.onUnrealistischErsatzBestätigen = { _, _, _ in false }
        
        // Nicht überschreiben: manuell geändert; oder aus CSV (C) mit Wert – außer „Alle überschreiben“. Ohne Kursziel immer abrufen (auch bei Quelle C), damit FMP/OpenAI etc. einen Wert liefern können.
        let sollUeberschreiben: (Aktie) -> Bool = { a in
            if forceOverwrite { return !a.kurszielManuellGeaendert }
            if a.kurszielManuellGeaendert { return false }
            if a.kursziel == nil { return true }
            return a.kurszielQuelle != "C"
        }
        let listToProcess = aktienListe.filter(sollUeberschreiben)
        
        // 1. FMP Bulk-Abruf für die zu bearbeitenden Aktien
        let fmpCache = await KurszielService.fetchKurszieleBulkFMP(aktien: listToProcess, forceOverwrite: forceOverwrite)
        
        for aktie in aktienListe {
            guard sollUeberschreiben(aktie) else { continue }
            
            // Aktuelle Aktie anzeigen
            await MainActor.run {
                aktuelleKurszielAktie = (bezeichnung: aktie.bezeichnung, wkn: aktie.wkn)
            }
            
            // Watchlist: Kurs kommt nicht aus der CSV – bei Einlesung aktuellen Kurs ermitteln
            if aktie.isWatchlist {
                let term = (aktie.isin.trimmingCharacters(in: .whitespaces).isEmpty ? aktie.wkn : aktie.isin).trimmingCharacters(in: .whitespaces)
                if !term.isEmpty, let lookup = await KurszielService.lookupWatchlist(searchTerm: term) {
                    await MainActor.run {
                        if let k = lookup.kurs {
                            aktie.kurs = k
                            if aktie.bestand == 0 { aktie.marktwertEUR = 0 } else { aktie.marktwertEUR = k * Double(aktie.bestand) }
                        }
                        // Bezeichnung für Watchlist erzeugen, wenn fehlend oder nur WKN/ISIN (kommt nicht aus CSV)
                        let aktuelleBez = aktie.bezeichnung.trimmingCharacters(in: .whitespaces)
                        let lookupBez = lookup.bezeichnung.trimmingCharacters(in: .whitespaces)
                        if !lookupBez.isEmpty,
                           aktuelleBez.isEmpty || aktuelleBez == aktie.wkn || aktuelleBez == aktie.isin || (aktuelleBez.count <= 8 && aktuelleBez.allSatisfy(\.isNumber)) {
                            aktie.bezeichnung = lookupBez
                        } else if aktuelleBez.isEmpty || aktuelleBez == aktie.wkn || aktuelleBez == aktie.isin {
                            aktie.bezeichnung = watchlistBezeichnungFallback(wkn: aktie.wkn, isin: aktie.isin)
                        }
                        try? modelContext.save()
                    }
                }
            }
            
            // WICHTIG: Setze Kursziel erst auf nil, damit nicht das alte Kursziel bestehen bleibt
            await MainActor.run {
                aktie.kursziel = nil
                aktie.kurszielDatum = nil
                aktie.kurszielAbstand = nil
                aktie.kurszielQuelle = nil
                aktie.kurszielWaehrung = nil
                aktie.kurszielHigh = nil
                aktie.kurszielLow = nil
                aktie.kurszielAnalysten = nil
            }
            
            // Gleicher Abruf wie beim Button (FMP, OpenAI mit „Antwort:“/„Rückgabe:“-Parsing, finanzen.net, …)
            let refPrice = aktie.kurs ?? aktie.einstandskurs
            var info: KurszielInfo? = nil
            if let fmpInfo = fmpCache[aktie.wkn], fmpInfo.kursziel > 0, KurszielService.isKurszielRealistisch(kursziel: fmpInfo.kursziel, refPrice: refPrice) {
                // FMP hat brauchbares Kursziel → ggf. OpenAI-Ersatz bei unrealistisch
                info = await KurszielService.applyOpenAIFallbackBeiUnrealistisch(info: fmpInfo, refPrice: refPrice, aktie: aktie)
            } else {
                // Kein FMP oder FMP wertlos (0/unrealistisch) → volle Kette wie Button: OpenAI, finanzen.net, …
                info = await KurszielService.fetchKursziel(for: aktie)
            }
            // Bei refPrice nil/0 wird ermitteltes Kursziel trotzdem übernommen (isKurszielRealistisch gibt dann true)
            if let info = info, KurszielService.isKurszielRealistisch(kursziel: info.kursziel, refPrice: refPrice) {
                await MainActor.run {
                    aktie.kursziel = info.kursziel
                    aktie.kurszielDatum = info.datum
                    aktie.kurszielAbstand = info.spalte4Durchschnitt
                    aktie.kurszielQuelle = info.quelle.rawValue
                    aktie.kurszielWaehrung = info.waehrung
                    aktie.kurszielHigh = info.kurszielHigh
                    aktie.kurszielLow = info.kurszielLow
                    aktie.kurszielAnalysten = info.kurszielAnalysten
                    aktie.kurszielManuellGeaendert = false
                    try? modelContext.save()
                }
            } else {
                await MainActor.run {
                    aktie.kursziel = nil
                    aktie.kurszielDatum = nil
                    aktie.kurszielAbstand = nil
                    aktie.kurszielQuelle = nil
                    aktie.kurszielWaehrung = nil
                    aktie.kurszielHigh = nil
                    aktie.kurszielLow = nil
                    aktie.kurszielAnalysten = nil
                    try? modelContext.save()
                }
            }
        }
        
        await MainActor.run { 
            isImportingKursziele = false
            aktuelleKurszielAktie = nil
        }
        KurszielService.onUnrealistischErsatzBestätigen = nil
        
        // Nach Fetch: Snapshots der gerade bearbeiteten Einlesung mit ermittelten Kurszielen aktualisieren (Chart zeigt sonst nur Blau)
        if let importDate = snapshotImportDatum {
            await MainActor.run {
                let descriptor = FetchDescriptor<ImportPositionSnapshot>(predicate: #Predicate<ImportPositionSnapshot> { $0.importDatum == importDate })
                guard let snapshots = try? modelContext.fetch(descriptor) else { return }
                let blTrim = { (s: String) in s.trimmingCharacters(in: .whitespaces) }
                for snap in snapshots {
                    guard let aktie = aktienListe.first(where: { blTrim($0.isin) == blTrim(snap.isin) && blTrim($0.bankleistungsnummer) == blTrim(snap.bankleistungsnummer) }) else { continue }
                    snap.kursziel = aktie.kursziel
                    if let kurs = aktie.kurs ?? aktie.devisenkurs, kurs > 0, let kz = aktie.kursziel {
                        snap.abstandPct = (kz - kurs) / kurs * 100
                    } else {
                        snap.abstandPct = nil
                    }
                }
                try? modelContext.save()
            }
        }
    }
    
    private func deleteAllAktien() {
        withAnimation {
            for aktie in aktien {
                modelContext.delete(aktie)
            }
            for summary in importSummaries {
                modelContext.delete(summary)
            }
            let snapDesc = FetchDescriptor<ImportPositionSnapshot>()
            if let allSnaps = try? modelContext.fetch(snapDesc) {
                for s in allSnaps { modelContext.delete(s) }
            }
            try? modelContext.save()
        }
    }
    
    /// Eine Einlesung (ein Tag) löschen: zugehörige Aktien, Snapshots und ImportSummary entfernen
    private func deleteEinlesung(_ summary: ImportSummary) {
        let dateToRemove = summary.datumAktuelleEinlesung
        withAnimation {
            do {
                let aktieDescriptor = FetchDescriptor<Aktie>(predicate: #Predicate<Aktie> { $0.importDatum == dateToRemove })
                let aktienToDelete = try modelContext.fetch(aktieDescriptor)
                for a in aktienToDelete { modelContext.delete(a) }
                let snapDescriptor = FetchDescriptor<ImportPositionSnapshot>(predicate: #Predicate<ImportPositionSnapshot> { $0.importDatum == dateToRemove })
                let snapsToDelete = try modelContext.fetch(snapDescriptor)
                for s in snapsToDelete { modelContext.delete(s) }
                modelContext.delete(summary)
                try modelContext.save()
            } catch {
                // Fehler beim Speichern ignorieren oder anzeigen
            }
        }
    }
    
    /// Manuelle Kursziele in UserDefaults speichern, dann alles löschen; beim nächsten Import wieder zuordnen
    private func saveManualKurszieleAndDeleteAll() {
        let zuMerken = aktien.filter { $0.kurszielManuellGeaendert }.compactMap { a -> SavedManualKursziel? in
            guard let kz = a.kursziel else { return nil }
            return SavedManualKursziel(
                isin: a.isin.trimmingCharacters(in: .whitespaces),
                wkn: a.wkn.trimmingCharacters(in: .whitespaces),
                kursziel: kz,
                kurszielDatum: a.kurszielDatum,
                kurszielAbstand: a.kurszielAbstand,
                kurszielQuelle: a.kurszielQuelle,
                kurszielWaehrung: a.kurszielWaehrung,
                kurszielHigh: a.kurszielHigh,
                kurszielLow: a.kurszielLow,
                kurszielAnalysten: a.kurszielAnalysten
            )
        }
        if !zuMerken.isEmpty {
            if let data = try? JSONEncoder().encode(zuMerken) {
                UserDefaults.standard.set(data, forKey: savedManualKurszieleUserDefaultsKey)
            }
        } else {
            UserDefaults.standard.removeObject(forKey: savedManualKurszieleUserDefaultsKey)
        }
        deleteAllAktien()
    }
    
    /// Gespeicherte manuelle Kursziele laden und auf neue Aktien anwenden (Match über ISIN oder WKN), dann aus UserDefaults entfernen. Gibt die Anzahl zugeordneter zurück.
    private func applySavedManualKursziele(to neueAktien: [Aktie]) -> Int {
        guard let data = UserDefaults.standard.data(forKey: savedManualKurszieleUserDefaultsKey),
              let saved = try? JSONDecoder().decode([SavedManualKursziel].self, from: data) else { return 0 }
        var zugeordnet = 0
        for s in saved {
            guard let match = neueAktien.first(where: { neu in
                let isinMatch = !s.isin.isEmpty && !neu.isin.trimmingCharacters(in: .whitespaces).isEmpty && neu.isin.trimmingCharacters(in: .whitespaces) == s.isin
                let wknMatch = !s.wkn.isEmpty && !neu.wkn.trimmingCharacters(in: .whitespaces).isEmpty && neu.wkn.trimmingCharacters(in: .whitespaces) == s.wkn
                return isinMatch || wknMatch
            }) else { continue }
            match.kursziel = s.kursziel
            match.kurszielDatum = s.kurszielDatum
            match.kurszielAbstand = s.kurszielAbstand
            match.kurszielQuelle = s.kurszielQuelle
            match.kurszielWaehrung = s.kurszielWaehrung
            match.kurszielHigh = s.kurszielHigh
            match.kurszielLow = s.kurszielLow
            match.kurszielAnalysten = s.kurszielAnalysten
            match.kurszielManuellGeaendert = true
            zugeordnet += 1
        }
        UserDefaults.standard.removeObject(forKey: savedManualKurszieleUserDefaultsKey)
        return zugeordnet
    }

    private func deleteAktienInGroup(_ groupAktien: [Aktie], offsets: IndexSet) {
        withAnimation {
            for index in offsets {
                modelContext.delete(groupAktien[index])
            }
        }
    }
}

// MARK: - Seite 2: Kursziele (ISIN, Bezeichnung, Kursziel, Realistisch, Links)
struct KurszielListenView: View {
    var aktien: [Aktie]
    @Binding var scrollToISIN: String?
    /// ISIN des zuletzt in der Aktien-Detailansicht gewählten Wertpapiers → Zeile in der Kursziel-Liste markieren
    var markedISIN: String? = nil
    var onCopyISIN: ((String) -> Void)? = nil
    /// Wird gesetzt, wenn in einer Zeile ein Kursziel geändert wird → beim Zurückwechseln zur Aktien-Ansicht dorthin scrollen
    var onRowEdited: ((String) -> Void)? = nil
    /// Wird aufgerufen, wenn „Kursziel suchen“ getippt wird → Zeile blau markieren; beim nächsten Tipp auf andere Zeile Markierung verschieben
    var onKurszielSuchenTapped: ((String) -> Void)? = nil
    @Environment(\.modelContext) private var modelContext
    @State private var showDebugLog = false
    private let finanzenNetAnalysenURL = URL(string: "https://www.finanzen.net/analysen")!
    
    var body: some View {
        ScrollViewReader { proxy in
            List {
                Section {
                    Link(destination: finanzenNetAnalysenURL) {
                        Label("Finanzen.net Analysen", systemImage: "link")
                    }
                } header: {
                    Text("Links")
                }
                
                Section {
                    ForEach(aktien) { aktie in
                        KurszielZeileView(aktie: aktie, modelContext: modelContext, isMarked: markedISIN.map { aktie.isin == $0 } ?? false, onCopyISIN: onCopyISIN, onRowEdited: onRowEdited, onKurszielSuchenTapped: onKurszielSuchenTapped)
                            .id(aktie.isin)
                    }
                } header: {
                    Text("Kursziele")
                } footer: {
                    Text("Gelber Stern = zuletzt geöffnete Position. ISIN antippen → Kopieren. Kursziel bearbeiten wirkt wie auf der Detailseite (manuell). Tastatur: «Fertig» oder nach unten scrollen.")
                }
            }
            .onChange(of: scrollToISIN) { _, isin in
                guard let isin = isin, !isin.isEmpty else { return }
                DispatchQueue.main.async {
                    proxy.scrollTo(isin, anchor: .center)
                    scrollToISIN = nil
                }
            }
            .onAppear {
                if let isin = scrollToISIN, !isin.isEmpty {
                    DispatchQueue.main.async {
                        proxy.scrollTo(isin, anchor: .center)
                        scrollToISIN = nil
                    }
                }
            }
        }
        .scrollDismissesKeyboard(.interactively)
        .navigationTitle("Kursziele")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button(action: { showDebugLog = true }) {
                    Label("Debug-Log", systemImage: "ladybug")
                }
            }
            #if os(iOS)
            ToolbarItemGroup(placement: .keyboard) {
                Spacer()
                Button("Fertig") {
                    UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
                }
            }
            #endif
        }
        .sheet(isPresented: $showDebugLog) {
            DebugLogSheet()
        }
    }
}

private struct KurszielZeileView: View {
    @Bindable var aktie: Aktie
    var modelContext: ModelContext
    /// true = zuletzt in der Aktien-Detailansicht gewähltes Wertpapier (Stern + farbige Markierung)
    var isMarked: Bool = false
    var onCopyISIN: ((String) -> Void)? = nil
    var onRowEdited: ((String) -> Void)? = nil
    var onKurszielSuchenTapped: ((String) -> Void)? = nil
    @AppStorage(KurszielService.fmpAPIKeyKey) private var fmpAPIKeyStore: String = ""
    @AppStorage(KurszielService.openAIAPIKeyKey) private var openAIAPIKeyStore: String = ""
    @State private var showZwischenablageFeedback = false
    @State private var showChatGPTPromptFeedback = false
    @State private var showFMPTest = false
    @State private var showFinanzenNetTest = false
    @State private var showSnippetTest = false
    @State private var showOpenAIDebug = false
    @State private var isLoadingOpenAI = false
    @State private var showOpenAIFileImporter = false
    @State private var pendingKurszielFromFile: Double? = nil
    @State private var showKurszielFromFileConfirm = false
    @State private var pendingOpenAIInfo: KurszielInfo? = nil
    @State private var showOpenAIÜbernehmenConfirm = false
    /// Generation des letzten OpenAI-Abrufs – nur dessen Ergebnis anzeigen (verhindert Mischung bei mehrfachem Tippen)
    @State private var openAIRequestGeneration: Int = 0
    
    private var istFonds: Bool { aktie.istFonds }
    
    private func googleKurszielURL(isin: String) -> URL {
        let query = (isin + " Kursziel").addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? (isin + " Kursziel")
        return URL(string: "https://www.google.com/search?q=\(query)")!
    }
    
    /// Zwischenablage: ISIN + durchschnittliches Kursziel
    private var zwischenablageText: String {
        var t = "ISIN: \(aktie.isin)\ndurchschnittliches Kursziel:"
        if let kz = aktie.kursziel, kz > 0 {
            t += " \(String(format: "%.2f", kz)) \(aktie.kurszielWaehrung ?? "EUR")"
        } else { t += " –" }
        return t
    }
    
    private func copyISIN() {
        let text = zwischenablageText
        #if os(iOS)
        UIPasteboard.general.string = text
        #elseif os(macOS)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        #endif
        onCopyISIN?(aktie.isin)
        showZwischenablageFeedback = true
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.zwischenablageFeedbackDauer) {
            showZwischenablageFeedback = false
        }
    }
    
    private static let zwischenablageFeedbackDauer: TimeInterval = 4.0
    private static let chatGPTURL = URL(string: "https://chat.openai.com/")!
    /// Baut exakten Prompt für ChatGPT: „ISIN … durchschnittliches Kursziel in EUR ? Rückgabe nur den Wert“ (nur ISIN/WKN, keine Bezeichnung).
    private func buildChatGPTPrompt(for aktie: Aktie) -> String {
        let isin = aktie.isin.trimmingCharacters(in: .whitespaces)
        let wkn = aktie.wkn.trimmingCharacters(in: .whitespaces)
        let kennung = isin.count >= 10 ? "ISIN \(isin)" : (wkn.isEmpty ? "ISIN \(isin)" : "WKN \(wkn)")
        return "\(kennung) durchschnittliches Kursziel in EUR ? Rückgabe nur den Wert"
    }
    private func openChatGPT() {
        let prompt = buildChatGPTPrompt(for: aktie)
        showChatGPTPromptFeedback = true
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.zwischenablageFeedbackDauer) {
            showChatGPTPromptFeedback = false
        }
        // Zwischenablage sofort setzen – Hinweis erscheint zuerst in der App
        #if os(iOS)
        UIPasteboard.general.string = prompt
        #elseif os(macOS)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(prompt, forType: .string)
        #endif
        // ChatGPT erst nach 1,5 s öffnen, damit der Zwischenablage-Text sichtbar ist, bevor die App wechselt
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            #if os(iOS)
            UIPasteboard.general.string = prompt
            #elseif os(macOS)
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(prompt, forType: .string)
            #endif
            #if os(iOS)
            UIApplication.shared.open(Self.chatGPTURL)
            #elseif os(macOS)
            NSWorkspace.shared.open(Self.chatGPTURL)
            #endif
        }
    }
    
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 4) {
                        if isMarked {
                            Image(systemName: "star.fill")
                                .font(.caption)
                                .foregroundColor(.yellow)
                        }
                    Button(action: copyISIN) {
                        HStack(spacing: 6) {
                            Text(aktie.isin)
                                .font(.system(.caption, design: .monospaced))
                                .foregroundColor(.accentColor)
                                .underline()
                            if showZwischenablageFeedback {
                                Text("Zwischenablage")
                                    .font(.caption2)
                                    .foregroundColor(.white)
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 3)
                                    .background(Color.accentColor.opacity(0.9))
                                    .cornerRadius(4)
                            }
                        }
                    }
                    .buttonStyle(.plain)
                    .animation(.easeInOut(duration: 0.2), value: showZwischenablageFeedback)
                    Button("ChatGPT") { openChatGPT() }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    if showChatGPTPromptFeedback {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Zwischenablage")
                            Text("Einfügen per Klick – direkt in ChatGPT")
                                .font(.caption2)
                                .opacity(0.95)
                        }
                        .font(.caption2)
                        .foregroundColor(.white)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 3)
                        .background(Color.accentColor.opacity(0.9))
                        .cornerRadius(4)
                    }
                    }
                    .animation(.easeInOut(duration: 0.2), value: showChatGPTPromptFeedback)
                    Text(aktie.bezeichnung)
                        .font(.subheadline)
                        .fontWeight(.medium)
                    if let kurs = aktie.kurs ?? aktie.devisenkurs {
                        Text("Kurs: \(kurs, specifier: "%.4f") \(aktie.waehrung)")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                    }
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 2) {
                    Text(aktie.zeigeAlsUnrealistisch ? "Unrealistisch" : "Realistisch")
                        .font(.caption)
                        .foregroundColor(aktie.zeigeAlsUnrealistisch ? .orange : .green)
                    if let q = aktie.kurszielQuelle {
                        VStack(alignment: .trailing, spacing: 2) {
                            Text("\(q) · \(quelleLabel(q, manuell: aktie.kurszielManuellGeaendert))")
                                .font(.caption2)
                                .foregroundColor(.secondary)
                            if q == KurszielQuelle.suchmaschine.rawValue,
                               let url = KurszielService.snippetSuchergebnisURL(for: aktie) {
                                Button("Suchergebnis") {
                                    #if os(iOS)
                                    UIApplication.shared.open(url)
                                    #elseif os(macOS)
                                    NSWorkspace.shared.open(url)
                                    #endif
                                }
                                .font(.caption2)
                            }
                        }
                    } else if aktie.kurszielManuellGeaendert {
                        Text("Manuell")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                    }
                }
            }
            
            VStack(alignment: .leading, spacing: 8) {
                // Eine Zeile: Kursziel | Eingabefeld EUR | Eingabefeld Währung aus Satz
                HStack(alignment: .center, spacing: 12) {
                    Text("Kursziel")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    StableDecimalField(
                        placeholder: "EUR",
                        value: Binding(
                            get: { aktie.kursziel },
                            set: { newVal in
                                aktie.kursziel = newVal
                                aktie.kurszielManuellGeaendert = true
                                aktie.kurszielDatum = nil
                                aktie.kurszielAbstand = nil
                                aktie.kurszielQuelle = nil
                                aktie.kurszielWaehrung = nil
                                aktie.kurszielHigh = nil
                                aktie.kurszielLow = nil
                                aktie.kurszielAnalysten = nil
                                try? modelContext.save()
                                onRowEdited?(aktie.isin)
                            }
                        )
                    )
                    .frame(maxWidth: 100)
                    Text("EUR")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    if aktie.waehrung.uppercased() != "EUR" {
                        StableDecimalField(
                            placeholder: aktie.waehrung,
                            value: Binding(
                                get: {
                                    guard let k = aktie.kursziel else { return nil }
                                    let rate = (aktie.devisenkurs ?? 1).nonzeroOrOne
                                    return rate != 0 ? k * rate : k
                                },
                                set: { newVal in
                                    let rate = (aktie.devisenkurs ?? 1).nonzeroOrOne
                                    aktie.kursziel = newVal.map { $0 / rate }
                                    aktie.kurszielManuellGeaendert = true
                                    aktie.kurszielDatum = nil
                                    aktie.kurszielAbstand = nil
                                    aktie.kurszielQuelle = nil
                                    aktie.kurszielWaehrung = nil
                                    aktie.kurszielHigh = nil
                                    aktie.kurszielLow = nil
                                    aktie.kurszielAnalysten = nil
                                    try? modelContext.save()
                                    onRowEdited?(aktie.isin)
                                }
                            )
                        )
                        .frame(maxWidth: 100)
                        Text(aktie.waehrung)
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
                // finanzen.net testen + FMP testen + OpenAI + Snippet testen (nur Fonds) + Kursziel suchen
                HStack {
                    Spacer()
                    Button("finanzen.net") {
                        showFinanzenNetTest = true
                    }
                    .font(.caption)
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    Button("FMP testen") {
                        showFMPTest = true
                    }
                    .font(.caption)
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .disabled(fmpAPIKeyStore.trimmingCharacters(in: .whitespaces).isEmpty)
                    Button("OpenAI") {
                        loadKurszielViaOpenAI()
                    }
                    .font(.caption)
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .disabled(openAIAPIKeyStore.trimmingCharacters(in: .whitespaces).isEmpty || isLoadingOpenAI)
                    Button("Aus Datei") {
                        showOpenAIFileImporter = true
                    }
                    .font(.caption)
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    if istFonds {
                        Button("Snippet testen") {
                            showSnippetTest = true
                        }
                        .font(.caption)
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    }
                    Button("Kursziel suchen") {
                        onKurszielSuchenTapped?(aktie.isin)
                        #if os(iOS)
                        UIApplication.shared.open(googleKurszielURL(isin: aktie.isin))
                        #elseif os(macOS)
                        NSWorkspace.shared.open(googleKurszielURL(isin: aktie.isin))
                        #endif
                    }
                    .font(.caption)
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
            }
        }
        .padding(.vertical, 4)
        .listRowBackground(isMarked ? Color.accentColor.opacity(0.2) : Color.clear)
        .sheet(isPresented: $showFMPTest) {
            FMPTestSheetView(aktie: aktie, modelContext: modelContext, onRowEdited: onRowEdited)
        }
        .sheet(isPresented: $showFinanzenNetTest) {
            FinanzenNetTestSheetView(aktie: aktie, modelContext: modelContext, onRowEdited: onRowEdited)
        }
        .sheet(isPresented: $showSnippetTest) {
            SnippetTestSheetView(aktie: aktie, modelContext: modelContext, onRowEdited: onRowEdited)
        }
        .fileImporter(isPresented: $showOpenAIFileImporter, allowedContentTypes: [.json], allowsMultipleSelection: false) { result in
            loadKurszielFromFile(result: result)
        }
        .confirmationDialog("Kursziel übernehmen?", isPresented: $showKurszielFromFileConfirm) {
            Button("Ja") {
                if let kz = pendingKurszielFromFile {
                    aktie.kursziel = kz
                    aktie.kurszielDatum = Date()
                    aktie.kurszielQuelle = "A"
                    aktie.kurszielWaehrung = "EUR"
                    aktie.kurszielManuellGeaendert = false
                    try? modelContext.save()
                    onRowEdited?(aktie.isin)
                }
                pendingKurszielFromFile = nil
            }
            Button("Nein", role: .cancel) {
                pendingKurszielFromFile = nil
            }
        } message: {
            if let kz = pendingKurszielFromFile {
                Text("Kursziel \(String(format: "%.2f", kz)) EUR aus Datei übernehmen?")
            }
        }
        .confirmationDialog("Kursziel übernehmen? – \(aktie.bezeichnung)", isPresented: $showOpenAIÜbernehmenConfirm) {
            Button("Ja, übernehmen") {
                if let info = pendingOpenAIInfo {
                    aktie.kursziel = info.kursziel
                    aktie.kurszielDatum = info.datum
                    aktie.kurszielAbstand = info.spalte4Durchschnitt
                    aktie.kurszielQuelle = info.quelle.rawValue
                    aktie.kurszielWaehrung = info.waehrung
                    aktie.kurszielManuellGeaendert = false
                    try? modelContext.save()
                    onRowEdited?(aktie.isin)
                }
                pendingOpenAIInfo = nil
            }
            Button("Nein, nicht übernehmen") {
                pendingOpenAIInfo = nil
            }
            Button("Abbrechen", role: .cancel) {
                pendingOpenAIInfo = nil
            }
        } message: {
            if let info = pendingOpenAIInfo {
                Text("\(aktie.bezeichnung): Kursziel \(String(format: "%.2f", info.kursziel)) \(info.waehrung ?? "EUR") von OpenAI übernehmen?")
            }
        }
        .onChange(of: aktie.isin) { _, _ in
            openAIRequestGeneration = 0
            pendingOpenAIInfo = nil
            showOpenAIÜbernehmenConfirm = false
        }
    }
    
    /// Extrahiert erste Zahl aus Text (z.B. "125.50 USD" → 125.5)
    private func extractFirstNumber(from s: String) -> Double? {
        let pattern = #"\d+(?:[.,]\d+)?"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)),
              let range = Range(match.range, in: s) else { return nil }
        var numStr = String(s[range]).replacingOccurrences(of: ",", with: ".")
        return Double(numStr)
    }

    /// Demo-Umweg: Kursziel aus openai_kursziel_result.json lesen (Skript im Terminal ausführen, dann Datei wählen)
    private func loadKurszielFromFile(result: Result<[URL], Error>) {
        KurszielService.clearDebugLog()
        KurszielService.debugAppend("━━━ Kursziel aus Datei (Demo-Umweg) ━━━")
        switch result {
        case .success(let urls):
            guard let url = urls.first else {
                KurszielService.debugAppend("   ❌ Keine Datei gewählt")
                return
            }
            guard url.startAccessingSecurityScopedResource() else {
                KurszielService.debugAppend("   ❌ Kein Zugriff auf Datei")
                return
            }
            defer { url.stopAccessingSecurityScopedResource() }
            do {
                let data = try Data(contentsOf: url)
                guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let output = json["output"] as? [[String: Any]] else {
                    KurszielService.debugAppend("   ❌ Ungültiges Format (erwarte output[])")
                    return
                }
                var kursziel: Double?
                var istUSD = false
                for item in output {
                    for c in (item["content"] as? [[String: Any]]) ?? [] {
                        if (c["type"] as? String) == "output_text", let t = c["text"] as? String {
                            let trimmed = t.trimmingCharacters(in: .whitespaces)
                            if let v = Double(trimmed.replacingOccurrences(of: ",", with: ".")), v > 0 {
                                kursziel = v
                                istUSD = trimmed.contains("$") || trimmed.uppercased().contains("USD")
                                break
                            }
                            // Fallback: Zahl aus Text mit Währung (z.B. "125.50 USD" oder "125.50 $")
                            if let v = extractFirstNumber(from: trimmed), v > 0 {
                                kursziel = v
                                istUSD = trimmed.contains("$") || trimmed.uppercased().contains("USD")
                                break
                            }
                        }
                    }
                    if kursziel != nil { break }
                }
                var kzGültig = kursziel
                if let kz = kursziel, kz > 0 {
                    // Verhindern: ISIN-Ziffern statt Kursziel (z.B. 11821202 aus DE00011821202)
                    let kzStr = String(format: "%.0f", kz)
                    if kzStr.count >= 7, !aktie.isin.isEmpty, aktie.isin.contains(kzStr) {
                        KurszielService.debugAppend("   ❌ Gelesener Wert (\(kzStr)) sieht nach ISIN aus, nicht Kursziel")
                        kzGültig = nil
                    } else if kz >= 1_000_000, kz == floor(kz) {
                        KurszielService.debugAppend("   ❌ Unplausibel hoher Wert (\(kz)) – evtl. ISIN, ignoriert")
                        kzGültig = nil
                    }
                }
                if let kz = kzGültig, kz > 0 {
                    if istUSD {
                        Task {
                            let info = KurszielInfo(kursziel: kz, datum: Date(), spalte4Durchschnitt: nil, quelle: .openAI, waehrung: "USD")
                            let eurInfo = await KurszielService.kurszielInfoZuEUR(info: info, aktie: aktie)
                            await MainActor.run {
                                KurszielService.debugAppend("   ✅ Gelesen: \(kz) USD → \(String(format: "%.2f", eurInfo.kursziel)) EUR")
                                pendingKurszielFromFile = eurInfo.kursziel
                                showKurszielFromFileConfirm = true
                            }
                        }
                    } else {
                        KurszielService.debugAppend("   ✅ Gelesen: \(kz) EUR")
                        pendingKurszielFromFile = kz
                        showKurszielFromFileConfirm = true
                    }
                } else {
                    KurszielService.debugAppend("   ❌ Kein Kursziel in Datei gefunden")
                }
            } catch {
                KurszielService.debugAppend("   ❌ Fehler: \(error.localizedDescription)")
            }
        case .failure(let error):
            KurszielService.debugAppend("   ❌ Datei-Auswahl: \(error.localizedDescription)")
        }
    }
    
    private func loadKurszielViaOpenAI() {
        KurszielService.clearCachesForApiCalls()
        guard KurszielService.openAIAPIKey != nil else {
            KurszielService.clearDebugLog()
            KurszielService.debugLog.append("[\(DateFormatter.localizedString(from: Date(), dateStyle: .none, timeStyle: .medium))] ❌ OpenAI API-Key nicht konfiguriert (Einstellungen)")
            return
        }
        // Alte Dialog-Daten und vorherige Abrufe ignorieren – nur dieser Abruf zählt
        pendingOpenAIInfo = nil
        showOpenAIÜbernehmenConfirm = false
        openAIRequestGeneration += 1
        let generation = openAIRequestGeneration
        isLoadingOpenAI = true
        KurszielService.clearDebugLog()
        KurszielService.debugAppend("━━━ OpenAI Kursziel (Button) ━━━")
        KurszielService.debugAppend("   Aktie: \(aktie.bezeichnung), WKN: \(aktie.wkn), ISIN: \(aktie.isin)")
        Task {
            if var info = await KurszielService.fetchKurszielVonOpenAI(wkn: aktie.wkn, bezeichnung: aktie.bezeichnung, isin: aktie.isin) {
                info = await KurszielService.kurszielInfoZuEUR(info: info, aktie: aktie, usdToEurFromHeader: AppWechselkurse.shared.usdToEur, gbpToEurFromHeader: AppWechselkurse.shared.gbpToEur)
                await MainActor.run {
                    guard generation == openAIRequestGeneration else { return }
                    KurszielService.debugAppend("   ✅ Erfolg: \(info.kursziel) \(info.waehrung ?? "EUR")")
                    pendingOpenAIInfo = info
                    showOpenAIÜbernehmenConfirm = true
                }
            } else {
                await MainActor.run {
                    guard generation == openAIRequestGeneration else { return }
                    KurszielService.debugAppend("   ❌ Kein Kursziel erhalten")
                }
            }
            await MainActor.run {
                if generation == openAIRequestGeneration {
                    isLoadingOpenAI = false
                }
            }
        }
    }
    
    private func quelleLabel(_ code: String, manuell: Bool) -> String {
        let name: String
        switch code {
        case "C": name = "CSV"
        case "M": name = "FMP"
        case "A": name = "OpenAI"
        case "F": name = "finanzen.net"
        case "Y": name = "Yahoo"
        case "S": name = "Snippet"
        default: name = code
        }
        return manuell ? "\(name), manuell" : name
    }
}

struct AktieDetailView: View {
    @Environment(\.modelContext) private var modelContext
    @Bindable var aktie: Aktie
    var onAppearISIN: ((String) -> Void)? = nil
    @State private var isLoadingKursziel = false
    @State private var kurszielError: String?
    @State private var positionSnapshots: [ImportPositionSnapshot] = []
    @State private var verlaufChartZoomScale: CGFloat = 1.0
    
    var body: some View {
        Form {
            Section("Grunddaten") {
                LabeledContent("Bankleistungsnummer") {
                    Text(aktie.bankleistungsnummer)
                }
                LabeledContent("Bezeichnung") {
                    Text(aktie.bezeichnung.trimmingCharacters(in: .whitespaces).isEmpty && aktie.isWatchlist
                          ? watchlistBezeichnungFallback(wkn: aktie.wkn, isin: aktie.isin)
                          : aktie.bezeichnung)
                }
                .lineLimit(1)
                LabeledContent("WKN") {
                    Text(aktie.wkn)
                }
                LabeledContent("ISIN") {
                    Text(aktie.isin)
                }
                LabeledContent("Währung") {
                    Text(aktie.waehrung)
                }
                LabeledContent("Bestand") {
                    Text("\(aktie.bestand, specifier: "%.2f")")
                }
            }
            
            if !positionSnapshots.isEmpty {
                Section("Verlauf Kurs / Kursziel (Einlesungen)") {
                    PositionVerlaufChartView(snapshots: positionSnapshots, currentKursziel: aktie.kursziel, zoomScale: $verlaufChartZoomScale)
                        .frame(minHeight: 90)
                        .frame(height: 120 * verlaufChartZoomScale)
                }
            }
            
            Section("Kurse") {
                if let einstandskurs = aktie.einstandskurs {
                    LabeledContent("Einstandskurs") {
                        Text("\(einstandskurs, specifier: "%.4f")")
                    }
                }
                if let kurs = aktie.kurs {
                    LabeledContent("Aktueller Kurs") {
                        Text("\(kurs, specifier: "%.4f")")
                    }
                }
                LabeledContent("Kursziel") {
                    HStack {
                        StableDecimalField(
                            placeholder: "EUR",
                            value: Binding(
                                get: { aktie.kursziel },
                                set: { newVal in
                                    aktie.kursziel = newVal
                                    aktie.kurszielManuellGeaendert = true
                                    aktie.kurszielDatum = nil
                                    aktie.kurszielAbstand = nil
                                    aktie.kurszielQuelle = nil
                                    aktie.kurszielWaehrung = nil
                                    aktie.kurszielHigh = nil
                                    aktie.kurszielLow = nil
                                    aktie.kurszielAnalysten = nil
                                    try? modelContext.save()
                                }
                            )
                        )
                        Text("EUR")
                            .foregroundColor(.secondary)
                        if aktie.waehrung.uppercased() != "EUR" {
                            StableDecimalField(
                                placeholder: aktie.waehrung,
                                value: Binding(
                                    get: {
                                        guard let k = aktie.kursziel else { return nil }
                                        let rate = (aktie.devisenkurs ?? 1).nonzeroOrOne
                                        return rate != 0 ? k * rate : k
                                    },
                                    set: { newVal in
                                        let rate = (aktie.devisenkurs ?? 1).nonzeroOrOne
                                        aktie.kursziel = newVal.map { $0 / rate }
                                        aktie.kurszielManuellGeaendert = true
                                        aktie.kurszielDatum = nil
                                        aktie.kurszielAbstand = nil
                                        aktie.kurszielQuelle = nil
                                        aktie.kurszielWaehrung = nil
                                        aktie.kurszielHigh = nil
                                        aktie.kurszielLow = nil
                                        aktie.kurszielAnalysten = nil
                                        try? modelContext.save()
                                    }
                                )
                            )
                            Text(aktie.waehrung)
                                .foregroundColor(.secondary)
                        }
                        if let quelle = aktie.kurszielQuelle {
                            Text(quelle)
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                        if aktie.kurszielManuellGeaendert {
                            Text("Manuell")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    }
                }
                HStack {
                    Spacer()
                    if aktie.kurszielQuelle == KurszielQuelle.suchmaschine.rawValue,
                       let url = KurszielService.snippetSuchergebnisURL(for: aktie) {
                        Button("Suchergebnis anzeigen") {
                            #if os(iOS)
                            UIApplication.shared.open(url)
                            #elseif os(macOS)
                            NSWorkspace.shared.open(url)
                            #endif
                        }
                        .font(.caption)
                    }
                }
                Text("Eingabe = manuell (wird beim nächsten Kursziel-Abruf nicht überschrieben)")
                    .font(.caption2)
                    .foregroundColor(.secondary)
                if let kursziel = aktie.kursziel, let kurs = aktie.kurs, kurs > 0 {
                    let differenz = kursziel - kurs
                    let differenzProzent = (differenz / kurs) * 100
                    Text("(\(differenz >= 0 ? "+" : "")\(differenzProzent, specifier: "%.1f")% zum Ziel)")
                        .font(.caption)
                        .foregroundColor(differenz >= 0 ? .green : .red)
                }
                if let abstand = aktie.kurszielAbstand {
                    LabeledContent("Abstand Analysten (Ø)") {
                        Text("\(abstand >= 0 ? "+" : "")\(abstand, specifier: "%.1f")%")
                            .foregroundColor(.secondary)
                    }
                }
                if aktie.kurszielQuelle == "M" {
                    let w = aktie.kurszielWaehrung ?? aktie.waehrung
                    if let high = aktie.kurszielHigh { LabeledContent("Hochziel") { Text("\(high, specifier: "%.2f") \(w)") } }
                    if let low = aktie.kurszielLow { LabeledContent("Niedrigziel") { Text("\(low, specifier: "%.2f") \(w)") } }
                    if let n = aktie.kurszielAnalysten { LabeledContent("Anzahl Analysten") { Text("\(n)") } }
                }
                if let kursziel = aktie.kursziel, !aktie.isKurszielPlausibel {
                    Text("Wert erscheint unwahrscheinlich (z.B. 19€ bei Kurs 197€).")
                        .font(.caption)
                        .foregroundColor(.orange)
                    Button("Kursziel verwerfen") {
                        aktie.kursziel = nil
                        aktie.kurszielDatum = nil
                        aktie.kurszielAbstand = nil
                        aktie.kurszielQuelle = nil
                        aktie.kurszielWaehrung = nil
                        aktie.kurszielHigh = nil
                        aktie.kurszielLow = nil
                        aktie.kurszielAnalysten = nil
                        aktie.kurszielManuellGeaendert = false
                        try? modelContext.save()
                    }
                    .font(.caption)
                }
                if !isLoadingKursziel {
                    if aktie.kurszielManuellGeaendert {
                        Button("Wieder automatisch ermitteln") {
                            aktie.kurszielManuellGeaendert = false
                            try? modelContext.save()
                            loadKursziel()
                        }
                    } else if aktie.kursziel == nil || !aktie.isKurszielPlausibel {
                        Button(action: loadKursziel) {
                            HStack {
                                Text("Kursziel abrufen")
                            }
                        }
                    }
                }
                if isLoadingKursziel {
                    HStack {
                        ProgressView()
                            .scaleEffect(0.8)
                        Text("Kursziel wird geladen...")
                            .foregroundColor(.secondary)
                    }
                }
                if let error = kurszielError {
                    Text("Fehler: \(error)")
                        .foregroundColor(.red)
                        .font(.caption)
                }
            }
            
            Section("Gewinn/Verlust") {
                if let gewinnEUR = aktie.gewinnVerlustEUR {
                    LabeledContent("Gewinn/Verlust (EUR)") {
                        Text("\(gewinnEUR, specifier: "%.2f") €")
                            .foregroundColor(gewinnEUR >= 0 ? .green : .red)
                    }
                }
                if let gewinnProzent = aktie.gewinnVerlustProzent {
                    LabeledContent("Gewinn/Verlust (%)") {
                        Text("\(gewinnProzent, specifier: "%.2f") %")
                            .foregroundColor(gewinnProzent >= 0 ? .green : .red)
                    }
                }
                LabeledContent("Marktwert (EUR)") {
                    StableDecimalField(
                        placeholder: "Marktwert",
                        value: Binding(
                            get: { aktie.marktwertEUR },
                            set: { aktie.marktwertEUR = $0 }
                        ),
                        onCommit: { try? modelContext.save() }
                    )
                }
            }
            
            // Section für Alt-Werte aus Voreinlesung (Seite 2)
            if aktie.previousBestand != nil || aktie.previousMarktwertEUR != nil || aktie.previousKurs != nil {
                Section("Werte aus Voreinlesung") {
                    if let bestandAlt = aktie.previousBestand {
                        LabeledContent("Bestand Alt") {
                            Text("\(bestandAlt, specifier: "%.2f")")
                        }
                    }
                    if let marktwertAlt = aktie.previousMarktwertEUR {
                        LabeledContent("Marktwert Alt") {
                            Text("\(marktwertAlt, specifier: "%.2f") €")
                        }
                    }
                    if let kursAlt = aktie.previousKurs {
                        LabeledContent("Kurs Alt") {
                            Text("\(kursAlt, specifier: "%.4f")")
                        }
                    }
                }
            }
            
            Section("Weitere Informationen") {
                LabeledContent("Gattung") {
                    Text(aktie.gattung)
                }
                LabeledContent("Branche") {
                    Text(aktie.branche)
                }
                LabeledContent("Risikoklasse") {
                    Text(aktie.risikoklasse)
                }
                if let datum = aktie.datumLetzteBewegung {
                    LabeledContent("Letzte Bewegung") {
                        Text(datum, format: .dateTime.day().month().year())
                    }
                }
            }
        }
        .task(id: "\(aktie.isin)_\(aktie.bankleistungsnummer)") {
            let isin = aktie.isin.trimmingCharacters(in: .whitespaces)
            let bl = aktie.bankleistungsnummer.trimmingCharacters(in: .whitespaces)
            let descriptor = FetchDescriptor<ImportPositionSnapshot>(
                predicate: #Predicate<ImportPositionSnapshot> { $0.isin == isin && $0.bankleistungsnummer == bl },
                sortBy: [SortDescriptor(\.importDatum)]
            )
            positionSnapshots = (try? modelContext.fetch(descriptor)) ?? []
        }
        .onAppear {
            onAppearISIN?(aktie.isin)
        }
        .scrollDismissesKeyboard(.interactively)
        .navigationTitle(aktie.bezeichnung.trimmingCharacters(in: .whitespaces).isEmpty ? watchlistBezeichnungFallback(wkn: aktie.wkn, isin: aktie.isin) : aktie.bezeichnung)
        .navigationBarTitleDisplayMode(.inline)
        #if os(iOS)
        .toolbar(.visible, for: .tabBar)
        .toolbar {
            ToolbarItemGroup(placement: .keyboard) {
                Spacer()
                Button("Fertig") {
                    UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
                }
            }
        }
        #endif
    }
    
    private func loadKursziel() {
        KurszielService.clearCachesForApiCalls()
        guard !aktie.kurszielManuellGeaendert else {
            isLoadingKursziel = false
            return
        }
        isLoadingKursziel = true
        kurszielError = nil
        
        Task {
            // Dialog „OpenAI-Ersatz übernehmen?“ nur bei manueller Anwahl aus der Kurszielmaske anzeigen
            KurszielService.onUnrealistischErsatzBestätigen = { original, replacement, aktieIn in
                await UnrealistischConfirmHelper.shared.confirm(original: original, replacement: replacement, aktie: aktieIn)
            }
            defer { KurszielService.onUnrealistischErsatzBestätigen = nil }
            
            if let kurszielInfo = await KurszielService.fetchKursziel(for: aktie) {
                await MainActor.run {
                    aktie.kursziel = kurszielInfo.kursziel
                    aktie.kurszielDatum = kurszielInfo.datum
                    aktie.kurszielAbstand = kurszielInfo.spalte4Durchschnitt
                    aktie.kurszielQuelle = kurszielInfo.quelle.rawValue
                    aktie.kurszielWaehrung = kurszielInfo.waehrung
                    aktie.kurszielManuellGeaendert = false
                    isLoadingKursziel = false
                    
                    // Speichern
                    do {
                        try modelContext.save()
                    } catch {
                        kurszielError = "Speicherfehler: \(error.localizedDescription)"
                    }
                }
            } else {
                await MainActor.run {
                    isLoadingKursziel = false
                    kurszielError = "Kursziel nicht gefunden"
                }
            }
        }
    }
}

/// Sheet zum FMP-Befehl testen und Ergebnis übernehmen (pro Aktie auf der Kursziele-Karte)
private struct FMPTestSheetView: View {
    @Bindable var aktie: Aktie
    var modelContext: ModelContext
    var onRowEdited: ((String) -> Void)?
    @Environment(\.dismiss) private var dismiss
    
    @State private var isFetching = false
    @State private var fmpResult: KurszielInfo? = nil
    @State private var fmpError: String? = nil
    
    private var befehlInfo: (url: String, viaIsin: Bool)? {
        KurszielService.fmpBefehlForDisplay(for: aktie)
    }
    
    var body: some View {
        NavigationView {
            Form {
                Section {
                    if let info = befehlInfo {
                        Text(info.url)
                            .font(.system(.caption, design: .monospaced))
                            .textSelection(.enabled)
                    } else {
                        Text("Kein FMP-Symbol für \(aktie.bezeichnung) oder API-Key in Einstellungen fehlt.")
                            .foregroundColor(.secondary)
                    }
                } header: {
                    Text("FMP-Befehl")
                } footer: {
                    if let info = befehlInfo, info.viaIsin {
                        Text("1. search-isin: ISIN → Symbol. 2. price-target-consensus: Symbol → Kursziel. Beide Schritte werden automatisch ausgeführt.")
                    } else {
                        Text("API-URL mit Symbol für diese Aktie. API-Key maskiert.")
                    }
                }
                
                if isFetching {
                    Section {
                        HStack {
                            ProgressView()
                            Text("FMP wird abgerufen...")
                                .foregroundColor(.secondary)
                        }
                    }
                }
                
                if let result = fmpResult {
                    Section {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("Kursziel: \(result.kursziel, specifier: "%.2f") \(result.waehrung ?? "EUR")")
                                .font(.headline)
                            if let h = result.kurszielHigh, let l = result.kurszielLow {
                                Text("High: \(h, specifier: "%.2f") | Low: \(l, specifier: "%.2f")")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                            if let a = result.kurszielAnalysten {
                                Text("\(a) Analysten")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                        }
                        Button("Übernehmen") {
                            aktie.kursziel = result.kursziel
                            aktie.kurszielDatum = result.datum
                            aktie.kurszielAbstand = result.spalte4Durchschnitt
                            aktie.kurszielQuelle = KurszielQuelle.fmp.rawValue
                            aktie.kurszielWaehrung = result.waehrung
                            aktie.kurszielHigh = result.kurszielHigh
                            aktie.kurszielLow = result.kurszielLow
                            aktie.kurszielAnalysten = result.kurszielAnalysten
                            aktie.kurszielManuellGeaendert = false
                            try? modelContext.save()
                            onRowEdited?(aktie.isin)
                            dismiss()
                        }
                        .buttonStyle(.borderedProminent)
                    } header: {
                        Text("Ergebnis")
                    }
                }
                
                if let err = fmpError {
                    Section {
                        Text(err)
                            .foregroundColor(.red)
                    } header: {
                        Text("Fehler")
                    }
                }
                
                Section {
                    Button("FMP abrufen") {
                        fmpAbrufen()
                    }
                    .disabled(befehlInfo == nil || isFetching)
                }
            }
            .navigationTitle("FMP Test: \(aktie.bezeichnung)")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Schließen") { dismiss() }
                }
            }
        }
    }
    
    private func fmpAbrufen() {
        guard befehlInfo != nil else { return }
        isFetching = true
        fmpResult = nil
        fmpError = nil
        Task {
            if var info = await KurszielService.fetchKurszielFromFMP(for: aktie) {
                info = await KurszielService.kurszielInfoZuEUR(info: info, aktie: aktie)
                await MainActor.run {
                    fmpResult = info
                    isFetching = false
                }
            } else {
                await MainActor.run {
                    fmpError = "Kein Kursziel von FMP"
                    isFetching = false
                }
            }
        }
    }
}

/// Sheet zum finanzen.net-Abruf testen mit Debug-Ausgabe (pro Aktie auf der Kursziele-Karte)
private struct FinanzenNetTestSheetView: View {
    @Bindable var aktie: Aktie
    var modelContext: ModelContext
    var onRowEdited: ((String) -> Void)?
    @Environment(\.dismiss) private var dismiss
    
    @State private var isFetching = false
    @State private var result: KurszielInfo? = nil
    @State private var errorMsg: String? = nil
    @State private var debugLog: [String] = []
    
    private var urls: [String] {
        KurszielService.finanzenNetBefehlForDisplay(for: aktie)
    }
    
    var body: some View {
        NavigationView {
            Form {
                Section {
                    ForEach(urls, id: \.self) { url in
                        Text(url)
                            .font(.system(.caption, design: .monospaced))
                            .textSelection(.enabled)
                    }
                    if urls.isEmpty {
                        Text("Keine URL (Bezeichnung oder WKN fehlt)")
                            .foregroundColor(.secondary)
                    }
                } header: {
                    Text("finanzen.net URLs")
                } footer: {
                    Text("Slug aus Bezeichnung, dann WKN. Werden nacheinander versucht.")
                }
                
                if isFetching {
                    Section {
                        HStack {
                            ProgressView()
                            Text("finanzen.net wird abgerufen...")
                                .foregroundColor(.secondary)
                        }
                    }
                }
                
                if let info = result {
                    Section {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("Kursziel: \(info.kursziel, specifier: "%.2f") \(info.waehrung ?? "EUR")")
                                .font(.headline)
                            if let abstand = info.spalte4Durchschnitt {
                                Text("Abstand: \(abstand >= 0 ? "+" : "")\(abstand, specifier: "%.1f")%")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                        }
                        Button("Übernehmen") {
                            aktie.kursziel = info.kursziel
                            aktie.kurszielDatum = info.datum
                            aktie.kurszielAbstand = info.spalte4Durchschnitt
                            aktie.kurszielQuelle = KurszielQuelle.finanzenNet.rawValue
                            aktie.kurszielWaehrung = info.waehrung
                            aktie.kurszielHigh = nil
                            aktie.kurszielLow = nil
                            aktie.kurszielAnalysten = nil
                            aktie.kurszielManuellGeaendert = false
                            try? modelContext.save()
                            onRowEdited?(aktie.isin)
                            dismiss()
                        }
                        .buttonStyle(.borderedProminent)
                    } header: {
                        Text("Ergebnis")
                    }
                }
                
                if let err = errorMsg {
                    Section {
                        Text(err)
                            .foregroundColor(.red)
                    } header: {
                        Text("Fehler")
                    }
                }
                
                if !debugLog.isEmpty {
                    Section {
                        ScrollView {
                            VStack(alignment: .leading, spacing: 4) {
                                ForEach(Array(debugLog.enumerated()), id: \.offset) { _, entry in
                                    Text(entry)
                                        .font(.system(.caption, design: .monospaced))
                                        .foregroundColor(entry.contains("✅") ? .green : (entry.contains("❌") ? .red : .secondary))
                                }
                            }
                        }
                        .frame(maxHeight: 300)
                    } header: {
                        Text("Debug-Log")
                    }
                }
                
                Section {
                    Button("finanzen.net abrufen") {
                        finanzenNetAbrufen()
                    }
                    .disabled(urls.isEmpty || isFetching)
                }
            }
            .navigationTitle("finanzen.net Test: \(aktie.bezeichnung)")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Schließen") { dismiss() }
                }
            }
        }
    }
    
    private func finanzenNetAbrufen() {
        guard !urls.isEmpty else { return }
        isFetching = true
        result = nil
        errorMsg = nil
        debugLog = []
        Task {
            if var info = await KurszielService.fetchKurszielFromFinanzenNet(for: aktie) {
                info = await KurszielService.kurszielInfoZuEUR(info: info, aktie: aktie)
                await MainActor.run {
                    result = info
                    debugLog = KurszielService.getDebugLog()
                    isFetching = false
                }
            } else {
                await MainActor.run {
                    errorMsg = "Kein Kursziel von finanzen.net"
                    debugLog = KurszielService.getDebugLog()
                    isFetching = false
                }
            }
        }
    }
}

/// Sheet zum Snippet-Abruf testen (DuckDuckGo) – nur für Fonds
private struct SnippetTestSheetView: View {
    @Bindable var aktie: Aktie
    var modelContext: ModelContext
    var onRowEdited: ((String) -> Void)?
    @Environment(\.dismiss) private var dismiss
    
    @State private var isFetching = false
    @State private var result: KurszielInfo? = nil
    @State private var errorMsg: String? = nil
    @State private var debugLog: [String] = []
    
    private var searchURL: URL? { KurszielService.snippetSuchergebnisURL(for: aktie) }
    
    var body: some View {
        NavigationView {
            Form {
                Section {
                    if let url = searchURL {
                        Text(url.absoluteString)
                            .font(.system(.caption, design: .monospaced))
                            .textSelection(.enabled)
                        Button("Suchergebnis öffnen") {
                            #if os(iOS)
                            UIApplication.shared.open(url)
                            #elseif os(macOS)
                            NSWorkspace.shared.open(url)
                            #endif
                        }
                    }
                } header: {
                    Text("DuckDuckGo-Suche")
                } footer: {
                    Text("Erster Betrag mit €, $ oder EUR aus den Snippets wird als Kursziel vorgeschlagen.")
                }
                
                if isFetching {
                    Section {
                        HStack {
                            ProgressView()
                            Text("Snippet wird abgerufen...")
                                .foregroundColor(.secondary)
                        }
                    }
                }
                
                if let info = result {
                    Section {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("Kursziel: \(info.kursziel, specifier: "%.2f") \(info.waehrung ?? "EUR")")
                                .font(.headline)
                        }
                        Button("Übernehmen") {
                            aktie.kursziel = info.kursziel
                            aktie.kurszielDatum = info.datum
                            aktie.kurszielAbstand = nil
                            aktie.kurszielQuelle = KurszielQuelle.suchmaschine.rawValue
                            aktie.kurszielWaehrung = info.waehrung
                            aktie.kurszielHigh = nil
                            aktie.kurszielLow = nil
                            aktie.kurszielAnalysten = nil
                            aktie.kurszielManuellGeaendert = false
                            try? modelContext.save()
                            onRowEdited?(aktie.isin)
                            dismiss()
                        }
                        .buttonStyle(.borderedProminent)
                    } header: {
                        Text("Ergebnis")
                    }
                }
                
                if let err = errorMsg {
                    Section {
                        Text(err)
                            .foregroundColor(.red)
                    } header: {
                        Text("Fehler")
                    }
                }
                
                if !debugLog.isEmpty {
                    Section {
                        ScrollView {
                            VStack(alignment: .leading, spacing: 4) {
                                ForEach(Array(debugLog.enumerated()), id: \.offset) { _, entry in
                                    Text(entry)
                                        .font(.system(.caption, design: .monospaced))
                                        .foregroundColor(entry.contains("✅") ? .green : (entry.contains("❌") ? .red : .secondary))
                                }
                            }
                        }
                        .frame(maxHeight: 300)
                    } header: {
                        Text("Debug-Log")
                    }
                }
                
                Section {
                    Button("Snippet abrufen") {
                        snippetAbrufen()
                    }
                    .disabled(isFetching)
                }
            }
            .navigationTitle("Snippet Test: \(aktie.bezeichnung)")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Schließen") { dismiss() }
                }
            }
        }
    }
    
    private func snippetAbrufen() {
        isFetching = true
        result = nil
        errorMsg = nil
        debugLog = []
        Task {
            if var info = await KurszielService.fetchKurszielFromSnippet(for: aktie) {
                info = await KurszielService.kurszielInfoZuEUR(info: info, aktie: aktie)
                await MainActor.run {
                    result = info
                    debugLog = KurszielService.getDebugLog()
                    isFetching = false
                }
            } else {
                await MainActor.run {
                    errorMsg = "Kein Betrag im Suchergebnis gefunden"
                    debugLog = KurszielService.getDebugLog()
                    isFetching = false
                }
            }
        }
    }
}

private let defaultRechtlichesText = """
Programm-technische Beschreibung

Diese App dient der Verwaltung von Wertpapierpositionen (Aktien, Fonds, ETFs) und der Ermittlung von Kurszielen.

Funktionen: CSV-Import von Portfolio-Daten; Abgleich nach Bankleistungsnummer und WKN/ISIN; Ermittlung von Kurszielen über verschiedene Quellen (finanzen.net, Financial Modeling Prep, OpenAI, Yahoo, Suchmaschinen-Snippet); Anzeige von Verlauf und Kennzahlen; Speicherung lokal (SwiftData).

Datenquellen: Kursziele werden je nach Konfiguration von Drittanbietern abgerufen. Es wird keine Gewähr für Richtigkeit oder Verfügbarkeit übernommen. Nutzung auf eigenes Risiko.

Rechtliches: Keine Haftung für Schäden aus der Nutzung. Alle Angaben ohne Gewähr.
"""

struct RechtlichesSheetView: View {
    @Environment(\.dismiss) private var dismiss
    @AppStorage("RechtlichesText") private var rechtlichesText = ""
    @AppStorage("Entwicklermodus") private var entwicklermodus = false
    @State private var editableText = ""
    @State private var hasLoaded = false
    
    private var displayText: String {
        rechtlichesText.isEmpty ? defaultRechtlichesText : rechtlichesText
    }
    
    @ViewBuilder
    private var rechtlichesLinks: some View {
        VStack(alignment: .leading, spacing: 12) {
            Link(destination: URL(string: "https://kisoft4you.com/impressum")!) {
                HStack {
                    Label("Impressum", systemImage: "doc.text.fill")
                    Spacer()
                    Image(systemName: "arrow.up.right.square")
                        .font(.caption)
                }
            }
            Link(destination: URL(string: "https://kisoft4you.com/datenschutzerklaerung")!) {
                HStack {
                    Label("Datenschutz", systemImage: "lock.shield.fill")
                    Spacer()
                    Image(systemName: "arrow.up.right.square")
                        .font(.caption)
                }
            }
            Link(destination: URL(string: "https://kisoft4you.com/agb")!) {
                HStack {
                    Label("AGB", systemImage: "list.clipboard.fill")
                    Spacer()
                    Image(systemName: "arrow.up.right.square")
                        .font(.caption)
                }
            }
        }
        .padding(.horizontal)
        .padding(.vertical, 12)
    }
    
    var body: some View {
        NavigationStack {
            Group {
                if entwicklermodus {
                    VStack(spacing: 0) {
                        TextEditor(text: $editableText)
                            .font(.body)
                            .padding(.horizontal, 4)
                            .onAppear {
                                if !hasLoaded {
                                    editableText = rechtlichesText.isEmpty ? defaultRechtlichesText : rechtlichesText
                                    hasLoaded = true
                                }
                            }
                        rechtlichesLinks
                    }
                } else {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 20) {
                            Text(displayText)
                                .font(.body)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .textSelection(.enabled)
                            rechtlichesLinks
                        }
                        .padding()
                    }
                }
            }
            .navigationTitle("Rechtliches")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Schließen") {
                        dismiss()
                    }
                }
                if entwicklermodus {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Speichern") {
                            rechtlichesText = editableText
                            dismiss()
                        }
                    }
                }
            }
        }
        .onAppear {
            if entwicklermodus && !hasLoaded {
                editableText = rechtlichesText.isEmpty ? defaultRechtlichesText : rechtlichesText
                hasLoaded = true
            }
        }
    }
}

struct CSVSpaltenZuordnungView: View {
    @State private var mapping: [String: String] = loadCSVColumnMapping()
    @AppStorage(csvFieldSeparatorUserDefaultsKey) private var fieldSeparator = "auto"
    @AppStorage(csvDecimalSeparatorUserDefaultsKey) private var decimalSeparator = "german"
    @Environment(\.dismiss) private var dismiss
    
    private func binding(for id: String) -> Binding<String> {
        Binding(
            get: { mapping[id] ?? "" },
            set: { newValue in
                var m = mapping
                if newValue.trimmingCharacters(in: .whitespaces).isEmpty {
                    m.removeValue(forKey: id)
                } else {
                    m[id] = newValue.trimmingCharacters(in: .whitespaces)
                }
                mapping = m
            }
        )
    }
    
    var body: some View {
        Form {
            Section {
                Text("Tragen Sie rechts den exakten Spaltennamen aus Ihrer CSV-Datei ein (so wie in der ersten Zeile Ihrer Datei). Links steht die Bedeutung in der App. Nach „Speichern“ wird beim CSV-Import diese Zuordnung verwendet.")
                    .font(.subheadline)
                    .textSelection(.enabled)
            } header: {
                Text("Anleitung")
            }
            Section {
                ForEach(csvSpaltenFields) { field in
                    HStack(alignment: .top, spacing: 12) {
                        Text(field.label)
                            .font(.subheadline)
                            .foregroundColor(field.optional ? .secondary : .primary)
                        Spacer(minLength: 8)
                        TextField("Spaltenname in Ihrer CSV", text: binding(for: field.id))
                            .font(.subheadline)
                            .multilineTextAlignment(.trailing)
                            .autocapitalization(.none)
                            .disableAutocorrection(true)
                    }
                }
            } header: {
                Text("Feld in der App")
            } footer: {
                Text("Basis: Ohne Zuordnung (oder nach „Zurücksetzen“) verwendet die App wie bisher das normale Layout (Deutsche Bank / maxblue). Mindestens Bankleistungsnummer, Bestand, Bezeichnung und WKN sollten Sie zuordnen, sobald Sie eine andere Bank nutzen.")
            }
            Section {
                Picker("Feldtrenner", selection: $fieldSeparator) {
                    Text("Automatisch (; oder , oder Tab)").tag("auto")
                    Text("Semikolon (;)").tag("semicolon")
                    Text("Komma (,)").tag("comma")
                    Text("Tab").tag("tab")
                }
                Picker("Dezimaltrennzeichen", selection: $decimalSeparator) {
                    Text("Deutsch (1.234,56)").tag("german")
                    Text("Englisch (1,234.56)").tag("english")
                }
            } header: {
                Text("Format der CSV-Datei")
            } footer: {
                Text("Feldtrenner: Zeichen zwischen den Spalten. „Automatisch“ erkennt ; oder , oder Tab aus der ersten Zeile. Dezimaltrennzeichen: Komma (deutsch) oder Punkt (englisch) bei Zahlen.")
            }
            Section {
                Button("Zurücksetzen (Standard Deutsche Bank / maxblue)") {
                    mapping = [:]
                }
                .foregroundColor(.orange)
            }
        }
        .navigationTitle("CSV-Spalten zuordnen")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Speichern") {
                    saveCSVColumnMapping(mapping)
                    dismiss()
                }
            }
        }
        .onAppear {
            if mapping.isEmpty {
                mapping = loadCSVColumnMapping()
            }
        }
    }
}

// MARK: - Watchlist
/// Fallback-Bezeichnung für Watchlist, wenn Lookup keine liefert (z. B. „WKN 710000“ oder „ISIN DE000…“).
private func watchlistBezeichnungFallback(wkn: String, isin: String) -> String {
    let w = wkn.trimmingCharacters(in: .whitespaces)
    let i = isin.trimmingCharacters(in: .whitespaces)
    if w.count == 6, w.allSatisfy(\.isNumber) { return "WKN \(w)" }
    if i.count >= 12 { return "ISIN \(i)" }
    if !w.isEmpty { return "WKN \(w)" }
    if !i.isEmpty { return "ISIN \(i)" }
    return "Watchlist"
}

struct WatchlistView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    @Query(sort: [SortDescriptor<Aktie>(\.bezeichnung)]) private var alleAktien: [Aktie]
    @State private var isinWknEingabe = ""
    @State private var lookupResult: KurszielService.WatchlistLookupResult?
    @State private var isLookingUp = false
    @State private var bearbeiteterKurs: String = ""
    @State private var bearbeitetesKursziel: String = ""
    /// ISIN der Aktie, für die gerade „Bezeichnung ermitteln“ läuft (in der Liste)
    @State private var aktualisiereAktieId: String?
    
    private var watchlistAktien: [Aktie] {
        alleAktien.filter { $0.isWatchlist }
    }
    
    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("ISIN oder WKN", text: $isinWknEingabe)
                        .textContentType(.none)
                        .autocapitalization(.allCharacters)
                        .disableAutocorrection(true)
                    Button {
                        Task { await ermitteln() }
                    } label: {
                        HStack {
                            Text("Bezeichnung, Kurs und Kursziel ermitteln")
                            if isLookingUp {
                                Spacer()
                                ProgressView()
                                    .scaleEffect(0.9)
                            }
                        }
                    }
                    .disabled(isinWknEingabe.trimmingCharacters(in: .whitespaces).isEmpty || isLookingUp)
                } header: {
                    Text("Neuer Eintrag")
                }
                if let r = lookupResult {
                    Section {
                        LabeledContent("Bezeichnung", value: r.bezeichnung)
                        if let k = r.kurs {
                            LabeledContent("Kurs", value: String(format: "%.2f €", k))
                        } else {
                            TextField("Kurs (optional)", text: $bearbeiteterKurs)
                                .keyboardType(.decimalPad)
                        }
                        if let kz = r.kursziel {
                            LabeledContent("Kursziel", value: String(format: "%.2f €", kz))
                        } else {
                            TextField("Kursziel (optional)", text: $bearbeitetesKursziel)
                                .keyboardType(.decimalPad)
                        }
                        Button("Zur Watchlist hinzufügen") {
                            zurWatchlistHinzufuegen(result: r)
                            lookupResult = nil
                            isinWknEingabe = ""
                            bearbeiteterKurs = ""
                            bearbeitetesKursziel = ""
                        }
                    } header: {
                        Text("Ergebnis")
                    }
                }
                Section {
                    ForEach(watchlistAktien) { aktie in
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(aktie.bezeichnung)
                                    .font(.headline)
                                Text(aktie.isin.isEmpty ? aktie.wkn : aktie.isin)
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                                if let k = aktie.kurs ?? aktie.devisenkurs, let kz = aktie.kursziel {
                                    Text("Kurs \(String(format: "%.2f", k)) € · Kursziel \(String(format: "%.2f", kz)) €")
                                        .font(.caption2)
                                        .foregroundColor(.secondary)
                                }
                            }
                            Spacer()
                            if aktualisiereAktieId == (aktie.isin.isEmpty ? aktie.wkn : aktie.isin) {
                                ProgressView()
                                    .scaleEffect(0.8)
                            }
                        }
                        .contextMenu {
                            Button {
                                Task { await bezeichnungErmittelnFuer(aktie: aktie) }
                            } label: {
                                Label("Bezeichnung & Kurs aktualisieren", systemImage: "arrow.clockwise")
                            }
                            .disabled(aktie.isin.trimmingCharacters(in: .whitespaces).isEmpty && aktie.wkn.trimmingCharacters(in: .whitespaces).isEmpty)
                        }
                    }
                    .onDelete(perform: deleteWatchlistItems)
                } header: {
                    Text("Watchlist (\(watchlistAktien.count))")
                } footer: {
                    Text("Einträge erscheinen in der Aktien-Liste unter Bankleistungsnummer 999999 mit Kennzeichnung „Watchlist“ und werden bei der normalen CSV-Einlesung aktualisiert.")
                }
            }
            .navigationTitle("Watchlist")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Schließen") { dismiss() }
                }
            }
        }
        .onAppear {
            if let r = lookupResult {
                if r.kurs == nil, bearbeiteterKurs.isEmpty { bearbeiteterKurs = "" }
                if r.kursziel == nil, bearbeitetesKursziel.isEmpty { bearbeitetesKursziel = "" }
            }
        }
    }
    
    private func ermitteln() async {
        let term = isinWknEingabe.trimmingCharacters(in: .whitespaces)
        guard !term.isEmpty else { return }
        isLookingUp = true
        defer { isLookingUp = false }
        let result = await KurszielService.lookupWatchlist(searchTerm: term)
        await MainActor.run {
            lookupResult = result
            if let r = result {
                bearbeiteterKurs = r.kurs.map { String(format: "%.2f", $0) } ?? ""
                bearbeitetesKursziel = r.kursziel.map { String(format: "%.2f", $0) } ?? ""
            }
        }
    }
    
    /// Bezeichnung, Kurs und Kursziel für einen bestehenden Watchlist-Eintrag ermitteln und speichern.
    private func bezeichnungErmittelnFuer(aktie: Aktie) async {
        let term = (aktie.isin.trimmingCharacters(in: .whitespaces).isEmpty ? aktie.wkn : aktie.isin).trimmingCharacters(in: .whitespaces)
        guard !term.isEmpty else { return }
        let id = aktie.isin.isEmpty ? aktie.wkn : aktie.isin
        await MainActor.run { aktualisiereAktieId = id }
        let result = await KurszielService.lookupWatchlist(searchTerm: term)
        await MainActor.run {
            aktualisiereAktieId = nil
            guard let r = result else { return }
            let neueBez = r.bezeichnung.trimmingCharacters(in: .whitespaces)
            if !neueBez.isEmpty {
                aktie.bezeichnung = neueBez
            } else if aktie.bezeichnung.trimmingCharacters(in: .whitespaces).isEmpty || aktie.bezeichnung == aktie.wkn || aktie.bezeichnung == aktie.isin {
                aktie.bezeichnung = watchlistBezeichnungFallback(wkn: aktie.wkn, isin: aktie.isin)
            }
            if !r.wkn.trimmingCharacters(in: .whitespaces).isEmpty { aktie.wkn = r.wkn }
            if !r.isin.trimmingCharacters(in: .whitespaces).isEmpty { aktie.isin = r.isin }
            if let k = r.kurs { aktie.kurs = k }
            if let kz = r.kursziel {
                aktie.kursziel = kz
                aktie.kurszielQuelle = "F"
                aktie.kurszielWaehrung = "EUR"
            }
            try? modelContext.save()
        }
    }
    
    private func zurWatchlistHinzufuegen(result: KurszielService.WatchlistLookupResult) {
        let kurs: Double? = Double(bearbeiteterKurs.replacingOccurrences(of: ",", with: ".")) ?? result.kurs
        let kursziel: Double? = Double(bearbeitetesKursziel.replacingOccurrences(of: ",", with: ".")) ?? result.kursziel
        let wkn = result.wkn.trimmingCharacters(in: .whitespaces)
        let isin = result.isin.trimmingCharacters(in: .whitespaces)
        let bez = result.bezeichnung.trimmingCharacters(in: .whitespaces).isEmpty
            ? watchlistBezeichnungFallback(wkn: wkn, isin: isin)
            : result.bezeichnung
        let a = Aktie(
            bankleistungsnummer: watchlistBankleistungsnummer,
            bestand: 0,
            bezeichnung: bez,
            wkn: wkn.isEmpty ? isin : wkn,
            isin: isin.isEmpty ? wkn : isin,
            waehrung: "EUR",
            hinweisEinstandskurs: "",
            einstandskurs: nil,
            deviseneinstandskurs: nil,
            kurs: kurs,
            devisenkurs: nil,
            gewinnVerlustEUR: nil,
            gewinnVerlustProzent: nil,
            marktwertEUR: nil,
            stueckzinsenEUR: nil,
            anteilProzent: nil,
            datumLetzteBewegung: nil,
            gattung: "Aktie",
            branche: "-",
            risikoklasse: "-",
            depotPortfolioName: "Watchlist",
            kursziel: kursziel,
            kurszielQuelle: kursziel != nil ? "F" : nil,
            kurszielWaehrung: kursziel != nil ? "EUR" : nil,
            isWatchlist: true
        )
        modelContext.insert(a)
        try? modelContext.save()
    }
    
    private func deleteWatchlistItems(offsets: IndexSet) {
        withAnimation {
            for i in offsets {
                if i < watchlistAktien.count {
                    modelContext.delete(watchlistAktien[i])
                }
            }
            try? modelContext.save()
        }
    }
}

struct DebugLogSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var logEntries: [String] = []
    
    private func refreshLog() {
        logEntries = KurszielService.getDebugLog()
    }
    
    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                Button(action: refreshLog) {
                    Label("Aktualisieren", systemImage: "arrow.clockwise")
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                }
                .buttonStyle(.borderedProminent)
                .tint(.blue)
                .padding(.horizontal, 16)
                .padding(.top, 16)
                .padding(.bottom, 12)
                
                Rectangle()
                    .fill(Color.gray.opacity(0.3))
                    .frame(height: 1)
                
                if logEntries.isEmpty {
                    Spacer()
                    Text("Kein Eintrag.")
                        .font(.headline)
                    Text("Zuerst z. B. „finanzen.net abrufen“ (bei einer Aktie) ausführen, dann hier „Aktualisieren“ tippen.")
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 24)
                        .padding(.top, 8)
                    Spacer()
                } else {
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 4) {
                            ForEach(Array(logEntries.enumerated()), id: \.offset) { _, entry in
                                Text(entry)
                                    .font(.system(.caption, design: .monospaced))
                                    .foregroundColor(entry.contains("FMP") || entry.contains("━━━") || entry.contains("💱") ? .primary : .secondary)
                            }
                        }
                        .padding()
                    }
                }
            }
            .navigationTitle("Debug-Log")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Schließen") { dismiss() }
                }
            }
            .onAppear {
                refreshLog()
            }
        }
    }
}

private enum WKNTestQuelle: String, CaseIterable {
    case finanzenNet = "Finanzen.net"
    case fmp = "FMP"
    case openAI = "OpenAI"
}

struct WKNTesterView: View {
    @Binding var wkn: String
    @Binding var result: String?
    @Binding var isTesting: Bool
    var urlFromSettings: String = ""
    var openAIFromSettings: String = ""
    @State private var debugLog: [String] = []
    @State private var selectedTestQuelle: WKNTestQuelle = .finanzenNet
    @State private var openAITestBefehl = "Gib mir das aktuelle Datum zurück"
    @Environment(\.dismiss) private var dismiss
    
    private static let openAIResponsesURL = "https://api.openai.com/v1/responses"
    private static let openAIChatURL = "https://api.openai.com/v1/chat/completions"
    
    /// Klartext des Befehls (OpenAI-Prompt oder URL mit maskiertem Key) – nur für FMP/finanzen.net
    private var befehlKlartext: String {
        let raw = wkn.trimmingCharacters(in: .whitespaces)
        if raw.contains("financialmodelingprep.com") {
            if let range = raw.range(of: "apikey=") {
                let nachKey = raw[range.upperBound...]
                let rest = nachKey.contains("&") ? String(nachKey[nachKey.firstIndex(of: "&")!...].dropFirst()) : ""
                let prefix = String(raw[..<range.upperBound])
                return prefix + "***" + (rest.isEmpty ? "" : "&" + rest)
            }
            return raw
        }
        if raw.contains("finanzen.net") || raw.hasPrefix("http://") || raw.hasPrefix("https://") {
            return raw
        }
        let wknOnly = raw
            .replacingOccurrences(of: "https://", with: "")
            .replacingOccurrences(of: "http://", with: "")
            .trimmingCharacters(in: .whitespaces)
        return "kursziel (nur wert) wkn \(wknOnly.isEmpty ? raw : wknOnly) in EUR."
    }
    
    private static func preset(for quelle: WKNTestQuelle, fmpUrlFromSettings: String) -> String {
        switch quelle {
        case .finanzenNet:
            return "https://www.finanzen.net/kursziele/rheinmetall"
        case .fmp:
            let url = fmpUrlFromSettings.trimmingCharacters(in: .whitespaces)
            if !url.isEmpty { return url }
            return "https://financialmodelingprep.com/stable/price-target-consensus?symbol=AAPL&apikey=DEIN_KEY"
        case .openAI:
            return "716460"
        }
    }
    
    /// Binding ohne Auto-https – WKN (z.B. 716460) bleibt unverändert, URLs werden direkt übernommen
    private var displayWKN: Binding<String> {
        Binding(get: { wkn }, set: { wkn = $0 })
    }
    
    var body: some View {
        NavigationView {
            Form {
                Section {
                    Picker("Quelle", selection: $selectedTestQuelle) {
                        ForEach(WKNTestQuelle.allCases, id: \.self) { q in
                            Text(q.rawValue).tag(q)
                        }
                    }
                    .pickerStyle(.segmented)
                    .onChange(of: selectedTestQuelle) { _, newValue in
                        wkn = Self.preset(for: newValue, fmpUrlFromSettings: urlFromSettings)
                        result = nil
                        debugLog = []
                        KurszielService.clearDebugLog()
                    }
                } header: {
                    Text("Test-URL / Quelle")
                } footer: {
                    Text("Finanzen.net: Beispiel-URL. FMP: API-URL aus Einstellungen. OpenAI: Genereller API-Test (z.B. Datum zurückgeben), Link zum Kopieren.")
                }
                
                if selectedTestQuelle == .openAI {
                    // OpenAI: Nur genereller API-Test – Befehl, Link, curl-Syntax, Test
                    Section {
                        Text("\(Self.openAIResponsesURL)\n(bzw. \(Self.openAIChatURL) bei Fallback)")
                            .font(.system(.caption, design: .monospaced))
                            .textSelection(.enabled)
                        Divider()
                        Text("curl -X POST \(Self.openAIChatURL) \\\n  -H \"Authorization: Bearer DEIN_API_KEY\" \\\n  -H \"Content-Type: application/json\" \\\n  -d '{\"model\":\"gpt-4o-mini\",\"messages\":[{\"role\":\"user\",\"content\":\"Gib das heutige Datum\"}]}'")
                            .font(.system(.caption2, design: .monospaced))
                            .textSelection(.enabled)
                    } header: {
                        Text("API-Link & curl-Syntax")
                    } footer: {
                        Text("Key steht nicht in der URL, sondern im Header. curl: DEIN_API_KEY durch echten Key ersetzen.")
                    }
                    
                    Section {
                        TextField("Befehl (Klartext)", text: $openAITestBefehl, axis: .vertical)
                            .lineLimit(2...4)
                            .textContentType(.none)
                    } header: {
                        Text("Befehl")
                    } footer: {
                        Text("z.B. „Gib mir das aktuelle Datum zurück“ – nur ein Rückgabewert. Befehl anpassen, dann testen.")
                    }
                    
                    if isTesting {
                        Section {
                            HStack {
                                ProgressView()
                                Text("Test wird ausgeführt...")
                                    .foregroundColor(.secondary)
                            }
                        }
                    }
                    
                    if let result = result {
                        Section {
                            Text(result)
                                .foregroundColor(result.contains("Fehler") ? .red : .primary)
                                .textSelection(.enabled)
                        } header: {
                            Text("Ergebnis")
                        }
                    }
                    
                    if !debugLog.isEmpty {
                        Section {
                            ScrollView {
                                VStack(alignment: .leading, spacing: 4) {
                                    ForEach(debugLog, id: \.self) { logEntry in
                                        Text(logEntry)
                                            .font(.system(.caption, design: .monospaced))
                                            .foregroundColor(.secondary)
                                    }
                                }
                            }
                            .frame(maxHeight: 300)
                        } header: {
                            Text("Debug")
                        }
                    }
                    
                    Section {
                        Button("Verbindung testen") {
                            testOpenAI()
                        }
                        .disabled(openAITestBefehl.trimmingCharacters(in: .whitespaces).isEmpty || isTesting)
                    }
                } else {
                    // finanzen.net / FMP: URL oder WKN, Kursziel abrufen
                    Section {
                        TextField("URL oder WKN eingeben", text: displayWKN)
                            .keyboardType(.default)
                            .autocapitalization(.none)
                            .autocorrectionDisabled()
                        if !urlFromSettings.trimmingCharacters(in: .whitespaces).isEmpty || !openAIFromSettings.trimmingCharacters(in: .whitespaces).isEmpty {
                            Button("Aus Einstellungen einfügen") {
                                switch selectedTestQuelle {
                                case .openAI:
                                    break
                                case .fmp:
                                    wkn = urlFromSettings.trimmingCharacters(in: .whitespaces).isEmpty
                                        ? Self.preset(for: .fmp, fmpUrlFromSettings: urlFromSettings)
                                        : urlFromSettings.trimmingCharacters(in: .whitespaces)
                                case .finanzenNet:
                                    wkn = Self.preset(for: .finanzenNet, fmpUrlFromSettings: urlFromSettings)
                                }
                                result = nil
                                debugLog = []
                                KurszielService.clearDebugLog()
                            }
                        }
                    } header: {
                        Text("WKN oder URL")
                    } footer: {
                        Text("FMP: Kursziel-API-URL aus Einstellungen. Mit „Aus Einstellungen einfügen“ wird der passende Wert gesetzt.")
                    }
                    
                    if !wkn.isEmpty && wkn != "https://" {
                        Section {
                            Text(befehlKlartext)
                                .font(.system(.caption, design: .monospaced))
                                .textSelection(.enabled)
                        } header: {
                            Text("Befehl (Klartext)")
                        } footer: {
                            Text("Verwendete URL (API-Key maskiert).")
                        }
                    }
                    
                    if isTesting {
                        Section {
                            HStack {
                                ProgressView()
                                Text("Kursziel wird abgerufen...")
                                    .foregroundColor(.secondary)
                            }
                        }
                    }
                    
                    if let result = result {
                        Section {
                            Text(result)
                                .foregroundColor(result.contains("Fehler") ? .red : .primary)
                                .textSelection(.enabled)
                        } header: {
                            Text("Ergebnis")
                        }
                    }
                    
                    if !debugLog.isEmpty {
                        Section {
                            ScrollView {
                                VStack(alignment: .leading, spacing: 4) {
                                    ForEach(debugLog, id: \.self) { logEntry in
                                        Text(logEntry)
                                            .font(.system(.caption, design: .monospaced))
                                            .foregroundColor(.secondary)
                                    }
                                }
                            }
                            .frame(maxHeight: 300)
                        } header: {
                            Text("Debug")
                        }
                    }
                    
                    Section {
                        Button("Kursziel abrufen") {
                            testKursziel()
                        }
                        .disabled(wkn.isEmpty || wkn == "https://" || isTesting)
                    }
                }
            }
            .onAppear {
                if wkn.contains("financialmodelingprep") { selectedTestQuelle = .fmp }
                else if wkn.contains("finanzen.net") { selectedTestQuelle = .finanzenNet }
                else if !wkn.isEmpty { selectedTestQuelle = .openAI }
            }
            .navigationTitle("WKN Testen")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Schließen") {
                        dismiss()
                    }
                }
            }
        }
    }
    
    private func testOpenAI() {
        let befehl = openAITestBefehl.trimmingCharacters(in: .whitespaces)
        guard !befehl.isEmpty, !openAIFromSettings.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        KurszielService.openAIAPIKey = openAIFromSettings.trimmingCharacters(in: .whitespaces)
        isTesting = true
        result = nil
        debugLog = []
        Task {
            let testResult = await KurszielService.testOpenAIVerbindung(prompt: befehl)
            await MainActor.run {
                result = testResult
                debugLog = KurszielService.getDebugLog()
                isTesting = false
            }
        }
    }
    
    private func testKursziel() {
        guard !wkn.isEmpty && wkn != "https://" else { return }
        isTesting = true
        result = nil
        debugLog = []
        
        Task {
            var wknCleaned = wkn.trimmingCharacters(in: .whitespaces)
            if wknCleaned.isEmpty || wknCleaned == "https://" {
                await MainActor.run { isTesting = false }
                return
            }
            KurszielService.clearDebugLog()
            
            if let info = await KurszielService.fetchKurszielByWKN(wknCleaned) {
                await MainActor.run {
                    let formatter = NumberFormatter()
                    formatter.numberStyle = .decimal
                    formatter.minimumFractionDigits = 2
                    formatter.maximumFractionDigits = 2
                    let kurszielString = formatter.string(from: NSNumber(value: info.kursziel)) ?? String(format: "%.2f", info.kursziel)
                    let waehrungAnzeige = (info.waehrung ?? "EUR") == "USD" ? "USD" : "EUR"
                    var resultText = "Kursziel gefunden: \(kurszielString) \(waehrungAnzeige) \(info.quelle.rawValue)"
                    if let sp4 = info.spalte4Durchschnitt {
                        let sp4String = formatter.string(from: NSNumber(value: sp4)) ?? String(format: "%.2f", sp4)
                        resultText += " | Spalte 4: \(sp4String)"
                    } else {
                        resultText += " | Spalte 4: –"
                    }
                    result = resultText
                    debugLog = KurszielService.getDebugLog()
                    isTesting = false
                }
            } else {
                await MainActor.run {
                    result = "Fehler: Kein Kursziel für WKN \(wknCleaned) gefunden"
                    debugLog = KurszielService.getDebugLog()
                    isTesting = false
                }
            }
        }
    }
}

struct SettingsView: View {
    @Binding var openAIAPIKey: String
    @Binding var fmpAPIKey: String
    @AppStorage("ForceOverwriteAllKursziele") private var forceOverwriteAllKursziele = false
    @AppStorage("Entwicklermodus") private var entwicklermodus = false
    @Environment(\.dismiss) private var dismiss
    @State private var showFilePicker = false
    @State private var keyImportMessage: String? = nil
    @State private var showKeyImportAlert = false
    @State private var isTestingConnection = false
    @State private var connectionTestResult: String? = nil
    @State private var showConnectionTestAlert = false
    @State private var showDebugFromConnectionTest = false
    @State private var openAITestBefehl = "Gib mir das aktuelle Datum zurück"
    @State private var isTestingFMP = false
    @State private var fmpTestResult: String? = nil
    @State private var showFMPTestAlert = false
    @State private var isTestingFMPAPIs = false
    @State private var fmpAPIsTestResult: String? = nil
    @State private var showFMPAPIsTestAlert = false
    
    var body: some View {
        NavigationStack {
            Form {
                Section {
                    EmptyView()
                } header: {
                    Text("Kursziel-Quellen (Basis)")
                } footer: {
                    Text("Optionale API-URL unten eintragen (FMP oder OpenAI). Der Nutzer muss sich einen passenden API-Schlüssel beim Anbieter besorgen und diesen in die komplette URL einsetzen (Varianten: per ISIN, Kürzel oder Kennung).\n\nWenn keine URL/Key eingetragen wird: Kursziele werden über finanzen.net, ariva.de, Yahoo o. Ä. ermittelt (ggf. ungenauer).\n\nVorschläge FMP:\n• Preisziele (Symbol): https://financialmodelingprep.com/stable/price-target-consensus?symbol=SYMBOL&apikey=KEY\n• Suche ISIN: https://financialmodelingprep.com/stable/search-isin?isin=ISIN&apikey=KEY\n\nOpenAI: API-Key im Abschnitt „OpenAI“ eintragen; die App nutzt ihn für Kursziel-Abfragen. Zusätzlich kann die Portfolio-CSV extern mit OpenAI bearbeitet werden (Kursziele in neue CSV schreiben) und die erzeugte CSV hier importiert werden.\n\nCSV-Import: Enthält die CSV in der letzten Spalte oder in einer Spalte „Kursziel“ bzw. „Kursziel_EUR“ bereits einen Wert, wird keine Ermittlung durchgeführt und dieser Wert übernommen.")
                }
                
                Section {
                    Text("Ermittle bitte auf Grund der WKN oder der ISIN ein durchschnittliches Kursziel in EUR für jede Zeile und stelle diesen in ein neues Kursziel-Feld – bitte hinten anfügen – bitte neue Datei erzeugen.")
                        .font(.subheadline)
                        .textSelection(.enabled)
                    Button("Prompt kopieren") {
                        UIPasteboard.general.string = "Ermittle bitte auf Grund der WKN oder der ISIN ein durchschnittliches Kursziel in EUR für jede Zeile und stelle diesen in ein neues Kursziel-Feld – bitte hinten anfügen – bitte neue Datei erzeugen."
                    }
                } header: {
                    Text("Kursziele aus CSV")
                } footer: {
                    Text("Beim Einlesen wird die CSV-Datei ausgewählt. Enthält sie in der letzten Spalte oder in „Kursziel“/„Kursziel Ø“/„Kursziel_EUR“ einen Wert, wird dieser übernommen (keine Ermittlung).\n\nNach Hochladen der CSV-Datei (z. B. in ChatGPT oder eine andere KI/DB): obigen Prompt eingeben bzw. kopieren. Die erzeugte neue CSV mit der Kursziel-Spalte hinten hier in der App importieren.")
                }
                
                Section {
                    NavigationLink("Spalten anderer Banken zuordnen") {
                        CSVSpaltenZuordnungView()
                    }
                } header: {
                    Text("CSV-Import")
                } footer: {
                    Text("Basis: Wenn nichts eingetragen bzw. keine Zuordnung gespeichert ist, bleibt das normale CSV-Layout wie bisher (Deutsche Bank / maxblue). Nur wenn Sie hier eine Zuordnung anlegen und speichern, wird diese beim Import verwendet.")
                }
                
                Section {
                    Toggle("Alle Kursziele überschreiben", isOn: $forceOverwriteAllKursziele)
                } header: {
                    Text("Kursziel-Überschreiben")
                } footer: {
                    Text("Wenn an: Beim nächsten Abruf (z. B. nach CSV-Import oder „Kursziele OpenAI“) werden alle Kursziele neu ermittelt und überschrieben – auch aus CSV oder manuell gesetzte. Wenn aus: Kursziele aus CSV und manuell geänderte werden nicht überschrieben.")
                }
                
                Section {
                    Toggle("Entwicklermodus", isOn: $entwicklermodus)
                } header: {
                    Text("Entwickler")
                } footer: {
                    Text("Wenn an: Der Text unter „Rechtliches“ kann in der App bearbeitet und gespeichert werden.")
                }
                
                Section {
                    SecureField("Kursziel-API-URL (z. B. FMP)", text: $fmpAPIKey)
                        .textContentType(.password)
                        .autocorrectionDisabled()
                    Button(action: { testFMPConnection() }) {
                        HStack {
                            Text("Verbindung testen")
                            if isTestingFMP {
                                Spacer()
                                ProgressView()
                                    .scaleEffect(0.8)
                            }
                        }
                    }
                    .disabled(fmpAPIKey.trimmingCharacters(in: .whitespaces).isEmpty || isTestingFMP)
                    Button(action: { testFMPAlleAPIs() }) {
                        HStack {
                            Text("FMP APIs testen (Debug)")
                            if isTestingFMPAPIs {
                                Spacer()
                                ProgressView()
                                    .scaleEffect(0.8)
                            }
                        }
                    }
                    .disabled(fmpAPIKey.trimmingCharacters(in: .whitespaces).isEmpty || isTestingFMPAPIs)
                } header: {
                    Text("Kursziel-API-URL (FMP o. ä.)")
                } footer: {
                    Text("Komplette URL mit eigenem API-Key einfügen (z. B. price-target-consensus?symbol=SYMBOL&apikey=…). «Verbindung testen» ruft die URL so auf.")
                }
                
                Section {
                    SecureField("OpenAI API-Key", text: $openAIAPIKey)
                        .textContentType(.password)
                        .autocorrectionDisabled()
                    Button("API-Key aus Datei laden…") {
                        showFilePicker = true
                    }
                    TextField("Befehl (Klartext)", text: $openAITestBefehl, axis: .vertical)
                        .lineLimit(2...4)
                        .textContentType(.none)
                    Button(action: { testConnection() }) {
                        HStack {
                            Text("Verbindung testen")
                            if isTestingConnection {
                                Spacer()
                                ProgressView()
                                    .scaleEffect(0.8)
                            }
                        }
                    }
                    .disabled(openAIAPIKey.trimmingCharacters(in: .whitespaces).isEmpty || openAITestBefehl.trimmingCharacters(in: .whitespaces).isEmpty || isTestingConnection)
                } header: {
                    Text("OpenAI")
                } footer: {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("API-Key für Kursziele via OpenAI. «Befehl»: z.B. „Gib mir das aktuelle Datum zurück“ – nur ein Rückgabewert. Befehl anpassen, dann «Verbindung testen». Im Ergebnis wird der komplette Link angezeigt.")
                        Text("Nach der Generierung in OpenAI wird der API-Key zum Kopieren angeboten. Falls das direkte Einfügen in die Einstellung nicht klappt: Key kopieren und in eine E-Mail einfügen (nicht in eine separate Datei). Auf dem iPhone die Mail öffnen und den Key von dort in die Einstellung einfügen – das funktioniert.")
                    }
                }
            }
            .navigationTitle("Einstellungen")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Fertig") { dismiss() }
                }
            }
            .fileImporter(
                isPresented: $showFilePicker,
                allowedContentTypes: [.plainText, .text],
                allowsMultipleSelection: false
            ) { result in
                switch result {
                case .success(let urls):
                    guard let url = urls.first else {
                        keyImportMessage = "Keine Datei ausgewählt"
                        showKeyImportAlert = true
                        return
                    }
                    guard url.startAccessingSecurityScopedResource() else {
                        keyImportMessage = "Kein Zugriff auf die Datei"
                        showKeyImportAlert = true
                        return
                    }
                    defer { url.stopAccessingSecurityScopedResource() }
                    do {
                        let data = try Data(contentsOf: url)
                        let raw = String(data: data, encoding: .utf8)
                            ?? String(data: data, encoding: .utf16)
                            ?? ""
                        guard let key = KurszielService.cleanOpenAIKey(raw), !key.isEmpty else {
                            keyImportMessage = "Datei ist leer oder enthält keinen gültigen Text (evtl. unsichtbare Zeichen)"
                            showKeyImportAlert = true
                            return
                        }
                        openAIAPIKey = key
                        keyImportMessage = "API-Key aus Datei geladen"
                        showKeyImportAlert = true
                    } catch {
                        keyImportMessage = "Fehler: \(error.localizedDescription)"
                        showKeyImportAlert = true
                    }
                case .failure(let error):
                    keyImportMessage = "Fehler: \(error.localizedDescription)"
                    showKeyImportAlert = true
                }
            }
            .alert("API-Key", isPresented: $showKeyImportAlert) {
                Button("OK", role: .cancel) { }
            } message: {
                Text(keyImportMessage ?? "")
            }
            .sheet(isPresented: $showConnectionTestAlert) {
                NavigationStack {
                    VStack(alignment: .leading, spacing: 12) {
                        Text(connectionTestResult ?? "")
                            .font(.body)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding()
                        Spacer()
                        Button("Debug-Log anzeigen") {
                            showDebugFromConnectionTest = true
                        }
                        .padding(.horizontal)
                    }
                    .navigationTitle("OpenAI-Verbindungstest")
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        ToolbarItem(placement: .confirmationAction) {
                            Button("Schließen") { showConnectionTestAlert = false }
                        }
                    }
                    .sheet(isPresented: $showDebugFromConnectionTest) {
                        DebugLogSheet()
                    }
                }
            }
            .alert("FMP-Verbindungstest", isPresented: $showFMPTestAlert) {
                Button("OK", role: .cancel) { }
            } message: {
                Text(fmpTestResult ?? "")
            }
            .alert("FMP APIs Test", isPresented: $showFMPAPIsTestAlert) {
                Button("OK", role: .cancel) { }
            } message: {
                Text(fmpAPIsTestResult ?? "")
            }
        }
    }
    
    private func testFMPAlleAPIs() {
        KurszielService.clearCachesForApiCalls()
        guard !fmpAPIKey.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        KurszielService.fmpAPIKey = fmpAPIKey.trimmingCharacters(in: .whitespaces)
        isTestingFMPAPIs = true
        Task {
            let result = await KurszielService.testFMPAlleAPIs()
            await MainActor.run {
                fmpAPIsTestResult = result
                showFMPAPIsTestAlert = true
                isTestingFMPAPIs = false
            }
        }
    }
    
    private func testFMPConnection() {
        KurszielService.clearCachesForApiCalls()
        guard !fmpAPIKey.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        KurszielService.fmpAPIKey = fmpAPIKey.trimmingCharacters(in: .whitespaces)
        isTestingFMP = true
        Task {
            let result = await KurszielService.testFMPVerbindung()
            await MainActor.run {
                fmpTestResult = result
                showFMPTestAlert = true
                isTestingFMP = false
            }
        }
    }
    
    private func testConnection() {
        KurszielService.clearCachesForApiCalls()
        guard !openAIAPIKey.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        KurszielService.openAIAPIKey = openAIAPIKey.trimmingCharacters(in: .whitespaces)
        isTestingConnection = true
        Task {
            let result = await KurszielService.testOpenAIVerbindung(prompt: openAITestBefehl)
            await MainActor.run {
                connectionTestResult = result
                showConnectionTestAlert = true
                isTestingConnection = false
            }
        }
    }
}

#Preview {
    ContentView()
        .modelContainer(for: [Aktie.self, ImportSummary.self, ImportPositionSnapshot.self], inMemory: true)
}
