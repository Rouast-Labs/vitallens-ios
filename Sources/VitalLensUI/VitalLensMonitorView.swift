import SwiftUI
import VitalLens
import VitalLensInference
import VitalLensCore

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

enum MonitorState {
    case idle
    case searching
    case warmingUp
    case tracking
    case issue
}

public struct VitalLensMonitorView: View {
    
    private let apiKey: String?
    private let proxyURL: URL?
    private let method: String
    private let showWaveforms: Bool
    private let mode: VitalLensMode
    private let bufferOffset: TimeInterval
    private let windowSize: TimeInterval
    private let minDisplayDuration: TimeInterval
    
    @State private var client: VitalLens?
    @State private var isProcessing = false
    @State private var monitorState: MonitorState = .idle
    @State private var feedbackMessage: String = ""
    
    @State private var isFaceCurrentlyDetected = false
    
    // Vital states
    @State private var hrValue: Double?
    @State private var hrConf: Double = 0.0
    @State private var rrValue: Double?
    @State private var rrConf: Double = 0.0
    @State private var sdnnValue: Double?
    @State private var sdnnConf: Double = 0.0
    @State private var rmssdValue: Double?
    @State private var rmssdConf: Double = 0.0
    
    // Waveform states
    @State private var ppgHistory: [Double] = []
    @State private var ppgConf: Double = 0.0
    @State private var respHistory: [Double] = []
    @State private var respConf: Double = 0.0
    
    private var maxHistoryPoints: Int {
        return Int(minDisplayDuration * mode.fps)
    }
    
    struct BufferedPoint {
        let value: Double
        let displayTime: TimeInterval
    }
    @State private var ppgQueue: [BufferedPoint] = []
    @State private var respQueue: [BufferedPoint] = []
    @State private var timeAnchor: (videoTime: TimeInterval, realTime: TimeInterval)? = nil
    @State private var playbackTask: Task<Void, Never>? = nil
    
    private let vitalConfThreshold = 0.6
    private let hrvConfThreshold = 0.5
    private let faceConfThreshold = 0.5
    
    public init(
        apiKey: String? = nil,
        proxyURL: URL? = nil,
        method: String = "vitallens",
        showWaveforms: Bool = true,
        mode: VitalLensMode = .eco,
        bufferOffset: TimeInterval = 0.4,
        windowSize: TimeInterval = 10.0,
        minDisplayDuration: TimeInterval = 5.0 
    ) {
        self.apiKey = apiKey
        self.proxyURL = proxyURL
        self.method = method
        self.showWaveforms = showWaveforms
        self.mode = mode
        self.bufferOffset = bufferOffset
        self.windowSize = windowSize
        self.minDisplayDuration = minDisplayDuration
    }
    
    // MARK: - Computed Properties for UI Readiness
    // Moving these out of the body block fixes the compiler timeout
    private var hasEnoughData: Bool { ppgHistory.count >= maxHistoryPoints }
    private var isHrReady: Bool { hrConf >= vitalConfThreshold && hasEnoughData }
    private var isRrReady: Bool { rrConf >= vitalConfThreshold && hasEnoughData }
    private var isSdnnReady: Bool { sdnnConf >= hrvConfThreshold && hasEnoughData }
    private var isRmssdReady: Bool { rmssdConf >= hrvConfThreshold && hasEnoughData }
    private var isPpgReady: Bool { ppgConf >= vitalConfThreshold && hasEnoughData }
    private var isRespReady: Bool { respConf >= vitalConfThreshold && hasEnoughData }
    
    private var dynamicMessage: String {
        if !feedbackMessage.isEmpty { return feedbackMessage }
        if monitorState == .warmingUp {
            let progress = min(100, Int((Double(ppgHistory.count) / Double(maxHistoryPoints)) * 100))
            return "Calibrating signals... (\(progress)%)"
        }
        return ""
    }
    
