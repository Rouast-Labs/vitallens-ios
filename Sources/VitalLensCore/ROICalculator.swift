import Foundation
import CoreGraphics

/// Helper utilities for calculating the processing Region of Interest (ROI) from face detections.
///
/// All operations within this struct are performed in **normalized coordinates (0.0 - 1.0)**,
/// making them resolution-independent.
public struct ROICalculator {
    
    /// The relative coordinate changes required to convert a Face Box into the
    /// "Upper Body Cropped" ROI expected by the VitalLens API models.
    /// Format: [Left, Top, Right, Bottom] as percentages of width/height.
    private static let upperBodyInsets: [CGFloat] = [0.19, 0.1455, 0.19, 0.2769]
    
    // MARK: - ROI Calculation
    
    /// Derives the specific ROI required for signal extraction based on a detected face.
    ///
    /// - Parameters:
    ///   - faceRect: The normalized face bounding box (Top-Left origin).
    ///   - method: The ROI extraction method name (defaults to "upper_body_cropped").
    ///   - frameSize: Ignored (kept for API compatibility). Math is performed in normalized space.
    /// - Returns: A normalized `CGRect` representing the ROI to crop.
    public static func calculateROI(
        from faceRect: CGRect,
        method: String = "upper_body_cropped",
        frameSize: CGSize = .zero
    ) -> CGRect {
        // We perform pure float math on normalized coordinates.
        // Rounding to pixel boundaries is the responsibility of the ImageProcessor.
        return applyRelativeChange(to: faceRect, change: upperBodyInsets)
    }

    /// Calculates the Intersection over Union (IoU) between two rects.
    /// Used to determine if a new detection belongs to an existing buffer.
    public static func computeIoU(_ a: CGRect, _ b: CGRect) -> CGFloat {
        let intersection = a.intersection(b)
        let iArea = intersection.width * intersection.height
        
        // If they don't intersect, area is 0
        if intersection.isNull || iArea <= 0 { return 0.0 }
        
        let aArea = a.width * a.height
        let bArea = b.width * b.height
        
        let uArea = aArea + bArea - iArea
        return uArea > 0 ? (iArea / uArea) : 0.0
    }

    // MARK: - Private Helpers
    
    /// Applies relative coordinate changes to a rect and clamps result to [0.0, 1.0].
    private static func applyRelativeChange(to rect: CGRect, change: [CGFloat]) -> CGRect {
        let w = rect.width
        let h = rect.height
        
        let chLeft = change[0] * w
        let chTop = change[1] * h
        let chRight = change[2] * w
        let chBottom = change[3] * h
        
        var newX = rect.minX - chLeft
        var newY = rect.minY - chTop
        var newMaxX = rect.maxX + chRight
        var newMaxY = rect.maxY + chBottom
        
        newX = max(0, min(newX, 1.0))
        newY = max(0, min(newY, 1.0))
        newMaxX = max(0, min(newMaxX, 1.0))
        newMaxY = max(0, min(newMaxY, 1.0))
        
        return CGRect(x: newX, y: newY, width: newMaxX - newX, height: newMaxY - newY)
    }
}