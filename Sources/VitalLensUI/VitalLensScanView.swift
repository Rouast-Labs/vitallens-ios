import SwiftUI
import VitalLens
import VitalLensInference

#if canImport(UIKit)

// TODO: Adopt centralised state management for scan and monitor views from js

/// Represents the various operational states of the scanning process.
public enum ScanState {
    case idle
    case searching
    case warmingUp
    case tracking
    case recovering
    case issue
    case completed
}

/// A SwiftUI view that provides a guided, fixed-duration scanning experience.
/// It captures video, evaluates face placement and lighting, and returns a single aggregated result upon completion.
public struct VitalLensScanView: View {
    
    private let apiKey: String?
    private let proxyURL: URL?
    private let method: String
    private let onComplete: (VitalLensResult) -> Void
    
    @State private var client: VitalLens?
    @State private var scanState: ScanState = .idle
    @State private var currentModeState: VitalLensMode = .eco
    private let initialMode: VitalLensMode
    
    @State private var progress: Double = 0.0
    @State private var statusMessage: String = "Position your face in the oval"
    @State private var finalResult: VitalLensResult? = nil
    @State private var showDetails: Bool = false
    
    @State private var accumulatedScanTime: TimeInterval = 0
    @State private var lastFrameTime: Date? = nil
    @State private var stateStartTime: Date? = nil
    @State private var strikeCount: Int = 0
    @State private var ppgConfHistory: [Double] = []
    @State private var respConfHistory: [Double] = []
    @State private var faceConfHistory: [Double] = []
    
    @State private var totalFramesProcessed: Int = 0
    @State private var primaryVitals: [ResolvedVital] = []
    @State private var secondaryVitals: [ResolvedVital] = []
    @State private var scanStats = ScanStats(duration: 0, sampleCount: 0, avgFaceConf: 0)

    private let scanDuration: TimeInterval = 30.0
    private let warmUpDuration: TimeInterval = 3.0
    private let recoveryTimeout: TimeInterval = 10.0
    
    private let vitalConfThreshold = 0.8
    private let hrvConfThreshold = 0.7
    
    /// Initializes a new Scan View.
    ///
    /// - Parameters:
    ///   - apiKey: Your VitalLens API Key. Defaults to `nil`.
    ///   - proxyURL: An optional URL to a custom backend proxy. Defaults to `nil`.
    ///   - method: The specific model or method to use for inference. Defaults to `"vitallens"`.
    ///   - mode: The performance mode to use during the scan. Defaults to `.eco`.
    ///   - onComplete: A closure called when the scan successfully finishes, providing the aggregated result.
    public init(
        apiKey: String? = nil,
        proxyURL: URL? = nil,
        method: String = "vitallens",
        mode: VitalLensMode = .eco,
        onComplete: @escaping (VitalLensResult) -> Void
    ) {
        self.apiKey = apiKey
        self.proxyURL = proxyURL
        self.method = method
        self.initialMode = mode
        self.onComplete = onComplete
    }
    
    public var body: some View {
        ZStack {
            if scanState == .idle {
                VitalLensStartView(
                    title: "VitalLens Vitals Scan",
                    subtitle: "Estimate your vital signs using\nonly your camera",
                    timingHintLabel: "Scan takes\n~30 seconds.",
                    startButtonLabel: "Start Scan",
                    currentMode: $currentModeState,
                    onStart: { startProcessing() }
                )
            } else if scanState == .completed {
                VitalLensResultView(
                    title: "Scan Complete",
                    primaryVitals: primaryVitals,
                    secondaryVitals: secondaryVitals,
                    stats: scanStats,
                    onDone: resetToIdle
                )
            } else {
                scanUILayer
            }
        }
        .onAppear { self.currentModeState = self.initialMode }
        .onDisappear {
            client?.stopStream()
        }
    }
    
