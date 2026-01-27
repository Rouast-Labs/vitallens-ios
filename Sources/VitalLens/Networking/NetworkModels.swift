import Foundation

// MARK: - Resolve Model Response

public struct ResolveModelResponse: Codable, Sendable {
    public let resolvedModel: String
    public let config: ModelConfig
    
    enum CodingKeys: String, CodingKey {
        case resolvedModel = "resolved_model"
        case config
    }
}

public struct ModelConfig: Codable, Sendable {
    public let nInputs: Int
    public let inputSize: Int
    public let fpsTarget: Double
    public let roiMethod: String
    public let supportedVitals: [String]
    
    enum CodingKeys: String, CodingKey {
        case nInputs = "n_inputs"
        case inputSize = "input_size"
        case fpsTarget = "fps_target"
        case roiMethod = "roi_method"
        case supportedVitals = "supported_vitals"
    }
}

// MARK: - Error Response

struct APIErrorResponse: Decodable {
    let message: String?
}
