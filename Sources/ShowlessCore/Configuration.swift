import Foundation

public struct ShowlessConfig: Codable, Equatable, Sendable {
    public var workdir: String?
    public var timeoutSeconds: Double?
    public var include: [String]
    public var exclude: [String]
    public var walkthroughDepth: Int

    public init(
        workdir: String? = nil,
        timeoutSeconds: Double? = nil,
        include: [String] = [],
        exclude: [String] = [],
        walkthroughDepth: Int = 2
    ) {
        self.workdir = workdir
        self.timeoutSeconds = timeoutSeconds
        self.include = include
        self.exclude = exclude
        self.walkthroughDepth = walkthroughDepth
    }

    public static func load(startingAt directory: String = FileManager.default.currentDirectoryPath) throws -> ShowlessConfig {
        let fileManager = FileManager.default
        let jsonPath = URL(fileURLWithPath: directory).appendingPathComponent(".showless.json").path
        if fileManager.fileExists(atPath: jsonPath) {
            let data = try Data(contentsOf: URL(fileURLWithPath: jsonPath))
            return try JSONDecoder().decode(ShowlessConfig.self, from: data)
        }

        let yamlPath = URL(fileURLWithPath: directory).appendingPathComponent(".showless.yml").path
        if fileManager.fileExists(atPath: yamlPath) {
            let text = try String(contentsOfFile: yamlPath, encoding: .utf8)
            return parseSimpleYAML(text)
        }

        return ShowlessConfig()
    }

    private static func parseSimpleYAML(_ text: String) -> ShowlessConfig {
        var config = ShowlessConfig()
        for rawLine in text.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") {
                continue
            }
            let parts = line.split(separator: ":", maxSplits: 1).map(String.init)
            guard parts.count == 2 else {
                continue
            }
            let key = parts[0].trimmingCharacters(in: .whitespaces)
            let value = parts[1].trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
            switch key {
            case "workdir":
                config.workdir = value
            case "timeoutSeconds", "timeout", "timeout_seconds":
                config.timeoutSeconds = Double(value)
            case "include":
                config.include = parseList(value)
            case "exclude":
                config.exclude = parseList(value)
            case "walkthroughDepth", "walkthrough_depth":
                config.walkthroughDepth = Int(value) ?? config.walkthroughDepth
            default:
                continue
            }
        }
        return config
    }

    private static func parseList(_ value: String) -> [String] {
        let trimmed = value.trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        if trimmed.isEmpty {
            return []
        }
        return trimmed.split(separator: ",").map {
            String($0).trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
        }
    }
}
