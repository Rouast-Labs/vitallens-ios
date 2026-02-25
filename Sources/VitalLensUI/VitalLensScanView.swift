import SwiftUI
import VitalLens
import VitalLensInference

#if canImport(UIKit)

public enum ScanState {
    case idle, searching, warmingUp, tracking, recovering, issue, completed
}

public struct VitalLensScanView: View {
    
    private let apiKey: String?
    private let proxyURL: URL?
    private let method: String
    private let onComplete: (VitalLensResult) -> Void
    
    @State private var client: VitalLens?
    @State private var scanState: ScanState = .idle
    @State private var currentModeState: VitalLensMode
    
    @State private var progress: Double = 0.0
    @State private var statusMessage: String = "Position your face in the oval"
    @State private var finalResult: VitalLensResult? = nil
    
    @State private var accumulatedScanTime: TimeInterval = 0
    @State private var lastFrameTime: Date? = nil
    @State private var stateStartTime: Date? = nil
    @State private var strikeCount: Int = 0
    @State private var ppgConfHistory: [Double] = []
    @State private var faceConfHistory: [Double] = []
    
    private let scanDuration: TimeInterval = 30.0
    private let warmUpDuration: TimeInterval = 5.0
    private let recoveryTimeout: TimeInterval = 10.0
    
    private let vitalConfThreshold = 0.6
    private let hrvConfThreshold = 0.5
    
