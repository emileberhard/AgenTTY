# AgenTTY — GhosttyKit vendor build & iOS app pipeline
#
#   just ios-build-install-dev           Build + install dev app to iPhone + auto-launch (default workflow)
#   just ios-build-install-dev-ipad      Build + install dev app to iPad + auto-launch
#   just ios-build-install-exp           Build + install exp app to iPhone + auto-launch (side-by-side variant)
#   just ios-build-install-main          Build + install main app to iPhone + auto-launch (only when explicitly requested)
#   AGENTTY_IPHONE_UDID=<udid>           Check, install and launch the iPhone recipes on exactly that iPhone
#   just ios-build-host-dev-ota          Build dev ad-hoc IPA + host tailnet OTA link for 5 minutes
#   just screenshots                     Capture, frame, compose, and validate App Store screenshots
#   just ios-perf-suite [args...]        Run programmatic iPhone Instruments diagnostics suite
#   just ios-perf-analyze <run-dir>      Re-analyze an existing diagnostics run directory
#   just ghostty-rebuild-xcframework     Rebuild Ghostty xcframework
#   just ghostty-validate-xcframework    Verify Ghostty slices and required symbols
#   just ghostty-validate-release-xcframework Verify pinned release checksums and slices
#   just ghostty-check-vendor            Verify pinned Ghostty/libxev vendor state
#   just ghostty-toolchain-check         Fast probe of Ghostty's pinned Zig/Xcode build runner
#   just backend-dev               Run the local Rust backend service
#   just backend-test              Run Rust backend tests
#   just backend-build             Build the backend release binary
#   just backend-analytics-report [db] Print the current analytics blocker/digest surface
#   just backend-reload-local      Reload an operator-owned relay deployment
#   just backend-deploy-local      Build + deploy + restart an operator-owned relay deployment
#   just notify-helper-test              Run Rust tests for the host-side agentty-notify helper
#   just notify-helper-rebuild           Rebuild host-runtime agentty-notify binaries into HostRuntimeArtifacts/bin
#   just host-shell-test                 Verify managed agent wrappers win after user shell startup
#   just host-connector-test             Run Rust tests for the host-side relay connector
#   just host-connector-rebuild          Rebuild host-runtime agentty-host-connector binaries into HostRuntimeArtifacts/bin
#   just tmux-runtime-rebuild            Best-effort local tmux runtime build for the current host
#   just tmux-runtime-build-gh [ref]     Dispatch GitHub Actions tmux runtime build
#   just tmux-runtime-sync <run-id>      Download + verify GitHub Actions tmux runtime bundle
#   just host-runtime-publish-release V Publish immutable host-runtime artifacts for release version V
#   just host-runtime-verify-release V  Verify an already-published immutable host-runtime release V
#   just host-runtime-ensure-release V  Publish or verify/reuse immutable host-runtime release V
#   just host-runtime-publish-latest    Publish/update the mutable latest host-runtime channel
#   just host-runtime-deploy-local      Install/reload an operator-owned static artifact host
#   just xcode-clean                     Clean Xcode build artifacts
#   just ghostty-reset-sources           Remove cloned Ghostty/libxev source repos
#
# All source dependencies are pinned to exact commits below.
# Change a commit hash to update, then run `just ghostty-rebuild-xcframework` to rebuild.
# --- Pinned source dependencies ---

ghostty_repo := env_var_or_default("AGENTTY_GHOSTTY_REPO", "https://github.com/emileberhard/ghostty.git")
ghostty_commit := "48dca2e9814b64d606350d0cf4720b01bcd8c4d4"
ghostty_version := `python3 -c 'import json; print(json.load(open("scripts/ghostty-artifact.json"))["version"])'`
libxev_repo := env_var_or_default("AGENTTY_LIBXEV_REPO", "https://github.com/mitchellh/libxev.git")
libxev_commit := "7bf2b2f9027a1862c7422b64cc4e53901f4f19ff"
iphone_udid := env_var_or_default("AGENTTY_IPHONE_UDID", "")
delivery := "direct"
build_only := "false"

# --- Paths ---

