#!/usr/bin/env bash
# cmacs-capability-audit.sh --- measure how much of cmacs's RPC surface
# comes from the one capability table, and how much is still hand-written.
#
# Copyright (C) 2026 Zach Podbielniak
# SPDX-License-Identifier: AGPL-3.0-or-later
#
# The tool registry (`cmacs-brigade-deftool') is the table every surface
# is meant to derive from: MCP, org.cmacs.Editor1.Tools, `emacsctl tool'
# and the generated reference all read it.  What predates it is three
# hand-written tables that say the same things again:
#
#   cmacs/mcp/cmacs-mcp-tools-*.c       one C handler per MCP tool (only
#                                       the deliberate remainder is left:
#                                       the handlers the registry replaced
#                                       were deleted, and what they
#                                       published is frozen in
#                                       test/cmacs/data/mcp-wire-schema.json)
#   cmacs/dbus/cmacs-dbus-iface-*.c     one D-Bus method per capability
#   cmacs/emacsctl/ctl-cmd-*.c          one row per CLI verb
#
# This script lists every entry in those three and marks each one
# `registry' (a registered tool already provides it, so the hand-written
# copy is a fallback or a duplicate), `kept' (an MCP tool that stays in
# C on purpose -- KEPT below says why, tool by tool) or `hand-written'
# (nothing in the registry provides it yet, and nothing says it should
# stay).  The last set is the migration that is left, as a list instead
# of a feeling; `--remainder' prints the middle one with its reasons.
#
# It reads source text only.  It starts no editor, makes no D-Bus call
# and needs no build -- except `--write-docs' and `--check-docs', which
# run a batch Emacs to regenerate the reference the audit reads.
#
# What "a registered tool provides it" means, precisely:
#
#   MCP       the tool's name is a registry wire name or alias.
#   D-Bus     the registry has a tool called PREFIX_method, where PREFIX
#             is the interface's prefix (IFACE_PREFIX below, else the
#             interface's last word in snake_case) and method is the
#             method in snake_case -- or METHOD_TOOL below names one.
#   emacsctl  the row's D-Bus method is provided, by the rule above.
#             Flag-driven commands (not table rows) are always
#             hand-written: their flags are C.
#
# The registry's names come from the generated, drift-guarded reference
# doc_org/cmacs/cmacs-capability-reference.org, so this needs no Emacs
# and cannot disagree with what the tests accept.

set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" > /dev/null && pwd)"
ROOT="$(cd -- "${SCRIPT_DIR}/.." > /dev/null && pwd)"
REFERENCE="${CMACS_CAPABILITY_REFERENCE:-${ROOT}/doc_org/cmacs/cmacs-capability-reference.org}"

