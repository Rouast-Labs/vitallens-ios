import SwiftUI
import VitalLensInference

#if canImport(UIKit)

/// A collection of statistical metrics regarding a completed vital signs scan.
public struct ScanStats {
    public let duration: Double
    public let sampleCount: Int
    public let avgFaceConf: Double
    
    /// Initializes a new `ScanStats` instance.
    ///
    /// - Parameters:
    ///   - duration: The duration of the scan in seconds.
    ///   - sampleCount: The number of frames processed.
    ///   - avgFaceConf: The average face detection confidence.
    public init(duration: Double, sampleCount: Int, avgFaceConf: Double) {
        self.duration = duration
        self.sampleCount = sampleCount
        self.avgFaceConf = avgFaceConf
    }
}

/// A UI-ready representation of an estimated vital sign, containing pre-formatted strings and visual metadata.
public struct ResolvedVital: Identifiable {
    public let id: String
    public let title: String
    public let value: Double?
    public let unit: String
    public let format: String
    public let confidence: Double?
    public let emoji: String
    
    /// Initializes a new `ResolvedVital`.
    ///
    /// - Parameters:
    ///   - id: The unique identifier.
    ///   - title: The display title.
    ///   - value: The estimated value.
    ///   - unit: The unit of measurement.
    ///   - format: The formatting string.
    ///   - confidence: The confidence score.
    ///   - emoji: The representative emoji.
    public init(id: String, title: String, value: Double?, unit: String, format: String, confidence: Double?, emoji: String) {
        self.id = id
        self.title = title
        self.value = value
        self.unit = unit
        self.format = format
        self.confidence = confidence
        self.emoji = emoji
    }
}

/// A SwiftUI view that displays the final aggregated results of a vital signs scan or file processing operation.
/// It presents primary and secondary vitals, along with optional time-series waveforms.
public struct VitalLensResultView: View {
    let title: String
    let primaryVitals: [ResolvedVital]
    let secondaryVitals: [ResolvedVital]
    let ppgWaveform: [Double]?
    let respWaveform: [Double]?
    let stats: ScanStats
    let onDone: () -> Void
    
    @State private var showDetails: Bool = false
    
    /// Initializes a new Result View.
    ///
    /// - Parameters:
    ///   - title: The title displayed at the top of the view.
    ///   - primaryVitals: An array of prominently displayed vital signs (e.g., Heart Rate, Respiration).
    ///   - secondaryVitals: An array of secondary vital signs (e.g., HRV metrics).
    ///   - ppgWaveform: An optional array of PPG waveform data points.
    ///   - respWaveform: An optional array of respiratory waveform data points.
    ///   - stats: Statistical information about the completed scan.
    ///   - onDone: A closure executed when the user dismisses the result view.
    public init(
        title: String,
        primaryVitals: [ResolvedVital],
        secondaryVitals: [ResolvedVital],
        ppgWaveform: [Double]? = nil,
        respWaveform: [Double]? = nil,
        stats: ScanStats,
        onDone: @escaping () -> Void
    ) {
        self.title = title
        self.primaryVitals = primaryVitals
        self.secondaryVitals = secondaryVitals
        self.ppgWaveform = ppgWaveform
        self.respWaveform = respWaveform
        self.stats = stats
        self.onDone = onDone
    }
    
    public var body: some View {
        ZStack {
            Color(red: 0.06, green: 0.07, blue: 0.09).edgesIgnoringSafeArea(.all)
            
            VStack(spacing: 24) {
                HStack(spacing: 12) {
                    Link(destination: URL(string: "https://www.rouast.com/api/")!) {
                        Image("vitallens_logo", bundle: .module)
                            .resizable()
                            .scaledToFit()
                            .frame(width: 32, height: 32)
                            .background(Color.white)
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                    }
                    
                    Text(title).font(.headline).foregroundColor(.white)
                    
                    Spacer()
                    
                    Button("Done", action: onDone)
                        .font(.headline)
                        .foregroundColor(VitalMetadataCache.brandBlue)
                }
                .padding(.top, 8)

                GeometryReader { geo in
                    ScrollView(showsIndicators: false) {
                        VStack(spacing: 16) {
                            Spacer(minLength: 0)
                            
                            if !primaryVitals.isEmpty {
                                HStack(spacing: 16) {
                                    ForEach(primaryVitals) { vital in
                                        ScanResultTile(vital: vital, showDetails: showDetails)
                                    }
                                }
                            }
                            
                            if !secondaryVitals.isEmpty {
                                HStack(spacing: 16) {
                                    ForEach(secondaryVitals) { vital in
                                        ScanResultTile(vital: vital, showDetails: showDetails)
                                    }
                                }
                            }
                            
                            if let ppg = ppgWaveform, !ppg.isEmpty {
                                WaveformContainer(vitalId: "ppg_waveform", history: ppg, isReady: true)
                                    .frame(height: 100)
                            }
                            
                            if let resp = respWaveform, !resp.isEmpty {
                                WaveformContainer(vitalId: "respiratory_waveform", history: resp, isReady: true)
                                    .frame(height: 100)
                            }
                            
                            if showDetails {
                                VStack(spacing: 8) {
                                    Text(String(format: "Total Usage: %.1fs (%df)", stats.duration, stats.sampleCount))
                                    Text(String(format: "Avg Face Confidence: %.0f%%", stats.avgFaceConf * 100))
                                }
                                .font(.footnote)
                                .foregroundColor(.secondary)
                                .padding(.top, 8)
                            }
                            
                            Spacer(minLength: 0)
                        }
                        .frame(minHeight: geo.size.height)
                    }
                }

                Button(action: { withAnimation { showDetails.toggle() } }) {
                    Text(showDetails ? "Hide Details" : "View Details")
                        .font(.headline)
                        .foregroundColor(.white)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 18)
                        .background(Color(white: 0.12))
                        .cornerRadius(16)
                }
                .padding(.bottom, 24)
            }
            .padding(.horizontal, 24)
        }
    }
}

/// A reusable UI component that displays a single formatted vital sign in the result view.
struct ScanResultTile: View {
    let vital: ResolvedVital
    let showDetails: Bool
    
    var body: some View {
        VStack(spacing: 8) {
            HStack(spacing: 4) {
                Text(vital.emoji)
                Text(vital.title)
            }
            .font(.system(size: 12, weight: .semibold))
            .foregroundColor(.secondary)
            
            HStack(alignment: .firstTextBaseline, spacing: 2) {
                if let val = vital.value {
                    Text(String(format: vital.format, val))
                        .font(.system(size: 30, weight: .bold, design: .rounded))
                        .foregroundColor(.white)
                } else {
                    Text("--").font(.system(size: 30, weight: .bold, design: .rounded))
                        .foregroundColor(.white.opacity(0.3))
                }
                Text(vital.unit).font(.system(size: 10)).foregroundColor(.secondary)
            }
            
            if showDetails {
                Text(vital.confidence != nil ? String(format: "Conf: %.0f%%", vital.confidence! * 100) : "Conf: --")
                    .font(.system(size: 10)).foregroundColor(.secondary.opacity(0.7))
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 20)
        .background(Color(white: 0.12))
        .cornerRadius(20)
    }
}

#endif