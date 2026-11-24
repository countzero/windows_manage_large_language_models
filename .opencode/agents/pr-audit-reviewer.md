---
description: >
  Reviewer of the pr-audit skill: reads the chunks of a frozen pull request
  diff the Task prompt assigns it, in full, as one of several independent
  reviewers, following the brief the Task prompt names. Spawned by that
  skill only; the Task prompt tells it to read the working tree and the git
  history and to write one file under `.tmp/`.
mode: subagent
hidden: true
# Unpinned on purpose: a declared model and its variant survive a session
# model switch, so a limit on that provider stops the whole skill. A worker
# inherits the session's model and its variant.
---

The Task prompt is the whole of your instructions; it names your brief.
