import Foundation

/// Renders a Showless document (a list of `ShowBlock`s) into a beautiful,
/// self-contained HTML page suitable for sharing or hosting.
///
/// The renderer ships its own CSS and JavaScript inline so the resulting file
/// has no local assets to copy around. Syntax highlighting (highlight.js) and
/// diagram rendering (mermaid.js) are loaded from public CDNs at view time.
public enum HTMLRenderer {
    public struct Options: Sendable {
        public var titleOverride: String?
        public var subtitle: String?
        public var includeFooter: Bool

        public init(titleOverride: String? = nil, subtitle: String? = nil, includeFooter: Bool = true) {
            self.titleOverride = titleOverride
            self.subtitle = subtitle
            self.includeFooter = includeFooter
        }
    }

    /// A static, best-effort warning produced while inspecting a diagram block.
    /// These never abort rendering — they are emitted alongside the HTML so
    /// authors can spot likely mermaid syntax problems before publishing.
    public struct DiagramIssue: Equatable, Sendable {
        public var diagramNumber: Int
        public var language: String
        public var firstLine: String
        public var message: String

        public init(diagramNumber: Int, language: String, firstLine: String, message: String) {
            self.diagramNumber = diagramNumber
            self.language = language
            self.firstLine = firstLine
            self.message = message
        }

        public var humanDescription: String {
            "diagram #\(diagramNumber) (\(language)): \(message)"
        }
    }

    /// Recognised mermaid root keywords. The lint only fires when a diagram's
    /// first non-empty, non-comment line does not begin with one of these.
    /// Kept intentionally permissive — false negatives are better than false
    /// positives during HTML generation.
    private static let mermaidKeywords: [String] = [
        "graph", "flowchart", "sequenceDiagram", "classDiagram",
        "stateDiagram", "stateDiagram-v2", "erDiagram", "journey",
        "gantt", "pie", "gitGraph", "mindmap", "timeline",
        "quadrantChart", "requirementDiagram",
        "C4Context", "C4Container", "C4Component", "C4Dynamic", "C4Deployment",
        "xychart-beta", "block-beta", "sankey-beta", "architecture-beta",
        "info"
    ]

    public static func lintDiagrams(_ blocks: [ShowBlock]) -> [DiagramIssue] {
        var issues: [DiagramIssue] = []
        var diagramNumber = 0

        for block in blocks {
            guard case .code(let code) = block, code.isDiagram else { continue }
            diagramNumber += 1

            let language = code.language.lowercased()
            let lines = code.code.components(separatedBy: "\n")
            let firstLine = lines.first(where: { line in
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                return !trimmed.isEmpty && !trimmed.hasPrefix("%%")
            })?.trimmingCharacters(in: .whitespaces) ?? ""

            if firstLine.isEmpty {
                issues.append(DiagramIssue(
                    diagramNumber: diagramNumber,
                    language: code.language,
                    firstLine: "",
                    message: "diagram source is empty"
                ))
                continue
            }

            if language == "mermaid" {
                let firstWord = firstLine.split(whereSeparator: { $0.isWhitespace }).first.map(String.init) ?? ""
                let starts = mermaidKeywords.contains(where: { firstWord.hasPrefix($0) || $0.hasPrefix(firstWord) })
                if !starts {
                    issues.append(DiagramIssue(
                        diagramNumber: diagramNumber,
                        language: code.language,
                        firstLine: firstLine,
                        message: "first line does not start with a recognised mermaid keyword (\(firstWord)); the browser will display a parse error inline"
                    ))
                }

                // Heuristic: warn about edge labels that contain `/` or `\` —
                // the most common cause of "syntax error" messages from the
                // mermaid flowchart grammar (e.g. `A -- /usr/bin/x --> B`).
                // The non-greedy capture allows hyphens inside the label
                // (`-c`, `-v`, etc.) so `Runner -- /usr/bin/env lang -c code -->`
                // is still flagged.
                let labelPattern = #"--\s+((?:(?!-->)[^\n])*?[/\\](?:(?!-->)[^\n])*?)\s+-->"#
                if let regex = try? NSRegularExpression(pattern: labelPattern) {
                    for (offset, raw) in lines.enumerated() {
                        let nsRange = NSRange(raw.startIndex..<raw.endIndex, in: raw)
                        let matches = regex.matches(in: raw, range: nsRange)
                        for match in matches where match.numberOfRanges >= 2 {
                            if let labelRange = Range(match.range(at: 1), in: raw) {
                                let label = String(raw[labelRange]).trimmingCharacters(in: .whitespaces)
                                issues.append(DiagramIssue(
                                    diagramNumber: diagramNumber,
                                    language: code.language,
                                    firstLine: firstLine,
                                    message: "line \(offset + 1) edge label `\(label)` contains `/` or `\\`; mermaid often refuses to parse this — quote it as `-- \"\(label)\" -->`"
                                ))
                            }
                        }
                    }
                }
            }
        }

        return issues
    }

    public static func render(_ blocks: [ShowBlock], options: Options = Options()) -> String {
        let titleBlock = blocks.compactMap { block -> TitleBlock? in
            if case .title(let title) = block { return title }
            return nil
        }.first

        let pageTitle = options.titleOverride
            ?? titleBlock?.title
            ?? "Showless Walkthrough"

        let toc = buildTOC(blocks)
        let body = renderBody(blocks, toc: toc)

        return assembleHTML(
            pageTitle: pageTitle,
            titleBlock: titleBlock,
            toc: toc,
            body: body,
            options: options
        )
    }

    /// Returns the inner pieces of a rendered page so other renderers (e.g. the
    /// docs-site renderer) can wrap the article body in their own shell while
    /// reusing the same block-level styling.
    struct InnerRender {
        var titleBlock: TitleBlock?
        var toc: [TOCEntry]
        var body: String
    }

    static func renderInner(_ blocks: [ShowBlock]) -> InnerRender {
        let titleBlock = blocks.compactMap { block -> TitleBlock? in
            if case .title(let title) = block { return title }
            return nil
        }.first
        let toc = buildTOC(blocks)
        let body = renderBody(blocks, toc: toc)
        return InnerRender(titleBlock: titleBlock, toc: toc, body: body)
    }

    /// Renders an in-page TOC `<aside>` block, identical to what `render`
    /// emits for a single codewalk page. Returns an empty string when the
    /// supplied TOC has no entries.
    static func renderTOCAside(_ toc: [TOCEntry]) -> String {
        guard !toc.isEmpty else { return "" }
        var items = ""
        for entry in toc {
            items += """
            <li class="toc-item toc-level-\(entry.level)"><a href="#\(attributeEscape(entry.slug))">\(htmlEscape(entry.title))</a></li>
            """
        }
        return """
        <aside class="toc" aria-label="Table of contents">
          <div class="toc-inner">
            <div class="toc-title">On this page</div>
            <ol class="toc-list">\(items)</ol>
          </div>
        </aside>
        """
    }

    static func escapeAttribute(_ text: String) -> String { attributeEscape(text) }
    static func escapeText(_ text: String) -> String { htmlEscape(text) }

    // MARK: - Table of contents

    struct TOCEntry: Sendable {
        var level: Int
        var title: String
        var slug: String
    }

    static func buildTOC(_ blocks: [ShowBlock]) -> [TOCEntry] {
        var entries: [TOCEntry] = []
        var seen: [String: Int] = [:]

        func addEntry(level: Int, raw: String) {
            let cleaned = stripInlineMarkdown(raw)
            let baseSlug = slugify(cleaned)
            let slug: String
            if let count = seen[baseSlug] {
                slug = "\(baseSlug)-\(count + 1)"
                seen[baseSlug] = count + 1
            } else {
                slug = baseSlug
                seen[baseSlug] = 1
            }
            entries.append(TOCEntry(level: level, title: cleaned, slug: slug))
        }

        for block in blocks {
            guard case .commentary(let commentary) = block else { continue }
            for line in commentary.text.components(separatedBy: "\n") {
                if line.hasPrefix("## ") {
                    addEntry(level: 2, raw: String(line.dropFirst(3)))
                } else if line.hasPrefix("### ") {
                    addEntry(level: 3, raw: String(line.dropFirst(4)))
                }
            }
        }

        return entries
    }

    // MARK: - Body

    static func renderBody(_ blocks: [ShowBlock], toc: [TOCEntry]) -> String {
        var html = ""
        var headingCursor = 0
        var lastCodeBlock: CodeBlock? = nil

        for block in blocks {
            switch block {
            case .title:
                continue
            case .commentary(let commentary):
                html += renderCommentary(commentary.text, toc: toc, cursor: &headingCursor)
            case .code(let code):
                html += renderCodeBlock(code)
                if !code.isImage, !code.isDiagram {
                    lastCodeBlock = code
                } else {
                    lastCodeBlock = nil
                }
            case .output(let output):
                let inferred = inferOutputLanguage(precedingCode: lastCodeBlock)
                html += renderOutput(output, inferredLanguage: inferred)
                lastCodeBlock = nil
            case .imageOutput(let image):
                html += renderImage(image)
                lastCodeBlock = nil
            case .sourceExcerpt(let source):
                html += renderSourceExcerpt(source)
                lastCodeBlock = nil
            }
        }

        return html
    }

