import SwiftUI
import VitalLens
import VitalLensInference
import VitalLensCore

#if canImport(UIKit)

/// Defines the performance and accuracy profile for the inference engine.
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

/// Represents the current operational state of the live monitor.
enum MonitorState {
    case idle
    case searching
    case warmingUp
    case tracking
    case issue
}

/// A SwiftUI view that provides a real-time, continuous monitoring interface for vital signs.
/// It integrates a live camera feed and dynamically displays physiological estimates and waveforms.
public struct VitalLensMonitorView: View {
    
    private let apiKey: String?
    private let proxyURL: URL?
    private let method: String
    private let showWaveforms: Bool
    private let bufferOffset: TimeInterval
    private let windowSize: TimeInterval
    private let minDisplayDuration: TimeInterval
    
    @State private var currentMode: VitalLensMode = .eco
    private let initialMode: VitalLensMode

    @State private var client: VitalLens?
    @State private var isProcessing = false
    @State private var monitorState: MonitorState = .idle
    @State private var feedbackMessage: String = ""
    
    @State private var isFaceCurrentlyDetected = false
    
    @State private var hrValue: Double?
    @State private var hrConf: Double = 0.0
    @State private var rrValue: Double?
    @State private var rrConf: Double = 0.0
    @State private var sdnnValue: Double?
    @State private var sdnnConf: Double = 0.0
    @State private var rmssdValue: Double?
    @State private var rmssdConf: Double = 0.0
    @State private var ieRatioValue: Double?
    @State private var ieRatioConf: Double = 0.0
    
    @State private var ppgHistory: [Double] = []
    @State private var ppgConf: Double = 0.0
    @State private var ppgConfHistory: [Double] = []
    @State private var respHistory: [Double] = []
    @State private var respConfHistory: [Double] = []
    @State private var respConf: Double = 0.0

    @State private var receivedVitals: Set<String> = []

    @State private var showDebug: Bool = false
    @State private var debugImage: UIImage? = nil
    @State private var debugROI: CGRect? = nil

    private var maxHistoryPoints: Int {
        return Int(windowSize * currentMode.fps)
    }
    
    private var requiredSamplesForDisplay: Int {
        return Int(minDisplayDuration * currentMode.fps)
    }
    
    private var hasSecondaryVitals: Bool {
        !receivedVitals.isDisjoint(with: ["hrv_sdnn", "hrv_rmssd", "ie_ratio"])
    }

    private var dynamicTileWidth: CGFloat? {
        guard showWaveforms else { return nil }
        return hasSecondaryVitals ? 170 : 110
    }

    struct BufferedPoint {
        let value: Double
        let confidence: Double
        let displayTime: TimeInterval
    }
    @State private var ppgQueue: [BufferedPoint] = []
    @State private var respQueue: [BufferedPoint] = []
    @State private var timeAnchor: (videoTime: TimeInterval, realTime: TimeInterval)? = nil
    @State private var playbackTask: Task<Void, Never>? = nil
    
    private let vitalConfThreshold = 0.8
    private let hrvConfThreshold = 0.7
    private let faceConfThreshold = 0.5
    
    /// Initializes a new Monitor View for real-time vital sign estimation.
    ///
    /// - Parameters:
    ///   - apiKey: Your VitalLens API Key. Defaults to `nil`.
    ///   - proxyURL: An optional URL to a custom backend proxy. Defaults to `nil`.
    ///   - method: The specific model or method to use for inference. Defaults to `"vitallens"`.
    ///   - showWaveforms: Whether to render real-time waveforms on the UI. Defaults to `true`.
    ///   - initialMode: The starting performance mode. Defaults to `.eco`.
    ///   - bufferOffset: The delay in seconds applied to the waveform to ensure smooth rendering. Defaults to `0.15`.
    ///   - windowSize: The duration of the history to retain for waveform rendering. Defaults to `8.0`.
    ///   - minDisplayDuration: The minimum data accumulation time required before displaying results. Defaults to `6.0`.
    public init(
        apiKey: String? = nil,
        proxyURL: URL? = nil,
        method: String = "vitallens",
        showWaveforms: Bool = true,
        initialMode: VitalLensMode = .eco,
        bufferOffset: TimeInterval = 0.15,
        windowSize: TimeInterval = 8.0,
        minDisplayDuration: TimeInterval = 6.0 
    ) {
        self.apiKey = apiKey
        self.proxyURL = proxyURL
        self.method = method
        self.showWaveforms = showWaveforms
        self.bufferOffset = bufferOffset
        self.windowSize = windowSize
        self.minDisplayDuration = minDisplayDuration
        self.initialMode = initialMode        
    }
    