    // MARK: - Body
    public var body: some View {
        ZStack {
            cameraLayer
            
            VStack(spacing: 0) {
                topBarLayer
                Spacer()
                middleGapLayer
                bottomMetricsLayer
            }
            
            idleOverlayLayer
        }
        .onTapGesture { toggleProcessing() }
        .onDisappear { stopProcessing() }
    }
    
    // MARK: - Extracted View Layers
    
    @ViewBuilder
    private var cameraLayer: some View {
        if isProcessing {
            CameraPreview { view in
                startSession(in: view)
            }
            .edgesIgnoringSafeArea(.all)
        } else {
            Color.black.edgesIgnoringSafeArea(.all)
        }
    }
    
    private var topBarLayer: some View {
        HStack {
            Link(destination: URL(string: "https://www.rouast.com/api/")!) {
                HStack(spacing: 8) {
                    Image(systemName: "bolt.heart.fill")
                        .foregroundColor(.red)
                    Text("VitalLens API")
                        .font(.headline)
                        .foregroundColor(.primary)
                }
            }
            Spacer()
            StatusBadge(state: monitorState)
        }
        .padding(.horizontal)
        .padding(.top, 8)
        .padding(.bottom, 12)
        .background(
            Rectangle()
                .fill(.ultraThinMaterial)
                .edgesIgnoringSafeArea(.top)
        )
    }
    
    @ViewBuilder
    private var middleGapLayer: some View {
        if monitorState == .searching || monitorState == .issue {
            Ellipse()
                .strokeBorder(Color.white.opacity(0.4), style: StrokeStyle(lineWidth: 2, dash: [8]))
                .frame(width: 220, height: 300)
                .padding()
            Spacer()
        }
    }
    
