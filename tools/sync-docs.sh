#!/bin/bash
# sync-docs.sh — verify doc_org/cmacs/ and doc/cmacs/ stay in sync
#
# Copyright (C) 2026 Zach Podbielniak
# SPDX-License-Identifier: AGPL-3.0-or-later
#
# The two trees carry the same user-facing reference in two formats:
# Org (primary, interactive) and Texinfo (the formal manual, built into
# Info).  This script looks for the ways they drift apart.
#
# Directory pairs are DISCOVERED, not listed: a new subsystem is
# checked the moment its docs exist.  The previous version hardcoded
# two names, so everything added after it went unchecked.
#
# Three documentation conventions are in use, and conflating them
# produces nothing but false alarms, so each is recognised:
#
#   per-topic   doc_org/cmacs/<n>/*.org and doc/cmacs/<n>/*.texi both
#               hold one file per topic, and the basenames match.
#               Enforced: any future divergence is drift.
#               (dbus, emacsctl, libreclaw)
#
#   consolidated  Several .org topics, but a single <n>.texi chapter
#               covering them.  Topic parity does NOT apply; the
#               chapter just has to exist and be reachable.
#               (gnuseye, roamgraph, ai-brigade, lrgscript, ...)
#
#   hybrid      Some topics split into their own .texi, the rest folded
#               into the master as plain @node sections.  A directory
#               declares this itself, with
#                   #+SYNC_DOCS: folded topic1 topic2
#               in its index.org -- listing exactly which topics live in
#               the master.  Anything NOT listed is still held to strict
#               parity, so the declaration cannot quietly excuse future
#               drift.  (calculator: catalog and reference)
#
#   standalone  A <n>.texi that opens with \input texinfo: its own
#               manual, built separately, deliberately NOT @include'd.
#               (org-ex)
#
# Checks performed:
#   1. strictly paired directories keep matching topic basenames
#   2. every included chapter is actually @include'd by cmacs.texi
#      (a chapter nothing includes is invisible in Info)
#   3. a standalone manual is NOT @include'd (it would nest a second
#      \input texinfo inside the master and break the build)
#   4. every compiled-in subsystem has some doc_org manual
#   5. directories present in only one tree are reported
#
# Exit codes:
#   0  — in sync
#   1  — mismatch found (reported on stderr)
#   2  — usage / environment error
#
# Usage:
#   tools/sync-docs.sh                (from anywhere in the repo)
#   tools/sync-docs.sh --quiet        (only report problems)
#   tools/sync-docs.sh --list         (show what was discovered)

set -euo pipefail

usage () {
    cat <<'USAGE'
sync-docs.sh — verify doc_org/cmacs/ and doc/cmacs/ stay in sync

Usage: tools/sync-docs.sh [--quiet] [--list]

  --quiet   report only problems; say nothing when everything is fine
  --list    print each discovered directory and how it was classified

Directory pairs are discovered rather than hardcoded.  Per-topic pairs
must have matching basenames; consolidated and standalone manuals are
recognised and exempted from topic parity.  See the comments at the top
of this script for what each convention means.
USAGE
}

quiet=0
list=0
for arg in "$@"; do
    case "${arg}" in
        -h|--help) usage; exit 0 ;;
        --quiet)   quiet=1 ;;
        --list)    list=1 ;;
        *)
            echo "sync-docs.sh: unknown argument: ${arg}" >&2
            usage >&2
            exit 2
            ;;
    esac
done

repo_root="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
org_root="${repo_root}/doc_org/cmacs"
tex_root="${repo_root}/doc/cmacs"
master="${tex_root}/cmacs.texi"

for d in "${org_root}" "${tex_root}"; do
    if [[ ! -d "${d}" ]]; then
        echo "sync-docs.sh: missing ${d}" >&2
        exit 2
    fi
done
if [[ ! -f "${master}" ]]; then
    echo "sync-docs.sh: missing ${master}" >&2
    exit 2
