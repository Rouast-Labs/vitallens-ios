import XCTest
import Compression
@testable import VitalLensCore

final class APIClientTests: XCTestCase {
    
    var apiClient: APIClient!
    var session: URLSession!
    
    override func setUp() {
        super.setUp()
        // Ensure MockURLProtocol is registered in the configuration
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]
        session = URLSession(configuration: configuration)
    }
    
    override func tearDown() {
        MockURLProtocol.requestHandler = nil
        super.tearDown()
    }
    
    // MARK: - Headers & Auth
    
    func testAPIKeyHeaderIsSet_DirectCall() async throws {
        apiClient = APIClient(apiKey: "test_key_123", proxyURL: nil, session: session)
        
        MockURLProtocol.requestHandler = { request in
            XCTAssertEqual(request.value(forHTTPHeaderField: "X-Api-Key"), "test_key_123")
            return (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, self.emptySuccessResponse)
        }
        
        _ = try await apiClient.resolveModel(requestedModel: nil)
    }
    
    func testProxyIgnoresAPIKey() async throws {
        let proxy = URL(string: "https://my-proxy.com")!
        apiClient = APIClient(apiKey: "should_be_ignored", proxyURL: proxy, session: session)
        
        MockURLProtocol.requestHandler = { request in
            XCTAssertEqual(request.url?.host, "my-proxy.com")
            // Security Check: Key should NOT be sent to proxy
            XCTAssertNil(request.value(forHTTPHeaderField: "X-Api-Key"))
            return (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, self.emptySuccessResponse)
        }
        
        _ = try await apiClient.resolveModel(requestedModel: nil)
    }
    
    // MARK: - Error Handling
    
    func testQuotaExceededError() async {
        apiClient = APIClient(apiKey: "key", proxyURL: nil, session: session)
        
        MockURLProtocol.requestHandler = { request in
            return (HTTPURLResponse(url: request.url!, statusCode: 429, httpVersion: nil, headerFields: nil)!, nil)
        }
        
        do {
            _ = try await apiClient.resolveModel(requestedModel: nil)
            XCTFail("Should have thrown error")
        } catch let error as VitalLensError {
            XCTAssertEqual(error, VitalLensError.quotaExceeded)
        } catch {
            XCTFail("Wrong error type: \(error)")
        }
    }
    
    func testServerError() async {
        apiClient = APIClient(apiKey: "key", proxyURL: nil, session: session)
        
        MockURLProtocol.requestHandler = { request in
            return (HTTPURLResponse(url: request.url!, statusCode: 500, httpVersion: nil, headerFields: nil)!, nil)
        }
        
        do {
            _ = try await apiClient.resolveModel(requestedModel: nil)
            XCTFail("Should have thrown error")
        } catch {
            if let vlError = error as? VitalLensError, case .serverError(let code, _) = vlError {
                XCTAssertEqual(code, 500)
            } else {
                XCTFail("Wrong error type: \(error)")
            }
        }
    }
    
    // MARK: - Logic: Resolve Model
    
    func testResolveModelQueryParam() async throws {
        apiClient = APIClient(apiKey: "key", proxyURL: nil, session: session)
        
        MockURLProtocol.requestHandler = { request in
            let components = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)
            let modelItem = components?.queryItems?.first(where: { $0.name == "model" })
            XCTAssertEqual(modelItem?.value, "vitallens-2.0")
            
            let json = """
            {
                "resolved_model": "vitallens-2.0",
                "config": {
                    "n_inputs": 4,
                    "input_size": 40,
                    "fps_target": 30.0,
                    "roi_method": "face",
                    "supported_vitals": ["heart_rate"]
                }
            }
            """.data(using: .utf8)
            
            return (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, json)
        }
        
        let response = try await apiClient.resolveModel(requestedModel: "vitallens-2.0")
        XCTAssertEqual(response.resolvedModel, "vitallens-2.0")
        XCTAssertEqual(response.config.nInputs, 4)
    }
    
    // MARK: - Logic: Streaming (Compression & Headers)
    
    func testStreamBatchRequestConstruction() async throws {
        apiClient = APIClient(apiKey: "key", proxyURL: nil, session: session)
        
        let dummyState: [Float] = [0.1, 0.2]
        // Create repeating data that is highly compressible
        let dummyData = Data(repeating: 0xAB, count: 1000)
        
        MockURLProtocol.requestHandler = { request in
            // 1. Endpoint Check
            XCTAssertEqual(request.url?.path, "/vitallens-v3/stream")
            XCTAssertEqual(request.httpMethod, "POST")
            
            // 2. Header Checks
            XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/octet-stream")
            XCTAssertEqual(request.value(forHTTPHeaderField: "X-Origin"), "vitallens-ios")
            XCTAssertEqual(request.value(forHTTPHeaderField: "X-Model"), "vitallens-2.0")
            
            // Compression Flag
            XCTAssertEqual(request.value(forHTTPHeaderField: "X-Encoding"), "gzip", "Stream requests must declare gzip compression")
            
            // State must be in HEADER for stream
            guard let stateHeader = request.value(forHTTPHeaderField: "X-State"),
                  let decodedData = Data(base64Encoded: stateHeader) else {
                XCTFail("X-State header missing or invalid Base64")
                return (HTTPURLResponse(), nil)
            }
            
            let floats = decodedData.withUnsafeBytes {
                Array($0.bindMemory(to: Float.self))
            }
            XCTAssertEqual(floats.count, 2)
            XCTAssertEqual(floats[0], 0.1, accuracy: 0.0001)
            
            // 3. Body Checks (Compression)
            let bodyData = request.httpBodyStreamData() ?? request.httpBody ?? Data()
            
            // Body should NOT match raw data (it should be compressed)
            XCTAssertNotEqual(bodyData, dummyData, "Request body was not compressed")
            // Verify GZIP Magic Bytes (RFC 1952)
            XCTAssertGreaterThan(bodyData.count, 2, "Body too small for GZIP")
            XCTAssertEqual(bodyData[0], 0x1f, "Missing GZIP magic byte 1")
            XCTAssertEqual(bodyData[1], 0x8b, "Missing GZIP magic byte 2")
            
            return (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, self.validStreamResponse)
        }
        
        _ = try await apiClient.sendStreamBatch(
            rawRGBBytes: dummyData,
            state: dummyState,
            model: "vitallens-2.0"
        )
    }
    
    // MARK: - Logic: File Upload (JSON & Body State)
    
    func testFileEndpointRequestConstruction() async throws {
        apiClient = APIClient(apiKey: "key", proxyURL: nil, session: session)
        
        let dummyState: [Float] = [0.5, 0.6]
        let dummyData = Data([0x01, 0x02, 0x03, 0x04])
        let metadata = ["fps": "30.0"]
        
        MockURLProtocol.requestHandler = { request in
            // 1. Endpoint Check
            XCTAssertEqual(request.url?.path, "/vitallens-v3/file")
            XCTAssertEqual(request.httpMethod, "POST")
            
            // 2. Header Checks
            XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/json")
            // Ensure we do NOT send stream headers
            XCTAssertNil(request.value(forHTTPHeaderField: "X-Encoding"))
            XCTAssertNil(request.value(forHTTPHeaderField: "X-State"))
            
            // 3. Body Checks (JSON)
            let bodyData = request.httpBodyStreamData() ?? request.httpBody ?? Data()
            guard let json = try? JSONSerialization.jsonObject(with: bodyData) as? [String: Any] else {
                XCTFail("Body was not valid JSON")
                return (HTTPURLResponse(), nil)
            }
            
            XCTAssertEqual(json["origin"] as? String, "vitallens-ios")
            XCTAssertEqual(json["fps"] as? String, "30.0")
            
            // Video should be Base64
            let videoB64 = json["video"] as? String
            XCTAssertEqual(videoB64, dummyData.base64EncodedString())
            
            // State should be in Body (Base64)
            let stateB64 = json["state"] as? String
            XCTAssertNotNil(stateB64)
            
            return (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, self.validStreamResponse)
        }
        
        _ = try await apiClient.processVideoChunk(
            rawRGBBytes: dummyData,
            metadata: metadata,
            state: dummyState
        )
    }

    func testStrategyConformance() async throws {
        // Ensure APIClient satisfies the InferenceStrategy protocol requirements at runtime
        let strategy: InferenceStrategy = APIClient(apiKey: "test", proxyURL: nil, session: session)
        
        MockURLProtocol.requestHandler = { request in
            let json = """
            {
                "resolved_model": "vitallens-2.0",
                "config": { "n_inputs": 8, "input_size": 40, "fps_target": 30.0, "roi_method": "face", "supported_vitals": [] }
            }
            """.data(using: .utf8)!
            return (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, json)
        }
        
        let config = try await strategy.resolveConfig()
        XCTAssertEqual(config.nInputs, 8)
        XCTAssertEqual(config.inputSize, 40)
    }
    
    // MARK: - Helpers
    
    private var emptySuccessResponse: Data {
        """
        { "resolved_model": "test", "config": { "n_inputs": 0, "input_size": 0, "fps_target": 0, "roi_method": "", "supported_vitals": [] } }
        """.data(using: .utf8)!
    }
    
    private var validStreamResponse: Data {
        """
        {
            "face": { "coordinates": [], "confidence": [], "note": "" },
            "vital_signs": {
                "heart_rate": { "value": 72.0, "unit": "bpm", "confidence": 0.9, "note": "" }
            },
            "time": [1.0],
            "fps": 30.0,
            "message": "OK"
        }
        """.data(using: .utf8)!
    }
}

