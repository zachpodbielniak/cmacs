#!/usr/bin/env bash
# cmacs-speech-catalog.sh --- build etc/cmacs/speech-models.eld from the seed
#
# Copyright (C) 2026 Zach Podbielniak
# SPDX-License-Identifier: AGPL-3.0-or-later
#
# etc/cmacs/speech-models.yaml is the hand-curated list of models the
# speech settings buffer offers.  This turns it into what Emacs reads:
# every entry resolved to its download URL(s), checked to exist, with
# its byte size and SHA-256 attached so the downloader can show
# progress against a real total and refuse a corrupted file.
#
#   sherpa  GitHub release assets of k2-fsa/sherpa-onnx; size and digest
#           come from the release API (one paginated listing per tag)
#   whisper Hugging Face; size and SHA-256 from the LFS headers of a HEAD
#           (x-linked-size, x-linked-etag)
#   piper   Hugging Face rhasspy/piper-voices: the .onnx and its .onnx.json
#
# An entry whose source no longer exists is dropped with a warning
# rather than shipped as a dead download.  Run it after editing the seed
# and commit both files; the build never runs it (it needs the network).

set -euo pipefail

readonly SCRIPT_NAME="cmacs-speech-catalog.sh"
readonly SHERPA_RELEASES="https://github.com/k2-fsa/sherpa-onnx/releases/download"
readonly SHERPA_API="https://api.github.com/repos/k2-fsa/sherpa-onnx/releases/tags"
readonly HF="https://huggingface.co"

usage () {
	cat <<'EOF'
cmacs-speech-catalog.sh - build the speech model catalog from its YAML seed

Usage:
  admin/cmacs-speech-catalog.sh [-i SEED] [-o OUTPUT] [--no-hash]

Options:
  -i, --input FILE    seed (default: etc/cmacs/speech-models.yaml)
  -o, --output FILE   catalog (default: etc/cmacs/speech-models.eld)
      --no-hash       skip SHA-256 lookups (sizes only; faster, offline-ish)
  -h, --help          show this help
      --license       show the license

Examples:
  # after adding a model to the seed
  admin/cmacs-speech-catalog.sh

  # see what would be written
  admin/cmacs-speech-catalog.sh -o /dev/stdout
EOF
}

