# ship-epic — three-gate inner architecture for autonomous BMad delivery

This repo is the public reference for the ship-epic methodology — a way to chain BMad `/bmad-ship-story` runs into epic-scale autonomous delivery, with infrastructure-level safety nets that catch the failure modes Claude sessions actually exhibit in practice.

It's distilled from real first-build runs on Velo9 projects (Velocity2 in particular) and the bugs surfaced during them.

## The failure mode this exists to solve

`scripts/ship-epic.sh` spawns an inner `claude -p "/bmad-ship-story <story>"` session that's expected to produce + review + commit per-story work. Across multiple repos and multiple stories, the inner session has been observed to **exit 0 with the security-review report as its final response, leaving its work product staged but uncommitted**. The outer loop, trusting exit 0 as proof of commit, advances. The orphaned staged files get bundled into the next story's commit — or sit in working-tree limbo while the story is marked blocked.

Three for three failures during the Velocity2 first-build (stories 1-1, 11-1, 1-2 — all 2026-05-25). Consistent enough to engineer around.

## The four layers

| Layer | Where it lives | What it does |
|---|---|---|
| **Gate 1 — commit verification** | `scripts/ship-epic.sh` (outer) | Compares `git rev-parse HEAD` before/after `_run_ship_story`. If exit 0 but SHA unchanged, treat as failure. |
| **Gate 2 — auto-commit fallback** | `scripts/ship-epic.sh` (outer) | If Gate 1 fires AND files are staged AND reviewers passed, the outer shell commits the staged work itself using a story-derived message. Empty stage = real failure. |
| **Gate 3 — files-affected verification** | `scripts/ship-epic.sh` (outer) | After a commit lands, parse the story file's `### File List` (authoritative) or `### Project Structure Notes` (fallback) and verify each declared path exists in HEAD or worktree. Catches "shipped tests but missed production code." |
| **Termination Contract** | `.claude/commands/bmad-ship-story.md` (inner) | Non-negotiable final-response gate: session must end with `SHIP-STORY COMPLETE: story=<id> commit=<sha> sprint-status=<...>`. A session that ends with a review report is a FAILED RUN even if every step passed. |

Gate 2 makes the system self-healing — even if every future inner session terminates at the security review, the work still ships cleanly. The Termination Contract pushes the model to do it right at the source; the gates are the safety net.

## Files in this repo

- **`ship-epic-inner-gate.md`** — full architecture writeup with copy-paste-ready Bash snippets for the outer-loop gates and exact wording for the inner-loop contract. Plus portability notes (story formats, reviewer scripts, cross-repo apply checklist).
- **`bmad-ship-story.md`** — the per-story slash command with the Termination Contract block + new HALT condition. Drop at `~/.claude/commands/bmad-ship-story.md` for user-level resolution, or at `.claude/commands/bmad-ship-story.md` for repo-local override.
- **`reviewer-chain/`** — installable form of the Tina → Tom → Cody adversarial review chain: the two non-Claude reviewers as BMad skills (`bmad-code-review-gemini`/Gemini, `bmad-code-review-gpt55`/gpt-5.5) plus self-contained scripts that wire them into every project's `bmad-story-automator-review` flow. See [`reviewer-chain/README.md`](reviewer-chain/README.md).

## Installing in your repo

### Quick (curl)

```bash
# From the repo root you want to upgrade:
curl -sL https://raw.githubusercontent.com/velo9-ai/ship-epic/main/ship-epic-inner-gate.md > _ship-epic-gate-reference.md
# Read it. Apply Gate 1 + Gate 2 + Gate 3 to your scripts/ship-epic.sh and the
# Termination Contract block to your .claude/commands/bmad-ship-story.md.
```

### User-level slash command (optional but recommended)

```bash
mkdir -p ~/.claude/commands
curl -sL https://raw.githubusercontent.com/velo9-ai/ship-epic/main/bmad-ship-story.md > ~/.claude/commands/bmad-ship-story.md
```

After this, `/bmad-ship-story` resolves for every repo that doesn't override it project-locally.

### Pull updates

```bash
git clone https://github.com/velo9-ai/ship-epic.git ~/ship-epic   # one-time
cd ~/ship-epic && git pull                                         # ongoing
```

## Assumptions about your existing setup

The gates assume your `/bmad-ship-story` invocation has:

- A `/bmad-dev-story` skill (or equivalent) to do the actual implementation
- An adversarial review chain — observed working pattern is **Tina** (Google Gemini Flash via REST) + **Cody** (OpenAI Codex CLI) + Claude `/code-review` + Claude `/security-review`
- A `git commit` step that runs after all reviews pass
- A separate commit that updates a `sprint-status.yaml` (BMad convention)

You don't need exact name matches — the gates only care about (a) the HEAD SHA moving, (b) the staged file list, and (c) the story file's declared deliverables. Swap in your own reviewer suite as needed.

## Validation evidence

| Story | Without gates | With Gate 1 only | With Gate 2 (canonical) |
|---|---|---|---|
| 1-1 (Velocity2 initial migration) | Inner session: exit 0, no commit. Files orphaned in working tree. Bundled into next story's commit. | Would be caught + halted. | Would auto-commit cleanly. |
| 11-1 (Velocity2 e2e harness, ran ahead of deps via substring-filter bug) | Committed both stories' files together; bundled-commit + mis-titled. | Same as above. | Same as above. |
| 1-2 (Velocity2 audit-log triggers) | Inner session: exit 0, no commit. Operator discarded staged file before verifying — recoverable only via dangling-blob fsck. | Halted via party-mode; manual recovery needed. | Would auto-commit cleanly. **No operator intervention required.** |

## License

MIT. See `LICENSE`.

## Origin

Built during the Velocity2 first-build (Velo9 coaching platform, 2026-05). Distilled to portable form so the same gate architecture can install into any repo running BMad-style autonomous delivery via `ship-epic.sh`.
