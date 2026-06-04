#!/usr/bin/env bash
# ship-epic.sh — unattended story delivery for any BMAD project (project-independent; reviewers via skills)
#
# Scans `_bmad-output/implementation-artifacts/stories/` for BMad story files
# whose status (in `_bmad-output/implementation-artifacts/sprint-status.yaml`)
# is `ready-for-dev`, and ships each one via `/bmad-ship-story`. On failure,
# convenes a party-mode panel to decide: RETRY_ONCE | SKIP_AND_CONTINUE |
# HALT_FOR_HUMAN.
#
# BMad alignment:
#   - Story path:        _bmad-output/implementation-artifacts/stories/
#   - Sprint-status:     _bmad-output/implementation-artifacts/sprint-status.yaml
#   - Status values:     backlog | ready-for-dev | in-progress | review | done
#   - File naming:       <epic>-<story>-<slug>.md  (BMad bmad-create-story
#                        template convention)
#
# SETUP REQUIRED before first use:
#   1. Story files exist at the path above with BMad template header
#      (`Status: ready-for-dev` on its own line).
#   2. `_bmad-output/implementation-artifacts/sprint-status.yaml` exists with
#      keys for each story.
#   3. `scripts/test-gate.sh` exists — invoked after each successful ship.
#   4. Reviewers are NOT invoked by this script. ship-epic only calls
#      `/bmad-ship-story` per story; the review gates (Tina = the
#      `bmad-code-review-gemini` skill, Cody = `bmad-code-review-gpt55`,
#      then `/bmad-code-review` + `/security-review`) run INSIDE
#      /bmad-ship-story (its Steps 3-6, two passes). The legacy
#      `run_tina.sh`/`run_cody.sh` wrappers are not part of this path.
#   5. Reviewer creds (consumed by those skills): `google-ai-key` in the
#      macOS Keychain (Tina/Gemini) + the `codex` CLI / ChatGPT subscription
#      (Cody). Each reviewer degrades gracefully (skips + notes) if absent —
#      so confirm both are present before an unattended run, or a gate may
#      silently pass with a reviewer skipped.
#
# Usage:
#   bash scripts/ship-epic.sh                     # ship all ready-for-dev stories
#   bash scripts/ship-epic.sh --dry-run           # list ready stories, do nothing
#   bash scripts/ship-epic.sh --story=1-1         # ship one story by filename prefix
#   bash scripts/ship-epic.sh --max-stories=2     # cap stories per session
#
# Cancel in flight:  touch ~/.velocity-crew/cancel-tonight
# Logs:              ~/Library/Logs/velocity-crew/
# Results JSON:      ~/.velocity-crew/results-<date>.json

set -euo pipefail

# Ensure the Claude Code CLI is reachable even when the non-interactive / login PATH
# omits the native-installer bin dir (headless SSH, cron, remote sessions, mac-mini).
export PATH="$HOME/.local/bin:$HOME/.claude/local:$PATH"

REPO_DIR="$(cd "$(dirname "$0")/.." && pwd)"
# Project-independent: derive a slug from the repo dir so logs/state never collide
# across projects and the box runs anywhere. Override dirs via env if desired.
PROJECT_SLUG="$(basename "$REPO_DIR" | tr '[:upper:]' '[:lower:]' | tr -cd '[:alnum:]-')"
PROJECT_SLUG="${PROJECT_SLUG:-project}"
STORY_DIR="${REPO_DIR}/_bmad-output/implementation-artifacts/stories"
SPRINT_STATUS_FILE="${REPO_DIR}/_bmad-output/implementation-artifacts/sprint-status.yaml"

# ── Test gate (optional, per-project) ──────────────────────────────────────────
if [[ -f "${REPO_DIR}/scripts/test-gate.sh" ]]; then
  TEST_GATE_CMD="bash ${REPO_DIR}/scripts/test-gate.sh"
else
  TEST_GATE_CMD="echo '[ship-epic] No test-gate.sh found — skipping gate'"
fi

