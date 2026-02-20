import SwiftUI
import VitalLens
import VitalLensInference
#if canImport(UIKit)

public struct VitalLensScanView: View {
    
    private let apiKey: String?
    private let proxyURL: URL?
    private let method: VitalLens.Method
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
    ///   - method: The model version to use (default: .vitalLens).
    ///   - onComplete: Closure called with the final result upon success.
    public init(
        apiKey: String? = nil,
        proxyURL: URL? = nil,
        method: VitalLens.Method = .vitalLens,
        onComplete: @escaping (VitalLensResult) -> Void
    ) {
        self.apiKey = apiKey
        self.proxyURL = proxyURL
        self.method = method
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
        
        // Validation
        if apiKey == nil && proxyURL == nil {
            self.statusMessage = "Error: Missing API Key or Proxy URL"
            return
        }
        
        let newClient = VitalLens(apiKey: apiKey, method: method, proxyURL: proxyURL)
        self.client = newClient
        
        Task {
            do {
                let stream = try await newClient.startStream(preview: view)
                
                var startTime: Date?
                
                for await result in stream {
                    let hasFace = !(result.face.boundingBoxes.isEmpty)
                    
                    await MainActor.run {
                        self.faceDetected = hasFace
                        
                        if !isScanning && hasFace {
                            isScanning = true
                            startTime = Date()
                            statusMessage = "Measuring..."
                        }
                        
                        guard isScanning, let start = startTime else {
                            if !hasFace { statusMessage = "Face not detected" }
                            return
                        }
                        
                        let elapsed = Date().timeIntervalSince(start)
                        self.progress = min(elapsed / scanDuration, 1.0)
                        
                        if let hr = result.heartRate?.value {
                            self.currentHeartRate = Int(hr)
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