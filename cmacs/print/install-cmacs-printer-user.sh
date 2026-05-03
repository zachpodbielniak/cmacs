#!/bin/sh
# install-cmacs-printer-user.sh — per-user IPP-Everywhere install.
#
# Copyright (C) 2026 Zach Podbielniak
# SPDX-License-Identifier: AGPL-3.0-or-later
#
# Idempotent.  No sudo.  Writes only to:
#   ~/.local/libexec/cmacs/cmacs-print-handler
#   ~/.config/systemd/user/cmacs-print.service
#
# Designed for immutable / atomic / OSTree systems where
# /usr/lib/cups/backend/ is read-only.  Uses ippeveprinter (ships with
# CUPS) to expose a per-user IPP printer; cups-browsed discovers it
# via mDNS and surfaces it in the print dialogs of every GTK/Qt app.

set -eu

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
HANDLER_SRC="${SCRIPT_DIR}/cmacs-print-handler"
UNIT_SRC="${SCRIPT_DIR}/cmacs-print.service.in"

HANDLER_DST_DIR="${HOME}/.local/libexec/cmacs"
HANDLER_DST="${HANDLER_DST_DIR}/cmacs-print-handler"
UNIT_DST_DIR="${HOME}/.config/systemd/user"
UNIT_DST="${UNIT_DST_DIR}/cmacs-print.service"

# --- Sanity ---------------------------------------------------------

for f in "$HANDLER_SRC" "$UNIT_SRC"; do
  if [ ! -r "$f" ]; then
    echo "ERROR: missing source file: $f" >&2
    exit 1
  fi
done

if [ "$(id -u)" -eq 0 ]; then
  echo "ERROR: do not run as root.  This installer is per-user." >&2
  echo "  For the system-wide install, use install-cmacs-printer.sh instead." >&2
  exit 1
fi

# --- Locate ippeveprinter ------------------------------------------

IPPEVE="$(command -v ippeveprinter || true)"
if [ -z "$IPPEVE" ]; then
  echo "ERROR: ippeveprinter not found on PATH." >&2
  echo "  Install it (cups package on Fedora/Debian/Arch).  On" >&2
  echo "  Silverblue: 'rpm-ostree install cups' (reboot required)." >&2
  exit 1
fi

if ! command -v systemctl >/dev/null 2>&1; then
  echo "ERROR: systemctl not found.  Per-user install requires systemd." >&2
  exit 1
fi

# --- Stage files ---------------------------------------------------

echo "==> Installing handler to ${HANDLER_DST}"
install -d -m 0755 "$HANDLER_DST_DIR"
install -m 0755 "$HANDLER_SRC" "$HANDLER_DST"

echo "==> Generating systemd user unit at ${UNIT_DST}"
install -d -m 0755 "$UNIT_DST_DIR"

# Substitute absolute paths into the unit template.  systemd user-unit
# PATH is intentionally minimal, so ExecStart must use absolute paths.
# Use sed over `awk` for portability and to avoid shell-quote pitfalls
# in the substituted values (paths shouldn't contain |, but we use a
# rare delimiter to be safe).
sed \
  -e "s|@IPPEVE@|${IPPEVE}|g" \
  -e "s|@HANDLER@|${HANDLER_DST}|g" \
  "$UNIT_SRC" > "$UNIT_DST"
chmod 0644 "$UNIT_DST"

# --- Reload + enable + start --------------------------------------

systemctl --user daemon-reload
systemctl --user enable --now cmacs-print.service

# --- Cups-browsed advisory ----------------------------------------

# The IPP printer advertises via mDNS, but apps' print dialogs only
# see it if cups-browsed is creating a CUPS queue from the discovery.
# Most desktop spins ship cups-browsed enabled by default; flag it if
# missing or inactive so the user knows to fix it.
if command -v systemctl >/dev/null 2>&1; then
  if ! systemctl is-active --quiet cups-browsed 2>/dev/null; then
    cat <<'EOF'

NOTE: cups-browsed is not active.  Without it, mDNS-discovered
printers do not appear in app print dialogs.  Enable it with:

    sudo systemctl enable --now cups-browsed

(This is a one-time system-level command — your only sudo step.
On Silverblue/Atomic, /etc/systemd/ is writable, so it just works.)

EOF
  fi
fi

# --- Status --------------------------------------------------------

echo
echo "==> cmacs IPP virtual printer installed"
echo "    Handler: ${HANDLER_DST}"
echo "    Unit:    ${UNIT_DST}"
echo
echo "    Status:  systemctl --user status cmacs-print.service"
echo "    Logs:    journalctl --user -u cmacs-print.service -f"
echo "    Stop:    systemctl --user stop cmacs-print.service"
echo
echo "After cups-browsed sees the mDNS advertisement (a few seconds),"
echo "'cmacs' will appear in every app's print dialog."
