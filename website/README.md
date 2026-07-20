# Agent Field Manual

A self-contained learning site for mastering coding-agent harnesses, Vibe CLI, ACP, Codex, Pi, and the integration patterns used by LeChaton.

## Run locally

From the repository root:

```sh
python3 -m http.server 4173
```

Then open [http://localhost:4173/website/](http://localhost:4173/website/). Serving the repository root keeps the manual's links to local source files and architecture documents navigable.

The local site has no package dependencies. Lab progress, exam score, and the selected color theme are stored in browser local storage.

## OpenAI Sites

Build and validate the production worker package:

```sh
cd website
npm run build
npm run validate
```

The deployable output is written to `website/dist/` and is linked to the Sites
project by `website/.openai/hosting.json`.

## Content scope

- General harness engineering: context assembly, provider normalization, loop control, tools, policies, events, sessions, compaction, safety, and evals.
- Current product concepts for Vibe, Codex, and Pi, linked to primary sources.
- ACP v1 mental models and an interactive request/notification trace.
- A clearly labeled LeChaton case study based on the repository's exact Vibe 2.21.0 compatibility evidence.

Upstream product behavior changes over time. The LeChaton section deliberately treats `docs/compatibility/vibe-2.21.0-live-gate.md` and `docs/vibe-acp-issues.md` as the source of truth for the pinned integration, rather than projecting current upstream documentation onto the supported version.
