import Foundation
import Testing
@testable import ShowlessCore

@Suite struct DocsSiteRendererTests {
    @Test func emptyFolderThrowsHelpfulError() throws {
        let dir = try temporaryDirectory()
        do {
            _ = try DocsSiteRenderer.render(folder: dir.path, outputFolder: dir.appendingPathComponent("_site").path)
            Issue.record("expected error for empty folder")
        } catch let error as ShowlessError {
            #expect(String(describing: error).contains("no .md files"))
        }
    }

    @Test func rendersOneHTMLPagePerMarkdownFile() throws {
        let dir = try temporaryDirectory()
        try write("# Welcome\n\nHi.", at: dir.appendingPathComponent("index.md"))
        try write("# Overview\n\nWhat this is.", at: dir.appendingPathComponent("overview.md"))
        let report = try DocsSiteRenderer.render(folder: dir.path, outputFolder: dir.appendingPathComponent("_site").path)

        let fm = FileManager.default
        #expect(fm.fileExists(atPath: dir.appendingPathComponent("_site/index.html").path))
        #expect(fm.fileExists(atPath: dir.appendingPathComponent("_site/overview.html").path))
        #expect(report.pages.count == 2)
    }

    @Test func navOrderingPutsIndexFirstAndReferenceLast() throws {
        let dir = try temporaryDirectory()
        try write("# A", at: dir.appendingPathComponent("alpha.md"))
        try write("# Home", at: dir.appendingPathComponent("index.md"))
        try fmCreateDir(dir.appendingPathComponent("reference"))
        try write("# Ref X", at: dir.appendingPathComponent("reference/x.md"))
        try fmCreateDir(dir.appendingPathComponent("how-to"))
        try write("# Task", at: dir.appendingPathComponent("how-to/task.md"))

        let outDir = dir.appendingPathComponent("_site")
        _ = try DocsSiteRenderer.render(folder: dir.path, outputFolder: outDir.path)

        // Sidebar order on the index page should be: Home, Alpha, How To group, Reference group.
        let html = try String(contentsOf: outDir.appendingPathComponent("index.html"), encoding: .utf8)
        guard let homeIdx = html.range(of: ">Home<")?.lowerBound,
              let alphaIdx = html.range(of: ">A<", range: html.range(of: "docs-nav-list")!.lowerBound..<html.endIndex)?.lowerBound,
              let howIdx = html.range(of: ">Task<")?.lowerBound,
              let refIdx = html.range(of: ">Ref X<")?.lowerBound else {
            Issue.record("expected all nav labels in rendered HTML")
            return
        }
        #expect(homeIdx < alphaIdx)
        #expect(alphaIdx < howIdx)
        #expect(howIdx < refIdx)
    }

    @Test func frontmatterControlsTitleLabelOrderAndSubtitle() throws {
        let dir = try temporaryDirectory()
        try write("# Whatever\n", at: dir.appendingPathComponent("index.md"))
        try write(
            """
            ---
            title: Getting Started Fast
            nav_label: Start
            nav_order: 1
            subtitle: Install in 60 seconds
            ---

            # Anything

            Body.
            """,
            at: dir.appendingPathComponent("zsetup.md")
        )

        let outDir = dir.appendingPathComponent("_site")
        _ = try DocsSiteRenderer.render(folder: dir.path, outputFolder: outDir.path)

        let html = try String(contentsOf: outDir.appendingPathComponent("zsetup.html"), encoding: .utf8)
        #expect(html.contains("<h1 class=\"docs-page-title\">Getting Started Fast</h1>"))
        #expect(html.contains("Install in 60 seconds"))
        #expect(html.contains(">Start<"))
        // nav_order: 1 puts it before alphabetical neighbours; on the index
        // page sidebar, "Start" should appear before any other top-level
        // entries with higher order.
        let idx = try String(contentsOf: outDir.appendingPathComponent("index.html"), encoding: .utf8)
        if let startRange = idx.range(of: ">Start<"),
           let homeRange = idx.range(of: ">Home<") {
            #expect(homeRange.lowerBound < startRange.lowerBound)
        }
    }

    @Test func internalMarkdownLinksAreRewrittenWithFragmentPreserved() throws {
        let dir = try temporaryDirectory()
        try write(
            """
            # Home

            See the [Overview](overview.md), [step 1](getting-started.md#step-1),
            and the [Apple docs](https://docs.swift.org).
            """,
            at: dir.appendingPathComponent("index.md")
        )
        try write("# Overview", at: dir.appendingPathComponent("overview.md"))
        try write("# Getting Started\n\n## Step 1\n\nDo this.", at: dir.appendingPathComponent("getting-started.md"))

        let outDir = dir.appendingPathComponent("_site")
        _ = try DocsSiteRenderer.render(folder: dir.path, outputFolder: outDir.path)
        let html = try String(contentsOf: outDir.appendingPathComponent("index.html"), encoding: .utf8)

        #expect(html.contains("<a href=\"overview.html\">Overview</a>"))
        #expect(html.contains("<a href=\"getting-started.html#step-1\">step 1</a>"))
        #expect(html.contains("<a href=\"https://docs.swift.org\" target=\"_blank\""))
    }

