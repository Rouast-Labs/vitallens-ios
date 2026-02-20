import XCTest
import zlib
@testable import VitalLensInference

final class APIInferenceTests: XCTestCase {
    
    var apiInference: APIInference!
    var session: URLSession!
    
    override func setUp() {
        super.setUp()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [APIMockURLProtocol.self]
        session = URLSession(configuration: configuration)
    }
    
    override func tearDown() {
        APIMockURLProtocol.requestHandler = nil
        super.tearDown()
    }
    
    func makeWindow(size: Int) -> [(InferenceUnit, InferenceContext)] {
        let dummyData = Data(repeating: 0xAB, count: size)
        let unit = InferenceUnit.rgbData(dummyData)
        let ctx = InferenceContext(timestamp: 0)
        return [(unit, ctx)]
    }

    // MARK: - Configuration & Auth Tests

    func testAPIKeyHeaderIsSet_DirectCall() async throws {
        apiInference = APIInference(apiKey: "test_key_123", proxyURL: nil, session: session)
        
        APIMockURLProtocol.requestHandler = { request in
            XCTAssertEqual(request.value(forHTTPHeaderField: "X-Api-Key"), "test_key_123")
            return (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, self.emptySuccessResponse)
        }
        
        _ = try await apiInference.resolveModel(requestedModel: nil)
    }

    func testEnvironmentBaseURL_IsUsed_WhenProxyIsNil() async throws {
        let mockEnv = ["VITALLENS_BASE_URL": "http://dev.example.com"]
        apiInference = APIInference(apiKey: "key", proxyURL: nil, session: session, environment: mockEnv)
        
        APIMockURLProtocol.requestHandler = { request in
            XCTAssertEqual(request.url?.host, "dev.example.com")
            XCTAssertEqual(request.value(forHTTPHeaderField: "X-Api-Key"), "key")
            return (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, self.emptySuccessResponse)
        }
        
        _ = try await apiInference.resolveModel(requestedModel: nil)
    }

    func testEnvironmentAPIKey_IsUsed_WhenExplicitKeyIsNil() async throws {
        let mockEnv = ["VITALLENS_API_KEY": "env_secret_key"]
        apiInference = APIInference(apiKey: nil, proxyURL: nil, session: session, environment: mockEnv)
        
        APIMockURLProtocol.requestHandler = { request in
            XCTAssertEqual(request.value(forHTTPHeaderField: "X-Api-Key"), "env_secret_key")
            return (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, self.emptySuccessResponse)
        }
        
        _ = try await apiInference.resolveModel(requestedModel: nil)
    }

    func testExplicitKey_Overrides_EnvironmentKey() async throws {
        let mockEnv = ["VITALLENS_API_KEY": "env_key"]
        apiInference = APIInference(apiKey: "explicit_key", proxyURL: nil, session: session, environment: mockEnv)
        
        APIMockURLProtocol.requestHandler = { request in
            XCTAssertEqual(request.value(forHTTPHeaderField: "X-Api-Key"), "explicit_key")
            return (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, self.emptySuccessResponse)
        }
        
        _ = try await apiInference.resolveModel(requestedModel: nil)
    }

    // TODO: Unsure if this is the behavior we want
    func testProxyIgnoresAPIKey() async throws {
        let mockEnv = ["VITALLENS_BASE_URL": "http://dev.example.com"]
        let proxy = URL(string: "https://my-proxy.com")!
        
        apiInference = APIInference(apiKey: "key", proxyURL: proxy, session: session, environment: mockEnv)
        
        APIMockURLProtocol.requestHandler = { request in
            XCTAssertEqual(request.url?.host, "my-proxy.com")
            XCTAssertNil(request.value(forHTTPHeaderField: "X-Api-Key"))
            return (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, self.emptySuccessResponse)
        }
        
        _ = try await apiInference.resolveModel(requestedModel: nil)
    }
    
    // MARK: - Proxy & Dev Environment Specifics

    func testExplicitProxy_Overrides_EnvironmentBaseURL() async throws {
        let mockEnv = ["VITALLENS_BASE_URL": "http://dev.example.com"]
        let proxy = URL(string: "https://my-proxy.com")!
        
        apiInference = APIInference(apiKey: "key", proxyURL: proxy, session: session, environment: mockEnv)
        
        APIMockURLProtocol.requestHandler = { request in
            XCTAssertEqual(request.url?.host, "my-proxy.com")
            XCTAssertNil(request.value(forHTTPHeaderField: "X-Api-Key"))
            return (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, self.emptySuccessResponse)
        }
        
        _ = try await apiInference.resolveModel(requestedModel: nil)
    }
    
