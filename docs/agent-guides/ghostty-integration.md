# Ghostty Integration

Read this when working on Ghostty runtime code, vendor rebuilds, theme resolution, or the C API boundary.

## Dependency Chain

```text
AgenTTY → checksum-pinned GitHub release → Vendor/GhosttyKit.xcframework
                                              ↑ maintainer rebuild
                        emileberhard/ghostty + mitchellh/libxev
```

`just _ensure-xcframework` downloads the release pinned in
`scripts/ghostty-artifact.json` and verifies its archive SHA-256 before extracting
only the allowlisted files into checkout-local ignored storage. Every installed
file is checked against its pinned SHA-256 on reuse. Concurrent installers share
a checkout-local lock; failed downloads leave the previous artifact intact.
Neither Git LFS nor another checkout's mutable Vendor symlink is used.

Only explicit vendor rebuilds clone the exact sources into `Vendor/sources/`.
The Ghostty fork uses sibling `../libxev` from public `mitchellh/libxev` at the
unchanged iOS Mach-port fix commit. Normal app builds and CI need no Zig or
source checkout. Missing or changed artifacts download again; source rebuilds
remain deliberate maintainer operations.

## Fork Customizations

### Ghostty Fork

Branch: `agentty-ghostty-1-3`. Rebased conceptually onto upstream `ghostty-org/ghostty` `v1.3.0` (March 9, 2026) and then reapplies the AgenTTY-specific fork delta. Two major feature areas:

