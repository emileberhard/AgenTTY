# Keyboard and Input Architecture

Read this when working on the in-app keyboard, key routing, modifiers, repeat behavior, dictation, or clipboard paste.

## Overview

AgenTTY's own key grid is the default input surface, but it is no longer the only one. `KeyboardPresentationPolicy.resolve(idiom:sceneSize:inputMode:isHiddenByUser:)` returns exactly one `KeyboardSurfaceMode` per layout pass, and `AgenTTYMainWindowView` mounts that mode's content into the bottom safe area via `.safeAreaInset(edge: .bottom)`:

| Mode | Bottom inset | Terminal input source |
|------|--------------|-----------------------|
| `.customGrid` | `InAppKeyboardView` | AgenTTY key grid → `TerminalInputRouter` |
| `.systemKeyboard` | `KeyboardHiddenShelfView` | iOS software keyboard → `UIKeyInput` on `TerminalSurfaceViewIOS` → `handleHardwareKey` |
| `.hidden` | `KeyboardHiddenShelfView` | hardware keyboard via `pressesBegan`, or nothing |

Resolution order is deliberate: iPad landscape is `.hidden` unconditionally (the Magic Keyboard path, decided from scene shape because a full-screen iPad reports regular/regular in both orientations), then a user-initiated hide wins, then the persisted `KeyboardInputMode` picks grid vs system keyboard.

`KeyboardInputMode` (`Common/Config/KeyboardInputMode.swift`) is app-group-persisted under `keyboardInputMode`, defaults to `.custom`, and is exposed as the Settings row **Keyboard Style** with the two options *AgenTTY Keyboard* and *System Keyboard*.

Hiding is transient, not persisted: `KeyboardState.isKeyboardHidden` is toggled by the floating glass chevron button the app shell keeps above the top-right of the keyboard/shelf (see `ios-surface-and-touch.md`) or by the top-left menu's `Show Keyboard`/`Hide Keyboard` item. There is no hide key inside the key grid. The grid animates in and out like the system keyboard — a bounce-free spring scoped to the inset content in `AgenTTYApp.swift` drives the grid's `.move` transition while the terminal snaps to final size in one resize rather than animating its layout per frame (see `ios-surface-and-touch.md`), applied immediately under Reduce Motion.

## Input Flow

```
Key press → KeyboardKeyButton (SwiftUI)
  → KeyboardState (modifier/shift/layer state)
  → TerminalInputRouter.handleKeyAction(action, keyboardState)
    → mode-aware byte encoding (parity baseline + optional shortcut overrides)
    → TerminalInputSink.sendTerminalBytes([UInt8])
      → TerminalBridge.sendRawBytes → SSHClientSession.send
```

All keyboard input bypasses Ghostty's keyboard pipeline and goes directly to SSH as raw bytes.

## TerminalInputSink Protocol

Five routes implemented by `TerminalSurfaceViewIOS`:
- `sendTerminalBytes(_ bytes:)` — direct bytes to SSH
- `insertDictationText(_ text:, fallbackBytes:)` — tmux-aware text insertion with byte fallback
- `insertClipboardText(_ text:, fallbackBytes:)` — clipboard text paste via tmux
- `insertClipboardImages(_ imagePayloads:, fallbackBytes:)` — concurrent image uploads via SSH exec + one bracketed-paste event per successful remote path, emitted in clipboard order and paced by 500 ms between multi-image path events
- `insertClipboardFiles(_ filePayloads:, fallbackBytes:)` — sequential streamed file uploads via SSH exec + one space-separated bracketed paste containing the successful remote paths
- `captureDictationShellContext(maxLines:) async -> String?` — tmux tail capture for LLM context

## Key Models (`KeyboardModels.swift`)

- `KeyAction` — enum: `.character(String)`, `.backspace`, `.enter`, `.space`, `.shift`, `.ctrl`, `.alt`, `.dictation`, `.directionPad`, `.arrowUp/Down/Left/Right`, `.escape`, `.tab`, `.symbolLayer`
- `KeyDefinition` — `(id, action, label, widthWeight, style)` where style is `character | modifier | action | space`
- `ModifierKey` — `.shift`, `.ctrl`, `.alt` with associated `ModifierPolicy`
- `KeyboardLayer` — `.letters`, `.symbols`
- `ShiftState` — `.lowercase`, `.shifted`, `.capsLock`

