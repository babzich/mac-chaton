# Vibe ACP Issues

**Status:** Living issue register
**Date:** 2026-07-18
**Reference Vibe version:** 2.21.0

This document isolates known `vibe-acp` integration constraints and open risks that affect VibeApp's architecture. It is not a list of general ACP limitations, and an item marked **Needs validation** must not be presented as a confirmed upstream defect.

See the [Technical Specification](./technical-spec.md) for VibeApp's architecture and the [Product Specification](./product-spec.md) for user-facing behavior.

## Status definitions

| Status | Meaning |
|---|---|
| Confirmed | Observed in the reference implementation or established by an integration test |
| Needs validation | Plausible risk that must be tested against the supported Vibe version |
| Upstream dependent | VibeApp has a mitigation, but a complete solution requires a Vibe change |

## Confirmed constraints

### VACP-001: Working directory is process-global

**Status:** Confirmed, upstream dependent
**Severity:** Critical

Vibe 2.21.0 changes the Python process working directory with `os.chdir(cwd)` while creating, loading, or forking a session. Its built-in Bash and filesystem tools can resolve relative paths from that process-wide directory.

**Impact**

Multiple sessions attached to different directories inside one `vibe-acp` process can interfere. A later session can change the directory used by an earlier session and direct relative file or shell operations at the wrong project.

**MVP mitigation**

- Run one `vibe-acp` process per active thread.
- Give the process an explicit working directory.
- Never multiplex active VibeApp threads through one process, even though ACP allows multiple sessions on a connection.
- Use separate Git worktrees when threads work concurrently on the same repository.

**Removal condition**

Vibe tools become session-directory-aware without depending on process-global state, followed by a concurrency regression test.

### VACP-002: Model and thinking configuration is not session-local

**Status:** Confirmed, upstream dependent
**Severity:** High

ACP exposes configuration in a session context, but Vibe 2.21.0 persists the active model and thinking configuration in shared Vibe configuration. Changing them for one thread can therefore affect other new or resumed runtimes.

**Impact**

VibeApp cannot honestly offer independent model and thinking choices per thread while processes share the same Vibe home.

**MVP mitigation**

- Present model and thinking settings as app-wide.
- Serialize configuration writes.
- Stop or invalidate warm runtimes after a change, then restore them with the new configuration.
- Keep agent mode and turn limits thread-specific where Vibe actually stores them in session state.

**Removal condition**

Vibe supports session-local model and thinking values, or VibeApp deliberately introduces isolated Vibe-home profiles and validates their authentication and session-storage behavior.

### VACP-003: Delegated browser authentication is process-bound

**Status:** Confirmed
**Severity:** Medium

The pending delegated browser-authentication attempt is held in the `vibe-acp` process. The `start` and `complete` operations must be sent to the same live process.

**Impact**

Terminating or crashing the authentication process while the browser flow is open loses the pending attempt. A newly launched process cannot simply complete it.

**MVP mitigation**

- Use one dedicated authentication process that is not tied to a project.
- Keep it alive from `start` through `complete` and status verification.
- If it exits, discard the pending attempt and restart sign-in from the beginning.
- Never persist the transient completion payload as a credential.

### VACP-004: Authentication relies on Vibe-specific extensions

**Status:** Confirmed, upstream dependent
**Severity:** High

Browser sign-in status and sign-out use Vibe-specific authentication methods and initialization metadata rather than portable ACP primitives alone.

**Impact**

Authentication cannot live in the generic ACP layer, and future Vibe versions may change extension names or payloads independently of the core ACP protocol.

**MVP mitigation**

- Keep all Vibe extensions inside `VibeAdapter` and `AuthCoordinator`.
- Version and decode extension payloads defensively.
- Gate the UI on capabilities and successful probes, not only on the Vibe version string.
- Retain manual API-key authentication as a fallback, with the key stored in macOS Keychain.

### VACP-005: Session replay can arrive before `session/load` completes

**Status:** Confirmed
**Severity:** Medium

When a session is loaded, replayed `session/update` notifications can arrive before the response to `session/load`.

**Impact**

A request/response-only implementation can lose history, render events out of order, or duplicate transcript items when the load response arrives.

**MVP mitigation**

- Start the permanent read loop before sending any session request.
- Create and register the session reducer before calling `session/load`.
- Merge replay and live updates using stable message and tool-call identifiers.
- Treat the load response as completion of loading, not as the source of replay content.

