#!/bin/bash
# sync-docs.sh — verify doc_org/cmacs/libreclaw/ and
#                doc/cmacs/libreclaw/ stay in sync
#
# Copyright (C) 2026 Zach Podbielniak
# SPDX-License-Identifier: AGPL-3.0-or-later
#
# The two directories contain the same user-facing reference in two
# formats: Org (primary, interactive) and Texinfo (formal manual,
# built into Info).  This script checks that both sides carry the
# same set of topic filenames so we catch drift when one format adds
# a section the other is missing.
#
# Exit codes:
#   0  — directories in sync
#   1  — mismatch found (reported on stderr)
#   2  — usage / environment error
#
# Usage:
#   tools/sync-docs.sh                (from repository root)
#   tools/sync-docs.sh --quiet        (only report mismatches)

set -euo pipefail

usage () {
    cat <<'USAGE'
sync-docs.sh — verify doc_org / doc directories are in sync

Usage: tools/sync-docs.sh [--quiet]

Compares the *basenames* (minus extension) under
  doc_org/cmacs/libreclaw/*.org
and
  doc/cmacs/libreclaw/*.texi
and exits non-zero on any mismatch.  Master index files
(doc_org/cmacs/libreclaw/index.org and doc/cmacs/libreclaw/libreclaw.texi)
are excluded — they serve as top-level TOC/@include bootstraps and
do not need per-section parity.
USAGE
}

quiet=0
for arg in "$@"; do
    case "${arg}" in
        -h|--help) usage; exit 0 ;;
        --quiet)   quiet=1 ;;
        *)
            echo "sync-docs.sh: unknown argument: ${arg}" >&2
            usage >&2
            exit 2
            ;;
    esac
done

repo_root="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
org_dir="${repo_root}/doc_org/cmacs/libreclaw"
tex_dir="${repo_root}/doc/cmacs/libreclaw"

if [[ ! -d "${org_dir}" ]]; then
    echo "sync-docs.sh: missing ${org_dir}" >&2
    exit 2
fi
if [[ ! -d "${tex_dir}" ]]; then
    echo "sync-docs.sh: missing ${tex_dir}" >&2
    exit 2
fi

# Collect org basenames, excluding the master index.org.
mapfile -t org_files < <(
    cd "${org_dir}"
    find . -maxdepth 1 -name '*.org' -printf '%f\n' \
        | sed 's/\.org$//' \
        | grep -v '^index$' \
        | sort
)

# Collect texi basenames, excluding the master libreclaw.texi.
mapfile -t tex_files < <(
    cd "${tex_dir}"
    find . -maxdepth 1 -name '*.texi' -printf '%f\n' \
        | sed 's/\.texi$//' \
        | grep -v '^libreclaw$' \
        | sort
)

# Compute set differences without writing temp files.
only_in_org=$(comm -23 \
    <(printf '%s\n' "${org_files[@]}") \
    <(printf '%s\n' "${tex_files[@]}"))
only_in_tex=$(comm -13 \
    <(printf '%s\n' "${org_files[@]}") \
    <(printf '%s\n' "${tex_files[@]}"))

status=0

if [[ -n "${only_in_org}" ]]; then
    echo "sync-docs.sh: topics only in doc_org/cmacs/libreclaw/:" >&2
    printf '  %s\n' ${only_in_org} >&2
    status=1
fi

if [[ -n "${only_in_tex}" ]]; then
    echo "sync-docs.sh: topics only in doc/cmacs/libreclaw/:" >&2
    printf '  %s\n' ${only_in_tex} >&2
    status=1
fi

if [[ ${status} -eq 0 && ${quiet} -eq 0 ]]; then
    printf '%d topic files, in sync (%s)\n' "${#org_files[@]}" \
        "$(printf '%s ' "${org_files[@]}")"
fi

exit ${status}
