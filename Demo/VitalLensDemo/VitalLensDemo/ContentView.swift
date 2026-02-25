import SwiftUI
import VitalLensUI
internal import VitalLensInference

struct ContentView: View {
    let apiKey = ProcessInfo.processInfo.environment["VITALLENS_API_KEY"] ?? "YOUR_API_KEY_HERE"
    let proxyUrlString = ProcessInfo.processInfo.environment["VITALLENS_PROXY_URL"] ?? ""
    
    var proxyURL: URL? {
        URL(string: proxyUrlString)
    }
    
    var hasValidAuth: Bool {
        let hasKey = apiKey != "YOUR_API_KEY_HERE" && !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let hasProxy = proxyURL != nil
        return hasKey || hasProxy
    }
    
    var body: some View {
        if !hasValidAuth {
            MissingKeyView()
        } else {
            TabView {
                VitalLensMonitorView(apiKey: apiKey, proxyURL: proxyURL, showWaveforms: true)
                    .tabItem { Label("Monitor", systemImage: "waveform.path.ecg") }
                
                VitalLensScanView(apiKey: apiKey, proxyURL: proxyURL) { result in
                    print("✅ Scan complete! Final HR: \(result.heartRate?.value ?? 0)")
                }
                .tabItem { Label("Scan", systemImage: "face.dashed") }
                
                VitalLensFileView(apiKey: apiKey, proxyURL: proxyURL)
                    .tabItem { Label("File", systemImage: "folder") }
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
            Text("Authentication Missing")
                .font(.title2).bold()
            Text("Please open **ContentView.swift** and replace `YOUR_API_KEY_HERE` with your actual API key, or provide a valid Proxy URL.")
                .multilineTextAlignment(.center)
                .foregroundColor(.secondary)
            
            Link("Get an API Key", destination: URL(string: "https://www.rouast.com/api/")!)
                .buttonStyle(.borderedProminent)
        }
        .padding()
    }
}
