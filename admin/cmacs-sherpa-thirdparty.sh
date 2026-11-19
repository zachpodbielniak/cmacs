#!/usr/bin/env bash
# cmacs-sherpa-thirdparty.sh --- pre-stage sherpa-onnx's FetchContent tarballs
#
# Copyright (C) 2026 Zach Podbielniak
# SPDX-License-Identifier: AGPL-3.0-or-later
#
# sherpa-onnx's CMake build pulls about a dozen third-party sources
# (kaldi-native-fbank, kaldi-decoder, openfst, eigen, utf8proc, json,
# simple-sentencepiece, hclust-cpp, ...) with FetchContent at CONFIGURE
# time.  A build that reaches the network from inside cmake is a build
# that fails in a container without network, on a plane, and whenever
# GitHub has a bad afternoon -- and it fails with a cmake download error
# that names none of this.
#
# Every one of those modules (deps/sherpa-onnx/cmake/<name>.cmake) has
# the same three lines:
#
#     set(<name>_URL  "https://...")
#     set(<name>_HASH "SHA256=...")
#     ${CMAKE_BINARY_DIR}/<file>.tar.gz      # in possible_file_locations
#
# and before downloading it checks that list and uses the first local
# file it finds.  So no patch is needed: this script reads the three
# lines out of each module, downloads each tarball ONCE into a cache
# (verified against the module's own SHA256), and copies it into the
# build directory under the exact name the module looks for.  cmake then
# never opens a socket.
#
# onnxruntime is deliberately excluded: cmacs always builds against the
# system onnxruntime (pkg-config libonnxruntime), never sherpa's prebuilt
# download.  So are the modules cmacs turns off (portaudio, googletest,
# pybind11, websocketpp, asio, directml).
#
# See doc_org/cmacs/cmacs-sherpa.org, "Building".

set -euo pipefail

readonly SCRIPT_NAME="cmacs-sherpa-thirdparty.sh"

# Modules cmacs never enables, plus onnxruntime (system only).
readonly SKIP_REGEX='^(onnxruntime.*|directml|portaudio|googletest|pybind11|websocketpp|asio)$'

usage () {
	cat <<'EOF'
cmacs-sherpa-thirdparty.sh - pre-stage sherpa-onnx third-party tarballs

Usage:
  admin/cmacs-sherpa-thirdparty.sh [OPTIONS]

Options:
  -s, --source DIR   sherpa-onnx checkout (default: deps/sherpa-onnx)
  -b, --build DIR    cmake build dir to stage into (default: SOURCE/build)
  -c, --cache DIR    download cache (default: $XDG_CACHE_HOME/cmacs/sherpa-thirdparty)
  -l, --list         print NAME FILE URL SHA256 for every staged module, no I/O
  -o, --offline      never download; fail if a tarball is not cached
  -h, --help         show this help
      --license      show the license

Examples:
  # stage everything the default build needs (what `make' runs)
  admin/cmacs-sherpa-thirdparty.sh

  # see what would be fetched
  admin/cmacs-sherpa-thirdparty.sh --list

  # container build: cache populated in an earlier layer, never download
  admin/cmacs-sherpa-thirdparty.sh --offline --cache /var/cache/sherpa
EOF
}

