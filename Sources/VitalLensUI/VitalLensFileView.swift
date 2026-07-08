import SwiftUI
import UniformTypeIdentifiers
import PhotosUI
import CoreTransferable
import VitalLens
import VitalLensInference

#if canImport(UIKit)

/// Represents the current state of the file processing workflow.
public enum FileState {
    case idle
    case processing
    case completed
    case error
}

/// A helper struct to conform video file URLs to `Transferable` for use with `PhotosPicker`.
struct VideoFile: Transferable {
    let url: URL
    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(contentType: .movie) { movie in
            SentTransferredFile(movie.url)
        } importing: { received in
            let copy = FileManager.default.temporaryDirectory.appendingPathComponent(received.file.lastPathComponent)
            if FileManager.default.fileExists(atPath: copy.path) {
                try FileManager.default.removeItem(at: copy)
            }
            try FileManager.default.copyItem(at: received.file, to: copy)
            return VideoFile(url: copy)
        }
    }
}

/// A SwiftUI view that allows users to select a video file from their Photo Library or Files app,
/// processes it using the VitalLens API, and displays the resulting vital signs and waveforms.
public struct VitalLensFileView: View {
    private let apiKey: String?
    private let proxyURL: URL?
    private let method: String
    
    @State private var state: FileState = .idle
    @State private var showSourceSelector = false
    @State private var showFilePicker = false
    @State private var showPhotosPicker = false
    @State private var selectedPhotoItem: PhotosPickerItem? = nil
    
    @State private var finalResult: VitalLensResult?
    @State private var errorMessage: String = ""
    @State private var mode: VitalLensMode = .standard
    
    @State private var primaryVitals: [ResolvedVital] = []
    @State private var secondaryVitals: [ResolvedVital] = []

    @State private var scanStats = ScanStats(duration: 0, sampleCount: 0, avgFaceConf: 0)

    /// Initializes a new File View for batch processing video files.
    ///
    /// - Parameters:
    ///   - apiKey: Your VitalLens API Key. Defaults to `nil`.
    ///   - proxyURL: An optional URL to a custom backend proxy. Defaults to `nil`.
    ///   - method: The specific model or method to use for inference. Defaults to `"vitallens"`.
    public init(apiKey: String? = nil, proxyURL: URL? = nil, method: String = "vitallens") {
        self.apiKey = apiKey
        self.proxyURL = proxyURL
        self.method = method
    }

    public var body: some View {
        ZStack {
            Color(red: 0.06, green: 0.07, blue: 0.09).edgesIgnoringSafeArea(.all)
            
            switch state {
            case .idle:
                VitalLensStartView(
                    title: "VitalLens File Processing",
                    subtitle: "Estimate vital signs from\na video file",
                    timingHintLabel: "Processing time\ndepends on video.",
                    startButtonLabel: "Select Video File",
                    currentMode: $mode,
                    instruction1: ("person.crop.circle.fill", "Ensure one face is\nclearly visible."),
                    instruction2: ("pause.circle.fill", "Ensure the face\ndoes not move much."),
                    showModeToggle: false,
                    onStart: { showSourceSelector = true }
                )
            case .processing:
                VStack(spacing: 16) {
                    ProgressView().tint(.white)
                    Text("Processing video...").foregroundColor(.white)
                }
            case .completed:
                VitalLensResultView(
                    title: "Scan Complete",
                    primaryVitals: primaryVitals,
                    secondaryVitals: secondaryVitals,
                    ppgWaveform: finalResult?.ppg?.data.map(Double.init),
                    respWaveform: finalResult?.resp?.data.map(Double.init),
                    stats: scanStats,
                    onDone: { state = .idle }
                )
            case .error:
                VStack(spacing: 16) {
                    Text("Error").font(.headline).foregroundColor(.red)
                    Text(errorMessage).foregroundColor(.white).multilineTextAlignment(.center)
                    Button("Try Again") { state = .idle }
                        .buttonStyle(.borderedProminent)
                }.padding()
            }
        }
        .confirmationDialog("Choose Video Source", isPresented: $showSourceSelector) {
            Button("Photo Library") {
                showPhotosPicker = true
            }
            Button("Files") {
                showFilePicker = true
            }
            Button("Cancel", role: .cancel) {}
        }
        .fileImporter(isPresented: $showFilePicker, allowedContentTypes: [.movie, .video]) { result in
            switch result {
            case .success(let url):
                let secured = url.startAccessingSecurityScopedResource()
                process(url: url, isSecurityScoped: secured)
            case .failure(let error):
                errorMessage = error.localizedDescription
                state = .error
            }
        }
        .photosPicker(isPresented: $showPhotosPicker, selection: $selectedPhotoItem, matching: .videos)
        .onChange(of: selectedPhotoItem) { newItem in
            guard let newItem = newItem else { return }
            state = .processing
            Task {
                do {
                    if let videoFile = try await newItem.loadTransferable(type: VideoFile.self) {
                        process(url: videoFile.url, isSecurityScoped: false)
                    } else {
                        await MainActor.run {
                            errorMessage = "Could not load video from Photos."
                            state = .error
                        }
                    }
                } catch {
                    await MainActor.run {
                        errorMessage = error.localizedDescription
                        state = .error
                    }
                }
                selectedPhotoItem = nil
            }
        }
    }
    
