#!/usr/bin/env bash
# cmacs-verify-fresh.sh --- is every build artifact newer than its sources?
#
# Copyright (C) 2026 Zach Podbielniak
# SPDX-License-Identifier: AGPL-3.0-or-later
#
# A test that runs against a stale artifact does not fail: it passes, or
# fails somewhere unrelated, against code that is no longer on disk.
# This tree has done that through every door it has:
#
#   - test/cmacs/*.elc older than the src/emacs that should recompile
#     them (33 fake failures across 8 suites, 2026-09-04);
#   - lisp/cmacs/*.elc older than their .el -- Emacs loads the .elc
#     anyway, and the .eln is only ever looked up THROUGH that .elc;
#   - cmacs/api/libcmacs-api.so and the bacon modules, which
#     src/Makefile.in builds only when they are ABSENT;
#   - gowl module .so files and xdg-desktop-portal-gowl, which a test
#     dlopened or executed from a previous build;
#   - bundled dep archives (libwhisper.a) linked against new headers;
#   - src/temacs not relinked after a dep archive it links changed,
#     because LIBES archives are link inputs, not prerequisites.
#
# One rule covers all of them: an artifact is stale when any file it is
# built from is newer than it.  The file lists are the REAL ones -- the
# make database of the Makefile that builds the artifact (which already
# includes the compiler's -MMD .d files), the compiler's .o.d files for
# a cmake build, or the pattern rule's own shape for .elc -- never a
# guess from names when an exact list exists.
#
# Reading a make database must not build anything.  `make -q' still
# REMAKES INCLUDED MAKEFILES (a .d with a rule, a generated .mk), so
# every makefile the probe may read is passed with -o, and the makefiles
# make reports having read are checked against that set afterwards.
#
# The artifact classes live in vf_register_classes; adding one is one
# vf_class call.

set -uo pipefail
shopt -s nullglob

VF_SELF="${0##*/}"
VF_VERSION="1.0.0"

# Options.
vf_root=""
vf_fix=0
vf_quiet=0
vf_gate=0
vf_all=0
vf_verbose=0
vf_system=0
vf_list=0
vf_only=""
vf_max_shown=8

# The class table: one entry per index across these arrays.
VF_NAME=()
VF_KIND=()
VF_DIR=()
VF_SELECT=()
VF_FIX=()
VF_DESC=()
VF_ARGS=()

# Scratch space, removed on exit.
vf_tmp=""

# Results across classes.
vf_total_stale=0
vf_total_notes=0
vf_stale_classes=()