    private var hasEnoughData: Bool { ppgHistory.count >= requiredSamplesForDisplay }
    
    private var isHrReady: Bool { hrValue != nil && hrConf >= vitalConfThreshold }
    private var isRrReady: Bool { rrValue != nil && rrConf >= vitalConfThreshold }
    private var isSdnnReady: Bool { sdnnValue != nil && sdnnConf >= hrvConfThreshold }
    private var isRmssdReady: Bool { rmssdValue != nil && rmssdConf >= hrvConfThreshold }
    private var isIeReady: Bool { ieRatioValue != nil && ieRatioConf >= vitalConfThreshold }
    private var isPpgReady: Bool { 
        let avgConf = ppgConfHistory.isEmpty ? 0.0 : ppgConfHistory.reduce(0, +) / Double(ppgConfHistory.count)
        return avgConf >= vitalConfThreshold && hasEnoughData 
    }
    private var isRespReady: Bool { 
        let avgConf = respConfHistory.isEmpty ? 0.0 : respConfHistory.reduce(0, +) / Double(respConfHistory.count)
        return avgConf >= vitalConfThreshold && hasEnoughData 
    }
    
    private var dynamicMessage: String {
        if !feedbackMessage.isEmpty { return feedbackMessage }
        if monitorState == .warmingUp {
            let progress = min(100, Int((Double(ppgHistory.count) / Double(requiredSamplesForDisplay)) * 100))
            return "Calibrating signals... (\(progress)%)"
        }
        return ""
    }
    
    public var body: some View {
        ZStack {
            cameraLayer
            
            if monitorState == .idle {
                idleOverlayLayer
            } else {
                VStack(spacing: 0) {
                    topBarLayer
                    Spacer()
                    middleGapLayer
                    bottomMetricsLayer
                }
            }
        }
        .overlay(alignment: .topTrailing) {
            if showDebug, let img = debugImage {
                VStack {
                    Image(uiImage: img)
                        .resizable()
                        .frame(width: 80, height: 80)
                        .border(Color.red, width: 2)
                    Text("API INPUT")
                        .font(.caption2)
                        .background(Color.black)
                }
                .padding(.top, 100)
                .padding(.trailing, 20)
            }
        }
        .onReceive(Timer.publish(every: 0.1, on: .main, in: .common).autoconnect()) { _ in
            guard showDebug else { return }
            if let cgImg = client?.debugLatestCrop {
                self.debugImage = UIImage(cgImage: cgImg)
            }
        }
        .onAppear { self.currentMode = self.initialMode }
        .onDisappear { stopProcessing() }
    }
    
