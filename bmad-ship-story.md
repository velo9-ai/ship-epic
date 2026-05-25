---
description: Autonomously implement, review, and commit a story. Chains DS → code-review → Gemini → GPT-5.5 → security review → commit. Stops only on FAIL or new HIGH finding.
---

# bmad-ship-story

Autonomously implement, review, and commit a single story without user interruption — except on genuine blockers (HALT conditions). One command from story to committed and sprint-status updated.

## ⚠ NON-NEGOTIABLE TERMINATION CONTRACT

You MUST execute all 13 steps in order. Your final response — the LAST thing you write in this session — MUST be a one-line confirmation of the form:

```
SHIP-STORY COMPLETE: story=<story-id> commit=<sha> sprint-status=<done|blocked>
```

A session that ends with a review report (Tina/Cody/code-review/security/anything else) as its final response is a **FAILED RUN** even if every individual step passed. The commit (step 11) and the sprint-status update (step 12) are gates, not options. Skipping them — even because you judged the work complete at an earlier step — IS a HALT condition; emit `SHIP-STORY HALT: <reason>` and stop.

This gate exists because three prior runs ended at the security review without committing. ship-epic.sh has auto-commit fallback to recover, but a clean run produces step 11 + step 12 + the SHIP-STORY COMPLETE line above.

## Usage

```
/bmad-ship-story [story-file-path]   # ship a specific story
/bmad-ship-story                     # auto-detect next ready story in sprint
```

## Procedure

Execute all steps sequentially without pausing for user input unless a HALT condition fires.

---

### Step 1 — Implement

If a story file path was provided as `$ARGUMENTS`, use it. Otherwise, auto-detect: read `_bmad-output/implementation-artifacts/sprint-status.yaml`, find the first story with `status: ready`, and use its file path.

HALT if:
- No story file path provided and no `status: ready` story exists in sprint-status.yaml
- The story file has `status: blocked` or `status: done`

Invoke `/bmad-dev-story` with the story file path. Run to completion.

---

### Step 2 — Stage

Identify all modified and new files:

```bash
git status --porcelain
```

Stage all changed files with `git add <files>`. Exclude:
- `.env` and any `*.env` variants
- `*.secret`
- `credentials*`
- Private keys (files matching `*_rsa`, `*_ed25519`, `*.pem`, `*.key`)

Do NOT use `git add -A` or `git add .` — enumerate files explicitly.

HALT if there are merge conflicts or missing files that prevent staging.

---

### Step 3 — Gemini review (Tina), pass 1

Run:

```bash
bash scripts/run_tina.sh --mode=staged
```

Capture verdict and all findings. Record as "round-1 Gemini findings".

If `run_tina.sh` exits 4 (infra failure — Gemini key not configured or other infra error), skip Tina for this run. Note the skip in the eventual commit message. GPT-5.5 review in Step 4 is still required.

---

### Step 4 — GPT-5.5 review (Cody), pass 1

Run:

```bash
bash scripts/run_cody.sh --mode=staged
```

Capture verdict and all findings. Record as "round-1 GPT findings".

---

### Step 5 — Claude code review

Invoke `/code-review`. Wait for all three agents (blind hunter, edge case hunter, acceptance auditor) to complete.

Fix any blocking findings inline before proceeding. Re-stage changed files after fixes.

---

### Step 6 — Security review

Invoke `/security-review staged`.

If verdict is `SECURITY VERDICT: BLOCKED`:
→ **HALT**: surface all CRITICAL/HIGH findings to user. Do NOT commit. Stop.

---

### Step 7 — Route after pass 1

**Case A — Both PASS:**
Gemini=PASS and GPT=PASS (or Tina skipped due to infra failure and GPT=PASS):
→ Skip to Step 11.

**Case B — Either FAIL, or any new HIGH finding:**
→ Fix the specific flagged issues inline. Do NOT re-run DS (bmad-dev-story) — inline fix only.
→ Re-stage changed files: `git add <changed files>`
→ Return to Step 3 (this is pass 2).

**Case C — Both CONCERNS (MED/LOW only, no FAIL, no HIGH):**
→ Fix any MED findings that are clearly correct and not disputed.
→ Re-stage.
→ Continue to Step 8.

---

### Step 8 — Gemini review (Tina), pass 2

Run:

```bash
bash scripts/run_tina.sh --mode=staged
```

Capture verdict and all findings. Record as "round-2 Gemini findings".

If `run_tina.sh` exits 4 (infra failure), skip and note.

---

### Step 9 — GPT-5.5 review (Cody), pass 2

Run:

```bash
bash scripts/run_cody.sh --mode=staged
```

Capture verdict and all findings. Record as "round-2 GPT findings".

---

### Step 10 — Final route

Compare round-2 findings (or round-1 if routed here from Case A) against round-1. Classify each finding:

- **NEW**: not present in round 1 (different file:line AND different issue category) → must fix, or surface to user if HIGH
- **REPEAT**: same file:line or same issue category as a round-1 finding → eligible for override

**If any NEW HIGH finding:** HALT — surface to user. Stop.

**If FAIL from either reviewer after pass 2:** HALT — surface to user. Stop.

**If all remaining findings are REPEAT or LOW-only:**
→ Proceed. Document each overridden finding in the commit message under "Reviewer overrides:".

**If PASS from both:** Proceed normally (no override section needed).

---

### Step 10b — Conflict arbitration (party mode)

