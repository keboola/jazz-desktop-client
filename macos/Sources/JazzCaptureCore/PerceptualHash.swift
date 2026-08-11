import Foundation

/// Difference hash (dHash) for near-duplicate screenshot detection. The capture path downscales a
/// frame to a tiny grayscale grid and calls ``dHash``; two frames whose hashes are within a small
/// Hamming distance are visually ~identical (e.g. repeated clicks in the same view), so the capture
/// path can SKIP uploading the redundant frame — cutting wasted Keboola Files uploads/bandwidth
/// without dropping meaningful keyframes. Pure (no image APIs) so it is unit-tested in CI.
public enum PerceptualHash {
    /// dHash over a ``width`` × ``height`` row-major grayscale buffer: compare each pixel to its
    /// right neighbor, emitting one bit per comparison — `(width - 1) * height` bits total. The
    /// canonical sizing is width 9 × height 8 → exactly 64 bits. The buffer must be `width * height`
    /// bytes and the bit count must fit in 64; otherwise this returns 0 (treated as "no signal", so
    /// the caller keeps the frame rather than wrongly skipping it).
    public static func dHash(grayscale samples: [UInt8], width: Int, height: Int) -> UInt64 {
        guard width >= 2, height >= 1, samples.count == width * height,
            (width - 1) * height <= 64
        else { return 0 }

        var hash: UInt64 = 0
        var bit: UInt64 = 0
        for row in 0..<height {
            let base = row * width
            for col in 0..<(width - 1) {
                // A brighter pixel to the right than the current → set this bit.
                if samples[base + col] < samples[base + col + 1] {
                    hash |= (1 << bit)
                }
                bit += 1
            }
        }
        return hash
    }

    /// Number of differing bits between two hashes — small means visually similar.
    public static func hammingDistance(_ a: UInt64, _ b: UInt64) -> Int {
        (a ^ b).nonzeroBitCount
    }
}
