import SwiftUI
import Charts

#if canImport(UIKit)

/// A UI container that provides a standard background, title, and loading state for a `WaveformView`.
public struct WaveformContainer: View {
    public let history: [Double]
    public let isReady: Bool
    
    public let title: String
    public let chartColor: Color
    
    /// Initializes a new WaveformContainer.
    ///
    /// - Parameters:
    ///   - vitalId: The identifier used to fetch metadata (like title and color).
    ///   - history: The array of data points to plot.
    ///   - isReady: Whether the data is ready to be displayed. If false, shows a loading indicator.
    public init(vitalId: String, history: [Double], isReady: Bool) {
        self.history = history
        self.isReady = isReady
        
        let meta = VitalInfoCache.getInfo(for: vitalId)
        self.title = meta?.displayName ?? vitalId
        self.chartColor = meta.flatMap { Color(hex: $0.color) } ?? .red
    }
    
    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(title)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 10)
                .padding(.top, 6)
            
            ZStack {
                if isReady && !history.isEmpty {
                    WaveformView(samples: history, color: chartColor)
                        .padding(.horizontal, 6)
                        .padding(.bottom, 6)
                } else {
                    ProgressView()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(Color(UIColor.secondarySystemBackground))
        .cornerRadius(12)
    }
}

/// A lightweight, high-performance waveform chart for rendering time-series physiological data.
/// It utilizes Swift Charts (available on iOS 16+) to draw smooth, interpolated lines.
public struct WaveformView: View {
    
    /// The sequential data points representing the waveform amplitudes over time.
    public let samples: [Double]
    
    /// The color used to stroke the waveform line.
    public var color: Color = .red
    
    /// The thickness of the rendered waveform line.
    public var lineWidth: CGFloat = 2.0
    
    /// Initializes a new waveform view.
    ///
    /// - Parameters:
    ///   - samples: The array of data points to plot.
    ///   - color: The color of the waveform line. Defaults to `.red`.
    ///   - lineWidth: The stroke width of the line. Defaults to `2.0`.
    public init(samples: [Double], color: Color = .red, lineWidth: CGFloat = 2.0) {
        self.samples = samples
        self.color = color
        self.lineWidth = lineWidth
    }
    
    public var body: some View {
        if #available(iOS 16.0, *) {
            Chart {
                ForEach(Array(samples.enumerated()), id: \.offset) { index, value in
                    LineMark(
                        x: .value("Time", index),
                        y: .value("Amplitude", value)
                    )
                    .foregroundStyle(color)
                    .interpolationMethod(.catmullRom)
                    .lineStyle(StrokeStyle(lineWidth: lineWidth))
                }
            }
            .chartXAxis(.hidden)
            .chartYAxis(.hidden)
            .chartYScale(domain: .automatic(includesZero: false))
        } else {
            Text("Charts require iOS 16+")
                .font(.caption)
                .foregroundColor(.gray)
        }
    }
}

#endif