//
//  DateFromFilename.swift
//  Aktien
//
//  Created by Axel Behm on 06.02.26.
//

import Foundation

enum DateFromFilename {
    /// Parst Datum aus Dateinamen wie Bestandsaufstellung_20260205_130835
    /// Format: YYYYMMDD_HHMMSS (Jahr, Monat, Tag_Stunde, Minute, Sekunde)
    static func parse(_ filename: String) -> Date? {
    // Pattern: _YYYYMMDD_HHMMSS (z.B. Bestandsaufstellung_20260205_130835)
    let pattern = #"(\d{4})(\d{2})(\d{2})_(\d{2})(\d{2})(\d{2})"#
    guard let regex = try? NSRegularExpression(pattern: pattern),
          let match = regex.firstMatch(in: filename, range: NSRange(filename.startIndex..., in: filename)) else {
        return nil
    }
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
        return nil
    }
    var comp = DateComponents()
    comp.year = year
    comp.month = month
    comp.day = day
    comp.hour = hour
    comp.minute = minute
    comp.second = second
    return Calendar.current.date(from: comp)
    }
}
