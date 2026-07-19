# LeChaton Single-Session Continuity Prototype

## Summary and Decision Gates

Build a native macOS prototype around one user-accessible saved Thread backed by one Mistral Vibe 2.21.0 ACP session. The prototype covers restart and explicit Resume, replay-safe streaming, Vibe-managed authentication, app-managed OpenAI-compatible provider profiles, repository trust, permissions, cancellation with complete process cleanup, app-wide model and thinking Settings, executable replacement, and bounded read-only Git inspection.

This is a quality-gated prototype estimated at **9-13 focused engineering days**, not the original 140-minute exercise. Use `feature/lechaton-mvp` and Conventional Commits. Create the branch before documentation or implementation changes.

The existing product and technical specifications remain the long-term roadmap. This document is the implementation source of truth for the current prototype. Use LeChaton naming in new code and current hackathon material; do not turn this work into a repository-wide rename of legacy VibeApp draft specifications.

[ADR 0006](./adr/0006-persistence-and-session-restoration.md) began as Proposed. Before persistence or UI work, the branch had to prove this live slice against the supported Vibe version:

```text
new -> prompt -> terminate -> repeated fresh-process load/replay
    -> follow-up -> config change/reload/verification/restoration
    -> cancellation and complete descendant cleanup
```

The gate passed against Vibe 2.21.0 on 2026-07-18, after the durable contracts were approved. ADR 0006 is therefore Accepted and persistence implementation is unblocked. The content-free evidence is recorded in [the compatibility report](./compatibility/vibe-2.21.0-live-gate.md). A future required-behavior failure must stop persistence-dependent changes and reopen the compatibility contract.

## Foundation and Ownership

- Pin Tuist 4.59.2 through Mise, use Swift language mode 6, and pin GRDB 7.11.1 exactly in `Tuist/Package.swift`. Commit the dependency resolution and bootstrap explicitly with `mise exec -- tuist install --no-update` so builds never hide a network update.
- Target macOS 26.0 and Apple Silicon with bundle identifier `com.vincentbach.LeChaton`. Disable App Sandbox for this local prototype.
- Keep generated Xcode projects, workspaces, and Tuist artifacts uncommitted.
- Route local build and launch through `script/build_and_run.sh`, using `mise exec -- tuist run LeChaton --generate`. Support `--debug`, `--logs`, `--telemetry`, and `--verify`, and make the local Run action delegate to it.
- Keep exactly five targets:
  - `LeChatonCore`: UI-independent domain, transport, persistence, Vibe, process, and Git behavior.
  - `LeChaton`: native SwiftUI application.
  - `ACPProbe`: opt-in live compatibility and recovery probe using the same core.
  - `FakeACPAgent`: deterministic process-boundary behavior.
  - `LeChatonTests`: deterministic offline tests.
- Use a singleton `Window("LeChaton", id: "main")` plus the standard macOS Settings scene. Remove the standard New Window command and keep the workspace window restorable.

Ownership remains explicit:

- `ACPTransport` is an actor owning one session process, its pipes, JSON-RPC framing and correlation, receive sequencing, continuations, and process-tree cleanup.
- `SessionReducer` is a synchronous deterministic reducer with no I/O or UI dependency.
- `SessionModel` is app-owned, isolated to `@MainActor`, and owns lifecycle coordination, user actions, and published state.
- `PersistenceStore` is an actor owning GRDB, migrations, and typed transactions. It never exposes a database handle.
- `AuthCoordinator` is an actor owning the separate, lazily created authentication process.
- `VibeAdapter` is the sole Vibe-specific wire boundary. `VibeLocator` is a UI-independent core component; the native executable picker remains app-owned.

Require ACP protocol 1, exact `agentInfo.version == "2.21.0"`, flat `loadSession == true`, and nested `sessionCapabilities.list` on every Vibe process. Keep JSON-RPC IDs as string-or-number `RPCID`, `_meta` as recursive `JSONValue`, and forward-compatible enums as `.unknown(rawValue)`.

