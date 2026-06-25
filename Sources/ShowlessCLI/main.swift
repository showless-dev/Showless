import ArgumentParser
import ShowlessCore
import Foundation

private let appVersion = "1.0"

// MARK: - Shared global options

struct GlobalOptions: ParsableArguments {
    @Option(help: "Set working directory for code execution (default: current)")
    var workdir: String?

    @Option(name: .customLong("source-root"), help: "Set repository root for source excerpt verification")
    var sourceRoot: String?

    @Option(help: "Limit command execution time in seconds")
    var timeout: Double?

    @Flag(help: "Emit machine-readable JSON where supported")
    var json: Bool = false
}

// MARK: - Entry point

struct ShowlessCLI: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "showless",
        abstract: "Create executable demo documents that show and prove an agent's work.",
        discussion: """
        Showless helps agents build markdown documents that mix commentary, \
        executable code blocks, captured output, image references, and verifiable \
        source excerpts. These documents serve as both readable documentation and \
        reproducible proof of work. A verifier can re-execute code blocks and \
        confirm the outputs still match.

        Commands accept input from stdin when the text/code argument is omitted:
          echo "Hello world" | showless note demo
          cat script.sh | showless exec demo bash

        File arguments do not require a .md extension — it is appended automatically.
        """,
        version: appVersion,
        subcommands: [
            InitCommand.self,
            NoteCommand.self,
            ExecCommand.self,
            ImageCommand.self,
            DiagramCommand.self,
            PopCommand.self,
            VerifyCommand.self,
            ExtractCommand.self,
            WalkthroughCommand.self,
            HTMLCommand.self,
            DocsHTMLCommand.self,
        ]
    )
}

ShowlessCLI.main()

// MARK: - Helpers

private func makeService() -> ShowlessService {
    ShowlessService(version: appVersion)
}

private func resolvedContext(globals: GlobalOptions) -> CommandContext {
    let config = (try? ShowlessConfig.load()) ?? ShowlessConfig()
    return CommandContext(
        workdir: globals.workdir ?? config.workdir,
        sourceRoot: globals.sourceRoot,
        timeout: globals.timeout ?? config.timeoutSeconds,
        json: globals.json
    )
}

private func readStdin() -> String {
    String(decoding: FileHandle.standardInput.readDataToEndOfFile(), as: UTF8.self)
}

private func printRaw(_ output: String) {
    FileHandle.standardOutput.write(Data(output.utf8))
}

private func printJSON<T: Encodable>(_ value: T) {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    guard let data = try? encoder.encode(value) else { return }
    print(String(decoding: data, as: UTF8.self))
}

private func defaultWalkthroughOutputPath(for repositoryPath: String) -> String {
    let repoName = URL(fileURLWithPath: repositoryPath).standardizedFileURL.lastPathComponent
    let base = sanitizedFilename(repoName.isEmpty ? "codewalk" : repoName)
    return URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        .appendingPathComponent("codewalks")
        .appendingPathComponent("\(base)-codewalk.md")
        .path
}

private func sanitizedFilename(_ value: String) -> String {
    let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_."))
    let chars = value.unicodeScalars.map { allowed.contains($0) ? Character($0) : Character("-") }
    let sanitized = String(chars).trimmingCharacters(in: CharacterSet(charactersIn: "-."))
    return sanitized.isEmpty ? "codewalk" : sanitized
}

private func resolvedFile(_ path: String) -> String {
    path.hasSuffix(".md") ? path : path + ".md"
}

// MARK: - init

struct InitCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "init",
        abstract: "Create a new demo document"
    )

    @Argument(help: "Path to the document file to create")
    var file: String

    @Argument(help: "Title of the document")
    var title: String

    @Flag(help: "Replace an existing document file")
    var force: Bool = false

    func run() throws {
        let path = resolvedFile(file)
        if force, FileManager.default.fileExists(atPath: path) {
            try FileManager.default.removeItem(atPath: path)
        }
        try makeService().initDocument(file: path, title: title)
    }
}

// MARK: - note

struct NoteCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "note",
        abstract: "Append commentary text to a document"
    )

    @Argument(help: "Path to the document file")
    var file: String

    @Argument(help: "Commentary text (reads from stdin when omitted)")
    var text: String?

    func run() throws {
        try makeService().note(file: resolvedFile(file), text: text ?? readStdin())
    }
}

// MARK: - exec

struct ExecCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "exec",
        abstract: "Run code and capture output into a document"
    )

    @OptionGroup var globals: GlobalOptions

    @Argument(help: "Path to the document file")
    var file: String

    @Argument(help: "Language / runner (e.g. bash, python3)")
    var language: String

    @Argument(
        parsing: .remaining,
        help: "Code to run (remaining words are joined; reads from stdin when omitted)"
    )
    var codeParts: [String] = []

    func run() throws {
        let code = codeParts.isEmpty ? readStdin() : codeParts.joined(separator: " ")
        let result = try makeService().execute(
            file: resolvedFile(file),
            language: language,
            code: code,
            context: resolvedContext(globals: globals)
        )
        printRaw(result.output)
        if result.exitCode != 0 {
            // Propagate the subprocess exit code without printing an extra error line.
            Foundation.exit(result.exitCode)
        }
    }
}

