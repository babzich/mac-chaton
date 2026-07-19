# 0004 External Integration Boundaries

Status: Accepted
Date: 2026-07-19
Scope: Repository-wide protocol, vendor, credential, Git, and subprocess boundaries

## Decision

Standard ACP behavior remains independent of Vibe-specific extensions. `VibeAdapter` is the durable boundary for executable discovery, compatibility diagnostics, authentication extensions, repository trust, Vibe provider configuration, and Vibe-specific metadata.

The current implementation may split that boundary into `VibeLocator` and stateless `VibeExtensions`. A future `AuthCoordinator` may own user-facing authentication policy and lifecycle, but Vibe wire behavior remains behind `VibeAdapter`.

A Vibe identifier returned by `session/new` is provisional. LeChaton treats it as durable only after a user-authored, persistence-producing prompt and a subsequent `session/list` response that contains the exact identifier. LeChaton never sends a hidden prompt or edits a repository file merely to force Vibe session persistence.

Vibe-managed browser credentials are persisted entirely by Vibe; LeChaton never receives, stores, inspects, or logs them. App-managed provider keys are stored only in app-specific, non-synchronizing Keychain items and are explicitly injected after environment sanitization into only the Vibe session, auth-status, executable-validation, or disposable provider-test process that needs them. Vibe configuration contains an environment-variable name, never the secret.

LeChaton may manage OpenAI Chat Completions-compatible provider and model entries in the user-level Vibe configuration. It owns only collision-resistant `lechaton_` identifiers, preserves unrelated configuration semantically, and never edits repository-local Vibe configuration. Provider tests use disposable Vibe-owned ACP runtimes and isolated temporary Vibe homes; LeChaton does not become an inference client.

Git access remains behind an adapter with an explicit mutation policy. Every external command uses an absolute executable, an explicit working directory, and an argument array rather than shell interpolation. Git baseline capture is auxiliary and never blocks session startup or prompting. Pre-existing-path attribution is valid only when capture completes before the first prompt request; a later capture is current-state inspection with unknown attribution until the next Resume.

The owner of a child process owns its complete lifecycle, including descendants. Terminating only the immediate parent is not sufficient. Compatibility is established through negotiated ACP capabilities and an opt-in live integration gate.

## Rationale

ACP is a portable protocol, while executable discovery, authentication, trust, and metadata are Vibe-specific and may change independently. Keeping those details at an adapter boundary limits compatibility changes and preserves defensive protocol models.

Vibe 2.21.0 can return a new session identifier before it creates durable session storage. Explicit confirmation prevents LeChaton metadata from pointing at an empty, unavailable Vibe session without creating hidden agent activity.

External processes, credentials, configuration files, and repositories are side-effect boundaries. Explicit invocation, stale-write detection, recoverable replacement, bounded observation, and complete cleanup reduce the risk of path injection, leaked credentials, lost configuration, orphaned tools, and unbounded output. A Git status command racing the first prompt cannot prove which dirty paths predated that prompt, so late observation must not imply attribution.

## Agent Guidance

- Keep vendor extension payloads out of generic ACP domain types.
- Treat `VibeLocator` and `VibeExtensions` as components of `VibeAdapter`, not competing owners.
- Keep provisional session creation and exact `session/list` durability confirmation behind the Vibe boundary.
- Never generate hidden agent work or repository mutations to make a Vibe session durable.
- Keep authentication flow policy separate from Vibe-specific wire payloads.
- Never inspect Vibe-managed browser credential persistence or pass authentication values to Git.
- Keep provider configuration and provider tests behind the Vibe boundary; never call a model endpoint directly from LeChaton.
- Preserve unrelated user Vibe configuration, reject managed-identifier collisions and stale edits, and make a recoverable backup before atomically replacing the user configuration.
- Keep app-managed keys out of observable shared state, SQLite, TOML, logs, diagnostics, errors, and process arguments.
- Require an explicit policy before exposing a Git mutation through the adapter.
- Keep Git capture failures non-fatal to the session and suppress pre-existing attribution for captures that finish after prompting starts.
- Track and terminate verified descendant processes without signaling LeChaton's own process group.

## Flag To User When

- Generic ACP code would depend on a Vibe method, version, or metadata shape.
- A new or replacement Thread would be persisted before Vibe confirms the exact session identifier through `session/list`.
- Session persistence would require an invisible prompt or a synthetic repository edit.
- A command would be built through shell interpolation or inherit an implicit working directory.
- Vibe-specific behavior would bypass `VibeAdapter` or leak into generic ACP models.
- A Vibe-managed browser credential would enter LeChaton, or an app-managed key would bypass Keychain.
- LeChaton would call a provider inference endpoint directly, edit repository-local Vibe configuration, overwrite an external config edit, or expose a provider key outside its specific Vibe process.
- Git availability would block prompting, or a post-prompt snapshot would be labeled as pre-existing state.
- A child process could outlive its owning runtime.
- A new external side effect has no explicit adapter or mutation policy.
