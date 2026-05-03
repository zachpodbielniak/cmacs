#!/bin/sh
# install-cmacs-print-watcher.sh — per-user systemd drainer.
#
# Copyright (C) 2026 Zach Podbielniak
# SPDX-License-Identifier: AGPL-3.0-or-later
#
# Idempotent.  No sudo.  Writes only to:
#   ~/.config/systemd/user/cmacs-print-drain.{path,service}
#
# Companion to install-cmacs-printer.sh (system mode).  After the CUPS
# backend writes a print job to /tmp/cmacs-print-<uid>/, this systemd
# user service drains it into ~/Documents/notes/03_resources/cmacs-print/
# regardless of whether you have an interactive cmacs running.
#
# When you DO have an interactive cmacs running (with cmacs-print.el
# loaded), its in-process file-notify watcher races this service.
# Whichever wins processes the file; the loser is a no-op since the
# original PDF was already cleaned up by the winner.

set -eu

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PATH_SRC="${SCRIPT_DIR}/cmacs-print-drain.path.in"
SERVICE_SRC="${SCRIPT_DIR}/cmacs-print-drain.service.in"

UNIT_DST_DIR="${HOME}/.config/systemd/user"
PATH_DST="${UNIT_DST_DIR}/cmacs-print-drain.path"
SERVICE_DST="${UNIT_DST_DIR}/cmacs-print-drain.service"

# --- Sanity ---------------------------------------------------------

for f in "$PATH_SRC" "$SERVICE_SRC"; do
  if [ ! -r "$f" ]; then
    echo "ERROR: missing source file: $f" >&2
    exit 1
  fi
done

if [ "$(id -u)" -eq 0 ]; then
  echo "ERROR: do not run as root.  This installer is per-user." >&2
  exit 1
fi

if ! command -v systemctl >/dev/null 2>&1; then
  echo "ERROR: systemctl not found.  This installer requires systemd." >&2
  exit 1
fi

# --- Locate cmacs binary + lisp dir --------------------------------

# Prefer the in-tree build (devs hack on it); fall back to /usr.
TREE_CMACS="$(cd "${SCRIPT_DIR}/../.." && pwd)/src/emacs"
TREE_LISP="$(cd "${SCRIPT_DIR}/../.." && pwd)/lisp"

if [ -x "${CMACS_PRINT_EMACS:-}" ]; then
  CMACS="$CMACS_PRINT_EMACS"
  LISP="${CMACS_PRINT_LISP:-$(dirname "$(dirname "$CMACS")")/lisp}"
elif [ -x "$TREE_CMACS" ]; then
  CMACS="$TREE_CMACS"
  LISP="$TREE_LISP"
elif command -v cmacs >/dev/null 2>&1; then
  CMACS="$(command -v cmacs)"
  LISP="$(dirname "$(dirname "$CMACS")")/share/emacs/$($CMACS --batch --eval '(princ emacs-version)' 2>/dev/null)/lisp"
else
  echo "ERROR: no cmacs binary found." >&2
  echo "  Set CMACS_PRINT_EMACS=/path/to/emacs to override," >&2
  echo "  or run from inside the cmacs source tree (where src/emacs exists)." >&2
  exit 1
fi

if [ ! -d "$LISP/cmacs" ]; then
  echo "ERROR: lisp/cmacs/ not found under $LISP" >&2
  echo "  Set CMACS_PRINT_LISP=/path/to/lisp to override." >&2
  exit 1
fi

SPOOL="/tmp/cmacs-print-$(id -u)"

echo "==> Resolved cmacs:    $CMACS"
echo "==> Resolved lisp dir: $LISP"
echo "==> Watching spool:    $SPOOL"

# --- Stage units ---------------------------------------------------

install -d -m 0755 "$UNIT_DST_DIR"

# Substitute @SPOOL@ / @CMACS@ / @LISP@.  Using `|` as the sed delimiter
# so paths can contain `/` freely; paths with `|` are pathological and
# don't survive the install -d above anyway.
sed \
  -e "s|@SPOOL@|${SPOOL}|g" \
  "$PATH_SRC" > "$PATH_DST"
chmod 0644 "$PATH_DST"

sed \
  -e "s|@SPOOL@|${SPOOL}|g" \
  -e "s|@CMACS@|${CMACS}|g" \
  -e "s|@LISP@|${LISP}|g" \
  "$SERVICE_SRC" > "$SERVICE_DST"
chmod 0644 "$SERVICE_DST"

# --- Reload + enable + start --------------------------------------

systemctl --user daemon-reload
systemctl --user enable --now cmacs-print-drain.path

# Drain anything sitting in the spool right now.  Glob via `set --` to
# avoid the bash-only `compgen`.  When no match, the literal pattern
# survives and the -e test fails; we suppress nullglob errors with a
# guard.
if [ -d "$SPOOL" ]; then
  set -- "$SPOOL"/*.pdf
  if [ -e "$1" ]; then
    echo "==> Draining existing spool contents now"
    systemctl --user start cmacs-print-drain.service
  fi
fi

echo
echo "==> cmacs-print drainer installed"
echo "    Path unit:    $PATH_DST"
echo "    Service unit: $SERVICE_DST"
echo
echo "    Status: systemctl --user status cmacs-print-drain.path"
echo "            systemctl --user status cmacs-print-drain.service"
echo "    Logs:   journalctl --user -u cmacs-print-drain.service -f"
echo
echo "Now any 'lp -d cmacs <file.pdf>' or app-print-to-cmacs will land in"
echo "  ~/Documents/notes/03_resources/cmacs-print/<TS>-<title>/"
echo "within ~1 second, with or without an interactive cmacs running."
