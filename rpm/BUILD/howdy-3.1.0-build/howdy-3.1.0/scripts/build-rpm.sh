#!/usr/bin/env bash
# Build the fork's RPM locally. Result: rpm/RPMS/x86_64/howdy-3.1.0-1.fc44.x86_64.rpm
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

VERSION="3.1.0"
TOPDIR="$REPO_ROOT/rpm"
mkdir -p "$TOPDIR"/{BUILD,SOURCES,SPECS,RPMS}

# source tarball from the current commit (scripts/, install.sh, workflow included)
git archive --format=tar.gz --prefix=howdy-$VERSION/ HEAD -o "$TOPDIR/SOURCES/howdy-$VERSION.tar.gz"

# reuse already-downloaded onnx models so rpmbuild does not fetch them again
mkdir -p "$TOPDIR/SOURCES"
for m in face_detection_yunet_2023mar.onnx face_recognition_sface_2021dec.onnx; do
	if [ -f "/usr/share/howdy-dnn/$m" ]; then
		cp "/usr/share/howdy-dnn/$m" "$TOPDIR/SOURCES/$m"
	fi
done

rpmbuild --define "_topdir $TOPDIR" -bb "$TOPDIR/howdy.spec"

echo
echo "Built rpms:"
ls -lh "$TOPDIR"/RPMS/*/*.rpm
