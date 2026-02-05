import Foundation

// MARK: - Resolve Model Response

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

public struct ModelConfig: Codable, Sendable {
    public let nInputs: Int
    public let inputSize: Int
    public let fpsTarget: Double
    public let roiMethod: String
    public let supportedVitals: [String]
    
    public init(nInputs: Int, inputSize: Int, fpsTarget: Double, roiMethod: String, supportedVitals: [String]) {
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

// MARK: - Error Response

struct APIErrorResponse: Decodable {
    let message: String?
}
