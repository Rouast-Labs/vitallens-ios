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
    
    // TODO: Fix up the oval loading bar alignment with cutout
    @ViewBuilder
    private var scanUILayer: some View {
        ZStack {
            Color.black.edgesIgnoringSafeArea(.all)
            
            CameraPreview { view in
                startSession(in: view)
            }
            .edgesIgnoringSafeArea(.all)
            
            CutoutOverlay()
            
            VStack {
                topBarLayer
                Spacer()
                
                ZStack {
                    Ellipse()
                        .stroke(Color.white.opacity(0.3), lineWidth: 3)
                        .frame(width: 250, height: 350)
                    
                    if scanState == .tracking || scanState == .recovering || scanState == .warmingUp {
                        Ellipse()
                            .trim(from: 0.0, to: CGFloat(progress))
                            .stroke(VitalMetadataCache.brandBlue, style: StrokeStyle(lineWidth: 6, lineCap: .round))
                            .rotationEffect(.degrees(-90))
                            .frame(width: 250, height: 350)
                            .animation(.linear(duration: 0.2), value: progress)
                    }
                }
                
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
        }
    }
    
    private var topBarLayer: some View {
        HStack {
            Image("vitallens_logo", bundle: .module)
                .resizable()
                .scaledToFit()
                .frame(width: 32, height: 32)
                .background(Color.white)
                .clipShape(RoundedRectangle(cornerRadius: 8))
            
            Spacer()
            
            ScanStatusBadge(state: scanState)
            
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
        .padding(.horizontal)
        .padding(.top, 8)
    }
    
    @ViewBuilder
    private var resultOverlay: some View {
        if let res = finalResult {
            ZStack {
                Color(red: 0.08, green: 0.09, blue: 0.11).edgesIgnoringSafeArea(.all)
                
                VStack(spacing: 0) {
                    HStack(spacing: 12) {
                        Image("vitallens_logo", bundle: .module)
                            .resizable()
                            .scaledToFit()
                            .frame(width: 32, height: 32)
                            .background(Color.white)
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                        Text("VitalLens Vitals Scan")
                            .font(.headline)
                            .foregroundColor(.white)
                        Spacer()
                    }
                    .padding(.bottom, 32)
                    
                    HStack(spacing: 16) {
                        ScanResultTile(title: "HEART RATE", value: res.heartRate?.value, unit: "bpm", format: "%.0f")
                        ScanResultTile(title: "RESPIRATION", value: res.respiratoryRate?.value, unit: "rpm", format: "%.0f")
                    }
                    
                    Divider().background(Color(white: 0.3)).padding(.vertical, 24)
                    
                    HStack(spacing: 16) {
                        ScanResultTile(title: "HRV (SDNN)", value: res.hrvSdnn?.value, unit: "ms", format: "%.0f")
                        ScanResultTile(title: "HRV (RMSSD)", value: res.hrvRmssd?.value, unit: "ms", format: "%.0f")
                    }
                    
                    HStack(spacing: 16) {
                        Button(action: { resetToIdle() }) {
                            Text("Scan Again")
                                .font(.subheadline)
                                .foregroundColor(.white)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 14)
                                .background(Color(white: 0.1))
                                .cornerRadius(12)
                                .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color(white: 0.2), lineWidth: 1))
                        }
                        Button(action: { resetToIdle() }) {
                            Text("View Details")
                                .font(.subheadline)
                                .foregroundColor(.white)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 14)
                                .background(Color(white: 0.1))
                                .cornerRadius(12)
                                .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color(white: 0.2), lineWidth: 1))
                        }
                    }
                    .padding(.top, 32)
                }
                .padding(32)
                .background(Color(red: 0.12, green: 0.13, blue: 0.14))
                .cornerRadius(24)
                .padding(.horizontal, 16)
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
                .frame(width: 250, height: 350)
                .blendMode(.destinationOut)
        }
        .compositingGroup()
        .edgesIgnoringSafeArea(.all)
    }
}


// TODO: Only show each result if confidence was high enough
// TODO: Re-design similar to monitor view
// TODO: Pull name, unit etc. from core like monitor view
struct ScanResultTile: View {
    let title: String
    let value: Double?
    let unit: String
    let format: String
    
    var body: some View {
        VStack(spacing: 8) {
            Text(title)
                .font(.system(size: 10, weight: .semibold))
                .foregroundColor(.secondary)
                
            HStack(alignment: .firstTextBaseline, spacing: 2) {
                if let val = value {
                    Text(String(format: format, val))
                        .font(.system(size: 28, weight: .bold, design: .rounded))
                        .foregroundColor(.white)
                } else {
                    Text("--")
                        .font(.system(size: 28, weight: .bold, design: .rounded))
                        .foregroundColor(.white.opacity(0.5))
                }
                Text(unit)
                    .font(.system(size: 12))
                    .foregroundColor(.secondary)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 20)
        .background(Color(white: 0.16))
        .cornerRadius(16)
    }
}

#endif