import XCTest

@testable import JasnostCaptureCore

final class CaptureScopeTests: XCTestCase {
    func testMintAreaIdKebabsAndLowercases() {
        XCTAssertEqual(CaptureScope.mintAreaId(from: "Merchant Onboarding"), "merchant-onboarding")
        XCTAssertEqual(CaptureScope.mintAreaId(from: "Finance"), "finance")
        XCTAssertEqual(CaptureScope.mintAreaId(from: "  SKU  Stocking  "), "sku-stocking")
        XCTAssertEqual(CaptureScope.mintAreaId(from: "A/B Testing!"), "a-b-testing")
    }

    func testMintAreaIdIsDeterministic() {
        XCTAssertEqual(
            CaptureScope.mintAreaId(from: "Payments"),
            CaptureScope.mintAreaId(from: "Payments"))
    }

    func testNonAsciiCollapsesToDashesAndStaysSafe() {
        // The human name keeps its diacritics; the id is an ASCII-safe handle (each run of
        // non-ASCII collapses to a single dash). "příchutě 2" -> p · [ř
        //  í]→- · chut · [ě]→- · 2  = "p-chut-2".
        XCTAssertEqual(CaptureScope.mintAreaId(from: "Příchutě 2"), "p-chut-2")
    }

    func testEmptyOrPunctuationFallsBackToGeneral() {
        XCTAssertEqual(CaptureScope.mintAreaId(from: ""), CaptureScope.generalAreaId)
        XCTAssertEqual(CaptureScope.mintAreaId(from: "  !!!  "), CaptureScope.generalAreaId)
    }

    // MARK: - AreaRegistry decoding

    func testDecodesFullRegistry() {
        // Full document per the schema, including fields the agent doesn't model (owner,
        // source, timestamps) — they must be ignored, not fail the decode.
        let json = """
            {
              "areaId": "finance",
              "name": "Finance",
              "description": "Money things",
              "owner": {"email": "owner@example.com", "name": "Owner"},
              "source": {"kind": "bdm-domain", "sessionId": "s1", "domainId": "d1"},
              "processes": [
                {
                  "processId": "monthly-booking",
                  "name": "Monthly booking",
                  "description": "Close the month",
                  "owner": {"email": "book@example.com"},
                  "source": "interview",
                  "conceptIds": ["c1"],
                  "sourceSessions": ["s2"]
                },
                {"processId": "invoicing", "name": "Invoicing"}
              ],
              "createdAt": "2026-07-01T00:00:00Z",
              "updatedAt": "2026-07-02T00:00:00Z",
              "updatedBy": "owner@example.com"
            }
            """
        let registry = AreaRegistry.parse(data: Data(json.utf8))
        XCTAssertEqual(registry?.areaId, "finance")
        XCTAssertEqual(registry?.name, "Finance")
        XCTAssertEqual(registry?.processes.count, 2)
        XCTAssertEqual(registry?.processes.first?.processId, "monthly-booking")
        XCTAssertEqual(registry?.processes.first?.name, "Monthly booking")
        XCTAssertEqual(registry?.processes.first?.description, "Close the month")
        XCTAssertEqual(
            registry?.processChoices,
            [
                ProcessChoice(id: "monthly-booking", name: "Monthly booking"),
                ProcessChoice(id: "invoicing", name: "Invoicing"),
            ])
    }

