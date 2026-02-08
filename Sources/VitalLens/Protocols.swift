import Foundation
import CoreVideo

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
    func detectFace(in pixelBuffer: SendablePixelBuffer) async throws -> CGRect?
}