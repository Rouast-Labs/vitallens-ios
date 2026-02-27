import Foundation

/// The response returned by the `/resolve-model` endpoint.
/// Contains the resolved model name and its specific configuration parameters.
public struct ResolveModelResponse: Codable, Sendable {
    
    public let resolvedModel: String
    public let config: ModelConfig
    
    /// Initializes a new response object.
    ///
    /// - Parameters:
    ///   - resolvedModel: The string identifier of the model.
    ///   - config: The configuration parameters.
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
public struct ModelConfig: Codable, Sendable {
    
    public var modelName: String = "vitallens"
    public let nInputs: Int
    public let inputSize: Int
    public var fpsTarget: Double
    public let roiMethod: String
    public let supportedVitals: [String]
    
    /// Initializes a new model configuration.
    ///
    /// - Parameters:
    ///   - nInputs: The number of required input frames.
    ///   - inputSize: The target pixel size (width and height) for the frames.
    ///   - fpsTarget: The expected frame rate.
    ///   - roiMethod: The method to compute the region of interest.
    ///   - supportedVitals: The vital signs supported by the model.
    ///   - modelName: The model identifier. Defaults to `"vitallens"`.
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

/// Standard error response format returned by the API for 4xx and 5xx errors.
struct APIErrorResponse: Decodable {    
    let message: String?
}