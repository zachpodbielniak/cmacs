#!/usr/bin/env bash
# cmacs-perf.sh --- whole-editor performance workloads for cmacs
#
# Copyright (C) 2026 Zach Podbielniak
# SPDX-License-Identifier: AGPL-3.0-or-later
#
# A profiler says where time goes; this says whether a change made real
# editor work faster without changing what the editor did.  It replays
# fixed workloads (admin/cmacs-perf/*.el) inside a real Emacs -- batch for
# Lisp, buffers and search; `emacs -nw' in a private pseudo-terminal for
# anything whose cost is redisplay -- and keeps a sample only when the
# workload proves it did the same work (the CHECK half of every
# workload).  A fast wrong answer is never a sample.
#
# The method is ported from neomacs-perf (eval-exec/neomacs,
# crates/neomacs-perf), and so is its central lesson: wall time is not a
# verdict.  It moves with whatever else the machine is doing -- and this
# machine builds OS images next to cmacs.  Hardware counters do not:
# `perf stat' counts instructions and cycles for the editor alone, and
# only inside the workload's timed window, through perf's control FIFO
# (the workload writes enable/disable, perf acknowledges).  So:
#
#   - gate on cycles, read instructions beside them (a change can execute
#     more instructions in fewer cycles, and that is a win);
#   - `compare' interleaves the two editors, alternating which goes first,
#     so the baseline is a control: if both sides moved, the machine did;
#   - never compare numbers taken at different merge-bases.
#
# Layout of an output directory (default build/perf/):
#
#   <stamp>-<command>/
#     build-<label>/      the workload files, compiled by THAT editor
#     data/               read-only inputs shared by both editors
#     samples.csv         one row per sample, every run
#     summary.yaml        medians, MADs, ratios, verdicts
#     <workload>/<label>-<n>/
#       result.json       what the workload reported
#       counters.csv      raw `perf stat -x,' output
#       stderr.log        the editor's stderr
#       tty.log           the raw terminal byte stream (TUI only)
#       home/             the private HOME the editor ran with

set -uo pipefail
shopt -s nullglob

PF_SELF="${0##*/}"
PF_VERSION="1.0.0"
PF_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." >/dev/null && pwd)"
PF_LIB="${PF_ROOT}/admin/cmacs-perf"

# The counted events.  User-space only (`:u'), so the default
# perf_event_paranoid of 2 suffices and kernel noise stays out.
PF_EVENTS="instructions:u,cycles:u,branch-misses:u,task-clock"

# The terminal a TUI workload gets.  screen-256color, not xterm: Emacs's
# xterm support sends device-attribute queries at startup and waits up
# to two seconds for answers a headless pty never gives; the screen
# setup sends none.  140x40 gives a 140x39 frame, the grid the headless
# compositor's default floating window (1276x716) holds at PF_GUI_FONT,
# so all three display frontends lay out the same lines and columns.
PF_TERM="screen-256color"
PF_ROWS=40
PF_COLS=140

# Graphical frontends (lrg, pgtk) get one font, pinned because the two
# backends otherwise pick different defaults (126 vs 138 columns in the
# same pixels).  The window size is the compositor's: the headless one
# floats every window at the same default size, which the result
# records (frame.columns/lines/pixel_*) so a mismatch is visible.
PF_GUI_FONT="DejaVu Sans Mono-11"

# Options.
pf_editor=""
pf_baseline=""
pf_candidate=""
pf_iterations=""
pf_samples=5
pf_frontend=""
pf_baseline_frontend=""
pf_candidate_frontend=""
pf_lrg_spec="2d"
pf_extra_env=()
pf_priming=0
pf_display="headless"
pf_headless_pid=""
pf_headless_runtime=""
pf_headless_socket=""
declare -A PF_PRIMED=()
pf_counters="auto"
pf_native=0
pf_cpu=""
pf_source="${PF_ROOT}/lisp/simple.el"
pf_out="${PF_ROOT}/build/perf"
pf_timeout=600
pf_budget=""
pf_quiet=0

# Set per invocation.
pf_session=""
pf_status=0

pf_usage () {
	cat <<EOF
Usage: ${PF_SELF} [OPTION]... COMMAND [WORKLOAD]...

Replay deterministic editor workloads, check that each did exactly the
work it claims, and measure it with hardware counters scoped to the
workload's timed window.

Commands:
  list                 list the workloads (name, frontend, iterations,
                       suite budget, description)
  run WORKLOAD...      one sample of each workload with --editor
  compare WORKLOAD...  --samples interleaved samples of each workload
                       with --baseline and --candidate; medians, MADs,
                       ratio and change per metric
  suite [WORKLOAD]...  compare every workload (or those named) and fail
                       when any regresses past its budget
  profile WORKLOAD     perf record over the timed window only, with
                       DWARF call graphs; prints the self-time report

Options:
  -e, --editor PATH      editor for run, profile and list
                         (default: ${PF_ROOT}/src/emacs)
  -b, --baseline PATH    baseline editor for compare and suite (required)
  -c, --candidate PATH   candidate editor (default: the --editor default)
  -n, --iterations N     override every workload's iteration count
  -s, --samples N        samples per editor for compare/suite (default 5,
                         at least 3)
  -f, --frontend NAME    force batch, tui, lrg or pgtk instead of each
                         workload's own.  lrg is \`emacs --lrg' (the
                         libregnum backend), pgtk the stock GTK frame --
                         the control for lrg (same font stack, own
                         renderer).  All three display frontends lay out
                         the same 140x39 grid
      --baseline-frontend NAME, --candidate-frontend NAME
                         run each side of compare/suite on its own
                         frontend; with no --baseline, both sides use the
                         candidate editor (compare two display backends)
      --display WHERE    where lrg and pgtk windows go: headless (default;
                         a private, invisible gowl compositor rendering
                         on the GPU -- nothing appears on screen) or
                         session (the current graphical session)
      --lrg-spec SPEC    the --lrg SPEC for the lrg frontend (default 2d)
      --env VAR=VALUE    add VAR to every sample's environment
                         (repeatable), e.g. --env vblank_mode=0
      --counters         require perf counters (fail if perf cannot count)
      --no-counters      clocks only: no perf, nothing gated
      --native           native-compile the workloads instead of
                         byte-compiling them
      --cpu N            pin the editor to logical CPU N (taskset)
      --source FILE      Emacs Lisp file the editing workloads edit
                         (default: lisp/simple.el, copied once per session)
      --budget PCT       suite: one budget for every workload instead of
                         each workload's own
  -o, --out DIR          output directory (default: build/perf)
  -t, --timeout SECS     per-sample timeout (default ${pf_timeout})
  -q, --quiet            print only the final table and errors
  -h, --help             show this help and exit
      --license          show the license and exit
      --version          show the version and exit

Exit status: 0 success; 1 a sample was invalid (correctness mismatch or
infrastructure failure), or suite found a regression past its budget;
2 usage error.

Reading the numbers: gate on cycles and read instructions beside them;
treat wall time as a hint.  In a comparison, if the baseline sits in its
usual band with a tight MAD and only the candidate moved, it is real; if
both sides inflated and both MADs blew out, the machine was busy --
discard the run.  Check /proc/loadavg (recorded per sample).

The baseline must be a complete build tree of its own (a git worktree at
the older commit), not an older src/emacs-32.0.50.N binary: that binary
would load this tree's Lisp and native code.

Examples:
  # What is there:
  ${PF_SELF} list

  # One sample of two workloads with the tree's editor:
  ${PF_SELF} run lexical-loop scrolling

  # Did my change regress the bytecode call path?  (worktree baseline)
  ${PF_SELF} compare bytecode-call-loop \\
      --baseline ../cmacs-base/src/emacs --samples 9 --cpu 3

  # Everything, against budgets, through the Justfile:
  just perf-suite --baseline ../cmacs-base/src/emacs

  # The terminal frontend against the libregnum one, same build:
  ${PF_SELF} compare scrolling input-latency \\
      --baseline-frontend tui --candidate-frontend lrg

  # Where does the time go in scrolling?
  ${PF_SELF} profile scrolling --iterations 50
EOF
}

