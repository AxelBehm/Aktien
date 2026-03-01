//
//  CSVParser.swift
//  Aktien
//
//  Created by Axel Behm on 28.01.26.
//

import Foundation

class CSVParser {
    
    /// Liefert die Spaltenzuordnung (Feld-ID → Spaltenbuchstabe A,B,C oder "=fester Wert"). Wenn zu wenige Pflichtfelder, nil.
    private static func loadCustomColumnMapping() -> [String: String]? {
        guard let decoded = BankStore.loadActiveBankCSVMapping() else { return nil }
        let required = ["bankleistungsnummer", "bestand", "bezeichnung", "wkn"]
        func isValid(_ val: String?) -> Bool {
            guard let v = val else { return false }
            if v.hasPrefix("=") { return !v.dropFirst(1).trimmingCharacters(in: .whitespaces).isEmpty }
            return columnLetterToIndex(v) >= 0
        }
        let hasRequired = required.allSatisfy { isValid(decoded[$0]) }
        return hasRequired ? decoded : nil
    }

    /// Spaltenbuchstabe (A, B, …, Z, AA, AB, …) in 0-basierenden Index. Ungültig → -1.
    private static func columnLetterToIndex(_ letter: String) -> Int {
        let s = letter.trimmingCharacters(in: .whitespaces).uppercased()
        guard !s.isEmpty else { return -1 }
        if s.count == 1 {
            let c = s.unicodeScalars.first!.value
            guard c >= 65, c <= 90 else { return -1 }
            return Int(c) - 65
        }
        if s.count == 2, s.hasPrefix("A") {
            return 26 + columnLetterToIndex(String(s.dropFirst()))
        }
        return -1
    }
    
    // Deutsche Zahlenformate: Komma als Dezimaltrennzeichen
    private static let germanNumberFormatter: NumberFormatter = {
        let formatter = NumberFormatter()
        formatter.locale = Locale(identifier: "de_DE")
        formatter.numberStyle = .decimal
        return formatter
    }()
    