`VibeLocator` resolves executables in this order: an explicit `ACPProbe --vibe-path`, the app's persisted selected path, `~/.local/bin/vibe-acp`, `/opt/homebrew/bin/vibe-acp`, `/usr/local/bin/vibe-acp`, then the app-owned native picker. Resolve symlinks and require a regular executable file; never depend on a GUI shell `PATH`.

Use a separate lazy process for authentication. Delegated browser `start` and `complete` remain on the same process, and Vibe-managed browser credentials remain entirely Vibe-owned. LeChaton never receives, stores, inspects, or logs them. Check repository trust dynamically for the selected canonical `cwd`, render the choices Vibe supplies, and do not persist trust as app metadata.

Use these lifecycle and replay types in the core:

```text
EventEnvelope(
  runtimeGeneration: UUID,
  loadAttemptID: UUID?,
  sequence: UInt64,
  deliveryPhase: loadPending | postLoadGuard | live,
  payload
)

ReplayBarrier(
  runtimeGeneration: UUID,
  loadAttemptID: UUID,
  throughSequence: UInt64
)

ProcessIdentity(pid, processStartTime)

SessionLifecycle:
  unloaded | loadingHistory | idle | prompting | cancelling
  | replacingThread | validatingExecutable | swappingExecutable
  | reloadRequired | cleanupRequired | swapFailed | failed
```

## Replay and Session Loading Contract

### Generation, sequencing, and barrier completion

- Allocate a new runtime-generation UUID for every session process and a new load-attempt UUID for every `session/load`.
- Use one serial, lossless stdout receive loop. After a session update is successfully decoded, assign its monotonically increasing sequence number immediately before yielding it. Sequence unknown update kinds too.
- Tag events associated with a pending load with its attempt ID. Ignore events from an invalidated generation or a superseded load attempt.
- When the matching load response is decoded, capture the highest event sequence already yielded by that receive loop and return it locally as `ReplayBarrier`; do not change the ACP wire response.
- `SessionModel` consumes envelopes serially, filters for the current generation and attempt, reduces synchronously, and advances `lastAppliedSequence` only after reduction completes.
- Remain in Loading History until the response succeeded, generation and attempt are still current, the runtime is healthy, no response-order violation occurred, and `lastAppliedSequence >= barrier.throughSequence`.
- Keep the transport in `postLoadGuard` until the first follow-up prompt is atomically started. A known reducer-bound history event received after the matching load response is a Vibe compatibility failure. Metadata, usage, and configuration notifications may arrive during the guard.

### Defensive decoding

Decode in two stages:

1. Validate UTF-8, JSON, and the JSON-RPC envelope.
2. Dispatch recognized methods and recognized session-update discriminators.

Invalid JSON-RPC, a malformed matching load response, or missing/invalid required fields in a known reducer event fail the load and runtime. Unknown object fields, enum values, session-update kinds, and notification methods remain tolerated. Preserve an unknown session update as `.unknown(kind, rawJSON)`, reduce it as a diagnostic no-op, and acknowledge it through the barrier. Reply `method not found` to unknown requests; ignore and diagnose unknown notifications.

### Staging, identity, and failure

- Reduce initial Resume history into an unpublished staging reducer. Never render partial history.
- A settings-triggered reload may retain a labeled, disabled `KnownGoodSnapshot`; it is presentation-only and never active runtime state. Replace it atomically when the fresh load succeeds.
- Any load failure invalidates the runtime generation before shutdown, discards staging, and preserves saved metadata. General failures offer Retry, Reset Runtime, and Remove Saved Thread; an exact unavailable-session result offers explicit Retry and Remove Saved Thread. Never fall back to `session/new`.
- Merge replayed messages and tools idempotently when stable IDs exist.
- Treat every ID-less update as a distinct synthetic `(runtimeGeneration, sequence)` event. Do not claim that arbitrary upstream ID-less chunks can be deduplicated across loads; prevent only duplicates introduced by LeChaton's own routing.
- Plans are live, transient reducer state. Clear them on unload, never persist them, and expect the plan panel to start empty after Resume. Vibe 2.21.0 replay is expected to restore messages, reasoning, and replayable tool activity, not old plans.

## Runtime, Permissions, and Cancellation

