import Testing
@testable import ShowlessCore

@Suite struct MarkdownTests {
    @Test func parseAndWriteShowlessDocument() throws {
        let input = """
        # Demo

        *2026-02-06T15:30:00Z by Showless dev*
        <!-- showless-id: abc-123 -->

        Some commentary.

        ```bash
        echo hello
        ```

        ```output
        hello
        ```

        ```bash {image}
        screenshot.png
        ```

        ![screenshot](abc-2026-02-06.png)
        """

        let blocks = try MarkdownParser.parse(input)
        #expect(blocks.count == 6)
        #expect(try MarkdownWriter.write(blocks) == input + "\n")
    }

    @Test func outputFenceExpandsForBackticksAtLineStart() throws {
        let block = ShowBlock.output(OutputBlock(content: "```\ninside\n"))
        #expect(try MarkdownWriter.write([block]).hasPrefix("````output"))
    }

    @Test func sourceExcerptRoundTrips() throws {
        let source = SourceExcerptBlock(
            path: "Sources/App/main.swift",
            language: "swift",
            startLine: 1,
            endLine: 2,
            hash: "fnv1a64:test",
            content: "print(\"hello\")\nprint(\"world\")"
        )
        let markdown = try MarkdownWriter.write([.sourceExcerpt(source)])
        #expect(try MarkdownParser.parse(markdown) == [.sourceExcerpt(source)])
    }

    @Test func imageReferenceParser() {
        let parsed = MarkdownParser.parseImageReference("![Alt text](image.png)")
        #expect(parsed.alt == "Alt text")
        #expect(parsed.filename == "image.png")
    }
}
