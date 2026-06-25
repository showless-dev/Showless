Create a high-quality open-source documentation site for this project.

You will be given two inputs in chat context:
1. The project's `README.md` — the source of truth for what the project is and how it is positioned today.
2. A folder of "syntax" markdown files — the existing low-level reference. These describe every primitive, flag, option, type, or grammar rule. Treat them as canonical reference. Do not rewrite or paraphrase them.

Your job is to author a fresh `docs/` folder of markdown files that turns those raw inputs into a complete, friendly, well-paced documentation site. A new user should be able to land on the home page, read top-to-bottom, and reach productive use without ever needing the rest of the internet.

## Output file layout

Create or replace a `docs/` folder at the repository root, structured roughly like this (adjust to the project; you do not have to include every file, but include the ones that genuinely apply):

```
docs/
  site.config.md              # Site-level metadata (title, subtitle, …)
  index.md                    # Landing page
  overview.md                 # What the project is and why it exists
  getting-started.md          # Install + first success
  concepts.md                 # Mental model: core ideas, vocabulary, design
  how-to/
    <task>.md                 # 2–5 task-oriented pages, one per common job
  tutorials/
    <walkthrough>.md          # Optional. Long-form learn-by-doing guides
  reference/
    <syntax-file>.md          # Every file from the supplied syntax folder, verbatim
  faq.md
  contributing.md
```

Rules for the layout:
- Every page is plain markdown. You may use standard fenced code blocks; `\`\`\`mermaid` blocks render as diagrams.
- The `reference/` folder must contain every file from the supplied syntax folder, copied verbatim with the original filenames. Do not paraphrase or shorten — the syntax docs are the source of truth.
- Do not invent a page that has nothing to say. Better to skip `tutorials/` than to ship a stub.
- One concept per page. If a page is about "Installation", it should not also be about "Configuration".

## `site.config.md` — site-level metadata

You must always create `docs/site.config.md`. This file is **not** a page — the renderer treats it as metadata and never renders it. It holds the values the renderer uses to style every page's chrome: the topbar brand text, the `<title>` of every HTML page, the small caption under the brand.

Author it with your own best inference from the README and reference docs. Do not ask the user. The user can edit this file later to tweak the rendered site without ever re-running you.

Required frontmatter:

```yaml
---
title: <Project Name> Documentation
subtitle: <one-line positioning tagline derived from the README>
home_url: <optional URL the brand link should take readers to>
---
```

Rules:
- `title` is the **site** title. It appears as the brand text in the topbar on every page and as the suffix of every `<title>` tag. Use the project's actual name plus the word "Documentation" — e.g. `Stripe Documentation`, not `Stripe Docs` or `Stripe API`.
- `subtitle` is the small caption that renders under the brand. Keep it to ≤ 60 characters and ≤ one short clause. It should restate the project's positioning, not its features. Pull the language from the README's tagline if there is one.
- `home_url` is **optional**. When set, clicking the brand text in the topbar navigates to this URL instead of the docs root. Use it to point back to the project's marketing site or repository (`https://github.com/<org>/<repo>`). When the URL is external (starts with `http`, `https`, `mailto:`, …) the link opens in a new tab. Leave the key out (or set it to an empty string) to keep the default behaviour of linking back to `index.html`.
- The body of `site.config.md` after the frontmatter may be empty, or hold a few lines of comments explaining what each key does. The renderer ignores it.
- Do not invent additional keys; only `title`, `subtitle`, and `home_url` are read today.

Resolution order at render time, most explicit wins: CLI flag (`--title`, `--subtitle`) > `site.config.md` frontmatter > a built-in fallback. So the config file is the default the user lives with; the CLI flag is the override for one-off renders.

## Front matter

Each authored markdown file may start with an optional YAML frontmatter block to control how it appears in the sidebar:

```yaml
---
title: Getting Started
nav_label: Getting Started
nav_order: 2
subtitle: Install and run your first command in 60 seconds
---
```

- `title` overrides the H1 used in the page header and `<title>` tag.
- `nav_label` is the short label shown in the sidebar.
- `nav_order` controls sort order within a group (smaller first; default 100).
- `subtitle` is a one-line tagline rendered under the page title.
- `nav_group` overrides the parent folder name when grouping in the sidebar.