    @Test func navLabelStripsMarkdownEmphasisFromDefault() throws {
        let dir = try temporaryDirectory()
        try write("# Home", at: dir.appendingPathComponent("index.md"))
        try fmCreateDir(dir.appendingPathComponent("reference"))
        try write("# `init` syntax\n\nFoo.", at: dir.appendingPathComponent("reference/init.md"))

        let outDir = dir.appendingPathComponent("_site")
        _ = try DocsSiteRenderer.render(folder: dir.path, outputFolder: outDir.path)
        let html = try String(contentsOf: outDir.appendingPathComponent("index.html"), encoding: .utf8)
        // Sidebar label should not contain backticks (markdown stripped).
        #expect(html.contains(">init syntax<"))
        #expect(!html.contains(">`init` syntax<"))
    }

    @Test func syntheticIndexIsBuiltWhenIndexMarkdownIsMissing() throws {
        let dir = try temporaryDirectory()
        try write("# Overview", at: dir.appendingPathComponent("overview.md"))
        try write("# Setup", at: dir.appendingPathComponent("setup.md"))

        let outDir = dir.appendingPathComponent("_site")
        _ = try DocsSiteRenderer.render(folder: dir.path, outputFolder: outDir.path)
        let html = try String(contentsOf: outDir.appendingPathComponent("index.html"), encoding: .utf8)
        #expect(html.contains("docs-index"))
        #expect(html.contains("docs-index-card"))
        #expect(html.contains("Overview"))
        #expect(html.contains("Setup"))
    }

    @Test func assetsAreCopiedAlongsideHTML() throws {
        let dir = try temporaryDirectory()
        try write("# Home\n\n![chart](images/chart.png)\n", at: dir.appendingPathComponent("index.md"))
        try fmCreateDir(dir.appendingPathComponent("images"))
        try Data("not really a png".utf8).write(to: dir.appendingPathComponent("images/chart.png"))

        let outDir = dir.appendingPathComponent("_site")
        let report = try DocsSiteRenderer.render(folder: dir.path, outputFolder: outDir.path)
        let copied = outDir.appendingPathComponent("images/chart.png")
        #expect(FileManager.default.fileExists(atPath: copied.path))
        #expect(report.assets.contains(copied.path))

        let html = try String(contentsOf: outDir.appendingPathComponent("index.html"), encoding: .utf8)
        #expect(html.contains("<img src=\"images/chart.png\""))
        // A block-level image at line start renders as a figure with class
        // `image-block`; the inline variant is exercised separately.
        #expect(html.contains("image-block"))
    }

    @Test func inlineImageInsideParagraphRendersAsInlineImageClass() throws {
        let dir = try temporaryDirectory()
        try write(
            "# Home\n\nLook at this chart ![chart](chart.png) right here in the prose.\n",
            at: dir.appendingPathComponent("index.md")
        )
        try Data("fake".utf8).write(to: dir.appendingPathComponent("chart.png"))

        let outDir = dir.appendingPathComponent("_site")
        _ = try DocsSiteRenderer.render(folder: dir.path, outputFolder: outDir.path)
        let html = try String(contentsOf: outDir.appendingPathComponent("index.html"), encoding: .utf8)
        #expect(html.contains("class=\"inline-image\""))
        #expect(html.contains("src=\"chart.png\""))
    }

    @Test func deeplyNestedPageResolvesRelativeRootCorrectly() throws {
        let dir = try temporaryDirectory()
        try write("# Home", at: dir.appendingPathComponent("index.md"))
        try fmCreateDir(dir.appendingPathComponent("reference/api/v1"))
        try write("# Users API", at: dir.appendingPathComponent("reference/api/v1/users.md"))

        let outDir = dir.appendingPathComponent("_site")
        _ = try DocsSiteRenderer.render(folder: dir.path, outputFolder: outDir.path)

        let nested = try String(contentsOf: outDir.appendingPathComponent("reference/api/v1/users.html"), encoding: .utf8)
        // Three "../" should be present in nav links back to the root.
        #expect(nested.contains("href=\"../../../index.html\""))
        #expect(nested.contains("href=\"../../../reference/api/v1/users.html\""))
    }