sources := "Vendor/sources"
xcframework := "Vendor/GhosttyKit.xcframework"
project := "AgenTTY.xcodeproj"
scheme := "AgenTTY-iOS-Dev"
xcode_log_filter := "./scripts/filter-xcodebuild-output"
backend_runner := "./services/backend/scripts/run-backend"
backend_manifest := "./services/backend/Cargo.toml"
notify_helper_manifest := "./tools/agentty-notify/Cargo.toml"
notify_helper_target_root := "./tools/agentty-notify/target"
notify_helper_toolchain_script := "./scripts/ensure-notify-helper-toolchain"
ghostty_zig_toolchain_script := "./scripts/ensure-ghostty-zig"
notify_helper_build_config_script := "./scripts/notify-helper-build-config.sh"
notify_helper_source_hash_script := "./scripts/agentty-notify-source-hash"
notify_helper_source_hash_stamp := "./HostRuntimeArtifacts/bin/.agentty-notify-source.sha256"
host_connector_manifest := "./tools/agentty-host-connector/Cargo.toml"
host_connector_target_root := "./tools/agentty-host-connector/target"
host_connector_build_config_script := "./scripts/host-connector-build-config.sh"
host_connector_source_hash_script := "./scripts/agentty-host-connector-source-hash"
host_connector_source_hash_stamp := "./HostRuntimeArtifacts/bin/.agentty-host-connector-source.sha256"
host_runtime_artifact_root := "./HostRuntimeArtifacts/bin"
notify_helper_resource_root := host_runtime_artifact_root
tmux_runtime_builder := "./scripts/build-tmux-runtime"
host_runtime_publish_script := "./scripts/publish-host-runtime-artifacts"
release_simulator_resolver := "./scripts/resolve-release-simulator"

# Default command
[private]
default: ios-build-install-dev

backend-dev:
    {{ backend_runner }}

backend-test:
    cargo test --locked --manifest-path "{{ backend_manifest }}"

backend-build:
    cargo build --manifest-path "{{ backend_manifest }}" --release --locked

screenshots:
    ./scripts/with-agentty-screenshot-fixture ./scripts/generate-app-store-screenshots

backend-analytics-report db="":
    #!/usr/bin/env bash
    set -euo pipefail
    if [[ -n "{{ db }}" ]]; then
        ./services/backend/scripts/analytics-report "{{ db }}"
    else
        ./services/backend/scripts/analytics-report
    fi

backend-reload-local:
    #!/usr/bin/env bash
    set -euo pipefail
    : "${AGENTTY_BACKEND_DEPLOY_SCRIPT:?AGENTTY_BACKEND_DEPLOY_SCRIPT must point to the local backend deploy script}"
    "$AGENTTY_BACKEND_DEPLOY_SCRIPT" --skip-build

backend-deploy-local:
    #!/usr/bin/env bash
    set -euo pipefail
    : "${AGENTTY_BACKEND_DEPLOY_SCRIPT:?AGENTTY_BACKEND_DEPLOY_SCRIPT must point to the local backend deploy script}"
    "$AGENTTY_BACKEND_DEPLOY_SCRIPT"

# Run the opt-in live Gemini structured-output regression test.
ios-llm-integration-test:
    #!/bin/bash
    set -euo pipefail
    ./scripts/sync-local-llm-router-key
    simulator_id="$({{ release_simulator_resolver }})"
    xcodebuild test -project "{{ project }}" -scheme AgenTTY-iOS-LLM-IntegrationTests \
        -destination "platform=iOS Simulator,id=$simulator_id" \
        -disableAutomaticPackageResolution -onlyUsePackageVersionsFromResolvedFile -skipPackageUpdates

notify-helper-test:
    #!/bin/bash
    set -euo pipefail
    cargo test --locked --manifest-path "{{ notify_helper_manifest }}"

host-shell-test:
    ./scripts/test-host-shell-path

notify-helper-rebuild:
    #!/bin/bash
    set -euo pipefail
    export PATH="$HOME/.cargo/bin:$PATH"
    {{ notify_helper_toolchain_script }}
    source "{{ notify_helper_build_config_script }}"

    rust_targets=()
    for entry in "${NOTIFY_HELPER_TARGET_MATRIX[@]}"; do
        IFS='|' read -r rust_target _ _ <<< "$entry"
        rust_targets+=("$rust_target")
    done
    rustup target add "${rust_targets[@]}"

    for entry in "${NOTIFY_HELPER_TARGET_MATRIX[@]}"; do
        IFS='|' read -r rust_target bundle_dir builder <<< "$entry"

        if [[ "$builder" == "zigbuild" ]]; then
            cargo zigbuild --locked --manifest-path "{{ notify_helper_manifest }}" --release --target "$rust_target"
        else
            cargo build --locked --manifest-path "{{ notify_helper_manifest }}" --release --target "$rust_target"
        fi

        install -d "{{ notify_helper_resource_root }}/$bundle_dir"
        cp "{{ notify_helper_target_root }}/$rust_target/release/agentty-notify" "{{ notify_helper_resource_root }}/$bundle_dir/agentty-notify"
        chmod 755 "{{ notify_helper_resource_root }}/$bundle_dir/agentty-notify"
    done

    source_hash="$({{ notify_helper_source_hash_script }})"
    printf '%s\n' "$source_hash" > "{{ notify_helper_source_hash_stamp }}"
    chmod 644 "{{ notify_helper_source_hash_stamp }}"

host-connector-test:
    #!/bin/bash
    set -euo pipefail
    cargo test --locked --manifest-path "{{ host_connector_manifest }}"

