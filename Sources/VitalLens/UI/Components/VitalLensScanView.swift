import SwiftUI

public struct VitalLensScanView: View {
    
    // Configuration
    private let apiKey: String
    private let method: VitalLens.Method
    private let onComplete: (VitalLensResult) -> Void
    
    // State
    @State private var client: VitalLens?
    @State private var isScanning = false
    @State private var progress: Double = 0.0 // 0.0 to 1.0
    @State private var currentHeartRate: Int = 0
    @State private var statusMessage: String = "Position your face in the oval"
    @State private var faceDetected = false
    
    // Constants
    private let scanDuration: TimeInterval = 30.0
    
    public init(
        apiKey: String,
        method: VitalLens.Method = .vitalLens,
        onComplete: @escaping (VitalLensResult) -> Void
    ) {
        self.apiKey = apiKey
        self.method = method
        self.onComplete = onComplete
    }
    
    public var body: some View {
        ZStack {
            Color.black.edgesIgnoringSafeArea(.all)
            
            // 1. Camera Layer
            CameraPreview { view in
                startSession(in: view)
            }
            .edgesIgnoringSafeArea(.all)
            
            // 2. UI Overlay
            VStack {
                Spacer()
                
                // Status Text
                Text(statusMessage)
                    .font(.headline)
                    .foregroundColor(.white)
                    .padding(.top, 40)
                    .padding(.horizontal)
                    .multilineTextAlignment(.center)
                
                Spacer()
                
                // Face Guide Oval & Progress
                ZStack {
                    // Guide Oval
                    Ellipse()
                        .strokeBorder(faceDetected ? Color.green : Color.white, lineWidth: 3)
                        .background(Color.black.opacity(0.01)) // Hit test
                        .frame(width: 250, height: 320)
                    
                    // Progress Ring
                    if isScanning {
                        Circle()
                            .trim(from: 0.0, to: CGFloat(progress))
                            .stroke(Color.green, style: StrokeStyle(lineWidth: 6, lineCap: .round))
                            .rotationEffect(.degrees(-90))
                            .frame(width: 340, height: 340)
                            .animation(.linear(duration: 0.1), value: progress)
                        
                        // Live HR
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
        
        let newClient = VitalLens(apiKey: apiKey, method: method)
        self.client = newClient
        
        Task {
            do {
                let stream = try await newClient.startStream(preview: view)
                
                var startTime: Date?
                
                for await result in stream {
                    // Update Face Status
                    let hasFace = !(result.face.boundingBoxes.isEmpty)
                    
                    await MainActor.run {
                        self.faceDetected = hasFace
                        
                        if !isScanning && hasFace {
                            // Start Scan Logic
                            isScanning = true
                            startTime = Date()
                            statusMessage = "Measuring..."
                        }
                        
                        guard isScanning, let start = startTime else {
                            if !hasFace { statusMessage = "Face not detected" }
                            return
                        }
                        
                        // Update Progress
                        let elapsed = Date().timeIntervalSince(start)
                        self.progress = min(elapsed / scanDuration, 1.0)
                        
                        // Update Live Vitals
                        if let hr = result.vitalSigns.heartRate?.value {
                            self.currentHeartRate = Int(hr)
                        }
                        
                        // Check Completion
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