Create a high-quality linear Showless walkthrough for this codebase.

Use Showless as an evidence recorder, not as an automatic walkthrough generator. Quality comes from your reading, your judgment, and your prose. Showless only proves the snippets and outputs are real.

## Output file
- Create or replace `codewalk.md` at the repository root.
- Use `showless init codewalk "<Project Name>: A Code Walkthrough"`.
- Use `showless note` for authored explanation.
- Use `showless exec` for evidence commands and code snippets.
- Use `showless diagram` for visual architecture (mermaid by default).
- Use stdin (`<<'NOTE' ... NOTE`) for multiline notes. Never pass escaped `\n` strings.
- File arguments do not require a `.md` extension — it is appended automatically.

## Reference standard
Treat https://raw.githubusercontent.com/simonw/present/refs/heads/main/walkthrough.md as the quality bar. The walkthrough you produce should match its rhythm, voice, and structure.

## Before writing
1. Read every important source file end to end. Do not skim.
2. Identify the user-facing purpose of the project in one paragraph.
3. List every source file and order them the way a new engineer should learn them. Usually: data model first, entry point next, UI/IO outward, side effects last.
4. For each file, list the 3-5 specific concepts you want to teach. Each concept will become one H3 subsection.

## Document structure
- Title (`# Project Name: A Code Walkthrough`).
- Opening paragraph: what the project is and why it exists. Use plain language. Mention the size in lines and the number of files. State 1-2 design decisions that define the codebase.
- A short bullet list of key features.
- A **single architecture diagram** (mermaid) directly under the opening paragraph. See "Visual architecture" below.
- A "Project Structure" or "Repository shape" section with `find` and `wc -l` evidence so the reader gets a feel for scale.
- One H2 chapter per important source file. Title each chapter with the conceptual role and the filename, like `## 1. The Data Model — Slide.swift`.
- Inside each chapter, use H3 subsections to break ideas into tight focused units.
- Optionally, **one extra diagram** for the most important runtime path (sequence or data flow). Place it inside the chapter that owns that path.
- Closing chapter that pulls everything together: a one-paragraph summary that names every file and how they fit.

## Visual architecture
Use diagrams to compress structural knowledge that prose cannot deliver efficiently. Diagrams are not decoration; they replace pages of "X talks to Y which calls Z" prose.

When to add a diagram:
- **Always**: a single component / dependency overview near the top, showing the major modules and which way data flows.
- **Sometimes**: a sequence diagram for the most important user-triggered runtime path.
- **Rarely**: a state diagram for a small, important state machine.
- **Never**: a diagram that just lists files, or a diagram that duplicates what the next paragraph says.

Hard limits:
- 1 mandatory architecture diagram.
- Up to 2 optional diagrams (sequence and/or state). Never more than 3 diagrams total.
- Each diagram must have at most ~12 nodes. If you need more, the diagram is wrong; split it or simplify.
- Each diagram must be followed by 2-4 sentences naming the most important nodes/edges and the user-visible behavior they enable.

How to add a diagram (mermaid is the default and renders natively on GitHub):

```bash
showless diagram codewalk mermaid <<'MMD'
graph LR
  CLI[showless CLI] --> Service[ShowlessService]
  Service --> Store[DocumentStore]
  Service --> Runner[ProcessRunner]
  Store -- read/write --> Disk[(Markdown file)]
  Runner -- /usr/bin/env lang -c code --> Child[(Child process)]
MMD
```

Recommended diagram types and templates:
- **Architecture (component)**: `graph LR` or `graph TD`. Boxes are modules, edges are calls or data flow. Group strongly related modules with `subgraph` blocks if it improves clarity.
- **Sequence (runtime path)**: `sequenceDiagram`. Use for "what happens when the user runs `showless exec`?" style explanations.
- **State (small state machines)**: `stateDiagram-v2`. Only when the project has a real state machine.

Style rules:
- Use the same names that appear in the code (file names, type names, function names). The diagram must be greppable against the source.
- Label edges with the actual function call or data being passed when it adds insight (e.g. `-- writeBlocks -->`).
- Prefer plain ASCII labels. Avoid emojis. No styling unless it carries meaning.
- Do not invent components that are not in the codebase.