- Keep the receive loop active while outgoing requests and permission decisions are pending.
- Publish permission requests without blocking transport input. Queue them FIFO and answer each exactly once using its original JSON-RPC ID.
- Cancellation wins unresolved permission races. Resolve queued and later-arriving requests once with Vibe's cancelled outcome.
- Send `session/cancel` once, fail or resolve pending continuations once, mark unfinished tools cancelled locally, and keep receiving until cleanup completes.

Process ownership uses verified `ProcessIdentity(pid, processStartTime)` values:

1. Immediately before sending cancellation, snapshot the verified descendant closure.
2. A process becomes tracked when a scan proves a parent chain from its identity to the Vibe root or another tracked identity.
3. During the five-second graceful interval and TERM/KILL phases, rescan the root and every live tracked descendant. Continue scanning after the root exits so reparented descendants and late grandchildren remain tracked.
4. Retain an identity until it disappears or the PID reports a different start time. PPID and PGID are routing evidence, not identity.
5. Normal cancellation succeeds only after the prompt response arrives and no tracked descendants remain.
6. Otherwise send `SIGTERM` bottom-up to verified identities, wait two seconds, then `SIGKILL` verified survivors. Treat `EPERM` as still alive.
7. Use `killpg` only when every live group member is verified runtime-owned and the group is neither LeChaton's nor the test runner's.

Graceful cancellation retains the runtime and permits a follow-up. Forced cleanup or surviving descendants moves the session to Failed. EOF or termination fails every pending continuation.

## Persistence and Repository Invariants

### Database location and migration v1

Use:

```text
~/Library/Application Support/com.vincentbach.LeChaton/
  Database/LeChaton.sqlite
  Recovery/
```

Enable SQLite foreign keys on every database connection before running migrations. Store every timestamp as UTC Unix milliseconds in `INTEGER NOT NULL`.

Migration v1 creates:

| Table | Required columns and constraints |
| --- | --- |
| `projects` | `id TEXT PRIMARY KEY NOT NULL`; `canonical_path TEXT NOT NULL UNIQUE`; `display_name TEXT NOT NULL`; `created_at_ms INTEGER NOT NULL`; `last_opened_at_ms INTEGER NOT NULL` |
| `threads` | `id TEXT PRIMARY KEY NOT NULL`; `project_id TEXT NOT NULL REFERENCES projects(id) ON DELETE CASCADE`; `vibe_session_id TEXT NOT NULL UNIQUE`; `title TEXT NOT NULL`; `created_at_ms INTEGER NOT NULL`; `updated_at_ms INTEGER NOT NULL` |
| `thread_environments` | `thread_id TEXT PRIMARY KEY NOT NULL REFERENCES threads(id) ON DELETE CASCADE`; `cwd TEXT NOT NULL`; `execution_mode TEXT NOT NULL CHECK(execution_mode = 'local')` |
| `app_settings` | `id INTEGER PRIMARY KEY NOT NULL CHECK(id = 1)`; `selected_vibe_path TEXT`; `selected_thread_id TEXT REFERENCES threads(id) ON DELETE SET NULL`; seed exactly `id = 1` |

The primary-key foreign key on `thread_environments.thread_id` enforces one environment per Thread. The singleton check on `app_settings` prevents any valid key other than 1.

Keep the relational schema plural and forward-compatible. The prototype's one user-accessible saved Thread is a `PersistenceStore` API and transaction invariant, not a permanent row-count constraint. `createThread` refuses while a selected Thread exists. `replaceSelectedThread` atomically selects the replacement, removes the old Thread, and removes orphaned project metadata.

`PersistenceStore` exposes typed operations for metadata restoration, selected-Thread creation/replacement/removal, Vibe-path updates, and recoverable reset. No caller receives a GRDB queue or raw SQL surface.

Persist only project identity, Thread metadata, Vibe session ID, local environment, selection, and the selected executable path. Never persist conversation/reducer/tool/plan state, permissions, trust decisions, credentials, authentication payloads, model, or thinking.

A `session/new` identifier remains provisional and in memory. Persist a new or replacement Thread only after a visible user prompt has caused Vibe to persist the session and `session/list` contains the exact identifier. Never send a hidden prompt or edit a repository file to force persistence.

