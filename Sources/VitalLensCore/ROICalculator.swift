import Foundation
import CoreGraphics

/// Helper utilities for calculating Region of Interest (ROI) from face detections.
public struct ROICalculator {
    
    enum ROIMethod: String {
        case face
        case forehead
        case upperBodyCropped = "upper_body_cropped"
    }
    
    /// Derives the processing ROI based on the method specified by the model config.
    ///
    /// - Parameters:
    ///   - faceRect: The normalized face bounding box (Top-Left origin).
    ///   - method: The ROI method to use (e.g. "face", "upper_body_cropped").
    ///   - frameSize: The dimension of the video frame (width, height).
    /// - Returns: A normalized ROI rect suitable for processing.
    public static func calculateROI(
        from faceRect: CGRect,
        method: String,
        frameSize: CGSize
    ) -> CGRect {
        
        // Default to 'face' if unknown
        let roiMethod = ROIMethod(rawValue: method) ?? .face
        
        switch roiMethod {
        case .face:
            return getFaceROI(from: faceRect, frameSize: frameSize)
        case .forehead:
            return getForeheadROI(from: faceRect, frameSize: frameSize)
        case .upperBodyCropped:
            return getUpperBodyROI(from: faceRect, frameSize: frameSize, cropped: true)
        }
    }
    
    // MARK: - Specific Strategies
    
    /// Standard Face ROI (reduces width to 60% and height to 80% of detection).
    /// Matches `getFaceROI` in faceOps.ts.
    private static func getFaceROI(from face: CGRect, frameSize: CGSize) -> CGRect {
        // Relative changes: [-0.2, -0.1, -0.2, -0.1]
        // This effectively shrinks the box.
        return applyRelativeChange(to: face, change: [-0.2, -0.1, -0.2, -0.1], frameSize: frameSize)
    }
    
    /// Forehead ROI.
    /// Matches `getForeheadROI` in faceOps.ts.
    private static func getForeheadROI(from face: CGRect, frameSize: CGSize) -> CGRect {
        // Relative changes: [-0.35, -0.15, -0.35, -0.75]
        return applyRelativeChange(to: face, change: [-0.35, -0.15, -0.35, -0.75], frameSize: frameSize)
    }
    
    /// Upper Body ROI.
    /// Matches `getUpperBodyROI` in faceOps.ts.
    private static func getUpperBodyROI(from face: CGRect, frameSize: CGSize, cropped: Bool) -> CGRect {
        // Relative changes for cropped: [0.19, 0.1455, 0.19, 0.2769]
        // This expands the box to include shoulders/upper chest.
        let change: [CGFloat] = cropped ? [0.19, 0.1455, 0.19, 0.2769] : [0.25, 0.2, 0.25, 0.4]
        return applyRelativeChange(to: face, change: change, frameSize: frameSize)
    }
    
    // MARK: - ROI Math
    
    /// Checks if a face is sufficiently contained within an existing ROI.
    /// Used to decide if we need to switch ROIs (and thus buffers).
    /// Matches `checkFaceInROI`.
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
    /// Change format: [left, top, right, bottom] as percentages of width/height.
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