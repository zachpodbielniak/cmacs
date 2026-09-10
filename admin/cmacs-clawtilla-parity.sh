#!/usr/bin/env bash
#
# cmacs-clawtilla-parity.sh - the cmacs clawtilla client answers for the
# same daemon as the GTK one, so it should reach the same parts of it.
#
# Copyright (C) 2026 Zach Podbielniak
# SPDX-License-Identifier: AGPL-3.0-or-later
#
# This file is part of CMacs.
#
# clawtilla ships tools/clawt-client-parity.sh, which compares its GTK
# and web clients across five layers and fails when a capability exists
# in only one of them.  That script lives in clawtilla and greps
# clients/gtk and clients/web; it cannot reach a client in another
# repository, and clawtilla should not have to know where cmacs is.
#
# So the third comparison lives here, against the same data sources --
# deps/clawtilla's daemon sources and its GTK client -- and applies the
# same rule in the same spirit: a capability the GTK client has and this
# one does not is a failure, not a to-do somebody remembers.
#
# Two clients drifting apart is invisible.  Nothing breaks, nothing
# warns, and somebody finds out by reaching for the half that was not
# built.

set -euo pipefail

CDPATH=

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CLAWT="${ROOT}/deps/clawtilla"
GTK_DIR="${CLAWT}/clients/gtk"
LISP_DIR="${ROOT}/lisp/cmacs"

work=""

# shellcheck disable=SC2329  # invoked by the EXIT trap below
cleanup () {
    [[ -n "${work}" ]] && rm -rf "${work}"
}

trap cleanup EXIT

if [[ ! -d "${GTK_DIR}" ]]
then
    echo "parity: ${GTK_DIR} is not checked out; skipping" >&2
    exit 0
fi

work="$(mktemp -d)"
failures=0

#
# Kinds the cmacs client is allowed to lack, each with the reason.
#
# An entry here is a decision, not a to-do.  Anything without a reason
# somebody would agree with belongs in the client instead.
#
declare -A MAY_LACK=(
    ["agent.file_read"]="same capability, different mechanism: /edit opens the file in a buffer, which is the better answer when the client IS the editor"
    ["agent.file_write"]="the other half of the same; the buffer is saved back through the same frame the GTK client would have used"
)

#
# Interface affordances, which touch no shared symbol and so cannot be
# found by grepping for one.  A marker per client.
#
# This layer is honest about its limit: it catches one half being
# removed or never written, and it cannot catch a feature nobody
# declared.
#
declare -A AFFORDANCES=(
    ["unread marker"]="clawt-unread-badge|cmacs-clawtilla-unread"
    ["unread rule"]="clawt_unread_should_count|unread-should-count"
    ["alert severity tiers"]="clawt_alert_tier_for_event|alert-tier"
    ["alert arrives read"]="clawt_alert_arrives_read|alert-arrives-read"
    ["alert filter"]="alerts_show_all|alerts-toggle-filter"
    ["alerts surface"]="build_alerts_panel|clawtilla-alerts-mode"
    ["team tally"]="clawt_team_tally|team-tally"
    ["fleet warnings"]="append_warning_rows|fleet--warnings"
    ["day dividers"]="day_divider|new-day"
    ["message runs"]="clawt_chat_run_is_start|run-is-start"
    ["transcript stamps"]="clawt_chat_time_label|time-label"
    ["markdown rendering"]="clawt_markdown_to_pango|render-markdown"
    ["live turn steps"]="clawt_gtk_steps_add|draw-activity"
    ["tool run collapsing"]="clawt_turn_step_run_summary|step-summary"
    ["steps merged into history"]="clawt_turn_step_precedes|append-history-steps"
    ["follow the live edge"]="clawt_transcript_is_at_bottom|chat--at-end-p"
    ["transcript measure"]="adw_clamp_new|clawtilla-measure"
    ["computer types"]="clawt_computer_type_count|computer-type"
    ["measure units"]="clawt_measure_unit_count|measure-unit"
    ["import modes"]="clawt_import_mode_count|import-mode"
    ["palettes from disk"]="clawt_appearance_scheme_count|appearance-scheme"
    ["connection reachability"]="clawt_connection_probe|link-notice"
    ["decision inbox"]="build_decision_page|decision"
)

#
# The library's choice enumerations.  A client is not allowed to contain
# any of their values as a literal: having a copy of the list is what
# makes a client able to disagree with it.
#
VOCABULARY_FILE="${CLAWT}/src/config/clawt-appearance.c"

banner () {
    printf '\n== %s ==\n' "$1"
}

# ── Layer 1: the daemon's frame kinds ────────────────────────────────
#
# A proxy for "feature", not a definition of one -- a client could name
# a kind and do nothing useful with it.  But every real feature has to
# talk to the daemon to do anything, so a kind one client sends and the
# other never mentions is a capability that exists in one place only.

cat "${CLAWT}"/src/core/clawt-daemon.c "${CLAWT}"/src/core/daemon-*.c 2>/dev/null \
    | grep -o 'kind, "[a-z_.]*"' \
    | sed 's/kind, "//; s/"//' | sort -u > "${work}/daemon"

