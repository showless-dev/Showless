import Foundation

public struct DocumentStore {
    private let fileManager: FileManager

    public init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
    }

    public func exists(_ path: String) -> Bool {
        fileManager.fileExists(atPath: path)
    }

    public func readBlocks(from path: String) throws -> [ShowBlock] {
        guard exists(path) else {
            throw ShowlessError.fileNotFound(path)
        }
        let text = try String(contentsOfFile: path, encoding: .utf8)
        return try MarkdownParser.parse(text)
    }

    public func writeBlocks(_ blocks: [ShowBlock], to path: String) throws {
        let text = try MarkdownWriter.write(blocks)
        try ensureParentDirectory(for: path)
        try text.write(toFile: path, atomically: true, encoding: .utf8)
    }

    public func ensureNewFile(_ path: String) throws {
        if exists(path) {
            throw ShowlessError.fileAlreadyExists(path)
        }
        try ensureParentDirectory(for: path)
    }

    private func ensureParentDirectory(for path: String) throws {
        let parent = URL(fileURLWithPath: path).deletingLastPathComponent().path
        guard !parent.isEmpty, parent != "." else {
            return
        }
        try fileManager.createDirectory(atPath: parent, withIntermediateDirectories: true)
    }
}
