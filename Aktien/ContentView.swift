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
#if os(iOS)
import QuickLook
import UIKit
extension URL: Identifiable {
    public var id: String { absoluteString }
}
#endif
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

/// Gespeichertes manuelles Kursziel für Wiedereinsetzen nach „Alles löschen“ und erneutem Einlesen (Zuordnung über ISIN/WKN). Von BankStartView für „Alles löschen“ auf der Startseite genutzt.
struct SavedManualKursziel: Codable {
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
let savedManualKurszieleUserDefaultsKey = "SavedManualKursziele"

// MARK: - CSV-Spaltenzuordnung (andere Banken, pro Bank über BankStore)
/// Spaltenbuchstaben wie in Excel: A, B, …, Z, AA, …, AZ (52 Spalten)
private let csvColumnLetterOptions: [String] = {
    var r = [""]
    for i in 0..<52 {
        if i < 26 {
            r.append(String(Character(Unicode.Scalar(65 + i)!)))
        } else {
            r.append("A" + String(Character(Unicode.Scalar(65 + i - 26)!)))
        }
    }
    return r
}()

/// Eine Spalte unserer App für die CSV-Zuordnung (App-Feld → Spalte A, B, C, …)
private struct CSVSpaltenField: Identifiable {
    let id: String
    let label: String
    var optional: Bool { id == "kursziel" || id == "kursziel_quelle" || id == "hinweisEinstandskurs" || id == "branche" || id == "risikoklasse" || id == "depotPortfolioName" }
}

private let csvSpaltenFields: [CSVSpaltenField] = [
    CSVSpaltenField(id: "bankleistungsnummer", label: "Bankleistungsnummer / Depotnummer (ohne Spalte: Fester Wert)"),
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
    CSVSpaltenField(id: "depotPortfolioName", label: "Depot-/Portfolio-Name (z. B. Konto, Neues Konto)"),
    CSVSpaltenField(id: "kursziel", label: "Kursziel (optional)"),
    CSVSpaltenField(id: "kursziel_quelle", label: "Kursziel Quelle (optional)"),
]

/// Beträge einheitlich im deutschen Format anzeigen (z. B. 1.234,56).
private func formatBetragDE(_ value: Double, decimals: Int = 2) -> String {
    let f = NumberFormatter()
    f.locale = Locale(identifier: "de_DE")
    f.numberStyle = .decimal
    f.minimumFractionDigits = decimals
    f.maximumFractionDigits = decimals
    return f.string(from: NSNumber(value: value)) ?? String(format: "%.\(decimals)f", value)
}

/// Für „Fester Wert“-Übernahme: String als Double parsen (deutsches Format).
private func parseDoubleFromFixed(_ s: String) -> Double? {
    let trimmed = s.trimmingCharacters(in: .whitespaces)
    guard !trimmed.isEmpty else { return nil }
    let formatter = NumberFormatter()
    formatter.locale = Locale(identifier: "de_DE")
    formatter.numberStyle = .decimal
    return formatter.number(from: trimmed)?.doubleValue ?? Double(trimmed.replacingOccurrences(of: ",", with: "."))
}

/// Für „Fester Wert“-Übernahme: String als Datum parsen (dd.MM.yyyy).
private func parseDateFromFixed(_ s: String) -> Date? {
    let trimmed = s.trimmingCharacters(in: .whitespaces)
    guard !trimmed.isEmpty else { return nil }
    let formatter = DateFormatter()
    formatter.dateFormat = "dd.MM.yyyy"
    formatter.locale = Locale(identifier: "de_DE")
    return formatter.date(from: trimmed)
}

/// Wendet einen festen Zuordnungswert (Feld-ID + String nach „=“) auf eine Aktie an. Gilt für alle Felder mit „Fester Wert“.
private func applyFixedValueToAktie(_ aktie: Aktie, fieldId: String, fixedValue: String) {
    switch fieldId {
    case "bankleistungsnummer": aktie.bankleistungsnummer = fixedValue
    case "bezeichnung": aktie.bezeichnung = fixedValue
    case "wkn": aktie.wkn = fixedValue
    case "isin": aktie.isin = fixedValue
    case "waehrung": aktie.waehrung = fixedValue.isEmpty ? "EUR" : fixedValue
    case "hinweisEinstandskurs": aktie.hinweisEinstandskurs = fixedValue
    case "gattung": aktie.gattung = fixedValue.isEmpty ? "Aktie" : fixedValue
    case "branche": aktie.branche = fixedValue.isEmpty ? "-" : fixedValue
    case "risikoklasse": aktie.risikoklasse = fixedValue.isEmpty ? "-" : fixedValue
    case "depotPortfolioName": aktie.depotPortfolioName = fixedValue
    case "kursziel_quelle": aktie.kurszielQuelle = fixedValue.isEmpty ? nil : fixedValue
    case "einstandskurs": aktie.einstandskurs = parseDoubleFromFixed(fixedValue)
    case "deviseneinstandskurs": aktie.deviseneinstandskurs = parseDoubleFromFixed(fixedValue)
    case "kurs": aktie.kurs = parseDoubleFromFixed(fixedValue)
    case "devisenkurs": aktie.devisenkurs = parseDoubleFromFixed(fixedValue)
    case "gewinnVerlustEUR": aktie.gewinnVerlustEUR = parseDoubleFromFixed(fixedValue)
    case "gewinnVerlustProzent": aktie.gewinnVerlustProzent = parseDoubleFromFixed(fixedValue)
    case "marktwertEUR": aktie.marktwertEUR = parseDoubleFromFixed(fixedValue)
    case "stueckzinsenEUR": aktie.stueckzinsenEUR = parseDoubleFromFixed(fixedValue)
    case "anteilProzent": aktie.anteilProzent = parseDoubleFromFixed(fixedValue)
    case "kursziel": aktie.kursziel = parseDoubleFromFixed(fixedValue).flatMap { $0 > 0 ? $0 : nil }
    case "datumLetzteBewegung": aktie.datumLetzteBewegung = parseDateFromFixed(fixedValue)
    case "bestand": if let d = parseDoubleFromFixed(fixedValue), d >= 0 { aktie.bestand = d }
    default: break
    }
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
        f.locale = Locale(identifier: "de_DE")
        f.numberStyle = .decimal
        f.minimumFractionDigits = 0
        f.maximumFractionDigits = 2
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

#if os(iOS)
/// Dezimalfeld mit festem „Fertig“-Button über der Tastatur (inputAccessoryView), damit es in Listenzellen zuverlässig erscheint.
private struct StableDecimalFieldWithFertig: View {
    let placeholder: String
    @Binding var value: Double?
    var onCommit: (() -> Void)?
    
    var body: some View {
        DecimalFieldWithAccessoryRepresentable(placeholder: placeholder, value: $value, onCommit: onCommit)
    }
}

private struct DecimalFieldWithAccessoryRepresentable: UIViewRepresentable {
    let placeholder: String
    @Binding var value: Double?
    var onCommit: (() -> Void)?
    
    private static let formatter: NumberFormatter = {
        let f = NumberFormatter()
        f.locale = Locale(identifier: "de_DE")
        f.numberStyle = .decimal
        f.minimumFractionDigits = 0
        f.maximumFractionDigits = 2
        return f
    }()
    
    func makeUIView(context: Context) -> UITextField {
        let field = UITextField()
        context.coordinator.textField = field
        field.placeholder = placeholder
        field.keyboardType = .decimalPad
        field.textAlignment = .right
        field.delegate = context.coordinator
        field.borderStyle = .roundedRect
        field.font = .preferredFont(forTextStyle: .body)
        let bar = UIToolbar()
        bar.sizeToFit()
        let done = UIBarButtonItem(title: "Fertig", style: .done, target: context.coordinator, action: #selector(Coordinator.doneTapped))
        let flex = UIBarButtonItem(barButtonSystemItem: .flexibleSpace, target: nil, action: nil)
        bar.items = [flex, done]
        field.inputAccessoryView = bar
        return field
    }
    
    func updateUIView(_ uiView: UITextField, context: Context) {
        if !uiView.isFirstResponder {
            if let v = value {
                uiView.text = Self.formatter.string(from: NSNumber(value: v))
            } else {
                uiView.text = ""
            }
        }
    }
    
    func makeCoordinator() -> Coordinator {
        Coordinator(value: $value, onCommit: onCommit)
    }
    
    class Coordinator: NSObject, UITextFieldDelegate {
        @Binding var value: Double?
        var onCommit: (() -> Void)?
        weak var textField: UITextField?
        
        init(value: Binding<Double?>, onCommit: (() -> Void)?) {
            _value = value
            self.onCommit = onCommit
        }
        
        @objc func doneTapped() {
            textField?.resignFirstResponder()
        }
        
        func textFieldDidEndEditing(_ textField: UITextField) {
            commit(text: textField.text ?? "")
        }
        
        private func commit(text: String) {
            let cleaned = text
                .replacingOccurrences(of: " ", with: "")
                .trimmingCharacters(in: .whitespaces)
            if cleaned.isEmpty {
                value = nil
            } else if let n = DecimalFieldWithAccessoryRepresentable.formatter.number(from: cleaned)?.doubleValue {
                value = n
            }
            onCommit?()
        }
    }
}
#endif

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
                Text("USD/EUR: \(usdToEur.map { formatBetragDE($0, decimals: 4) } ?? "–")")
                    .font(.caption)
                    .foregroundColor(.secondary)
                Text("GBP/EUR: \(gbpToEur.map { formatBetragDE($0, decimals: 4) } ?? "–")")
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
                            Text("\(formatBetragDE(val, decimals: 0)) €")
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

/// Maximale Anzahl Einlese-Läufe, die gespeichert und in der Statistik angezeigt werden (gesamt, nicht pro BL).
private let maxAnzahlEinlesungen = 20

/// Statistik-Fenster: Einlesestatistik (letzte N Läufe gesamt) + API-Zugriffe (FMP, OpenAI)
private struct StatistikSheetView: View {
    var summaries: [ImportSummary]
    @Binding var showEinlesungenChart: Bool
    /// Bei alreadyConfirmed == true direkt löschen (nach „Wirklich löschen? Ja“); sonst Bestätigung in ContentView anzeigen
    var onDeleteEinlesung: (ImportSummary, _ alreadyConfirmed: Bool) -> Void
    /// Schließt Statistik und öffnet in ContentView den Dialog „Alles löschen?“ (Löschen merken / nicht merken)
    var onRequestDeleteAll: () -> Void
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @State private var summaryToDelete: ImportSummary?
    @State private var showDeleteAllConfirm = false
    
    private var letzteEinlesungen: [ImportSummary] {
        Array(summaries.prefix(maxAnzahlEinlesungen)).sorted(by: { $0.datumAktuelleEinlesung < $1.datumAktuelleEinlesung })
    }
    
    /// Formatierung mit Vorzeichen für Statistik: immer „+1,23“ oder „-1,23“, nie ohne Plus (deutsches Format)
    private static func formatVeränderung(_ value: Double) -> String {
        let vorzeichen = value >= 0 ? "+" : ""
        return vorzeichen + formatBetragDE(value) + " €"
    }
    
    /// Pro Einlesedatum die Summe pro BL und Abweichung zur letzten Einlesung, in der dieselbe BL vorkam (rückwärts suchen, auch wenn dazwischen andere BLs eingelesen wurden)
    private func einlesungenProDatumUndBL() -> [(summary: ImportSummary, zeilen: [(bl: String, wert: Double, abweichung: Double?)])] {
        let sorted = letzteEinlesungen
        var result: [(summary: ImportSummary, zeilen: [(bl: String, wert: Double, abweichung: Double?)])] = []
        /// Pro BL der zuletzt bekannte Wert (aus beliebigem früheren Lauf), damit Abweichung auch bei dazwischenliegenden anderen BL-Läufen stimmt
        var lastKnownPerBL: [String: Double] = [:]
        let trim: (String) -> String = { $0.trimmingCharacters(in: .whitespaces) }
        
        for summary in sorted {
            let snaps: [ImportPositionSnapshot]
            if let runId = summary.importRunId {
                let descriptor = FetchDescriptor<ImportPositionSnapshot>(predicate: #Predicate<ImportPositionSnapshot> { $0.importRunId == runId })
                snaps = (try? modelContext.fetch(descriptor)) ?? []
            } else {
                let einleseDatum = summary.datumAktuelleEinlesung
                let descriptor = FetchDescriptor<ImportPositionSnapshot>(predicate: #Predicate<ImportPositionSnapshot> { $0.importDatum == einleseDatum })
                snaps = (try? modelContext.fetch(descriptor)) ?? []
            }
            var currentPerBL: [String: Double] = [:]
            for s in snaps {
                let bl = trim(s.bankleistungsnummer)
                guard let mw = s.marktwertEUR else { continue }
                currentPerBL[bl, default: 0] += mw
            }
            var zeilen: [(bl: String, wert: Double, abweichung: Double?)] = []
            for (bl, wert) in currentPerBL.sorted(by: { $0.key < $1.key }) {
                let lastKnown = lastKnownPerBL[bl]
                let abw: Double? = lastKnown != nil ? wert - lastKnown! : nil
                zeilen.append((bl.isEmpty ? "—" : bl, wert, abw))
            }
            result.append((summary, zeilen))
            // Nur die in diesem Lauf vorkommenden BLs aktualisieren; andere BLs behalten ihren letzten Wert für spätere Abweichung
            for (bl, wert) in currentPerBL {
                lastKnownPerBL[bl] = wert
            }
        }
        return result
    }
    
    var body: some View {
        NavigationStack {
            List {
                Section("API-Zugriffe (automatischer Kursziel-Durchlauf)") {
                    LabeledContent("FMP (Financial Modeling Prep)", value: "\(KurszielService.zugriffeFMP)")
                    LabeledContent("OpenAI", value: "\(KurszielService.zugriffeOpenAI)")
                }
                Section {
                    if letzteEinlesungen.isEmpty {
                        Text("Keine Einlesungen. Nach CSV-Import erscheinen hier pro Datum und BL die Werte sowie die Abweichung zur letzten Einlesung.")
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                    } else {
                        if showEinlesungenChart {
                            EinlesungenChartView(summaries: letzteEinlesungen)
                                .frame(height: 160)
                                .listRowBackground(Color.clear)
                                .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))
                        }
                        ForEach(Array(einlesungenProDatumUndBL().enumerated()), id: \.element.summary.importDatum) { _, item in
                            let summary = item.summary
                            VStack(alignment: .leading, spacing: 8) {
                                HStack(alignment: .top, spacing: 8) {
                                    VStack(alignment: .leading, spacing: 4) {
                                        Text(summary.datumAktuelleEinlesung.formatted(date: .abbreviated, time: .shortened))
                                            .font(.subheadline)
                                            .fontWeight(.medium)
                                        ForEach(item.zeilen, id: \.bl) { row in
                                            VStack(alignment: .leading, spacing: 2) {
                                                HStack {
                                                    Text("BL \(row.bl)")
                                                        .font(.caption)
                                                        .foregroundColor(.secondary)
                                                    Spacer()
                                                    Text(formatBetragDE(row.wert) + " €")
                                                        .font(.caption)
                                                }
                                                if let abw = row.abweichung {
                                                    Text(Self.formatVeränderung(abw))
                                                        .font(.caption2)
                                                        .foregroundColor(abw >= 0 ? .green : .red)
                                                } else {
                                                    Text("—")
                                                        .font(.caption2)
                                                        .foregroundColor(.secondary)
                                                }
                                            }
                                        }
                                    }
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    Button(role: .destructive) {
                                        summaryToDelete = summary
                                    } label: {
                                        Image(systemName: "trash")
                                            .font(.body)
                                    }
                                    .buttonStyle(.borderless)
                                }
                            }
                            .padding(.vertical, 6)
                        }
                    }
                } header: {
                    Text("Einlesestatistik (letzte \(maxAnzahlEinlesungen))")
                } footer: {
                    if !letzteEinlesungen.isEmpty {
                        Text("Pro Datum/Zeit und BL: Wert der Einlesedatei und Abweichung zur vorherigen Einlesung (gleiche BL).")
                            .font(.caption)
                            .foregroundColor(.secondary)
                        Button(showEinlesungenChart ? "Chart aus" : "Chart") {
                            showEinlesungenChart.toggle()
                        }
                        .font(.caption)
                    }
                }
                Section {
                    Button(role: .destructive) {
                        showDeleteAllConfirm = true
                    } label: {
                        Label("Alles löschen", systemImage: "trash")
                    }
                    Text("Löscht alle Aktien, Einlesungen und Snapshots. Optional: „Löschen und Kursziele merken“ – beim nächsten Import werden gemerkte Kursziele wieder zugeordnet.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                } header: {
                    Text("Daten")
                }
            }
            .navigationTitle("Statistik · \(BankStore.selectedBank.name)")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Schließen") { dismiss() }
                }
            }
            .confirmationDialog("Wirklich löschen?", isPresented: Binding(
                get: { summaryToDelete != nil },
                set: { if !$0 { summaryToDelete = nil } }
            ), presenting: summaryToDelete) { summary in
                Button("Ja", role: .destructive) {
                    onDeleteEinlesung(summary, true)
                    summaryToDelete = nil
                    dismiss()
                }
                Button("Nein", role: .cancel) {
                    summaryToDelete = nil
                }
            } message: { summary in
                Text("Einlesung vom \(summary.datumAktuelleEinlesung.formatted(date: .abbreviated, time: .shortened)) und alle zugehörigen Positionen werden gelöscht.")
            }
            .confirmationDialog("Wirklich löschen?", isPresented: $showDeleteAllConfirm) {
                Button("Ja", role: .destructive) {
                    showDeleteAllConfirm = false
                    onRequestDeleteAll()
                    dismiss()
                }
                Button("Nein", role: .cancel) {
                    showDeleteAllConfirm = false
                }
            } message: {
                Text("Alle Aktien, Einlesungen und Verläufe werden gelöscht. Nach „Ja“ erscheint die Auswahl: mit oder ohne Kursziele merken.")
            }
        }
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
                                            Text(formatBetragDE(kurs))
                                                .font(.system(size: 6))
                                                .foregroundColor(.blue)
                                                .lineLimit(1)
                                                .minimumScaleFactor(0.6)
                                        }
                                        if s.kurs != nil && (s.kursziel != nil || kzEffective != nil) { Spacer(minLength: 0) }
                                        if let kz = kzEffective {
                                            Text(formatBetragDE(kz))
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
    @State private var showDebugLog = false
    @State private var showSettings = false
    @State private var showRechtliches = false
    @State private var showWatchlist = false
    @State private var pendingImportURLs: [URL]? = nil
    @State private var showFingerprintMismatchAlert = false
    /// Für Hinweis im Format-Dialog: Spaltenanzahl dieser Datei vs. gespeichert
    @State private var fingerprintMismatchFileSpalten: String? = nil
    @State private var fingerprintMismatchStoredSpalten: String? = nil
    @AppStorage(KurszielService.openAIAPIKeyKey) private var openAIAPIKeyStore: String = ""
    @AppStorage(KurszielService.fmpAPIKeyKey) private var fmpAPIKeyStore: String = ""
    @AppStorage("ForceOverwriteAllKursziele") private var forceOverwriteAllKursziele = false
    /// Wenn an (nur in Einstellungen sichtbar bei Debug-Build): Beim CSV-Import nur 1 Zeile einlesen und Einlesewerte + Satz Deutsche Bank in die Konsole drucken.
    @AppStorage("DebugEinlesungNurEinSatz") private var debugEinlesungNurEinSatz = false
    @State private var isImportingKurszieleOpenAI = false
    /// Nach CSV-Import: Kurszielermittlung erst starten, wenn der Nutzer den Import-Alert mit OK geschlossen hat (verhindert blockierten OK-Button).
    @State private var pendingKurszielFetchAfterImport = false
    @State private var pendingKurszielForceOverwrite = false
    /// Einlese-Datum der letzten Import-Aktion; nach Kursziel-Fetch Snapshots mit diesem Datum aktualisieren (Kursziel nachtragen).
    @State private var pendingKurszielImportDatum: Date? = nil
    /// Daten liegen vor dem Tagesdatum → nach OK Abfrage anzeigen, ob Kursziele ermittelt werden sollen (zeitaufwendig).
    @State private var showKurszielAbfrageBeiAltemDatum = false
    @State private var showKurszielAbfrageAlert = false
    /// Beim Anzeigen von „Kursziele ermitteln?“: Zusatzhinweis, wenn CSV bereits Kursziele enthielt
    @State private var lastImportHadCSVKursziele = false
    @State private var unrealistischConfirm = UnrealistischConfirmHelper.shared
    /// Bereits eingelesene Datei erneut ausgewählt → „Nochmal? Ja/Nein“
    @State private var showAlreadyImportedConfirm = false
    @State private var alreadyImportedFilenamesForAlert: [String] = []
    @State private var pendingURLsForAlreadyImported: [URL]? = nil
    @State private var alreadyImportedFromStart = false

    /// Filter nach Kursziel-Quelle: Aus = alle, sonst nur die gewählte Quelle. Manuell = von Hand eingegebene/geänderte Kursziele.
    enum KurszielQuelleFilter: String, CaseIterable {
        case aus = "Aus"
        case openAI = "OpenAI"
        case fmp = "FMP"
        case csv = "CSV"
        case manuell = "Manuell"
    }
    @State private var kurszielQuelleFilter: KurszielQuelleFilter = .aus
    @State private var filterNurUnrealistischeKursziele = false
    @State private var selectedTab = 0
    @State private var scrollToISIN: String? = nil
    @State private var scrollToISINOnKurszieleTab: String? = nil
    /// Beim Wechsel von Kursziele → Aktien: Aktien-Liste zu dieser ISIN scrollen (letzte bearbeitete Zeile)
    @State private var scrollToISINWhenReturningFromKursziele: String? = nil
    @State private var currentDetailKey: String? = nil
    @State private var visibleDetailKeysOnAktienList: Set<String> = []
    /// true = Liste nach grösster Differenz Kurs ↔ Kursziel sortieren, mit % zum Ziel
    @State private var sortiereNachAbstandKursziel = false
    /// true = Chart über den 5 Einlesungen (Gesamtwert pro Datum) anzeigen
    @State private var showEinlesungenChart = false
    @State private var showStatistik = false
    /// Pfad für Aktien-Detail (nur unser Chevron, kein System-Chevron)
    @State private var aktienDetailPath: [String] = []
    /// Beim Start kurz Splash anzeigen statt weißen Bildschirm
    @State private var showSplash = true
    /// Auf iPad/Mac: Auswahl für mittlere Spalte im 3-Spalten-Layout (Aktie | Detail | Kursziele)
    @State private var selectedAktieKeyForThreeColumn: String? = nil
    @State private var exportFileURL: URL? = nil
    /// Linke Spalte (Aktienliste) auf iPad/Mac immer sichtbar
    @State private var threeColumnVisibility: NavigationSplitViewVisibility = .all
    @State private var preferredCompactColumn: NavigationSplitViewColumn = .sidebar
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    /// Nur iPad: Hinweis anzeigen, nach „Einlesen“ den Seiten-Wechsel-Button zu betätigen
    /// iPad: Meldung „Nach dem Einlesen … Seiten-Wechsel-Button“ 3 Sekunden anzeigen, dann Dateiauswahl
    @State private var showEinlesenHinweis2Sek = false

    #if os(iOS)
    private var isIPad: Bool { UIDevice.current.userInterfaceIdiom == .pad }
    #else
    private var isIPad: Bool { false }
    #endif

    /// iPad (regular) / Mac: 3-Spalten-Layout; iPhone / schmale iPad: Tabs
    private var useThreeColumnLayout: Bool { horizontalSizeClass == .regular }
    
    /// Eindeutiger Schlüssel pro Position (BL|ISIN|WKN – ISIN kann leer sein, wenn nicht in CSV)
    private func detailKey(bl: String, isin: String, wkn: String) -> String { "\(bl)|\(isin)|\(wkn)" }
    private func parseDetailKey(_ key: String) -> (bl: String, isin: String, wkn: String)? {
        let parts = key.split(separator: "|", omittingEmptySubsequences: false)
        guard parts.count >= 2 else { return nil }
        let bl = String(parts[0])
        let isin = String(parts[1])
        let wkn = parts.count >= 3 ? String(parts[2]) : ""
        return (bl, isin, wkn)
    }
    private func aktieForDetailKey(_ key: String) -> Aktie? {
        guard let (bl, isin, wkn) = parseDetailKey(key) else { return nil }
        return aktien.first(where: { a in
            guard a.bankleistungsnummer == bl else { return false }
            if !isin.isEmpty { return a.isin == isin }
            return a.wkn == wkn
        })
    }

    /// CSV-Zelle escapen (Semikolon/Anführungszeichen in Anführungszeichen, innere " verdoppeln)
    private static func csvEscape(_ s: String) -> String {
        let t = s.trimmingCharacters(in: .whitespaces)
        if t.contains(";") || t.contains("\"") || t.contains("\n") || t.contains("\r") {
            return "\"" + t.replacingOccurrences(of: "\"", with: "\"\"") + "\""
        }
        return t
    }
    
    /// Aktien als CSV-String (Semikolon-getrennt, mit Kursziel)
    private func buildExportCSV() -> String {
        buildExportCSVFrom(aktien: aktien)
    }
    
    /// CSV aus gegebener Aktienliste bauen (für Export im Hintergrund)
    private func buildExportCSVFrom(aktien list: [Aktie]) -> String {
        let header = "Bankleistungsnummer;Bezeichnung;WKN;ISIN;Bestand;Waehrung;Einstandskurs;Kurs;Marktwert_EUR;Kursziel;Kursziel_Waehrung;Kursziel_Datum;Kursziel_Quelle"
        let formatter = NumberFormatter()
        formatter.locale = Locale(identifier: "de_DE")
        formatter.numberStyle = .decimal
        formatter.minimumFractionDigits = 0
        formatter.maximumFractionDigits = 4
        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "dd.MM.yyyy"
        dateFormatter.locale = Locale(identifier: "de_DE")
        var rows: [String] = [header]
        for a in list {
            let bez = Self.csvEscape(a.bezeichnung)
            let bl = Self.csvEscape(a.bankleistungsnummer)
            let wkn = Self.csvEscape(a.wkn)
            let isin = Self.csvEscape(a.isin)
            let bestand = formatter.string(from: NSNumber(value: a.bestand)) ?? "\(a.bestand)"
            let waehrung = Self.csvEscape(a.waehrung)
            let einstand = a.einstandskurs.map { formatter.string(from: NSNumber(value: $0)) ?? "" } ?? ""
            let kurs = a.kurs.map { formatter.string(from: NSNumber(value: $0)) ?? "" } ?? ""
            let marktwert = a.marktwertEUR.map { formatter.string(from: NSNumber(value: $0)) ?? "" } ?? ""
            let kursziel = a.kursziel.map { formatter.string(from: NSNumber(value: $0)) ?? "" } ?? ""
            let kzWaehrung = (a.kurszielWaehrung ?? "").trimmingCharacters(in: .whitespaces)
            let kzW = Self.csvEscape(kzWaehrung)
            let kzDatum = a.kurszielDatum.map { dateFormatter.string(from: $0) } ?? ""
            let kzQuelle = Self.csvEscape(a.kurszielQuelle ?? "")
            rows.append("\(bl);\(bez);\(wkn);\(isin);\(bestand);\(waehrung);\(einstand);\(kurs);\(marktwert);\(kursziel);\(kzW);\(kzDatum);\(kzQuelle)")
        }
        return rows.joined(separator: "\n")
    }
    
    @State private var isExportingCSV = false
    
    /// Eine Zeile Rohdaten für CSV-Export (nur Werttypen, Hintergrund-thread-sicher)
    private struct ExportRow {
        let bl: String
        let bezeichnung: String
        let wkn: String
        let isin: String
        let bestand: Double
        let waehrung: String
        let einstandskurs: Double?
        let kurs: Double?
        let marktwertEUR: Double?
        let kursziel: Double?
        let kurszielWaehrung: String
        let kurszielDatum: Date?
        let kurszielQuelle: String
    }
    
    private func exportAktienToCSV() {
        guard !isExportingCSV else { return }
        isExportingCSV = true
        let rows = aktien.map { a in
            ExportRow(
                bl: a.bankleistungsnummer,
                bezeichnung: a.bezeichnung,
                wkn: a.wkn,
                isin: a.isin,
                bestand: a.bestand,
                waehrung: a.waehrung,
                einstandskurs: a.einstandskurs,
                kurs: a.kurs ?? a.devisenkurs,
                marktwertEUR: a.marktwertEUR,
                kursziel: a.kursziel,
                kurszielWaehrung: a.kurszielWaehrung ?? "",
                kurszielDatum: a.kurszielDatum,
                kurszielQuelle: a.kurszielQuelle ?? ""
            )
        }
        Task { @MainActor in
            let result = await Task.detached(priority: .userInitiated) {
                let csv = Self.buildCSVFromExportRows(rows)
                let df = DateFormatter()
                df.dateFormat = "yyyy-MM-dd_HH-mm"
                df.locale = Locale(identifier: "de_DE")
                let dateStr = df.string(from: Date())
                let fileName = "Aktien_Export_\(dateStr).csv"
                let tempDir = FileManager.default.temporaryDirectory
                let fileURL = tempDir.appendingPathComponent(fileName)
                do {
                    try csv.write(to: fileURL, atomically: true, encoding: .utf8)
                    return Result<URL, Error>.success(fileURL)
                } catch {
                    return Result<URL, Error>.failure(error)
                }
            }.value
            switch result {
            case .success(let url):
                exportFileURL = url
            case .failure(let error):
                importMessage = "Export fehlgeschlagen: \(error.localizedDescription)"
                showImportMessage = true
            }
            isExportingCSV = false
        }
    }
    
    /// CSV-String aus Rohzeilen bauen (läuft komplett im Hintergrund)
    private static func buildCSVFromExportRows(_ rows: [ExportRow]) -> String {
        let header = "Bankleistungsnummer;Bezeichnung;WKN;ISIN;Bestand;Waehrung;Einstandskurs;Kurs;Marktwert_EUR;Kursziel;Kursziel_Waehrung;Kursziel_Datum;Kursziel_Quelle"
        let formatter = NumberFormatter()
        formatter.locale = Locale(identifier: "de_DE")
        formatter.numberStyle = .decimal
        formatter.minimumFractionDigits = 0
        formatter.maximumFractionDigits = 4
        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "dd.MM.yyyy"
        dateFormatter.locale = Locale(identifier: "de_DE")
        var lines = [header]
        for a in rows {
            let bez = Self.csvEscape(a.bezeichnung)
            let bl = Self.csvEscape(a.bl)
            let wkn = Self.csvEscape(a.wkn)
            let isin = Self.csvEscape(a.isin)
            let bestand = formatter.string(from: NSNumber(value: a.bestand)) ?? "\(a.bestand)"
            let waehrung = Self.csvEscape(a.waehrung)
            let einstand = a.einstandskurs.map { formatter.string(from: NSNumber(value: $0)) ?? "" } ?? ""
            let kurs = a.kurs.map { formatter.string(from: NSNumber(value: $0)) ?? "" } ?? ""
            let marktwert = a.marktwertEUR.map { formatter.string(from: NSNumber(value: $0)) ?? "" } ?? ""
            let kursziel = a.kursziel.map { formatter.string(from: NSNumber(value: $0)) ?? "" } ?? ""
            let kzW = Self.csvEscape(a.kurszielWaehrung)
            let kzDatum = a.kurszielDatum.map { dateFormatter.string(from: $0) } ?? ""
            let kzQuelle = Self.csvEscape(a.kurszielQuelle)
            lines.append("\(bl);\(bez);\(wkn);\(isin);\(bestand);\(waehrung);\(einstand);\(kurs);\(marktwert);\(kursziel);\(kzW);\(kzDatum);\(kzQuelle)")
        }
        return lines.joined(separator: "\n")
    }
    
    /// Gefilterte Aktien nach gewählter Kursziel-Quelle, optional nur unrealistische
    private var aktienZurAnzeige: [Aktie] {
        let byQuelle: [Aktie]
        switch kurszielQuelleFilter {
        case .aus: byQuelle = aktien
        case .openAI: byQuelle = aktien.filter { $0.kurszielQuelle == KurszielQuelle.openAI.rawValue }
        case .fmp: byQuelle = aktien.filter { $0.kurszielQuelle == KurszielQuelle.fmp.rawValue }
        case .csv: byQuelle = aktien.filter { $0.kurszielQuelle == KurszielQuelle.csv.rawValue }
        case .manuell: byQuelle = aktien.filter { $0.kurszielManuellGeaendert }
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
                // Zeile 1: Bestand + Anzahl, Marktwert + Wert (gekürzte Labels). Marktwert aus CSV oder berechnet (Kurs × Bestand).
                HStack(spacing: 12) {
                    Text("Stück \(formatBetragDE(aktie.bestand, decimals: 0))")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    if let mw = aktie.marktwertEUR {
                        Text("Marktw. \(formatBetragDE(mw)) €")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    } else if let k = aktie.kurs ?? aktie.devisenkurs, aktie.bestand > 0 {
                        let computed = k * aktie.bestand
                        Text("Marktw. \(formatBetragDE(computed)) €")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
                // Zeile 2: Kurs alt, Kurs neu (nur wenn mindestens einer vorhanden)
                if aktie.previousKurs != nil || (aktie.kurs ?? aktie.devisenkurs) != nil {
                    HStack(spacing: 12) {
                        if let alt = aktie.previousKurs {
                            Text("Kurs alt \(formatBetragDE(alt))")
                                .font(.caption2)
                                .foregroundColor(.secondary)
                        }
                        if let neu = aktie.kurs ?? aktie.devisenkurs {
                            Text("Kurs neu \(formatBetragDE(neu))")
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
                        Text("\(pct >= 0 ? "+" : "")\(formatBetragDE(pct))%")
                            .font(.caption2)
                            .fontWeight(.medium)
                            .foregroundColor(pct >= 0 ? .green : .red)
                    }
                }
                // Zeile 4: Kursziel, Abstand zum Kursziel + Mini-Balken (Kurs/devisenkurs → Kursziel)
                if let kurs = (aktie.kurs ?? aktie.devisenkurs).flatMap({ $0 > 0 ? $0 : nil }), let kz = aktie.kursziel {
                    let abstandPct = (kz - kurs) / kurs * 100
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: 12) {
                            Text("Kursziel \(formatBetragDE(kz))")
                                .font(.caption2)
                                .foregroundColor(.secondary)
                            Text("Abstand \(abstandPct >= 0 ? "+" : "")\(formatBetragDE(abstandPct, decimals: 1))%")
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
                if new == 1, currentDetailKey == nil {
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
                                    let key = scrollToISINWhenReturningFromKursziele ?? scrollToISIN
                                    scrollToISINWhenReturningFromKursziele = nil
                                    if let key = key {
                                        DispatchQueue.main.async {
                                            proxy.scrollTo(key, anchor: .center)
                                            scrollToISIN = nil
                                        }
                                    }
                                }
                            }
                    }
                }
                .navigationDestination(for: String.self) { key in
                    if let aktie = aktieForDetailKey(key) {
                        AktieDetailView(aktie: aktie, onAppearISIN: { _ in currentDetailKey = key })
                    }
                }
            }
            #if os(macOS)
            .navigationSplitViewColumnWidth(min: 360, ideal: 480, max: 680)
            #elseif os(iOS)
            .navigationSplitViewColumnWidth(min: 320, ideal: 420)
            #endif
            .navigationTitle("Aktien · \(BankStore.selectedBank.name)")
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
            .confirmationDialog("Wirklich löschen?", isPresented: $showDeleteEinlesungConfirmation, presenting: einlesungToDelete) { summary in
                Button("Ja", role: .destructive) {
                    deleteEinlesung(summary)
                    einlesungToDelete = nil
                }
                Button("Nein", role: .cancel) { einlesungToDelete = nil }
            } message: { summary in
                Text("Einlesung vom \(summary.datumAktuelleEinlesung.formatted(date: .abbreviated, time: .shortened)) und alle zugehörigen Positionen werden gelöscht.")
            }
            .fileImporter(isPresented: $isImporting, allowedContentTypes: [.commaSeparatedText, .text, .spreadsheet, UTType(filenameExtension: "xlsx", conformingTo: .spreadsheet)!], allowsMultipleSelection: true) { result in
                handleFileImport(result: result)
            }
            .confirmationDialog("Anderes CSV-Format", isPresented: $showFingerprintMismatchAlert) {
                Button("Abbrechen", role: .cancel) {
                    pendingImportURLs = nil
                    showFingerprintMismatchAlert = false
                    isImporting = false
                    clearPendingKurszielAfterImport()
                }
                Button("Trotzdem einlesen") {
                    if let urls = pendingImportURLs {
                        importMultipleCSVFiles(urls: urls)
                    }
                    pendingImportURLs = nil
                    showFingerprintMismatchAlert = false
                }
            } message: {
                let bankName = BankStore.selectedBank.name
                let fileSp = fingerprintMismatchFileSpalten ?? "?"
                let storedSp = fingerprintMismatchStoredSpalten ?? "?"
                Text("Die Datei hat eine andere Spaltenanzahl als beim letzten Einlesen für \(bankName): diese Datei \(fileSp) Spalten, zuletzt \(storedSp) Spalten. Unter Einstellungen → \(bankName) → Spalten zuordnen prüfen: Welche Spalte (A, B, C, …) welchem Feld zugeordnet ist. Bankleistungsnummer kann „Fester Wert“ (z. B. = Ihre Kontonummer oder 1) sein, wenn die CSV keine hat. Nur einlesen, wenn es der richtige Export ist.")
            }
            .confirmationDialog("Bereits eingelesen", isPresented: $showAlreadyImportedConfirm) {
                Button("Ja, nochmal einlesen") { proceedWithPendingAlreadyImportedURLs() }
                Button("Nein", role: .cancel) {
                    pendingURLsForAlreadyImported = nil
                    showAlreadyImportedConfirm = false
                }
            } message: {
                Text("Folgende Datei(en) wurden bereits eingelesen: \(alreadyImportedFilenamesForAlert.joined(separator: ", ")). Nochmal einlesen?")
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
                    } else {
                        NotificationCenter.default.post(name: .returnToStartAfterImport, object: nil)
                    }
                }
            } message: { Text(importMessage) }
            .alert("Kursziele ermitteln?", isPresented: $showKurszielAbfrageAlert) {
                Button("Ja") { showKurszielAbfrageAlert = false; startPendingKurszielFetch() }
                Button("Nein", role: .cancel) { showKurszielAbfrageAlert = false }
            } message: {
                if lastImportHadCSVKursziele {
                    Text("Die eingelesenen Daten liegen vor dem Tagesdatum. Sollen die Kursziele trotzdem ermittelt werden? (Kann zeitaufwendig sein.)\n\nEs sind bereits Kursziele über die Datei mit eingelesen worden.")
                } else {
                    Text("Die eingelesenen Daten liegen vor dem Tagesdatum. Sollen die Kursziele trotzdem ermittelt werden? (Kann zeitaufwendig sein.)")
                }
            }
            .sheet(isPresented: $showSettings) {
                SettingsView(openAIAPIKey: $openAIAPIKeyStore, fmpAPIKey: $fmpAPIKeyStore)
            }
            .sheet(isPresented: $showDebugLog) { DebugLogSheet() }
            .sheet(isPresented: $showRechtliches) { RechtlichesSheetView() }
            .sheet(isPresented: $showWatchlist) { WatchlistView() }
            .sheet(isPresented: $showStatistik) {
                StatistikSheetView(summaries: importSummaries, showEinlesungenChart: $showEinlesungenChart, onDeleteEinlesung: { summary, alreadyConfirmed in
                    if alreadyConfirmed {
                        deleteEinlesung(summary)
                    } else {
                        einlesungToDelete = summary
                        showDeleteEinlesungConfirmation = true
                        showStatistik = false
                    }
                }, onRequestDeleteAll: {
                    showStatistik = false
                    showDeleteConfirmation = true
                })
            }
            .sheet(item: $exportFileURL, onDismiss: { exportFileURL = nil }) { url in
                ExportCSVShareSheet(fileURL: url) {
                    exportFileURL = nil
                }
            }
        } detail: {
            Text("Aktie auswählen")
        }
    }
    
    /// iPad (regular) und Mac: 3 Spalten nebeneinander – Aktien | Detail | Kursziele
    @ViewBuilder
    private var threeColumnLayout: some View {
        NavigationSplitView(columnVisibility: $threeColumnVisibility, preferredCompactColumn: $preferredCompactColumn) {
            VStack(spacing: 0) {
                DevisenkursKopfView(usdToEur: appWechselkurse.usdToEur, gbpToEur: appWechselkurse.gbpToEur, isLoading: appWechselkurse.isLoading)
                ScrollViewReader { proxy in
                    aktienListContent(proxy: proxy, selectionForThreeColumn: $selectedAktieKeyForThreeColumn)
                }
            }
            #if os(macOS)
            .navigationSplitViewColumnWidth(min: 320, ideal: 380, max: 500)
            #elseif os(iOS)
            .navigationSplitViewColumnWidth(min: 280, ideal: 360)
            #endif
            .navigationTitle("Aktien · \(BankStore.selectedBank.name)")
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
            .confirmationDialog("Wirklich löschen?", isPresented: $showDeleteEinlesungConfirmation, presenting: einlesungToDelete) { summary in
                Button("Ja", role: .destructive) {
                    deleteEinlesung(summary)
                    einlesungToDelete = nil
                }
                Button("Nein", role: .cancel) { einlesungToDelete = nil }
            } message: { summary in
                Text("Einlesung vom \(summary.datumAktuelleEinlesung.formatted(date: .abbreviated, time: .shortened)) und alle zugehörigen Positionen werden gelöscht.")
            }
            .fileImporter(isPresented: $isImporting, allowedContentTypes: [.commaSeparatedText, .text, .spreadsheet, UTType(filenameExtension: "xlsx", conformingTo: .spreadsheet)!], allowsMultipleSelection: true) { result in
                handleFileImport(result: result)
            }
            .confirmationDialog("Anderes CSV-Format", isPresented: $showFingerprintMismatchAlert) {
                Button("Abbrechen", role: .cancel) {
                    pendingImportURLs = nil
                    showFingerprintMismatchAlert = false
                    isImporting = false
                    clearPendingKurszielAfterImport()
                }
                Button("Trotzdem einlesen") {
                    if let urls = pendingImportURLs {
                        importMultipleCSVFiles(urls: urls)
                    }
                    pendingImportURLs = nil
                    showFingerprintMismatchAlert = false
                }
            } message: {
                let bankName = BankStore.selectedBank.name
                let fileSp = fingerprintMismatchFileSpalten ?? "?"
                let storedSp = fingerprintMismatchStoredSpalten ?? "?"
                Text("Die Datei hat eine andere Spaltenanzahl als beim letzten Einlesen für \(bankName): diese Datei \(fileSp) Spalten, zuletzt \(storedSp) Spalten. Unter Einstellungen → \(bankName) → Spalten zuordnen prüfen: Welche Spalte (A, B, C, …) welchem Feld zugeordnet ist. Bankleistungsnummer kann „Fester Wert“ (z. B. = Ihre Kontonummer oder 1) sein, wenn die CSV keine hat. Nur einlesen, wenn es der richtige Export ist.")
            }
            .confirmationDialog("Bereits eingelesen", isPresented: $showAlreadyImportedConfirm) {
                Button("Ja, nochmal einlesen") { proceedWithPendingAlreadyImportedURLs() }
                Button("Nein", role: .cancel) {
                    pendingURLsForAlreadyImported = nil
                    showAlreadyImportedConfirm = false
                }
            } message: {
                Text("Folgende Datei(en) wurden bereits eingelesen: \(alreadyImportedFilenamesForAlert.joined(separator: ", ")). Nochmal einlesen?")
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
                    } else {
                        NotificationCenter.default.post(name: .returnToStartAfterImport, object: nil)
                    }
                }
            } message: { Text(importMessage) }
            .alert("Kursziele ermitteln?", isPresented: $showKurszielAbfrageAlert) {
                Button("Ja") { showKurszielAbfrageAlert = false; startPendingKurszielFetch() }
                Button("Nein", role: .cancel) { showKurszielAbfrageAlert = false }
            } message: {
                if lastImportHadCSVKursziele {
                    Text("Die eingelesenen Daten liegen vor dem Tagesdatum. Sollen die Kursziele trotzdem ermittelt werden? (Kann zeitaufwendig sein.)\n\nEs sind bereits Kursziele über die Datei mit eingelesen worden.")
                } else {
                    Text("Die eingelesenen Daten liegen vor dem Tagesdatum. Sollen die Kursziele trotzdem ermittelt werden? (Kann zeitaufwendig sein.)")
                }
            }
            .sheet(isPresented: $showSettings) {
                SettingsView(openAIAPIKey: $openAIAPIKeyStore, fmpAPIKey: $fmpAPIKeyStore)
            }
            .sheet(isPresented: $showDebugLog) { DebugLogSheet() }
            .sheet(isPresented: $showRechtliches) { RechtlichesSheetView() }
            .sheet(isPresented: $showWatchlist) { WatchlistView() }
            .sheet(isPresented: $showStatistik) {
                StatistikSheetView(summaries: importSummaries, showEinlesungenChart: $showEinlesungenChart, onDeleteEinlesung: { summary, alreadyConfirmed in
                    if alreadyConfirmed {
                        deleteEinlesung(summary)
                    } else {
                        einlesungToDelete = summary
                        showDeleteEinlesungConfirmation = true
                        showStatistik = false
                    }
                }, onRequestDeleteAll: {
                    showStatistik = false
                    showDeleteConfirmation = true
                })
            }
            .sheet(item: $exportFileURL, onDismiss: { exportFileURL = nil }) { url in
                ExportCSVShareSheet(fileURL: url) {
                    exportFileURL = nil
                }
            }
        } content: {
            Group {
                if let key = selectedAktieKeyForThreeColumn, let aktie = aktieForDetailKey(key) {
                    AktieDetailView(aktie: aktie, onAppearISIN: { _ in currentDetailKey = key })
                } else {
                    Text("Aktie wählen")
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        #if os(iOS)
                        .background(Color(uiColor: .secondarySystemGroupedBackground))
                        #endif
                }
            }
            #if os(macOS)
            .navigationSplitViewColumnWidth(min: 320, ideal: 420, max: 600)
            #elseif os(iOS)
            .navigationSplitViewColumnWidth(min: 300, ideal: 400)
            #endif
            .navigationTitle("Detail · \(BankStore.selectedBank.name)")
        } detail: {
            KurszielListenView(aktien: aktienZurAnzeige, scrollToDetailKey: $scrollToISINOnKurszieleTab, markedDetailKey: selectedAktieKeyForThreeColumn ?? currentDetailKey, onCopyDetailKey: { scrollToISIN = $0 }, onRowEdited: { scrollToISINWhenReturningFromKursziele = $0 }, onKurszielSuchenTapped: { currentDetailKey = $0 })
                .onChange(of: selectedAktieKeyForThreeColumn) { _, key in
                    if let key = key, !key.isEmpty { scrollToISINOnKurszieleTab = key }
                }
                #if os(macOS)
                .navigationSplitViewColumnWidth(min: 320, ideal: 440, max: 700)
                #elseif os(iOS)
                .navigationSplitViewColumnWidth(min: 300, ideal: 400)
                #endif
                .navigationTitle("Kursziele · \(BankStore.selectedBank.name)")
        }
        .navigationSplitViewStyle(.balanced)
    }

    @ToolbarContentBuilder
    private var aktienToolbarContent: some ToolbarContent {
        Group {
            ToolbarItem(placement: .navigationBarLeading) {
                Button {
                    StartState.shared.hasStarted = false
                } label: {
                    Label("Startseite", systemImage: "house.fill")
                }
            }
            ToolbarItem(placement: .navigationBarLeading) {
                Button(role: .destructive) {
                    StartState.shared.requestAuthOnNextStart()
                } label: {
                    Label("App beenden", systemImage: "lock.fill")
                }
            }
        }
        #if os(iOS)
        ToolbarItem(placement: .navigationBarTrailing) {
            Button("Rechtliches") { showRechtliches = true }
        }
        #endif
        Group {
            ToolbarItem {
                Button(action: { sortiereNachAbstandKursziel.toggle() }) {
                    Label(sortiereNachAbstandKursziel ? "Sortierung: Standard" : "Nach Abstand zum Kursziel", systemImage: sortiereNachAbstandKursziel ? "list.bullet" : "chart.line.uptrend.xyaxis")
                }
            }
            ToolbarItem {
                Button(action: { showWatchlist = true }) { Label("Watchlist", systemImage: "eye") }
            }
            ToolbarItem {
                Button(action: { showStatistik = true }) { Label("Statistik", systemImage: "chart.bar.doc.horizontal") }
            }
            ToolbarItem {
                Button(action: { startKurszielErmittlungManuell() }) {
                    Label("Kursziele ermitteln", systemImage: "arrow.clockwise.circle")
                }
                .disabled(isImportingKursziele || aktien.isEmpty)
            }
            ToolbarItem {
                Button(action: { exportAktienToCSV() }) {
                    if isExportingCSV {
                        ProgressView()
                            .scaleEffect(0.8)
                    } else {
                        Label("CSV exportieren", systemImage: "square.and.arrow.up")
                    }
                }
                .disabled(aktien.isEmpty || isExportingCSV)
            }
            ToolbarItem {
                Button(action: { showDebugLog = true }) { Label("Debug-Log", systemImage: "ladybug") }
            }
        }
    }

    @ViewBuilder
    private func aktienListContent(proxy: ScrollViewProxy, selectionForThreeColumn: Binding<String?>? = nil) -> some View {
        List {
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
                                if let sel = selectionForThreeColumn { sel.wrappedValue = detailKey(bl: aktie.bankleistungsnummer, isin: aktie.isin, wkn: aktie.wkn) } else { aktienDetailPath.append(detailKey(bl: aktie.bankleistungsnummer, isin: aktie.isin, wkn: aktie.wkn)) }
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
                            .id(detailKey(bl: aktie.bankleistungsnummer, isin: aktie.isin, wkn: aktie.wkn))
                            .onAppear { visibleDetailKeysOnAktienList.insert(detailKey(bl: aktie.bankleistungsnummer, isin: aktie.isin, wkn: aktie.wkn)) }
                            .onDisappear { visibleDetailKeysOnAktienList.remove(detailKey(bl: aktie.bankleistungsnummer, isin: aktie.isin, wkn: aktie.wkn)) }
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
                                    if let sel = selectionForThreeColumn { sel.wrappedValue = detailKey(bl: aktie.bankleistungsnummer, isin: aktie.isin, wkn: aktie.wkn) } else { aktienDetailPath.append(detailKey(bl: aktie.bankleistungsnummer, isin: aktie.isin, wkn: aktie.wkn)) }
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
                                .id(detailKey(bl: aktie.bankleistungsnummer, isin: aktie.isin, wkn: aktie.wkn))
                                .onAppear { visibleDetailKeysOnAktienList.insert(detailKey(bl: aktie.bankleistungsnummer, isin: aktie.isin, wkn: aktie.wkn)) }
                                .onDisappear { visibleDetailKeysOnAktienList.remove(detailKey(bl: aktie.bankleistungsnummer, isin: aktie.isin, wkn: aktie.wkn)) }
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
                                Text("\(formatBetragDE(zwischensumme)) €")
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
                        Text("\(formatBetragDE(gesamtMarktwert)) €")
                            .font(.subheadline)
                            .fontWeight(.semibold)
                    }
                    .padding(.vertical, 4)
                }
            }
    }

    var body: some View {
        ZStack(alignment: .top) {
            contentView
            if showSplash {
                splashOverlay
            }
            if isIPad, showEinlesenHinweis2Sek {
                Color.black.opacity(0.4)
                    .ignoresSafeArea()
                VStack(spacing: 16) {
                    Text("Nach dem Einlesen bitte den Seiten-Wechsel-Button betätigen, um die Ergebnisse zu sehen.")
                        .font(.body)
                        .fontWeight(.medium)
                        .multilineTextAlignment(.center)
                        .foregroundStyle(.primary)
                        .padding(.horizontal, 32)
                        .padding(.vertical, 24)
                        .background(.regularMaterial)
                        .cornerRadius(16)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .transition(.opacity)
            }
        }
        .animation(.easeOut(duration: 0.25), value: showSplash)
        .animation(.easeOut(duration: 0.2), value: showEinlesenHinweis2Sek)
        .onAppear {
            // Kurz Splash zeigen, damit nie nur ein weißes Bild erscheint
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                showSplash = false
            }
            // Von Startseite: Dateien bereits gewählt → sofort Fingerprint/Import verarbeiten (Picker war dort geöffnet)
            if let urls = StartState.shared.pendingImportURLsFromStart {
                StartState.shared.pendingImportURLsFromStart = nil
                applyImportURLsFromStart(urls)
            } else {
                // Mit „Start“ gekommen: Aktienliste anzeigen (Sidebar), keine Detailseite – sonst erscheint nur „Aktie wählen“
                selectedAktieKeyForThreeColumn = nil
                aktienDetailPath = []
                preferredCompactColumn = .sidebar
                threeColumnVisibility = .all
                // Einmal im nächsten Run-Loop wiederholen, damit das Split-View die Sidebar anzeigt (iPad)
                DispatchQueue.main.async {
                    preferredCompactColumn = .sidebar
                    threeColumnVisibility = .all
                }
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
        Group {
            if useThreeColumnLayout {
                threeColumnLayout
                    .task {
                        let (usd, gbp) = await KurszielService.fetchAppWechselkurse()
                        await MainActor.run { AppWechselkurse.shared.set(usd: usd, gbp: gbp) }
                    }
            } else {
                TabView(selection: selectedTabBinding) {
                    aktienTabContent
                        .tabItem { Label("Aktien", systemImage: "list.bullet") }
                        .tag(0)
                        .task {
                            let (usd, gbp) = await KurszielService.fetchAppWechselkurse()
                            await MainActor.run { AppWechselkurse.shared.set(usd: usd, gbp: gbp) }
                        }

                    NavigationStack {
                        KurszielListenView(aktien: aktienZurAnzeige, scrollToDetailKey: $scrollToISINOnKurszieleTab, markedDetailKey: currentDetailKey, onCopyDetailKey: { scrollToISIN = $0 }, onRowEdited: { scrollToISINWhenReturningFromKursziele = $0 }, onKurszielSuchenTapped: { currentDetailKey = $0 })
                    }
                    .tabItem { Label("Kursziele", systemImage: "target") }
                    .tag(1)
                    .onChange(of: selectedTab) { _, new in
                        if new == 1 {
                            scrollToISINOnKurszieleTab = currentDetailKey ?? gruppierteAktien.flatMap(\.aktien).first(where: { visibleDetailKeysOnAktienList.contains(detailKey(bl: $0.bankleistungsnummer, isin: $0.isin, wkn: $0.wkn)) }).map { detailKey(bl: $0.bankleistungsnummer, isin: $0.isin, wkn: $0.wkn) }
                        }
                    }
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
                Text("\(name): Original \(formatBetragDE(orig.kursziel)) \(orig.waehrung ?? "EUR"). OpenAI-Ersatz: \(formatBetragDE(repl.kursziel)) \(repl.waehrung ?? "EUR"). Übernehmen?")
            }
        }
    }

    @ViewBuilder
    private var importingOverlay: some View {
        if isImportingKursziele || isImportingKurszieleOpenAI {
            VStack {
                Spacer()
                VStack(spacing: 10) {
                    HStack {
                        ProgressView()
                        Text(isImportingKurszieleOpenAI ? "Kursziele werden via OpenAI abgerufen…" : "Kursziele werden abgerufen…")
                            .font(.caption)
                    }
                    // In der Automatik nur FMP und OpenAI (nur wenn API-Key gesetzt)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Quellen (automatischer Durchlauf):")
                            .font(.caption2)
                            .fontWeight(.medium)
                            .foregroundColor(.secondary)
                        kurszielQuelleZeile(name: "FMP (Financial Modeling Prep)", brauchtKey: true, hatKey: !fmpAPIKeyStore.trimmingCharacters(in: .whitespaces).isEmpty)
                        kurszielQuelleZeile(name: "OpenAI", brauchtKey: true, hatKey: !openAIAPIKeyStore.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
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
    
    private func kurszielQuelleZeile(name: String, brauchtKey: Bool, hatKey: Bool) -> some View {
        let ausgegraut = brauchtKey && !hatKey
        return Text("• \(name)\(ausgegraut ? " (kein API-Key)" : "")")
            .font(.caption2)
            .foregroundColor(ausgegraut ? .secondary : .primary)
            .opacity(ausgegraut ? 0.65 : 1)
    }

    private func importCSVFiles() {
        isImporting = true
    }
    
    /// Prüft, ob mindestens ein gewählter Dateiname in der Einlese-Merkliste ist. Wenn ja: Dialog „Nochmal?“; sonst proceed().
    private func ifNotAlreadyImported(urls: [URL], fromStart: Bool, proceed: @escaping () -> Void) {
        let namen = urls.map { $0.lastPathComponent }
        let gespeichert = Set(BankStore.eingeleseneDateinamen())
        let treffer = namen.filter { gespeichert.contains($0) }
        if !treffer.isEmpty {
            alreadyImportedFilenamesForAlert = treffer
            pendingURLsForAlreadyImported = urls
            alreadyImportedFromStart = fromStart
            showAlreadyImportedConfirm = true
        } else {
            proceed()
        }
    }

    /// Nach „Ja“ im Dialog „Bereits eingelesen – Nochmal?“: Import mit den zwischengespeicherten URLs starten.
    private func proceedWithPendingAlreadyImportedURLs() {
        guard let urls = pendingURLsForAlreadyImported else { return }
        pendingURLsForAlreadyImported = nil
        showAlreadyImportedConfirm = false
        DispatchQueue.main.async { [urls] in
            importMultipleCSVFiles(urls: urls)
        }
    }

    /// Verarbeitet vom Startseiten-Picker gewählte URLs (Fingerprint prüfen, ggf. Format-Dialog oder Import).
    private func applyImportURLsFromStart(_ urls: [URL]) {
        if isIPad {
            showEinlesenHinweis2Sek = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                showEinlesenHinweis2Sek = false
            }
        }
        guard urls.first != nil else { return }
        ifNotAlreadyImported(urls: urls, fromStart: true) {
            DispatchQueue.main.async { [urls] in
                importMultipleCSVFiles(urls: urls)
            }
        }
    }

    private func handleFileImport(result: Result<[URL], Error>) {
        switch result {
        case .success(let urls):
            isImporting = false
            guard urls.first != nil else { return }
            ifNotAlreadyImported(urls: urls, fromStart: false) {
                DispatchQueue.main.async { [urls] in
                    self.importMultipleCSVFiles(urls: urls)
                }
            }
        case .failure(let error):
            isImporting = false
            clearPendingKurszielAfterImport()
            importMessage = "Fehler beim Auswählen der Dateien: \(error.localizedDescription)"
            showImportMessage = true
        }
    }
    
    /// Prüft, ob die Filter-Nummer im Dateitext vorkommt – als eigenständige Zahl, nicht als Teil einer längeren Ziffernfolge (z. B. in ISIN).
    /// Sucht auch nach deutscher Schreibweise mit Tausendertrennzeichen (z. B. 2.522.365), damit CSV-Exporte von Excel o. Ä. erkannt werden.
    private func fileContentContainsFilterNumberAsWhole(_ content: String, _ filterNr: String) -> Bool {
        guard !filterNr.isEmpty else { return false }
        if containsFilterNumberAsWhole(in: content, needle: filterNr) { return true }
        // Zusätzlich: Nummer mit deutschem Tausendertrennzeichen (z. B. 2.522.365), falls die CSV so exportiert wurde
        if filterNr.allSatisfy(\.isNumber), filterNr.count >= 4,
           let formatted = germanThousandsFormatted(filterNr) {
            return containsFilterNumberAsWhole(in: content, needle: formatted)
        }
        return false
    }

    private func containsFilterNumberAsWhole(in content: String, needle: String) -> Bool {
        var searchStart = content.startIndex
        while searchStart < content.endIndex,
              let range = content.range(of: needle, range: searchStart..<content.endIndex) {
            let beforeOk = range.lowerBound == content.startIndex || !content[content.index(before: range.lowerBound)].isNumber
            let afterOk = range.upperBound == content.endIndex || !content[range.upperBound].isNumber
            if beforeOk && afterOk { return true }
            searchStart = range.upperBound
        }
        return false
    }

    /// Erzeugt z. B. "2.522.365" aus "2522365" (Tausendertrennzeichen von rechts).
    private func germanThousandsFormatted(_ digits: String) -> String? {
        guard digits.allSatisfy(\.isNumber), !digits.isEmpty else { return nil }
        var result = ""
        let chars = Array(digits)
        let count = chars.count
        for (i, c) in chars.enumerated() {
            if i > 0, (count - i) % 3 == 0 { result += "." }
            result.append(c)
        }
        return result
    }

    private func importMultipleCSVFiles(urls: [URL]) {
        pendingImportURLs = nil
        showFingerprintMismatchAlert = false
        let currentFingerprint = urls.first.flatMap { CSVParser.computeFingerprint(from: $0) }
        if debugEinlesungNurEinSatz {
            print("\n>>> DEBUG EINLESUNG: Schalter an – es wird nur die erste Datei, erste Zeile verarbeitet. Ausgabe folgt unten. <<<\n")
        }
        var alleNeuenAktien: [Aktie] = []
        var zeilenVerarbeitet = 0
        var errors: [String] = []
        var parseHinweise: [String] = []
        
        // Einlesedatum aus allen Dateinamen bestimmen: neueste (Datum+Uhrzeit) der ausgewählten Dateien.
        // Wenn kein Datum im Dateinamen erkennbar ist, aktueller Zeitpunkt als Fallback (damit mehrere Läufe am selben Tag unterscheidbar bleiben).
        let parsedDates = urls.compactMap { DateFromFilename.parse($0.lastPathComponent) }
        let einleseDatum = parsedDates.max() ?? Date()
        
        // 1. Alle CSV-Daten einlesen (zunächst nur sammeln, Einfügen nach Prüfung pro BL)
        var csvHadKursziele = false
        var firstFailureLineAny: Int?
        var firstFailureDiagnosticAny: String?
        var firstFailureFileAny: String?
        var firstFilePreviewAny: String?
        let urlsToProcess = debugEinlesungNurEinSatz ? Array(urls.prefix(1)) : urls
        let kontoFilterRaw = BankStore.loadKontoFilter(for: BankStore.selectedBankId)
        let kontoFilterNumbers: [String] = (kontoFilterRaw ?? "")
            .components(separatedBy: CharacterSet(charactersIn: "|,"))
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        if kontoFilterNumbers.isEmpty {
            clearPendingKurszielAfterImport()
            importMessage = "Konto-Filter fehlt – unter Einstellungen → \(BankStore.selectedBank.name) → Spalten zuordnen eintragen (z. B. 600252636500|20070000)."
            showImportMessage = true
            return
        }
        // Immer prüfen: Datei muss mindestens eine Filter-Nummer enthalten (als eigenständige Zahl, nicht in ISIN o. Ä.).
        // So greift die Ablehnung auch bei „BL aus Spalte“ (z. B. Commerzbank-Datei bei ausgewählter Deutscher Bank).
        // XLSX: Inhalt per CoreXLSX auslesen (wie beim Parsen), da String(contentsOf:) nur Binär/XML liefert.
        for url in urlsToProcess {
            _ = url.startAccessingSecurityScopedResource()
            defer { url.stopAccessingSecurityScopedResource() }
            let fileContent: String?
            if url.pathExtension.lowercased() == "xlsx" {
                fileContent = try? csvStyleStringFromXLSX(url: url)
            } else {
                fileContent = (try? String(contentsOf: url, encoding: .utf8))
                    ?? (try? String(contentsOf: url, encoding: .isoLatin1))
            }
            guard let content = fileContent, !content.isEmpty else {
                clearPendingKurszielAfterImport()
                importMessage = "Datei konnte nicht gelesen werden: \(url.lastPathComponent)"
                showImportMessage = true
                return
            }
            let enthaeltKonto = kontoFilterNumbers.contains { fileContentContainsFilterNumberAsWhole(content, $0) }
            if !enthaeltKonto {
                clearPendingKurszielAfterImport()
                let filterPreview = kontoFilterNumbers.prefix(3).joined(separator: ", ") + (kontoFilterNumbers.count > 3 ? "…" : "")
                importMessage = "Falsche Bank – in der Datei „\(url.lastPathComponent)“ kommt keine der Kontonummern vor (\(filterPreview))."
                showImportMessage = true
                return
            }
        }
        let hasFixedBL = BankStore.fixedBankleistungsnummer(for: BankStore.selectedBankId) != nil
        for url in urlsToProcess {
            do {
                _ = url.startAccessingSecurityScopedResource()
                defer { url.stopAccessingSecurityScopedResource() }
                
                let (neueAktien, zeilenGesamt, zeilenImportiert, hadKursziele, firstFailureLine, firstFailureDiagnostic, filePreview) = try CSVParser.parseCSVWithStats(from: url)
                if firstFailureDiagnosticAny == nil, let diag = firstFailureDiagnostic {
                    firstFailureLineAny = firstFailureLine
                    firstFailureDiagnosticAny = diag
                    firstFailureFileAny = url.lastPathComponent
                }
                if firstFilePreviewAny == nil, let preview = filePreview { firstFilePreviewAny = preview }
                let neueAktienToInsert = debugEinlesungNurEinSatz ? Array(neueAktien.prefix(1)) : neueAktien
                csvHadKursziele = csvHadKursziele || hadKursziele
                zeilenVerarbeitet += debugEinlesungNurEinSatz ? neueAktienToInsert.count : zeilenImportiert
                if zeilenGesamt > zeilenImportiert, !debugEinlesungNurEinSatz {
                    var hinweis = "\(url.lastPathComponent): \(zeilenGesamt) Zeilen in Datei, \(zeilenImportiert) als Positionen importiert. \(zeilenGesamt - zeilenImportiert) Zeile(n) konnten nicht zugeordnet werden."
                    if let line = firstFailureLine, let diag = firstFailureDiagnostic {
                        hinweis += " Erste fehlgeschlagene Zeile: Zeile \(line) – \(diag)"
                    } else {
                        hinweis += " (z. B. anderes Format oder fehlende Pflichtfelder)"
                    }
                    parseHinweise.append(hinweis)
                }
                for neueAktie in neueAktienToInsert {
                    alleNeuenAktien.append(neueAktie)
                }
                // Nach erfolgreichem Einlesen: Umbenennen in EX_<Dateiname> (in Place). Wenn nicht möglich (z. B. schreibgeschützt), Datei löschen; sonst Kopie ins App-Documents.
                if url.isFileURL {
                    let ursprungsname = url.lastPathComponent
                    let neuerName = "EX_" + ursprungsname
                    let fm = FileManager.default
                    let dir = url.deletingLastPathComponent()
                    let neuesURLInPlace = dir.appendingPathComponent(neuerName)
                    do {
                        try fm.moveItem(at: url, to: neuesURLInPlace)
                    } catch {
                        // Umbenennen fehlgeschlagen (z. B. nur Lesezugriff) → versuchen zu löschen
                        if (try? fm.removeItem(at: url)) == nil, let docDir = fm.urls(for: .documentDirectory, in: .userDomainMask).first {
                            let zielURL = docDir.appendingPathComponent(neuerName)
                            try? fm.removeItem(at: zielURL)
                            try? fm.copyItem(at: url, to: zielURL)
                        }
                    }
                }
            } catch {
                errors.append("\(url.lastPathComponent): \(error.localizedDescription)")
            }
        }
        if debugEinlesungNurEinSatz && alleNeuenAktien.isEmpty {
            print(">>> DEBUG: Keine Zeilen in alleNeuenAktien (Parser lieferte 0 Positionen oder alle waren Watchlist-Treffer). Prüfe CSV-Format und Zuordnung. <<<\n")
        }
        if !hasFixedBL {
            let blValues = alleNeuenAktien.map { $0.bankleistungsnummer.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            let hatTreffer = blValues.contains { bl in
                kontoFilterNumbers.contains { filterNr in
                    bl.contains(filterNr) || filterNr.contains(bl)
                }
            }
            if !hatTreffer {
                clearPendingKurszielAfterImport()
                let filterPreview = kontoFilterNumbers.prefix(3).joined(separator: ", ") + (kontoFilterNumbers.count > 3 ? "…" : "")
                importMessage = "Falsche Bank – keine Zeile, in der die Bankleistungsnummer eine der Filter-Nummern enthält (\(filterPreview))."
                showImportMessage = true
                return
            }
        }
        
        // Feste Werte aus der Zuordnung: Jedes Feld, bei dem „Fester Wert“ (=…) eingetragen ist, wird auf alle Einlesezeilen angewendet (z. B. Bankleistungsnummer). Die BL aus der CSV-Spalte wird dabei überschrieben.
        let aktivesMapping = BankStore.loadCSVColumnMapping(for: BankStore.selectedBankId)
        if debugEinlesungNurEinSatz, let first = alleNeuenAktien.first {
            let aktiveBankName = BankStore.selectedBank.name
            let blMapping = aktivesMapping["bankleistungsnummer"] ?? "nil"
            print("========== Einlesung Debug (1 Zeile) ==========")
            print("  Aktive Bank (wird für Zuordnung genutzt): \(aktiveBankName)")
            print("  Mapping BL: \(blMapping) — wenn mit '=' (z. B. =99999): BL aus CSV wird ignoriert, fester Wert gilt.")
            print("--- Einlesewerte (aus CSV/Parser, vor fester Wert) ---")
            print("  BL: \(first.bankleistungsnummer)")
            print("  Bezeichnung: \(first.bezeichnung)")
            print("  WKN: \(first.wkn)  ISIN: \(first.isin)")
            print("  Bestand: \(first.bestand)  Währung: \(first.waehrung)")
            print("  Kurs: \(first.kurs ?? 0)  Devisenkurs: \(first.devisenkurs ?? 0)")
            print("  Marktwert EUR: \(first.marktwertEUR?.description ?? "nil")")
            print("  Gattung: \(first.gattung)  Depot/Portfolio: \(first.depotPortfolioName)")
            print("  importDatum (Parser): \(first.importDatum)")
        }
        for (fieldId, raw) in aktivesMapping {
            guard raw.hasPrefix("=") else { continue }
            let fixedValue = String(raw.dropFirst(1)).trimmingCharacters(in: .whitespaces)
            guard !fixedValue.isEmpty else { continue }
            for aktie in alleNeuenAktien {
                applyFixedValueToAktie(aktie, fieldId: fieldId, fixedValue: fixedValue)
            }
        }
        // Fester BL-Wert aus beliebiger Bank: Wenn irgendeine Bank „Fester Wert“ für BL hat, alle Zeilen damit überschreiben (BL aus CSV wird ignoriert).
        if let festeBL = BankStore.fixedBankleistungsnummer(for: BankStore.selectedBankId) {
            for aktie in alleNeuenAktien {
                aktie.bankleistungsnummer = festeBL
            }
        }
        
        // Marktwert aus Kurs × Bestand, wenn CSV keine Marktwert-Spalte lieferte (z. B. DKB)
        for aktie in alleNeuenAktien {
            if aktie.marktwertEUR == nil, let k = aktie.kurs ?? aktie.devisenkurs, aktie.bestand > 0 {
                aktie.marktwertEUR = k * aktie.bestand
            }
        }
        
        // Pro BL prüfen, ob das Einlesedatum älter ist als die letzte Einlesung dieser BL – nur dann „nur Vergleichsliste“
        let neueBLs: Set<String> = {
            if let festeBL = BankStore.fixedBankleistungsnummer(for: BankStore.selectedBankId) {
                return [festeBL]
            }
            return Set(alleNeuenAktien.map { $0.bankleistungsnummer.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty })
        }()
        let nurVergleichsliste = !importSummaries.isEmpty && !aktien.isEmpty && !neueBLs.isEmpty && neueBLs.allSatisfy { bl in
            guard let latest = aktien.filter({ $0.bankleistungsnummer.trimmingCharacters(in: .whitespaces) == bl }).map(\.importDatum).max() else { return false }
            return einleseDatum < latest
        }
        if nurVergleichsliste {
            let gesamtwertNurVergleich = alleNeuenAktien.compactMap { $0.marktwertEUR }.reduce(0, +)
            let runId = UUID()
            let summary = ImportSummary(gesamtwertVoreinlesung: 0, gesamtwertAktuelleEinlesung: gesamtwertNurVergleich, datumVoreinlesung: nil, datumAktuelleEinlesung: einleseDatum, importBankId: BankStore.selectedBankId, importRunId: runId)
            modelContext.insert(summary)
            let ueberzaehlige = Array(importSummaries.dropFirst(maxAnzahlEinlesungen))
            for oldSummary in ueberzaehlige {
                let snapsToDelete: [ImportPositionSnapshot]
                if let oldRunId = oldSummary.importRunId {
                    snapsToDelete = (try? modelContext.fetch(FetchDescriptor<ImportPositionSnapshot>(predicate: #Predicate<ImportPositionSnapshot> { $0.importRunId == oldRunId }))) ?? []
                } else {
                    let dateToRemove = oldSummary.datumAktuelleEinlesung
                    snapsToDelete = (try? modelContext.fetch(FetchDescriptor<ImportPositionSnapshot>(predicate: #Predicate<ImportPositionSnapshot> { $0.importDatum == dateToRemove }))) ?? []
                }
                for s in snapsToDelete { modelContext.delete(s) }
                modelContext.delete(oldSummary)
            }
            do {
                try modelContext.save()
            } catch {
                clearPendingKurszielAfterImport()
                importMessage = "Speicherfehler: \(error.localizedDescription)"
                showImportMessage = true
                return
            }
            let datumStr = einleseDatum.formatted(date: .abbreviated, time: .shortened)
            let neuestesProBL = neueBLs.compactMap { bl in aktien.filter { $0.bankleistungsnummer.trimmingCharacters(in: .whitespaces) == bl }.map(\.importDatum).max() }.max()
            let neuestStr = neuestesProBL.map { $0.formatted(date: .abbreviated, time: .shortened) } ?? ""
            clearPendingKurszielAfterImport()
            importMessage = "Einlesung vom \(datumStr) wurde nur für die Vergleichsliste übernommen (älteres Datum pro BL). Die angezeigten Daten stammen weiterhin vom \(neuestStr)."
            showImportMessage = true
            return
        }
        
        let alteAktien = Array(aktien)
        let gesamtwertVoreinlesung = alteAktien.compactMap { $0.marktwertEUR }.reduce(0, +)
        
        // Einlesedatum auf alle neuen Positionen setzen (Parser setzt nur Date()), damit „Einlesung löschen“ alle zugehörigen Sätze findet
        for aktie in alleNeuenAktien {
            aktie.importDatum = einleseDatum
        }
        if debugEinlesungNurEinSatz, let first = alleNeuenAktien.first {
            print("--- Satz Deutsche Bank (nach Verarbeitung, wird gespeichert) ---")
            print("  BL: \(first.bankleistungsnummer)")
            print("  Bezeichnung: \(first.bezeichnung)")
            print("  WKN: \(first.wkn)  ISIN: \(first.isin)")
            print("  Bestand: \(first.bestand)  Währung: \(first.waehrung)")
            print("  Kurs: \(first.kurs ?? 0)  Devisenkurs: \(first.devisenkurs ?? 0)")
            print("  Marktwert EUR: \(first.marktwertEUR?.description ?? "nil")")
            print("  Gattung: \(first.gattung)  Depot/Portfolio: \(first.depotPortfolioName)")
            print("  importDatum: \(first.importDatum)")
            print("================================================================")
        }
        
        // Hinweiszeilen (allgemeine Hinweise ohne Bestand/Marktwert) ausfiltern – keine echten Depotpositionen
        alleNeuenAktien = alleNeuenAktien.filter { $0.bestand > 0 && $0.marktwertEUR != nil }
        
        // Neue Positionen einfügen bzw. Watchlist aktualisieren (nur eingefügte für Abgleich/Stats nutzen)
        var eingefuegteAktien: [Aktie] = []
        for neueAktie in alleNeuenAktien {
            let nIsin = neueAktie.isin.trimmingCharacters(in: .whitespaces)
            let nWkn = neueAktie.wkn.trimmingCharacters(in: .whitespaces)
            if let watchlist = alteAktien.first(where: { w in
                w.isWatchlist && ((!nIsin.isEmpty && w.isin.trimmingCharacters(in: .whitespaces) == nIsin) || (!nWkn.isEmpty && w.wkn.trimmingCharacters(in: .whitespaces) == nWkn))
            }) {
                watchlist.kurs = neueAktie.kurs
                watchlist.devisenkurs = neueAktie.devisenkurs
                watchlist.marktwertEUR = neueAktie.marktwertEUR
                if !neueAktie.bezeichnung.isEmpty { watchlist.bezeichnung = neueAktie.bezeichnung }
                continue
            }
            modelContext.insert(neueAktie)
            eingefuegteAktien.append(neueAktie)
        }
        alleNeuenAktien = eingefuegteAktien
        
        do {
            try modelContext.save()
        } catch {
            clearPendingKurszielAfterImport()
            importMessage = "Speicherfehler beim Einlesen: \(error.localizedDescription)"
            showImportMessage = true
            return
        }
        
        // Gespeicherte manuelle Kursziele (nach „Löschen und Kursziele merken“) wieder zuordnen
        let wiederZugeordnet = applySavedManualKursziele(to: alleNeuenAktien)
        
        // Abgleich: Bei „Fester Wert“ für BL spielt die BL aus der Datei keine Rolle – Suche und Löschen nur mit festem Wert + WKN/ISIN.
        let festeBL = BankStore.fixedBankleistungsnummer(for: BankStore.selectedBankId)
        let csvBankleistungsnummern = Set(alleNeuenAktien.map { $0.bankleistungsnummer.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty })
        /// Set aus (WKN, ISIN) der neuen Zeilen für Lösch-Logik bei festem BL (alte Sätze mit gleicher WKN/ISIN ersetzen).
        let neueWknIsinSet: Set<String> = {
            var s = Set<String>()
            for a in alleNeuenAktien {
                let w = a.wkn.trimmingCharacters(in: .whitespaces)
                let i = a.isin.trimmingCharacters(in: .whitespaces)
                if !w.isEmpty || !i.isEmpty { s.insert("\(w)|\(i)") }
            }
            return s
        }()
        
        // 2. Vergleiche alt/neu: previousMarktwertEUR, previousBestand, previousKurs, Kursziel etc. von alter Position übernehmen
        // Immer nur die Kombination (Bankleistungsnummer + WKN oder ISIN) – andere Kombinationen gelten nicht. Bei festem BL: Such-BL = fester Wert (BL aus Datei ignoriert).
        for neue in alleNeuenAktien {
            let bl = neue.bankleistungsnummer.trimmingCharacters(in: .whitespaces)
            let wkn = neue.wkn.trimmingCharacters(in: .whitespaces)
            let isin = neue.isin.trimmingCharacters(in: .whitespaces)
            let suchBL = festeBL ?? bl  // Bei festem BL: Such-BL = fester Wert
            
            if let alte = alteAktien.first(where: { alteAktie in
                let alteBL = alteAktie.bankleistungsnummer.trimmingCharacters(in: .whitespaces)
                let alteWKN = alteAktie.wkn.trimmingCharacters(in: .whitespaces)
                let alteISIN = alteAktie.isin.trimmingCharacters(in: .whitespaces)
                let blMatch = !suchBL.isEmpty && !alteBL.isEmpty && alteBL == suchBL
                let wknMatch = !wkn.isEmpty && !alteWKN.isEmpty && wkn == alteWKN
                let isinMatch = !isin.isEmpty && !alteISIN.isEmpty && isin == alteISIN
                return blMatch && (wknMatch || isinMatch)
            }) {
                // Alte Werte von der gefundenen Position (gleiche BL + WKN/ISIN) übernehmen
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
        
        // 3. Alte Zeilen löschen: Bei festem BL alle alten Sätze mit fester BL oder mit gleicher WKN/ISIN wie die neue Einlesung (BL aus Datei spielt keine Rolle). Sonst: nur alte mit BL aus der neuen CSV löschen.
        for alte in alteAktien {
            if alte.isWatchlist { continue }
            let alteBL = alte.bankleistungsnummer.trimmingCharacters(in: .whitespaces)
            let alteWkn = alte.wkn.trimmingCharacters(in: .whitespaces)
            let alteIsin = alte.isin.trimmingCharacters(in: .whitespaces)
            if let feste = festeBL {
                let hatFesteBL = !alteBL.isEmpty && alteBL == feste
                let inNeuerEinlesung = neueWknIsinSet.contains("\(alteWkn)|\(alteIsin)")
                if hatFesteBL || inNeuerEinlesung {
                    modelContext.delete(alte)
                }
            } else {
                if !alteBL.isEmpty && csvBankleistungsnummern.contains(alteBL) {
                    modelContext.delete(alte)
                }
            }
        }
        
        let gesamtwertAktuelleEinlesung = alleNeuenAktien.compactMap { $0.marktwertEUR }.reduce(0, +)
        let datumVoreinlesung = importSummaries.first?.importDatum
        let runId = UUID()
        let summary = ImportSummary(gesamtwertVoreinlesung: gesamtwertVoreinlesung, gesamtwertAktuelleEinlesung: gesamtwertAktuelleEinlesung, datumVoreinlesung: datumVoreinlesung, datumAktuelleEinlesung: einleseDatum, importBankId: BankStore.selectedBankId, importRunId: runId)
        modelContext.insert(summary)
        // Pro Position Snapshot für Verlauf/Charts (Kurs, Kursziel, Abstand) – mit Lauf-ID, damit mehrere Läufe pro Tag getrennt sind
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
                abstandPct: abstand,
                importRunId: runId
            )
            modelContext.insert(snap)
        }
        // Nur die letzten N Einlesungen behalten; darüber hinaus entfällt die älteste (importSummaries hat noch den Stand vor dem Insert)
        let ueberzaehlige = Array(importSummaries.dropFirst(maxAnzahlEinlesungen))
        for oldSummary in ueberzaehlige {
            let snapsToDelete: [ImportPositionSnapshot]
            if let oldRunId = oldSummary.importRunId {
                snapsToDelete = (try? modelContext.fetch(FetchDescriptor<ImportPositionSnapshot>(predicate: #Predicate<ImportPositionSnapshot> { $0.importRunId == oldRunId }))) ?? []
            } else {
                let dateToRemove = oldSummary.datumAktuelleEinlesung
                snapsToDelete = (try? modelContext.fetch(FetchDescriptor<ImportPositionSnapshot>(predicate: #Predicate<ImportPositionSnapshot> { $0.importDatum == dateToRemove }))) ?? []
            }
            for s in snapsToDelete { modelContext.delete(s) }
            modelContext.delete(oldSummary)
        }
        
        do {
            try modelContext.save()
        } catch {
            clearPendingKurszielAfterImport()
            importMessage = "Speicherfehler: \(error.localizedDescription)"
            showImportMessage = true
            return
        }
        
        if let fp = currentFingerprint {
            BankStore.saveCSVFingerprint(fp, for: BankStore.selectedBankId)
        }
        
        BankStore.addEingeleseneDateinamen(urlsToProcess.map { $0.lastPathComponent })
        let eingeleseneDateinamen = urlsToProcess.map { $0.lastPathComponent }
        var message = "\(alleNeuenAktien.count) Aktien in der Liste (\(zeilenVerarbeitet) Zeilen aus CSV verarbeitet)."
        if !eingeleseneDateinamen.isEmpty {
            message += "\n\nEingelesen: \(eingeleseneDateinamen.joined(separator: ", "))"
        }
        let querstrich = "\n\n━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\n\nHinweis:\n"
        var hinweisTeile: [String] = []
        if !eingeleseneDateinamen.isEmpty {
            hinweisTeile.append("Eingelesene Dateien werden nach dem Import umbenannt (EX_…) oder – falls nicht möglich – gelöscht, damit Sie in der Dateien-App sehen, was schon verarbeitet wurde.")
        }
        if alleNeuenAktien.isEmpty, let diag = firstFailureDiagnosticAny {
            let filePart = firstFailureFileAny.map { " (\($0))" } ?? ""
            let linePart = firstFailureLineAny.map { " Zeile \($0):" } ?? ""
            hinweisTeile.append("► Erste fehlgeschlagene Einlesezeile\(filePart)\(linePart) \(diag)")
        }
        if wiederZugeordnet > 0 {
            hinweisTeile.append("\(wiederZugeordnet) manuelle Kursziele wieder zugeordnet (gemerkt nach „Alles löschen“).")
        }
        if !parseHinweise.isEmpty {
            hinweisTeile.append(parseHinweise.joined(separator: "\n"))
        }
        if !errors.isEmpty {
            hinweisTeile.append("Fehler:\n" + errors.joined(separator: "\n"))
        }
        if alleNeuenAktien.isEmpty {
            hinweisTeile.append("Unter Einstellungen → \(BankStore.selectedBank.name) → Spalten zuordnen prüfen. Pflicht: Bankleistungsnummer (Spalte A/B/C oder Fester Wert, z. B. = Ihre Kontonummer oder 1), Bezeichnung (Spalte), Bestand (Spalte), WKN (Spalte). Jede Zuordnung bedeutet: aus der gewählten Spalte wird Text in das App-Feld gelesen – falsche Spalte = keine gültige Zeile.")
            if let preview = firstFilePreviewAny {
                hinweisTeile.append("Dateivorschau (was die App liest):\n\(preview)")
            }
        }
        if !hinweisTeile.isEmpty {
            message += querstrich + hinweisTeile.joined(separator: "\n\n")
        }
        
        // Kurszielermittlung erst nach OK auf dem Import-Alert starten; bei Daten vor Tagesdatum vorher abfragen.
        let sollAktualisieren: (Aktie) -> Bool = { a in
            if forceOverwriteAllKursziele || !csvHadKursziele { return !a.kurszielManuellGeaendert }
            guard !a.kurszielManuellGeaendert else { return false }
            let keinWert = a.kursziel == nil || (a.kursziel ?? 0) == 0
            return a.kurszielQuelle != "C" || keinWert
        }
        let brauchtKursziel = !csvHadKursziele || !alleNeuenAktien.filter(sollAktualisieren).isEmpty
        let startOfToday = Calendar.current.startOfDay(for: Date())
        let alteDatenMitImport = einleseDatum < startOfToday && !alleNeuenAktien.isEmpty
        let sollAbfragenOderStarten = (brauchtKursziel || alteDatenMitImport)
        let kurszielHadKursziele = csvHadKursziele
        let kurszielForceOverwrite = forceOverwriteAllKursziele || !csvHadKursziele
        let kurszielImportDatum = einleseDatum
        let kurszielAltesDatum = einleseDatum < startOfToday

        // Alert erst im nächsten Run-Loop anzeigen, damit der Datei-Picker vollständig geschlossen ist (sonst erscheint die Maske erst nach Tipp auf Seitenwechsel, v. a. iPad).
        Task { @MainActor in
            importMessage = message
            showImportMessage = true
            if sollAbfragenOderStarten {
                lastImportHadCSVKursziele = kurszielHadKursziele
                pendingKurszielForceOverwrite = kurszielForceOverwrite
                pendingKurszielImportDatum = kurszielImportDatum
                if kurszielAltesDatum {
                    showKurszielAbfrageBeiAltemDatum = true
                } else {
                    pendingKurszielFetchAfterImport = true
                }
            }
        }
    }
    
    /// Setzt alle „nach Import“-Kursziel-Zustände zurück, damit beim nächsten OK keine Kurszielermittlung startet (z. B. bei Format-Dialog oder Import-Fehler).
    private func clearPendingKurszielAfterImport() {
        pendingKurszielFetchAfterImport = false
        showKurszielAbfrageBeiAltemDatum = false
        pendingKurszielImportDatum = nil
        pendingKurszielForceOverwrite = false
    }
    
    private func startPendingKurszielFetch() {
        KurszielService.clearCachesForApiCalls()
        let forceOverwrite = pendingKurszielForceOverwrite
        let sollAktualisieren: (Aktie) -> Bool = { a in
            if forceOverwrite { return !a.kurszielManuellGeaendert }
            guard !a.kurszielManuellGeaendert else { return false }
            // Auch aus CSV (C): ermitteln, wenn Kursziel fehlt oder 0 ist
            let keinWert = a.kursziel == nil || (a.kursziel ?? 0) == 0
            return a.kurszielQuelle != "C" || keinWert
        }
        let list = aktien.filter(sollAktualisieren)
        let importDate = pendingKurszielImportDatum
        if !list.isEmpty {
            Task { await fetchKurszieleForAktien(list, forceOverwrite: forceOverwrite, snapshotImportDatum: importDate) }
        }
        pendingKurszielImportDatum = nil
    }
    
    /// Kurszielermittlung manuell starten (z. B. nach Unterbrechung durch Home-Button). Verwendet dieselbe Logik wie nach Import; Einstellung „Alle Kursziele überschreiben“ wird beachtet.
    private func startKurszielErmittlungManuell() {
        let forceOverwrite = forceOverwriteAllKursziele
        let sollAktualisieren: (Aktie) -> Bool = { a in
            if forceOverwrite { return !a.kurszielManuellGeaendert }
            guard !a.kurszielManuellGeaendert else { return false }
            let keinWert = a.kursziel == nil || (a.kursziel ?? 0) == 0
            return a.kurszielQuelle != "C" || keinWert
        }
        let list = aktien.filter(sollAktualisieren)
        let importDate = importSummaries.first?.datumAktuelleEinlesung
        if list.isEmpty {
            importMessage = "Keine Positionen zum Aktualisieren (alle manuell gesetzt oder bereits mit Kursziel)."
            showImportMessage = true
        } else {
            Task { await fetchKurszieleForAktien(list, forceOverwrite: forceOverwrite, snapshotImportDatum: importDate) }
        }
    }
    
    private func fetchKurszieleViaOpenAI() {
        KurszielService.clearCachesForApiCalls()
        KurszielService.resetZugriffeStatistik()
        guard !openAIAPIKeyStore.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        KurszielService.openAIAPIKey = openAIAPIKeyStore.trimmingCharacters(in: .whitespaces)
        isImportingKurszieleOpenAI = true
        aktuelleKurszielAktie = nil
        Task {
            let keinKurszielWert: (Aktie) -> Bool = { $0.kursziel == nil || ($0.kursziel ?? 0) == 0 }
            let zuAktualisieren = aktien.filter { forceOverwriteAllKursziele || (!$0.kurszielManuellGeaendert && ($0.kurszielQuelle != "C" || keinKurszielWert($0))) }
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
        KurszielService.resetZugriffeStatistik()
        await MainActor.run { 
            isImportingKursziele = true
            aktuelleKurszielAktie = nil
        }
        KurszielService.clearDebugLog()
        // Bei automatischer Einlesung: keinen Dialog anzeigen, OpenAI-Ersatz nicht übernehmen (nur Werte übernehmen, die realistisch sind)
        KurszielService.onUnrealistischErsatzBestätigen = { _, _, _ in false }
        
        // Nicht überschreiben: manuell geändert; oder aus CSV (C) mit gültigem Wert. Bei Quelle C mit leer/0 trotzdem ermitteln.
        let sollUeberschreiben: (Aktie) -> Bool = { a in
            if forceOverwrite { return !a.kurszielManuellGeaendert }
            if a.kurszielManuellGeaendert { return false }
            if a.kursziel == nil { return true }
            if (a.kursziel ?? 0) == 0 { return true }  // CSV-Spalte da, aber Wert 0 → trotzdem ermitteln
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
            
            // Nur bei Treffer eintragen; kein Treffer → Vortag/Kursziel bleibt erhalten (nichts löschen)
            let fmpVorab = fmpCache[aktie.wkn]
            let info = await KurszielService.fetchKursziel(for: aktie, fmpResult: fmpVorab)
            if let info = info {
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
            do {
                let snapDesc = FetchDescriptor<ImportPositionSnapshot>()
                let allSnaps = try modelContext.fetch(snapDesc)
                for s in allSnaps { modelContext.delete(s) }
                let summaryDesc = FetchDescriptor<ImportSummary>()
                let allSummaries = try modelContext.fetch(summaryDesc)
                for s in allSummaries { modelContext.delete(s) }
                let aktienDesc = FetchDescriptor<Aktie>()
                let allAktien = try modelContext.fetch(aktienDesc)
                for a in allAktien { modelContext.delete(a) }
                try modelContext.save()
                KurszielService.resetZugriffeStatistik()
            } catch {
                importMessage = "Beim Löschen ist ein Fehler aufgetreten: \(error.localizedDescription)"
                showImportMessage = true
            }
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
    @Binding var scrollToDetailKey: String?
    /// Detail-Key (BL|ISIN) der zuletzt gewählten Position → Zeile markieren (gleiche ISIN in mehreren BL eindeutig)
    var markedDetailKey: String? = nil
    var onCopyDetailKey: ((String) -> Void)? = nil
    var onRowEdited: ((String) -> Void)? = nil
    var onKurszielSuchenTapped: ((String) -> Void)? = nil
    @Environment(\.modelContext) private var modelContext
    @State private var showDebugLog = false
    private let finanzenNetAnalysenURL = URL(string: "https://www.finanzen.net/analysen")!
    private func rowKey(aktie: Aktie) -> String { "\(aktie.bankleistungsnummer)|\(aktie.isin)|\(aktie.wkn)" }
    
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
                        let key = rowKey(aktie: aktie)
                        KurszielZeileView(aktie: aktie, modelContext: modelContext, detailKey: key, isMarked: markedDetailKey == key, onCopyDetailKey: onCopyDetailKey, onRowEdited: onRowEdited, onKurszielSuchenTapped: onKurszielSuchenTapped)
                            .id(key)
                    }
                } header: {
                    Text("Kursziele")
                } footer: {
                    Text("Gelber Stern = zuletzt geöffnete Position. ISIN antippen → Kopieren. Kursziel bearbeiten wirkt wie auf der Detailseite (manuell). Tastatur: «Fertig» oder nach unten scrollen.")
                        .foregroundStyle(Color.primary.opacity(0.72))
                }
            }
            #if os(iOS)
            .scrollContentBackground(.hidden)
            .background(Color(uiColor: .tertiarySystemGroupedBackground))
            #endif
            .onChange(of: scrollToDetailKey) { _, key in
                guard let key = key, !key.isEmpty else { return }
                DispatchQueue.main.async {
                    proxy.scrollTo(key, anchor: .center)
                    scrollToDetailKey = nil
                }
            }
            .onAppear {
                if let key = scrollToDetailKey, !key.isEmpty {
                    DispatchQueue.main.async {
                        proxy.scrollTo(key, anchor: .center)
                        scrollToDetailKey = nil
                    }
                }
            }
        }
        .scrollDismissesKeyboard(.interactively)
        .navigationTitle("Kursziele · \(BankStore.selectedBank.name)")
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
    /// Eindeutiger Schlüssel (BL|ISIN) für Scroll/Markierung bei gleicher ISIN in mehreren BL
    var detailKey: String = ""
    var isMarked: Bool = false
    var onCopyDetailKey: ((String) -> Void)? = nil
    var onRowEdited: ((String) -> Void)? = nil
    var onKurszielSuchenTapped: ((String) -> Void)? = nil
    @AppStorage(KurszielService.fmpAPIKeyKey) private var fmpAPIKeyStore: String = ""
    @AppStorage(KurszielService.openAIAPIKeyKey) private var openAIAPIKeyStore: String = ""
    @State private var showZwischenablageFeedback = false
    @State private var showChatGPTPromptFeedback = false
    @State private var showFMPTest = false
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
    
    /// Besser lesbar auf iPad (grauer Listen-Hintergrund) als .secondary
    private var kurszielSecondary: Color { Color.primary.opacity(0.65) }
    
    private var istFonds: Bool { aktie.istFonds }
    
    private func googleKurszielURL(isin: String) -> URL {
        let query = (isin + " Kursziel").addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? (isin + " Kursziel")
        return URL(string: "https://www.google.com/search?q=\(query)")!
    }
    
    /// Zwischenablage: ISIN + durchschnittliches Kursziel
    private var zwischenablageText: String {
        var t = "ISIN: \(aktie.isin)\ndurchschnittliches Kursziel:"
        if let kz = aktie.kursziel, kz > 0 {
            t += " \(formatBetragDE(kz)) \(aktie.kurszielWaehrung ?? "EUR")"
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
        onCopyDetailKey?(detailKey)
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
    
    @ViewBuilder
    private var kurszielEingabeZeile: some View {
        HStack(alignment: .center, spacing: 12) {
            Text("Kursziel")
                .font(.caption)
                .foregroundColor(kurszielSecondary)
            #if os(iOS)
            StableDecimalFieldWithFertig(
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
                        onRowEdited?(detailKey)
                    }
                ),
                onCommit: { onRowEdited?(detailKey) }
            )
            .frame(maxWidth: 100)
            #else
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
                        onRowEdited?(detailKey)
                    }
                )
            )
            .frame(maxWidth: 100)
            #endif
            Text("EUR")
                .font(.caption)
                .foregroundColor(.secondary)
            if aktie.waehrung.uppercased() != "EUR" {
                #if os(iOS)
                StableDecimalFieldWithFertig(
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
                            onRowEdited?(detailKey)
                        }
                    ),
                    onCommit: { onRowEdited?(detailKey) }
                )
                .frame(maxWidth: 100)
                #else
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
                            onRowEdited?(detailKey)
                        }
                    )
                )
                .frame(maxWidth: 100)
                #endif
                Text(aktie.waehrung)
                    .font(.caption)
                    .foregroundColor(kurszielSecondary)
            }
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
                        Text("Kurs: \(formatBetragDE(kurs, decimals: 4)) \(aktie.waehrung)")
                            .font(.caption2)
                            .foregroundColor(kurszielSecondary)
                    }
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 2) {
                    Group {
                        if aktie.kursziel == nil || (aktie.kursziel ?? 0) == 0 {
                            Text("Kein Kursziel")
                                .foregroundColor(kurszielSecondary)
                        } else if aktie.zeigeAlsUnrealistisch {
                            Text("Unrealistisch")
                                .foregroundColor(.orange)
                        } else {
                            Text("Realistisch")
                                .foregroundColor(.green)
                        }
                    }
                    .font(.caption)
                    if let q = aktie.kurszielQuelle {
                        VStack(alignment: .trailing, spacing: 2) {
                            Text(KurszielQuelle.label(for: q, manuell: aktie.kurszielManuellGeaendert))
                                .font(.caption2)
                                .foregroundColor(kurszielSecondary)
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
                            .foregroundColor(kurszielSecondary)
                    }
                }
            }
            
            VStack(alignment: .leading, spacing: 8) {
                kurszielEingabeZeile
                // FMP testen + OpenAI + Aus Datei + Snippet (nur Fonds) + Kursziel suchen
                HStack {
                    Spacer()
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
                        onKurszielSuchenTapped?(detailKey)
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
        #if os(iOS)
        .listRowBackground(isMarked ? Color.accentColor.opacity(0.2) : Color(uiColor: .systemBackground))
        #else
        .listRowBackground(isMarked ? Color.accentColor.opacity(0.2) : Color.clear)
        #endif
        .sheet(isPresented: $showFMPTest) {
            FMPTestSheetView(aktie: aktie, modelContext: modelContext, detailKey: detailKey, onRowEdited: onRowEdited)
        }
        .sheet(isPresented: $showSnippetTest) {
            SnippetTestSheetView(aktie: aktie, modelContext: modelContext, detailKey: detailKey, onRowEdited: onRowEdited)
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
                    onRowEdited?(detailKey)
                }
                pendingKurszielFromFile = nil
            }
            Button("Nein", role: .cancel) {
                pendingKurszielFromFile = nil
            }
        } message: {
            if let kz = pendingKurszielFromFile {
                Text("Kursziel \(formatBetragDE(kz)) EUR aus Datei übernehmen?")
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
                    onRowEdited?(detailKey)
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
                Text("\(aktie.bezeichnung): Kursziel \(formatBetragDE(info.kursziel)) \(info.waehrung ?? "EUR") von OpenAI übernehmen?")
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
        KurszielQuelle.label(for: code, manuell: manuell)
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
    @State private var isLoadingISIN = false
    @State private var isinLookupError: String?
    
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
                    HStack {
                        Text(aktie.isin.isEmpty ? "—" : aktie.isin)
                        Spacer()
                        if !aktie.wkn.trimmingCharacters(in: .whitespaces).isEmpty && aktie.isin.trimmingCharacters(in: .whitespaces).isEmpty {
                            Button {
                                Task { await isinErmitteln() }
                            } label: {
                                if isLoadingISIN {
                                    ProgressView().scaleEffect(0.8)
                                } else {
                                    Text("ISIN ermitteln")
                                        .font(.caption)
                                }
                            }
                            .disabled(isLoadingISIN)
                        } else if !aktie.isin.trimmingCharacters(in: .whitespaces).isEmpty {
                            Button("Zurücksetzen") {
                                aktie.isin = ""
                                isinLookupError = nil
                                try? modelContext.save()
                            }
                            .font(.caption)
                            .foregroundColor(.secondary)
                        }
                    }
                }
                if let err = isinLookupError {
                    Text(err)
                        .font(.caption)
                        .foregroundColor(.red)
                }
                LabeledContent("Währung") {
                    Text(aktie.waehrung)
                }
                LabeledContent("Bestand") {
                    Text(formatBetragDE(aktie.bestand))
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
                        Text(formatBetragDE(einstandskurs, decimals: 4))
                    }
                }
                if let kurs = aktie.kurs {
                    LabeledContent("Aktueller Kurs") {
                        Text(formatBetragDE(kurs, decimals: 4))
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
                            Text(KurszielQuelle.label(for: quelle, manuell: false))
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
                    Text("(\(differenz >= 0 ? "+" : "")\(formatBetragDE(differenzProzent, decimals: 1))% zum Ziel)")
                        .font(.caption)
                        .foregroundColor(differenz >= 0 ? .green : .red)
                }
                if let abstand = aktie.kurszielAbstand {
                    LabeledContent("Abstand Analysten (Ø)") {
                        Text("\(abstand >= 0 ? "+" : "")\(formatBetragDE(abstand, decimals: 1))%")
                            .foregroundColor(.secondary)
                    }
                }
                if aktie.kurszielQuelle == "M" {
                    let w = aktie.kurszielWaehrung ?? aktie.waehrung
if let high = aktie.kurszielHigh { LabeledContent("Hochziel") { Text("\(formatBetragDE(high)) \(w)") } }
    if let low = aktie.kurszielLow { LabeledContent("Niedrigziel") { Text("\(formatBetragDE(low)) \(w)") } }
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
                        Text("\(formatBetragDE(gewinnEUR)) €")
                            .foregroundColor(gewinnEUR >= 0 ? .green : .red)
                    }
                }
                if let gewinnProzent = aktie.gewinnVerlustProzent {
                    LabeledContent("Gewinn/Verlust (%)") {
                        Text("\(formatBetragDE(gewinnProzent)) %")
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
                            Text(formatBetragDE(bestandAlt))
                        }
                    }
                    if let marktwertAlt = aktie.previousMarktwertEUR {
                        LabeledContent("Marktwert Alt") {
                            Text("\(formatBetragDE(marktwertAlt)) €")
                        }
                    }
                    if let kursAlt = aktie.previousKurs {
                        LabeledContent("Kurs Alt") {
                            Text(formatBetragDE(kursAlt, decimals: 4))
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
    
    @MainActor
    private func isinErmitteln() async {
        let wkn = aktie.wkn.trimmingCharacters(in: .whitespaces)
        guard !wkn.isEmpty else { return }
        isLoadingISIN = true
        isinLookupError = nil
        defer { isLoadingISIN = false }
        if let isin = await KurszielService.fetchISINFromWKN(wkn: wkn) {
            aktie.isin = isin
            try? modelContext.save()
        } else {
            isinLookupError = "ISIN konnte nicht ermittelt werden."
        }
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
    var detailKey: String = ""
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
                            Text("Kursziel: \(formatBetragDE(result.kursziel)) \(result.waehrung ?? "EUR")")
                                .font(.headline)
                            if let h = result.kurszielHigh, let l = result.kurszielLow {
                                Text("High: \(formatBetragDE(h)) | Low: \(formatBetragDE(l))")
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
                            onRowEdited?(detailKey)
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

/// Schwellwert: Kursziel über 1 Mio. wird als unrealistisch behandelt (finanzen.net-Parsefehler o. ä.)
private let kurszielUnrealistischSchwellwert: Double = 1_000_000

/// Sheet zum finanzen.net-Abruf testen mit Debug-Ausgabe (pro Aktie auf der Kursziele-Karte)
private struct FinanzenNetTestSheetView: View {
    @Bindable var aktie: Aktie
    var modelContext: ModelContext
    var detailKey: String = ""
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
                            if info.kursziel > kurszielUnrealistischSchwellwert {
                                Text("Unrealistisch")
                                    .font(.headline)
                                    .foregroundColor(.secondary)
                            } else {
                                Text("Kursziel: \(formatBetragDE(info.kursziel)) \(info.waehrung ?? "EUR")")
                                    .font(.headline)
                                if let abstand = info.spalte4Durchschnitt {
                                    Text("Abstand: \(abstand >= 0 ? "+" : "")\(formatBetragDE(abstand, decimals: 1))%")
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                }
                            }
                        }
                        if info.kursziel <= kurszielUnrealistischSchwellwert {
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
                                onRowEdited?(detailKey)
                                dismiss()
                            }
                            .buttonStyle(.borderedProminent)
                        }
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
    var detailKey: String = ""
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
                            Text("Kursziel: \(formatBetragDE(info.kursziel)) \(info.waehrung ?? "EUR")")
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
                            onRowEdited?(detailKey)
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
                        rechtlichesLinks
                        TextEditor(text: $editableText)
                            .font(.body)
                            .padding(.horizontal, 4)
                            .onAppear {
                                if !hasLoaded {
                                    editableText = rechtlichesText.isEmpty ? defaultRechtlichesText : rechtlichesText
                                    hasLoaded = true
                                }
                            }
                    }
                } else {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 20) {
                            rechtlichesLinks
                            Text(displayText)
                                .font(.body)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .textSelection(.enabled)
                        }
                        .padding()
                    }
                }
            }
            .navigationTitle("Rechtliches · \(BankStore.selectedBank.name)")
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

// MARK: - Quick Look für gebündelte Word/PDF (Programm-Beschreibung)
#if os(iOS)
private struct DocumentPreviewViewController: UIViewControllerRepresentable {
    let url: URL

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    func makeUIViewController(context: Context) -> QLPreviewController {
        let controller = QLPreviewController()
        controller.dataSource = context.coordinator
        return controller
    }

    func updateUIViewController(_ uiViewController: QLPreviewController, context: Context) {}

    class Coordinator: NSObject, QLPreviewControllerDataSource {
        let parent: DocumentPreviewViewController
        init(parent: DocumentPreviewViewController) { self.parent = parent }
        func numberOfPreviewItems(in controller: QLPreviewController) -> Int { 1 }
        func previewController(_ controller: QLPreviewController, previewItemAt index: Int) -> QLPreviewItem {
            parent.url as NSURL
        }
    }
}
#endif

// MARK: - Programm-Beschreibung (Startseite, Buch-Symbol; getrennt von Rechtliches, großer Bereich)
/// Word-Datei anbinden: Im Xcode-Projekt die .docx-Datei per Drag & Drop in den Projektnavigator legen, „Copy items if needed“ und Target „Aktien“ aktivieren. Dateiname exakt: Programmbeschreibung.docx (oder Namen unten anpassen).
private let programmBeschreibungBundleName = "Programmbeschreibung"
private let programmBeschreibungBundleExtension = "docx"

private let defaultProgrammBeschreibungText = """
Programm-Beschreibung und Funktionsweise

Hier können Sie eine ausführliche Beschreibung der App, der Bedienung und der Funktionen hinterlegen.

• Startseite: Bank auswählen, CSV-Spalten zuordnen (bei anderen Banken), „Einlesen“ startet den Import für die gewählte Bank.
• Nach „Start“: Aktienliste, Verlauf, Kursziele; „Statistik“ für Einlesungen; Einstellungen für API-Keys und CSV-Zuordnung.
• Fester Wert (z. B. Bankleistungsnummer): In der CSV-Zuordnung „Fester Wert“ wählen – gilt für alle Zeilen dieser Bank.
• Einlesung löschen: In der Statistik pro Einlesung möglich; löscht alle zugehörigen Positionen (gleiches Datum).

Im Entwicklermodus (Einstellungen) ist dieser Text bearbeitbar und wird gespeichert.
"""

#if os(iOS)
private struct BundledDocumentSheetView: View {
    let url: URL
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            DocumentPreviewViewController(url: url)
                .ignoresSafeArea(.container)
                .navigationTitle("Programm-Beschreibung")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Schließen") { dismiss() }
                    }
                }
        }
    }
}
#endif

struct ProgrammBeschreibungSheetView: View {
    @Environment(\.dismiss) private var dismiss
    @AppStorage("ProgrammBeschreibungText") private var programmBeschreibungText = ""
    @AppStorage("Entwicklermodus") private var entwicklermodus = false
    @State private var editableText = ""
    @State private var hasLoaded = false
    @State private var showBundledDocument = false

    private var displayText: String {
        programmBeschreibungText.isEmpty ? defaultProgrammBeschreibungText : programmBeschreibungText
    }

    private var bundledDocumentURL: URL? {
        #if os(iOS)
        return Bundle.main.url(forResource: programmBeschreibungBundleName, withExtension: programmBeschreibungBundleExtension)
        #else
        return nil
        #endif
    }

    var body: some View {
        NavigationStack {
            Group {
                if entwicklermodus {
                    VStack(spacing: 0) {
                        if bundledDocumentURL != nil {
                            Button {
                                showBundledDocument = true
                            } label: {
                                Label("Vollständige Beschreibung (Word) öffnen", systemImage: "doc.fill")
                                    .frame(maxWidth: .infinity)
                                    .padding(.vertical, 8)
                            }
                            .buttonStyle(.bordered)
                            .padding(.horizontal, 16)
                            .padding(.top, 12)
                        }
                        TextEditor(text: $editableText)
                            .font(.body)
                            .padding(16)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                            .onAppear {
                                if !hasLoaded {
                                    editableText = programmBeschreibungText.isEmpty ? defaultProgrammBeschreibungText : programmBeschreibungText
                                    hasLoaded = true
                                }
                            }
                    }
                } else {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 16) {
                            if bundledDocumentURL != nil {
                                Button {
                                    showBundledDocument = true
                                } label: {
                                    Label("Vollständige Beschreibung (Word) öffnen", systemImage: "doc.fill")
                                        .font(.headline)
                                        .frame(maxWidth: .infinity)
                                        .padding(.vertical, 12)
                                }
                                .buttonStyle(.borderedProminent)
                                Divider()
                            }
                            Text(displayText)
                                .font(.body)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .textSelection(.enabled)
                        }
                        .padding(24)
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .navigationTitle("Programm-Beschreibung")
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
                            programmBeschreibungText = editableText
                            dismiss()
                        }
                    }
                }
            }
        }
        #if os(iOS)
        .sheet(isPresented: $showBundledDocument) {
            if let url = bundledDocumentURL {
                BundledDocumentSheetView(url: url)
            }
        }
        #endif
        .onAppear {
            if entwicklermodus && !hasLoaded {
                editableText = programmBeschreibungText.isEmpty ? defaultProgrammBeschreibungText : programmBeschreibungText
                hasLoaded = true
            }
        }
    }
}

/// Sheet zum Teilen/Speichern der exportierten CSV
struct ExportCSVShareSheet: View {
    let fileURL: URL
    var onDismiss: () -> Void = {}
    
    var body: some View {
        #if os(iOS)
        ShareSheetController(activityItems: [fileURL]) {
            onDismiss()
        }
        #elseif os(macOS)
        VStack(spacing: 20) {
            Image(systemName: "doc.text")
                .font(.system(size: 40))
                .foregroundColor(.accentColor)
            Text("CSV exportiert")
                .font(.headline)
            Text(fileURL.lastPathComponent)
                .font(.caption)
                .foregroundColor(.secondary)
                .lineLimit(2)
                .multilineTextAlignment(.center)
            Text("Über „Im Finder anzeigen“ können Sie die Datei prüfen oder weitergeben.")
                .font(.caption)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
            HStack(spacing: 16) {
                Button("Im Finder anzeigen") {
                    NSWorkspace.shared.activateFileViewerSelecting([fileURL])
                    onDismiss()
                }
                .buttonStyle(.borderedProminent)
                Button("Schließen") { onDismiss() }
                    .buttonStyle(.bordered)
            }
        }
        .padding(32)
        .frame(minWidth: 320, minHeight: 200)
        #endif
    }
}

#if os(iOS)
private struct ShareSheetController: UIViewControllerRepresentable {
    let activityItems: [Any]
    var onDismiss: (() -> Void)?
    
    func makeUIViewController(context: Context) -> UIActivityViewController {
        let vc = UIActivityViewController(activityItems: activityItems, applicationActivities: nil)
        vc.completionWithItemsHandler = { _, _, _, _ in onDismiss?() }
        return vc
    }
    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}
#endif

struct CSVSpaltenZuordnungView: View {
    let bank: Bank
    @State private var mapping: [String: String] = [:]
    @State private var fieldSeparator = "auto"
    @State private var decimalSeparator = "german"
    @State private var kontoFilterText = ""
    @Environment(\.dismiss) private var dismiss
    
    private func binding(for id: String) -> Binding<String> {
        Binding(
            get: { mapping[id] ?? "" },
            set: { newValue in
                var m = mapping
                if newValue.trimmingCharacters(in: .whitespaces).isEmpty, !newValue.hasPrefix("=") {
                    m.removeValue(forKey: id)
                } else {
                    m[id] = newValue.hasPrefix("=") ? newValue : newValue.trimmingCharacters(in: .whitespaces)
                }
                mapping = m
            }
        )
    }

    /// Picker-Auswahl: Spalte (A,B,C…) oder "=" für Fester Wert
    private func bindingColumnOrFixed(for id: String) -> Binding<String> {
        Binding(
            get: { (mapping[id] ?? "").hasPrefix("=") ? "=" : (mapping[id] ?? "") },
            set: { newValue in
                var m = mapping
                if newValue == "=" {
                    let rest = (mapping[id] ?? "").hasPrefix("=") ? String((mapping[id] ?? "").dropFirst(1)) : ""
                    m[id] = "=" + rest
                } else {
                    m[id] = newValue
                }
                mapping = m
            }
        )
    }

    /// Nur der Teil nach "=" (fester Wert)
    private func bindingFixedValue(for id: String) -> Binding<String> {
        Binding(
            get: {
                let v = mapping[id] ?? ""
                return v.hasPrefix("=") ? String(v.dropFirst(1)) : ""
            },
            set: { newValue in
                var m = mapping
                m[id] = "=" + newValue
                mapping = m
            }
        )
    }

    var body: some View {
        Form {
            Section {
                Text("Möglichst ISIN und WKN in der CSV mitgeben. Ohne ISIN kann die App sie aus der WKN ermitteln – bei US-/GB-ISIN kann die automatische Ermittlung jedoch falsche Werte liefern (dann in der Detailansicht „ISIN zurücksetzen“).")
                    .font(.subheadline)
                    .textSelection(.enabled)
            } header: {
                Text("CSV-Schnittstelle")
            }
            Section {
                Text("Öffnen Sie Ihre CSV in Excel, dann ordnen Sie jeder Spalte (A, B, C, … wie in Excel) das passende App-Feld zu. Aus Spalte A wird dann der Text in das zugeordnete Feld gelesen usw. Wenn die CSV ein Feld nicht hat (z. B. keine Bankleistungsnummer), wählen Sie „Fester Wert“ und tragen z. B. = Ihre Kontonummer ein oder 1. Wenn Sie Felder nicht zuordnen können – leer lassen. Wichtig: Nach dem Ändern „Speichern“ tippen – und beim Einlesen muss dieselbe Bank ausgewählt sein (Haken auf der Startseite).")
                    .font(.subheadline)
                    .textSelection(.enabled)
            } header: {
                Text("Anleitung")
            }
            Section {
                ForEach(csvSpaltenFields) { field in
                    VStack(alignment: .leading, spacing: 6) {
                        HStack(alignment: .center, spacing: 12) {
                            Text(field.label)
                                .font(.subheadline)
                                .foregroundColor(field.optional ? .secondary : .primary)
                            Spacer(minLength: 8)
                            Picker("Spalte", selection: bindingColumnOrFixed(for: field.id)) {
                                Text("—").tag("")
                                ForEach(csvColumnLetterOptions.dropFirst(), id: \.self) { letter in
                                    Text(letter).tag(letter)
                                }
                                Text("Fester Wert").tag("=")
                            }
                            .labelsHidden()
                            .pickerStyle(.menu)
                            .frame(minWidth: 100)
                        }
                        if field.id == "bankleistungsnummer" {
                            Text("Keine Depot-/BL-Nummer in der CSV? → „Fester Wert“ wählen und z. B. = Ihre Kontonummer eintragen oder 1.")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                        if (mapping[field.id] ?? "").hasPrefix("=") {
                            TextField("Fester Wert (z. B. für alle Zeilen)", text: bindingFixedValue(for: field.id))
                                .font(.subheadline)
                                .textFieldStyle(.roundedBorder)
                                .autocapitalization(.none)
                        }
                    }
                }
            } header: {
                Text("App-Feld")
            } footer: {
                Text("Spalte A/B/C = aus dieser CSV-Spalte wird der Wert ins App-Feld gelesen. „Fester Wert“ = keine Spalte, gleicher Wert für jede Zeile (z. B. Bankleistungsnummer = Ihre Kontonummer oder 1). Felder, die Sie nicht zuordnen können – leer lassen („—“). Pflicht: Bankleistungsnummer (Spalte oder Fester Wert), Bezeichnung, Bestand, WKN. ISIN optional.\n\nBeim Speichern wird diese Bank ausgewählt – der Import verwendet dann diese Zuordnung.")
            }
            Section {
                TextField("z. B. 600252636500|20070000", text: $kontoFilterText)
                    .font(.subheadline)
                    .textFieldStyle(.roundedBorder)
                    .autocapitalization(.none)
                    .autocorrectionDisabled()
            } header: {
                Text("Konto-Filter (Pflicht)")
            } footer: {
                Text("Mehrere Kontonummern/Bankleistungsnummern mit | oder Komma trennen. Ohne Eintrag wird das Einlesen abgebrochen. Enthält die Datei keine dieser Nummern (in der BL-Spalte bzw. irgendwo im Text bei „Fester Wert“), wird mit „Falsche Bank“ abgebrochen.")
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
                Text("Feldtrenner: Zeichen zwischen den Spalten. Dezimaltrennzeichen: Komma (deutsch) oder Punkt (englisch) bei Zahlen.")
            }
            Section {
                Button("Zurücksetzen (Standard Deutsche Bank / maxblue)") {
                    mapping = [:]
                }
                .foregroundColor(.orange)
            }
        }
        .navigationTitle("CSV: \(bank.name)")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Speichern") {
                    BankStore.saveCSVColumnMapping(mapping, for: bank.id)
                    BankStore.saveCSVFieldSeparator(fieldSeparator, for: bank.id)
                    BankStore.saveCSVDecimalSeparator(decimalSeparator, for: bank.id)
                    BankStore.saveKontoFilter(kontoFilterText, for: bank.id)
                    BankStore.setSelectedBank(bank)
                    NotificationCenter.default.post(name: .csvMappingDidSave, object: nil)
                    dismiss()
                }
            }
        }
        .onAppear {
            mapping = BankStore.loadCSVColumnMapping(for: bank.id)
            fieldSeparator = BankStore.loadCSVFieldSeparator(for: bank.id)
            decimalSeparator = BankStore.loadCSVDecimalSeparator(for: bank.id)
            kontoFilterText = BankStore.loadKontoFilter(for: bank.id) ?? ""
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
                            LabeledContent("Kurs", value: formatBetragDE(k) + " €")
                        } else {
                            TextField("Kurs (optional)", text: $bearbeiteterKurs)
                                .keyboardType(.decimalPad)
                        }
                        if let kz = r.kursziel {
                            LabeledContent("Kursziel", value: formatBetragDE(kz) + " €")
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
                                    Text("Kurs \(formatBetragDE(k)) € · Kursziel \(formatBetragDE(kz)) €")
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
            .navigationTitle("Watchlist · \(BankStore.selectedBank.name)")
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
                bearbeiteterKurs = r.kurs.map { formatBetragDE($0) } ?? ""
                bearbeitetesKursziel = r.kursziel.map { formatBetragDE($0) } ?? ""
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
            .navigationTitle("Debug-Log · \(BankStore.selectedBank.name)")
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
            .navigationTitle("WKN Testen · \(BankStore.selectedBank.name)")
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
                    let kurszielString = formatBetragDE(info.kursziel)
                    let waehrungAnzeige = (info.waehrung ?? "EUR") == "USD" ? "USD" : "EUR"
                    var resultText = "Kursziel gefunden: \(kurszielString) \(waehrungAnzeige) \(info.quelle.rawValue)"
                    if let sp4 = info.spalte4Durchschnitt {
                        let sp4String = formatBetragDE(sp4)
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
    @AppStorage("DebugEinlesungNurEinSatz") private var debugEinlesungNurEinSatz = false
    @AppStorage("Aktien.SubscriptionManager.simulateTrialExpired") private var simulateTrialExpired = false
    @State private var subscriptionManager = SubscriptionManager.shared
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
                    if subscriptionManager.hasActiveSubscription {
                        Label("Premium aktiv", systemImage: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                    } else if subscriptionManager.isInFreeTrialPeriod {
                        Text("Abo: Kostenlose Testwoche – noch \(subscriptionManager.trialRemainingDays) Tag\(subscriptionManager.trialRemainingDays == 1 ? "" : "e")")
                            .foregroundStyle(.secondary)
                    } else {
                        Text("Abo erforderlich (Paywall nach Start)")
                            .foregroundStyle(.secondary)
                    }
                    Button {
                        Task { await subscriptionManager.restore() }
                    } label: {
                        HStack {
                            Text("Käufe wiederherstellen")
                            if subscriptionManager.isPurchasing {
                                Spacer()
                                ProgressView()
                                    .scaleEffect(0.8)
                            }
                        }
                    }
                    .disabled(subscriptionManager.isPurchasing)
                    if entwicklermodus {
                        Toggle("Trial abgelaufen simulieren", isOn: $simulateTrialExpired)
                            .foregroundStyle(.orange)
                    }
                } header: {
                    Text("Abo")
                } footer: {
                    Text("Status der kostenlosen Woche bzw. des Abos. „Trial abgelaufen simulieren“ (nur bei Entwicklermodus): zeigt die Paywall beim nächsten Start, ohne 7 Tage zu warten – zum Testen. Abo-Kauf testen: In App Store Connect einen Sandbox-Tester anlegen; auf dem Gerät unter Einstellungen → App Store → Sandbox-Konto abmelden/anmelden. Dann in der App „Kostenlos testen & abonnieren“ – die Abbuchung erfolgt nicht wirklich.")
                }

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
                    Toggle("Alle Kursziele überschreiben", isOn: $forceOverwriteAllKursziele)
                } header: {
                    Text("Kursziel-Überschreiben")
                } footer: {
                    Text("Wenn an: Beim nächsten Abruf (z. B. nach CSV-Import oder „Kursziele OpenAI“) werden alle Kursziele neu ermittelt und überschrieben – auch aus CSV oder manuell gesetzte. Wenn aus: Kursziele aus CSV und manuell geänderte werden nicht überschrieben.")
                }
                
                Section {
                    Toggle("Entwicklermodus", isOn: $entwicklermodus)
                    #if DEBUG
                    Toggle("Debug: Nur 1 Zeile einlesen", isOn: $debugEinlesungNurEinSatz)
                    #endif
                } header: {
                    Text("Entwickler")
                } footer: {
                    Text("Wenn an: Der Text unter „Rechtliches“ kann in der App bearbeitet und gespeichert werden. „Debug: Nur 1 Zeile“: Beim nächsten CSV-Import wird nur die erste Zeile verarbeitet; Einlesewerte und Satz Deutsche Bank erscheinen in der Xcode-Konsole.")
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
            .navigationTitle("Einstellungen · \(BankStore.selectedBank.name)")
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
