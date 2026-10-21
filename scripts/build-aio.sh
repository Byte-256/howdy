#!/usr/bin/env bash
#
# Build the portable all-in-one (AIO) release tarball for howdy.
#
# The tarball bundles everything needed on the target machine:
#   - a self-contained CPython runtime (python-build-standalone)
#   - vendored Python deps (opencv-python-headless + numpy) inside the howdy
#     python directory, so no system site-packages are touched
#   - the compiled pam_howdy.so with a baked rpath + shared libs the module
#     needs (libevdev, libinih/INIReader, libstdc++, libgcc_s)
#   - config, CLI wrapper, bash completion, man page, dnn-data downloader
#
# EXCLUDED from the tarball: the onnx models (downloaded on first run by the
# inner installer), dlib models/data, howdy-gtk graphical sources, ffmpeg.
#
# Run this inside a Linux container (the CI workflow uses ubuntu:22.04):
#   ./scripts/build-aio.sh --install-deps   # installs apt deps (Debian/Ubuntu)
#   ./scripts/build-aio.sh                 # performs the actual build
# Output: dist/howdy-aio-<version>-<arch>.tar.gz + .sha256
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ARCH="$(uname -m)"
MODE="${1:-build}"
BUILD_DIR="$REPO_ROOT/dist/aio-build"

# python-build-standalone: resolve + download a pinned CPython 3.12
fetch_python() {
	local triple
	case "$ARCH" in
		x86_64)  triple="x86_64-unknown-linux-gnu" ;;
		aarch64) triple="aarch64-unknown-linux-gnu" ;;
		*) echo "Unsupported architecture: $ARCH" >&2; return 1 ;;
	esac
	local url
	url="$(curl -fsSL https://api.github.com/repos/astral-sh/python-build-standalone/releases/latest | \
		grep -o "https://[^\"]*cpython-3\.12\.[0-9]+[^\"/]*[^\"]*${triple}-install_only\.tar\.gz" | \
		tail -1)" || true
	if [ -z "$url" ]; then
		echo "Could not resolve a python-build-standalone asset for $triple" >&2
		return 1
	fi
	echo "Downloading $url"
	curl -fsSL --retry 3 "$url" -o "$BUILD_DIR/python.tar.gz"
	mkdir -p "$STAGE/opt/howdy/python"
	tar -xzf "$BUILD_DIR/python.tar.gz" -C "$STAGE/opt/howdy/python" --strip-components=1
}

case "$MODE" in
--install-deps)
	# Debian/Ubuntu only - this is what the CI workflow and local container use
	apt-get update
	DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
		git build-essential meson ninja-build pkg-config patchelf ca-certificates \
		curl tar gzip sha256sum libpam0g-dev libevdev-dev libinih-dev python3-dev \
		locales
	locale-gen en_US.UTF-8 || true
	exit 0
	;;
build)
	;;
*)
	echo "Usage: $0 [--install-deps | (no argument: build)]" >&2
	exit 2
	;;
esac

cd "$REPO_ROOT"
rm -rf "$BUILD_DIR"
mkdir -p "$BUILD_DIR" dist
STAGE="$BUILD_DIR/stage"

VER="$(git describe --tags --always 2>/dev/null || echo dev)"
OUT="dist/howdy-aio-${VER}-${ARCH}.tar.gz"

# ---- 1. compile + stage the meson install ------------------------------
meson setup "$BUILD_DIR/work" \
	-Dprefix=/usr/local \
	-Dconfig_dir=/etc/howdy \
	-Duser_models_dir=/etc/howdy/models \
	-Ddlib_data_dir=/opt/howdy/data/dlib-data \
	-Ddnn_data_dir=/opt/howdy/data/dnn-data \
	-Dlog_path=/var/log/howdy \
	-Dpython_path=/opt/howdy/python/bin/python3 \
	-Dpy_sources_dir=/opt/howdy/pysrc \
	-Dpam_dir=/usr/lib/security \
	-Dpam_rpath=/opt/howdy/syslibs \
	-Dinstall_in_site_packages=false \
	-Dinstall_pam_config=false \
	-Dwith_polkit=false \
	-Dcpp_link_args="-static-libstdc++ -static-libgcc"
