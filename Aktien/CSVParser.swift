//
//  CSVParser.swift
//  Aktien
//
//  Created by Axel Behm on 28.01.26.
//

import Foundation

class CSVParser {
    
    private static let csvColumnMappingUserDefaultsKey = "CSVColumnMapping"
    
    /// Liefert die benutzerdefinierte Spaltenzuordnung (Feld-ID → CSV-Header). Wenn nicht vorhanden oder zu wenige Pflichtfelder, nil.
    private static func loadCustomColumnMapping() -> [String: String]? {
        guard let data = UserDefaults.standard.data(forKey: csvColumnMappingUserDefaultsKey),
              let decoded = try? JSONDecoder().decode([String: String].self, from: data) else { return nil }
        let required = ["bankleistungsnummer", "bestand", "bezeichnung", "wkn"]
        let hasRequired = required.allSatisfy { key in
            guard let h = decoded[key] else { return false }
            return !h.trimmingCharacters(in: .whitespaces).isEmpty
        }
        return hasRequired ? decoded : nil
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
    
    /// Parst eine CSV-Datei und gibt ein Array von Aktien zurück
    static func parseCSV(from url: URL) throws -> [Aktie] {
        let content = try String(contentsOf: url, encoding: .utf8)
        return parseCSV(from: content)
    }
    
    /// Parst CSV-Datei und gibt Aktien + Statistik zurück (für Diagnose).
    /// Kursziel: aus Spalte „Kursziel_EUR“, „Kursziel“ oder letzter Spalte (Zahl) – wenn vorhanden, wird in der App keine Ermittlung durchgeführt.
    /// Optional: Kursziel_Quelle (z. B. aus Python-Script).
    /// hadKursziele: true, wenn mindestens eine Zeile ein Kursziel aus der CSV geliefert hat (dann werden C-markierten nicht neu berechnet; sonst schon).
    static func parseCSVWithStats(from url: URL) throws -> (aktien: [Aktie], zeilenGesamt: Int, zeilenImportiert: Int, hadKursziele: Bool) {
        var content = try String(contentsOf: url, encoding: .utf8)
        if content.isEmpty, let latin1 = try? String(contentsOf: url, encoding: .isoLatin1) {
            content = latin1
        }
        content = content.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        let lines = content.components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        let dataLines = lines.count > 1 ? Array(lines.dropFirst()) : []
        let delimiter = detectDelimiter(firstLine: lines.first ?? "")
        let headerMap = buildHeaderMap(firstLine: lines.first ?? "", delimiter: delimiter)
        let customMapping = loadCustomColumnMapping()
        var aktien: [Aktie] = []
        for line in dataLines {
            let aktie: Aktie?
            if let map = customMapping {
                aktie = parseLineWithMapping(line, delimiter: delimiter, headerMap: headerMap, columnMapping: map)
            } else {
                aktie = parseLine(line, delimiter: delimiter, headerMap: headerMap)
            }
            if let a = aktie { aktien.append(a) }
        }
        let hadKursziele = aktien.contains { $0.kursziel != nil }
        return (aktien, dataLines.count, aktien.count, hadKursziele)
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
        let semicolons = firstLine.filter { $0 == ";" }.count
        let commas = firstLine.filter { $0 == "," }.count
        if semicolons > 0 || commas > 0 {
            return semicolons >= commas ? ";" : ","
        }
        return ";" // Standard für deutsche CSV
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
        let delimiter = detectDelimiter(firstLine: lines.first ?? "")
        let headerMap = buildHeaderMap(firstLine: lines.first ?? "", delimiter: delimiter)
        let customMapping = loadCustomColumnMapping()
        for line in dataLines {
            let aktie: Aktie?
            if let map = customMapping {
                aktie = parseLineWithMapping(line, delimiter: delimiter, headerMap: headerMap, columnMapping: map)
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
    
    /// Parst eine Zeile nur über die benutzerdefinierte Spaltenzuordnung (CSV-Header → App-Feld).
    private static func parseLineWithMapping(_ line: String, delimiter: Character, headerMap: [String: Int], columnMapping: [String: String]) -> Aktie? {
        let columns = splitCSVLine(line, delimiter: delimiter)
        func valueFor(_ fieldId: String) -> String? {
            guard let csvHeader = columnMapping[fieldId], !csvHeader.trimmingCharacters(in: .whitespaces).isEmpty,
                  let idx = headerMap[csvHeader.trimmingCharacters(in: .whitespaces).lowercased()], idx < columns.count else { return nil }
            let s = columns[idx].trimmingCharacters(in: .whitespaces)
            return s.isEmpty ? nil : s
        }
        guard let bankleistungsnummer = valueFor("bankleistungsnummer"), !bankleistungsnummer.isEmpty,
              let bezeichnung = valueFor("bezeichnung"), !bezeichnung.isEmpty,
              let wkn = valueFor("wkn") else { return nil }
        // Summen- und Kopfzeilen nicht als Position importieren (z. B. „Zwischensumme“, wiederholte Kopfzeile)
        let bezeichnungNorm = bezeichnung.lowercased().trimmingCharacters(in: .whitespaces)
        if summenKopfStichwoerter.contains(bezeichnungNorm) { return nil }
        if bezeichnungNorm.hasPrefix("zwischensumme") || bezeichnungNorm.hasPrefix("summe ") || bezeichnungNorm.hasPrefix("gesamtsumme") { return nil }
        let bestandVal = valueFor("bestand").flatMap { parseDouble($0) } ?? 0.0
        guard bestandVal >= 0 else { return nil }
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
        let depotPortfolioName = valueFor("depotPortfolioName") ?? ""
        var kursziel: Double? = valueFor("kursziel").flatMap { parseDouble($0) }.flatMap { $0 > 0 ? $0 : nil }
        if kursziel == nil, let kzStr = valueFor("kursziel"), let k = parseDouble(kzStr), k > 0 { kursziel = k }
        var kurszielQuelle: String? = nil
        if kursziel != nil {
            kurszielQuelle = mapKurszielQuelle(valueFor("kursziel_quelle"))
            if kurszielQuelle == nil { kurszielQuelle = "C" }
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
    
    /// Konvertiert einen String mit deutschem Format (Komma als Dezimaltrennzeichen) zu Double
    private static func parseDouble(_ value: String) -> Double? {
        let trimmed = value.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return nil }
        
        // Prüfe ob es ein Komma gibt (Dezimaltrennzeichen)
        if let commaIndex = trimmed.firstIndex(of: ",") {
            // Es gibt ein Komma, also ist das Dezimaltrennzeichen
            let beforeComma = String(trimmed[..<commaIndex])
            let afterComma = String(trimmed[trimmed.index(after: commaIndex)...])
            // Entferne Tausender-Trennzeichen (Punkte) vor dem Komma
            let cleanedBefore = beforeComma.replacingOccurrences(of: ".", with: "")
            // Kombiniere zu "Zahl.Zahl" Format
            return Double("\(cleanedBefore).\(afterComma)")
        } else {
            // Kein Komma, also entferne alle Punkte (Tausender-Trennzeichen)
            let cleaned = trimmed.replacingOccurrences(of: ".", with: "")
            return Double(cleaned)
        }
    }
    
    /// Parst ein Datum im Format DD.MM.YYYY
    private static func parseDate(_ value: String) -> Date? {
        let trimmed = value.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return nil }
        return dateFormatter.date(from: trimmed)
    }
}