// Ensure the helper exists for handling stream bodies
extension URLRequest {
    func httpBodyStreamData() -> Data? {
        guard let stream = httpBodyStream else { return nil }
        stream.open()
        var data = Data()
        let bufferSize = 1024
        let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: bufferSize)
        while stream.hasBytesAvailable {
            let read = stream.read(buffer, maxLength: bufferSize)
            if read > 0 {
                data.append(buffer, count: read)
            } else {
                break
            }
        }
        buffer.deallocate()
        stream.close()
        return data
    }
}

// Helper for verifying compression in tests
extension Data {
    func test_decompressed() -> Data? {
        let pageSize = 128
        var decompressed = Data()
        
        return try? self.withUnsafeBytes { rawBuffer in
            guard let baseAddress = rawBuffer.baseAddress else { return nil }
            let srcSize = self.count
            
            // Estimate output size (heuristic for test data)
            let dstSize = srcSize * 20
            let dstBuffer = UnsafeMutablePointer<UInt8>.allocate(capacity: dstSize)
            defer { dstBuffer.deallocate() }
            
            // ZLIB signature for 'deflate'
            let compression = COMPRESSION_ZLIB
            
            let decompressedSize = compression_decode_buffer(
                dstBuffer, dstSize,
                baseAddress.bindMemory(to: UInt8.self, capacity: srcSize), srcSize,
                nil,
                compression
            )
            
            if decompressedSize == 0 { return nil }
            return Data(bytes: dstBuffer, count: decompressedSize)
        }
    }
}