    func testDevEnvironment_SendsAuthHeader() async throws {
        let mockEnv = ["VITALLENS_BASE_URL": "http://dev.example.com"]
        
        apiInference = APIInference(apiKey: "secret", proxyURL: nil, session: session, environment: mockEnv)
        
        APIMockURLProtocol.requestHandler = { request in
            XCTAssertEqual(request.url?.host, "dev.example.com")
            XCTAssertEqual(request.value(forHTTPHeaderField: "X-Api-Key"), "secret")
            return (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, self.emptySuccessResponse)
        }
        
        _ = try await apiInference.resolveModel(requestedModel: nil)
    }
    
    // MARK: - Error Handling Tests
    
    func testQuotaExceededError() async {
        apiInference = APIInference(apiKey: "key", proxyURL: nil, session: session)
        
        APIMockURLProtocol.requestHandler = { request in
            return (HTTPURLResponse(url: request.url!, statusCode: 429, httpVersion: nil, headerFields: nil)!, nil)
        }
        
        do {
            _ = try await apiInference.resolveModel(requestedModel: nil)
            XCTFail("Should have thrown error")
        } catch let error as VitalLensError {
            XCTAssertEqual(error, VitalLensError.quotaExceeded)
        } catch {
            XCTFail("Wrong error type: \(error)")
        }
    }
    
    func testServerError() async {
        apiInference = APIInference(apiKey: "key", proxyURL: nil, session: session)
        
        APIMockURLProtocol.requestHandler = { request in
            return (HTTPURLResponse(url: request.url!, statusCode: 500, httpVersion: nil, headerFields: nil)!, nil)
        }
        
        do {
            _ = try await apiInference.resolveModel(requestedModel: nil)
            XCTFail("Should have thrown error")
        } catch {
            if let vlError = error as? VitalLensError, case .serverError(let code, _) = vlError {
                XCTAssertEqual(code, 500)
            } else {
                XCTFail("Wrong error type: \(error)")
            }
        }
    }
    
    // MARK: - Logic: Resolve Model & Conformance
    
    func testResolveModelQueryParam() async throws {
        apiInference = APIInference(apiKey: "key", proxyURL: nil, session: session)
        
        APIMockURLProtocol.requestHandler = { request in
            let components = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)
            let modelItem = components?.queryItems?.first(where: { $0.name == "model" })
            XCTAssertEqual(modelItem?.value, "vitallens-2.0")
            return (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, self.resolveResponse)
        }
        
