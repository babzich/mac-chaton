# LeChaton Documentation

## Specifications

- [Hackathon Build Plan](./hackathon-plan.md) - implementation source of truth for the current single-session build.
- [Product Specification](./product-spec.md) - long-term product goals and behavior.
- [Technical Specification](./technical-spec.md) - long-term architecture and implementation direction.
- [Vibe ACP Issues](./vibe-acp-issues.md) - confirmed upstream constraints and validation risks.

## Compatibility Evidence

- [Vibe 2.21.0 Live Gate](./compatibility/vibe-2.21.0-live-gate.md) - sanitized evidence for replay ordering, configuration restoration, and descendant cleanup.

## Architecture Decisions

ADRs contain durable, agent-facing boundaries. Implementation constants, wire details, and demo procedures remain in the specifications.

The product specification owns user-facing requirements. Accepted ADRs govern architecture within their stated scope. The technical and hackathon specifications own implementation details and sequencing. A conflict between these authorities must be reconciled before implementation rather than resolved implicitly.

Every ADR declares a date, scope, and lifecycle status:

- **Proposed:** under discussion and not binding.
- **Accepted:** binding within its declared scope.
- **Superseded:** replaced by a newer ADR and retained for history.
- **Rejected:** considered but not adopted.

| Change area | ADR |
| --- | --- |
| Architecture principles and adding abstractions | [0001 Architecture Principles](./adr/0001-architecture-principles.md) |
| Project targets, delivery surfaces, and dependency direction | [0002 Core And Delivery Surfaces](./adr/0002-core-and-delivery-surfaces.md) |
| State, concurrency, cancellation, and runtime ownership | [0003 State And Concurrency Ownership](./adr/0003-state-and-concurrency-ownership.md) |
| ACP, Vibe, providers, API keys, Vibe configuration, Git, subprocesses, trust, and compatibility | [0004 External Integration Boundaries](./adr/0004-external-integration-boundaries.md) |
| Tuist, build/run workflow, and validation strategy | [0005 Project Generation And Validation](./adr/0005-project-generation-and-validation.md) |
| Persistence ownership, migrations, durable metadata, session restoration, and database recovery | [0006 Persistence And Session Restoration](./adr/0006-persistence-and-session-restoration.md) |

Use the repository-local Codex skill `$write-lechaton-adr` to create or update an ADR and register it in both indexes.
