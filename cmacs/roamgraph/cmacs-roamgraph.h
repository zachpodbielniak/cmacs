/* cmacs-roamgraph.h --- native org-roam knowledge-graph visualiser.
 *
 * Copyright (C) 2026 Zach Podbielniak
 * SPDX-License-Identifier: AGPL-3.0-or-later
 *
 * roamgraph renders an org-roam link graph as a live libregnum scene
 * inside a cmacs buffer -- the in-editor replacement for org-roam-ui's
 * local web server plus browser.  A roamgraph buffer owns a
 * CmacsLibregnumView whose render context holds one sphere per note and
 * one line per [[id:]] link, positioned by a force-directed solver.
 *
 * Architecture.  Three translation-unit classes, not two:
 *
 *   - cmacs-roamgraph-scene.c includes <libregnum.h> and therefore may
 *     NOT include lisp.h (raylib's `Color' clashes with pgtkgui.h's).
 *   - cmacs-roamgraph-defuns.c / -scan.c include lisp.h and talk to the
 *     render half only through cmacs-roamgraph-scene.h.
 *   - cmacs-roamgraph-graph.c / -layout.c include NEITHER, only glib.
 *     That is what makes the graph model and the force solver testable
 *     with no Lisp VM and no GL context.  (Same split as gnuseye, whose
 *     geodesy lives in cmacs-gnuseye-geomath.h.)
 *
 * Division of labour.  C owns geometry, the solver, the pick ray and
 * the node table.  Elisp owns where the data comes from (org-roam.db
 * via Emacs's builtin SQLite, or the native scanner here), what a click
 * means, and every UI pane.  C never touches org-roam.  The whole
 * contract is one DEFUN, `cmacs-roamgraph-set-graph', taking a vector
 * of node plists and a vector of edge plists.
 *
 * Identity.  libregnum node ids are insertion indices and churn on
 * every rebuild, so the org-roam id string is the key for everything:
 * it goes into the node table's `path' field, which is what arrives
 * synchronously in the click dispatch. */

#ifndef CMACS_ROAMGRAPH_H
#define CMACS_ROAMGRAPH_H

#include <config.h>

#ifdef HAVE_CMACS_ROAMGRAPH

#include "lisp.h"

/* syms_of_cmacs_roamgraph / init_cmacs_roamgraph are declared in
 * src/lisp.h alongside the other cmacs subsystem entry points.  Each
 * roamgraph translation unit that registers DEFUNs exposes its own
 * syms_of_ hook, aggregated in cmacs-roamgraph-init.c. */
extern void syms_of_cmacs_roamgraph_defuns (void);
extern void syms_of_cmacs_roamgraph_scan   (void);

#endif /* HAVE_CMACS_ROAMGRAPH */
#endif /* CMACS_ROAMGRAPH_H */