# MCP tools that are hand-written C on purpose, each with its reason.
# This is the whole deliberate remainder: an MCP tool that is neither in
# the registry nor here is unfinished migration, and shows as such.
# Since the migrated handlers were deleted, every tool the C files
# register should be here: the summary's mcp TOTAL and KEPT are equal,
# and a HAND-WRITTEN count above zero is a C tool someone added without
# deciding.  (`capability_doctor' in cmacs-mcp-tools-brigade.c is not
# one: it is the stand-in for the registry's own tool of that name,
# registered only when the registry failed to load.)
#
# Three reasons recur, so they are written once:
PRIVILEGED="privileged: runs caller-supplied code or types caller-supplied input"
IMAGE="returns image content; a registry tool returns text"
NATIVE="C introspection of the running binary; the handler is the feature"
declare -A KEPT=(
    [eval]="${PRIVILEGED}"
    [execute_command]="${PRIVILEGED}"
    [send_keys]="${PRIVILEGED}"
    [send_to_process]="${PRIVILEGED}"
    [gi_call]="${PRIVILEGED}"
    [bacon_eval]="${PRIVILEGED}"
    [crispy_eval]="${PRIVILEGED}"
    [podomation_eval_dsl]="${PRIVILEGED}"
    [podomation_repl_eval]="${PRIVILEGED}"
    [gowl_hotkey_send]="${PRIVILEGED}"
    [cmacs.c.compile_snippet]="${PRIVILEGED}"
    [cmacs.c.call_handle]="${PRIVILEGED}"
    [cmacs.c.patch_defun]="${PRIVILEGED}"
    [cmacs.c.unpatch_defun]="${PRIVILEGED}"
    [cmacs.c.unpatch_all]="${PRIVILEGED}"
    [cmacs.c.list]="${NATIVE}"
    [cmacs.c.symbol_info]="${NATIVE}"
    [cmacs.c.type_info]="${NATIVE}"
    [cmacs.c.function_source]="${NATIVE}"
    [cmacs.c.addr_to_source]="${NATIVE}"
    [cmacs.c.defun_info]="${NATIVE}"
    [cmacs.c.stack_trace]="${NATIVE}"
    [cmacs.c.patch_log]="${NATIVE}"
    [gowl_screenshot]="${IMAGE}"
    [cad_snapshot]="${IMAGE}"
    [lrgterm_dump_screen]="${IMAGE}"
    [video_snapshot]="${IMAGE}"
)

# D-Bus interface (last word) -> the prefix its tools carry in the
# registry, where that is not simply the interface name in snake_case.
declare -A IFACE_PREFIX=(
    [Brigade]="agent"
    [Calc]="calc"
    [Compositor]="gowl"
    [DbExplorer]="db"
    [GnusEye]="gnuseye"
    [Lrg]="lrgeditor"
    [SecondBrain]="secondbrain"
)

# Interface.Method -> registry tool, for the methods whose name the rule
# above does not reach.  Add a line here when a migrated tool was named
# differently from the method it replaces.
declare -A METHOD_TOOL=(
    [Calc.ListCalculators]="calc_list"
    [Brigade.Agents]="agent_list"
    [SecondBrain.Ingest]="secondbrain_ingest"
    [SecondBrain.IngestStatus]="secondbrain_ingest_status"
    [DbExplorer.Connections]="db_connections"
)

# The generic interface itself: neither migrated nor waiting to be.
GENERIC_IFACE="Tools"

# The three-argument match() below is gawk's.  Fedora's awk is gawk; a
# distro whose awk is mawk has to have gawk installed for this script.
AWK="$(command -v gawk || true)"

declare -A REGISTRY=()

show_help () {
    cat << 'EOF'
Usage: cmacs-capability-audit.sh [OPTION]

Measure how much of cmacs's RPC surface is derived from the capability
table (the brigade tool registry) and how much is still hand-written.

Options:
      --summary        Counts per surface (the default)
      --list SURFACE   Every entry of SURFACE with its status, as
                       tab-separated  SURFACE NAME STATUS SOURCE
                       SURFACE is mcp, dbus, cli or all
      --hand-written   Like --list all, but only what is left to migrate
      --remainder      The MCP tools that stay in C on purpose, as
                       tab-separated  NAME REASON SOURCE
      --families       Hand-written MCP tools counted per C file: the
                       migration queue, smallest family first
      --write-docs     Regenerate the capability reference (org + texi)
                       from the shipped lisp/cmacs files, in batch Emacs
      --check-docs     Exit 1 if the checked-in reference is stale
  -h, --help           Show this help
      --license        Show the license

Environment:
  EMACS   The Emacs to run for --write-docs/--check-docs
          (default: src/emacs in this tree)
  CMACS_CAPABILITY_REFERENCE
          Read the registry's names from this file instead of the
          checked-in reference (to audit a tree before regenerating)

Statuses:
  registry      a registered tool provides it; the hand-written copy is
                a fallback or a duplicate and can go
  kept          an MCP tool hand-written on purpose (see --remainder)
  hand-written  nothing in the registry provides it yet
  generic       part of org.cmacs.Editor1.Tools itself
  forwarded     a D-Bus method that is a row of
                cmacs/dbus/cmacs-dbus-forward-table.h: served by a tool
                (or a redacting Lisp method function), with no
                hand-written body left

Examples:
  # How far along is the migration?
  admin/cmacs-capability-audit.sh

  # Which family is cheapest to migrate next?
  admin/cmacs-capability-audit.sh --families

  # Every hand-written D-Bus method, for a checklist
  admin/cmacs-capability-audit.sh --list dbus | rg 'hand-written$'

  # After adding or changing a cmacs-brigade-deftool
  admin/cmacs-capability-audit.sh --write-docs

  # What will never be a registry tool, and why
  admin/cmacs-capability-audit.sh --remainder
EOF
}

