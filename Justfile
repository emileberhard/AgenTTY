# AgenTTY: Ghostty-based SSH terminal for iPhone and iPad, its Rust backend and the host tools.

# The Xcode that .xcode-version names, as CI and the release use; callers may explicitly override it.
export DEVELOPER_DIR := if os() == "macos" { shell('if [ -n "${DEVELOPER_DIR:-}" ]; then echo "$DEVELOPER_DIR"; else scripts/select-xcode; fi') } else { "" }

delivery := "auto"
ghostty_repo := env_var_or_default("AGENTTY_GHOSTTY_REPO", "https://github.com/emileberhard/ghostty.git")
ghostty_commit := "48dca2e9814b64d606350d0cf4720b01bcd8c4d4"
ghostty_version := `python3 -c 'import json; print(json.load(open("scripts/ghostty-artifact.json"))["version"])'`
libxev_repo := env_var_or_default("AGENTTY_LIBXEV_REPO", "https://github.com/mitchellh/libxev.git")
libxev_commit := "7bf2b2f9027a1862c7422b64cc4e53901f4f19ff"
sources := "Vendor/sources"
xcframework := "Vendor/GhosttyKit.xcframework"

default:
    @just --list

# Build the Dev app for the simulator, unsigned and without private configuration
[group('app')]
build:
    scripts/ios-public build

# Run the unit tests on a simulator, or only the named suites
[group('app')]
[positional-arguments]
test *suites:
    scripts/ios-public test "$@"

# Run the opt-in live dictation and LLM regression tests through llm-router
[group('app')]
test-llm:
    scripts/ios-public test-llm

# Render the UI preview suite on the shared warm simulator, or only the named screens, into .local/ui-previews
[group('app')]
[positional-arguments]
ui-previews *args:
    AppStore/capture previews "$@"

# Shut down the shared preview simulators
[group('app')]
ui-previews-stop:
    AppStore/capture stop

# Capture and compose the App Store screenshots into .local/screenshots, as the release does
[group('app')]
screenshots:
    AppStore/capture app-store

# Build the Dev app and install it on Emil's iPhone, or on the iPhone or iPad with this UDID
[group('phone')]
install-dev $device="":
    scripts/iphone-iteration --flavor dev --delivery "{{ delivery }}" --device "$device"

# Build and retain a signed Dev checkpoint without contacting a phone
[group('phone')]
build-dev:
    scripts/iphone-iteration --flavor dev --build-only

# Deliver a retained Dev checkpoint to Emil's iPhone, or to the device with this UDID
[group('phone')]
deliver-dev $app_path $device="":
    scripts/iphone-iteration --flavor dev --app-path "$app_path" --delivery "{{ delivery }}" --device "$device"

# Build the side-by-side Exp app and install it like install-dev
[group('phone')]
install-exp $device="":
    scripts/iphone-iteration --flavor exp --delivery "{{ delivery }}" --device "$device"

# Build the main app with the local unlock at this tag's version and install it directly; only on request
[group('phone')]
install-main $device="":
    scripts/iphone-iteration --flavor main --delivery direct --device "$device"

# Record an Instruments diagnostics suite on a cabled device; see scripts/ios-perf-suite --help
[group('phone')]
[positional-arguments]
perf-suite *args:
    scripts/ios-perf-suite "$@"

# Analyze a recorded diagnostics run again
[group('phone')]
perf-analyze $run_dir $process_name="AgenTTY_iOS_Dev":
    scripts/ios-perf-analyze --run-dir "$run_dir" --process-name "$process_name"

# Run the backend locally
[group('backend')]
run-backend:
    services/backend/scripts/run-backend

# Run the backend tests
[group('backend')]
test-backend:
    cargo test --locked --manifest-path services/backend/Cargo.toml

# Build the backend release binary
[group('backend')]
build-backend:
    cargo build --locked --release --manifest-path services/backend/Cargo.toml

