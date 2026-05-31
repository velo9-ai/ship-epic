---
description: Autonomously implement, review, and commit a story. Chains DS → adversarial reviewers (Gemini/Tina + GPT-5.5/Cody) → Claude code-review → security → commit. Stops only on FAIL or new HIGH. Project-independent.
---

# bmad-ship-story (project-independent)

Autonomously implement, review, and commit a single story without user interruption — except on genuine blockers (HALT conditions). One command from story to committed and sprint-status updated. **Works in any BMAD project** — no project-specific scripts required.

**Two modes.** When invoked with `--headless` (the way `ship-epic.sh` always calls you, via `claude -p` — no human in the loop): run fully autonomous, **skip Step 0**, never ask, never print a prompt that expects input. If something truly blocks, emit exactly `SHIP-STORY HALT: <one-line reason>` and stop; the orchestrator's party-mode panel diagnoses and routes. When invoked **without** `--headless` (a human ran you directly): begin with **Step 0 — Plan & Clarify**.

**Branch policy.** Defaults to committing on the current branch (trunk-style). If `SHIP_BRANCH_MODE=topic` is set, create/commit on a `story/<id>` branch instead. Either way, never force-push, never `--no-verify`, never `--no-gpg-sign`.

**Project-specific quality gates live in the reviewers, not here.** This orchestrator is generic; each project's hard constraints (e.g. isolation/leak checks, HC gates) are enforced by that project's configured review skills — do not strip or genericize a project's reviewer findings.

## ⚠ NON-NEGOTIABLE TERMINATION CONTRACT

Execute all steps in order. Your final response MUST be one line:

```
SHIP-STORY COMPLETE: story=<story-id> commit=<sha> sprint-status=<done|blocked>
```

A session that ends with a review report as its final response is a **FAILED RUN** even if every step passed. The commit (Step 11) and sprint-status update (Step 12) are gates, not options. Skipping them is a HALT condition — emit `SHIP-STORY HALT: <reason>` and stop.

## Usage

```
/bmad-ship-story [story-file-path]   # ship a specific story
/bmad-ship-story                     # auto-detect next ready story in sprint
```

## Procedure

Execute sequentially without pausing unless a HALT condition fires.

### Step 0 — Plan & clarify (interactive only — SKIP entirely if invoked with `--headless`)
Before touching anything, state the plan in **3–5 lines**:
- **Story**: id + title (the one given, or the first `ready` story you auto-detected).
- **Chain**: dev-story → Tina (Gemini) + Cody (gpt-5.5) + Claude code-review → security → commit on `<branch>`.
- **Gates**: what can HALT (security BLOCKED, new HIGH, reviewer FAIL, party-mode ESCALATE).

Then ask a clarifying question **only if proceeding would risk building the wrong thing** — e.g. no story given and several are `ready` (which one?); the story has no/empty acceptance criteria; sprint-status and the story file disagree on status. Do **NOT** ask about anything you can reasonably decide yourself — this is a YOLO box, not a checklist. If nothing is genuinely ambiguous, print `No blockers — proceeding.` and continue. After Step 0, execute Steps 1–13 autonomously (no further questions; HALT on blockers per the contract).

### Step 1 — Implement
If a story file path was given as `$ARGUMENTS`, use it. Else read `_bmad-output/implementation-artifacts/sprint-status.yaml`, find the first `status: ready` story, use its path.
HALT if: no path given and no ready story; or the story is `blocked`/`done`.
Invoke `/bmad-dev-story` with the story file path. Run to completion.

### Step 2 — Stage
`git status --porcelain`; stage changed files with `git add -- <files>`. **Exclude** `.env`/`*.env`/`*.secret`/`credentials*`/`*_rsa`/`*_ed25519`/`*.pem`/`*.key`. Do NOT use `git add -A`/`git add .` — enumerate explicitly. HALT on merge conflicts or unstageable files.

