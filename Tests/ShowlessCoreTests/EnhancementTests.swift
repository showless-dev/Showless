import Foundation
import Testing
@testable import ShowlessCore

@Suite struct EnhancementTests {
    @Test func unifiedDiffShowsExpectedAndActualLines() {
        let diff = UnifiedDiff.make(expected: "one\ntwo\n", actual: "one\nthree\n")
        #expect(diff.contains("--- expected"))
        #expect(diff.contains("-two"))
        #expect(diff.contains("+three"))
    }

    @Test func simpleYAMLConfiguration() throws {
        let directory = try temporaryDirectory()
        try """
        workdir: /tmp/project
        timeout: 5
        include: [Sources, Tests]
        exclude: [.build]
        walkthrough_depth: 3
        """.write(to: directory.appendingPathComponent(".showless.yml"), atomically: true, encoding: .utf8)

        let config = try ShowlessConfig.load(startingAt: directory.path)

        #expect(config.workdir == "/tmp/project")
        #expect(config.timeoutSeconds == 5)
        #expect(config.include == ["Sources", "Tests"])
        #expect(config.exclude == [".build"])
        #expect(config.walkthroughDepth == 3)
    }

    @Test func runnerTimeoutReturnsExit124() throws {
        let result = try ProcessRunner().run(language: "bash", code: "sleep 2", timeout: 0.1)
        #expect(result.exitCode == 124)
        #expect(result.timedOut)
        #expect(result.output.contains("timed out"))
    }

    @Test func htmlRendererProducesSelfContainedDocument() {
        let blocks: [ShowBlock] = [
            .title(TitleBlock(
                title: "Demo Walkthrough",
                timestamp: "2026-05-01T09:00:00Z",
                version: "test",
                documentID: "abc-123"
            )),
            .commentary(CommentaryBlock(text: "## 1. Intro\n\nA short *intro* with `code` and a [link](https://example.com).")),
            .code(CodeBlock(language: "bash", code: "echo hi")),
            .output(OutputBlock(content: "hi\n")),
            .commentary(CommentaryBlock(text: "### 1.1 A diagram")),
            .code(CodeBlock(language: "mermaid", code: "graph LR; A-->B")),
            .sourceExcerpt(SourceExcerptBlock(
                path: "Sources/Foo.swift",
                language: "swift",
                startLine: 10,
                endLine: 12,
                hash: "fnv1a64:abcdef0123456789",
                content: "let x = 1\nlet y = 2"
            ))
        ]

        let html = HTMLRenderer.render(blocks)

        #expect(html.hasPrefix("<!doctype html>"))
        #expect(html.contains("<title>Demo Walkthrough</title>"))
        #expect(html.contains("hero-title"))
        #expect(html.contains("class=\"toc\""))
        #expect(html.contains("id=\"1-intro\""))
        #expect(html.contains("class=\"language-bash hljs\""))
        #expect(html.contains("output-block"))
        #expect(html.contains("source-excerpt"))
        #expect(html.contains("L10\u{2013}L12") || html.contains("L10–L12"))
        #expect(html.contains("<pre class=\"mermaid\">"))
        #expect(html.contains("highlight.min.js"))
        #expect(html.contains("mermaid.min.js"))
        #expect(!html.contains("<script type=\"module\""))
    }

    @Test func htmlRendererEscapesAngleBrackets() {
        let blocks: [ShowBlock] = [
            .title(TitleBlock(title: "<script>alert(1)</script>", timestamp: "now", version: "test")),
            .commentary(CommentaryBlock(text: "Text with <b>tags</b>"))
        ]
        let html = HTMLRenderer.render(blocks)
        #expect(!html.contains("<script>alert(1)</script>"))
        #expect(html.contains("&lt;script&gt;alert(1)&lt;/script&gt;"))
        #expect(html.contains("&lt;b&gt;tags&lt;/b&gt;"))
    }

    @Test func serviceRenderHTMLWritesFile() throws {
        let directory = try temporaryDirectory()
        let markdown = directory.appendingPathComponent("demo.md").path
        let service = ShowlessService(version: "test")
        try service.initDocument(file: markdown, title: "Demo")
        try service.note(file: markdown, text: "## 1. Intro\n\nHello.")

        let report = try service.renderHTML(file: markdown)
        #expect(FileManager.default.fileExists(atPath: report.outputPath))
        #expect(report.outputPath.hasSuffix(".html"))
        #expect(report.diagramIssues.isEmpty)
        let html = try String(contentsOfFile: report.outputPath, encoding: .utf8)
        #expect(html.contains("<title>Demo</title>"))
        #expect(html.contains("id=\"1-intro\""))
    }

    @Test func htmlRendererLintsBadMermaidDiagrams() {
        let blocks: [ShowBlock] = [
            .title(TitleBlock(title: "Demo", timestamp: "now", version: "test")),
            .code(CodeBlock(language: "mermaid", code: "graph LR\n  A --> B")),
            .code(CodeBlock(language: "mermaid", code: "totallyBogusKeyword\n  Foo -- /usr/bin/x --> Bar"))
        ]
        let issues = HTMLRenderer.lintDiagrams(blocks)
        #expect(issues.count == 2)
        #expect(issues.contains(where: { $0.diagramNumber == 2 && $0.message.contains("recognised mermaid keyword") }))
        #expect(issues.contains(where: { $0.diagramNumber == 2 && $0.message.contains("/") }))
    }

    @Test func htmlRendererInfersOutputLanguageFromPrecedingShellCommand() {
        let blocks: [ShowBlock] = [
            .title(TitleBlock(title: "Demo", timestamp: "now", version: "test")),
            .code(CodeBlock(language: "bash", code: "sed -n '23,37p' Sources/ShowlessCore/Blocks.swift")),
            .output(OutputBlock(content: "public struct TitleBlock: Equatable, Sendable {\n    public var title: String\n}")),
            .code(CodeBlock(language: "bash", code: "echo hi")),
            .output(OutputBlock(content: "hi"))
        ]
        let html = HTMLRenderer.render(blocks)
        #expect(html.contains(#"<code class="output-content language-swift hljs">"#))
        #expect(html.contains(#"<code class="output-content">"#))
    }

    @Test func htmlRendererProducesMermaidErrorBlockMarkup() {
        let html = HTMLRenderer.render([
            .title(TitleBlock(title: "Demo", timestamp: "now", version: "test")),
            .code(CodeBlock(language: "mermaid", code: "graph LR\n  A --> B"))
        ])
        #expect(html.contains("mermaid-error"))
        #expect(html.contains("makeErrorBlock"))
        #expect(html.contains("white-space: pre-wrap"))
    }

    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("showless-enhancement-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}
