import SwiftUI
import VitalLens
import VitalLensInference
#if canImport(UIKit)

public enum VitalLensMode {
    case standard
    case eco
    
    var fps: Double {
        switch self {
        case .standard: return 30.0
        case .eco: return 15.0
        }
    }
}

public struct VitalLensMonitorView: View {
    
    private let apiKey: String?
    private let proxyURL: URL?
    private let method: String
    private let showWaveforms: Bool
    private let mode: VitalLensMode
    private let bufferOffset: TimeInterval
    
    @State private var client: VitalLens?
    @State private var heartRate: String = "--"
    @State private var hrvSDNN: String = "--"
    @State private var respRate: String = "--"
    @State private var status: String = "Connecting..."
    @State private var isActive: Bool = false
    @State private var isFaceDetected: Bool = false
    
    // Waveform state
    @State private var ppgHistory: [Double] = []
    private let maxHistoryPoints = 150
    
    // Smooth Playback Buffer state
    struct BufferedPoint {
        let value: Double
        let displayTime: TimeInterval
    }
    @State private var ppgQueue: [BufferedPoint] = []
    @State private var timeAnchor: (videoTime: TimeInterval, realTime: TimeInterval)? = nil
    @State private var playbackTask: Task<Void, Never>? = nil
    
    /// Initializes the Monitor View.
    ///
    /// - Parameters:
    ///   - apiKey: Your VitalLens API Key (Optional if proxyURL is set).
    ///   - proxyURL: URL to your backend proxy (Optional if apiKey is set).
    ///   - method: The model version to use (default: "vitallens").
    ///   - showWaveforms: Whether to render the real-time PPG chart.
    ///   - mode: The performance mode (standard 30fps vs eco 15fps).
    ///   - bufferOffset: Delay in seconds to smooth out waveform playback.
    public init(
        apiKey: String? = nil,
        proxyURL: URL? = nil,
        method: String = "vitallens",
        showWaveforms: Bool = true,
        mode: VitalLensMode = .standard,
        bufferOffset: TimeInterval = 1.0
    ) {
        self.apiKey = apiKey
        self.proxyURL = proxyURL
        self.method = method
        self.showWaveforms = showWaveforms
        self.mode = mode
        self.bufferOffset = bufferOffset
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
                            // Disable standard animation if we are buffering, to let the loop handle the smoothness
                            .animation(bufferOffset > 0 ? nil : .easeOut(duration: 0.1), value: ppgHistory)
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
            playbackTask?.cancel()
        }
    }
    
    private func startSession(in view: UIView) {
        guard client == nil else { return }
        
        if apiKey == nil && proxyURL == nil {
            self.status = "Config Error"
            return
        }
        
        let newClient = VitalLens(
            apiKey: apiKey,
            method: method, // Use provided method
            proxyURL: proxyURL,
            overrideFps: mode.fps // Apply eco-mode FPS
        )
        
        // Hook into the instantaneous SDK callback
        newClient.onFaceStateChanged = { @Sendable isPresent in
            Task { @MainActor in
                self.isFaceDetected = isPresent
                self.status = isPresent ? "Live" : "No Face Detected"
                
                if !isPresent {
                    self.heartRate = "--"
                    self.hrvSDNN = "--"
                    self.respRate = "--"
                    self.ppgHistory.removeAll()
                    self.ppgQueue.removeAll()
                    self.timeAnchor = nil
                }
            }
        }
        
        self.client = newClient
        
        // Start the smooth playback loop if buffering is enabled
        if bufferOffset > 0 {
            playbackTask = Task { await runPlaybackLoop() }
        }
        
        Task {
            do {
                let stream = try await newClient.startStream(preview: view)
                
                await MainActor.run { status = "Connecting..."; isActive = true }
                
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
        guard isFaceDetected else { return }
        
        // 1. Update Scalar Vitals Immediately
        if let hr = result.heartRate, hr.confidence > 0.5 {
            self.heartRate = String(format: "%.0f", hr.value)
        }
        if let sdnn = result.hrvSdnn, sdnn.confidence > 0.5 {
            self.hrvSDNN = String(format: "%.0f", sdnn.value)
        }
        if let rr = result.respiratoryRate, rr.confidence > 0.5 {
            self.respRate = String(format: "%.0f", rr.value)
        }
        
        // 2. Handle Waveform Buffering
        if showWaveforms, let ppgChunk = result.ppg?.data, !ppgChunk.isEmpty {
            if bufferOffset > 0 {
                // Initialize relative time anchor on first chunk
                if timeAnchor == nil, let firstVideoTime = result.time.first {
                    timeAnchor = (videoTime: firstVideoTime, realTime: CACurrentMediaTime())
                }
                
                if let anchor = timeAnchor {
                    for (index, val) in ppgChunk.enumerated() {
                        let frameTime = result.time[index]
                        // Map the video timestamp to a future real-world display time
                        let targetDisplayTime = anchor.realTime + (frameTime - anchor.videoTime) + bufferOffset
                        ppgQueue.append(BufferedPoint(value: Double(val), displayTime: targetDisplayTime))
                    }
                }
            } else {
                // Immediate append (No buffering)
                self.ppgHistory.append(contentsOf: ppgChunk.map { Double($0) })
                if self.ppgHistory.count > maxHistoryPoints {
                    self.ppgHistory.removeFirst(self.ppgHistory.count - maxHistoryPoints)
                }
            }
        }
    }
    
    /// Drip-feeds queued data points into the chart at ~60fps
    @MainActor
    private func runPlaybackLoop() async {
        while !Task.isCancelled {
            let now = CACurrentMediaTime()
            var pointsToAdd: [Double] = []
            
            // Pop all points that are "due" to be displayed
            while let first = ppgQueue.first, now >= first.displayTime {
                pointsToAdd.append(first.value)
                ppgQueue.removeFirst()
            }
            
            if !pointsToAdd.isEmpty {
                self.ppgHistory.append(contentsOf: pointsToAdd)
                if self.ppgHistory.count > maxHistoryPoints {
                    self.ppgHistory.removeFirst(self.ppgHistory.count - maxHistoryPoints)
                }
            }
            
            // Sleep for ~16ms to match display refresh rate
            try? await Task.sleep(nanoseconds: 16_666_666) 
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
