# iOS Surface, Touch, and Lifecycle

Read this when working on the terminal surface view, Metal rendering, app lifecycle, touch interactions (scroll/selection/swipe), shell indicators, or the theme system.

## App Entry (`AgenTTYApp.swift`)

SwiftUI `@main` app struct. Creates:
- `GhosttyRuntime` (let, not @State)
- `@State TerminalInputRouter`
- `@State ShellIndicatorState`
- `@State KeyboardState`
- `@State AgenTTYHostStore`
- `@State AgenTTYLifetimeAccessController`

View hierarchy:
```
WindowGroup → GeometryReader → ZStack
  GhosttyTerminalViewIOS          ← terminal surface
    .safeAreaInset(.bottom)       ← InAppKeyboardView | KeyboardHiddenShelfView
                                     (+ floating keyboard toggle in its .overlay(.topTrailing))
    .overlay(.topTrailing)        ← InAppNotificationBanner
    .overlay(.bottomLeading)      ← dictation status badge (non-.customGrid modes)
    .overlay(.top)                ← status bar blackout + TopStatusChromeView
```

Main/TestFlight access is coordinated by `AgenTTYLifetimeAccessController`. It starts at launch, listens to `StoreKit.Transaction.updates`, checks both `Transaction.currentEntitlements(for:)` and `Transaction.latest(for:)` for the non-consumable unlock `dev.tuist.agentty.lifetime_access`, and maintains a 5-hour foreground-usage trial record in Keychain plus mirrored app-group defaults. The v2 usage record stores only `startedAt` and `consumedUsage`, is persisted under new v2 keys so older day-based records are ignored, and counts time only while the app scene is `.active` and the interactive terminal stack is eligible to render. Metering uses `ProcessInfo.processInfo.systemUptime` as the primary elapsed-time source, falls back to wall-clock only if uptime moves backward unexpectedly, checkpoints every 15 seconds while active, and flushes immediately when the scene leaves `.active`.
Production analytics also start from app entry. `AgenTTY-iOS` resolves a verified `AppTransaction.appTransactionID` and, when available, records production-only app-session completions plus access-state, purchase-flow, paywall, and host-setup analytics through the existing relay backend using the install-scoped `device_id` / `device_secret` write path. App-session payloads now also carry coarse session context such as saved-host count, active-host presence, paywall visibility, and completed SSH-session counters. The analytics client allows only one actor-owned flush at a time, treats HTTP 400 validation responses as permanent event-level rejections, splits rejected batches until it can drop only the invalid event, and leaves 500/network failures retryable. Each batch includes coarse per-install device facts (`system_version`, Apple model identifier, device family, locale identifier, preferred languages). `AgenTTY-iOS-Dev`, `AgenTTY-iOS-Exp`, and side-loaded `main` installs that lack a verified app transaction do not emit analytics.

`AgenTTYMainWindowView` conditionally mounts the terminal stack. Initial entitlement resolution is optimistic and never blocks first render: the terminal, keyboard, and top chrome mount immediately while StoreKit resolves in the background. If the local trial is already expired and the first lookup finds no purchase, the controller waits five seconds and checks again before allowing `AgenTTYAccessGateView` to appear; an empty or inconclusive lookup never revokes lifetime access already verified in the process, while an explicit verified revocation does. Once an expired unpaid state is confirmed, `GhosttyTerminalViewIOS`, the keyboard safe-area inset, top chrome, and in-app notification banner unmount behind the full-screen gate. Dev/exp flavors bypass the paywall entirely so side-loaded daily development builds stay usable.

Status bar is hidden (`.statusBar(hidden: true)`). Custom blackout overlay fills the area above the Dynamic Island. `TopStatusChromeView` renders the leading menu button plus clock/battery status on the left lane, host status on the right lane, and reserves the center cutout lane dynamically for notch/Dynamic Island devices; its clock/battery timer state lives in an internal subview so time ticks do not invalidate keyboard state trees.
Because that blackout strip remains solid black, the collapsed top chrome uses a fixed dark-appearance semantic foreground for legibility, while the menu contents themselves still use the active theme-derived foreground colors.
`TopStatusChromeView` exposes host actions: open Hosts sheet, select a specific host from quick picker, or swipe horizontally on the host control to cycle adjacent hosts.
App-shell overlay depth roles are centralized in `VisualLayering`; top status chrome intentionally renders above the in-app notification banner on overlap.

