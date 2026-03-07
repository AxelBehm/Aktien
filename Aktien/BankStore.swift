//
//  BankStore.swift
//  Aktien
//
//  Banken-Auswahl und pro-Bank-CSV-Zuordnung.
//

import Foundation
import SwiftUI

/// Eine Bank (nur Name); CSV-Zuordnung wird separat pro Bank gespeichert.
struct Bank: Identifiable, Codable, Equatable {
    var id: UUID
    var name: String

    static func == (lhs: Bank, rhs: Bank) -> Bool { lhs.id == rhs.id }
}

/// Vorgegebene Bank-Typen für Picker; gewählter Wert kann vom Nutzer verändert werden.
enum BankType: String, CaseIterable, Identifiable {
    case deutscheBankMaxblue = "Deutsche Bank/maxblue"
    case commerzbank = "Commerzbank"
    case dkb = "DKB"
    case ing = "ING"
    case sparkasse = "Sparkasse"
    case volksbank = "Volksbank"
    case andere = "Andere"

    var id: String { rawValue }
    var displayName: String { rawValue }
}

/// Platzhalter-UUID, wenn keine Bank ausgewählt ist (z. B. leere Liste).
private let placeholderBankId = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!

/// Wird gesendet, nachdem die CSV-Zuordnung für eine Bank gespeichert wurde (Startseite kann „Einlesen“-Button neu bewerten).
extension Notification.Name {
    static let csvMappingDidSave = Notification.Name("Aktien.csvMappingDidSave")
    /// Nach Import-Alert „OK“: RootView wechselt zur Startseite (zuverlässig auf iPad).
    static let returnToStartAfterImport = Notification.Name("Aktien.returnToStartAfterImport")
    /// „Kostenlos testen“ getippt obwohl kein Abo-Produkt → RootView soll zur Aktien-Ansicht wechseln.
    static let subscriptionGrantAccessWithoutProduct = Notification.Name("Aktien.subscriptionGrantAccessWithoutProduct")
}

private let banksListKey = "Aktien.BanksList"
private let selectedBankIdKey = "Aktien.SelectedBankId"

/// Speichert Banken, aktive Bank und CSV-Einstellungen pro Bank. Keine Bank erscheint automatisch – Nutzer legt alle über den Picker an.
enum BankStore {

    // MARK: - Bankenliste

    static func loadBanks() -> [Bank] {
        guard let data = UserDefaults.standard.data(forKey: banksListKey),
              let decoded = try? JSONDecoder().decode([Bank].self, from: data)
        else {
            return []
        }
        return decoded
    }

    static func saveBanks(_ banks: [Bank]) {
        guard let data = try? JSONEncoder().encode(banks) else { return }
        UserDefaults.standard.set(data, forKey: banksListKey)
    }

    static func addBank(name: String, bankType: BankType? = nil) -> Bank {
        var banks = loadBanks()
        let nameTrimmed = name.trimmingCharacters(in: .whitespaces)
        let bank = Bank(id: UUID(), name: nameTrimmed.isEmpty ? BankType.andere.displayName : nameTrimmed)
        if !bank.name.isEmpty, !banks.contains(where: { $0.name == bank.name }) {
            banks.append(bank)
            saveBanks(banks)
        }
        return bank
    }

    // MARK: - Demo-Bank (für App-Store-Tester)

    /// Reihenfolge der App-Felder wie in der CSV-Zuordnung (A, B, C, …).
    private static let csvFieldIdsInOrder = [
        "bankleistungsnummer", "bestand", "bezeichnung", "wkn", "isin", "waehrung",
        "hinweisEinstandskurs", "einstandskurs", "deviseneinstandskurs", "kurs", "devisenkurs",
        "gewinnVerlustEUR", "gewinnVerlustProzent", "marktwertEUR", "stueckzinsenEUR", "anteilProzent",
        "datumLetzteBewegung", "gattung", "branche", "risikoklasse", "depotPortfolioName",
        "kursziel", "kursziel_quelle"
    ]

    private static func columnLetter(for index: Int) -> String {
        if index < 26 { return String(Character(Unicode.Scalar(65 + index)!)) }
        return "A" + String(Character(Unicode.Scalar(65 + index - 26)!))
    }

