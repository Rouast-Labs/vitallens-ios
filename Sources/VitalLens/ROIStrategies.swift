import Foundation
import CoreVideo
import ImageIO
import VitalLensCore

/// A strategy that determines which regions of the video frame should be processed.
public protocol ROIStrategy: Sendable {
    /// Determines the Regions of Interest for the current frame.
    /// This method is called on every frame and must remain fast/non-blocking.
    ///
    /// - Parameters:
    ///   - buffer: The current video frame.
    ///   - orientation: The orientation of the frame.
    /// - Returns: A list of ROIs (normalized 0.0-1.0) to process.
    func determineROIs(in buffer: SendablePixelBuffer, orientation: CGImagePropertyOrientation) async -> [CGRect]
}

// MARK: - Face Detection Strategy (Default)

/// Uses a FaceDetector to track faces and return their ROIs.
/// It throttles the expensive Vision detection calls internally and returns the last known stable ROI in between.
public actor FaceROIStrategy: ROIStrategy {
    
    private let detector: any FaceDetecting
    private let detectionInterval: TimeInterval
    private var lastDetectionTime: Date = .distantPast
    
    // We cache the last known ROIs to return instantly between detections
    private var currentROIs: [CGRect] = []
    
    // Track if a detection is currently running to avoid queue pile-up
    private var isDetecting: Bool = false
    
    public init(detector: any FaceDetecting = FaceDetector(), interval: TimeInterval = 0.5) {
        self.detector = detector
        self.detectionInterval = interval
    }
    
    public func determineROIs(in buffer: SendablePixelBuffer, orientation: CGImagePropertyOrientation) async -> [CGRect] {
        let now = Date()
        
        // Check if we should run a new detection
        if !isDetecting && now.timeIntervalSince(lastDetectionTime) >= detectionInterval {
            isDetecting = true
            
            // Start detection detached so we don't block the current frame return
            Task {
                let rois = await performDetection(in: buffer, orientation: orientation)
                self.updateROIs(rois, time: now)
            }
        }
        
        return currentROIs
    }
    
    private func performDetection(in buffer: SendablePixelBuffer, orientation: CGImagePropertyOrientation) async -> [CGRect] {
        // We currently only support single face tracking for the API
        if let rect = try? await detector.detectFace(in: buffer, orientation: orientation) {
            // Apply smoothing or ROI calculation here if needed
            // For now, we return the raw normalized face rect. 
            // The BufferManager will handle ROI expansion via ModelConfig.
            return [rect]
        }
        return []
    }
    
    private func updateROIs(_ rois: [CGRect], time: Date) {
        // Only update if we found something (or maybe we want to clear it if lost?)
        // For stability, let's keep the last known face if detection fails briefly.
        if !rois.isEmpty {
            self.currentROIs = rois
        }
        self.lastDetectionTime = time
        self.isDetecting = false
    }
}