Settings, Tips & Tricks, Themes, Hosts, and Keys are separate sheets and intentionally share the same dimmed terminal presentation background (`AppTheme.terminalBackground.opacity(0.3)`), detents, and overall glass tint language.
`TerminalHostsSheet` now uses the shared add/edit host form for the `Manual Setup`, `Automatic Setup`, and `Password Setup` paths (the last is the renamed one-time-password flow; the enum case is still `HostSetupMethod.oneTimePassword` and the persisted auth mode is still `.passwordBootstrap`, so only user-facing copy changed); automatic pairing can prefill a Tailscale-selected hostname, preferring the short MagicDNS host label over the full `*.tail...ts.net` name when available, and the form runs a short reachability probe before save for every new host plus edited hosts whose address or port changed so unreachable targets surface a warning instead of being silently persisted. Host-field input is normalized before matching, verification, and saving by trimming whitespace/invisible padding and converting common Unicode dash/minus characters to ASCII `-`; when the displayed text changes meaningfully, the form shows an inline note. DNS reachability failures now get DNS-specific copy and recovery suggestions instead of the generic reachability warning, while preserving the explicit save-anyway path. Existing hosts no longer show a setup-method chooser on their detail screen; the editor simply reflects the host's current saved auth mode. When the form is in `Manual Setup`, the selected key's public key is shown in a dedicated export section with inline copy/share controls so the user can add it to the remote host without opening the separate Keys sheet.
`TerminalSSHKeysSheet` keeps the same list/detail structure as the other sheets, and existing-key detail now includes a matching public-key export section that reuses the same ornament-row styling and short-lived inline copied state instead of a separate toast/banner layer. Key import also has a passphrase field: it is optional, and a passphrase-protected `openssh-key-v1` file that arrives without one fails with `privateKeyPassphraseRequired` so the user is told to fill it in rather than being given a generic parse error.

Layout constants are centralized in `enum TerminalLayout` — use these for any overlay alignment.

When library sharing is enabled, app launch and foreground activation retry the companion's own pending dictation publication. `AgenTTYDictationLibrary` retains its status for the Settings row. The input router observes account transitions through capture and transcription so a late result from a changed account cannot be inserted into the terminal.

## Keyboard Surface Mode and iPad Adaptation

`AgenTTYMainWindowView` computes one `KeyboardSurfaceMode` per layout pass via
`KeyboardPresentationPolicy.resolve(idiom:sceneSize:inputMode:isHiddenByUser:)`
and switches on it inside the existing `.safeAreaInset(edge: .bottom)` call:
`.customGrid` mounts `InAppKeyboardView`, while `.systemKeyboard` and `.hidden`
both mount the slim `KeyboardHiddenShelfView` so the shell dots and dir/branch
chips stay on screen. The policy is the only place these inputs combine — do
not re-derive keyboard visibility anywhere else.

iPad landscape resolves to `.hidden` unconditionally and uses the
hardware-keyboard path. That check reads scene shape (`height < width`) rather
than size classes, because full-screen iPads report regular width and regular
height in both orientations. iPad portrait then follows the same rules as
iPhone: user-hidden wins next, otherwise the persisted `KeyboardInputMode`
selects the AgenTTY grid or the iOS software keyboard.

Two overlays are keyed off the same mode. The floating dictation status badge
renders for every non-`.customGrid` mode, because without the key grid there is
no in-key recording indicator. The floating keyboard toggle is one glass button
(`.buttonStyle(.glassProminent)` + `AppTheme.controlGlassTint`) whose label is
the shared `ChromeGlassIconLabel` base from `AppTheme.swift` — the same
component the top-left menu button uses, so both chrome controls keep identical
metrics and the label's `.contentShape(.rect)` (glass enlarges visual bounds
without expanding hit-testing) — mounted in an `.overlay(alignment: .topTrailing)` on the bottom
`safeAreaInset` content and floated above it by a zero-height anchor frame
(`.frame(height: 0, alignment: .bottom)` with inner bottom/trailing padding), so
the button lays out fully above the inset's top edge and hovers over the
terminal without growing the inset. It shows `chevron.down` and
hides the keyboard in `.customGrid`/`.systemKeyboard`, and `chevron.up` +
`showKeyboard()` in `.hidden` — but only while `KeyboardState.isKeyboardHidden`
is set, so an iPad-landscape hide (which the user did not ask for) does not
grow a restore affordance.

