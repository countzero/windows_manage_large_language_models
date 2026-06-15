---
name: pr-code-review
description: >
  Multi-pass PR code review. Use when reviewing pull request code changes for
  defects and design issues. Performs 3 review passes with escalating focus,
  deduplicates findings, and prints a severity-filtered report directly in the
  terminal with deep links to the relevant code on GitHub. This skill is
  read-only: it writes no files and never posts comments, reviews, or any data
  to GitHub; it is advisory only.
---

## Multi-Pass PR Code Review

This skill performs 3 iterative review passes over a pull request diff with
escalating focus: general defects, cross-file interactions, then absent
behavior. After all passes, a final summary deduplicates, validates, assigns
severity, and filters to Critical/High/Medium. The output includes clickable
deep links to the relevant code on GitHub so the developer or reviewer can
easily navigate to each finding.

### PR and Diff Resolution

1. Run `gh pr view --json number,baseRefName,state,isDraft`. This single call
   determines whether a PR exists and, if so, its state.
2. **If a PR exists:**
   - If the PR is closed or a draft, inform the user and stop.
   - Otherwise, use the PR's `baseRefName` as the base for the diff.
3. **If no PR exists** (the command fails):
   - Use `develop` as the default base branch (the integration branch; feature
     work is PR'd into it).
   - Inform the user: "No PR found. Diffing against `develop`."
4. Get the diff via `git diff <base>...HEAD`.
5. Resolve the full HEAD SHA via `git rev-parse HEAD`.
6. Resolve the repository owner/name via `gh repo view --json owner,name`
   (fall back to parsing `git remote get-url origin` if `gh` is unavailable).
   Store the owner, repo name, full SHA, and PR number (or `null` when no
   PR exists) for constructing deep links in the output.

### Context Gathering

Before starting the review passes, gather context to understand the intent
behind the changes:

1. **Branch and commits:** Read the current branch name via
   `git branch --show-current` and the commit subjects in range via
   `git log --oneline <base>..HEAD` to understand the stated intent.
2. **Full file reads:** Do NOT read full files upfront. Instead, during each
   pass, if a diff hunk lacks sufficient surrounding context to assess a
   potential defect, read the full file at that point using the Read tool.

### Design Review (before passes)

After gathering context and the diff, but before starting the defect passes,
evaluate the overall design of the change:

1. **Scope:** Does the PR implement more or less than its stated intent (branch
   name, commit subjects)? Flag scope creep or missing pieces.
2. **Placement:** Do the changes live in the correct place? This repo is a
   PowerShell quantization toolkit: download/quantize orchestration belongs in
   the two root scripts (`download_model_sources.ps1`,
   `quantize_weights_for_llama.cpp.ps1`); reusable Python helpers belong in
   `tools/`; configuration belongs in `.env`, not hard-coded in scripts. The
   working directories `source/`, `gguf/`, `cache/`, and `imatrix/` hold data,
   never code, and the compiled llama.cpp toolchain is external (resolved via
   `LLAMA_CPP_DIRECTORY`), so its files are never part of a change here.
3. **Complexity:** Is any part of the change more complex than necessary? Flag
   over-engineering, unnecessary abstractions, or functionality that is not
   required by the change's intent.

Record design-level findings separately under `### Design` in the output,
before the severity tables. Design findings do not go through the severity
classification; they are qualitative observations for the author.

### Workflow and User Communication

Use the TodoWrite tool to create and track these steps:

1. Resolve PR, base branch, and gather context
2. Design review
3. Pass 1
4. Pass 2
5. Pass 3
6. Build final summary (deduplicate, re-examine, severity, filter); internally only
7. Print the report in the terminal

Mark each todo as `in_progress` when starting and `completed` when done.
After each pass, tell the user in one line how many new defects were found
(e.g., "Pass 1 complete; found 6 defects.").

After Pass 3, build the final summary internally; **do not print it yet**.
Once the summary is complete, print the report body in the conversation as the
turn's final output, following the *Report Output* section below. **Nothing
(no recap, no "Let me know if…", no "Review complete" line, no follow-up
commentary) may be printed after the report.** The report is the terminal
output of the turn; any follow-up question opens a new turn.

### Review Passes

Three passes over the full diff, each with a different focus. All passes
review the full diff. Findings are recorded **without severity**: just File,
Line(s), and Description.

Only flag defects in lines that are added or modified in this PR. Do not flag
issues in unchanged context lines, even if they appear in diff hunks.

Skip any finding that:
- Matches a finding from a previous pass (same file and overlapping line
  range).
- Describes the same logical issue as an existing finding but references a
  different location (e.g., a function definition vs. its call site). Two
  findings about the same root cause count as one; keep the one closest to
  the root cause.

**Pass 1: General scan**
Review the diff. Report all defects: bugs, logic errors, security issues, bad
practices, missing validation, incorrect error handling. Also check the
project-specific concerns listed in the Project-Specific Review Checklist
section below. Only flag defects in lines that are added or modified in this PR.

**Pass 2: What was missed**
Review the diff again, assuming defects were missed on the first pass. Focus
on interactions between changed files, subtle logic errors, and implicit
assumptions in the code. Only flag defects in lines that are added or modified
in this PR.

**Pass 3: What the code does NOT do**
Assume there are still undiscovered defects. Focus on what is absent: missing
error handling, missing edge cases, missing input validation, missing null
checks, race conditions, resource leaks, and incorrect assumptions about
state. Only flag defects in lines that are added or modified in this PR.

Track findings internally across passes (in conversation context). The format
for each finding is: File, Line(s), Description.

### False Positive Exclusion List

Do NOT flag any of the following:

- Pre-existing issues not introduced in this PR's changes.
- Code that appears to be a bug but is actually correct.
- Pedantic nitpicks that a senior engineer would not flag.
- General code quality concerns unless explicitly required in AGENTS.md.
- Issues explicitly silenced in code (e.g., via a lint ignore comment).
- Pure code style or formatting preferences.
- Potential issues that depend on specific inputs or runtime state.

### Project-Specific Review Checklist

These are architectural and safety concerns specific to this PowerShell
quantization toolkit; there is no linter to catch them. Check for these during
all passes, in addition to general defect scanning. They are NOT style issues;
they are correctness and safety rules. Each maps to a rule in AGENTS.md
("Architecture", "Key Implementation Details", "Non-obvious behavior").

- **Destructive cleanup:** The intermediate-GGUF cleanup must preserve
  source-provided `.gguf` files and the cached importance matrices in
  `imatrix/`. Flag any change that could delete downloaded models in `source/`,
  finished outputs in `gguf/`, or cached matrices — these are expensive to
  recompute or re-download.
- **`.env` parsing fragility:** Both scripts parse `.env` by splitting on `=`
  and skipping blank/comment lines (no quoting, no escaping). Flag values that
  can contain `=` parsed naively, and new configuration consumed without a
  sane default or existence check.
- **MTP / NextN imatrix-coverage path:** Changes to the
  `tools/list_missing_imatrix_tensors.py` integration that break the
  missing-tensor `--tensor-type` injection: the helper's stdout contract (one
  regex rule per missing tensor), the stripping of `.in_sum2` / `.counts`
  suffixes, or `$draftTensorType` reducing a K-quant preset to its base ggml
  type (`--tensor-type` takes a ggml type, not a preset). Pinning drafts below
  `Q4_0`, or to an i-quant / `Q2_K`, is unsupported (no imatrix is computed).