Follow at most 32 `session/list` pages, reject cursor cycles, and leave the candidate provisional with explicit retry/discard recovery when confirmation cannot complete.

### Repository validity and canonicalization

- Require a non-bare Git worktree with a valid HEAD commit. Local staged, unstaged, and untracked modifications are allowed. Their pre-existing attribution is best-effort and valid only when baseline capture completes before the first prompt.
- Canonicalize paths through `realpath`: absolute, symlink-resolved, and without a trailing separator. For v1, environment `cwd` equals the canonical project root.
- Repository relocation and import remain deferred. A missing saved repository appears unavailable with Retry and Remove Saved Thread actions.

## Thread Creation, Restoration, and Replacement

### Launch, New Thread, and Resume

- App launch runs migrations and restores metadata without starting Vibe. A saved Thread appears Unloaded and requires explicit Resume.
- New Thread initializes a provisional runtime and calls `session/new` without writing Thread metadata. After each successful visible prompt, it checks `session/list`; only the exact identifier permits project, environment, Vibe session ID, and selection to commit in one transaction.
- If a prompt does not produce a listed session, keep the usable candidate visibly provisional and allow another prompt or explicit save retry. If the database transaction fails after Vibe persistence, keep the candidate runtime usable, retain the previous durable selection, and offer Retry Save or Discard Draft. Quitting still persists no candidate metadata.
- Resume validates repository, executable, authentication, and trust before starting a fresh runtime and empty staging reducer for `session/load`.
- If `session/load` reports the exact stored identifier unavailable, preserve all metadata and offer Retry and Remove Saved Thread without creating a substitute session.
- Reset Runtime disposes transient state while preserving saved metadata.
- Remove Saved Thread warns that LeChaton will lose the Vibe session ID while Vibe's own session files remain untouched.

### Replace Saved Thread

Allow replacement only while Unloaded or Idle and preserve the one-session-runtime invariant:

```text
enter Replacing
-> invalidate the old runtime generation and load attempts
-> dispose the old session runtime and verify its process tree is gone
-> retain the old metadata and selection as Unloaded
-> launch the sole replacement session runtime
-> initialize and call session/new provisionally
-> accept visible user prompts until Vibe persists the candidate
-> require session/list to contain the exact candidate identifier
-> commit the replacement database transaction
-> atomically publish replacement runtime and metadata
```

- Never launch the replacement process until old cleanup is verified.
- Cleanup failure launches no replacement and enters Cleanup Required with Resume disabled.
- Before the database commit, the old saved Thread remains the durable selection. A non-persisting prompt or metadata-write failure leaves the replacement candidate usable and visibly provisional with Retry Save and Discard Draft; discarding or quitting returns to the old Thread as Unloaded and resumable.
- The commit makes the replacement authoritative. A later candidate crash leaves the replacement unloaded or failed and resumable; never resurrect deleted old metadata.
- The separate auth process and a private executable-validation process do not count as session runtimes.

### Database failure and recoverable reset

- A database created by a newer application version offers Update Application, Reveal Database, and Quit. It never offers reset.
- Corruption or migration failure offers Retry, Reveal Database, Export Diagnostic, and a separately confirmed Reset Local Metadata.
- Reset first stops every session, auth, and candidate owner and closes the GRDB queue.
- Atomically rename the complete `Database` directory, including SQLite `-wal` and `-shm` sidecars, to a unique timestamped directory under `Recovery`.
- Abort without creating a replacement store if backup fails. Otherwise recreate `Database`, run migrations, and show the recoverable backup path.
- Never silently delete the only forensic copy.

## Settings

### Managed OpenAI-compatible providers

The Providers tab manages only generated `lechaton_` provider and model identifiers in the user `VIBE_HOME/config.toml`. It preserves unrelated semantic TOML values, rejects reserved-name collisions and stale external edits, makes a timestamped recoverable backup, and atomically replaces the file without editing repository-local `.vibe` configuration. TOMLKit 0.6.0 is pinned exactly; comment preservation is not promised because Vibe may rewrite the whole document.