    @ViewBuilder
    private var scanUILayer: some View {
        VStack {
            topBarLayer
            Spacer()
            
            Text(statusMessage)
                .font(.subheadline)
                .fontWeight(.medium)
                .foregroundColor(.white)
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
                .background(Color.black.opacity(0.6))
                .cornerRadius(20)
                .padding(.bottom, 40)
        }
        .background {
            ZStack {
                Color.black
                
                CameraPreview { view in
                    startSession(in: view)
                }
                
                CutoutOverlay()
                
                if scanState == .tracking || scanState == .recovering || scanState == .warmingUp {
                    ZStack {
                        Ellipse()
                            .trim(from: 0.0, to: CGFloat(progress))
                            .stroke(VitalInfoCache.brandBlue, style: StrokeStyle(lineWidth: 6, lineCap: .round))
                            .frame(width: 450, height: 320)
                            .rotationEffect(.degrees(-90))
                            .animation(.linear(duration: 0.2), value: progress)
                    }
                    .frame(width: 320, height: 450)
                }
            }
            .ignoresSafeArea()
        }
    }
    
    private var topBarLayer: some View {
        ZStack {
            HStack {
                Link(destination: URL(string: "https://www.rouast.com/api/")!) {
                    Image("vitallens_logo", bundle: .module)
                        .resizable()
                        .scaledToFit()
                        .frame(width: 32, height: 32)
                        .background(Color.white)
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                }
                
                Spacer()
                
                Button(action: {
                    transition(to: .issue, message: "Scan cancelled by user.")
                }) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.title)
                        .symbolRenderingMode(.hierarchical)
                        .foregroundColor(.white)
                        .padding(.leading, 8)
                }
            }
            