    /// Legt die Demo-Bank „Dem-Bank“ an: CSV-Zuordnung A, B, C, D, E, F, … (wie Felderreihenfolge), Kontonummerfilter 2222229. Gibt die angelegte Bank zurück.
    static func createDemoBank() -> Bank {
        let bank = addBank(name: "Dem-Bank")
        var mapping: [String: String] = [:]
        for (idx, fieldId) in csvFieldIdsInOrder.enumerated() {
            mapping[fieldId] = columnLetter(for: idx)
        }
        saveCSVColumnMapping(mapping, for: bank.id)
        saveKontoFilter("2222229", for: bank.id)
        saveCSVFieldSeparator("auto", for: bank.id)
        saveCSVDecimalSeparator("german", for: bank.id)
        setSelectedBank(bank)
        return bank
    }

    static func deleteBank(_ bank: Bank) {
        var banks = loadBanks().filter { $0.id != bank.id }
        saveBanks(banks)
        if selectedBankId == bank.id {
            selectedBankId = banks.first?.id ?? placeholderBankId
        }
    }

    static func renameBank(_ bank: Bank, name: String) {
        let n = name.trimmingCharacters(in: .whitespaces)
        guard !n.isEmpty else { return }
        var banks = loadBanks()
        guard let i = banks.firstIndex(where: { $0.id == bank.id }) else { return }
        banks[i].name = n
        saveBanks(banks)
    }

    // MARK: - Aktive Bank

    static var selectedBankId: UUID {
        get {
            guard let s = UserDefaults.standard.string(forKey: selectedBankIdKey),
                  let id = UUID(uuidString: s) else { return placeholderBankId }
            return id
        }
        set {
            UserDefaults.standard.set(newValue.uuidString, forKey: selectedBankIdKey)
        }
    }

    static var selectedBank: Bank {
        let banks = loadBanks()
        if let b = banks.first(where: { $0.id == selectedBankId }) { return b }
        return banks.first ?? Bank(id: placeholderBankId, name: "")
    }

    static func setSelectedBank(_ bank: Bank) {
        selectedBankId = bank.id
    }

    // MARK: - CSV-Zuordnung pro Bank

    private static func csvMappingKey(for bankId: UUID) -> String {
        "CSVColumnMapping_\(bankId.uuidString)"
    }

    private static func csvFieldSeparatorKey(for bankId: UUID) -> String {
        "CSVFieldSeparator_\(bankId.uuidString)"
    }

    private static func csvDecimalSeparatorKey(for bankId: UUID) -> String {
        "CSVDecimalSeparator_\(bankId.uuidString)"
    }

    static func loadCSVColumnMapping(for bankId: UUID) -> [String: String] {
        let key = csvMappingKey(for: bankId)
        guard let data = UserDefaults.standard.data(forKey: key),
              let decoded = try? JSONDecoder().decode([String: String].self, from: data) else { return [:] }
        return decoded
    }

    /// Ob für diese Bank eine gültige CSV-Zuordnung existiert (Pflichtfelder gesetzt: BL, Bezeichnung, Bestand, WKN).
    static func hasValidCSVMapping(for bankId: UUID) -> Bool {
        let m = loadCSVColumnMapping(for: bankId)
        let required = ["bankleistungsnummer", "bezeichnung", "bestand", "wkn"]
        return required.allSatisfy { key in
            let v = (m[key] ?? "").trimmingCharacters(in: .whitespaces)
            guard !v.isEmpty else { return false }
            if v.hasPrefix("=") { return v.count > 1 }
            return true
        }
    }

    /// Liefert den festen BL-Wert (Teil nach „=“) nur für die angegebene Bank. Beim Import wird nur die BL der ausgewählten Bank verwendet – nicht die einer anderen Bank (z. B. DKB).
    static func fixedBankleistungsnummer(for bankId: UUID) -> String? {
        let m = loadCSVColumnMapping(for: bankId)
        guard let raw = m["bankleistungsnummer"], raw.hasPrefix("=") else { return nil }
        let v = String(raw.dropFirst(1)).trimmingCharacters(in: .whitespaces)
        return v.isEmpty ? nil : v
    }

    static func saveCSVColumnMapping(_ mapping: [String: String], for bankId: UUID) {
        let key = csvMappingKey(for: bankId)
        guard let data = try? JSONEncoder().encode(mapping) else { return }
        UserDefaults.standard.set(data, forKey: key)
    }

