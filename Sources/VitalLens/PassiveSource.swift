import Foundation
import CoreVideo
import ImageIO
import VitalLensInference

#if canImport(UIKit)
import UIKit
#endif

/// A camera source that does not capture video itself, but accepts frames injected from an external source.
/// This is used when integrating the SDK into an app that already manages its own Camera session.
public final class PassiveSource: CameraStreaming, @unchecked Sendable {
    
    private let streamContinuation: AsyncStream<InputFrame>.Continuation

    /// The asynchronous stream of injected video frames.
    public let stream: AsyncStream<InputFrame>
    
    /// Initializes a new PassiveSource.
    public init() {
        let (s, c) = AsyncStream.makeStream(of: InputFrame.self)
        self.stream = s
        self.streamContinuation = c
    }
    
    /// A no-op for `PassiveSource` since it does not manage any hardware.
    public func start() async throws {
    }
    
    /// A no-op for `PassiveSource`. To stop the stream, simply stop injecting frames.
    public func stop() {
    }
    
    /// Injects a frame into the SDK's processing pipeline.
    /// 
    /// - Parameters:
    ///   - buffer: The raw `CVPixelBuffer` from your custom camera or video output.
    ///   - orientation: The orientation of the image.
    ///   - isMirrored: Whether the image is horizontally mirrored.
    ///   - timestamp: The capture timestamp in seconds.
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
    /// A no-op for `PassiveSource`. You must manage your own preview layer.
    ///
    /// - Parameter view: The view where the preview would normally be attached.
    public func showPreview(on view: UIView) {
    }
    #endif
}