import Foundation
import CoreVideo
import ImageIO
#if canImport(UIKit)
import UIKit
#endif

/// A camera source that does not capture video itself, but accepts frames injected from an external source.
/// This is used when integrating the SDK into an app that already manages its own Camera session.
public final class PassiveSource: CameraStreaming, @unchecked Sendable {
    
    private let streamContinuation: AsyncStream<InputFrame>.Continuation
    public let stream: AsyncStream<InputFrame>
    
    public init() {
        var continuation: AsyncStream<InputFrame>.Continuation!
        self.stream = AsyncStream { continuation = $0 }
        self.streamContinuation = continuation
    }
    
    public func start() async throws {
        // No-op: The external host manages the start lifecycle
    }
    
    public func stop() {
        // We don't finish the stream here to allow the host to pause/resume injection without killing the AsyncStream.
        // The host should simply stop calling inject().
    }
    
    /// Injects a frame into the SDK processing pipeline.
    /// - Parameters:
    ///   - buffer: The raw pixel buffer.
    ///   - orientation: The orientation of the image.
    ///   - isMirrored: Whether the image is mirrored.
    ///   - timestamp: The capture timestamp.
    public func inject(buffer: CVPixelBuffer, orientation: CGImagePropertyOrientation, isMirrored: Bool, timestamp: TimeInterval) {
        let frame = InputFrame(
            buffer: SendablePixelBuffer(buffer),
            orientation: orientation,
            isMirrored: isMirrored,
            timestamp: timestamp
        )
        streamContinuation.yield(frame)
    }
    
    #if canImport(UIKit)
    public func showPreview(on view: UIView) {
        // No-op: The external host manages the preview layer
    }
    #endif
}