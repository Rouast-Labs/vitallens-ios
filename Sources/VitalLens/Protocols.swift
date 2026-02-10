import Foundation
import CoreVideo
import ImageIO

#if canImport(UIKit)
import UIKit
#endif

/// A thread-safe wrapper for CVPixelBuffer to satisfy Swift 6 strict concurrency.
public struct SendablePixelBuffer: @unchecked Sendable {
    public let buffer: CVPixelBuffer
    public init(_ buffer: CVPixelBuffer) { self.buffer = buffer }
}

/// A thread-safe wrapper for transporting UI references (UIView, NSView) into actors.
/// CAUTION: Only access the wrapped value on the Main Actor.
public struct SendableUIPreview: @unchecked Sendable {
    public let view: Any
    public init(_ view: Any) { self.view = view }
}

/// Abstraction for face detection to allow mocking in tests.
public protocol FaceDetecting: Sendable {
    func detectFace(
        in pixelBuffer: SendablePixelBuffer, 
        orientation: CGImagePropertyOrientation
    ) async throws -> CGRect?
}

/// Abstract interface for a camera source to allow mocking in tests.
public protocol CameraStreaming: Sendable {
    var stream: AsyncStream<SendablePixelBuffer> { get }
    func start() async throws
    func stop()
    
    // Only require the view preview method on platforms that have UIKit
    #if canImport(UIKit)
    @MainActor func showPreview(on view: UIView)
    #endif
}
