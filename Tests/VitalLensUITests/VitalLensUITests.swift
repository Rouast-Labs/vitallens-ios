// FILE: Tests/VitalLensUITests/VitalLensUITests.swift
import XCTest
import SwiftUI
@testable import VitalLens
@testable import VitalLensUI

#if canImport(UIKit)
final class VitalLensUITests: XCTestCase {
    
    // MARK: - Scan View Tests
    
    func testScanView_InitWithAPIKey() {
        let view = VitalLensScanView(
            apiKey: "test_key",
            method: "vitallens-2.0",
            onComplete: { _ in }
        )
        
        // Verify the view body can be retrieved (sanity check)
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
        // It is valid to provide both (though client logic prioritizes proxy)
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
        // Ensure default values (showWaveforms = true) work
        let view = VitalLensMonitorView(apiKey: "key")
        XCTAssertNotNil(view.body)
    }
}
#endif