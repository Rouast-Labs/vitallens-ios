import Foundation
import CoreVideo

/// A thread-safe wrapper for CVPixelBuffer to satisfy Swift 6 strict concurrency.
/// We treat the underlying buffer as read-only during transfer.
public struct SendablePixelBuffer: @unchecked Sendable {
    public let buffer: CVPixelBuffer
    
    public init(_ buffer: CVPixelBuffer) {
        self.buffer = buffer
    }
}

/// Abstraction for face detection to allow mocking in tests.
public protocol FaceDetecting: Sendable {
    /// Detects face in a thread-safe pixel buffer wrapper.
    func detectFace(in pixelBuffer: SendablePixelBuffer) async throws -> CGRect?
}
