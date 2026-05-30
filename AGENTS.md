# FloatyMPV Agent Rules

This file is the workflow contract for the repository. Follow it before making code changes.

## Source Of Truth

- `README.md` defines the project goals and build order.
- `AGENTS.md` defines the required development flow and engineering constraints.
- `agents/*.md` define the scope of each workstream.
- If a request conflicts with a higher-level doc, follow the higher-level doc.

## Non-Negotiable Flow

1. Pick one workstream only.
2. Read the project README and the active agent file before editing code.
3. Define the smallest shippable change for that workstream.
4. Keep the implementation inside the owning boundary.
5. Build, run, and verify before expanding scope.
6. Do not start the next workstream until the current one is stable.

## Code Organization Rules

- `ContentView.swift` is composition, not a dumping ground.
- Window setup belongs in window-specific types.
- Gesture state and gesture math belong in gesture-specific types.
- Shared constants and reusable helpers belong in focused utility types, not copied into multiple views.
- If a file grows because it owns more than one responsibility, split it before adding more behavior.

## Engineering Rules

### SOLID

- One type, one reason to change.
- Keep public surface area narrow.
- Prefer small protocols or dedicated types over large grab-bag objects.
- Depend on clear boundaries, not incidental implementation details.

### DRY

- Do not duplicate gesture state transitions, window configuration, or frame math.
- If the same conditional or numeric rule appears twice, centralize it.
- Log once at the decision point, not in every branch.

### KISS

- Choose the simplest implementation that satisfies the current milestone.
- Avoid premature abstraction.
- Avoid combining gesture recognition, window mutation, and view composition in the same file unless the file is genuinely tiny.
- Prefer explicit code over clever code.

## Gesture Flow Rules

- Gesture handling must be deterministic.
- Trackpad and mouse behavior must be separated if they have different lifecycles.
- State changes should be modeled explicitly, not inferred from scattered flags.
- Any cursor hide/show logic must be symmetrical and deinitialized safely.
- Any pinch, drag, or snap behavior must have a single owner.

## Logging Rules

- Add logs only where runtime behavior matters.
- Logs must identify the subsystem and the state transition.
- Remove temporary logs once the behavior is understood and stable.
- Do not add noisy per-frame logging unless it is required for debugging.

## Review Checklist

- Does this change stay inside the active agent scope?
- Does it reduce or increase file complexity?
- Did we introduce duplicated state or duplicated math?
- Can this be simplified without losing behavior?
- Is the code still readable after one pass?

## Stop Conditions

Stop and split the work if any of these become true:

- A single file owns UI composition, window control, and gesture logic.
- A type is growing by adding unrelated branches.
- A change requires hidden coupling to make the current implementation work.
- The milestone needs more than one behavior change to stay understandable.

## Current Priority

- Keep the window prototype stable.
- Move gesture-specific behavior out of `ContentView.swift` as soon as the next code change touches it.
- Preserve clean buildability after every change.

