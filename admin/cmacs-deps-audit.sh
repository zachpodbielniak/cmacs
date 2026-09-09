#!/usr/bin/env bash
# cmacs-deps-audit.sh --- which nested submodules does this tree actually use?
#
# Copyright (C) 2026 Zach Podbielniak
# SPDX-License-Identifier: AGPL-3.0-or-later
#
# cmacs pulls in deps that bundle their own copies of deps cmacs already
# has.  Most of those copies are never used -- the build is pointed at
# the canonical one with a *_DIR override -- and cloning them cost about
# 3 GB of a fresh checkout.  This says which are which, so
# SKIP_SUBMODULES in the Justfile can be extended safely.
#
# THE WHOLE POINT IS THE THIRD COLUMN.  "Produces no library" is not the
# same as "unused": raygui, rres and rpng are header-only, compiled
# straight into graylib's sources, and an audit that looked only for
# .a/.so files reported all three as dead weight.  Pruning on that answer
# breaks the build in a way that looks nothing like a missing submodule.
#
# So a checkout is USED when any of:
#   built    an UNTRACKED .a/.so lives under it.  Tracked ones are
#            shipped prebuilts -- steamworks vendors four -- and say
#            nothing about whether this tree built anything.
#   build    its parent's makefiles name deps/<basename>, which is how a
#            header-only dependency earns its include path.
#   include  a source outside it includes a header that exists in it.
#
# Only a checkout that is none of those three is a prune candidate, and
# even then this REPORTS rather than asserts: a dep that starts using a
# bundled copy should show up as a row changing, not as a build that
# silently picks the wrong copy.

set -uo pipefail

cd "$(dirname "$0")/.." || exit 1

printf '%-58s %7s  %-8s %s\n' PATH SIZE STATUS WHY
printf '%-58s %7s  %-8s %s\n' "$(printf '%.58s' "------------------------------------------------------------")" \
       "-------" "--------" "---"

# shellcheck disable=SC2016  # git expands $displaypath, not us
git submodule foreach --recursive --quiet 'echo "$displaypath"' 2>/dev/null | sort | while read -r d; do
	case "$d" in
	*/deps/*|*/extlib/*|*/subprojects/*) ;;
	*) continue ;;
	esac
	[ -d "$d" ] || continue

	parent=${d%/*}          # .../deps or .../extlib
	parent=${parent%/*}     # the repository holding it
	# The last two components, e.g. `deps/raudio' or `extlib/eigen'.
	# That is how every consumer spells it, at whatever depth.
	tail2=${d#"${d%/*/*}"/}
	why=""

	# 1. Did we build something here?  Untracked only.
	if git -C "$d" ls-files --others --ignored --exclude-standard 2>/dev/null \
	     | grep -qE '\.(a|so)$'; then
		why="built"
	fi

	# 2. Do ANY of its ancestors' build files name it?  This is how a
	#    header-only dependency gets its -I, and the only trace it
	#    leaves.
	#
	#    Every ancestor, not just the immediate parent: cad-glib
	#    compiles the solvespace solver itself, with
	#    `-isystem $(SLVS_DIR)/extlib/eigen', from a Makefile TWO levels
	#    above extlib/eigen.  Looking only at the containing repository
	#    called eigen and mimalloc unused, and both are load-bearing.
	if [ -z "$why" ]; then
		anc=$parent
		while [ -n "$anc" ] && [ "$anc" != "." ]; do
			if grep -rqE "$tail2([/ \"')]|\$)" \
			     "$anc"/Makefile "$anc"/*.mk "$anc"/CMakeLists.txt \
			     2>/dev/null; then
				why="build-ref:$anc"
				break
			fi
			[ "$anc" = "${anc%/*}" ] && break
			anc=${anc%/*}
		done
	fi

	# 3. Does a source in the containing repository include a header
	#    that lives in it?
	if [ -z "$why" ] && [ -d "$parent/src" ]; then
		hdrs=$(find "$d" -maxdepth 3 -name '*.h' -printf '%f\n' 2>/dev/null \
		       | sort -u | head -40)
		for h in $hdrs; do
			if grep -rqE "#include *[<\"]${h}[>\"]" "$parent/src" 2>/dev/null; then
				why="include:$h"
				break
			fi
		done
	fi

	if [ -n "$why" ]; then status=used; else status=UNUSED; why="-"; fi

	printf '%-58s %7s  %-8s %s\n' "$d" \
	       "$(du -sh "$d" 2>/dev/null | cut -f1)" "$status" "$why"
done