### Step 3 — Gemini review (Tina), pass 1
Invoke the **bmad-code-review-gemini** skill on the staged diff (`git diff --cached`). Capture verdict + findings as "round-1 Gemini". If the skill reports its key/CLI is unavailable, note the skip and continue — the GPT-5.5 review (Step 4) is still required.

### Step 4 — GPT-5.5 review (Cody), pass 1
Invoke the **bmad-code-review-gpt55** skill on the staged diff. Capture verdict + findings as "round-1 GPT". If Codex is unavailable, note the skip and continue.

### Step 5 — Claude code review
Invoke `/bmad-code-review` (or `/code-review` if unavailable). Fix any blocking findings inline; re-stage after fixes.

### Step 6 — Security review
Invoke `/security-review staged`. If `SECURITY VERDICT: BLOCKED` → **HALT**: surface CRITICAL/HIGH findings; do NOT commit.

### Step 7 — Route after pass 1
- **Both PASS** (or a reviewer skipped due to infra + the other PASS) → skip to Step 11.
- **Either FAIL, or any new HIGH** → fix the flagged issues inline (no DS re-run), re-stage, return to Step 3 (pass 2).
- **Both CONCERNS (MED/LOW only)** → fix clearly-correct MED findings, re-stage, continue to Step 8.

### Step 8 — Gemini review (Tina), pass 2
Re-invoke **bmad-code-review-gemini** on the staged diff. Capture as "round-2 Gemini" (skip+note if unavailable).

### Step 9 — GPT-5.5 review (Cody), pass 2
Re-invoke **bmad-code-review-gpt55** on the staged diff. Capture as "round-2 GPT".

### Step 10 — Final route
Classify round-2 findings vs round-1: **NEW** (different file:line AND category) vs **REPEAT**.
- Any **NEW HIGH** → HALT. Any **FAIL** after pass 2 → HALT.
- All remaining REPEAT or LOW-only → proceed; document each override in the commit message under "Reviewer overrides:".
- Both PASS → proceed.

### Step 10b — Conflict arbitration (party mode)
If reviewers disagree on a REPEAT MED finding, or one PASS / other CONCERNS after pass 2 (and it isn't a documented false positive): invoke `/bmad-party-mode --solo` per disputed finding — Architect + Senior Dev + The Spec each vote FIX or OVERRIDE, majority of 3 rules, no majority → ESCALATE.
- **OVERRIDE** → proceed, document under "Party override:".
- **FIX** → targeted fix, re-stage, re-run only the disagreeing reviewer; PASS/CONCERNS → Step 11.
- **ESCALATE** → HALT.
If no dispute, skip to Step 11.

### Step 11 — Commit
Commit (honoring the branch policy above):
- **Subject**: story title (≤72 chars).
- **Body**: brief summary; "Reviewer overrides:" / "Party override:" sections if any; reviewer-skip note if applicable.
- **Footer**: `Co-Authored-By: Claude <noreply@anthropic.com>`
Never `--no-verify`/`--no-gpg-sign`.

### Step 12 — Update sprint status
In `_bmad-output/implementation-artifacts/sprint-status.yaml`, set the story `status` → `done`. Commit as a separate `chore: mark story <id> done in sprint-status` commit.

### Step 13 — Report
Final line = the SHIP-STORY COMPLETE contract above.

## HALT Conditions
- `SECURITY VERDICT: BLOCKED`; any NEW HIGH after pass 2; either reviewer FAIL after pass 2; party-mode ESCALATE; unstageable changes; story `blocked`/`done`; no ready story found; or finished reviews but cannot/will not execute Steps 11–12 (emit `SHIP-STORY HALT: <reason>`).

## Notes
- Reviewers are skills (`bmad-code-review-gemini`, `bmad-code-review-gpt55`, `bmad-code-review`) — installed per-project, portable, and they degrade gracefully when a key/CLI is absent.
- The autonomy grant covers ONE story — do NOT start the next after completion.
- "Fix inline" means targeted edits to flagged code, never a full DS re-run for pass-2 fixes.