Front matter is optional but strongly recommended on every authored page so the navigation reads in the order you intend.

## Reference standard

Treat the documentation for [SQLite](https://www.sqlite.org/docs.html), [Stripe](https://stripe.com/docs), and [Tailwind CSS](https://tailwindcss.com/docs) as the quality bar. The docs you produce should have their rhythm: short paragraphs, frequent runnable examples, a clear next-page-to-read at every turn.

## Before writing

1. Read the README end to end. Identify the user-facing purpose of the project in one paragraph. Note its core nouns and verbs — they will become the vocabulary of the docs.
2. Read every supplied syntax file end to end. List the concepts they cover and note any feature the README mentions that the syntax docs assume.
3. List the realistic user journeys: installation, first success, common task A, common task B, integration, debugging. Each journey usually maps to one or two pages.
4. Decide your page list before writing. A typical project: `index.md`, `overview.md`, `getting-started.md`, `concepts.md`, 2–4 `how-to/*.md` pages, the verbatim `reference/`, `faq.md`. Anything else is optional.

## Per-page structure

Every page has:
- A short opening paragraph that names the problem the page solves and who it is for.
- A clear H1 (= the page title). The H1 may be the first line of the file, or set via the `title:` front matter.
- 2–6 H2 sections, each with 1–4 H3 subsections when needed.
- At least one runnable code block or concrete example on any "Getting Started", "How-To", or "Tutorial" page. No abstract-only pages outside `concepts.md`.
- A closing "What to read next" line linking to the natural next page.

### `index.md`

The landing page. Three things, in order:
1. A one-sentence pitch — what the project is.
2. A 2–4 sentence "why does it exist" paragraph.
3. A short list of links to the most important next pages: `Getting Started`, `Overview`, `Concepts`, `Reference`. Do not duplicate the full nav.

Do not include a feature list, screenshots, or marketing copy. Keep it under one screen of text.

### `overview.md`

Answer: "What is this thing?" in a way the README does not.
- Restate the project's purpose in your own words.
- Name 3–5 design decisions that shape it. Each gets a short paragraph.
- One small architecture diagram (mermaid) showing the major components. At most 8 nodes. Use names that appear in the codebase or the reference docs — do not invent terminology.
- Close with a paragraph that names every top-level docs section and what the reader will get from each.

### `getting-started.md`

The fastest path from "haven't installed it yet" to "first real success".
- Installation. One block per platform, only the platforms the project officially supports.
- The smallest possible "hello world" or equivalent. The reader runs one command, sees one result.
- One worked example that uses the project's main verb (the thing it is best known for). Show the input, show the output, explain the output in 2–3 sentences.
- End with two links: "Now learn how it works" → `concepts.md`, and "Or jump to a specific task" → `how-to/`.

### `concepts.md`

The mental model. Not a tour of features — a tour of ideas.
- Define every term the rest of the docs will use, in dependency order. Each term gets a paragraph and, where helpful, a tiny snippet.
- One sequence or data-flow diagram for the most important runtime path. Place it under a sensible H2.
- Explain at least one design tradeoff explicitly: "X was chosen over Y because Z."

### `how-to/*.md`

Task-oriented. Each file answers exactly one "How do I X?" question. Pick the 2–5 tasks a real user will hit in their first week. Each page:
- Names the task in the H1.
- Lists the prerequisites in a single short paragraph or bullet list.
- Walks through the task as numbered steps. Each step is one paragraph, plus one snippet when relevant.
- Ends with "Common variations" or "Pitfalls" — at most 3 bullets. No more.

Do not write speculative how-tos. If you cannot give a concrete command sequence, drop the page.

### `reference/*.md`

Every file from the supplied syntax folder. Copied verbatim, preserving filename and content. Do not edit, summarise, reorder, or reformat. These are the source of truth.

If a syntax file has no front matter, the renderer uses the H1 as the page title and the filename as the sidebar label, which is what we want.

### `faq.md`

Real questions, in question-and-answer form. 5–12 entries. Each answer is 2–4 sentences. Order by frequency, not alphabetically. Do not invent questions the reader will not ask.

### `contributing.md`

How to build, test, and submit a change. Keep it short and accurate. If the README already has this content, summarise and link rather than duplicate.

## Visual architecture

Use mermaid diagrams sparingly. The renderer treats `\`\`\`mermaid` fenced blocks as diagrams.

When to add a diagram:
- **Once on `overview.md` or `index.md`**: a single component / dependency overview showing the major modules and which way data flows.
- **Once on `concepts.md`**: a sequence diagram for the most important user-triggered runtime path.
- **Rarely on `how-to/*.md`**: a state diagram for a small, important state machine.
- **Never**: a diagram that just lists files, or a diagram that duplicates what the next paragraph says.

Hard limits:
- At most 3 diagrams across the entire site.
- Each diagram must have at most ~12 nodes.
- Each diagram must be followed by 2–4 sentences naming the most important nodes/edges and the user-visible behaviour they enable.
- Use ASCII names that appear in the code or the reference docs. The diagram must be greppable.

Mermaid edge labels that contain `/`, `\`, or parentheses must be quoted: `A -- "/usr/bin/x" --> B`. Mermaid is strict.

## Prose rules

- Confident, friendly senior-engineer voice. Short sentences. Active verbs.
- "The trick is", "notice", "the important detail" — prefer over "we can see that", "this method does the following".
- Explain why, not just what. Mention design tradeoffs, invariants, and consequences.
- After every snippet, write at least 2 sentences of explanation. No empty snippets.
- Close the loop on every page: "this code does X, which means the user experiences Y."
- Never lecture, never restate the obvious, never end with "and that's it!".

## Snippet rules

- Each snippet illustrates exactly one concept.
- 5–25 lines for code snippets. Hard upper limit: 30 lines.
- Hard upper limit for any output block: 30 lines. If the natural snippet is longer, split it across multiple H3s or pages.
- Use real commands that the reader can type. Avoid placeholders unless absolutely necessary.
- For shell, prefer `\`\`\`bash`. For JSON, YAML, etc., use the matching fence.
- Avoid output that varies between runs: timestamps, random IDs, absolute paths in temp dirs, progress percentages.

## Linking

- Use relative markdown links between pages: `[Getting Started](getting-started.md)` or `[Configuration](how-to/configure.md)`. The renderer rewrites the trailing `.md` to `.html` and keeps any `#fragment` intact, so `[Step 1](getting-started.md#step-1)` lands on the right section.
- External links (`http://`, `https://`, `mailto:`, …) are passed through unchanged and open in a new tab.
- Always end every page (except `index.md`) with a "What to read next" line linking forward.

## Quality bar

- The docs should feel like a senior engineer wrote them for a friend, not like generated boilerplate.
- A new user should reach first success on `getting-started.md` in under 5 minutes of reading + typing.
- Each `how-to/*.md` page should be a complete answer to one question. The reader closes the tab and the task is done.
- The `reference/` section must be byte-exact to the supplied syntax folder. Trust those docs; do not improvise.

## Self-check before declaring done

Run these checks. If any fail, fix the docs before moving on.
- `docs/site.config.md` exists and has both `title:` and `subtitle:` in its frontmatter.
- Every authored page has an H1 (either at top of file or via `title:` frontmatter).
- Every authored page (except `index.md`) ends with a "What to read next" link.
- `reference/` contains one file per file in the supplied syntax folder, with identical content.
- No more than 3 mermaid diagrams across the whole site.
- Every diagram has at most 12 nodes and is followed by 2–4 sentences of explanation.
- Largest output block is 30 lines or fewer.
- No `--help` dumps, no whole-file dumps, no marketing copy.
- Sidebar order, when you read it top to bottom, matches the order a new user should learn the project.

## After writing

- Run `showless docs-html docs/ --force` to render the site. Title and subtitle come from `site.config.md`, so you do not need to pass them on the command line. Pass `--title` / `--subtitle` only when you want a one-off override.
- Open `docs/_site/index.html` in a browser to spot-check the visual result.
- Re-render whenever you change a page.
- Report the final docs folder path and rendered output directory.
