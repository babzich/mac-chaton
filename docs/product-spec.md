# VibeApp Product Specification

**Status:** Draft v0.2
**Date:** 2026-07-18
**Platform:** macOS 26.0 or later
**Architecture:** Apple Silicon only

Implementation details live in the [Technical Specification](./technical-spec.md).

## 1. Product summary

VibeApp is a native macOS application for running and supervising Mistral Vibe coding threads across local projects.

It gives developers one place to:

- Sign into Mistral.
- Manage projects and Vibe threads.
- Run independent threads in parallel.
- Follow plans, messages, and tool activity.
- Approve or reject sensitive operations.
- Review file changes and Git diffs.
- Isolate same-project parallel work with Git worktrees.

The product should feel like a native agent workspace rather than a terminal emulator.

## 2. Product goals

- A fresh user can install VibeApp, authenticate, select a repository, and start a thread without opening Terminal.
- Users can maintain multiple projects and multiple threads per project.
- Threads in different projects can run concurrently.
- Threads in the same project can run concurrently without overwriting one another.
- Every agent action is visible and attributable to its thread.
- Permissions and cancellation remain under user control.
- Threads can be resumed after the app or agent process exits.
- Agent failures are isolated and recoverable.

## 3. MVP non-goals

- Intel Mac support.
- A full embedded code editor.
- A general-purpose built-in terminal.
- Automatic merging between threads.
- Automatic Local-to-Worktree or Worktree-to-Local handoff.
- Copying uncommitted Local changes into new worktrees.
- Bundling the Python or Vibe runtime.
- Vibe cloud sessions or teleport support.
- Mac App Store distribution.
- Mobile or non-macOS clients.

## 4. Target user and core use cases

The primary user is a developer working across one or more local Git repositories who wants a visual interface for supervising Vibe agents and parallel work.

Core use cases:

1. Sign into a Mistral account from VibeApp.
2. Start a Vibe thread in a local repository.
3. Resume a previously saved thread.
4. Run tasks in different projects simultaneously.
5. Run independent tasks in the same project using worktrees.
6. Review and approve file or shell operations.
7. Inspect changed files and diffs after a turn.
8. Cancel one thread without affecting others.

## 5. Terminology

| Term | Meaning |
|---|---|
| Project | A local folder, normally the root of a Git repository |
| Thread | A persisted Vibe conversation |
| Turn | One user prompt and the agent work that follows |
| Local | The user's original project checkout |
| Worktree | A separate Git checkout dedicated to a thread |
| Active thread | A thread with a running turn or warm runtime |
| Idle thread | A persisted thread without a running agent process |
| Tool call | An agent operation such as reading, editing, searching, or executing |
| Permission request | A decision VibeApp asks the user to make before an operation proceeds |

## 6. User experience

### 6.1 Main layout

```text
+------------------+--------------------------+---------------------+
| Projects/Threads | Conversation             | Activity/Changes    |
|                  |                          |                     |
| Project A        | User and agent messages  | Plan                |
|  - Thread 1      | Streaming output         | Tool calls          |
|  - Thread 2      | Composer                 | Changed files       |
| Project B        |                          | Git diff            |
+------------------+--------------------------+---------------------+
```

The activity inspector may be collapsed.

### 6.2 Thread states

Each thread displays one of:

- Idle
- Starting
- Loading history
- Queued
- Running
- Awaiting approval
- Cancelling
- Failed
- Completed with unread changes

### 6.3 New thread flow

The user selects:

- A project.
- Local or Worktree execution.
- A starting branch or commit for Worktree execution.
- An initial prompt.

If another Local thread is already active for the project, VibeApp recommends Worktree execution and prevents a second Local turn from starting concurrently.

### 6.4 Composer

The composer provides:

- Send while idle.
- Stop while running.
- Queue status when the concurrency limit is reached.
- Attachments supported by the connected Vibe version.
- Per-thread agent mode selection when supported.
- The effective app-wide model and thinking level.

## 7. Product requirements

### 7.1 Authentication

- **P0:** Authenticate without opening Terminal.
- **P0:** Support delegated Mistral browser authentication.
- **P0:** Support manual API-key entry through macOS Keychain.
- **P0:** Detect and reuse an existing Vibe authentication.
- **P0:** Display authentication status and support sign out.
- **P0:** Never expose credentials in logs, app databases, or preferences.
- **P1:** Support additional configured Vibe providers dynamically.

### 7.2 Projects

- **P0:** Add a project with a native folder picker.
- **P0:** Detect whether it belongs to a Git repository.
- **P0:** Persist recent projects and their order.
- **P0:** Open a project in Finder or the preferred editor.
- **P1:** Detect relocated repositories.
- **P1:** Treat permanent worktrees as projects.

### 7.3 Threads

- **P0:** Create multiple threads per project.
- **P0:** Resume threads after app restart.
- **P0:** Rename and archive threads.
- **P0:** Run threads in different projects concurrently.
- **P0:** Run same-project threads concurrently in separate worktrees.
- **P1:** Fork a thread when supported by Vibe.
- **P1:** Import existing Vibe sessions.
- **P2:** Delete Vibe's persisted session data.

### 7.4 Conversation and activity

- **P0:** Render user and agent messages incrementally.
- **P0:** Display plans and progress.
- **P0:** Display tool calls with pending, running, completed, and failed states.
- **P0:** Render Markdown and code blocks.
- **P0:** Cancel an active turn.
- **P1:** Support image prompts when Vibe advertises support.
- **P1:** Display token and usage information.

