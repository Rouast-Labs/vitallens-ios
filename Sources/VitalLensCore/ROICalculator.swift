import Foundation
import CoreGraphics

/// Helper utilities for calculating Region of Interest (ROI) from face detections.
/// Operates exclusively in normalized coordinates (0.0 - 1.0).
public struct ROICalculator {
    
    /// The relative coordinate changes required to convert a Face Box into the
    /// "Upper Body Cropped" ROI expected by the VitalLens API models.
    /// Format: [Left, Top, Right, Bottom] as percentages of width/height.
    private static let upperBodyInsets: [CGFloat] = [0.19, 0.1455, 0.19, 0.2769]
    
    /// Derives the processing ROI for the VitalLens API.
    ///
    /// - Parameters:
    ///   - faceRect: The normalized face bounding box (Top-Left origin).
    ///   - method: (Ignored) Defaults to API standard.
    ///   - frameSize: (Ignored) Kept for API compatibility, but unused as math is resolution-independent.
    /// - Returns: A normalized ROI rect suitable for processing.
    public static func calculateROI(
        from faceRect: CGRect,
        method: String = "upper_body_cropped",
        frameSize: CGSize = .zero 
    ) -> CGRect {
        // We perform pure float math on normalized coordinates.
        // We do NOT round to pixels here; that is the responsibility of the ImageProcessor.
        return applyRelativeChange(to: faceRect, change: upperBodyInsets)
    }
    
    // MARK: - ROI Math
    
    /// Checks if a face is sufficiently contained within an existing ROI.
    public static func isFace(
        _ face: CGRect,
        sufficientlyInsideROI roi: CGRect,
        thresholds: (width: CGFloat, height: CGFloat) = (0.5, 0.5)
    ) -> Bool {
        let faceRight = face.maxX
        let faceBottom = face.maxY
        let roiRight = roi.maxX
        let roiBottom = roi.maxY
        
        let requiredWidth = thresholds.width * face.width
        let requiredHeight = thresholds.height * face.height
        
        // Check overlap constraints
        let isWidthInside = (faceRight - roi.minX >= requiredWidth) && (roiRight - face.minX >= requiredWidth)
        let isHeightInside = (faceBottom - roi.minY >= requiredHeight) && (roiBottom - face.minY >= requiredHeight)
        
        return isWidthInside && isHeightInside
    }
    
    /// Applies relative coordinate changes to a rect and clamps to 0.0-1.0.
    private static func applyRelativeChange(
        to rect: CGRect,
        change: [CGFloat]
    ) -> CGRect {
        let w = rect.width
        let h = rect.height
        
        // Calculate shifts in normalized space
        let chLeft = change[0] * w
        let chTop = change[1] * h
        let chRight = change[2] * w
        let chBottom = change[3] * h
        
        var newX = rect.minX - chLeft
        var newY = rect.minY - chTop
        var newMaxX = rect.maxX + chRight
        var newMaxY = rect.maxY + chBottom
        
        // Clamp to 0.0 - 1.0 to ensure ROI stays within frame
        newX = max(0, min(newX, 1.0))
        newY = max(0, min(newY, 1.0))
        newMaxX = max(0, min(newMaxX, 1.0))
        newMaxY = max(0, min(newMaxY, 1.0))
        
        return CGRect(x: newX, y: newY, width: newMaxX - newX, height: newMaxY - newY)
    }
}