    /// Konto-Filter pro Bank: Erlaubte Kontonummern/Bankleistungsnummern (z. B. "600252636500|20070000"). Beim Import muss mind. eine vorkommen, sonst "Falsche Bank".
    private static func kontoFilterKey(for bankId: UUID) -> String {
        "KontoFilter_\(bankId.uuidString)"
    }
    static func loadKontoFilter(for bankId: UUID) -> String? {
        let s = UserDefaults.standard.string(forKey: kontoFilterKey(for: bankId))?.trimmingCharacters(in: .whitespaces)
        return s?.isEmpty == true ? nil : s
    }
    static func saveKontoFilter(_ value: String, for bankId: UUID) {
        let trimmed = value.trimmingCharacters(in: .whitespaces)
        UserDefaults.standard.set(trimmed.isEmpty ? nil : trimmed, forKey: kontoFilterKey(for: bankId))
    }

    private static func csvFingerprintKey(for bankId: UUID) -> String {
        "CSVFingerprint_\(bankId.uuidString)"
    }

    static func loadCSVFingerprint(for bankId: UUID) -> String? {
        UserDefaults.standard.string(forKey: csvFingerprintKey(for: bankId))
    }

    static func saveCSVFingerprint(_ value: String, for bankId: UUID) {
        UserDefaults.standard.set(value, forKey: csvFingerprintKey(for: bankId))
    }

    static func loadCSVFieldSeparator(for bankId: UUID) -> String {
        UserDefaults.standard.string(forKey: csvFieldSeparatorKey(for: bankId)) ?? "auto"
    }

    static func saveCSVFieldSeparator(_ value: String, for bankId: UUID) {
        UserDefaults.standard.set(value, forKey: csvFieldSeparatorKey(for: bankId))
    }

    static func loadCSVDecimalSeparator(for bankId: UUID) -> String {
        UserDefaults.standard.string(forKey: csvDecimalSeparatorKey(for: bankId)) ?? "german"
    }

    static func saveCSVDecimalSeparator(_ value: String, for bankId: UUID) {
        UserDefaults.standard.set(value, forKey: csvDecimalSeparatorKey(for: bankId))
    }

    /// Für CSVParser: Mapping der aktuell ausgewählten Bank.
    static func loadActiveBankCSVMapping() -> [String: String]? {
        loadCSVColumnMapping(for: selectedBankId)
    }

    static func activeBankFieldSeparator() -> String {
        loadCSVFieldSeparator(for: selectedBankId)
    }

    static func activeBankDecimalSeparator() -> String {
        loadCSVDecimalSeparator(for: selectedBankId)
    }

    // MARK: - Einlese-Merkliste (bereits eingelesene Dateinamen)

    private static let eingeleseneDateinamenKey = "Aktien.EingeleseneDateinamen"
    private static let maxEingeleseneDateinamen = 100

    /// Liste der zuletzt eingelesenen Dateinamen (für Hinweis bei erneuter Auswahl). Beim Lesen werden ungültige Einträge nicht entfernt (kein Dateipfad gespeichert).
    static func eingeleseneDateinamen() -> [String] {
        guard let data = UserDefaults.standard.data(forKey: eingeleseneDateinamenKey),
              let list = try? JSONDecoder().decode([String].self, from: data) else { return [] }
        return list
    }

    /// Fügt Dateinamen zur Merkliste hinzu (Duplikate ans Ende, max. 100 Einträge).
    static func addEingeleseneDateinamen(_ names: [String]) {
        var list = eingeleseneDateinamen()
        let neu = names.filter { !$0.isEmpty }
        for n in neu {
            list.removeAll { $0 == n }
            list.append(n)
        }
        if list.count > maxEingeleseneDateinamen {
            list = Array(list.suffix(maxEingeleseneDateinamen))
        }
        guard let data = try? JSONEncoder().encode(list) else { return }
        UserDefaults.standard.set(data, forKey: eingeleseneDateinamenKey)
    }

    /// Merkliste leeren („EinleseBereich bereinigen“).
    static func clearEingeleseneDateinamen() {
        UserDefaults.standard.removeObject(forKey: eingeleseneDateinamenKey)
    }
}
