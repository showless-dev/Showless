import Foundation

public enum MarkdownParser {
    public static func parse(_ markdown: String) throws -> [ShowBlock] {
        let lines = markdownLines(markdown)
        var blocks: [ShowBlock] = []
        var index = 0

        func skipSeparator() {
            if index < lines.count, lines[index].isEmpty {
                index += 1
            }
        }

        while index < lines.count {
            // Skip any blank lines that precede the first block. Frontmatter
            // strippers and other preprocessing layers commonly leave a single
            // empty line at the top; we don't want that to prevent the leading
            // `# Heading` from being recognised as the document title.
            if blocks.isEmpty, lines[index].isEmpty {
                index += 1
                continue
            }
            if blocks.isEmpty, lines[index].hasPrefix("# ") {
                let title = String(lines[index].dropFirst(2))
                index += 1

                if index < lines.count, lines[index].isEmpty {
                    index += 1
                }

                var timestamp = ""
                var version = ""
                if index < lines.count, lines[index].hasPrefix("*"), lines[index].hasSuffix("*") {
                    let dateline = String(lines[index].dropFirst().dropLast())
                    if let range = dateline.range(of: " by Showless ") {
                        timestamp = String(dateline[..<range.lowerBound])
                        version = String(dateline[range.upperBound...])
                    } else {
                        timestamp = dateline
                    }
                    index += 1
                }

                var documentID = ""
                if index < lines.count,
                   lines[index].hasPrefix("<!-- showless-id: "),
                   lines[index].hasSuffix(" -->") {
                    documentID = String(lines[index].dropFirst("<!-- showless-id: ".count).dropLast(" -->".count))
                    index += 1
                }

                blocks.append(.title(TitleBlock(title: title, timestamp: timestamp, version: version, documentID: documentID)))
                skipSeparator()
                continue
            }

            if let source = try parseSourceExcerpt(at: &index, lines: lines) {
                blocks.append(.sourceExcerpt(source))
                skipSeparator()
                continue
            }

            if lines[index].hasPrefix("```") {
                let opening = lines[index]
                let tickCount = opening.prefix { $0 == "`" }.count
                let closingFence = String(repeating: "`", count: tickCount)
                let info = String(opening.dropFirst(tickCount))
                index += 1

                if info == "output" {
                    var content = ""
                    while index < lines.count, lines[index] != closingFence {
                        content += lines[index] + "\n"
                        index += 1
                    }
                    if index < lines.count {
                        index += 1
                    }
                    blocks.append(.output(OutputBlock(content: content)))
                } else {
                    var language = info
                    var isImage = false
                    if language.hasSuffix(" {image}") {
                        language.removeLast(" {image}".count)
                        isImage = true
                    }

                    var codeLines: [String] = []
                    while index < lines.count, lines[index] != closingFence {
                        codeLines.append(lines[index])
                        index += 1
                    }
                    if index < lines.count {
                        index += 1
                    }
                    blocks.append(.code(CodeBlock(language: language, code: codeLines.joined(separator: "\n"), isImage: isImage)))
                }

                skipSeparator()
                continue
            }

            if lines[index].hasPrefix("![") {
                let image = parseImageReference(lines[index])
                if !image.filename.isEmpty {
                    index += 1
                    blocks.append(.imageOutput(ImageOutputBlock(altText: image.alt, filename: image.filename)))
                    skipSeparator()
                    continue
                }
            }

            var textLines: [String] = []
            while index < lines.count {
                if lines[index].hasPrefix("```") {
                    break
                }
                if lines[index].hasPrefix("![") {
                    let image = parseImageReference(lines[index])
                    if !image.filename.isEmpty {
                        break
                    }
                }
                if lines[index].hasPrefix("<!-- showless-source: ") {
                    break
                }
                textLines.append(lines[index])
                index += 1
            }

            while textLines.last == "" {
                textLines.removeLast()
            }

            if !textLines.isEmpty {
                blocks.append(.commentary(CommentaryBlock(text: textLines.joined(separator: "\n"))))
            } else if index < lines.count {
                index += 1
            }
        }

        return blocks
    }

    public static func parseImageReference(_ line: String) -> (alt: String, filename: String) {
        guard let start = line.range(of: "![") else {
            return ("", "")
        }
        let rest = line[start.upperBound...]
        guard let closeBracket = rest.range(of: "](") else {
            return ("", "")
        }
        let alt = String(rest[..<closeBracket.lowerBound])
        let afterBracket = rest[closeBracket.upperBound...]
        guard let closeParen = afterBracket.firstIndex(of: ")") else {
            return (alt, "")
        }
        return (alt, String(afterBracket[..<closeParen]))
    }

    private static func parseSourceExcerpt(at index: inout Int, lines: [String]) throws -> SourceExcerptBlock? {
        guard index < lines.count,
              lines[index].hasPrefix("<!-- showless-source: "),
              lines[index].hasSuffix(" -->") else {
            return nil
        }

        let jsonText = String(lines[index].dropFirst("<!-- showless-source: ".count).dropLast(" -->".count))
        guard let data = jsonText.data(using: .utf8),
              let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let path = object["path"] as? String,
              let language = object["language"] as? String,
              let startLine = object["startLine"] as? Int,
              let endLine = object["endLine"] as? Int,
              let hash = object["hash"] as? String else {
            return nil
        }

        let next = index + 1
        guard next < lines.count, lines[next].hasPrefix("```") else {
            return nil
        }

        index = next
        let opening = lines[index]
        let tickCount = opening.prefix { $0 == "`" }.count
        let closingFence = String(repeating: "`", count: tickCount)
        index += 1

        var codeLines: [String] = []
        while index < lines.count, lines[index] != closingFence {
            codeLines.append(lines[index])
            index += 1
        }
        if index < lines.count {
            index += 1
        }

        return SourceExcerptBlock(
            path: path,
            language: language,
            startLine: startLine,
            endLine: endLine,
            hash: hash,
            content: codeLines.joined(separator: "\n")
        )
    }

    private static func markdownLines(_ markdown: String) -> [String] {
        let normalized = markdown.replacingOccurrences(of: "\r\n", with: "\n")
        var lines = normalized.components(separatedBy: "\n")
        if normalized.hasSuffix("\n"), !lines.isEmpty {
            lines.removeLast()
        }
        return lines
    }
}
