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
    /// - Returns: A single ROI (normalized 0.0-1.0) to process, or nil.
    func determineROI(in buffer: SendablePixelBuffer, orientation: CGImagePropertyOrientation) async -> CGRect?
}

// MARK: - Face Detection Strategy (Default)

/// Uses a FaceDetector to track faces and return their ROI.
/// It throttles the expensive Vision detection calls internally and returns the last known stable ROI in between.
public actor FaceROIStrategy: ROIStrategy {
    
    private let detector: any FaceDetecting
    private let detectionInterval: TimeInterval
    private var lastDetectionTime: Date = .distantPast
    
    // We cache the last known ROI to return instantly between detections
    private var currentROI: CGRect? = nil
    
    // Track if a detection is currently running to avoid queue pile-up
    private var isDetecting: Bool = false
    
    public init(detector: any FaceDetecting = FaceDetector(), interval: TimeInterval = 0.5) {
        self.detector = detector
        self.detectionInterval = interval
    }
    
    public func determineROI(in buffer: SendablePixelBuffer, orientation: CGImagePropertyOrientation) async -> CGRect? {
        let now = Date()
        
        // Check if we should run a new detection
        if !isDetecting && now.timeIntervalSince(lastDetectionTime) >= detectionInterval {
            isDetecting = true
            
            // Start detection detached so we don't block the current frame return
            Task {
                let roi = await performDetection(in: buffer, orientation: orientation)
                self.updateROI(roi, time: now)
            }
        }
        
        return currentROI
    }
    
    private func performDetection(in buffer: SendablePixelBuffer, orientation: CGImagePropertyOrientation) async -> CGRect? {
        if let rect = try? await detector.detectFace(in: buffer, orientation: orientation) {
            return rect
        }
        return nil
    }
    
    private func updateROI(_ roi: CGRect?, time: Date) {
        if let roi = roi {
            self.currentROI = roi
        }
        self.lastDetectionTime = time
        self.isDetecting = false
    }
}
