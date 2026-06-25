import Foundation

/// Renders a folder of markdown pages into a multi-page HTML documentation
/// site. Visual styling reuses every variable, animation, and inline asset
/// from `HTMLRenderer` so a docs site looks and behaves like a codewalk page
/// — with one addition: a left navigation sidebar built from the folder
/// structure (subfolders become nav groups; `reference/` is forced last).
///
/// Authoring contract: every `*.md` file in the input folder becomes one HTML
/// page in the output folder, preserving relative paths. Files may contain an
/// optional YAML frontmatter block at the top:
///
///   ---
///   title: Getting Started
///   nav_label: Getting Started
///   nav_order: 2
///   nav_group: Tutorials
///   subtitle: Install in 60 seconds
///   ---
///
/// Frontmatter keys are all optional. `title` overrides the H1, `nav_label`
/// overrides the sidebar entry text, `nav_order` controls sort order within a
/// group (smaller first; default 100), and `nav_group` overrides the parent
/// directory name as the sidebar group.
public enum DocsSiteRenderer {
    public struct Options: Sendable {
        public var siteTitle: String?
        public var subtitle: String?
        public var includeFooter: Bool

        public init(siteTitle: String? = nil, subtitle: String? = nil, includeFooter: Bool = true) {
            self.siteTitle = siteTitle
            self.subtitle = subtitle
            self.includeFooter = includeFooter
        }
    }

    public struct Report: Sendable {
        public var outputDirectory: String
        public var pages: [String]
        public var assets: [String]
        public var diagramIssues: [HTMLRenderer.DiagramIssue]
    }

