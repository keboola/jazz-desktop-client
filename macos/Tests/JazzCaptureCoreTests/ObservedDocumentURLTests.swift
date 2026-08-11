import XCTest

@testable import JazzCaptureCore

final class ObservedDocumentURLTests: XCTestCase {
    func testHTTPURLDropsCredentialsQueryAndFragment() {
        XCTAssertEqual(
            ObservedDocumentURL.sanitize(
                "  HTTPS://Alice:secret@Example.COM/invoices/42?token=private#details  "),
            "https://example.com/invoices/42"
        )
    }

    func testFileURLKeepsOnlyPortableBasename() throws {
        let sanitized = try XCTUnwrap(
            ObservedDocumentURL.sanitize("file:///Users/alice/Finance/July Invoice.pdf"))
        XCTAssertFalse(sanitized.contains("alice"))
        XCTAssertFalse(sanitized.contains("Finance"))
        XCTAssertTrue(sanitized.contains("July%20Invoice.pdf"))
        XCTAssertFalse(ObservedDocumentURL.isClickableHTTP(sanitized))
    }

    func testOnlyHTTPAndHTTPSAreClickable() {
        XCTAssertTrue(ObservedDocumentURL.isClickableHTTP("https://example.com/path"))
        XCTAssertTrue(ObservedDocumentURL.isClickableHTTP("http://localhost/path"))
        XCTAssertFalse(ObservedDocumentURL.isClickableHTTP("file:///%3Clocal%3E/report.pdf"))
        XCTAssertFalse(ObservedDocumentURL.isClickableHTTP("app://com.example.app"))
        XCTAssertFalse(ObservedDocumentURL.isClickableHTTP(nil))
    }

    func testRejectsUnsafeOrMalformedSchemes() {
        XCTAssertNil(ObservedDocumentURL.sanitize("data:text/plain,secret"))
        XCTAssertNil(ObservedDocumentURL.sanitize("javascript:alert(1)"))
        XCTAssertNil(ObservedDocumentURL.sanitize("https:///missing-host"))
        XCTAssertNil(ObservedDocumentURL.sanitize("   "))
        XCTAssertNil(ObservedDocumentURL.sanitize(nil))
    }
}
