/* cmacs-roamgraph-layout.h --- force-directed graph layout.
 *
 * Copyright (C) 2026 Zach Podbielniak
 * SPDX-License-Identifier: AGPL-3.0-or-later
 *
 * Fruchterman-Reingold with Barnes-Hut repulsion, over a
 * CmacsRoamGraph.  Pure C: no "lisp.h", no <libregnum.h>, so the whole
 * solver is unit-testable with neither a Lisp VM nor a GL context.
 *
 * One code path serves both views; DIMS selects it.  DIMS == 2 lays
 * the graph out in the XY plane and snaps z to 0 (the 2D camera is a
 * front-facing orthographic one at +Z, so X is right and Y is up --
 * the conventional 2D reading).  DIMS == 3 uses all three axes.
 *
 * The solver is STEPPED, not one-shot: `begin' seeds and arms it,
 * `step' advances a few iterations and reports convergence.  The Lisp
 * side drives it from a timer so the graph visibly unfolds and then
 * stops -- a synchronous multi-second freeze on M-x is exactly the
 * experience this subsystem exists to replace, and a permanently hot
 * render clock is pure waste once the layout has settled.
 *
 * Barnes-Hut is not an optimisation to defer: brute force at ~1200
 * nodes is ~1.4M pair evaluations per iteration, which is tolerable
 * once but hopeless at 30 FPS.  Setting THETA to 0 degenerates the
 * approximation to an exact all-pairs sum, which the tests use as a
 * free reference implementation. */

#ifndef CMACS_ROAMGRAPH_LAYOUT_H
#define CMACS_ROAMGRAPH_LAYOUT_H

#include <config.h>

#ifdef HAVE_CMACS_ROAMGRAPH

#include <glib.h>
#include "cmacs-roamgraph-graph.h"

G_BEGIN_DECLS

typedef struct CmacsRoamLayout CmacsRoamLayout;

extern CmacsRoamLayout *cmacs_roam_layout_new  (void);
extern void             cmacs_roam_layout_free (CmacsRoamLayout *l);

/* Seed unplaced nodes and arm the cooling schedule.  Survivors from a
 * previous generation keep their positions; new nodes are placed at the
 * centroid of their already-placed neighbours, and whole new components
 * get their own slot on a Fibonacci sphere (3D) / phyllotaxis disc (2D)
 * so disconnected orphans do not collapse into a blob at the origin.
 *
 * ITERS is the nominal schedule length; <= 0 picks a sensible default
 * scaled to the node count. */
extern void cmacs_roam_layout_begin (CmacsRoamLayout *l,
                                     CmacsRoamGraph *g,
                                     int dims, int iters);

/* Advance N_ITERS iterations (<= 0 means 1).  Returns TRUE once the
 * layout has converged or the schedule is exhausted; further calls are
 * cheap no-ops until the next begin/reheat. */
extern gboolean cmacs_roam_layout_step (CmacsRoamLayout *l,
                                        CmacsRoamGraph *g,
                                        int n_iters);

extern gboolean cmacs_roam_layout_converged (CmacsRoamLayout *l);

/* Re-arm a settled layout at FRAC of the initial temperature for
 * EXTRA_ITERS more iterations -- used after a node drag so the
 * neighbourhood relaxes around the new pin. */
extern void cmacs_roam_layout_reheat (CmacsRoamLayout *l,
                                      double frac, int extra_iters);

extern int    cmacs_roam_layout_dims     (CmacsRoamLayout *l);
extern double cmacs_roam_layout_progress (CmacsRoamLayout *l);

/* Barnes-Hut opening angle.  Default 0.9; 0 forces exact all-pairs. */
extern void   cmacs_roam_layout_set_theta (CmacsRoamLayout *l, double theta);
extern double cmacs_roam_layout_get_theta (CmacsRoamLayout *l);

/* Axis-aligned bounds of the placed nodes.  MIN and MAX are float[3].
 * Returns FALSE (and leaves them untouched) for an empty graph. */
extern gboolean cmacs_roam_layout_bounds (CmacsRoamGraph *g,
                                          float *min, float *max);

G_END_DECLS

#endif /* HAVE_CMACS_ROAMGRAPH */
#endif /* CMACS_ROAMGRAPH_LAYOUT_H */