Provider keys live only in non-synchronizing, When-Unlocked Keychain items under `com.vincentbach.LeChaton.vibe-provider`. Vibe configuration stores only a generated environment-variable name. After the standard environment allowlist is built, LeChaton injects the resolved key into the matching session, auth-status, executable-validation, or disposable provider-test process. Mistral browser credentials, unrelated processes, SQLite, TOML, diagnostics, logs, errors, and arguments never receive it.

Users enter model IDs manually. Remote endpoints require HTTPS; keyless mode is limited to loopback HTTP/HTTPS. Draft changes invalidate a prior test. Testing discloses token use and runs initialization, streaming, and one narrowly authorized temporary-file tool check through a disposable Vibe ACP process using an isolated Vibe home and temporary Git repository. Save accepts only the exact tested draft. Activation is separate, is allowed only while Unloaded or Idle, disposes the session and auth owners before the Vibe-config commit, publishes Unloaded, and requires explicit Resume. An active provider cannot be removed until another model is active.

### Executable candidate and swap

If the resolved candidate equals the current canonical path, refresh compatibility and authentication status without replacing owners. Otherwise allow validation only while the Thread is Unloaded or Idle and disable prompts and conflicting lifecycle actions during validation.

1. Resolve and validate the canonical executable.
2. Launch a private auth candidate in a neutral directory.
3. Verify ACP protocol, exact version, required capabilities, and `_auth/status`.
4. If needed, complete delegated authentication on that same private process. It may temporarily coexist with current owners but is never published.
5. Perform the committed swap in this order:

```text
persist candidate path
-> enter irrevocable, non-interactive Swapping
-> invalidate the current generation and load attempts
-> dispose the session runtime and old auth owner
-> verify processes are gone and continuations failed
-> re-query candidate compatibility and authentication status
-> atomically publish candidate auth owner plus an Unloaded Thread
-> require explicit Resume
```

Validation or persistence failure terminates the candidate and leaves LeChaton's saved path, owner identities, and runtime unchanged. Delegated candidate sign-in may nevertheless mutate Vibe-managed global credentials. Re-query the current auth owner and publish its actual status; if reconciliation fails or no owner exists, publish Unknown and refresh on Resume.

Persistence is the irrevocable swap commit point. Never revive old owners afterward. Cleanup or promotion failure enters Swap Failed with no usable session runtime, retains the candidate path, disposes any private candidate, disables Resume, and offers cleanup/candidate retry or Quit.

The successful publication is one `@MainActor` mutation after old state is disposed. It installs the candidate auth owner and Unloaded Thread and clears old reducer output, plans, permissions, trust/activity, and configuration presentation.

### Model and thinking

Expose model and thinking controls only for a loaded Idle Thread. Treat Vibe as authoritative and serialize writes:

```text
effectiveFromVibe -> candidate -> applying -> effectiveFromVibe
                                  `-> reloadRequired
