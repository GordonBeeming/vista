// QueryParser.swift — Turns a search bar string into a structured Query.
//
// Grammar (loose, permissive — we prefer "do what I mean"):
//   word                        → freeTerms += ["word"]
//   "two words"                 → freeTerms += ["two words"]
//   name:foo                    → nameTerms += ["foo"]
//   text:"invoice number"       → textTerms += ["invoice number"]
//   date:yesterday              → dateRanges += [<midnight..<today>]
//   date:2024-12                → dateRanges += [2024-12-01..2024-12-31]
//   date:2024-12-25             → dateRanges += [that day]
//
// Multiple prefix clauses are AND-combined with each other and with the
// free-text residue. Unrecognised date tokens are silently dropped — users
// type noise, we degrade gracefully rather than erroring the whole query.

import Foundation

public enum QueryParser {

    /// Parses `raw` using the provided `reference` date (injected so tests
    /// can pin "today" to a fixed value). Production callers pass `Date()`.
    public static func parse(_ raw: String, reference: Date = Date()) -> Query {
        var nameTerms: [String] = []
        var textTerms: [String] = []
        var dateRanges: [ClosedRange<Date>] = []
        var freeTerms: [String] = []

        for token in tokenise(raw) {
            if let (prefix, value) = splitPrefix(token) {
                switch prefix.lowercased() {
                case "name":
                    if !value.isEmpty { nameTerms.append(value) }
                case "text":
                    if !value.isEmpty { textTerms.append(value) }
                case "date":
                    if let range = parseDate(value, reference: reference) {
                        dateRanges.append(range)
                    }
                default:
                    // Unknown prefix — treat the whole token as free text so
                    // users who type "filename:foo" don't get silent drops.
                    freeTerms.append(token)
                }
            } else if !token.isEmpty {
                freeTerms.append(token)
            }
        }

        return Query(
            nameTerms: nameTerms,
            textTerms: textTerms,
            dateRanges: dateRanges,
            freeTerms: freeTerms
        )
    }

    // MARK: - Tokenisation

    /// Splits on whitespace but keeps quoted regions together. Handles the
    /// common case of `text:"two words"` without requiring a full parser.
    private static func tokenise(_ raw: String) -> [String] {
        var out: [String] = []
        var current = ""
        var inQuotes = false
        for ch in raw {
            switch ch {
            case "\"":
                inQuotes.toggle()
            case " ", "\t":
                if inQuotes {
                    current.append(ch)
                } else if !current.isEmpty {
                    out.append(current)
                    current = ""
                }
            default:
                current.append(ch)
            }
        }
        if !current.isEmpty { out.append(current) }
        return out
    }

    /// Returns (prefix, value) if `token` is of the form `prefix:value`,
    /// where prefix is a letters-only run. Otherwise nil.
    private static func splitPrefix(_ token: String) -> (String, String)? {
        guard let colon = token.firstIndex(of: ":") else { return nil }
        let prefix = token[..<colon]
        guard !prefix.isEmpty, prefix.allSatisfy(\.isLetter) else { return nil }
        let value = token[token.index(after: colon)...]
        return (String(prefix), String(value))
    }

    // MARK: - Dates

