import Foundation
import Testing
@testable import ShowlessCore

@Suite struct ServiceTests {
    @Test func initNoteExecVerifyAndExtract() throws {
        let directory = try temporaryDirectory()
        let file = directory.appendingPathComponent("demo.md").path
        let service = ShowlessService(version: "test")

        try service.initDocument(file: file, title: "Demo")
        try service.note(file: file, text: "First note")
        let result = try service.execute(file: file, language: "bash", code: "echo hello")
        #expect(result.output == "hello\n")
        #expect(result.exitCode == 0)

        #expect(try service.verify(file: file) == [])
        let commands = try service.extract(file: file)
        #expect(commands.contains("showless note \(file) 'First note'") || commands.contains("showless note '\(file)' 'First note'"))
    }

    @Test func failedExecIsRecorded() throws {
        let directory = try temporaryDirectory()
        let file = directory.appendingPathComponent("demo.md").path
        let service = ShowlessService(version: "test")

        try service.initDocument(file: file, title: "Demo")
        let result = try service.execute(file: file, language: "bash", code: "echo nope && exit 7")

        #expect(result.output == "nope\n")
        #expect(result.exitCode == 7)
        let blocks = try MarkdownParser.parse(String(contentsOfFile: file, encoding: .utf8))
        #expect(blocks.count == 3)
    }

    @Test func popRemovesCodeAndOutputPair() throws {
        let directory = try temporaryDirectory()
        let file = directory.appendingPathComponent("demo.md").path
        let service = ShowlessService(version: "test")

        try service.initDocument(file: file, title: "Demo")
        _ = try service.execute(file: file, language: "bash", code: "echo hello")
        try service.pop(file: file)

        let blocks = try MarkdownParser.parse(String(contentsOfFile: file, encoding: .utf8))
        #expect(blocks.count == 1)
    }

    @Test func imageCopiesFileAndAppendsImageBlocks() throws {
        let directory = try temporaryDirectory()
        let file = directory.appendingPathComponent("demo.md").path
        let image = directory.appendingPathComponent("source.png")
        try Data([0x89, 0x50, 0x4E, 0x47]).write(to: image)
        let service = ShowlessService(version: "test")

        try service.initDocument(file: file, title: "Demo")
        try service.image(file: file, input: "![Screenshot](\(image.path))")

        let blocks = try MarkdownParser.parse(String(contentsOfFile: file, encoding: .utf8))
        #expect(blocks.count == 3)
        guard case .imageOutput(let output) = blocks.last else {
            Issue.record("Expected image output block")
            return
        }
        #expect(output.altText == "Screenshot")
        #expect(output.filename.hasSuffix(".png"))
        #expect(FileManager.default.fileExists(atPath: directory.appendingPathComponent(output.filename).path))
    }

    @Test func diagramAppendsBlockAndIsSkippedByVerify() throws {
        let directory = try temporaryDirectory()
        let file = directory.appendingPathComponent("demo.md").path
        let service = ShowlessService(version: "test")

        try service.initDocument(file: file, title: "Demo")
        try service.diagram(file: file, language: "Mermaid", source: "graph TD\nA-->B")

        let blocks = try MarkdownParser.parse(String(contentsOfFile: file, encoding: .utf8))
        #expect(blocks.count == 2)
        guard case .code(let code) = blocks[1] else {
            Issue.record("Expected code block")
            return
        }
        #expect(code.language == "mermaid")
        #expect(code.isDiagram)
        #expect(!code.isImage)
        #expect(code.code.contains("graph TD"))

        #expect(try service.verify(file: file) == [])

        let commands = try service.extract(file: file)
        #expect(commands.contains { $0.contains("showless diagram") && $0.contains("mermaid") })
        #expect(!commands.contains { $0.contains("showless exec") })
    }

    @Test func diagramPopRemovesSingleBlock() throws {
        let directory = try temporaryDirectory()
        let file = directory.appendingPathComponent("demo.md").path
        let service = ShowlessService(version: "test")

        try service.initDocument(file: file, title: "Demo")
        try service.diagram(file: file, language: "mermaid", source: "graph TD; A-->B")
        try service.pop(file: file)

        let blocks = try MarkdownParser.parse(String(contentsOfFile: file, encoding: .utf8))
        #expect(blocks.count == 1)
    }

    @Test func walkthroughIncludesSourceExcerpt() throws {
        let repo = try temporaryDirectory()
        try "print(\"hello\")\n".write(to: repo.appendingPathComponent("main.swift"), atomically: true, encoding: .utf8)
        try "// swift-tools-version: 6.2\n".write(to: repo.appendingPathComponent("Package.swift"), atomically: true, encoding: .utf8)

        let output = repo.appendingPathComponent("walkthrough.md").path
        let service = ShowlessService(version: "test")
        let report = try service.walkthrough(repositoryPath: repo.path, outputFile: output, options: WalkthroughOptions(depth: 1))

        #expect(report.manifestFiles.contains("Package.swift"))
        let blocks = try MarkdownParser.parse(String(contentsOfFile: output, encoding: .utf8))
        #expect(blocks.contains { if case .sourceExcerpt = $0 { true } else { false } })
        #expect(try service.verify(file: output, context: CommandContext(sourceRoot: repo.path)) == [])
    }

    @Test func verifyDetectsStaleSourceExcerpt() throws {
        let repo = try temporaryDirectory()
        let source = repo.appendingPathComponent("main.swift")
        try "print(\"hello\")\n".write(to: source, atomically: true, encoding: .utf8)
        try "// swift-tools-version: 6.2\n".write(to: repo.appendingPathComponent("Package.swift"), atomically: true, encoding: .utf8)

        let output = repo.appendingPathComponent("walkthrough.md").path
        let refreshed = repo.appendingPathComponent("refreshed.md").path
        let service = ShowlessService(version: "test")
        _ = try service.walkthrough(repositoryPath: repo.path, outputFile: output, options: WalkthroughOptions(depth: 1))

        try "print(\"changed\")\n".write(to: source, atomically: true, encoding: .utf8)
        let issues = try service.verify(file: output, outputFile: refreshed, context: CommandContext(sourceRoot: repo.path))

        #expect(issues.count == 1)
        #expect(issues[0].kind == .sourceExcerpt)
        #expect(FileManager.default.fileExists(atPath: refreshed))
    }

    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("showless-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}