Diagrams are *not* verified by `showless verify` — they are skipped automatically. So they will never break the build, but you also do not get drift detection. Keep them at a level of abstraction that ages well: module names and major flows, not method signatures or line numbers.

## H3 rule (critical)
Aim for 3-6 H3 subsections per chapter. Each H3 has:
1. A one-sentence framing of the concept.
2. One snippet (5-25 lines).
3. 2-5 sentences of explanation that connect the code to a user-visible behavior.

If a chapter has zero H3s, the walkthrough is broken. Add them.

## Snippet rules
- Each snippet illustrates exactly one concept.
- 5-25 lines for code snippets. Hard upper limit: 30 lines.
- Hard upper limit for any output block: 30 lines. If the natural snippet is longer, split it across multiple H3s.
- Never dump a whole file. Never dump full `--help` output. Never dump full test files.
- Use `sed -n 'A,Bp' path/to/file` with tight ranges.
- For commands that may print noisy or unstable output, filter or reduce. Examples:
  - `swift test >/dev/null 2>&1 && echo 'swift test passed'`
  - `swift build >/dev/null 2>&1 && echo 'swift build ok'`
  - `find Sources Tests -type f | sort`
  - `wc -l Sources/**/*.swift | sort -n`
  - `python3 - <<'PY' ... PY` for stable structural summaries
- Do not use commands that may not exist on the host (`rg`, `bat`, `jq`) unless you confirm them.
- Avoid output that varies between runs: timestamps, build timings, progress percentages, absolute temp paths, randomized IDs.

## Prose rules
- Write in a confident, friendly senior-engineer voice. Short sentences. Active verbs.
- Always close the loop: "this code does X, which means the user experiences Y."
- Prefer "notice" / "the trick is" / "the important detail" over "we can see that" / "this method does the following".
- Explain why, not just what. Mention design tradeoffs, invariants, and consequences.
- After every snippet, write at least 2 sentences of explanation. Empty snippets are not allowed.
- One vivid concrete observation per chapter. Lines, sizes, totals, "this file is the heaviest", "this is the smallest module", etc.
- Do not lecture. Do not summarize what was just shown. Move forward.

## Rhythm rule
The reader should never see two consecutive output blocks without prose between them. Each snippet is bracketed by intro prose and follow-up prose.

## What to leave out
- The full `showless --help` (or equivalent) output. Mention it. Do not dump it.
- Boilerplate file headers, imports, license blocks, and docstrings, unless they teach something.
- Repetitive snippets that show the same pattern as a previous one.
- Do not mention Showless itself unless the project is Showless.

## Suggested chapter order
1. What this project is and why it exists.
2. Repository shape (file list, line counts, key decision summary).
3. The core data model (1-2 files at most).
4. The application entry point.
5. Each major feature file, in the order a user encounters them.
6. External effects (network, filesystem, subprocess, image handling).
7. Verification or testing strategy.
8. Final mental model summary.

## Quality bar
- The finished walkthrough should feel like a senior engineer giving a friend a guided tour of the codebase.
- A new engineer should be able to make a small change after reading it once.
- Length target: roughly 800-1200 lines, with at least 20 H3 subsections.
- Voice: warm, direct, opinionated, never bureaucratic.
- Density: the reader should learn something new in every paragraph.

## Self-check before declaring done
Run these checks. If any fail, fix the walkthrough before moving on.
- Largest output block is 30 lines or fewer.
- At least 20 H3 subsections across the document.
- Every chapter has at least 2 H3s.
- Exactly one architecture diagram appears near the top, with at most 12 nodes.
- Total diagram count is between 1 and 3.
- Every diagram is followed by 2-4 sentences of explanation.
- No `--help` dumps, no whole-file dumps.
- Every snippet is followed by explanation prose.
- Each chapter mentions a user-visible behavior at least once.
- Closing section names every important file.

## After writing
- Run `showless verify codewalk`.
- If verification fails because output is unstable, replace that command with a stable one and verify again.
- Re-run verification until it passes.
- Report the final file path and verification result.
