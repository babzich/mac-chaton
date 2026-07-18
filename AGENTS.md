# LeChaton Contributor Guidance

LeChaton is a native macOS client for Mistral Vibe ACP. The hackathon implementation is defined in `docs/hackathon-plan.md`; long-term product and technical direction remains in the other specifications under `docs/`.

## Architecture Decisions

Read the matching ADR before making architecture-affecting changes. Accepted ADRs are binding within their declared scope; proposed, superseded, and rejected ADRs are not. If a requested change conflicts with an accepted ADR, flag it before implementation.

| Change area | Required guidance |
| --- | --- |
| Architecture principles, boundaries, or adding abstractions | [0001 Architecture Principles](docs/adr/0001-architecture-principles.md) |
| Targets, delivery surfaces, or dependency direction | [0002 Core And Delivery Surfaces](docs/adr/0002-core-and-delivery-surfaces.md) |
| State ownership, actors, streaming, permissions, cancellation, or runtime replacement | [0003 State And Concurrency Ownership](docs/adr/0003-state-and-concurrency-ownership.md) |
| ACP, Vibe, Git, credentials, subprocesses, trust, or compatibility | [0004 External Integration Boundaries](docs/adr/0004-external-integration-boundaries.md) |
| Tuist, build/run workflow, tests, validation gates, or compatibility evidence | [0005 Project Generation And Validation](docs/adr/0005-project-generation-and-validation.md) |
| Persistence ownership, migrations, durable metadata, session restoration, or database recovery | [0006 Persistence And Session Restoration](docs/adr/0006-persistence-and-session-restoration.md) |
| Creating or changing a durable architecture rule | Use `$write-lechaton-adr` from `.agents/skills/write-lechaton-adr/` |

## Build And Validation

- Use Mise to run the pinned Tuist version.
- Use `script/build_and_run.sh` as the canonical local launch path once it exists.
- Keep default tests deterministic and offline; run the live ACP probe only when explicitly validating Vibe compatibility.
- Never edit generated Xcode projects or commit generated projects, workspaces, or Tuist artifacts.

## Git

- Use Conventional Commits with focused scopes and imperative subjects.
- Keep unrelated changes in separate commits.