**iOS platform port** (based on clauntty/eriklangille's fork):
- `NullPty` for iOS (no real PTY; fd=0 stubs). Read thread suppressed so bytes written to fd=0 are not read back as terminal output.
- `ghostty_surface_write_pty_output()` C API to feed inbound SSH bytes to the terminal from a background thread.
- iOS-safe XDG path resolution via `NSHomeDirectory()`.
- Metal `.shared` storage mode forced on iOS (no `.managed`).
- IOSurface sublayer injection via `addSublayer:` ObjC selector.
- Render coalescing timer (10ms normal, 30ms low-power) to batch rapid SSH data.
- `ghostty_config_load_string()` for loading bundled themes from memory.

**Always-visible wrapped URL links:**
- URL underlines render unconditionally on iOS (no hover/modifier needed).
- Contrast-aware link tint (prefers `bright_cyan`, falls back to higher-contrast palette).
- URL-stitching layer (`src/url_wrap.zig`) removes line-break padding from wrapped URLs before regex matching so multi-row URLs work as single strings.
- Alphabetic guard prevents false-positive stitching of ordinary word-wrapped prose.

### Upstream status

The publication keeps the existing Ghostty v1.3.0 base. A mechanical v1.3.1
rebase was attempted, but the build exposed toolchain failures, so that upgrade
was deferred to a separate vendor pass. AgenTTY still uses the four embedding
APIs listed below; changing the upstream base requires rebuilding all slices
and proving the app still links.

The focused fork preserves upstream history and the AgenTTY patch branch. Its
`AGENTTY.md` explains the supported embedding changes. GhosttyKit uses a separate
plain-semver release train starting at `0.1.0`; that number is not the upstream
Ghostty version. The fork's hosted workflow builds tagged releases and publishes
the archive, checksum file, and notices. The tag is also the embedded library
version; local rebuilds read that version from `scripts/ghostty-artifact.json`.

### libxev

`mitchellh/libxev` at `7bf2b2f9027a1862c7422b64cc4e53901f4f19ff` contains
Erik Langille's two-line Darwin Mach-port fix. Keeping exactly that commit
removes the private-fork dependency without changing event-loop behavior.
Without this fix the iOS wakeup path can stop after the first I/O cycle.

## C API Reference

All functions in `include/ghostty.h`. All must be called from `@MainActor` unless noted.

### Lifecycle

```
ghostty_init(argc, argv)
ghostty_config_new() → ghostty_config_load_cli_args() → ghostty_config_finalize()
ghostty_app_new(&runtime_config, config)
ghostty_surface_new(app, &surface_config)
ghostty_surface_free(surface)    // tears down renderer + I/O threads, joins them
ghostty_app_free(app)
```

`ghostty_config_finalize()` is mandatory before `ghostty_app_new`. `ghostty_config_load_default_files()` is macOS-only — skip on iOS.

### Runtime callbacks (set at `ghostty_app_new`)

| Callback | Thread | Purpose |
|----------|--------|---------|
| `wakeup_cb` | any thread | Must dispatch `ghostty_app_tick(app)` to main thread |
| `action_cb` | main | Receives all actions: `RENDER`, `SET_TITLE`, `CELL_SIZE`, `OPEN_URL`, etc. |
| `read_clipboard_cb` | main | Read system clipboard |
| `write_clipboard_cb` | main | Write to system clipboard |
| `close_surface_cb` | main | Surface close request (nullable) |

### Surface functions

| Function | Purpose |
|----------|---------|
| `set_content_scale(surface, x, y)` | Set pixel/point scale. Call before `set_size`. |
| `set_size(surface, w_px, h_px)` | Set size in **pixels** (not points). Default is 800x600. |
| `surface_size(surface)` | Returns columns, rows, cell dimensions in pixels |
| `set_focus(surface, bool)` | Cursor blink, focus tracking |
| `set_occlusion(surface, visible)` | `false` suspends GPU work (prevents background Metal crash) |
| `refresh(surface)` / `draw(surface)` | Schedule / force render |
| `write_pty_output(surface, ptr, len)` | Feed inbound bytes. **Background thread only** — deadlocks on main. |
| `set_pty_input_callback(surface, callback)` | Forward Ghostty-generated terminal input (for example mouse reporting) to the SSH bridge. Clear before freeing the surface. |
| `is_alternate_screen(surface)` | Distinguish full-screen terminal apps from normal scrollback when routing touch input. |
| `binding_action(surface, str, len)` | Execute named action (e.g. `"set_font_size:7.5"`, `"select_all"`) |
| `mouse_button(surface, ...)` | Returns `true` if consumed by mouse protocol, NOT success/failure |
| `has_selection(surface)` / `read_selection(surface, &text)` | Selection state |
| `config_get(config, &out, key, len)` | Read config value — type inferred from output pointer |

### `text` vs `key` — critical distinction
- `ghostty_surface_text` — paste semantics (adds bracketed-paste wrappers). Not for key presses.
- `ghostty_surface_key` — full key event with keybinding matching and protocol encoding.
- AgenTTY bypasses both, sending raw bytes directly to SSH.

## Threading Model

Ghostty creates three threads per surface:

1. **Renderer thread** — libxev event loop, ~120 FPS Metal rendering, cursor blink timer
2. **I/O thread** — libxev event loop, coalesced resize, synchronized output timer
3. **Read thread** — suppressed on iOS (no PTY to read from)

**Shared mutex**: `renderer_state.mutex` is held by both `processOutput` (called from SSH background queue via `write_pty_output`) and the renderer thread. This is why `write_pty_output` must not be called from main thread.

**Wakeup flow**: Ghostty threads → `wakeup_cb` (any thread) → host dispatches to main → `ghostty_app_tick(app)`.

## Config

iOS settings are injected via fake CLI args before `ghostty_init`. Config values set through `AgenTTYGhosttyConfig.iOSInitialization` (theme, cursor style, padding). Font size uses `UserDefaults` key `terminalFontSize` with `0.1pt` step quantization (4-24pt range).

Load in-memory config/theme text with `ghostty_config_load_string(config, bytes, length)`. Reading config uses `ghostty_config_get(config, &color, "background", 10)` — pass the appropriate output pointer type. Font-size `0` means "use default" (13pt).

## Theme Resolution

After config finalize, `GhosttyRuntime.applyResolvedIOSThemeColors` reads named colors and 256-entry palette via `ghostty_config_get`, reads the bundled theme file for extra named colors, synthesizes missing semantic colors, and pushes the result into `AppTheme`. All keyboard and chrome styling derives from this resolved theme.

Falls back to `GhosttyResolvedTheme.fallback` (dark colors) if background/foreground cannot be resolved.

## Vendor Rebuild

```bash
just ghostty-rebuild-xcframework
```

This runs three steps: `_setup` (clone + pin repos), `_build-xcframework` (Zig build), `_install-xcframework` (copy + module map fix).

The rebuild uses patched Zig 0.15.2 with `-Dstrip=false -Dsentry=false
-Di18n=false`, normalizes archive indexes with Apple `ranlib`, and links the
macOS consumer. The fork only links libintl when i18n is enabled and creates
the consumer's empty locale resource when it is disabled. The unused standalone
VT shared library is excluded from XCFramework builds. Installation validates
all slices, architectures, the custom embedding APIs, and bundled zlib, and
rejects libintl, Sentry Native, Breakpad, or Crashpad symbols. AgenTTY keeps its
separate sentry-cocoa integration.

To prepare an updated immutable release after rebuilding:

```bash
just ghostty-package-xcframework /tmp/GhosttyKit.xcframework.zip https://github.com/emileberhard/ghostty/releases/download/1.0.0/GhosttyKit.xcframework.zip
just ghostty-validate-release-xcframework
```

Use the next release version for a changed artifact. Packaging updates the
archive hash and complete file hash list in `scripts/ghostty-artifact.json`.
Review and commit those pins together with the source pins. The package
includes `docs/licenses/GhosttyKit-NOTICES.txt` and the exact unmodified
MPL-covered z2d source, fetched with a pinned SHA-256. Publish that archive,
`GhosttyKit-NOTICES.txt`, and `SHA256SUMS` on the fork before landing its consumer
pins. Never overwrite an existing release's bytes.

The archive and file hashes have one owner in the checked-in manifest; the
installer has no mutable global artifact cache. Checkout removal reclaims it.
This trades a download per checkout for isolated builds and avoids public Git
LFS bandwidth and cross-worktree mutations. Release validation checks installed
bytes against the manifest before compiling the app.

**Module map invariant**: After every rebuild, verify `header "ghostty.h"` (not `umbrella header`):
```bash
find Vendor/GhosttyKit.xcframework -name module.modulemap -print0 | xargs -0 rg 'header "ghostty.h"'
```

**Zig caches**: The content-addressed global cache is namespaced by Zig/Xcode and may be shared by local development worktrees. Keep the mutable local cache unique per checkout or workflow attempt; never share it across concurrent builds.

## Debugging

- Env-gated diagnostics: `GHOSTTY_LOG=true`, `AGENTTY_VERBOSE_LOGGING=1` (legacy `AGENTTY_VERBOSE_LOGGING=1` still accepted).
- Native API probing: `AGENTTY_NATIVE_PROBE_MODE=1` logs Ghostty API discovery at startup.
- Verify Ghostty C API semantics in upstream headers before changing behavior — do not infer from function names.
- `ghostty_surface_mouse_button` returns whether the event was consumed by mouse reporting, not dispatch success.
