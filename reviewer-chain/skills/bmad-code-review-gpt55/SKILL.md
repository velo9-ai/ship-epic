---
name: bmad-code-review-gpt55
description: Adversarial code review via ChatGPT gpt-5.5 through Codex CLI (the "Cody" reviewer). Use when the user says "cody review", "gpt-5.5 review", "bmad code review gpt55", or wants a non-Claude second opinion on code changes. The gpt-5.5 counterpart to bmad-code-review-gemini (Tina) — the deepest non-Claude reviewer in the chain.
---

# bmad-code-review-gpt55 — gpt-5.5 adversarial review (Cody)

The BMAD-integrated form of the standalone `cody` reviewer — a non-Claude second opinion via
ChatGPT gpt-5.5 through the Codex CLI. In the reviewer chain it runs LAST (after Tina's cheap
pre-screen and Tom's deep Claude review): Tina → Tom → Cody → security-review.

## Procedure

1. **Determine the diff.** Run `git status --short` and `git diff --shortstat`. The Codex companion
   reviews the working tree by default; if both are empty AND the work is on a committed branch,
   pass `--base <ref> --scope branch` to review the committed range instead. If there is genuinely
   nothing to review, tell the user "No changes to review" and stop.

2. **Run the review via the Codex companion** (foreground, blocks until gpt-5.5 returns):
   ```bash
   node "$HOME/.claude/plugins/marketplaces/openai-codex/plugins/codex/scripts/codex-companion.mjs" \
     adversarial-review --wait --model gpt-5.5 \
     "adversarial static review — find bugs, logic errors, and unhandled edge cases. Check: null/None handling, type coercion, off-by-one, FK/nullability assumptions, exception-handling correctness, contract propagation across producers/consumers/tests, and secret hygiene (no hardcoded credentials/keys/tokens). Adapt focus to THIS project's stack — do NOT flag the absence of patterns from other projects (no repository layer, DomainError, or uuid5 unless this project actually uses them). Lead with PASS/CONCERNS/FAIL."
   ```
   Append `--base <ref> --scope branch` when reviewing an already-committed range.

3. **Present the result verbatim** under the header `### Cody (gpt-5.5) says:` — do not paraphrase,
   re-rank findings, or add commentary before the verdict.

4. After presenting, add one sentence on whether Cody's verdict aligns with your own read. Honest
   disagreement is useful; sycophantic agreement is not.

## Notes
- Auth: Codex CLI authenticates via the user's ChatGPT account; each run draws against that subscription.
- Requires the `openai-codex` marketplace plugin (companion at the path above). If Codex is not
  installed/authenticated, direct the user to `/codex:setup` and stop.
- On companion error (auth rotated, subscription exhausted, model unavailable), surface stderr
  verbatim rather than pretending the review succeeded. Do not auto-apply fixes after presenting.
- Chain (bmad-ship-story): Tina (bmad-code-review-gemini) → Tom (bmad-code-review) → Cody (this) → security-review.
