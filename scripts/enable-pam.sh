#!/bin/bash
#
# howdy-enable-pam - wire pam_howdy into /etc/pam.d files.
#
# Adds the `auth sufficient howdy` line to the given PAM files (backup is
# created next to each file as <file>.howdy-backup), so facial authentication
# works for sudo, the GDM lock/login screen etc.
#
# Usage:
#   sudo howdy-enable-pam                       # default: sudo + gdm-password
#   sudo howdy-enable-pam /etc/pam.d/system-auth
#
# The line inserted is "sufficient": facial auth is tried first and your
# password still always works as fallback. Removing howdy from a file = delete
# the line (or restore the .howdy-backup copy).
set -euo pipefail

LINE="auth       sufficient   pam_howdy.so no_confirmation"

if [ "${EUID:-$(id -u)}" -ne 0 ]; then
	echo "Run as root: sudo howdy-enable-pam" >&2
	exit 1
fi

# defaults chosen for a typical Fedora/GNOME setup
TARGETS=("$@")
if [ ${#TARGETS[@]} -eq 0 ]; then
	TARGETS=(/etc/pam.d/sudo /etc/pam.d/gdm-password)
fi

for tgt in "${TARGETS[@]}"; do
	if [ ! -f "$tgt" ]; then
		echo "Skipping $tgt (not found)"
		continue
	fi
	if grep -q "pam_howdy.so" "$tgt"; then
		echo " already configured: $tgt"
		continue
	fi
	cp -a "$tgt" "$tgt.howdy-backup"
	sed -i "1i $LINE" "$tgt"
	echo " enabled: $tgt (backup: $tgt.howdy-backup)"
done

echo
echo "NOTE: to remove facial auth from a file, delete the pam_howdy.so line"
echo "(or restore the .howdy-backup). Logs go to /var/log/howdy."