host-connector-rebuild:
    #!/bin/bash
    set -euo pipefail
    export PATH="$HOME/.cargo/bin:$PATH"
    {{ notify_helper_toolchain_script }}
    source "{{ host_connector_build_config_script }}"

    rust_targets=()
    for entry in "${HOST_CONNECTOR_TARGET_MATRIX[@]}"; do
        IFS='|' read -r rust_target _ _ <<< "$entry"
        rust_targets+=("$rust_target")
    done
    rustup target add "${rust_targets[@]}"

    for entry in "${HOST_CONNECTOR_TARGET_MATRIX[@]}"; do
        IFS='|' read -r rust_target bundle_dir builder <<< "$entry"

        if [[ "$builder" == "zigbuild" ]]; then
            cargo zigbuild --locked --manifest-path "{{ host_connector_manifest }}" --release --target "$rust_target"
        else
            cargo build --locked --manifest-path "{{ host_connector_manifest }}" --release --target "$rust_target"
        fi

        install -d "{{ notify_helper_resource_root }}/$bundle_dir"
        cp "{{ host_connector_target_root }}/$rust_target/release/agentty-host-connector" "{{ notify_helper_resource_root }}/$bundle_dir/agentty-host-connector"
        chmod 755 "{{ notify_helper_resource_root }}/$bundle_dir/agentty-host-connector"
    done

    source_hash="$({{ host_connector_source_hash_script }})"
    printf '%s\n' "$source_hash" > "{{ host_connector_source_hash_stamp }}"
    chmod 644 "{{ host_connector_source_hash_stamp }}"

tmux-runtime-rebuild:
    {{ tmux_runtime_builder }}

tmux-runtime-build-gh ref="main":
    #!/usr/bin/env bash
    set -euo pipefail
    gh_cli="${AGENTTY_GH_CLI:-ghp}"
    "$gh_cli" workflow run build-tmux-runtime.yml --ref "{{ ref }}"

tmux-runtime-sync run_id:
    ./scripts/sync-tmux-runtime-artifacts "{{ run_id }}"

host-runtime-publish-release version:
    #!/usr/bin/env bash
    set -euo pipefail
    {{ host_runtime_publish_script }} --version "{{ version }}" --auto-rebuild-notify

host-runtime-verify-release version:
    #!/usr/bin/env bash
    set -euo pipefail
    {{ host_runtime_publish_script }} --version "{{ version }}" --verify-existing-release

host-runtime-ensure-release version:
    #!/usr/bin/env bash
    set -euo pipefail
    {{ host_runtime_publish_script }} --version "{{ version }}" --reuse-existing-release --auto-rebuild-notify

host-runtime-publish-latest:
    #!/usr/bin/env bash
    set -euo pipefail
    {{ host_runtime_publish_script }} --latest --auto-rebuild-notify

host-runtime-deploy-local:
    #!/usr/bin/env bash
    set -euo pipefail
    : "${AGENTTY_HOST_RUNTIME_DEPLOY_SCRIPT:?AGENTTY_HOST_RUNTIME_DEPLOY_SCRIPT must point to the local artifact-host deploy script}"
    "$AGENTTY_HOST_RUNTIME_DEPLOY_SCRIPT"

[private]
_ensure-host-runtime-published channel version="":
    #!/usr/bin/env bash
    set -euo pipefail

    current_host() {
        if command -v scutil >/dev/null 2>&1; then
            scutil --get LocalHostName 2>/dev/null && return 0
        fi
        hostname -s 2>/dev/null || hostname
    }

    host_name="$(current_host)"
    required_host="${AGENTTY_HOST_RUNTIME_PUBLISH_HOST:-}"
    auto_publish="${AGENTTY_HOST_RUNTIME_AUTO_PUBLISH:-false}"
    if [[ -z "$required_host" && "$auto_publish" != "1" && "$auto_publish" != "true" ]]; then
        echo "notice: skipping {{ channel }} host runtime publish preflight; set AGENTTY_HOST_RUNTIME_AUTO_PUBLISH=1 or AGENTTY_HOST_RUNTIME_PUBLISH_HOST to enable" >&2
        exit 0
    fi
    if [[ -n "$required_host" && "$host_name" != "$required_host" ]]; then
        echo "notice: skipping {{ channel }} host runtime publish preflight on $host_name; publish is local-only to $required_host" >&2
        exit 0
    fi

    publish_args=()
    case "{{ channel }}" in
        latest)
            publish_args=(--latest)
            ;;
        release)
            release_version="{{ version }}"
            if [[ -z "$release_version" ]]; then
                release_version="$(./scripts/resolve-release-marketing-version)"
            fi
            publish_args=(--version "$release_version")
            ;;
        *)
            echo "unsupported host runtime publish channel: {{ channel }}" >&2
            exit 1
            ;;
    esac

    {{ host_runtime_publish_script }} "${publish_args[@]}" --auto-rebuild-notify

