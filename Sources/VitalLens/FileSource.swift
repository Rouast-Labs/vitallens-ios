import AVFoundation
import CoreVideo
import VitalLensInference
import ImageIO

#if canImport(UIKit)
import UIKit
#endif

/// A helper class to read video frames from a local file URL using AVAssetReader.
final class FileSource: @unchecked Sendable {
    let asset: AVAsset
    let track: AVAssetTrack
    let naturalSize: CGSize
    let nominalFrameRate: Float
    let orientation: CGImagePropertyOrientation
    
    /// Initializes a new FileSource with the loaded asset and track properties.
    ///
    /// - Parameters:
    ///   - asset: The loaded video asset.
    ///   - track: The primary video track.
    ///   - orientation: The pre-calculated orientation of the video.
    private init(asset: AVAsset, track: AVAssetTrack, orientation: CGImagePropertyOrientation) async throws {
        self.asset = asset
        self.track = track
        self.orientation = orientation
        self.naturalSize = try await track.load(.naturalSize)
        self.nominalFrameRate = try await track.load(.nominalFrameRate)
    }
    
    /// Creates a `FileSource` instance asynchronously from a local file URL.
    ///
    /// - Parameter url: The local file URL of the video.
    /// - Returns: An initialized `FileSource` ready to stream frames.
    /// - Throws: `VitalLensError` if the file cannot be read or contains no video track.
    static func from(url: URL) async throws -> FileSource {
        let asset = AVAsset(url: url)
        guard let track = try await asset.loadTracks(withMediaType: .video).first else {
            throw VitalLensError.processingError("No video track found in file.")
        }
        
        let transform = try await track.load(.preferredTransform)
        let orientation = FileSource.calculateOrientation(from: transform)
        
        return try await FileSource(asset: asset, track: track, orientation: orientation)
    }
    
    /// Creates an asynchronous stream of pixel buffers by reading the video file sequentially.
    ///
    /// - Returns: An `AsyncStream` yielding `SendablePixelBuffer` frames.
    func frames() -> AsyncStream<SendablePixelBuffer> {
        AsyncStream { continuation in
            Task.detached(priority: .userInitiated) {
                do {
                    let reader = try AVAssetReader(asset: self.asset)
                    
                    let settings: [String: Any] = [
                        kCVPixelBufferPixelFormatTypeKey as String: Int(kCVPixelFormatType_32BGRA),
                        kCVPixelBufferIOSurfacePropertiesKey as String: [:]
                    ]
                    
                    let output = AVAssetReaderTrackOutput(track: self.track, outputSettings: settings)
                    output.alwaysCopiesSampleData = false
                    
                    if reader.canAdd(output) {
                        reader.add(output)
                    } else {
                        print("[FileSource] Error: Cannot add reader output.")
                        continuation.finish()
                        return
                    }
                    
                    if !reader.startReading() {
                        print("[FileSource] Error: Failed to start reading: \(String(describing: reader.error))")
                        continuation.finish()
                        return
                    }
                    
                    while reader.status == .reading {
                        if let sampleBuffer = output.copyNextSampleBuffer(),
                           let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) {
                            
                            let result = continuation.yield(SendablePixelBuffer(pixelBuffer))
                            if case .terminated = result {
                                reader.cancelReading()
                                return
                            }
                        } else {
                            break
                        }
                    }
                    
                    if reader.status == .failed {
                        print("[FileSource] Reader failed: \(String(describing: reader.error))")
                    }
                    
                    continuation.finish()
                    
                } catch {
                    print("[FileSource] Error initializing reader: \(error)")
                    continuation.finish()
                }
            }
        }
    }
}

extension FileSource {
    /// Calculates the image orientation based on the video track's affine transform matrix.
    ///
    /// - Parameter transform: The affine transform of the video track.
    /// - Returns: The corresponding `CGImagePropertyOrientation`.
    static func calculateOrientation(from transform: CGAffineTransform) -> CGImagePropertyOrientation {
        if transform.a == 0 && transform.b == 1.0 && transform.c == -1.0 && transform.d == 0 {
            return .left
        } else if transform.a == 0 && transform.b == -1.0 && transform.c == 1.0 && transform.d == 0 {
            return .right
        } else if transform.a == -1.0 && transform.b == 0 && transform.c == 0 && transform.d == -1.0 {
            return .down
        } else {
            return .up
        }
    }
}
