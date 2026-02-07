import XCTest
@testable import VitalLensCore

final class APIClientTests: XCTestCase {
    
    var apiClient: APIClient!
    var session: URLSession!
    
    override func setUp() {
        super.setUp()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]
        session = URLSession(configuration: configuration)
    }
    
    override func tearDown() {
        MockURLProtocol.requestHandler = nil
        super.tearDown()
    }
    
    // MARK: - Headers & Auth
    
    func testAPIKeyHeaderIsSet() async throws {
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
            if case VitalLensError.serverError(let code, _) = error {
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
    
    // MARK: - Logic: Streaming
    
    func testStreamBatchRequestConstruction() async throws {
        apiClient = APIClient(apiKey: "key", proxyURL: nil, session: session)
        
        let dummyState = [Float](repeating: 0.5, count: 10)
        let dummyData = Data(repeating: 0xFF, count: 100)
        
        MockURLProtocol.requestHandler = { request in
            XCTAssertEqual(request.url?.path, "/vitallens-v3/stream")
            XCTAssertEqual(request.httpMethod, "POST")
            
            XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/octet-stream")
            XCTAssertEqual(request.value(forHTTPHeaderField: "X-Origin"), "vitallens-ios")
            XCTAssertEqual(request.value(forHTTPHeaderField: "X-Model"), "vitallens-2.0")
            
            XCTAssertNotNil(request.value(forHTTPHeaderField: "X-State"))
            
            let bodyData = request.httpBodyStreamData() ?? request.httpBody
            XCTAssertEqual(bodyData, dummyData)
            
            return (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, self.validStreamResponse)
        }
        
        _ = try await apiClient.sendStreamBatch(
            rawRGBBytes: dummyData,
            state: dummyState,
            model: "vitallens-2.0"
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