# Print the analytics digest from the backend database, or from this database file
[group('backend')]
[positional-arguments]
analytics-report *db:
    services/backend/scripts/analytics-report "$@"

# Run the host notification helper tests
[group('host tools')]
test-notify-helper:
    cargo test --locked --manifest-path tools/agentty-notify/Cargo.toml

# Run the host relay connector tests
[group('host tools')]
test-host-connector:
    cargo test --locked --manifest-path tools/agentty-host-connector/Cargo.toml

# Check that managed agent wrappers win after user shell startup
[group('host tools')]
test-host-shell:
    scripts/test-host-shell-path

# Rebuild the notification helper for every host target into .local/host-runtime
[group('host tools')]
build-notify-helper: (_build-host-helper "agentty-notify" "notify-helper-build-config.sh" "NOTIFY_HELPER_TARGET_MATRIX" "agentty-notify-source-hash")

# Rebuild the relay connector for every host target into .local/host-runtime
[group('host tools')]
build-host-connector: (_build-host-helper "agentty-host-connector" "host-connector-build-config.sh" "HOST_CONNECTOR_TARGET_MATRIX" "agentty-host-connector-source-hash")

[private]
_build-host-helper $crate $config $matrix $hash_script:
    #!/usr/bin/env bash
    set -euo pipefail
    export PATH="$HOME/.cargo/bin:$PATH"
    scripts/ensure-notify-helper-toolchain
    source "scripts/$config"
    entries="$matrix[@]"
    entries=("${!entries}")
    rust_targets=()
    for entry in "${entries[@]}"; do rust_targets+=("${entry%%|*}"); done
    rustup target add "${rust_targets[@]}"
    for entry in "${entries[@]}"; do
        IFS='|' read -r rust_target bundle_dir builder <<< "$entry"
        cargo "$([[ $builder == zigbuild ]] && echo zigbuild || echo build)" --locked --release \
            --manifest-path "tools/$crate/Cargo.toml" --target "$rust_target"
        install -d ".local/host-runtime/$bundle_dir"
        install -m 755 "tools/$crate/target/$rust_target/release/$crate" ".local/host-runtime/$bundle_dir/$crate"
    done
    "scripts/$hash_script" > ".local/host-runtime/.$crate-source.sha256"
    chmod 644 ".local/host-runtime/.$crate-source.sha256"

# Build the tmux runtime for this host, best effort
[group('host tools')]
build-tmux-runtime:
    scripts/build-tmux-runtime

# Build every tmux runtime target in GitHub Actions from this ref
[group('host tools')]
build-tmux-runtime-ci $ref="main":
    "${AGENTTY_GH_CLI:-ghp}" workflow run build-tmux-runtime.yml --ref "$ref"

# Download and verify the tmux runtime that this Actions run built
[group('host tools')]
sync-tmux-runtime $run_id:
    scripts/sync-tmux-runtime-artifacts "$run_id"

# Publish the host runtime to the mutable latest channel that Dev, Exp and development CLIs read
[group('host tools')]
publish-host-runtime:
    scripts/publish-host-runtime-artifacts --latest --auto-rebuild-notify

# Clone the pinned Ghostty and libxev sources and rebuild GhosttyKit
[group('ghostty')]
ghostty-rebuild:
    mkdir -p Vendor
    just _ghostty-setup
    just _ghostty-build
    just _ghostty-install