```

- Send `session/set_config_option` without optimistically publishing the candidate.
- After a successful write, invalidate and terminate the current runtime before starting a fresh process and staged load.
- Re-read the fresh load's configuration options. Publish only after the requested value is observed as effective and history replay succeeds.
- Timeout, EOF, mismatch, or reload failure may mean Vibe's global value changed. Dispose the runtime, retain disabled known-good history, enter Reload Required, and reconcile from Vibe on explicit Resume. Never claim an automatic rollback.
- Disable a setting with only one advertised value. The live gate performs an idempotent current-value set/reload/re-query and reports `notValidated(noAlternativeAdvertised)` for cross-value switching.

### Live-probe configuration restoration

Configuration mutation in `ACPProbe` is failure-safe and explicitly best-effort across external termination:

- Before mutation, record the original effective model and the original model's thinking value in a durable application-support recovery journal.
- Run mutating checks in a worker supervised by an outer process. The supervisor initiates restoration after success, assertion failure, timeout, cancellation, or worker crash.
- Test an alternate thinking value on the original model and restore it before testing an alternate model. Do not modify the alternate model's thinking setting.
- Restoration always starts a fresh ACP process, re-queries actual values, changes only observed differences, reloads, and re-queries.
- The live gate cannot Pass until the original values are re-observed.
- If restoration fails, retain the journal, report original and current values, and block further mutating live tests. Reconcile an existing journal before any later mutation.
- A power loss or supervisor kill may defer cleanup until the next invocation; never promise more than the journal-backed best effort and never edit Vibe configuration files directly.

## Native Experience and Git Inspection

Use `NavigationSplitView` with an inspector:

- Sidebar: saved repository, Vibe version, authentication/trust status, and single Thread lifecycle.
- Center: replayed and streamed conversation, reasoning disclosure, composer, Resume/Stop/Retry actions, and disabled known-good history during reload failure.
- Inspector: transient live plan plus Activity and Changes tabs.
- Native sheets: delegated sign-in, repository trust, dynamic permission options, replacement warnings, and recoverable database reset.

Keep Git read-only and behind its adapter. Every invocation uses `/usr/bin/git`, an explicit working directory, argument arrays, no shell interpolation, and `--` before paths.

- Capture baseline and current state with `git status --porcelain=v2 -z --untracked-files=all`. Capture is auxiliary: it never delays session startup, disables the composer, or blocks a prompt.
- Render staged and unstaged diffs separately with no color, external diff, or textconv.
- Generate a synthetic `/dev/null` unified diff for bounded text untracked files.
- Use explicit placeholders for binary content, submodules, non-regular files, oversized input, truncation, and Git errors.
- Cap each rendered file at 512 KiB or 10,000 lines.
- Attempt a fresh baseline on New Thread and Resume. Label pre-existing dirty paths only if capture completed before the first prompt request, without claiming hunk attribution.
- If the first prompt wins the race or capture fails, keep prompting available and show current-only changes with attribution Unknown. A later capture must not be relabeled as the pre-prompt baseline; retry attribution on the next Resume.

## Implementation Sequence and Live Gate

1. Create and switch to `feature/lechaton-mvp`.
2. Add Proposed ADR 0006, register it in both routing tables, update this plan, and limit LeChaton naming changes to current implementation material.
3. Add Mise/Tuist/GRDB configuration, ignores, five targets, explicit dependency bootstrap, the canonical run script, and the app Run action.
4. Implement only the transport, tolerant decoder, reducer, fake process, process-identity tracker, and `ACPProbe` surface required to validate compatibility.
5. Run the opt-in live gate described below.
6. If any required behavior fails, stop and revise the contract. If the gate passes and durable contracts are approved, promote ADR 0006 to Accepted.
7. Complete deterministic transport, replay, settings-state, permission, cancellation, and process-tree tests.
8. Implement migration v1, `PersistenceStore`, metadata-only restoration, Thread transactions, staged replay, and recoverable reset.
9. Build the workspace UI, explicit Resume flow, Settings executable swap, and model/thinking controls.
10. Add bounded Git inspection, integration tests, accessibility basics, and final demo rehearsal.

The live gate creates four independent Vibe histories covering messages, reasoning, a replayable tool/result, and a live plan-producing interaction. Load each history sequentially through three fresh Vibe processes for **12 load traces**.

For each trace, record only sanitized frame ordinal, event kind, local sequence, load-response position, and reducer acknowledgement; never record transcript content. Require non-zero replay coverage for messages, reasoning, and replayable tools. Observe the plan live, then record its absence after load as expected transient behavior rather than replay-order evidence.

Fail immediately if any known reducer-bound history envelope arrives after its matching load response. Send the follow-up only after the replay barrier completes. A passing gate is compatibility evidence for Vibe 2.21.0, not a general ACP proof; production still enforces generation and barrier checks.

The same gate must:

- Create one empty `session/new`, terminate it, and verify a fresh process cannot list or load that identifier. Separately send an explicit prompt to a provisional session and require `session/list` to report its exact identifier before using it as compatibility evidence.
- Exercise model/thinking mutation, fresh-process reload, effective-value verification, and journal-backed restoration on all exit paths.
- When no alternative value is advertised, run the idempotent current-value test and record cross-value switching as not validated.
- Start a descendant-producing prompt, cancel it, and verify that no tracked process identity survives.

## Test and Acceptance Plan

Default tests remain deterministic and offline after explicit dependency bootstrap. Cover:

- Replay generation invalidation, load-attempt mismatch, barrier acknowledgement, partial-staging discard, response failure, EOF, stale events, and response-order violations.
- Unknown fields/enums/update kinds loading and counting through the barrier; malformed JSON-RPC, known reducer events, and matching load responses failing without publishing history.
- Stable-ID idempotency, the explicit non-deduplication contract for ID-less events, and plan clearing on unload/Resume.
- FIFO permissions, cancellation races, duplicate cancellation, late updates, and one-time continuation failure.
- Initial and late descendants, grandchildren after root exit, reparenting, PGID changes, PID reuse, `EPERM`, TERM resistance, mixed groups, and zero signals to app/test processes.
- Empty `session/new` nondurability, exact `session/list` confirmation after a user prompt, no hidden persistence work, and no metadata commit when confirmation is absent.
- Thread replacement cleanup-before-create, old-metadata retention through prompt and confirmation failures, failure before/after database commit, and the one-session-runtime invariant.
- Exact unavailable-session load preserving metadata and exposing Retry and Remove without `session/new` fallback.
- Executable validation/persistence failure, global-auth reconciliation, disposal-before-publication, post-commit Swap Failed, and atomic owner publication.
- Configuration success without effective persistence, timeout after mutation, cancellation at every boundary, worker crash, restoration timeout, stale response, effective-value mismatch, and one-option degradation.
- Every migration-v1 constraint, foreign-key action, singleton setting, canonical path, UTC millisecond timestamp, store-level single-Thread invariant, migration failure, too-new schema, and recoverable directory backup.
- Dirty Git baselines, spaces and Unicode, staged/unstaged edits, renames, deletions, binaries, submodules, non-regular files, and truncation.
- Baseline success before the first prompt, prompt-before-capture and capture-failure degradation to current-only/Unknown, non-blocking prompting, stale capture rejection, and a fresh attribution attempt on Resume.

Final app acceptance is:

```text
New Thread
-> user-visible prompt with streaming, reasoning, tool, and live plan activity
-> session/list confirms the exact Vibe session ID
-> Thread metadata and selection commit
-> quit
-> relaunch with metadata only and no Vibe process
-> explicit Resume
-> messages, reasoning, and replayable tools restored once; old plan empty
-> successful follow-up
-> model/thinking change with fresh reload and effective-value assertion
-> cancellation with complete descendant cleanup
-> another follow-up
-> bounded Git inspection, with pre-existing attribution only when its baseline preceded the first prompt
```

Failure-path acceptance also verifies that quitting a provisional New Thread before a persistence-producing prompt leaves no saved Thread, replacement retains the old selection until the confirmed candidate commits, and an unavailable stored session remains saved with Retry and Remove actions.

Final validation commands are:

```sh
mise exec -- tuist test
script/build_and_run.sh --verify
```

The live ACP gate remains separate, explicit, and opt-in.

The real-provider smoke test is also separate and opt-in. It runs only when `LECHATON_LIVE_PROVIDER_SMOKE=1` and requires `LECHATON_PROVIDER_BASE_URL`, `LECHATON_PROVIDER_MODEL_ID`, and either `LECHATON_PROVIDER_API_KEY` or `LECHATON_PROVIDER_KEYLESS=1`. `LECHATON_VIBE_EXECUTABLE` may override executable discovery. It is never part of the default deterministic suite or the Vibe compatibility gate.

## Assumptions and Deferrals

- Authentication uses a separate lazy process; delegated start and complete remain on that process.
- At most one session process exists. A private auth-validation process may temporarily overlap but is never published as session state.
- Vibe remains transcript authority. LeChaton stores no conversation or plan content.
- Plans are intentionally transient across Resume.
- One-value configuration options degrade explicitly instead of failing overall compatibility.
- Multiple user-accessible Threads/projects, repository relocation/import, rename/archive, multi-worktree UX, sign-out, attachments, Git mutations, distribution, and deletion of Vibe session data remain deferred.
