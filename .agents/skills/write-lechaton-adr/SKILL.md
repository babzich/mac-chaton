---
name: write-lechaton-adr
description: Create or update LeChaton Architecture Decision Records and register them in AGENTS.md. Use when a design discussion establishes or changes a durable architecture, tooling, state-ownership, concurrency, runtime, or external-integration rule.
---

# Write LeChaton ADR

LeChaton ADRs are concise, agent-facing architecture rules in `docs/adr/`. Write or update the record and register it in both `AGENTS.md` and `docs/README.md` in the same change.

## Workflow

1. Confirm the decision is broad, durable, and not already enforced by code, tests, or linting.
2. Read the ADR routing table and every existing ADR that overlaps the change.
3. Update an existing ADR when the decision belongs to its boundary. Create one ADR only when the decision is independently cohesive.
4. For a new ADR, inspect `docs/adr/` and use the next four-digit sequential number in a lowercase hyphenated filename.
5. Write the ADR with the required metadata and format below. Use `Proposed` unless the decision has already been explicitly accepted. Keep it directive, agent-facing, and approximately 20-60 lines.
6. Add or update a concrete change-area trigger in the Architecture Decisions table in `AGENTS.md`.
7. Add or update the ADR entry in `docs/README.md` and verify every link.
8. Check the hackathon and technical specifications for contradictions. Keep implementation constants and procedures there rather than duplicating them in the ADR.

## ADR Format

```markdown
# 000N Decision Title

Status: Proposed
Date: YYYY-MM-DD
Scope: The repository area and decisions governed by this ADR

## Decision

State the durable boundary, rule, or direction.

## Rationale

Explain the ambiguity, tradeoff, or failure mode that makes the decision necessary.

## Agent Guidance

- Give concrete instructions for changing code within the decision.

## Flag To User When

- Name situations where the requested change conflicts with or expands the decision.
```

Use `Proposed`, `Accepted`, `Superseded`, or `Rejected`. When superseding a record, mark the old ADR `Superseded`, link the replacement in its Decision section, and update both routing tables. Do not add consequences or alternatives headings; express that context inside the four required sections.

## Existing ADRs

- `0001` - architecture principles and abstraction boundaries.
- `0002` - core targets and delivery surfaces.
- `0003` - state, concurrency, cancellation, and runtime ownership.
- `0004` - ACP, Vibe, Git, credentials, and subprocess boundaries.
- `0005` - Tuist, build/run workflow, and validation strategy.

## Do Not Create An ADR For

- One-off constants, command flags, filenames, paths, timeouts, or output limits.
- Formatting, naming, or behavior already enforced by tooling.
- Hackathon sequencing, estimates, demo scripts, or temporary implementation notes.
- Deferred features that are not entering implementation.
- A rule already covered by an existing ADR; update or reference that ADR instead.

## Validation

- Ensure the filename number matches the title number and numbering is contiguous.
- Ensure Status, Date, and Scope are present and the lifecycle value is valid.
- Ensure the ADR contains exactly the four required sections.
- Ensure `AGENTS.md` uses a concrete task trigger rather than vague wording such as "when relevant."
- Ensure links resolve and terminology matches the specifications.
- Keep `.agents/skills/write-lechaton-adr/SKILL.md` canonical; do not create a `.vibe/skills` copy.
