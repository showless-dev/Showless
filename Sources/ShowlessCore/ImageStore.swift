import Foundation

public struct ImageInput: Equatable, Sendable {
    public var path: String
    public var altText: String
}

public struct ImageStore {
    private let validExtensions: Set<String> = [".png", ".jpg", ".jpeg", ".gif", ".svg"]
    private let fileManager: FileManager

    public init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
    }

    public func parseInput(_ input: String) -> ImageInput {
        var trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("\\![") {
            trimmed.removeFirst()
        }

        if trimmed.hasPrefix("!["), trimmed.hasSuffix(")") {
            let rest = String(trimmed.dropFirst(2))
            if let closeBracket = rest.range(of: "](") {
                let alt = String(rest[..<closeBracket.lowerBound])
                let path = String(rest[closeBracket.upperBound...].dropLast())
                return ImageInput(path: path, altText: alt)
            }
        }

        return ImageInput(path: trimmed, altText: "")
    }

    public func copyImage(from sourcePath: String, to destinationDirectory: String, date: Date = Date()) throws -> String {
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: sourcePath, isDirectory: &isDirectory) else {
            throw ShowlessError.invalidImage("image file not found: \(sourcePath)")
        }
        if isDirectory.boolValue {
            throw ShowlessError.invalidImage("image path is a directory: \(sourcePath)")
        }

        let ext = URL(fileURLWithPath: sourcePath).pathExtension.lowercased()
        let dottedExt = ".\(ext)"
        guard validExtensions.contains(dottedExt) else {
            throw ShowlessError.invalidImage("unrecognized image format: \(dottedExt)")
        }

        let dateFormatter = DateFormatter()
        dateFormatter.calendar = Calendar(identifier: .gregorian)
        dateFormatter.locale = Locale(identifier: "en_US_POSIX")
        dateFormatter.timeZone = TimeZone(secondsFromGMT: 0)
        dateFormatter.dateFormat = "yyyy-MM-dd"

        let id = String(UUID().uuidString.lowercased().prefix(8))
        let filename = "\(id)-\(dateFormatter.string(from: date))\(dottedExt)"
        let destination = URL(fileURLWithPath: destinationDirectory).appendingPathComponent(filename).path
        try fileManager.copyItem(atPath: sourcePath, toPath: destination)
        return filename
    }
}
