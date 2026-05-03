#!/bin/sh
# uninstall-cmacs-print-watcher.sh — remove the per-user drainer.
#
# Copyright (C) 2026 Zach Podbielniak
# SPDX-License-Identifier: AGPL-3.0-or-later

set -eu

UNIT_DST_DIR="${HOME}/.config/systemd/user"
PATH_DST="${UNIT_DST_DIR}/cmacs-print-drain.path"
SERVICE_DST="${UNIT_DST_DIR}/cmacs-print-drain.service"

if [ "$(id -u)" -eq 0 ]; then
  echo "ERROR: do not run as root.  This uninstaller is per-user." >&2
  exit 1
fi

if command -v systemctl >/dev/null 2>&1; then
  for u in cmacs-print-drain.path cmacs-print-drain.service; do
    if systemctl --user is-enabled --quiet "$u" 2>/dev/null \
       || systemctl --user is-active --quiet "$u" 2>/dev/null; then
      echo "==> Stopping + disabling $u"
      systemctl --user disable --now "$u" 2>/dev/null || true
    fi
  done
fi

for f in "$PATH_DST" "$SERVICE_DST"; do
  if [ -e "$f" ]; then
    echo "==> Removing $f"
    rm -f "$f"
  fi
done

if command -v systemctl >/dev/null 2>&1; then
  systemctl --user daemon-reload 2>/dev/null || true
fi

echo "==> Done."
