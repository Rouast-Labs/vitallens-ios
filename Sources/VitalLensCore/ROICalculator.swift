import Foundation
import CoreGraphics

/// Helper utilities for calculating Region of Interest (ROI) from face detections.
public struct ROICalculator {
    
    /// The relative coordinate changes required to convert a Face Box into the
    /// "Upper Body Cropped" ROI expected by the VitalLens API models.
    /// Format: [Left, Top, Right, Bottom] as percentages of width/height.
    private static let upperBodyInsets: [CGFloat] = [0.19, 0.1455, 0.19, 0.2769]
    
    /// Derives the processing ROI for the VitalLens API.
    ///
    /// - Parameters:
    ///   - faceRect: The normalized face bounding box (Top-Left origin).
    ///   - method: The ROI method string from config (Ignored in iOS as we only support API models).
    ///   - frameSize: The dimension of the video frame (width, height).
    /// - Returns: A normalized ROI rect suitable for processing.
    public static func calculateROI(
        from faceRect: CGRect,
        method: String,
        frameSize: CGSize
    ) -> CGRect {
        // We ignore 'method' here because the iOS client exclusively uses VitalLens API models,
        // which rely on the "upper_body_cropped" strategy defined by `upperBodyInsets`.
        return applyRelativeChange(to: faceRect, change: upperBodyInsets, frameSize: frameSize)
    }
    
    // MARK: - ROI Math
    
    /// Checks if a face is sufficiently contained within an existing ROI.
    /// Used to decide if we need to switch ROIs (and thus buffers).
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
        change: [CGFloat],
        frameSize: CGSize
    ) -> CGRect {
        let w = rect.width
        let h = rect.height
        
        // Calculate absolute pixel shifts (rounded)
        // We use frameSize to ensure we are thinking in pixels before normalizing back,
        // matching the JS integer rounding logic which is important for consistency.
        let pixelW = w * frameSize.width
        let pixelH = h * frameSize.height
        
        let absChLeft = round(change[0] * pixelW) / frameSize.width
        let absChTop = round(change[1] * pixelH) / frameSize.height
        let absChRight = round(change[2] * pixelW) / frameSize.width
        let absChBottom = round(change[3] * pixelH) / frameSize.height
        
        var newX = rect.minX - absChLeft
        var newY = rect.minY - absChTop
        var newMaxX = rect.maxX + absChRight
        var newMaxY = rect.maxY + absChBottom
        
        // Clamp to 0.0 - 1.0
        newX = max(0, min(newX, 1.0))
        newY = max(0, min(newY, 1.0))
        newMaxX = max(0, min(newMaxX, 1.0))
        newMaxY = max(0, min(newMaxY, 1.0))
        
        return CGRect(x: newX, y: newY, width: newMaxX - newX, height: newMaxY - newY)
    }
}