import Foundation
import Vision
import CoreImage
import VitalLensInference
import ImageIO
import CoreML

/// An actor responsible for detecting faces in video frames using the Vision framework.
/// It handles the coordinate space conversion (Vision Bottom-Left -> Normalized Top-Left).
public actor FaceDetector: FaceDetecting {
        
    private let faceRequest: VNDetectFaceRectanglesRequest
    
    /// Initializes a new FaceDetector.
    /// Configures the Vision request and optimizes execution for the simulator if applicable.
    public init() {
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
            request.usesCPUOnly = true
        }
        #endif

        self.faceRequest = request
    }    
    
    /// Detects the most prominent face in the provided pixel buffer.
    ///
    /// - Parameters:
    ///   - pixelBuffer: The video frame to analyze.
    ///   - orientation: The orientation of the image. Default is `.up`.
    ///   - isMirrored: Whether the image is horizontally mirrored. Default is `false`.
    /// - Returns: The bounding box of the face in **normalized coordinates (0.0-1.0)** with Top-Left origin,
    ///            or `nil` if no face is found.
    /// - Throws: An error if the underlying Vision request fails.
    public func detectFace(
        in pixelBuffer: SendablePixelBuffer, 
        orientation: CGImagePropertyOrientation = .up,
        isMirrored: Bool = false
    ) async throws -> CGRect? {
        let buffer = pixelBuffer.buffer
        
        let handler = VNImageRequestHandler(cvPixelBuffer: buffer, orientation: orientation, options: [:])
        
        try handler.perform([faceRequest])
        
        guard let observations = faceRequest.results,
              let face = observations.first else {
            return nil
        }
        
        let visionRect = face.boundingBox
        return convertVisionToTopLeft(visionRect, isMirrored: isMirrored)
    }
    
    /// Converts Vision's coordinate system (Bottom-Left origin) to standard Top-Left origin.
    ///
    /// - Parameters:
    ///   - rect: The normalized rect from Vision (y is distance from bottom).
    ///   - isMirrored: Whether to flip the x-axis to account for mirroring.
    /// - Returns: The normalized rect with y as distance from top.
    private func convertVisionToTopLeft(_ rect: CGRect, isMirrored: Bool) -> CGRect {
        let newY = 1.0 - rect.origin.y - rect.height
        let newX = isMirrored ? 1.0 - rect.origin.x - rect.width : rect.origin.x
        return CGRect(x: newX, y: newY, width: rect.width, height: rect.height)
    }
}
