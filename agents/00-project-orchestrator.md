# Project Orchestrator

## Purpose

Keep the implementation sequence aligned with the product goal: a native-feeling PiP window that is stable before it becomes feature-rich.

## Owns

- Scope control
- Phase ordering
- Cross-cutting technical decisions
- Definition of done for each workstream

## Rules

- Do not start with playback before window behavior is stable.
- Prefer AppKit primitives over SwiftUI for window control.
- Keep each workstream small and testable.
- Preserve a low-level escape hatch for future rendering and gesture issues.

## Current milestone

Establish the app skeleton and window prototype without adding playback complexity.

