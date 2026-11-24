---
name: pr-audit
description: >
  Sampled PR code review. Use when asked to audit a pull request, or to
  review one for defects and design issues with this skill by name. Freezes
  the diff once, runs independent reviewers of the same brief at the same
  time, each in a context of its own (two of the whole diff, or one per
  shard of a large one), then verifiers in fresh contexts that confirm,
  refute or leave open every candidate against the code and assign
  severity. Writes the whole result as JSON and a GitHub-styled HTML page of
  the findings of Medium and above, with deep links to the code on GitHub, to
  `.tmp/sessions/<session-id>/`, and links the page in the chat. This skill
  never writes comments, reviews, or any data to GitHub; it is advisory only.
---

## Sampled PR Code Review

One reviewer reading a diff three times in one context finds about half of
what it could, and which half is chance: a second reading in a second context
misses different things, so their union is worth more than either. A second
reading with a narrower brief misses the same things every time, because the
brief steers both. So two reviewers read the diff at once with one broad
brief; a diff over 600 KB is read shard by shard instead, one reviewer each,
because a reviewer holding a whole large diff finds less. Verifiers
that start from nothing but the code then sort every candidate into confirmed, refuted or open. A refutation quotes the
contradicting line, because a looser bar dropped real defects; so a verifier
seldom refutes, and a false candidate that misreads a real line or describes
what the ticket, the pull request or a comment declares intended often comes
out confirmed. The verifier clusters, assigns severity and words each finding;
it is no filter. The cut keeps the page short: the HTML lists the confirmed
findings of Medium and above and counts the rest, and the JSON holds all three
verdicts, each refutation with its quoted line so a reader can overrule it
without re-running the review. The workers write JSON too, held to one schema
(`scripts/report_schema.mjs`) that each runs on its own file before it returns.

The session running this skill is the orchestrator. It fetches the ticket,
runs the scripts, spawns the workers with the prompts the scripts print, and
links the report. It starts no step while a worker it spawned runs. It reads no
source file and no diff and does not review: a finding it notices on its own has
no place in the report. Every step that has one right answer is a script under
`scripts/`; the workers' briefs are `prompts/reviewer.md` and
`prompts/verifier.md`.

`<repo>` below is the working tree the review runs in, the scripts' working
directory, and `<main>` the main working tree, the same one outside a git
worktree, whose `.tmp/` holds the scratch (`AGENTS.md` → *Scratch Files*). `<review>` is `<main>/.tmp/sessions/<session-id>/review`, always
as an absolute path; the freeze empties it and refuses any directory that is
not a `review` under `.tmp/sessions/<id>/`. `<scripts>` is
`<repo>/.claude/skills/pr-audit/scripts`.

### Steps

Track these with the todo tool:

1. **Ticket.** Optional. When the user names a ticket, write
   `<review>/ticket.md` with the Write tool: the first line
   `# KEY-123: <summary>`, then the full description, acceptance criteria
   included. Otherwise write no file; the freeze records that the business
   context is unavailable, and the pull request body is the intent.
2. **Freeze.** `node <scripts>/freeze.mjs <review>` resolves the pull
   request, its base (`develop` without one) and the merge-base, writes
   `diff.patch`, `meta.json` and `intent.md`, splits the diff into chunks,
   and prints one Task prompt per reviewer. A non-zero exit is a failure to
   report as printed: a closed pull request, a failing `gh`, a HEAD that is
   not the pull request's head, a file the diff changes that differs from
   HEAD in the working tree, or an empty diff. Only
   once every check holds does the freeze empty `<review>` of an earlier run
   and move `ticket.md` into `intent.md`; a refused freeze leaves it as it was.
3. **Reviewers.** One Task call (in OpenCode the `subagent` tool) per printed
   prompt, all in one message, in the background (in OpenCode
   `background: true`, in omp `blocking: false`), subagent type
   `pr-audit-reviewer`, the prompt passed unchanged (in omp one `task` call
   whose `tasks` hold every prompt as `task`, `isolated: false` where offered,
   under the one `context` "A pr-audit worker."). Backgrounded, a slow or stuck
   worker no longer holds the step, which waits for every call in the message,
   and an interrupt ends the turn rather than the workers. Two cases put a
   spawn in the foreground instead: an unattended `opencode run`, which ends
   with the turn and kills workers still running, and a harness that refuses a
   background spawn for these agents. A reviewer that fails or returns without
   writing its file is spawned once more with the same prompt, in the
   foreground where the background was refused. When all have returned, say in
   one line how many candidates each reviewer wrote.
