import Foundation
import CoreGraphics
import VitalLensCore

/// A utility for calculating specific Regions of Interest (ROIs) from face bounding boxes
/// and computing intersection metrics.
public struct ROICalculator {
    
    /// Calculates a specific region of interest based on a detected face bounding box.
    ///
    /// - Parameters:
    ///   - faceRect: The normalized bounding box of the detected face (values from 0.0 to 1.0).
    ///   - method: A string identifier dictating how the ROI should be extracted (e.g., "face", "forehead", "upper_body").
    /// - Returns: A normalized `CGRect` representing the computed region of interest.
    public static func calculateROI(from faceRect: CGRect, method: String) -> CGRect {
        let rustMethod: VitalLensCore.RoiMethod
        switch method {
        case "face": rustMethod = .face
        case "forehead": rustMethod = .forehead
        case "upper_body": rustMethod = .upperBody
        case "upper_body_cropped": rustMethod = .upperBodyCropped
        default: rustMethod = .upperBodyCropped
        }
        
        let result = VitalLensCore.calculateRoi(
            face: faceRect.toRustRect(),
            method: rustMethod,
            detector: .appleVision,
            containerWidth: 1.0,
            containerHeight: 1.0,
            forceEven: false
        )
        
        return CGRect(x: CGFloat(result.x), y: CGFloat(result.y), width: CGFloat(result.width), height: CGFloat(result.height))
    }
    
    /// Computes the Intersection over Union (IoU) between two rectangles.
    ///
    /// - Parameters:
    ///   - a: The first rectangle.
    ///   - b: The second rectangle.
    /// - Returns: The IoU ratio as a `CGFloat` between 0.0 (no overlap) and 1.0 (perfect overlap).
    public static func computeIoU(_ a: CGRect, _ b: CGRect) -> CGFloat {
        return CGFloat(VitalLensCore.computeIou(a: a.toRustRect(), b: b.toRustRect()))
    }
}