[private]
_ensure-latest-host-runtime-published:
    if [ "{{ build_only }}" != true ]; then just --justfile Justfile _ensure-host-runtime-published latest; fi

[private]
_ensure-release-host-runtime-published:
    just --justfile Justfile _ensure-host-runtime-published release

# Ensure SPM packages resolve cleanly from the committed lock.

# Auto-recovers from stale SPM caches; gives clear errors for auth/network issues.
[private]
_ensure-project:
    #!/bin/bash
    set -euo pipefail
    for stale in AgenTTY.xcodeproj/project.pbxproj AgenTTY.xcworkspace Derived; do
        [[ ! -e "$stale" ]] || { echo "$stale is generated Tuist output that the committed project replaced; delete it." >&2; exit 1; }
    done
    # --- SPM: resolve packages (auto-recover from stale caches) ---
    resolve_log="$(mktemp -t agentty-spm-resolve.XXXXXX)"
    trap 'rm -f "$resolve_log"' EXIT
    set +e
    xcodebuild -resolvePackageDependencies \
        -project "{{ project }}" \
        -scheme "{{ scheme }}" \
        -disableAutomaticPackageResolution \
        -onlyUsePackageVersionsFromResolvedFile \
        -skipPackageUpdates \
        >"$resolve_log" 2>&1
    resolve_exit=$?
    set -e
    if [ "$resolve_exit" -eq 0 ]; then
        exit 0
    fi
    # Resolve failed — diagnose and attempt recovery
    if grep -q "Git command.*failed.*No such file or directory" "$resolve_log"; then
        echo "SPM cache is corrupted — auto-repairing..."
        # Create placeholder git repos at the expected cache paths.
        # SPM computes a hash from the package URL and expects a repo at that path;
        # if missing, it crashes instead of re-cloning. Placeholders unblock re-fetch.
        grep -oE "/[^ ']+/repositories/[^ ']+" "$resolve_log" | sort -u | while read -r broken_path; do
            if [ ! -d "$broken_path" ]; then
                mkdir -p "$broken_path"
                git init "$broken_path" --quiet
                echo "  created placeholder: $broken_path"
            fi
        done
        echo "  retrying package resolve..."
        set +e
        xcodebuild -resolvePackageDependencies \
            -project "{{ project }}" \
            -scheme "{{ scheme }}" \
            -disableAutomaticPackageResolution \
            -onlyUsePackageVersionsFromResolvedFile \
            -skipPackageUpdates \
            >"$resolve_log" 2>&1
        resolve_exit=$?
        set -e
        if [ "$resolve_exit" -eq 0 ]; then
            echo "  resolved successfully after cache repair"
            exit 0
        fi
        echo ""
        echo "FATAL: SPM resolve still failing after cache repair." >&2
        tail -5 "$resolve_log" >&2
        echo "" >&2
        echo "  Try: rm -rf ~/Library/Caches/org.swift.swiftpm/repositories/" >&2
        echo "  Then re-run the build." >&2
        exit 1
    fi
    if grep -qiE "(authentication|403|404|not find a branch)" "$resolve_log"; then
        echo ""
        echo "FATAL: SPM package resolution failed — likely a GitHub authentication issue." >&2
        echo "  Private package access may be required for configured Swift packages." >&2
        echo "" >&2
        echo "  Fix: set up gh as the git HTTPS credential helper:" >&2
        echo "    1. ghp auth login     (if not already logged in)" >&2
        echo "    2. ghp auth setup-git (registers gh as HTTPS credential helper)" >&2
        echo "  Then re-run the build." >&2
        exit 1
    fi
    # Unknown failure — dump the tail of the log
    echo ""
    echo "FATAL: SPM package resolution failed." >&2
    tail -10 "$resolve_log" >&2
    echo "" >&2
    echo "  Full resolve log: $resolve_log" >&2
    trap - EXIT  # keep log for debugging
    exit 1

# Ensure the pinned release is installed before project generation.
[private]
_ensure-xcframework:
    ./scripts/ghostty-xcframework ensure

[private]
_ensure-vendor:
    mkdir -p Vendor

# Only rebuild xcframework (clone/pin + build + copy + fix module map)
ghostty-rebuild-xcframework:
    #!/bin/bash
    set -euo pipefail
    just --justfile Justfile _ensure-vendor
    just --justfile Justfile _setup
    just --justfile Justfile _build-xcframework
    just --justfile Justfile _install-xcframework

# Verify Ghostty binary slices and required symbols
ghostty-validate-xcframework:
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

# Verify the release archive's pinned file checksums before app releases.
ghostty-validate-release-xcframework: _ensure-xcframework
    ./scripts/ghostty-xcframework verify
    just --justfile Justfile ghostty-validate-xcframework

