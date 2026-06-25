import Foundation

public enum ShowBlock: Equatable, Sendable {
    case title(TitleBlock)
    case commentary(CommentaryBlock)
    case code(CodeBlock)
    case output(OutputBlock)
    case imageOutput(ImageOutputBlock)
    case sourceExcerpt(SourceExcerptBlock)
}

public struct TitleBlock: Equatable, Sendable {
    /// Name stamped into the dateline. The parser/writer hard-code this
    /// literal, so it is not a per-instance field.
    public static let generator: String = "Showless"

    public var title: String
    public var timestamp: String
    public var version: String
    public var documentID: String

    public init(title: String, timestamp: String, version: String = "", documentID: String = "") {
        self.title = title
        self.timestamp = timestamp
        self.version = version
        self.documentID = documentID
    }
}

public struct CommentaryBlock: Equatable, Sendable {
    public var text: String

    public init(text: String) {
        self.text = text
    }
}

public struct CodeBlock: Equatable, Sendable {
    public var language: String
    public var code: String
    public var isImage: Bool

    public init(language: String, code: String, isImage: Bool = false) {
        self.language = language
        self.code = code
        self.isImage = isImage
    }

    public var isDiagram: Bool {
        DiagramLanguage.isDiagram(language)
    }
}

public enum DiagramLanguage {
    public static let known: Set<String> = [
        "mermaid",
        "plantuml",
        "puml",
        "dot",
        "graphviz",
        "d2"
    ]

    public static func isDiagram(_ language: String) -> Bool {
        known.contains(language.lowercased())
    }

    public static func canonicalize(_ language: String) -> String {
        let lower = language.lowercased()
        if known.contains(lower) {
            return lower
        }
        return language
    }
}

public struct OutputBlock: Equatable, Sendable {
    public var content: String

    public init(content: String) {
        self.content = content
    }
}

public struct ImageOutputBlock: Equatable, Sendable {
    public var altText: String
    public var filename: String

    public init(altText: String, filename: String) {
        self.altText = altText
        self.filename = filename
    }
}

public struct SourceExcerptBlock: Equatable, Sendable {
    public var path: String
    public var language: String
    public var startLine: Int
    public var endLine: Int
    public var hash: String
    public var content: String

    public init(path: String, language: String, startLine: Int, endLine: Int, hash: String, content: String) {
        self.path = path
        self.language = language
        self.startLine = startLine
        self.endLine = endLine
        self.hash = hash
        self.content = content
    }
}
