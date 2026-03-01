#!/usr/bin/env bash

set -euo pipefail

REPO="mhiro2/code-shape.nvim"
BINARY_NAME="code-shape-core"

build_from_source() {
  if command -v cargo >/dev/null 2>&1; then
    echo "Building from source with cargo..."
    (cd "${PLUGIN_DIR}/rust" && cargo build --release)
    echo "Build complete. Binary at: ${PLUGIN_DIR}/rust/target/release/${BINARY_NAME}"
    exit 0
  fi
  echo "cargo not found. Install Rust or use a tagged release." >&2
  exit 1
}

# Determine install directory (plugin directory)
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_DIR="$(dirname "$SCRIPT_DIR")"
INSTALL_DIR="${PLUGIN_DIR}/bin"
mkdir -p "$INSTALL_DIR"

# Determine OS and architecture
OS="$(uname -s)"
ARCH="$(uname -m)"

case "$OS" in
  Linux)  OS_TAG="linux" ;;
  Darwin) OS_TAG="macos" ;;
  *)
    echo "Unsupported OS: $OS (supported: Linux, macOS)" >&2
    exit 1
    ;;
esac

case "$ARCH" in
  x86_64|amd64) ARCH_TAG="x86_64" ;;
  aarch64|arm64) ARCH_TAG="aarch64" ;;
  *)
    echo "Unsupported architecture: $ARCH" >&2
    exit 1
    ;;
esac

ARTIFACT="${BINARY_NAME}-${OS_TAG}-${ARCH_TAG}"

if ! command -v curl >/dev/null 2>&1 || ! command -v tar >/dev/null 2>&1; then
  echo "curl and tar are required for binary download. Falling back to source build..." >&2
  build_from_source
fi

if ! command -v shasum >/dev/null 2>&1 && ! command -v sha256sum >/dev/null 2>&1; then
  echo "shasum or sha256sum is required for checksum verification. Falling back to source build..." >&2
  build_from_source
fi

resolve_tag() {
  if [ -n "${CODE_SHAPE_CORE_TAG:-}" ]; then
    echo "${CODE_SHAPE_CORE_TAG}"
    return
  fi

  if [ -d "${PLUGIN_DIR}/.git" ] && command -v git >/dev/null 2>&1; then
    local exact_tag
    exact_tag="$(git -C "${PLUGIN_DIR}" tag --points-at HEAD | head -1 || true)"
    if [ -n "${exact_tag}" ]; then
      echo "${exact_tag}"
      return
    fi
  fi

  echo ""
}

TAG="$(resolve_tag)"
if [ -n "${TAG}" ]; then
  echo "Using plugin tag: ${TAG}"
else
  echo "No exact plugin tag detected. Falling back to latest release." >&2
  TAG="$(curl -sS "https://api.github.com/repos/${REPO}/releases/latest" \
    | grep '"tag_name"' \
    | head -1 \
    | sed -E 's/.*"tag_name": *"([^"]+)".*/\1/')"
fi

if [ -z "${TAG}" ]; then
  echo "Failed to determine release tag." >&2
  build_from_source
fi

DOWNLOAD_URL="https://github.com/${REPO}/releases/download/${TAG}/${ARTIFACT}.tar.gz"
CHECKSUM_URL="${DOWNLOAD_URL}.sha256"

# Download and extract
TMPDIR=$(mktemp -d)
trap "rm -rf '$TMPDIR'" EXIT

echo "Downloading ${ARTIFACT}..."
if ! curl -sSfL "$DOWNLOAD_URL" -o "${TMPDIR}/${ARTIFACT}.tar.gz"; then
  echo "Download failed for tag ${TAG}. Falling back to source build..." >&2
  build_from_source
fi

echo "Downloading checksum..."
if ! curl -sSfL "$CHECKSUM_URL" -o "${TMPDIR}/${ARTIFACT}.tar.gz.sha256"; then
  echo "Checksum download failed for tag ${TAG}. Falling back to source build..." >&2
  build_from_source
fi

if command -v shasum >/dev/null 2>&1; then
  actual_sha="$(shasum -a 256 "${TMPDIR}/${ARTIFACT}.tar.gz" | awk '{print $1}')"
elif command -v sha256sum >/dev/null 2>&1; then
  actual_sha="$(sha256sum "${TMPDIR}/${ARTIFACT}.tar.gz" | awk '{print $1}')"
else
  echo "No SHA256 tool found (shasum/sha256sum)." >&2
  build_from_source
fi

expected_sha="$(awk '{print $1}' "${TMPDIR}/${ARTIFACT}.tar.gz.sha256")"
if [ -z "$expected_sha" ] || [ "$actual_sha" != "$expected_sha" ]; then
  echo "Checksum verification failed." >&2
  exit 1
fi

tar xzf "${TMPDIR}/${ARTIFACT}.tar.gz" -C "$TMPDIR"
install -m 755 "${TMPDIR}/${ARTIFACT}" "${INSTALL_DIR}/${BINARY_NAME}"

echo "Installed ${BINARY_NAME} to ${INSTALL_DIR}/${BINARY_NAME}"