ghostty-package-xcframework $archive $url:
    just --justfile Justfile ghostty-validate-xcframework
    ./scripts/ghostty-xcframework package "$archive" "$url"

# Clone/pin sources and compile only Ghostty's build runner
ghostty-toolchain-check:
    #!/bin/bash
    set -euo pipefail
    just --justfile Justfile _ensure-vendor
    just --justfile Justfile _setup
    just --justfile Justfile _check-ghostty-toolchain

# Verify pinned dependency state
ghostty-check-vendor: _ensure-xcframework
    #!/bin/bash
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
    just --justfile Justfile ghostty-validate-release-xcframework

# Bake the llm-router key into the dev/exp local secrets.
[private]
_sync-local-llm-router-key:
    ./scripts/sync-local-llm-router-key

# Ensure the canonical never-locked apple-signing keychain is ready for signing.
[private]
_ensure-signing-keychain:
    ./scripts/check-build-identity
    "$HOME/configs/skills/apple-devops/scripts/ensure-signing-keychain"

# Ensure the canonical keychain and repair/install the manual development profiles
# that AgenTTY-iOS-Dev iPhone and iPad builds sign against.
[private]
_ensure-ios-dev-signing: _ensure-signing-keychain
    #!/bin/bash
    set -euo pipefail
    asc="$HOME/configs/skills/apple-devops/scripts/asc_api.py"
    uv run "$asc" ensure-profile --name "AgenTTY iOS Dev Development" \
        --type IOS_APP_DEVELOPMENT --bundle-id dev.tuist.agentty.iOS.dev
    uv run "$asc" ensure-profile --name "AgenTTY Notification Service Dev Development" \
        --type IOS_APP_DEVELOPMENT --bundle-id dev.tuist.agentty.iOS.dev.NotificationService

[private]
_validate-ios-dev-delivery:
    @test "{{ delivery }}" = direct || { echo "AgenTTY Dev currently supports direct delivery only. Managed delivery needs a safe replacement for bundled AI credentials and matching runtime APNs metadata." >&2; exit 1; }
    @test "{{ build_only }}" = true -o "{{ build_only }}" = false

ios-build-dev:
    just build_only=true ios-build-install-dev

ios-deliver-dev $app_path:
    #!/bin/bash
    set -euo pipefail
    expected="$(python3 - "$app_path" <<'PY'
    import json, pathlib, sys
    app = pathlib.Path(sys.argv[1]).resolve()
    value = json.loads((app.parent / 'artifact.json').read_text())
    if pathlib.Path(value['appPath']).resolve() != app or value['bundleIdentifier'] != 'dev.tuist.agentty.iOS.dev':
        raise SystemExit('Expected a retained AgenTTY Dev checkpoint')
    print(value['appSHA256'])
    PY
    )"
    delivery_args=(--app-path "$app_path" --expected-app-sha256 "$expected" --delivery direct --launch)
    if [ -n "{{ iphone_udid }}" ]; then delivery_args+=(--device "{{ iphone_udid }}"); fi
    "$HOME/configs/skills/apple-devops/scripts/ios-deliver-app" "${delivery_args[@]}"

