//
//  ImportPositionSnapshot.swift
//  Aktien
//
//  Pro Einlesung pro Position: Marktwert, Kurs, Kursziel, Abstand – für Verlauf/Charts (letzte 10 Einlesungen).
//

import Foundation
import SwiftData

@Model
final class ImportPositionSnapshot {
    var importDatum: Date
    var isin: String
    var wkn: String
    /// Bankleistungsnummer, damit dieselbe Aktie (ISIN) unter mehreren BL getrennt geführt wird
    var bankleistungsnummer: String
    var marktwertEUR: Double?
    var kurs: Double?
    var kursziel: Double?
    /// Abstand Kurs → Kursziel in %; (kursziel - kurs) / kurs * 100
    var abstandPct: Double?

    init(importDatum: Date, isin: String, wkn: String, bankleistungsnummer: String = "", marktwertEUR: Double? = nil, kurs: Double? = nil, kursziel: Double? = nil, abstandPct: Double? = nil) {
        self.importDatum = importDatum
        self.isin = isin
        self.wkn = wkn
        self.bankleistungsnummer = bankleistungsnummer
        self.marktwertEUR = marktwertEUR
        self.kurs = kurs
        self.kursziel = kursziel
        self.abstandPct = abstandPct
    }
}