# Check GhosttyKit's slices, required symbols and module maps
[group('ghostty')]
ghostty-validate:
    #!/bin/bash
    set -euo pipefail
    libraries=(
        "{{ xcframework }}/ios-arm64/libghostty-fat.a"
        "{{ xcframework }}/ios-arm64-simulator/libghostty-fat.a"
        "{{ xcframework }}/macos-arm64_x86_64/libghostty.a"
    )
    expected_architectures=(
        "arm64"
        "arm64"
        "x86_64 arm64"
    )
    required_symbols=(
        _ghostty_init
        _ghostty_app_free
        _ghostty_surface_new
        _ghostty_config_load_string
        _ghostty_surface_write_pty_output
        _ghostty_surface_set_pty_input_callback
        _ghostty_surface_is_alternate_screen
        _zcfree
    )
    for index in "${!libraries[@]}"; do
        library="${libraries[$index]}"
        expected="${expected_architectures[$index]}"
        [ -f "$library" ] || {
            echo "FATAL: missing Ghostty binary slice: $library" >&2
            exit 1
        }
        actual="$(lipo -archs "$library")"
        if [ "$actual" != "$expected" ]; then
            echo "FATAL: Ghostty binary architectures are '$actual', expected '$expected': $library" >&2
            exit 1
        fi
        for architecture in $expected; do
            if nm -arch "$architecture" -g "$library" 2>/dev/null | awk '
                /libintl|_sentry_|google_breakpad|crashpad|Breakpad/ { found = 1 }
                END { exit !found }
            '; then
                echo "FATAL: Ghostty includes excluded gettext or native crash-reporting symbols: $library ($architecture)" >&2
                exit 1
            fi
            if ! missing_symbols="$(
                nm -arch "$architecture" -g "$library" 2>/dev/null | \
                    awk -v required="${required_symbols[*]}" '
                        BEGIN {
                            count = split(required, symbols, " ")
                            for (i = 1; i <= count; i++) expected[symbols[i]] = 1
                        }
                        $NF in expected && $(NF - 1) != "U" { found[$NF] = 1 }
                        END {
                            for (i = 1; i <= count; i++) {
                                symbol = symbols[i]
                                if (!found[symbol]) missing = missing (missing ? " " : "") symbol
                            }
                            if (missing) {
                                print missing
                                exit 1
                            }
                        }
                    '
            )"; then
                echo "FATAL: Ghostty binary is missing symbols for $architecture: $missing_symbols ($library)" >&2
                exit 1
            fi
        done
    done
    while IFS= read -r module_map; do
        if grep -q 'umbrella header' "$module_map"; then
            echo "FATAL: Ghostty module map uses an unsupported umbrella header: $module_map" >&2
            exit 1
        fi
    done < <(find "{{ xcframework }}" -name module.modulemap -type f)
    echo "Ghostty XCFramework verified: ${#libraries[@]} slices, ${#required_symbols[@]} required symbols; no libintl, Sentry Native, or Breakpad"

# Check the downloaded GhosttyKit against its pinned release checksums
[group('ghostty')]
ghostty-validate-release:
    scripts/ghostty-xcframework ensure
    scripts/ghostty-xcframework verify
    just ghostty-validate

# Package the rebuilt GhosttyKit as a release archive for this download URL
[group('ghostty')]
ghostty-package $archive $url:
    just ghostty-validate
    scripts/ghostty-xcframework package "$archive" "$url"

# Probe Ghostty's pinned Zig and Xcode build runner without building
[group('ghostty')]
ghostty-toolchain-check:
    mkdir -p Vendor
    just _ghostty-setup
    just _ghostty-check-toolchain

# Check that the cloned sources sit at their pinned commits and the artifact verifies
[group('ghostty')]
ghostty-check-vendor:
    #!/usr/bin/env bash
    set -euo pipefail
    for entry in "ghostty:{{ ghostty_commit }}" "libxev:{{ libxev_commit }}"; do
        name="${entry%%:*}"
        expected="${entry#*:}"
        if [ -d "{{ sources }}/$name" ]; then
            actual="$(git -C "{{ sources }}/$name" rev-parse HEAD)"
            [ "$actual" = "$expected" ] || { echo "FATAL: $name expected $expected, got $actual" >&2; exit 1; }
            echo "$name: $actual"
        fi
    done
    just ghostty-validate-release

# Remove the cloned Ghostty and libxev sources
[group('ghostty')]
ghostty-reset-sources:
    rm -rf "{{ sources }}"

