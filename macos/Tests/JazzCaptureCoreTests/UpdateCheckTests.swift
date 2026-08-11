import XCTest

@testable import JazzCaptureCore

final class UpdateCheckTests: XCTestCase {
    // MARK: parse(latestReleaseJSON:)

    func testParsesRealShapedLatestReleaseResponse() throws {
        // Trimmed from a real GET /repos/{owner}/{repo}/releases/latest response shape;
        // the unknown keys (assets, author, …) prove tolerance to API additions.
        let fixture = """
            {
              "url": "https://api.github.com/repos/keboola/jazz-desktop-client/releases/230000001",
              "html_url": "https://github.com/keboola/jasnost/releases/tag/v0.21.1",
              "id": 230000001,
              "author": {"login": "padak", "type": "User"},
              "tag_name": "v0.21.1",
              "target_commitish": "main",
              "name": "v0.21.1",
              "draft": false,
              "prerelease": false,
              "created_at": "2026-06-27T09:12:00Z",
              "published_at": "2026-06-27T09:30:12Z",
              "assets": [],
              "body": "## What's Changed\\n..."
            }
            """
        let release = try XCTUnwrap(UpdateCheck.parse(latestReleaseJSON: Data(fixture.utf8)))
        XCTAssertEqual(release.tagName, "v0.21.1")
        XCTAssertEqual(
            release.htmlURL.absoluteString,
            "https://github.com/keboola/jasnost/releases/tag/v0.21.1")
        let published = try XCTUnwrap(release.publishedAt)
        XCTAssertEqual(
            published, ISO8601DateFormatter().date(from: "2026-06-27T09:30:12Z"))
    }

    func testParseToleratesNullPublishedAt() throws {
        let fixture = """
            {"tag_name": "v0.22.0", "html_url": "https://github.com/keboola/jasnost/releases/tag/v0.22.0", "published_at": null}
            """
        let release = try XCTUnwrap(UpdateCheck.parse(latestReleaseJSON: Data(fixture.utf8)))
        XCTAssertEqual(release.tagName, "v0.22.0")
        XCTAssertNil(release.publishedAt)
    }

