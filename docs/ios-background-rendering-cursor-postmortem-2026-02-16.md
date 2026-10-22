# iOS Background Rendering + Cursor Regression Postmortem

Date: 2026-02-16
Repo: `AgenTTY`
Branch during debugging: `fix-background-metal-warning`

## TL;DR

Two issues appeared related but unstable during iteration:

1. `IOGPUMetalError ... BackgroundExecutionNotPermitted` when app was backgrounded.
2. Cursor rendering regression (non-blinking/static block at wrong cell) often after resume.

The final root cause was an integration bug in our iOS host code: we passed the wrong semantic value to Ghostty's occlusion API.

Ghostty expects `ghostty_surface_set_occlusion(surface, visible)` where argument means **visible**, not **occluded**.

We were passing `occluded` directly, effectively inverted.

Fixing this resolved both problems in testing.

## Symptoms Observed

- Backgrounding app produced repeated Metal GPU permission errors.
- Renderer health toggled unhealthy/healthy around app lifecycle.
- Cursor blink sometimes froze after resume.
- Cursor block sometimes rendered one cell off (covering latest typed character).
- Behavior varied by branch and by specific experimental patch, which made diagnosis noisy.

## What We Tried (and Why Some Attempts Failed)

1. Added app lifecycle gating for render/tick in `GhosttyRuntime`.
Why: stop rendering/ticking while app inactive.
Result: reduced some background activity but did not reliably eliminate GPU warnings and introduced/changed cursor behavior in some runs.

2. Added focus lifecycle updates (`ghostty_app_set_focus`, `ghostty_surface_set_focus`).
Why: keep Ghostty aware of active/inactive state.
Result: necessary but insufficient alone.

3. Added surface occlusion callbacks on iOS lifecycle (`willResignActive`, `didEnterBackground`, `didBecomeActive`).
Why: explicitly inform Ghostty renderer of visibility.
Result: this was the right direction, but initially implemented with inverted meaning, which preserved the bug under some permutations.

4. Added extensive logging (runtime, SSH, terminal, Ghostty actions, wakeup/tick/render counters, env logging).
Why: remove guesswork and identify exact transition behavior.
Result: this enabled the final diagnosis.

## The Key Clue That Unblocked It

From high-verbosity logs we saw lifecycle transitions and rendering behavior precisely around background/foreground.

Then we verified Ghostty API semantics in the embedded API source/header:

- `ghostty_surface_set_occlusion(surface, visible)`
- The parameter is interpreted as **visible**.

Our code path treated it as **occluded** and passed that value directly.

That meant:

- On background, we sent `true` (interpreted by Ghostty as visible).
- On foreground, we sent `false` (interpreted as not visible).

This inversion explains both:

- GPU work attempts in background.
- Broken cursor animation/render state after resume.

## Exact Bug Location

File: `AgenTTY/Sources/iOS/GhosttyTerminalView.swift`

Previous logic conceptually:

- `applySurfaceOcclusion(occluded)`
- `ghostty_surface_set_occlusion(surface, occluded)`

Correct logic:

- `applySurfaceVisibility(visible)`
- `ghostty_surface_set_occlusion(surface, visible)`

## Final Fix Implemented

In `AgenTTY/Sources/iOS/GhosttyTerminalView.swift`:

1. Replaced occlusion-state tracking with visibility-state tracking:
   - `lastOccludedState` -> `lastVisibleState`

2. Replaced helper:
   - `applySurfaceOcclusion(_ occluded: Bool, reason: String)`
   - with `applySurfaceVisibility(_ visible: Bool, reason: String)`

3. Corrected lifecycle calls:
   - `willResignActive` -> `applySurfaceVisibility(false, ...)`
   - `didEnterBackground` -> `applySurfaceVisibility(false, ...)`
   - `didBecomeActive` -> `applySurfaceVisibility(true, ...)`

4. Added initial visibility sync:
   - In `didMoveToWindow` -> `applySurfaceVisibility(window != nil, reason: "didMoveToWindow")`

5. Updated logs to print both values for clarity:
   - `surface visibility=<...> occluded=<...>`

## Why This Fix Works

- Ghostty now receives accurate visibility state during lifecycle transitions.
- Renderer can avoid background GPU submissions when app is not visible.
- On foreground return, renderer and cursor animation pipeline resume in the correct state.

## Was This a Ghostty Core Bug?

No. This was on our side (host integration semantics), not a Ghostty core defect.

Ghostty API behaved consistently; our wrapper semantics were inverted.

## Validation Summary

In latest successful run:

- No `IOGPUMetalError ... BackgroundExecutionNotPermitted` after backgrounding.
- Cursor blink/render behavior remained correct before and after resume.
- Logs showed correct lifecycle semantics:
  - background: `surface visibility=false occluded=true`
  - foreground: `surface visibility=true occluded=false`

## Remaining Non-Blocking Warnings

Still present and unrelated to this bug:

- `NoHomeDir`
- `os_locale ... fallback ... uncertain results`

These are separate environment/locale setup concerns and do not appear causal for the renderer/cursor issue.

## Lessons Learned

1. For embedded/native libraries, verify argument semantics from source/API headers early.
2. Lifecycle bugs can look like renderer bugs; instrumentation must include lifecycle + render/tick/wakeup together.
3. "Looks right" naming (`set_occlusion`) can still hide inverted semantics.
4. Preserve a known-good baseline branch to compare behavior quickly.

## Suggested Follow-Up Cleanup

1. Keep the occlusion/visibility fix as permanent.
2. Keep high-verbosity logging only behind explicit debug env toggles (already partially done).
3. Reduce default log volume before release builds.
4. Optionally open an internal note documenting `ghostty_surface_set_occlusion` semantics to prevent regression.