    @ViewBuilder
    private var cameraLayer: some View {
        if isProcessing {
            CameraPreview { view in
                startSession(in: view)
            }
            .edgesIgnoringSafeArea(.all)
            .overlay(
                GeometryReader { geo in
                    if showDebug, let roi = debugROI {
                        Rectangle()
                            .stroke(Color.yellow, lineWidth: 3)
                            .frame(
                                width: roi.width * geo.size.width,
                                height: roi.height * geo.size.height
                            )
                            .offset(
                                x: roi.minX * geo.size.width,
                                y: roi.minY * geo.size.height
                            )
                            .animation(.linear(duration: 0.1), value: roi)
                    }
                }
            )
        } else {
            Color.black.edgesIgnoringSafeArea(.all)
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
                .onTapGesture(count: 2) {
                    showDebug.toggle()
                }
                
                Spacer()
                
                if isProcessing {
                    Button(action: {
                        stopProcessing()
                    }) {
                        Image(systemName: "xmark.circle.fill")
                            .font(.title)
                            .symbolRenderingMode(.hierarchical)
                            .foregroundColor(.white)
                            .padding(.leading, 8)
                    }
                }
            }
            
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
        VStack(spacing: 12) {
            
            if !dynamicMessage.isEmpty {
                Text(dynamicMessage)
                    .font(.footnote)
                    .fontWeight(.medium)
                    .foregroundColor(.white)  
                    .multilineTextAlignment(.center)
                    .padding(.horizontal)
            }
            
            HStack(spacing: 12) {
                if showWaveforms {
                    WaveformContainer(vitalId: "ppg_waveform", history: ppgHistory, isReady: isPpgReady)
                }
                
                GroupedMetricsTile(
                    primaryId: "heart_rate", primaryValue: hrValue, isPrimaryReady: isHrReady,
                    secondary1Id: receivedVitals.contains("hrv_sdnn") ? "hrv_sdnn" : nil, secondary1Value: sdnnValue, isSecondary1Ready: isSdnnReady,
                    secondary2Id: receivedVitals.contains("hrv_rmssd") ? "hrv_rmssd" : nil, secondary2Value: rmssdValue, isSecondary2Ready: isRmssdReady
                )
                .frame(width: dynamicTileWidth)
                .frame(maxWidth: showWaveforms ? nil : .infinity)
            }
            .frame(height: 90)
            .padding(.horizontal)
            
            HStack(spacing: 12) {
                if showWaveforms {
                    WaveformContainer(vitalId: "respiratory_waveform", history: respHistory, isReady: isRespReady)
                }
                
                GroupedMetricsTile(
                    primaryId: "respiratory_rate", primaryValue: rrValue, isPrimaryReady: isRrReady,
                    secondary1Id: receivedVitals.contains("ie_ratio") ? "ie_ratio" : nil, secondary1Value: ieRatioValue, isSecondary1Ready: isIeReady,
                    secondary2Id: nil, secondary2Value: nil, isSecondary2Ready: false
                )
                .frame(width: dynamicTileWidth)
                .frame(maxWidth: showWaveforms ? nil : .infinity)
            }
            .frame(height: 90)
            .padding(.horizontal)
        }
        .padding(.top, 12)
        .padding(.bottom, 24)
        .background(
            Rectangle()
                .fill(.ultraThinMaterial)
                .edgesIgnoringSafeArea(.bottom)
        )
    }
    
    @ViewBuilder
    private var idleOverlayLayer: some View {
        VitalLensStartView(
            title: "VitalLens Vitals Monitor",
            subtitle: "Estimate your vital signs using\nonly your camera",
            timingHintLabel: "Scan runs\ncontinuously.",
            startButtonLabel: "Start Monitor",
            currentMode: $currentMode,
            onStart: { startProcessing() }
        )
    }
    
    private func startProcessing() {
        isProcessing = true
        monitorState = .searching
        feedbackMessage = "Face the camera, ensure good lighting and hold still."
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
        ieRatioValue = nil; ieRatioConf = 0.0
        
        ppgHistory.removeAll(); ppgQueue.removeAll(); ppgConf = 0.0
        respHistory.removeAll(); respQueue.removeAll(); respConf = 0.0
        ppgConfHistory.removeAll()
        respConfHistory.removeAll()
        timeAnchor = nil
        receivedVitals.removeAll()
    }
    
    private func resetUI() {
        clearMeasurements()
        isFaceCurrentlyDetected = false
    }
    
