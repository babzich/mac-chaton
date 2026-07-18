# 0006 Persistence And Session Restoration

Status: Accepted
Date: 2026-07-18
Scope: Durable application metadata, database ownership, and restoration of saved Vibe sessions

## Decision

`PersistenceStore` is the sole owner of LeChaton's local relational store, migrations, and durable metadata transactions. Callers use typed operations and never receive a database connection or execute raw queries.

Vibe's session storage remains the transcript authority. LeChaton persists the minimum metadata required to identify a project, locate a saved Vibe session, reconstruct its execution environment, and restore the user's selection. Conversation content, reducer output, plans, tool state, permissions, trust decisions, credentials, authentication payloads, and Vibe configuration values are not application database records.

Application launch restores metadata without launching Vibe. Resuming a saved Thread is explicit: create a fresh runtime, load the stored Vibe session into unpublished staging state, and publish it only after the current runtime generation has successfully completed replay. A failed load preserves saved metadata and never silently creates a replacement session.

Schema evolution begins with the first store version and preserves forward-compatible project and Thread relationships. Product restrictions such as exposing only one saved Thread are enforced by typed store transactions rather than irreversible schema cardinality.

Database recovery preserves evidence. Destructive local-metadata reset must close every store owner and move the existing database and its sidecars to a recoverable backup before creating a new store.

## Rationale

The app needs enough durable state to resume work after a restart without creating a second transcript authority or retaining sensitive runtime data. A single store owner makes migrations, selection changes, Thread replacement, and recovery atomic and testable.

Metadata-only launch prevents authentication or agent processes from starting unexpectedly. Staged replay prevents partial or stale history from becoming visible, while retaining metadata on failure keeps recovery under user control.

Keeping the relational model plural avoids blocking the long-term multi-project design even though the first prototype intentionally exposes one saved Thread.

## Agent Guidance

- Add durable fields only when they are app-owned metadata needed across launches; leave Vibe-owned history and global configuration in Vibe.
- Route every read, write, migration, and replacement through `PersistenceStore` typed APIs.
- Restore metadata first and require an explicit Resume action before launching or loading a session runtime.
- Stage replay under the current runtime generation and publish only after its complete replay barrier succeeds.
- Preserve saved metadata when runtime validation, authentication, trust, or `session/load` fails.
- Dispose old runtime-owned state according to ADR 0003 before publishing restored or replacement state.
- Back up the complete database storage unit before recoverable reset; never silently delete the only forensic copy.

## Flag To User When

- A change would make LeChaton, rather than Vibe, authoritative for transcript or plan content.
- Credentials, authentication payloads, trust decisions, permission state, or Vibe configuration would enter the application database.
- App launch or metadata inspection would implicitly start or resume a Vibe runtime.
- A failed load would create a new session, publish partial replay, or discard the saved session identifier.
- A schema restriction would prevent future multiple projects or Threads solely to enforce the prototype's one-Thread UI.
- Reset or migration recovery could destroy the only recoverable copy of local metadata.
