import Foundation
import VitalLensCore
import zlib

public struct APIState: InferenceState {
    public let data: [Float]
}

// MARK: - GZIP Helper
extension Data {
    /// Compresses the data using GZIP (RFC 1952).
    func gzipped() -> Data? {
        guard !self.isEmpty else { return Data() }
        
        var stream = z_stream()
        var status: Int32
        
        // 15 + 16 tells zlib to write a gzip header/trailer (RFC 1952)
        // memLevel: 8 is default
        status = deflateInit2_(&stream, Z_DEFAULT_COMPRESSION, Z_DEFLATED, 15 + 16, 8, Z_DEFAULT_STRATEGY, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size))
        
        guard status == Z_OK else { return nil }
        
        var data = Data(capacity: self.count / 2)
        let chunkSize = 16384
        
        self.withUnsafeBytes { (inputPointer: UnsafeRawBufferPointer) in
            // Initialize input stream
            // zlib expects Mutable pointers, but we are only reading. We cast safely.
            stream.next_in = UnsafeMutablePointer(mutating: inputPointer.bindMemory(to: UInt8.self).baseAddress)
            stream.avail_in = uInt(inputPointer.count)
            
            repeat {
                // Resize output buffer if we are running out of space
                if Int(stream.total_out) >= data.count {
                    data.count += chunkSize
                }
                
                // Write compressed data
                data.withUnsafeMutableBytes { (outputPointer: UnsafeMutableRawBufferPointer) in                    
                    if let base = outputPointer.baseAddress?.assumingMemoryBound(to: UInt8.self) {
                        stream.next_out = base.advanced(by: Int(stream.total_out))
                        stream.avail_out = uInt(outputPointer.count) - uInt(stream.total_out)
                        status = deflate(&stream, Z_FINISH)
                    }
                }
                
            } while stream.avail_out == 0
        }
        
        deflateEnd(&stream)
        
        // Trim to actual size
        data.count = Int(stream.total_out)
        
        return status == Z_STREAM_END ? data : nil
    }
}

// MARK: - Remote Inference

