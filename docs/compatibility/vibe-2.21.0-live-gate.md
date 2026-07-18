# Vibe 2.21.0 Live Compatibility Gate

- Date: 2026-07-18
- Result: Passed
- ACP protocol: 1
- Vibe version: 2.21.0

This opt-in gate ran against a disposable non-bare Git worktree with a valid HEAD. Its output was deliberately content-free: it recorded event kinds, local ordering, barriers, configuration restoration state, and verified process identities, but no prompt or transcript content.

## Replay matrix

- Created four independent Vibe histories covering text, reasoning, replayable tool activity, and a live plan-producing interaction.
- Loaded every history through three fresh processes, for 12 independent load traces.
- Observed 48 replayed message events, 30 reasoning events, and 6 replayable tool events in aggregate.
- Observed no plan replay, recorded as the expected transient/unsupported behavior.
- Every reducer-bound history envelope preceded its matching load response.
- Every replay barrier was acknowledged before the follow-up prompt began.
- Post-response updates were limited to tolerated non-history updates.

## Configuration safety

- Created the recovery journal before the first mutation.
- Validated an alternate thinking value on the original model and restored it before the model test.
- Validated an alternate model value through a fresh-process load and effective-value re-query.
- Re-observed both original values through a fresh ACP process before reporting success.
- Removed the recovery journal only after restoration was verified.

## Cancellation

- Cancelled a descendant-producing prompt after tracking two verified runtime identities.
- Completed graceful cleanup with zero surviving tracked identities.
- Sent a successful follow-up through the retained session runtime.

## Decision

The required compatibility slice passed, so ADR 0006 could move from Proposed to Accepted and persistence/UI work could begin. This is evidence for the exact supported Vibe release, not a general ACP ordering guarantee; runtime generation checks, staged replay, the post-load guard, and complete process cleanup remain enforced in production code.

The gate remains explicit and opt-in:

```sh
mise exec -- tuist run ACPProbe --generate -- \
  gate --confirm-live-vibe --auto-allow-permissions \
  --vibe-path /absolute/path/to/vibe-acp \
  --cwd /absolute/path/to/disposable-worktree \
  --prompt-spec /absolute/path/to/content-local-prompt-spec.json
```