    /// Top-level rendering entry point. Walks `folder` for `*.md` files,
    /// renders each into an HTML page under `outputFolder`, generates a
    /// landing `index.html` (from `index.md` if present, otherwise synthetic),
    /// and returns a structured report.
    public static func render(folder: String, outputFolder: String, options: Options = Options()) throws -> Report {
        let fileManager = FileManager.default
        var isDir: ObjCBool = false
        guard fileManager.fileExists(atPath: folder, isDirectory: &isDir), isDir.boolValue else {
            throw ShowlessError.fileNotFound(folder)
        }

        let folderURL = URL(fileURLWithPath: folder).standardizedFileURL
        let siteConfig = loadSiteConfig(in: folderURL)
        let pages = try discoverPages(in: folderURL)
        guard !pages.isEmpty else {
            throw ShowlessError.execution(
                "no .md files found under \(folder). Author at least one page (e.g. `\(folder)/index.md`) before running docs-html."
            )
        }
        let nav = buildNav(pages)

        // Resolution order, most explicit wins:
        //   CLI flag > site.config.md frontmatter > built-in fallback.
        let siteTitle = options.siteTitle
            ?? siteConfig["title"]
            ?? folderURL.lastPathComponent.capitalized + " Documentation"
        let subtitle = options.subtitle ?? siteConfig["subtitle"]
        // Optional brand-link override. When unset, the topbar title still
        // points at the docs root (`index.html`).
        let brandURL = siteConfig["home_url"].flatMap { $0.isEmpty ? nil : $0 }

        var diagramIssues: [HTMLRenderer.DiagramIssue] = []
        var writtenPaths: [String] = []
        var copiedAssets: [String] = []

        // Copy any non-markdown assets (images, PDFs, fonts, …) from the
        // docs folder into the matching location in the output folder so
        // relative references like `![chart](images/chart.png)` resolve.
        copiedAssets = try copyAssets(from: folderURL, to: URL(fileURLWithPath: outputFolder))

        // Render each authored page.
        for (index, page) in pages.enumerated() {
            let prev = index > 0 ? pages[index - 1] : nil
            let next = index + 1 < pages.count ? pages[index + 1] : nil
            var inner = HTMLRenderer.renderInner(page.blocks)
            inner.body = rewriteInternalMarkdownLinks(inner.body)
            diagramIssues.append(contentsOf: HTMLRenderer.lintDiagrams(page.blocks))

            let html = assemblePage(
                page: page,
                nav: nav,
                inner: inner,
                prev: prev,
                next: next,
                siteTitle: siteTitle,
                subtitle: subtitle,
                brandURL: brandURL,
                includeFooter: options.includeFooter
            )

            let outURL = URL(fileURLWithPath: outputFolder)
                .appendingPathComponent(page.outputRelativePath)
            try fileManager.createDirectory(
                at: outURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try html.write(to: outURL, atomically: true, encoding: .utf8)
            writtenPaths.append(outURL.path)
        }

        // Make sure there's always an index.html at the root. If the user
        // didn't author one, synthesise it from the nav so the site is
        // immediately browsable.
        let rootIndex = URL(fileURLWithPath: outputFolder).appendingPathComponent("index.html")
        if !fileManager.fileExists(atPath: rootIndex.path) {
            let html = assembleSyntheticIndex(
                pages: pages,
                nav: nav,
                siteTitle: siteTitle,
                subtitle: subtitle,
                brandURL: brandURL,
                includeFooter: options.includeFooter
            )
            try fileManager.createDirectory(
                at: rootIndex.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try html.write(to: rootIndex, atomically: true, encoding: .utf8)
            writtenPaths.append(rootIndex.path)
        }

        return Report(outputDirectory: outputFolder, pages: writtenPaths, assets: copiedAssets, diagramIssues: diagramIssues)
    }

    /// Walks `folder` and copies every file that is not a `.md` to the
    /// matching location under `destination`, preserving relative paths.
    /// Skips the destination directory itself (when nested inside the docs
    /// folder, e.g. `docs/_site`) and any hidden file.
    private static func copyAssets(from folder: URL, to destination: URL) throws -> [String] {
        let fileManager = FileManager.default
        let destStandardized = destination.standardizedFileURL.path
        guard let enumerator = fileManager.enumerator(
            at: folder,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else {
            return []
        }

        var copied: [String] = []
        for case let url as URL in enumerator {
            let name = url.lastPathComponent
            if name == "_site" || url.standardizedFileURL.path == destStandardized {
                enumerator.skipDescendants()
                continue
            }
            // Also skip anything nested inside the destination (handles
            // `--output docs/_site` where the output lives under the source).
            if url.standardizedFileURL.path.hasPrefix(destStandardized + "/") {
                enumerator.skipDescendants()
                continue
            }
            let ext = url.pathExtension.lowercased()
            if ext == "md" { continue }
            let isRegular = (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) ?? false
            guard isRegular else { continue }

            let relative = relativePath(of: url, in: folder)
            let outURL = destination.appendingPathComponent(relative)
            try fileManager.createDirectory(at: outURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            if fileManager.fileExists(atPath: outURL.path) {
                try fileManager.removeItem(at: outURL)
            }
            try fileManager.copyItem(at: url, to: outURL)
            copied.append(outURL.path)
        }
        return copied
    }

    // MARK: - Site config

    /// Conventional filename for site-level metadata. Reserved: the file is
    /// parsed for its YAML frontmatter (`title`, `subtitle`) and otherwise
    /// skipped — it never appears in the nav or as a rendered page.
    static let siteConfigFilename = "site.config.md"

    /// Reads `site.config.md` from the root of `folder`, parses its
    /// YAML frontmatter, and returns the resulting key/value pairs.
    /// Returns an empty dictionary when the file is absent or unreadable.
    private static func loadSiteConfig(in folder: URL) -> [String: String] {
        let configURL = folder.appendingPathComponent(siteConfigFilename)
        guard let raw = try? String(contentsOf: configURL, encoding: .utf8) else {
            return [:]
        }
        let (frontmatter, _) = splitFrontmatter(raw)
        return frontmatter
    }

    // MARK: - Discovery

    struct Page {
        var relativePath: String        // e.g. "how-to/install.md"
        var outputRelativePath: String  // e.g. "how-to/install.html"
        var depth: Int                  // 0 = top level
        var group: String               // "" for top-level, otherwise the subfolder
        var title: String
        var navLabel: String
        var navOrder: Int
        var subtitle: String?
        var blocks: [ShowBlock]
    }

    private static let defaultNavOrder = 100

    private static func discoverPages(in folder: URL) throws -> [Page] {
        let fileManager = FileManager.default
        guard let enumerator = fileManager.enumerator(
            at: folder,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else {
            return []
        }

        var pages: [Page] = []
        for case let url as URL in enumerator {
            let name = url.lastPathComponent
            // Skip the output dir itself (default `_site`) and anything that
            // looks like a previously-generated site.
            if name == "_site" {
                enumerator.skipDescendants()
                continue
            }
            // The site config file is metadata, not a page.
            if name == siteConfigFilename { continue }
            guard url.pathExtension.lowercased() == "md" else { continue }

            let relative = relativePath(of: url, in: folder)
            let raw = try String(contentsOf: url, encoding: .utf8)
            let (frontmatter, body) = splitFrontmatter(raw)
            let blocks = try MarkdownParser.parse(body)

            let h1 = firstHeading(blocks) ?? defaultTitle(forFilename: name)
            let title = frontmatter["title"] ?? h1
            // Default sidebar label is the title with inline markdown stripped
            // (e.g. `` # `init` syntax `` becomes "init syntax").
            let navLabel = frontmatter["nav_label"] ?? stripMarkdownEmphasis(title)
            let navOrder = Int(frontmatter["nav_order"] ?? "") ?? defaultNavOrder
            let subtitle = frontmatter["subtitle"]
            let groupOverride = frontmatter["nav_group"]

            let parts = relative.components(separatedBy: "/")
            let depth = parts.count - 1
            let group: String
            if let override = groupOverride, !override.isEmpty {
                group = override
            } else if depth >= 1 {
                group = parts[0]
            } else {
                group = ""
            }

            let outRel = (relative as NSString).deletingPathExtension + ".html"

            pages.append(Page(
                relativePath: relative,
                outputRelativePath: outRel,
                depth: depth,
                group: group,
                title: title,
                navLabel: navLabel,
                navOrder: navOrder,
                subtitle: subtitle,
                blocks: blocks
            ))
        }

        // Order: index.md first at top level; reference/* group last;
        // within each group, nav_order ASC then alphabetical.
        pages.sort { lhs, rhs in
            // index.md at top level always wins.
            let lhsIsRootIndex = lhs.group == "" && filename(lhs.relativePath).lowercased() == "index"
            let rhsIsRootIndex = rhs.group == "" && filename(rhs.relativePath).lowercased() == "index"
            if lhsIsRootIndex != rhsIsRootIndex { return lhsIsRootIndex }

            // Reference group last.
            let lhsRef = lhs.group.lowercased() == "reference"
            let rhsRef = rhs.group.lowercased() == "reference"
            if lhsRef != rhsRef { return !lhsRef }

            // Different groups: top-level (empty) first, then alpha by group name.
            if lhs.group != rhs.group {
                if lhs.group == "" { return true }
                if rhs.group == "" { return false }
                return lhs.group.lowercased() < rhs.group.lowercased()
            }

            // Same group: nav_order, then alpha.
            if lhs.navOrder != rhs.navOrder { return lhs.navOrder < rhs.navOrder }
            return filename(lhs.relativePath).lowercased() < filename(rhs.relativePath).lowercased()
        }

        return pages
    }

    private static func relativePath(of url: URL, in folder: URL) -> String {
        let folderPath = folder.path.hasSuffix("/") ? folder.path : folder.path + "/"
        let abs = url.standardizedFileURL.path
        if abs.hasPrefix(folderPath) {
            return String(abs.dropFirst(folderPath.count))
        }
        return url.lastPathComponent
    }

    private static func filename(_ relativePath: String) -> String {
        ((relativePath as NSString).lastPathComponent as NSString).deletingPathExtension
    }

    private static func defaultTitle(forFilename name: String) -> String {
        let base = (name as NSString).deletingPathExtension
        // "getting-started" -> "Getting Started"
        let words = base.split(whereSeparator: { $0 == "-" || $0 == "_" })
        return words.map { word -> String in
            guard let first = word.first else { return "" }
            return first.uppercased() + word.dropFirst()
        }.joined(separator: " ")
    }

    private static func firstHeading(_ blocks: [ShowBlock]) -> String? {
        for block in blocks {
            switch block {
            case .title(let t):
                return t.title
            case .commentary(let c):
                for line in c.text.components(separatedBy: "\n") {
                    if line.hasPrefix("# ") {
                        return String(line.dropFirst(2))
                    }
                }
                return nil
            default:
                continue
            }
        }
        return nil
    }

    // MARK: - Frontmatter

    private static func splitFrontmatter(_ raw: String) -> (frontmatter: [String: String], body: String) {
        let normalized = raw.replacingOccurrences(of: "\r\n", with: "\n")
        guard normalized.hasPrefix("---\n") else {
            return ([:], normalized)
        }
        let afterOpen = normalized.dropFirst("---\n".count)
        guard let closingRange = afterOpen.range(of: "\n---\n") else {
            // Tolerate missing trailing newline.
            if let altRange = afterOpen.range(of: "\n---") {
                let fmText = afterOpen[..<altRange.lowerBound]
                let body = String(afterOpen[altRange.upperBound...]).trimmingCharacters(in: CharacterSet(charactersIn: "\n"))
                return (parseFrontmatter(String(fmText)), body)
            }
            return ([:], normalized)
        }
        let fmText = afterOpen[..<closingRange.lowerBound]
        let body = afterOpen[closingRange.upperBound...]
        return (parseFrontmatter(String(fmText)), String(body))
    }

    private static func parseFrontmatter(_ text: String) -> [String: String] {
        var result: [String: String] = [:]
        for raw in text.components(separatedBy: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") { continue }
            guard let colon = line.firstIndex(of: ":") else { continue }
            let key = String(line[..<colon]).trimmingCharacters(in: .whitespaces)
            var value = String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
            // Strip surrounding quotes if present.
            if value.count >= 2,
               (value.hasPrefix("\"") && value.hasSuffix("\"")) ||
               (value.hasPrefix("'") && value.hasSuffix("'")) {
                value = String(value.dropFirst().dropLast())
            }
            if !key.isEmpty { result[key] = value }
        }
        return result
    }

    // MARK: - Nav model

    struct NavGroup {
        var name: String          // "" for the top-level (ungrouped)
        var displayLabel: String  // shown as the sidebar group heading
        var pages: [Page]
    }

    private static func buildNav(_ pages: [Page]) -> [NavGroup] {
        var byGroup: [String: [Page]] = [:]
        var order: [String] = []
        for page in pages {
            if byGroup[page.group] == nil {
                byGroup[page.group] = []
                order.append(page.group)
            }
            byGroup[page.group]?.append(page)
        }
        return order.map { name in
            NavGroup(name: name, displayLabel: navGroupLabel(name), pages: byGroup[name] ?? [])
        }
    }

    private static func navGroupLabel(_ name: String) -> String {
        if name.isEmpty { return "" }
        return defaultTitle(forFilename: name)
    }

    // MARK: - Page assembly

    private static func assemblePage(
        page: Page,
        nav: [NavGroup],
        inner: HTMLRenderer.InnerRender,
        prev: Page?,
        next: Page?,
        siteTitle: String,
        subtitle: String?,
        brandURL: String?,
        includeFooter: Bool
    ) -> String {
        let rootPrefix = relativeRootPrefix(from: page.outputRelativePath)
        let escapedTitle = HTMLRenderer.escapeText(page.title)
        let escapedSite = HTMLRenderer.escapeText(siteTitle)

        let head = pageHead(
            pageTitle: escapedTitle,
            siteTitle: escapedSite,
            rootPrefix: rootPrefix
        )

        let topbar = renderTopbar(siteTitle: siteTitle, subtitle: subtitle, brandURL: brandURL, rootPrefix: rootPrefix)
        let sidebar = renderSidebar(nav: nav, currentRelativePath: page.outputRelativePath, rootPrefix: rootPrefix)

        let breadcrumb = renderBreadcrumb(page: page, siteTitle: siteTitle, rootPrefix: rootPrefix)

        let subtitleHTML: String
        if let s = page.subtitle, !s.isEmpty {
            subtitleHTML = "<p class=\"docs-page-subtitle\">\(HTMLRenderer.escapeText(s))</p>"
        } else {
            subtitleHTML = ""
        }

        // Prepend a synthetic TOC entry for the page title so the first thing
        // a reader sees at the top of the page is also the first jump in the
        // in-page nav. Anchors to `#docs-top`, which is set on the page header.
        let topEntry = HTMLRenderer.TOCEntry(level: 2, title: page.title, slug: "docs-top")
        let tocEntries = [topEntry] + inner.toc
        let tocAside = HTMLRenderer.renderTOCAside(tocEntries)
        let layoutClass = "with-toc"

        let pager = renderPager(prev: prev, next: next, currentRelativePath: page.outputRelativePath)

        let footer = renderFooter(siteTitle: siteTitle, include: includeFooter)

        // Strip the first H2 mention's chapter number side-rail by reusing
        // the existing CSS via the `docs-site` body class.
        return """
        <!doctype html>
        <html lang="en" data-theme="auto">
        \(head)
        <body class="docs-site no-transition">
          <div class="reading-progress" aria-hidden="true"><div class="reading-progress-fill"></div></div>
          \(topbar)
          <div class="docs-shell">
            \(sidebar)
            <main class="docs-main">
              <div class="docs-page">
                <header class="docs-page-header" id="docs-top">
                  \(breadcrumb)
                  <h1 class="docs-page-title">\(escapedTitle)</h1>
                  \(subtitleHTML)
                </header>
                <div class="layout \(layoutClass)">
                  <article class="content docs-content">
        \(inner.body)
                  </article>
                  \(tocAside)
                </div>
                \(pager)
              </div>
            </main>
          </div>
          \(footer)
          <button type="button" class="back-to-top" aria-label="Back to top" title="Back to top">↑</button>
          <script src="https://cdn.jsdelivr.net/gh/highlightjs/cdn-release@11.9.0/build/highlight.min.js"></script>
          <script src="https://cdn.jsdelivr.net/npm/mermaid@10/dist/mermaid.min.js"></script>
          <script>
        \(inlineScript)
          </script>
          <script>
        \(docsSidebarScript)
          </script>
        </body>
        </html>
        """
    }

    private static func assembleSyntheticIndex(
        pages: [Page],
        nav: [NavGroup],
        siteTitle: String,
        subtitle: String?,
        brandURL: String?,
        includeFooter: Bool
    ) -> String {
        let escapedSite = HTMLRenderer.escapeText(siteTitle)
        let head = pageHead(pageTitle: escapedSite, siteTitle: escapedSite, rootPrefix: "")
        let topbar = renderTopbar(siteTitle: siteTitle, subtitle: subtitle, brandURL: brandURL, rootPrefix: "")
        let sidebar = renderSidebar(nav: nav, currentRelativePath: "index.html", rootPrefix: "")

        var cards = ""
        for group in nav {
            let label = group.name.isEmpty ? "Start here" : navGroupLabel(group.name)
            cards += "<section class=\"docs-index-group\">\n"
            cards += "<h2 class=\"docs-index-group-title\">\(HTMLRenderer.escapeText(label))</h2>\n"
            cards += "<div class=\"docs-index-grid\">\n"
            for page in group.pages {
                let href = HTMLRenderer.escapeAttribute(page.outputRelativePath)
                let title = HTMLRenderer.escapeText(page.title)
                let blurb = HTMLRenderer.escapeText(page.subtitle ?? firstParagraphBlurb(page.blocks) ?? "")
                cards += """
                <a class="docs-index-card" href="\(href)">
                  <span class="docs-index-card-title">\(title)</span>
                  <span class="docs-index-card-blurb">\(blurb)</span>
                </a>
                """
            }
            cards += "</div>\n</section>\n"
        }

        let subtitleHTML: String
        if let s = subtitle, !s.isEmpty {
            subtitleHTML = "<p class=\"docs-page-subtitle\">\(HTMLRenderer.escapeText(s))</p>"
        } else {
            subtitleHTML = "<p class=\"docs-page-subtitle\">Browse the documentation</p>"
        }

        let footer = renderFooter(siteTitle: siteTitle, include: includeFooter)

        return """
        <!doctype html>
        <html lang="en" data-theme="auto">
        \(head)
        <body class="docs-site docs-index no-transition">
          <div class="reading-progress" aria-hidden="true"><div class="reading-progress-fill"></div></div>
          \(topbar)
          <div class="docs-shell">
            \(sidebar)
            <main class="docs-main">
              <div class="docs-page">
                <header class="docs-page-header">
                  <h1 class="docs-page-title">\(escapedSite)</h1>
                  \(subtitleHTML)
                </header>
                \(cards)
              </div>
            </main>
          </div>
          \(footer)
          <button type="button" class="back-to-top" aria-label="Back to top" title="Back to top">↑</button>
          <script>
        \(docsSidebarScript)
          </script>
        </body>
        </html>
        """
    }

    private static func firstParagraphBlurb(_ blocks: [ShowBlock]) -> String? {
        for block in blocks {
            if case .commentary(let c) = block {
                for raw in c.text.components(separatedBy: "\n\n") {
                    let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
                    if trimmed.isEmpty { continue }
                    if trimmed.hasPrefix("#") { continue }
                    if trimmed.hasPrefix("-") || trimmed.hasPrefix("*") { continue }
                    if trimmed.hasPrefix(">") { continue }
                    let oneLine = trimmed.replacingOccurrences(of: "\n", with: " ")
                    let stripped = stripMarkdownEmphasis(oneLine)
                    if stripped.count <= 160 { return stripped }
                    let end = stripped.index(stripped.startIndex, offsetBy: 157)
                    return String(stripped[..<end]) + "…"
                }
            }
        }
        return nil
    }

    private static func stripMarkdownEmphasis(_ s: String) -> String {
        var t = s
        for pattern in [#"\*\*([^*]+)\*\*"#, #"\*([^*\s][^*]*?)\*"#, "`([^`]+)`"] {
            if let regex = try? NSRegularExpression(pattern: pattern) {
                let range = NSRange(t.startIndex..<t.endIndex, in: t)
                t = regex.stringByReplacingMatches(in: t, range: range, withTemplate: "$1")
            }
        }
        return t
    }

    // MARK: - Components

    private static func pageHead(pageTitle: String, siteTitle: String, rootPrefix: String) -> String {
        return """
        <head>
          <meta charset="utf-8">
          <meta name="viewport" content="width=device-width, initial-scale=1">
          <title>\(pageTitle) · \(siteTitle)</title>
          <meta name="generator" content="Showless DocsSiteRenderer">
          <script>
        \(themeBootScript)
          </script>
          <link rel="preconnect" href="https://fonts.googleapis.com">
          <link rel="preconnect" href="https://fonts.gstatic.com" crossorigin>
          <link href="https://fonts.googleapis.com/css2?family=Inter:wght@400;500;600;700&family=JetBrains+Mono:wght@400;500;600;700&family=Newsreader:ital,wght@0,400;0,500;0,600;1,400&display=optional" rel="stylesheet">
          <style>
        \(inlineStylesheet)
        \(docsExtraStylesheet)
          </style>
        </head>
        """
    }

    private static func renderTopbar(siteTitle: String, subtitle: String?, brandURL: String?, rootPrefix: String) -> String {
        let escapedSite = HTMLRenderer.escapeText(siteTitle)
        let subtitleHTML: String
        if let s = subtitle, !s.isEmpty {
            subtitleHTML = "<span class=\"docs-brand-subtitle\">\(HTMLRenderer.escapeText(s))</span>"
        } else {
            subtitleHTML = ""
        }

        // Brand link target: explicit override from `site.config.md` wins; else
        // back to the docs root (`index.html`, resolved relative to the page).
        let href: String
        let externalAttrs: String
        if let custom = brandURL {
            href = custom
            externalAttrs = isExternalURL(custom) ? " target=\"_blank\" rel=\"noopener noreferrer\"" : ""
        } else {
            href = rootPrefix.isEmpty ? "index.html" : rootPrefix + "index.html"
            externalAttrs = ""
        }

        return """
        <header class="docs-topbar">
          <div class="docs-topbar-inner">
            <button type="button" class="docs-sidebar-toggle" aria-label="Toggle navigation" aria-expanded="false">☰</button>
            <a href="\(HTMLRenderer.escapeAttribute(href))" class="docs-brand"\(externalAttrs)>
              <span class="docs-brand-title">\(escapedSite)</span>
              \(subtitleHTML)
            </a>
            <button type="button" class="theme-toggle" aria-label="Cycle color theme" title="Cycle theme">
              <span class="theme-icon" data-icon="auto" aria-hidden="true">◐</span>
              <span class="theme-text">Theme</span>
            </button>
          </div>
        </header>
        """
    }

    private static func isExternalURL(_ s: String) -> Bool {
        let lower = s.lowercased()
        for prefix in ["http://", "https://", "mailto:", "ftp://", "tel:", "//"] {
            if lower.hasPrefix(prefix) { return true }
        }
        return false
    }

    private static func renderSidebar(nav: [NavGroup], currentRelativePath: String, rootPrefix: String) -> String {
        var html = "<aside class=\"docs-sidebar\" aria-label=\"Documentation navigation\">\n<nav class=\"docs-nav\">\n"

        // Site-level entries: a single "Home" link that always points at the
        // root index. We render this regardless of whether an index page is
        // among the authored pages.
        html += "<ul class=\"docs-nav-list docs-nav-top\">\n"
        let homeHref = rootPrefix.isEmpty ? "index.html" : rootPrefix + "index.html"
        let homeActive = currentRelativePath.lowercased() == "index.html"
        let homeClass = homeActive ? "docs-nav-item active" : "docs-nav-item"
        html += "  <li class=\"\(homeClass)\"><a href=\"\(HTMLRenderer.escapeAttribute(homeHref))\">Home</a></li>\n"
        html += "</ul>\n"

        for group in nav {
            if group.name.isEmpty {
                html += "<ul class=\"docs-nav-list\">\n"
                for page in group.pages where !isRootIndex(page) {
                    html += navItemLI(page: page, currentRelativePath: currentRelativePath, rootPrefix: rootPrefix)
                }
                html += "</ul>\n"
            } else {
                let label = HTMLRenderer.escapeText(navGroupLabel(group.name))
                html += "<div class=\"docs-nav-group\">\n"
                html += "  <div class=\"docs-nav-group-title\">\(label)</div>\n"
                html += "  <ul class=\"docs-nav-list\">\n"
                for page in group.pages {
                    html += navItemLI(page: page, currentRelativePath: currentRelativePath, rootPrefix: rootPrefix)
                }
                html += "  </ul>\n"
                html += "</div>\n"
            }
        }

        html += "</nav>\n</aside>"
        return html
    }

    private static func isRootIndex(_ page: Page) -> Bool {
        page.group == "" && filename(page.relativePath).lowercased() == "index"
    }

    private static func navItemLI(page: Page, currentRelativePath: String, rootPrefix: String) -> String {
        let active = page.outputRelativePath == currentRelativePath
        let cssClass = active ? "docs-nav-item active" : "docs-nav-item"
        let href = rootPrefix + page.outputRelativePath
        let label = HTMLRenderer.escapeText(page.navLabel)
        return "    <li class=\"\(cssClass)\"><a href=\"\(HTMLRenderer.escapeAttribute(href))\">\(label)</a></li>\n"
    }

    private static func renderBreadcrumb(page: Page, siteTitle: String, rootPrefix: String) -> String {
        var crumbs: [String] = []
        let homeHref = rootPrefix.isEmpty ? "index.html" : rootPrefix + "index.html"
        crumbs.append("<a href=\"\(HTMLRenderer.escapeAttribute(homeHref))\">\(HTMLRenderer.escapeText(siteTitle))</a>")
        if !page.group.isEmpty {
            crumbs.append("<span>\(HTMLRenderer.escapeText(navGroupLabel(page.group)))</span>")
        }
        return "<p class=\"docs-breadcrumb\">\(crumbs.joined(separator: " <span class=\"docs-breadcrumb-sep\">›</span> "))</p>"
    }

    private static func renderPager(prev: Page?, next: Page?, currentRelativePath: String) -> String {
        guard prev != nil || next != nil else { return "" }
        var html = "<nav class=\"docs-pager\" aria-label=\"Page navigation\">\n"
        if let prev {
            let href = relativeLink(from: currentRelativePath, to: prev.outputRelativePath)
            html += """
              <a class="docs-pager-prev" href="\(HTMLRenderer.escapeAttribute(href))">
                <span class="docs-pager-label">← Previous</span>
                <span class="docs-pager-title">\(HTMLRenderer.escapeText(prev.navLabel))</span>
              </a>
            """
        } else {
            html += "<span class=\"docs-pager-spacer\"></span>\n"
        }
        if let next {
            let href = relativeLink(from: currentRelativePath, to: next.outputRelativePath)
            html += """
              <a class="docs-pager-next" href="\(HTMLRenderer.escapeAttribute(href))">
                <span class="docs-pager-label">Next →</span>
                <span class="docs-pager-title">\(HTMLRenderer.escapeText(next.navLabel))</span>
              </a>
            """
        } else {
            html += "<span class=\"docs-pager-spacer\"></span>\n"
        }
        html += "\n</nav>"
        return html
    }

    private static func renderFooter(siteTitle: String, include: Bool) -> String {
        guard include else { return "" }
        return """
        <footer class="docs-footer">
          <span>\(HTMLRenderer.escapeText(siteTitle)) · rendered with <a href="https://github.com/" target="_blank" rel="noopener noreferrer" class="brand">Showless</a></span>
        </footer>
        """
    }

    // MARK: - Internal link rewriting

    /// `HTMLRenderer.renderInline` emits every prose link as
    /// `<a href="..." target="_blank" rel="noopener noreferrer">…</a>`, which
    /// is correct for codewalk pages (one self-contained HTML, every link
    /// goes off-site) but wrong for a docs site, where cross-page links
    /// should (a) point at the rendered `.html` and (b) navigate in place.
    ///
    /// This pass walks the rendered body and rewrites every `*.md` href that
    /// is not an external URL or a same-page fragment. The fragment portion
    /// (`#section`) is preserved.
    static func rewriteInternalMarkdownLinks(_ body: String) -> String {
        let pattern = #"<a href="([^"]+)" target="_blank" rel="noopener noreferrer">"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return body }
        let nsBody = body as NSString
        let fullRange = NSRange(location: 0, length: nsBody.length)
        let matches = regex.matches(in: body, range: fullRange)
        guard !matches.isEmpty else { return body }

        var result = ""
        var cursor = 0
        for match in matches {
            let matchRange = match.range
            let hrefRange = match.range(at: 1)
            guard hrefRange.location != NSNotFound else { continue }
            let href = nsBody.substring(with: hrefRange)

            result += nsBody.substring(with: NSRange(location: cursor, length: matchRange.location - cursor))

            let (rewritten, isInternal) = rewriteHrefIfInternal(href)
            if isInternal {
                result += "<a href=\"\(HTMLRenderer.escapeAttribute(rewritten))\">"
            } else {
                result += nsBody.substring(with: matchRange)
            }
            cursor = matchRange.location + matchRange.length
        }
        if cursor < nsBody.length {
            result += nsBody.substring(with: NSRange(location: cursor, length: nsBody.length - cursor))
        }
        return result
    }

    /// Returns the rewritten href and whether the link is treated as an
    /// internal docs-site link. External schemes (http, https, mailto, ftp,
    /// tel, file, data) and root-anchor fragments are passed through
    /// untouched.
    private static func rewriteHrefIfInternal(_ href: String) -> (String, Bool) {
        let lower = href.lowercased()
        let externalPrefixes = ["http://", "https://", "mailto:", "ftp://", "tel:", "file://", "data:"]
        for prefix in externalPrefixes {
            if lower.hasPrefix(prefix) { return (href, false) }
        }
        if href.hasPrefix("#") { return (href, true) }

        // Split off any fragment.
        let path: String
        let fragment: String
        if let hashIdx = href.firstIndex(of: "#") {
            path = String(href[..<hashIdx])
            fragment = String(href[hashIdx...])
        } else {
            path = href
            fragment = ""
        }

        // Rewrite `.md` to `.html`. If the link doesn't end in `.md`, leave
        // it alone but still drop the new-tab attributes (internal anchor /
        // fragment-only / hash-only links).
        if path.lowercased().hasSuffix(".md") {
            let rewritten = String(path.dropLast(3)) + ".html" + fragment
            return (rewritten, true)
        }

        // Same-page fragment without a path is already handled above. Other
        // hrefs (e.g. `screenshot.png`, `./foo.html`) keep their original
        // value but still count as internal so we strip `target="_blank"`.
        return (href, true)
    }

    // MARK: - Path helpers

    /// For a page at `dir/sub/page.html`, returns `"../../"` so links to the
    /// root resolve correctly. Top-level pages return `""`.
    private static func relativeRootPrefix(from outputRelativePath: String) -> String {
        let parts = outputRelativePath.components(separatedBy: "/")
        let depth = parts.count - 1
        if depth <= 0 { return "" }
        return String(repeating: "../", count: depth)
    }

    /// Produces a path from `currentRelativePath` to `targetRelativePath`.
    /// Both are relative to the site root, e.g. `how-to/install.html`.
    private static func relativeLink(from currentRelativePath: String, to targetRelativePath: String) -> String {
        let prefix = relativeRootPrefix(from: currentRelativePath)
        return prefix + targetRelativePath
    }
}

// MARK: - Extra stylesheet + sidebar script

/// CSS additions specific to the docs site. Loaded right after the codewalk
/// stylesheet so every variable, color, and animation is shared; only the
/// layout and a few new components are overridden.
let docsExtraStylesheet: String = """
/* Docs site — hides the heavy hero and switches to a sidebar layout. */
body.docs-site .hero { display: none; }
body.docs-site .page-controls { display: none; }

/* Disable the codewalk section-reveal animation on docs pages. Codewalks
 * load once and benefit from the fade-in flourish; a docs site reloads on
 * every sidebar click, so the same animation reads as a jingle on every
 * navigation. Render content at rest immediately. */
body.docs-site .section-heading,
body.docs-site .showless-block,
body.docs-site .content > p,
body.docs-site .content > ul,
body.docs-site .content > ol,
body.docs-site .content > blockquote,
body.docs-site .content > h1,
body.docs-site .content > h2,
body.docs-site .content > h3,
body.docs-site .content > pre,
body.docs-site .content > div,
body.docs-site .content > figure {
  opacity: 1 !important;
  transform: none !important;
  transition: none !important;
  animation: none !important;
}

/* Other page-load animations the codewalk page gets right but a multi-page
 * site renders as a flicker on every navigation:
 *   - Browser smooth-scrolling fragment jumps and scroll restoration.
 *   - The reading-progress bar tweening from `scaleX(0)` to its first value.
 *   - The TOC auto-scrolling the active link into view on load. */
body.docs-site,
html:has(body.docs-site) {
  scroll-behavior: auto;
}
body.docs-site .reading-progress-fill { transition: none; }

/* Always reserve space for the vertical scrollbar so navigating between
 * pages of different content heights doesn't shift the layout sideways
 * when the scrollbar appears or disappears. */
html:has(body.docs-site) { overflow-y: scroll; scrollbar-gutter: stable; }

/* Suppress every transition/animation during the very first paint. The
 * inline boot script and the body footer script both remove this class on
 * the next animation frame, by which point styles have settled. Without
 * this, hover transitions and other tiny tweens can fire visibly during
 * the initial style recalculation. */
body.docs-site.no-transition,
body.docs-site.no-transition * {
  transition: none !important;
  animation: none !important;
}

.docs-topbar {
  position: sticky;
  top: 0;
  z-index: 40;
  background: var(--bg-card);
  border-bottom: 1px solid var(--border);
}
.docs-topbar-inner {
  max-width: 1440px;
  margin: 0 auto;
  padding: 12px 24px;
  display: flex;
  align-items: center;
  gap: 16px;
}
.docs-brand {
  display: flex;
  flex-direction: column;
  text-decoration: none;
  color: var(--ink-strong);
  border-bottom: none;
  margin-right: auto;
}
.docs-brand:hover { border-bottom: none; color: var(--accent); }
.docs-brand-title {
  font-family: var(--font-display);
  font-weight: 600;
  font-size: 1.15rem;
  line-height: 1.1;
  letter-spacing: -0.01em;
}
.docs-brand-subtitle {
  font-family: var(--font-mono);
  font-size: 10px;
  letter-spacing: .15em;
  text-transform: uppercase;
  color: var(--ink-faint);
  margin-top: 4px;
}
.docs-sidebar-toggle {
  display: none;
  background: transparent;
  border: 1px solid var(--border-strong);
  color: var(--ink);
  border-radius: 8px;
  padding: 6px 10px;
  font-size: 16px;
  cursor: pointer;
}
body.docs-site .docs-topbar .theme-toggle {
  position: static;
  margin-left: 8px;
}

.docs-shell {
  display: grid;
  grid-template-columns: 280px minmax(0, 1fr);
  gap: 0;
  max-width: 1440px;
  margin: 0 auto;
  align-items: start;
}

.docs-sidebar {
  position: sticky;
  top: 53px;
  align-self: start;
  max-height: calc(100vh - 53px);
  overflow-y: auto;
  padding: 28px 22px 60px;
  border-right: 1px solid var(--border);
  font-size: 13.5px;
}
.docs-nav { display: flex; flex-direction: column; gap: 22px; }
.docs-nav-top { margin-bottom: 4px; }
.docs-nav-group-title {
  font-family: var(--font-mono);
  font-size: 11px;
  letter-spacing: .15em;
  text-transform: uppercase;
  color: var(--ink-faint);
  margin: 0 0 8px;
  padding: 0 12px;
}
.docs-nav-list { list-style: none; margin: 0; padding: 0; }
.docs-nav-item { margin: 0; }
.docs-nav-item a {
  display: block;
  padding: 6px 12px;
  color: var(--ink-muted);
  border-radius: 6px;
  border-bottom: none;
  transition: background .12s ease, color .12s ease;
  line-height: 1.4;
}
.docs-nav-item a:hover { background: var(--bg-soft); color: var(--ink-strong); border-bottom: none; }
.docs-nav-item.active a {
  background: var(--accent-soft);
  color: var(--accent-strong);
  font-weight: 600;
}
.docs-sidebar::-webkit-scrollbar { width: 6px; }
.docs-sidebar::-webkit-scrollbar-thumb { background: var(--border); border-radius: 3px; }

.docs-main { padding: 40px 40px 60px; min-width: 0; }
.docs-page { max-width: 1280px; margin: 0 auto; }
.docs-page-header {
  margin-bottom: 32px;
  padding-bottom: 24px;
  border-bottom: 1px solid var(--border);
}
.docs-breadcrumb {
  font-family: var(--font-mono);
  font-size: 11px;
  letter-spacing: .12em;
  text-transform: uppercase;
  color: var(--ink-faint);
  margin: 0 0 12px;
}
.docs-breadcrumb a {
  color: var(--ink-muted);
  border-bottom: none;
}
.docs-breadcrumb a:hover { color: var(--accent); border-bottom: none; }
.docs-breadcrumb-sep { margin: 0 6px; color: var(--ink-faint); }
.docs-page-title {
  font-family: var(--font-display);
  font-weight: 600;
  font-size: clamp(1.8rem, 3.5vw, 2.4rem);
  line-height: 1.15;
  letter-spacing: -0.015em;
  margin: 0;
  color: var(--ink-strong);
  background: none;
  -webkit-background-clip: border-box;
  background-clip: border-box;
  -webkit-text-fill-color: var(--ink-strong);
}
.docs-page-subtitle {
  font-family: var(--font-sans);
  font-size: 1.05rem;
  color: var(--ink-muted);
  margin: 12px 0 0;
  font-style: italic;
}

/* Reuse the codewalk grid for content + in-page TOC, scoped tighter.
 * Content goes left/wide, TOC goes right/narrow — this matches the
 * source order in `assemblePage` (article first, toc-aside second). */
body.docs-site .layout {
  max-width: none;
  padding: 0;
  margin: 0;
  grid-template-columns: minmax(0, 1fr) 220px;
  gap: 56px;
}
body.docs-site .layout.no-toc { grid-template-columns: minmax(0, 1fr); }
body.docs-site .content { max-width: none; }
body.docs-site .toc { padding-left: 24px; border-left: 1px solid var(--border); }
body.docs-site .toc-inner { padding-right: 0; }
body.docs-site .content > p:first-of-type::first-letter {
  font-family: var(--font-sans);
  font-weight: 400;
  font-size: 1em;
  float: none;
  margin: 0;
  line-height: inherit;
  color: inherit;
}
body.docs-site .content h2:first-child,
body.docs-site .content h3:first-child { margin-top: 0; }
body.docs-site .section-heading .chapter-number { display: none; }
body.docs-site .toc-inner { top: 80px; max-height: calc(100vh - 100px); }

/* Pager */
.docs-pager {
  margin-top: 72px;
  padding-top: 28px;
  border-top: 1px solid var(--border);
  display: flex;
  gap: 16px;
  justify-content: space-between;
}
.docs-pager a {
  flex: 1 1 0;
  min-width: 0;
  padding: 16px 20px;
  border: 1px solid var(--border);
  border-radius: var(--radius-sm);
  text-decoration: none;
  color: var(--ink);
  display: flex;
  flex-direction: column;
  gap: 4px;
  transition: border-color .12s ease, background .12s ease, transform .12s ease;
}
.docs-pager a:hover {
  border-color: var(--accent);
  background: var(--bg-soft);
  border-bottom: 1px solid var(--accent);
  transform: translateY(-1px);
}
.docs-pager .docs-pager-label {
  font-family: var(--font-mono);
  font-size: 10.5px;
  letter-spacing: .12em;
  text-transform: uppercase;
  color: var(--ink-faint);
}
.docs-pager .docs-pager-title {
  font-family: var(--font-display);
  font-weight: 600;
  color: var(--ink-strong);
  font-size: 1.05rem;
}
.docs-pager .docs-pager-next { text-align: right; align-items: flex-end; }
.docs-pager-spacer { flex: 1 1 0; }

/* Footer */
.docs-footer {
  max-width: 1440px;
  margin: 0 auto;
  padding: 28px 32px;
  border-top: 1px solid var(--border);
  display: flex;
  justify-content: space-between;
  align-items: center;
  gap: 16px;
  font-family: var(--font-mono);
  font-size: 12px;
  color: var(--ink-faint);
}
.docs-footer .brand { color: var(--accent); font-weight: 600; }

/* Index page grid */
.docs-index-group { margin: 40px 0; }
.docs-index-group-title {
  font-family: var(--font-display);
  font-weight: 600;
  font-size: 1.35rem;
  color: var(--ink-strong);
  margin: 0 0 16px;
  letter-spacing: -0.01em;
}
.docs-index-grid {
  display: grid;
  grid-template-columns: repeat(auto-fit, minmax(260px, 1fr));
  gap: 16px;
}
.docs-index-card {
  display: flex;
  flex-direction: column;
  gap: 8px;
  padding: 20px 22px;
  background: var(--bg-card);
  border: 1px solid var(--border);
  border-radius: var(--radius);
  box-shadow: var(--shadow-soft);
  text-decoration: none;
  color: var(--ink);
  transition: transform .12s ease, border-color .12s ease, box-shadow .15s ease;
}
.docs-index-card:hover {
  border-color: var(--accent);
  border-bottom: 1px solid var(--accent);
  transform: translateY(-2px);
  box-shadow: var(--shadow-card);
}
.docs-index-card-title {
  font-family: var(--font-display);
  font-weight: 600;
  color: var(--ink-strong);
  font-size: 1.1rem;
}
.docs-index-card-blurb {
  color: var(--ink-muted);
  font-size: 0.95rem;
  line-height: 1.5;
}

/* Mobile */
@media (max-width: 960px) {
  .docs-shell { grid-template-columns: 1fr; }
  .docs-sidebar {
    position: fixed;
    inset: 53px 0 0 0;
    background: var(--bg-page);
    transform: translateX(-100%);
    transition: transform .2s ease;
    z-index: 35;
    max-height: none;
    border-right: 0;
    border-top: 1px solid var(--border);
    padding: 22px 18px 80px;
  }
  .docs-sidebar.open { transform: translateX(0); }
  .docs-sidebar-toggle { display: inline-flex; align-items: center; justify-content: center; }
  body.docs-site .layout { grid-template-columns: 1fr; gap: 0; }
  body.docs-site .toc { display: none; }
  .docs-main { padding: 28px 22px 60px; }
  .docs-pager { flex-direction: column; }
}
"""

/// Inline `<head>` script that runs synchronously *before* the body paints.
/// Reads the saved theme from localStorage and writes it onto
/// `documentElement` so the first paint uses the right palette. Without
/// this, every navigation between docs pages causes a Flash of Wrong Theme:
/// the browser would briefly paint with the server-default `data-theme=auto`
/// and then re-paint after the main inline script (loaded at the bottom of
/// the body) reads localStorage and applies the user's preference.
///
/// The script intentionally has no dependencies and never throws — `try/catch`
/// guards the localStorage access for private-mode browsers.
let themeBootScript: String = #"""
(function () {
  try {
    var saved = localStorage.getItem('showless-theme');
    if (saved === 'light' || saved === 'dark' || saved === 'auto') {
      document.documentElement.setAttribute('data-theme', saved);
    }
  } catch (e) {}
})();
"""#

/// Tiny inline script that wires up the mobile sidebar toggle and removes
/// the `no-transition` guard class that suppresses transitions during the
/// initial paint. Everything else (theme, scroll progress, copy buttons,
/// hljs, mermaid) is handled by the shared codewalk inline script.
let docsSidebarScript: String = #"""
(function () {
  'use strict';

  // Drop the no-transition guard on the next animation frame, after styles
  // and content have settled. This prevents the initial paint from running
  // transitions/animations that fire when the browser first computes the
  // active selectors (hover residue, theme transitions, link borders, …).
  function dropNoTransition() {
    document.body.classList.remove('no-transition');
  }
  if (document.readyState === 'loading') {
    document.addEventListener('DOMContentLoaded', function () {
      requestAnimationFrame(function () { requestAnimationFrame(dropNoTransition); });
    });
  } else {
    requestAnimationFrame(function () { requestAnimationFrame(dropNoTransition); });
  }

  var toggle = document.querySelector('.docs-sidebar-toggle');
  var sidebar = document.querySelector('.docs-sidebar');
  if (!toggle || !sidebar) return;
  toggle.addEventListener('click', function () {
    var open = sidebar.classList.toggle('open');
    toggle.setAttribute('aria-expanded', open ? 'true' : 'false');
  });
  // Close on link click on mobile.
  sidebar.querySelectorAll('a').forEach(function (a) {
    a.addEventListener('click', function () {
      if (window.matchMedia && window.matchMedia('(max-width: 960px)').matches) {
        sidebar.classList.remove('open');
        toggle.setAttribute('aria-expanded', 'false');
      }
    });
  });
})();
"""#
