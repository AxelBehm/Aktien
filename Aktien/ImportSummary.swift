//
//  ImportSummary.swift
//  Aktien
//
//  Created by Axel Behm on 04.02.26.
//

import Foundation
import SwiftData

@Model
final class ImportSummary {
    var gesamtwertVoreinlesung: Double
    var gesamtwertAktuelleEinlesung: Double
    var importDatum: Date
    var datumVoreinlesung: Date?
    var datumAktuelleEinlesung: Date
    /// Bank, mit der diese Einlesung erfolgte (für „Letzte Einlesung pro Bank“ auch ohne feste BL).
    var importBankId: UUID?
    /// Eindeutige Lauf-ID, damit Snapshots genau diesem Import-Lauf zugeordnet werden (mehrere Läufe pro Tag).
    var importRunId: UUID?
    
    init(gesamtwertVoreinlesung: Double, gesamtwertAktuelleEinlesung: Double, datumVoreinlesung: Date? = nil, datumAktuelleEinlesung: Date, importBankId: UUID? = nil, importRunId: UUID? = nil) {
        self.gesamtwertVoreinlesung = gesamtwertVoreinlesung
        self.gesamtwertAktuelleEinlesung = gesamtwertAktuelleEinlesung
        self.importDatum = datumAktuelleEinlesung
        self.datumVoreinlesung = datumVoreinlesung
        self.datumAktuelleEinlesung = datumAktuelleEinlesung
        self.importBankId = importBankId
        self.importRunId = importRunId
    }
}
