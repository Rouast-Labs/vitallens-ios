import SwiftUI
import VitalLens
import VitalLensCore
#if canImport(UIKit)

public struct VitalLensMonitorView: View {
    
    // Config
    private let apiKey: String
    private let showWaveforms: Bool
    
    // State
    @State private var client: VitalLens?
    @State private var heartRate: String = "--"
    @State private var hrvSDNN: String = "--"
    @State private var respRate: String = "--"
    @State private var status: String = "Connecting..."
    @State private var isActive: Bool = false
    
    // Waveform Buffers (Last 150 points is ~5 seconds at 30fps)
    @State private var ppgHistory: [Double] = []
    private let maxHistoryPoints = 150
    
    public init(apiKey: String, showWaveforms: Bool = true) {
        self.apiKey = apiKey
        self.showWaveforms = showWaveforms
    }
    
    public var body: some View {
        ZStack {
            Color(UIColor.systemBackground).edgesIgnoringSafeArea(.all)
            
            VStack(spacing: 24) {
                // 1. Header / Status
                HStack {
                    Text("VitalLens Monitor")
                        .font(.headline)
                    Spacer()
                    StatusBadge(status: status, isActive: isActive)
                }
                .padding(.horizontal)
                .padding(.top)
                
                // 2. Main Metric (Heart Rate)
                VStack(spacing: -5) {
                    Text(heartRate)
                        .font(.system(size: 80, weight: .bold, design: .rounded))
                        // .contentTransition(.numericText(value: Double(heartRate) ?? 0)) // iOS 16+
                        .monospacedDigit()
                    Text("BPM")
                        .font(.headline)
                        .foregroundStyle(.secondary)
                }
                
                // 3. Secondary Metrics Grid
                if #available(iOS 16.0, *) {
                    Grid(horizontalSpacing: 20) {
                        GridRow {
                            MetricTile(title: "HRV (SDNN)", value: hrvSDNN, unit: "ms")
                            MetricTile(title: "Resp Rate", value: respRate, unit: "rpm")
                        }
                    }
                    .padding(.horizontal)
                } else {
                    HStack(spacing: 20) {
                        MetricTile(title: "HRV (SDNN)", value: hrvSDNN, unit: "ms")
                        MetricTile(title: "Resp Rate", value: respRate, unit: "rpm")
                    }
                    .padding(.horizontal)
                }
                
                // 4. Real-time Graph
                if showWaveforms {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("PPG Signal")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .padding(.horizontal)
                        
                        WaveformView(samples: ppgHistory, color: .red)
                            .frame(height: 140)
                            .padding()
                            .background(Color(UIColor.secondarySystemBackground))
                            .cornerRadius(16)
                            .padding(.horizontal)
                            .animation(.easeOut(duration: 0.1), value: ppgHistory)
                    }
                }
                
                Spacer()
                
                // 5. Hidden Camera Preview (Required to keep camera active)
                CameraPreview { view in
                    startSession(in: view)
                }
                .frame(width: 1, height: 1)
                .opacity(0)
            }
        }
        .onDisappear {
            client?.stopStream()
        }
    }
    
    private func startSession(in view: UIView) {
        guard client == nil else { return }
        
        let newClient = VitalLens(apiKey: apiKey, method: .vitalLens2)
        self.client = newClient
        
        Task {
            do {
                let stream = try await newClient.startStream(preview: view)
                
                await MainActor.run { status = "Live"; isActive = true }
                
                for await result in stream {
                    await updateUI(with: result)
                }
            } catch {
                await MainActor.run { status = "Error"; isActive = false }
                print(error)
            }
        }
    }
    
    @MainActor
    private func updateUI(with result: VitalLensResult) {
        if let hr = result.vitalSigns.heartRate?.value {
            self.heartRate = String(format: "%.0f", hr)
        }
        if let sdnn = result.vitalSigns.hrvSdnn?.value {
            self.hrvSDNN = String(format: "%.0f", sdnn)
        }
        if let rr = result.vitalSigns.respiratoryRate?.value {
            self.respRate = String(format: "%.0f", rr)
        }
        
        if showWaveforms, let ppgChunk = result.vitalSigns.ppgWaveform?.data {
            self.ppgHistory.append(contentsOf: ppgChunk)
            if self.ppgHistory.count > maxHistoryPoints {
                self.ppgHistory.removeFirst(self.ppgHistory.count - maxHistoryPoints)
            }
        }
    }
}

// MARK: - Internal Subviews

struct StatusBadge: View {
    let status: String
    let isActive: Bool
    
    var body: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(isActive ? Color.green : Color.orange)
                .frame(width: 8, height: 8)
            Text(status)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(.ultraThinMaterial)
        .cornerRadius(20)
    }
}

struct MetricTile: View {
    let title: String
    let value: String
    let unit: String
    
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
            HStack(alignment: .firstTextBaseline, spacing: 2) {
                Text(value)
                    .font(.title2)
                    .bold()
                    // .contentTransition(.numericText(value: Double(value) ?? 0))
                    .monospacedDigit()
                Text(unit)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .background(Color(UIColor.secondarySystemBackground))
        .cornerRadius(12)
    }
}
#endif