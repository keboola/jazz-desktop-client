import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Concrete JPEG encoder for an already privacy-filtered frame, called by a reserved media
/// operation. Does not acquire a screen or replace the installed archive screenshot encoder.
/// Output is capped WHILE ImageIO writes, not after NSBitmapImageRep allocates an entire JPEG.
enum BestEffortImageEncoder {
    private final class Output {
        let maximumBytes: Int
        let cancelled: () -> Bool
        let lock = NSLock()
        var data = Data()
        var failed = false
        init(maximumBytes: Int, cancelled: @escaping () -> Bool) {
            self.maximumBytes = maximumBytes
            self.cancelled = cancelled
        }
        func append(_ buffer: UnsafeRawPointer, count: Int) -> Int {
            lock.withLock {
                guard !failed, !cancelled(), count >= 0, count <= maximumBytes - data.count else {
                    failed = true
                    return 0
                }
                data.append(buffer.assumingMemoryBound(to: UInt8.self), count: count)
                return count
            }
        }
    }
    static func jpeg(
        _ image: CGImage, maximumBytes: Int, maximumPixelBytes: Int,
        quality: Double, cancelled: @escaping () -> Bool
    ) -> Data? {
        guard maximumBytes > 0, maximumBytes <= 256 * 1024 * 1024,
            maximumPixelBytes > 0, image.height > 0, image.width > 0,
            image.bytesPerRow > 0, image.bytesPerRow <= maximumPixelBytes / image.height,
            quality.isFinite, (0...1).contains(quality), !cancelled()
        else { return nil }
        // Visible pixel geometry is a preflight, not proof of a cropped/provider backing store's
        // size or ImageIO's private working set. The acquisition owner must budget those too.
        let output = Output(maximumBytes: maximumBytes, cancelled: cancelled)
        return withExtendedLifetime(output) {
            var callbacks = CGDataConsumerCallbacks(
                putBytes: { info, buffer, count in
                    guard let info else { return 0 }
                    return Unmanaged<Output>.fromOpaque(info).takeUnretainedValue().append(
                        buffer, count: count)
                },
                releaseConsumer: { info in
                    if let info { Unmanaged<Output>.fromOpaque(info).release() }
                })
            let retained = Unmanaged.passRetained(output)
            guard let consumer = CGDataConsumer(info: retained.toOpaque(), cbks: &callbacks) else {
                retained.release()
                return nil
            }
            guard
                let destination = CGImageDestinationCreateWithDataConsumer(
                    consumer, UTType.jpeg.identifier as CFString, 1, nil)
            else { return nil }
            CGImageDestinationAddImage(
                destination, image,
                [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
            guard CGImageDestinationFinalize(destination), !output.failed, !cancelled(),
                !output.data.isEmpty
            else { return nil }
            return output.data
        }
    }
}