Surface-mode changes animate like the system keyboard, with the animation
deliberately scoped away from the terminal: a bounce-free spring
`.animation(_, value: keyboardSurfaceMode)` sits on the Group *inside* the
`safeAreaInset` — wrapping the keyboard/shelf switch — so the grid's
`.transition(.move(edge: .bottom))` plays (a transition only animates inside an
animated transaction; attaching the animation to the transition alone does not
fire on current SDKs), while the outer transaction stays un-animated: the inset
height and the terminal snap to final size in one step (a single
Ghostty/IOSurface/PTY resize) and the grid slides over the already-resized
terminal as a frozen subtree, elevated by
`VisualLayering.AppShell.keyboardSurfaceTransition` while grid and shelf
coexist. Never move that `.animation` outside the `safeAreaInset` — animating
the whole transaction relayouts the Metal surface every frame and produced a
visibly steppy slide on device. The floating chevron button gets its own
`.animation(_, value: keyboardSurfaceMode)` scoped to just the button so it
glides along the same curve instead of teleporting with the snapping inset
anchor. Reduce Motion applies everything immediately (nil animation in both
spots).

Whenever the mode leaves `.customGrid`, an `onChange` handler calls
`TerminalSurfaceViewIOS.claimFirstResponderForActiveSurface()` so hardware
`UIPress` events and the system keyboard reach the surface. Every `.sheet`
declared in `AgenTTYApp.body` also reclaims FR via `onDismiss` (sheets briefly
hand FR to their text fields when the user taps in). See
keyboard-architecture.md for the full hardware-key and `UIKeyInput` pipelines.

`Project.swift` enables iPad — which supports both orientations — through three changes per iOS app target plus one
notification-service-extension change: `TARGETED_DEVICE_FAMILY` is `"1,2"`,
`UIRequiresFullScreen` is omitted (so iPadOS 26 windowing can size the app),
and a new `UISupportedInterfaceOrientations~ipad` key advertises all four
orientations. iPhone keeps its portrait-only `UISupportedInterfaceOrientations`
key untouched.

## Terminal Surface (`TerminalSurfaceViewIOS`)

`UIView` subclass. Conforms to `GhosttySurfaceProvider`, `TerminalInputSink`, and host protocols for lifecycle/scroll/selection/swipe controllers.

**IOSurface rendering**: Ghostty's Metal renderer adds an `IOSurfaceLayer` as a sublayer via `@objc(addSublayer:)` override (not `layerClass`). On resize, `configureIOSurfaceLayers` finds layers named `"IOSurfaceLayer"` and updates frame/contentsScale in a `CATransaction` with actions disabled.

**Sizing flow**: SwiftUI `updateUIView` now prefers `uiView.bounds` as the terminal sizing source (falls back to `GeometryReader` size only when bounds are zero), then calls `sizeDidChange`. `sizeDidChange` always keeps IOSurface layer frames/scales in sync, performs Ghostty resize only when `(widthPx,heightPx,scale)` changes, and deduplicates SSH PTY window updates by a terminal-window signature `(columns,rows,widthPx,heightPx)` so grid changes (for example font-size updates) still propagate immediately.
IOSurface sublayer insertion schedules a coalesced one-tick deferred `sizeDidChange(bounds)` resync. Theme updates run a short multi-pass resync sequence (`same runloop` + `next frame` + `~80ms`) to catch first-switch cold-start layer races without waiting for user scroll interaction.
Because Ghostty applies `ghostty_surface_set_size` on its I/O thread with resize coalescing, the immediate `ghostty_surface_size` read-back after a geometry change can still report the pre-resize grid. Every geometry change therefore schedules generation-guarded verify resync passes (`next frame` + `~80ms` + `~300ms`) that re-read the settled grid; the window-signature dedup makes settled passes free, and without them the SSH PTY rows can stay behind the visible grid, leaving a blank band above the keyboard.
Terminal font-size live actions are forced once when a new surface attaches, then only on actual font-size setting changes; theme changes should not emit redundant `set_font_size` actions.

**Font size**: `applyTerminalFontSize` calls `ghostty_surface_binding_action("set_font_size:<pt>")` then `sizeDidChange(bounds)` (when bounds are non-zero) to re-sync PTY dimensions immediately.

**Host target propagation**: `updateActiveHost(_:)` forwards active host changes to `TerminalBridge.setActiveHost(_:)`, which handles connect/reconnect/disconnect behavior.

## Lifecycle (`TerminalSurfaceLifecycleController`)

