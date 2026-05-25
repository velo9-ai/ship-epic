# ship-epic Inner Gate — Cross-Project Reference

**Status:** Canonical. Apply to any `ship-epic.sh` install in any repo.
**Last updated:** 2026-05-25 (from Velocity2 install + first-real-run debugging).
**Velocity2 reference implementation:** `~/Developer/velo9-dev/velocity/scripts/ship-epic.sh` + `~/Developer/velo9-dev/velocity/.claude/commands/bmad-ship-story.md`.

---

## Why this exists

`scripts/ship-epic.sh` spawns an inner `claude -p "/bmad-ship-story <story>"` session that's expected to produce + review + commit per-story work. **In observed real runs, the inner session terminates at the security review (its review-step output) without executing the commit step.** ship-epic's outer loop only knew about the inner exit code, not whether work actually shipped — so it moved on, leaving orphan-staged files that got bundled into the next story's commit.

Three for three failures at Velocity2 (stories 1-1, 11-1, 1-2) — the failure mode is consistent enough to engineer around. The fix is **three infrastructure gates + a slash-command-level contract**.

---

## The four layers

### Gate 1 — commit verification (single line of defense)

Capture HEAD SHA before and after the inner `/bmad-ship-story` invocation. If exit 0 but SHA didn't move, the inner session didn't commit. Synthesize exit 99 → party-mode.

This catches the failure but doesn't repair it. It's the floor.

### Gate 2 — auto-commit fallback (self-healing)

If Gate 1 fires AND files are staged AND reviewers all passed (CLAUDE_EXIT=0), the outer shell commits the staged work itself using a story-derived message + a body explaining the fallback fired. Empty stage = real failure → party-mode.

**This makes the system self-healing.** Even if every future inner session terminates at the security review, the work still ships cleanly.

### Gate 3 — files-affected verification (incomplete-build detector)

After a commit lands, parse the story file's `### File List` (authoritative if present) or `### Project Structure Notes` (fallback) for declared paths. Verify each exists in HEAD or worktree. Catches "shipped tests but missed production code" cases.

Tolerates `(deferred)`, `(removed)`, `(n/a)` annotations. Path detection is heuristic — looks for `/` in the value or known file extensions.

### Termination Contract (slash-command discipline)

Add to the top of `.claude/commands/bmad-ship-story.md`:

> Your final response — the LAST thing you write in this session — MUST be a one-line confirmation of the form: `SHIP-STORY COMPLETE: story=<story-id> commit=<sha> sprint-status=<done|blocked>`. A session that ends with a review report (Tina/Cody/code-review/security/anything else) as its final response is a FAILED RUN even if every individual step passed.

Plus a HALT condition: "You finished reviews and judged the work complete but cannot or will not execute step 11 + step 12. Emit `SHIP-STORY HALT: <reason>` and stop."

This pushes the model to do it right. The gates are the safety net.

---

## Patch — `ship-epic.sh`

Insert after the existing `_run_ship_story "$STORY_FILE" "$STORY_LOG" || CLAUDE_EXIT=$?` line and replace the original `if [[ $CLAUDE_EXIT -ne 0 ]]; then` block with the version below.

Pre-condition: just before `BUILD_START=$(date +%s)`, add:

```bash
PRE_SHIP_SHA="$(git -C "$REPO_DIR" rev-parse HEAD 2>/dev/null || echo "no-git")"
```

After `_run_ship_story` and the `BUILD_MIN` calc, add:

```bash
POST_SHIP_SHA="$(git -C "$REPO_DIR" rev-parse HEAD 2>/dev/null || echo "no-git")"

# ── Gate 1: commit-verification ─────────────────────────────────────────────
if [[ $CLAUDE_EXIT -eq 0 ]] && [[ "$PRE_SHIP_SHA" == "$POST_SHIP_SHA" ]]; then
  # ── Gate 2: auto-commit fallback ────────────────────────────────────────
  STAGED_FILES="$(git -C "$REPO_DIR" diff --cached --name-only 2>/dev/null || true)"
  if [[ -n "$STAGED_FILES" ]]; then
    echo "⚠ bmad-ship-story exited 0 but did not commit. Gate 2 auto-commit fallback firing."
    echo "  Staged files:"
    echo "$STAGED_FILES" | sed 's/^/    /'

    STORY_TITLE="$(grep -m1 '^# Story ' "$STORY_FILE" 2>/dev/null | sed 's/^# Story [0-9]*\.[0-9]*: *//')"
    STORY_TITLE="${STORY_TITLE:-${STORY_ID}}"

    git -C "$REPO_DIR" commit -m "$(cat <<COMMIT_EOF
${STORY_TITLE}

Auto-committed by ship-epic.sh Gate 2 fallback: the inner /bmad-ship-story
session exited 0 without executing step 11 (commit). Reviewers (Tina, Cody,
code-review, security) all returned PASS per the story log at:
    ${STORY_LOG}

Story: ${STORY_ID}
Story file: ${STORY_FILE}

Co-Authored-By: Claude Sonnet 4.6 <noreply@anthropic.com>
COMMIT_EOF
)" 2>&1 | tail -5

    POST_SHIP_SHA="$(git -C "$REPO_DIR" rev-parse HEAD)"
    if [[ "$PRE_SHIP_SHA" == "$POST_SHIP_SHA" ]]; then
      echo "  ⚠ Gate 2 auto-commit failed. Treating as build failure."
      CLAUDE_EXIT=99
    else
      echo "  ✅ Gate 2 auto-commit landed at ${POST_SHIP_SHA}."
    fi
  else
    echo "⚠ bmad-ship-story exited 0, HEAD didn't move, AND nothing is staged."
    echo "  Inner session produced no work product. Treating as build failure → party mode..."
    CLAUDE_EXIT=99
  fi
fi

# ── Gate 3: files-affected verification ─────────────────────────────────────
if [[ $CLAUDE_EXIT -eq 0 ]] && [[ "$PRE_SHIP_SHA" != "$POST_SHIP_SHA" ]]; then
  MISSING_PATHS="$(
    python3 - "$STORY_FILE" "$REPO_DIR" <<'PYEOF'
import pathlib, re, sys, subprocess
story_path = pathlib.Path(sys.argv[1])
repo_dir   = pathlib.Path(sys.argv[2])
text = story_path.read_text()

paths: list[str] = []
for header in ("### File List", "### Project Structure Notes"):
    m = re.search(rf'^{re.escape(header)}\s*\n(.+?)(?=^##|^---|\Z)', text, re.MULTILINE | re.DOTALL)
    if not m:
        continue
    for line in m.group(1).splitlines():
        bm = re.match(r'^\s*[-*]\s*`?([^`\s]+)`?(\s+\(.*\))?\s*$', line)
        if bm:
            p = bm.group(1).strip()
            annotation = (bm.group(2) or '').lower()
            if 'deferred' in annotation or 'removed' in annotation or 'n/a' in annotation:
                continue
            if '/' in p or p.endswith(('.py', '.md', '.toml', '.yaml', '.ini', '.sh', '.yml', '.html', '.css', '.js', '.ts', '.tsx', '.jsx')):
                paths.append(p)
    if paths and header == "### File List":
        break

seen = set()
ordered: list[str] = []
for p in paths:
    if p not in seen:
        seen.add(p)
        ordered.append(p)

missing: list[str] = []
for p in ordered:
    fs_path = repo_dir / p
    if fs_path.exists():
        continue
    rc = subprocess.run(["git", "-C", str(repo_dir), "cat-file", "-e", f"HEAD:{p}"],
                        capture_output=True, text=True)
    if rc.returncode != 0:
        missing.append(p)

for p in missing:
    print(p)
PYEOF
  )"
  if [[ -n "$MISSING_PATHS" ]]; then
    echo "⚠ Gate 3 (files-affected): the following story-declared paths are missing:"
    echo "$MISSING_PATHS" | sed 's/^/    /'
    echo "  Treating as incomplete-build → consulting party mode..."
    CLAUDE_EXIT=99
  fi
fi
```

---

## Patch — `.claude/commands/bmad-ship-story.md`

Insert near the top, right after the existing `# bmad-ship-story` heading + intro:

```markdown
## ⚠ NON-NEGOTIABLE TERMINATION CONTRACT

You MUST execute all 13 steps in order. Your final response — the LAST thing you write in this session — MUST be a one-line confirmation of the form:

```
SHIP-STORY COMPLETE: story=<story-id> commit=<sha> sprint-status=<done|blocked>
```

A session that ends with a review report (Tina/Cody/code-review/security/anything else) as its final response is a **FAILED RUN** even if every individual step passed. The commit (step 11) and the sprint-status update (step 12) are gates, not options. Skipping them — even because you judged the work complete at an earlier step — IS a HALT condition; emit `SHIP-STORY HALT: <reason>` and stop.

This gate exists because three prior runs ended at the security review without committing. ship-epic.sh has auto-commit fallback to recover, but a clean run produces step 11 + step 12 + the SHIP-STORY COMPLETE line above.
```

Add to the HALT Conditions list:

```markdown
- **You finished reviews and judged the work complete but cannot or will not execute step 11 + step 12.** Emit `SHIP-STORY HALT: <reason>` and stop. Do NOT end the session with a review report as the final response. The Termination Contract at the top of this file is binding.
```

---

## Portability notes

### Story format

The Gate 2 commit-message derivation uses `^# Story <epic>.<story>: <title>` (BMad format). If the target repo uses a different story header, adjust the `grep -m1 '^# Story '` and `sed 's/^# Story [0-9]*\.[0-9]*: *//'` accordingly. Fallback to `${STORY_ID}` works for any naming convention.

### File-List parsing (Gate 3)

The parser looks for `### File List` and `### Project Structure Notes` (BMad section names). For repos that use different section conventions, adjust the `header` tuple. The path-recognition heuristic (`/` or known extensions) is broad enough to work across most projects.

### Reviewer scripts

These gates assume `/bmad-ship-story` has Tina (`scripts/run_tina.sh`) + Cody (`scripts/run_cody.sh`) + `/code-review` + `/security-review` in its review chain. If a repo uses a different reviewer suite, the gates still work — they only care about the commit landing, not what reviewed it.

### Cross-repo apply checklist

When installing or updating `ship-epic.sh` in any repo:

1. [ ] Capture `PRE_SHIP_SHA` before `_run_ship_story`
2. [ ] Capture `POST_SHIP_SHA` after `_run_ship_story`
3. [ ] Gate 1: synth exit 99 if SHA unchanged + exit 0
4. [ ] Gate 2: if Gate 1 + stage non-empty → outer-shell commit with story-derived message
5. [ ] Gate 3: parse story file's `### File List` / `### Project Structure Notes`; synth exit 99 if any path missing
6. [ ] Update `.claude/commands/bmad-ship-story.md` with the Termination Contract block + new HALT condition
7. [ ] Smoke test: `bash scripts/ship-epic.sh --dry-run`

### Known repos with ship-epic.sh

- `~/Developer/velo9-dev/velocity/scripts/ship-epic.sh` ✅ (reference implementation)
- `~/Developer/velo9-dev/COPman/scripts/ship-epic.sh`
- `~/Developer/velo9-dev/jb-os/scripts/ship-epic.sh`
- (Add to this list as you install in new repos.)

---

## Validation evidence (Velocity2, 2026-05-25)

Without the gates:
- Story 1-1 inner session: exit 0, no commit. Files orphaned in working tree.
- Story 11-1 inner session: exit 0, committed everything including 1-1's orphans. Result: bundled tangled commit + 11-1 shipped 30 stories ahead of deps.

With Gate 1 only (commit-verification):
- Story 1-2 inner session: exit 0, no commit. Gate 1 detected → halted via party-mode. But work product (the staged test file) was discarded by the operator pending diagnosis.

With Gate 2 (this is the canonical state):
- Same scenario as above would auto-commit the staged file and proceed.

With Gate 3:
- Would catch a scenario where inner session writes only tests + claims a production file in its declared deliverables but never writes it. (Not yet exercised in real run; design-time check.)

With Termination Contract:
- Pushes the model to do it right at the source; gates remain as defense.
