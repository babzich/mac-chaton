# 0002 Core And Delivery Surfaces

Status: Accepted
Date: 2026-07-18
Scope: Repository target graph and delivery-surface boundaries

## Decision

LeChaton is organized around one reusable core and explicit delivery surfaces:

- `LeChatonCore` contains UI-independent domain and integration logic.
- `LeChaton` adapts the core into a native SwiftUI application.
- `ACPProbe` exercises the same core against a live Vibe process.
- `FakeACPAgent` provides deterministic ACP behavior at the process boundary.
- `LeChatonTests` verifies core behavior and integration boundaries.

Dependencies point toward `LeChatonCore`; the core never imports app or test targets. Add a target only when it represents a distinct delivery surface, executable, or dependency boundary.

## Rationale

The app, probe, and tests must validate the same transport and session behavior. A surface-neutral core prevents protocol behavior from being duplicated and keeps SwiftUI concerns outside portable logic.

Targets are architectural boundaries rather than folders. Creating a target without a distinct dependency direction increases build and ownership complexity without improving isolation.

## Agent Guidance

- Put reusable protocol, runtime, reduction, and external-adapter behavior in `LeChatonCore`.
- Keep native presentation and interaction in `LeChaton`.
- Reuse core entry points from `ACPProbe`; do not duplicate ACP handling in the executable.
- Keep fakes at an external boundary rather than branching production logic for tests.
- Prefer source-file organization over a new target when dependency direction is unchanged.

## Flag To User When

- Core logic would need to import SwiftUI, AppKit presentation code, or a test target.
- A delivery surface or test requires a second implementation of production behavior.
- A new target has no distinct executable, dependency boundary, or ownership purpose.
- Dependencies would point from the core into an outer delivery surface.