    @ViewBuilder
    private var bottomMetricsLayer: some View {
        if monitorState != .idle {
            VStack(spacing: 10) {
                
                if !dynamicMessage.isEmpty {
                    Text(dynamicMessage)
                        .font(.footnote)
                        .fontWeight(.medium)
                        .foregroundColor(.orange)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal)
                }
                
                // ROW 1: Cardiac
                HStack(spacing: 10) {
                    if showWaveforms {
                        WaveformContainer(title: "PPG Waveform", color: .red, history: ppgHistory, isReady: isPpgReady)
                    }
                    
                    GroupedMetricsTile(
                        primaryTitle: "Heart Rate", primaryValue: hrValue, primaryUnit: "BPM", isPrimaryReady: isHrReady,
                        secondary1Title: "SDNN", secondary1Value: sdnnValue, secondary1Unit: "ms", isSecondary1Ready: isSdnnReady, isSecondary1Placeholder: false,
                        secondary2Title: "RMSSD", secondary2Value: rmssdValue, secondary2Unit: "ms", isSecondary2Ready: isRmssdReady, isSecondary2Placeholder: false
                    )
                    .frame(width: showWaveforms ? 140 : .infinity)
                }
                .frame(height: 90)
                .padding(.horizontal)
                
                // ROW 2: Respiration
                HStack(spacing: 10) {
                    if showWaveforms {
                        WaveformContainer(title: "Respiratory Waveform", color: .blue, history: respHistory, isReady: isRespReady)
                    }
                    
                    GroupedMetricsTile(
                        primaryTitle: "Resp Rate", primaryValue: rrValue, primaryUnit: "RPM", isPrimaryReady: isRrReady,
                        secondary1Title: "I:E Ratio", secondary1Value: nil, secondary1Unit: "", isSecondary1Ready: false, isSecondary1Placeholder: true,
                        secondary2Title: "", secondary2Value: nil, secondary2Unit: "", isSecondary2Ready: false, isSecondary2Placeholder: true 
                    )
                    .frame(width: showWaveforms ? 140 : .infinity)
                }
                .frame(height: 90)
                .padding(.horizontal)
            }
            .padding(.top, 12)
            .padding(.bottom, 20)
            .background(
                Rectangle()
                    .fill(.ultraThinMaterial)
                    .edgesIgnoringSafeArea(.bottom)
            )
        }
    }
    
    @ViewBuilder
    private var idleOverlayLayer: some View {
        if monitorState == .idle {
            Color.black.opacity(0.6).edgesIgnoringSafeArea(.all)
            VStack {
                Image(systemName: "play.circle.fill")
                    .font(.system(size: 64))
                    .foregroundColor(.white)
                Text("Tap to Start")
                    .font(.title2)
                    .fontWeight(.semibold)
                    .foregroundColor(.white)
                    .padding(.top, 8)
            }
        }
    }
    
    // MARK: - Logic Methods
    
    private func toggleProcessing() {
        if isProcessing { stopProcessing() } else {
            isProcessing = true
            monitorState = .searching
            feedbackMessage = "Face the camera, ensure good lighting and hold still."
        }
    }
    
    private func stopProcessing() {
        isProcessing = false
        monitorState = .idle
        feedbackMessage = ""
        client?.stopStream()
        playbackTask?.cancel()
        client = nil
        resetUI()
    }
    
    private func clearMeasurements() {
        hrValue = nil; hrConf = 0.0
        rrValue = nil; rrConf = 0.0
        sdnnValue = nil; sdnnConf = 0.0
        rmssdValue = nil; rmssdConf = 0.0
        ppgHistory.removeAll(); ppgQueue.removeAll(); ppgConf = 0.0
        respHistory.removeAll(); respQueue.removeAll(); respConf = 0.0
        timeAnchor = nil
    }
    
    private func resetUI() {
        clearMeasurements()
        isFaceCurrentlyDetected = false
    }
    
    private func startSession(in view: UIView) {
        guard client == nil else { return }
        
        let newClient = VitalLens(
            apiKey: apiKey,
            method: method,
            proxyURL: proxyURL,
            overrideFps: mode.fps,
            waveformMode: .incremental
        )
        
        newClient.onFaceStateChanged = { @Sendable isPresent in
            Task { @MainActor in
                self.isFaceCurrentlyDetected = isPresent
                if !isPresent {
                    self.monitorState = .issue
                    self.feedbackMessage = "Check Position: Face the camera and hold still."
                    self.clearMeasurements()
                } else if self.monitorState == .issue {
                    self.monitorState = .searching
                    self.feedbackMessage = "Face detected, analyzing..."
                }
            }
        }
        
        self.client = newClient
        if bufferOffset > 0 { playbackTask = Task { await runPlaybackLoop() } }
        
        Task {
            do {
                let stream = try await newClient.startStream(preview: view)
                for await result in stream {
                    await updateUI(with: result)
                }
            } catch {
                await MainActor.run { stopProcessing() }
            }
        }
    }
    
    @MainActor
    private func updateUI(with result: VitalLensResult) {
        guard isFaceCurrentlyDetected else { return }
        
        let faceConfs = result.face.confidence ?? []
        let currentFaceConf = faceConfs.isEmpty ? 1.0 : faceConfs.last!
        
        if currentFaceConf < faceConfThreshold {
            monitorState = .issue
            feedbackMessage = "Face not clear. Hold still."
            return
        }
        
        if showWaveforms { queueWaveformData(result: result) }
        
        if let hr = result.heartRate { hrValue = hr.value; hrConf = hr.confidence }
        if let rr = result.respiratoryRate { rrValue = rr.value; rrConf = rr.confidence }
        if let sdnn = result.hrvSdnn { sdnnValue = sdnn.value; sdnnConf = sdnn.confidence }
        if let rmssd = result.hrvRmssd { rmssdValue = rmssd.value; rmssdConf = rmssd.confidence }
        
        let hasConfidentHr = hrConf >= vitalConfThreshold
        let hasConfidentRr = rrConf >= vitalConfThreshold
        let hasConfidentHrv = sdnnConf >= hrvConfThreshold || rmssdConf >= hrvConfThreshold
        
        if !(hasConfidentHr || hasConfidentRr || hasConfidentHrv) {
            monitorState = .issue
            feedbackMessage = "Low confidence. Ensure you are well lit and hold still."
        } else if !hasEnoughData {
            monitorState = .warmingUp
            feedbackMessage = "" 
        } else {
            monitorState = .tracking
            feedbackMessage = "Tracking vitals"
        }
        
        if let ppg = result.ppg { ppgConf = Double(ppg.confidence.last ?? 0) }
        if let resp = result.resp { respConf = Double(resp.confidence.last ?? 0) }
    }
    
    @MainActor
    private func queueWaveformData(result: VitalLensResult) {
        let ppgChunk = result.ppg?.data ?? []
        let respChunk = result.resp?.data ?? []
        guard !ppgChunk.isEmpty || !respChunk.isEmpty else { return }
        
        if bufferOffset > 0 {
            if timeAnchor == nil, let firstTime = result.time.first {
                timeAnchor = (videoTime: firstTime, realTime: CACurrentMediaTime())
            }
            
            if let anchor = timeAnchor {
                for (index, time) in result.time.enumerated() {
                    let targetDisplayTime = anchor.realTime + (time - anchor.videoTime) + bufferOffset
                    
                    if index < ppgChunk.count {
                        ppgQueue.append(BufferedPoint(value: Double(ppgChunk[index]), displayTime: targetDisplayTime))
                    }
                    if index < respChunk.count {
                        respQueue.append(BufferedPoint(value: Double(respChunk[index]), displayTime: targetDisplayTime))
                    }
                }
            }
        } else {
            self.ppgHistory.append(contentsOf: ppgChunk.map { Double($0) })
            if self.ppgHistory.count > maxHistoryPoints { self.ppgHistory.removeFirst(self.ppgHistory.count - maxHistoryPoints) }
            
            self.respHistory.append(contentsOf: respChunk.map { Double($0) })
            if self.respHistory.count > maxHistoryPoints { self.respHistory.removeFirst(self.respHistory.count - maxHistoryPoints) }
        }
    }
    
    @MainActor
    private func runPlaybackLoop() async {
        while !Task.isCancelled {
            let now = CACurrentMediaTime()
            
            var ppgToAdd: [Double] = []
            while let first = ppgQueue.first, now >= first.displayTime {
                ppgToAdd.append(first.value)
                ppgQueue.removeFirst()
            }
            if !ppgToAdd.isEmpty {
                ppgHistory.append(contentsOf: ppgToAdd)
                if ppgHistory.count > maxHistoryPoints { ppgHistory.removeFirst(ppgHistory.count - maxHistoryPoints) }
            }
            
            var respToAdd: [Double] = []
            while let first = respQueue.first, now >= first.displayTime {
                respToAdd.append(first.value)
                respQueue.removeFirst()
            }
            if !respToAdd.isEmpty {
                respHistory.append(contentsOf: respToAdd)
                if respHistory.count > maxHistoryPoints { respHistory.removeFirst(respHistory.count - maxHistoryPoints) }
            }
            
            try? await Task.sleep(nanoseconds: 16_666_666)
        }
    }
}