    /// Inspects the most recent shell command (e.g. `sed -n '20,40p' file.swift`)
    /// and pulls out a likely language for the output that follows. Returns nil
    /// when no extension-bearing file argument is found, in which case the JS
    /// side falls back to highlight.js auto-detection.
    private static func inferOutputLanguage(precedingCode: CodeBlock?) -> String? {
        guard let code = precedingCode else { return nil }
        let lower = code.language.lowercased()
        guard ["bash", "sh", "zsh", "shell"].contains(lower) else { return nil }

        // Look for the LAST `*.<ext>` token on the command line, since `sed -n '1,5p' Foo.swift` /
        // `cat ./Sources/Bar.go` / `awk '...' Baz.py` all put the file at or near the end.
        let pattern = #"(?i)\b[^\s'"`<>|;]+\.([A-Za-z0-9]{1,8})\b"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let range = NSRange(code.code.startIndex..<code.code.endIndex, in: code.code)
        let matches = regex.matches(in: code.code, range: range)
        guard let last = matches.last, last.numberOfRanges >= 2,
              let extRange = Range(last.range(at: 1), in: code.code) else {
            return nil
        }
        let ext = String(code.code[extRange]).lowercased()
        return canonicalLanguage(forExtension: ext)
    }

    private static func canonicalLanguage(forExtension ext: String) -> String? {
        switch ext {
        case "swift": return "swift"
        case "py": return "python"
        case "rb": return "ruby"
        case "js", "mjs", "cjs": return "javascript"
        case "ts", "tsx": return "typescript"
        case "go": return "go"
        case "rs": return "rust"
        case "java": return "java"
        case "kt", "kts": return "kotlin"
        case "c", "h": return "c"
        case "cpp", "cc", "hpp", "hh", "cxx": return "cpp"
        case "cs": return "csharp"
        case "json": return "json"
        case "yml", "yaml": return "yaml"
        case "toml": return "toml"
        case "xml", "html", "htm": return "xml"
        case "css": return "css"
        case "md", "markdown": return "markdown"
        case "sh", "bash", "zsh": return "bash"
        case "sql": return "sql"
        case "rs.in": return nil
        default: return nil
        }
    }

    // MARK: - Commentary (mini markdown)

    private static func renderCommentary(_ text: String, toc: [TOCEntry], cursor: inout Int) -> String {
        let lines = text.components(separatedBy: "\n")
        var html = ""
        var index = 0

        while index < lines.count {
            let line = lines[index]

            if line.hasPrefix("## ") {
                let title = String(line.dropFirst(3))
                let slug = nextSlug(toc: toc, cursor: &cursor)
                html += sectionHeading(level: 2, title: title, slug: slug)
                index += 1
                continue
            }

            if line.hasPrefix("### ") {
                let title = String(line.dropFirst(4))
                let slug = nextSlug(toc: toc, cursor: &cursor)
                html += sectionHeading(level: 3, title: title, slug: slug)
                index += 1
                continue
            }

            if line.hasPrefix("#### ") {
                let title = String(line.dropFirst(5))
                html += "<h4>\(renderInline(title))</h4>\n"
                index += 1
                continue
            }

            if line.hasPrefix("- ") || line.hasPrefix("* ") {
                html += "<ul>\n"
                while index < lines.count, lines[index].hasPrefix("- ") || lines[index].hasPrefix("* ") {
                    let item = String(lines[index].dropFirst(2))
                    html += "  <li>\(renderInline(item))</li>\n"
                    index += 1
                }
                html += "</ul>\n"
                continue
            }

            if line.range(of: #"^\d+\.\s"#, options: .regularExpression) != nil {
                html += "<ol>\n"
                while index < lines.count,
                      let match = lines[index].range(of: #"^\d+\.\s"#, options: .regularExpression) {
                    let item = String(lines[index][match.upperBound...])
                    html += "  <li>\(renderInline(item))</li>\n"
                    index += 1
                }
                html += "</ol>\n"
                continue
            }

            if line.hasPrefix("> ") {
                var quoteLines: [String] = []
                while index < lines.count, lines[index].hasPrefix("> ") {
                    quoteLines.append(String(lines[index].dropFirst(2)))
                    index += 1
                }
                html += "<blockquote><p>\(renderInline(quoteLines.joined(separator: " ")))</p></blockquote>\n"
                continue
            }

            if line.isEmpty {
                index += 1
                continue
            }

            var paragraphLines: [String] = []
            while index < lines.count {
                let current = lines[index]
                if current.isEmpty
                    || current.hasPrefix("## ")
                    || current.hasPrefix("### ")
                    || current.hasPrefix("#### ")
                    || current.hasPrefix("- ")
                    || current.hasPrefix("* ")
                    || current.hasPrefix("> ")
                    || current.range(of: #"^\d+\.\s"#, options: .regularExpression) != nil {
                    break
                }
                paragraphLines.append(current)
                index += 1
            }

            let paragraph = paragraphLines.joined(separator: " ")
            html += "<p>\(renderInline(paragraph))</p>\n"
        }

        return html
    }

    private static func sectionHeading(level: Int, title: String, slug: String) -> String {
        let chapter = leadingChapterNumber(title)
        let displayTitle: String
        if chapter != nil, let stripped = strippingLeadingChapter(title) {
            displayTitle = stripped
        } else {
            displayTitle = title
        }
        let cleaned = renderInline(displayTitle)
        let chapterMarkup: String
        if let chapter {
            chapterMarkup = #"<span class="chapter-number">\#(chapter)</span>"#
        } else {
            chapterMarkup = ""
        }
        let attrSlug = attributeEscape(slug)
        return """
        <h\(level) id="\(attrSlug)" class="section-heading level-\(level)">\
        \(chapterMarkup)\
        <span class="heading-text">\(cleaned)</span>\
        <a href="#\(attrSlug)" class="anchor-link" aria-label="Link to section">¶</a>\
        </h\(level)>\n
        """
    }

    /// Pulls a leading "1." or "2.3" out of a heading title so we can render it in a
    /// stylised side rail. Returns nil if no obvious chapter number is present.
    private static func leadingChapterNumber(_ title: String) -> String? {
        guard let match = title.range(of: #"^[0-9]+(\.[0-9]+)*\.?\s"#, options: .regularExpression) else {
            return nil
        }
        let raw = String(title[match]).trimmingCharacters(in: .whitespaces)
        let trimmed = raw.hasSuffix(".") ? String(raw.dropLast()) : raw
        return trimmed
    }

    private static func strippingLeadingChapter(_ title: String) -> String? {
        guard let match = title.range(of: #"^[0-9]+(\.[0-9]+)*\.?\s+"#, options: .regularExpression) else {
            return nil
        }
        return String(title[match.upperBound...])
    }

    private static func nextSlug(toc: [TOCEntry], cursor: inout Int) -> String {
        guard cursor < toc.count else {
            return "section-\(cursor + 1)"
        }
        let slug = toc[cursor].slug
        cursor += 1
        return slug
    }

    // MARK: - Inline markdown

