import XCTest

@testable import JasnostCaptureCore

final class PerceptualHashTests: XCTestCase {
    func testIdenticalBuffersHashEqualZeroDistance() {
        let a = (0..<72).map { UInt8(($0 * 3) % 256) }
        let h1 = PerceptualHash.dHash(grayscale: a, width: 9, height: 8)
        let h2 = PerceptualHash.dHash(grayscale: a, width: 9, height: 8)
        XCTAssertEqual(h1, h2)
        XCTAssertEqual(PerceptualHash.hammingDistance(h1, h2), 0)
    }

    func testStrictlyIncreasingRowsAreAllOnes() {
        // Every pixel is brighter than its left neighbor → every comparison bit set.
        var s = [UInt8]()
        for _ in 0..<8 { s += (0..<9).map { UInt8($0 * 10) } }
        let h = PerceptualHash.dHash(grayscale: s, width: 9, height: 8)
        XCTAssertEqual(h, 0xFFFF_FFFF_FFFF_FFFF)  // 64 bits, all set
    }

    func testStrictlyDecreasingRowsAreAllZeros() {
        var s = [UInt8]()
        for _ in 0..<8 { s += (0..<9).map { UInt8((8 - $0) * 10) } }
        XCTAssertEqual(PerceptualHash.dHash(grayscale: s, width: 9, height: 8), 0)
    }

    func testOneFlippedComparisonIsDistanceOne() {
        var s = [UInt8]()
        for _ in 0..<8 { s += (0..<9).map { UInt8($0 * 10) } }  // all-ones hash
        // Make the first row's first pair decrease instead of increase → flips exactly one bit.
        s[0] = 200
        s[1] = 0
        let h = PerceptualHash.dHash(grayscale: s, width: 9, height: 8)
        XCTAssertEqual(PerceptualHash.hammingDistance(h, 0xFFFF_FFFF_FFFF_FFFF), 1)
    }

    func testSizeMismatchReturnsZero() {
        // Wrong count → 0 (no signal): the caller keeps the frame rather than skipping it.
        XCTAssertEqual(PerceptualHash.dHash(grayscale: [1, 2, 3], width: 9, height: 8), 0)
    }

    func testTooManyBitsReturnsZero() {
        // (width-1)*height must fit in 64 bits.
        let big = [UInt8](repeating: 0, count: 10 * 8)
        XCTAssertEqual(PerceptualHash.dHash(grayscale: big, width: 10, height: 8), 0)
    }
}
