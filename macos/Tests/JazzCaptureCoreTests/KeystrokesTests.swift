import XCTest

@testable import JazzCaptureCore

/// Tests the pure keystroke classification + typing accumulation + typed-text redaction that back
/// the "semantic text + shortcuts" capture model.
final class KeystrokesTests: XCTestCase {
    // MARK: classification

    func testPlainCharacterIsText() {
        let a = KeyClassifier.classify(
            keycode: 0, characters: "a", command: false, control: false, option: false, shift: false
        )
        XCTAssertEqual(a, .text("a"))
    }

    func testShiftedCharacterIsStillText() {
        // Shift is part of normal typing — "A", not a shortcut.
        let a = KeyClassifier.classify(
            keycode: 0, characters: "A", command: false, control: false, option: false, shift: true
        )
        XCTAssertEqual(a, .text("A"))
    }

    func testCommandChordIsShortcut() {
        let s = KeyClassifier.classify(
            keycode: 1, characters: "s", command: true, control: false, option: false, shift: false
        )
        XCTAssertEqual(s, .shortcut("Cmd+S"))
    }

    func testModifierOrderIsStable() {
        let z = KeyClassifier.classify(
            keycode: 6, characters: "z", command: true, control: false, option: false, shift: true
        )
        XCTAssertEqual(z, .shortcut("Cmd+Shift+Z"))
    }

    func testSpecialKeys() {
        XCTAssertEqual(
            KeyClassifier.classify(
                keycode: 36, characters: nil, command: false, control: false, option: false,
                shift: false), .special("Enter"))
        XCTAssertEqual(
            KeyClassifier.classify(
                keycode: 48, characters: "\t", command: false, control: false, option: false,
                shift: false), .special("Tab"))
        XCTAssertEqual(
            KeyClassifier.classify(
                keycode: 123, characters: nil, command: false, control: false, option: false,
                shift: false), .special("ArrowLeft"))
    }

    func testBackspaceAndIgnored() {
        XCTAssertEqual(
            KeyClassifier.classify(
                keycode: 51, characters: nil, command: false, control: false, option: false,
                shift: false), .backspace)
        // Unprintable / dead key with no characters -> ignored.
        XCTAssertEqual(
            KeyClassifier.classify(
                keycode: 999, characters: nil, command: false, control: false, option: false,
                shift: false), .ignored)
    }

    func testOptionBackspaceDeletesPreviousWord() {
        XCTAssertEqual(
            KeyClassifier.classify(
                keycode: 51, characters: nil, command: false, control: false, option: true,
                shift: false), .wordBackspace)

        var acc = TypingAccumulator()
        acc.append("Invoice apporve")
        acc.wordBackspace()
        acc.append("approved")
        XCTAssertEqual(acc.flush(), "Invoice approved")
    }

    func testRenderedFieldValueReconcilesComplexEditing() {
        var acc = TypingAccumulator()
        acc.append("Invoice apporveapproved")
        XCTAssertEqual(
            acc.flush(reconciledWith: "Invoice approved"),
            "Invoice approved")
        XCTAssertTrue(acc.isEmpty)
    }

    func testSpaceIsText() {
        let space = KeyClassifier.classify(
            keycode: 49, characters: " ", command: false, control: false, option: false, shift: false
        )
        XCTAssertEqual(space, .text(" "))
    }

    // MARK: keymap round-trip (capture name -> replay keycode)

    func testKeymapRoundTrip() {
        for name in ["A", "S", "Z", "7", "Enter", "Tab", "Escape", "ArrowUp"] {
            guard let code = KeyMap.nameToCode[name] else { return XCTFail("no code for \(name)") }
            // Letters/digits/specials must map back to a usable name (Enter has two codes, fine).
            XCTAssertNotNil(KeyMap.codeToName[code], "no name for \(name)'s code \(code)")
        }
        XCTAssertEqual(KeyMap.nameToCode["S"], 1)
        XCTAssertEqual(KeyMap.nameToCode["Enter"], 36)
    }

    // MARK: typing accumulator

    func testAccumulatorAppendsBackspacesAndFlushes() {
        var acc = TypingAccumulator()
        XCTAssertTrue(acc.isEmpty)
        acc.append("h")
        acc.append("e")
        acc.append("l")
        acc.append("o")
        acc.backspace()  // "hel"
        acc.append("lo")  // "hello"
        XCTAssertFalse(acc.isEmpty)
        XCTAssertEqual(acc.flush(), "hello")
        XCTAssertTrue(acc.isEmpty)
        XCTAssertEqual(acc.flush(), "")  // idempotent once cleared
    }

    func testBackspaceOnEmptyIsNoop() {
        var acc = TypingAccumulator()
        acc.backspace()
        XCTAssertTrue(acc.isEmpty)
    }

    // MARK: typed-text redaction

    func testRedactMasksEmail() {
        XCTAssertEqual(Sensitivity.redactTyped("ping petr@keboola.com now"), "ping •••@••• now")
    }

    func testRedactMasksLongDigitRuns() {
        // 16-digit card masked; short numbers left intact.
        XCTAssertEqual(Sensitivity.redactTyped("card 4111111111111111 ok"), "card •••••••••••••••• ok")
        XCTAssertEqual(Sensitivity.redactTyped("year 2026"), "year 2026")
        XCTAssertEqual(Sensitivity.redactTyped("42 + 8"), "42 + 8")
    }

    func testRedactKeepsOrdinaryText() {
        XCTAssertEqual(Sensitivity.redactTyped("San Francisco"), "San Francisco")
        XCTAssertNil(Sensitivity.redactTyped("   "))
        XCTAssertNil(Sensitivity.redactTyped(nil))
    }

    func testTypedMaskDispositionMeansContentWasActuallyReplaced() {
        XCTAssertEqual(
            Sensitivity.redactTypedWithDisposition("Review status"),
            TypedTextRedaction(value: "Review status", wasMasked: false))
        XCTAssertEqual(
            Sensitivity.redactTypedWithDisposition("mail petr@keboola.com"),
            TypedTextRedaction(value: "mail •••@•••", wasMasked: true))
        XCTAssertEqual(
            Sensitivity.redactTypedWithDisposition("card 4111111111111111"),
            TypedTextRedaction(value: "card ••••••••••••••••", wasMasked: true))
        XCTAssertNil(Sensitivity.redactTypedWithDisposition("   "))
    }

    func testRenderedTypingReconciliationRequiresSameNonSensitiveFocus() {
        XCTAssertEqual(
            Sensitivity.typingReconciliationValue(
                "Invoice approved",
                observedFocusIdentity: "status|AXTextField|Status",
                bufferedFocusIdentity: "status|AXTextField|Status",
                role: "AXTextField",
                subrole: nil,
                label: "Status"),
            "Invoice approved")
        XCTAssertNil(
            Sensitivity.typingReconciliationValue(
                "another field",
                observedFocusIdentity: "notes|AXTextField|Notes",
                bufferedFocusIdentity: "status|AXTextField|Status",
                role: "AXTextField",
                subrole: nil,
                label: "Notes"))
        XCTAssertNil(
            Sensitivity.typingReconciliationValue(
                "do-not-capture",
                observedFocusIdentity: "password|AXTextField|Password",
                bufferedFocusIdentity: "password|AXTextField|Password",
                role: "AXTextField",
                subrole: "AXSecureTextField",
                label: "Password"))
    }
}
