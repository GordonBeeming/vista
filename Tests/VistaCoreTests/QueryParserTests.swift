// QueryParserTests.swift — Parser correctness + edge cases.

import XCTest
@testable import VistaCore

final class QueryParserTests: XCTestCase {

    // Fixed reference so "today" is deterministic across CI clocks.
    // 2026-04-22 12:00 UTC.
    private let reference = Date(timeIntervalSince1970: 1_777_204_800)

    func testEmptyStringIsEmptyQuery() {
        XCTAssertTrue(QueryParser.parse("").isEmpty)
        XCTAssertTrue(QueryParser.parse("   ").isEmpty)
    }

    func testBareWordBecomesFreeTerm() {
        let q = QueryParser.parse("login")
        XCTAssertEqual(q.freeTerms, ["login"])
        XCTAssertTrue(q.nameTerms.isEmpty)
    }

    func testQuotedFreeText() {
        let q = QueryParser.parse("\"login form\"")
        XCTAssertEqual(q.freeTerms, ["login form"])
    }

    func testNamePrefix() {
        let q = QueryParser.parse("name:invoice")
        XCTAssertEqual(q.nameTerms, ["invoice"])
        XCTAssertTrue(q.freeTerms.isEmpty)
    }

    func testTextPrefixWithQuotedValue() {
        let q = QueryParser.parse("text:\"invoice number\"")
        XCTAssertEqual(q.textTerms, ["invoice number"])
    }

    func testCombinedPrefixesAndFreeText() {
        let q = QueryParser.parse("name:slack login text:oauth")
        XCTAssertEqual(q.nameTerms, ["slack"])
        XCTAssertEqual(q.textTerms, ["oauth"])
        XCTAssertEqual(q.freeTerms, ["login"])
    }

    func testUnknownPrefixTreatedAsFreeText() {
        // We decided in the grammar: unknown prefix → free term verbatim.
        let q = QueryParser.parse("filename:foo")
        XCTAssertEqual(q.freeTerms, ["filename:foo"])
        XCTAssertTrue(q.nameTerms.isEmpty)
    }

    func testDateToday() {
        let q = QueryParser.parse("date:today", reference: reference)
        XCTAssertEqual(q.dateRanges.count, 1)
        let range = q.dateRanges.first!
        XCTAssertTrue(range.contains(reference))
        // Range should be a single calendar day in local time.
        let cal = Calendar(identifier: .gregorian)
        XCTAssertEqual(cal.startOfDay(for: range.lowerBound), range.lowerBound)
    }

    func testDateYesterday() {
        let q = QueryParser.parse("date:yesterday", reference: reference)
        XCTAssertEqual(q.dateRanges.count, 1)
        let range = q.dateRanges.first!
        let cal = Calendar(identifier: .gregorian)
        let yesterday = cal.date(byAdding: .day, value: -1, to: reference)!
        XCTAssertTrue(range.contains(cal.startOfDay(for: yesterday)))
    }

    func testDateISODay() {
        let q = QueryParser.parse("date:2024-12-25")
        XCTAssertEqual(q.dateRanges.count, 1)
        let cal = Calendar(identifier: .gregorian)
        let christmas = cal.date(from: DateComponents(year: 2024, month: 12, day: 25))!
        XCTAssertTrue(q.dateRanges[0].contains(christmas))
    }

    func testDateISOMonth() {
        let q = QueryParser.parse("date:2024-12")
        XCTAssertEqual(q.dateRanges.count, 1)
        let cal = Calendar(identifier: .gregorian)
        let mid = cal.date(from: DateComponents(year: 2024, month: 12, day: 15))!
        XCTAssertTrue(q.dateRanges[0].contains(mid))
    }

    func testDateBareYear() {
        let q = QueryParser.parse("date:2024")
        let cal = Calendar(identifier: .gregorian)
        let summer = cal.date(from: DateComponents(year: 2024, month: 6, day: 21))!
        XCTAssertTrue(q.dateRanges[0].contains(summer))
    }

    func testDateMonthName() {
        let q = QueryParser.parse("date:march", reference: reference)
        let cal = Calendar(identifier: .gregorian)
        let mid = cal.date(from: DateComponents(year: 2026, month: 3, day: 15))!
        XCTAssertTrue(q.dateRanges[0].contains(mid))
    }

    func testDateThreeLetterMonth() {
        let q = QueryParser.parse("date:jul", reference: reference)
        let cal = Calendar(identifier: .gregorian)
        let mid = cal.date(from: DateComponents(year: 2026, month: 7, day: 15))!
        XCTAssertTrue(q.dateRanges[0].contains(mid))
    }

    func testDateLastWeek() {
        let q = QueryParser.parse("date:\"last week\"", reference: reference)
        XCTAssertEqual(q.dateRanges.count, 1)
    }

    func testBadDateIsIgnored() {
        let q = QueryParser.parse("date:never")
        XCTAssertTrue(q.dateRanges.isEmpty)
    }

    func testCaseInsensitivePrefix() {
        let q = QueryParser.parse("NAME:invoice")
        XCTAssertEqual(q.nameTerms, ["invoice"])
    }

    func testMultipleSpacesCollapse() {
        let q = QueryParser.parse("  foo    bar  ")
        XCTAssertEqual(q.freeTerms, ["foo", "bar"])
    }

    func testEmptyValueAfterPrefixIsSkipped() {
        let q = QueryParser.parse("name:")
        XCTAssertTrue(q.nameTerms.isEmpty)
        XCTAssertTrue(q.freeTerms.isEmpty)
    }

    func testMixedBagEndToEnd() {
        let q = QueryParser.parse("oauth text:\"error 500\" date:2024-12 name:chrome")
        XCTAssertEqual(q.freeTerms, ["oauth"])
        XCTAssertEqual(q.textTerms, ["error 500"])
        XCTAssertEqual(q.nameTerms, ["chrome"])
        XCTAssertEqual(q.dateRanges.count, 1)
    }

    func testColonInsideFreeTextIsPreserved() {
        // A colon not preceded by letters is just punctuation — we treat
        // the whole token as free text rather than mangling it.
        let q = QueryParser.parse("12:34")
        XCTAssertEqual(q.freeTerms, ["12:34"])
    }
}
