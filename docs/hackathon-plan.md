# LeChaton Hackathon Build Plan

## Summary

Build LeChaton as a native macOS interface for one live Mistral Vibe 2.21.0 ACP session. The demo covers executable discovery, Vibe-managed authentication, repository trust, streaming, permissions, cancellation with process-tree cleanup, and bounded Git diff inspection.

Keep the existing specifications as the long-term roadmap and use this document as the hackathon source of truth. The live ACP command-line slice is a release gate before full UI work begins.

Durable architectural boundaries are indexed in the [Architecture Decision Records](./README.md#architecture-decisions). This plan owns implementation constants, sequencing, and demo acceptance details.

## Foundation and Architecture

- Pin Tuist through Mise with `mise use --pin tuist@latest` and commit the resolved version. Generate:
  - `LeChatonCore`: discovery, transport, reducer, Vibe extensions, process cleanup, and Git inspection.
  - `LeChaton`: SwiftUI application.
  - `ACPProbe`: live command-line compatibility probe.
  - `FakeACPAgent`: deterministic test process.
  - `LeChatonTests`: Swift Testing suite.
- Target macOS 26.0, Apple Silicon, Swift language mode 6, and bundle identifier `com.vincentbach.LeChaton`. Disable App Sandbox for this local hackathon build.
- Add `script/build_and_run.sh` as the kill/build/run entry point using `mise exec -- tuist run LeChaton --generate`. Support `--debug`, `--logs`, `--telemetry`, and `--verify`, and connect the local Run action to it.
- Use a singleton `Window("LeChaton", id: "main")`, remove the standard New Window command, and keep the main window restorable.
- Create one app-owned `@MainActor @Observable SessionModel` containing the selected repository, runtime, session, reducer state, permissions, trust, and Git baseline. Keep only inspector visibility and presentation details view-scoped.
- Preserve three implementation seams:
  - `ACPTransport` actor: process and pipes, framing, correlation, routing, stderr, and termination.
  - Pure `SessionReducer`: conversation, reasoning, plans, tools, and turn state.
  - `SessionModel`: UI state and actions.
- Implement the durable `VibeAdapter` boundary with `VibeLocator` and stateless `VibeExtensions` components for the current build.
- Model JSON-RPC IDs as string-or-number `RPCID`, `_meta` as recursive `JSONValue`, and unknown enum values as `.unknown(rawValue)`.

## Vibe Lifecycle and Safety

### Discovery and compatibility

- Add a shared `VibeLocator` used by the app and `ACPProbe`, with this precedence:
  1. Explicit `ACPProbe --vibe-path` or app override.
  2. Last user-selected path stored as a non-secret preference.
  3. `~/.local/bin/vibe-acp`
  4. `/opt/homebrew/bin/vibe-acp`
  5. `/usr/local/bin/vibe-acp`
  6. Native executable picker.
- Resolve symlinks and require a regular executable file. Never depend on GUI shell `PATH`.
- After `initialize`, require `agentInfo.version == "2.21.0"`. Block the session with a diagnostic showing the expected version, reported version, and resolved executable when it differs.

### Live Phase 0 gate

- `ACPProbe` accepts `--vibe-path`, `--cwd`, `--prompt`, and optional `--cancel-after`. Trust and permission choices are printed exactly as supplied by Vibe and selected interactively.
- Execute:

```text
locate and validate vibe-acp
-> launch in a neutral directory
-> initialize and negotiate ACP v1
-> enforce Vibe 2.21.0
-> _auth/status
-> delegated browser authentication when required
-> _trust/status(cwd)
-> render and submit _trust/decision
-> session/new(cwd)
-> verify _meta.workspace_trust
-> session/prompt
-> stream updates and permissions
-> optional session/cancel
-> verify prompt and process-tree cleanup
```

- The same Vibe process performs delegated authentication `start` and `complete`.
- State the browser credential contract as: "Vibe-managed browser credentials are persisted entirely by Vibe; LeChaton never receives, stores, inspects, or logs them." Do not promise Keychain storage, inspect Vibe's credential location, or automatically sign the developer out. Manual API-key entry remains deferred from the hackathon build.
- Negotiate protocol and capabilities from `initialize`; do not infer them from the Vibe version. Reject unsupported protocol versions.

### Streaming, permissions, and cancellation

- Merge content by `messageId` when present. For ID-less content, use a synthetic ID for consecutive same-role chunks and start a new boundary on role changes, non-content updates, or turn boundaries.
- Keep the transport read loop active while permissions await user input. Publish each request to `SessionModel` and respond later using its original JSON-RPC ID.
- Enforce:

```text
Running / Awaiting approval -> Cancelling -> Idle or Failed
```

- `SessionModel` coordinates cancellation and its deadline. `ACPTransport` sends cancellation and permission responses, owns pending continuations, and performs process cleanup. `SessionReducer` applies local cancelled tool and turn state.
- Send `session/cancel` once, complete every pending permission exactly once with `cancelled`, mark unfinished tools cancelled locally, and continue accepting late updates.
- Wait five seconds for the cancelled prompt response. On timeout, terminate the complete Vibe process tree; after a two-second grace period, force-kill survivors. EOF or termination fails all pending RPC continuations.

### Process-tree cleanup

- Launch Vibe through a small Darwin `posix_spawn` wrapper inside `ACPTransport`, configuring `POSIX_SPAWN_SETPGROUP` so Vibe receives a verified dedicated process group while preserving stdin, stdout, and stderr pipes.
- Add `ProcessTreeTerminator` that snapshots PID, parent PID, and process-group relationships before terminating the parent.
- On fallback termination:
  1. Snapshot descendants while Vibe is still alive.
  2. Send `SIGTERM` bottom-up to descendant process groups and then Vibe's group.
  3. Never signal LeChaton's own process group.
  4. Rescan after two seconds.
  5. Send `SIGKILL` to verified survivors.
- Do not treat the Vibe group alone as sufficient: Vibe shell tools may create their own sessions and process groups.
- The live gate starts a long-running shell with recorded shell and child PIDs, cancels it, and asserts both disappear.

## Native Experience and Git Inspection

- Use `NavigationSplitView` with `.inspector`:
  - Sidebar: selected repository, Vibe version, authentication and trust, and single thread state.
  - Center: streamed conversation, reasoning disclosure, composer, and stop control.
  - Inspector: plan plus Activity and Changes tabs.
  - Native sheets: delegated sign-in, trust decisions, and dynamic permission options.
- Allow repository switching only while `Idle`. A failed session must first use **Reset Session**, which performs cleanup and returns to `Idle`.
- Switching repositories terminates the old runtime and clears the session ID, reducer contents, pending permissions, trust state, Git baseline, selected diff, and activity before assigning the new repository.
- Capture baseline and post-turn status using:

```text
/usr/bin/git status --porcelain=v2 -z --untracked-files=all
```

- Pass `--` before paths. Mark files already dirty at session creation without claiming hunk-level attribution.
- Stream each diff and cap it at 512 KiB or 10,000 lines. Stat untracked files before reading and display placeholders for oversized files, binary content, and submodules.

## Implementation Sequence

1. **Foundation - 20 minutes:** Tuist targets, run script, singleton window, `VibeLocator`, and version diagnostics.
2. **Live ACP gate - 45 minutes:** defensive transport, process groups, auth status, trust, session creation, streaming, permissions, cancellation, and descendant assertion.
3. **Deterministic core - 20 minutes:** fake ACP process and transport, reducer, and process-cleanup tests.
4. **Native UI - 30 minutes:** repository flow, app-owned session, three-pane workspace, trust and permission sheets, streaming, stop, and reset.
5. **Git inspector - 15 minutes:** porcelain-v2 parsing, baseline labels, bounded diffs, and placeholders.
6. **Demo rehearsal - 10 minutes:** run twice from separate clean disposable repositories.

If time slips, reduce visual polish and diff syntax coloring first. Do not remove executable validation, trust, permissions, cancellation semantics, or process cleanup.

Use branch `feature/lechaton-mvp` and Conventional Commits, for example:

- `chore(project): scaffold LeChaton with Tuist`
- `feat(runtime): locate and validate Vibe`
- `feat(acp): add live session transport`
- `feat(session): add cancellation and process cleanup`
- `feat(app): add trusted single-session workspace`
- `feat(git): add bounded changes inspector`
- `test(acp): cover transport and cancellation`

## Test and Demo Acceptance

- Locator tests cover precedence, spaces and Unicode in paths, symlinks, missing files, non-executable files, picker cancellation, and incorrect `agentInfo.version`.
- Fake-agent tests cover split and combined frames, malformed messages, string and numeric IDs, unknown enums, preserved `_meta`, permissions during prompts, duplicate cancellation, late updates, timeout, EOF, and pending-continuation failure.
- Process tests spawn a helper shell and grandchild in separate process groups, verify normal ACP cancellation cleans them up, and verify fallback cleanup without signaling the test runner's group.
- Reducer tests cover identified and ID-less messages, reasoning, plan replacement, tool merging, and terminal turn states.
- Session-model tests verify only one runtime can exist, repository switching is idle-only, reset performs cleanup, and switching clears all repository-specific state.
- Git tests use temporary repositories containing spaces, Unicode, renames, binary files, submodules, oversized untracked files, and pre-existing changes.
- The live probe must prove initialization, exact Vibe version, auth status, trust, session creation, streaming, a real permission response, cancellation, and zero surviving descendants.
- The final demo launches through `script/build_and_run.sh --verify`, selects or locates Vibe without relying on `PATH`, authenticates when needed, trusts a clean repository, completes an edit prompt, shows activity and diffs, sends a follow-up, cancels a long-running tool, and remains usable.
- Multiple windows, persistence beyond the selected Vibe path, session loading, parallel sessions, worktrees, manual API keys, sign-out, settings, attachments, Git mutations, distribution, and replay remain deferred.
