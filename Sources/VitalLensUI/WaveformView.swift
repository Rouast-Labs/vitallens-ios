import SwiftUI
import Charts
#if canImport(UIKit)

/// A lightweight, high-performance waveform chart for PPG data.
public struct WaveformView: View {
    
    /// The normalized data points to render.
    public let samples: [Double]
    
    /// The line color.
    public var color: Color = .red
    
    /// Line thickness.
    public var lineWidth: CGFloat = 2.0
    
    public init(samples: [Double], color: Color = .red, lineWidth: CGFloat = 2.0) {
        self.samples = samples
        self.color = color
        self.lineWidth = lineWidth
    }
    
    public var body: some View {
        if #available(iOS 16.0, *) {
            Chart {
                // Enumerating gives us stable X-axis indices (0, 1, 2...)
                ForEach(Array(samples.enumerated()), id: \.offset) { index, value in
                    LineMark(
                        x: .value("Time", index),
                        y: .value("Amplitude", value)
                    )
                    .foregroundStyle(color)
                    // Curve smoothing: Makes the PPG signal look organic
                    .interpolationMethod(.catmullRom)
                    .lineStyle(StrokeStyle(lineWidth: lineWidth))
                }
            }
            // Hide axes for a clean "medical monitor" look
            .chartXAxis(.hidden)
            .chartYAxis(.hidden)
            // Optimize for performance (disable interaction/accessibility grouping for rapid updates)
            .chartYScale(domain: .automatic(includesZero: false))
        } else {
            // Fallback for iOS 15
            Text("Charts require iOS 16+")
                .font(.caption)
                .foregroundColor(.gray)
        }
    }
}
#endif