LOG_DIR="${SHIP_EPIC_LOG_DIR:-${HOME}/Library/Logs/${PROJECT_SLUG}-ship-epic}"
STATE_DIR="${SHIP_EPIC_STATE_DIR:-${HOME}/.${PROJECT_SLUG}-ship-epic}"
LOCKFILE="${STATE_DIR}/ship-epic.lock"
CANCEL_FILE="${STATE_DIR}/cancel-tonight"
DATE_STAMP="$(date +%Y-%m-%d)"
RUN_STAMP="$(date +%Y-%m-%d-%H%M%S)"
LOG_FILE="${LOG_DIR}/ship-epic-${RUN_STAMP}.log"
RESULTS_FILE="${STATE_DIR}/results-${DATE_STAMP}.json"
STORY_TIMEOUT_SECS="${STORY_TIMEOUT_SECS:-5400}"

DRY_RUN=false
STORY_FILTER=""
MAX_STORIES=99

while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry-run)          DRY_RUN=true; shift ;;
    --story=*)          STORY_FILTER="${1#*=}"; shift ;;
    --max-stories=*)    MAX_STORIES="${1#*=}"; shift ;;
    -h|--help)
      sed -n '2,28p' "$0"; exit 0 ;;
    *) echo "ERROR: unknown arg: $1" >&2; exit 1 ;;
  esac
done

mkdir -p "$LOG_DIR" "$STATE_DIR"
exec > >(tee -a "$LOG_FILE") 2>&1

echo ""
echo "═══════════════════════════════════════════════════════════"
echo "ship-epic [${PROJECT_SLUG}]: $(date -Iseconds)"
echo "═══════════════════════════════════════════════════════════"

for bin in claude python3 git; do
  command -v "$bin" &>/dev/null || { echo "ERROR: '$bin' not on PATH" >&2; exit 1; }
done

[[ -d "$REPO_DIR/.git" ]] || { echo "ERROR: $REPO_DIR is not a git repo" >&2; exit 1; }

if [[ ! -d "$STORY_DIR" ]]; then
  echo "ERROR: story dir not found: $STORY_DIR"
  echo "Run bmad-create-story or bmad-sprint-planning to populate."
  exit 1
fi

if [[ ! -f "$SPRINT_STATUS_FILE" ]]; then
  echo "ERROR: sprint-status not found: $SPRINT_STATUS_FILE"
  echo "Run bmad-sprint-planning to populate."
  exit 1
fi

if [[ -f "$CANCEL_FILE" ]]; then
  echo "Cancel file present — aborting."
  rm -f "$CANCEL_FILE"
  exit 0
fi

# ── Lock ───────────────────────────────────────────────────────────────────────
if [[ -f "$LOCKFILE" ]]; then
  EXISTING_PID="$(cat "$LOCKFILE" 2>/dev/null || true)"
  if [[ -n "$EXISTING_PID" ]] && kill -0 "$EXISTING_PID" 2>/dev/null; then
    echo "Another ship-epic run is active (PID $EXISTING_PID). Exiting."
    exit 0
  fi
  rm -f "$LOCKFILE"
fi
echo $$ > "$LOCKFILE"
trap 'rm -f "$LOCKFILE"' EXIT INT TERM

# ── Discover ready-for-dev stories from sprint-status.yaml ─────────────────────
# BMad sprint-status.yaml shape:
#   development_status:
#     epic-1: in-progress
#     1-1-initial-alembic-migration: ready-for-dev
#     1-2-audit-log-triggers: backlog
#     ...
#
# A story key matches /^[0-9]+-[0-9]+-/.  Epic keys match /^epic-/.
READY_STORIES="$(
  python3 - "$STORY_DIR" "$SPRINT_STATUS_FILE" "$STORY_FILTER" <<'PYEOF'
import pathlib, re, sys

story_dir = pathlib.Path(sys.argv[1])
status_file = pathlib.Path(sys.argv[2])
story_filter = sys.argv[3]

text = status_file.read_text(errors="replace")
# Minimal YAML: parse `<story-key>: <status>` lines under `development_status:`.
in_dev = False
story_re = re.compile(r'^\s+([0-9]+-[0-9]+[a-z0-9-]*)\s*:\s*([a-z-]+)\s*(?:#.*)?$', re.IGNORECASE)
for line in text.splitlines():
    if line.strip().startswith('development_status:'):
        in_dev = True
        continue
    if not in_dev:
        continue
    if line and not line.startswith((' ', '\t')) and not line.startswith('#'):
        # left margin → out of block
        break
    m = story_re.match(line)
    if not m:
        continue
    story_key, status = m.group(1), m.group(2)
    if status != 'ready-for-dev':
        continue
    if story_filter:
        # Anchored prefix match: `--story=1-1` matches `1-1-…` but NOT `11-1-…`.
        # Exact match also works (`--story=1-1-initial-alembic-migration`).
        if not (story_key == story_filter or story_key.startswith(story_filter + '-')):
            continue
    md = story_dir / f"{story_key}.md"
    if md.exists():
        print(f"{story_key}\t{md}")
    else:
        print(f"# WARN missing: {md}", file=sys.stderr)