[private]
_ghostty-setup:
    #!/bin/bash
    set -euo pipefail
    mkdir -p "{{ sources }}"
    scrub_non_release_tags_at_ghostty_head() {
        while IFS= read -r head_tag; do
            if [ -z "$head_tag" ]; then
                continue
            fi
            if [[ "$head_tag" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
                continue
            fi
            echo "▸ Removing non-release ghostty HEAD tag '$head_tag' to avoid zig release-version panic..."
            git -C "{{ sources }}/ghostty" tag -d "$head_tag" >/dev/null 2>&1 || true
        done < <(git -C "{{ sources }}/ghostty" tag --points-at HEAD)
    }
    # Clone ghostty if missing
    if [ ! -d "{{ sources }}/ghostty" ]; then
        echo "▸ Cloning ghostty..."
        git clone "{{ ghostty_repo }}" "{{ sources }}/ghostty"
    fi
    # Clone libxev if missing
    if [ ! -d "{{ sources }}/libxev" ]; then
        echo "▸ Cloning libxev..."
        git clone "{{ libxev_repo }}" "{{ sources }}/libxev"
    fi
    # Pin ghostty to exact commit
    actual=$(git -C "{{ sources }}/ghostty" rev-parse HEAD)
    if [ "$actual" != "{{ ghostty_commit }}" ]; then
        echo "▸ Pinning ghostty to {{ ghostty_commit }}..."
        git -C "{{ sources }}/ghostty" fetch origin
        git -C "{{ sources }}/ghostty" checkout "{{ ghostty_commit }}"
    fi
    scrub_non_release_tags_at_ghostty_head
    # Pin libxev to exact commit
    actual=$(git -C "{{ sources }}/libxev" rev-parse HEAD)
    if [ "$actual" != "{{ libxev_commit }}" ]; then
        echo "▸ Pinning libxev to {{ libxev_commit }}..."
        git -C "{{ sources }}/libxev" fetch origin
        git -C "{{ sources }}/libxev" checkout "{{ libxev_commit }}"
    fi
    # Verify ghostty references local libxev
    if ! grep -q '"../libxev"' "{{ sources }}/ghostty/build.zig.zon" 2>/dev/null; then
        echo "FATAL: ghostty/build.zig.zon does not reference local ../libxev"
        echo "The pinned ghostty commit may not be compatible with this build setup."
        exit 1
    fi
    echo "▸ Sources pinned and verified"

[private]
_ghostty-check-toolchain:
    #!/bin/bash
    set -euo pipefail
    zig_bin="$(scripts/ensure-ghostty-zig)"
    ghostty_developer_dir="$DEVELOPER_DIR"
    xcodebuild_bin="$ghostty_developer_dir/usr/bin/xcodebuild"
    [ -x "$xcodebuild_bin" ] || {
        echo "FATAL: Ghostty Xcode toolchain is missing: $xcodebuild_bin" >&2
        exit 1
    }
    xcode_build="$($xcodebuild_bin -version | awk '/Build version/ { print $3; exit }')"
    if [[ -z "${ZIG_GLOBAL_CACHE_DIR:-}" ]]; then
        cache_home="${XDG_CACHE_HOME:-$HOME/Library/Caches}"
        export ZIG_GLOBAL_CACHE_DIR="$cache_home/AgenTTY/ghostty/zig-0.15.2-xcode-$xcode_build/global"
    fi
    echo "▸ Probing Ghostty with $($xcodebuild_bin -version | tr '\n' ' ') and Zig $("$zig_bin" version)..."
    echo "▸ Shared Zig global cache: $ZIG_GLOBAL_CACHE_DIR"
    mkdir -p "$ZIG_GLOBAL_CACHE_DIR"
    if [[ -n "${ZIG_LOCAL_CACHE_DIR:-}" ]]; then
        mkdir -p "$ZIG_LOCAL_CACHE_DIR"
    fi
    (
        export DEVELOPER_DIR="$ghostty_developer_dir"
        cd "{{ sources }}/ghostty"
        "$zig_bin" build -h >/dev/null
    )
    echo "▸ Ghostty build runner verified"

[private]
_ghostty-build:
    #!/bin/bash
    set -euo pipefail
    zig_bin="$(scripts/ensure-ghostty-zig)"
    ghostty_developer_dir="$DEVELOPER_DIR"
    xcodebuild_bin="$ghostty_developer_dir/usr/bin/xcodebuild"
    [ -x "$xcodebuild_bin" ] || {
        echo "FATAL: Ghostty Xcode toolchain is missing: $xcodebuild_bin" >&2
        exit 1
    }
    xcode_build="$($xcodebuild_bin -version | awk '/Build version/ { print $3; exit }')"
    echo "▸ Ghostty toolchain: $($xcodebuild_bin -version | tr '\n' ' ')"
    echo "▸ Zig toolchain: $("$zig_bin" version) ($zig_bin)"
    # Share only the global cache across checkouts; Zig's local cache remains checkout-specific.
    if [[ -z "${ZIG_GLOBAL_CACHE_DIR:-}" ]]; then
        cache_home="${XDG_CACHE_HOME:-$HOME/Library/Caches}"
        export ZIG_GLOBAL_CACHE_DIR="$cache_home/AgenTTY/ghostty/zig-0.15.2-xcode-$xcode_build/global"
    fi
    echo "▸ Shared Zig global cache: $ZIG_GLOBAL_CACHE_DIR"
    if [[ -n "${ZIG_LOCAL_CACHE_DIR:-}" ]]; then
        echo "▸ Isolated Zig local cache: $ZIG_LOCAL_CACHE_DIR"
    else
        echo "▸ Isolated Zig local cache: checkout default"
    fi
    if [[ -n "${ZIG_GLOBAL_CACHE_DIR:-}" ]]; then
        mkdir -p "$ZIG_GLOBAL_CACHE_DIR"
    fi
    if [[ -n "${ZIG_LOCAL_CACHE_DIR:-}" ]]; then
        mkdir -p "$ZIG_LOCAL_CACHE_DIR"
    fi
    echo "▸ Building GhosttyKit xcframework..."
    (
        export DEVELOPER_DIR="$ghostty_developer_dir"
        cd "{{ sources }}/ghostty"
        "$zig_bin" build -j4 -Demit-xcframework -Doptimize=ReleaseFast -Dstrip=false -Dsentry=false -Di18n=false "-Dversion-string={{ ghostty_version }}" --summary all --verbose
    )
    [ -d "{{ sources }}/ghostty/macos/GhosttyKit.xcframework" ] \
        || { echo "FATAL: xcframework not found after build"; exit 1; }
    echo "▸ GhosttyKit built"

[private]
_ghostty-install:
    #!/bin/bash
    set -euo pipefail
    src="{{ sources }}/ghostty/macos/GhosttyKit.xcframework"
    dst="{{ xcframework }}"
    [ -d "$src" ] || { echo "FATAL: $src not found. Run _build-xcframework first."; exit 1; }
    echo "▸ Installing xcframework to $dst..."
    rm -rf "$dst"
    cp -R "$src" "$dst"
    find "$dst" -type f -name '*.h' -exec sed -i '' -E 's/[[:blank:]]+$//' {} +
    # Fix module maps: AgenTTY requires `header "ghostty.h"` (not umbrella header)
    # to avoid Clang explicit-module PCM failures from auxiliary headers.
    find "$dst" -name module.modulemap -print0 | while IFS= read -r -d '' mapfile; do
        if grep -q 'umbrella header' "$mapfile"; then
            sed -i '' 's/umbrella header "ghostty.h"/header "ghostty.h"/' "$mapfile"
            echo "  fixed: $mapfile"
        fi
    done
    # Verify fix
    if find "$dst" -name module.modulemap -print0 | xargs -0 grep -l 'umbrella header' >/dev/null 2>&1; then
        echo "FATAL: module map fix failed — still contains 'umbrella header'"
        exit 1
    fi
    just ghostty-validate
    echo "▸ xcframework installed, module maps verified"
