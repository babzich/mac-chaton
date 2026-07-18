# 0001 Architecture Principles

Status: Accepted
Date: 2026-07-18
Scope: Repository-wide architecture and dependency boundaries

## Decision

LeChaton uses explicit ownership for state and side effects. Three boundaries are mandatory:

- `ACPTransport` is an actor that owns child processes and protocol I/O.
- `SessionReducer` is a synchronous, deterministic reducer with no I/O or UI dependency.
- `SessionModel` is app-owned, isolated to `@MainActor`, and owns user actions and published application state.

Views do not parse ACP or retain RPC continuations. Transport code does not publish SwiftUI state or merge conversation content. Reducers do not perform asynchronous work.

Add an abstraction only when it owns a side effect, protects an external boundary, enforces an independent invariant, or enables a real substitute in tests. A type that only forwards calls or renames another abstraction is not a useful boundary.

## Rationale

LeChaton must remain responsive while protocol input, prompts, and permission decisions overlap. A monolithic client would mix process lifetime, protocol correlation, state reduction, and UI publication, making deadlocks and state duplication likely.

The three mandatory seams make transport testable with a fake process, reduction testable without concurrency, and UI behavior testable without launching Vibe.

## Agent Guidance

- Extend an existing owner when the new behavior shares its state and lifetime.
- Split large files without inventing a new architectural layer when ownership is unchanged.
- Keep protocol and platform models separate from observable UI models.
- Make dependency direction visible and avoid cycles between actors and the main actor.

## Flag To User When

- A view would need to parse ACP, retain a continuation, or own a process handle.
- Transport would need to import SwiftUI or mutate observable UI state.
- Reduction would require an actor, filesystem access, a clock, or asynchronous work.
- Two components would both own cancellation, runtime state, or the same derived UI state.
- A proposed layer has no independent state, side effect, invariant, or substitutable implementation.
