#!/usr/bin/env bash
# cmacs-sherpa-gen-config.sh --- generate plist -> sherpa config tables
#
# Copyright (C) 2026 Zach Podbielniak
# SPDX-License-Identifier: AGPL-3.0-or-later
#
# sherpa-onnx configures every engine with a nested C struct: the
# offline recognizer alone has ~20 model families and well over a
# hundred leaf fields, and every release adds some.  Hand-writing the
# mapping from a Lisp plist to those fields would be a few thousand
# lines that silently fall behind the submodule.
#
# So the mapping is generated from the header itself.  The header is run
# through the preprocessor (which drops its comments), every
# `typedef struct SherpaOnnxX { ... } SherpaOnnxX;' is parsed, and each
# top-level config struct named below is flattened into a table of
#
#     { "model-config.whisper.encoder", CMACS_SHERPA_F_STR,
#       offsetof (SherpaOnnxOfflineRecognizerConfig,
#                 model_config.whisper.encoder) },
#
# one row per leaf of type `const char *', `int32_t' or `float'.  Keys
# are the struct path with `_' turned into `-', which is what Lisp
# passes (`:model-config.whisper.encoder').  Pointer arrays and
# `const float *' leaves are skipped: no config takes them from Lisp.
#
# Run by src/Makefile.in whenever c-api.h is newer than the output, so
# a submodule bump regenerates the tables and a renamed field becomes a
# compile error in the one place that names fields by hand.

set -euo pipefail

readonly SCRIPT_NAME="cmacs-sherpa-gen-config.sh"

# Top-level structs that cmacs fills from a plist.
readonly ROOTS=(
	SherpaOnnxOfflineRecognizerConfig
	SherpaOnnxOnlineRecognizerConfig
	SherpaOnnxKeywordSpotterConfig
	SherpaOnnxVadModelConfig
	SherpaOnnxOfflineTtsConfig
	SherpaOnnxGenerationConfig
	SherpaOnnxOfflineSpeakerDiarizationConfig
	SherpaOnnxSpeakerEmbeddingExtractorConfig
	SherpaOnnxOfflinePunctuationConfig
	SherpaOnnxOnlinePunctuationConfig
	SherpaOnnxSpokenLanguageIdentificationConfig
	SherpaOnnxAudioTaggingConfig
	SherpaOnnxOfflineSpeechDenoiserConfig
	SherpaOnnxOnlineSpeechDenoiserConfig
	SherpaOnnxOfflineSourceSeparationConfig
)

usage () {
	cat <<'EOF'
cmacs-sherpa-gen-config.sh - generate sherpa-onnx config field tables

Usage:
  admin/cmacs-sherpa-gen-config.sh [-s SHERPA_DIR] [-o OUTPUT] [-c CC]

Options:
  -s, --source DIR   sherpa-onnx checkout (default: deps/sherpa-onnx)
  -o, --output FILE  output header (default: stdout)
  -c, --cc CC        C compiler used as preprocessor (default: $CC or gcc)
  -h, --help         show this help
      --license      show the license

Examples:
  # what src/Makefile.in runs
  admin/cmacs-sherpa-gen-config.sh -o cmacs/sherpa/cmacs-sherpa-config-tables.h

  # inspect the keys the offline recognizer accepts
  admin/cmacs-sherpa-gen-config.sh | grep -A3 OfflineRecognizerConfig
EOF
}