    @ViewBuilder
    private var completedView: some View {
        VStack(spacing: 16) {
            HStack {
                Text("Scan Complete").font(.headline).foregroundColor(.white)
                Spacer()
                Button("Done") { state = .idle }
                    .foregroundColor(VitalInfoCache.brandBlue)
            }.padding(.top, 8)
            
            ScrollView {
                VStack(spacing: 16) {
                    if !primaryVitals.isEmpty {
                        HStack(spacing: 16) {
                            ForEach(primaryVitals) { vital in
                                ScanResultTile(vital: vital, showDetails: true)
                            }
                        }
                    }
                    
                    if !secondaryVitals.isEmpty {
                        HStack(spacing: 16) {
                            ForEach(secondaryVitals) { vital in
                                ScanResultTile(vital: vital, showDetails: true)
                            }
                        }
                    }
                    
                    if let ppg = finalResult?.ppg?.data {
                        WaveformContainer(vitalId: "ppg_waveform", history: ppg.map(Double.init), isReady: true)
                            .frame(height: 120)
                    }
                    
                    if let resp = finalResult?.resp?.data {
                        WaveformContainer(vitalId: "respiratory_waveform", history: resp.map(Double.init), isReady: true)
                            .frame(height: 120)
                    }
                }
            }
        }
        .padding(.horizontal, 24)
    }
    
    /// Processes the selected video file, managing security scopes and file cleanup.
    ///
    /// - Parameters:
    ///   - url: The local URL of the video file.
    ///   - isSecurityScoped: Whether the URL requires security-scoped access (e.g., from the Files app).
    private func process(url: URL, isSecurityScoped: Bool) {
        state = .processing
        Task {
            defer { 
                if isSecurityScoped { 
                    url.stopAccessingSecurityScopedResource() 
                } else {
                    try? FileManager.default.removeItem(at: url)
                }
            }
            
            let client = VitalLens(apiKey: apiKey, method: method, proxyURL: proxyURL, waveformMode: .global)
            
            do {
                let result = try await client.processVideoFile(at: url)
                await MainActor.run {
                    self.finalResult = result
                    self.parseVitals(from: result)
                    self.state = .completed
                }
            } catch {
                await MainActor.run {
                    self.errorMessage = error.localizedDescription
                    self.state = .error
                }
            }
        }
    }
    
    /// Parses the raw `VitalLensResult` to extract and format primary and secondary vital signs for the UI.
    ///
    /// - Parameter res: The raw result returned by the inference engine.
    private func parseVitals(from res: VitalLensResult) {
        let hrInfo = VitalInfoCache.getInfo(for: "heart_rate")
        let rrInfo = VitalInfoCache.getInfo(for: "respiratory_rate")
        
        self.primaryVitals = [
            ResolvedVital(id: "hr", title: hrInfo?.displayName ?? "Heart Rate", 
                          value: res.heartRate?.value, unit: hrInfo?.unit.uppercased() ?? "BPM", 
                          format: "%.0f", confidence: res.heartRate?.confidence, emoji: hrInfo?.emoji ?? "❤️"),
            ResolvedVital(id: "rr", title: rrInfo?.displayName ?? "Respiration", 
                          value: res.respiratoryRate?.value, unit: rrInfo?.unit.uppercased() ?? "RPM", 
                          format: "%.0f", confidence: res.respiratoryRate?.confidence, emoji: rrInfo?.emoji ?? "🫁")
        ].filter { $0.value != nil }
        
        self.secondaryVitals = [
            ("hrv_sdnn", res.hrvSdnn?.value, res.hrvSdnn?.confidence),
            ("hrv_rmssd", res.hrvRmssd?.value, res.hrvRmssd?.confidence),
            ("ie_ratio", res.vitals["ie_ratio"]?.value, res.vitals["ie_ratio"]?.confidence)
        ].compactMap { id, val, conf in
            guard let v = val, let m = VitalInfoCache.getInfo(for: id) else { return nil }
            return ResolvedVital(id: id, title: m.shortName, value: v, unit: m.unit.uppercased(), 
                                 format: (id == "ie_ratio" ? "%.2f" : "%.0f"), confidence: conf, emoji: m.emoji)
        }

        let fps = res.fps ?? mode.fps
        let count = res.sampleCount ?? res.time.count
        let duration = fps > 0 ? Double(count) / fps : 0
        let faceConfs = res.face.confidence ?? []
        let avgFaceConf = faceConfs.isEmpty ? 0.0 : faceConfs.reduce(0, +) / Double(faceConfs.count)
        
        self.scanStats = ScanStats(duration: duration, sampleCount: count, avgFaceConf: avgFaceConf)
    }
}

#endif