Maps app lifecycle to Ghostty API:
- App inactive/background → `ghostty_surface_set_occlusion(surface, false)` — stops Metal submission, prevents `IOGPUMetalError`.
- App active/foreground → `ghostty_surface_set_occlusion(surface, true)` — resumes rendering.
- Focus managed separately via `ghostty_surface_set_focus`.
- On app foreground while attached, lifecycle also sends a synthetic terminal focus refresh pulse (`ESC[O` then `ESC[I`) through `TerminalBridge` so CLI apps that rely on focus transitions refresh immediately. `TerminalBridge` follows this with a targeted same-size PTY window refresh and a targeted two-pass nudge for focus-refresh reasons (`didBecomeActive`, `theme-change`): pass 1 immediately, then a coalesced pass 2 at ~80ms. For `theme-change`, each pass applies `window refresh + render` before the post-pass focus pulse to avoid one-step-late prompt tint updates.

`GhosttyRuntime` also gates `render()` and `tick()` on `appIsActive` to prevent background GPU submissions.

**Connection lifecycle on iOS:** backgrounding starts a ~30s `beginBackgroundTask` warm hold in `TerminalBridge`. When the warm hold expires, AgenTTY ends the background task without explicitly closing SSH and lets iOS suspend the process naturally. On foregrounding, the bridge verifies transport liveness with a short probe instead of trusting the socket, reconnects immediately if the probe fails, and automatically reconnects an active host when no transport remains. Shell polling drops to a 15s cadence while backgrounded.

## Disconnected State

`AgenTTYHostConnectionPhase` (`.disconnected` / `.connecting` / `.connected`) is
published by `TerminalBridge` through `hostConnectionPhaseDidChange`, and
`allowsHostInteraction` (true only for `.connected`) is the **single** gate for
every affordance that needs a live transport. Add new host-dependent UI behind
this property rather than checking phases ad hoc. Current consumers: shell
swipes (`TerminalSurfaceViewIOS.canSwipeShell`) and the keyboard, which threads
it into `KeyboardKeyRenderInput.isHostInteractionAvailable` to gate opening the
spacebar quick switcher, close an open one when the host drops mid-hold, and
refuse card selection.

While AgenTTY is retrying on its own, `TerminalReconnectScreenPresenter` takes
the terminal over. It renders inside Ghostty — a braille spinner, a
`Connecting to <host>` / `Reconnecting to <host>` headline, an
`attempt N · retrying in Ns` detail line, and a dim
`Shell switching is paused until AgenTTY reconnects.` footer — as escape
sequences written locally through the same `injectTerminalOutputLocally` path as
the ASCII onboarding screen. Nothing is sent over SSH.

Behavior worth knowing before changing it:
- **It is not the only disconnected state.** `reconnectScreenPhase` returns nil
  (so the screen stays down) in screenshot mode, when there are no hosts, when
  no host is selected, when a manual `connectionRecoveryRequest` is pending, or
  whenever the phase is not `.connecting`. Manual recovery and permanently
  blocked outcomes keep the recovery alert plus ordinary `[agentty]` lines.
- **0.5s activation delay.** A fast reconnect finishes before the screen ever
  paints, which is why a routine blip does not flash a spinner.
- **It owns the screen while up.** `emitStatusLine` drops `[agentty]` lines to
  the log instead of writing them, because a status line would scroll the
  centered block apart.
- **Layout degrades by row count** (`full` → `compact` → `minimal`) and every
  line is truncated to the column count, so tiny grids still render.
- **Ticking is foreground-only** (`isAnimating: isApplicationActive`) and drops
  to a 1s interval under Reduce Motion. The timer runs in `.common` mode so the
  spinner keeps stepping during touch tracking.
- Steady-state ticks repaint only the spinner and detail rows via absolute
  cursor addressing; a full repaint happens only when columns, rows, or the
  headline change.

## Touch Scroll (`TerminalTouchScrollController`)

One-finger vertical pan scrolling. Installed as `UIPanGestureRecognizer` on the terminal surface.

**Vertical gating**: `gestureRecognizerShouldBegin` requires `abs(velocity.y) >= abs(velocity.x)` so horizontal swipes are reserved for shell navigation.

**Ghostty bypass**: Scrolling bypasses Ghostty entirely. Swift generates SGR mouse wheel escape sequences (`ESC[<64;col;rowM` up, `ESC[<65;col;rowM` down) from clamped in-viewport cell coordinates and sends directly to SSH.

**Pan dispatch**: 60Hz `CADisplayLink` paces pixel-to-line conversion with velocity boost (1.5x base multiplier, low-pass smoothing).

