import Foundation

/// Internal actor responsible for handling all network communication with the VitalLens API.
/// It manages authentication, endpoint resolution, and request batching.
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
    
    /// Initializes a new API client.
    ///
    /// - Parameters:
    ///   - apiKey: The VitalLens API key. Required if `proxyURL` is nil.
    ///   - proxyURL: Optional URL to a backend proxy. If set, the API key is not sent by the client.
    ///   - session: The URLSession to use for requests. Defaults to `.shared`.
    public init(apiKey: String?, proxyURL: URL?, session: URLSession = .shared) {
        self.apiKey = apiKey
        self.proxyURL = proxyURL
        self.session = session
    }
    
    // MARK: - Configuration
    
    /// Contacts the API to determine the optimal configuration (FPS, Input Size) for the current user plan.
    ///
    /// - Parameter requestedModel: The specific model version to request (e.g., "vitallens-2.0"). If nil, the API selects the best available.
    /// - Returns: A `ResolveModelResponse` containing the configuration parameters.
    /// - Throws: `VitalLensError` if the request fails or the plan is invalid.
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
    
    /// Sends a batch of accumulated video frames to the real-time streaming endpoint.
    ///
    /// - Parameters:
    ///   - rawRGBBytes: A concatenated buffer of raw RGB bytes for multiple frames.
    ///   - state: The RNN state vector returned from the previous API response.
    ///   - model: The model version identifier to use for inference.
    /// - Returns: The `VitalLensResult` containing vital signs and the updated state.
    /// - Throws: `VitalLensError` for network or API errors.
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
        
        request.setValue("vitallens-ios", forHTTPHeaderField: "X-Origin")
        
        if let model = model {
            request.setValue(model, forHTTPHeaderField: "X-Model")
        }
        
        if let state = state, !state.isEmpty {
            let stateData = state.withUnsafeBufferPointer { Data(buffer: $0) }
            let base64State = stateData.base64EncodedString()
            request.setValue(base64State, forHTTPHeaderField: "X-State")
        }

        request.httpBody = rawRGBBytes
        
        return try await perform(request: request)
    }
    
    // MARK: - File Processing
    
    /// Uploads a video file chunk to the file processing endpoint.
    ///
    /// - Parameters:
    ///   - rawRGBBytes: The raw video data for the chunk.
    ///   - metadata: Additional processing parameters (e.g., fps).
    ///   - state: Optional RNN state if continuing a previous session.
    /// - Returns: The `VitalLensResult` for the processed chunk.
    /// - Throws: `VitalLensError`.
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
        
        let base64Video = rawRGBBytes.base64EncodedString()
        
        var payload: [String: Any] = [
            "video": base64Video,
            "origin": "vitallens-ios"
        ]
        
        if let state = state, !state.isEmpty {
            let stateData = state.withUnsafeBufferPointer { Data(buffer: $0) }
            payload["state"] = stateData.base64EncodedString()
        }
        
        for (key, value) in metadata {
            payload[key] = value
        }
        
        request.httpBody = try JSONSerialization.data(withJSONObject: payload)
        
        return try await perform(request: request)
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

extension APIClient: InferenceStrategy {
    
    public func resolveConfig() async throws -> ModelConfig {
        let response = try await self.resolveModel(requestedModel: nil)
        return response.config
    }
    
    public func process(frames: Data, state: [Float]?, meta: [String : String]) async throws -> VitalLensResult {
        return try await self.sendStreamBatch(rawRGBBytes: frames, state: state, model: nil)
    }
}