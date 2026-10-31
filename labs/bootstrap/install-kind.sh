#!/usr/bin/env bash
# Installs `kind` if it isn't already on PATH. Prefers Homebrew; falls back to
# downloading the correct binary for this OS/arch (e.g. darwin/arm64 on an M2).
set -euo pipefail

if command -v kind >/dev/null 2>&1; then
  echo "✓ kind already installed: $(kind --version)"
  exit 0
fi

if command -v brew >/dev/null 2>&1; then
  echo "Installing kind via Homebrew…"
  brew install kind
  echo "✓ $(kind --version)"
  exit 0
fi

OS=$(uname | tr '[:upper:]' '[:lower:]')
ARCH=$(uname -m)
case "$ARCH" in
  arm64 | aarch64) ARCH=arm64 ;;
  x86_64 | amd64) ARCH=amd64 ;;
  *) echo "✗ unsupported arch: $ARCH"; exit 1 ;;
esac

VER="v0.27.0"
URL="https://kind.sigs.k8s.io/dl/${VER}/kind-${OS}-${ARCH}"
echo "Downloading kind ${VER} for ${OS}/${ARCH}…"
curl -fsSLo /tmp/kind "$URL"
chmod +x /tmp/kind

if mv /tmp/kind /usr/local/bin/kind 2>/dev/null; then
  echo "✓ installed to /usr/local/bin/kind"
else
  echo "Need elevated permission to write /usr/local/bin…"
  sudo mv /tmp/kind /usr/local/bin/kind
  echo "✓ installed to /usr/local/bin/kind"
fi
kind --version