- **Standalone-draft detection & routing:** Edits to the detection of
  `*AssistantForCausalLM` / `backbone_hidden_size` (MTP / NextN heads) or
  `draft_vocab_size` (EAGLE3) that misclassify a model; a standalone draft
  merged into the main GGUF instead of emitted as a separate `mtp-` / `eagle3-`
  file; a dropped `--target-model-dir` for EAGLE3; or quantizing the main
  model's KV cache at runtime (drops MTP draft acceptance to ~0%).
- **gguf-py source:** Importing `gguf` from a `pip install gguf` instead of the
  in-tree `gguf-py` under `LLAMA_CPP_DIRECTORY` — the pip package lags upstream
  and misreads files written by newer converters.
- **Mistral-format models:** A new Mistral-format model not added to
  `$mistralFormatModels` (so it misses `--mistral-format`), or list edits that
  desync from the matching conversion flag.
- **External-binary invariants:** llama.cpp binaries resolved at
  `{LLAMA_CPP_DIRECTORY}\build\bin\Release\`; unquoted space-bearing paths
  passed to `convert_hf_to_gguf.py` / `llama-imatrix.exe` / `llama-quantize.exe`
  / `git`; a removed conda `llama.cpp` activation before quantization; or a
  broken GPU-first / CPU-fallback imatrix path.
- **CHANGELOG style:** Entries not grouped under the Keep a Changelog
  `### Added` / `### Changed` / `### Fixed` / `### Removed` headings within
  `## [Unreleased]`.