pf_license () {
	cat <<'EOF'
cmacs-perf.sh -- whole-editor performance workloads for cmacs
Copyright (C) 2026 Zach Podbielniak

This program is free software: you can redistribute it and/or modify
it under the terms of the GNU Affero General Public License as published
by the Free Software Foundation, either version 3 of the License, or
(at your option) any later version.

This program is distributed in the hope that it will be useful,
but WITHOUT ANY WARRANTY; without even the implied warranty of
MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
GNU Affero General Public License for more details.

You should have received a copy of the GNU Affero General Public License
along with this program.  If not, see <https://www.gnu.org/licenses/>.

The workload files in admin/cmacs-perf/ other than cmacs-perf.el and
cmacs-perf-pty.el are ported from neomacs-perf (Copyright (C) 2026 Eval
Exec and the neomacs contributors) and remain under the GNU General
Public License, version 3 or later.
EOF
}

# Progress to stderr unless --quiet.
pf_say () {
	if [[ ${pf_quiet} -eq 0 ]]
	then
		printf '%s\n' "$*" >&2
	fi
}

# An error to stderr; the run carries on.
pf_warn () {
	printf '%s: %s\n' "${PF_SELF}" "$*" >&2
}

# A fatal error.
pf_die () {
	printf '%s: %s\n' "${PF_SELF}" "$*" >&2
	exit 2
}

# ---------------------------------------------------------------------
# Building: compile the workload files with the editor that runs them
# ---------------------------------------------------------------------

