/* cmacs-secondbrain.h --- the ARMS second-brain visualiser.
 *
 * Copyright (C) 2026 Zach Podbielniak
 * SPDX-License-Identifier: AGPL-3.0-or-later
 *
 * secondbrain renders an agentic workspace as a live libregnum scene:
 * four concentric rings around a centre, one per layer of the ARMS
 * framework.
 *
 *   Applications  what the agent is wired into -- MCP servers, CLIs,
 *                 connected accounts.  The outer ring.
 *   Routines      what runs unattended -- scheduled tasks, pods.
 *   Memory        what has accumulated -- the PARA notes tree, agent
 *                 memory.  Usually the largest layer by far.
 *   Skills        what the agent can do.  The inner ring.
 *
 * The question it answers is operational, not decorative.  An
 * application you no longer use is standing trust you have not revoked;
 * a routine you have forgotten is unattended automation; a skill you
 * cannot see is one you will rewrite.  roamgraph answers "how are my
 * notes linked?"; this answers "what does my system consist of?".
 *
 * It is a sibling of roamgraph, not a mode of it: either can be built
 * and used without the other.  What they share is cmacs/graphcore --
 * the node/edge store, the solver, the closed-form layouts, tweening
 * and collapse -- so an engine improvement lands in both.
 *
 * Architecture.  Three translation-unit classes, the roamgraph split:
 *
 *   - cmacs-secondbrain-scene.c includes <libregnum.h> and therefore
 *     may NOT include lisp.h (raylib's `Color' clashes with
 *     pgtkgui.h's).
 *   - cmacs-secondbrain-defuns.c includes lisp.h and talks to the
 *     render half only through cmacs-secondbrain-scene.h.
 *   - cmacs-secondbrain-model.c includes NEITHER, only glib.  The ARMS
 *     ring vocabulary lives there so both halves agree on it and it
 *     can be tested headless.
 *
 * Division of labour.  C owns geometry, the rings, the pick ray and the
 * node table.  Elisp owns where the data comes from (the source
 * registry), what a click means, and every pane.  C knows nothing about
 * MCP servers, cron or org files.  The contract is one DEFUN,
 * `cmacs-secondbrain-set-graph'.
 *
 * Identity.  As in roamgraph: libregnum node ids are insertion indices
 * and churn on every rebuild, so a caller-chosen id string is the key
 * for everything and is what goes into the node table's `path'. */

#ifndef CMACS_SECONDBRAIN_H
#define CMACS_SECONDBRAIN_H

#include <config.h>

#ifdef HAVE_CMACS_SECONDBRAIN

#include "lisp.h"

/* syms_of_cmacs_secondbrain / init_cmacs_secondbrain are declared in
 * src/lisp.h alongside the other cmacs subsystem entry points.  Each
 * translation unit that registers DEFUNs exposes its own syms_of_ hook,
 * aggregated in cmacs-secondbrain-init.c. */
extern void syms_of_cmacs_secondbrain_defuns (void);

#endif /* HAVE_CMACS_SECONDBRAIN */
#endif /* CMACS_SECONDBRAIN_H */