**Momentum**: On pan end, if velocity exceeds threshold, launches inertial scroll via 60Hz display link. Adaptive decay rate, carry-over stacking across consecutive flicks, tap-to-stop cancellation.

## Touch Selection (`TerminalTouchSelectionController`)

Long-press gesture (0.35s threshold). Uses Ghostty's mouse API with `GHOSTTY_MODS_SHIFT` modifier so selection works while tmux mouse mode is enabled.
Touch selection and tap handling now share `TerminalTouchGeometry.clampedSurfacePoint`, so both controllers clamp gesture coordinates to the same interior surface bounds before feeding Ghostty or positioning edit-menu anchors.

On long-press release, the controller anchors `UIEditMenuInteraction` at the touch point (or the selected text anchor when Ghostty reports one). The terminal surface exposes standard responder edit actions so the native menu can show Paste when clipboard content is available, plus Copy / Select All when a selection exists. Paste now uses the same async general-pasteboard resolver as keyboard `Ctrl+V` with precedence `images` → `files` → `text`: image items are loaded through `NSItemProvider`, provider `jpeg`/`png` data is kept as-is, unsupported image formats like `heic` are normalized to `jpeg`, provider payloads resolve concurrently, remote temp image files upload concurrently, and each successful image path is emitted as its own paste event in clipboard order. If no image payload resolves but copied file items are present, AgenTTY loads provider file representations, copies them into app-owned temp storage, uploads them sequentially with streamed SSH writes, and pastes the successful remote paths back as one space-separated bracketed paste string before falling back to text. Tap-while-selected clears selection by sending a normal click (no shift).

## Shell Swipe (`TerminalShellSwipeController`)

Horizontal pan gesture for tmux window navigation.

**Gating**: `abs(velocity.x) > abs(velocity.y)` AND `host.canSwipeShell(direction)` returns true. `canSwipeShell` first requires `bridge?.hostConnectionPhase.allowsHostInteraction == true`, so while the host is gone the pan never begins at all — no snapshot, no mask, no queued tmux command. The check is in `canSwipeShell` rather than in the controller because `endShellSwipePan` re-checks it before committing, which also cancels a swipe whose transport died mid-gesture.

**Commit**: Based on 30% progress or 500pt/s velocity threshold. Committed swipes queue in `TerminalBridge` and drain sequentially.

**Visual**: On commit, snapshot view slides off-screen, mask overlay hides until new terminal data arrives (0.6s timeout). Swipe curtain/snapshot overlays are non-interactive so follow-up swipes can start immediately. UIKit overlay depth is explicit via `VisualLayering.TerminalSurfaceUIKit` (`swipeSnapshot` above `swipeMask`).
The swipe snapshot tracks finger movement in UIKit, while shell-title preview state avoids per-tick Observation writes to reduce SwiftUI invalidation pressure.

**Optimistic state**: `TerminalSurfaceViewIOS` maintains pending optimistic shell states keyed by full window ID lists plus active position (not count/position only). On forward swipe at the shell-list end, it appends a provisional negative window ID so quick switcher cards can show the new shell immediately. Canonical tmux updates are reconciled by shape (count + active position) and ID-list matching, with stale mismatched updates suppressed while optimistic state is pending. `canSwipeShell` uses optimistic prediction so rapid successive swipes are not blocked by stale poll data.

## Shell Indicators (`ShellIndicatorState`, `ShellIndicatorView`)

`ShellIndicatorState` (`@Observable`) bridges tmux window state from `TerminalBridge` (UIKit) via `shellStateDidChange`, `shellTitleDidChange`, `shellWorkingDirectoryDidChange`, and `activeShellContextDidChange`. It tracks canonical tmux `window_id` values plus displayed IDs (which may temporarily include provisional IDs during optimistic shell creation). It also caches per-window shell context (working directory path + git branch/detached SHA) and exposes active-strip labels (`activeWorkingDirectoryLabel`, `activeGitBranchLabel`) for the bottom shelf UI. Quick-switcher cards use AI-generated shell titles when available; agent titles are scheduled after each of the first five completed Claude/Codex turns and then every tenth turn, and persisted under host + tmux-session + provider-session identity so a reused `window_id` cannot inherit another shell's title. Otherwise cards fall back to the per-window working-directory path, abbreviated to `~` for conventional home-directory paths and head-truncated in the card UI so the trailing path remains visible. It appends a dedicated create-shell placeholder card (`windowID = Int.min`) so the quick switcher always exposes one explicit create action; selecting it dispatches `createAndNavigateToNewWindow` through `TerminalBridge.createTmuxWindowAndSelect()`. New shells default to reusing the rightmost shell's working directory, with a Settings toggle to fall back to HOME. It exposes `activeShellTitle` for keyboard UI and relays measured spacebar title character capacity back to bridge for shell-title generation constraints.