# Build + install dev app to iPhone (no xcframework rebuild)
ios-build-install-dev: _validate-ios-dev-delivery _sync-local-llm-router-key _ensure-latest-host-runtime-published _ensure-xcframework _ensure-project _ensure-ios-dev-signing
    #!/bin/bash
    set -euo pipefail
    build_args=(--project "{{ project }}" --scheme "{{ scheme }}" --allow-provisioning-updates)
    if [ "{{ build_only }}" = true ]; then
        common_root="$(cd "$(git rev-parse --path-format=absolute --git-common-dir)/.." && pwd)"
        artifact_root="$common_root/.local/iphone-builds/$(uuidgen)"
        mkdir -p "$(dirname "$artifact_root")"
        build_args+=(--build-only --artifact-output "$artifact_root")
    else
        ./scripts/ios-devicectl-app-target --check-only --udid "{{ iphone_udid }}"
        if [ -n "{{ iphone_udid }}" ]; then build_args+=(--device "{{ iphone_udid }}"); fi
    fi
    install_log_raw="$(mktemp -t agentty-ios-build-install-dev.raw.XXXXXX)"
    install_log_filtered="$(mktemp -t agentty-ios-build-install-dev.filtered.XXXXXX)"
    install_log_extra="$(mktemp -t agentty-ios-build-install-dev.extra.XXXXXX)"
    trap 'rm -f "$install_log_raw" "$install_log_filtered" "$install_log_extra"' EXIT
    set +e
    "$HOME/configs/skills/swift-development/scripts/ios-install-device" \
        "${build_args[@]}" \
        -- -verbose -showBuildTimingSummary DEBUG_INFORMATION_FORMAT=dwarf-with-dsym \
        2>&1 | tee "$install_log_raw" | "{{ xcode_log_filter }}" | tee "$install_log_filtered"
    install_exit=${PIPESTATUS[0]}
    set -e
    if [ "$install_exit" -ne 0 ]; then
        xcode_log="$(sed -n 's/^xcodebuild log: //p' "$install_log_raw" | tail -n1)"
        if [ -n "$xcode_log" ] && [ -f "$xcode_log" ]; then
            "{{ xcode_log_filter }}" < "$xcode_log" \
                | awk 'NR==FNR { seen[$0]=1; next } !seen[$0] { print }' "$install_log_filtered" - \
                > "$install_log_extra"
            if [ -s "$install_log_extra" ]; then
                echo "additional diagnostics from $xcode_log:"
                if grep -q $'^\t' "$install_log_extra" && ! grep -q '^The following build commands failed:$' "$install_log_extra"; then
                    echo "The following build commands failed:"
                fi
                cat "$install_log_extra"
            fi
        fi
        exit "$install_exit"
    fi
    if [ "{{ build_only }}" = true ]; then
        python3 - "$artifact_root" <<'PY'
    import json, pathlib, subprocess, sys
    root = pathlib.Path(sys.argv[1])
    value = json.loads((root / 'artifact.json').read_text())
    value['sourceCommit'] = subprocess.check_output(['git', 'rev-parse', 'HEAD'], text=True).strip()
    value['sourceDirty'] = bool(subprocess.check_output(['git', 'status', '--porcelain']))
    (root / 'source.json').write_text(json.dumps(value, indent=2) + '\n')
    print(json.dumps(value))
    PY
        exit 0
    fi
    device_name="$(sed -n 's/^installing to iPhone: //p' "$install_log_raw" | tail -n1)"
    launch_args=(
        --bundle-id dev.tuist.agentty.iOS.dev
        --udid "{{ iphone_udid }}"
    )
    if [ -n "$device_name" ]; then
        launch_args+=(--installed-device-name "$device_name")
    fi
    if ! ./scripts/ios-devicectl-app-target "${launch_args[@]}"; then
        echo "warning: build and install succeeded, but auto-launch failed; open the app manually if needed" >&2
    fi

# Build + install main app to iPhone (no xcframework rebuild)
ios-build-install-main: _ensure-release-host-runtime-published _ensure-xcframework _ensure-project _ensure-signing-keychain
    #!/bin/bash
    set -euo pipefail
    release_marketing_version="$(./scripts/resolve-release-marketing-version)"
    run_install() {
        local skip_build_flag="${1:-no}"
        local -a install_cmd=(
            "$HOME/configs/skills/swift-development/scripts/ios-install-device"
            --project "{{ project }}"
            --scheme "AgenTTY-iOS"
        )
        if [ -n "{{ iphone_udid }}" ]; then install_cmd+=(--device "{{ iphone_udid }}"); fi

        if [ "$skip_build_flag" = "yes" ]; then
            install_cmd+=(--skip-build)
        else
            install_cmd+=(--allow-provisioning-updates)
        fi

        install_cmd+=(
            --
            -verbose
            -showBuildTimingSummary
            DEBUG_INFORMATION_FORMAT=dwarf-with-dsym
            MARKETING_VERSION="$release_marketing_version"
            "OTHER_SWIFT_FLAGS=\$(inherited) -D AGENTTY_LOCAL_MAIN_UNLOCK"
        )
        "${install_cmd[@]}"
    }

    ./scripts/ios-devicectl-app-target --check-only --udid "{{ iphone_udid }}"
    install_log_raw="$(mktemp -t agentty-ios-build-install-main.raw.XXXXXX)"
    install_log_filtered="$(mktemp -t agentty-ios-build-install-main.filtered.XXXXXX)"
    install_log_extra="$(mktemp -t agentty-ios-build-install-main.extra.XXXXXX)"
    trap 'rm -f "$install_log_raw" "$install_log_filtered" "$install_log_extra"' EXIT
    set +e
    run_install no 2>&1 | tee "$install_log_raw" | "{{ xcode_log_filter }}" | tee "$install_log_filtered"
    install_exit=${PIPESTATUS[0]}
    set -e
    if [ "$install_exit" -ne 0 ]; then
        if grep -Fq "A coordinated app install already exists for [dev.tuist.agentty.iOS/" "$install_log_raw"; then
            echo "main install is blocked by an existing App Store/TestFlight copy; uninstalling it and retrying once"
            xcrun devicectl device uninstall app \
                --device "{{ iphone_udid }}" \
                dev.tuist.agentty.iOS

            : > "$install_log_raw"
            : > "$install_log_filtered"
            set +e
            run_install yes 2>&1 | tee "$install_log_raw" | "{{ xcode_log_filter }}" | tee "$install_log_filtered"
            install_exit=${PIPESTATUS[0]}
            set -e
        fi

        xcode_log="$(sed -n 's/^xcodebuild log: //p' "$install_log_raw" | tail -n1)"
        if [ -n "$xcode_log" ] && [ -f "$xcode_log" ]; then
            "{{ xcode_log_filter }}" < "$xcode_log" \
                | awk 'NR==FNR { seen[$0]=1; next } !seen[$0] { print }' "$install_log_filtered" - \
                > "$install_log_extra"
            if [ -s "$install_log_extra" ]; then
                echo "additional diagnostics from $xcode_log:"
                if grep -q $'^\t' "$install_log_extra" && ! grep -q '^The following build commands failed:$' "$install_log_extra"; then
                    echo "The following build commands failed:"
                fi
                cat "$install_log_extra"
            fi
        fi
        exit "$install_exit"
    fi
    device_name="$(sed -n 's/^installing to iPhone: //p' "$install_log_raw" | tail -n1)"
    launch_args=(
        --bundle-id dev.tuist.agentty.iOS
        --udid "{{ iphone_udid }}"
    )
    if [ -n "$device_name" ]; then
        launch_args+=(--installed-device-name "$device_name")
    fi
    if ! ./scripts/ios-devicectl-app-target "${launch_args[@]}"; then
        echo "warning: build and install succeeded, but auto-launch failed; open the app manually if needed" >&2
    fi
    if ! ./scripts/upload-sentry-local-dsyms --project "{{ project }}" --scheme "AgenTTY-iOS"; then
        echo "warning: local Sentry dSYM upload failed; symbolication for this side-loaded main build may be incomplete" >&2
    fi

