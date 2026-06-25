import Foundation

public struct VerificationIssue: Codable, Equatable, Sendable {
    public enum Kind: String, Codable, Sendable {
        case commandOutput
        case sourceExcerpt
    }

    public var kind: Kind
    public var blockIndex: Int
    public var path: String?
    public var expected: String
    public var actual: String
    public var diff: String

    public init(kind: Kind, blockIndex: Int, path: String? = nil, expected: String, actual: String) {
        self.kind = kind
        self.blockIndex = blockIndex
        self.path = path
        self.expected = expected
        self.actual = actual
        self.diff = UnifiedDiff.make(expected: expected, actual: actual)
    }

    public var humanDescription: String {
        var header = "block \(blockIndex)"
        if let path {
            header += " (\(path))"
        }
        return "\(header):\n\(diff)"
    }
}

public enum UnifiedDiff {
    public static func make(expected: String, actual: String) -> String {
        let oldLines = splitForDiff(expected)
        let newLines = splitForDiff(actual)
        var result: [String] = ["--- expected", "+++ actual"]
        let table = lcsTable(oldLines, newLines)
        result.append(contentsOf: backtrack(oldLines, newLines, table, oldLines.count, newLines.count).reversed())
        return result.joined(separator: "\n")
    }

    private static func splitForDiff(_ text: String) -> [String] {
        if text.isEmpty {
            return []
        }
        var lines = text.components(separatedBy: "\n")
        if text.hasSuffix("\n") {
            lines.removeLast()
        }
        return lines
    }

    private static func lcsTable(_ a: [String], _ b: [String]) -> [[Int]] {
        var table = Array(repeating: Array(repeating: 0, count: b.count + 1), count: a.count + 1)
        if a.isEmpty || b.isEmpty {
            return table
        }
        for i in 1...a.count {
            for j in 1...b.count {
                if a[i - 1] == b[j - 1] {
                    table[i][j] = table[i - 1][j - 1] + 1
                } else {
                    table[i][j] = max(table[i - 1][j], table[i][j - 1])
                }
            }
        }
        return table
    }

    private static func backtrack(_ a: [String], _ b: [String], _ table: [[Int]], _ i: Int, _ j: Int) -> [String] {
        if i > 0, j > 0, a[i - 1] == b[j - 1] {
            return [" \(a[i - 1])"] + backtrack(a, b, table, i - 1, j - 1)
        }
        if j > 0, (i == 0 || table[i][j - 1] >= table[i - 1][j]) {
            return ["+\(b[j - 1])"] + backtrack(a, b, table, i, j - 1)
        }
        if i > 0, (j == 0 || table[i][j - 1] < table[i - 1][j]) {
            return ["-\(a[i - 1])"] + backtrack(a, b, table, i - 1, j)
        }
        return []
    }
}
