# Showless

Showless is a Swift 6.2 CLI for creating executable demo documents that show and prove an agent's work.

It is intentionally a static tool, not an AI. Showless gives agents and developers reliable primitives for building markdown documents that mix commentary, executable code blocks, captured output, image references, and source excerpts that can be verified later.

The agent supplies the judgment and narrative. Showless supplies the durable transcript, source anchors, command output, and verification.

## Requirements

- macOS 13 or newer
- Swift 6.2 or newer

## Build And Run

```bash
swift build
```

Run without installing:

```bash
swift run showless --help
```

Install a release build somewhere on your `PATH`:

```bash
swift build -c release
cp .build/release/showless /usr/local/bin/showless
```

## Commands

Document file arguments do not require a `.md` extension — it is appended automatically.

```bash
showless init demo "Setting Up A Project"
showless note demo "First, inspect the toolchain."
showless exec demo bash "swift --version"
showless image demo screenshot.png
showless diagram demo mermaid "graph LR; CLI-->Service; Service-->Store"
showless pop demo
showless verify demo
showless extract demo
```

### Diagrams

`showless diagram` appends a fenced diagram source block. It writes a plain
` ```mermaid `, ` ```plantuml `, ` ```dot `, ` ```graphviz `, or ` ```d2 ` fence
so GitHub and most markdown viewers render the diagram natively. The block is
skipped by `showless verify` because diagram source is not executed.

```bash
showless diagram walkthrough mermaid <<'MMD'
graph TD
  CLI[showless CLI] --> Service
  Service --> Store[DocumentStore]
  Service --> Runner[ProcessRunner]
  Store --> Disk[(Markdown on disk)]
MMD
```

Use diagrams sparingly — usually one architecture diagram at the start of a
walkthrough plus a sequence or data-flow diagram for a critical path.

Commands also accept stdin when the text or code argument is omitted:

```bash
echo "A longer note" | showless note demo
cat script.sh | showless exec demo bash
```

`exec` records output even when the child command exits non-zero, prints the output to stdout, and exits with the same status. `verify` re-runs executable code blocks, skips image blocks, and exits non-zero if recorded output changed.

## Using Showless With An Agent

The best walkthroughs and demos come from an agent reading the codebase and using Showless as its notebook:

```text
Use Showless to create a linear, human-readable walkthrough of this codebase.
Read the important files first. Use `showless note` for explanations and
`showless exec` for evidence commands. Explain the architecture in the order a
new engineer should learn it. Do not rely only on automatic scaffold generation.
```

That workflow produces better documents than any static scanner can, because the agent can decide what matters, connect files into a story, and explain trade-offs.

## Static Codewalk Scaffold

Generate a static scaffold for an existing repository:

```bash
showless codewalk /path/to/repo
```

By default, Showless creates a `codewalks` folder in the directory where the executable is run and writes the document there as `<repo-name>-codewalk.md`. For example, running the command above from `/tmp/session` writes `/tmp/session/codewalks/repo-codewalk.md`.

Use `--output` when you want an explicit custom path:

```bash
showless codewalk /path/to/repo --output codewalk.md
```

The scaffold engine scans common manifests, entry points, tests, CI files, languages, and TODO markers. It adds source excerpt blocks with content hashes:

````markdown
<!-- showless-source: {"endLine":20,"hash":"fnv1a64:...","language":"swift","path":"Sources/App/main.swift","startLine":1} -->
```swift {source}
...
```
````

Verify scaffold excerpts later:

```bash
showless --source-root /path/to/repo verify codewalks/repo-codewalk
```

Write a refreshed copy without changing the original:

```bash
showless --source-root /path/to/repo verify walkthrough --output refreshed.md
```

## Docs Mode

Showless can also render a folder of plain markdown files into a beautiful multi-page documentation site that shares the codewalk visual language.

The intended workflow:

1. Hand an agent the project's `README.md` and a folder of "syntax" markdown files (your existing low-level reference) as conversation context.
2. Point the agent at [`generate-docs-prompt.md`](generate-docs-prompt.md). It will author a `docs/` folder with overview, getting-started, concepts, how-to, FAQ, and a verbatim `docs/reference/` copy of your syntax files.
3. Render the site:

```bash
showless docs-html docs/ --title "MyProject Documentation"
```

By default this writes to `docs/_site/` — one HTML page per markdown file, plus a synthetic `index.html` landing page if you didn't author one. Subfolders become sidebar groups; `reference/` is forced last.

Optional YAML frontmatter on each markdown file controls its sidebar entry:

```yaml
---
title: Getting Started
nav_label: Getting Started
nav_order: 2
subtitle: Install in 60 seconds
---
```

The full options:

```bash
showless docs-html docs/ \
  --output dist/site \
  --title "MyProject Documentation" \
  --subtitle "Build, ship, verify." \
  --force
```

## Enhancements

- `--timeout <seconds>` limits command execution and records timeout output with exit code `124`.
- `--json` emits structured JSON for `verify` and `codewalk`.
- Unified diffs make changed command output and stale source excerpts easier to inspect.
- `.showless.json` or `.showless.yml` can define defaults:

```yaml
workdir: /path/to/project
timeout: 10
include: [Sources, Tests]
exclude: [.build]
walkthrough_depth: 3
```

## Development

Dependencies are pinned in `Package.resolved` so CLI builds are reproducible.

Run the test suite:

```bash
swift test
```

The GitHub Actions workflow in `.github/workflows/test.yml` runs `swift build`
and `swift test` on pushes and pull requests.

## License

Showless is available under the MIT License. See [LICENSE](LICENSE).