meson compile -C "$BUILD_DIR/work"
DESTDIR="$STAGE" meson install -C "$BUILD_DIR/work"

# Drop the GTK UI from the AIO package (headless auth only)
rm -rf "$STAGE/opt/howdy/pysrc/howdy-gtk"
rm -rf "$STAGE/usr/local/share/howdy-gtk"

# ---- 2. bundled python runtime + vendored deps -------------------------
fetch_python
"$STAGE/opt/howdy/python/bin/python3" -m pip install \
	--disable-pip-version-check --no-compile --only-binary=:all: \
	--target "$STAGE/opt/howdy/pysrc/howdy" \
	"opencv-python-headless" "numpy"
# remove pip artifacts not needed at runtime
rm -rf "$STAGE/opt/howdy/pysrc/howdy/bin" \
	"$STAGE/opt/howdy/pysrc/howdy/pip" \
	"$STAGE/opt/howdy/pysrc/howdy/pip-*.dist-info" \
	"$STAGE/opt/howdy/pysrc/howdy/matplotlib" \
	"$STAGE/opt/howdy/pysrc/howdy/pandas"

# ---- 3. bundle shared libs the pam module needs ------------------------
mkdir -p "$STAGE/opt/howdy/syslibs"
BASE_RE='^(linux-vdso|ld-linux|libc\.so|libm\.so|libpthread|libdl\.so|libpam\.so|librt\.so|libutil|libnsl|libresolv)'
so="$STAGE/usr/lib/security/pam_howdy.so"

resolve_libs() {
	# recursively copy non-base dependencies of the given files into syslibs
	local copied=0
	local f obj full
	for f in "$@"; do
		while IFS= read -r line; do
			case "$line" in
				*"=>"*) obj="${line%% =>*}"; full="${line#*=> }"; full="${full%% (*}"; full="${full##* }" ;;
				*) continue ;;
			esac
			case "$obj" in $BASE_RE*) continue ;; esac
			case "$f" in
				"$STAGE"/opt/howdy/syslibs/*) [ "$obj" = "${f##*/}" ] && continue ;;
			esac
			cp -L "$full" "$STAGE/opt/howdy/syslibs/$obj"
			patchelf --set-rpath /opt/howdy/syslibs "$STAGE/opt/howdy/syslibs/$obj"
			copied=1
		done < <(ldd "$f" 2>/dev/null)
	done
	[ "$copied" -eq 1 ] && resolve_libs "$STAGE"/opt/howdy/syslibs/*
}
resolve_libs "$so"

# ---- 4. config, installer scripts, perms -------------------------------
# AIO default: enable the DNN pipeline (dlib is NOT bundled)
mkdir -p "$STAGE/etc/howdy/models"
sed 's/^use_dnn.*/use_dnn = true/' howdy/src/config.ini > "$STAGE/etc/howdy/config.ini"
chmod 0744 "$STAGE/etc/howdy/config.ini"

cp "$REPO_ROOT/scripts/aio-installer.sh" "$STAGE/install"
chmod +x "$STAGE/install"

cat > "$STAGE/uninstall" << 'EOF'
#!/usr/bin/env bash
# Remove the AIO howdy install (keeps /etc/howdy configs and user models)
set -e
rm -rf /opt/howdy
rm -f /usr/local/bin/howdy
for d in /usr/lib/security /usr/lib64/security /lib/security; do
	rm -f "$d/pam_howdy.so"
done
echo "Removed howdy AIO files. /etc/howdy (config + face models) was kept."
echo "NOTE: remove any 'pam_howdy.so' lines from /etc/pam.d/* yourself."
EOF
chmod +x "$STAGE/uninstall"

# ---- 5. tarball + checksum ---------------------------------------------
# stage/usr/lib/security/pam_howdy.so is placed at the distro-default path;
# the inner installer relocates it to wherever pam_unix.so actually lives.
( cd "$STAGE" && tar -czf "$REPO_ROOT/$OUT" . )
( cd "$REPO_ROOT" && sha256sum "$(basename "$OUT")" > "$OUT.sha256" )

echo
echo "Built: $OUT"
ls -lh "$OUT" "$OUT.sha256"
