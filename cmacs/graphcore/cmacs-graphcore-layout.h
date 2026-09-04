/* cmacs-graphcore-layout.h --- force-directed graph layout.
 *
 * Copyright (C) 2026 Zach Podbielniak
 * SPDX-License-Identifier: AGPL-3.0-or-later
 *
 * Fruchterman-Reingold with Barnes-Hut repulsion, over a
 * CmacsGraph.  Pure C: no "lisp.h", no <libregnum.h>, so the whole
 * solver is unit-testable with neither a Lisp VM nor a GL context.
 *
 * One code path serves both views; DIMS selects it.  DIMS == 2 lays
 * the graph out in the XY plane and snaps z to 0 (the flat camera is a
 * head-on PERSPECTIVE one at +Z with orbit locked -- not orthographic;
 * see cmacs-roamgraph-scene.c for why -- so X is right and Y is up,
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

#ifndef CMACS_GRAPHCORE_LAYOUT_H
#define CMACS_GRAPHCORE_LAYOUT_H

#include <config.h>

#ifdef HAVE_CMACS_GRAPHCORE

#include <glib.h>
#include "cmacs-graphcore-graph.h"

G_BEGIN_DECLS

typedef struct CmacsGraphLayout CmacsGraphLayout;

/* Placement strategies.
 *
 * FORCE is the simulated one -- it converges over many steps and is
 * what `begin'/`step' drive.  The other three are closed-form: they
 * compute a final position for every node in a single pass, with no
 * iteration and no convergence.  That difference is why they go
 * through `place' rather than through the solver: there is nothing to
 * step, and running a solver over them would only undo them. */
typedef enum
{
  CMACS_GRAPH_LAYOUT_FORCE  = 0,  /* Fruchterman-Reingold + Barnes-Hut */
  CMACS_GRAPH_LAYOUT_CIRCLE = 1,  /* one concentric circle per group */
  CMACS_GRAPH_LAYOUT_HEX    = 2,  /* axial hex lattice, spiralling out */
  CMACS_GRAPH_LAYOUT_RINGS  = 3   /* concentric bands from node->ring */
} CmacsGraphLayoutKind;

extern CmacsGraphLayout *cmacs_graph_layout_new  (void);
extern void             cmacs_graph_layout_free (CmacsGraphLayout *l);

/* Seed unplaced nodes and arm the cooling schedule.  Survivors from a
 * previous generation keep their positions; new nodes are placed at the
 * centroid of their already-placed neighbours, and whole new components
 * get their own slot on a Fibonacci sphere (3D) / phyllotaxis disc (2D)
 * so disconnected orphans do not collapse into a blob at the origin.
 *
 * ITERS is the nominal schedule length; <= 0 picks a sensible default
 * scaled to the node count. */
extern void cmacs_graph_layout_begin (CmacsGraphLayout *l,
                                     CmacsGraph *g,
                                     int dims, int iters);

/* Advance N_ITERS iterations (<= 0 means 1).  Returns TRUE once the
 * layout has converged or the schedule is exhausted; further calls are
 * cheap no-ops until the next begin/reheat. */
extern gboolean cmacs_graph_layout_step (CmacsGraphLayout *l,
                                        CmacsGraph *g,
                                        int n_iters);

extern gboolean cmacs_graph_layout_converged (CmacsGraphLayout *l);

/* Re-arm a settled layout at FRAC of the initial temperature for
 * EXTRA_ITERS more iterations -- used after a node drag so the
 * neighbourhood relaxes around the new pin. */
extern void cmacs_graph_layout_reheat (CmacsGraphLayout *l,
                                      double frac, int extra_iters);

extern int    cmacs_graph_layout_dims     (CmacsGraphLayout *l);
extern double cmacs_graph_layout_progress (CmacsGraphLayout *l);

/* Barnes-Hut opening angle.  Default 0.9; 0 forces exact all-pairs. */
extern void   cmacs_graph_layout_set_theta (CmacsGraphLayout *l, double theta);
extern double cmacs_graph_layout_get_theta (CmacsGraphLayout *l);