// MARK: - image

struct ImageCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "image",
        abstract: "Copy an image into a document",
        discussion: """
        Accepts a plain file path or a markdown image reference of the form
        ![alt text](path). The image is copied next to the document and a
        markdown reference is appended, preserving any alt text.
        """
    )

    @Argument(help: "Path to the document file")
    var file: String

    @Argument(help: #"Image path or markdown reference "![alt](path)" (reads from stdin when omitted)"#)
    var input: String?

    func run() throws {
        try makeService().image(file: resolvedFile(file), input: input ?? readStdin())
    }
}

// MARK: - diagram

struct DiagramCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "diagram",
        abstract: "Append a diagram block (mermaid, plantuml, dot, d2…)",
        discussion: """
        If the first positional argument is a recognised diagram language keyword \
        (mermaid, plantuml, puml, dot, graphviz, d2) it is used as the language; \
        otherwise it is treated as part of the source and the language defaults to \
        mermaid. Source may also be piped via stdin.
        """
    )

    @Argument(help: "Path to the document file")
    var file: String

    @Argument(
        parsing: .remaining,
        help: "[<lang>] [<source>] — language keyword followed by diagram source, or just source"
    )
    var rest: [String] = []

    func run() throws {
        let (language, source) = resolvedDiagramArgs()
        try makeService().diagram(file: resolvedFile(file), language: language, source: source)
    }

    private func resolvedDiagramArgs() -> (language: String, source: String) {
        guard let first = rest.first else {
            return ("mermaid", readStdin())
        }
        if DiagramLanguage.known.contains(first.lowercased()) {
            let src = rest.dropFirst().joined(separator: " ")
            return (DiagramLanguage.canonicalize(first), src.isEmpty ? readStdin() : src)
        }
        return ("mermaid", rest.joined(separator: " "))
    }
}

// MARK: - pop

struct PopCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "pop",
        abstract: "Remove the most recent entry from a document"
    )

    @Argument(help: "Path to the document file")
    var file: String

    func run() throws {
        try makeService().pop(file: resolvedFile(file))
    }
}

// MARK: - verify

struct VerifyCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "verify",
        abstract: "Re-run executable blocks and diff against recorded output",
        discussion: """
        Exits with code 1 if any block's output has changed or any source excerpt \
        has drifted. Exits 0 when everything matches. Use --output to write an \
        updated copy without modifying the original.
        """
    )

    @OptionGroup var globals: GlobalOptions

    @Argument(help: "Path to the document file")
    var file: String

    @Option(help: "Write the updated document to this path instead of modifying the original")
    var output: String?

    func run() throws {
        let issues = try makeService().verify(
            file: resolvedFile(file),
            outputFile: output,
            context: resolvedContext(globals: globals)
        )
        if globals.json {
            printJSON(issues)
        } else {
            for issue in issues { print(issue.humanDescription) }
        }
        if !issues.isEmpty {
            throw ExitCode.failure
        }
    }
}

// MARK: - extract

struct ExtractCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "extract",
        abstract: "Emit CLI commands that would recreate a document from scratch"
    )

    @Argument(help: "Path to the document file")
    var file: String

    @Option(help: "Substitute this filename in the emitted commands")
    var filename: String?

    @Option(name: .customLong("command-name"), help: "CLI binary name to use in emitted commands (default: showless)")
    var commandName: String = "showless"

    func run() throws {
        let commands = try makeService().extract(file: resolvedFile(file), outputFile: filename, commandName: commandName)
        for command in commands { print(command) }
    }
}

// MARK: - codewalk

struct WalkthroughCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "codewalk",
        abstract: "Generate a static scaffold document for an existing repository",
        discussion: """
        Scans the repository and produces a markdown scaffold with project shape, \
        likely entry points, tests, CI files, TODO markers, and verifiable source \
        excerpts. Writes to ./codewalks/<repo>-codewalk.md by default. \
        This is a starting point for an agent-authored codewalk, not a \
        replacement for code understanding.
        """
    )

    @OptionGroup var globals: GlobalOptions

    @Argument(help: "Path to the repository to scan")
    var repo: String

    @Option(help: "Output path (default: ./codewalks/<repo>-codewalk.md)")
    var output: String?

    @Option(help: "Document title (default: \"<repo> Codewalk Scaffold\")")
    var title: String?

    @Option(help: "Directory scan depth (default from config or 2)")
    var depth: Int?

    @Option(name: .customLong("include"), help: "Glob pattern to include (repeatable)")
    var include: [String] = []

    @Option(name: .customLong("exclude"), help: "Glob pattern to exclude (repeatable)")
    var exclude: [String] = []

    @Flag(help: "Overwrite an existing output file")
    var force: Bool = false

    func run() throws {
        let config = (try? ShowlessConfig.load()) ?? ShowlessConfig()
        let outputPath = output ?? defaultWalkthroughOutputPath(for: repo)
        let report = try makeService().walkthrough(
            repositoryPath: repo,
            outputFile: outputPath,
            options: WalkthroughOptions(
                title: title,
                depth: depth ?? config.walkthroughDepth,
                include: include.isEmpty ? config.include : include,
                exclude: exclude.isEmpty ? config.exclude : exclude
            ),
            force: force
        )
        if globals.json {
            printJSON(report)
        } else {
            print("Wrote codewalk to \(outputPath)")
        }
    }
}

