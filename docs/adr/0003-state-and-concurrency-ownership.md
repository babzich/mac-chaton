# 0003 State And Concurrency Ownership

Status: Accepted
Date: 2026-07-18
Scope: Repository-wide session state, concurrency, and runtime lifecycle

## Decision

`SessionModel` is the app-level source of observable session state. `ACPTransport` serializes mutable protocol and process state through actor isolation. `SessionReducer` transforms protocol events synchronously without I/O or concurrency.

The transport receive loop remains active while prompts, outgoing requests, and human permission decisions are pending. Permission replies are delivered asynchronously with their original JSON-RPC IDs.

`SessionModel` coordinates cancellation: it makes the state transition idempotent, starts the cancellation deadline, and resolves each pending permission decision once. `ACPTransport` performs the wire and process work: it writes cancellation and permission responses, owns and fails pending RPC continuations, and terminates the process tree when required. `SessionReducer` applies the resulting local turn and tool state.

Replacing a runtime is atomic from the UI's perspective: dispose of all state owned by the previous runtime before publishing the replacement.

## Rationale

Incoming permission requests can arrive while an outgoing prompt remains unresolved. Blocking protocol input on UI interaction would prevent the client from receiving progress or the response needed to finish the prompt.

Named coordination and execution owners prevent duplicate cancellation, leaked continuations, and UI state that outlives the runtime that produced it.

## Agent Guidance

- Publish incoming work without awaiting human interaction inside the transport loop.
- Keep cancellation coordination in `SessionModel` and process/RPC cleanup in `ACPTransport`.
- Guard state transitions, permission responses, and continuation completion against duplicates.
- Fail transport continuations before releasing process state.
- Replace runtime-owned observable state as one coordinated operation.

## Flag To User When

- A scene or view would own session or process lifetime independently of `SessionModel`.
- Cancellation coordination would be implemented in more than one component.
- Transport would synchronously wait for the main actor to present or resolve UI.
- Reduction would perform asynchronous work or own a continuation.
- State produced by a disposed runtime could remain visible after replacement.