    @Test func siteConfigFrontmatterSuppliesTitleAndSubtitle() throws {
        let dir = try temporaryDirectory()
        try write("# Home", at: dir.appendingPathComponent("index.md"))
        try write(
            """
            ---
            title: ProjectX Documentation
            subtitle: A friendly tagline for ProjectX
            ---
            """,
            at: dir.appendingPathComponent("site.config.md")
        )

        let outDir = dir.appendingPathComponent("_site")
        let report = try DocsSiteRenderer.render(folder: dir.path, outputFolder: outDir.path)

        let html = try String(contentsOf: outDir.appendingPathComponent("index.html"), encoding: .utf8)
        #expect(html.contains(">ProjectX Documentation<"))
        #expect(html.contains(">A friendly tagline for ProjectX<"))

        let pages = report.pages.map { ($0 as NSString).lastPathComponent }
        #expect(!pages.contains("site.config.html"), "site.config.md must not render as a page")
        let fm = FileManager.default
        #expect(!fm.fileExists(atPath: outDir.appendingPathComponent("site.config.html").path))
    }

    @Test func siteConfigHomeURLRedirectsBrandLink() throws {
        let dir = try temporaryDirectory()
        try write("# Home", at: dir.appendingPathComponent("index.md"))
        try fmCreateDir(dir.appendingPathComponent("how-to"))
        try write("# Task", at: dir.appendingPathComponent("how-to/task.md"))
        try write(
            """
            ---
            title: ProjectX Documentation
            home_url: https://projectx.example.com
            ---
            """,
            at: dir.appendingPathComponent("site.config.md")
        )

        let outDir = dir.appendingPathComponent("_site")
        _ = try DocsSiteRenderer.render(folder: dir.path, outputFolder: outDir.path)

        // Brand link on root index points at the configured URL with new-tab attrs.
        let indexHTML = try String(contentsOf: outDir.appendingPathComponent("index.html"), encoding: .utf8)
        #expect(indexHTML.contains("class=\"docs-brand\" target=\"_blank\" rel=\"noopener noreferrer\""))
        #expect(indexHTML.contains("href=\"https://projectx.example.com\""))

        // Nested pages still resolve to the same absolute URL (no `../` prepended).
        let nestedHTML = try String(contentsOf: outDir.appendingPathComponent("how-to/task.html"), encoding: .utf8)
        #expect(nestedHTML.contains("href=\"https://projectx.example.com\""))
    }

    @Test func docsSiteDisablesSectionRevealAnimation() throws {
        let dir = try temporaryDirectory()
        try write("# Home\n\n## Section A\n\nBody.", at: dir.appendingPathComponent("index.md"))

        let outDir = dir.appendingPathComponent("_site")
        _ = try DocsSiteRenderer.render(folder: dir.path, outputFolder: outDir.path)

        let html = try String(contentsOf: outDir.appendingPathComponent("index.html"), encoding: .utf8)
        // The docs override pins paragraphs/headings at opacity 1, transform none.
        #expect(html.contains("body.docs-site .content > p,"))
        #expect(html.contains("transform: none;"))
    }

    @Test func cliOptionsOverrideSiteConfig() throws {
        let dir = try temporaryDirectory()
        try write("# Home", at: dir.appendingPathComponent("index.md"))
        try write(
            """
            ---
            title: From Config
            subtitle: Config subtitle
            ---
            """,
            at: dir.appendingPathComponent("site.config.md")
        )

        let outDir = dir.appendingPathComponent("_site")
        let options = DocsSiteRenderer.Options(siteTitle: "From CLI", subtitle: "CLI subtitle")
        _ = try DocsSiteRenderer.render(folder: dir.path, outputFolder: outDir.path, options: options)

        let html = try String(contentsOf: outDir.appendingPathComponent("index.html"), encoding: .utf8)
        #expect(html.contains(">From CLI<"))
        #expect(html.contains(">CLI subtitle<"))
        #expect(!html.contains(">From Config<"))
    }

    @Test func renderingASecondTimeOverwritesAssetsCleanly() throws {
        let dir = try temporaryDirectory()
        try write("# Home\n\n![x](x.png)", at: dir.appendingPathComponent("index.md"))
        try Data("v1".utf8).write(to: dir.appendingPathComponent("x.png"))

        let outDir = dir.appendingPathComponent("_site")
        _ = try DocsSiteRenderer.render(folder: dir.path, outputFolder: outDir.path)
        let firstBytes = try Data(contentsOf: outDir.appendingPathComponent("x.png"))
        #expect(String(decoding: firstBytes, as: UTF8.self) == "v1")

        try Data("v2".utf8).write(to: dir.appendingPathComponent("x.png"))
        _ = try DocsSiteRenderer.render(folder: dir.path, outputFolder: outDir.path)
        let secondBytes = try Data(contentsOf: outDir.appendingPathComponent("x.png"))
        #expect(String(decoding: secondBytes, as: UTF8.self) == "v2")
    }

    // MARK: - helpers

    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("showless-docs-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func fmCreateDir(_ url: URL) throws {
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    private func write(_ contents: String, at url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try contents.write(to: url, atomically: true, encoding: .utf8)
    }
}
