import SwiftUI
#if canImport(UIKit)
import UIKit

class VideoPreviewView: UIView {
    override func layoutSubviews() {
        super.layoutSubviews()
        layer.sublayers?.forEach { $0.frame = bounds }
    }
}

/// A SwiftUI wrapper that provides a UIView for the camera preview layer.
public struct CameraPreview: UIViewRepresentable {
    
    /// Callback passing the UIView back to the coordinator so we can attach the layer.
    public let onViewAvailable: (UIView) -> Void
    
    public init(onViewAvailable: @escaping (UIView) -> Void) {
        self.onViewAvailable = onViewAvailable
    }
    
    public func makeUIView(context: Context) -> UIView {
        let view = VideoPreviewView(frame: .zero)
        view.backgroundColor = .black
        view.setContentHuggingPriority(.defaultLow, for: .horizontal)
        view.setContentHuggingPriority(.defaultLow, for: .vertical)
        return view
    }
    
    public func updateUIView(_ uiView: UIView, context: Context) {
        if !context.coordinator.hasCalledOnViewAvailable {
            context.coordinator.hasCalledOnViewAvailable = true
            DispatchQueue.main.async {
                onViewAvailable(uiView)
            }
        }
    }
    
    public func makeCoordinator() -> Coordinator {
        Coordinator()
    }
    
    public class Coordinator {
        var hasCalledOnViewAvailable = false
    }
}
#endif