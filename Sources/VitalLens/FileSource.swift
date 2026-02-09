import AVFoundation
import CoreVideo
import VitalLensCore

/// A helper class to read video frames from a local file URL using AVAssetReader.
final class FileSource: @unchecked Sendable {
    let asset: AVAsset
    let track: AVAssetTrack
    let naturalSize: CGSize
    let nominalFrameRate: Float
    
    private init(asset: AVAsset, track: AVAssetTrack) async throws {
        self.asset = asset
        self.track = track
        self.naturalSize = try await track.load(.naturalSize)
        self.nominalFrameRate = try await track.load(.nominalFrameRate)
    }
    
    static func from(url: URL) async throws -> FileSource {
        let asset = AVAsset(url: url)
        
        guard let track = try await asset.loadTracks(withMediaType: .video).first else {
            throw VitalLensError.processingError("No video track found in file.")
        }
        
        return try await FileSource(asset: asset, track: track)
    }
    
    /// Returns an AsyncStream of pixel buffers.
    func frames() -> AsyncStream<SendablePixelBuffer> {
        AsyncStream { continuation in
            // CRITICAL: Task.detached allows the blocking AVAssetReader calls 
            // to run off the Main Actor, preventing deadlocks during tests/UI updates.
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