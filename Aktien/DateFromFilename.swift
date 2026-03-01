//
//  DateFromFilename.swift
//  Aktien
//
//  Created by Axel Behm on 06.02.26.
//

import Foundation

enum DateFromFilename {
    /// Parst Datum inkl. Uhrzeit aus Dateinamen.
    /// Unterstützt z. B.:
    /// - Deutsche Bank: Bestandsaufstellung_20260227_181242.csv (YYYYMMDD_HHMMSS)
    /// - Comdirect: depotuebersicht_9774351748_20260226_220945 (Kontonr. vor YYYYMMDD_HHMMSS)
    /// Trenner zwischen Datum und Uhrzeit: „_“ oder „-“. Vor dem Datum muss ein Trenner stehen, damit z. B. Comdirect-Kontonummern nicht als Datum gelten.
    static func parse(_ filename: String) -> Date? {
        // [_-] vor YYYYMMDD, damit z. B. depotuebersicht_9774351748_20260226_220945 nur 20260226_220945 trifft
        let pattern = #"[_-](\d{4})(\d{2})(\d{2})[_-](\d{2})(\d{2})(\d{2})"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let range = NSRange(filename.startIndex..., in: filename)
        let matches = regex.matches(in: filename, options: [], range: range)
        for match in matches {
            guard match.numberOfRanges >= 7,
                  let yRange = Range(match.range(at: 1), in: filename),
                  let mRange = Range(match.range(at: 2), in: filename),
                  let dRange = Range(match.range(at: 3), in: filename),
                  let hRange = Range(match.range(at: 4), in: filename),
                  let minRange = Range(match.range(at: 5), in: filename),
                  let sRange = Range(match.range(at: 6), in: filename),
                  let year = Int(filename[yRange]),
                  let month = Int(filename[mRange]),
                  let day = Int(filename[dRange]),
                  let hour = Int(filename[hRange]),
                  let minute = Int(filename[minRange]),
                  let second = Int(filename[sRange]),
                  (1...12).contains(month),
                  (1...31).contains(day),
                  (0...23).contains(hour),
                  (0...59).contains(minute),
                  (0...59).contains(second) else {
                continue
            }
            var comp = DateComponents()
            comp.year = year
            comp.month = month
            comp.day = day
            comp.hour = hour
            comp.minute = minute
            comp.second = second
            if let date = Calendar.current.date(from: comp) {
                return date
            }
        }
        return nil
    }
}