# The workload sources, runtime first (the others require it).  The pty
# helper is a script for the driver, not a workload, so it is not here.
pf_sources () {
	local file

	printf '%s\n' "${PF_LIB}/cmacs-perf.el"
	for file in "${PF_LIB}"/cmacs-perf-*.el
	do
		if [[ ${file##*/} != cmacs-perf-pty.el ]]
		then
			printf '%s\n' "${file}"
		fi
	done
}

# The features to `-l', in load order: the basenames of pf_sources.
pf_features () {
	local file

	while IFS= read -r file
	do
		file="${file##*/}"
		printf '%s\n' "${file%.el}"
	done < <(pf_sources)
}

# pf_build EDITOR DIR
#
# Copy the workload files into DIR and compile them with EDITOR, so the
# bytecode is that editor's own.  Warnings are errors: a workload that
# compiles with a warning is a workload whose loop may not be what it
# says.  With --native the files are also native-compiled into DIR/eln.
pf_build () {
	if [[ $# -ne 2 ]]
	then
		pf_die 'pf_build() requires 2 positional arguments: pf_build <editor> <dir>'
	fi

	local editor="${1}"
	local dir="${2}"
	local -a files=()
	local file

	mkdir -p -- "${dir}" || return 1
	while IFS= read -r file
	do
		cp -- "${file}" "${dir}/" || return 1
		files+=("${dir}/${file##*/}")
	done < <(pf_sources)

	if ! "${editor}" -Q --batch -L "${dir}" \
		--eval '(setq byte-compile-error-on-warn t)' \
		-f batch-byte-compile "${files[@]}" >"${dir}/compile.log" 2>&1
	then
		pf_warn "byte-compiling the workloads with ${editor} failed:"
		cat -- "${dir}/compile.log" >&2
		return 1
	fi

	if [[ ${pf_native} -eq 1 ]]
	then
		if ! "${editor}" -Q --batch -L "${dir}" \
			--eval "(setq native-compile-target-directory \"${dir}/eln/\")" \
			-f batch-native-compile "${files[@]}" >>"${dir}/compile.log" 2>&1
		then
			pf_warn "native-compiling the workloads with ${editor} failed:"
			cat -- "${dir}/compile.log" >&2
			return 1
		fi
	fi
	return 0
}

# pf_catalog EDITOR BUILD
#
# Print the workload table (name TAB frontend TAB iterations TAB budget
# TAB primary metric TAB description), cached in BUILD/catalog.tsv.
pf_catalog () {
	if [[ $# -ne 2 ]]
	then
		pf_die 'pf_catalog() requires 2 positional arguments: pf_catalog <editor> <build>'
	fi

	local editor="${1}"
	local build="${2}"
	local -a load=()
	local feature

	if [[ ! -s ${build}/catalog.tsv ]]
	then
		while IFS= read -r feature
		do
			load+=(-l "${feature}")
		done < <(pf_features)
		if ! "${editor}" -Q --batch -L "${build}" "${load[@]}" \
			-f cmacs-perf-list >"${build}/catalog.tsv" 2>"${build}/catalog.log"
		then
			pf_warn "listing the workloads failed:"
			cat -- "${build}/catalog.log" >&2
			return 1
		fi
	fi
	cat -- "${build}/catalog.tsv"
}

# pf_catalog_field CATALOG NAME COLUMN -- one column of one workload.
pf_catalog_field () {
	if [[ $# -ne 3 ]]
	then
		pf_die 'pf_catalog_field() requires 3 positional arguments: pf_catalog_field <catalog> <name> <column>'
	fi

	local catalog="${1}"
	local name="${2}"
	local column="${3}"

	awk -F '\t' -v name="${name}" -v column="${column}" \
		'$1 == name { print $column; found = 1 } END { exit !found }' \
		"${catalog}"
}

# ---------------------------------------------------------------------
# One sample
# ---------------------------------------------------------------------

# What the workloads were compiled to: the result must agree.
pf_compiled_kind () {
	if [[ ${pf_native} -eq 1 ]]
	then
		printf native
	else
		printf bytecode
	fi
}

# Can perf count user-space events for our own processes here?
pf_counters_available () {
	command -v perf >/dev/null 2>&1 || return 1
	perf stat "-x," -e instructions:u -o /dev/null -- true >/dev/null 2>&1
}

# Decide once per invocation whether counters are on.
pf_resolve_counters () {
	case "${pf_counters}" in
		auto)
			if pf_counters_available
			then
				pf_counters="on"
			else
				pf_warn "perf cannot count here; clocks only (see --counters)"
				pf_counters="off"
			fi
			;;
		on)
			pf_counters_available \
				|| pf_die "--counters: perf cannot count user-space events (perf_event_paranoid=$(cat /proc/sys/kernel/perf_event_paranoid 2>/dev/null))"
			;;
		off)
			;;
	esac
}

# pf_counter CSV EVENT -- the value of EVENT in a `perf stat -x,' file,
# or nothing when perf did not count it.
pf_counter () {
	if [[ $# -ne 2 ]]
	then
		pf_die 'pf_counter() requires 2 positional arguments: pf_counter <csv> <event>'
	fi

	local csv="${1}"
	local event="${2}"

	awk -F, -v event="${event}" '
		/^#/ || NF < 3 { next }
		{
			name = $3
			sub(/:u$/, "", name)
			if (name == event && $1 ~ /^[0-9.]+$/)
				print $1
		}' "${csv}"
}

# pf_editor_command FRONTEND EDITOR BUILD -- print, NUL-separated, the
# argv that runs the workload in EDITOR.
pf_editor_command () {
	if [[ $# -ne 3 ]]
	then
		pf_die 'pf_editor_command() requires 3 positional arguments: pf_editor_command <frontend> <editor> <build>'
	fi

	local frontend="${1}"
	local editor="${2}"
	local build="${3}"
	local feature
	# Native compilation in the background would be counted (perf counts
	# children) and would differ between editors, so it is off -- except
	# in a priming run, whose job is to compile what the measured runs
	# will load (see pf_prime).  With --native the workloads' own .eln
	# are put first on the load path.
	local prelude="(setq native-comp-jit-compilation nil)"

	if [[ ${pf_priming} -eq 1 ]]
	then
		# Everything but the workloads themselves: they are measured as
		# the bytecode pf_build made (or the .eln --native made).
		prelude="(when (featurep (quote native-compile)) (require (quote comp-run)) (setq native-comp-jit-compilation t) (push (regexp-quote \"${build}/\") native-comp-jit-compilation-deny-list))"
	fi

	if [[ ${pf_native} -eq 1 ]]
	then
		prelude="(progn ${prelude} (push \"${build}/eln/\" native-comp-eln-load-path))"
	fi

	case "${frontend}" in
		tui)
			printf '%s\0' "${editor}" -Q -nw
			;;
		lrg)
			# The libregnum backend, at the TUI's text grid so the two
			# frontends lay out the same number of lines and columns.
			printf '%s\0' "${editor}" -Q "--lrg=${pf_lrg_spec}" \
				-fn "${PF_GUI_FONT}" -geometry "${PF_COLS}x${PF_ROWS}"
			;;
		pgtk)
			# The stock GTK backend: the control for lrg, since both share
			# Emacs's font stack (fontconfig, cairo, FreeType, HarfBuzz)
			# and differ only in how glyphs reach the screen.
			printf '%s\0' "${editor}" -Q -fn "${PF_GUI_FONT}" \
				-geometry "${PF_COLS}x${PF_ROWS}"
			;;
		*)
			printf '%s\0' "${editor}" -Q --batch
			;;
	esac
	printf '%s\0' -L "${build}" --eval "${prelude}"
	if [[ ${frontend} == lrg || ${frontend} == pgtk ]]
	then
		# No menu, tool or scroll bars: pgtk has them and lrg does not,
		# and they would take lines from one side only.
		printf '%s\0' --eval \
			"(progn (menu-bar-mode -1) (tool-bar-mode -1) (scroll-bar-mode -1))"
	fi
	while IFS= read -r feature
	do
		printf '%s\0' -l "${feature}"
	done < <(pf_features)
	if [[ ${frontend} == batch ]]
	then
		printf '%s\0' -f cmacs-perf-main
	else
		# After startup, once the first frame exists, has been drawn and (on
		# a window system) has stopped being mapped and resized.
		printf '%s\0' --eval \
			"(add-hook 'emacs-startup-hook (lambda () (run-at-time 0 nil #'cmacs-perf-main-when-settled)))"
	fi
}

# pf_child_env FRONTEND DIR WORKLOAD -- print, NUL-separated, the
# environment a sample runs with (for `env -i').
#
# Clean and reproducible: no user configuration, a fixed locale and
# zone, a private HOME.  batch and tui get no display and no session
# bus, so nothing reaches the live desktop.  lrg and pgtk need a window,
# so they alone are handed the display variables and open one on the
# current session.  --env entries come last and win.
pf_child_env () {
	if [[ $# -ne 3 ]]
	then
		pf_die 'pf_child_env() requires 3 positional arguments: pf_child_env <frontend> <dir> <workload>'
	fi

	local frontend="${1}"
	local dir="${2}"
	local workload="${3}"
	local name entry

	printf '%s\0' "HOME=${dir}/home" "PATH=${PATH}" "LANG=C.UTF-8" \
		"LC_ALL=C.UTF-8" "TZ=UTC" \
		"CMACS_PERF_WORKLOAD=${workload}" \
		"CMACS_PERF_RESULT=${dir}/result.json" \
		"CMACS_PERF_DATA=${pf_session}/data" \
		"CMACS_PERF_ITERATIONS=$( [[ ${pf_priming} -eq 1 ]] && printf 1 || printf '%s' "${pf_iterations}")"
	if [[ ${pf_priming} -eq 1 ]]
	then
		printf '%s\0' "CMACS_PERF_PRIME=1"
	fi
	case "${frontend}" in
		tui) printf '%s\0' "TERM=${PF_TERM}" ;;
		*) printf '%s\0' "TERM=dumb" ;;
	esac
	if [[ ${frontend} == lrg || ${frontend} == pgtk ]]
	then
		if [[ ${pf_display} == headless ]]
		then
			printf '%s\0' "XDG_RUNTIME_DIR=${pf_headless_runtime}" \
				"WAYLAND_DISPLAY=${pf_headless_socket}" \
				"XDG_SESSION_TYPE=wayland"
		else
			for name in WAYLAND_DISPLAY DISPLAY XDG_RUNTIME_DIR XAUTHORITY \
				XDG_SESSION_TYPE
			do
				if [[ -n ${!name:-} ]]
				then
					printf '%s\0' "${name}=${!name}"
				fi
			done
		fi
	fi
	for entry in "${pf_extra_env[@]}"
	do
		printf '%s\0' "${entry}"
	done
}

# pf_launch FRONTEND EDITOR DIR COMMAND... -- run COMMAND (perf and the
# editor beneath it) the way FRONTEND needs: in a sized pseudo-terminal
# for tui, directly under timeout(1) otherwise.  Returns its status.
pf_launch () {
	if [[ $# -lt 4 ]]
	then
		pf_die 'pf_launch() requires at least 4 positional arguments: pf_launch <frontend> <editor> <dir> <command>...'
	fi

	local frontend="${1}"
	local editor="${2}"
	local dir="${3}"

	shift 3
	if [[ ${frontend} == tui ]]
	then
		"${editor}" -Q --batch -l "${PF_LIB}/cmacs-perf-pty.el" -- \
			"${PF_ROWS}" "${PF_COLS}" "${dir}/tty.log" "${pf_timeout}" \
			"$@" 2>"${dir}/stderr.log"
	else
		timeout --kill-after=10 "${pf_timeout}" "$@" \
			</dev/null >"${dir}/stdout.log" 2>"${dir}/stderr.log"
	fi
}

# ---------------------------------------------------------------------
# The headless display
# ---------------------------------------------------------------------

# pf_headless_start -- start a private, invisible Wayland compositor for
# the graphical frontends (lrg, pgtk) and remember its socket.
#
# A graphical sample needs a window, and windows on the user's own
# session pop up over whatever they are doing -- dozens per comparison.
# So by default the samples get a compositor of their own: gowl from
# this tree with the headless wlroots backend.  Nothing reaches a screen,
# but rendering still goes through the GPU (WLR_RENDERER=gles2 on the
# render node), so lrg is measured on real hardware GL rather than
# llvmpipe, which is what an Xvfb would give it.  One rule floats every
# window, so the two backends get the same default size (tiling would
# size them by how many windows are open).  The runtime directory is short and lives in
# $XDG_RUNTIME_DIR: a socket path must fit in 108 bytes.
pf_headless_start () {
	local gowl="${CMACS_PERF_GOWL:-${PF_ROOT}/deps/gowl/build/release/gowl}"
	local base="${XDG_RUNTIME_DIR:-/tmp}"
	local i

	[[ -n ${pf_headless_pid} ]] && return 0
	[[ -x ${gowl} ]] \
		|| pf_die "no gowl at ${gowl} for the headless display (build deps/gowl, set CMACS_PERF_GOWL, or use --display session)"
	pf_headless_runtime="$(mktemp -d -p "${base}" cmacs-perf-XXXXXX)" \
		|| pf_die "cannot create a runtime directory under ${base}"
	chmod 700 -- "${pf_headless_runtime}"
	printf 'rules:\n  - app_id: "*"\n    floating: true\n    no-anim: true\nautostart: []\n' \
		>"${pf_headless_runtime}/gowl.yaml"

	env -i "HOME=${pf_headless_runtime}" "PATH=${PATH}" \
		"XDG_RUNTIME_DIR=${pf_headless_runtime}" GOWL_DISABLE_SYSTEMD=1 \
		WLR_BACKENDS=headless WLR_HEADLESS_OUTPUTS=1 WLR_RENDERER=gles2 \
		"LD_LIBRARY_PATH=${gowl%/*}" \
		"${gowl}" --no-c-config --config "${pf_headless_runtime}/gowl.yaml" \
		>"${pf_headless_runtime}/compositor.log" 2>&1 &
	pf_headless_pid=$!

	# Wait for the socket rather than sleeping a guess.
	for (( i = 0; i < 100; i++ ))
	do
		pf_headless_socket="$(find "${pf_headless_runtime}" -maxdepth 1 \
			-name 'wayland-[0-9]*' ! -name '*.lock' -printf '%f\n' | head -n1)"
		[[ -n ${pf_headless_socket} ]] && break
		kill -0 "${pf_headless_pid}" 2>/dev/null || break
		sleep 0.1
	done
	if [[ -z ${pf_headless_socket} ]]
	then
		cat -- "${pf_headless_runtime}/compositor.log" >&2
		pf_die "the headless compositor never opened a socket"
	fi
	pf_say "display: headless gowl (pid ${pf_headless_pid}, ${pf_headless_socket})"
}

# shellcheck disable=SC2329  # invoked by the EXIT trap
# pf_headless_stop -- stop the compositor this run started (by its PID,
# never by name) and remove its runtime directory.
pf_headless_stop () {
	if [[ -n ${pf_headless_pid} ]]
	then
		kill -TERM "${pf_headless_pid}" 2>/dev/null
		wait "${pf_headless_pid}" 2>/dev/null
		pf_headless_pid=""
	fi
	if [[ -n ${pf_headless_runtime} && -d ${pf_headless_runtime} ]]
	then
		rm -rf -- "${pf_headless_runtime}"
	fi
}

# pf_home LABEL DIR -- create DIR/home with the session's eln-cache for
# LABEL's editor linked in.
#
# Every sample gets a private HOME, but the eln-cache inside it is one
# directory per editor per session.  Lisp that is not in the dump and
# has no ahead-of-time .eln is native-compiled when first loaded; with a
# fresh cache per sample that happened in EVERY sample, as child
# processes inside the counted window (~20% of a profile, in libgccjit
# and ld).  A shared cache filled by pf_prime is what a user's warm
# cache looks like.  Each editor keeps its own: .eln files are tied to
# the build that compiled them.
pf_home () {
	if [[ $# -ne 2 ]]
	then
		pf_die 'pf_home() requires 2 positional arguments: pf_home <label> <dir>'
	fi

	local label="${1}"
	local dir="${2}"

	mkdir -p -- "${dir}/home/.emacs.d" "${pf_session}/eln-${label}" || return 1
	ln -sfn -- "${pf_session}/eln-${label}" "${dir}/home/.emacs.d/eln-cache"
}

# pf_prime LABEL EDITOR BUILD FRONTEND WORKLOAD
#
# Run WORKLOAD once, untimed and uncounted, with native compilation ON,
# and let every compilation it starts finish before it exits, so the
# measured runs that follow load native code from LABEL's eln-cache
# instead of compiling it.  Once per (label, frontend, workload) per
# session.  A failed priming run is reported but not fatal: the measured
# run refuses itself if a compilation is still active in its window.
pf_prime () {
	if [[ $# -ne 5 ]]
	then
		pf_die 'pf_prime() requires 5 positional arguments: pf_prime <label> <editor> <build> <frontend> <workload>'
	fi

	local label="${1}"
	local editor="${2}"
	local build="${3}"
	local frontend="${4}"
	local workload="${5}"
	local key="${label}/${frontend}/${workload}"
	local dir="${pf_session}/prime/${label}-${frontend}-${workload}"
	local -a argv=() env_args=()

	[[ -z ${PF_PRIMED[${key}]:-} ]] || return 0
	PF_PRIMED[${key}]=1
	pf_home "${label}" "${dir}" || return 1
	pf_priming=1
	mapfile -d '' -t argv < <(pf_editor_command "${frontend}" "${editor}" "${build}")
	mapfile -d '' -t env_args < <(pf_child_env "${frontend}" "${dir}" "${workload}")
	pf_priming=0
	pf_say "prime: ${workload} ${label} (${frontend})"
	if ! pf_launch "${frontend}" "${editor}" "${dir}" env -i "${env_args[@]}" "${argv[@]}"
	then
		pf_warn "prime: ${workload} ${label} (${frontend}) did not finish cleanly; see ${dir}"
	fi
	return 0
}

# pf_sample WORKLOAD LABEL N EDITOR BUILD FRONTEND DIR
#
# Run one sample into DIR and append its row to the session's
# samples.csv.  Returns 0 for a valid sample, 1 otherwise.
pf_sample () {
	if [[ $# -ne 7 ]]
	then
		pf_die 'pf_sample() requires 7 positional arguments: pf_sample <workload> <label> <n> <editor> <build> <frontend> <dir>'
	fi

	local workload="${1}"
	local label="${2}"
	local n="${3}"
	local editor="${4}"
	local build="${5}"
	local frontend="${6}"
	local dir="${7}"
	local -a argv=()
	local -a env_args=()
	local -a wrapped=()
	local status="infrastructure-failure"
	local reported exit_code load
	local instructions="" cycles="" branch_misses="" task_clock=""

	pf_home "${label}" "${dir}" || return 1
	mapfile -d '' -t argv < <(pf_editor_command "${frontend}" "${editor}" "${build}")

	mapfile -d '' -t env_args < <(pf_child_env "${frontend}" "${dir}" "${workload}")
	env_args=(env -i "${env_args[@]}")

	if [[ -n ${pf_cpu} ]]
	then
		env_args=(taskset -c "${pf_cpu}" "${env_args[@]}")
	fi

	# perf starts with every event disabled (-D -1) and counts only
	# between the workload's enable and disable.
	if [[ ${pf_counters} == on ]]
	then
		rm -f -- "${dir}/ctl" "${dir}/ack"
		mkfifo -- "${dir}/ctl" "${dir}/ack" || return 1
		env_args+=("CMACS_PERF_CTL=${dir}/ctl" "CMACS_PERF_ACK=${dir}/ack")
		wrapped=(perf stat "-x," -e "${PF_EVENTS}" -D -1
			--control "fifo:${dir}/ctl,${dir}/ack"
			-o "${dir}/counters.csv" --)
	fi
	wrapped+=("${env_args[@]}" "${argv[@]}")

	load="$(cut -d' ' -f1 /proc/loadavg)"
	pf_launch "${frontend}" "${editor}" "${dir}" "${wrapped[@]}"
	exit_code=$?

	# The verdict comes from the result file, and must agree with the
	# exit status: a result that says ok from a process that died is not
	# a sample.
	if [[ -s ${dir}/result.json ]]
	then
		reported="$(yq -p json -o yaml -r '.status' "${dir}/result.json" 2>/dev/null)"
		if [[ ${reported} == ok && ${exit_code} -eq 0 ]] \
			&& [[ "$(yq -p json -o yaml -r '.schema' "${dir}/result.json")" == 1 ]] \
			&& [[ "$(yq -p json -o yaml -r '.workload' "${dir}/result.json")" == "${workload}" ]] \
			&& [[ "$(yq -p json -o yaml -r '.frontend' "${dir}/result.json")" == "${frontend}" ]] \
			&& [[ "$(yq -p json -o yaml -r '.compiled' "${dir}/result.json")" == "$(pf_compiled_kind)" ]]
		then
			status="ok"
		elif [[ ${reported} == mismatch ]]
		then
			status="correctness-mismatch"
		fi
	fi

	if [[ ${status} == ok && ${pf_counters} == on ]]
	then
		instructions="$(pf_counter "${dir}/counters.csv" instructions)"
		cycles="$(pf_counter "${dir}/counters.csv" cycles)"
		branch_misses="$(pf_counter "${dir}/counters.csv" branch-misses)"
		task_clock="$(pf_counter "${dir}/counters.csv" task-clock)"
		# An uncounted event is a failed sample, never a zero.
		if [[ -z ${instructions} || -z ${cycles} ]]
		then
			pf_warn "${workload}/${label}-${n}: perf did not count every event"
			status="infrastructure-failure"
		fi
	fi

	{
		printf '%s,%s,%s,%s,%s,' "${workload}" "${label}" "${n}" "${status}" "${load}"
		if [[ -s ${dir}/result.json ]]
		then
			yq -p json -o yaml -r '[.cpu_us, .wall_us, .cpu_ns_per_op, .gcs_done, .gc_us, (.primary // "")] | join(",")' \
				"${dir}/result.json" | tr -d '\n'
		else
			printf ',,,,,'
		fi
		printf ',%s,%s,%s,%s,%s\n' "${instructions}" "${cycles}" \
			"${branch_misses}" "${task_clock}" "${dir#"${pf_session}/"}"
	} >>"${pf_session}/samples.csv"

	if [[ ${status} != ok ]]
	then
		pf_warn "${workload}/${label}-${n}: ${status} (exit ${exit_code}); see ${dir}"
		if [[ -s ${dir}/result.json ]]
		then
			yq -p json -o yaml -r '(.failures[] | "  failure: " + .), (select(.error != null) | "  error: " + .error)' \
				"${dir}/result.json" >&2
		fi
		return 1
	fi
	return 0
}

# ---------------------------------------------------------------------
# Statistics
# ---------------------------------------------------------------------

# pf_stats WORKLOAD LABEL COLUMN -- "median mad count" of one samples.csv
# column over the valid samples of one editor.
pf_stats () {
	if [[ $# -ne 3 ]]
	then
		pf_die 'pf_stats() requires 3 positional arguments: pf_stats <workload> <label> <column>'
	fi

	local workload="${1}"
	local label="${2}"
	local column="${3}"

	awk -F, -v w="${workload}" -v l="${label}" -v c="${column}" '
		NR > 1 && $1 == w && $2 == l && $4 == "ok" && $c != "" { print $c }' \
		"${pf_session}/samples.csv" \
		| sort -g \
		| awk '
			function median(a, n) {
				return (n % 2) ? a[(n + 1) / 2] : (a[n / 2] + a[n / 2 + 1]) / 2
			}
			# Counts print whole; small fractional values keep four digits.
			function fmt(x) {
				return (x == int(x) || x >= 1000) ? sprintf("%.0f", x) : sprintf("%.4g", x)
			}
			{ v[++n] = $1 }
			END {
				if (n == 0) { print "  0"; exit }
				m = median(v, n)
				for (i = 1; i <= n; i++) {
					d[i] = v[i] - m
					if (d[i] < 0) d[i] = -d[i]
				}
				asort(d)
				printf "%s %s %d\n", fmt(m), fmt(median(d, n)), n
			}'
}

# samples.csv columns, by name.
declare -A PF_COLUMN=(
	[cpu_us]=6 [wall_us]=7 [cpu_ns_per_op]=8 [gcs_done]=9 [gc_us]=10
	[primary]=11 [instructions]=12 [cycles]=13 [branch_misses]=14
	[task_clock_ms]=15
)

# ---------------------------------------------------------------------
# Sessions
# ---------------------------------------------------------------------

# pf_session_open COMMAND -- create the session directory and its
# shared inputs.
pf_session_open () {
	if [[ $# -ne 1 ]]
	then
		pf_die 'pf_session_open() requires 1 positional argument: pf_session_open <command>'
	fi

	local command="${1}"

	pf_session="${pf_out}/$(date -u +%Y%m%dT%H%M%SZ)-${command}-$$"
	mkdir -p -- "${pf_session}/data" || pf_die "cannot create ${pf_session}"
	[[ -r ${pf_source} ]] || pf_die "--source ${pf_source} is not readable"
	cp -- "${pf_source}" "${pf_session}/data/source.el" \
		|| pf_die "cannot copy ${pf_source}"
	printf 'workload,label,sample,status,load1,cpu_us,wall_us,cpu_ns_per_op,gcs_done,gc_us,primary,instructions,cycles,branch_misses,task_clock_ms,dir\n' \
		>"${pf_session}/samples.csv"
}

# pf_editor_identity LABEL EDITOR -- YAML lines identifying one editor.
pf_editor_identity () {
	if [[ $# -ne 2 ]]
	then
		pf_die 'pf_editor_identity() requires 2 positional arguments: pf_editor_identity <label> <editor>'
	fi

	local label="${1}"
	local editor="${2}"

	printf '  %s:\n' "${label}"
	printf '    path: %s\n' "${editor}"
	printf '    sha256: %s\n' "$(sha256sum -- "${editor}" | cut -d' ' -f1)"
	printf '    version: "%s"\n' "$("${editor}" --version 2>/dev/null | head -n1)"
}

# pf_session_header -- the YAML preamble shared by every summary.
pf_session_header () {
	local governor="unknown"

	if [[ -n ${pf_cpu} && -r /sys/devices/system/cpu/cpu${pf_cpu}/cpufreq/scaling_governor ]]
	then
		governor="$(cat "/sys/devices/system/cpu/cpu${pf_cpu}/cpufreq/scaling_governor")"
	fi
	printf 'schema: 1\n'
	printf 'tool: %s %s\n' "${PF_SELF}" "${PF_VERSION}"
	printf 'started: %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
	printf 'host:\n'
	printf '  kernel: %s\n' "$(uname -r)"
	printf '  arch: %s\n' "$(uname -m)"
	printf '  cpu_model: "%s"\n' "$(awk -F': ' '/^model name/ { print $2; exit }' /proc/cpuinfo)"
	printf '  pinned_cpu: %s\n' "${pf_cpu:-null}"
	printf '  governor: %s\n' "${governor}"
	printf '  perf_event_paranoid: %s\n' "$(cat /proc/sys/kernel/perf_event_paranoid 2>/dev/null || printf unknown)"
	printf 'counters: %s\n' "${pf_counters}"
	printf 'compiled: %s\n' "$(pf_compiled_kind)"
	printf 'source: %s\n' "${pf_source}"
	printf 'source_sha256: %s\n' "$(sha256sum -- "${pf_source}" | cut -d' ' -f1)"
}

# pf_frontend_for CATALOG WORKLOAD -- --frontend, else the workload's own.
pf_frontend_for () {
	if [[ $# -ne 2 ]]
	then
		pf_die 'pf_frontend_for() requires 2 positional arguments: pf_frontend_for <catalog> <workload>'
	fi

	if [[ -n ${pf_frontend} ]]
	then
		printf '%s\n' "${pf_frontend}"
	else
		pf_catalog_field "${1}" "${2}" 2
	fi
}

# pf_check_workloads CATALOG WORKLOAD... -- die on an unknown name.
pf_check_workloads () {
	local catalog="${1}"
	local workload

	shift
	for workload in "$@"
	do
		pf_catalog_field "${catalog}" "${workload}" 1 >/dev/null \
			|| pf_die "unknown workload '${workload}' (try: ${PF_SELF} list)"
	done
}

# ---------------------------------------------------------------------
# Commands
# ---------------------------------------------------------------------

pf_cmd_list () {
	local build

	build="$(mktemp -d)" || pf_die "mktemp failed"
	# shellcheck disable=SC2064  # expand now: the path is fixed
	trap "rm -rf -- '${build}'" EXIT
	pf_build "${pf_editor}" "${build}" || exit 1
	{
		printf 'NAME\tFRONTEND\tITERATIONS\tBUDGET%%\tPRIMARY\tDESCRIPTION\n'
		pf_catalog "${pf_editor}" "${build}"
	} | column -t -s $'\t'
}

pf_cmd_run () {
	local build workload frontend dir

	[[ $# -ge 1 ]] || pf_die "run: name at least one workload"
	pf_resolve_counters
	pf_session_open run
	build="${pf_session}/build-editor"
	pf_build "${pf_editor}" "${build}" || exit 1
	pf_catalog "${pf_editor}" "${build}" >/dev/null || exit 1
	pf_check_workloads "${build}/catalog.tsv" "$@"

	{
		pf_session_header
		printf 'editors:\n'
		pf_editor_identity editor "${pf_editor}"
		printf 'runs:\n'
	} >"${pf_session}/summary.yaml"

	for workload in "$@"
	do
		frontend="$(pf_frontend_for "${build}/catalog.tsv" "${workload}")"
		dir="${pf_session}/${workload}/editor-1"
		pf_prime editor "${pf_editor}" "${build}" "${frontend}" "${workload}"
		pf_say "run: ${workload} (${frontend})"
		if pf_sample "${workload}" editor 1 "${pf_editor}" "${build}" "${frontend}" "${dir}"
		then
			printf '  - workload: %s\n    status: ok\n    result: %s\n' \
				"${workload}" "${dir#"${pf_session}/"}/result.json" \
				>>"${pf_session}/summary.yaml"
		else
			printf '  - workload: %s\n    status: invalid\n' "${workload}" \
				>>"${pf_session}/summary.yaml"
			pf_status=1
		fi
	done

	pf_say "session: ${pf_session}"
	pf_print_runs
}

# Print the run table from samples.csv.
pf_print_runs () {
	{
		printf 'WORKLOAD\tSTATUS\tCPU_NS/OP\tCPU_MS\tWALL_MS\tINSTRUCTIONS\tCYCLES\tGCS\n'
		awk -F, 'NR > 1 {
			printf "%s\t%s\t%s\t%.1f\t%.1f\t%s\t%s\t%s\n",
				$1, $4, $8, $6 / 1000, $7 / 1000,
				($12 == "" ? "-" : $12), ($13 == "" ? "-" : $13), $9
		}' "${pf_session}/samples.csv"
	} | column -t -s $'\t'
}

# pf_compare_workload WORKLOAD CATALOG -- interleave the samples of one
# workload and append its YAML block to the summary.  Prints the change
# of the primary metric (or "invalid").
pf_compare_workload () {
	if [[ $# -ne 2 ]]
	then
		pf_die 'pf_compare_workload() requires 2 positional arguments: pf_compare_workload <workload> <catalog>'
	fi

	local workload="${1}"
	local catalog="${2}"
	local frontend base_frontend cand_frontend i first second label editor
	local valid=1
	local primary metric declared
	local -a metrics=(cpu_us wall_us cpu_ns_per_op gcs_done)
	local base_median base_mad base_n cand_median cand_mad cand_n ratio change
	local primary_change="invalid"

	frontend="$(pf_frontend_for "${catalog}" "${workload}")"
	# Each side may run another frontend (--baseline-frontend tui
	# --candidate-frontend lrg compares two display backends of one build).
	base_frontend="${pf_baseline_frontend:-${frontend}}"
	cand_frontend="${pf_candidate_frontend:-${frontend}}"
	if [[ ${pf_counters} == on ]]
	then
		metrics=(cycles instructions branch_misses "${metrics[@]}")
		primary="cycles"
	else
		primary="cpu_us"
	fi
	# A workload that declares its own primary metric is judged on it:
	# its window also holds harness work it does not want gated.
	declared="$(pf_catalog_field "${catalog}" "${workload}" 5)"
	if [[ -n ${declared} && ${declared} != - ]]
	then
		metrics=(primary "${metrics[@]}")
		primary="primary"
	fi

	pf_prime baseline "${pf_baseline}" "${pf_session}/build-baseline" \
		"${base_frontend}" "${workload}"
	pf_prime candidate "${pf_candidate}" "${pf_session}/build-candidate" \
		"${cand_frontend}" "${workload}"

	# Alternate which editor goes first, so slow drift (thermal, a
	# background build ramping up) lands on both sides equally.
	for (( i = 1; i <= pf_samples; i++ ))
	do
		if (( i % 2 ))
		then
			first=baseline second=candidate
		else
			first=candidate second=baseline
		fi
		for label in "${first}" "${second}"
		do
			if [[ ${label} == baseline ]]
			then
				editor="${pf_baseline}" frontend="${base_frontend}"
			else
				editor="${pf_candidate}" frontend="${cand_frontend}"
			fi
			pf_say "compare: ${workload} ${label} ${i}/${pf_samples} (${frontend})"
			pf_sample "${workload}" "${label}" "${i}" "${editor}" \
				"${pf_session}/build-${label}" "${frontend}" \
				"${pf_session}/${workload}/${label}-${i}" || valid=0
		done
	done

	{
		printf '  - workload: %s\n' "${workload}"
		printf '    frontend: {baseline: %s, candidate: %s}\n' "${base_frontend}" "${cand_frontend}"
		printf '    samples: %d\n' "${pf_samples}"
		printf '    primary: %s\n' "$([[ ${primary} == primary ]] && printf '%s' "${declared}" || printf '%s' "${primary}")"
	} >>"${pf_session}/summary.yaml"

	# No statistics from an incomplete comparison: a faster run that
	# skipped work or crashed must not improve the candidate's numbers.
	if [[ ${valid} -eq 0 ]]
	then
		printf '    status: invalid\n' >>"${pf_session}/summary.yaml"
		printf 'invalid\n'
		return 1
	fi

	printf '    status: ok\n    metrics:\n' >>"${pf_session}/summary.yaml"
	for metric in "${metrics[@]}"
	do
		read -r base_median base_mad base_n < <(pf_stats "${workload}" baseline "${PF_COLUMN[${metric}]}")
		read -r cand_median cand_mad cand_n < <(pf_stats "${workload}" candidate "${PF_COLUMN[${metric}]}")
		read -r ratio change < <(awk -v b="${base_median}" -v c="${cand_median}" \
			'BEGIN { if (b == 0) print "null null"; else printf "%.4f %.2f\n", c / b, (c / b - 1) * 100 }')
		{
			printf '      %s:\n' "${metric}"
			printf '        baseline: {median: %s, mad: %s, n: %s}\n' "${base_median}" "${base_mad}" "${base_n}"
			printf '        candidate: {median: %s, mad: %s, n: %s}\n' "${cand_median}" "${cand_mad}" "${cand_n}"
			printf '        ratio: %s\n        change_pct: %s\n' "${ratio}" "${change}"
		} >>"${pf_session}/summary.yaml"
		printf '%s\t%s\t%s ±%s\t%s ±%s\t%s\n' "${workload}" "${metric}" \
			"${base_median}" "${base_mad}" "${cand_median}" "${cand_mad}" \
			"$([[ ${change} == null ]] && printf 'n/a' || printf '%s%%' "${change}")" \
			>>"${pf_session}/table.tsv"
		if [[ ${metric} == "${primary}" ]]
		then
			primary_change="${change}"
		fi
	done
	printf '%s\n' "${primary_change}"
}

# Build both editors' copies of the workloads and open the summary.
pf_compare_prepare () {
	local command="${1}"

	# Comparing two frontends of one build needs no second editor.
	if [[ -z ${pf_baseline} && ( -n ${pf_baseline_frontend} || -n ${pf_candidate_frontend} ) ]]
	then
		pf_baseline="${pf_candidate}"
	fi
	[[ -n ${pf_baseline} ]] || pf_die "${command}: --baseline is required"
	[[ ${pf_samples} -ge 3 ]] || pf_die "${command}: --samples must be at least 3"
	pf_resolve_counters
	pf_session_open "${command}"
	pf_build "${pf_baseline}" "${pf_session}/build-baseline" || exit 1
	pf_build "${pf_candidate}" "${pf_session}/build-candidate" || exit 1
	pf_catalog "${pf_candidate}" "${pf_session}/build-candidate" >/dev/null || exit 1
	{
		pf_session_header
		printf 'editors:\n'
		pf_editor_identity baseline "${pf_baseline}"
		pf_editor_identity candidate "${pf_candidate}"
		printf 'comparisons:\n'
	} >"${pf_session}/summary.yaml"
	printf 'WORKLOAD\tMETRIC\tBASELINE\tCANDIDATE\tCHANGE\n' >"${pf_session}/table.tsv"
}

pf_cmd_compare () {
	local catalog workload change

	[[ $# -ge 1 ]] || pf_die "compare: name at least one workload"
	pf_compare_prepare compare
	catalog="${pf_session}/build-candidate/catalog.tsv"
	pf_check_workloads "${catalog}" "$@"
	for workload in "$@"
	do
		change="$(pf_compare_workload "${workload}" "${catalog}")"
		if [[ ${change} == invalid ]]
		then
			pf_status=1
		fi
	done
	pf_say "session: ${pf_session}"
	column -t -s $'\t' "${pf_session}/table.tsv"
}

pf_cmd_suite () {
	local catalog workload change budget verdict
	local -a workloads=("$@")

	pf_compare_prepare suite
	catalog="${pf_session}/build-candidate/catalog.tsv"
	if [[ ${#workloads[@]} -eq 0 ]]
	then
		mapfile -t workloads < <(cut -f1 "${catalog}")
	fi
	pf_check_workloads "${catalog}" "${workloads[@]}"

	printf 'WORKLOAD\tCHANGE\tBUDGET\tVERDICT\n' >"${pf_session}/verdicts.tsv"
	for workload in "${workloads[@]}"
	do
		budget="${pf_budget:-$(pf_catalog_field "${catalog}" "${workload}" 4)}"
		change="$(pf_compare_workload "${workload}" "${catalog}")"
		if [[ ${change} == invalid || ${change} == null ]]
		then
			verdict="invalid"
		elif awk -v c="${change}" -v b="${budget}" 'BEGIN { exit !(c > b) }'
		then
			verdict="regression"
		else
			verdict="pass"
		fi
		[[ ${verdict} == pass ]] || pf_status=1
		printf '    budget_pct: %s\n    verdict: %s\n' "${budget}" "${verdict}" \
			>>"${pf_session}/summary.yaml"
		printf '%s\t%s%%\t%s%%\t%s\n' "${workload}" "${change}" "${budget}" "${verdict}" \
			>>"${pf_session}/verdicts.tsv"
	done
	pf_say "session: ${pf_session}"
	column -t -s $'\t' "${pf_session}/table.tsv" >&2
	column -t -s $'\t' "${pf_session}/verdicts.tsv"
}

pf_cmd_profile () {
	local workload build frontend dir
	local -a argv=() env_args=() wrapped=()

	[[ $# -eq 1 ]] || pf_die "profile: name exactly one workload"
	workload="${1}"
	command -v perf >/dev/null 2>&1 || pf_die "profile: perf is not installed"
	pf_counters="off"
	pf_session_open profile
	build="${pf_session}/build-editor"
	pf_build "${pf_editor}" "${build}" || exit 1
	pf_catalog "${pf_editor}" "${build}" >/dev/null || exit 1
	pf_check_workloads "${build}/catalog.tsv" "${workload}"
	frontend="$(pf_frontend_for "${build}/catalog.tsv" "${workload}")"
	pf_prime editor "${pf_editor}" "${build}" "${frontend}" "${workload}"
	dir="${pf_session}/${workload}/profile"
	pf_home editor "${dir}" || exit 1
	mkfifo -- "${dir}/ctl" "${dir}/ack" || exit 1

	mapfile -d '' -t argv < <(pf_editor_command "${frontend}" "${pf_editor}" "${build}")
	mapfile -d '' -t env_args < <(pf_child_env "${frontend}" "${dir}" "${workload}")
	env_args=(env -i "${env_args[@]}"
		"CMACS_PERF_CTL=${dir}/ctl" "CMACS_PERF_ACK=${dir}/ack")
	if [[ -n ${pf_cpu} ]]
	then
		env_args=(taskset -c "${pf_cpu}" "${env_args[@]}")
	fi
	# 999 Hz, user space, 16 KiB DWARF stacks; sampling only between the
	# workload's enable and disable.  --user-callchains: at the default
	# perf_event_paranoid of 2 a callchain that may include kernel frames
	# is refused outright, even for a `:u' event.
	wrapped=(perf record -F 999 -e cpu-clock:u --user-callchains
		--call-graph "dwarf,16384" -D -1
		--control "fifo:${dir}/ctl,${dir}/ack" -o "${dir}/perf.data" --
		"${env_args[@]}" "${argv[@]}")

	pf_say "profile: ${workload} (${frontend})"
	pf_launch "${frontend}" "${pf_editor}" "${dir}" "${wrapped[@]}"
	if [[ "$(yq -p json -o yaml -r '.status' "${dir}/result.json" 2>/dev/null)" != ok ]]
	then
		pf_warn "profile: the workload did not complete correctly; see ${dir}"
		exit 1
	fi
	perf report -i "${dir}/perf.data" --stdio --no-children --percent-limit 0.5 \
		--sort symbol >"${dir}/report.txt" 2>"${dir}/report.log" \
		|| { pf_warn "perf report failed; see ${dir}/report.log"; exit 1; }
	pf_say "session: ${pf_session}"
	grep -v '^#' "${dir}/report.txt" | grep -E '^ +[0-9]' | head -n 40
}

# ---------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------

pf_main () {
	local command="" frontend entry tool
	local -a workloads=()

	while [[ $# -gt 0 ]]
	do
		case "${1}" in
			-e|--editor) pf_editor="${2:?--editor needs a path}"; shift 2 ;;
			-b|--baseline) pf_baseline="${2:?--baseline needs a path}"; shift 2 ;;
			-c|--candidate) pf_candidate="${2:?--candidate needs a path}"; shift 2 ;;
			-n|--iterations) pf_iterations="${2:?--iterations needs a number}"; shift 2 ;;
			-s|--samples) pf_samples="${2:?--samples needs a number}"; shift 2 ;;
			-f|--frontend) pf_frontend="${2:?--frontend needs batch, tui, lrg or pgtk}"; shift 2 ;;
			--baseline-frontend) pf_baseline_frontend="${2:?--baseline-frontend needs a frontend}"; shift 2 ;;
			--candidate-frontend) pf_candidate_frontend="${2:?--candidate-frontend needs a frontend}"; shift 2 ;;
			--display) pf_display="${2:?--display needs headless or session}"; shift 2 ;;
			--lrg-spec) pf_lrg_spec="${2:?--lrg-spec needs a SPEC}"; shift 2 ;;
			--env) pf_extra_env+=("${2:?--env needs VAR=VALUE}"); shift 2 ;;
			--counters) pf_counters="on"; shift ;;
			--no-counters) pf_counters="off"; shift ;;
			--native) pf_native=1; shift ;;
			--cpu) pf_cpu="${2:?--cpu needs a CPU number}"; shift 2 ;;
			--source) pf_source="${2:?--source needs a file}"; shift 2 ;;
			--budget) pf_budget="${2:?--budget needs a percentage}"; shift 2 ;;
			-o|--out) pf_out="${2:?--out needs a directory}"; shift 2 ;;
			-t|--timeout) pf_timeout="${2:?--timeout needs seconds}"; shift 2 ;;
			-q|--quiet) pf_quiet=1; shift ;;
			-h|--help) pf_usage; exit 0 ;;
			--license) pf_license; exit 0 ;;
			--version) printf '%s %s\n' "${PF_SELF}" "${PF_VERSION}"; exit 0 ;;
			--) shift; workloads+=("$@"); break ;;
			-*) pf_die "unknown option '${1}' (see --help)" ;;
			*)
				if [[ -z ${command} ]]
				then
					command="${1}"
				else
					workloads+=("${1}")
				fi
				shift
				;;
		esac
	done

	[[ -n ${command} ]] || { pf_usage >&2; exit 2; }

	# Validate and absolutise.
	pf_editor="${pf_editor:-${PF_ROOT}/src/emacs}"
	pf_candidate="${pf_candidate:-${pf_editor}}"
	if [[ -n ${pf_iterations} && ! ${pf_iterations} =~ ^[1-9][0-9]*$ ]]
	then
		pf_die "--iterations must be a positive integer"
	fi
	[[ ${pf_samples} =~ ^[1-9][0-9]*$ ]] || pf_die "--samples must be a positive integer"
	[[ ${pf_timeout} =~ ^[1-9][0-9]*$ ]] || pf_die "--timeout must be a positive integer"
	[[ -z ${pf_cpu} || ${pf_cpu} =~ ^[0-9]+$ ]] || pf_die "--cpu must be a CPU number"
	[[ -z ${pf_budget} || ${pf_budget} =~ ^[0-9]+([.][0-9]+)?$ ]] || pf_die "--budget must be a number"
	for frontend in "${pf_frontend}" "${pf_baseline_frontend}" "${pf_candidate_frontend}"
	do
		case "${frontend}" in
			""|batch|tui|lrg|pgtk) ;;
			*) pf_die "a frontend must be batch, tui, lrg or pgtk, not '${frontend}'" ;;
		esac
	done
	for entry in "${pf_extra_env[@]}"
	do
		[[ ${entry} =~ ^[A-Za-z_][A-Za-z0-9_]*= ]] || pf_die "--env takes VAR=VALUE, not '${entry}'"
	done
	case "${pf_display}" in
		headless|session) ;;
		*) pf_die "--display must be headless or session" ;;
	esac
	[[ ${pf_lrg_spec} =~ ^[a-z0-9:_-]+$ ]] || pf_die "--lrg-spec '${pf_lrg_spec}' is not a --lrg SPEC"
	for tool in yq awk column sha256sum timeout
	do
		command -v "${tool}" >/dev/null 2>&1 || pf_die "${tool} is required"
	done
	pf_editor="$(realpath -- "${pf_editor}")" || pf_die "no editor at ${pf_editor}"
	pf_candidate="$(realpath -- "${pf_candidate}")" || pf_die "no editor at ${pf_candidate}"
	if [[ -n ${pf_baseline} ]]
	then
		pf_baseline="$(realpath -- "${pf_baseline}")" || pf_die "no editor at ${pf_baseline}"
	fi
	pf_source="$(realpath -- "${pf_source}")" || pf_die "no source file at ${pf_source}"
	mkdir -p -- "${pf_out}" || pf_die "cannot create ${pf_out}"
	pf_out="$(realpath -- "${pf_out}")"

	# A graphical frontend is only ever chosen explicitly, so this is the
	# one place that knows a display is needed.  Started here, not in
	# pf_child_env: that runs in a subshell and its compositor would
	# outlive the variables that name it.
	if [[ ${pf_display} == headless && ( ${pf_frontend} == lrg || ${pf_frontend} == pgtk
		|| ${pf_baseline_frontend} == lrg || ${pf_baseline_frontend} == pgtk
		|| ${pf_candidate_frontend} == lrg || ${pf_candidate_frontend} == pgtk ) ]]
	then
		trap pf_headless_stop EXIT
		pf_headless_start
	fi

	case "${command}" in
		list) pf_cmd_list ;;
		run) pf_cmd_run "${workloads[@]}" ;;
		compare) pf_cmd_compare "${workloads[@]}" ;;
		suite) pf_cmd_suite "${workloads[@]}" ;;
		profile) pf_cmd_profile "${workloads[@]}" ;;
		*) pf_die "unknown command '${command}' (see --help)" ;;
	esac
	exit "${pf_status}"
}

pf_main "$@"