PYEOF
)"

if [[ -z "$READY_STORIES" ]]; then
  echo "No ready-for-dev stories found in ${SPRINT_STATUS_FILE}."
  exit 0
fi

TOTAL=$(echo "$READY_STORIES" | wc -l | tr -d ' ')
echo "Stories queued: ${TOTAL}"
echo "$READY_STORIES" | while IFS=$'\t' read -r id file; do
  echo "  • ${id}: ${file}"
done
echo ""

if [[ "$DRY_RUN" == "true" ]]; then
  echo "(dry-run — exiting without building)"
  exit 0
fi

# ── Timeout helper ─────────────────────────────────────────────────────────────
_timeout_prefix() {
  if command -v gtimeout &>/dev/null; then echo "gtimeout ${STORY_TIMEOUT_SECS}s"
  elif command -v timeout &>/dev/null; then echo "timeout ${STORY_TIMEOUT_SECS}s"
  else echo ""; fi
}
TIMEOUT_PREFIX="$(_timeout_prefix)"

# ── Results accumulator ────────────────────────────────────────────────────────
echo "[]" > "$RESULTS_FILE"
_record() {
  local id="$1" status="$2" notes="$3"
  python3 -c "
import json, pathlib
f = pathlib.Path('${RESULTS_FILE}')
data = json.loads(f.read_text())
data.append({'id': '${id}', 'status': '${status}', 'notes': '${notes}'})
f.write_text(json.dumps(data, indent=2))
" 2>/dev/null || true
}

# ── Update sprint-status.yaml in-place ─────────────────────────────────────────
_set_sprint_story_status() {
  local story_key="$1" new_status="$2"
  python3 - "$SPRINT_STATUS_FILE" "$story_key" "$new_status" <<'PYEOF'
import sys, re, pathlib
path, story_key, new_status = pathlib.Path(sys.argv[1]), sys.argv[2], sys.argv[3]
text = path.read_text()
# Replace `<story_key>: <old_status>` with `<story_key>: <new_status>` (preserve indentation).
pattern = re.compile(rf'^(\s+{re.escape(story_key)}\s*:\s*)([a-z-]+)(\s*)$', re.MULTILINE)
text, n = pattern.subn(rf'\g<1>{new_status}\g<3>', text)
path.write_text(text)
sys.exit(0 if n else 1)
PYEOF
}

# ── Update story file header status in-place (BMad template line) ─────────────
_set_story_file_status() {
  local story_file="$1" new_status="$2"
  python3 - "$story_file" "$new_status" <<'PYEOF'
import sys, re, pathlib
path, new_status = pathlib.Path(sys.argv[1]), sys.argv[2]
text = path.read_text()
# BMad template:  `Status: ready-for-dev`  (top of file, post-heading).
text, _n = re.subn(r'^(Status:\s*)[\w-]+', lambda m: m.group(1) + new_status, text, count=1, flags=re.MULTILINE)
path.write_text(text)
PYEOF
}