# Build + install dev app to iPad (no xcframework rebuild)
ios-build-install-dev-ipad: _sync-local-llm-router-key _ensure-latest-host-runtime-published _ensure-xcframework _ensure-project _ensure-ios-dev-signing
    #!/bin/bash
    set -euo pipefail
    ./scripts/ios-devicectl-app-target --check-only --device-type ipad
    install_log_raw="$(mktemp -t agentty-ios-build-install-dev-ipad.raw.XXXXXX)"
    install_log_filtered="$(mktemp -t agentty-ios-build-install-dev-ipad.filtered.XXXXXX)"
    install_log_extra="$(mktemp -t agentty-ios-build-install-dev-ipad.extra.XXXXXX)"
    trap 'rm -f "$install_log_raw" "$install_log_filtered" "$install_log_extra"' EXIT
    set +e
    "$HOME/configs/skills/swift-development/scripts/ios-install-device" \
        --project "{{ project }}" \
        --scheme "{{ scheme }}" \
        --device-type ipad \
        --allow-provisioning-updates \
        -- -verbose -showBuildTimingSummary \
        2>&1 | tee "$install_log_raw" | "{{ xcode_log_filter }}" | tee "$install_log_filtered"
    install_exit=${PIPESTATUS[0]}
    set -e
    if [ "$install_exit" -ne 0 ]; then
        xcode_log="$(sed -n 's/^xcodebuild log: //p' "$install_log_raw" | tail -n1)"
        if [ -n "$xcode_log" ] && [ -f "$xcode_log" ]; then
            "{{ xcode_log_filter }}" < "$xcode_log" \
                | awk 'NR==FNR { seen[$0]=1; next } !seen[$0] { print }' "$install_log_filtered" - \
                > "$install_log_extra"
            if [ -s "$install_log_extra" ]; then
                echo "additional diagnostics from $xcode_log:"
                if grep -q $'^\t' "$install_log_extra" && ! grep -q '^The following build commands failed:$' "$install_log_extra"; then
                    echo "The following build commands failed:"
                fi
                cat "$install_log_extra"
            fi
        fi
        exit "$install_exit"
    fi
    device_name="$(sed -n 's/^installing to iPad: //p' "$install_log_raw" | tail -n1)"
    launch_args=(
        --bundle-id dev.tuist.agentty.iOS.dev
        --device-type ipad
    )
    if [ -n "$device_name" ]; then
        launch_args+=(--installed-device-name "$device_name")
    fi
    if ! ./scripts/ios-devicectl-app-target "${launch_args[@]}"; then
        echo "warning: build and install succeeded, but auto-launch failed; open the app manually if needed" >&2
    fi

