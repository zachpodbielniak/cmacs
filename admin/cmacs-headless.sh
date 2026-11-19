#!/usr/bin/env bash
# cmacs-headless.sh --- run cmacs in a private, invisible compositor
#
# Copyright (C) 2026 Zach Podbielniak
# SPDX-License-Identifier: AGPL-3.0-or-later
#
# GUI work (a settings buffer, a right-click menu, a streaming overlay)
# has to be seen to be checked, but it must never pop windows on the
# desktop session it is developed on -- that is the user's live session,
# and under `emacs --gowl' it is the compositor itself.  So this starts
# gowl from this tree with the headless wlroots backend (GPU rendering
# through GLES on the render node, nothing on any screen), points a
# freshly built cmacs at it, and runs a driver scenario that takes
# screenshots with grim on the private display.
#
# Every process is signalled by the PID this script started, never by
# name (AGENTS.md: other image builds run on this host), and the runtime
# directory lives under $XDG_RUNTIME_DIR because a Wayland socket path
# must fit in 108 bytes.
#
# The scenario is an Elisp file loaded after test/cmacs/headless/
# cmacs-headless-driver.el; it calls `cmacs-headless-shot' and ends with
# `cmacs-headless-done'.  See doc_org/cmacs/build.org, "Headless runs".

set -euo pipefail

readonly SCRIPT_NAME="cmacs-headless.sh"

usage () {
	cat <<'EOF'
cmacs-headless.sh - run cmacs in a private headless gowl and take screenshots

Usage:
  admin/cmacs-headless.sh [OPTIONS] SCENARIO.el [-- EXTRA-EMACS-ARGS...]

Options:
  -o, --out DIR        where screenshots go (default: ./headless-shots)
  -s, --size WxH       output size (default: 1920x1080)
  -t, --timeout SECS   kill the run after SECS (default: 300)
  -e, --emacs PATH     the emacs to run (default: src/emacs)
  -k, --keep           keep the runtime dir (compositor + emacs logs)
  -h, --help           show this help
      --license        show the license

Examples:
  # phase screenshots for the speech subsystem
  admin/cmacs-headless.sh -o /tmp/shots test/cmacs/headless/speech-settings.el

  # same, with Emacs's own debugger output kept for inspection
  admin/cmacs-headless.sh --keep test/cmacs/headless/speech-menu.el
EOF
}

license () {
	cat <<'EOF'
cmacs-headless.sh
Copyright (C) 2026 Zach Podbielniak

This program is free software: you can redistribute it and/or modify it
under the terms of the GNU Affero General Public License as published by
the Free Software Foundation, either version 3 of the License, or (at
your option) any later version.

This program is distributed in the hope that it will be useful, but
WITHOUT ANY WARRANTY; without even the implied warranty of
MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU Affero
General Public License for more details.

You should have received a copy of the GNU Affero General Public License
along with this program.  If not, see <https://www.gnu.org/licenses/>.
EOF
}

gowl_pid=""
emacs_pid=""
runtime=""
keep="no"

cleanup () {
	if [[ -n "${emacs_pid}" ]] && kill -0 "${emacs_pid}" 2>/dev/null
	then
		kill -TERM "${emacs_pid}" 2>/dev/null || true
		wait "${emacs_pid}" 2>/dev/null || true
	fi
	if [[ -n "${gowl_pid}" ]] && kill -0 "${gowl_pid}" 2>/dev/null
	then
		kill -TERM "${gowl_pid}" 2>/dev/null || true
		wait "${gowl_pid}" 2>/dev/null || true
	fi
	if [[ -n "${runtime}" && -d "${runtime}" ]]
	then
		if [[ "${keep}" == "yes" ]]
		then
			echo "${SCRIPT_NAME}: kept ${runtime}" >&2
		else
			rm -rf -- "${runtime}"
		fi
	fi
}

