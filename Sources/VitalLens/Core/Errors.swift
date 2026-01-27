import Foundation

/// Errors specific to the VitalLens SDK and API interactions.
public enum VitalLensError: LocalizedError, Sendable {
    /// The API Key provided is missing or invalid.
    case invalidAPIKey
    
    /// The API rejected the request due to quota limits (HTTP 429).
    case quotaExceeded
    
    /// The API returned a server error (5xx).
    case serverError(statusCode: Int, message: String?)
    
    /// The API returned a client error (4xx) other than auth/quota.
    case clientError(statusCode: Int, message: String?)
    
    /// The response from the API could not be decoded.
    case decodingError(Error)
    
    /// A general network error (e.g. offline).
    case networkError(Error)
    
    /// Internal SDK error (e.g., invalid image buffer).
    case processingError(String)
    
    public var errorDescription: String? {
        switch self {
        case .invalidAPIKey:
            return "A valid VitalLens API key is required. Please check your configuration."
        case .quotaExceeded:
            return "VitalLens API quota exceeded. Please check your plan limits."
        case .serverError(let code, let msg):
            return "VitalLens Server Error (\(code)): \(msg ?? "Unknown error")"
        case .clientError(let code, let msg):
            return "VitalLens Request Error (\(code)): \(msg ?? "Bad request")"
        case .decodingError(let error):
            return "Failed to parse API response: \(error.localizedDescription)"
        case .networkError(let error):
            return "Network connection failed: \(error.localizedDescription)"
        case .processingError(let msg):
            return "Processing error: \(msg)"
        }
    }
}
