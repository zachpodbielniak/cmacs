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
)

# A URL change in .gitmodules does NOT reach an already-cloned submodule:
# git uses the URL cached in .git/config when it was first initialised,
# and the failure then reads as a stale pin rather than a stale URL.
git submodule sync --recursive >/dev/null

# Top level first -- the skips below configure repositories that do not
# exist until their parent is checked out.
git submodule update --init

for entry in "${SKIP[@]}"; do
	parent=${entry%%=*}
	name=${entry#*=}
	if [ -e "$parent/.git" ]; then
		git -C "$parent" config "submodule.$name.update" none
	fi
done

git submodule update --init --recursive
