import Foundation

public struct CommandContext {
    public var workdir: String?
    public var sourceRoot: String?
    public var timeout: TimeInterval?
    public var json: Bool

    public init(workdir: String? = nil, sourceRoot: String? = nil, timeout: TimeInterval? = nil, json: Bool = false) {
        self.workdir = workdir
        self.sourceRoot = sourceRoot
        self.timeout = timeout
        self.json = json
    }
}

public struct ShowlessService {
    private let store: DocumentStore
    private let runner: ProcessRunner
    private let imageStore: ImageStore
    private let walkthroughEngine: WalkthroughEngine
    private let version: String

    public init(
        store: DocumentStore = DocumentStore(),
        runner: ProcessRunner = ProcessRunner(),
        imageStore: ImageStore = ImageStore(),
        walkthroughEngine: WalkthroughEngine = WalkthroughEngine(),
        version: String = "dev"
    ) {
        self.store = store
        self.runner = runner
        self.imageStore = imageStore
        self.walkthroughEngine = walkthroughEngine
        self.version = version
    }

    public func initDocument(file: String, title: String) throws {
        try store.ensureNewFile(file)
        let block = TitleBlock(
            title: title,
            timestamp: ISO8601DateFormatter().string(from: Date()),
            version: version,
            documentID: UUID().uuidString.lowercased()
        )
        let blocks: [ShowBlock] = [.title(block)]
        try store.writeBlocks(blocks, to: file)
    }

    public func note(file: String, text: String) throws {
        var blocks = try store.readBlocks(from: file)
        let block = ShowBlock.commentary(CommentaryBlock(text: text))
        blocks.append(block)
        try store.writeBlocks(blocks, to: file)
    }

    public func execute(file: String, language: String, code: String, context: CommandContext = CommandContext()) throws -> ExecutionResult {
        guard store.exists(file) else {
            throw ShowlessError.fileNotFound(file)
        }
        let result = try runner.run(language: language, code: code, workdir: context.workdir, timeout: context.timeout)
        var blocks = try store.readBlocks(from: file)
        let codeBlock = ShowBlock.code(CodeBlock(language: language, code: code))
        let outputBlock = ShowBlock.output(OutputBlock(content: result.output))
        blocks.append(codeBlock)
        blocks.append(outputBlock)
        try store.writeBlocks(blocks, to: file)
        return result
    }

    public func diagram(file: String, language: String = "mermaid", source: String) throws {
        guard store.exists(file) else {
            throw ShowlessError.fileNotFound(file)
        }
        let canonical = DiagramLanguage.canonicalize(language)
        var blocks = try store.readBlocks(from: file)
        let codeBlock = ShowBlock.code(CodeBlock(language: canonical, code: source))
        blocks.append(codeBlock)
        try store.writeBlocks(blocks, to: file)
    }

    public func image(file: String, input: String) throws {
        guard store.exists(file) else {
            throw ShowlessError.fileNotFound(file)
        }
        let parsed = imageStore.parseInput(input)
        let destinationDirectory = URL(fileURLWithPath: file).deletingLastPathComponent().path
        let filename = try imageStore.copyImage(from: parsed.path, to: destinationDirectory)
        var blocks = try store.readBlocks(from: file)
        let alt = parsed.altText.isEmpty ? URL(fileURLWithPath: filename).deletingPathExtension().lastPathComponent : parsed.altText
        let codeBlock = ShowBlock.code(CodeBlock(language: "bash", code: input, isImage: true))
        let imageBlock = ShowBlock.imageOutput(ImageOutputBlock(altText: alt, filename: filename))
        blocks.append(codeBlock)
        blocks.append(imageBlock)
        try store.writeBlocks(blocks, to: file)
    }

    public func pop(file: String) throws {
        var blocks = try store.readBlocks(from: file)
        guard !blocks.isEmpty else {
            throw ShowlessError.emptyDocument
        }
        if blocks.count == 1, case .title = blocks[0] {
            throw ShowlessError.titleOnlyDocument
        }

        switch blocks.last {
        case .output, .imageOutput:
            if blocks.count >= 2 {
                blocks.removeLast(2)
            } else {
                blocks.removeLast()
            }
        default:
            blocks.removeLast()
        }

        try store.writeBlocks(blocks, to: file)
    }

    public func verify(file: String, outputFile: String? = nil, context: CommandContext = CommandContext()) throws -> [VerificationIssue] {
        var blocks = try store.readBlocks(from: file)
        var issues: [VerificationIssue] = []

        for index in blocks.indices {
            switch blocks[index] {
            case .code(let code) where !code.isImage && !code.isDiagram:
                let result = try runner.run(language: code.language, code: code.code, workdir: context.workdir, timeout: context.timeout)
                let next = blocks.index(after: index)
                if next < blocks.endIndex, case .output(let output) = blocks[next], output.content != result.output {
                    issues.append(VerificationIssue(
                        kind: .commandOutput,
                        blockIndex: index,
                        expected: output.content,
                        actual: result.output
                    ))
                    blocks[next] = .output(OutputBlock(content: result.output))
                }

            case .sourceExcerpt(let source):
                let actual = try readSourceExcerpt(source, sourceRoot: context.sourceRoot ?? context.workdir)
                if actual.content != source.content || actual.hash != source.hash {
                    issues.append(VerificationIssue(
                        kind: .sourceExcerpt,
                        blockIndex: index,
                        path: source.path,
                        expected: source.content,
                        actual: actual.content
                    ))
                    blocks[index] = .sourceExcerpt(actual)
                }

            default:
                continue
            }
        }

        if let outputFile, !outputFile.isEmpty {
            try store.writeBlocks(blocks, to: outputFile)
        }

        return issues
    }

