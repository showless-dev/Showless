import Foundation

public struct ShellInvocation: Equatable, Sendable {
    public var executableURL: URL
    public var arguments: [String]

    public init(executableURL: URL, arguments: [String]) {
        self.executableURL = executableURL
        self.arguments = arguments
    }
}

public enum ShellInvocationParser {
    public static func isShell(_ language: String) -> Bool {
        ["bash", "sh", "zsh", "shell"].contains(language.lowercased())
    }

    public static func containsShellOperators(_ line: String) -> Bool {
        let operators = CharacterSet(charactersIn: "|&;<>")
        if line.unicodeScalars.contains(where: { operators.contains($0) }) {
            return true
        }
        return line.contains("$(") || line.contains("${") || line.contains("`")
    }

    /// Parse a simple single-line shell command into a direct process invocation.
    /// Handles unquoted executable paths that contain spaces.
    public static func parse(line: String) -> ShellInvocation? {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.contains("\n"), !containsShellOperators(trimmed) else {
            return nil
        }

        let tokens = tokenize(trimmed)
        guard tokens.first != nil else {
            return nil
        }

        let (executable, args) = resolveExecutable(tokens: tokens)
        guard FileManager.default.fileExists(atPath: executable) else {
            return nil
        }

        if FileManager.default.isExecutableFile(atPath: executable) {
            return ShellInvocation(
                executableURL: URL(fileURLWithPath: executable),
                arguments: args
            )
        }

        return ShellInvocation(
            executableURL: URL(fileURLWithPath: "/bin/bash"),
            arguments: [executable] + args
        )
    }

    private static func resolveExecutable(tokens: [String]) -> (String, [String]) {
        guard let first = tokens.first else {
            return ("", [])
        }

        if FileManager.default.fileExists(atPath: first) {
            return (first, Array(tokens.dropFirst()))
        }

        for end in 1 ..< tokens.count {
            let candidate = tokens[0 ... end].joined(separator: " ")
            if FileManager.default.fileExists(atPath: candidate) {
                return (candidate, Array(tokens.dropFirst(end + 1)))
            }
        }

        return (first, Array(tokens.dropFirst()))
    }

    static func tokenize(_ line: String) -> [String] {
        var tokens: [String] = []
        var current = ""
        var quote: Character?
        var escape = false

        for ch in line {
            if escape {
                current.append(ch)
                escape = false
                continue
            }

            if ch == "\\" {
                escape = true
                continue
            }

            if let activeQuote = quote {
                if ch == activeQuote {
                    quote = nil
                } else {
                    current.append(ch)
                }
                continue
            }

            if ch == "'" || ch == "\"" {
                quote = ch
                continue
            }

            if ch.isWhitespace {
                if !current.isEmpty {
                    tokens.append(current)
                    current = ""
                }
                continue
            }

            current.append(ch)
        }

        if !current.isEmpty {
            tokens.append(current)
        }

        return tokens
    }
}
