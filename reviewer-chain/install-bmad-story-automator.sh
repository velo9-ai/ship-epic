#!/usr/bin/env bash
# install-bmad-story-automator.sh
#
# Mirror the bmad-story-automator (+ bmad-story-automator-review) skill from a
# canonical source install into every Claude/BMAD project under the dev root.
#
# Installs the BASE skill only. Wiring the Tina/Gemini pre-screen into each
# project's review flow is a SEPARATE step (see wire-tina-into-story-automator).
#
# Usage:
#   ./install-bmad-story-automator.sh                  # dry-run: show the plan (default)
#   ./install-bmad-story-automator.sh --apply          # perform the install (skip projects that already have it)
#   ./install-bmad-story-automator.sh --apply --force  # also overwrite existing copies (re-mirror from source)
#   ./install-bmad-story-automator.sh --src=/path/proj # override the source project (default: V9OS)
#   ./install-bmad-story-automator.sh --apply velocity Cadence   # only these target projects (basenames)
set -euo pipefail

DEV_ROOT="${DEV_ROOT:-$HOME/Developer/velo9-dev}"
SRC_PROJECT="${SRC_PROJECT:-$DEV_ROOT/V9OS}"
SKILLS=(bmad-story-automator bmad-story-automator-review)
APPLY=0
FORCE=0
ONLY=()

for a in "$@"; do
  case "$a" in
    --apply) APPLY=1 ;;
    --force) FORCE=1 ;;
    --src=*) SRC_PROJECT="${a#--src=}" ;;
    -h|--help) sed -n '2,16p' "$0"; exit 0 ;;
    --*) echo "unknown flag: $a" >&2; exit 2 ;;
    *) ONLY+=("$a") ;;
  esac
done

# --- validate source ---------------------------------------------------------
for s in "${SKILLS[@]}"; do
  [ -d "$SRC_PROJECT/.claude/skills/$s" ] \
    || { echo "ERROR: source missing '$s' under $SRC_PROJECT/.claude/skills" >&2; exit 1; }
done
SRC_ABS="$(cd "$SRC_PROJECT" && pwd)"
echo "Source : $SRC_ABS/.claude/skills"
echo "Skills : ${SKILLS[*]}"
[ "$APPLY" = 1 ] && echo "Mode   : APPLY${FORCE:+ (force overwrite)}" || echo "Mode   : dry-run (pass --apply to write)"
echo "---"

# --- resolve targets ---------------------------------------------------------
targets=()
if [ "${#ONLY[@]}" -gt 0 ]; then
  for t in "${ONLY[@]}"; do targets+=("$DEV_ROOT/$t"); done
else
  for d in "$DEV_ROOT"/*/; do
    d="${d%/}"
    [ -d "$d/.claude/skills" ] || continue                 # only real Claude/BMAD projects
    [ "$(cd "$d" && pwd)" = "$SRC_ABS" ] && continue        # never target the source
    targets+=("$d")
  done
fi

# --- install -----------------------------------------------------------------
new=0; updated=0; present=0; missing_dir=0
for proj in "${targets[@]}"; do
  name="$(basename "$proj")"
  if [ ! -d "$proj/.claude/skills" ]; then
    printf "  %-9s %-16s (no .claude/skills — not a project)\n" "SKIP" "$name"; missing_dir=$((missing_dir+1)); continue
  fi
  for s in "${SKILLS[@]}"; do
    dest="$proj/.claude/skills/$s"
    if [ -d "$dest" ] && [ "$FORCE" != 1 ]; then
      printf "  %-9s %-16s %s (already installed)\n" "present" "$name" "$s"; present=$((present+1)); continue
    fi
    label=$([ -d "$dest" ] && echo "overwrite" || echo "install")
    [ "$label" = overwrite ] && updated=$((updated+1)) || new=$((new+1))
    if [ "$APPLY" = 1 ]; then
      rm -rf "$dest"
      cp -R "$SRC_PROJECT/.claude/skills/$s" "$dest"
      # cp -R preserves mode, but re-assert the exec bit on helper scripts to be safe
      [ -d "$dest/scripts" ] && find "$dest/scripts" -type f -exec chmod +x {} \; 2>/dev/null || true
      printf "  %-9s %-16s %s\n" "$label" "$name" "$s"
    else
      printf "  would-%-3s %-16s %s\n" "$label" "$name" "$s"
    fi
  done
done

echo "---"
echo "Targets: ${#targets[@]} project(s) | install:$new overwrite:$updated present-skipped:$present non-project:$missing_dir"
[ "$APPLY" = 1 ] || echo "Dry run — re-run with --apply to perform the install (add --force to re-mirror existing copies)."
