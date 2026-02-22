import Foundation

// MARK: - API Responses

/// The response returned by the `/resolve-model` endpoint.
/// Contains the resolved model name and its specific configuration parameters.
public struct ResolveModelResponse: Codable, Sendable {
    public let resolvedModel: String
    public let config: ModelConfig
    
    public init(resolvedModel: String, config: ModelConfig) {
        self.resolvedModel = resolvedModel
        self.config = config
    }
    
    enum CodingKeys: String, CodingKey {
        case resolvedModel = "resolved_model"
        case config
    }
}

/// Configuration parameters for a specific VitalLens model.
/// These parameters dictate how the client should preprocess video data.
public struct ModelConfig: Codable, Sendable {
    public var modelName: String = "vitallens"
    public let nInputs: Int
    public let inputSize: Int
    public var fpsTarget: Double
    public let roiMethod: String
    public let supportedVitals: [String]
    
    public init(nInputs: Int, inputSize: Int, fpsTarget: Double, roiMethod: String, supportedVitals: [String], modelName: String = "vitallens") {
        self.modelName = modelName
        self.nInputs = nInputs
        self.inputSize = inputSize
        self.fpsTarget = fpsTarget
        self.roiMethod = roiMethod
        self.supportedVitals = supportedVitals
    }
    
    enum CodingKeys: String, CodingKey {
        case nInputs = "n_inputs"
        case inputSize = "input_size"
        case fpsTarget = "fps_target"
        case roiMethod = "roi_method"
        case supportedVitals = "supported_vitals"
    }
}

// MARK: - Internal Error Handling

/// Standard error response format returned by the API for 4xx/5xx errors.
struct APIErrorResponse: Decodable {
    let message: String?
}