`ShellIndicatorView` now renders a three-anchor strip on the keyboard shelf: left active folder label, center shell dots, right branch label. The left and right labels each render as a lightweight outlined capsule chip with an SF Symbol prefix (`folder` and `arrow.triangle.branch`). Horizontal inset keeps chips away from rounded bottom corners, and the center dot zone has fixed width so side chips never overlap dots. Text styling is shared with spacebar shell-title typography through `ShellIndicatorTextStyle`.

The spacebar keeps the directional slide transition for shell navigation. First title appearance and same-shell title replacement instead use a short fade/lift/settle animation scoped to the rendered title state; Reduce Motion bypasses that movement and applies the title immediately.

## Theme System

### Resolution flow
1. `GhosttyRuntime.applyResolvedIOSThemeColors` reads named colors + 256-entry palette from Ghostty config
2. Reads bundled theme file for extra named colors
3. Synthesizes missing semantic colors (selection, cursor)
4. Pushes `GhosttyResolvedTheme` into `AppTheme`

### AppTheme
`@MainActor enum` with static `Palette` holding all derived colors. Keyboard and chrome colors are derived from the Ghostty theme palette (mixing terminal background/foreground with ANSI palette entries). All SwiftUI views consume colors via static `AppTheme` computed properties.
SwiftUI preferred light/dark mode is also derived from the resolved Ghostty theme background luminance, so light terminal themes switch system/sheet presentation into light mode while dark themes keep dark presentation.
Neutral overlay ornaments (sheet row fills, glass borders, keyboard hint borders, quick-switcher card strokes) should use `AppTheme.surfaceOrnamentFill` and `AppTheme.surfaceOrnamentStroke` instead of hard-coded white/black opacity values so they track the active theme/color-scheme.
Small glyphs inside saturated gradient badges (for example settings/host/key leading icons) intentionally use the fixed dark-appearance semantic foreground because those chip backgrounds stay dark enough that adaptive `.primary` weakens contrast in light themes.

Theme selection applies live through `GhosttyRuntime.applyTheme(named:)`. `AppThemeToken` still handles the general theme refresh path: the root scene reads the theme nonce so preferred color-scheme updates reapply immediately, the top status chrome remounts on theme changes so liquid-glass tint refreshes instantly, and keyboard key colors are forced through the keyboard-local dependency graph by bumping `KeyboardState.visualInvalidationGeneration` on theme apply and again after the theme sheet dismisses.
Because the Themes sheet stays presented during theme switches, it also observes `AppThemeToken` directly and threads the theme nonce through its row/content rendering so sheet-local label and row styling refresh immediately instead of waiting for a second invalidation, without resetting sheet scroll state.
The Themes sheet also applies `preferredColorScheme(AppTheme.preferredColorScheme)` inside the sheet content itself, because SwiftUI resolves that modifier against the nearest enclosing presentation; this keeps the live sheet material/chrome in sync when the app flips between dark and light themes.
Theme-change updates additionally send a synthetic terminal focus refresh pulse (`ESC[O` then `ESC[I`), plus a targeted same-size PTY window refresh and a targeted two-pass nudge through `TerminalBridge` (immediate + ~80ms follow-up). For theme updates, pass ordering is `window refresh + render` followed by focus pulse so terminal UIs that re-sample default colors on `FocusGained` do not render one theme behind.

Falls back to `GhosttyResolvedTheme.fallback` if background/foreground cannot be resolved.

### Shared sheet infrastructure (`SheetPresentationComponents.swift`)

All shared sheet components live in `SheetPresentationComponents.swift`. **Always use these; never hand-roll.**

