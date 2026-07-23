#!/bin/sh
set -e

REPO="sakakibara/holt"
BIN="holt"

# Defaults, overridable by environment or flags.
INSTALL_DIR="${HOLT_INSTALL_DIR:-$HOME/.local/bin}"
VERSION="${HOLT_VERSION:-}"

usage() {
  cat <<EOF
Install $BIN.

Usage:
  install.sh [--version <vX.Y.Z>] [--dir <path>]

Options:
  --version <vX.Y.Z>   Version to install (default: latest release)
  --dir <path>         Install directory (default: ~/.local/bin)
  -h, --help           Show this help

Environment:
  HOLT_VERSION         Same as --version
  HOLT_INSTALL_DIR     Same as --dir

Examples:
  curl -fsSL <url> | sh
  curl -fsSL <url> | HOLT_INSTALL_DIR=/usr/local/bin sh
  curl -fsSL <url> | sh -s -- --version v0.1.0
EOF
}

err() { echo "Error: $*" >&2; exit 1; }

while [ $# -gt 0 ]; do
  case "$1" in
    --version) VERSION="$2"; shift 2 ;;
    --version=*) VERSION="${1#*=}"; shift ;;
    --dir) INSTALL_DIR="$2"; shift 2 ;;
    --dir=*) INSTALL_DIR="${1#*=}"; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Error: unknown option: $1" >&2; usage >&2; exit 1 ;;
  esac
done

# Pick a downloader once. fetch = to stdout, download = to a file.
if command -v curl >/dev/null 2>&1; then
  fetch()    { curl -fsSL "$1"; }
  download() { curl -fsSL -o "$2" "$1"; }
elif command -v wget >/dev/null 2>&1; then
  fetch()    { wget -qO- "$1"; }
  download() { wget -qO "$2" "$1"; }
else
  err "need curl or wget on PATH"
fi
command -v tar >/dev/null 2>&1 || err "need tar on PATH"

if [ -z "$VERSION" ]; then
  VERSION=$(fetch "https://api.github.com/repos/${REPO}/releases/latest" \
    | grep '"tag_name"' | sed -E 's/.*"tag_name": *"([^"]+)".*/\1/')
  [ -n "$VERSION" ] || err "could not determine latest release version"
fi

OS=$(uname -s | tr '[:upper:]' '[:lower:]')
ARCH=$(uname -m)
case "$OS" in
  darwin) OS="macos" ;;
  linux)  OS="linux" ;;
  *) err "unsupported OS: $OS (macOS and Linux are supported)" ;;
esac
case "$ARCH" in
  arm64|aarch64) ARCH="aarch64" ;;
  x86_64|amd64)  ARCH="x86_64" ;;
  *) err "unsupported architecture: $ARCH" ;;
esac

ARCHIVE="${BIN}-${OS}-${ARCH}.tar.gz"
BASE="https://github.com/${REPO}/releases/download/${VERSION}"

TMPDIR=$(mktemp -d)
trap 'rm -rf "$TMPDIR"' EXIT

echo "Downloading $BIN $VERSION for $OS/$ARCH..."
download "${BASE}/${ARCHIVE}" "$TMPDIR/$ARCHIVE" || err "download failed: ${BASE}/${ARCHIVE}"

# Verify the archive against the release's published checksums when both the
# file and a hasher are available; a mismatch is fatal, a missing hasher is
# skipped. Current releases publish SHA256SUMS; pre-0.6.1 published
# checksums.txt, so fall back to that name (same GNU sha256sum format).
sums=$(fetch "${BASE}/SHA256SUMS" 2>/dev/null) || sums=""
[ -n "$sums" ] || sums=$(fetch "${BASE}/checksums.txt" 2>/dev/null) || sums=""
if [ -n "$sums" ]; then
  expected=$(echo "$sums" | awk -v f="$ARCHIVE" '$2 == f { print $1 }')
  if [ -n "$expected" ]; then
    if command -v sha256sum >/dev/null 2>&1; then
      actual=$(sha256sum "$TMPDIR/$ARCHIVE" | awk '{print $1}')
    elif command -v shasum >/dev/null 2>&1; then
      actual=$(shasum -a 256 "$TMPDIR/$ARCHIVE" | awk '{print $1}')
    else
      actual=""
    fi
    if [ -n "$actual" ]; then
      [ "$actual" = "$expected" ] || err "checksum mismatch for $ARCHIVE"
      echo "Checksum verified."
    fi
  fi
fi

tar -xzf "$TMPDIR/$ARCHIVE" -C "$TMPDIR" || err "could not extract $ARCHIVE"
[ -f "$TMPDIR/$BIN" ] || err "archive did not contain $BIN"

mkdir -p "$INSTALL_DIR"
mv "$TMPDIR/$BIN" "$INSTALL_DIR/$BIN"
chmod +x "$INSTALL_DIR/$BIN"

# Print the version the freshly installed binary reports, which also confirms
# it runs on this machine; fall back to a plain message if it does not.
if installed=$("$INSTALL_DIR/$BIN" version 2>/dev/null); then
  echo "Installed $installed to $INSTALL_DIR/$BIN"
else
  echo "Installed $BIN to $INSTALL_DIR/$BIN"
fi

case ":$PATH:" in
  *":$INSTALL_DIR:"*) ;;
  *)
    echo "Note: $INSTALL_DIR is not on your PATH. Add it, e.g.:"
    echo "  export PATH=\"$INSTALL_DIR:\$PATH\""
    ;;
esac

echo "Then run '$BIN setup' to get started."
