/* cmacs-roamgraph-scene.h --- plain-C render API for the roam graph.
 *
 * Copyright (C) 2026 Zach Podbielniak
 * SPDX-License-Identifier: AGPL-3.0-or-later
 *
 * Implemented by cmacs-roamgraph-scene.c, the ONLY roamgraph
 * translation unit that includes <libregnum.h>/raylib.  Everything
 * libregnum-shaped is exposed here as plain C so the lisp.h-side code
 * (cmacs-roamgraph-defuns.c) can drive it without pulling in the
 * raylib `Color' typedef that clashes with pgtkgui.h's.
 *
 * Mirrors cmacs-gnuseye-globe.h and cmacs-libregnum-scenes.h. */

#ifndef CMACS_ROAMGRAPH_SCENE_H
#define CMACS_ROAMGRAPH_SCENE_H

#include <config.h>

#ifdef HAVE_CMACS_ROAMGRAPH

#include <glib.h>
#include "cmacs-libregnum-render.h"   /* opaque CmacsLibregnumRenderCtx */
#include "cmacs-graphcore-graph.h"

G_BEGIN_DECLS

/* Rebuild every drawable and node-table entry on R from G.
 *
 * Each graph node becomes one sphere plus one node-table entry whose
 * `path' is the org-roam id -- the id, not the index, because scene
 * node ids are insertion order and churn on every rebuild, so the
 * string is what the pick dispatch can rely on.  Each edge becomes one
 * line.  Drawable references are retained internally so a later
 * position or colour change is an in-place mutation rather than
 * another full rebuild.
 *
 * Returns the number of nodes emitted. */
extern guint cmacs_roamgraph_scene_build (CmacsLibregnumRenderCtx *r,
                                          CmacsGraph *g,
                                          int dims);

/* Push the graph's current positions into the retained drawables and
 * the node table's pick boxes, without rebuilding anything.  This is
 * what the animated layout calls each step; skipping it would leave
 * picking pointing at where the nodes used to be. */
extern void cmacs_roamgraph_scene_sync_positions (CmacsLibregnumRenderCtx *r,
                                                  CmacsGraph *g);

/* Drop the retained drawable references (called before the render
 * context clears its drawable list out from under us). */
extern void cmacs_roamgraph_scene_reset (CmacsLibregnumRenderCtx *r);

/* Recolour the retained shapes from the render context's per-node flags
 * (search matches take an accent colour, dimmed nodes fade, and edges
 * follow their endpoints).  In place -- recolouring on every search
 * keystroke must not mean rebuilding the scene. */
extern void cmacs_roamgraph_scene_apply_flags (CmacsLibregnumRenderCtx *r,
                                               CmacsGraph *g);

/* Camera.  FLAT selects a front-facing orthographic view of the XY
 * plane (X right, Y up -- the conventional 2D reading, matching the
 * solver's DIMS == 2 layout); otherwise a perspective view.  Deliberately
 * NOT the libregnum editor's top-down `editor_set_view_2d', which is
 * editor-scoped and hard-codes its own camera placement. */
extern void     cmacs_roamgraph_scene_set_projection
                        (CmacsLibregnumRenderCtx *r, gboolean flat);
extern gboolean cmacs_roamgraph_scene_flat_p (CmacsLibregnumRenderCtx *r);

/* Frame the whole graph: place the camera so every node is visible,
 * respecting the current projection. */
extern void cmacs_roamgraph_scene_fit (CmacsLibregnumRenderCtx *r,
                                       CmacsGraph *g);

G_END_DECLS

#endif /* HAVE_CMACS_ROAMGRAPH */
#endif /* CMACS_ROAMGRAPH_SCENE_H */
