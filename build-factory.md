---
name: build-factory
description: >-
  Hands-off build factory. Turns an APPROVED foundation spec + BMAD epic/story plan into a built,
  usable system through a STAGED, demo-gated autonomous build — so the human invests in requirements
  and look/feel, hands off, and is only pulled back in at product-level go/no-go gates (never code).
  Use when the user says "run the build factory", "build this spec", "ship all the epics with
  checkpoints", "build-factory", or "turn this spec into a working system". Stage model:
  walking skeleton → capability-milestone demos → MVP gate (hands-on) → build-out → retrospective →
  integration PR. Drives the project's hardened scripts/ship-epic.sh as its per-epic engine; adds the
  staging, the demo capture, and the human gates on top.
---

# Build Factory 🏭

A hands-off factory that converts an approved spec into a working system. The human's time goes into
**requirements + the foundation spec** (look/feel + system basis). The factory builds. The human is
only interrupted at **product-level gates** — shown a *running, usable result* and asked "right
direction?" — never asked to look at code.

## The one principle this exists to enforce

Automated gates (Tina/Gemini, Cody/GPT-5.5, `/bmad-code-review`, `/security-review`) prove a build is
**correct** and **matches the spec**. They CANNOT prove it is **usable** or that it is the **right
thing** — only a human using a running version can. So the factory does not try to *review* its way to
the right product. It **gets to a usable result as fast and cheaply as possible, puts it in front of
the human, and gates further build-out on their product judgment.** The failure mode it prevents:
building a mountain of correct-but-unusable code before anyone notices, then reworking. Every gate is a
*product demo*, and the redirect at a gate edits the **spec** (via `/bmad-correct-course`), never the
code by hand.

## Preconditions (verify first; stop and ask if missing)

1. **An approved foundation spec** — look/feel + the system's basis (PRD + UX/architecture). The human
   owns this; the factory consumes it. If absent or unapproved, STOP — the factory does not invent
   requirements.
2. **A BMAD epic/story plan** — `_bmad-output/implementation-artifacts/sprint-status.yaml` + the epics
   doc. (If only a spec exists, run BMAD planning first: `/bmad-create-epics-and-stories` →
   `/bmad-sprint-planning`. Confirm with the human before building.)
3. **The MVP line** — which epics make the core journey usable end-to-end with real data (see Stages).
   Read it from the plan if marked; otherwise PROPOSE the cut and get one-tap confirmation.