main () {
	local root out size timeout emacs scenario socket i w h
	local -a extra=()

	root="$(cd -- "$(dirname -- "$0")/.." >/dev/null && pwd)"
	out="${PWD}/headless-shots"
	size="1920x1080"
	timeout=300
	emacs="${root}/src/emacs"
	scenario=""

	while [[ $# -gt 0 ]]
	do
		case "${1}" in
			-o|--out) out="${2:?--out needs a directory}"; shift 2 ;;
			-s|--size) size="${2:?--size needs WxH}"; shift 2 ;;
			-t|--timeout) timeout="${2:?--timeout needs seconds}"; shift 2 ;;
			-e|--emacs) emacs="${2:?--emacs needs a path}"; shift 2 ;;
			-k|--keep) keep="yes"; shift ;;
			-h|--help) usage; exit 0 ;;
			--license) license; exit 0 ;;
			--) shift; extra=("$@"); break ;;
			-*) echo "${SCRIPT_NAME}: unknown option: ${1}" >&2; usage >&2; exit 1 ;;
			*) scenario="${1}"; shift ;;
		esac
	done

	if [[ -z "${scenario}" || ! -f "${scenario}" ]]
	then
		echo "${SCRIPT_NAME}: a scenario file is required" >&2
		usage >&2
		exit 1
	fi
	if ! command -v grim >/dev/null
	then
		echo "${SCRIPT_NAME}: grim is required for screenshots" >&2
		exit 1
	fi
	w="${size%x*}"
	h="${size#*x}"
	mkdir -p -- "${out}"
	out="$(cd -- "${out}" >/dev/null && pwd)"
	scenario="$(cd -- "$(dirname -- "${scenario}")" >/dev/null && pwd)/$(basename -- "${scenario}")"

	rm -f -- "${out}/.final-ok"
	trap cleanup EXIT INT TERM
	runtime="$(mktemp -d -p "${XDG_RUNTIME_DIR:-/tmp}" cmacs-hl-XXXXXX)"
	chmod 700 -- "${runtime}"
	mkdir -p -- "${runtime}/home"

	# Float every window so the frame keeps the size it asks for, and no
	# animations, so a screenshot never catches a transition.
	printf 'rules:\n  - app_id: "*"\n    floating: true\n    no-anim: true\nautostart: []\n' \
		> "${runtime}/gowl.yaml"

	env -i "HOME=${runtime}/home" "PATH=${PATH}" \
		"XDG_RUNTIME_DIR=${runtime}" GOWL_DISABLE_SYSTEMD=1 \
		WLR_BACKENDS=headless WLR_HEADLESS_OUTPUTS=1 WLR_RENDERER=gles2 \
		"LD_LIBRARY_PATH=${root}/deps/gowl/build/release" \
		"${root}/deps/gowl/build/release/gowl" --no-c-config \
		--config "${runtime}/gowl.yaml" \
		> "${runtime}/compositor.log" 2>&1 &
	gowl_pid=$!

	socket=""
	for (( i = 0; i < 100; i++ ))
	do
		socket="$(find "${runtime}" -maxdepth 1 -name 'wayland-[0-9]*' \
			! -name '*.lock' -printf '%f\n' | head -n1)"
		[[ -n "${socket}" ]] && break
		kill -0 "${gowl_pid}" 2>/dev/null || break
		sleep 0.1
	done
	if [[ -z "${socket}" ]]
	then
		cat -- "${runtime}/compositor.log" >&2
		echo "${SCRIPT_NAME}: the headless compositor never opened a socket" >&2
		exit 1
	fi
	# Size the headless output.  wlr-randr is optional: without it the
	# output keeps the backend default and the frame is fitted to it.
	if command -v wlr-randr >/dev/null
	then
		env "XDG_RUNTIME_DIR=${runtime}" "WAYLAND_DISPLAY=${socket}" \
			wlr-randr --output HEADLESS-1 --custom-mode "${w}x${h}" \
			>/dev/null 2>&1 || true
	fi
	echo "${SCRIPT_NAME}: headless gowl pid ${gowl_pid} on ${socket}" >&2

	# The user's real HOME for models and the eln cache, but the private
	# display only: DISPLAY is unset so nothing can fall back to X.
	env -u DISPLAY "XDG_RUNTIME_DIR=${runtime}" "WAYLAND_DISPLAY=${socket}" \
		"CMACS_HEADLESS_OUT=${out}" "CMACS_HEADLESS_WIDTH=${w}" \
		"CMACS_HEADLESS_HEIGHT=${h}" \
		"CMACS_MODULE_DIR=${root}/cmacs/bacon/modules" \
		"CMACS_GOWL_MODULE_DIR=${root}/deps/gowl/build/release/modules" \
		"${emacs}" -Q --eval '(setq inhibit-startup-screen t)' \
		-l "${root}/test/cmacs/headless/cmacs-headless-driver.el" \
		-l "${scenario}" "${extra[@]}" \
		> "${runtime}/emacs.log" 2>&1 &
	emacs_pid=$!

	for (( i = 0; i < timeout * 10; i++ ))
	do
		kill -0 "${emacs_pid}" 2>/dev/null || break
		sleep 0.1
	done
	if kill -0 "${emacs_pid}" 2>/dev/null
	then
		echo "${SCRIPT_NAME}: scenario timed out after ${timeout}s" >&2
		tail -n 40 -- "${runtime}/emacs.log" >&2
		exit 1
	fi
	wait "${emacs_pid}" || {
		# A scenario that ends on an open menu stops Emacs from outside
		# (see `cmacs-headless-shot-menu-final') and says so first.
		if [[ -f "${out}/.final-ok" ]]
		then
			rm -f -- "${out}/.final-ok"
			emacs_pid=""
			echo "${SCRIPT_NAME}: screenshots in ${out}" >&2
			ls -1 -- "${out}" >&2
			return 0
		fi
		echo "${SCRIPT_NAME}: emacs exited non-zero" >&2
		tail -n 40 -- "${runtime}/emacs.log" >&2
		emacs_pid=""
		exit 1
	}
	emacs_pid=""
	echo "${SCRIPT_NAME}: screenshots in ${out}" >&2
	ls -1 -- "${out}" >&2
}

main "$@"