// MARK: - UI Components

struct StatusBadge: View {
    let state: MonitorState
    
    var body: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(color)
                .frame(width: 8, height: 8)
                .modifier(PulseEffect(isPulsing: state == .searching || state == .warmingUp))
            Text(text)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(.ultraThinMaterial)
        .cornerRadius(20)
    }
    
    var color: Color {
        switch state {
        case .idle: return .gray
        case .searching: return .blue
        case .warmingUp: return .purple
        case .tracking: return .green
        case .issue: return .orange
        }
    }
    
    var text: String {
        switch state {
        case .idle: return "Idle"
        case .searching: return "Searching..."
        case .warmingUp: return "Calibrating..."
        case .tracking: return "Tracking"
        case .issue: return "Check Position"
        }
    }
}

struct PulseEffect: ViewModifier {
    let isPulsing: Bool
    @State private var scale: CGFloat = 1.0
    @State private var opacity: Double = 1.0
    
    func body(content: Content) -> some View {
        content
            .scaleEffect(scale)
            .opacity(opacity)
            .onChange(of: isPulsing) { pulsing in
                if pulsing {
                    withAnimation(.easeInOut(duration: 0.75).repeatForever(autoreverses: true)) {
                        scale = 1.2
                        opacity = 0.5
                    }
                } else {
                    withAnimation {
                        scale = 1.0
                        opacity = 1.0
                    }
                }
            }
    }
}