4. **Coverage gate.** `node <scripts>/split_diff.mjs --check <review>` writes
   `coverage.json` and prints what comes next. Resume each reviewer under
   `resume` once with its prompt (by its handle where the harness offers
   one, `task_id` or omp's `agent://<id>`, otherwise a fresh reviewer with its
   original prompt followed by this one), then run the check again. A
   reviewer whose file the schema refuses lists no chunk as read, so it is
   resumed on all of them, its prompt naming the problems. When `verifiers`
   is empty, no reviewer wrote a file: stop and tell the user, since a report
   on no candidates reads as a clean audit. A reviewer under `failed` is lost;
   the report and the summary name it. Run the check only after every reviewer
   has returned, since it reads each reviewer's file: one still running counts
   as `failed`.
5. **Verifiers.** One Task call per entry of the last check's `verifiers`,
   all in one message, in the background, as in step 3, subagent type
   `pr-audit-verifier`, the prompt passed unchanged. A verifier that fails or
   returns without writing its file is spawned once more; when it fails
   again, stop and tell the user, since there is no report without it and the
   renderer refuses one. Say in one line how many each confirmed, left open
   and refuted.
6. **Report.** `node <scripts>/render_report.mjs <review> --out
   <main>/.tmp/sessions/<session-id>` merges the verifiers' files, writes
   `<stem>.json` and `<stem>.html` and prints JSON. When it refuses a
   verifier's file, resume that verifier once with "The renderer refused
   <file>: <error>. Fix every problem it names, in the brief's *Output
   format*, run the format check your prompt names until it prints ok, and
   change nothing else", and render again.

The reply to the user is the renderer's `summary`, as printed: the counts,
the coverage, a note when a reviewer was lost or chunks went unread, and the
link to the HTML page. The report is read in the browser, so nothing of it
is retyped into the chat. When the renderer still refuses, the reply is its
error in one line and the path of the file it refused.

Where the review is one step of a larger task (a caller fixing what its own
review found), the caller reads the JSON file, whose `confirmed` list holds
every severity, and carries on in its next message; the summary closes the
review, not the task.

A worker the provider cuts off can leave its Task call hanging with nothing
the orchestrator can observe; no candidate file after twenty minutes is the
user's cue to interrupt and start the review over.

### Workers

The reviewers differ in nothing but their number and their chunks, on
purpose: a prompt that told one where to look would make every run notice
the same things. How each reads is in its brief; the Task prompt adds only
its files and the boundaries every worker keeps.

A diff read whole gets one verifier over both candidate files, which merges
what both reviewers found into one finding. A sharded diff gets one verifier
per shard at once, because shards hold disjoint files, save a file larger
than a shard, which is split at its chunks; that is the faster verifier step
for nearly the same verdicts. The cost is that one root cause two reviewers reached from
different shards prints twice.

No diff is too large to take: the reviewers and the verifiers grow with the
shards, about one each per 250 KB, and so does the cost. Nothing above
about 1.9 MB is measured, and a diff far above it starts more workers at once
than any run has tried.

The agents are defined in `.claude/agents/` and `.opencode/agents/`, each
only a header pinning the model and its effort, since
no two harnesses share a format or an include; the instructions are the
brief and the Task prompt. When the harness does not offer them, use
`general-purpose`, `general` or omp's `task` with the same prompt. They hold
the permissions of any other agent, so only the prompt keeps them to their
one file under `.tmp/`.

### Constraints

- Write only under `.tmp/sessions/<session-id>/`; modify no source file.
- Post nothing to GitHub: no comment, no review, no data.
- The report is what the renderer wrote. Add no finding to it, and drop,
  reorder or reword none.
- `review/` keeps the frozen inputs, the candidate files and the verifiers'
  output after the run, so a reader who wants a reviewer's own words for a
  finding finds them beside the report.