| Component | Purpose |
|-----------|---------|
| `SheetNavigationCoordinator<Route: Hashable>` | `@Observable` coordinator for `[.medium, .large]` sheets. Owns `path`, `selectedDetent`, `pendingRoute`. Call `navigate(to:)` from root-entry buttons and `presentDetail(_:)` when an already-pushed sheet screen needs to expand and push another detail route. |
| `.sheetDetailNavigation(_ coordinator:)` | View modifier. Apply to `NavigationStack`. Handles detent-expand-then-push with 100ms delay (SwiftUI limitation). |
| `SheetDetailMode<T>` | `.add` / `.edit(T)` enum with `isAdd` and `existing` helpers. |
| `SheetPresentation` | `@Observable` app-level booleans: `showSettings`, `showTips`, `showHosts`, `showSSHKeys`, `showThemes`. |
| `esmaTermSheetBackground()` | Dimmed terminal background for `.presentationBackground`. Use on every sheet. |
| `SheetFormFieldRow<Field>` | Standard labeled text-field row for `List` forms. |
| `SheetPickerRow<SelectionValue>` | Standard labeled picker row for `List` forms. |
| `SheetDestructiveActionButton` | Red glass delete button. Use in detail views at `.large` detent. |

**New sheet checklist:**
1. Define a `Route: Hashable` enum (`case add`, `case edit(Item)`).
2. Declare `@State private var nav = SheetNavigationCoordinator<Route>()`.
3. In `body`: add `@Bindable var nav = nav`, bind `NavigationStack(path: $nav.path)`, apply `.presentationDetents([.medium, .large], selection: $nav.selectedDetent)` and `.sheetDetailNavigation(nav)`.
4. All navigation entry points call `nav.navigate(to:)`.
5. Pass `selectedDetent: $nav.selectedDetent` into detail views that show the delete button conditionally.

## Notifications

`AgenTTYAppDelegate` handles push notification permissions, APNs token capture, foreground presentation decisions, and device registration with the notify relay backend. Notification parsing/logging now runs through a shared trace layer used by both the app and the bundled Notification Service Extension targets, so foreground handling, notification taps, and background/locked deliveries all emit the same `attempt_id`-keyed log fields. `TerminalBridge` provisions a base host runtime before the shell attaches, then provisions the notification runtime after SSH is ready by issuing a relay session, detecting the remote host platform, fetching the correct per-platform runtime payload from the public static artifact host at `https://agentty-assets.esmadil.se/host-runtime`, verifying SHA-256 with `CryptoKit`, caching the payload in the shared app-group caches directory, uploading `tmux` and `agentty-notify` to `~/.agentty/libexec/`, uploading managed terminfo files to `~/.agentty/share/terminfo/`, exposing the managed public wrapper at `~/.agentty/bin/agentty-notify`, and writing runtime config directly from Swift. `AgenTTY-iOS` uses immutable semver manifests under `/host-runtime/releases/<marketing-version>/manifest.json`; `AgenTTY-iOS-Dev` and `AgenTTY-iOS-Exp` use `/host-runtime/latest.json`. The runtime still uses shared shell logging via `bin/agentty-log`, wrappers for `claude` and `codex`, strict runtime config in `config/notify.json`, the persisted tmux session contract in `config/tmux-session-name`, and cached host facts under `state/`. The tmux wrapper, bootstrap, and shell wrapper now export `TERMINFO_DIRS` with the managed `~/.agentty/share/terminfo` tree first, and tmux sets `default-terminal=tmux-256color` before the first session is created so attach-time and in-pane terminfo stay AgenTTY-managed. Provisioning also cleans up known installer-era leftovers such as the old root-level `notify.env`, `claude-settings.json`, and `agentty-install-notifications` so the app remains the source of truth for remote host state. `Project.swift` keeps `AgenTTY/Resources/notifications` as a folder reference for scripts/settings only and now also embeds one Notification Service Extension per iOS flavor through Tuist. The same relay also backs main-flavor enhanced dictation: the app reuses its relay device identity, requests a short-lived dictation token on demand, and streams audio through SpeechKit's MAI-Transcribe-2 relay with server-side monthly allowances instead of embedding a provider or router key. The relay marks visible alert pushes with `mutable-content=1`, which lets the service extension log `push_extension_*` breadcrumbs before the system presents the notification. If the APNs token arrives after SSH is already connected, the app posts a token-change notification and `TerminalBridge` retries provisioning for the active SSH generation automatically. While the bridge stays connected, it also refreshes relay tokens before expiry; reconnects reuse already-installed static assets and skip binary downloads when `state/host-runtime-version` already matches the required manifest version and the expected managed files still exist. The runtime avoids editing user Claude/Codex config directly; instead it updates the AgenTTY tmux session (`agentty-main`, persisted in `config/tmux-session-name`) so new panes use wrapped `claude` (`--settings`) and `codex` (`-c notify=...`) commands only inside AgenTTY-managed shells, while already-open panes keep their existing shell environment until reopened. `InAppNotificationBanner` uses glass styling with axis-locked swipe-dismiss gestures. Notifications with a `tmuxWindowId` auto-dismiss when that window becomes active.
The relay also accepts production analytics writes on a separate authenticated endpoint. Analytics batches do not use relay bearer tokens or APNs readiness; they authenticate with the same device credentials as pairing/device registration and call `/v1/devices/ensure` before the first flush so production installs can write user/usage data even before APNs registration finishes. Validation failures return privacy-safe event id/type plus field/rule diagnostics, and the backend stores those diagnostics with payload version and redacted payload shape so malformed host-setup events can be diagnosed without raw hostnames, usernames, candidate values, or raw error messages.