vf_usage () {
	cat <<EOF
Usage: ${VF_SELF} [OPTION]...

Check that every cmacs build artifact is newer than the files it is
built from, using the real dependency lists (make databases, compiler
.d files, pattern rules).  Reports each stale artifact, the newest
source that makes it stale, and the command that rebuilds it.  Exits 0
when everything is fresh, 1 when anything is stale, 2 on a usage error.

Nothing is built unless --fix is given.

Options:
  -f, --fix          run the rebuild command of every stale class, then
                     check again.  Each command runs under
                     \`flock \$CMACS_BUILD_LOCK' when that variable names
                     a lock file, and bare otherwise.
  -q, --quiet        print nothing; exit status only
  -a, --all          list every stale artifact (default: first ${vf_max_shown} per class)
  -v, --verbose      also list artifacts that are absent, and fresh classes
  -o, --only GLOBS   check only classes matching a comma-separated list of
                     globs, e.g. 'gowl-*,src-link'
  -l, --list         list the artifact classes and exit
  -g, --gate         precondition mode for test entry points: honour
                     CMACS_SKIP_FRESH_CHECK=1 and say how to bypass
  -s, --system       also count prerequisites outside the tree (system
                     headers); off by default, since an OS update would
                     otherwise mark everything stale
  -r, --root DIR     tree to check (default: this script's ../)
  -h, --help         show this help and exit
      --license      show the license and exit
      --version      show the version and exit

Environment:
  CMACS_BUILD_LOCK        lock file that --fix wraps every command in
  CMACS_SKIP_FRESH_CHECK  =1 makes --gate a no-op (the escape hatch)

Examples:
  # Before trusting a test result:
  ${VF_SELF}

  # Same, through the Justfile:
  just verify-fresh

  # Only the gowl classes, every stale artifact listed:
  ${VF_SELF} --only 'gowl-*' --all

  # Rebuild what is stale, serialised against other builds:
  CMACS_BUILD_LOCK=/tmp/build.lock ${VF_SELF} --fix

  # In a script: is the tree fresh?
  if ${VF_SELF} --quiet; then make -C test check-cmacs; fi

  # Run the tests anyway, knowingly against a stale tree:
  CMACS_SKIP_FRESH_CHECK=1 make -C test check-cmacs
EOF
}

vf_license () {
	cat <<'EOF'
cmacs-verify-fresh.sh -- stale build artifact guard for cmacs
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
EOF
}

# Print to stdout unless --quiet.
vf_say () {
	if [[ ${vf_quiet} -eq 0 ]]
	then
		printf '%s\n' "$*"
	fi
}

# Print to stderr unless --quiet.
vf_warn () {
	if [[ ${vf_quiet} -eq 0 ]]
	then
		printf '%s: %s\n' "${VF_SELF}" "$*" >&2
	fi
}

# shellcheck disable=SC2329  # invoked by the EXIT trap
vf_cleanup () {
	if [[ -n ${vf_tmp} && -d ${vf_tmp} ]]
	then
		rm -rf -- "${vf_tmp}"
	fi
}

# ---------------------------------------------------------------------
# The class table
# ---------------------------------------------------------------------

# vf_class NAME KIND DIR SELECT FIX DESC [ARG]...
#
# NAME    short identifier, used by --only.
# KIND    where the dependency list comes from:
#           makedb   the make database of the Makefile in DIR (DIR may
#                    be a glob: one probe per matching directory).
#                    ARGs are make arguments, except these:
#                      vf:find=REL      also consider files under DIR/REL
#                                       (pattern-rule outputs that no
#                                       explicit rule names)
#                      vf:link=T:VAR    the in-tree .a/.so words of $(VAR)
#                                       are prerequisites of T too (link
#                                       inputs make does not track)
#                      vf:requires=P    skip the class unless P exists
#                      vf:gate=no       not part of a bare --gate run
#           pattern  a pattern rule: SELECT is a glob of artifacts under
#                    DIR; ARGs:
#                      vf:from=SUF vf:to=SUF   artifact -> source suffix
#                      vf:extra=PATH           prerequisite of every one
#                      vf:selfheal=FILE:ERE    when FILE matches ERE, the
#                                       run that consumes these rebuilds
#                                       them itself: report, do not fail
#           cmake    DIR is a cmake build tree: every lib<T>.a against
#                    the objects of CMakeFiles/<T>.dir, every object
#                    against its compiler .o.d file.
# DIR     relative to the tree root.
# SELECT  makedb: ERE over root-relative artifact paths; pattern: glob.
# FIX     shell command, run from the tree root.  `{+}' becomes the stale
#         artifacts, relative to DIR.
# DESC    one line for the report.
vf_class () {
	if [[ $# -lt 6 ]]
	then
		# shellcheck disable=SC2016  # literal backticks
		echo '`vf_class()` requires at least 6 positional arguments' >&2
		echo 'vf_class <name> <kind> <dir> <select> <fix> <desc> [arg]...' >&2
		exit 2
	fi

	local IFS=$'\x1f'

	VF_NAME+=("${1}")
	VF_KIND+=("${2}")
	VF_DIR+=("${3}")
	VF_SELECT+=("${4}")
	VF_FIX+=("${5}")
	VF_DESC+=("${6}")
	shift 6
	VF_ARGS+=("$*")
}

# Read one `VAR = value' line out of a configured makefile.
vf_makefile_var () {
	local file="${1}"
	local var="${2}"

	if [[ -f ${file} ]]
	then
		sed -n "s/^${var} *= *//p" "${file}" | head -n 1
	fi
}

# FIX strings are run later by bash -c, so they stay unexpanded here.
# shellcheck disable=SC2016
vf_register_classes () {
	local r="${vf_root}"
	local dep_flags
	local dep_type
	local dep
	local gowl_type
	local gowl_flag
	local gowl_what
	local gowl_gate
	local -a common

	# Build type of the bundled deps, as configure chose it.
	dep_type="$(vf_makefile_var "${r}/src/Makefile" CMACS_DEP_BUILDTYPE)"
	dep_flags="$(vf_makefile_var "${r}/src/Makefile" CMACS_DEP_MAKEFLAGS)"
	if [[ -z ${dep_type} ]]
	then
		dep_type="release"
	fi

	# The link: every C object against its .d, temacs against its
	# objects AND every in-tree archive on its link line, the dumped
	# emacs against temacs and the preloaded Lisp.  The fix forces the
	# relink (AGENTS.md: `make' may not relink).
	vf_class src-link makedb src \
		'^src/(temacs|emacs|emacs\.pdmp|cmacs-screensaver-render)$' \
		'rm -f src/temacs && make -j"$(nproc)"' \
		'C objects, temacs (incl. archives on its link line) and the dump' \
		vf:link=temacs:LIBES \
		-o "${r}/src/lisp.mk" -o ../src/verbose.mk

	# Runtime shared objects src/Makefile.in builds only when ABSENT.
	vf_class api-so makedb cmacs/api \
		'^cmacs/api/libcmacs-api\.so$' \
		'make -C cmacs/api all' \
		'libcmacs-api.so (src/Makefile.in builds it only when absent)'
	vf_class bacon-modules makedb cmacs/bacon/modules \
		'^cmacs/bacon/modules/[^/]+\.so$' \
		'make -C cmacs/bacon/modules BACON_DIR="$PWD/deps/bacon" API_DIR="$PWD/cmacs/api"' \
		'bacon cmacs_gi.so / cmacs_pod.so (built only when absent)' \
		"BACON_DIR=${r}/deps/bacon" "API_DIR=${r}/cmacs/api"
	vf_class gsurf-modules makedb cmacs/gsurf/modules \
		'^cmacs/gsurf/modules/[^/]+\.so$' \
		'make -C cmacs/gsurf/modules GSURF_DIR="$PWD/deps/gsurf"' \
		'gsurf modules loaded through CMACS_GSURF_MODULE_DIR' \
		"GSURF_DIR=${r}/deps/gsurf" vf:find=.
	vf_class org-ex makedb cmacs/org-ex/lib \
		'^cmacs/org-ex/lib/liborgex-1\.0\.a$' \
		'make -C cmacs/org-ex/lib static' \
		'liborgex-1.0.a'

	# gowl, in both build types: cmacs links and loads the configured
	# one, `make -C deps/gowl test' and `just gowl' use release.
	for gowl_type in debug release
	do
		# debug is what cmacs links and runs (libgowl, gowl-lock);
		# release is what gowl's own `make test' builds and runs.
		# The type cmacs does not use is left out of --gate (the ERT
		# run never loads it); `just test-gowl' names it with --only.
		gowl_gate="vf:gate=no"
		if [[ ${gowl_type} == "${dep_type}" ]]
		then
			gowl_gate="vf:gate=yes"
		fi
		gowl_flag=""
		gowl_what='gowl|gowlbar|gowl-lock|gowl-msg|gowl-mcp|xdg-desktop-portal-gowl'
		if [[ ${gowl_type} == debug ]]
		then
			gowl_flag="DEBUG=1"
			gowl_what='gowl-lock'
		fi
		vf_class "gowl-${gowl_type}" makedb deps/gowl \
			"^deps/gowl/build/${gowl_type}/(libgowl\\.(a|so[.0-9]*)|${gowl_what})\$" \
			"make -C deps/gowl ${gowl_flag} YAMLGLIB_DIR=\"\$PWD/deps/yaml-glib\" CRISPY_DIR=\"\$PWD/deps/crispy\" all" \
			"libgowl and ${gowl_what//|/, } (${gowl_type})" \
			"vf:requires=deps/gowl/build/${gowl_type}" "${gowl_gate}" \
			${gowl_flag:+"${gowl_flag}"} \
			"YAMLGLIB_DIR=${r}/deps/yaml-glib" "CRISPY_DIR=${r}/deps/crispy"
		vf_class "gowl-modules-${gowl_type}" makedb 'deps/gowl/modules/*' \
			"^deps/gowl/build/${gowl_type}/modules/[^/]+\\.so\$" \
			"make -C deps/gowl ${gowl_flag} YAMLGLIB_DIR=\"\$PWD/deps/yaml-glib\" CRISPY_DIR=\"\$PWD/deps/crispy\" modules" \
			"gowl module .so files (${gowl_type}; no pattern rule names them)" \
			"vf:requires=deps/gowl/build/${gowl_type}/modules" "${gowl_gate}" \
			-f Makefile -f ../dependencies.mk \
			"OUTDIR=${r}/deps/gowl/build/${gowl_type}/modules" \
			"LIBDIR=${r}/deps/gowl/build/${gowl_type}"
	done

	# Every other bundled dep: its own Makefile's database, with the
	# same canonical *_DIR overrides src/Makefile.in passes.  Passing an
	# override a dep does not use is harmless.
	common=(
		"CRISPY_DIR=${r}/deps/crispy"
		"YAMLGLIB_DIR=${r}/deps/yaml-glib"
		"YAML_GLIB_DIR=${r}/deps/yaml-glib"
		"MCP_GLIB_DIR=${r}/deps/mcp-glib"
		"AI_GLIB_DIR=${r}/deps/ai-glib"
		"LIBREGNUM_DIR=${r}/deps/libregnum"
	)
	if [[ -n ${dep_flags} ]]
	then
		# Word-split on purpose: it is a make argument list.
		# shellcheck disable=SC2206
		common+=(${dep_flags})
	fi
	for dep in bacon crispy yaml-glib podomation ai-glib cad-glib \
	           orm-glib clawtilla clawtilla/deps/libreclaw libregnum \
	           gsurf screensavers
	do
		vf_class "dep-${dep##*/}" makedb "deps/${dep}" \
			"^deps/${dep}/build/${dep_type}/(.*/)?lib[^/]*\\.(a|so(\\.[0-9]+)*)\$" \
			'make -j"$(nproc)"' \
			"deps/${dep} libraries (${dep_type})" \
			"vf:requires=deps/${dep}/build/${dep_type}" \
			"vf:find=build/${dep_type}" "${common[@]}"
	done

	# cmake: whisper.cpp and its ggml archives.  The top-level make
	# FORCEs `cmake --build', then relinks.
	vf_class dep-whisper cmake deps/whisper.cpp/build '' \
		'make -j"$(nproc)"' \
		'whisper.cpp / ggml archives (cmake)'

	# Lisp: Emacs loads a stale .elc rather than its newer .el, and the
	# .eln is found only through the .elc being loaded (its name carries
	# the md5 of the source, so it cannot be stale by itself).
	vf_class lisp-elc pattern lisp 'cmacs/*.elc' \
		'make -C lisp {+}' \
		'lisp/cmacs/*.elc older than their .el (loaded anyway)' \
		vf:from=.elc vf:to=.el

	# Tests: the %.elc rule has the byte compiler as a prerequisite
	# (test/Makefile.in, `## CMACS:'), so check-cmacs recompiles these
	# itself -- unless a merge dropped that hunk.
	vf_class test-elc pattern test 'cmacs/**/*.elc' \
		'make -C test {+}' \
		'test/cmacs/*.elc older than their .el or src/emacs' \
		vf:from=.elc vf:to=.el vf:extra=src/emacs \
		'vf:selfheal=test/Makefile:^%\.elc: %\.el \$\(cmacs_byte_compiler\)'
}

# ---------------------------------------------------------------------
# The engine
# ---------------------------------------------------------------------

# AWK: turn a make database (or gcc .d files) into dependency edges.
#
# Input files: the candidate list (paths relative to DIRABS, may be
# empty), then the database.  Output, tab-separated, root-relative:
#   E <artifact> <prereq>             an explicit prerequisite
#   G <artifact> <group> <stem> <p>   pattern-rule prerequisite; the
#                                     comparer picks one group the way
#                                     make does (all prerequisites
#                                     exist, shortest stem, first rule)
#   A <artifact>                      a selected artifact
#   O <target>                        its recipe is a no-op or copies
#                                     only if changed: never stale
#   M <makefile>                      a makefile make says it read,
#                                     spelled as make spelled it
# shellcheck disable=SC2016
VF_AWK_PARSE='
function norm(p,    n, i, k, parts, out, s) {
	if (substr(p, 1, 1) != "/")
		p = DIRABS "/" p
	n = split(p, parts, "/")
	k = 0
	for (i = 1; i <= n; i++) {
		if (parts[i] == "" || parts[i] == ".")
			continue
		if (parts[i] == "..") {
			if (k > 0)
				k--
			continue
		}
		out[++k] = parts[i]
	}
	s = ""
	for (i = 1; i <= k; i++)
		s = s "/" out[i]
	if (s == ROOT)
		return "."
	if (index(s, ROOT "/") == 1)
		return substr(s, length(ROOT) + 2)
	return s
}
function add_target(t,    n) {
	if (!(t in known)) {
		known[t] = 1
		order[++ntargets] = t
	}
}
# One rule line: "t1 t2: p1 p2 | o1".
function rule(line, implicit,    c, tl, pl, nt, np, ts, ps, i, j, t, bar) {
	c = index(line, ":")
	if (c == 0)
		return
	tl = substr(line, 1, c - 1)
	pl = substr(line, c + 1)
	if (substr(pl, 1, 1) == ":")
		pl = substr(pl, 2)
	# A variable assignment, not a rule.
	if (substr(pl, 1, 1) == "=" || tl ~ /[ \t]$/ && pl ~ /^=/)
		return
	if (pl ~ /^[ \t]*[A-Za-z_.][A-Za-z0-9_.-]*[ \t]*(\+|\?|!|:|::)?=/)
		return
	bar = index(pl, "|")
	if (bar > 0)
		pl = substr(pl, 1, bar - 1)
	nt = split(tl, ts, /[ \t]+/)
	np = split(pl, ps, /[ \t]+/)
	for (i = 1; i <= nt; i++) {
		t = ts[i]
		if (t == "")
			continue
		if (t == ".PHONY") {
			for (j = 1; j <= np; j++)
				if (ps[j] != "")
					phony[norm(ps[j])] = 1
			continue
		}
		if (substr(t, 1, 1) == ".")
			continue
		if (implicit || index(t, "%") > 0) {
			npat++
			ptgt[npat] = t
			pprq[npat] = pl
			continue
		}
		t = norm(t)
		add_target(t)
		cur = cur SUBSEP t
		for (j = 1; j <= np; j++)
			if (ps[j] != "")
				deps[t] = deps[t] SUBSEP ps[j]
	}
}
# Match artifact a (root-relative) against pattern rule k; print edges.
function try_pattern(a, k,    tp, pc, pre, suf, base, dir, rel, stem, np, ps, j, p, slash) {
	tp = ptgt[k]
	pc = index(tp, "%")
	if (pc == 0)
		return
	slash = index(tp, "/") > 0
	if (slash) {
		tp = norm(tp)
		pc = index(tp, "%")
		rel = a
		dir = ""
	} else {
		rel = a
		dir = ""
		if (match(a, /.*\//)) {
			dir = substr(a, 1, RLENGTH)
			rel = substr(a, RLENGTH + 1)
		}
	}
	pre = substr(tp, 1, pc - 1)
	suf = substr(tp, pc + 1)
	if (length(rel) < length(pre) + length(suf))
		return
	if (substr(rel, 1, length(pre)) != pre)
		return
	if (substr(rel, length(rel) - length(suf) + 1) != suf)
		return
	stem = substr(rel, length(pre) + 1, length(rel) - length(pre) - length(suf))
	if (stem == "")
		return
	np = split(pprq[k], ps, /[ \t]+/)
	for (j = 1; j <= np; j++) {
		if (ps[j] == "")
			continue
		p = ps[j]
		gsub(/%/, stem, p)
		if (slash)
			p = norm(p)
		else
			p = (substr(p, 1, 1) == "/") ? norm(p) : (dir == "" ? p : dir p)
		if (p in phony)
			continue
		printf "G\t%s\t%d\t%d\t%s\n", a, k, length(stem), p
	}
}
BEGIN {
	FS = "\n"
	sec = (MODE == "dfile") ? 2 : 0
	# From the environment: -v would turn the ERE backslashes into
	# string escapes.
	SEL = ENVIRON["VF_SEL"]
}
FILENAME == CANDS {
	if ($0 != "") {
		cand[norm($0)] = 1
		add_target(norm($0))
	}
	next
}
MODE == "dfile" {
	# Join backslash continuations, then treat as a rule.
	line = $0
	while (line ~ /\\$/ && (getline nxt) > 0)
		line = substr(line, 1, length(line) - 1) " " nxt
	if (line ~ /^[^#\t]/)
		rule(line, 0)
	next
}
/^@@vf-link@@ / {
	n = split($0, w, /[ \t]+/)
	t = norm(w[2])
	for (i = 3; i <= n; i++)
		if (w[i] ~ /\.(a|so)$/ && substr(w[i], 1, 1) != "-")
			link[t] = link[t] SUBSEP w[i]
	next
}
/^MAKEFILE_LIST :?= / {
	sub(/^MAKEFILE_LIST :?= */, "")
	n = split($0, w, /[ \t]+/)
	for (i = 1; i <= n; i++)
		if (w[i] != "")
			print "M\t" w[i]
	next
}
/^# Implicit Rules/ { sec = 1; next }
/^# Files/ { sec = 2; next }
/^# (VPATH Search Paths|Pattern-specific Variable Values|Directories|Variables|files hash-table stats|Finished Make data base)/ { sec = 0; next }
sec > 0 && /^[^#\t ]/ && index($0, ":") > 0 {
	cur = ""
	rule($0, sec == 1)
	next
}
# A recipe line of the file entry just read.  Remember whether every
# line is a no-op (":", "true", "test -f $@") or the whole recipe is an
# update-only-if-changed copy (move-if-change, "cmp -s || cp"): make
# re-stats such a target after running it, sees the same mtime, and
# rebuilds nothing above it -- so its being older is not staleness.
sec == 2 && /^\t/ && cur != "" {
	line = $0
	sub(/^\t[@+ -]*/, "", line)
	n = split(cur, w, SUBSEP)
	for (i = 1; i <= n; i++) {
		if (w[i] == "")
			continue
		if (!(w[i] in rcp))
			rcp[w[i]] = "noop"
		if (line ~ /move-if-change|cmp -s/)
			rcp[w[i]] = "copy"
		else if (rcp[w[i]] == "noop" && line !~ /^(:|true|test -[ef] [^;&|]*)[ \t]*$/)
			rcp[w[i]] = "real"
	}
	next
}
sec == 2 && /^$/ { cur = "" }
END {
	# A .d file set: every rule is an edge, nothing is selected here.
	if (MODE == "dfile") {
		for (i = 1; i <= ntargets; i++) {
			a = order[i]
			n = split(deps[a], w, SUBSEP)
			for (j = 1; j <= n; j++)
				if (w[j] != "" && norm(w[j]) != a)
					printf "E\t%s\t%s\n", a, norm(w[j])
		}
		exit
	}
	# Selected artifacts, then everything they reach: staleness is
	# transitive (a source newer than an object makes the archive that
	# holds the object stale), so the walk follows rules all the way.
	for (i = 1; i <= ntargets; i++) {
		a = order[i]
		if (a in phony || a !~ SEL)
			continue
		print "A\t" a
		queue[++qn] = a
		vis[a] = 1
	}
	for (qi = 1; qi <= qn; qi++) {
		a = queue[qi]
		n = split(deps[a] link[a], w, SUBSEP)
		for (j = 1; j <= n; j++) {
			if (w[j] == "")
				continue
			p = norm(w[j])
			if (p in phony || p == a)
				continue
			printf "E\t%s\t%s\n", a, p
			if (rcp[p] == "noop" || rcp[p] == "copy")
				printf "O\t%s\n", p
			if (!(p in vis)) {
				vis[p] = 1
				queue[++qn] = p
			}
		}
		# Pattern rules only for what something builds: a leaf
		# source (or a -MP phantom header) has nothing to match.
		if (deps[a] != "" || a in cand || a ~ SEL)
			for (k = 1; k <= npat; k++)
				try_pattern(a, k)
	}
}
'

# AWK: compare.  Input files: the mtime table (path, sec, nsec, type),
# then the edges.  Output, tab-separated:
#   S <artifact> <culprit> <via> <artifact sec> <culprit sec> <via sec>
#       CULPRIT is the newest file that makes ARTIFACT stale; VIA is
#       the file it is directly newer than (ARTIFACT itself, or an
#       intermediate such as an object inside an archive).
#   X <artifact>                  selected but absent
# shellcheck disable=SC2016
VF_AWK_COMPARE='
function newer(p, a) {
	if (sec[p] != sec[a])
		return sec[p] > sec[a]
	return nsec[p] > nsec[a]
}
function blame(a, c, v) {
	if (!(a in cul) || (c in sec && cul[a] in sec && newer(c, cul[a]))) {
		cul[a] = c
		via[a] = v
	}
}
# Is A stale?  Memoised depth-first walk; a cycle counts as fresh.
function stale(a,    n, i, p, ps) {
	if (a in state)
		return (a in cul)
	state[a] = 1
	if (a in opaque)
		return 0
	n = split(pre[a], ps, SUBSEP)
	for (i = 1; i <= n; i++) {
		p = ps[i]
		if (p == "" || p == a)
			continue
		if (!SYSTEM && substr(p, 1, 1) == "/")
			continue
		if (!(p in sec)) {
			# An absent intermediate that has a rule gets remade,
			# and so does everything above it.
			if (p in pre)
				blame(a, p, p)
			continue
		}
		if (typ[p] == "directory")
			continue
		if (newer(p, a))
			blame(a, p, a)
		else if (stale(p))
			blame(a, cul[p], via[p])
	}
	return (a in cul)
}
BEGIN { FS = "\t" }
FNR == NR {
	sec[$1] = $2 + 0
	nsec[$1] = $3 + 0
	typ[$1] = $4
	next
}
$1 == "A" { if (!($2 in seen)) { seen[$2] = 1; arts[++na] = $2 }; next }
$1 == "E" { pre[$2] = pre[$2] SUBSEP $3; next }
$1 == "O" { opaque[$2] = 1; next }
$1 == "G" {
	g = $2 SUBSEP $3
	if (!(g in gstem)) {
		gstem[g] = $4 + 0
		glist[$2] = glist[$2] SUBSEP $3
		gok[g] = 1
	}
	gp[g] = gp[g] SUBSEP $5
	if (!($5 in sec))
		gok[g] = 0
	next
}
END {
	# Pick the pattern rule of each node the way make does: every
	# prerequisite exists, shortest stem, first defined.
	for (a in glist) {
		best = ""
		n = split(glist[a], ks, SUBSEP)
		for (j = 1; j <= n; j++) {
			if (ks[j] == "")
				continue
			g = a SUBSEP ks[j]
			if (!gok[g])
				continue
			if (best == "" || gstem[g] < gstem[best] || \
			    (gstem[g] == gstem[best] && ks[j] + 0 < bestk))
			{
				best = g
				bestk = ks[j] + 0
			}
		}
		if (best != "")
			pre[a] = pre[a] gp[best]
	}
	for (i = 1; i <= na; i++) {
		a = arts[i]
		if (!(a in sec)) {
			print "X\t" a
			continue
		}
		if (stale(a)) {
			c = cul[a]
			v = via[a]
			printf "S\t%s\t%s\t%s\t%d\t%d\t%d\n", a, c, v, sec[a], \
				(c in sec) ? sec[c] : 0, (v in sec) ? sec[v] : 0
		}
	}
}
'


# Stat every path named in an edges file into a mtime table.
vf_stat_edges () {
	local edges="${1}"
	local out="${2}"

	awk -F '\t' '
		$1 == "A" { print $2 }
		$1 == "E" { print $2; print $3 }
		$1 == "G" && $5 != "-" { print $5 }
	' "${edges}" | sort -u \
	| (cd -- "${vf_root}" >/dev/null && xargs -r -d '\n' stat -L -c '%.9Y|%F|%n' -- 2>/dev/null) \
	| awk -F '|' '{
		split($1, t, ".")
		name = substr($0, length($1) + length($2) + 3)
		printf "%s\t%s\t%s\t%s\n", name, t[1], (t[2] == "" ? 0 : t[2]), $2
	}' >"${out}"
}

# Probe one make directory: write its database to OUT.  Every makefile
# it might read is protected with -o; -q with a goal that is itself -o'd
# runs no recipe.
vf_makedb_probe () {
	local dir="${1}"
	local out="${2}"
	local linkfile="${3}"
	shift 3
	local -a args=("$@")
	local -a protect=()
	local f

	while IFS= read -r -d '' f
	do
		protect+=(-o "${f#./}" -o "${dir}/${f#./}")
	done < <(cd -- "${dir}" >/dev/null && find . \( -name .git -prune \) -o -type f \
		\( -name '*.d' -o -name '*.mk' -o -name 'Makefile' -o -name 'GNUmakefile' \
		   -o -name 'makefile' \) -print0 2>/dev/null)

	if [[ -n ${linkfile} ]]
	then
		# A link-inputs probe needs an explicit -f list.
		if [[ " ${args[*]} " != *" -f "* ]]
		then
			args=(-f Makefile "${args[@]}")
		fi
		args+=(-f "${linkfile}")
		protect+=(-o "${linkfile}")
	fi

	# Makefiles named with -f are read too, and -o the class gave.
	for ((f = 0; f + 1 < ${#args[@]}; f++))
	do
		if [[ ${args[f]} == -f ]]
		then
			protect+=(-o "${args[f + 1]}")
		elif [[ ${args[f]} == -o ]]
		then
			protect+=(-o "${args[f + 1]}")
		fi
	done

	# The protected spellings, for the after-the-fact check.
	printf '%s\n' "${protect[@]}" | grep -v -x -e '-o' >"${out}.protect"

	# SHELL is the refusing wrapper (see vf_write_shell_guard), so even
	# a makefile remake the -o list missed cannot run.
	(cd -- "${dir}" >/dev/null && VF_REFUSED_LOG="${out}.refused" LC_ALL=C \
		make -p -q --no-print-directory "SHELL=${vf_tmp}/shell-guard" \
		"${protect[@]}" "${args[@]}" Makefile) >"${out}" 2>"${out}.err"
	return 0
}

# The SHELL every probe runs with.  $(shell ...) functions must work --
# config.mk files call pkg-config and test for headers -- but no recipe
# may run.  make tells the two apart for us: while it remakes a
# makefile it drops -q from the MAKEFLAGS it exports, and the probe has
# no other recipe to run (its goal is -o'd).  So: q present, run it;
# q absent, refuse and log, which vf_edges_makedb reports.
vf_write_shell_guard () {
	local guard="${vf_tmp}/shell-guard"

	cat >"${guard}" <<'EOF'
#!/usr/bin/env bash
# Written by cmacs-verify-fresh.sh: runs $(shell) commands, refuses recipes.
flags="${MAKEFLAGS%% *}"
if [[ ${flags} == *q* ]]
then
	exec bash "$@"
fi
if [[ -n ${VF_REFUSED_LOG:-} ]]
then
	printf '%s\n' "${*: -1}" >>"${VF_REFUSED_LOG}"
fi
exit 1
EOF
	chmod +x "${guard}"
}

# Produce the edges file for one makedb class.
vf_edges_makedb () {
	local i="${1}"
	local out="${2}"
	local -a dirs=()
	local -a margs=()
	local -a finds=()
	local -a links=()
	local arg
	local d
	local n=0
	local linkfile=""
	local lk
	local cands
	local made
	local IFS=$'\x1f'
	local -a raw

	read -r -a raw <<<"${VF_ARGS[i]}"
	IFS=$' \t\n'
	for arg in "${raw[@]}"
	do
		case "${arg}" in
		vf:find=*)
			finds+=("${arg#vf:find=}")
			;;
		vf:link=*)
			links+=("${arg#vf:link=}")
			;;
		vf:requires=*)
			;;
		*)
			margs+=("${arg}")
			;;
		esac
	done

	if [[ ${#links[@]} -gt 0 ]]
	then
		linkfile="${vf_tmp}/link-${i}.mk"
		: >"${linkfile}"
		for lk in "${links[@]}"
		do
			# shellcheck disable=SC2016  # make syntax, not shell
			printf '$(info @@vf-link@@ %s $(%s))\n' "${lk%%:*}" "${lk#*:}" >>"${linkfile}"
		done
	fi

	# DIR may be a glob.
	for d in "${vf_root}"/${VF_DIR[i]}
	do
		if [[ -f ${d}/Makefile || -f ${d}/GNUmakefile || -f ${d}/makefile ]]
		then
			dirs+=("${d}")
		fi
	done

	: >"${out}"
	if [[ ${#dirs[@]} -eq 0 ]]
	then
		return 1
	fi

	# One probe per directory, in parallel.
	for d in "${dirs[@]}"
	do
		vf_makedb_probe "${d}" "${vf_tmp}/db-${i}-${n}" "${linkfile}" "${margs[@]}" &
		n=$((n + 1))
	done
	wait

	n=0
	for d in "${dirs[@]}"
	do
		cands="${vf_tmp}/cands-${i}-${n}"
		: >"${cands}"
		for arg in "${finds[@]}"
		do
			if [[ -d ${d}/${arg} ]]
			then
				(cd -- "${d}" >/dev/null && find "${arg}" -type f -print) >>"${cands}" 2>/dev/null
			fi
		done
		if ! grep -q '^# Files' "${vf_tmp}/db-${i}-${n}"
		then
			vf_warn "${VF_NAME[i]}: could not read the make database of ${d#"${vf_root}"/}: $(grep -m 1 -E '\*\*\*|rror' "${vf_tmp}/db-${i}-${n}.err" "${vf_tmp}/db-${i}-${n}")"
			n=$((n + 1))
			continue
		fi
		VF_SEL="${VF_SELECT[i]}" awk -v MODE=makedb -v ROOT="${vf_root}" \
			-v DIRABS="${d}" -v CANDS="${cands}" \
			"${VF_AWK_PARSE}" "${cands}" "${vf_tmp}/db-${i}-${n}" >>"${out}"

		# Did make try to run a recipe (remake an included makefile)?
		# The shell guard refused it; say which, so the class can be
		# given the -o that stops make asking.
		if [[ -s ${vf_tmp}/db-${i}-${n}.refused ]]
		then
			vf_warn "${VF_NAME[i]}: refused a recipe make tried to run in ${d#"${vf_root}"/}: $(head -n 1 "${vf_tmp}/db-${i}-${n}.refused" | cut -c1-120)"
		fi

		# Did the probe read a makefile no -o protected, under the
		# spelling make used?  Then it could have remade it: say so,
		# so the class can be given that -o.
		while IFS= read -r made
		do
			vf_warn "${VF_NAME[i]}: make read ${made} (in ${d#"${vf_root}"/}) unprotected by -o; add it to the class"
		done < <(awk -F '\t' '$1 == "M" { print $2 }' "${out}" \
			| sort -u | grep -v -F -x -f "${vf_tmp}/db-${i}-${n}.protect" || true)
		sed -i '/^M\t/d' "${out}"
		n=$((n + 1))
	done
	return 0
}

# Produce the edges file for one cmake build tree.
vf_edges_cmake () {
	local i="${1}"
	local out="${2}"
	local dir="${vf_root}/${VF_DIR[i]}"
	local cands="${vf_tmp}/cands-${i}"
	local lib
	local name
	local obj

	: >"${out}"
	if [[ ! -f ${dir}/CMakeCache.txt ]]
	then
		return 1
	fi
	: >"${cands}"

	# Objects against their compiler dependency files.  The .o.d
	# target is spelled relative to the build tree; the object sits
	# next to its .d either way.
	find "${dir}" -name '*.o.d' -type f -print0 2>/dev/null \
	| VF_SEL='^$' xargs -r -0 awk -v MODE=dfile -v ROOT="${vf_root}" \
		-v DIRABS="${dir}" -v CANDS="${cands}" "${VF_AWK_PARSE}" "${cands}" >>"${out}"

	# Archives against the objects of their own CMakeFiles/<T>.dir.
	while IFS= read -r -d '' lib
	do
		name="${lib##*/lib}"
		name="${name%.a}"
		printf 'A\t%s\n' "${lib#"${vf_root}"/}" >>"${out}"
		while IFS= read -r -d '' obj
		do
			printf 'E\t%s\t%s\n' "${lib#"${vf_root}"/}" "${obj#"${vf_root}"/}" >>"${out}"
		done < <(find "${lib%/*}/CMakeFiles/${name}.dir" -name '*.o' -type f -print0 2>/dev/null)
	done < <(find "${dir}" -name 'lib*.a' -type f -print0 2>/dev/null)
	return 0
}

# Produce the edges file for one pattern-rule class.
vf_edges_pattern () {
	local i="${1}"
	local out="${2}"
	local dir="${vf_root}/${VF_DIR[i]}"
	local from=""
	local to=""
	local -a extras=()
	local arg
	local f
	local rel
	local IFS=$'\x1f'
	local -a raw

	read -r -a raw <<<"${VF_ARGS[i]}"
	IFS=$' \t\n'
	for arg in "${raw[@]}"
	do
		case "${arg}" in
		vf:from=*)
			from="${arg#vf:from=}"
			;;
		vf:to=*)
			to="${arg#vf:to=}"
			;;
		vf:extra=*)
			extras+=("${arg#vf:extra=}")
			;;
		esac
	done

	: >"${out}"
	if [[ ! -d ${dir} ]]
	then
		return 1
	fi

	shopt -s globstar
	for f in "${dir}"/${VF_SELECT[i]}
	do
		rel="${f#"${vf_root}"/}"
		printf 'A\t%s\n' "${rel}"
		printf 'E\t%s\t%s\n' "${rel}" "${rel%"${from}"}${to}"
		for arg in "${extras[@]}"
		do
			printf 'E\t%s\t%s\n' "${rel}" "${arg}"
		done
	done >>"${out}"
	shopt -u globstar
	return 0
}

# Does a class's vf:requires= / vf:selfheal= hold?
vf_class_arg () {
	local i="${1}"
	local key="${2}"
	local arg
	local IFS=$'\x1f'
	local -a raw

	read -r -a raw <<<"${VF_ARGS[i]}"
	for arg in "${raw[@]}"
	do
		if [[ ${arg} == "vf:${key}="* ]]
		then
			printf '%s\n' "${arg#"vf:${key}="}"
			return 0
		fi
	done
	return 1
}

# Run one class: write $vf_tmp/res-I (the S/X lines) or nothing when
# the class does not apply to this tree.
vf_run_class () {
	local i="${1}"
	local edges="${vf_tmp}/edges-${i}"
	local mt="${vf_tmp}/mtime-${i}"
	local req

	if req="$(vf_class_arg "${i}" requires)" && [[ ! -e ${vf_root}/${req} ]]
	then
		return 0
	fi
	case "${VF_KIND[i]}" in
	makedb)
		vf_edges_makedb "${i}" "${edges}" || return 0
		;;
	cmake)
		vf_edges_cmake "${i}" "${edges}" || return 0
		;;
	pattern)
		vf_edges_pattern "${i}" "${edges}" || return 0
		;;
	*)
		vf_warn "${VF_NAME[i]}: unknown kind ${VF_KIND[i]}"
		return 0
		;;
	esac
	vf_stat_edges "${edges}" "${mt}"
	awk -v SYSTEM="${vf_system}" "${VF_AWK_COMPARE}" "${mt}" "${edges}" \
		| sort -t "$(printf '\t')" -k2,2 >"${vf_tmp}/res-${i}"
	grep -c '^A' "${edges}" >"${vf_tmp}/count-${i}" || true
}

# Is class I selected?  --only globs pick classes by name; without
# them every class runs, except that --gate leaves out vf:gate=no ones.
vf_selected () {
	local i="${1}"
	local name="${VF_NAME[i]}"
	local glob
	local gate
	local -a globs

	if [[ -z ${vf_only} ]]
	then
		if [[ ${vf_gate} -eq 1 ]] && gate="$(vf_class_arg "${i}" gate)" && [[ ${gate} == no ]]
		then
			return 1
		fi
		return 0
	fi
	IFS=',' read -r -a globs <<<"${vf_only}"
	for glob in "${globs[@]}"
	do
		# shellcheck disable=SC2053  # the glob is the point
		if [[ ${name} == ${glob} ]]
		then
			return 0
		fi
	done
	return 1
}

# Build the fix command of class I for its stale artifacts.
vf_fix_command () {
	local i="${1}"
	local fix="${VF_FIX[i]}"
	local dir="${VF_DIR[i]}"
	local list=""
	local a

	if [[ ${fix} == *'{+}'* ]]
	then
		while IFS=$'\t' read -r _ a _
		do
			list+=" ${a#"${dir}"/}"
		done < <(grep '^S' "${vf_tmp}/res-${i}")
		fix="${fix//\{+\}/${list# }}"
	fi
	printf '%s\n' "${fix}"
}

# Report class I.  Returns 0 when it has failing stale artifacts.
vf_report_class () {
	local i="${1}"
	local res="${vf_tmp}/res-${i}"
	local n_stale
	local n_missing
	local n_checked=0
	local selfheal=""
	local heal_file
	local heal_re
	local shown=0
	local a
	local p
	local as
	local ps
	local tag="STALE"

	if [[ ! -f ${res} ]]
	then
		return 1
	fi
	n_stale="$(grep -c '^S' "${res}")"
	n_missing="$(grep -c '^X' "${res}")"
	if [[ -f ${vf_tmp}/count-${i} ]]
	then
		n_checked="$(<"${vf_tmp}/count-${i}")"
	fi

	if selfheal="$(vf_class_arg "${i}" selfheal)"
	then
		heal_file="${selfheal%%:*}"
		heal_re="${selfheal#*:}"
		if [[ -f ${vf_root}/${heal_file} ]] && grep -q -E -- "${heal_re}" "${vf_root}/${heal_file}"
		then
			tag="note "
		else
			selfheal=""
		fi
	fi

	if [[ ${n_stale} -eq 0 ]]
	then
		if [[ ${vf_verbose} -eq 1 ]]
		then
			vf_say "fresh ${VF_NAME[i]}: ${n_checked} checked -- ${VF_DESC[i]}"
		fi
	else
		vf_say "${tag} ${VF_NAME[i]}: ${n_stale} of ${n_checked} -- ${VF_DESC[i]}"
		while IFS=$'\t' read -r _ a p v as ps vs
		do
			if [[ ${vf_all} -eq 0 && ${shown} -ge ${vf_max_shown} ]]
			then
				vf_say "    ... and $((n_stale - shown)) more (--all lists them)"
				break
			fi
			vf_say "    ${a}  ($(printf '%(%F %T)T' "${as}"))"
			if [[ ${ps} -eq 0 ]]
			then
				vf_say "      needs ${p}, which is absent but has a rule"
			elif [[ ${v} == "${a}" ]]
			then
				vf_say "      older than ${p}  ($(printf '%(%F %T)T' "${ps}"))"
			else
				vf_say "      via ${v}  ($(printf '%(%F %T)T' "${vs}"))"
				vf_say "      older than ${p}  ($(printf '%(%F %T)T' "${ps}"))"
			fi
			shown=$((shown + 1))
		done < <(grep '^S' "${res}")
		if [[ -n ${selfheal} ]]
		then
			vf_say "    (not a failure: ${heal_file} rebuilds these before it uses them)"
		fi
		vf_say "    fix: $(vf_fix_command "${i}" | cut -c1-200)"
	fi

	if [[ ${vf_verbose} -eq 1 && ${n_missing} -gt 0 ]]
	then
		vf_say "absent ${VF_NAME[i]}: ${n_missing} artifact(s) not built"
		while IFS=$'\t' read -r _ a
		do
			vf_say "    ${a}"
		done < <(grep '^X' "${res}")
	fi

	if [[ ${n_stale} -gt 0 && -z ${selfheal} ]]
	then
		vf_total_stale=$((vf_total_stale + n_stale))
		return 0
	fi
	if [[ ${n_stale} -gt 0 ]]
	then
		vf_total_notes=$((vf_total_notes + n_stale))
	fi
	return 1
}

# Check every selected class; fill vf_stale_classes.
vf_check () {
	local i
	local n_classes=0

	vf_total_stale=0
	vf_total_notes=0
	vf_stale_classes=()
	rm -f "${vf_tmp}"/res-* "${vf_tmp}"/count-*

	for i in "${!VF_NAME[@]}"
	do
		if vf_selected "${i}"
		then
			vf_run_class "${i}" &
		fi
	done
	wait

	for i in "${!VF_NAME[@]}"
	do
		if ! vf_selected "${i}" || [[ ! -f ${vf_tmp}/res-${i} ]]
		then
			continue
		fi
		n_classes=$((n_classes + 1))
		if vf_report_class "${i}"
		then
			vf_stale_classes+=("${i}")
		fi
	done

	if [[ ${vf_total_stale} -gt 0 ]]
	then
		vf_say "${VF_SELF}: ${vf_total_stale} stale artifact(s) in ${#vf_stale_classes[@]} class(es) -- a test run now would exercise old code"
		return 1
	fi
	if [[ ${vf_total_notes} -gt 0 ]]
	then
		vf_say "${VF_SELF}: fresh (${n_classes} classes checked, ${vf_total_notes} self-healing note(s))"
	else
		vf_say "${VF_SELF}: fresh (${n_classes} classes checked)"
	fi
	return 0
}

# Run the fix commands of every stale class (and self-healing ones).
vf_run_fixes () {
	local i
	local cmd
	local rc=0
	local -a done_cmds=()
	local seen

	for i in "${!VF_NAME[@]}"
	do
		if [[ ! -f ${vf_tmp}/res-${i} ]] || ! grep -q '^S' "${vf_tmp}/res-${i}"
		then
			continue
		fi
		cmd="$(vf_fix_command "${i}")"
		for seen in "${done_cmds[@]}"
		do
			if [[ ${seen} == "${cmd}" ]]
			then
				continue 2
			fi
		done
		done_cmds+=("${cmd}")
		vf_say "${VF_SELF}: [${VF_NAME[i]}] ${cmd}"
		if [[ -n ${CMACS_BUILD_LOCK:-} ]]
		then
			(cd -- "${vf_root}" >/dev/null && flock "${CMACS_BUILD_LOCK}" bash -c "${cmd}") || rc=1
		else
			(cd -- "${vf_root}" >/dev/null && bash -c "${cmd}") || rc=1
		fi
	done
	return "${rc}"
}

vf_main () {
	local rc
	local i

	while [[ $# -gt 0 ]]
	do
		case "${1}" in
		-f|--fix)
			vf_fix=1
			;;
		-q|--quiet)
			vf_quiet=1
			;;
		-a|--all)
			vf_all=1
			;;
		-v|--verbose)
			vf_verbose=1
			;;
		-g|--gate)
			vf_gate=1
			;;
		-s|--system)
			vf_system=1
			;;
		-l|--list)
			vf_list=1
			;;
		-o|--only)
			if [[ $# -lt 2 ]]
			then
				echo "${VF_SELF}: ${1} needs an argument" >&2
				exit 2
			fi
			vf_only="${2}"
			shift
			;;
		--only=*)
			vf_only="${1#--only=}"
			;;
		-r|--root)
			if [[ $# -lt 2 ]]
			then
				echo "${VF_SELF}: ${1} needs an argument" >&2
				exit 2
			fi
			vf_root="${2}"
			shift
			;;
		--root=*)
			vf_root="${1#--root=}"
			;;
		-h|--help)
			vf_usage
			exit 0
			;;
		--license)
			vf_license
			exit 0
			;;
		--version)
			echo "${VF_SELF} ${VF_VERSION}"
			exit 0
			;;
		*)
			echo "${VF_SELF}: unknown option: ${1} (see --help)" >&2
			exit 2
			;;
		esac
		shift
	done

	if [[ ${vf_gate} -eq 1 && ${CMACS_SKIP_FRESH_CHECK:-0} == 1 ]]
	then
		vf_warn "CMACS_SKIP_FRESH_CHECK=1: not checking build artifacts"
		exit 0
	fi

	if [[ -z ${vf_root} ]]
	then
		vf_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." >/dev/null && pwd -P)"
	else
		vf_root="$(cd -- "${vf_root}" >/dev/null && pwd -P)" || exit 2
	fi

	vf_register_classes

	if [[ ${vf_list} -eq 1 ]]
	then
		for i in "${!VF_NAME[@]}"
		do
			printf '%-24s %-8s %s\n' "${VF_NAME[i]}" "${VF_KIND[i]}" "${VF_DESC[i]}"
		done
		exit 0
	fi

	vf_tmp="$(mktemp -d "${TMPDIR:-/tmp}/cmacs-verify-fresh.XXXXXX")" || exit 2
	trap vf_cleanup EXIT
	vf_write_shell_guard

	vf_check
	rc=$?

	if [[ ${vf_fix} -eq 1 && ${rc} -ne 0 || ${vf_fix} -eq 1 && ${vf_total_notes} -gt 0 ]]
	then
		vf_run_fixes || vf_warn "a rebuild command failed"
		vf_say "${VF_SELF}: checking again"
		vf_check
		rc=$?
	fi

	if [[ ${rc} -ne 0 && ${vf_gate} -eq 1 ]]
	then
		vf_say "${VF_SELF}: refusing to test a stale tree.  Rebuild with the commands above"
		vf_say "  (or \`admin/${VF_SELF} --fix'), or run anyway with CMACS_SKIP_FRESH_CHECK=1."
	fi
	exit "${rc}"
}

# A gate runs inside `make -C test': an inherited MAKEFLAGS (-B, -k,
# jobserver fds) would reach every probe.  Start clean.
unset MAKEFLAGS MFLAGS MAKELEVEL

vf_main "$@"