license () {
	cat <<'EOF'
cmacs-sherpa-thirdparty.sh
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

# Print "NAME FILE URL SHA256" for one cmake module, or nothing when the
# module does not follow the URL/HASH/CMAKE_BINARY_DIR shape.
module_entry () {
	if [[ $# -ne 1 ]]
	then
		echo 'module_entry() requires 1 positional argument' >&2
		echo 'module_entry <cmake-module>' >&2
		exit 1
	fi

	local module="${1}"
	local name url hash file

	name="$(basename -- "${module}" .cmake)"
	if [[ "${name}" =~ ${SKIP_REGEX} ]]
	then
		return 0
	fi

	# First primary URL (not URL2, the hf-mirror fallback).
	url="$(sed -nE 's/^[[:space:]]*set\([A-Za-z0-9_-]+_URL[[:space:]]+"(https?:[^"]+)"\).*/\1/p' "${module}" | head -n 1)"
	hash="$(sed -nE 's/^[[:space:]]*set\([A-Za-z0-9_-]+_HASH[[:space:]]+"SHA256=([0-9a-fA-F]{64})"\).*/\1/p' "${module}" | head -n 1)"
	file="$(sed -nE 's/^[[:space:]]*\$\{CMAKE_BINARY_DIR\}\/([^[:space:]")]+).*/\1/p' "${module}" | head -n 1)"

	if [[ -z "${url}" || -z "${hash}" || -z "${file}" ]]
	then
		return 0
	fi

	printf '%s %s %s %s\n' "${name}" "${file}" "${url}" "${hash}"
}

# Verify FILE against SHA256; return 0 on match.
sha_ok () {
	if [[ $# -ne 2 ]]
	then
		echo 'sha_ok() requires 2 positional arguments' >&2
		echo 'sha_ok <file> <sha256>' >&2
		exit 1
	fi

	local file="${1}"
	local want="${2}"
	local have

	[[ -f "${file}" ]] || return 1
	have="$(sha256sum -- "${file}" | cut -d' ' -f1)"
	[[ "${have,,}" == "${want,,}" ]]
}

# Make sure CACHE/FILE exists and matches; download it unless OFFLINE.
fetch_one () {
	if [[ $# -ne 5 ]]
	then
		echo 'fetch_one() requires 5 positional arguments' >&2
		echo 'fetch_one <cache> <file> <url> <sha256> <offline>' >&2
		exit 1
	fi

	local cache="${1}"
	local file="${2}"
	local url="${3}"
	local sha="${4}"
	local offline="${5}"
	local dest="${cache}/${file}"
	local part="${dest}.part"

	if sha_ok "${dest}" "${sha}"
	then
		return 0
	fi

	if [[ "${offline}" == "yes" ]]
	then
		echo "${SCRIPT_NAME}: ${file} is not cached and --offline was given" >&2
		echo "${SCRIPT_NAME}: expected ${dest} (sha256 ${sha})" >&2
		return 1
	fi

	echo "${SCRIPT_NAME}: fetching ${file}" >&2
	# -C - resumes an interrupted .part; --fail turns a 404 page into an error.
	if ! curl -L --fail --silent --show-error --retry 3 -C - -o "${part}" -- "${url}"
	then
		echo "${SCRIPT_NAME}: download failed: ${url}" >&2
		return 1
	fi

	if ! sha_ok "${part}" "${sha}"
	then
		echo "${SCRIPT_NAME}: sha256 mismatch for ${file} (from ${url})" >&2
		echo "${SCRIPT_NAME}: removing ${part}; re-run to fetch it again" >&2
		rm -f -- "${part}"
		return 1
	fi

	mv -f -- "${part}" "${dest}"
}

# Print module entries for the cmake/*.cmake files INSIDE an archive.
nested_entries () {
	if [[ $# -ne 1 ]]
	then
		echo 'nested_entries() requires 1 positional argument' >&2
		echo 'nested_entries <archive>' >&2
		exit 1
	fi

	local archive="${1}"
	local tmp module

	tmp="$(mktemp -d)"
	# shellcheck disable=SC2064  # expand now: tmp is local
	trap "rm -rf -- '${tmp}'" RETURN
	case "${archive}" in
		*.zip)
			unzip -q -o "${archive}" '*/cmake/*.cmake' -d "${tmp}" 2>/dev/null || true ;;
		*)
			tar -xf "${archive}" -C "${tmp}" --wildcards '*/cmake/*.cmake' 2>/dev/null || true ;;
	esac
	for module in "${tmp}"/*/cmake/*.cmake
	do
		[[ -f "${module}" ]] || continue
		module_entry "${module}"
	done
}

main () {
	local root source build cache offline list
	local name file url sha
	local -a entries=()
	local failed=0

	root="$(cd -- "$(dirname -- "$0")/.." >/dev/null && pwd)"
	source="${root}/deps/sherpa-onnx"
	build=""
	cache="${XDG_CACHE_HOME:-${HOME}/.cache}/cmacs/sherpa-thirdparty"
	offline="no"
	list="no"

	while [[ $# -gt 0 ]]
	do
		case "${1}" in
			-s|--source) source="${2:?--source needs a directory}"; shift 2 ;;
			-b|--build) build="${2:?--build needs a directory}"; shift 2 ;;
			-c|--cache) cache="${2:?--cache needs a directory}"; shift 2 ;;
			-l|--list) list="yes"; shift ;;
			-o|--offline) offline="yes"; shift ;;
			-h|--help) usage; exit 0 ;;
			--license) license; exit 0 ;;
			*) echo "${SCRIPT_NAME}: unknown option: ${1}" >&2; usage >&2; exit 1 ;;
		esac
	done

	build="${build:-${source}/build}"

	if [[ ! -d "${source}/cmake" ]]
	then
		echo "${SCRIPT_NAME}: ${source}/cmake not found (run admin/cmacs-submodules.sh)" >&2
		exit 1
	fi

	# Collect every module that follows the URL/HASH/local-file shape.
	local module entry
	for module in "${source}"/cmake/*.cmake
	do
		entry="$(module_entry "${module}")"
		[[ -n "${entry}" ]] && entries+=("${entry}")
	done

	[[ "${list}" == "yes" ]] || mkdir -p -- "${cache}" "${build}"

	# A worklist, not a loop over a fixed list: some fetched sources
	# fetch their own deps the same way (kaldi-native-fbank -> kissfft,
	# kaldi-decoder -> kaldifst), and they too look in CMAKE_BINARY_DIR,
	# which is the top-level build dir for every FetchContent subproject.
	# So each archive's own cmake/*.cmake are scanned once it is cached,
	# and anything new joins the end of the list.
	local -A seen=()
	local i=0 nested
	while [[ "${i}" -lt "${#entries[@]}" ]]
	do
		entry="${entries[${i}]}"
		i=$((i + 1))
		read -r name file url sha <<<"${entry}"
		if [[ -n "${seen[${file}]:-}" ]]
		then
			continue
		fi
		seen[${file}]=1

		if [[ "${list}" == "yes" ]]
		then
			printf '%s\n' "${entry}"
			# --list does no I/O: nested entries are shown only when
			# their parent is already cached.
			sha_ok "${cache}/${file}" "${sha}" || continue
		else
			if ! fetch_one "${cache}" "${file}" "${url}" "${sha}" "${offline}"
			then
				failed=1
				continue
			fi
			# Copy only when the build copy is missing or differs, so a
			# re-run leaves mtimes (and cmake's own checks) alone.
			if ! sha_ok "${build}/${file}" "${sha}"
			then
				cp -f -- "${cache}/${file}" "${build}/${file}"
			fi
		fi

		while IFS= read -r nested
		do
			[[ -n "${nested}" ]] && entries+=("${nested}")
		done < <(nested_entries "${cache}/${file}")
	done

	if [[ "${failed}" -ne 0 ]]
	then
		echo "${SCRIPT_NAME}: some third-party tarballs could not be staged" >&2
		exit 1
	fi

	if [[ "${list}" != "yes" ]]
	then
		echo "${SCRIPT_NAME}: staged ${#seen[@]} tarballs into ${build}" >&2
	fi
}

main "$@"
