//
//  XLSXToCSV.swift
//  Aktien
//
//  Liest .xlsx (Excel) und liefert einen CSV-ähnlichen String (Semikolon-getrennt),
//  damit derselbe Parser wie für CSV verwendet werden kann (z. B. für App-Store-Connect-Tests).
//

import Foundation
import CoreXLSX

enum XLSXToCSVError: LocalizedError {
    case notXLSX
    case openFailed
    case noWorksheet
    /// Datei lesbar, aber Inhalt ist kein gültiges XLSX (z. B. beschädigt oder anderes Format).
    case invalidFormat(underlying: Error?)
    
    var errorDescription: String? {
        switch self {
        case .notXLSX: return "Keine XLSX-Datei."
        case .openFailed: return "XLSX-Datei konnte nicht geöffnet werden."
        case .noWorksheet: return "Kein Arbeitsblatt in der XLSX-Datei."
        case .invalidFormat(let err): return "Die Datei ist kein gültiges Excel-XLSX oder konnte nicht gelesen werden.\(err.map { " (\($0.localizedDescription))" } ?? "")"
        }
    }
}

/// Excel speichert Zahlen mit Punkt (US) und oft mit vielen Nachkommastellen (z. B. 30.294999999999999).
/// Wenn der CSV-Parser „Deutsch“ nutzt, wird der Punkt als Tausender gelesen und entfernt → 30294999999999999.
/// Daher: Rohwert nur wenn kein Zahl-Format; sonst als Double parsen und mit Bank-Dezimalformat ausgeben (z. B. 30,295).
private func formatXLSXNumericCellValue(_ raw: String, formatter: NumberFormatter) -> String {
    let trimmed = raw.trimmingCharacters(in: .whitespaces)
    guard !trimmed.isEmpty else { return raw }
    guard let num = Double(trimmed) else { return raw }
    return formatter.string(from: NSNumber(value: num)) ?? raw
}

private func xlsxNumberFormatter(decimalStyle: String) -> NumberFormatter {
    let f = NumberFormatter()
    f.locale = decimalStyle == "english" ? Locale(identifier: "en_US") : Locale(identifier: "de_DE")
    f.numberStyle = .decimal
    f.minimumFractionDigits = 0
    f.maximumFractionDigits = 10
    return f
}

/// Liest die erste Tabelle einer .xlsx-Datei und liefert den Inhalt als Semikolon-getrennten Text (eine Zeile pro Zeile, Zellen mit ; getrennt).
func csvStyleStringFromXLSX(url: URL) throws -> String {
    guard url.pathExtension.lowercased() == "xlsx" else { throw XLSXToCSVError.notXLSX }
    let data: Data
    do {
        data = try Data(contentsOf: url)
    } catch {
        throw XLSXToCSVError.openFailed
    }
    guard !data.isEmpty else { throw XLSXToCSVError.openFailed }
    let file: XLSXFile
    do {
        file = try XLSXFile(data: data)
    } catch {
        throw XLSXToCSVError.invalidFormat(underlying: error)
    }
    let paths: [String]
    do {
        paths = try file.parseWorksheetPaths()
    } catch {
        throw XLSXToCSVError.invalidFormat(underlying: error)
    }
    guard let firstPath = paths.first else { throw XLSXToCSVError.noWorksheet }
    let worksheet: CoreXLSX.Worksheet
    do {
        worksheet = try file.parseWorksheet(at: firstPath)
    } catch {
        throw XLSXToCSVError.invalidFormat(underlying: error)
    }
    // Optional: Manche XLSX-Dateien haben keine Shared-Strings-Tabelle; dann nil, Zellwerte nur über cell.value
    let sharedStrings = try? file.parseSharedStrings()
    guard let rows = worksheet.data?.rows else { return "" }
    let decimalSeparator = BankStore.activeBankDecimalSeparator()
    let numberFormatterForXLSX = xlsxNumberFormatter(decimalStyle: decimalSeparator)
    var lines: [String] = []
    for row in rows.sorted(by: { $0.reference < $1.reference }) {
        let sortedCells = row.cells.sorted { a, b in
            String(describing: a.reference) < String(describing: b.reference)
        }
        let values = sortedCells.map { cell -> String in
            if let shared = sharedStrings, let s = cell.stringValue(shared) { return s }
            if let v = cell.value {
                return formatXLSXNumericCellValue(v, formatter: numberFormatterForXLSX)
            }
            return ""
        }
        let line = values.map { v in
            v.contains(";") || v.contains("\"") || v.contains("\n") ? "\"" + v.replacingOccurrences(of: "\"", with: "\"\"") + "\"" : v
        }.joined(separator: ";")
        lines.append(line)
    }
    return lines.joined(separator: "\n")
}
