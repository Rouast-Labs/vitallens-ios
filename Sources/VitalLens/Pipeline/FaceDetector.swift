import Foundation
import Vision
import CoreImage

/// An actor responsible for detecting faces in video frames using the Vision framework.
/// It handles the coordinate space conversion (Vision Bottom-Left -> Normalized Top-Left).
actor FaceDetector {
    
    // MARK: - Properties
    
    private let faceRequest: VNDetectFaceRectanglesRequest
    
    // MARK: - Initialization
    
    init() {
        self.faceRequest = VNDetectFaceRectanglesRequest()
    }
    
    // MARK: - Detection
    
    /// Detects the most prominent face in the provided pixel buffer.
    ///
    /// - Parameter pixelBuffer: The video frame to analyze.
    /// - Returns: The bounding box of the face in **normalized coordinates (0.0-1.0)** with Top-Left origin,
    ///            or `nil` if no face is found.
    func detectFace(in pixelBuffer: CVPixelBuffer) async throws -> CGRect? {
        
        let handler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer, orientation: .up, options: [:])
        
        // Perform the request
        // Note: Vision operations are synchronous on the calling thread, but since we are in an Actor,
        // this runs safely on a background cooperative thread without blocking the UI.
        try handler.perform([faceRequest])
        
        guard let observations = faceRequest.results,
              let face = observations.first else {
            return nil
        }
        
        // VitalLens JS strategy: If multiple faces, pick the largest/most central.
        // Vision sorts by confidence usually, but let's stick to the first result for now.
        // Future optimization: Implement tracking ID to stick to the *same* face.
        
        // Vision returns coordinates in a normalized space where (0,0) is BOTTOM-left.
        // We need to convert this to TOP-left origin for standard image processing.
        let visionRect = face.boundingBox
        let normalizedRect = convertVisionToTopLeft(visionRect)
        
        return normalizedRect
    }
    
    // MARK: - Helpers
    
    /// Converts Vision's coordinate system (Bottom-Left origin) to standard Top-Left origin.
    ///
    /// - Parameter rect: The normalized rect from Vision (y is distance from bottom).
    /// - Returns: The normalized rect with y as distance from top.
    private func convertVisionToTopLeft(_ rect: CGRect) -> CGRect {
        // x and width remain the same.
        // y in Vision is the bottom edge. In Top-Left, y is the top edge.
        // Vision Rect: (x, y_bottom, w, h)
        // Top-Left Rect: (x, 1.0 - y_bottom - h, w, h)
        
        let newY = 1.0 - rect.origin.y - rect.height
        return CGRect(x: rect.origin.x, y: newY, width: rect.width, height: rect.height)
    }
}