/// Actor responsible for handling all network communication with the VitalLens API.
public actor APIInference: InferenceStrategy {
    
    private let apiKey: String?
    private let proxyURL: URL?
    private let session: URLSession
    private let environment: [String: String]

    private static let productionBaseURL = URL(string: "https://api.rouast.com/vitallens-v3")!

    // Cache the config once resolved
    private var config: ModelConfig?
    
    public init(
        apiKey: String? = nil, 
        proxyURL: URL? = nil, 
        session: URLSession = .shared,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) {
        self.environment = environment
        
        let envKey = environment["VITALLENS_API_KEY"]
        self.apiKey = apiKey ?? envKey
        
        self.proxyURL = proxyURL
        self.session = session
    }

    private var baseURL: URL {
        if let proxy = proxyURL { return proxy }

        if let envURLString = environment["VITALLENS_BASE_URL"],
           let envURL = URL(string: envURLString) {
            return envURL
        }
        
        return Self.productionBaseURL
    }
    
    // MARK: - Configuration

    /// Contacts the API to determine the optimal configuration (FPS, Input Size) for the current user plan.
    public func resolveModel(requestedModel: String?) async throws -> ResolveModelResponse {
        var url = baseURL.appendingPathComponent("resolve-model")
        
        if let model = requestedModel {
            var components = URLComponents(url: url, resolvingAgainstBaseURL: true)!
            components.queryItems = [URLQueryItem(name: "model", value: model)]
            url = components.url!
        }
        
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        addAuthHeaders(to: &request)
        
        return try await perform(request: request)
    }
    
    // MARK: - Streaming Endpoint
    
    /// Sends a batch of accumulated video frames to the real-time streaming endpoint.
    /// Uses GZIP compression for the body and HTTP Headers for metadata/state.
    public func inferStream(
        rawRGBBytes: Data,
        state: [Float]?,
        model: String?
    ) async throws -> VitalLensResult {
        
        let url = baseURL.appendingPathComponent("stream")
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        
        addAuthHeaders(to: &request)
        request.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
        request.setValue("vitallens-ios", forHTTPHeaderField: "X-Origin")
        request.setValue("gzip", forHTTPHeaderField: "X-Encoding")
        
        if let model = model {
            request.setValue(model, forHTTPHeaderField: "X-Model")
        }
        
        if let state = state, !state.isEmpty {
            let stateData = state.withUnsafeBufferPointer { Data(buffer: $0) }
            let base64State = stateData.base64EncodedString()
            request.setValue(base64State, forHTTPHeaderField: "X-State")
        }
        
        guard let compressedBody = rawRGBBytes.gzipped() else {
            throw VitalLensError.processingError("Failed to compress video batch")
        }
        
        request.httpBody = compressedBody
        
        return try await perform(request: request)
    }
    
    // MARK: - File Endpoint
    
    /// Uploads a video file chunk to the file processing endpoint.
    /// Uses standard JSON body with Base64 video and state in the payload (No Compression).
    public func inferFile(
        rawRGBBytes: Data,
        state: [Float]?,
        model: String?
    ) async throws -> VitalLensResult {
        
        let url = baseURL.appendingPathComponent("file")
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        addAuthHeaders(to: &request)
        
        // 1. Base64 Encode Video (No GZIP for JSON endpoint)
        let base64Video = rawRGBBytes.base64EncodedString()
        
        var payload: [String: Any] = [
            "video": base64Video,
            "origin": "vitallens-ios"
        ]
        
        // 2. State in Body
        if let state = state, !state.isEmpty {
            let stateData = state.withUnsafeBufferPointer { Data(buffer: $0) }
            payload["state"] = stateData.base64EncodedString()
        }

        if let model = model {
            payload["model"] = model
        }
        
        request.httpBody = try JSONSerialization.data(withJSONObject: payload)
        
        // Perform Request
        let result: VitalLensResult = try await perform(request: request)

        if result.time.isEmpty, let n = result.sampleCount {            
            return VitalLensResult(
                face: result.face,
                vitals: result.vitals,
                waveforms: result.waveforms,
                time: [],
                modelUsed: result.modelUsed,
                state: result.state,
                message: result.message,
                sampleCount: n
            )
        }

        return result
    }

    // MARK: InferenceStrategy Conformance
    
    public func resolveConfig() async throws -> ModelConfig {
        let response = try await self.resolveModel(requestedModel: nil)
        self.config = response.config
        return response.config
    }

    public var bufferConfig: VitalLensCore.BufferConfig {
        get throws {
            guard let config = config else {
                throw VitalLensError.processingError("Attempted to access config before resolving.")
            }
            // Ask Rust to compute the optimal limits based on the API configuration!
            return VitalLensCore.computeBufferConfig(config: config.toSessionConfig())
        }
    }

    public func infer(
        window: [(InferenceUnit, InferenceContext)],
        state: (any InferenceState)?,
        mode: InferenceMode,
        model: String?
    ) async throws -> (result: VitalLensResult, newState: (any InferenceState)?) {
        
        // 1. Flatten the window into a single Data blob
        var combinedData = Data()
        for item in window {
            switch item.0 {
            case .rgbData(let data):
                combinedData.append(data)
            case .pixelBuffer:
                throw VitalLensError.processingError("APIInference received raw PixelBuffer. Ensure the Transformer is configured for API mode.")
            }
        }

        let currentState = (state as? APIState)?.data
        
        // 2. Dispatch
        let result: VitalLensResult
        switch mode {
        case .stream:
            result = try await self.inferStream(rawRGBBytes: combinedData, state: currentState, model: model)
        case .file:
            result = try await self.inferFile(rawRGBBytes: combinedData, state: currentState, model: model)
        }

        var nextState: APIState? = nil
        if let stateData = result.state?.data, // The Base64 string from Python backend
           let decoded = Data(base64Encoded: stateData) {
            
            let floatArray = decoded.withUnsafeBytes { 
                Array($0.bindMemory(to: Float.self)) 
            }
            nextState = APIState(data: floatArray)
        }

        let cleanResult = VitalLensResult(
            face: result.face,
            vitals: result.vitals,
            waveforms: result.waveforms,
            time: result.time,
            fps: result.fps,
            modelUsed: result.modelUsed,
            state: nil, // Hiding it here since we return it in the tuple
            message: result.message,
            sampleCount: result.sampleCount
        )
        
        return (cleanResult, nextState)
    }
    
    // MARK: - Private Helpers
    
    private func addAuthHeaders(to request: inout URLRequest) {
        if proxyURL == nil, let key = apiKey {
            request.setValue(key, forHTTPHeaderField: "X-Api-Key")
        }
    }
    
    private func perform<T: Decodable>(request: URLRequest) async throws -> T {
        do {
            let (data, response) = try await session.data(for: request)
            
            guard let httpResponse = response as? HTTPURLResponse else {
                throw VitalLensError.networkError(URLError(.badServerResponse))
            }
            
            switch httpResponse.statusCode {
            case 200...299:
                break
            case 401, 403:
                throw VitalLensError.invalidAPIKey
            case 429:
                throw VitalLensError.quotaExceeded
            case 400...499:
                let msg = try? JSONDecoder().decode(APIErrorResponse.self, from: data).message
                throw VitalLensError.clientError(statusCode: httpResponse.statusCode, message: msg)
            case 500...599:
                throw VitalLensError.serverError(statusCode: httpResponse.statusCode, message: nil)
            default:
                throw VitalLensError.networkError(URLError(.badServerResponse))
            }
            
            return try JSONDecoder().decode(T.self, from: data)
            
        } catch let error as VitalLensError {
            throw error
        } catch {
            throw VitalLensError.networkError(error)
        }
    }
}