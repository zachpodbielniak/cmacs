#!/bin/sh
# uninstall-cmacs-printer-user.sh — remove per-user IPP virtual printer.
#
# Copyright (C) 2026 Zach Podbielniak
# SPDX-License-Identifier: AGPL-3.0-or-later

set -eu

HANDLER_DST="${HOME}/.local/libexec/cmacs/cmacs-print-handler"
UNIT_DST="${HOME}/.config/systemd/user/cmacs-print.service"

if [ "$(id -u)" -eq 0 ]; then
  echo "ERROR: do not run as root.  This uninstaller is per-user." >&2
  exit 1
fi

if command -v systemctl >/dev/null 2>&1; then
  if systemctl --user is-enabled --quiet cmacs-print.service 2>/dev/null \
     || systemctl --user is-active --quiet cmacs-print.service 2>/dev/null; then
    echo "==> Stopping + disabling cmacs-print.service"
    systemctl --user disable --now cmacs-print.service 2>/dev/null || true
  fi
fi

if [ -e "$UNIT_DST" ]; then
  echo "==> Removing ${UNIT_DST}"
  rm -f "$UNIT_DST"
fi

if [ -e "$HANDLER_DST" ]; then
  echo "==> Removing ${HANDLER_DST}"
  rm -f "$HANDLER_DST"
  # Remove the libexec/cmacs/ dir if empty.
  rmdir "$(dirname "$HANDLER_DST")" 2>/dev/null || true
fi

if command -v systemctl >/dev/null 2>&1; then
  systemctl --user daemon-reload 2>/dev/null || true
fi

echo "==> Done."
