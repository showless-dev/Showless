import Foundation

public struct WalkthroughOptions: Equatable, Sendable {
    public var title: String?
    public var depth: Int
    public var include: [String]
    public var exclude: [String]

    public init(title: String? = nil, depth: Int = 2, include: [String] = [], exclude: [String] = []) {
        self.title = title
        self.depth = max(1, depth)
        self.include = include
        self.exclude = exclude
    }
}

public struct WalkthroughReport: Codable, Equatable, Sendable {
    public var repository: String
    public var manifestFiles: [String]
    public var entryPoints: [String]
    public var testFiles: [String]
    public var ciFiles: [String]
    public var languages: [String: Int]
    public var todos: [String]
}

public struct WalkthroughEngine {
    private let fileManager: FileManager

    public init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
    }

    public func generate(repositoryPath: String, options: WalkthroughOptions = WalkthroughOptions(), version: String = "dev") throws -> [ShowBlock] {
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: repositoryPath, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw ShowlessError.fileNotFound(repositoryPath)
        }

        let files = try collectFiles(repositoryPath: repositoryPath, options: options)
        let report = analyze(repositoryPath: repositoryPath, files: files)
        let repositoryName = URL(fileURLWithPath: repositoryPath).lastPathComponent
        let title = options.title ?? "\(repositoryName) Walkthrough Scaffold"
        var blocks: [ShowBlock] = [
            .title(TitleBlock(
                title: title,
                timestamp: ISO8601DateFormatter().string(from: Date()),
                version: version,
                documentID: UUID().uuidString.lowercased()
            ))
        ]

        blocks.append(.commentary(CommentaryBlock(text: projectShape(report))))
        blocks.append(.commentary(CommentaryBlock(text: howItRuns(report))))
        blocks.append(.commentary(CommentaryBlock(text: coreFlow(report))))

        let important = importantFiles(report: report, files: files, depth: options.depth)
        if !important.isEmpty {
            blocks.append(.commentary(CommentaryBlock(text: "## Important Files\n\nThe excerpts below anchor this static scaffold in real source files. `verify` can later detect when these snippets drift from the repository. An AI or human author should turn these anchors into a linear narrative.")))
            for file in important {
                blocks.append(.commentary(CommentaryBlock(text: "### `\(file)`")))
                if let excerpt = try sourceExcerpt(repositoryPath: repositoryPath, relativePath: file, maxLines: 80) {
                    blocks.append(.sourceExcerpt(excerpt))
                }
            }
        }

        blocks.append(.commentary(CommentaryBlock(text: testsAndCI(report))))
        blocks.append(.commentary(CommentaryBlock(text: risksAndTodos(report))))
        return blocks
    }

    public func report(repositoryPath: String, options: WalkthroughOptions = WalkthroughOptions()) throws -> WalkthroughReport {
        let files = try collectFiles(repositoryPath: repositoryPath, options: options)
        return analyze(repositoryPath: repositoryPath, files: files)
    }

    private func collectFiles(repositoryPath: String, options: WalkthroughOptions) throws -> [String] {
        guard let enumerator = fileManager.enumerator(
            at: URL(fileURLWithPath: repositoryPath),
            includingPropertiesForKeys: [.isDirectoryKey, .fileSizeKey],
            options: [.skipsPackageDescendants]
        ) else {
            return []
        }

        var files: [String] = []
        for case let url as URL in enumerator {
            let relative = relativePath(url.path, root: repositoryPath)
            let name = url.lastPathComponent

            if shouldSkipDirectory(name: name, relativePath: relative) {
                enumerator.skipDescendants()
                continue
            }

            let values = try url.resourceValues(forKeys: [.isDirectoryKey, .fileSizeKey])
            if values.isDirectory == true {
                continue
            }
            if let size = values.fileSize, size > 1_000_000 {
                continue
            }
            if isBinary(url.path) {
                continue
            }
            if !options.include.isEmpty, !options.include.contains(where: { relative.contains($0) }) {
                continue
            }
            if options.exclude.contains(where: { relative.contains($0) }) {
                continue
            }
            files.append(relative)
        }
        return files.sorted()
    }

    private func analyze(repositoryPath: String, files: [String]) -> WalkthroughReport {
        let manifestNames: Set<String> = ["Package.swift", "go.mod", "package.json", "pyproject.toml", "Cargo.toml", "Gemfile", "pom.xml", "build.gradle", "Makefile"]
        let manifests = files.filter { manifestNames.contains(URL(fileURLWithPath: $0).lastPathComponent) }
        let entryPoints = files.filter(isLikelyEntryPoint)
        let testFiles = files.filter { path in
            let lower = path.lowercased()
            return lower.contains("/test") || lower.contains("tests/") || lower.hasSuffix("_test.go") || lower.hasSuffix("test.swift") || lower.hasSuffix(".spec.ts") || lower.hasSuffix(".test.ts")
        }
        let ciFiles = files.filter { $0.hasPrefix(".github/workflows/") || $0.contains("/.github/workflows/") || $0.hasPrefix(".circleci/") }
        var languages: [String: Int] = [:]
        for file in files {
            let language = languageForPath(file)
            guard language != "text" else {
                continue
            }
            languages[language, default: 0] += 1
        }

        let todos = findTodos(repositoryPath: repositoryPath, files: files)
        return WalkthroughReport(
            repository: repositoryPath,
            manifestFiles: manifests,
            entryPoints: entryPoints,
            testFiles: Array(testFiles.prefix(20)),
            ciFiles: ciFiles,
            languages: languages,
            todos: todos
        )
    }

    private func projectShape(_ report: WalkthroughReport) -> String {
        var lines = ["## Project Shape", ""]
        lines.append("Repository: `\(report.repository)`")
        if report.manifestFiles.isEmpty {
            lines.append("No common manifest files were found.")
        } else {
            lines.append("Manifest files: \(report.manifestFiles.map { "`\($0)`" }.joined(separator: ", "))")
        }
        if !report.languages.isEmpty {
            let languageSummary = report.languages.sorted { $0.key < $1.key }.map { "\($0.key): \($0.value)" }.joined(separator: ", ")
            lines.append("Detected languages: \(languageSummary)")
        }
        return lines.joined(separator: "\n")
    }

    private func howItRuns(_ report: WalkthroughReport) -> String {
        var commands: [String] = []
        let manifests = Set(report.manifestFiles)
        if manifests.contains("Package.swift") { commands.append("`swift build` / `swift test`") }
        if manifests.contains("go.mod") { commands.append("`go test ./...`") }
        if manifests.contains("package.json") { commands.append("`npm install` then package scripts") }
        if manifests.contains("pyproject.toml") { commands.append("Python tooling from `pyproject.toml`") }
        if manifests.contains("Cargo.toml") { commands.append("`cargo test`") }

        let summary = commands.isEmpty ? "No standard run command could be inferred from manifests." : commands.joined(separator: ", ")
        return "## How It Runs\n\n\(summary)"
    }

    private func coreFlow(_ report: WalkthroughReport) -> String {
        if report.entryPoints.isEmpty {
            return "## Core Flow\n\nNo obvious entry point was detected. Start with the manifest and important files below."
        }
        return "## Core Flow\n\nLikely entry points: \(report.entryPoints.prefix(10).map { "`\($0)`" }.joined(separator: ", "))"
    }

    private func testsAndCI(_ report: WalkthroughReport) -> String {
        var lines = ["## Tests And CI", ""]
        if report.testFiles.isEmpty {
            lines.append("No obvious tests were detected.")
        } else {
            lines.append("Test files: \(report.testFiles.prefix(10).map { "`\($0)`" }.joined(separator: ", "))")
        }
        if report.ciFiles.isEmpty {
            lines.append("No common CI workflow files were detected.")
        } else {
            lines.append("CI files: \(report.ciFiles.map { "`\($0)`" }.joined(separator: ", "))")
        }
        return lines.joined(separator: "\n")
    }

    private func risksAndTodos(_ report: WalkthroughReport) -> String {
        if report.todos.isEmpty {
            return "## Risks Or TODOs\n\nNo TODO/FIXME/HACK/XXX markers were found in scanned text files."
        }
        return "## Risks Or TODOs\n\n" + report.todos.prefix(20).map { "- \($0)" }.joined(separator: "\n")
    }

    private func importantFiles(report: WalkthroughReport, files: [String], depth: Int) -> [String] {
        var ordered: [String] = []
        ordered.append(contentsOf: report.manifestFiles)
        ordered.append(contentsOf: report.entryPoints)
        ordered.append(contentsOf: files.filter { URL(fileURLWithPath: $0).lastPathComponent.lowercased().hasPrefix("readme") })
        ordered.append(contentsOf: files.filter { isSourceFile($0) })

        var seen: Set<String> = []
        return ordered.filter { seen.insert($0).inserted }.prefix(depth * 3).map { $0 }
    }

    private func sourceExcerpt(repositoryPath: String, relativePath: String, maxLines: Int) throws -> SourceExcerptBlock? {
        let url = URL(fileURLWithPath: repositoryPath).appendingPathComponent(relativePath)
        let text = try String(contentsOf: url, encoding: .utf8)
        var lines = text.components(separatedBy: .newlines)
        if text.hasSuffix("\n"), !lines.isEmpty {
            lines.removeLast()
        }
        guard !lines.isEmpty else {
            return nil
        }
        let end = min(lines.count, maxLines)
        let excerpt = Array(lines[0..<end]).joined(separator: "\n")
        return SourceExcerptBlock(
            path: relativePath,
            language: languageForPath(relativePath),
            startLine: 1,
            endLine: end,
            hash: StableHash.contentHash(excerpt),
            content: excerpt
        )
    }

    private func findTodos(repositoryPath: String, files: [String]) -> [String] {
        var results: [String] = []
        let markers = ["TODO", "FIXME", "HACK", "XXX"]
        for file in files where results.count < 20 {
            guard isSourceFile(file) || URL(fileURLWithPath: file).lastPathComponent.lowercased().hasPrefix("readme") else {
                continue
            }
            let path = URL(fileURLWithPath: repositoryPath).appendingPathComponent(file).path
            guard let text = try? String(contentsOfFile: path, encoding: .utf8) else {
                continue
            }
            let lines = text.components(separatedBy: .newlines)
            for (offset, line) in lines.enumerated() where markers.contains(where: { line.contains($0) }) {
                results.append("`\(file):\(offset + 1)` \(line.trimmingCharacters(in: .whitespaces))")
                if results.count >= 20 {
                    break
                }
            }
        }
        return results
    }

    private func isLikelyEntryPoint(_ path: String) -> Bool {
        let lower = path.lowercased()
        let name = URL(fileURLWithPath: path).lastPathComponent.lowercased()
        return name == "main.swift" ||
            name == "main.go" ||
            name == "main.rs" ||
            name == "index.js" ||
            name == "index.ts" ||
            name == "app.py" ||
            name == "main.py" ||
            lower.hasSuffix("/src/main.swift") ||
            lower.hasSuffix("/src/main.rs") ||
            lower.hasSuffix("/cmd/main.go")
    }

    private func shouldSkipDirectory(name: String, relativePath: String) -> Bool {
        let skipped: Set<String> = [".git", ".build", ".swiftpm", "node_modules", "dist", "build", ".venv", "__pycache__", "target", ".idea", ".vscode"]
        if skipped.contains(name) {
            return true
        }
        if name.hasPrefix("."), relativePath != ".github" && !relativePath.hasPrefix(".github/") {
            return true
        }
        return false
    }

    private func isBinary(_ path: String) -> Bool {
        let ext = URL(fileURLWithPath: path).pathExtension.lowercased()
        return ["png", "jpg", "jpeg", "gif", "pdf", "zip", "gz", "tar", "dylib", "so", "a", "o", "sqlite"].contains(ext)
    }

    private func isSourceFile(_ path: String) -> Bool {
        let language = languageForPath(path)
        return language != "text" && language != "markdown" && language != "yaml" && language != "json"
    }

    private func languageForPath(_ path: String) -> String {
        let name = URL(fileURLWithPath: path).lastPathComponent
        if name == "Package.swift" { return "swift" }
        if name == "Dockerfile" { return "dockerfile" }
        let ext = URL(fileURLWithPath: path).pathExtension.lowercased()
        switch ext {
        case "swift": return "swift"
        case "go": return "go"
        case "js", "mjs", "cjs": return "javascript"
        case "ts", "tsx": return "typescript"
        case "py": return "python"
        case "rs": return "rust"
        case "java": return "java"
        case "kt": return "kotlin"
        case "rb": return "ruby"
        case "php": return "php"
        case "c", "h": return "c"
        case "cpp", "cc", "hpp": return "cpp"
        case "md", "markdown": return "markdown"
        case "yml", "yaml": return "yaml"
        case "json": return "json"
        case "toml": return "toml"
        case "sh", "bash", "zsh": return "bash"
        default: return "text"
        }
    }

    private func relativePath(_ path: String, root: String) -> String {
        let rootURL = URL(fileURLWithPath: root).standardizedFileURL
        let pathURL = URL(fileURLWithPath: path).standardizedFileURL
        let rootComponents = rootURL.pathComponents
        let pathComponents = pathURL.pathComponents
        guard pathComponents.starts(with: rootComponents) else {
            return path
        }
        return pathComponents.dropFirst(rootComponents.count).joined(separator: "/")
    }
}
