#!/usr/bin/env bash
#
# howdy AIO inner installer - runs from the extracted release tarball root.
# Installs to /opt/howdy + /usr/local/bin/howdy + the detected PAM module
# directory + /etc/howdy, then downloads the DNN (YuNet/SFace) models.
#
# Options:
#   --no-pam   skip touching /etc/pam.d (you wire PAM up manually)
#   --yes      answer yes to every prompt (non-interactive PAM wiring)
#
# Idempotent: safe to re-run to update files (your /etc/howdy config and
# face models are never overwritten).
set -euo pipefail

SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ASSUME_YES=0
WIRE_PAM=1
for arg in "$@"; do
	case "$arg" in
		--no-pam) WIRE_PAM=0 ;;
		--yes) ASSUME_YES=1 ;;
		*) echo "Unknown option: $arg" >&2; exit 2 ;;
	esac
done

if [ "${EUID:-$(id -u)}" -ne 0 ]; then
	echo "Please run as root (sudo bash install)" >&2
	exit 1
fi

echo "==> Installing howdy AIO files"

# --- file layout ---------------------------------------------------------
mkdir -p /etc/howdy/models /var/log/howdy
cp -a "$SRC/opt/." /opt/

# Everything under ./usr (CLI wrapper + share data incl. man, autocompletion)
cp -a "$SRC/usr/." /usr/

# --- PAM module ----------------------------------------------------------
# Find the directory where this distro's PAM actually lives
PAMDIR=""
for d in /usr/lib/security /usr/lib64/security /lib/security; do
	if [ -e "$d/pam_unix.so" ]; then PAMDIR="$d"; break; fi
done
if [ -z "$PAMDIR" ]; then
	echo "!! Could not find an existing PAM module directory; defaulting to /usr/lib/security"
	PAMDIR="/usr/lib/security"
	mkdir -p "$PAMDIR"
fi
install -m 0644 "$SRC/usr/lib/security/pam_howdy.so" "$PAMDIR/pam_howdy.so"
echo "   pam_howdy.so -> $PAMDIR/pam_howdy.so"
command -v ldconfig >/dev/null && ldconfig || true

# --- config --------------------------------------------------------------
# Never overwrite an existing config or the user's face models.
if [ -f /etc/howdy/config.ini ]; then
	echo "   /etc/howdy/config.ini exists - keeping it (the packaged one is at $SRC/etc/howdy/config.ini)"
else
	cp "$SRC/etc/howdy/config.ini" /etc/howdy/config.ini
	echo "   installed default /etc/howdy/config.ini (use_dnn = true)"
fi

# --- DNN models (first-run setup) ---------------------------------------
DNNDIR=/opt/howdy/data/dnn-data
if [ -f "$DNNDIR/face_recognition_sface_2021dec.onnx" ] && [ -f "$DNNDIR/face_detection_yunet_2023mar.onnx" ]; then
	echo "   DNN models already present"
else
	echo "==> Downloading face recognition models (~38 MB)..."
	if (cd "$DNNDIR" && ./install.sh); then
		echo "   models ready"
	else
		echo "!! Model download failed. Run 'sudo /opt/howdy/data/dnn-data/install.sh' before enrolling." >&2
	fi
fi

# --- PAM wiring ----------------------------------------------------------
# howdy is enrolled with 'auth sufficient ... no_confirmation': if it acts
# up you can always fall back to your password. Wiring is therefore safe.
prompt_yes() {
	[ "$ASSUME_YES" -eq 1 ] && return 0
	[ -t 0 ] || return 1
	read -r -p "$1 [y/N] " reply </dev/tty 2>/dev/null || return 1
	case "$reply" in [Yy]*) return 0 ;; *) return 1 ;; esac
}

if [ "$WIRE_PAM" -eq 1 ]; then
	for pfile in /etc/pam.d/sudo /etc/pam.d/gdm-password /etc/pam.d/common-auth; do
		[ -f "$pfile" ] || continue
		grep -q "pam_howdy.so" "$pfile" && { echo "   $pfile already references pam_howdy"; continue; }
		if prompt_yes "Add facial auth to $pfile? (password still works as fallback)"; then
			printf '\nauth sufficient pam_howdy.so no_confirmation\n' >> "$pfile"
			echo "   wired: $pfile"
		fi
	done
else
	echo ">> /etc/pam.d left untouched (--no-pam). To enable facial auth add first:"
	echo "     auth sufficient pam_howdy.so no_confirmation"
	echo "   to the top of the relevant /etc/pam.d files (e.g. sudo, gdm-password)."
fi

# --- done ----------------------------------------------------------------
echo
echo "howdy AIO installed."
echo "Next steps:"
echo "  1. sudo /usr/local/bin/howdy config       # set device_path (e.g. /dev/video0)"
echo "  2. sudo howdy add                         # guided multi-pose enrollment"
echo "  3. test: sudo howdy test (non-GUI build: use 'howdy list' / lock+unlock)"
echo "Diagnostics: sudo journalctl -t pam_howdy, log file: /var/log/howdy"
