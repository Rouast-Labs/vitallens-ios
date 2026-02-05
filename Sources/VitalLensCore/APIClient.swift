import Foundation

/// Internal actor to handle network requests.
public actor APIClient {
    
    private let apiKey: String?
    private let proxyURL: URL?
    private let session: URLSession
    
    // MARK: - Endpoints
    private static let productionBaseURL = URL(string: "https://api.rouast.com/vitallens-v3")!
    
    private var baseURL: URL {
        return proxyURL ?? Self.productionBaseURL
    }
    
    // MARK: - Initialization
    
    public init(apiKey: String?, proxyURL: URL?, session: URLSession = .shared) {
        self.apiKey = apiKey
        self.proxyURL = proxyURL
        self.session = session
    }
    
    // MARK: - Configuration
    
    /// Calls /resolve-model to determine the correct configuration (FPS, Input Size) for the user's plan.
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
    
    // MARK: - Streaming
    
    /// Sends a **batch** of accumulated video frames to the Streaming endpoint.
    ///
    /// - Parameters:
    ///   - rawRGBBytes: A concatenated buffer of raw RGB bytes for *multiple* frames.
    ///                  Format: [Frame 1 Bytes][Frame 2 Bytes]...[Frame N Bytes].
    ///                  Total size must be: N * (inputSize * inputSize * 3).
    ///   - state: The RNN state vector returned from the *previous* API response.
    ///   - model: The model version identifier.
    /// - Returns: The parsed VitalLensResult containing the updated state.
    public func sendStreamBatch(
        rawRGBBytes: Data,
        state: [Float]?,
        model: String?
    ) async throws -> VitalLensResult {
        
        let url = baseURL.appendingPathComponent("stream")
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
        
        addAuthHeaders(to: &request)
        
        // Metadata Headers
        request.setValue("vitallens-ios", forHTTPHeaderField: "X-Origin")
        
        if let model = model {
            request.setValue(model, forHTTPHeaderField: "X-Model")
        }
        
        // State Injection
        if let state = state, !state.isEmpty {
            let stateData = state.withUnsafeBufferPointer { Data(buffer: $0) }
            let base64State = stateData.base64EncodedString()
            request.setValue(base64State, forHTTPHeaderField: "X-State")
        }

        // TODO: Support compression for faster network calls
        
        // The body is now a batch of frames
        request.httpBody = rawRGBBytes
        
        return try await perform(request: request)
    }
    
    // MARK: - File Processing
    
    /// Uploads a video file chunk for processing.
    public func processVideoChunk(
        rawRGBBytes: Data,
        metadata: [String: String],
        state: [Float]?
    ) async throws -> VitalLensResult {
        let url = baseURL.appendingPathComponent("file")
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        addAuthHeaders(to: &request)
        
        // Matches lambda_function.py expectation:
        // video = np.frombuffer(base64.b64decode(video_base64), dtype=np.uint8)
        let base64Video = rawRGBBytes.base64EncodedString()
        
        var payload: [String: Any] = [
            "video": base64Video,
            "origin": "vitallens-ios"
        ]
        
        if let state = state, !state.isEmpty {
            let stateData = state.withUnsafeBufferPointer { Data(buffer: $0) }
            payload["state"] = stateData.base64EncodedString()
        }
        
        // Add metadata (fps, process_signals, etc)
        for (key, value) in metadata {
            // Convert boolean strings to actual booleans if needed, or send as string
            // The backend uses str2bool helper, so strings "True"/"False" are fine.
            payload[key] = value
        }
        
        request.httpBody = try JSONSerialization.data(withJSONObject: payload)
        
        return try await perform(request: request)
    }
    
    // MARK: - Private Helpers
    
    private func addAuthHeaders(to request: inout URLRequest) {
        // Proxy handles auth if set. Otherwise, we send the key.
        if proxyURL == nil, let key = apiKey {
            // Matches casing in vitallens-infra/lambda code
            request.setValue(key, forHTTPHeaderField: "X-Api-Key")
        }
    }
    
    private func perform<T: Decodable>(request: URLRequest) async throws -> T {
        do {
            let (data, response) = try await session.data(for: request)
            
            guard let httpResponse = response as? HTTPURLResponse else {
                throw VitalLensError.networkError(URLError(.badServerResponse))
            }
            
            // Validate Status Codes
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
