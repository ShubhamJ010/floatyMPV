# Agent Map

These agent files define the initial workstreams for FloatyMPV.

The binding workflow rules live in [`../AGENTS.md`](../AGENTS.md). Read that first.

## Agents

- [`00-project-orchestrator.md`](./00-project-orchestrator.md): keeps scope, sequencing, and cross-cutting decisions aligned
- [`01-window-mechanics.md`](./01-window-mechanics.md): owns the floating `NSWindow` prototype
- [`02-gestures.md`](./02-gestures.md): owns direct trackpad and mouse interaction
- [`03-snap-engine.md`](./03-snap-engine.md): owns magnetic snapping and screen edge behavior
- [`04-playback-mpv.md`](./04-playback-mpv.md): owns `libmpv` integration and playback state
- [`05-rendering-metal.md`](./05-rendering-metal.md): owns Metal-backed rendering and resize behavior
- [`06-overlay-ui.md`](./06-overlay-ui.md): owns controls, hover states, and overlays

## How to use these

Each agent file should stay narrowly scoped:

- one owner
- one responsibility
- one set of success criteria
- one current milestone
- one clear exit point

That keeps implementation order aligned with the project plan and avoids mixing windowing, rendering, and playback concerns too early.

## Development Flow

Use this flow for the full project. Do not skip steps:

1. Pick one agent/workstream only.
2. Read `README.md`, `AGENTS.md`, and the active agent file before editing code.
3. Define the smallest working milestone for that phase.
4. Identify the owning file or type before writing code.
5. Implement the feature with logs for the key lifecycle points.
6. Build locally and fix compile issues before moving on.
7. Verify behavior in Xcode or the app runtime.
8. Share logs back into the next iteration so the next phase starts from real runtime behavior.
9. Only then move to the next agent/workstream.

Rules of this flow:

- Keep changes isolated to the active phase.
- Prefer working prototypes over broad unfinished foundations.
- Split files when a file starts owning more than one responsibility.
- Add logging whenever runtime behavior matters.
- Treat build failures and runtime crashes as part of the phase, not as separate cleanup work.
- Default to SOLID, DRY, and KISS. If a change violates one of those, simplify before merging.