/* Axis-aligned bounds of the placed nodes.  MIN and MAX are float[3].
 * Returns FALSE (and leaves them untouched) for an empty graph. */
extern gboolean cmacs_graph_layout_bounds (CmacsGraph *g,
                                          float *min, float *max);

/* ---- Closed-form placement ---------------------------------------
 *
 * `place' writes each visible node's destination into its tx/ty/tz and
 * moves nothing.  Separating "decide where things go" from "move them
 * there" is what lets the same code path serve an instant switch and an
 * animated one -- and it keeps the layouts themselves testable without
 * running an animation. */
extern void cmacs_graph_layout_place (CmacsGraphLayout *l,
                                      CmacsGraph *g,
                                      CmacsGraphLayoutKind kind,
                                      int dims);

/* Apply the targets immediately (tx -> x).  The un-animated path. */
extern void cmacs_graph_layout_snap (CmacsGraph *g);

/* Angular offset applied per band by the RINGS layout, in radians.
 * A parameter rather than a constant because spinning the rings is a
 * user-facing control, and re-placing is how it animates. */
extern void   cmacs_graph_layout_set_spin (CmacsGraphLayout *l, double radians);
extern double cmacs_graph_layout_get_spin (CmacsGraphLayout *l);

/* Radial distance between adjacent bands / circles.  Default 6.0. */
extern void   cmacs_graph_layout_set_ring_gap (CmacsGraphLayout *l, double gap);
extern double cmacs_graph_layout_get_ring_gap (CmacsGraphLayout *l);

/* Maximum out-of-plane angle of the RINGS layout's galaxy warp, in
 * radians; 0 (the default) keeps the rings coplanar.
 *
 * Concentric rings viewed in 3D are coplanar, so orbiting them only
 * proves they are flat.  The warp bends the disc -- z grows with radius
 * and varies as sin of the azimuth -- so one side lifts and the other
 * drops, which is what makes a 3D view of a ring layout worth having.
 * TILT is the warp's crest: there atan(z/r) == TILT exactly.  The small
 * per-node thickness term rides on top, so one node may sit slightly
 * beyond it -- TILT describes the disc, not a ceiling per node.
 *
 * Only the RINGS layout warps, and only in 3D: `place_set' zeroes z in a
 * 2D layout, so the same setting is correct in both views. */
extern void   cmacs_graph_layout_set_galaxy_tilt (CmacsGraphLayout *l,
                                                  double radians);
extern double cmacs_graph_layout_get_galaxy_tilt (CmacsGraphLayout *l);

extern CmacsGraphLayoutKind cmacs_graph_layout_get_kind (CmacsGraphLayout *l);

/* ---- Tweening -----------------------------------------------------
 *
 * Snapshots every node's current position as the tween's start and
 * eases toward tx/ty/tz over FRAMES steps.  Used for layout switches,
 * expand/collapse and ring spin, so that none of them teleport.
 *
 * FRAMES <= 0 snaps.  A second tween_begin mid-flight re-snapshots
 * from wherever the nodes currently are, so an interrupted transition
 * continues smoothly rather than jumping back to its origin. */
extern void     cmacs_graph_layout_tween_begin (CmacsGraphLayout *l,
                                                CmacsGraph *g, int frames);
/* Advance one frame.  Returns TRUE when the tween has finished (and
 * every node is exactly on its target, not merely near it). */
extern gboolean cmacs_graph_layout_tween_step  (CmacsGraphLayout *l,
                                                CmacsGraph *g);
extern gboolean cmacs_graph_layout_tweening    (CmacsGraphLayout *l);
/* 0.0 at the start, 1.0 when finished. */
extern double   cmacs_graph_layout_tween_progress (CmacsGraphLayout *l);

G_END_DECLS

#endif /* HAVE_CMACS_GRAPHCORE */
#endif /* CMACS_GRAPHCORE_LAYOUT_H */