### VACP-006: Filesystem and shell execution remains inside Vibe

**Status:** Confirmed architectural constraint
**Severity:** Medium

For the MVP, Vibe uses its built-in Bash, file, edit, and search tools. VibeApp observes tool activity and answers permission requests, but does not provide ACP filesystem or terminal capabilities.

**Impact**

VibeApp does not directly mediate every byte read, written, or emitted by a shell through client-hosted capability APIs. Isolation depends on the process directory, worktree, sandboxing available to Vibe, and permission flow.

**MVP mitigation**

- Launch every runtime with an explicit directory and minimal environment.
- Render every tool call and route every permission request to the correct thread.
- Keep credentials out of Git and unrelated subprocess environments.
- Add client-hosted filesystem or terminal capabilities only if VibeApp later needs to become the execution host.

## Risks requiring validation

### VACP-101: Cancellation during a running tool

**Status:** Needs validation
**Severity if confirmed:** High

Verify whether `session/cancel` promptly interrupts long-running shell tools, what terminal response is returned, and whether late tool and session updates continue after cancellation.

**Required test:** Start a deterministic long-running tool, cancel it, and assert process lifetime, child-process cleanup, stop reason, late updates, and permission resolution.

### VACP-102: Concurrent processes sharing Vibe storage

**Status:** Needs validation
**Severity if confirmed:** High

VibeApp intentionally runs several `vibe-acp` processes. Confirm that concurrent session writes, history loading, authentication reads, and shared configuration reads do not corrupt or lose data.

**Required test:** Run prompts in at least four processes, repeatedly load their sessions, then verify complete and isolated histories. Exercise a configuration change separately because VibeApp serializes that operation.

### VACP-103: Sign-out while thread runtimes are alive

**Status:** Needs validation
**Severity if confirmed:** High

Confirm whether warm processes retain usable in-memory credentials after global sign-out and how expired authentication is reported during a prompt.

**Required test:** Authenticate, start multiple runtimes, sign out through the auth process, then attempt another prompt in each runtime and inspect errors and credential state.

**Required VibeApp behavior regardless of result:** Terminate all warm thread runtimes after sign-out and require authentication before restarting them.

### VACP-104: Session loading after a worktree moves or disappears

**Status:** Needs validation
**Severity if confirmed:** Medium

Confirm the error behavior when a persisted session is loaded with a missing, relocated, or mismatched working directory.

**Required test:** Create a session in a worktree, terminate the runtime, remove or relocate the worktree, and attempt `session/load` with both the old and replacement paths.

### VACP-105: Compatibility across supported Vibe versions

**Status:** Needs validation, ongoing
**Severity if confirmed:** High

VibeApp depends on core ACP behavior plus Vibe-specific authentication and configuration details. Capability negotiation alone may not expose every behavioral change.

**Required test:** Maintain an opt-in compatibility suite covering initialization, authentication, new/load session, replay, prompts, tools, permissions, cancellation, configuration, and multiple simultaneous processes.

## Release gate

Before supporting a new Vibe version:

1. Run the live compatibility suite.
2. Re-check all confirmed constraints against the new source and observed behavior.
3. Resolve or explicitly accept every high-severity validation risk.
4. Update this register's reference version and changed dispositions.
5. Do not remove an app mitigation based only on a version number or release note.

## Issue summary

| ID | Topic | Status | MVP disposition |
|---|---|---|---|
| VACP-001 | Process-global working directory | Confirmed | One process per active thread |
| VACP-002 | Shared model/thinking configuration | Confirmed | App-wide settings |
| VACP-003 | Process-bound delegated auth | Confirmed | Dedicated persistent auth process |
| VACP-004 | Vibe-specific auth extensions | Confirmed | Isolate in Vibe adapter |
| VACP-005 | Replay before load response | Confirmed | Register reducer before load |
| VACP-006 | Vibe-hosted filesystem and shell tools | Confirmed | Explicit cwd, permissions, isolation |
| VACP-101 | Tool cancellation semantics | Needs validation | Live integration test |
| VACP-102 | Concurrent shared-storage access | Needs validation | Stress test four processes |
| VACP-103 | Sign-out and warm runtimes | Needs validation | Terminate runtimes on sign-out |
| VACP-104 | Missing or moved worktree | Needs validation | Recovery-path test |
| VACP-105 | Version compatibility | Needs validation | Per-version compatibility suite |
