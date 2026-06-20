#!/bin/sh
# guard-symbols.sh --- enforce the screensaver out-of-process invariants.
#
# Copyright (C) 2026 Zach Podbielniak
# SPDX-License-Identifier: AGPL-3.0-or-later
#
# 1. The Emacs-side screensaver objects reference ZERO libregnum/raylib symbols
#    (proof the render path really moved into the child process).
# 2. The cmacs-screensaver-render binary DOES resolve libregnum symbols (it is
#    the module host) AND defines NO Emacs symbols (a crash there can't corrupt
#    the editor -- it is standalone like emacsctl).
# 3. gowl still links zero libregnum (the long-standing "gowl never depends on
#    libregnum" invariant).
#
# Run after a build:  sh guard-symbols.sh [SRCDIR]
# SRCDIR defaults to the in-tree build's src/ (three levels up).

set -e

# CDPATH= keeps `cd' from echoing the resolved directory into the capture.
here=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
root=$(CDPATH= cd -- "$here/../../../.." && pwd)   # tests -> render -> ... -> root
srcdir=${1:-"$root/src"}

fail=0
note() { printf '  %s\n' "$1"; }

# A built tree is required; skip cleanly if objects are absent (e.g. CI that
# only ran the unit tests).
if [ ! -e "$srcdir/cmacs-screensaver.o" ]; then
  echo "guard-symbols: no built screensaver objects in $srcdir -- skipping"
  exit 0
fi

echo "guard 1: Emacs screensaver objects are libregnum-free"
for o in cmacs-screensaver.o cmacs-screensaver-proto.o \
         cmacs-screensaver-defuns.o cmacs-screensaver-init.o; do
  [ -e "$srcdir/$o" ] || continue
  n=$(nm "$srcdir/$o" 2>/dev/null \
        | grep -cE ' (lrg_|grl_|rl[A-Z]|BeginDrawing|InitWindow)' || true)
  note "$o: $n libregnum/raylib refs"
  [ "$n" -eq 0 ] || fail=1
done

echo "guard 2: cmacs-screensaver-render is a standalone libregnum host"
bin="$srcdir/cmacs-screensaver-render"
if [ -x "$bin" ]; then
  lrg=$(nm -D "$bin" 2>/dev/null | grep -cE ' (lrg_|grl_)' || true)
  ema=$(nm "$bin" 2>/dev/null \
          | grep -cE ' [TtDdBb] (Fcons|make_fixnum|staticpro|Fsignal|emacs_abort|syms_of_)' \
          || true)
  note "lrg_/grl_ exported: $lrg (want >0)"
  note "Emacs symbols defined: $ema (want 0)"
  { [ "$lrg" -gt 0 ] && [ "$ema" -eq 0 ]; } || fail=1
else
  note "render binary not built (gowl off?) -- skipping guard 2"
fi

echo "guard 3: gowl links zero libregnum"
gowl_a=$(ls "$root"/deps/gowl/build/release/libgowl.a \
            "$srcdir"/libgowl-dedup.a 2>/dev/null | head -1 || true)
if [ -n "$gowl_a" ]; then
  n=$(nm "$gowl_a" 2>/dev/null | grep -cE ' (lrg_|grl_)' || true)
  note "gowl lrg_/grl_ symbols: $n (want 0)"
  [ "$n" -eq 0 ] || fail=1
else
  note "libgowl archive not found -- skipping guard 3"
fi

if [ "$fail" -ne 0 ]; then
  echo "guard-symbols: FAIL"
  exit 1
fi
echo "guard-symbols: PASS"
