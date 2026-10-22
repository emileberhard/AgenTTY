#!/usr/bin/env bash

NOTIFY_HELPER_TARGET_MATRIX=(
  "aarch64-apple-darwin|darwin-arm64|build"
  "x86_64-apple-darwin|darwin-x86_64|build"
  "aarch64-unknown-linux-musl|linux-arm64|zigbuild"
  "x86_64-unknown-linux-musl|linux-x86_64|zigbuild"
)
