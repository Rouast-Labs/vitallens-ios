import Foundation

/// Errors specific to the VitalLens SDK and API interactions.
public enum VitalLensError: LocalizedError, Sendable, Equatable {
    
    /// Indicates that the provided API key is missing or invalid.
    case invalidAPIKey
    
    /// Indicates that the API rejected the request due to quota limits (e.g., HTTP 429).
    case quotaExceeded
    
    /// Indicates that the API returned a server-side error (HTTP 5xx).
    ///
    /// - Parameters:
    ///   - statusCode: The HTTP status code returned by the server.
    ///   - message: An optional error message provided by the server.
    case serverError(statusCode: Int, message: String?)
    
    /// Indicates that the API returned a client-side error (HTTP 4xx) other than authentication or quota issues.
    ///
    /// - Parameters:
    ///   - statusCode: The HTTP status code returned by the server.
    ///   - message: An optional error message provided by the server.
    case clientError(statusCode: Int, message: String?)
    
    /// Indicates that the response from the API could not be successfully decoded.
    ///
    /// - Parameter Error: The underlying decoding error.
    case decodingError(Error)
    
    /// Indicates a general network failure, such as being offline or a connection timeout.
    ///
    /// - Parameter Error: The underlying network error.
    case networkError(Error)
    
    /// Indicates an internal SDK error occurred during frame processing or inference setup.
    ///
    /// - Parameter String: A descriptive message detailing the processing failure.
    case processingError(String)

    /// Evaluates if two `VitalLensError` instances are equal.
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
    
    /// A localized message describing what error occurred.
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