fi

status=0

note () { [[ ${quiet} -eq 1 ]] || printf '%s\n' "$*"; }
fail () { printf 'sync-docs.sh: %s\n' "$*" >&2; status=1; }

# ── Discover the directories in each tree ──────────────────────────
mapfile -t org_dirs < <(
    cd "${org_root}" && find . -maxdepth 1 -mindepth 1 -type d \
        -printf '%f\n' | sort)
mapfile -t tex_dirs < <(
    cd "${tex_root}" && find . -maxdepth 1 -mindepth 1 -type d \
        -printf '%f\n' | sort)

in_list () {
    local needle="$1"; shift
    local e
    for e in "$@"; do [[ "${e}" == "${needle}" ]] && return 0; done
    return 1
}

# ── 1-3: per directory present in BOTH trees ───────────────────────
check_dir () {
    local name="$1"
    local org_dir="${org_root}/${name}"
    local tex_dir="${tex_root}/${name}"
    local chapter="${tex_dir}/${name}.texi"

    local -a org_files tex_files
    mapfile -t org_files < <(
        cd "${org_dir}"
        find . -maxdepth 1 -name '*.org' -printf '%f\n' \
            | sed 's/\.org$//' | grep -v '^index$' | sort)
    mapfile -t tex_files < <(
        cd "${tex_dir}"
        find . -maxdepth 1 -name '*.texi' -printf '%f\n' \
            | sed 's/\.texi$//' | grep -v "^${name}$" | sort)

    if [[ ! -f "${chapter}" ]]; then
        fail "${name}: no ${name}.texi chapter in doc/cmacs/${name}/"
        return
    fi

    # A chapter that opens with \input texinfo is its own manual and
    # must NOT be included; anything else is a fragment and must be.
    local standalone=no
    head -3 "${chapter}" | grep -qF '\input texinfo' && standalone=yes

    local included=no
    grep -q "@include ${name}/${name}\.texi" "${master}" && included=yes

    if [[ "${standalone}" == yes ]]; then
        if [[ "${included}" == yes ]]; then
            fail "${name}: standalone manual is @include'd by cmacs.texi;" \
                 "nesting a second \\input texinfo breaks the build"
        fi
    elif [[ "${included}" == no ]]; then
        fail "${name}: ${name}.texi is never @include'd by cmacs.texi," \
             "so the chapter is unreachable in Info"
    fi

    # Topic parity applies wherever the texi side is split into topics
    # at all.  Topics the directory has DECLARED as folded into the
    # master are exempt; everything else is held to 1:1.  Reading the
    # exemption from the directory rather than from a table in here is
    # what keeps this script free of a hardcoded list -- and listing
    # them individually means a newly-added topic is still caught.
    local kind only_org only_tex folded=""
    if [[ -f "${org_dir}/index.org" ]]; then
        folded=$(sed -n 's/^#+SYNC_DOCS:[[:space:]]*folded[[:space:]]*//p' \
                     "${org_dir}/index.org" | head -1)
    fi

    if [[ ${#tex_files[@]} -eq 0 ]]; then
        kind=$([[ "${standalone}" == yes ]] && echo standalone \
                                            || echo consolidated)
    else
        kind=$([[ -n "${folded// }" ]] && echo hybrid || echo per-topic)

        # Drop the declared-folded topics from the org side before
        # comparing.
        local -a effective_org=()
        local t skip
        for t in ${org_files[@]+"${org_files[@]}"}; do
            skip=no
            for f in ${folded}; do
                [[ "${t}" == "${f}" ]] && { skip=yes; break; }
            done
            [[ "${skip}" == no ]] && effective_org+=("${t}")
        done

        only_org=$(comm -23 \
            <(printf '%s\n' ${effective_org[@]+"${effective_org[@]}"}) \
            <(printf '%s\n' "${tex_files[@]}") | tr '\n' ' ')
        only_tex=$(comm -13 \
            <(printf '%s\n' ${effective_org[@]+"${effective_org[@]}"}) \
            <(printf '%s\n' "${tex_files[@]}") | tr '\n' ' ')

        if [[ -n "${only_org// }" ]]; then
            fail "${name}: topics only in doc_org/cmacs/${name}/:" \
                 "${only_org}" \
                 "(add the .texi, or declare them folded into" \
                 "${name}.texi with a #+SYNC_DOCS: folded line in" \
                 "doc_org/cmacs/${name}/index.org)"
        fi
        if [[ -n "${only_tex// }" ]]; then
            fail "${name}: topics only in doc/cmacs/${name}/:" \
                 "${only_tex}"
        fi

        # A declaration naming a topic that no longer exists is itself
        # drift -- it would silently excuse a real gap later.
        for f in ${folded}; do
            in_list "${f}" ${org_files[@]+"${org_files[@]}"} || \
                fail "${name}: index.org declares '${f}' folded, but" \
                     "doc_org/cmacs/${name}/${f}.org does not exist"
        done

        [[ ${list} -eq 1 && -n "${folded// }" ]] && \
            printf '  %-12s %-13s folded into %s.texi: %s\n' \
                   "" "" "${name}" "${folded}"
    fi

    [[ ${list} -eq 1 ]] && \
        printf '  %-12s %-13s %2d org topic(s)\n' \
               "${name}" "${kind}" "${#org_files[@]}"
    return 0
}

for name in "${org_dirs[@]}"; do
    in_list "${name}" ${tex_dirs[@]+"${tex_dirs[@]}"} && check_dir "${name}"
done

# ── 4: every compiled-in subsystem has a doc_org manual ────────────
# The feature list is authoritative (cmacs/core/cmacs-features.c), so a
# new subsystem that ships without documentation is caught here.  Read
# it from the source rather than a built binary so this works in a
# clean tree.
mapfile -t features < <(
    awk '/cmacs_feature_names\[\]/,/^};/' \
        "${repo_root}/cmacs/core/cmacs-features.c" 2>/dev/null \
        | sed -n 's/^[[:space:]]*"\([a-z0-9-]\+\)",.*/\1/p' | sort -u)

# Documented as part of another subsystem's manual rather than having
# one of its own.  Keep this list short and justified.
declare -A doc_exempt=(
    [gsurf-lrg]="a second gsurf backend; covered by cmacs-gsurf.org"
)

undocumented=()
for f in ${features[@]+"${features[@]}"}; do
    [[ -n "${doc_exempt[${f}]:-}" ]] && continue
    if [[ ! -e "${org_root}/cmacs-${f}.org" \
       && ! -e "${org_root}/${f}.org" \
       && ! -d "${org_root}/${f}" ]]; then
        undocumented+=("${f}")
    fi
done
if [[ ${#undocumented[@]} -gt 0 ]]; then
    fail "subsystems with no doc_org/cmacs manual:" \
         "$(printf '%s ' "${undocumented[@]}")"
fi

# ── 5: directories in only one tree ────────────────────────────────
# Informational.  Several are legitimate: a subsystem may keep its Org
# reference in a directory while its Texinfo lives in a single
# top-level chapter, or vice versa.
for name in "${org_dirs[@]}"; do
    in_list "${name}" ${tex_dirs[@]+"${tex_dirs[@]}"} || \
        note "  note: doc_org/cmacs/${name}/ has no doc/cmacs/${name}/"
done
for name in "${tex_dirs[@]}"; do
    in_list "${name}" ${org_dirs[@]+"${org_dirs[@]}"} || \
        note "  note: doc/cmacs/${name}/ has no doc_org/cmacs/${name}/"
done

if [[ ${status} -eq 0 ]]; then
    note "docs in sync: ${#org_dirs[@]} org dirs, ${#tex_dirs[@]} texi dirs," \
         "${#features[@]} subsystems documented"
fi

exit ${status}
