import Foundation
import CoreVideo
import ImageIO
import VitalLensInference
import VitalLensCore

/// A strategy that determines which regions of the video frame should be processed.
public protocol ROIStrategy: Sendable {
    /// Determines the single Region of Interest for the current frame.
    /// This method is called on every frame and must remain fast/non-blocking.
    ///
    /// - Parameters:
    ///   - buffer: The current video frame.
    ///   - orientation: The orientation of the frame.
    ///   - isMirrored: Whether the frame is horizontally mirrored.
    ///   - roiMethod: The specific ROI calculation method to apply (e.g., "face", "forehead").
    /// - Returns: A single ROI (normalized 0.0-1.0) to process, or `nil`.
    func determineROI(
        in buffer: SendablePixelBuffer,
        orientation: CGImagePropertyOrientation,
        isMirrored: Bool,
        roiMethod: String
    ) async -> CGRect?
}

/// Uses a FaceDetector to track faces and return their ROI.
/// It throttles the expensive Vision detection calls internally and returns the last known stable ROI in between.
/// A detection that finds no face keeps the last ROI until no face has been found for the hold time
/// (vitallens-core's `FaceHold`), so a single missed detection doesn't drop the ROI.
public actor FaceROIStrategy: ROIStrategy {
    
    private let detector: any FaceDetecting
    private let detectionInterval: TimeInterval
    private var lastDetectionTime: Date = .distantPast
    
    private var currentROI: CGRect? = nil
    
    private var isDetecting: Bool = false
    
    private let faceHold: FaceHold
    
    /// Initializes a new FaceROIStrategy.
    ///
    /// - Parameters:
    ///   - detector: The face detection implementation to use. Defaults to `FaceDetector()`.
    ///   - interval: The minimum time in seconds between actual face detection runs. Defaults to `0.5`.
    ///   - holdSeconds: How long to keep the last ROI while detections find no face. Defaults to vitallens-core's `FaceHold` default.
    public init(detector: any FaceDetecting = FaceDetector(), interval: TimeInterval = 0.5, holdSeconds: Double? = nil) {
        self.detector = detector
        self.detectionInterval = interval
        self.faceHold = FaceHold(holdSeconds: holdSeconds)
    }
    
    /// Determines the ROI by performing face detection, throttling actual detection calls to save resources.
    /// If called before the `detectionInterval` has elapsed, it returns the last known stable ROI.
    ///
    /// - Parameters:
    ///   - buffer: The current video frame.
    ///   - orientation: The orientation of the frame.
    ///   - isMirrored: Whether the frame is horizontally mirrored.
    ///   - roiMethod: The specific ROI calculation method to apply (e.g., "face", "forehead").
    /// - Returns: A single ROI (normalized 0.0-1.0) to process, or `nil` if no face is currently tracked.
    public func determineROI(
        in buffer: SendablePixelBuffer,
        orientation: CGImagePropertyOrientation,
        isMirrored: Bool,
        roiMethod: String
    ) async -> CGRect? {
        let now = Date()
        
        if !isDetecting && now.timeIntervalSince(lastDetectionTime) >= detectionInterval {
            isDetecting = true
            
            Task {
                let faceRect = await performDetection(in: buffer, orientation: orientation, isMirrored: isMirrored)
                
                let finalROI: CGRect?
                if let face = self.faceHold.update(face: faceRect?.toRustRect(), timestamp: now.timeIntervalSince1970) {
                    let held = CGRect(x: CGFloat(face.x), y: CGFloat(face.y), width: CGFloat(face.width), height: CGFloat(face.height))
                    finalROI = ROICalculator.calculateROI(from: held, method: roiMethod)
                } else {
                    finalROI = nil
                }
                
                self.updateROI(finalROI, time: now)
            }
        }
        
        return currentROI
    }
    
    /// Performs the actual face detection in the background.
    private func performDetection(in buffer: SendablePixelBuffer, orientation: CGImagePropertyOrientation, isMirrored: Bool) async -> CGRect? {
        if let rect = try? await detector.detectFace(in: buffer, orientation: orientation, isMirrored: isMirrored) {
            return rect
        }
        return nil
    }
    
    /// Updates the internally cached ROI and tracking state.
    private func updateROI(_ roi: CGRect?, time: Date) {
        if let roi = roi {
            self.currentROI = roi
        } else {
            self.currentROI = nil
        }
        self.lastDetectionTime = time
        self.isDetecting = false
    }
}