show_license () {
    cat << 'EOF'
cmacs-capability-audit.sh
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

die () {
    echo "cmacs-capability-audit: ${1}" >&2
    exit 1
}

# Print ${1}, a CamelCase word, in snake_case.
snake () {
    local word="${1}"

    # A capital that starts a new word gets an underscore in front of it:
    # after a lower-case letter or digit (EvalJs -> eval_js), and before
    # the last capital of a run that is followed by lower case
    # (GetURIFor -> get_uri_for).
    sed -E 's/([a-z0-9])([A-Z])/\1_\2/g; s/([A-Z]+)([A-Z][a-z])/\1_\2/g' \
        <<< "${word}" | tr '[:upper:]' '[:lower:]'
}

# Fill REGISTRY with every wire name and alias in the reference.
load_registry () {
    local name
    local alias_line
    local alias

    [[ -r "${REFERENCE}" ]] \
        || die "no ${REFERENCE#"${ROOT}/"}; run --write-docs first"

    while IFS= read -r name
    do
        REGISTRY["${name}"]=1
    done < <(sed -n -E 's/^\*\* ([a-z0-9_]+)$/\1/p' "${REFERENCE}")

    while IFS= read -r alias_line
    do
        # "a, b, c" -> one name per line
        while IFS= read -r alias
        do
            [[ -n "${alias}" ]] && REGISTRY["${alias}"]=1
        done < <(tr ',' '\n' <<< "${alias_line}" | tr -d ' ')
    done < <(sed -n -E 's/^- Aliases :: (.*)$/\1/p' "${REFERENCE}")

    [[ ${#REGISTRY[@]} -gt 0 ]] \
        || die "the reference lists no tools; is it truncated?"
}

# Every MCP tool the C files register, as "NAME<TAB>FILE".  Three
# spellings are in use and all three are literal, so text is enough:
#   mcp_tool_new ("name", ...)             the direct call
#   xx_add (server, "name", ...)           a per-file helper around it
#   { "name", TRUE|FALSE, ...              a row of a tools[] table
# The brigade file is skipped: what it registers IS the registry.
mcp_entries () {
    local file
    local base

    for file in "${ROOT}"/cmacs/mcp/cmacs-mcp-tools-*.c
    do
        base="$(basename -- "${file}")"
        [[ "${base}" == "cmacs-mcp-tools-brigade.c" ]] && continue
        {
            # `.' as well: the introspection tools are cmacs.c.list etc.
            sed -n -E 's/.*mcp_tool_new \("([a-z0-9_.]+)".*/\1/p' "${file}"
            sed -n -E 's/^[[:space:]]*[a-z_]+ \(server,[[:space:]]*"([a-z0-9_.]+)".*/\1/p' "${file}"
            sed -n -E 's/^[[:space:]]*\{ "([a-z0-9_.]+)", (TRUE|FALSE).*/\1/p' "${file}"
        } | sort -u | sed "s/\$/\t${base}/"
    done
}

# Every D-Bus method cmacs serves under org.cmacs.Editor1, as
# "IFACE.Method<TAB>FILE" with IFACE the interface's last word ("" for
# the root interface, printed as Editor1).
dbus_entries () {
    local file

    for file in "${ROOT}"/cmacs/dbus/*.c "${ROOT}"/cmacs/glib/*.c
    do
        # shellcheck disable=SC2016  # an awk program, not a shell string
        "${AWK}" -v base="$(basename -- "${file}")" '
            match($0, /<interface name=.([A-Za-z0-9.]+)/, m) {
                iface = m[1]
            }
            match($0, /<method name=.([A-Za-z0-9]+)/, m) {
                if (iface ~ /^org\.cmacs\.Editor1/) {
                    last = iface
                    sub(/^.*\./, "", last)
                    printf "%s.%s\t%s\n", last, m[1], base
                }
            }' "${file}"
    done
}

# Every emacsctl verb.  Table rows as "VERB<TAB>IFACE.Method<TAB>FILE",
# flag-driven commands as "VERB<TAB>-<TAB>FILE".  A row spans lines: the
# verb on one, the CTL_IFACE_* constant and method on a later one.
cli_entries () {
    local file
    local base
    local -A iface_of=()
    local constant
    local value
    local verb
    local method

    while read -r constant value
    do
        iface_of["${constant}"]="${value##*.}"
    done < <(sed -n -E 's/^#define (CTL_IFACE_[A-Z_]+)[[:space:]]+"([^"]+)".*/\1 \2/p' \
                 "${ROOT}/cmacs/emacsctl/ctl-ifaces.h")

    for file in "${ROOT}"/cmacs/emacsctl/ctl-cmd-*.c
    do
        base="$(basename -- "${file}")"
        # `emacsctl tool' is the registry's own surface, not a table.
        [[ "${base}" == "ctl-cmd-tool.c" ]] && continue

        # shellcheck disable=SC2016  # an awk program, not a shell string
        while IFS=$'\t' read -r verb constant method
        do
            printf '%s\t%s.%s\t%s\n' "${verb}" \
                   "${iface_of[${constant}]:-?}" "${method}" "${base}"
        done < <("${AWK}" '
            match($0, /^[[:space:]]*\{ "([a-z0-9 _-]+)",/, m) { verb = m[1] }
            match($0, /(CTL_IFACE_[A-Z_]+), "([A-Za-z0-9]+)"/, m) {
                if (verb != "") {
                    printf "%s\t%s\t%s\n", verb, m[1], m[2]
                    verb = ""
                }
            }' "${file}")

        # ctl_simple_command_new[_with_options] ( "verb", ...
        # shellcheck disable=SC2016  # an awk program, not a shell string
        "${AWK}" -v base="${base}" '
            /ctl_simple_command_new(_with_options)? \(/ { pending = 1 }
            pending && match($0, /"([a-z0-9 _-]+)"/, m) {
                printf "%s\t-\t%s\n", m[1], base
                pending = 0
            }' "${file}"
    done
}

# The D-Bus forwarding table, cmacs/dbus/cmacs-dbus-forward-table.h:
# "Iface.Method" -> the tool or @method-function that serves it.  Read
# as text, one FWD (...) row per line, which is the format that file
# promises.
declare -A FORWARD=()
FORWARD_LOADED=0

load_forward () {
    local table="${ROOT}/cmacs/dbus/cmacs-dbus-forward-table.h"
    local iface method target

    FORWARD_LOADED=1
    [[ -r "${table}" ]] || return 0
    while IFS=$'\t' read -r iface method target
    do
        FORWARD["${iface}.${method}"]="${target}"
    done < <(sed -n \
        's/^FWD ("\([^"]*\)", "\([^"]*\)", "\([^"]*\)",.*$/\1\t\2\t\3/p' \
        "${table}")
}

# Print the status of the D-Bus method ${1} ("Iface.Method").
dbus_status () {
    local entry="${1}"
    local iface="${entry%%.*}"
    local method="${entry#*.}"
    local prefix
    local tool

    if [[ "${iface}" == "${GENERIC_IFACE}" ]]
    then
        echo "generic"
        return
    fi

    # A row of the forwarding table: the method has no body of its own
    # any more, whatever its name would have matched.
    [[ "${FORWARD_LOADED}" -eq 1 ]] || load_forward
    if [[ -n "${FORWARD[${entry}]:-}" ]]
    then
        echo "forwarded"
        return
    fi

    tool="${METHOD_TOOL[${entry}]:-}"
    if [[ -z "${tool}" ]]
    then
        prefix="${IFACE_PREFIX[${iface}]:-$(snake "${iface}")}"
        tool="${prefix}_$(snake "${method}")"
    fi

    if [[ -n "${REGISTRY[${tool}]:-}" ]]
    then
        echo "registry"
    else
        echo "hand-written"
    fi
}

# Print "SURFACE<TAB>NAME<TAB>STATUS<TAB>SOURCE" for the surface ${1}.
list_surface () {
    local surface="${1}"
    local name
    local source
    local method

    case "${surface}" in
        mcp)
            while IFS=$'\t' read -r name source
            do
                # The registry wins over KEPT: a tool that has been
                # migrated after all must not keep reading as kept.
                if [[ -n "${REGISTRY[${name}]:-}" ]]
                then
                    printf 'mcp\t%s\tregistry\t%s\n' "${name}" "${source}"
                elif [[ -n "${KEPT[${name}]:-}" ]]
                then
                    printf 'mcp\t%s\tkept\t%s\n' "${name}" "${source}"
                else
                    printf 'mcp\t%s\thand-written\t%s\n' "${name}" "${source}"
                fi
            done < <(mcp_entries)
            ;;
        dbus)
            while IFS=$'\t' read -r name source
            do
                printf 'dbus\t%s\t%s\t%s\n' "${name}" \
                       "$(dbus_status "${name}")" "${source}"
            done < <(dbus_entries)
            ;;
        cli)
            while IFS=$'\t' read -r name method source
            do
                if [[ "${method}" == "-" ]]
                then
                    printf 'cli\t%s\thand-written\t%s\n' "${name}" "${source}"
                else
                    printf 'cli\t%s\t%s\t%s\n' "${name}" \
                           "$(dbus_status "${method}")" "${source}"
                fi
            done < <(cli_entries)
            ;;
        all)
            list_surface mcp
            list_surface dbus
            list_surface cli
            ;;
        *)
            die "unknown surface '${surface}' (mcp, dbus, cli or all)"
            ;;
    esac
}

summary () {
    local listing

    listing="$(list_surface all)"

    printf 'registry tools (wire names + aliases): %d\n\n' "${#REGISTRY[@]}"
    printf '%-10s %8s %10s %6s %14s %9s %10s\n' \
           "SURFACE" "TOTAL" "REGISTRY" "KEPT" "HAND-WRITTEN" "GENERIC" \
           "FORWARDED"
    awk -F'\t' '
        { total[$1]++; count[$1, $3]++ }
        END {
            n = split("mcp dbus cli", order, " ")
            for (i = 1; i <= n; i++) {
                s = order[i]
                printf "%-10s %8d %10d %6d %14d %9d %10d\n", s, total[s],
                       count[s, "registry"], count[s, "kept"],
                       count[s, "hand-written"], count[s, "generic"],
                       count[s, "forwarded"]
            }
        }' <<< "${listing}"
    printf '\nmcp = tools registered by cmacs/mcp/cmacs-mcp-tools-*.c'
    printf ' (the registry'"'"'s own publisher excluded).\n'
    printf 'kept = MCP tools hand-written on purpose; --remainder says why.\n'
    printf 'dbus = methods of org.cmacs.Editor1[.X] in cmacs/dbus + cmacs/glib.\n'
    printf 'forwarded = D-Bus methods served from the capability table'
    printf ' (cmacs-dbus-forward-table.h).\n'
    printf 'cli = emacsctl verbs outside `emacsctl tool'"'"'.\n'
}

families () {
    printf '%-36s %6s %10s %6s %14s\n' \
           "MCP FILE" "TOOLS" "REGISTRY" "KEPT" "HAND-WRITTEN"
    list_surface mcp | awk -F'\t' '
        { total[$4]++; count[$4, $3]++ }
        END {
            for (f in total)
                printf "%-36s %6d %10d %6d %14d\n", f, total[f],
                       count[f, "registry"], count[f, "kept"],
                       count[f, "hand-written"]
        }' | sort -k5,5n -k1,1
}

# Print "NAME<TAB>REASON<TAB>SOURCE" for every MCP tool that is kept in
# C on purpose, and warn about KEPT entries that name no tool any more:
# a reason for a tool that was deleted or renamed is a stale table.
remainder () {
    local name
    local source
    local -A seen=()

    while IFS=$'\t' read -r name source
    do
        seen["${name}"]=1
        if [[ -z "${REGISTRY[${name}]:-}" && -n "${KEPT[${name}]:-}" ]]
        then
            printf '%s\t%s\t%s\n' "${name}" "${KEPT[${name}]}" "${source}"
        fi
    done < <(mcp_entries)

    for name in "${!KEPT[@]}"
    do
        if [[ -z "${seen[${name}]:-}" ]]
        then
            echo "cmacs-capability-audit: KEPT lists '${name}', which no C file registers" >&2
        elif [[ -n "${REGISTRY[${name}]:-}" ]]
        then
            echo "cmacs-capability-audit: KEPT lists '${name}', which the registry now provides" >&2
        fi
    done
}

# Run the batch generator with ${1} = "" (write) or "--check".
run_generator () {
    local mode="${1}"
    local emacs="${EMACS:-${ROOT}/src/emacs}"
    local home
    local status=0

    [[ -x "${emacs}" ]] || die "no Emacs at ${emacs}; set EMACS"

    # An empty HOME: the reference describes the tools cmacs ships, not
    # the ones this user's init file adds, and a generator that read the
    # real config would produce a different file on every machine.
    home="$(mktemp -d)"
    # shellcheck disable=SC2086  # ${mode} is deliberately absent when empty
    HOME="${home}" \
    XDG_CONFIG_HOME="${home}/config" \
    XDG_DATA_HOME="${home}/data" \
    XDG_STATE_HOME="${home}/state" \
    XDG_CACHE_HOME="${home}/cache" \
        "${emacs}" --batch -Q -L "${ROOT}/lisp/cmacs" \
        --eval '(setq load-prefer-newer t)' \
        -l cmacs-capability \
        -f cmacs-capability-batch-write-reference "${ROOT}" ${mode} \
        || status=$?
    rm -rf -- "${home}"

    case "${status}" in
        0) ;;
        1) die "the capability reference is stale; run --write-docs" ;;
        2) die "a tool file would not load in this build; the reference needs a full default build" ;;
        *) die "the generator exited ${status}" ;;
    esac
}

main () {
    local action="${1:---summary}"

    [[ -n "${AWK}" ]] || die "gawk is required (package: gawk)"

    case "${action}" in
        -h|--help)
            show_help
            ;;
        --license)
            show_license
            ;;
        --summary)
            load_registry
            summary
            ;;
        --list)
            [[ $# -ge 2 ]] || die "--list needs a surface (mcp, dbus, cli or all)"
            load_registry
            list_surface "${2}"
            ;;
        --hand-written)
            load_registry
            list_surface all | awk -F'\t' '$3 == "hand-written"'
            ;;
        --families)
            load_registry
            families
            ;;
        --remainder)
            load_registry
            remainder
            ;;
        --write-docs)
            run_generator ""
            ;;
        --check-docs)
            run_generator "--check"
            ;;
        *)
            show_help >&2
            exit 2
            ;;
    esac
}

main "$@"
