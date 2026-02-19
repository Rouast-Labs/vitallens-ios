import Foundation
import CoreVideo
import ImageIO
import VitalLensInference

#if canImport(UIKit)
import UIKit
#endif

/// A container for a video frame and its capture metadata.
public struct InputFrame: Sendable {
    public let buffer: SendablePixelBuffer
    public let orientation: CGImagePropertyOrientation
    public let isMirrored: Bool
    public let timestamp: TimeInterval
    
    public init(buffer: SendablePixelBuffer, orientation: CGImagePropertyOrientation, isMirrored: Bool, timestamp: TimeInterval) {
        self.buffer = buffer
        self.orientation = orientation
        self.isMirrored = isMirrored
        self.timestamp = timestamp
    }
}

/// A thread-safe wrapper for transporting UI references (UIView, NSView) into actors.
public struct SendableUIPreview: @unchecked Sendable {
    public let view: Any
    public init(_ view: Any) { self.view = view }
}

/// Abstraction for face detection.
public protocol FaceDetecting: Sendable {
    func detectFace(
        in pixelBuffer: SendablePixelBuffer, 
        orientation: CGImagePropertyOrientation
    ) async throws -> CGRect?
}

/// Abstract interface for a camera source.
public protocol CameraStreaming: Sendable {
    /// The stream of input frames including metadata.
    var stream: AsyncStream<InputFrame> { get }
    
    func start() async throws
    func stop()
    
    #if canImport(UIKit)
    @MainActor func showPreview(on view: UIView)
    #endif
}