    private func startSession(in view: UIView) {
        guard client == nil, isProcessing else { return }
        
        let newClient = VitalLens(
            apiKey: apiKey,
            method: method,
            proxyURL: proxyURL,
            overrideFps: currentMode.fps,
            waveformMode: .incremental,
            debugMode: showDebug
        )
        
        newClient.onFaceStateChanged = { @Sendable isPresent in
            Task { @MainActor in
                guard self.isProcessing else { return } 
                
                self.isFaceCurrentlyDetected = isPresent
                if !isPresent {
                    self.monitorState = .issue
                    self.feedbackMessage = "Check Position: Face the camera and hold still."
                    self.client?.resetStream()
                    self.clearMeasurements()
                } else if self.monitorState == .issue || self.monitorState == .idle {
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
                    updateUI(with: result)
                }
            } catch {
                await MainActor.run { stopProcessing() }
            }
        }
    }
    
    @MainActor
    private func updateUI(with result: VitalLensResult) {
        guard isProcessing, isFaceCurrentlyDetected else { return }

        self.debugROI = result.face.boundingBoxes.last

        for key in result.vitals.keys {
            receivedVitals.insert(key)
        }
        
        let faceConfs = result.face.confidence ?? []
        let currentFaceConf = faceConfs.isEmpty ? 0.0 : faceConfs.last!
        
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
        if let ie = result.vitals["ie_ratio"] { ieRatioValue = ie.value; ieRatioConf = ie.confidence }
        
        let hasConfidentHr = hrConf >= vitalConfThreshold
        let hasConfidentRr = rrConf >= vitalConfThreshold
        let hasConfidentHrv = sdnnConf >= hrvConfThreshold || rmssdConf >= hrvConfThreshold
        
        if !(hasConfidentHr || hasConfidentRr || hasConfidentHrv) {
            monitorState = .issue
            feedbackMessage = "Low confidence. Ensure you are well lit and hold still."
        } else if showWaveforms && !hasEnoughData {
            monitorState = .warmingUp
            feedbackMessage = "" 
        } else {
            monitorState = .tracking
            feedbackMessage = "Tracking vitals"
        }
        
        if !ppgConfHistory.isEmpty {
            ppgConf = ppgConfHistory.reduce(0, +) / Double(ppgConfHistory.count)
        }
        
        if !respConfHistory.isEmpty {
            respConf = respConfHistory.reduce(0, +) / Double(respConfHistory.count)
        }
    }
    
    @MainActor
    private func queueWaveformData(result: VitalLensResult) {
        let ppgChunk = result.ppg?.data ?? []
        let ppgConfs = result.ppg?.confidence ?? []
        let respChunk = result.resp?.data ?? []
        let respConfs = result.resp?.confidence ?? []
        guard !ppgChunk.isEmpty || !respChunk.isEmpty else { return }
        
        if bufferOffset > 0 {
            if timeAnchor == nil, let firstTime = result.time.first {
                timeAnchor = (videoTime: firstTime, realTime: CACurrentMediaTime())
            }
            
            if let anchor = timeAnchor {
                for (index, time) in result.time.enumerated() {
                    let targetDisplayTime = anchor.realTime + (time - anchor.videoTime) + bufferOffset
                    
                    if index < ppgChunk.count {
                        let conf = Double(index < ppgConfs.count ? ppgConfs[index] : (ppgConfs.last ?? 0))
                        ppgQueue.append(BufferedPoint(value: Double(ppgChunk[index]), confidence: conf, displayTime: targetDisplayTime))
                    }
                    if index < respChunk.count {
                        let conf = Double(index < respConfs.count ? respConfs[index] : (respConfs.last ?? 0))
                        respQueue.append(BufferedPoint(value: Double(respChunk[index]), confidence: conf, displayTime: targetDisplayTime))
                    }
                }
            }
        } else {
            self.ppgHistory.append(contentsOf: ppgChunk.map { Double($0) })
            self.ppgConfHistory.append(contentsOf: ppgConfs.map { Double($0) })
            
            if self.ppgHistory.count > maxHistoryPoints { 
                self.ppgHistory.removeFirst(self.ppgHistory.count - maxHistoryPoints) 
                self.ppgConfHistory.removeFirst(self.ppgConfHistory.count - maxHistoryPoints)
            }
            
            self.respHistory.append(contentsOf: respChunk.map { Double($0) })
            self.respConfHistory.append(contentsOf: respConfs.map { Double($0) })
            
            if self.respHistory.count > maxHistoryPoints { 
                self.respHistory.removeFirst(self.respHistory.count - maxHistoryPoints) 
                self.respConfHistory.removeFirst(self.respConfHistory.count - maxHistoryPoints)
            }
        }
    }
    