// MARK: - html

struct HTMLCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "codewalk-html",
        abstract: "Render a walkthrough markdown document as a beautiful, self-contained HTML page",
        discussion: """
        Generates a stand-alone HTML file with a sticky table of contents, syntax \
        highlighting, mermaid diagrams, dark/light themes, copy-to-clipboard buttons, \
        and a reading-progress bar. Highlighting and diagrams load from public CDNs \
        at view time; the page itself has no other dependencies.

          showless codewalk-html walkthrough
          showless codewalk-html walkthrough --output dist/walkthrough.html --force
        """
    )

    @Argument(help: "Path to the walkthrough markdown file")
    var file: String

    @Option(help: "Output HTML path (default: alongside the markdown file with .html)")
    var output: String?

    @Option(help: "Override the document title that appears in the hero")
    var title: String?

    @Option(help: "Subtitle/tagline displayed under the title")
    var subtitle: String?

    @Flag(help: "Hide the rendered footer at the bottom of the page")
    var noFooter: Bool = false

    @Flag(help: "Overwrite an existing output file")
    var force: Bool = false

    func run() throws {
        let renderOptions = HTMLRenderer.Options(
            titleOverride: title,
            subtitle: subtitle,
            includeFooter: !noFooter
        )
        let report = try makeService().renderHTML(
            file: resolvedFile(file),
            outputFile: output,
            options: renderOptions,
            force: force
        )

        if !report.diagramIssues.isEmpty {
            let header = "showless: \(report.diagramIssues.count) diagram warning(s):\n"
            FileHandle.standardError.write(Data(header.utf8))
            for issue in report.diagramIssues {
                let line = "  • \(issue.humanDescription)\n"
                FileHandle.standardError.write(Data(line.utf8))
            }
            FileHandle.standardError.write(Data("  (rendered HTML still shows these errors inline in the diagram container)\n".utf8))
        }

        print("Wrote HTML to \(report.outputPath)")
    }
}

// MARK: - docs-html

struct DocsHTMLCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "docs-html",
        abstract: "Render a folder of markdown docs into a multi-page HTML site",
        discussion: """
        Walks the input folder for .md files and produces one HTML page per \
        markdown file in the output directory, preserving the relative layout. \
        Subfolders become sidebar groups; `reference/` is forced last. \
        Non-markdown files (images, PDFs, etc.) are copied alongside so \
        relative references like `![chart](images/chart.png)` resolve. Visual \
        styling matches the codewalk HTML output.

          showless docs-html docs/
          showless docs-html docs/ --output dist/site --title "MyProject Docs" --force

        Optional YAML frontmatter at the top of each .md file controls per-page \
        metadata:

          ---
          title: Getting Started
          nav_label: Getting Started
          nav_order: 2
          subtitle: Install in 60 seconds
          ---
        """
    )

    @OptionGroup var globals: GlobalOptions

    @Argument(help: "Path to the docs folder containing .md files")
    var folder: String

    @Option(help: "Output directory (default: <folder>/_site)")
    var output: String?

    @Option(help: "Site title shown in the sidebar header and <title>")
    var title: String?

    @Option(help: "Subtitle / tagline shown under the site title")
    var subtitle: String?

    @Flag(help: "Hide the rendered footer")
    var noFooter: Bool = false

    @Flag(help: "Overwrite an existing output directory")
    var force: Bool = false

    func run() throws {
        let options = DocsSiteRenderer.Options(
            siteTitle: title,
            subtitle: subtitle,
            includeFooter: !noFooter
        )
        let report = try makeService().renderDocsSite(
            folder: folder,
            outputFolder: output,
            options: options,
            force: force
        )

        if globals.json {
            printJSON(report)
            return
        }

        if !report.diagramIssues.isEmpty {
            let header = "showless: \(report.diagramIssues.count) diagram warning(s):\n"
            FileHandle.standardError.write(Data(header.utf8))
            for issue in report.diagramIssues {
                let line = "  • diagram #\(issue.diagramNumber) (\(issue.language)): \(issue.message)\n"
                FileHandle.standardError.write(Data(line.utf8))
            }
        }

        let pageCount = report.pages.count
        let assetCount = report.assets.count
        var summary = "Wrote docs site to \(report.outputDirectory) (\(pageCount) page\(pageCount == 1 ? "" : "s")"
        if assetCount > 0 {
            summary += ", \(assetCount) asset\(assetCount == 1 ? "" : "s")"
        }
        summary += ")"
        print(summary)
    }
}