struct WaveformContainer: View {
    let title: String
    let color: Color
    let history: [Double]
    let isReady: Bool
    
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(title)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 10)
                .padding(.top, 6)
            
            ZStack {
                if isReady && !history.isEmpty {
                    WaveformView(samples: history, color: color)
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

struct GroupedMetricsTile: View {
    let primaryTitle: String
    let primaryValue: Double?
    let primaryUnit: String
    let isPrimaryReady: Bool
    
    let secondary1Title: String
    let secondary1Value: Double?
    let secondary1Unit: String
    let isSecondary1Ready: Bool
    let isSecondary1Placeholder: Bool
    
    let secondary2Title: String
    let secondary2Value: Double?
    let secondary2Unit: String
    let isSecondary2Ready: Bool
    let isSecondary2Placeholder: Bool
    
    var body: some View {
        VStack(spacing: 0) {
            VStack(spacing: 0) {
                Text(primaryTitle)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.secondary)
                
                if isPrimaryReady, let val = primaryValue {
                    HStack(alignment: .firstTextBaseline, spacing: 2) {
                        Text(String(format: "%.0f", val))
                            .font(.system(size: 28, weight: .bold, design: .rounded)) // Reduced
                            .monospacedDigit()
                            .foregroundColor(.primary)
                        Text(primaryUnit)
                            .font(.system(size: 9))
                            .foregroundStyle(.secondary)
                    }
                } else {
                    ProgressView()
                        .frame(height: 30) // Tighter
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            
            Divider()
                .padding(.horizontal, 12)
            
            HStack(spacing: 0) {
                VStack(spacing: 0) {
                    Text(secondary1Title)
                        .font(.system(size: 8)) // Micro font
                        .foregroundStyle(.secondary)
                    
                    if isSecondary1Placeholder {
                        Text("--")
                            .font(.system(size: 12, weight: .bold, design: .rounded))
                            .foregroundColor(.secondary.opacity(0.3))
                    } else if isSecondary1Ready, let val = secondary1Value {
                        HStack(alignment: .firstTextBaseline, spacing: 1) {
                            Text(String(format: "%.0f", val))
                                .font(.system(size: 12, weight: .bold, design: .rounded))
                                .monospacedDigit()
                            Text(secondary1Unit)
                                .font(.system(size: 8))
                                .foregroundStyle(.secondary)
                        }
                    } else {
                        ProgressView().frame(height: 14)
                    }
                }
                .frame(maxWidth: .infinity)
                .opacity(secondary1Title.isEmpty ? 0 : 1.0)
                
                Divider()
                    .frame(height: 16)
                    .opacity(secondary2Title.isEmpty ? 0 : 1.0)
                
                VStack(spacing: 0) {
                    Text(secondary2Title)
                        .font(.system(size: 8))
                        .foregroundStyle(.secondary)
                    
                    if isSecondary2Placeholder {
                        Text("--")
                            .font(.system(size: 12, weight: .bold, design: .rounded))
                            .foregroundColor(.secondary.opacity(0.3))
                    } else if isSecondary2Ready, let val = secondary2Value {
                        HStack(alignment: .firstTextBaseline, spacing: 1) {
                            Text(String(format: "%.0f", val))
                                .font(.system(size: 12, weight: .bold, design: .rounded))
                                .monospacedDigit()
                            Text(secondary2Unit)
                                .font(.system(size: 8))
                                .foregroundStyle(.secondary)
                        }
                    } else {
                        ProgressView().frame(height: 14)
                    }
                }
                .frame(maxWidth: .infinity)
                .opacity(secondary2Title.isEmpty ? 0 : 1.0)
            }
            .padding(.vertical, 6) // Tighter bottom padding
        }
        .background(Color(UIColor.secondarySystemBackground))
        .cornerRadius(12) 
    }
}

#endif