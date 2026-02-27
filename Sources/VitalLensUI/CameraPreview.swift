import SwiftUI
#if canImport(UIKit)
import UIKit

/// A custom `UIView` designed specifically to host an `AVCaptureVideoPreviewLayer`.
class VideoPreviewView: UIView {
    override func layoutSubviews() {
        super.layoutSubviews()
        layer.sublayers?.forEach { $0.frame = bounds }
    }
}

/// A SwiftUI wrapper that provides a `UIView` for the camera preview layer.
public struct CameraPreview: UIViewRepresentable {
    
    /// A callback triggered once the underlying `UIView` is instantiated and available.
    public let onViewAvailable: (UIView) -> Void
    
    /// Initializes a new `CameraPreview`.
    ///
    /// - Parameter onViewAvailable: A closure that receives the generated `UIView` once it is ready.
    public init(onViewAvailable: @escaping (UIView) -> Void) {
        self.onViewAvailable = onViewAvailable
    }
    
    /// Creates the custom `VideoPreviewView` instance to be managed by SwiftUI.
    ///
    /// - Parameter context: The context containing information about the current state of the system.
    /// - Returns: A `UIView` configured with low hugging priority to expand and fill available space.
    public func makeUIView(context: Context) -> UIView {
        let view = VideoPreviewView(frame: .zero)
        view.backgroundColor = .black
        view.setContentHuggingPriority(.defaultLow, for: .horizontal)
        view.setContentHuggingPriority(.defaultLow, for: .vertical)
        return view
    }
    
    /// Updates the view and triggers the availability callback exactly once.
    ///
    /// - Parameters:
    ///   - uiView: The `UIView` representing the camera preview.
    ///   - context: The context containing information about the current state of the system.
    public func updateUIView(_ uiView: UIView, context: Context) {
        if !context.coordinator.hasCalledOnViewAvailable {
            context.coordinator.hasCalledOnViewAvailable = true
            DispatchQueue.main.async {
                onViewAvailable(uiView)
            }
        }
    }
    
    /// Creates the coordinator to manage the state of the view availability callback.
    ///
    /// - Returns: A new `Coordinator` instance.
    public func makeCoordinator() -> Coordinator {
        Coordinator()
    }
    
    /// A coordinator class used to track whether the `onViewAvailable` callback has been executed.
    public class Coordinator {
        var hasCalledOnViewAvailable = false
    }
}
#endif