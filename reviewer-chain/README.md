# reviewer-chain — Tina → Tom → Cody adversarial review for BMad story automation

The ship-epic delivery flow has always named a three-reviewer chain. This kit is the
installable form of it — the two **non-Claude** reviewers as BMad skills, plus the scripts
that wire them into every project's `bmad-story-automator-review` flow.

| Reviewer | Skill | Model | Role in the chain | Prereq |
|---|---|---|---|---|
| **Tina** | `bmad-code-review-gemini` | Gemini Flash | Step **2b** — fast, near-free *pre-screen* before the Claude review | `google-ai-key` in macOS Keychain |
| **Tom** | `bmad-code-review` (BMad built-in) | Claude | Step **3** — the deep adversarial review; **this is the gate** | — |
| **Cody** | `bmad-code-review-gpt55` | gpt-5.5 (Codex) | Step **3d** — non-Claude *second opinion* after Tom | `openai-codex` plugin + ChatGPT auth |

Tina and Cody are **advisory and non-blocking** — each logs "skipped: <reason>" and continues
if its key/CLI is unavailable. Only Tom's CRITICAL findings move sprint-status. The value is
cross-family diversity: Tina surfaces boundary-condition leads cheaply, Tom verifies and decides,
Cody catches what a Claude reviewer's blind spots miss.

## Install

From your dev root (the parent dir holding your project clones):

```bash
# 1. (optional) mirror the base bmad-story-automator skill into all projects.
#    Defaults to copying from a V9OS clone; override with --src=/path/to/source-project.
./install-bmad-story-automator.sh --apply

# 2. wire Tina (2b) + Cody (3d) into every project's review flow. Idempotent —
#    re-running only adds what's missing. Dry-run by default; --apply to write.
./wire-reviewers-into-story-automator.sh            # preview the plan
./wire-reviewers-into-story-automator.sh --apply    # perform the wiring
```

`wire-reviewers-into-story-automator.sh` is **self-contained** — it embeds both SKILL.md
bodies and an idempotent XML injector, so you can `scp` it to another box and run it as-is.
The `skills/` copies here are the canonical source of those embedded bodies (keep them in sync
if you edit the script's heredocs).

Set `DEV_ROOT=/path` to point at a non-default dev root. Pass project basenames to limit scope:
`./wire-reviewers-into-story-automator.sh --apply velocity Cadence`.

## Prerequisites

- **Tina:** `security add-generic-password -U -a "$USER" -s google-ai-key -w '<google-ai-key>'`
- **Cody:** the `openai-codex` Claude Code marketplace plugin installed (companion resolved via
  `$HOME/.claude/plugins/marketplaces/openai-codex/...`) and Codex authenticated against a ChatGPT
  account (`/codex:setup`). Each run draws against that subscription.

A box missing either credential still gets a valid wiring — the corresponding step just skips.

## Reverting

Each injected step is fenced with a `⚙️ WIRED` comment. Delete the `<step n="2b">` / `<step n="3d">`
block (and the Tina fold-in `<action>` in step 3) from a project's
`.claude/skills/bmad-story-automator-review/instructions.xml` to drop that reviewer.