### Final Summary

After Pass 3:

1. **Deduplicate:** Two findings are duplicates if they reference the same
   file and overlapping line ranges, or if they describe the same root cause
   at different locations. Keep the more detailed description.
2. **Re-examine:** For each remaining finding, verify it against the full file
   context. If the file was not already read during a pass, read it now using
   the Read tool. Remove any finding that cannot be confirmed after
   re-examination.
3. **Confidence filter:** Remove any finding where confidence is below 80%
   that it is a real defect. When in doubt, exclude.
4. **Assign severity** using these definitions:
   - **Critical:** Data loss (deleting downloaded models in `source/`,
     finished outputs in `gguf/`, or the cached importance matrices in
     `imatrix/`), corruption of an output GGUF, a security breach, or a crash
     on a common path.
   - **High:** Incorrect behavior under normal usage, unhandled error paths
     that will be hit, significant logic flaw.
   - **Medium:** Bad practice that could lead to bugs, missing validation for
     unlikely but possible inputs, minor logic issue.
5. **Filter:** Keep only Critical, High, and Medium.
6. **Print:** Print the deduped, severity-filtered findings directly in the
   terminal, following the *Report Output* section below. When the filtered
   set is empty, print a single line `No Critical/High/Medium findings.` in
   place of the severity tables; the metadata table and Design section still
   print normally. When the set is non-empty, print one table per severity
   level (omitting empty levels), following the link format rules in the Link
   Format section below.

No data is written to GitHub. The developer or reviewer uses the output to
manually create PR comments.

### Link Format

This section defines how links appear in the output tables. Follow these
rules exactly.

**Columns:** File, Description. The File column contains a markdown link. The
link label is the file path relative to the repository root with a leading
`/`, plus the line range in `:{start}-{end}` format (e.g.,
`/quantize_weights_for_llama.cpp.ps1:41-43`). The link URL is the full GitHub
URL constructed as described below.

**Line range:** Include 1 line of context before and after the finding. A
finding on line 42 links to lines 41-43. A finding spanning lines 42-45
links to lines 41-46. The label always uses `:{start}-{end}` regardless of
whether the URL uses `L` or `R` anchors.

**SHA-256 hash for PR links:** Compute the SHA-256 hex digest of each unique
file path via Node.js (cross-platform):
`node -e "process.stdout.write(require('crypto').createHash('sha256').update('{path}').digest('hex'))"`.

**When a PR exists:** Use PR deep links. The URL format is
`https://github.com/{owner}/{repo}/pull/{pr-number}/files#diff-{sha256}R{start}-R{end}`.

**When no PR exists (fallback):** Use blob links with the full HEAD SHA:
`https://github.com/{owner}/{repo}/blob/{full-sha}/{path}#L{start}-L{end}`.
Note: blob links use `L` (not `R`) for line anchors.

**Correct: markdown links with file path labels.**

```markdown
| File                                                                                                                              | Description                  |
| --------------------------------------------------------------------------------------------------------------------------------- | ---------------------------- |
| [/quantize_weights_for_llama.cpp.ps1:41-43](https://github.com/owner/repo/pull/42/files#diff-a1b2c3d4e5f6a7b8c9d0R41-R43)         | Cleanup deletes cached imatrix |
| [/quantize_weights_for_llama.cpp.ps1:41-43](https://github.com/owner/repo/blob/4a7c9e1f/quantize_weights_for_llama.cpp.ps1#L41-L43) | Cleanup deletes cached imatrix |
```

**Wrong: do NOT use any of these formats.**

```markdown
| https://github.com/owner/repo/pull/42/files#diff-a1b2c3d4e5f6a7b8c9d0R41-R43 | ...  |
| [https://github.com/...](https://github.com/...)                             | ...  |
| [quantize_weights_for_llama.cpp.ps1:41-43](https://github.com/...)           | ...  |
```

