import SwiftUI
import VitalLensUI
internal import VitalLensInference

struct ContentView: View {
    let apiKey = ProcessInfo.processInfo.environment["VITALLENS_API_KEY"] ?? "YOUR_API_KEY_HERE"
    
    //  TODO: Support proxyUrl here
    var body: some View {
        if apiKey == "YOUR_API_KEY_HERE" || apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            MissingKeyView()
        } else {
            TabView {
                VitalLensMonitorView(apiKey: apiKey, showWaveforms: true)
                    .tabItem { Label("Monitor", systemImage: "waveform.path.ecg") }
                
                VitalLensScanView(apiKey: apiKey, method: "vitallens-2.0") { result in
                    print("✅ Scan complete! Final HR: \(result.heartRate?.value ?? 0)")
                }
                .tabItem { Label("Scan", systemImage: "face.dashed") }
            }
        }
    }
}

struct MissingKeyView: View {
    var body: some View {
        VStack(spacing: 20) {
            Image(systemName: "key.fill")
                .font(.system(size: 50))
                .foregroundColor(.orange)
            Text("API Key Missing")
                .font(.title2).bold()
            Text("Please open **ContentView.swift** and replace `YOUR_API_KEY_HERE` with your actual VitalLens API key.")
                .multilineTextAlignment(.center)
                .foregroundColor(.secondary)
            
            Link("Get an API Key", destination: URL(string: "https://www.rouast.com/api/")!)
                .buttonStyle(.borderedProminent)
        }
        .padding()
    }
}
