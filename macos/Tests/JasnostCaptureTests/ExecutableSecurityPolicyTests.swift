import Security
import XCTest

@testable import JasnostCapture

final class ExecutableSecurityPolicyTests: XCTestCase {
    func testAllDesktopCredentialsAreDeviceLocalAfterFirstUnlock() {
        XCTAssertEqual(
            Keychain.accessibility as String,
            kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly as String)
    }
}