    /// Initializes the Scan View.
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
        self._currentModeState = State(initialValue: mode)
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
                resultOverlay
            } else {
                scanUILayer
            }
        }
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
                            .stroke(VitalMetadataCache.brandBlue, style: StrokeStyle(lineWidth: 6, lineCap: .round))
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
                Image("vitallens_logo", bundle: .module)
                    .resizable()
                    .scaledToFit()
                    .frame(width: 32, height: 32)
                    .background(Color.white)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                
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
    
    @ViewBuilder
    private var resultOverlay: some View {
        if let res = finalResult {
            ZStack {
                Color(red: 0.06, green: 0.07, blue: 0.09).edgesIgnoringSafeArea(.all)
                
                VStack(spacing: 24) {
                    HStack(spacing: 12) {
                        Image("vitallens_logo", bundle: .module)
                            .resizable()
                            .scaledToFit()
                            .frame(width: 32, height: 32)
                            .background(Color.white)
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                        Text("Scan Complete")
                            .font(.headline)
                            .foregroundColor(.white)
                        Spacer()
                    }
                    .padding(.top, 8)
                    
                    Spacer()
                    
                    // Evaluate Confidence
                    let hrVal = res.heartRate?.confidence ?? 0 >= vitalConfThreshold ? res.heartRate?.value : nil
                    let rrVal = res.respiratoryRate?.confidence ?? 0 >= vitalConfThreshold ? res.respiratoryRate?.value : nil
                    
                    let sdnnVal = res.hrvSdnn?.confidence ?? 0 >= hrvConfThreshold ? res.hrvSdnn?.value : nil
                    let rmssdVal = res.hrvRmssd?.confidence ?? 0 >= hrvConfThreshold ? res.hrvRmssd?.value : nil
                    let ieVal = res.vitals["ie_ratio"]?.confidence ?? 0 >= vitalConfThreshold ? res.vitals["ie_ratio"]?.value : nil
                    
                    let extras = [
                        ("hrv_sdnn", sdnnVal),
                        ("hrv_rmssd", rmssdVal),
                        ("ie_ratio", ieVal)
                    ].filter { $0.1 != nil }
                    
                    VStack(spacing: 16) {
                        HStack(spacing: 16) {
                            ScanResultTile(vitalId: "heart_rate", value: hrVal)
                            ScanResultTile(vitalId: "respiratory_rate", value: rrVal)
                        }
                        
                        if !extras.isEmpty {
                            HStack(spacing: 16) {
                                ForEach(extras, id: \.0) { item in
                                    ScanResultTile(vitalId: item.0, value: item.1)
                                }
                            }
                        }
                    }
                    
                    Spacer()
                    
                    VStack(spacing: 12) {
                        Button(action: { resetToIdle() }) {
                            Text("Scan Again")
                                .font(.headline)
                                .foregroundColor(.white)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 18)
                                .background(VitalMetadataCache.brandBlue)
                                .cornerRadius(16)
                        }
                        
                        Button(action: { resetToIdle() }) {
                            Text("View Details")
                                .font(.headline)
                                .foregroundColor(.white)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 18)
                                .background(Color(white: 0.12))
                                .cornerRadius(16)
                        }
                    }
                    .padding(.bottom, 24)
                }
                .padding(.horizontal, 24)
            }
        }
    }
    
     
    
    private func startProcessing() {
        scanState = .searching
        statusMessage = "Position your face in the oval"
        progress = 0.0
        accumulatedScanTime = 0.0
        stateStartTime = Date()
        lastFrameTime = nil
        strikeCount = 0
        ppgConfHistory.removeAll()
        faceConfHistory.removeAll()
    }
    
    private func resetToIdle() {
        client?.stopStream()
        client = nil
        scanState = .idle
        progress = 0.0
        accumulatedScanTime = 0.0
        finalResult = nil
        strikeCount = 0
        ppgConfHistory.removeAll()
        faceConfHistory.removeAll()
    }
    
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
            faceConfHistory.removeAll()
        }
    }
    
    private func isFaceGood(_ result: VitalLensResult) -> Bool {
        guard let box = result.face.boundingBoxes.last else { return false }
        let midX = box.midX
        let midY = box.midY
        return midX > 0.3 && midX < 0.7 && midY > 0.3 && midY < 0.7 && box.width > 0.15
    }
    
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
                    await updateUI(with: result)
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
        guard scanState != .idle && scanState != .completed && scanState != .issue else { return }
        
        let facePresent = result.face.boundingBoxes.last != nil
        if !facePresent {
            if scanState != .searching {
                handleIssue(message: "Face lost.")
            }
            return
        }
        
        let goodFace = isFaceGood(result)
        let now = Date()
        let elapsedInState = stateStartTime.map { now.timeIntervalSince($0) } ?? 0
        
        let maxHistory = Int(currentModeState.fps)
        
        if let newConfs = result.ppg?.confidence {
            ppgConfHistory.append(contentsOf: newConfs.map { Double($0) })
            if ppgConfHistory.count > maxHistory {
                ppgConfHistory.removeFirst(ppgConfHistory.count - maxHistory)
            }
        }
        
        if let newFaceConfs = result.face.confidence {
            faceConfHistory.append(contentsOf: newFaceConfs)
            if faceConfHistory.count > maxHistory {
                faceConfHistory.removeFirst(faceConfHistory.count - maxHistory)
            }
        }
        
        var isLowSignal = false
        if ppgConfHistory.count >= maxHistory && faceConfHistory.count >= maxHistory {
            let avgPpgConf = ppgConfHistory.reduce(0, +) / Double(ppgConfHistory.count)
            let avgFaceConf = faceConfHistory.reduce(0, +) / Double(faceConfHistory.count)
            isLowSignal = avgPpgConf < 0.5 || avgFaceConf < 0.5
        }
        
        // Let the timer run during BOTH tracking and recovering
        if scanState == .tracking || scanState == .recovering {
            if let last = lastFrameTime {
                accumulatedScanTime += now.timeIntervalSince(last)
                progress = min(accumulatedScanTime / scanDuration, 1.0)
            }
            lastFrameTime = now
            
            // Check for completion immediately so it can finish even during recovery
            if accumulatedScanTime >= scanDuration {
                client?.stopStream()
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
            // Grace period: we only abort if face completely lost (handled above)
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
        case .searching: return VitalMetadataCache.brandBlue
        case .warmingUp: return .purple
        case .tracking: return .green
        case .recovering: return .orange
        case .issue: return .red
        }
    }
    
    var text: String {
        switch state {
        case .idle: return "Idle"
        case .searching: return "Searching..."
        case .warmingUp: return "Calibrating..."
        case .tracking: return "Scanning"
        case .recovering: return "Adjust Position"
        case .issue: return "Issue"
        case .completed: return "Done"
        }
    }
}

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


struct ScanResultTile: View {
    let vitalId: String
    let value: Double?
    
    var body: some View {
        let meta = VitalMetadataCache.getMeta(for: vitalId)
        let title = meta?.displayName ?? vitalId
        let unit = meta?.unit.uppercased() ?? ""
        let format = (vitalId == "ie_ratio" || vitalId == "hrv_lfhf") ? "%.2f" : "%.0f"
        
        VStack(spacing: 8) {
            Text(title)
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
                
            HStack(alignment: .firstTextBaseline, spacing: 2) {
                if let val = value {
                    Text(String(format: format, val))
                        .font(.system(size: 32, weight: .bold, design: .rounded))
                        .foregroundColor(.white)
                        .lineLimit(1)
                        .minimumScaleFactor(0.5)
                } else {
                    Text("--")
                        .font(.system(size: 32, weight: .bold, design: .rounded))
                        .foregroundColor(.white.opacity(0.3))
                }
                
                if !unit.isEmpty {
                    Text(unit)
                        .font(.system(size: 12))
                        .foregroundColor(.secondary)
                }
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 24)
        .padding(.horizontal, 8)
        .background(Color(white: 0.12))
        .cornerRadius(20)
    }
}

#endif