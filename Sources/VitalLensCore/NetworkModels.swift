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
    /// The number of frames required for a single inference batch (temporal depth).
    public let nInputs: Int
    
    /// The required width/height of the input video frames (e.g., 40 for 40x40).
    public let inputSize: Int
    
    /// The target frame rate expected by the model.
    public let fpsTarget: Double
    
    /// The method used to calculate the Region of Interest (ROI) from a face detection.
    /// Typically "upper_body_cropped".
    public let roiMethod: String
    
    /// A list of vital signs supported by this model (e.g., "heart_rate", "hrv_sdnn").
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

// MARK: - Internal Error Handling

/// Standard error response format returned by the API for 4xx/5xx errors.
struct APIErrorResponse: Decodable {
    let message: String?
}