    @MainActor
    private func runPlaybackLoop() async {
        while !Task.isCancelled {
            let now = CACurrentMediaTime()
            
            var newPpgVals: [Double] = []
            var newPpgConfs: [Double] = []
            while let first = ppgQueue.first, now >= first.displayTime {
                newPpgVals.append(first.value)
                newPpgConfs.append(first.confidence)
                ppgQueue.removeFirst()
            }
            if !newPpgVals.isEmpty {
                ppgHistory.append(contentsOf: newPpgVals)
                ppgConfHistory.append(contentsOf: newPpgConfs)
                if ppgHistory.count > maxHistoryPoints {
                    ppgHistory.removeFirst(ppgHistory.count - maxHistoryPoints)
                    ppgConfHistory.removeFirst(ppgConfHistory.count - maxHistoryPoints)
                }
            }

            var newRespVals: [Double] = []
            var newRespConfs: [Double] = []
            while let first = respQueue.first, now >= first.displayTime {
                newRespVals.append(first.value)
                newRespConfs.append(first.confidence)
                respQueue.removeFirst()
            }
            if !newRespVals.isEmpty {
                respHistory.append(contentsOf: newRespVals)
                respConfHistory.append(contentsOf: newRespConfs)
                if respHistory.count > maxHistoryPoints {
                    respHistory.removeFirst(respHistory.count - maxHistoryPoints)
                    respConfHistory.removeFirst(respConfHistory.count - maxHistoryPoints)
                }
            }
            
            try? await Task.sleep(nanoseconds: 16_666_666)
        }
    }
}

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
        case .searching: return VitalInfoCache.brandBlue
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

struct GroupedMetricsTile: View {
    let primaryValue: Double?
    let isPrimaryReady: Bool
    let secondary1Value: Double?
    let isSecondary1Ready: Bool
    let secondary2Value: Double?
    let isSecondary2Ready: Bool
    
    let pTitle: String
    let pUnit: String
    let s1Title: String
    let s1Unit: String
    let s2Title: String
    let s2Unit: String
    let hasSec1: Bool
    let hasSec2: Bool
    let pFormat: String
    let s1Format: String
    let s2Format: String
    
    init(
        primaryId: String, primaryValue: Double?, isPrimaryReady: Bool,
        secondary1Id: String?, secondary1Value: Double?, isSecondary1Ready: Bool,
        secondary2Id: String?, secondary2Value: Double?, isSecondary2Ready: Bool
    ) {
        self.primaryValue = primaryValue
        self.isPrimaryReady = isPrimaryReady
        self.secondary1Value = secondary1Value
        self.isSecondary1Ready = isSecondary1Ready
        self.secondary2Value = secondary2Value
        self.isSecondary2Ready = isSecondary2Ready
        
        func format(for id: String?) -> String {
            guard let id = id else { return "%.0f" }
            return (id == "ie_ratio" || id == "hrv_lfhf") ? "%.2f" : "%.0f"
        }

        self.pFormat = format(for: primaryId)
        self.s1Format = format(for: secondary1Id)
        self.s2Format = format(for: secondary2Id)

        let pInfo = VitalInfoCache.getInfo(for: primaryId)
        self.pTitle = pInfo?.shortName ?? primaryId
        self.pUnit = pInfo?.unit.uppercased() ?? ""
        
        self.hasSec1 = secondary1Id != nil
        if let s1 = secondary1Id {
            let m = VitalInfoCache.getInfo(for: s1)
            self.s1Title = m?.shortName ?? s1
            self.s1Unit = m?.unit.uppercased() ?? ""
        } else { self.s1Title = ""; self.s1Unit = "" }
        
        self.hasSec2 = secondary2Id != nil
        if let s2 = secondary2Id {
            let m = VitalInfoCache.getInfo(for: s2)
            self.s2Title = m?.shortName ?? s2
            self.s2Unit = m?.unit.uppercased() ?? ""
        } else { self.s2Title = ""; self.s2Unit = "" }
    }
    