    // Datum-Formatter für DD.MM.YYYY
    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "dd.MM.yyyy"
        formatter.locale = Locale(identifier: "de_DE")
        return formatter
    }()
    
    /// Entfernt UTF-8-BOM und andere unsichtbare Zeichen am Dateianfang (z. B. von Excel-Export).
    private static func stripBOMAndNormalize(_ content: String) -> String {
        var s = content
        if s.hasPrefix("\u{FEFF}") { s = String(s.dropFirst()) }
        return s.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
    }
    
    /// Parst eine CSV-Datei und gibt ein Array von Aktien zurück
    static func parseCSV(from url: URL) throws -> [Aktie] {
        var content = try String(contentsOf: url, encoding: .utf8)
        if content.isEmpty { content = try String(contentsOf: url, encoding: .isoLatin1) }
        return parseCSV(from: stripBOMAndNormalize(content))
    }
    
    /// Format-Fingerabdruck für eine CSV-Datei (Spaltenanzahl der ersten Datenzeile). Zum Abgleich mit gespeichertem Wert pro Bank.
    static func computeFingerprint(from url: URL) -> String? {
        guard var content = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        if content.isEmpty, let latin1 = try? String(contentsOf: url, encoding: .isoLatin1) { content = latin1 }
        let text = stripBOMAndNormalize(content)
        let lines = text.components(separatedBy: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        guard lines.count >= 2 else { return nil }
        let firstLine = lines[0]
        let delimiter = resolveDelimiter(firstLine: firstLine)
        let firstDataLine = lines[1]
        let columns = splitCSVLine(firstDataLine, delimiter: delimiter)
        return "\(columns.count)"
    }

    /// Parst CSV-Datei und gibt Aktien + Statistik zurück (für Diagnose).
    /// Kursziel: aus Spalte „Kursziel_EUR“, „Kursziel“ oder letzter Spalte (Zahl) – wenn vorhanden, wird in der App keine Ermittlung durchgeführt.
    /// Optional: Kursziel_Quelle (z. B. aus Python-Script).
    /// hadKursziele: true, wenn mindestens eine Zeile ein Kursziel aus der CSV geliefert hat (dann werden C-markierten nicht neu berechnet; sonst schon).
    /// firstFailureLine: 1-basierte Datenzeilennummer (Zeile 2 = erste Datenzeile nach Header), bei der die erste Zeile nicht zugeordnet werden konnte.
    /// firstFailureDiagnostic: Kurzbeschreibung (Feld, gelesener Wert, Grund) für diese Zeile.
    /// filePreview: Erste Zeile (max 120 Zeichen) + Hex der ersten Bytes, für Diagnose bei 0 importierten Zeilen.
    static func parseCSVWithStats(from url: URL) throws -> (aktien: [Aktie], zeilenGesamt: Int, zeilenImportiert: Int, hadKursziele: Bool, firstFailureLine: Int?, firstFailureDiagnostic: String?, filePreview: String?) {
        let data = try Data(contentsOf: url)
        var content = String(data: data, encoding: .utf8)
        if content == nil || content?.isEmpty == true {
            content = String(data: data, encoding: .isoLatin1)
        }
        var text = content ?? ""
        text = stripBOMAndNormalize(text)
        let firstLineRaw = text.components(separatedBy: "\n").first ?? ""
        let previewLine = String(firstLineRaw.prefix(120))
        let hexBytes = data.prefix(24).map { String(format: "%02X", $0) }.joined(separator: " ")
        let filePreview = "Erste Zeile (max 120 Zeichen): \(previewLine)\nErste 24 Bytes (Hex): \(hexBytes) (EF BB BF = BOM)"
        let lines = text.components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        let dataLines = lines.count > 1 ? Array(lines.dropFirst()) : []
        let delimiter = resolveDelimiter(firstLine: lines.first ?? "")
        let headerMap = buildHeaderMap(firstLine: lines.first ?? "", delimiter: delimiter)
        let validMapping = loadCustomColumnMapping()
        let rawMapping = BankStore.loadActiveBankCSVMapping()
        let mappingToUse = validMapping ?? (rawMapping.flatMap { $0.isEmpty ? nil : $0 })
        var aktien: [Aktie] = []
        var firstFailureLine: Int?
        var firstFailureDiagnostic: String?
        for (index, line) in dataLines.enumerated() {
            let aktie: Aktie?
            if let map = mappingToUse {
                let (a, diag) = parseLineWithMapping(line, delimiter: delimiter, headerMap: headerMap, columnMapping: map)
                aktie = a
                if aktie == nil, firstFailureDiagnostic == nil, let d = diag {
                    firstFailureLine = index + 2
                    firstFailureDiagnostic = d
                }
            } else {
                aktie = parseLine(line, delimiter: delimiter, headerMap: headerMap)
            }
            if let a = aktie { aktien.append(a) }
        }
        let hadKursziele = aktien.contains { $0.kursziel != nil }
        return (aktien, dataLines.count, aktien.count, hadKursziele, firstFailureLine, firstFailureDiagnostic, filePreview)
    }
    
    /// Baut Map Spaltenname (lowercased) -> Index für Header-basiertes Parsing
    private static func buildHeaderMap(firstLine: String, delimiter: Character) -> [String: Int] {
        let headers = splitCSVLine(firstLine, delimiter: delimiter)
        var map: [String: Int] = [:]
        for (i, h) in headers.enumerated() {
            let key = h.trimmingCharacters(in: .whitespaces).lowercased()
            if !key.isEmpty { map[key] = i }
        }
        return map
    }
    
    /// Mappt Kursziel_Quelle aus Python-Script (finanzen.net, ariva.de, yahoo) auf App-Codes (F, Y, A)
    private static func mapKurszielQuelle(_ source: String?) -> String? {
        guard let s = source?.trimmingCharacters(in: .whitespaces), !s.isEmpty else { return nil }
        let lower = s.lowercased()
        if lower.contains("finanzen") { return "F" }
        if lower.contains("yahoo") { return "Y" }
        if lower.contains("ariva") { return "F" }
        if lower.contains("openai") { return "A" }
        return s
    }
    
    /// Splittet eine CSV-Zeile und respektiert Anführungszeichen
    private static func splitCSVLine(_ line: String, delimiter: Character) -> [String] {
        var result: [String] = []
        var current = ""
        var inQuotes = false
        for char in line {
            if char == "\"" {
                inQuotes.toggle()
            } else if !inQuotes && char == delimiter {
                result.append(current.trimmingCharacters(in: .whitespaces))
                current = ""
            } else {
                current.append(char)
            }
        }
        result.append(current.trimmingCharacters(in: .whitespaces))
        return result
    }
    
    /// Ermittelt Trennzeichen aus der ersten Zeile (Header) – einheitlich für die ganze Datei.
    /// Deutsche CSV-Exporte nutzen meist Semikolon (wegen Komma als Dezimaltrennzeichen).
    private static func detectDelimiter(firstLine: String) -> Character {
        let tabs = firstLine.filter { $0 == "\t" }.count
        let semicolons = firstLine.filter { $0 == ";" }.count
        let commas = firstLine.filter { $0 == "," }.count
        if tabs > semicolons && tabs > commas { return "\t" }
        if semicolons > 0 || commas > 0 {
            return semicolons >= commas ? ";" : ","
        }
        return ";" // Standard für deutsche CSV
    }
    
    /// Liefert das zu verwendende Feldtrennzeichen: Einstellung der aktiven Bank oder Auto-Erkennung.
    private static func resolveDelimiter(firstLine: String) -> Character {
        let key = BankStore.activeBankFieldSeparator()
        switch key {
        case "semicolon": return ";"
        case "comma": return ","
        case "tab": return "\t"
        default: return detectDelimiter(firstLine: firstLine)
        }
    }
    
    /// Parst CSV-String und gibt ein Array von Aktien zurück
    static func parseCSV(from content: String) -> [Aktie] {
        var aktien: [Aktie] = []
        let normalized = content.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        let lines = normalized.components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        guard lines.count > 1 else { return aktien }
        let dataLines = Array(lines.dropFirst())
        let delimiter = resolveDelimiter(firstLine: lines.first ?? "")
        let headerMap = buildHeaderMap(firstLine: lines.first ?? "", delimiter: delimiter)
        let customMapping = loadCustomColumnMapping()
        for line in dataLines {
            let aktie: Aktie?
            if let map = customMapping {
                aktie = parseLineWithMapping(line, delimiter: delimiter, headerMap: headerMap, columnMapping: map).0
            } else {
                aktie = parseLine(line, delimiter: delimiter, headerMap: headerMap)
            }
            if let a = aktie {
                aktien.append(a)
            }
        }
        return aktien
    }
    
    /// Kennwörter für Summen-/Kopfzeilen: Zeilen, deren Bezeichnung nur daraus besteht, werden nicht importiert (weder bei Custom-Mapping noch bei festem Layout).
    private static let summenKopfStichwoerter: [String] = [
        "zwischensumme", "summe", "gesamtsumme", "gesamt", "bezeichnung", "wertpapierbezeichnung",
        "depotübersicht", "depotuebersicht", "positionen", "subtotal", "total", "gross total"
    ]
    
    /// Sucht in headerMap nach einem der angegebenen Header-Namen (lowercased) und liefert den ersten nicht-leeren Zellwert aus columns.
    private static func valueForFirstMatchingHeader(columns: [String], headerMap: [String: Int], names: [String]) -> String {
        for name in names {
            guard let idx = headerMap[name], idx < columns.count else { continue }
            let s = columns[idx].trimmingCharacters(in: .whitespaces)
            if !s.isEmpty { return s }
        }
        return ""
    }
    
    /// Format für Diagnose: Spalte oder „Fester Wert“
    private static func spalteOderFesterWert(_ raw: String?) -> String {
        guard let r = raw, !r.isEmpty else { return "nicht zugeordnet" }
        if r.hasPrefix("=") { return "Fester Wert" }
        return "Spalte \(r)"
    }
    
    /// Parst eine Zeile über die Spaltenzuordnung (App-Feld → Spaltenbuchstabe A, B, C, …). Der Nutzer ordnet in Excel sichtbare Spalten (A, B, C) zu.
    /// Bei Fehler: zweiter Rückgabewert = Diagnose (Feld, gelesener Wert, Grund).
    private static func parseLineWithMapping(_ line: String, delimiter: Character, headerMap: [String: Int], columnMapping: [String: String]) -> (Aktie?, diagnostic: String?) {
        let columns = splitCSVLine(line, delimiter: delimiter)
        func valueFor(_ fieldId: String) -> String? {
            guard let raw = columnMapping[fieldId], !raw.isEmpty else { return nil }
            if raw.hasPrefix("=") {
                let fixed = String(raw.dropFirst(1)).trimmingCharacters(in: .whitespaces)
                if fixed.isEmpty { return nil }
                return fixed
            }
            let idx = columnLetterToIndex(raw)
            guard idx >= 0, idx < columns.count else { return nil }
            let s = columns[idx].trimmingCharacters(in: .whitespaces)
            return s.isEmpty ? nil : s
        }
        func rawFor(_ fieldId: String) -> String {
            let v = valueFor(fieldId)
            if let v = v { return v.isEmpty ? "(leer)" : v }
            return "(leer)"
        }
        guard let bankleistungsnummer = valueFor("bankleistungsnummer"), !bankleistungsnummer.isEmpty else {
            return (nil, "Bankleistungsnummer (\(spalteOderFesterWert(columnMapping["bankleistungsnummer"]))): gelesen '\(rawFor("bankleistungsnummer"))' – muss ausgefüllt sein (oder Fester Wert)")
        }
        guard let bezeichnung = valueFor("bezeichnung"), !bezeichnung.isEmpty else {
            return (nil, "Bezeichnung (\(spalteOderFesterWert(columnMapping["bezeichnung"]))): gelesen '\(rawFor("bezeichnung"))' – muss ausgefüllt sein")
        }
        guard let wkn = valueFor("wkn"), !wkn.isEmpty else {
            return (nil, "WKN (\(spalteOderFesterWert(columnMapping["wkn"]))): gelesen '\(rawFor("wkn"))' – muss ausgefüllt sein")
        }
        // Summen- und Kopfzeilen nicht als Position importieren (z. B. „Zwischensumme“, wiederholte Kopfzeile)
        let bezeichnungNorm = bezeichnung.lowercased().trimmingCharacters(in: .whitespaces)
        if summenKopfStichwoerter.contains(bezeichnungNorm) {
            return (nil, "Bezeichnung '\(bezeichnung)' – Summen-/Kopfzeile wird übersprungen")
        }
        if bezeichnungNorm.hasPrefix("zwischensumme") || bezeichnungNorm.hasPrefix("summe ") || bezeichnungNorm.hasPrefix("gesamtsumme") {
            return (nil, "Bezeichnung '\(bezeichnung)' – Summenzeile wird übersprungen")
        }
        let bestandStr = valueFor("bestand") ?? ""
        let bestandVal = valueFor("bestand").flatMap { parseDouble($0) } ?? 0.0
        guard bestandVal >= 0 else {
            return (nil, "Bestand (\(spalteOderFesterWert(columnMapping["bestand"]))): gelesen '\(bestandStr.isEmpty ? "(leer)" : bestandStr)' – keine gültige Zahl (≥ 0)")
        }
        let bestand = bestandVal
        let isin = valueFor("isin") ?? ""
        let waehrung = (valueFor("waehrung") ?? "").isEmpty ? "EUR" : (valueFor("waehrung") ?? "EUR")
        let hinweisEinstandskurs = valueFor("hinweisEinstandskurs") ?? ""
        let einstandskurs = valueFor("einstandskurs").flatMap { parseDouble($0) }
        let deviseneinstandskurs = valueFor("deviseneinstandskurs").flatMap { parseDouble($0) }
        let kurs = valueFor("kurs").flatMap { parseDouble($0) }
        let devisenkurs = valueFor("devisenkurs").flatMap { parseDouble($0) }
        let gewinnVerlustEUR = valueFor("gewinnVerlustEUR").flatMap { parseDouble($0) }
        let gewinnVerlustProzent = valueFor("gewinnVerlustProzent").flatMap { parseDouble($0) }
        let marktwertEUR = valueFor("marktwertEUR").flatMap { parseDouble($0) }
        let stueckzinsenEUR = valueFor("stueckzinsenEUR").flatMap { parseDouble($0) }
        let anteilProzent = valueFor("anteilProzent").flatMap { parseDouble($0) }
        let datumLetzteBewegung = valueFor("datumLetzteBewegung").flatMap { parseDate($0) }
        let gattung = (valueFor("gattung") ?? "").isEmpty ? "Aktie" : (valueFor("gattung") ?? "Aktie")
        let branche = (valueFor("branche") ?? "").isEmpty ? "-" : (valueFor("branche") ?? "-")
        let risikoklasse = (valueFor("risikoklasse") ?? "").isEmpty ? "-" : (valueFor("risikoklasse") ?? "-")
        var depotPortfolioName = valueFor("depotPortfolioName") ?? ""
        // Fallback: wenn nicht per Spalte zugeordnet, über typische Header suchen (optional)
        if depotPortfolioName.isEmpty, !headerMap.isEmpty {
            depotPortfolioName = valueForFirstMatchingHeader(columns: columns, headerMap: headerMap, names: ["konto", "neues konto", "depot", "depotname", "kontonummer", "depotnummer", "portfolio", "kontobezeichnung", "depotbezeichnung"])
            if depotPortfolioName.isEmpty {
                for (headerName, headerIdx) in headerMap {
                    let lower = headerName.lowercased()
                    if (lower.contains("konto") || lower.contains("depot") || lower.contains("portfolio")), headerIdx < columns.count {
                        let s = columns[headerIdx].trimmingCharacters(in: .whitespaces)
                        if !s.isEmpty { depotPortfolioName = s; break }
                    }
                }
            }
        }
        var kursziel: Double? = valueFor("kursziel").flatMap { parseDouble($0) }.flatMap { $0 > 0 ? $0 : nil }
        if kursziel == nil, let kzStr = valueFor("kursziel"), let k = parseDouble(kzStr), k > 0 { kursziel = k }
        var kurszielQuelle: String? = nil
        if kursziel != nil {
            kurszielQuelle = mapKurszielQuelle(valueFor("kursziel_quelle"))
            if kurszielQuelle == nil { kurszielQuelle = "C" }
        }
        return (Aktie(
            bankleistungsnummer: bankleistungsnummer,
            bestand: bestand,
            bezeichnung: bezeichnung,
            wkn: wkn,
            isin: isin,
            waehrung: waehrung,
            hinweisEinstandskurs: hinweisEinstandskurs,
            einstandskurs: einstandskurs,
            deviseneinstandskurs: deviseneinstandskurs,
            kurs: kurs,
            devisenkurs: devisenkurs,
            gewinnVerlustEUR: gewinnVerlustEUR,
            gewinnVerlustProzent: gewinnVerlustProzent,
            marktwertEUR: marktwertEUR,
            stueckzinsenEUR: stueckzinsenEUR,
            anteilProzent: anteilProzent,
            datumLetzteBewegung: datumLetzteBewegung,
            gattung: gattung,
            branche: branche,
            risikoklasse: risikoklasse,
            depotPortfolioName: depotPortfolioName,
            kursziel: kursziel,
            kurszielQuelle: kurszielQuelle,
            kurszielWaehrung: kursziel != nil ? "EUR" : nil
        ), nil)
    }
    
    /// Parst eine einzelne CSV-Zeile mit dem angegebenen Trennzeichen.
    /// Berücksichtigt Anführungszeichen. headerMap: Spaltenname (lowercased) -> Index für Kursziel_EUR, Kursziel_Quelle.
    private static func parseLine(_ line: String, delimiter: Character, headerMap: [String: Int] = [:]) -> Aktie? {
        let columns = splitCSVLine(line, delimiter: delimiter)
        
        guard columns.count >= 8 else { return nil }
        
        func col(_ i: Int) -> String {
            i < columns.count ? columns[i].trimmingCharacters(in: .whitespaces) : ""
        }
        func colByName(_ name: String) -> String? {
            guard let idx = headerMap[name.lowercased()], idx < columns.count else { return nil }
            let s = columns[idx].trimmingCharacters(in: .whitespaces)
            return s.isEmpty ? nil : s
        }
        
        let bankleistungsnummer = col(0)
        let bestand = parseDouble(col(1)) ?? 0.0
        let bezeichnung = col(2)
        let bezeichnungNorm = bezeichnung.lowercased().trimmingCharacters(in: .whitespaces)
        if !bezeichnungNorm.isEmpty && (summenKopfStichwoerter.contains(bezeichnungNorm) || bezeichnungNorm.hasPrefix("zwischensumme") || bezeichnungNorm.hasPrefix("summe ") || bezeichnungNorm.hasPrefix("gesamtsumme")) { return nil }
        let wkn = col(3)
        let isin = colByName("isin") ?? col(4)
        let waehrung = col(5).isEmpty ? "EUR" : col(5)
        let hinweisEinstandskurs = col(6)
        let einstandskurs = parseDouble(col(7))
        let deviseneinstandskurs = parseDouble(col(8))
        let kurs = parseDouble(col(9))
        let devisenkurs = parseDouble(col(10))
        let gewinnVerlustEUR = parseDouble(col(11))
        let gewinnVerlustProzent = parseDouble(col(12))
        let marktwertEUR = parseDouble(col(13))
        let stueckzinsenEUR = parseDouble(col(14))
        let anteilProzent = parseDouble(col(15))
        let datumLetzteBewegung = parseDate(col(16))
        let gattung = col(17).isEmpty ? "Aktie" : col(17)
        let branche = col(18).isEmpty ? "-" : col(18)
        let risikoklasse = col(19).isEmpty ? "-" : col(19)
        let depotPortfolioName = columns.count > 20 ? col(20) : ""
        
        var kursziel: Double? = nil
        var kurszielQuelle: String? = nil
        if let eurStr = colByName("Kursziel_EUR"), let k = parseDouble(eurStr), k > 0 {
            kursziel = k
            kurszielQuelle = mapKurszielQuelle(colByName("Kursziel_Quelle"))
        }
        if kursziel == nil, let kzStr = colByName("Kursziel"), let k = parseDouble(kzStr), k > 0 {
            kursziel = k
            kurszielQuelle = "C"
        }
        // Letzte Spalte: „Kursziel“ mit Durchschnittszeichen (z. B. „Kursziel Ø“) – Header enthält „kursziel“
        if kursziel == nil, let lastIdx = columns.indices.last,
           let (_, idx) = headerMap.first(where: { $0.key.contains("kursziel") && $0.value == lastIdx }),
           idx < columns.count {
            let kzStr = col(idx).trimmingCharacters(in: .whitespaces)
            if let k = parseDouble(kzStr), k > 0 {
                kursziel = k
                kurszielQuelle = "C"
            }
        }
        if kursziel == nil, let lastCol = columns.last?.trimmingCharacters(in: .whitespaces), !lastCol.isEmpty,
           let k = parseDouble(lastCol), k > 0 {
            kursziel = k
            kurszielQuelle = "C"
        }
        
        return Aktie(
            bankleistungsnummer: bankleistungsnummer,
            bestand: bestand,
            bezeichnung: bezeichnung,
            wkn: wkn,
            isin: isin,
            waehrung: waehrung,
            hinweisEinstandskurs: hinweisEinstandskurs,
            einstandskurs: einstandskurs,
            deviseneinstandskurs: deviseneinstandskurs,
            kurs: kurs,
            devisenkurs: devisenkurs,
            gewinnVerlustEUR: gewinnVerlustEUR,
            gewinnVerlustProzent: gewinnVerlustProzent,
            marktwertEUR: marktwertEUR,
            stueckzinsenEUR: stueckzinsenEUR,
            anteilProzent: anteilProzent,
            datumLetzteBewegung: datumLetzteBewegung,
            gattung: gattung,
            branche: branche,
            risikoklasse: risikoklasse,
            depotPortfolioName: depotPortfolioName,
            kursziel: kursziel,
            kurszielQuelle: kurszielQuelle,
            kurszielWaehrung: kursziel != nil ? "EUR" : nil
        )
    }
    
    /// Konvertiert einen String zu Double. Format abhängig von Einstellung: Deutsch (1.234,56) oder Englisch (1,234.56).
    private static func parseDouble(_ value: String) -> Double? {
        let trimmed = value.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return nil }
        let decimalStyle = BankStore.activeBankDecimalSeparator()
        if decimalStyle == "english" {
            return parseDoubleEnglish(trimmed)
        }
        return parseDoubleGerman(trimmed)
    }
    
    /// Deutsch: Komma = Dezimaltrennzeichen, Punkt = Tausender (1.234,56)
    private static func parseDoubleGerman(_ trimmed: String) -> Double? {
        if let commaIndex = trimmed.firstIndex(of: ",") {
            let beforeComma = String(trimmed[..<commaIndex])
            let afterComma = String(trimmed[trimmed.index(after: commaIndex)...])
            let cleanedBefore = beforeComma.replacingOccurrences(of: ".", with: "")
            return Double("\(cleanedBefore).\(afterComma)")
        }
        let cleaned = trimmed.replacingOccurrences(of: ".", with: "")
        return Double(cleaned)
    }
    
    /// Englisch: Punkt = Dezimaltrennzeichen, Komma = Tausender (1,234.56)
    private static func parseDoubleEnglish(_ trimmed: String) -> Double? {
        if let pointIndex = trimmed.firstIndex(of: ".") {
            let beforePoint = String(trimmed[..<pointIndex])
            let afterPoint = String(trimmed[trimmed.index(after: pointIndex)...])
            let cleanedBefore = beforePoint.replacingOccurrences(of: ",", with: "")
            return Double("\(cleanedBefore).\(afterPoint)")
        }
        let cleaned = trimmed.replacingOccurrences(of: ",", with: "")
        return Double(cleaned)
    }
    
    /// Parst ein Datum im Format DD.MM.YYYY
    private static func parseDate(_ value: String) -> Date? {
        let trimmed = value.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return nil }
        return dateFormatter.date(from: trimmed)
    }
}
