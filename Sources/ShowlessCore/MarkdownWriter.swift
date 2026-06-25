import Foundation

public enum MarkdownWriter {
    public static func write(_ blocks: [ShowBlock]) throws -> String {
        try blocks.map(writeBlock).joined(separator: "\n")
    }

    private static func fence(for content: String) -> String {
        var maxRun = 0
        for line in content.components(separatedBy: "\n") {
            var run = 0
            for character in line {
                if character == "`" {
                    run += 1
                } else {
                    break
                }
            }
            maxRun = max(maxRun, run)
        }
        return String(repeating: "`", count: maxRun >= 3 ? maxRun + 1 : 3)
    }

    private static func writeBlock(_ block: ShowBlock) throws -> String {
        switch block {
        case .title(let title):
            var dateline = title.timestamp
            if !title.version.isEmpty {
                dateline += " by Showless \(title.version)"
            }
            var result = "# \(title.title)\n\n*\(dateline)*\n"
            if !title.documentID.isEmpty {
                result += "<!-- showless-id: \(title.documentID) -->\n"
            }
            return result

        case .commentary(let commentary):
            return "\(commentary.text)\n"

        case .code(let code):
            var language = code.language
            if code.isImage {
                language += " {image}"
            }
            return "```\(language)\n\(code.code)\n```\n"

        case .output(let output):
            let fence = fence(for: output.content)
            return "\(fence)output\n\(output.content)\(fence)\n"

        case .imageOutput(let image):
            return "![\(image.altText)](\(image.filename))\n"

        case .sourceExcerpt(let source):
            let fence = fence(for: source.content)
            let metadata: [String: Any] = [
                "path": source.path,
                "language": source.language,
                "startLine": source.startLine,
                "endLine": source.endLine,
                "hash": source.hash
            ]
            let data = try JSONSerialization.data(withJSONObject: metadata, options: [.sortedKeys])
            let json = String(decoding: data, as: UTF8.self)
            return "<!-- showless-source: \(json) -->\n\(fence)\(source.language) {source}\n\(source.content)\n\(fence)\n"
        }
    }
}
