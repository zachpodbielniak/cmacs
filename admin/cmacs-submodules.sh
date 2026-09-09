#!/usr/bin/env bash
# cmacs-submodules.sh --- populate deps/, minus the copies nothing builds
#
# Copyright (C) 2026 Zach Podbielniak
# SPDX-License-Identifier: AGPL-3.0-or-later
#
# `git submodule update --init --recursive' clones about 4 GB of nested
# copies that this tree never builds -- gsurf's and screensavers' own
# libregnum, libregnum's own cad-glib, and the crispy / yaml-glib /
# mcp-glib that every dep bundles and src/Makefile.in overrides with a
# *_DIR pointing at the canonical checkout.
#
# Skipping has to be a per-repository config setting, because
# `--recursive' cannot exclude a path below the top level.  That setting
# persists once written, which is why a bare `git submodule update' is
# correct on a machine where this has run and wrong on a fresh clone --
# CI, and a first `build-container', are exactly that.  So every caller
# runs this instead, and it is a plain script rather than a just recipe
# because neither of those has `just'.
#
# See doc_org/cmacs/build.org, "One Copy of Each Dependency".

set -euo pipefail

cd "$(dirname "$0")/.." || exit 1

# "<parent directory>=<submodule NAME as its parent's .gitmodules spells it>"
SKIP=(
	"deps/gsurf=deps/libregnum"
	"deps/screensavers=deps/libregnum"
	"deps/libregnum=deps/cad-glib"
	"deps/libregnum/deps/graylib=deps/raudio"
	"deps/gsurf=deps/crispy"
	"deps/libregnum=deps/crispy"
	"deps/libregnum=deps/mcp-glib"
	"deps/libregnum=deps/yaml-glib"
	"deps/podomation=deps/bacon"
	"deps/podomation=deps/crispy"
	"deps/podomation=deps/mcp-glib"
	"deps/podomation=deps/yaml-glib"
	"deps/podomation/deps/ai-glib=deps/yaml-glib"
	"deps/ai-glib=deps/yaml-glib"
	"deps/clawtilla/deps/libreclaw=deps/yaml-glib"
	"deps/clawtilla/deps/libreclaw=deps/mcp-glib"
	"deps/clawtilla/deps/libreclaw/deps/podomation=deps/crispy"
	"deps/clawtilla/deps/libreclaw/deps/podomation=deps/yaml-glib"
	"deps/clawtilla/deps/libreclaw/deps/podomation=deps/mcp-glib"
	"deps/clawtilla/deps/libreclaw/deps/ai-glib=deps/yaml-glib"
	# gowl, gsurf and bacon compile crispy's and yaml-glib's SOURCES into
	# their own archives.  They now take CRISPY_DIR / YAMLGLIB_DIR /
	# MCP_GLIB_DIR as build arguments and src/Makefile.in points every one
	# at the canonical checkout, so their bundled copies are dead weight
	# here -- and a standalone clone of any of them still defaults to its
	# own submodule.
	"deps/gowl=deps/crispy"
	"deps/gowl=deps/yaml-glib"
	"deps/gowl=deps/mcp-glib"
	"deps/gsurf=deps/yaml-glib"
	"deps/gsurf=deps/mcp-glib"
	"deps/bacon=deps/crispy"
	"deps/bacon=deps/yaml-glib"
	"deps/podomation/deps/bacon=deps/crispy"
	"deps/podomation/deps/bacon=deps/yaml-glib"
	# freetype's meson subproject.  cad-glib builds freetype through
	# cmake and by compiling sources directly, and never names dlg.
	"deps/cad-glib/deps/solvespace/extlib/freetype=dlg"
)

# A URL change in .gitmodules does NOT reach an already-cloned submodule:
# git uses the URL cached in .git/config when it was first initialised,
# and the failure then reads as a stale pin rather than a stale URL.
git submodule sync --recursive >/dev/null

# Level by level, NOT `git submodule update --init --recursive'.
#
# A skip is per-repository config, so it can only be written once its
# PARENT is checked out -- and a parent three levels down does not exist
# until an earlier pass cloned it.  `--recursive' does the whole tree in
# one call and gives no opportunity to configure a repository that is
# about to be created, so the deep skips silently did nothing on a fresh
# clone: six checkouts nobody builds came down anyway, while an already
# populated tree looked correct because the config had persisted from
# when those directories did exist.
#
# So: configure a repository, update only its immediate submodules, then
# descend into whatever that produced.
queue=("")

while [ ${#queue[@]} -gt 0 ]; do
	repo=${queue[0]}
	queue=("${queue[@]:1}")
	dir=${repo:-.}

	for entry in "${SKIP[@]}"; do
		parent=${entry%%=*}
		name=${entry#*=}
		if [ "$parent" = "$repo" ]; then
			git -C "$dir" config "submodule.$name.update" none
		fi
	done

	git -C "$dir" submodule update --init

	# Descend into the ones that are now checked out.  A skipped
	# submodule has no .git and is simply not followed.
	while read -r path; do
		[ -n "$path" ] || continue
		child=${repo:+$repo/}$path
		[ -e "$child/.git" ] || continue
		queue+=("$child")
	done < <(git config -f "$dir/.gitmodules" \
	           --get-regexp '^submodule\..*\.path$' 2>/dev/null \
	         | awk '{print $2}')
done