license () {
	cat <<'EOF'
cmacs-sherpa-gen-config.sh
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

main () {
	local root source output cc
	root="$(cd -- "$(dirname -- "$0")/.." >/dev/null && pwd)"
	source="${root}/deps/sherpa-onnx"
	output=""
	cc="${CC:-gcc}"

	while [[ $# -gt 0 ]]
	do
		case "${1}" in
			-s|--source) source="${2:?--source needs a directory}"; shift 2 ;;
			-o|--output) output="${2:?--output needs a file}"; shift 2 ;;
			-c|--cc) cc="${2:?--cc needs a compiler}"; shift 2 ;;
			-h|--help) usage; exit 0 ;;
			--license) license; exit 0 ;;
			*) echo "${SCRIPT_NAME}: unknown option: ${1}" >&2; usage >&2; exit 1 ;;
		esac
	done

	if [[ ! -f "${source}/sherpa-onnx/c-api/c-api.h" ]]
	then
		echo "${SCRIPT_NAME}: ${source}/sherpa-onnx/c-api/c-api.h not found" >&2
		exit 1
	fi

	local tmp gen
	tmp="$(mktemp)"
	gen="$(mktemp)"
	# shellcheck disable=SC2064  # expand now
	trap "rm -f -- '${tmp}' '${gen}'" EXIT

	# The preprocessor strips the header's doc comments, leaving one
	# field per line, which is all the awk below has to understand.
	echo '#include "sherpa-onnx/c-api/c-api.h"' \
		| "${cc}" -E -P -I "${source}" - > "${tmp}"

	{
		emit_header
		awk -v roots="${ROOTS[*]}" -f /dev/stdin "${tmp}" <<'AWK'
# Pass 1: record every struct's fields as "TYPE NAME" lines.
/^typedef struct SherpaOnnx[A-Za-z0-9_]* \{/ {
	cur = $3
	nfields[cur] = 0
	next
}
cur != "" && /^\}/ { cur = ""; next }
cur != "" {
	line = $0
	sub(/^[ \t]+/, "", line)
	sub(/;[ \t]*$/, "", line)
	if (line ~ /^const char \*const \*/ || line ~ /\[/) next
	if (match(line, /^const char \*[A-Za-z0-9_]+$/)) {
		name = substr(line, 13); type = "STR"
	} else if (line ~ /^int32_t [A-Za-z0-9_]+$/) {
		name = substr(line, 9); type = "INT"
	} else if (line ~ /^float [A-Za-z0-9_]+$/) {
		name = substr(line, 7); type = "FLOAT"
	} else if (line ~ /^SherpaOnnx[A-Za-z0-9_]+ [A-Za-z0-9_]+$/) {
		split(line, parts, " "); type = parts[1]; name = parts[2]
	} else {
		next
	}
	nfields[cur]++
	ftype[cur, nfields[cur]] = type
	fname[cur, nfields[cur]] = name
}

# Recursively print leaf rows of struct S under C path PREFIX.
function walk(root, s, prefix,    i, t, n, path, key) {
	for (i = 1; i <= nfields[s]; i++) {
		t = ftype[s, i]; n = fname[s, i]
		path = (prefix == "" ? n : prefix "." n)
		if (t == "STR" || t == "INT" || t == "FLOAT") {
			key = path
			gsub(/_/, "-", key)
			printf "  { \"%s\", CMACS_SHERPA_F_%s,\n    offsetof (%s, %s) },\n", key, t, root, path
		} else if (t in nfields) {
			walk(root, t, path)
		}
	}
}

END {
	n = split(roots, list, " ")
	for (r = 1; r <= n; r++) {
		root = list[r]
		if (!(root in nfields)) {
			printf "#error \"c-api.h no longer defines %s\"\n", root
			continue
		}
		printf "\nstatic const CmacsSherpaField cmacs_sherpa_fields_%s[] = {\n", substr(root, 11)
		walk(root, root, "")
		printf "  { NULL, CMACS_SHERPA_F_STR, 0 }\n};\n"
	}
}
AWK
	} > "${gen}"

	if grep -q '^#error' "${gen}"
	then
		grep '^#error' "${gen}" >&2
		exit 1
	fi

	if [[ -z "${output}" ]]
	then
		cat -- "${gen}"
	elif [[ -f "${output}" ]] && cmp -s "${gen}" "${output}"
	then
		# move-if-changed: an unchanged table must not touch the
		# header's mtime, or every sherpa object recompiles.
		:
	else
		cp -f -- "${gen}" "${output}"
	fi
}

emit_header () {
	cat <<'EOF'
/* cmacs-sherpa-config-tables.h --- GENERATED, do not edit.
 *
 * Generated by admin/cmacs-sherpa-gen-config.sh from
 * deps/sherpa-onnx/sherpa-onnx/c-api/c-api.h.  One table per top-level
 * sherpa-onnx config struct, one row per settable leaf field.  Included
 * only by cmacs-sherpa-config.c.
 */

#include <stddef.h>
EOF
}

main "$@"