# ── Party-mode exception handler ───────────────────────────────────────────────
_party_mode_diagnose() {
  local story_id="$1" log_file="$2" exit_code="$3" context="$4"
  local party_log="${LOG_DIR}/party-${story_id}-${RUN_STAMP}.log"
  local log_excerpt
  log_excerpt="$(tail -60 "$log_file" 2>/dev/null)"

  # Prologue MUST go to stderr — caller captures stdout for the verdict only.
  echo "── Party Mode: diagnosing ${story_id} (exit ${exit_code}) ──" >&2
  echo "Party log: ${party_log}" >&2

  claude \
    --model claude-opus-4-7 \
    --dangerously-skip-permissions \
    --output-format text \
    --max-turns 25 \
    -p "/bmad-party-mode You are convening an emergency 3-agent panel (Architect, QA Lead, Dev Lead) to diagnose a blocked build story and recommend a recovery action.

BLOCKED STORY: ${story_id}
CONTEXT: ${context}
EXIT CODE: ${exit_code}

BUILD LOG (last 60 lines):
\`\`\`
${log_excerpt}
\`\`\`

Each agent briefly states their read of the failure. Panel agrees on exactly one action:
- RETRY_ONCE — failure looks transient (timeout, flaky test, lock, network blip)
- SKIP_AND_CONTINUE — real failure but other stories can proceed; mark blocked for human follow-up
- HALT_FOR_HUMAN — something fundamentally wrong; stop the entire epic run now

End with a line in exactly this format:
PANEL_VERDICT: RETRY_ONCE|SKIP_AND_CONTINUE|HALT_FOR_HUMAN" \
    > "$party_log" 2>&1 || true

  local verdict
  # Strip markdown bold (**), then whitespace, around the verdict word.
  verdict="$(grep 'PANEL_VERDICT:' "$party_log" | tail -1 | sed 's/.*PANEL_VERDICT:[[:space:]]*//' | tr -d '[:space:]*')"
  echo "Party verdict: ${verdict:-PARSE_FAILED}" >&2
  echo "Full transcript: ${party_log}" >&2

  # Only the verdict word goes to stdout — caller does VERDICT=$(...).
  case "$verdict" in
    RETRY_ONCE|SKIP_AND_CONTINUE|HALT_FOR_HUMAN) printf '%s' "$verdict" ;;
    *) printf '%s' "HALT_FOR_HUMAN" ;;
  esac
}

# ── Run one ship-story pass ────────────────────────────────────────────────────
_run_ship_story() {
  local story_file="$1" log_file="$2"
  local exit_code=0
  set +e
  if [[ -n "$TIMEOUT_PREFIX" ]]; then
    $TIMEOUT_PREFIX claude \
      --model claude-opus-4-7 \
      --dangerously-skip-permissions \
      --output-format text \
      --max-turns 200 \
      -p "/bmad-ship-story ${story_file} --headless" \
      > "$log_file" 2>&1
  else
    claude \
      --model claude-opus-4-7 \
      --dangerously-skip-permissions \
      --output-format text \
      --max-turns 200 \
      -p "/bmad-ship-story ${story_file} --headless" \
      > "$log_file" 2>&1
  fi
  exit_code=$?
  set -e
  return $exit_code
}

# ── Work ───────────────────────────────────────────────────────────────────────
BUILT=0
BLOCKED=0
HALTED=false

while IFS=$'\t' read -r STORY_ID STORY_FILE; do
  [[ "$HALTED" == "true" ]] && { echo "Epic halted by party-mode — stopping."; break; }
  [[ $BUILT -ge $MAX_STORIES ]] && { echo "Max stories (${MAX_STORIES}) reached — stopping."; break; }

  if [[ -f "$CANCEL_FILE" ]]; then
    echo "Cancel file found — stopping after ${BUILT} stories."
    rm -f "$CANCEL_FILE"
    break
  fi

  STORY_LOG="${LOG_DIR}/story-${STORY_ID}-${RUN_STAMP}.log"
  echo "── ${STORY_ID} ────────────────────────────────────────────"
  echo "File: ${STORY_FILE}"
  echo "Log:  ${STORY_LOG}"
  echo "Start: $(date -Iseconds)"

  _set_story_file_status "$STORY_FILE" "in-progress" 2>/dev/null || true
  _set_sprint_story_status "$STORY_ID" "in-progress" 2>/dev/null || true

  PRE_SHIP_SHA="$(git -C "$REPO_DIR" rev-parse HEAD 2>/dev/null || echo "no-git")"

  BUILD_START=$(date +%s)
  CLAUDE_EXIT=0
  _run_ship_story "$STORY_FILE" "$STORY_LOG" || CLAUDE_EXIT=$?
  BUILD_MIN=$(( ( $(date +%s) - BUILD_START ) / 60 ))

  POST_SHIP_SHA="$(git -C "$REPO_DIR" rev-parse HEAD 2>/dev/null || echo "no-git")"

  # ── Gate 1: commit-verification ─────────────────────────────────────────────
  # /bmad-ship-story exit 0 is necessary but not sufficient. The inner session
  # has been observed to exit 0 with a review report as final output, leaving
  # its files staged-but-uncommitted (story 1-1, story 1-2). We require either
  # HEAD to advance, OR (Gate 2 below) staged files we can commit ourselves.
  if [[ $CLAUDE_EXIT -eq 0 ]] && [[ "$PRE_SHIP_SHA" == "$POST_SHIP_SHA" ]]; then
    # ── Gate 2: auto-commit fallback ────────────────────────────────────────
    # If reviewers passed (CLAUDE_EXIT=0) and files are staged, the work is
    # real — commit it ourselves. Strict precondition: SOMETHING must be
    # staged. Empty stage = nothing was built = real failure.
    STAGED_FILES="$(git -C "$REPO_DIR" diff --cached --name-only 2>/dev/null || true)"
    if [[ -n "$STAGED_FILES" ]]; then
      echo "⚠ bmad-ship-story exited 0 but did not commit. Gate 2 auto-commit fallback firing."
      echo "  Staged files:"
      echo "$STAGED_FILES" | sed 's/^/    /'

      # Derive subject + body from the story file's headers.
      STORY_TITLE="$(grep -m1 '^# Story ' "$STORY_FILE" 2>/dev/null | sed 's/^# Story [0-9]*\.[0-9]*: *//')"
      STORY_TITLE="${STORY_TITLE:-${STORY_ID}}"

      # Use HEREDOC to preserve formatting.
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
        echo "  ⚠ Gate 2 auto-commit failed (HEAD still at ${PRE_SHIP_SHA}). Treating as build failure."
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
  # If a commit landed, verify the story's stated deliverables actually exist
  # on disk and are tracked in HEAD. Catches "shipped tests but missed
  # production code" (the 1-2 misdiagnosis we caught manually) and similar.
  #
  # Parses the story file for paths in:
  #   - "### File List" bullets (under "## Dev Agent Record")  (authoritative)
  #   - "### Project Structure Notes" bullets                  (story-author intent)
  # Verifies each path exists either committed in HEAD or in the working tree.
  # A *missing* path triggers party-mode. A path with "(new)" / "(deferred)"
  # annotation is tolerated.
  if [[ $CLAUDE_EXIT -eq 0 ]] && [[ "$PRE_SHIP_SHA" != "$POST_SHIP_SHA" ]]; then
    MISSING_PATHS="$(
      python3 - "$STORY_FILE" "$REPO_DIR" <<'PYEOF'
import pathlib, re, sys, subprocess
story_path = pathlib.Path(sys.argv[1])
repo_dir   = pathlib.Path(sys.argv[2])
text = story_path.read_text()

# Collect paths from both sections — File List is authoritative if present.
paths: list[str] = []
for header in ("### File List", "### Project Structure Notes"):
    m = re.search(rf'^{re.escape(header)}\s*\n(.+?)(?=^##|^---|\Z)', text, re.MULTILINE | re.DOTALL)
    if not m:
        continue
    for line in m.group(1).splitlines():
        # Match bulleted file path: "- `path`" or "- path"
        bm = re.match(r'^\s*[-*]\s*`?([^`\s]+)`?(\s+\(.*\))?\s*$', line)
        if bm:
            p = bm.group(1).strip()
            annotation = (bm.group(2) or '').lower()
            # Skip deferred/removed annotations
            if 'deferred' in annotation or 'removed' in annotation or 'n/a' in annotation:
                continue
            # Skip non-path strings (URLs, prose)
            if '/' in p or p.endswith('.py') or p.endswith('.md') or p.endswith('.toml') or p.endswith('.yaml') or p.endswith('.ini'):
                paths.append(p)
    if paths and header == "### File List":
        break  # File List is authoritative

# Dedup
seen = set()
ordered: list[str] = []
for p in paths:
    if p not in seen:
        seen.add(p)
        ordered.append(p)

# Verify each path exists either in HEAD or in the working tree.
missing: list[str] = []
for p in ordered:
    fs_path = repo_dir / p
    if fs_path.exists():
        continue
    # Maybe the path is committed but deleted from worktree?
    rc = subprocess.run(
        ["git", "-C", str(repo_dir), "cat-file", "-e", f"HEAD:{p}"],
        capture_output=True, text=True
    )
    if rc.returncode != 0:
        missing.append(p)

for p in missing:
    print(p)
PYEOF
    )"
    if [[ -n "$MISSING_PATHS" ]]; then
      echo "⚠ Gate 3 (files-affected): the following story-declared paths are missing on disk:"
      echo "$MISSING_PATHS" | sed 's/^/    /'
      echo "  Treating as incomplete-build → consulting party mode..."
      CLAUDE_EXIT=99
    fi
  fi

  if [[ $CLAUDE_EXIT -ne 0 ]]; then
    echo "BLOCKED (exit ${CLAUDE_EXIT}, ${BUILD_MIN}m) — consulting party mode..."
    VERDICT="$(_party_mode_diagnose "$STORY_ID" "$STORY_LOG" "$CLAUDE_EXIT" "build agent exited non-zero")"

    if [[ "$VERDICT" == "RETRY_ONCE" ]]; then
      echo "↺ Retrying ${STORY_ID}..."
      RETRY_LOG="${LOG_DIR}/retry-${STORY_ID}-${RUN_STAMP}.log"
      CLAUDE_EXIT=0
      _run_ship_story "$STORY_FILE" "$RETRY_LOG" || CLAUDE_EXIT=$?
      BUILD_MIN=$(( ( $(date +%s) - BUILD_START ) / 60 ))
      [[ $CLAUDE_EXIT -ne 0 ]] && VERDICT="SKIP_AND_CONTINUE"
    fi

    if [[ "$VERDICT" == "HALT_FOR_HUMAN" ]]; then
      echo "🛑 HALT_FOR_HUMAN — stopping epic run."
      _set_story_file_status "$STORY_FILE" "blocked" 2>/dev/null || true
      _set_sprint_story_status "$STORY_ID" "blocked" 2>/dev/null || true
      _record "$STORY_ID" "blocked" "HALT_FOR_HUMAN after ${BUILD_MIN}m"
      (( BLOCKED++ )) || true
      HALTED=true
      echo ""
      continue
    fi

    if [[ "$VERDICT" == "SKIP_AND_CONTINUE" ]] || [[ $CLAUDE_EXIT -ne 0 ]]; then
      echo "⏭ Skipping ${STORY_ID}."
      _set_story_file_status "$STORY_FILE" "blocked" 2>/dev/null || true
      _set_sprint_story_status "$STORY_ID" "blocked" 2>/dev/null || true
      _record "$STORY_ID" "blocked" "SKIP_AND_CONTINUE after ${BUILD_MIN}m"
      (( BLOCKED++ )) || true
      echo ""
      continue
    fi
  fi

  # ── Commit-integrity guard (retry-path safety net) ─────────────────────────
  # The first-attempt path runs Gate 1/2/3 (commit-verification + auto-commit of
  # staged work). The RETRY path (above) re-runs the build but did NOT re-run
  # that verification — so a retry that exits 0 with uncommitted work could be
  # marked "done" with its code stranded in the working tree, which then trips
  # the NEXT story's format gate and starves the one after (observed: Velocity
  # 22-5 → 22-6/22-7 cascade). Belt-and-suspenders: before the gate, commit any
  # uncommitted story CODE so the gate sees a clean tree, and refuse to proceed
  # if nothing ever committed. Status docs under `_bmad-output/` are managed by
  # this script (in-progress/done flips) and are expected dirty here — excluded.
  CODE_DIRTY="$(git -C "$REPO_DIR" status --porcelain --untracked-files=all 2>/dev/null | grep -v '_bmad-output/' || true)"
  if [[ -n "$CODE_DIRTY" ]]; then
    echo "⚠ Commit-integrity guard: uncommitted code after build/retry — auto-committing before the gate:"
    echo "$CODE_DIRTY" | sed 's/^/    /'
    git -C "$REPO_DIR" add -A -- ':(exclude)_bmad-output' 2>/dev/null || git -C "$REPO_DIR" add -A
    GUARD_TITLE="$(grep -m1 '^# Story ' "$STORY_FILE" 2>/dev/null | sed 's/^# Story [0-9]*\.[0-9]*: *//')"
    GUARD_TITLE="${GUARD_TITLE:-${STORY_ID}}"
    git -C "$REPO_DIR" commit -m "${GUARD_TITLE} (ship-epic commit-integrity guard)

Auto-committed by ship-epic.sh: the inner /bmad-ship-story (or its retry)
exited success but left code uncommitted. Reviewers passed per the story log.

Story: ${STORY_ID}
Story file: ${STORY_FILE}" 2>&1 | tail -3
    POST_SHIP_SHA="$(git -C "$REPO_DIR" rev-parse HEAD 2>/dev/null || echo "$POST_SHIP_SHA")"
  fi
  if [[ "$PRE_SHIP_SHA" == "$POST_SHIP_SHA" ]]; then
    echo "🛑 Commit-integrity guard: HEAD never advanced for ${STORY_ID} — nothing committed. Blocking."
    _set_story_file_status "$STORY_FILE" "blocked" 2>/dev/null || true
    _set_sprint_story_status "$STORY_ID" "blocked" 2>/dev/null || true
    _record "$STORY_ID" "blocked" "no-commit-landed after ${BUILD_MIN}m"
    (( BLOCKED++ )) || true
    echo ""
    continue
  fi

  # Build succeeded — run gate
  GATE_LOG="${LOG_DIR}/gate-${STORY_ID}-${RUN_STAMP}.log"
  echo "Running gate: ${TEST_GATE_CMD}"
  GATE_EXIT=0
  set +e
  eval "$TEST_GATE_CMD" > "$GATE_LOG" 2>&1
  GATE_EXIT=$?
  set -e

  if [[ $GATE_EXIT -ne 0 ]]; then
    echo "── gate output (tail) ──"
    tail -20 "$GATE_LOG"
    echo "────────────────────────"
    echo "BLOCKED (gate failed, ${BUILD_MIN}m) — consulting party mode..."
    VERDICT="$(_party_mode_diagnose "$STORY_ID" "$GATE_LOG" "$GATE_EXIT" "gate failed after build succeeded")"

    if [[ "$VERDICT" == "RETRY_ONCE" ]]; then
      echo "↺ Retrying gate..."
      GATE_EXIT=0
      set +e
      eval "$TEST_GATE_CMD" > "$GATE_LOG" 2>&1
      GATE_EXIT=$?
      set -e
      [[ $GATE_EXIT -ne 0 ]] && VERDICT="SKIP_AND_CONTINUE"
    fi

    if [[ "$VERDICT" == "HALT_FOR_HUMAN" ]]; then
      echo "🛑 HALT_FOR_HUMAN — stopping."
      _set_story_file_status "$STORY_FILE" "blocked" 2>/dev/null || true
      _set_sprint_story_status "$STORY_ID" "blocked" 2>/dev/null || true
      _record "$STORY_ID" "blocked" "HALT_FOR_HUMAN (gate) after ${BUILD_MIN}m"
      (( BLOCKED++ )) || true
      HALTED=true
      echo ""
      continue
    fi

    if [[ "$VERDICT" == "SKIP_AND_CONTINUE" ]] || [[ $GATE_EXIT -ne 0 ]]; then
      echo "⏭ Skipping ${STORY_ID} (gate)."
      _set_story_file_status "$STORY_FILE" "blocked" 2>/dev/null || true
      _set_sprint_story_status "$STORY_ID" "blocked" 2>/dev/null || true
      _record "$STORY_ID" "blocked" "SKIP_AND_CONTINUE (gate) after ${BUILD_MIN}m"
      (( BLOCKED++ )) || true
      echo ""
      continue
    fi
  fi

  echo "✅ Done (${BUILD_MIN}m)"
  _set_story_file_status "$STORY_FILE" "done" 2>/dev/null || true
  _set_sprint_story_status "$STORY_ID" "done" 2>/dev/null || true
  _record "$STORY_ID" "done" "${BUILD_MIN}m"
  (( BUILT++ )) || true
  echo ""

done <<< "$READY_STORIES"

# ── Summary ────────────────────────────────────────────────────────────────────
echo "═══════════════════════════════════════════════════════════"
echo "Done: $(date -Iseconds)"
echo "Stories shipped: ${BUILT}  Blocked: ${BLOCKED}  Halted: ${HALTED}"
echo ""

if [[ $BLOCKED -gt 0 ]]; then
  echo "Blocked stories:"
  python3 -c "
import json, pathlib
data = json.loads(pathlib.Path('${RESULTS_FILE}').read_text())
for r in data:
    if r['status'] == 'blocked':
        print(f\"  • {r['id']}: {r['notes']}\")
" 2>/dev/null || true
fi

echo ""
echo "Full run log: ${LOG_FILE}"
echo "Results:      ${RESULTS_FILE}"
if ls "${LOG_DIR}/party-"*"-${RUN_STAMP}.log" 2>/dev/null | grep -q .; then
  echo "Party mode:   ${LOG_DIR}/party-*-${RUN_STAMP}.log"
fi
echo "═══════════════════════════════════════════════════════════"