    public func extract(file: String, outputFile: String? = nil, commandName: String = "showless") throws -> [String] {
        let blocks = try store.readBlocks(from: file)
        let target = outputFile?.isEmpty == false ? outputFile! : file
        let quotedTarget = ShellQuoting.quote(target)

        return blocks.compactMap { block in
            switch block {
            case .title(let title):
                return "\(commandName) init \(quotedTarget) \(ShellQuoting.quote(title.title))"
            case .commentary(let commentary):
                return "\(commandName) note \(quotedTarget) \(ShellQuoting.quote(commentary.text))"
            case .code(let code):
                if code.isImage {
                    return "\(commandName) image \(quotedTarget) \(ShellQuoting.quote(code.code))"
                }
                if code.isDiagram {
                    return "\(commandName) diagram \(quotedTarget) \(code.language) \(ShellQuoting.quote(code.code))"
                }
                return "\(commandName) exec \(quotedTarget) \(code.language) \(ShellQuoting.quote(code.code))"
            case .output, .imageOutput:
                return nil
            case .sourceExcerpt:
                return nil
            }
        }
    }

    public func walkthrough(repositoryPath: String, outputFile: String, options: WalkthroughOptions = WalkthroughOptions(), force: Bool = false) throws -> WalkthroughReport {
        if !force {
            try store.ensureNewFile(outputFile)
        }
        let blocks = try walkthroughEngine.generate(repositoryPath: repositoryPath, options: options, version: version)
        try store.writeBlocks(blocks, to: outputFile)
        return try walkthroughEngine.report(repositoryPath: repositoryPath, options: options)
    }

    public struct RenderHTMLReport: Sendable {
        public var outputPath: String
        public var diagramIssues: [HTMLRenderer.DiagramIssue]
    }

    public struct RenderDocsSiteReport: Codable, Sendable {
        public var outputDirectory: String
        public var pages: [String]
        public var assets: [String]
        public var diagramIssues: [DiagramIssueRecord]

        public struct DiagramIssueRecord: Codable, Sendable {
            public var diagramNumber: Int
            public var language: String
            public var firstLine: String
            public var message: String
        }
    }

    @discardableResult
    public func renderDocsSite(
        folder: String,
        outputFolder: String? = nil,
        options: DocsSiteRenderer.Options = DocsSiteRenderer.Options(),
        force: Bool = false
    ) throws -> RenderDocsSiteReport {
        guard FileManager.default.fileExists(atPath: folder) else {
            throw ShowlessError.fileNotFound(folder)
        }

        let resolvedOutput: String
        if let outputFolder, !outputFolder.isEmpty {
            resolvedOutput = outputFolder
        } else {
            resolvedOutput = URL(fileURLWithPath: folder).appendingPathComponent("_site").path
        }

        if !force, FileManager.default.fileExists(atPath: resolvedOutput) {
            throw ShowlessError.fileAlreadyExists(resolvedOutput)
        }

        try FileManager.default.createDirectory(atPath: resolvedOutput, withIntermediateDirectories: true)

        let report = try DocsSiteRenderer.render(folder: folder, outputFolder: resolvedOutput, options: options)
        let issues = report.diagramIssues.map { issue in
            RenderDocsSiteReport.DiagramIssueRecord(
                diagramNumber: issue.diagramNumber,
                language: issue.language,
                firstLine: issue.firstLine,
                message: issue.message
            )
        }
        return RenderDocsSiteReport(
            outputDirectory: report.outputDirectory,
            pages: report.pages,
            assets: report.assets,
            diagramIssues: issues
        )
    }

    @discardableResult
    public func renderHTML(
        file: String,
        outputFile: String? = nil,
        options: HTMLRenderer.Options = HTMLRenderer.Options(),
        force: Bool = false
    ) throws -> RenderHTMLReport {
        let blocks = try store.readBlocks(from: file)
        let issues = HTMLRenderer.lintDiagrams(blocks)
        let html = HTMLRenderer.render(blocks, options: options)

        let resolvedOutput: String
        if let outputFile, !outputFile.isEmpty {
            resolvedOutput = outputFile
        } else {
            resolvedOutput = URL(fileURLWithPath: file)
                .deletingPathExtension()
                .appendingPathExtension("html")
                .path
        }

        if !force, store.exists(resolvedOutput) {
            throw ShowlessError.fileAlreadyExists(resolvedOutput)
        }

        let outputURL = URL(fileURLWithPath: resolvedOutput)
        let parentDirectory = outputURL.deletingLastPathComponent().path
        if !parentDirectory.isEmpty, parentDirectory != "." {
            try FileManager.default.createDirectory(atPath: parentDirectory, withIntermediateDirectories: true)
        }
        try html.write(toFile: resolvedOutput, atomically: true, encoding: .utf8)
        return RenderHTMLReport(outputPath: resolvedOutput, diagramIssues: issues)
    }

    private func readSourceExcerpt(_ source: SourceExcerptBlock, sourceRoot: String?) throws -> SourceExcerptBlock {
        let sourceURL: URL
        if source.path.hasPrefix("/") {
            sourceURL = URL(fileURLWithPath: source.path)
        } else {
            sourceURL = URL(fileURLWithPath: sourceRoot ?? FileManager.default.currentDirectoryPath).appendingPathComponent(source.path)
        }
        let text = try String(contentsOf: sourceURL, encoding: .utf8)
        let lines = text.components(separatedBy: .newlines)
        let start = max(1, source.startLine)
        let end = min(max(start, source.endLine), lines.count)
        let excerpt = Array(lines[(start - 1)..<end]).joined(separator: "\n")
        return SourceExcerptBlock(
            path: source.path,
            language: source.language,
            startLine: start,
            endLine: end,
            hash: StableHash.contentHash(excerpt),
            content: excerpt
        )
    }
}