    /// Parses a date fragment into an inclusive range. Supports:
    ///   today / yesterday
    ///   last week / this week
    ///   last month / this month
    ///   january … december (case-insensitive, full or 3-letter)
    ///   YYYY
    ///   YYYY-MM
    ///   YYYY-MM-DD
    private static func parseDate(_ raw: String, reference: Date) -> ClosedRange<Date>? {
        let calendar = Calendar(identifier: .gregorian)
        let normalised = raw.lowercased()
            .replacingOccurrences(of: "_", with: " ")
            .trimmingCharacters(in: .whitespaces)

        switch normalised {
        case "today":
            return dayRange(containing: reference, calendar: calendar)
        case "yesterday":
            guard let y = calendar.date(byAdding: .day, value: -1, to: reference) else { return nil }
            return dayRange(containing: y, calendar: calendar)
        case "this week":
            return weekRange(containing: reference, calendar: calendar)
        case "last week":
            guard let lw = calendar.date(byAdding: .weekOfYear, value: -1, to: reference) else { return nil }
            return weekRange(containing: lw, calendar: calendar)
        case "this month":
            return monthRange(containing: reference, calendar: calendar)
        case "last month":
            guard let lm = calendar.date(byAdding: .month, value: -1, to: reference) else { return nil }
            return monthRange(containing: lm, calendar: calendar)
        case "this year":
            return yearRange(containing: reference, calendar: calendar)
        case "last year":
            guard let ly = calendar.date(byAdding: .year, value: -1, to: reference) else { return nil }
            return yearRange(containing: ly, calendar: calendar)
        default:
            break
        }

        if let monthIndex = monthIndex(for: normalised) {
            // Bare month name → same month of the reference year.
            let year = calendar.component(.year, from: reference)
            guard let date = calendar.date(from: DateComponents(year: year, month: monthIndex, day: 1)) else { return nil }
            return monthRange(containing: date, calendar: calendar)
        }

        let parts = normalised.split(separator: "-").map(String.init)
        switch parts.count {
        case 1:
            // YYYY
            if let year = Int(parts[0]), (1970...2100).contains(year) {
                guard let date = calendar.date(from: DateComponents(year: year, month: 1, day: 1)) else { return nil }
                return yearRange(containing: date, calendar: calendar)
            }
        case 2:
            // YYYY-MM
            if let year = Int(parts[0]), let month = Int(parts[1]),
               (1970...2100).contains(year), (1...12).contains(month),
               let date = calendar.date(from: DateComponents(year: year, month: month, day: 1)) {
                return monthRange(containing: date, calendar: calendar)
            }
        case 3:
            // YYYY-MM-DD
            if let year = Int(parts[0]), let month = Int(parts[1]), let day = Int(parts[2]),
               let date = calendar.date(from: DateComponents(year: year, month: month, day: day)) {
                return dayRange(containing: date, calendar: calendar)
            }
        default:
            break
        }

        return nil
    }

    private static func dayRange(containing date: Date, calendar: Calendar) -> ClosedRange<Date> {
        let start = calendar.startOfDay(for: date)
        let end = calendar.date(byAdding: .day, value: 1, to: start)!.addingTimeInterval(-1)
        return start...end
    }

    private static func weekRange(containing date: Date, calendar: Calendar) -> ClosedRange<Date> {
        var cal = calendar
        cal.firstWeekday = 2 // Monday — matches ISO and most European locales.
        let start = cal.dateInterval(of: .weekOfYear, for: date)?.start ?? date
        let endDay = cal.date(byAdding: .day, value: 7, to: start)!.addingTimeInterval(-1)
        return start...endDay
    }

    private static func monthRange(containing date: Date, calendar: Calendar) -> ClosedRange<Date> {
        let comps = calendar.dateComponents([.year, .month], from: date)
        let start = calendar.date(from: comps)!
        let end = calendar.date(byAdding: DateComponents(month: 1, second: -1), to: start)!
        return start...end
    }

    private static func yearRange(containing date: Date, calendar: Calendar) -> ClosedRange<Date> {
        let year = calendar.component(.year, from: date)
        let start = calendar.date(from: DateComponents(year: year, month: 1, day: 1))!
        let end = calendar.date(from: DateComponents(year: year + 1, month: 1, day: 1))!.addingTimeInterval(-1)
        return start...end
    }

    private static let monthNames: [(String, Int)] = [
        ("january", 1), ("jan", 1),
        ("february", 2), ("feb", 2),
        ("march", 3), ("mar", 3),
        ("april", 4), ("apr", 4),
        ("may", 5),
        ("june", 6), ("jun", 6),
        ("july", 7), ("jul", 7),
        ("august", 8), ("aug", 8),
        ("september", 9), ("sep", 9), ("sept", 9),
        ("october", 10), ("oct", 10),
        ("november", 11), ("nov", 11),
        ("december", 12), ("dec", 12),
    ]

    private static func monthIndex(for token: String) -> Int? {
        monthNames.first { $0.0 == token }?.1
    }
}