4. **Build engine present** — `scripts/ship-epic.sh` + `scripts/test-gate.sh` in the repo. (If absent,
   the project isn't set up for the factory; offer `/new-project` to lay the kit down.)
5. **Reviewer creds present** — `google-ai-key` in Keychain (Tina) + the `codex` CLI (Cody), so the
   per-story gates don't silently skip. Warn loudly if either is missing.
6. **A safe branch** — NEVER run on `main`/the default branch if it auto-deploys. Create/switch to a
   dedicated integration branch (`build-factory/<spec-slug>`). The factory never auto-merges to a
   deploy branch; it ends with a PR the human merges.

## The stage model

There are three *kinds* of stop, not one. Build to each line, then gate.

```
spec(human) → 1. WALKING SKELETON ─[gate: bones+feel?]→
              2. CAPABILITY MILESTONES … each: build → review → demo (glance)
              3. 🛑 MVP GATE — usable for the core job; human takes the wheel; redirect authority over the back half
              4. BUILD-OUT … remaining epics: build → review → milestone demos
              5. RETROSPECTIVE → INTEGRATION PR (human merges)
```

- **Walking skeleton** — the *thinnest real end-to-end journey*: real UI in the foundation look/feel,
  real data path, stubbed logic where needed. Prioritize the visible surfaces so look/feel is judgeable
  immediately. In a BMAD plan this is usually the "thin end-to-end demo" story already pulled forward.
  Gate: cheap glance — "right bones and feel?" Redirect cost ≈ nothing.
- **Capability milestones** — each coherent user-visible capability (a group of epics/stories). Build
  it, run the per-epic review (below), then a *glance* demo. Redirect cost = one capability.
- **🛑 MVP gate** — the highest-value gate. The smallest set of epics where the **primary journey is
  usable end-to-end with real data** (the product does its actual job, not against a stub). Here the
  human does NOT glance — they *use it for real*, with all demo formats, and this gate holds explicit
  authority to **redirect the entire back half before any of it is built.** This is the gate that
  prevents the big rework.
- **Build-out** — everything past the MVP line: breadth, secondary flows, edge cases, polish. Lower
  rework risk because the core was confirmed. Milestone demos continue.
- **Retro + PR** — `/bmad-retrospective` over the whole run, then open the integration PR.

## Per-stage build loop (the engine)

For each stage's epics, in epic order:

1. **Ensure story files exist.** ship-epic needs `…/stories/<key>.md` per `ready-for-dev` story. If a
   ready key has no file, generate it first (`/bmad-create-story <key>`). Log any that can't be made.
2. **Build the epic** — `bash scripts/ship-epic.sh --story=<epic-number>` (detached; monitor to
   completion). This runs the full per-story chain (DS → Tina → Cody → `/bmad-code-review` →
   `/security-review` → commit) with the commit-integrity guard. Skip gated/blocked/backlog epics with
   a **logged reason** — never silently drop.
3. **Epic-boundary review** — after the epic's stories land, run `/bmad-code-review` and
   `/security-review` over the epic's diff (`git diff <epic-base-sha>..HEAD`). **HALT** on a new HIGH or
   `SECURITY VERDICT: BLOCKED` — do not build the next epic on a cracked foundation. (For a thorough
   capability or the MVP, optionally run the 4-lens panel: architecture / security / correctness / spec
   as parallel review subagents.)
4. **Clean-tree check at the seam** — confirm no uncommitted code crosses the epic boundary (the
   factory's outer mirror of the per-story commit-integrity guard).

## The demo protocol (every gate)

Produce ALL of these, then STOP and present — the human should not have to go hunting:

- **Deployed preview link** — deploy the stage to a live preview (project's preview/deploy mechanism,
  or `/run` to launch + expose). The realest signal.
- **Auto screenshots** — capture the key screens (use `/run` or `/verify` or a browser driver) so
  look/feel is judgeable at a glance.
- **Short written walkthrough** — in *product* terms: "what works now / what's next / decisions you
  should weigh in on." Never a diff, never code nouns.
- **Recorded click-through** — drive the real flow end-to-end and record it (or a screenshot flipbook
  if recording isn't available).

Surface the artifacts to the human (`SendUserFile` for screenshots/recording, the link + walkthrough
inline). At the MVP gate, additionally invite **hands-on** use and state plainly that this gate can
redirect the whole back half.

## The gate protocol

1. Present the demo (all formats). Ask one product question: **go** or **redirect?** (Use
   `AskUserQuestion` with go / redirect-this / redirect-bigger options.)
2. **Go** → record the stage approved; proceed to the next stage.
3. **Redirect** → do NOT hand-edit code. Run `/bmad-correct-course` to amend the **spec/plan** with the
   human's redirect, re-derive the affected stories (`/bmad-create-story` for changed/new keys), reset
   their sprint-status to `ready-for-dev`, and rebuild from the affected point. The redirect is a
   requirements change, propagated by the factory.
4. The factory **waits** at a gate — end the turn; resume when the human responds. Gates are the only
   places the factory stops for a human.

## HALT / safety / honesty

- **HALT** and surface to the human on: `/security-review` BLOCKED, a new HIGH at any boundary, a story
  the per-story party-panel escalates (`HALT_FOR_HUMAN`), an epic with zero buildable stories, or a
  budget cap hit. Never push through a HALT.
- **No auto-merge.** The run lives on the integration branch and ends with a PR the human merges. Never
  push to an auto-deploy branch mid-run.
- **Resumable.** Track stage/epic completion (a state note + the sprint-status `done` flags). A re-run
  skips completed stages and resumes at the last gate or the next epic. Respect a lockfile / cancel
  file (single run at a time).
- **Honest logging.** Every gated/blocked/skipped epic and every degraded reviewer (Tina/Cody skipped
  for a missing key) is reported. "Done" must never quietly mean "covered less than it looks."
- **Notify on long phases.** Build phases run for hours; ping the human when a gate is ready
  (proactive `SendUserFile` / a desktop notification on a local run).

## Budget / scope flags (when the human specifies)

- Scope: all eligible epics (default) or a named subset / single capability.
- Caps: max epics per run, a wall-clock cap, a token target — honor them and report what was deferred.
- `--dry-run` equivalent: print the full plan (stages, the MVP line, eligible vs gated epics, story
  counts) and STOP without building, so the human approves the plan first.

## Invocation

- `/build-factory` — auto-detect the spec + BMAD plan in the current project, propose the stage plan
  (incl. the MVP line), and STOP for plan approval before building.
- `/build-factory <path-to-spec-or-epics>` — point it at a specific spec/plan.
- The factory always shows the plan + the MVP line for confirmation **before** the first build — that
  confirmation is itself the first, cheapest course-correction.

## Why staged, not one big YOLO

A pure end-to-end YOLO (build everything, demo once at the end) is the exact failure mode this replaces:
maximum code written before the first usability signal = maximum rework when the signal is "wrong."
The factory front-loads the cheap signals (skeleton, milestones) and puts the one expensive-but-still-
cheap-to-act-on signal (MVP) in the middle, where human judgment is reliable AND the back half is still
unwritten. Spend on requirements; let the factory build; course-correct on running results.
