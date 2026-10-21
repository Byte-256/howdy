#!/bin/sh
#
# howdy all-in-one quick installer.
#
# Usage (from GitHub CI-less setups):
#   curl -fsSL https://raw.githubusercontent.com/Byte-256/howdy/master/install.sh -o install-howdy.sh
#   sudo bash install-howdy.sh
#
# or, if your shell allows it:
#   curl -fsSL https://raw.githubusercontent.com/Byte-256/howdy/master/install.sh | sudo bash -s -- [flags]
#
# Flags accepted (passed to the inner installer):
#   --no-pam    skip wiring /etc/pam.d (manual PAM setup)
#   --yes       accept prompts non-interactively (adds pam_howdy lines everywhere)
#
# Env overrides:
#   REPO=owner/name     GitHub repo with the releases (default: Byte-256/howdy)
#   HOWDY_VERSION=vX.Y  install a specific release instead of the latest
set -eu

REPO="${REPO:-Byte-256/howdy}"
ARCH="$(uname -m)"
case "$ARCH" in
	x86_64) ARCH_OK=1 ;;
	aarch64|arm64) ARCH=aarch64 ;;
	*) echo "Unsupported machine architecture: $ARCH (only x86_64 and aarch64 are packaged)" >&2; exit 1 ;;
esac

for bin in curl tar sha256sum; do
	command -v "$bin" >/dev/null 2>&1 || { echo "required tool not found: $bin" >&2; exit 1; }
done

TMPDIR_Q="$(mktemp -d || mktemp -d /tmp/howdy-install.XXXXXX)"
trap 'rm -rf "$TMPDIR_Q"' EXIT INT TERM
cd "$TMPDIR_Q"

# find the newest release's matching asset
if [ -n "${HOWDY_VERSION:-}" ]; then
	API_URL="https://api.github.com/repos/$REPO/releases/tags/$HOWDY_VERSION"
else
	API_URL="https://api.github.com/repos/$REPO/releases/latest"
fi
API_JSON="api-$(date +%s).json"
curl -fsSL -H "Accept: application/vnd.github+json" "$API_URL" -o "$API_JSON" \
	|| { echo "Could not list releases of https://github.com/$REPO - is there a published release?" >&2; exit 1; }

URL="$(grep -o "https://[^\"]*howdy-aio-[^\"]*-${ARCH}\.tar\.gz" "$API_JSON" | tail -1)"
SHA_URL="$(grep -o "https://[^\"]*howdy-aio-[^\"]*-${ARCH}\.tar\.gz\.sha256" "$API_JSON" | tail -1)"
[ -n "$URL" ] || { echo "No linux-${ARCH} asset found in the latest release of $REPO" >&2; exit 1; }

echo "==> Downloading howdy AIO: ${URL##*/}"
curl -fsSL --retry 3 "$URL" -o howdy.tar.gz

# verify checksum
if [ -n "$SHA_URL" ]; then
	curl -fsSL --retry 3 "$SHA_URL" -o howdy.tar.gz.sha256
	if echo "$(cat howdy.tar.gz.sha256)  howdy.tar.gz" | sha256sum -c --status 2>/dev/null; then
		echo "    checksum ok"
	else
		echo "checksum MISMATCH, aborting" >&2
		exit 1
	fi
else
	echo "!! No checksum file published for this release, skipping verification" >&2
fi

tar -xzf howdy.tar.gz
[ -f ./install ] || { echo "tarball is malformed (no ./install)" >&2; exit 1; }

# hand over to the inner installer, forwarding any flags
if [ "$(id -u)" -eq 0 ]; then
	bash ./install "$@"
else
	echo "==> Not root - elevating with sudo to run the installer"
	sudo bash ./install "$@"
fi

echo
echo "Install finished. Cleanup done automatically."
