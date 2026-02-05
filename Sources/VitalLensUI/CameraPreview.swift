import SwiftUI
#if canImport(UIKit)
import UIKit

/// A SwiftUI wrapper that provides a UIView for the camera preview layer.
public struct CameraPreview: UIViewRepresentable {
    
    /// Callback passing the UIView back to the coordinator so we can attach the layer.
    public let onViewAvailable: (UIView) -> Void
    
    public init(onViewAvailable: @escaping (UIView) -> Void) {
        self.onViewAvailable = onViewAvailable
    }
    
    public func makeUIView(context: Context) -> UIView {
        let view = UIView(frame: .zero)
        view.backgroundColor = .black
        // Ensure the view lays out correctly for the layer
        view.setContentHuggingPriority(.defaultLow, for: .horizontal)
        view.setContentHuggingPriority(.defaultLow, for: .vertical)
        return view
    }
    
    public func updateUIView(_ uiView: UIView, context: Context) {
        // One-time initialization of the preview attachment
        DispatchQueue.main.async {
            onViewAvailable(uiView)
        }
    }
}
#endif