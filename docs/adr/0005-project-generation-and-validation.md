# 0005 Project Generation And Validation

Status: Accepted
Date: 2026-07-18
Scope: Repository-wide project generation, local run workflow, and validation strategy

## Decision

LeChaton generates its Xcode project with Tuist pinned through Mise. Generated projects, workspaces, and Tuist build artifacts are not committed. Source uses Swift language mode 6 with the installed Xcode toolchain.

`script/build_and_run.sh` is the canonical local kill, build, and run entry point. Other local run actions delegate to it rather than maintaining separate command sequences.

Validation uses complementary layers:

- Pure tests cover deterministic state transitions.
- Fake-process tests cover transport and lifecycle behavior.
- Temporary repositories cover Git integration behavior.
- An opt-in live probe validates assumptions against a supported Vibe version.

Live evidence is required before LeChaton declares compatibility with a Vibe version; deterministic tests remain the default development gate.

## Rationale

Pinned generation keeps project definition reproducible without treating generated Xcode files as source. One run entry point prevents local development and app actions from drifting.

Fast deterministic tests find most regressions without credentials or network access. A separate live probe establishes behavioral compatibility that fake protocol fixtures cannot prove.

## Agent Guidance

- Change Tuist manifests rather than generated Xcode files.
- Keep default tests offline and independent of live credentials.
- Use fakes for deterministic protocol states and the live probe for compatibility claims.
- Route local launch actions through the canonical script.
- Record implementation sequencing and demo acceptance outside this ADR.

## Flag To User When

- A build dependency or tool would remain unpinned.
- A second build or launch workflow would bypass the canonical script.
- Default tests would require internet access, live Vibe usage, or user credentials.
- Compatibility would be claimed without evidence from the live probe.
