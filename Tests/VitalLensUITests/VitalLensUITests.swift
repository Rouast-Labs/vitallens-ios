import XCTest
import SwiftUI
@testable import VitalLens
@testable import VitalLensUI
@testable import VitalLensInference

#if canImport(UIKit)
@MainActor
final class VitalLensUITests: XCTestCase {
    
    // MARK: - Scan View Tests
    
    func testScanView_InitWithAPIKey() {
        let view = VitalLensScanView(
            apiKey: "test_key",
            method: "vitallens-2.0",
            onComplete: { _ in }
        )
        
        XCTAssertNotNil(view.body)
    }
    
    func testScanView_InitWithProxy() {
        let url = URL(string: "https://my-proxy.com")!
        let view = VitalLensScanView(
            proxyURL: url,
            method: "vitallens-2.0",
            onComplete: { _ in }
        )
        
        XCTAssertNotNil(view.body)
    }
    
    func testScanView_InitWithBoth() {
        let url = URL(string: "https://my-proxy.com")!
        let view = VitalLensScanView(
            apiKey: "test_key",
            proxyURL: url,
            onComplete: { _ in }
        )
        
        XCTAssertNotNil(view.body)
    }
    
    // MARK: - Monitor View Tests
    
    func testMonitorView_InitWithAPIKey() {
        let view = VitalLensMonitorView(
            apiKey: "test_key",
            showWaveforms: true
        )
        
        XCTAssertNotNil(view.body)
    }
    
    func testMonitorView_InitWithProxy() {
        let url = URL(string: "https://my-proxy.com")!
        let view = VitalLensMonitorView(
            proxyURL: url,
            showWaveforms: false
        )
        
        XCTAssertNotNil(view.body)
    }
    
    func testMonitorView_DefaultParams() {
        let view = VitalLensMonitorView(apiKey: "key")
        XCTAssertNotNil(view.body)
    }

    // MARK: - File View Tests
    
    func testFileView_Init() {
        let view = VitalLensFileView(apiKey: "test_key")
        XCTAssertNotNil(view.body)
    }

    func testFileView_InitWithProxy() {
        let url = URL(string: "https://my-proxy.com")!
        let view = VitalLensFileView(proxyURL: url)
        XCTAssertNotNil(view.body)
    }

    // MARK: - Shared Component Tests

    func testStartView_Init() {
        var mode = VitalLensMode.eco
        let binding = Binding(get: { mode }, set: { mode = $0 })
        
        let view = VitalLensStartView(
            title: "Test Start",
            subtitle: "Test Subtitle",
            timingHintLabel: "Hint",
            startButtonLabel: "Start",
            currentMode: binding,
            instruction1: ("star", "Star text"),
            instruction2: ("heart", "Heart text"),
            showModeToggle: false,
            onStart: {}
        )
        
        XCTAssertNotNil(view.body)
        XCTAssertEqual(view.title, "Test Start")
        XCTAssertFalse(view.showModeToggle)
    }

    func testResultView_Init() {
        let stats = ScanStats(duration: 10.0, sampleCount: 300, avgFaceConf: 0.95)
        
        let primaryVitals = [
            ResolvedVital(id: "hr", title: "HR", value: 65, unit: "BPM", format: "%.0f", confidence: 0.9, emoji: "❤️")
        ]
        
        let view = VitalLensResultView(
            title: "Test Complete",
            primaryVitals: primaryVitals,
            secondaryVitals: [],
            ppgWaveform: [0.1, 0.2, 0.3],
            respWaveform: nil,
            stats: stats,
            onDone: {}
        )
        
        XCTAssertNotNil(view.body)
        XCTAssertEqual(view.title, "Test Complete")
    }
}
#endif