            ScanStatusBadge(state: scanState)
        }
        .padding(.horizontal)
        .padding(.top, 8)
    }    
    
    /// Initializes internal state and begins the scanning workflow.
    private func startProcessing() {
        scanState = .searching
        statusMessage = "Position your face in the oval"
        progress = 0.0
        accumulatedScanTime = 0.0
        stateStartTime = Date()
        lastFrameTime = nil
        strikeCount = 0
        ppgConfHistory.removeAll()
        respConfHistory.removeAll()
        faceConfHistory.removeAll()
        totalFramesProcessed = 0
    }
    
    /// Resets the view back to the initial idle state.
    private func resetToIdle() {
        client?.stopStream()
        client = nil
        scanState = .idle
        progress = 0.0
        accumulatedScanTime = 0.0
        finalResult = nil
        strikeCount = 0
        ppgConfHistory.removeAll()
        respConfHistory.removeAll()
        faceConfHistory.removeAll()
        showDetails = false
        totalFramesProcessed = 0
    }
    
    /// Transitions the scanner to a new state, updating internal timers and messages.
    ///
    /// - Parameters:
    ///   - newState: The state to transition to.
    ///   - message: The localized message to display to the user.
    private func transition(to newState: ScanState, message: String) {
        self.scanState = newState
        self.statusMessage = message
        self.stateStartTime = Date()
        
        if newState == .issue {
            self.client?.stopStream()
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                if self.scanState == .issue {
                    self.resetToIdle()
                }
            }
        }
    }

    /// Handles transient issues during the scan, escalating to a full issue state if retries are exhausted.
    ///
    /// - Parameter message: The warning message to display.
    private func handleIssue(message: String) {
        strikeCount += 1
        if strikeCount >= 3 {
            transition(to: .issue, message: message)
        } else {
            scanState = .searching
            statusMessage = "\(message) Retrying..."
            progress = 0.0
            accumulatedScanTime = 0.0
            stateStartTime = Date()
            lastFrameTime = nil
            client?.resetStream()
            ppgConfHistory.removeAll()
            respConfHistory.removeAll()
            faceConfHistory.removeAll()
        }
    }
    
    /// Validates whether the detected face is adequately positioned within the frame.
    ///
    /// - Parameter result: The latest inference result containing face coordinates.
    /// - Returns: `true` if the face is centered and large enough; otherwise `false`.
    private func isFaceGood(_ result: VitalLensResult) -> Bool {
        guard let box = result.face.boundingBoxes.last else { return false }
        let midX = box.midX
        let midY = box.midY
        return midX > 0.3 && midX < 0.7 && midY > 0.3 && midY < 0.7 && box.width > 0.15
    }
    
    /// Initializes the stream processor and links it to the camera preview.
    ///
    /// - Parameter view: The `UIView` where the camera preview will be rendered.
    private func startSession(in view: UIView) {
        guard client == nil else { return }
        
        if apiKey == nil && proxyURL == nil {
            transition(to: .issue, message: "Error: Missing API Key or Proxy URL")
            return
        }
        
        let newClient = VitalLens(
            apiKey: apiKey,
            method: method,
            proxyURL: proxyURL,
            overrideFps: currentModeState.fps
        )
        
        newClient.onFaceStateChanged = { @Sendable isPresent in
            Task { @MainActor in
                guard self.scanState != .idle && self.scanState != .completed && self.scanState != .issue else { return }
                
                if !isPresent && self.scanState != .searching {
                    self.handleIssue(message: "Face lost.")
                }
            }
        }
        
        self.client = newClient
        
        Task {
            do {
                let stream = try await newClient.startStream(preview: view)
                for await result in stream {
                    updateUI(with: result)
                }
            } catch {
                await MainActor.run {
                    transition(to: .issue, message: "Error: \(error.localizedDescription)")
                }
            }
        }
    }
    
    @MainActor
    private func updateUI(with result: VitalLensResult) {
        let framesInThisUpdate = result.sampleCount ?? result.time.count
        self.totalFramesProcessed += framesInThisUpdate
        
        if let newFaceConfs = result.face.confidence {
            faceConfHistory.append(contentsOf: newFaceConfs)
        }
        if let newPpgConfs = result.ppg?.confidence {
            ppgConfHistory.append(contentsOf: newPpgConfs.map { Double($0) })
        }
        if let newRespConfs = result.resp?.confidence {
            respConfHistory.append(contentsOf: newRespConfs.map { Double($0) })
        }

        guard scanState != .idle && scanState != .completed && scanState != .issue else { return }

        let fps = currentModeState.fps
        let samplesInOneSecond = Int(fps)        
        
        let lastSecFaceConf = faceConfHistory.suffix(samplesInOneSecond)
        let avgFaceConfLastSec = lastSecFaceConf.isEmpty ? 0.0 : lastSecFaceConf.reduce(0, +) / Double(lastSecFaceConf.count)
        
        let lastSecPpgConf = ppgConfHistory.suffix(samplesInOneSecond)
        let avgPpgConfLastSec = lastSecPpgConf.isEmpty ? 0.0 : lastSecPpgConf.reduce(0, +) / Double(lastSecPpgConf.count)

        let isLowSignal = avgPpgConfLastSec < 0.5 || avgFaceConfLastSec < 0.5
        let goodFace = isFaceGood(result)
        
        let now = Date()
        let elapsedInState = stateStartTime.map { now.timeIntervalSince($0) } ?? 0
        
        if scanState == .tracking || scanState == .recovering {
            if let last = lastFrameTime {
                accumulatedScanTime += now.timeIntervalSince(last)
                progress = min(accumulatedScanTime / scanDuration, 1.0)
            }
            lastFrameTime = now
            
            if accumulatedScanTime >= scanDuration {
                client?.stopStream()
                
                let res = result
                let hrMeta = VitalInfoCache.getInfo(for: "heart_rate")
                let rrMeta = VitalInfoCache.getInfo(for: "respiratory_rate")
                
                self.primaryVitals = [
                    ResolvedVital(id: "hr", title: hrMeta?.displayName ?? "Heart Rate", 
                                value: (res.heartRate?.confidence ?? 0) >= vitalConfThreshold ? res.heartRate?.value : nil, 
                                unit: hrMeta?.unit.uppercased() ?? "BPM", format: "%.0f", 
                                confidence: res.heartRate?.confidence, emoji: hrMeta?.emoji ?? "❤️"),
                    ResolvedVital(id: "rr", title: rrMeta?.displayName ?? "Respiration", 
                                value: (res.respiratoryRate?.confidence ?? 0) >= vitalConfThreshold ? res.respiratoryRate?.value : nil, 
                                unit: rrMeta?.unit.uppercased() ?? "RPM", format: "%.0f", 
                                confidence: res.respiratoryRate?.confidence, emoji: rrMeta?.emoji ?? "🫁")
                ]
                
                self.secondaryVitals = [
                    ("hrv_sdnn", res.hrvSdnn?.value, res.hrvSdnn?.confidence ?? 0, hrvConfThreshold),
                    ("hrv_rmssd", res.hrvRmssd?.value, res.hrvRmssd?.confidence ?? 0, hrvConfThreshold),
                    ("ie_ratio", res.vitals["ie_ratio"]?.value, res.vitals["ie_ratio"]?.confidence ?? 0, vitalConfThreshold)
                ].compactMap { id, val, conf, thresh in
                    guard conf >= thresh, let v = val, let m = VitalInfoCache.getInfo(for: id) else { return nil }
                    return ResolvedVital(id: id, title: m.shortName, value: v, unit: m.unit.uppercased(), 
                                        format: (id == "ie_ratio" ? "%.2f" : "%.0f"), confidence: conf, emoji: m.emoji)
                }
                
                let globalAvgFace = faceConfHistory.isEmpty ? 0.0 : faceConfHistory.reduce(0, +) / Double(faceConfHistory.count)
                self.scanStats = ScanStats(
                    duration: Double(totalFramesProcessed) / (res.fps ?? currentModeState.fps),
                    sampleCount: totalFramesProcessed,
                    avgFaceConf: globalAvgFace
                )

                finalResult = result
                scanState = .completed
                onComplete(result)
                return  
            }
        } else {
            lastFrameTime = nil
        }
        
        switch scanState {
        case .searching:
            if goodFace {
                transition(to: .warmingUp, message: "Calibrating... Hold still.")
            }
            
        case .warmingUp:
            if elapsedInState >= warmUpDuration {
                transition(to: .tracking, message: "Scanning...")
                lastFrameTime = now
            }
            
        case .tracking:
            if !goodFace {
                transition(to: .recovering, message: "Adjust position...")
            } else if isLowSignal {
                transition(to: .recovering, message: "Improve lighting...")
            }
            
        case .recovering:
            if goodFace && !isLowSignal {
                transition(to: .tracking, message: "Scanning...")
            } else if elapsedInState >= recoveryTimeout {
                handleIssue(message: "Could not recover conditions.")
            } else {
                let currentIssueMessage = !goodFace ? "Adjust position..." : "Improve lighting..."
                if statusMessage != currentIssueMessage {
                    statusMessage = currentIssueMessage
                }
            }
            
        default: break
        }
    }
}

/// A lightweight visual component displaying the current state of the scan.
struct ScanStatusBadge: View {
    let state: ScanState
    
    var body: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(color)
                .frame(width: 8, height: 8)
                .modifier(PulseEffect(isPulsing: state == .searching || state == .warmingUp || state == .recovering))
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
        case .idle, .completed: return .gray
        case .searching: return VitalInfoCache.brandBlue
        case .warmingUp: return .purple
        case .tracking: return .green
        case .recovering: return .orange
        case .issue: return .red
        }
    }
    
    var text: String {
        switch state {
        case .idle: return "Idle"
        case .searching: return "Searching"
        case .warmingUp: return "Calibrating"
        case .tracking: return "Scanning"
        case .recovering: return "Recovering"
        case .issue: return "Issue"
        case .completed: return "Done"
        }
    }
}

/// An overlay providing a visual guide (an oval cutout) for user face placement.
struct CutoutOverlay: View {
    var body: some View {
        ZStack {
            Rectangle()
                .fill(.ultraThinMaterial)
            Ellipse()
                .frame(width: 320, height: 450)
                .blendMode(.destinationOut)
        }
        .compositingGroup()
    }
}

#endif