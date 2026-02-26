import Foundation
import CoreVideo
import ImageIO
import VitalLensInference

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
public actor FaceROIStrategy: ROIStrategy {
    
    private let detector: any FaceDetecting
    private let detectionInterval: TimeInterval
    private var lastDetectionTime: Date = .distantPast
    
    private var currentROI: CGRect? = nil
    
    private var isDetecting: Bool = false
    
    /// Initializes a new FaceROIStrategy.
    ///
    /// - Parameters:
    ///   - detector: The face detection implementation to use. Defaults to `FaceDetector()`.
    ///   - interval: The minimum time in seconds between actual face detection runs. Defaults to `0.5`.
    public init(detector: any FaceDetecting = FaceDetector(), interval: TimeInterval = 0.5) {
        self.detector = detector
        self.detectionInterval = interval
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
                if let face = faceRect {
                    finalROI = ROICalculator.calculateROI(from: face, method: roiMethod)
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