# Build + install exp app to iPhone (no xcframework rebuild)
ios-build-install-exp: _sync-local-llm-router-key _ensure-latest-host-runtime-published _ensure-xcframework _ensure-project _ensure-signing-keychain
    #!/bin/bash
    set -euo pipefail
    ./scripts/ios-devicectl-app-target --check-only --udid "{{ iphone_udid }}"
    install_log_raw="$(mktemp -t agentty-ios-build-install-exp.raw.XXXXXX)"
    install_log_filtered="$(mktemp -t agentty-ios-build-install-exp.filtered.XXXXXX)"
    install_log_extra="$(mktemp -t agentty-ios-build-install-exp.extra.XXXXXX)"
    trap 'rm -f "$install_log_raw" "$install_log_filtered" "$install_log_extra"' EXIT
    install_args=(--project "{{ project }}" --scheme "AgenTTY-iOS-Exp" --allow-provisioning-updates)
    if [ -n "{{ iphone_udid }}" ]; then install_args+=(--device "{{ iphone_udid }}"); fi
    set +e
    "$HOME/configs/skills/swift-development/scripts/ios-install-device" \
        "${install_args[@]}" \
        -- -verbose -showBuildTimingSummary \
        2>&1 | tee "$install_log_raw" | "{{ xcode_log_filter }}" | tee "$install_log_filtered"
    install_exit=${PIPESTATUS[0]}
    set -e
    if [ "$install_exit" -ne 0 ]; then
        xcode_log="$(sed -n 's/^xcodebuild log: //p' "$install_log_raw" | tail -n1)"
        if [ -n "$xcode_log" ] && [ -f "$xcode_log" ]; then
            "{{ xcode_log_filter }}" < "$xcode_log" \
                | awk 'NR==FNR { seen[$0]=1; next } !seen[$0] { print }' "$install_log_filtered" - \
                > "$install_log_extra"
            if [ -s "$install_log_extra" ]; then
                echo "additional diagnostics from $xcode_log:"
                if grep -q $'^\t' "$install_log_extra" && ! grep -q '^The following build commands failed:$' "$install_log_extra"; then
                    echo "The following build commands failed:"
                fi
                cat "$install_log_extra"
            fi
        fi
        exit "$install_exit"
    fi
    device_name="$(sed -n 's/^installing to iPhone: //p' "$install_log_raw" | tail -n1)"
    launch_args=(
        --bundle-id dev.tuist.agentty.iOS.exp
        --udid "{{ iphone_udid }}"
    )
    if [ -n "$device_name" ]; then
        launch_args+=(--installed-device-name "$device_name")
    fi
    if ! ./scripts/ios-devicectl-app-target "${launch_args[@]}"; then
        echo "warning: build and install succeeded, but auto-launch failed; open the app manually if needed" >&2
    fi

# Build + export dev ad-hoc IPA and host OTA install link on tailnet for 5 minutes
ios-build-host-dev-ota: _sync-local-llm-router-key _ensure-xcframework _ensure-project
    #!/bin/bash
    set -euo pipefail
    ./scripts/ios-host-dev-ota

# Run iPhone performance diagnostics (xctrace multi-template suite + analysis)
ios-perf-suite *args:
    #!/bin/bash
    set -euo pipefail
    ./scripts/ios-perf-suite {{ args }}

# Analyze an existing diagnostics run directory
ios-perf-analyze run_dir process_name="AgenTTY_iOS_Dev":
    #!/bin/bash
    set -euo pipefail
    ./scripts/ios-perf-analyze --run-dir "{{ run_dir }}" --process-name "{{ process_name }}"

# Clean Xcode build artifacts
xcode-clean:
    #!/bin/bash
    set -euo pipefail
    echo "Cleaning Xcode artifacts..."
    if [ -d "{{ project }}" ]; then
        xcodebuild -project "{{ project }}" -scheme "{{ scheme }}" clean -quiet 2>/dev/null || true
    fi
    echo "Done."

# Remove cloned source repos (forces fresh clone on next build)
ghostty-reset-sources: _ensure-vendor
    #!/bin/bash
    set -euo pipefail
    echo "Removing {{ sources }}..."
    rm -rf "{{ sources }}"
    echo "Done. Run 'just ghostty-rebuild-xcframework' to re-clone and rebuild."

# --- Internal recipes ---

# Clone repos if missing, pin to exact commits, verify build.zig.zon
_setup:
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
_check-ghostty-toolchain:
    #!/bin/bash
    set -euo pipefail
    zig_bin="$({{ ghostty_zig_toolchain_script }})"
    ghostty_developer_dir="${DEVELOPER_DIR:-/Applications/Xcode-27.2.0-release.candidate.app/Contents/Developer}"
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

# Build GhosttyKit xcframework via zig
_build-xcframework:
    #!/bin/bash
    set -euo pipefail
    zig_bin="$({{ ghostty_zig_toolchain_script }})"
    ghostty_developer_dir="${DEVELOPER_DIR:-/Applications/Xcode-27.2.0-release.candidate.app/Contents/Developer}"
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

# Copy xcframework to Vendor/ and fix module maps
_install-xcframework:
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
    just --justfile Justfile ghostty-validate-xcframework
    echo "▸ xcframework installed, module maps verified"

ios-check:
    ./scripts/ios-public build

ios-test:
    ./scripts/ios-public test

