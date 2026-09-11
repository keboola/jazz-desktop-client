import Foundation
import XCTest
@testable import JazzCaptureCore

final class CaptureDiskReserveTests: XCTestCase {
    func testConfigurableReserveAndExactThresholdIncludingImmediateWrite() throws {
        for bytes in [Int64(1), 512, CaptureDiskReserve.initialReserveBytes, Int64.max] {
            let reserve = try CaptureDiskReserve(setting: String(bytes))
            XCTAssertEqual(reserve.bytes, bytes)
            XCTAssertNoThrow(try reserve.validate(.init(availableBytes: bytes, sampledAtUptime: 10), nowUptime: 10))
            XCTAssertThrowsError(try reserve.validate(.init(availableBytes: bytes - 1, sampledAtUptime: 10), nowUptime: 10)) {
                XCTAssertEqual($0 as? CaptureDiskReserve.Failure, .insufficient(available: bytes - 1, required: bytes))
            }
        }
        let reserve = try CaptureDiskReserve(setting: "512")
        XCTAssertNoThrow(try reserve.validate(.init(availableBytes: 600, sampledAtUptime: 10),
            nowUptime: 10, immediateWriteBytes: 88))
        XCTAssertThrowsError(try reserve.validate(.init(availableBytes: 600, sampledAtUptime: 10),
            nowUptime: 10, immediateWriteBytes: 89))
        XCTAssertEqual(CaptureDiskReserve.initialReserveBytes, 2_147_483_648)
    }

    func testInvalidConfigurationArithmeticAndUnknownCapacityFailClosed() throws {
        for text in ["", "0", "-1", "+1", "1.5", "2GiB", " 512", "512\n", "true", "9223372036854775808", "１"] {
            XCTAssertThrowsError(try CaptureDiskReserve(setting: text), text) {
                XCTAssertEqual($0 as? CaptureDiskReserve.Failure, .invalidReserve)
            }
        }
        let reserve = try CaptureDiskReserve(setting: "512")
        for (capacity, expected) in [(nil, CaptureDiskReserve.Failure.unknownCapacity), (Int64(-1), .invalidCapacity)] {
            XCTAssertThrowsError(try reserve.validate(.init(availableBytes: capacity, sampledAtUptime: 10), nowUptime: 10)) {
                XCTAssertEqual($0 as? CaptureDiskReserve.Failure, expected)
            }
        }
        for write in [Int64(-1), Int64.max] {
            XCTAssertThrowsError(try reserve.validate(.init(availableBytes: .max, sampledAtUptime: 10),
                nowUptime: 10, immediateWriteBytes: write)) {
                XCTAssertEqual($0 as? CaptureDiskReserve.Failure, .invalidWriteSize)
            }
        }
    }

    func testStaleFutureAndInvalidClockCannotAuthorizeAdmission() throws {
        let reserve = try CaptureDiskReserve(setting: "1")
        XCTAssertNoThrow(try reserve.validate(.init(availableBytes: 1, sampledAtUptime: 10), nowUptime: 13))
        for (sample, now) in [(10.0, 13.0001), (10, 9), (-1, 0), (.nan, 10), (10, .nan), (.infinity, .infinity), (10, .infinity)] {
            XCTAssertThrowsError(try reserve.validate(.init(availableBytes: .max, sampledAtUptime: sample), nowUptime: now)) {
                XCTAssertEqual($0 as? CaptureDiskReserve.Failure, .staleCapacity)
            }
        }
    }
}