    func testDecodesMinimalRegistry() {
        let registry = AreaRegistry.parse(data: Data(#"{"areaId": "ops", "name": "Ops"}"#.utf8))
        XCTAssertEqual(registry?.areaId, "ops")
        XCTAssertEqual(registry?.name, "Ops")
        XCTAssertEqual(registry?.processes, [])
        XCTAssertEqual(registry?.processChoices, [])
    }

    func testGarbageReturnsNil() {
        XCTAssertNil(AreaRegistry.parse(data: Data("not json at all".utf8)))
        XCTAssertNil(AreaRegistry.parse(data: Data("[1, 2, 3]".utf8)))
        XCTAssertNil(AreaRegistry.parse(data: Data(#""just a string""#.utf8)))
        XCTAssertNil(AreaRegistry.parse(data: Data()))
    }

    func testSkipsUnusableProcessEntries() {
        // A non-object entry and entries missing processId/name are dropped; the good one survives.
        let json = """
            {
              "areaId": "finance",
              "name": "Finance",
              "processes": [
                "garbage-string-entry",
                {"name": "No id here"},
                {"processId": "no-name"},
                {"processId": "invoicing", "name": "Invoicing"}
              ]
            }
            """
        let registry = AreaRegistry.parse(data: Data(json.utf8))
        XCTAssertEqual(registry?.processChoices, [ProcessChoice(id: "invoicing", name: "Invoicing")])
    }

    // MARK: - resolveLabelPick

    private let inventory = [
        ProcessChoice(id: "monthly-booking", name: "Monthly booking"),
        ProcessChoice(id: "invoicing", name: "Invoicing"),
        ProcessChoice(id: "late-payment-check", name: "Late payment check"),
    ]

    func testExactMatchWinsCaseInsensitively() {
        let pick = CaptureScope.resolveLabelPick(text: "  INVOICING ", inventory: inventory)
        XCTAssertEqual(pick.processId, "invoicing")
        XCTAssertEqual(pick.processName, "Invoicing")
        // The stamped label is the CANONICAL registry name, not the typed casing.
        XCTAssertEqual(pick.label, "Invoicing")
    }

    func testUniqueSubstringMatchesTextInName() {
        let pick = CaptureScope.resolveLabelPick(text: "booking", inventory: inventory)
        XCTAssertEqual(pick.processId, "monthly-booking")
        XCTAssertEqual(pick.label, "Monthly booking")
    }

    func testUniqueSubstringMatchesNameInText() {
        let pick = CaptureScope.resolveLabelPick(
            text: "doing the late payment check for June", inventory: inventory)
        XCTAssertEqual(pick.processId, "late-payment-check")
        XCTAssertEqual(pick.label, "Late payment check")
    }

    func testAmbiguousSubstringStaysFreeText() {
        // "ing" appears in every name — ambiguous, so no processId and the raw text survives.
        let pick = CaptureScope.resolveLabelPick(text: "ing", inventory: inventory)
        XCTAssertNil(pick.processId)
        XCTAssertNil(pick.processName)
        XCTAssertEqual(pick.label, "ing")
    }

    func testNoMatchStaysFreeText() {
        let pick = CaptureScope.resolveLabelPick(
            text: "Approving a vendor contract", inventory: inventory)
        XCTAssertNil(pick.processId)
        XCTAssertNil(pick.processName)
        XCTAssertEqual(pick.label, "Approving a vendor contract")
    }

    func testEmptyInventoryStaysFreeText() {
        let pick = CaptureScope.resolveLabelPick(text: "Invoicing", inventory: [])
        XCTAssertNil(pick.processId)
        XCTAssertEqual(pick.label, "Invoicing")
    }

    func testExactMatchBeatsAmbiguousSubstrings() {
        // "Payment" is exact against one entry here even though it substring-matches another.
        let choices = [
            ProcessChoice(id: "payment", name: "Payment"),
            ProcessChoice(id: "late-payment-check", name: "Late payment check"),
        ]
        let pick = CaptureScope.resolveLabelPick(text: "payment", inventory: choices)
        XCTAssertEqual(pick.processId, "payment")
        XCTAssertEqual(pick.label, "Payment")
    }

    func testResolverIsDeterministic() {
        let first = CaptureScope.resolveLabelPick(text: "booking", inventory: inventory)
        let second = CaptureScope.resolveLabelPick(text: "booking", inventory: inventory)
        XCTAssertEqual(first.processId, second.processId)
        XCTAssertEqual(first.label, second.label)
    }
}
