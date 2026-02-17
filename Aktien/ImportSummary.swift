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
    
    init(gesamtwertVoreinlesung: Double, gesamtwertAktuelleEinlesung: Double, datumVoreinlesung: Date? = nil, datumAktuelleEinlesung: Date) {
        self.gesamtwertVoreinlesung = gesamtwertVoreinlesung
        self.gesamtwertAktuelleEinlesung = gesamtwertAktuelleEinlesung
        self.importDatum = datumAktuelleEinlesung
        self.datumVoreinlesung = datumVoreinlesung
        self.datumAktuelleEinlesung = datumAktuelleEinlesung
    }
}
