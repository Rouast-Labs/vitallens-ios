import Foundation
import Vision
import CoreImage
import VitalLensCore
import ImageIO
import CoreML

/// An actor responsible for detecting faces in video frames using the Vision framework.
/// It handles the coordinate space conversion (Vision Bottom-Left -> Normalized Top-Left).
actor FaceDetector: FaceDetecting {
    
    // MARK: - Properties
    
    private let faceRequest: VNDetectFaceRectanglesRequest
    
    // MARK: - Initialization
    
    init() {
        let request = VNDetectFaceRectanglesRequest()
        request.revision = VNDetectFaceRectanglesRequestRevision3

        #if targetEnvironment(simulator)
        if #available(iOS 17.0, *) {
            let allDevices = MLComputeDevice.allComputeDevices
            for device in allDevices {
                if device.description.contains("MLCPUComputeDevice") {
                    request.setComputeDevice(.some(device), for: .main)
                    break
                }
            }
        } else {
            // Fallback for older iOS versions
            request.usesCPUOnly = true
        }
        #endif

        self.faceRequest = request
    }    
    
    // MARK: - Detection
    
    /// Detects the most prominent face in the provided pixel buffer.
    ///
    /// - Parameter pixelBuffer: The video frame to analyze.
    /// - Returns: The bounding box of the face in **normalized coordinates (0.0-1.0)** with Top-Left origin,
    ///            or `nil` if no face is found.
    func detectFace(
        in pixelBuffer: SendablePixelBuffer, 
        orientation: CGImagePropertyOrientation = .up
    ) async throws -> CGRect? {
        let buffer = pixelBuffer.buffer
        
        let handler = VNImageRequestHandler(cvPixelBuffer: buffer, orientation: orientation, options: [:])
        
        try handler.perform([faceRequest])
        
        guard let observations = faceRequest.results,
              let face = observations.first else {
            return nil
        }
        
        let visionRect = face.boundingBox
        return convertVisionToTopLeft(visionRect)
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