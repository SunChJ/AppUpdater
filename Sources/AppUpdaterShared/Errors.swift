import Foundation

public enum UpdaterError: Error {
    case badInput
    case cancelled
    case networkError
    case fileSystemError
    case permissionDenied
    case unknownError
    
    public var localizedDescription: String {
        switch self {
        case .badInput:
            return "Invalid input or format"
        case .cancelled:
            return "Operation cancelled"
        case .networkError:
            return "Network error occurred"
        case .fileSystemError:
            return "File system error occurred"
        case .permissionDenied:
            return "Permission denied"
        case .unknownError:
            return "Unknown error occurred"
        }
    }
} 