---
name: tracking-issues
description: Use when the user asks to file, backlog, track, or "make an issue" for something, when work turns up a bug, debt, or idea that is out of scope for the current task, when a task references an issue number (#N), or before starting work that may already be on the board.
---

# Tracking issues on the Forgejo board

## Overview

The backlog lives on the project's Forgejo issue board
(`https://code.clausens.cloud/kalcode/personal-assistant/issues`). It replaces prose lists:
new backlog items go on the board, not into `IDEAS.md` or CLAUDE.md's "Known debt".

The CLI is `tea` (Gitea's CLI; Forgejo speaks the same API). Run it from inside the repo and it
picks the login and repo from the git remote. No `--login`/`--repo` needed.

## When to file

| Situation | Action |
|---|---|
| User asks to file / backlog / track something | File it, then give them the URL |
| You hit an out-of-scope bug, debt, or idea mid-task | Name it at handoff with a proposed title + labels; file when they say yes |
| About to start work | `tea issues list -k <keyword>` first; if it's there, reference it rather than duplicating |

## Labels

Exactly one **type** plus one or more **areas**. These are the whole set; ask before adding a label.

- Type: `bug` (broken), `feature` (new capability), `debt` (works, but costs cleanup, risk or
  speed), `idea` (undecided; brainstorm before any work)
- Area: `server` (`server/`), `native` (`native/`), `deploy` (Docker, Coolify, CI, hosting)

## Issue body

Write the body to a file in the scratchpad, then pass it with `--description-file`. The body is
these sections, in this order:

1. **Problem**: what is wrong or missing, and why it matters
2. **Current state**: evidence (`file:line`, log excerpts, measurements), trimmed to what proves it
3. **Options**: only when there is a real fork in the road
4. **Done when**: observable acceptance checks

No secret values, tokens, or personal data from logs (the repo is private, but issues get quoted).

## Quick reference

```bash
tea issues list                           # open issues (-k keyword, -L label, --state all)
tea issues 12 --comments                  # one issue in full
tea issues create -t "Title" -L debt,deploy --description-file "$SCRATCH/body.md"
tea issues edit 12 --add-labels server    # also --title, --description-file
tea comment 12 "Found the cause: ..."      # progress notes
tea issues close 12
```

Commits that finish an issue say `Closes #12` in the message. Forgejo closes it when that commit
reaches `main`. Pushing still needs the user's explicit yes.