license () {
	cat <<'EOF'
cmacs-speech-catalog.sh
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

# Quote a string for an Elisp string literal.
lisp_string () {
	if [[ $# -ne 1 ]]
	then
		echo 'lisp_string() requires 1 positional argument' >&2
		exit 1
	fi

	local s="${1}"
	s="${s//\\/\\\\}"
	s="${s//\"/\\\"}"
	printf '"%s"' "${s}"
}

# Print "SIZE SHA256" of a sherpa release asset, from a cached listing.
sherpa_asset () {
	if [[ $# -ne 3 ]]
	then
		echo 'sherpa_asset() requires 3 positional arguments' >&2
		echo 'sherpa_asset <cache-dir> <tag> <asset>' >&2
		exit 1
	fi

	local cache="${1}"
	local tag="${2}"
	local asset="${3}"
	local listing="${cache}/${tag}.json"
	local page=1 count id

	if [[ ! -f "${listing}" ]]
	then
		# The tag's release id, then its assets page by page (the tag
		# endpoint itself embeds only the first few hundred).
		id="$(curl -sfL "${SHERPA_API}/${tag}" | yq -p json -o yaml '.id')"
		echo '[]' > "${listing}"
		while :
		do
			curl -sfL "https://api.github.com/repos/k2-fsa/sherpa-onnx/releases/${id}/assets?per_page=100&page=${page}" \
				> "${cache}/page.json" || break
			count="$(yq -p json -o yaml 'length' "${cache}/page.json")"
			[[ "${count}" -gt 0 ]] || break
			yq -p json -o json -i ". + load(\"${cache}/page.json\")" "${listing}"
			page=$((page + 1))
		done
	fi
	NAME="${asset}" yq -p json -o tsv \
		'.[] | select(.name == env(NAME)) | [.size, (.digest // "" | sub("^sha256:"; ""))]' \
		"${listing}" | head -n 1
}

# Print "SIZE SHA256" of a Hugging Face file from its LFS headers.
hf_file () {
	if [[ $# -ne 1 ]]
	then
		echo 'hf_file() requires 1 positional argument' >&2
		exit 1
	fi

	local url="${1}"
	local headers size sha

	headers="$(curl -sI "${url}" | tr -d '\r')"
	if ! grep -qiE '^HTTP/[0-9.]+ (200|302|307)' <<<"${headers}"
	then
		return 0
	fi
	size="$(grep -i '^x-linked-size:' <<<"${headers}" | tail -n1 | awk '{print $2}')"
	sha="$(grep -i '^x-linked-etag:' <<<"${headers}" | tail -n1 | awk '{print $2}' | tr -d '"')"
	if [[ -z "${size}" ]]
	then
		size="$(curl -sIL "${url}" | tr -d '\r' | grep -i '^content-length:' | tail -n1 | awk '{print $2}')"
	fi
	printf '%s\t%s\n' "${size:-0}" "${sha}"
}

url_ok () {
	if [[ $# -ne 1 ]]
	then
		echo 'url_ok() requires 1 positional argument' >&2
		exit 1
	fi

	[[ "$(curl -sIL -o /dev/null -w '%{http_code}' "${1}")" == "200" ]]
}

main () {
	local root input output hashing
	root="$(cd -- "$(dirname -- "$0")/.." >/dev/null && pwd)"
	input="${root}/etc/cmacs/speech-models.yaml"
	output="${root}/etc/cmacs/speech-models.eld"
	hashing="yes"

	while [[ $# -gt 0 ]]
	do
		case "${1}" in
			-i|--input) input="${2:?--input needs a file}"; shift 2 ;;
			-o|--output) output="${2:?--output needs a file}"; shift 2 ;;
			--no-hash) hashing="no"; shift ;;
			-h|--help) usage; exit 0 ;;
			--license) license; exit 0 ;;
			*) echo "${SCRIPT_NAME}: unknown option: ${1}" >&2; usage >&2; exit 1 ;;
		esac
	done

	local cache tmp n i
	cache="$(mktemp -d)"
	tmp="$(mktemp)"
	# shellcheck disable=SC2064  # expand now
	trap "rm -rf -- '${cache}' '${tmp}'" EXIT

	n="$(yq '.models | length' "${input}")"
	{
		printf ';; -*- mode: lisp-data -*-\n'
		printf ';; GENERATED by admin/cmacs-speech-catalog.sh from speech-models.yaml.\n'
		printf ';; Edit the YAML seed and regenerate; do not edit this file.\n'
		printf '((version . 1)\n (generated . "%s")\n (models\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
	} > "${tmp}"

	for (( i = 0; i < n; i++ ))
	do
		local id backend source comps langs quality speed desc sample
		local url size sha archive files="" meta tag asset
		id="$(yq ".models[${i}].id" "${input}")"
		backend="$(yq ".models[${i}].backend" "${input}")"
		source="$(yq ".models[${i}].source" "${input}")"
		comps="$(yq -o tsv ".models[${i}].components | join(\" \")" "${input}")"
		langs="$(yq ".models[${i}].languages | join(\" \")" "${input}")"
		quality="$(yq ".models[${i}].quality // 3" "${input}")"
		speed="$(yq ".models[${i}].speed // 3" "${input}")"
		desc="$(yq ".models[${i}].description // \"\"" "${input}")"
		sample="$(yq ".models[${i}].sample // \"\"" "${input}")"
		archive="nil"
		sha=""
		size=0

		case "${backend}" in
			sherpa)
				url="${SHERPA_RELEASES}/${source}"
				tag="${source%%/*}"
				asset="${source#*/}"
				meta="$(sherpa_asset "${cache}" "${tag}" "${asset}" || true)"
				if [[ -z "${meta}" ]]
				then
					if ! url_ok "${url}"
					then
						echo "${SCRIPT_NAME}: dropping ${id}: ${url} not found" >&2
						continue
					fi
				else
					size="$(cut -f1 <<<"${meta}")"
					sha="$(cut -f2 <<<"${meta}")"
				fi
				[[ "${asset}" == *.tar.bz2 ]] && archive='"tar.bz2"'
				[[ "${asset}" == *.tar.gz ]] && archive='"tar.gz"'
				;;
			whisper|piper)
				url="${HF}/${source%%/*}/$(cut -d/ -f2 <<<"${source}")/resolve/main/$(cut -d/ -f3- <<<"${source}")"
				meta="$(hf_file "${url}")"
				if [[ -z "${meta}" ]]
				then
					echo "${SCRIPT_NAME}: dropping ${id}: ${url} not found" >&2
					continue
				fi
				size="$(cut -f1 <<<"${meta}")"
				sha="$(cut -f2 <<<"${meta}")"
				if [[ "${backend}" == piper ]]
				then
					# The voice's config travels with it.
					local jmeta
					jmeta="$(hf_file "${url}.json")"
					files=" :extra-files ((:name $(lisp_string "${id}.json") :url $(lisp_string "${url}.json") :size ${jmeta%%$'\t'*}))"
				fi
				;;
			*)
				echo "${SCRIPT_NAME}: ${id}: unknown backend ${backend}" >&2
				continue
				;;
		esac

		[[ "${hashing}" == "yes" ]] || sha=""
		if [[ -n "${sample}" ]] && ! url_ok "${sample}"
		then
			echo "${SCRIPT_NAME}: ${id}: sample ${sample} not found; omitted" >&2
			sample=""
		fi

		{
			printf '  (:id %s :backend %s :components (%s)\n' "$(lisp_string "${id}")" "${backend}" "${comps}"
			printf '   :languages (%s) :quality %s :speed %s\n' \
				"$(for l in ${langs}; do printf '%s ' "$(lisp_string "${l}")"; done | sed 's/ $//')" \
				"${quality}" "${speed}"
			printf '   :url %s :size %s :sha256 %s :archive %s%s\n' \
				"$(lisp_string "${url}")" "${size:-0}" \
				"$( [[ -n "${sha}" ]] && lisp_string "${sha}" || printf 'nil')" \
				"${archive}" "${files}"
			[[ -n "${sample}" ]] && printf '   :sample %s\n' "$(lisp_string "${sample}")"
			printf '   :description %s)\n' "$(lisp_string "${desc}")"
		} >> "${tmp}"
		echo "${SCRIPT_NAME}: ${id} (${size} bytes)" >&2
	done
	printf '  ))\n' >> "${tmp}"

	if [[ "${output}" == /dev/stdout ]]
	then
		cat -- "${tmp}"
	else
		cp -f -- "${tmp}" "${output}"
		echo "${SCRIPT_NAME}: wrote ${output}" >&2
	fi
}

main "$@"
