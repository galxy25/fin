#!/bin/bash
# Builds the aarch64-linux fin-agentd binary in a Swift container (native arm64
# on Apple Silicon) and drops it at scripts/cloud-agent/dist/fin-agentd.
#
# --static-swift-stdlib so the instance needs no Swift runtime; the remaining
# dynamic deps (libcurl for FoundationNetworking, openssl) ship with AL2023.
# --scratch-path keeps llbuild's SQLite off the virtiofs bind mount (it asserts
# there — the same gotcha as the daemon's Linux CI runs).
#
# The amazonlinux2 image, NOT plain swift:6.1: the plain image is Ubuntu 24.04
# (glibc 2.39) and its binaries refuse to start on AL2023 (glibc 2.34) — live
# failure: "version GLIBC_2.38 not found", systemd restart loop. AL2's glibc
# 2.26 floor runs everywhere newer.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
DIST="$REPO_ROOT/scripts/cloud-agent/dist"
mkdir -p "$DIST"

docker run --rm \
  -v "$REPO_ROOT/daemon":/src \
  -w /src \
  swift:6.1-amazonlinux2 \
  bash -c "swift build -c release --product fin-agentd --static-swift-stdlib \
             --scratch-path /tmp/fin-agentd-build \
           && cp /tmp/fin-agentd-build/release/fin-agentd /src/fin-agentd-linux-arm64"

mv "$REPO_ROOT/daemon/fin-agentd-linux-arm64" "$DIST/fin-agentd"
chmod +x "$DIST/fin-agentd"
echo "==> Built $DIST/fin-agentd ($(du -h "$DIST/fin-agentd" | cut -f1))"
