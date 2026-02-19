import XCTest
import VitalLensInference
import CoreVideo
@testable import VitalLens

#if canImport(UIKit) && !os(watchOS)
import UIKit

final class CameraSourceTests: XCTestCase {
    
    func testSimulatorStreaming() async throws {
        // This test runs on background threads to verify async streaming logic
        #if targetEnvironment(simulator)
        
        let source = CameraSource()
        
        // 1. Start
        try await source.start()
        
        // 2. Consume a few frames
        var frameCount = 0
        var receivedSize: CGSize = .zero
        
        for await frame in source.stream {
            frameCount += 1
            let buffer = frame.buffer.buffer
            
            if receivedSize == .zero {
                receivedSize = CGSize(
                    width: CVPixelBufferGetWidth(buffer),
                    height: CVPixelBufferGetHeight(buffer)
                )
            }
            
            if frameCount >= 5 { break }
        }
        
        // 3. Verify
        XCTAssertEqual(frameCount, 5, "Should have received 5 frames")
        XCTAssertEqual(receivedSize.width, 480, "Simulator default width")
        XCTAssertEqual(receivedSize.height, 640, "Simulator default height")
        
        // 4. Stop
        source.stop()
        
        // 5. Verify Stream Termination
        var extraFrames = 0
        for await _ in source.stream {
            extraFrames += 1
        }
        XCTAssertEqual(extraFrames, 0, "Stream should finish immediately after stop()")
        
        #else
        print("Skipping CameraSourceTests on physical device (requires manual verification)")
        #endif
    }
    
    // FIX: Mark as @MainActor to allow UIView initialization
    @MainActor
    func testPreviewLayerAttachment() async {
        // Basic smoke test to ensure UI code doesn't crash
        let source = CameraSource()
        let view = UIView(frame: CGRect(x: 0, y: 0, width: 100, height: 100))
        
        source.showPreview(on: view)
        
        #if targetEnvironment(simulator)
        XCTAssertEqual(view.backgroundColor, .darkGray)
        #else
        // On device, check layer insertion
        let previewLayer = view.layer.sublayers?.first as? AVCaptureVideoPreviewLayer
        XCTAssertNotNil(previewLayer)
        XCTAssertEqual(previewLayer?.frame, view.bounds)
        #endif
    }
}
#endif