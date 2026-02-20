import SwiftUI
import VitalLens
import VitalLensInference
#if canImport(UIKit)

public struct VitalLensMonitorView: View {
    
    private let apiKey: String?
    private let proxyURL: URL?
    private let showWaveforms: Bool
    
    @State private var client: VitalLens?
    @State private var heartRate: String = "--"
    @State private var hrvSDNN: String = "--"
    @State private var respRate: String = "--"
    @State private var status: String = "Connecting..."
    @State private var isActive: Bool = false
    
    @State private var ppgHistory: [Double] = []
    private let maxHistoryPoints = 150
    
    /// Initializes the Monitor View.
    ///
    /// - Parameters:
    ///   - apiKey: Your VitalLens API Key (Optional if proxyURL is set).
    ///   - proxyURL: URL to your backend proxy (Optional if apiKey is set).
    ///   - showWaveforms: Whether to render the real-time PPG chart (default: true).
    public init(
        apiKey: String? = nil,
        proxyURL: URL? = nil,
        showWaveforms: Bool = true
    ) {
        self.apiKey = apiKey
        self.proxyURL = proxyURL
        self.showWaveforms = showWaveforms
    }
    
    public var body: some View {
        ZStack {
            Color(UIColor.systemBackground).edgesIgnoringSafeArea(.all)
            
            VStack(spacing: 24) {
                HStack {
                    Text("VitalLens Monitor")
                        .font(.headline)
                        .foregroundColor(Color.primary)
                    Spacer()
                    StatusBadge(status: status, isActive: isActive)
                }
                .padding(.horizontal)
                .padding(.top)
                
                VStack(spacing: -5) {
                    Text(heartRate)
                        .font(.system(size: 80, weight: .bold, design: .rounded))
                        .monospacedDigit()
                        .foregroundColor(Color.primary)
                    Text("BPM")
                        .font(.headline)
                        .foregroundStyle(.secondary)
                }
                
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
        
        if apiKey == nil && proxyURL == nil {
            self.status = "Config Error"
            return
        }
        
        let newClient = VitalLens(apiKey: apiKey, method: .vitalLens2, proxyURL: proxyURL)
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
        if let hr = result.heartRate?.value {
            self.heartRate = String(format: "%.0f", hr)
        }
        if let sdnn = result.hrvSdnn?.value {
            self.hrvSDNN = String(format: "%.0f", sdnn)
        }
        if let rr = result.respiratoryRate?.value {
            self.respRate = String(format: "%.0f", rr)
        }
        
        if showWaveforms, let ppgChunk = result.ppg?.data {
            self.ppgHistory.append(contentsOf: ppgChunk.map { Double($0) })
            if self.ppgHistory.count > maxHistoryPoints {
                self.ppgHistory.removeFirst(self.ppgHistory.count - maxHistoryPoints)
            }
        }
    }
}

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
                    .monospacedDigit()
                    .foregroundColor(Color.primary)
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
