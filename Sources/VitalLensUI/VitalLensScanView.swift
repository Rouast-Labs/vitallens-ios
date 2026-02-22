import SwiftUI
import VitalLens
import VitalLensInference
#if canImport(UIKit)

public struct VitalLensScanView: View {
    
    private let apiKey: String?
    private let proxyURL: URL?
    private let method: String
    private let mode: VitalLensMode
    private let onComplete: (VitalLensResult) -> Void
    
    @State private var client: VitalLens?
    @State private var isScanning = false
    @State private var progress: Double = 0.0  
    @State private var currentHeartRate: Int = 0
    @State private var statusMessage: String = "Position your face in the oval"
    @State private var faceDetected = false
    
    private let scanDuration: TimeInterval = 30.0
    
    /// Initializes the Scan View.
    ///
    /// - Parameters:
    ///   - apiKey: Your VitalLens API Key (Optional if proxyURL is set).
    ///   - proxyURL: URL to your backend proxy (Optional if apiKey is set).
    ///   - method: The model version to use (default: "vitallens").
    ///   - mode: The performance mode (standard 30fps vs eco 15fps).
    ///   - onComplete: Closure called with the final result upon success.
    public init(
        apiKey: String? = nil,
        proxyURL: URL? = nil,
        method: String = "vitallens", // Explicit default
        mode: VitalLensMode = .standard,
        onComplete: @escaping (VitalLensResult) -> Void
    ) {
        self.apiKey = apiKey
        self.proxyURL = proxyURL
        self.method = method
        self.mode = mode
        self.onComplete = onComplete
    }
    
    public var body: some View {
        ZStack {
            Color.black.edgesIgnoringSafeArea(.all)
            
            CameraPreview { view in
                startSession(in: view)
            }
            .edgesIgnoringSafeArea(.all)
            
            VStack {
                Spacer()
                
                Text(statusMessage)
                    .font(.headline)
                    .foregroundColor(.white)
                    .padding(.top, 40)
                    .padding(.horizontal)
                    .multilineTextAlignment(.center)
                
                Spacer()
                
                ZStack {
                    Ellipse()
                        .strokeBorder(faceDetected ? Color.green : Color.white, lineWidth: 3)
                        .background(Color.black.opacity(0.01))
                        .frame(width: 250, height: 320)
                    
                    if isScanning {
                        Circle()
                            .trim(from: 0.0, to: CGFloat(progress))
                            .stroke(Color.green, style: StrokeStyle(lineWidth: 6, lineCap: .round))
                            .rotationEffect(.degrees(-90))
                            .frame(width: 340, height: 340)
                            .animation(.linear(duration: 0.1), value: progress)
                        
                        if currentHeartRate > 0 {
                            VStack {
                                Text("\(currentHeartRate)")
                                    .font(.system(size: 48, weight: .bold))
                                    .foregroundColor(.white)
                                Text("BPM")
                                    .font(.caption)
                                    .foregroundColor(.white.opacity(0.8))
                            }
                        }
                    }
                }
                
                Spacer()
                Spacer()
            }
        }
        .onDisappear {
            client?.stopStream()
        }
    }
    
    private func startSession(in view: UIView) {
        guard client == nil else { return }
        
        if apiKey == nil && proxyURL == nil {
            self.statusMessage = "Error: Missing API Key or Proxy URL"
            return
        }
        
        let newClient = VitalLens(
            apiKey: apiKey,
            method: method,
            proxyURL: proxyURL,
            overrideFps: mode.fps
        )
        
        // 1. Hook into the instantaneous SDK callback
        newClient.onFaceStateChanged = { @Sendable isPresent in
            Task { @MainActor in
                self.faceDetected = isPresent
                
                if !isPresent && self.isScanning {
                    // Punish movement: immediately kill the scan
                    self.isScanning = false
                    self.progress = 0.0
                    self.currentHeartRate = 0
                    self.statusMessage = "Face lost. Please reposition."
                } else if isPresent && !self.isScanning {
                    self.statusMessage = "Position your face in the oval"
                }
            }
        }
        
        self.client = newClient
        
        Task {
            do {
                let stream = try await newClient.startStream(preview: view)
                var startTime: Date?
                
                for await result in stream {
                    await MainActor.run {
                        // Ignore API stream results if our real-time callback knows the face is gone
                        if !self.faceDetected {
                            startTime = nil
                            return
                        }
                        
                        // Start tracking time
                        if !isScanning {
                            isScanning = true
                            startTime = Date()
                            statusMessage = "Measuring..."
                        }
                        
                        guard isScanning, let start = startTime else { return }
                        
                        let elapsed = Date().timeIntervalSince(start)
                        self.progress = min(elapsed / scanDuration, 1.0)
                        
                        // Only update HR if confidence is good
                        if let hr = result.heartRate, hr.confidence > 0.5 {
                            self.currentHeartRate = Int(hr.value)
                        }
                        
                        if elapsed >= scanDuration {
                            newClient.stopStream()
                            onComplete(result)
                        }
                    }
                }
            } catch {
                print("Scan Error: \(error)")
                await MainActor.run {
                    statusMessage = "Error: \(error.localizedDescription)"
                }
            }
        }
    }
}
#endif