## Layouts (`KeyboardLayouts.swift`)

Static tables define key rows for each layer.

**Letters layer** (5 rows): modifier/nav row, `qwertyuiop`, `asdfghjkl`, shift + `zxcvbnm` + backspace, `#+=` + dictation + space + `.` + enter.

**Symbols layer** (5 rows): `1234567890`, `-/:;()$&@"`, `[]{}#%^*+=`, `_\|<>,!?'` + 1.5-weight backspace, `abc` + dictation + space + backtick + enter.

The symbols layer deliberately mirrors the native iOS symbols keyboard's shape — full digit row, three symbol rows, `abc` bottom-left — so users find the characters where muscle memory expects them. AgenTTY's divergence from the native set is only in *which* symbols occupy those slots: shell-relevant characters (`$`, `&`, `|`, `\`, `<`, `>`, `^`, backtick) replace prose punctuation the native layout spends slots on (`•`, `¥`, `€`, `£`, `…`). Row 4's trailing backspace at `widthWeight: 1.5` matches the native symbols keyboard's wide backspace.

Top row (letters) has eight compact modifier/navigation keys: esc, ctrl, alt, tab, d-pad, `-`, `~`, `/`.

## Modifier Behavior

Centralized in `KeyboardState` (`@Observable`):

- **Shift**: tap toggles shifted/lowercase. Slide up while holding arms caps lock; caps lock commits on release. Sliding back down before release cancels.
- **Ctrl/Alt**: tap unlocks when currently locked; otherwise tap does not arm one-shot. Slide up while holding arms locked state; lock commits on release. Sliding back down before release cancels.
- **Hold**: any modifier stays active for the full touch duration and consumes if a chord key was pressed.
- **Modifier slide-chord**: while holding Shift/Ctrl/Alt, drag across another key and lift on the modifier key to emit the held-modifier chord for that target (for example Ctrl→C).
- Slide-chord target set is intentionally strict: characters, backspace, enter, tab, and escape. Spacebar and modifier keys are not slide-chord targets.
- A floating glass chord-preview capsule activates after a slide-chord target is first hovered and then stays visible until modifier release (fixed prefix like `⌃ +`, dynamic target suffix). Its X-position is centered over the held modifier key and clamped so the capsule always stays fully on-screen with at least 5pt left/right margin.
- Holding a modifier briefly shows white guidance hints: lock+arrow-up above the key for lock gesture and held-modifier-symbol+plus with arrow-down below the key for chord gesture.
- While sliding up, the lock hint scales and brightens with stronger white glow as lock-arm progress increases.
- During the lock-zone gesture (finger still inside the held modifier key or above it), slide-chord targeting is suppressed so neighboring keys cannot steal the gesture.
- Modifier-hint rows are temporarily elevated in z-order while a modifier is held so hints render above adjacent rows (for example Shift hints over the A-row). The elevation read is isolated in the per-row `KeyRowDepthWrapper`, so modifier hold/release does not force the grid to rebuild every key.
- Keyboard row/key depth roles are centralized in `VisualLayering` and consumed by `KeyboardKeyGridView`, `KeyboardKeyButton`, and `KeyboardDirectionalPadButton` instead of ad-hoc z-index literals.
- When multiple modifier-hint rows are elevated at once, lower rows get the higher z-order within that elevated band so their upward hints never render underneath the rows above during multi-touch interaction.
- Character key callouts render directly in the pressed key's local overlay. `KeyboardState.activeKeyCallouts` only coordinates row elevation for upward overflow and simultaneous touches; it does not transport geometry or render the callout. This removes the broad `anchorPreference`/`overlayPreferenceValue` dependency chain and repeated preference collection from the press path. Callout lifetime is deliberately trivial: visible while the finger is down, gone instantly on lift (`.transition(.identity)` plus a nil-animation transaction). Emil explicitly rejected both a post-release linger and a scale/fade exit animation — keep it instant.
- Keys use an iOS 18+ `UIGestureRecognizerRepresentable` backed by a tiny continuous UIKit recognizer rather than SwiftUI's `DragGesture`. Physical-device capture showed the window receiving touches promptly while `DragGesture.onChanged` waited roughly 90ms on upper keys and more than 350ms on a lower key; a second finger released both immediately. The custom recognizer forwards its raw `touchesBegan` before recognizer arbitration, reducing the measured gap between the window observer and `beginPress` to roughly 0.1–0.5ms while preserving move/end/cancel handling for modifiers and the spacebar. Raw touches are carried in global coordinates because the recognizer's UIKit view is not guaranteed to share the SwiftUI key's geometry; `UIGestureRecognizerRepresentable`'s `CoordinateSpaceConverter` derives key-local locations and translations, while modifier slide-chord hit-testing uses the global point directly against global key frames. Its `cancelsTouchesInView`, `delaysTouchesBegan`, and `delaysTouchesEnded` flags are all disabled.
- The keyboard no longer applies a screen-aligned overflow mask. Upward-extending affordances such as modifier hints, key callouts, the expanded d-pad, and the spacebar quick overlay can render past the keyboard bounds without side clipping, while the floating modifier chord-preview capsule still clamps itself to stay on-screen horizontally.
- Locked modifiers show a distinctive accent stroke and tiny white lock icon at the top-right corner inside the key.
- `KeyboardState` mutators are idempotent where possible to avoid redundant Observation writes during touch-heavy interactions.
- Key frame reporting for slide-chord targeting is tolerance-gated (~0.5pt) so micro-jitter in geometry updates doesn't trigger unnecessary state churn.
- Live theme switching is an explicit invalidation case: `KeyboardState.visualInvalidationGeneration` is bumped on theme apply and again after the theme sheet dismisses so every key refreshes through the same local keyboard-state dependency path that already handles lifecycle invalidation reliably.

## Byte Encoding (`TerminalInputRouter`, `TerminalParityKeyEncoder`)

Keyboard encoding has two persisted modes (`KeyboardEncodingMode`, app-group-backed in settings):

- **Default (Shortcuts)**: parity baseline plus explicit navigation overrides.
- **Strict Parity**: no overrides; all supported keys use parity sequences.

Shared parity behavior (both modes):
- Modified arrows use xterm/PC-style modifier CSI sequences (for example `Alt+Up` → `ESC[1;3A`), so modified arrows no longer emit double-escape payloads.
- Tab/Enter/Backspace/Escape use modifier-aware parity encodings (including `Alt+Tab`, `Ctrl+Enter`, `Ctrl+Backspace`, etc).
- `Ctrl+Space` encodes `NUL` (`0x00`), and `Alt+Ctrl+Space` encodes `ESC NUL`.
- Character keys use ctrl-byte conversion where applicable, with optional `Alt` escape prefix.

Default-only overrides:
- `Alt+Left/Right` → `ESC b` / `ESC f` (word jump).
- `Ctrl+Left/Right` → `^A` / `^E` (line start/end).
- `Ctrl+Backspace` → `^U` (delete to start-of-line).
- `Ctrl+V` uses async clipboard paste integration with precedence `images` → `files` → `text` → raw fallback. AgenTTY keeps provider `jpeg`/`png` image data as-is, normalizes unsupported image formats like `heic` to `jpeg`, resolves multiple image providers concurrently, uploads them concurrently, and emits successful image paths as separate bracketed paste events in clipboard order, pacing multi-image batches by 500 ms between path events so clients that collapse rapid successive pastes still treat each image separately. If no image payload resolves but copied file items are present, AgenTTY loads provider file representations, copies them into app-owned temp storage, uploads them sequentially with streamed SSH writes, and pastes the successful remote paths back as one space-separated bracketed paste string.

Strict parity differences:
- The override list above is disabled.
- `Ctrl+V` sends raw `0x16` (no clipboard interception).

## Hardware Keyboard

iPad in landscape hides the virtual keyboard and routes input from a connected
hardware keyboard (Magic Keyboard, etc.) through a parallel pipeline that
reuses the existing byte encoder. iPhone participates too, but only when it has
a reason to: `TerminalSurfaceViewIOS.shouldOwnKeyboardFocus` claims first
responder on iPad unconditionally, and on iPhone only when the system keyboard
is the active surface or `GCKeyboard.coalesced` reports an attached physical
keyboard. `GCKeyboardDidConnect`/`GCKeyboardDidDisconnect` re-evaluate that
gate, so plugging a keyboard in mid-session starts routing without a relaunch.
The default iPhone key-grid path never claims first responder at all.

```
UIPress / UIKey → TerminalSurfaceViewIOS.pressesBegan
  → HardwareKeyMapping.map(_:) → (KeyAction, Set<ModifierKey>)
  → TerminalInputRouter.handleHardwareKey(action:modifiers:)
    → TerminalParityKeyEncoder (same encoder as the virtual keyboard)
    → TerminalInputSink.sendTerminalBytes
```

`HardwareKeyMapping` translates `UIKey.keyCode` for the non-printable set
(Return, Backspace, Escape, Tab, Spacebar, four arrows) and falls through to
`KeyAction.character(key.characters)` for everything else. Modifier flags map
1:1 (`shift`, `control`, `alternate`); Caps Lock (`alphaShift`) is ignored
because it is already reflected in `key.characters`. Cmd-modified key events
return `nil` from the mapper so they fall through to UIKit, which lets
standard system Cmd-chords keep working. The two Cmd shortcuts the surface
claims are Cmd+V via `keyCommands` bound to `#selector(paste(_:))`, which
delegates to the same async `pasteClipboardContent()` path as touch-paste,
honoring the images → files → text precedence, and Cmd+Backspace, which the
mapper normalizes to the same `.backspace` + `.ctrl` route as Ctrl+Backspace
so it sends the existing line-delete payload.
One printable-key exception is intentionally normalized before byte encoding:
on Nordic iPad Magic Keyboard layouts, iPadOS reports Shift+`4` as `€`; AgenTTY
maps that specific `.keyboard4`/Shift/`€` event to `$` so terminal typing matches
the expected shell shortcut layout.

`TerminalInputRouter.handleHardwareKey(action:modifiers:)` deliberately
bypasses `KeyboardState`. Slide-chord arming, one-shot consumption, and
shift-state are virtual-keyboard concepts; hardware events arrive with
explicit `UIKey.modifierFlags`. The router uses `isUppercase: false` when
calling `TerminalParityKeyEncoder.encodeCharacter(_:isUppercase:modifiers:)`
because `UIKey.characters` already delivers the cased glyph.

Hardware keys whose `KeyAction` has `repeatBehavior` use `KeyboardRepeatEngine`
so held Backspace, arrows, Space, and similar keys repeat with the same timing
profile as the virtual keyboard. Key-up/cancel stops the active repeat, while
unhandled key-up events continue through `super`.

First-responder lifecycle:
- `TerminalSurfaceViewIOS.didMoveToWindow` claims FR on attach when `shouldOwnKeyboardFocus` allows it.
- A static weak `lastAttachedSurface` registry plus `claimFirstResponderForActiveSurface()` lets `AgenTTYMainWindowView`'s `keyboardSurfaceMode` `onChange` and every `.sheet` `onDismiss` re-claim FR after sheets that took focus into a `UITextField`.
- `updateSystemKeyboardActive(_:)` flows down from `GhosttyTerminalViewIOS` on every layout pass; a change runs `refreshKeyboardFocus()`, which becomes/resigns first responder or calls `reloadInputViews()` when the surface already holds it.
- `willMove(toWindow: nil)` clears the registry slot so detached surfaces don't keep handing out FR.

## System Keyboard (`KeyboardInputMode.system`)

The terminal surface conforms to `UIKeyInput` so the iOS software keyboard can
target it. There is no local text buffer: `hasText` is always `false`,
`insertText(_:)` forwards each character straight into
`handleHardwareKey(action:modifiers:)` (translating `\n`/`\r` to `.enter` so the
existing enter encoding is used rather than a raw `0x0A`), and
`deleteBackward()` maps to `.backspace`. That means the system keyboard reuses
the hardware pipeline and its encoder, not a second one.

Two suppressions keep it from misbehaving:
- `inputView` returns a zero-size `suppressedSoftwareInputView` whenever
  `systemKeyboardIsActive` is false, so a surface holding first responder for
  hardware keys does not also raise the software keyboard.
- The full `UITextInputTraits` set is overridden to `.no`/`.none` — autocorrect,
  autocapitalization, spell checking, smart quotes, smart dashes, smart
  insert/delete, inline prediction, and Writing Tools. Each would rewrite shell
  input (smart quotes break quoting, smart dashes break `--flag`,
  autocapitalization breaks `ls`). They are declared `@objc` because
  `UITextInputTraits` declares them as `@objc optional`, and UIKit's
  `respondsToSelector` probe would otherwise fall back to the defaults.
- `inputAssistantItem` bar button groups are cleared so iPadOS does not offer a
  shortcuts bar for a view with no editable text.

Because `KeyboardHiddenShelfView` is the bottom inset in this mode, the shell
dots and dir/branch chips stay visible under the system keyboard; the shelf is
`allowsHitTesting(false)` and only its gradient ignores the bottom safe area.
Dictation in this mode is the system keyboard's own microphone key, not
AgenTTY's — which is why the floating dictation status badge is shown for every
non-`.customGrid` mode (there is no in-key recording indicator to rely on).

## Repeat Engine (`KeyboardRepeatEngine`)

Timer-based, uses `RunLoop.main.add(timer, forMode: .common)` so timers fire during UIKit touch tracking.

- Character keys: fixed repeat (450ms initial, 65ms interval).
- Backspace: accelerated (250ms initial, 14 reps/sec base, exponential ramp over 10s to 140 reps/sec peak).
- D-pad: distance-scaled tiers with acceleration curve. Spacebar: no repeat (hold reserved for spacebar overlays).

## D-Pad (`KeyboardDirectionalPadButton`)

Radial direction detection with three speed tiers based on pull distance. Shows stacked chevrons (1/2/3) per tier. Idle key uses the outlined `dpad` symbol. Each arrow emission fires a per-step haptic tick. While d-pad is active, cursor style is temporarily switched to steady block via injected DECSCUSR sequences.

## Spacebar Shell Switcher

Long-press on spacebar presents the shell quick switcher (`SpacebarQuickShellOverlay`) with one glass card per tmux shell. Card titles use AI-generated shell titles when available; otherwise they fall back to the tmux working-directory path, abbreviated to `~` for conventional home-directory paths and head-truncated so the trailing path stays visible. If no shells exist, the long-press is ignored.

Switching shells needs a live transport, so the overlay is gated on `KeyboardKeyRenderInput.isHostInteractionAvailable`, fed from `TerminalInputRouter.hostConnectionPhase.allowsHostInteraction` (see `ios-surface-and-touch.md`). While the host is not connected the long-press does not open the switcher, an already-open switcher closes itself the moment the phase flips, and card selection is refused even if a touch is mid-flight.
Spacebar quick overlays are conditionally mounted only while visible. There is no keyboard overflow mask anymore, so the overlay simply renders above the keyboard when active.

Spacebar typing uses pending-press coordination: the press is tracked immediately, then emitted on release unless another non-space output key is pressed first. Interleaved key-down flushes the pending space first so rapid overlap preserves tap order.

The quick switcher always appends one extra trailing create-shell placeholder card with a centered plus symbol. Releasing on this card creates a new tmux shell and jumps to it.
Both that explicit create action and the forward-swipe-at-end auto-create path default to starting the new shell in the rightmost shell's working directory. Settings can disable the reuse behavior and fall back to HOME, and invalid/missing reused paths also fall back to HOME.

When a new shell is created by a right-swipe at the end of the shell list, the quick switcher can show an optimistic provisional shell card immediately (internal provisional window ID). This prevents transient "missing newest shell" states before canonical tmux `window_id` data arrives. Provisional cards use fallback titles and are not navigable until canonicalized.

Spacebar center label mirrors `ShellIndicatorState.activeShellTitle` (up to two lines, word-balanced split).
When the active shell changes, the center label uses a direction-aware slide transition derived from shell-state position updates: moving forward exits left and enters from the right; moving backward mirrors that.
During horizontal shell swipe gestures, the center label no longer tracks every drag tick. It stays stable during the gesture, then performs settle/commit transitions when the swipe cancels or commits.
When `AGENTTY_ENABLE_SHELL_TITLE_AI=0`, `activeShellTitle` is held empty so no shell title text is shown on the spacebar.

## Dictation System

Toggle flow: tap dictation key to start recording, tap again to stop and transcribe.

The bottom-row dictation key uses the same width weight as the symbol-layer and Enter keys on both letter and symbol layouts, keeping the microphone target prominent without changing the row's total width.

**Recording**: Batch and streaming models share one `AVAudioEngine` microphone tap. When the user enables **WisprClone Library** in Settings, `AgenTTYDictationLibrary` reads the account-fenced shared profile and resolves an immutable `.terminal` plan against this flavor's capabilities. The public relay remains the main flavor's only capability. Unsupported shared preferences remain unchanged and Settings shows the effective fallback. Terminal plans disable prose cleanup and translation.

Before starting the microphone, the companion creates a stable capture manifest and configures its native-rate PCM journal. The tap appends microphone buffers to that journal before provider-rate conversion. On stop, the companion seals its original to 48 kHz mono Opus CAF. Converted PCM also goes to SpeechKit's bounded provider recording cache, and, for streaming models, `RealtimeDictation`. Discarding that derived provider recording never authorizes deleting an archived original. Both paths retain the existing `.playAndRecord` + `.spokenAudio` session, built-in microphone preference, and interruption/route pause and resume behavior. A failed resume finalizes the captured prefix with a failure result.

Library sharing is opt-in in every flavor and defaults off. A confirmed absent/disabled shared profile creates no archive. If an opted-in refresh cannot verify the account/profile, ordinary dictation uses local defaults and the companion retains a held original without adopting it into a later account. Account transitions cancel active dictation before insertion; the companion fences publication. Failed and cancelled dictations retain their originals and independent failure results. The app owns a 512 MiB durable library limit in Application Support; it reports failures without evicting unpublished originals or disabling ordinary dictation. Provider recordings remain independently disposable. Foreground activation and completed results retry pending publication. Library failures and model fallback are visible in Settings; failures to save a capture/result also surface through the dictation alert.

**Transcription models**:
- Main/TestFlight flavor: fixed MAI-Transcribe-2 progressive upload through SpeechKit's Azure Speech provider and `services/backend/`. The provider uses relay access at `/v1/dictation/azure-speech`; Dev/Exp use router access. Both progressive and batch recovery requests use the same relay and clean transcription style, without custom instructions. Session issuance sends the verified StoreKit AppTransaction JWS and the first verified lifetime entitlement JWS when available. One actor caches the one-hour token, refreshes five minutes early, and drops it after an unauthorized relay rejection. Unsigned local main builds retain legacy issuance for operator-trusted devices. Notification tokens remain separate. The backend owns UTC calendar-month allowances (10 minutes for trial users, 120 minutes with lifetime access), PCM validation and operator budgets (see `docs/backend.md`). No model picker is shown.
- Dev/exp flavors: Settings shows a Provider menu and a Model menu. `AgenTTYDictation.Model` is the catalog of every SpeechKit transcription model: ElevenLabs Scribe v2 (batch) and Scribe v2 Realtime; OpenAI GPT-4o Mini Transcribe, GPT-4o Transcribe, and Whisper (batch) plus GPT Realtime Whisper, GPT-4o Transcribe Realtime, and GPT-4o Mini Transcribe Realtime; Gemini 3.1 Pro and 3.5 Flash (`generateContent` through `EsmaGeminiDictationProvider`, forced `LOW` thinking), Gemini 3.5 Transcribe Smart/Verbatim (batch), and Gemini 3.5 Transcribe Live Smart/Verbatim; AssemblyAI Universal-3.5 Pro (batch and realtime); and Azure MAI-Transcribe-2, which uploads progressively while recording and returns one result on stop. Each model declares its `capture` (batch or streaming) and `promptFormat`. The selection persists under the app-group `dictationProvider` key; the raw values `elevenLabs`, `openai`, and `gemini` from the earlier provider picker select Scribe v2 Realtime, GPT-4o Mini Transcribe, and Gemini 3.1 Pro. ElevenLabs Scribe v2 Realtime is the default.
- Only Gemini `generateContent` models and the OpenAI GPT-4o batch models receive the dictation system prompt and tmux terminal context; every other model gets no instructions, and AgenTTY skips the shell-context capture for them. Gemini Transcribe and Azure MAI reject custom instructions.
- `AgenTTYRealtimeDictation.make` configures the selected model as SpeechKit's provider-neutral `RealtimeTranscriptionSession`: the ElevenLabs, OpenAI, Gemini Live, and AssemblyAI WebSocket sessions, or `ProgressiveRealtimeTranscriptionSession` for the Azure progressive upload. SpeechKit's `RealtimeDictation` owns connection, ordered buffering, final commit, timeout, and cleanup. Only an explicitly finalized transcript is inserted. If `finish()` fails, AgenTTY batch-transcribes the saved provider recording with the compatible batch model and records that actual model identity. Relay rejections and cancellation skip this recovery upload; quota, service limits and capacity refusals must not trigger duplicate requests. It then discards only the provider cache copy. Finished batch uploads respect `TranscriptionEngine.maximumAudioByteCount`; the main-flavor relay additionally enforces its 15-minute request limit. Relay refusals map to dictation alerts, including the next UTC month boundary and the lifetime allowance for trial users. Expected quota/capacity refusals are not sent to Sentry; a free server tier alongside locally unlocked lifetime access leaves a diagnostic breadcrumb.
- Dev/exp builds compile one llm-router key (`AGENTTY_EMBED_AI_KEYS`) from the ignored `AgenTTY/Resources/AgenTTYLocalSecrets.json`. `scripts/sync-local-llm-router-key` runs before every dev/exp install and OTA build and bakes the `agentty` key from `~/.config/llm-router/agentty-ios.key` with the secrets file's `llmRouter.origin`. A worktree without that file first copies the main checkout's. Without the key it leaves the secrets file unchanged; a key without an origin fails the build. Every provider goes through the router, so no provider key is compiled in.

Dictation AI can be disabled at launch with `AGENTTY_ENABLE_DICTATION_AI=0`. In that mode, tapping dictation surfaces an in-app error and no recording/transcription work runs.

Model config is fail-fast: an invalid stored model or a provider without baked keys throws `ConfigurationError`, which surfaces as the dictation alert when recording starts or transcription runs.

**Provenance**: `DictationResultVersion` preserves the returned text before host trimming. Requests with terminal instructions are labelled `contextualOutput`, because the existing explicit development override can produce an answer; they are never labelled literal speech. Unconditioned transcription is `providerOutput`. Only context kind/use is recorded, never terminal scrollback. Model identifiers include provider, native model and transport, with explicit verbatim mode where needed. Each result has its own ID under the stable capture ID.

**Insertion**: Tmux-aware path — base64-encode text, one-off SSH exec with `tmux load-buffer` + `tmux paste-buffer -p`, auto-cancel copy-mode. Falls back to raw bytes.

## Haptics

Centralized `AppHaptics` singleton in `KeyboardHaptics.swift`. The cached generators use UIKit's current view-attached initializers and stay prepared during the keyboard's active interactive session; each feedback event prepares its generator again for the next event. The generators are released when the keyboard becomes inactive and recreated/prepared on activation so background time does not keep the Taptic Engine prepared. Typed event API (`.keyTap`, `.keyRepeat`, `.modifierTap`, `.touchSelectionStart`, etc.). Character/modifier keys use the `rigid` impact profile. Normal key taps fire from the custom recognizer's raw touch-down callback before the SSH byte is enqueued. Key press-down visuals apply instantly (the press edge disables the implicit animation); only the release eases with the short snappy animation. Modifier slide-lock uses a dedicated two-phase pattern: arm feedback while sliding up, then confirmation on release (`lead` + delayed stronger impact).

Outbound keyboard bytes are enqueued asynchronously onto `SSHClientSession.stateQueue`. Channel lookup, pending-buffer mutation, and the write remain serialized there, preserving input order without synchronously blocking the MainActor touch/haptic path.

## Bottom Shelf and Safe Area

The keyboard content must stay inside the bottom safe area; only its background gradient bleeds into the home-indicator zone (`.background { gradient.ignoresSafeArea(.container, edges: .bottom) }`). Do NOT apply `ignoresSafeArea(.container, edges: .bottom)` to the keyboard content itself: binaries linked against current SDKs then sink the whole keyboard ~34pt to the physical screen edge, which hides the `ShellIndicatorView` shelf (dir/branch chips + dot cluster) below the display. Older-SDK builds (for example past TestFlight releases) tolerated the content-level ignore, so a same-source TestFlight build rendering correctly does not clear this class of bug.
`InAppKeyboardView` also receives `bottomSafeAreaInset` from the app shell's `GeometryReader` (`AgenTTYMainWindowView`) rather than a `UIApplication` key-window walk; the remaining window walk is used only for screen bounds when clamping the floating chord-preview capsule.

## App Deactivation Safety

`KeyboardState.pressCancellationGeneration` increments on app deactivation, canceling all active key presses/timers. If a character or space was typed within 0.5s before deactivation (home-indicator swipe accident), auto-sends a backspace.

Unmounting `InAppKeyboardView` runs that same deactivation path, so any deliberate unmount must arm `KeyboardState.suppressLifecycleUndo()` first or the user gets a stray backspace. Two callers do: `hideKeyboard()` and the `keyboardInputMode` `onChange` in `AgenTTYiOSApp`. The suppression is a one-shot flag consumed by the next `consumeLifecycleUndoCandidate(within:)`, deliberately not a reliance on the incidental ordering of `executeAction` and `onDisappear`.

## Key Files

| File | Responsibility |
|------|---------------|
| `TerminalInputRouter.swift` | Key routing, byte encoding, dictation recording/transcription orchestration, clipboard paste |
| `AgenTTYRealtimeDictation.swift` | Streaming model selection, fallback provenance, and one native microphone tap with archival-before-provider conversion |
| `AgenTTYDictationLibrary.swift` | Explicit library consent, shared profile/capabilities, account fences, durable originals, result versions, and publication |
| `AgenTTYBatchTranscription.swift` | Batch SpeechKit engine per dictation model plus the Azure Speech configuration |
| `TerminalInputRouterDictationPrompting.swift` | Dictation prompt construction, terminal-context normalization, and provider instruction payload helpers |
| `DictationAudioSessionBoundary.swift` | Dictation audio-session boundary protocol + system AVAudioSession implementation |
| `TerminalParityKeyEncoder.swift` | Parity-oriented key encoding for character and non-character actions |
| `KeyboardEncodingMode.swift` | Persisted keyboard encoding mode (`default_shortcuts` vs `strict_parity`) |
| `KeyboardInputMode.swift` | Persisted keyboard style (`custom` grid vs `system` keyboard) + Settings row copy |
| `KeyboardPresentationPolicy.swift` | Resolves `KeyboardSurfaceMode` from idiom, scene shape, input mode, and user-hidden state |
| `KeyboardHiddenShelfView.swift` | Slim bottom shelf (shell dots + dir/branch chips) mounted for `.systemKeyboard` and `.hidden` |
| `KeyboardModels.swift` | `KeyAction`, `KeyDefinition`, `ModifierKey`, `ModifierPolicy` |
| `KeyboardLayouts.swift` | Static layout tables for letters and symbols layers |
| `KeyboardState.swift` | Modifier state machine (held/one-shot/locked), layer, shift, pending-space ordering state, user-hidden flag + lifecycle-undo suppression, transient keyboard interaction lifecycle, and keyboard-local visual invalidation generation for live theme refresh |
| `KeyboardSlideChordSupport.swift` | Slide-chord target model and shared geometry/preview-label helpers |
| `KeyboardKeyRenderInput.swift` | Immutable per-key render snapshot used to keep `KeyButton` body reads narrow while still carrying explicit lifecycle/theme invalidation generations and `isHostInteractionAvailable` when a full key refresh is required |
| `KeyboardRepeatEngine.swift` | Timer-based repeat with generation-safe cancellation |
| `KeyboardRepeatBehavior.swift` | Fixed and accelerated repeat behaviors |
| `KeyboardHaptics.swift` | `AppHaptics` singleton, typed haptic event API |
| `KeyboardModifierPressLogic.swift` | Modifier hold/tap gesture handling |
| `InAppKeyboardView.swift` | Top-level keyboard SwiftUI view, lifecycle, auto-undo, floating chord-preview capsule |
| `KeyboardKeyGridView.swift` | Grid layout, per-row z-index isolation, and keyboard-wide key-callout overlay composition |
| `KeyboardKeyButton.swift` | Individual key interaction, repeat handling, spacebar title transition state, and stable key-callout anchor publishing |
| `ModifierGestureHintViews.swift` | Modifier gesture hint symbols and visibility modifier views |
| `SpacebarQuickShellOverlay.swift` | Spacebar quick switcher layout + card overlay rendering |
| `KeyPressCallout.swift` | Key press callout bubble shape/view rendering |
| `KeyboardDirectionalPadButton.swift` | D-pad with radial detection and tiered speed |
| `VisualLayering.swift` | Shared keyboard row/key depth policy |
| `EsmaGeminiDictationProvider.swift` | Gemini-specific dictation transcription |

The CloudKit container is supplied by the app build configuration and passed explicitly into SpeechKit. Provider keys and SSH bootstrap data remain optional ignored Dev/Exp input; a missing local router key no longer blocks compilation.