    func testParseRejectsMalformedPayloads() {
        // Not JSON at all.
        XCTAssertNil(UpdateCheck.parse(latestReleaseJSON: Data("not json".utf8)))
        // Missing tag_name (e.g. an error envelope: {"message": "Not Found"}).
        XCTAssertNil(
            UpdateCheck.parse(
                latestReleaseJSON: Data(#"{"message": "Not Found", "status": "404"}"#.utf8)))
        // Empty tag.
        XCTAssertNil(
            UpdateCheck.parse(
                latestReleaseJSON: Data(
                    #"{"tag_name": "", "html_url": "https://github.com/x"}"#.utf8)))
        // Missing html_url — nowhere to send the user.
        XCTAssertNil(
            UpdateCheck.parse(latestReleaseJSON: Data(#"{"tag_name": "v1.0.0"}"#.utf8)))
        // Non-https html_url is refused (the menu opens this in a browser).
        XCTAssertNil(
            UpdateCheck.parse(
                latestReleaseJSON: Data(
                    #"{"tag_name": "v1.0.0", "html_url": "ftp://evil.example/x"}"#.utf8)))
    }

    // MARK: isNewer(current:latest:)

    func testNewerPatchMinorMajor() {
        XCTAssertTrue(UpdateCheck.isNewer(current: "0.21.1", latest: "0.21.2"))
        XCTAssertTrue(UpdateCheck.isNewer(current: "0.21.1", latest: "0.22.0"))
        XCTAssertTrue(UpdateCheck.isNewer(current: "0.21.1", latest: "1.0.0"))
        // Multi-digit components compare numerically, not lexicographically.
        XCTAssertTrue(UpdateCheck.isNewer(current: "0.9.0", latest: "0.10.0"))
    }

    func testEqualAndOlderAreNotNewer() {
        XCTAssertFalse(UpdateCheck.isNewer(current: "0.21.1", latest: "0.21.1"))
        XCTAssertFalse(UpdateCheck.isNewer(current: "0.21.1", latest: "0.21.0"))
        XCTAssertFalse(UpdateCheck.isNewer(current: "1.0.0", latest: "0.99.99"))
    }

    func testVPrefixToleratedOnEitherSide() {
        XCTAssertTrue(UpdateCheck.isNewer(current: "v0.21.1", latest: "v0.22.0"))
        XCTAssertTrue(UpdateCheck.isNewer(current: "0.21.1", latest: "v0.22.0"))
        XCTAssertTrue(UpdateCheck.isNewer(current: "v0.21.1", latest: "0.22.0"))
        XCTAssertFalse(UpdateCheck.isNewer(current: "v0.21.1", latest: "V0.21.1"))
    }

    func testUnequalComponentCountsZeroPad() {
        XCTAssertFalse(UpdateCheck.isNewer(current: "1.2", latest: "1.2.0"))
        XCTAssertFalse(UpdateCheck.isNewer(current: "1.2.0", latest: "1.2"))
        XCTAssertTrue(UpdateCheck.isNewer(current: "1.2", latest: "1.2.1"))
        XCTAssertFalse(UpdateCheck.isNewer(current: "1.2.1", latest: "1.2"))
    }

    func testPrereleaseSuffixesCompareOnNumericCore() {
        // A newer core is newer even when tagged as a prerelease…
        XCTAssertTrue(UpdateCheck.isNewer(current: "0.21.1", latest: "0.22.0-rc.1"))
        // …but a prerelease (or build) of the SAME core never nags.
        XCTAssertFalse(UpdateCheck.isNewer(current: "0.21.1", latest: "0.21.1-rc.1"))
        XCTAssertFalse(UpdateCheck.isNewer(current: "0.21.1", latest: "0.21.1+5"))
        // Prerelease suffix on the current side is stripped the same way.
        XCTAssertTrue(UpdateCheck.isNewer(current: "0.21.1-rc.1", latest: "0.21.2"))
    }

    func testMalformedVersionsAreNeverNewer() {
        // "dev" is the unbundled-build placeholder (swift run) — must never nag.
        XCTAssertFalse(UpdateCheck.isNewer(current: "dev", latest: "v0.22.0"))
        XCTAssertFalse(UpdateCheck.isNewer(current: "0.21.1", latest: "latest"))
        XCTAssertFalse(UpdateCheck.isNewer(current: "", latest: "v0.22.0"))
        XCTAssertFalse(UpdateCheck.isNewer(current: "0.21.1", latest: ""))
        XCTAssertFalse(UpdateCheck.isNewer(current: "0.21.1", latest: "v"))
        XCTAssertFalse(UpdateCheck.isNewer(current: "0.21.1", latest: "0..1"))
        XCTAssertFalse(UpdateCheck.isNewer(current: "0.21.1", latest: "0.x.1"))
    }

    // MARK: shouldCheck(now:lastCheck:)

    func testShouldCheckThrottle() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        // Never checked → due.
        XCTAssertTrue(UpdateCheck.shouldCheck(now: now, lastCheck: nil))
        // Checked two hours ago → not due yet.
        XCTAssertFalse(UpdateCheck.shouldCheck(now: now, lastCheck: now.addingTimeInterval(-2 * 3600)))
        // Checked 25 hours ago → due again.
        XCTAssertTrue(UpdateCheck.shouldCheck(now: now, lastCheck: now.addingTimeInterval(-25 * 3600)))
        // Exactly at the interval boundary counts as due.
        XCTAssertTrue(
            UpdateCheck.shouldCheck(
                now: now, lastCheck: now.addingTimeInterval(-UpdateCheck.checkInterval)))
        // A future stamp (clock skew) reads as recently checked — stay quiet.
        XCTAssertFalse(UpdateCheck.shouldCheck(now: now, lastCheck: now.addingTimeInterval(3600)))
    }
}
