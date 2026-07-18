# 0004 External Integration Boundaries

Status: Accepted
Date: 2026-07-18
Scope: Repository-wide protocol, vendor, credential, Git, and subprocess boundaries

## Decision

Standard ACP behavior remains independent of Vibe-specific extensions. `VibeAdapter` is the durable boundary for executable discovery, compatibility diagnostics, authentication extensions, repository trust, and Vibe-specific metadata.

The current implementation may split that boundary into `VibeLocator` and stateless `VibeExtensions`. A future `AuthCoordinator` may own user-facing authentication policy and lifecycle, but Vibe wire behavior remains behind `VibeAdapter`.

Vibe-managed browser credentials are persisted entirely by Vibe; LeChaton never receives, stores, inspects, or logs them. If app-managed manual API keys are implemented, LeChaton receives them only transiently, stores them in an app-specific Keychain item, and injects them only into the Vibe process that needs them.

Git access remains behind an adapter with an explicit mutation policy. Every external command uses an absolute executable, an explicit working directory, and an argument array rather than shell interpolation.

The owner of a child process owns its complete lifecycle, including descendants. Terminating only the immediate parent is not sufficient. Compatibility is established through negotiated ACP capabilities and an opt-in live integration gate.

## Rationale

ACP is a portable protocol, while executable discovery, authentication, trust, and metadata are Vibe-specific and may change independently. Keeping those details at an adapter boundary limits compatibility changes and preserves defensive protocol models.

External processes and repositories are side-effect boundaries. Explicit invocation, bounded observation, and complete cleanup reduce the risk of path injection, leaked credentials, orphaned tools, and unbounded output.

## Agent Guidance

- Keep vendor extension payloads out of generic ACP domain types.
- Treat `VibeLocator` and `VibeExtensions` as components of `VibeAdapter`, not competing owners.
- Keep authentication flow policy separate from Vibe-specific wire payloads.
- Never inspect Vibe-managed browser credential persistence or pass authentication values to Git.
- Require an explicit policy before exposing a Git mutation through the adapter.
- Track and terminate verified descendant processes without signaling LeChaton's own process group.

## Flag To User When

- Generic ACP code would depend on a Vibe method, version, or metadata shape.
- A command would be built through shell interpolation or inherit an implicit working directory.
- Vibe-specific behavior would bypass `VibeAdapter` or leak into generic ACP models.
- A Vibe-managed browser credential would enter LeChaton, or an app-managed key would bypass Keychain.
- A child process could outlive its owning runtime.
- A new external side effect has no explicit adapter or mutation policy.
