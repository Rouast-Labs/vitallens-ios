import Foundation

/// Errors specific to the VitalLens SDK and API interactions.
public enum VitalLensError: LocalizedError, Sendable, Equatable {
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

    public static func == (lhs: VitalLensError, rhs: VitalLensError) -> Bool {
        switch (lhs, rhs) {
        case (.invalidAPIKey, .invalidAPIKey): return true
        case (.quotaExceeded, .quotaExceeded): return true
        case (.serverError(let c1, let m1), .serverError(let c2, let m2)): return c1 == c2 && m1 == m2
        case (.clientError(let c1, let m1), .clientError(let c2, let m2)): return c1 == c2 && m1 == m2
        case (.processingError(let m1), .processingError(let m2)): return m1 == m2
        case (.decodingError(let e1), .decodingError(let e2)): 
            return e1.localizedDescription == e2.localizedDescription
        case (.networkError(let e1), .networkError(let e2)):
            return e1.localizedDescription == e2.localizedDescription
        default: return false
        }
    }
    
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
