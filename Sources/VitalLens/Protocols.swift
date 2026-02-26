import Foundation
import CoreVideo
import CoreGraphics
import ImageIO
import VitalLensInference

#if canImport(UIKit)
import UIKit
#endif

/// A container for a video frame and its capture metadata.
public struct InputFrame: Sendable {
    /// The captured video frame.
    public let buffer: SendablePixelBuffer
    /// The orientation of the captured frame.
    public let orientation: CGImagePropertyOrientation
    /// Whether the frame is horizontally mirrored.
    public let isMirrored: Bool
    /// The timestamp of the capture in seconds.
    public let timestamp: TimeInterval
    
    /// Initializes a new InputFrame.
    ///
    /// - Parameters:
    ///   - buffer: The captured video frame.
    ///   - orientation: The orientation of the captured frame.
    ///   - isMirrored: Whether the frame is horizontally mirrored.
    ///   - timestamp: The timestamp of the capture in seconds.
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

/// A protocol defining the interface for face detection algorithms.
public protocol FaceDetecting: Sendable {
    /// Detects a face within the provided pixel buffer.
    ///
    /// - Parameters:
    ///   - pixelBuffer: The video frame to analyze.
    ///   - orientation: The orientation of the image.
    ///   - isMirrored: Whether the image is horizontally mirrored.
    /// - Returns: The bounding box of the detected face in normalized coordinates (0.0-1.0), or `nil` if no face is found.
    func detectFace(
        in pixelBuffer: SendablePixelBuffer, 
        orientation: CGImagePropertyOrientation,
        isMirrored: Bool,
    ) async throws -> CGRect?
}

/// A protocol defining the interface for continuous video frame generation, typically from a device camera.
public protocol CameraStreaming: Sendable {
    /// The asynchronous stream of input frames including metadata.
    var stream: AsyncStream<InputFrame> { get }
    
    /// Configures and starts the video stream.
    func start() async throws

    /// Stops the video stream.
    func stop()
    
    #if canImport(UIKit)
    /// Attaches a live preview of the video stream to the specified view.
    ///
    /// - Parameter view: The `UIView` to render the preview on.
    @MainActor func showPreview(on view: UIView)
    #endif
}

public extension CGRect {
    /// Maps a normalized rectangle to its raw, unrotated, and unmirrored coordinate space.
    ///
    /// - Parameters:
    ///   - orientation: The original orientation of the image.
    ///   - isMirrored: Whether the image was horizontally mirrored.
    /// - Returns: A new `CGRect` adjusted for the specified transforms.
    func mappedToRaw(orientation: CGImagePropertyOrientation, isMirrored: Bool) -> CGRect {
        var rect = self
        
        if isMirrored {
            rect = CGRect(x: 1.0 - rect.origin.x - rect.width, y: rect.origin.y, width: rect.width, height: rect.height)
        }
        
        switch orientation {
        case .left, .leftMirrored: 
            rect = CGRect(x: 1.0 - rect.origin.y - rect.height, y: rect.origin.x, width: rect.height, height: rect.width)
        case .down, .downMirrored: 
            rect = CGRect(x: 1.0 - rect.origin.x - rect.width, y: 1.0 - rect.origin.y - rect.height, width: rect.width, height: rect.height)
        case .right, .rightMirrored: 
            rect = CGRect(x: rect.origin.y, y: 1.0 - rect.origin.x - rect.width, width: rect.height, height: rect.width)
        default:
            break
        }
        
        return rect
    }
}