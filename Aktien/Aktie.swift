//
//  Aktie.swift
//  Aktien
//
//  Created by Axel Behm on 28.01.26.
//

import Foundation
import SwiftData

@Model
final class Aktie {
    var bankleistungsnummer: String
    var bestand: Double
    var bezeichnung: String
    var wkn: String
    var isin: String
    var waehrung: String
    var hinweisEinstandskurs: String
    var einstandskurs: Double?
    var deviseneinstandskurs: Double?
    var kurs: Double?
    var devisenkurs: Double?
    var gewinnVerlustEUR: Double?
    var gewinnVerlustProzent: Double?
    var marktwertEUR: Double?
    var stueckzinsenEUR: Double?
    var anteilProzent: Double?
    var datumLetzteBewegung: Date?
    var gattung: String
    var branche: String
    var risikoklasse: String
    var depotPortfolioName: String
    var importDatum: Date
    var kursziel: Double?
    var kurszielDatum: Date?
    /// Abstand zum Kursziel (Spalte 4, z. B. in %), aus Tabelle ermittelt
    var kurszielAbstand: Double?
    /// Quelle: "Y" = Yahoo, "F" = finanzen.net
    var kurszielQuelle: String?
    /// Währung des Kursziels (EUR/USD), aus Quelldaten
    var kurszielWaehrung: String?
    /// Hochziel (FMP)
    var kurszielHigh: Double?
    /// Niedrigziel (FMP)
    var kurszielLow: Double?
    /// Anzahl Analysten (FMP)
    var kurszielAnalysten: Int?
    /// true = manuell geändert, nicht automatisch überschreiben
    var kurszielManuellGeaendert: Bool = false
    /// Marktwert aus der Voreinlesung (für Vergleich bei Ersetzung)
    var previousMarktwertEUR: Double?
    /// Bestand aus der Voreinlesung (für Vergleich bei Ersetzung)
    var previousBestand: Double?
    /// Kurs aus der Voreinlesung (für Vergleich bei Ersetzung)
    var previousKurs: Double?
    /// true = Eintrag aus der Watchlist (BL 999999), nicht aus CSV-Import
    var isWatchlist: Bool = false
    
    init(
        bankleistungsnummer: String,
        bestand: Double,
        bezeichnung: String,
        wkn: String,
        isin: String,
        waehrung: String,
        hinweisEinstandskurs: String = "",
        einstandskurs: Double? = nil,
        deviseneinstandskurs: Double? = nil,
        kurs: Double? = nil,
        devisenkurs: Double? = nil,
        gewinnVerlustEUR: Double? = nil,
        gewinnVerlustProzent: Double? = nil,
        marktwertEUR: Double? = nil,
        stueckzinsenEUR: Double? = nil,
        anteilProzent: Double? = nil,
        datumLetzteBewegung: Date? = nil,
        gattung: String,
        branche: String,
        risikoklasse: String,
        depotPortfolioName: String = "",
        kursziel: Double? = nil,
        kurszielDatum: Date? = nil,
        kurszielAbstand: Double? = nil,
        kurszielQuelle: String? = nil,
        kurszielWaehrung: String? = nil,
        kurszielHigh: Double? = nil,
        kurszielLow: Double? = nil,
        kurszielAnalysten: Int? = nil,
        kurszielManuellGeaendert: Bool = false,
        previousMarktwertEUR: Double? = nil,
        previousBestand: Double? = nil,
        previousKurs: Double? = nil,
        isWatchlist: Bool = false
    ) {
        self.bankleistungsnummer = bankleistungsnummer
        self.bestand = bestand
        self.bezeichnung = bezeichnung
        self.wkn = wkn
        self.isin = isin
        self.waehrung = waehrung
        self.hinweisEinstandskurs = hinweisEinstandskurs
        self.einstandskurs = einstandskurs
        self.deviseneinstandskurs = deviseneinstandskurs
        self.kurs = kurs
        self.devisenkurs = devisenkurs
        self.gewinnVerlustEUR = gewinnVerlustEUR
        self.gewinnVerlustProzent = gewinnVerlustProzent
        self.marktwertEUR = marktwertEUR
        self.stueckzinsenEUR = stueckzinsenEUR
        self.anteilProzent = anteilProzent
        self.datumLetzteBewegung = datumLetzteBewegung
        self.gattung = gattung
        self.branche = branche
        self.risikoklasse = risikoklasse
        self.depotPortfolioName = depotPortfolioName
        self.importDatum = Date()
        self.kursziel = kursziel
        self.kurszielDatum = kurszielDatum
        self.kurszielAbstand = kurszielAbstand
        self.kurszielQuelle = kurszielQuelle
        self.kurszielWaehrung = kurszielWaehrung
        self.kurszielHigh = kurszielHigh
        self.kurszielLow = kurszielLow
        self.kurszielAnalysten = kurszielAnalysten
        self.kurszielManuellGeaendert = kurszielManuellGeaendert
        self.previousMarktwertEUR = previousMarktwertEUR
        self.previousBestand = previousBestand
        self.previousKurs = previousKurs
        self.isWatchlist = isWatchlist
    }
}

/// Bankleistungsnummer für Watchlist-Positionen (werden in der Liste unter „Watchlist“ geführt)
let watchlistBankleistungsnummer = "999999"
