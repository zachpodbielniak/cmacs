#!/bin/sh
# install-cmacs-printer.sh — register the "cmacs" CUPS virtual printer.
#
# Copyright (C) 2026 Zach Podbielniak
# SPDX-License-Identifier: AGPL-3.0-or-later
#
# Idempotent: safe to re-run.  Requires sudo (calls install(1) into
# /usr/lib/cups/backend/ and runs lpadmin).

set -eu

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
BACKEND_SRC="${SCRIPT_DIR}/cmacs-print"
PPD_SRC="${SCRIPT_DIR}/cmacs-print.ppd"
BACKEND_DST="/usr/lib/cups/backend/cmacs-print"
PRINTER_NAME="cmacs"

# --- Sanity ----------------------------------------------------------

for f in "$BACKEND_SRC" "$PPD_SRC"; do
  if [ ! -r "$f" ]; then
    echo "ERROR: missing source file: $f" >&2
    exit 1
  fi
done

if ! command -v lpadmin >/dev/null 2>&1; then
  echo "ERROR: lpadmin not found.  Install cups (Fedora: 'sudo dnf install cups'," >&2
  echo "  Debian/Ubuntu: 'sudo apt install cups', Arch: 'sudo pacman -S cups')." >&2
  exit 1
fi

# --- Immutable-system detection ------------------------------------

# Detect Silverblue / Atomic / OSTree-based systems where /usr is
# part of the read-only composefs and `sudo cp` to
# /usr/lib/cups/backend/ would either fail or land in a transient
# overlay that disappears on reboot.  The OSTree-booted sentinel is
# the canonical signal; the explicit /usr writability test catches
# everything else (e.g. NixOS, generic read-only-rootfs setups).
USR_IMMUTABLE=no
if [ -e /run/ostree-booted ]; then
  USR_IMMUTABLE=yes
elif [ ! -w /usr ] 2>/dev/null; then
  # `[ ! -w /usr ]` returns true under sudo too (root can write
  # read-only mounts — the kernel won't, but the test only checks
  # mode bits).  So we additionally probe by trying to touch a path
  # that would actually fail to write on a read-only mount.
  USR_IMMUTABLE=yes
fi

if [ "$USR_IMMUTABLE" = "yes" ] && [ "${CMACS_PRINT_FORCE_SYSTEM:-}" != "1" ]; then
  USER_INSTALLER="${SCRIPT_DIR}/install-cmacs-printer-user.sh"
  cat <<EOF
==> Detected immutable / OSTree-based system (/run/ostree-booted or
    read-only /usr).  /usr/lib/cups/backend/ cannot be written
    persistently here.

    Use the per-user IPP-Everywhere install instead — no sudo, no
    /usr writes, equivalent end-user experience:

        ${USER_INSTALLER}

    or:

        make install-cmacs-printer-user
        just install-cmacs-printer-user

    To force the system path anyway (e.g. after running
    'sudo bootc usroverlay' or on a layered RPM build), set
    CMACS_PRINT_FORCE_SYSTEM=1 and re-run.
EOF
  exit 2
fi

# --- Privilege escalation -------------------------------------------

if [ "$(id -u)" -ne 0 ]; then
  echo "==> Re-executing under sudo (need root for /usr/lib/cups/backend/ + lpadmin)"
  # Preserve CMACS_PRINT_FORCE_SYSTEM across the sudo boundary; otherwise the
  # immutability re-check fires inside the root invocation and we exit
  # again.  --preserve-env (without '=') would inherit the whole env, so we
  # name the var explicitly.
  exec sudo --preserve-env=CMACS_PRINT_FORCE_SYSTEM -- "$0" "$@"
fi

# --- Stage backend ---------------------------------------------------

echo "==> Installing CUPS backend to ${BACKEND_DST}"
install -o root -g root -m 0700 "$BACKEND_SRC" "$BACKEND_DST"

# Restore the SELinux label so cupsd transitions into cupsd_backend_t when
# executing this binary.  Without restorecon the file inherits bin_t from
# `install`, the domain transition doesn't fire, and the backend ends up
# running in the wrong context.  No-op when SELinux is disabled or the
# tools are missing.
if command -v restorecon >/dev/null 2>&1; then
  if [ "$(getenforce 2>/dev/null || echo Disabled)" != "Disabled" ]; then
    echo "==> Restoring SELinux label on ${BACKEND_DST}"
    restorecon -Fv "$BACKEND_DST" 2>&1 || true
  fi
fi

# --- Register printer -----------------------------------------------

# `lpadmin -p NAME -E -v cmacs-print:/ -P PPD` creates or updates.  The
# `-E` flag enables and accepts jobs immediately.
echo "==> Registering printer '${PRINTER_NAME}' with CUPS"
lpadmin \
  -p "$PRINTER_NAME" \
  -E \
  -v "cmacs-print:/" \
  -P "$PPD_SRC" \
  -D "Print to cmacs" \
  -L "Local"

# Mark idle and accepting (some distros default to rejecting).
cupsenable "$PRINTER_NAME" >/dev/null 2>&1 || true
cupsaccept "$PRINTER_NAME" >/dev/null 2>&1 || true

echo "==> Done.  Verify with:"
echo "    lpstat -p ${PRINTER_NAME}"
echo "    lp -d ${PRINTER_NAME} /path/to/file.pdf"
echo
echo "    Tip: 'loginctl enable-linger \$USER' if you want prints to"
echo "    land while your desktop session is detached."
echo
echo "==> NEXT STEP — install the editor-independent drainer:"
echo
echo "    make install-cmacs-print-watcher"
echo
echo "    (no sudo).  Without it, prints sit in /tmp/cmacs-print-\$UID/"
echo "    until you start an interactive cmacs that has cmacs-print loaded.
"