### 7.5 Permissions

- **P0:** Show permission requests from the correct thread and tool call.
- **P0:** Display every choice supplied by Vibe.
- **P0:** Block the operation until a choice is returned.
- **P0:** Cancel unresolved requests when their turn is cancelled.
- **P1:** Allow narrowly scoped automatic decisions configured by the user.

### 7.6 Git changes

- **P0:** Show status after each completed turn.
- **P0:** List changed, added, deleted, and untracked files.
- **P0:** Display read-only unified diffs.
- **P0:** Refresh changes on demand.
- **P1:** Stage files or hunks.
- **P1:** Create commits and worktree branches.
- **P2:** Move a thread and its work between Local and Worktree.

## 8. Parallel work

### 8.1 Local execution

Only one Local thread may be active per project in the MVP. A second thread must wait or use a worktree.

### 8.2 Worktree execution

Each concurrent same-project thread receives a dedicated Git worktree:

```text
Project A
|- Local checkout
|- Worktree for Thread A
|- Worktree for Thread B
`- Worktree for Thread C
```

Worktrees prevent live file overwrites. They do not eliminate future Git merge conflicts.

### 8.3 Global concurrency

The default maximum is four running turns. Additional turns are queued in submission order.

Worktrees do not isolate ports, Docker resources, local databases, simulators, global caches, or user-level configuration. VibeApp should warn when these resources may conflict.

## 9. Worktree product behavior

- A Worktree thread starts from a committed branch or ref.
- Uncommitted Local changes are not copied in the MVP.
- A dirty Local checkout produces a warning before worktree creation.
- A worktree remains associated with its thread.
- VibeApp never removes a dirty worktree automatically.
- Removing a dirty worktree offers Create Branch, Open, Export Patch, or Cancel.

Automatic cleanup is deferred until snapshot and restoration behavior exists.

## 10. Settings semantics

Vibe currently stores some options globally even though ACP presents them alongside a session.

| Setting | VibeApp behavior |
|---|---|
| Agent mode | Per thread |
| Maximum turns | Per thread |
| Maximum tokens | Per thread |
| Model | App-wide |
| Thinking level | App-wide |
| Provider and authentication | App-wide |

Model and thinking controls live in App Settings. Thread headers display their effective values. A change waits for active turns to finish and applies consistently to subsequently started or resumed runtimes.

## 11. Security promises

- Browser authentication credentials are persisted by Vibe.
- Manually entered API keys are stored only in macOS Keychain.
- Credentials never enter Git subprocesses, SQLite, `UserDefaults`, or diagnostics.
- Destructive and persistent permission choices are not approved automatically by default.
- Worktree cleanup never silently discards changes.
- Sign out invalidates warm thread runtimes.

ACP permissions are user-policy interactions, not an OS security sandbox.

## 12. MVP acceptance criteria

The MVP is complete when:

1. A fresh user can sign in without opening Terminal.
2. Manual API keys are stored only in Keychain.
3. Signing out invalidates all thread runtimes.
4. The app runs on macOS 26 and ships Apple Silicon-only.
5. Users can add multiple projects and threads.
6. Threads in different projects can run simultaneously.
7. Same-project threads can run simultaneously in separate worktrees.
8. A second Local thread is blocked or redirected to Worktree mode.
9. Streaming messages and tool activity render correctly.
10. Permission requests block execution until answered.
11. Cancelling one thread leaves other threads running.
12. Threads can be restored after app restart.
13. File changes and unified diffs are visible after a turn.
14. A process crash is isolated to one thread.
15. Dirty worktrees cannot be removed without preserving or explicitly handling their changes.
16. No thread executes relative-path operations in another thread's directory.
17. All threads display the effective app-wide model and thinking level.
18. Agent mode remains independently selectable per thread when supported.

## 13. Delivery phases

### Phase 0: Protocol and authentication validation

Validate process launch, ACP initialization, authentication, session creation/loading, streaming, permissions, and cancellation from Swift.

### Phase 1: Single-thread desktop shell

Build onboarding, project selection, one Local thread, conversation UI, activity, permissions, and cancellation.

### Phase 2: Persistence and multiple projects

Add thread persistence, session loading, multiple projects, isolated thread runtimes, and a global queue.

### Phase 3: Worktree parallelism

Add worktree creation, same-project parallel execution, Git status, diffs, safe cleanup, and branch creation.

### Phase 4: Release hardening

Complete accessibility, diagnostics, crash recovery, signing, notarization, and automatic updates.

## 14. Product defaults

| Decision | Default |
|---|---|
| Authentication | Fully handled by VibeApp |
| Deployment target | macOS 26.0 or later |
| CPU architecture | Apple Silicon only |
| Maximum simultaneous turns | Four |
| Warm runtime timeout | Ten minutes |
| Local concurrency | One active thread per project |
| Same-project parallelism | Dedicated worktree per thread |
| Worktree starting state | Committed branch or ref |
| Vibe dependency | User-installed for MVP |
| Distribution | Signed and notarized direct download |
| Transcript authority | Vibe session storage |
| Agent mode | Per thread |
| Model and thinking | App-wide |
| Manual API-key storage | macOS Keychain |
| Browser credential storage | Managed by Vibe |
| Telemetry | Opt-in and separate from Vibe telemetry |
