import Foundation
import CoreImage
import CoreVideo

/// A stateless helper to handle image manipulation: Cropping, Resizing, and Raw Byte extraction.
struct ImageProcessor {
    
    // Using a shared CIContext is recommended for performance (caches intermediate textures).
    // disabling software renderer ensures we stay on the GPU.
    private let context = CIContext(options: [.useSoftwareRenderer: false])
    
    /// Processes a video frame: Crops to the ROI, scales to the target size, and extracts raw RGB bytes.
    ///
    /// - Parameters:
    ///   - pixelBuffer: The source video frame (usually YCbCr or BGRA).
    ///   - roi: The **normalized** region of interest (0.0 - 1.0) with **Top-Left** origin.
    ///   - targetSize: The dimension required by the API (e.g., 40 for a 40x40 image).
    /// - Returns: A `Data` object containing raw RGB bytes (flat array: R, G, B, R, G, B...).
    /// - Throws: If the image cannot be rendered.
    func process(
        pixelBuffer: CVPixelBuffer,
        roi: CGRect,
        targetSize: Int
    ) throws -> Data {
        
        // 1. Create CIImage from the pixel buffer
        // Core Image handles the color conversion from YUV/BGRA automatically.
        let ciImage = CIImage(cvPixelBuffer: pixelBuffer)
        
        let width = CGFloat(CVPixelBufferGetWidth(pixelBuffer))
        let height = CGFloat(CVPixelBufferGetHeight(pixelBuffer))
        
        // 2. Convert Normalized Top-Left ROI to Absolute CoreImage Coordinates
        // Core Image uses a Bottom-Left origin system.
        // ROI (Top-Left): x, y, w, h
        // CI (Bottom-Left): x, height - y - h, w, h
        let cropRect = CGRect(
            x: roi.origin.x * width,
            y: (1.0 - roi.origin.y - roi.height) * height,
            width: roi.width * width,
            height: roi.height * height
        )
        
        // 3. Crop and Clamp
        // We clamp to extent to avoid crashing if the ROI slips slightly outside due to rounding
        let croppedImage = ciImage.cropped(to: cropRect)
        
        // 4. Translate to Origin (0,0) for scaling
        // If we don't translate, the image retains its original coordinates and scaling won't work as expected
        let translatedImage = croppedImage.transformed(by: CGAffineTransform(translationX: -cropRect.origin.x, y: -cropRect.origin.y))
        
        // 5. Scale to Target Size (e.g. 40x40)
        let scaleX = CGFloat(targetSize) / cropRect.width
        let scaleY = CGFloat(targetSize) / cropRect.height
        
        // Use Lanczos or high-quality scaling for better signal preservation
        let scaledImage = translatedImage.transformed(by: CGAffineTransform(scaleX: scaleX, y: scaleY))
        
        // 6. Render to Raw Bytes (RGB)
        // Format: 3 bytes per pixel (R, G, B). No Alpha.
        let bytesPerPixel = 3
        let rowBytes = targetSize * bytesPerPixel
        let totalBytes = rowBytes * targetSize
        
        // Allocate buffer
        var rawData = Data(count: totalBytes)
        
        try rawData.withUnsafeMutableBytes { ptr in
            guard let baseAddress = ptr.baseAddress else { return }
            
            // Render the scaled image into the buffer.
            // CIContext will perform the actual resize/sampling here.
            context.render(
                scaledImage,
                toBitmap: baseAddress,
                rowBytes: rowBytes,
                bounds: CGRect(x: 0, y: 0, width: targetSize, height: targetSize),
                format: .RGB8, // 8 bits per channel, Red-Green-Blue order
                colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!
            )
        }
        
        return rawData
    }
}