    private static func renderInline(_ text: String) -> String {
        var working = htmlEscape(text)

        // Inline code first so other replacements don't bleed into it.
        working = regexReplace(working, pattern: "`([^`]+)`", template: "<code>$1</code>")

        // Inline images ![alt](src) — must come BEFORE the link regex so the
        // `[alt](src)` portion of an image isn't consumed as a link.
        working = regexReplace(
            working,
            pattern: #"!\[([^\]]*)\]\(([^)]+)\)"#,
            template: #"<img src="$2" alt="$1" loading="lazy" class="inline-image">"#
        )

        // Markdown links [text](url)
        working = regexReplace(
            working,
            pattern: #"\[([^\]]+)\]\(([^)]+)\)"#,
            template: #"<a href="$2" target="_blank" rel="noopener noreferrer">$1</a>"#
        )

        // Bold **text** before italic so we don't collide with the * in **.
        working = regexReplace(working, pattern: #"\*\*([^*]+)\*\*"#, template: "<strong>$1</strong>")

        // Italic *text* — require a non-space immediately after the opening *.
        working = regexReplace(working, pattern: #"\*([^*\s][^*]*?)\*"#, template: "<em>$1</em>")

        return working
    }

    private static func stripInlineMarkdown(_ text: String) -> String {
        var working = text
        for pattern in [#"\*\*([^*]+)\*\*"#, #"\*([^*\s][^*]*?)\*"#, "`([^`]+)`"] {
            working = regexReplace(working, pattern: pattern, template: "$1")
        }
        working = regexReplace(working, pattern: #"\[([^\]]+)\]\([^)]+\)"#, template: "$1")
        return working.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Code / output / image / source blocks

    private static func renderCodeBlock(_ block: CodeBlock) -> String {
        if block.isImage {
            // Image marker; the corresponding `imageOutput` block carries the
            // visible asset, so render this as a tiny invocation hint that
            // says "the user copied an image with this command".
            let escaped = htmlEscape(block.code)
            return """
            <figure class="showless-block invocation image-invocation">
              <header class="block-header">
                <span class="block-label">image</span>
                <span class="block-language">copied asset</span>
              </header>
              <pre><code>\(escaped)</code></pre>
            </figure>
            """
        }

        if block.isDiagram {
            return renderDiagram(block)
        }

        let language = block.language.lowercased()
        let displayLanguage = displayName(forLanguage: language)
        let escaped = htmlEscape(block.code)
        let isShell = ["bash", "sh", "zsh", "shell"].contains(language)
        let modifier = isShell ? "shell" : "code"

        return """
        <figure class="showless-block code-block \(modifier)">
          <header class="block-header">
            <span class="block-label">\(modifier == "shell" ? "command" : "code")</span>
            <span class="block-language">\(htmlEscape(displayLanguage))</span>
            <button type="button" class="copy-btn" aria-label="Copy to clipboard">Copy</button>
          </header>
          <pre><code class="language-\(htmlEscape(language)) hljs">\(escaped)</code></pre>
        </figure>
        """
    }

    private static func renderDiagram(_ block: CodeBlock) -> String {
        let language = block.language.lowercased()
        if language == "mermaid" {
            let escaped = htmlEscape(block.code)
            return """
            <figure class="showless-block diagram-block mermaid-block">
              <header class="block-header">
                <span class="block-label">diagram</span>
                <span class="block-language">mermaid</span>
              </header>
              <div class="mermaid-container">
                <pre class="mermaid">\(escaped)</pre>
              </div>
            </figure>
            """
        }

        // For plantuml / dot / d2 we don't bundle a renderer, so fall back to a
        // syntax-highlighted source block with a friendly hint.
        let escaped = htmlEscape(block.code)
        return """
        <figure class="showless-block diagram-block raw-diagram">
          <header class="block-header">
            <span class="block-label">diagram source</span>
            <span class="block-language">\(htmlEscape(language))</span>
          </header>
          <pre><code class="language-\(htmlEscape(language)) hljs">\(escaped)</code></pre>
        </figure>
        """
    }

    private static func renderOutput(_ block: OutputBlock, inferredLanguage: String? = nil) -> String {
        // Strip a single trailing newline so we don't render a phantom empty
        // last line. Then wrap every line in its own block-level span so each
        // captured line is guaranteed to start on a new row regardless of
        // whether the user's browser respects `white-space: pre-wrap` on
        // bare `<pre><code>`.
        var content = block.content
        if content.hasSuffix("\n") { content.removeLast() }
        let lines = content.components(separatedBy: "\n")

        let lineHTML = lines.map { line -> String in
            let escaped = htmlEscape(line)
            // U+200B zero-width space keeps empty lines from collapsing to
            // zero height inside `display: block` spans.
            let inner = escaped.isEmpty ? "\u{200B}" : escaped
            return "<span class=\"output-line\">\(inner)</span>"
        }.joined()

        let extraClasses: String
        if let language = inferredLanguage, !language.isEmpty {
            extraClasses = " language-\(htmlEscape(language)) hljs"
        } else {
            extraClasses = ""
        }

        return """
        <figure class="showless-block output-block">
          <header class="block-header terminal-header">
            <span class="block-label">output</span>
            <button type="button" class="copy-btn terminal-copy" aria-label="Copy output to clipboard">Copy</button>
          </header>
          <pre><code class="output-content\(extraClasses)">\(lineHTML)</code></pre>
        </figure>
        """
    }

    private static func renderImage(_ block: ImageOutputBlock) -> String {
        let alt = htmlEscape(block.altText)
        let src = attributeEscape(block.filename)
        return """
        <figure class="showless-block image-block">
          <img src="\(src)" alt="\(alt)" loading="lazy">
          \(block.altText.isEmpty ? "" : "<figcaption>\(alt)</figcaption>")
        </figure>
        """
    }

    private static func renderSourceExcerpt(_ block: SourceExcerptBlock) -> String {
        let escapedPath = htmlEscape(block.path)
        let escapedContent = htmlEscape(block.content)
        let language = block.language.lowercased()
        let displayLanguage = displayName(forLanguage: language)
        let lineRange: String
        if block.startLine == block.endLine {
            lineRange = "L\(block.startLine)"
        } else {
            lineRange = "L\(block.startLine)–L\(block.endLine)"
        }
        let hashShort = String(block.hash.suffix(8))

        return """
        <figure class="showless-block source-excerpt">
          <header class="block-header excerpt-header">
            <span class="excerpt-icon" aria-hidden="true">⟨/⟩</span>
            <span class="excerpt-path"><span class="excerpt-path-text">\(escapedPath)</span></span>
            <span class="excerpt-meta">
              <span class="excerpt-lang">\(htmlEscape(displayLanguage))</span>
              <span class="excerpt-lines">\(lineRange)</span>
              <span class="excerpt-hash" title="content hash">\(htmlEscape(hashShort))</span>
            </span>
            <button type="button" class="copy-btn" aria-label="Copy to clipboard">Copy</button>
          </header>
          <pre data-start-line="\(block.startLine)"><code class="language-\(htmlEscape(language)) hljs">\(escapedContent)</code></pre>
        </figure>
        """
    }

    // MARK: - HTML assembly

    private static func assembleHTML(
        pageTitle: String,
        titleBlock: TitleBlock?,
        toc: [TOCEntry],
        body: String,
        options: Options
    ) -> String {
        let escapedTitle = htmlEscape(pageTitle)
        let dateline: String
        if let titleBlock {
            var pieces: [String] = []
            if !titleBlock.timestamp.isEmpty {
                pieces.append(htmlEscape(titleBlock.timestamp))
            }
            let versionText = titleBlock.version.isEmpty
                ? TitleBlock.generator
                : "\(TitleBlock.generator) \(titleBlock.version)"
            pieces.append(htmlEscape(versionText))
            dateline = pieces.joined(separator: " · ")
        } else {
            dateline = ""
        }

        let subtitleHTML: String
        if let subtitle = options.subtitle, !subtitle.isEmpty {
            subtitleHTML = #"<p class="hero-subtitle">\#(htmlEscape(subtitle))</p>"#
        } else {
            subtitleHTML = #"<p class="hero-subtitle">An executable code walkthrough</p>"#
        }

        let blockCount = body.components(separatedBy: "<figure class=\"showless-block").count - 1
        let sectionCount = toc.filter { $0.level == 2 }.count
        let statsHTML = """
        <div class="hero-stats">
          <div class="stat"><span class="stat-value">\(sectionCount)</span><span class="stat-label">sections</span></div>
          <div class="stat"><span class="stat-value">\(blockCount)</span><span class="stat-label">code blocks</span></div>
          <div class="stat"><span class="stat-value">\(toc.count)</span><span class="stat-label">headings</span></div>
        </div>
        """

        let tocHTML: String
        let layoutClass: String
        if toc.isEmpty {
            tocHTML = ""
            layoutClass = "no-toc"
        } else {
            var items = ""
            for entry in toc {
                items += """
                <li class="toc-item toc-level-\(entry.level)"><a href="#\(attributeEscape(entry.slug))">\(htmlEscape(entry.title))</a></li>
                """
            }
            tocHTML = """
            <aside class="toc" aria-label="Table of contents">
              <div class="toc-inner">
                <div class="toc-title">Contents</div>
                <ol class="toc-list">\(items)</ol>
              </div>
            </aside>
            """
            layoutClass = "with-toc"
        }

        let footerHTML: String
        if options.includeFooter {
            let documentID = titleBlock?.documentID ?? ""
            let idLine: String
            if documentID.isEmpty {
                idLine = ""
            } else {
                idLine = #"<span class="footer-id">id <code>\#(htmlEscape(documentID))</code></span>"#
            }
            footerHTML = """
            <footer class="site-footer">
              <span>Rendered with <a href="https://github.com/" class="brand">Showless</a> · static, verifiable walkthroughs</span>
              \(idLine)
            </footer>
            """
        } else {
            footerHTML = ""
        }

        return """
        <!doctype html>
        <html lang="en" data-theme="auto">
        <head>
          <meta charset="utf-8">
          <meta name="viewport" content="width=device-width, initial-scale=1">
          <title>\(escapedTitle)</title>
          <meta name="generator" content="Showless HTMLRenderer">
          <link rel="preconnect" href="https://fonts.googleapis.com">
          <link rel="preconnect" href="https://fonts.gstatic.com" crossorigin>
          <link href="https://fonts.googleapis.com/css2?family=Inter:wght@400;500;600;700&family=JetBrains+Mono:wght@400;500;600;700&family=Newsreader:ital,wght@0,400;0,500;0,600;1,400&display=swap" rel="stylesheet">
          <style>
        \(inlineStylesheet)
          </style>
        </head>
        <body>
          <div class="reading-progress" aria-hidden="true"><div class="reading-progress-fill"></div></div>

          <header class="hero">
            <div class="hero-inner">
              <h1 class="hero-title">\(escapedTitle)</h1>
              \(statsHTML)
              \(subtitleHTML)
              \(dateline.isEmpty ? "" : #"<p class="hero-meta">\#(dateline)</p>"#)
            </div>
            <div class="hero-glow" aria-hidden="true"></div>
          </header>

          <div class="page-controls">
            <button type="button" class="theme-toggle" aria-label="Cycle color theme" title="Cycle theme">
              <span class="theme-icon" data-icon="auto" aria-hidden="true">◐</span>
              <span class="theme-text">Theme</span>
            </button>
          </div>

          <div class="layout \(layoutClass)">
            \(tocHTML)
            <main class="content">
        \(body)
            </main>
          </div>

          \(footerHTML)

          <button type="button" class="back-to-top" aria-label="Back to top" title="Back to top">↑</button>

          <script src="https://cdn.jsdelivr.net/gh/highlightjs/cdn-release@11.9.0/build/highlight.min.js"></script>
          <script src="https://cdn.jsdelivr.net/npm/mermaid@10/dist/mermaid.min.js"></script>
          <script>
        \(inlineScript)
          </script>
        </body>
        </html>
        """
    }

    // MARK: - Tiny utilities

    private static func htmlEscape(_ text: String) -> String {
        var result = ""
        result.reserveCapacity(text.count)
        for character in text {
            switch character {
            case "&": result += "&amp;"
            case "<": result += "&lt;"
            case ">": result += "&gt;"
            case "\"": result += "&quot;"
            case "'": result += "&#39;"
            default: result.append(character)
            }
        }
        return result
    }

    private static func attributeEscape(_ text: String) -> String {
        htmlEscape(text)
    }

    private static func slugify(_ text: String) -> String {
        let lowered = text.lowercased()
        var slug = ""
        var lastDash = false
        for scalar in lowered.unicodeScalars {
            if (scalar.value >= 0x30 && scalar.value <= 0x39)
                || (scalar.value >= 0x61 && scalar.value <= 0x7A) {
                slug.unicodeScalars.append(scalar)
                lastDash = false
            } else if !lastDash, !slug.isEmpty {
                slug.append("-")
                lastDash = true
            }
        }
        while slug.hasSuffix("-") { slug.removeLast() }
        return slug.isEmpty ? "section" : slug
    }

    private static func regexReplace(_ string: String, pattern: String, template: String) -> String {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else {
            return string
        }
        let range = NSRange(string.startIndex..<string.endIndex, in: string)
        return regex.stringByReplacingMatches(in: string, options: [], range: range, withTemplate: template)
    }

    private static func displayName(forLanguage language: String) -> String {
        switch language.lowercased() {
        case "bash", "sh", "shell", "zsh": return "shell"
        case "js", "javascript": return "javascript"
        case "ts", "typescript": return "typescript"
        case "py", "python", "python3": return "python"
        case "rb", "ruby": return "ruby"
        case "rs", "rust": return "rust"
        case "go", "golang": return "go"
        case "swift": return "swift"
        case "json": return "json"
        case "yaml", "yml": return "yaml"
        case "md", "markdown": return "markdown"
        case "html": return "html"
        case "css": return "css"
        case "c": return "c"
        case "cpp", "c++", "cc": return "c++"
        case "java": return "java"
        case "kt", "kotlin": return "kotlin"
        case "mermaid": return "mermaid"
        case "plantuml", "puml": return "plantuml"
        case "dot", "graphviz": return "graphviz"
        case "d2": return "d2"
        default: return language.isEmpty ? "text" : language
        }
    }
}

// MARK: - Inline assets

let inlineStylesheet: String = """
:root {
  color-scheme: light;
  --bg-page: #f7f4ec;
  --bg-card: #ffffff;
  --bg-soft: #efeadd;
  --bg-terminal: #1c1f26;
  --bg-hero: linear-gradient(140deg, #fff8e8 0%, #fde2c2 35%, #f6c79a 100%);
  --hero-glow: radial-gradient(circle at 20% 20%, rgba(217, 119, 6, 0.35), transparent 55%),
               radial-gradient(circle at 80% 80%, rgba(120, 53, 15, 0.25), transparent 55%);
  --ink: #1f1d1a;
  --ink-strong: #0f0d0a;
  --ink-muted: #5a544c;
  --ink-faint: #8b8378;
  --ink-on-terminal: #e7e5dd;
  --accent: #c2410c;
  --accent-strong: #9a3412;
  --accent-soft: #fde2c4;
  --border: #e6dfd0;
  --border-strong: #d6cdb6;
  --shadow-card: 0 1px 2px rgba(53, 38, 12, 0.06), 0 12px 30px rgba(53, 38, 12, 0.08);
  --shadow-soft: 0 1px 0 rgba(53, 38, 12, 0.04);
  --radius: 14px;
  --radius-sm: 8px;
  --code-fg: #2c2924;
  --code-keyword: #b91c1c;
  --code-string: #166534;
  --code-number: #c2410c;
  --code-comment: #9b8f7e;
  --code-function: #1d4ed8;
  --code-type: #7c2d12;
  --code-variable: #6b21a8;
  --code-meta: #92400e;
  --code-tag: #b91c1c;
  --code-attr: #1d4ed8;
  --max-content: 760px;
  --toc-width: 260px;
  --gutter: 64px;
  --font-sans: 'Inter', system-ui, -apple-system, 'Segoe UI', sans-serif;
  --font-display: 'Newsreader', 'Inter', Georgia, serif;
  --font-mono: 'JetBrains Mono', ui-monospace, 'SF Mono', Menlo, monospace;
}

@media (prefers-color-scheme: dark) {
  :root[data-theme="auto"] {
    color-scheme: dark;
    --bg-page: #0d0f14;
    --bg-card: #14171f;
    --bg-soft: #1a1d27;
    --bg-terminal: #07090d;
    --bg-hero: linear-gradient(140deg, #15171f 0%, #1f1a14 50%, #2a1f10 100%);
    --hero-glow: radial-gradient(circle at 20% 20%, rgba(251, 191, 36, 0.22), transparent 55%),
                 radial-gradient(circle at 80% 80%, rgba(217, 119, 6, 0.18), transparent 55%);
    --ink: #e7e9ee;
    --ink-strong: #f7f8fb;
    --ink-muted: #a4a8b3;
    --ink-faint: #6c7180;
    --ink-on-terminal: #e7e9ee;
    --accent: #fbbf24;
    --accent-strong: #fcd34d;
    --accent-soft: #3b2a08;
    --border: #252934;
    --border-strong: #353a47;
    --shadow-card: 0 1px 2px rgba(0, 0, 0, 0.4), 0 18px 40px rgba(0, 0, 0, 0.35);
    --shadow-soft: 0 1px 0 rgba(0, 0, 0, 0.4);
    --code-fg: #d6d8de;
    --code-keyword: #ff7b72;
    --code-string: #a5d6ff;
    --code-number: #79c0ff;
    --code-comment: #6c7180;
    --code-function: #d2a8ff;
    --code-type: #ffa657;
    --code-variable: #ffa657;
    --code-meta: #c9d1d9;
    --code-tag: #7ee787;
    --code-attr: #d2a8ff;
  }
}

:root[data-theme="dark"] {
  color-scheme: dark;
  --bg-page: #0d0f14;
  --bg-card: #14171f;
  --bg-soft: #1a1d27;
  --bg-terminal: #07090d;
  --bg-hero: linear-gradient(140deg, #15171f 0%, #1f1a14 50%, #2a1f10 100%);
  --hero-glow: radial-gradient(circle at 20% 20%, rgba(251, 191, 36, 0.22), transparent 55%),
               radial-gradient(circle at 80% 80%, rgba(217, 119, 6, 0.18), transparent 55%);
  --ink: #e7e9ee;
  --ink-strong: #f7f8fb;
  --ink-muted: #a4a8b3;
  --ink-faint: #6c7180;
  --ink-on-terminal: #e7e9ee;
  --accent: #fbbf24;
  --accent-strong: #fcd34d;
  --accent-soft: #3b2a08;
  --border: #252934;
  --border-strong: #353a47;
  --shadow-card: 0 1px 2px rgba(0, 0, 0, 0.4), 0 18px 40px rgba(0, 0, 0, 0.35);
  --shadow-soft: 0 1px 0 rgba(0, 0, 0, 0.4);
  --code-fg: #d6d8de;
  --code-keyword: #ff7b72;
  --code-string: #a5d6ff;
  --code-number: #79c0ff;
  --code-comment: #6c7180;
  --code-function: #d2a8ff;
  --code-type: #ffa657;
  --code-variable: #ffa657;
  --code-meta: #c9d1d9;
  --code-tag: #7ee787;
  --code-attr: #d2a8ff;
}

* { box-sizing: border-box; }

html { scroll-behavior: smooth; scroll-padding-top: 96px; }

body {
  margin: 0;
  font-family: var(--font-sans);
  font-size: 17px;
  line-height: 1.7;
  color: var(--ink);
  background: var(--bg-page);
  -webkit-font-smoothing: antialiased;
  -moz-osx-font-smoothing: grayscale;
  font-feature-settings: 'kern', 'liga', 'cv11';
  text-rendering: optimizeLegibility;
}

::selection { background: var(--accent-soft); color: var(--ink-strong); }

a { color: var(--accent); text-decoration: none; border-bottom: 1px solid transparent; transition: border-color .15s ease; }
a:hover { border-bottom-color: var(--accent); }

p { margin: 0 0 1.1em; }

/* Reading progress bar */
.reading-progress {
  position: fixed; top: 0; left: 0; right: 0; height: 3px;
  background: transparent; z-index: 100; pointer-events: none;
}
.reading-progress-fill {
  height: 100%; width: 100%;
  background: linear-gradient(90deg, var(--accent), var(--accent-strong));
  transform-origin: left; transform: scaleX(0);
  transition: transform .1s linear;
}

/* Hero */
.hero {
  position: relative;
  padding: 96px 24px 72px;
  background: var(--bg-hero);
  border-bottom: 1px solid var(--border);
  overflow: hidden;
}
.hero-glow {
  position: absolute; inset: -20%;
  background: var(--hero-glow);
  filter: blur(40px);
  pointer-events: none;
  opacity: .8;
}
.hero-inner {
  position: relative;
  max-width: 880px;
  margin: 0 auto;
  text-align: center;
}
.hero-meta {
  display: block;
  font-family: var(--font-mono);
  font-size: 10px;
  letter-spacing: .1em;
  text-transform: uppercase;
  color: var(--ink-faint);
  margin: 6px 0 0;
}
.hero-title {
  font-family: var(--font-display);
  font-weight: 600;
  font-size: clamp(2.2rem, 5vw, 3.6rem);
  line-height: 1.08;
  letter-spacing: -0.02em;
  margin: 0 0 14px;
  color: var(--ink-strong);
  background: linear-gradient(135deg, var(--ink-strong) 0%, var(--accent-strong) 100%);
  -webkit-background-clip: text;
  background-clip: text;
  -webkit-text-fill-color: transparent;
}
.hero-subtitle {
  font-size: 1.05rem;
  color: var(--ink-muted);
  margin: 0;
  font-style: italic;
}
.hero-stats {
  display: inline-flex;
  gap: 16px;
  padding: 6px 16px;
  background: rgba(255, 255, 255, 0.5);
  border: 1px solid var(--border);
  border-radius: 999px;
  backdrop-filter: blur(14px);
  -webkit-backdrop-filter: blur(14px);
  margin: 10px 0 18px;
}
:root[data-theme="dark"] .hero-stats,
:root[data-theme="auto"] .hero-stats { background: rgba(20, 23, 31, 0.55); }
@media (prefers-color-scheme: dark) {
  :root[data-theme="auto"] .hero-stats { background: rgba(20, 23, 31, 0.55); }
}
.stat { display: flex; flex-direction: row; align-items: baseline; gap: 4px; }
.stat-value {
  font-family: var(--font-display);
  font-weight: 600;
  font-size: 1.1rem;
  color: var(--ink-strong);
  line-height: 1;
}
.stat-label {
  font-family: var(--font-mono);
  font-size: 10px;
  letter-spacing: .15em;
  text-transform: uppercase;
  color: var(--ink-faint);
}

/* Page controls */
.page-controls {
  position: fixed;
  top: 18px;
  right: 18px;
  z-index: 50;
  display: flex;
  gap: 8px;
}
.theme-toggle {
  display: inline-flex;
  align-items: center;
  gap: 8px;
  padding: 8px 14px;
  border-radius: 999px;
  background: var(--bg-card);
  color: var(--ink);
  border: 1px solid var(--border);
  font-family: var(--font-sans);
  font-size: 12px;
  font-weight: 500;
  cursor: pointer;
  box-shadow: var(--shadow-soft);
  transition: transform .12s ease, border-color .15s ease;
}
.theme-toggle:hover { border-color: var(--accent); transform: translateY(-1px); }
.theme-icon { font-size: 14px; line-height: 1; }

/* Layout */
.layout {
  max-width: 1240px;
  margin: 0 auto;
  padding: 60px 32px 80px;
  display: grid;
  grid-template-columns: var(--toc-width) minmax(0, 1fr);
  gap: var(--gutter);
}
.layout.no-toc { grid-template-columns: minmax(0, 1fr); max-width: var(--max-content); }

/* Table of contents */
.toc { font-size: 13.5px; }
.toc-inner {
  position: sticky;
  top: 32px;
  max-height: calc(100vh - 48px);
  overflow-y: auto;
  padding-right: 8px;
}
.toc-title {
  font-family: var(--font-mono);
  font-size: 11px;
  letter-spacing: .15em;
  text-transform: uppercase;
  color: var(--ink-faint);
  margin-bottom: 14px;
}
.toc-list {
  list-style: none;
  margin: 0;
  padding: 0;
  border-left: 1px solid var(--border);
}
.toc-item { line-height: 1.45; }
.toc-item a {
  display: block;
  padding: 7px 14px;
  color: var(--ink-muted);
  border-bottom: none;
  border-left: 2px solid transparent;
  margin-left: -1px;
  transition: color .12s ease, border-color .12s ease, background .12s ease;
}
.toc-item a:hover { color: var(--ink-strong); }
.toc-item a.active {
  color: var(--accent);
  border-left-color: var(--accent);
  background: linear-gradient(90deg, var(--accent-soft) 0%, transparent 80%);
  font-weight: 500;
}
.toc-level-3 a { padding-left: 28px; font-size: 12.5px; color: var(--ink-faint); }
.toc-level-3 a.active { color: var(--accent); }

.toc-inner::-webkit-scrollbar { width: 6px; }
.toc-inner::-webkit-scrollbar-thumb { background: var(--border); border-radius: 3px; }

/* Content */
.content {
  max-width: var(--max-content);
  width: 100%;
  min-width: 0;
}
.content > p:first-of-type::first-letter {
  font-family: var(--font-display);
  font-weight: 600;
  font-size: 3.4em;
  float: left;
  line-height: .9;
  margin: 8px 10px 0 0;
  color: var(--accent);
}

.content h2,
.content h3,
.content h4 {
  font-family: var(--font-display);
  color: var(--ink-strong);
  letter-spacing: -0.01em;
  scroll-margin-top: 96px;
  position: relative;
}
.content h2 {
  font-size: 1.95rem;
  font-weight: 600;
  margin: 64px 0 12px;
  padding-bottom: 12px;
  border-bottom: 1px solid var(--border);
}
.content h3 {
  font-size: 1.35rem;
  font-weight: 600;
  margin: 44px 0 10px;
}
.content h4 {
  font-size: 1.05rem;
  font-weight: 600;
  margin: 32px 0 8px;
}
.content h2:first-child,
.content h3:first-child { margin-top: 0; }

.section-heading .heading-text { display: inline; }
.section-heading .chapter-number {
  position: absolute;
  right: calc(100% + 18px);
  top: 50%;
  transform: translateY(-50%);
  font-family: var(--font-mono);
  font-size: 11px;
  letter-spacing: .12em;
  color: var(--ink-faint);
  white-space: nowrap;
}
.section-heading.level-3 .chapter-number { display: none; }
.section-heading .anchor-link {
  margin-left: 10px;
  color: var(--ink-faint);
  border-bottom: none;
  opacity: 0;
  transition: opacity .12s ease, color .12s ease;
  font-weight: 400;
}
.section-heading:hover .anchor-link { opacity: 1; }
.section-heading .anchor-link:hover { color: var(--accent); }

.content ul, .content ol { margin: 0 0 1.2em; padding-left: 1.4em; }
.content li { margin-bottom: 6px; }
.content li::marker { color: var(--accent); }

.content blockquote {
  margin: 1.2em 0;
  padding: 16px 22px;
  background: var(--accent-soft);
  border-left: 3px solid var(--accent);
  border-radius: var(--radius-sm);
  color: var(--ink-strong);
  font-style: italic;
}
.content blockquote p:last-child { margin-bottom: 0; }

.content code:not([class*="language-"]):not(.hljs) {
  font-family: var(--font-mono);
  font-size: 0.88em;
  padding: 2px 6px;
  background: var(--bg-soft);
  color: var(--accent-strong);
  border-radius: 4px;
  border: 1px solid var(--border);
  white-space: nowrap;
}

/* Block cards */
.showless-block {
  margin: 28px 0;
  background: var(--bg-card);
  border: 1px solid var(--border);
  border-radius: var(--radius);
  box-shadow: var(--shadow-card);
  overflow: hidden;
  min-width: 0;
  max-width: 100%;
}
.showless-block + .showless-block { margin-top: 18px; }

.block-header {
  display: flex;
  align-items: center;
  gap: 12px;
  padding: 10px 16px;
  background: var(--bg-soft);
  border-bottom: 1px solid var(--border);
  font-family: var(--font-mono);
  font-size: 11px;
  letter-spacing: .08em;
  color: var(--ink-muted);
}
.block-label {
  text-transform: uppercase;
  font-weight: 600;
  letter-spacing: .15em;
  color: var(--ink-faint);
}
.block-language {
  color: var(--accent);
  font-weight: 500;
}
.copy-btn {
  margin-left: auto;
  padding: 4px 10px;
  border-radius: 999px;
  background: transparent;
  border: 1px solid var(--border-strong);
  color: var(--ink-muted);
  font-family: var(--font-mono);
  font-size: 10.5px;
  letter-spacing: .1em;
  text-transform: uppercase;
  cursor: pointer;
  transition: color .12s ease, border-color .12s ease, background .12s ease;
}
.copy-btn:hover { color: var(--accent); border-color: var(--accent); background: var(--accent-soft); }
.copy-btn.copied { color: var(--accent-strong); border-color: var(--accent); }

.showless-block pre {
  margin: 0;
  padding: 18px 20px;
  font-family: var(--font-mono);
  font-size: 13.5px;
  line-height: 1.6;
  color: var(--code-fg);
  background: var(--bg-card);
  /* Default: wrap long lines so nothing is clipped or invisibly off-screen.
     Source excerpts override this below to preserve exact formatting. */
  white-space: pre-wrap;
  word-break: break-word;
  overflow-wrap: anywhere;
  overflow-x: auto;     /* Safety net if wrapping ever fails. */
  max-width: 100%;
}
.showless-block pre code {
  display: block;
  background: transparent;
  padding: 0;
  border: 0;
  white-space: inherit;
  word-break: inherit;
  overflow-wrap: inherit;
  max-width: 100%;
}

.code-block.shell pre code::before {
  content: '$ ';
  color: var(--accent);
  font-weight: 600;
  margin-right: 6px;
}

/* Output / terminal */
.output-block { background: var(--bg-terminal); border-color: transparent; }
.output-block .terminal-header {
  background: rgba(255, 255, 255, 0.04);
  border-bottom: 1px solid rgba(255, 255, 255, 0.06);
  color: rgba(231, 233, 238, 0.6);
}
.output-block .terminal-header .block-label { color: rgba(231, 233, 238, 0.5); }
.output-block .copy-btn.terminal-copy {
  margin-left: auto;
  border-color: rgba(231, 233, 238, 0.18);
  color: rgba(231, 233, 238, 0.7);
  background: rgba(255, 255, 255, 0.04);
}
.output-block .copy-btn.terminal-copy:hover {
  color: var(--accent);
  border-color: var(--accent);
  background: rgba(251, 191, 36, 0.12);
}
.output-block .copy-btn.terminal-copy.copied {
  color: #28c840;
  border-color: #28c840;
  background: rgba(40, 200, 64, 0.12);
}
.output-block pre {
  background: var(--bg-terminal);
  color: var(--ink-on-terminal);
  font-size: 13px;
  padding: 18px 22px 22px;
  white-space: normal;          /* lines are explicit <span> blocks */
  overflow-x: hidden;
}
.output-block pre code.output-content {
  display: block;
  color: inherit;
  background: transparent;
  padding: 0;
  border: 0;
  width: 100%;
  max-width: 100%;
}
.output-block .output-line {
  display: block;
  width: 100%;
  white-space: pre-wrap;
  word-break: break-word;
  overflow-wrap: anywhere;
  font-variant-ligatures: none;
}

/* Highlight.js colours scoped to output blocks. The terminal background is
   dark in both page themes, so we always use the GitHub-dark-style palette
   here regardless of the global --code-* variables. */
.output-block .hljs,
.output-block .output-line .hljs { color: var(--ink-on-terminal); }
.output-block .hljs-keyword,
.output-block .hljs-selector-tag,
.output-block .hljs-built_in,
.output-block .hljs-name,
.output-block .hljs-doctag { color: #ff7b72; font-weight: 500; }
.output-block .hljs-string,
.output-block .hljs-attr,
.output-block .hljs-symbol,
.output-block .hljs-bullet,
.output-block .hljs-addition { color: #a5d6ff; }
.output-block .hljs-number,
.output-block .hljs-literal,
.output-block .hljs-quote { color: #79c0ff; }
.output-block .hljs-comment { color: #8b949e; font-style: italic; }
.output-block .hljs-function,
.output-block .hljs-title,
.output-block .hljs-title.function_,
.output-block .hljs-section { color: #d2a8ff; font-weight: 500; }
.output-block .hljs-type,
.output-block .hljs-class .hljs-title,
.output-block .hljs-title.class_ { color: #ffa657; }
.output-block .hljs-variable,
.output-block .hljs-attribute,
.output-block .hljs-template-variable { color: #ffa657; }
.output-block .hljs-meta,
.output-block .hljs-meta-keyword { color: #c9d1d9; }
.output-block .hljs-tag { color: #7ee787; }
.output-block .hljs-deletion { color: #ff7b72; }
.output-block .hljs-emphasis { font-style: italic; }
.output-block .hljs-strong { font-weight: bold; }

/* Source excerpts — preserve exact source formatting; horizontal scroll. */
.source-excerpt { border-color: var(--border-strong); }
.source-excerpt pre {
  white-space: pre;
  word-break: normal;
  overflow-wrap: normal;
  overflow-x: auto;
}
.source-excerpt pre code {
  white-space: inherit;
  word-break: inherit;
  overflow-wrap: inherit;
}
.source-excerpt .excerpt-header {
  background: linear-gradient(90deg, var(--accent-soft) 0%, var(--bg-soft) 100%);
  flex-wrap: wrap;
}
.excerpt-icon {
  font-family: var(--font-mono);
  font-size: 12px;
  font-weight: 600;
  color: var(--accent);
  letter-spacing: 0;
  background: var(--bg-card);
  padding: 2px 8px;
  border-radius: 6px;
  border: 1px solid var(--border);
}
.excerpt-path {
  font-family: var(--font-mono);
  color: var(--ink-strong);
  font-size: 12.5px;
  font-weight: 500;
  letter-spacing: 0;
  flex: 1;
  min-width: 0;
  overflow: hidden;
  text-overflow: ellipsis;
  white-space: nowrap;
}
.excerpt-meta {
  display: inline-flex;
  align-items: center;
  gap: 8px;
  font-family: var(--font-mono);
  font-size: 11px;
  letter-spacing: 0;
}
.excerpt-lang { color: var(--accent); font-weight: 500; }
.excerpt-lines {
  background: var(--bg-card);
  color: var(--ink-muted);
  padding: 2px 8px;
  border-radius: 6px;
  border: 1px solid var(--border);
}
.excerpt-hash { color: var(--ink-faint); }

/* Diagram */
.mermaid-block .mermaid-container {
  padding: 28px 24px;
  background: var(--bg-card);
  display: flex;
  justify-content: center;
}
.mermaid-block .mermaid {
  margin: 0;
  background: transparent;
  font-family: var(--font-sans);
  text-align: center;
  width: 100%;
  overflow-x: auto;
}
.mermaid svg { max-width: 100%; height: auto; }

/* Mermaid error fallback */
.mermaid-error {
  width: 100%;
  border: 1px solid #ef4444;
  background: rgba(239, 68, 68, 0.08);
  border-radius: var(--radius-sm);
  padding: 16px 18px;
  font-family: var(--font-mono);
  font-size: 12.5px;
  color: var(--ink);
  text-align: left;
}
.mermaid-error-title {
  display: inline-flex;
  align-items: center;
  gap: 8px;
  font-weight: 600;
  color: #b91c1c;
  margin-bottom: 8px;
  letter-spacing: .05em;
  text-transform: uppercase;
  font-size: 11px;
}
.mermaid-error-title::before {
  content: '⚠';
  font-size: 14px;
}
.mermaid-error-message {
  white-space: pre-wrap;
  word-break: break-word;
  margin: 0 0 12px;
  color: #991b1b;
}
.mermaid-error-source {
  margin: 0;
  padding: 12px 14px;
  background: var(--bg-soft);
  border: 1px solid var(--border);
  border-radius: 6px;
  white-space: pre;
  overflow-x: auto;
  color: var(--ink-muted);
}
:root[data-theme="dark"] .mermaid-error,
:root[data-theme="auto"] .mermaid-error {
  background: rgba(239, 68, 68, 0.12);
}
:root[data-theme="dark"] .mermaid-error-title,
:root[data-theme="auto"] .mermaid-error-title { color: #fca5a5; }
:root[data-theme="dark"] .mermaid-error-message,
:root[data-theme="auto"] .mermaid-error-message { color: #fecaca; }

/* Image */
.image-block { padding: 16px; background: var(--bg-card); text-align: center; }
.image-block img { max-width: 100%; height: auto; border-radius: var(--radius-sm); border: 1px solid var(--border); }
.image-block figcaption {
  margin-top: 10px;
  font-family: var(--font-mono);
  font-size: 11px;
  letter-spacing: .1em;
  text-transform: uppercase;
  color: var(--ink-faint);
}

/* Image-invocation (the bash block that creates the image) */
.image-invocation { opacity: .85; }

/* Inline images in prose */
.inline-image {
  max-width: 100%;
  height: auto;
  border-radius: var(--radius-sm);
  border: 1px solid var(--border);
  margin: 4px 0;
}

/* Syntax highlighting (custom hljs theme tied to our CSS variables) */
.hljs { color: var(--code-fg); background: transparent; }
.hljs-keyword,
.hljs-selector-tag,
.hljs-built_in,
.hljs-name,
.hljs-doctag { color: var(--code-keyword); font-weight: 500; }
.hljs-string,
.hljs-attr,
.hljs-symbol,
.hljs-bullet,
.hljs-addition { color: var(--code-string); }
.hljs-number,
.hljs-literal,
.hljs-quote { color: var(--code-number); }
.hljs-comment { color: var(--code-comment); font-style: italic; }
.hljs-function,
.hljs-title,
.hljs-title.function_,
.hljs-section { color: var(--code-function); font-weight: 500; }
.hljs-type,
.hljs-class .hljs-title,
.hljs-title.class_ { color: var(--code-type); }
.hljs-variable,
.hljs-attribute,
.hljs-template-variable { color: var(--code-variable); }
.hljs-meta,
.hljs-meta-keyword { color: var(--code-meta); }
.hljs-tag { color: var(--code-tag); }
.hljs-deletion { color: #b91c1c; }
.hljs-emphasis { font-style: italic; }
.hljs-strong { font-weight: bold; }

/* Footer */
.site-footer {
  max-width: 1240px;
  margin: 0 auto;
  padding: 32px;
  border-top: 1px solid var(--border);
  display: flex;
  justify-content: space-between;
  align-items: center;
  flex-wrap: wrap;
  gap: 16px;
  font-family: var(--font-mono);
  font-size: 12px;
  color: var(--ink-faint);
}
.site-footer .brand { color: var(--accent); font-weight: 600; }
.footer-id code { font-size: 11px; padding: 2px 6px; background: var(--bg-soft); border: 1px solid var(--border); border-radius: 4px; }

/* Back to top */
.back-to-top {
  position: fixed;
  bottom: 28px;
  right: 28px;
  width: 44px;
  height: 44px;
  border-radius: 50%;
  border: 1px solid var(--border);
  background: var(--bg-card);
  color: var(--ink);
  font-size: 18px;
  cursor: pointer;
  box-shadow: var(--shadow-card);
  opacity: 0;
  transform: translateY(8px);
  pointer-events: none;
  transition: opacity .2s ease, transform .2s ease, color .12s ease, border-color .12s ease;
  z-index: 50;
}
.back-to-top.visible { opacity: 1; transform: translateY(0); pointer-events: auto; }
.back-to-top:hover { color: var(--accent); border-color: var(--accent); }

/* Section reveal */
.section-heading,
.showless-block,
.content > p,
.content > ul,
.content > ol,
.content > blockquote {
  opacity: 0;
  transform: translateY(8px);
  transition: opacity .5s ease, transform .5s ease;
}
.section-heading.visible,
.showless-block.visible,
.content > p.visible,
.content > ul.visible,
.content > ol.visible,
.content > blockquote.visible {
  opacity: 1;
  transform: translateY(0);
}

/* Responsive */
@media (max-width: 960px) {
  .layout { grid-template-columns: 1fr; padding: 40px 22px 60px; }
  .toc { display: none; }
  .hero { padding: 72px 24px 56px; }
  .section-heading .chapter-number { position: static; transform: none; display: inline-block; margin-right: 10px; }
  .content > p:first-of-type::first-letter { font-size: 2.6em; }
}

@media (max-width: 540px) {
  body { font-size: 16px; }
  .showless-block pre { font-size: 12.5px; padding: 16px; }
  .hero-stats { flex-wrap: wrap; gap: 10px; padding: 5px 12px; }
  .stat-value { font-size: 1rem; }
  .back-to-top { right: 18px; bottom: 18px; }
}

@media print {
  .toc, .page-controls, .reading-progress, .back-to-top, .copy-btn { display: none !important; }
  .layout { grid-template-columns: 1fr; padding: 0; max-width: 100%; }
  .showless-block { break-inside: avoid; box-shadow: none; }
  .hero { padding: 32px; }
}
"""

let inlineScript: String = #"""
(function () {
  'use strict';

  var root = document.documentElement;
  var THEME_KEY = 'showless-theme';
  var ICONS = { auto: '◐', light: '☀', dark: '☾' };

  function currentEffectiveTheme() {
    var attr = root.getAttribute('data-theme') || 'auto';
    if (attr === 'auto') {
      return (window.matchMedia && window.matchMedia('(prefers-color-scheme: dark)').matches) ? 'dark' : 'light';
    }
    return attr;
  }

  function applyTheme(theme, opts) {
    opts = opts || {};
    root.setAttribute('data-theme', theme);
    try { localStorage.setItem(THEME_KEY, theme); } catch (e) { /* private mode */ }
    var icon = document.querySelector('.theme-icon');
    if (icon) icon.textContent = ICONS[theme] || ICONS.auto;
    if (opts.rerenderMermaid !== false) rerenderMermaid();
  }

  // Capture every mermaid source into dataset.source BEFORE we touch the DOM
  // or kick off rendering. This avoids a race where mermaid replaces the
  // <pre> textContent with rendered SVG before we've stored the original.
  var mermaidContainers = [];
  document.querySelectorAll('pre.mermaid').forEach(function (node) {
    if (!node.dataset.source) node.dataset.source = node.textContent;
    var container = node.parentElement;
    if (container) mermaidContainers.push({ container: container, source: node.dataset.source });
  });

  var savedTheme = 'auto';
  try { savedTheme = localStorage.getItem(THEME_KEY) || 'auto'; } catch (e) {}
  // Apply the theme attribute without triggering a mermaid render — we'll
  // do that explicitly once below.
  applyTheme(savedTheme, { rerenderMermaid: false });

  var toggle = document.querySelector('.theme-toggle');
  if (toggle) {
    toggle.addEventListener('click', function () {
      var current = root.getAttribute('data-theme') || 'auto';
      var next = current === 'light' ? 'dark' : current === 'dark' ? 'auto' : 'light';
      applyTheme(next);
    });
  }

  if (window.matchMedia) {
    window.matchMedia('(prefers-color-scheme: dark)').addEventListener('change', function () {
      if ((root.getAttribute('data-theme') || 'auto') === 'auto') {
        rerenderMermaid();
      }
    });
  }

  // Reading progress
  var progress = document.querySelector('.reading-progress-fill');
  function updateProgress() {
    if (!progress) return;
    var scrollable = document.documentElement.scrollHeight - window.innerHeight;
    var ratio = scrollable > 0 ? Math.min(1, Math.max(0, window.scrollY / scrollable)) : 0;
    progress.style.transform = 'scaleX(' + ratio + ')';
  }
  document.addEventListener('scroll', updateProgress, { passive: true });
  updateProgress();

  // Back-to-top
  var backToTop = document.querySelector('.back-to-top');
  function updateBackToTop() {
    if (!backToTop) return;
    if (window.scrollY > 600) backToTop.classList.add('visible');
    else backToTop.classList.remove('visible');
  }
  document.addEventListener('scroll', updateBackToTop, { passive: true });
  if (backToTop) backToTop.addEventListener('click', function () { window.scrollTo({ top: 0, behavior: 'smooth' }); });
  updateBackToTop();

  // TOC active link via IntersectionObserver
  var headings = document.querySelectorAll('.content h2, .content h3');
  var tocLinks = Array.prototype.slice.call(document.querySelectorAll('.toc a'));
  var linkMap = {};
  tocLinks.forEach(function (a) {
    var href = a.getAttribute('href') || '';
    if (href.indexOf('#') === 0) linkMap[href.slice(1)] = a;
  });

  function setActive(id) {
    tocLinks.forEach(function (a) { a.classList.remove('active'); });
    var link = linkMap[id];
    if (link) {
      link.classList.add('active');
      var inner = document.querySelector('.toc-inner');
      if (inner) {
        var top = link.offsetTop - inner.offsetTop;
        if (top < inner.scrollTop || top + link.offsetHeight > inner.scrollTop + inner.clientHeight) {
          inner.scrollTo({ top: top - 40, behavior: 'smooth' });
        }
      }
    }
  }

  if ('IntersectionObserver' in window && headings.length) {
    var visibleIds = [];
    var observer = new IntersectionObserver(function (entries) {
      entries.forEach(function (entry) {
        if (entry.isIntersecting) {
          if (visibleIds.indexOf(entry.target.id) === -1) visibleIds.push(entry.target.id);
        } else {
          var idx = visibleIds.indexOf(entry.target.id);
          if (idx !== -1) visibleIds.splice(idx, 1);
        }
      });
      if (visibleIds.length) {
        // Pick the topmost visible heading.
        var first = visibleIds[0];
        var firstTop = Number.MAX_VALUE;
        visibleIds.forEach(function (id) {
          var el = document.getElementById(id);
          if (el && el.getBoundingClientRect().top < firstTop) {
            firstTop = el.getBoundingClientRect().top;
            first = id;
          }
        });
        setActive(first);
      }
    }, { rootMargin: '-30% 0px -55% 0px', threshold: 0 });
    headings.forEach(function (h) { observer.observe(h); });
  }

  // Section reveal on scroll
  if ('IntersectionObserver' in window) {
    var revealTargets = document.querySelectorAll(
      '.section-heading, .showless-block, .content > p, .content > ul, .content > ol, .content > blockquote'
    );
    var revealObserver = new IntersectionObserver(function (entries) {
      entries.forEach(function (entry) {
        if (entry.isIntersecting) {
          entry.target.classList.add('visible');
          revealObserver.unobserve(entry.target);
        }
      });
    }, { rootMargin: '0px 0px -10% 0px', threshold: 0.05 });
    revealTargets.forEach(function (el) { revealObserver.observe(el); });
  } else {
    document.querySelectorAll(
      '.section-heading, .showless-block, .content > p, .content > ul, .content > ol, .content > blockquote'
    ).forEach(function (el) { el.classList.add('visible'); });
  }

  // Copy buttons
  document.querySelectorAll('.copy-btn').forEach(function (btn) {
    btn.addEventListener('click', function () {
      var card = btn.closest('.showless-block');
      if (!card) return;
      var text;
      var lineNodes = card.querySelectorAll('.output-line');
      if (lineNodes.length) {
        // Output blocks render each line in its own span; rebuild the
        // newline-separated text and strip the zero-width-space placeholder
        // we use to keep empty lines visible.
        var parts = [];
        lineNodes.forEach(function (n) {
          var t = n.textContent.replace(/\u200B/g, '');
          parts.push(t);
        });
        text = parts.join('\n');
      } else {
        var pre = card.querySelector('pre');
        if (!pre) return;
        text = pre.innerText;
      }
      var done = function () {
        var original = btn.textContent;
        btn.textContent = 'Copied';
        btn.classList.add('copied');
        setTimeout(function () {
          btn.textContent = original;
          btn.classList.remove('copied');
        }, 1500);
      };
      if (navigator.clipboard && navigator.clipboard.writeText) {
        navigator.clipboard.writeText(text).then(done).catch(function () {
          legacyCopy(text); done();
        });
      } else {
        legacyCopy(text); done();
      }
    });
  });

  function legacyCopy(text) {
    var area = document.createElement('textarea');
    area.value = text;
    area.style.position = 'fixed';
    area.style.left = '-9999px';
    document.body.appendChild(area);
    area.select();
    try { document.execCommand('copy'); } catch (e) {}
    document.body.removeChild(area);
  }

  // Highlight.js
  if (window.hljs) {
    // Standard code/source blocks: highlight in place.
    document.querySelectorAll('.showless-block pre code[class*="language-"]:not(.output-content)').forEach(function (el) {
      try { window.hljs.highlightElement(el); } catch (e) {}
    });

    // Output blocks: each captured line lives in its own <span class="output-line"> so
    // line wrapping stays bullet-proof. Highlight per line using the inferred language
    // (set server-side from a preceding `sed`/`cat`/`awk` command), or fall back to
    // auto-detection when the relevance is high enough to avoid mis-highlighting plain
    // status lines like "swift build ok".
    document.querySelectorAll('.output-block code.output-content').forEach(function (code) {
      var lines = code.querySelectorAll('.output-line');
      if (!lines.length) return;

      var texts = [];
      lines.forEach(function (l) { texts.push(l.textContent.replace(/\u200B/g, '')); });
      var fullText = texts.join('\n').trim();
      if (fullText.length < 4) return;

      var langMatch = code.className.match(/language-(\S+)/);
      var lang = langMatch ? langMatch[1] : null;

      if (!lang) {
        try {
          var detect = window.hljs.highlightAuto(fullText);
          if (detect && detect.relevance >= 8 && detect.language) {
            lang = detect.language;
            code.classList.add('hljs', 'language-' + lang);
          }
        } catch (e) {}
      }

      if (!lang) return;

      lines.forEach(function (line, i) {
        var text = texts[i];
        if (!text) return;
        try {
          var hl = window.hljs.highlight(text, { language: lang, ignoreIllegals: true });
          if (hl && hl.value) line.innerHTML = hl.value;
        } catch (e) {}
      });
    });
  }

  // Mermaid: render every captured diagram, replacing the <pre> in place.
  // On any rendering error we substitute a friendly inline error block that
  // shows the parser message together with the raw diagram source, so the
  // page itself acts as the diagram validator.
  function escapeHTML(s) {
    return String(s)
      .replace(/&/g, '&amp;')
      .replace(/</g, '&lt;')
      .replace(/>/g, '&gt;')
      .replace(/"/g, '&quot;')
      .replace(/'/g, '&#39;');
  }

  function makeErrorBlock(message, source) {
    return '<div class="mermaid-error" role="alert">'
      + '<div class="mermaid-error-title">Diagram failed to render</div>'
      + '<p class="mermaid-error-message">' + escapeHTML(message) + '</p>'
      + '<pre class="mermaid-error-source">' + escapeHTML(source) + '</pre>'
      + '</div>';
  }

  function renderOneDiagram(container, source, idx) {
    if (!window.mermaid) return Promise.resolve();
    container.innerHTML = '<pre class="mermaid">' + escapeHTML(source) + '</pre>';
    var node = container.querySelector('pre.mermaid');
    node.removeAttribute('data-processed');
    var renderId = 'showless-mermaid-' + idx + '-' + Date.now();
    try {
      var maybe = window.mermaid.run({ nodes: [node], suppressErrors: true });
      if (maybe && typeof maybe.then === 'function') {
        return maybe.catch(function (err) {
          container.innerHTML = makeErrorBlock(
            (err && (err.message || err.str)) || 'Unknown mermaid parse error.',
            source
          );
        });
      }
      return Promise.resolve();
    } catch (err) {
      container.innerHTML = makeErrorBlock(
        (err && (err.message || err.str)) || 'Unknown mermaid parse error.',
        source
      );
      return Promise.resolve();
    }
  }

  function rerenderMermaid() {
    if (!window.mermaid) return;
    var theme = currentEffectiveTheme();
    try {
      window.mermaid.initialize({
        startOnLoad: false,
        theme: theme === 'dark' ? 'dark' : 'default',
        securityLevel: 'loose',
        fontFamily: 'JetBrains Mono, ui-monospace, SF Mono, Menlo, monospace'
      });
    } catch (e) { /* swallow init errors; render call below will surface them */ }

    // Render diagrams sequentially so errors are reported per-diagram and
    // don't get lost in a race.
    mermaidContainers.reduce(function (chain, entry, idx) {
      return chain.then(function () { return renderOneDiagram(entry.container, entry.source, idx); });
    }, Promise.resolve());
  }

  // Initial mermaid render after sources are captured + theme is applied.
  rerenderMermaid();
})();
"""#