        let response = try await apiInference.resolveModel(requestedModel: "vitallens-2.0")
        XCTAssertEqual(response.resolvedModel, "vitallens-2.0")
        XCTAssertEqual(response.config.nInputs, 4)
    }

    func testStrategyConformance() async throws {
        let strategy: any InferenceStrategy = APIInference(apiKey: "test", proxyURL: nil, session: session)
        
        APIMockURLProtocol.requestHandler = { request in
            return (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, self.resolveResponse)
        }
        
        let config = try await strategy.resolveConfig()
        
        XCTAssertEqual(config.nInputs, 4)
        XCTAssertEqual(config.inputSize, 40)
        let bufConfig = try await strategy.bufferConfig
        XCTAssertGreaterThan(bufConfig.streamMax, 0)
    }
    
    // MARK: - Logic: Streaming (Compression & Headers)
    
    func testStreamBatchRequestConstruction() async throws {
        apiInference = APIInference(apiKey: "key", proxyURL: nil, session: session)
        
        let dummyState = APIState(data: [0.1, 0.2])
        let window = makeWindow(size: 1000)
        let rawData = Data(repeating: 0xAB, count: 1000)
        
        APIMockURLProtocol.requestHandler = { request in
            XCTAssertTrue(request.url?.path.hasSuffix("/stream") ?? false, "URL should end in /stream")
            XCTAssertEqual(request.httpMethod, "POST")
            
            XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/octet-stream")
            XCTAssertEqual(request.value(forHTTPHeaderField: "X-Encoding"), "gzip")
            XCTAssertEqual(request.value(forHTTPHeaderField: "X-Model"), "vitallens-2.0")
            
            guard let stateHeader = request.value(forHTTPHeaderField: "X-State"),
                  let decodedData = Data(base64Encoded: stateHeader) else {
                XCTFail("X-State header missing or invalid Base64")
                return (HTTPURLResponse(), nil)
            }
            let floats = decodedData.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
            XCTAssertEqual(floats.count, 2)
            XCTAssertEqual(floats[0], 0.1, accuracy: 0.0001)
            
            let bodyData = request.httpBodyStreamData() ?? request.httpBody ?? Data()
            
            XCTAssertGreaterThan(bodyData.count, 2)
            // GZIP Magic Bytes (1f 8b)
            XCTAssertEqual(bodyData[0], 0x1f)
            XCTAssertEqual(bodyData[1], 0x8b)
            
            if let decompressed = bodyData.test_decompressed() {
                XCTAssertEqual(decompressed, rawData)
            } else {
                XCTFail("Failed to decompress body")
            }
            
            return (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, self.validStreamResponse)
        }
        
        _ = try await apiInference.infer(window: window, state: dummyState, mode: .stream, model: "vitallens-2.0")
    }
    
    // MARK: - Logic: File Upload (JSON & Body State)
    
    func testFileEndpointRequestConstruction() async throws {
        apiInference = APIInference(apiKey: "key", proxyURL: nil, session: session)
        
        let dummyState = APIState(data: [0.5, 0.6])
        let window = makeWindow(size: 4)
        let rawData = Data(repeating: 0xAB, count: 4)
        
        APIMockURLProtocol.requestHandler = { request in
            XCTAssertTrue(request.url?.path.hasSuffix("/file") ?? false)
            XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/json")
            
            XCTAssertNil(request.value(forHTTPHeaderField: "X-Encoding"))
            XCTAssertNil(request.value(forHTTPHeaderField: "X-State"))
            
            let bodyData = request.httpBodyStreamData() ?? request.httpBody ?? Data()
            guard let json = try? JSONSerialization.jsonObject(with: bodyData) as? [String: Any] else {
                XCTFail("Body was not valid JSON")
                return (HTTPURLResponse(), nil)
            }
            
            XCTAssertEqual(json["origin"] as? String, "vitallens-ios")
            XCTAssertEqual(json["model"] as? String, "test-model")
            
            let videoB64 = json["video"] as? String
            XCTAssertEqual(videoB64, rawData.base64EncodedString())
            
            let stateB64 = json["state"] as? String
            XCTAssertNotNil(stateB64)
            
            return (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, self.validStreamResponse)
        }
        
        _ = try await apiInference.infer(window: window, state: dummyState, mode: .file, model: "test-model")
    }

    // MARK: - Helpers
    
    private var emptySuccessResponse: Data {
        """
        { "resolved_model": "test", "config": { "n_inputs": 0, "input_size": 0, "fps_target": 0, "roi_method": "", "supported_vitals": [] } }
        """.data(using: .utf8)!
    }
    
    private var resolveResponse: Data {
        """
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
        """.data(using: .utf8)!
    }
    
    private var validStreamResponse: Data {
        """
        {
            "face": { "coordinates": [], "confidence": [], "note": "" },
            "vital_signs": {
                "heart_rate": { "value": 72.0, "confidence": 0.9, "unit": "bpm", "note": "" }
            },
            "time": [1.0],
            "fps": 30.0,
            "message": "OK"
        }
        """.data(using: .utf8)!
    }
}

// MARK: - Mock Protocol

class APIMockURLProtocol: URLProtocol {
    nonisolated(unsafe) static var requestHandler: ((URLRequest) throws -> (HTTPURLResponse, Data?))?
    
    override class func canInit(with request: URLRequest) -> Bool { return true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { return request }
    
    override func startLoading() {
        guard let handler = APIMockURLProtocol.requestHandler else {
            fatalError("Handler not set.")
        }
        
        do {
            let (response, data) = try handler(request)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            if let data = data {
                client?.urlProtocol(self, didLoad: data)
            }
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }
    
    override func stopLoading() {}
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

extension Data {
    func test_decompressed() -> Data? {
        guard !self.isEmpty else { return Data() }
        
        var stream = z_stream()
        var status: Int32
        
        // 15 + 32 = Automatic detection of GZIP/ZLIB headers
        status = inflateInit2_(&stream, 15 + 32, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size))
        guard status == Z_OK else { return nil }
        
        var data = Data(capacity: self.count * 2)
        let chunkSize = 16384
        
        self.withUnsafeBytes { (inputPointer: UnsafeRawBufferPointer) in
            stream.next_in = UnsafeMutablePointer(mutating: inputPointer.bindMemory(to: UInt8.self).baseAddress)
            stream.avail_in = uInt(inputPointer.count)
            
            repeat {
                if Int(stream.total_out) >= data.count {
                    data.count += chunkSize
                }
                
                data.withUnsafeMutableBytes { (outputPointer: UnsafeMutableRawBufferPointer) in
                    if let base = outputPointer.baseAddress?.assumingMemoryBound(to: UInt8.self) {
                        stream.next_out = base.advanced(by: Int(stream.total_out))
                        stream.avail_out = uInt(outputPointer.count) - uInt(stream.total_out)
                        status = inflate(&stream, Z_NO_FLUSH)
                    }
                }
            } while status == Z_OK
        }
        
        inflateEnd(&stream)
        
        if status == Z_STREAM_END {
            data.count = Int(stream.total_out)
            return data
        }
        return nil
    }
}