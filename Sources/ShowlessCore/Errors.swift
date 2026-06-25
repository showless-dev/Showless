import Foundation

public enum ShowlessError: Error, CustomStringConvertible, Equatable {
    case fileNotFound(String)
    case fileAlreadyExists(String)
    case emptyDocument
    case titleOnlyDocument
    case invalidImage(String)
    case execution(String)

    public var description: String {
        switch self {
        case .fileNotFound(let path):
            "file not found: \(path)"
        case .fileAlreadyExists(let path):
            "file already exists: \(path)"
        case .emptyDocument:
            "document is empty"
        case .titleOnlyDocument:
            "nothing to pop: document only contains a title"
        case .invalidImage(let message):
            message
        case .execution(let message):
            message
        }
    }
}