The first is wrong because it uses a raw URL instead of a markdown link. The
second is wrong because the label is a URL instead of a file path. The third
is wrong because it uses a filename only; the label must be the full path
from the repository root with a leading `/`.

### Report Output

The report is printed directly in the terminal as the turn's final output; no
files are written and no trailer follows it. Print the body in this fixed
order: **(1)** the title (`# PR Review` then `## <branch> (vs <base>)`),
**(2)** the metadata table, **(3)** the `### Design` section, **(4)** the
severity tables (or the empty-findings line). Nothing may be printed after the
report.

All tables (the metadata table and every severity table) must have every cell
(header, separator, body) padded with spaces (or dashes for the separator row)
so all cells in the same column occupy the same character width between pipes.
This keeps the report scannable in the monospace TUI.

The metadata block is a 2-column GFM table with explicit `Field` / `Value`
headers. Severity glyphs (🔴 🟠 🟡) keep the Findings row scannable without
custom styling.

Metadata-row formatting rules:

- **Branch:** link both branches to their GitHub tree URLs:
  `https://github.com/<owner>/<repo>/tree/<branch-name>`. Multi-segment branch
  names (e.g. `feature/foo`) work without encoding because the `tree/` path
  accepts literal slashes; percent-encode any branch name that contains spaces
  or other reserved characters.
- **HEAD:** use the 7-char short SHA in both the link label and the URL
  (`/commit/<head7>`). The short SHA keeps the row narrow enough that the
  OpenCode TUI does not wrap the Field column. GitHub redirects
  `/commit/<short>` to the full commit, so the link resolves identically.
- **PR:** the PR number linked to its GitHub URL when one exists
  (`[#42](https://github.com/<owner>/<repo>/pull/42)`), `none` otherwise.
- **Diff:** plain text, no colour, no emoji. Format:
  `<files> files · +<additions> · −<deletions>`, with middle dots (` · `,
  U+00B7) as separators. Use the Unicode minus sign (U+2212, `−`) for the
  deletions count, not the ASCII hyphen-minus, for typographic correctness.

When the severity-filtered set is empty, print `No Critical/High/Medium
findings.` in place of the severity tables; the metadata table and Design
section still print.

**Full report template:**

```markdown
# PR Review

## feature/foo (vs develop)

| Field     | Value                                                                                                          |
| --------- | -------------------------------------------------------------------------------------------------------------- |
| Branch    | [`feature/foo`](https://github.com/owner/repo/tree/feature/foo) → [`develop`](https://github.com/owner/repo/tree/develop) |
| HEAD      | [`head7`](https://github.com/owner/repo/commit/head7)                                                          |
| PR        | [#42](https://github.com/owner/repo/pull/42) (or `none` when no PR is open)                                    |
| Generated | YYYY-MM-DD HH:MM                                                                                                |
| Diff      | 6 files · +390 · −0                                                                                            |
| Findings  | 🔴 0 Critical · 🟠 1 High · 🟡 6 Medium                                                                        |

### Design

- <Qualitative observation about scope, placement, or complexity>

### Critical

| File                                                                                                                                | Description                    |
| ----------------------------------------------------------------------------------------------------------------------------------- | ------------------------------ |
| [/quantize_weights_for_llama.cpp.ps1:41-43](https://github.com/owner/repo/pull/42/files#diff-a1b2c3d4e5f6a7b8c9d0R41-R43)           | Cleanup deletes cached imatrix |

### High

| File                                                                                                       | Description               |
| ---------------------------------------------------------------------------------------------------------- | ------------------------- |
| [/download_model_sources.ps1:14-19](https://github.com/owner/repo/pull/42/files#diff-f6a7b8c9d0a1b2c3d4e5R14-R19) | Unhandled LFS pull failure |
```

### Constraints

- Do NOT modify source code.
- Do NOT post comments, reviews, or any data to GitHub. This skill is
  advisory with respect to GitHub; it never writes there.
- This skill is read-only: do NOT write any files. The report is printed in
  the terminal only. Do not touch `.claude/`, the repo root, or the working
  directories `source/`, `gguf/`, `cache/`, `imatrix/`.
- Do NOT report pure style or formatting preferences.
- Do NOT report issues in generated files, lock files, or changelog entries.
- File cells in output tables must use markdown link syntax with the file
  path as label; see the Link Format section.
