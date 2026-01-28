import SwiftUI
import UIKit

/// A SwiftUI wrapper that provides a UIView for the camera preview layer.
struct CameraPreview: UIViewRepresentable {
    
    /// Callback passing the UIView back to the coordinator so we can attach the layer.
    let onViewAvailable: (UIView) -> Void
    
    func makeUIView(context: Context) -> UIView {
        let view = UIView(frame: .zero)
        view.backgroundColor = .black
        // Ensure the view lays out correctly for the layer
        view.setContentHuggingPriority(.defaultLow, for: .horizontal)
        view.setContentHuggingPriority(.defaultLow, for: .vertical)
        return view
    }
    
    func updateUIView(_ uiView: UIView, context: Context) {
        // One-time initialization of the preview attachment
        DispatchQueue.main.async {
            onViewAvailable(uiView)
        }
    }
}