## Link Taps

Single taps dispatch Ghostty link-opening click attempts using modifier-aware fallback sequences. The tap handler records the touch position locally first and avoids priming Ghostty with a plain `mouse_pos` before the actual click attempt, so modifier-bearing link activation can still set hover state at that cell. Ghostty-side cursor-position handling also refreshes link-hover state when the effective mouse modifiers change at the same cell, which closes the regression where a visually highlighted link remained non-clickable after a modifier-bearing synthetic tap. On normal iOS surfaces taps try `super` first, then plain, which matches Ghostty's default Darwin URL-link activation rule. In mouse-capture/alternate-screen contexts they try bypass combinations first (`shift+super` → `shift+ctrl` → `shift`), then reuse the plain fallback tail (`super` → plain) so link-opening and ordinary-click behavior stay aligned. Link foreground tint is theme-derived with contrast-aware selection. Link regex recomputation runs only on dirty frames.

## Key Files

| File | Responsibility |
|------|---------------|
| `AgenTTYApp.swift` | App entry, view hierarchy, keyboard-surface-mode switching, `TerminalLayout` constants |
| `GhosttyTerminalView.swift` | SwiftUI → UIViewRepresentable bridge |
| `TerminalReconnectScreen.swift` | In-terminal reconnect screen: phase/input models, pure escape-sequence renderer, and the presenter that owns draw/tick/teardown |
| `TerminalSettingsSheet.swift` | Settings UI for persisted terminal, keyboard style, encoding, AI, and new-shell toggles |
| `TerminalTipsSheet.swift` | Tips and tricks quick-reference sheet |
| `TerminalHostsSheet.swift` | Host management UI (list/select/add/delete) |
| `TerminalSurfaceViewIOS.swift` | UIKit surface, IOSurface management, sizing, input sink, swipe visuals |
| `TerminalSurfaceCallbacks.swift` | Ghostty PTY callback boundary + cross-file signature structs (`QuantizationSignature`, `CanonicalShellStateSignature`, `SurfaceGeometry`) |
| `TerminalSurfaceLifecycleController.swift` | Focus/occlusion lifecycle |
| `TerminalTouchGeometry.swift` | Shared interior-bounds clamping for touch controllers |
| `TerminalTouchScrollController.swift` | Vertical scroll, momentum, tap-to-click |
| `TerminalTouchSelectionController.swift` | Long-press selection, edit menu |
| `TerminalShellSwipeController.swift` | Horizontal tmux window swipes |
| `ShellIndicatorState.swift` | Observable tmux state bridge |
| `ShellIndicatorView.swift` | Shell indicator overlay |
| `ShellIndicatorTextStyle.swift` | Shared strip/spacebar typography token |
| `TopStatusChromeView.swift` | Status bar chrome (time, host, menu) |
| `GlassCapsuleBar.swift` | Shared Liquid Glass capsule component |
| `VisualLayering.swift` | Shared app-shell and terminal overlay depth policy |
| `AppTheme.swift` | Global palette derived from Ghostty theme and shared glass/styling tokens |
| `SheetPresentationComponents.swift` | Shared sheet infrastructure (`SheetNavigationCoordinator`, `SheetDestructiveActionButton`, `SheetFormFieldRow`, `SheetPickerRow`, `SheetDetailMode`, `SheetPresentation`, `esmaTermSheetBackground()`) |
| `GhosttyNamedColorKey.swift` | Typed enum of Ghostty color config keys |

Settings uses SheetNavigationCoordinator for its Acknowledgements destination, expanding before navigation. It loads the bundled ThirdPartyNotices.txt, the resource link to the authoritative root notice file. StoreKit product and shared-storage identity now come from build settings through AgenTTYBuildConfiguration.
