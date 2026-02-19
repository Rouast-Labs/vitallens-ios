import Foundation
import CoreGraphics
import VitalLensCore

public struct ROICalculator {
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
            containerWidth: 1.0,
            containerHeight: 1.0,
            forceEven: false
        )
        
        return CGRect(x: CGFloat(result.x), y: CGFloat(result.y), width: CGFloat(result.width), height: CGFloat(result.height))
    }
    
    public static func computeIoU(_ a: CGRect, _ b: CGRect) -> CGFloat {
        return CGFloat(VitalLensCore.computeIou(a: a.toRustRect(), b: b.toRustRect()))
    }
}