grep -ohE '"[a-z_]+\.[a-z_.]+"' "${GTK_DIR}"/*.c "${GTK_DIR}"/*.h 2>/dev/null \
    | tr -d '"' | sort -u | comm -12 - "${work}/daemon" > "${work}/gtk"

grep -ohE '"[a-z_]+\.[a-z_.]+"' "${LISP_DIR}"/cmacs-clawtilla*.el 2>/dev/null \
    | tr -d '"' | sort -u | comm -12 - "${work}/daemon" > "${work}/cmacs"

comm -23 "${work}/gtk" "${work}/cmacs" > "${work}/missing"

banner "IPC frame kinds"
printf 'daemon serves %s, gtk reaches %s, cmacs reaches %s\n' \
    "$(wc -l < "${work}/daemon")" "$(wc -l < "${work}/gtk")" \
    "$(wc -l < "${work}/cmacs")"

if [[ -s "${work}/missing" ]]
then
    while read -r kind
    do
        if [[ -v MAY_LACK["${kind}"] ]]
        then
            printf '  ok       %-28s (%s)\n' "${kind}" "${MAY_LACK[${kind}]}"
        else
            printf '  MISSING  %s\n' "${kind}"
            failures=$((failures + 1))
        fi
    done < "${work}/missing"
else
    echo "  every kind the GTK client sends is reachable here"
fi

# ── Layer 2: slash commands ──────────────────────────────────────────
#
# Compared because the frame-kind check misses them entirely: /files and
# /agents and /export are all built out of frames both clients already
# send.  A check that only looks at one layer will keep finding nothing
# at the others.

grep -ohE '"/[a-z][a-z-]*"' "${GTK_DIR}"/*.c 2>/dev/null \
    | tr -d '"' | sort -u > "${work}/gtk-cmds"
grep -ohE '"/[a-z][a-z-]*"' "${LISP_DIR}"/cmacs-clawtilla*.el 2>/dev/null \
    | tr -d '"' | sort -u > "${work}/cmacs-cmds"

banner "slash commands"
printf 'gtk answers %s, cmacs answers %s\n' \
    "$(wc -l < "${work}/gtk-cmds")" "$(wc -l < "${work}/cmacs-cmds")"

if comm -23 "${work}/gtk-cmds" "${work}/cmacs-cmds" | grep -q .
then
    comm -23 "${work}/gtk-cmds" "${work}/cmacs-cmds" \
        | sed 's/^/  MISSING  /'
    failures=$((failures + \
        $(comm -23 "${work}/gtk-cmds" "${work}/cmacs-cmds" | wc -l)))
else
    echo "  every slash command the GTK client answers is answered here"
fi

# ── Layer 3: hardcoded vocabulary ────────────────────────────────────
#
# The cause rather than the symptom: a client naming a value the library
# enumerates has a copy of the list, and a copy is what drifts.  The
# values are read out of the library's own table, so a palette added
# there is checked from the moment it exists.

banner "hardcoded vocabulary"

if [[ -f "${VOCABULARY_FILE}" ]]
then
    hardcoded=0

    while read -r value
    do
        [[ -z "${value}" ]] && continue

        if grep -qE "\"${value}\"" "${LISP_DIR}"/cmacs-clawtilla*.el 2>/dev/null
        then
            printf '  HARDCODED  "%s" is enumerated by libclawt\n' "${value}"
            hardcoded=$((hardcoded + 1))
        fi
    done < <(sed -n 's/.*{ *CLAWT_THEME_[A-Z_]*, *"\([a-z-]*\)".*/\1/p' \
                 "${VOCABULARY_FILE}" | sort -u)

    if [[ ${hardcoded} -eq 0 ]]
    then
        echo "  no enumerated value is spelled out in the elisp"
    else
        failures=$((failures + hardcoded))
    fi
else
    echo "  ${VOCABULARY_FILE} not found; skipped"
fi

# ── Layer 4: declared affordances ────────────────────────────────────

banner "declared affordances"
missing_affordance=0

for affordance in "${!AFFORDANCES[@]}"
do
    pair="${AFFORDANCES[${affordance}]}"
    gtk_marker="${pair%%|*}"
    cmacs_marker="${pair##*|}"

    gtk_has=no
    cmacs_has=no

    grep -qrF "${gtk_marker}" "${GTK_DIR}" 2>/dev/null && gtk_has=yes
    grep -qhF "${cmacs_marker}" "${LISP_DIR}"/cmacs-clawtilla*.el 2>/dev/null \
        && cmacs_has=yes

    if [[ "${gtk_has}" == yes && "${cmacs_has}" == no ]]
    then
        printf '  MISSING  %-28s (gtk: %s, cmacs: %s)\n' \
            "${affordance}" "${gtk_marker}" "${cmacs_marker}"
        missing_affordance=$((missing_affordance + 1))
    fi
done

if [[ ${missing_affordance} -eq 0 ]]
then
    printf '  all %s declared affordances present in both\n' \
        "${#AFFORDANCES[@]}"
else
    failures=$((failures + missing_affordance))
fi

# ── Verdict ──────────────────────────────────────────────────────────

banner "verdict"

if [[ ${failures} -eq 0 ]]
then
    echo "clawtilla client parity: OK"
    exit 0
fi

printf 'clawtilla client parity: %s difference(s)\n' "${failures}"
echo
echo "A capability in the GTK client and not in this one is a feature"
echo "somebody will reach for and not find.  Either build it, or add it"
echo "to MAY_LACK in this script with a reason somebody would agree with."
exit 1
