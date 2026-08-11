import Security
import XCTest

@testable import JazzCapture

final class ExecutableSecurityPolicyTests: XCTestCase {
    func testAllDesktopCredentialsAreDeviceLocalAfterFirstUnlock() {
        XCTAssertEqual(
            Keychain.accessibility as String,
            kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly as String)
    }
}