Party mode fires when **either** of these conditions is true after Step 10:

- There are REPEAT MED findings where Tina and Cody **disagree** — one flagged it, the other did not, and the finding is not an obviously-wrong static-analysis false positive already documented (e.g., the `begin_nested` pattern).
- Tina=PASS and Cody=CONCERNS (or vice versa) after pass 2.

Party mode does **NOT** fire when:
- Both reviewers agree the finding is valid → fix it (already handled in Step 10).
- Both reviewers independently flag the same REPEAT issue → auto-override per Step 10 logic.
- The finding is a documented false positive (e.g., `begin_nested` pattern in CLAUDE.md).

**If no dispute exists, skip this step entirely and proceed to Step 11.**

#### Party mode procedure

Invoke `/bmad-party-mode --solo` with the following framing (one invocation per disputed finding):

```
Topic: Conflict arbitration — reviewer disagreement on [finding summary]

Context:
- Story: [story title]
- Disputed finding: [file:line — description]
- Tina's verdict: [PASS or the specific finding Tina raised]
- Cody's verdict: [CONCERNS or the specific finding Cody raised]
- Relevant code: [paste the specific lines in question]
- Story spec says: [relevant acceptance criterion or dev note]

Question for the panel: Should this finding be FIXED or OVERRIDDEN?
Each agent gives a one-line verdict (FIX or OVERRIDE) with a one-sentence reason.
Majority of 2 out of 3 rules. If no majority, verdict is ESCALATE.
```

**Panel members:**

- **Winston (🏗️ Architect)** — one vote: FIX or OVERRIDE + one-sentence reason.
- **Amelia (💻 Senior Dev)** — one vote: FIX or OVERRIDE + one-sentence reason.
- **The Spec** — a non-agent third voice. Ask: does the story's acceptance criteria or dev notes explicitly address this pattern? If yes, The Spec votes accordingly and its vote counts as the tiebreaker. If silent, The Spec abstains (only Winston and Amelia votes count).

**Routing after party vote:**

| Result | Action |
|---|---|
| **OVERRIDE (2/3 or Winston + Amelia when Spec abstains with both agreeing)** | Proceed. Document in the commit message under "Party override:" with the finding summary and both agents' one-sentence reasons. |
| **FIX (2/3)** | Make the targeted fix, re-stage only the changed files, then re-run only the disagreeing reviewer (not a full pass 3). If that reviewer returns PASS or CONCERNS (no new HIGH/FAIL), continue to Step 11. |
| **ESCALATE (no majority)** | **HALT** — surface the full context (finding, both verdicts, Spec ruling) to the user. Stop. |

---

### Step 11 — Commit

Create a git commit:

- **Subject**: story title from the story file's `title:` field (≤72 characters)
- **Body**: brief summary of what was implemented
- **Reviewer overrides section** (if any): list each overridden finding with file:line and one-line justification
- **Party override section** (if any): list each party-mode override with the finding summary and both agents' reasons
- **Tina skip note** (if applicable): "Tina skipped — Gemini infra not available"
- **Footer**: `Co-Authored-By: Claude Sonnet 4.6 <noreply@anthropic.com>`

Use HEREDOC format:

```bash
git commit -m "$(cat <<'EOF'
<subject line>

<body>

Reviewer overrides:
- <file:line> — <finding summary> — <justification>

Party override:
- <file:line> — <finding summary> — Winston: <reason>. Amelia: <reason>.

Co-Authored-By: Claude Sonnet 4.6 <noreply@anthropic.com>
EOF
)"
```

Never use `--no-verify` or `--no-gpg-sign`.

---

### Step 12 — Update sprint status

In `_bmad-output/implementation-artifacts/sprint-status.yaml`, change the story's `status` from `in-progress` to `done`.

Commit this update as a separate commit:

```bash
git commit -m "chore: mark story <story-id> done in sprint-status

Co-Authored-By: Claude Sonnet 4.6 <noreply@anthropic.com>"
```

---

### Step 13 — Report

Output a single paragraph summarizing:
- Which story was implemented
- Which reviewers ran and their final verdicts
- Any findings that were fixed
- Any findings that were overridden (with brief justification)
- Any party-mode arbitrations and their outcomes
- The commit SHA(s)

---

## HALT Conditions

Stop immediately and surface to user if:

- `SECURITY VERDICT: BLOCKED` from `/security-review`
- Any NEW HIGH finding after pass 2
- Either reviewer returns FAIL after pass 2
- Party mode returns ESCALATE (no majority on disputed finding)
- Uncommitted changes that can't be staged (merge conflicts, missing files)
- The story file has `status: blocked` or `status: done`
- No story argument provided and no `status: ready` story found in sprint-status.yaml
- **You finished reviews and judged the work complete but cannot or will not execute step 11 + step 12.** Emit `SHIP-STORY HALT: <reason>` and stop. Do NOT end the session with a review report as the final response. The Termination Contract at the top of this file is binding.

---

## Notes

- Never commit `.env`, `*.secret`, `credentials*`, or private keys
- Never use `--no-verify` or `--no-gpg-sign`
- If `scripts/run_tina.sh` exits 4 (infra failure), skip Tina and note in commit message — GPT-5.5 review still required
- The autonomy grant covers this story only — do NOT begin the next story after completion
- "Fix inline" (Steps 7, 10) means targeted edits to the flagged code — never a full DS re-run for pass-2 fixes