    var body: some View {
        HStack(alignment: .center, spacing: 16) {
            
            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    Text(pTitle)
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(.secondary)
                    
                    if !pUnit.isEmpty {
                        Text(pUnit)
                            .font(.system(size: 8, weight: .regular))
                            .foregroundStyle(.secondary.opacity(0.6))  
                    }
                }
                
                if isPrimaryReady, let val = primaryValue {
                    Text(String(format: pFormat, val))
                        .font(.system(size: 32, weight: .bold, design: .rounded)) 
                        .monospacedDigit()
                        .foregroundColor(.primary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.4)
                } else {
                    Text("--")
                        .font(.system(size: 32, weight: .bold, design: .rounded))
                        .foregroundColor(.secondary.opacity(0.3))
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.leading, 12)
            
            if hasSec1 || hasSec2 {
                VStack(alignment: .leading, spacing: 8) { 
                    
                    if hasSec1 {
                        VStack(alignment: .leading, spacing: 2) {
                            HStack(alignment: .firstTextBaseline, spacing: 3) {
                                Text(s1Title)
                                    .font(.system(size: 9, weight: .medium))
                                    .foregroundStyle(.secondary)
                                
                                if !s1Unit.isEmpty {
                                    Text(s1Unit)
                                        .font(.system(size: 7, weight: .regular))
                                        .foregroundStyle(.secondary.opacity(0.6))
                                }
                            }
                            
                            if isSecondary1Ready, let val = secondary1Value {
                                Text(String(format: s1Format, val))
                                    .font(.system(size: 14, weight: .bold, design: .rounded))
                                    .monospacedDigit()
                                    .foregroundColor(.primary)
                                    .lineLimit(1)
                                    .minimumScaleFactor(0.6)
                            } else {
                                Text("--")
                                    .font(.system(size: 14, weight: .bold, design: .rounded))
                                    .foregroundColor(.secondary.opacity(0.3))
                            }
                        }
                    }
                    
                    if hasSec2 {
                        VStack(alignment: .leading, spacing: 2) {
                            HStack(alignment: .firstTextBaseline, spacing: 3) {
                                Text(s2Title)
                                    .font(.system(size: 9, weight: .medium))
                                    .foregroundStyle(.secondary)
                                
                                if !s2Unit.isEmpty {
                                    Text(s2Unit)
                                        .font(.system(size: 7, weight: .regular))
                                        .foregroundStyle(.secondary.opacity(0.6))
                                }
                            }
                            
                            if isSecondary2Ready, let val = secondary2Value {
                                Text(String(format: s2Format, val))
                                    .font(.system(size: 14, weight: .bold, design: .rounded))
                                    .monospacedDigit()
                                    .foregroundColor(.primary)
                                    .lineLimit(1)
                                    .minimumScaleFactor(0.6)
                            } else {
                                Text("--")
                                    .font(.system(size: 14, weight: .bold, design: .rounded))
                                    .foregroundColor(.secondary.opacity(0.3))
                            }
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.trailing, 8)
            }
        }
        .padding(.vertical, 12)
        .frame(maxHeight: .infinity)
        .background(Color(UIColor.secondarySystemBackground))
        .cornerRadius(12) 
    }
}

#endif