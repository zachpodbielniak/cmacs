#!/bin/sh
# uninstall-cmacs-printer.sh — remove the "cmacs" CUPS virtual printer.
#
# Copyright (C) 2026 Zach Podbielniak
# SPDX-License-Identifier: AGPL-3.0-or-later
#
# Idempotent.  Removes the printer registration and the backend file.
# Does not touch any prints already in ~/Documents/notes/03_resources/cmacs-print/.

set -eu

BACKEND_DST="/usr/lib/cups/backend/cmacs-print"
PRINTER_NAME="cmacs"

if [ "$(id -u)" -ne 0 ]; then
  echo "==> Re-executing under sudo (need root to unregister CUPS printer)"
  exec sudo -- "$0" "$@"
fi

if command -v lpadmin >/dev/null 2>&1; then
  if lpstat -p "$PRINTER_NAME" >/dev/null 2>&1; then
    echo "==> Removing printer '${PRINTER_NAME}'"
    lpadmin -x "$PRINTER_NAME"
  else
    echo "==> Printer '${PRINTER_NAME}' not registered — skipping"
  fi
fi

if [ -e "$BACKEND_DST" ]; then
  echo "==> Removing backend ${BACKEND_DST}"
  rm -f "$BACKEND_DST"
fi

echo "==> Done."
