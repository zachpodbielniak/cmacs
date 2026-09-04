/* cmacs-secondbrain-scene.h --- plain-C render API for the second brain.
 *
 * Copyright (C) 2026 Zach Podbielniak
 * SPDX-License-Identifier: AGPL-3.0-or-later
 *
 * Implemented by cmacs-secondbrain-scene.c, the ONLY secondbrain
 * translation unit that includes <libregnum.h>/raylib.  Everything
 * libregnum-shaped is exposed here as plain C so the lisp.h-side code
 * (cmacs-secondbrain-defuns.c) can drive it without pulling in the
 * raylib `Color' typedef that clashes with pgtkgui.h's.
 *
 * Mirrors cmacs-roamgraph-scene.h. */

#ifndef CMACS_SECONDBRAIN_SCENE_H
#define CMACS_SECONDBRAIN_SCENE_H

#include <config.h>

#ifdef HAVE_CMACS_SECONDBRAIN

#include <glib.h>
#include "cmacs-libregnum-render.h"   /* opaque CmacsLibregnumRenderCtx */
#include "cmacs-graphcore-graph.h"

G_BEGIN_DECLS

/* Rebuild every drawable and node-table entry on R from G.
 *
 * Unlike roamgraph, which deliberately keeps one visual vocabulary,
 * each node here is drawn per its ARMS role -- a hex prism for an
 * application, an orbited sphere for a routine, a sphere for a memory
 * node, a faceted gem for a skill.  The shape is the primary signal:
 * the map should be readable before any label resolves.
 *
 * Only VISIBLE nodes are emitted, so a collapsed department costs one
 * hub rather than its whole subtree.  Node and edge drawables have
 * SEPARATE budgets: a shared one spent edges-first can exhaust itself
 * before a single node is drawn.
 *
 * The node-table `path' is the caller's id string, not the index --
 * scene ids are insertion order and churn on every rebuild.
 *
 * Returns the number of nodes emitted. */
extern guint cmacs_secondbrain_scene_build (CmacsLibregnumRenderCtx *r,
                                            CmacsGraph *g,
                                            int dims,
                                            double ring_gap,
                                            gboolean band_guides);

/* Attach an SVG icon to the node at (X, Y, Z), sized SIZE in world
 * units.  Rasterised through libregnum's LrgVectorImage at PX pixels
 * square and uploaded as a texture, so it stays crisp at any zoom
 * rather than being a scaled bitmap.
 *
 * Returns FALSE when the file cannot be read or rendered -- an icon
 * that will not load must leave the node with its glyph rather than
 * taking the build down.
 *
 * Icons live in the render context's billboard list, which is cleared
 * with the drawables, so this must be called AFTER scene_build. */
extern gboolean cmacs_secondbrain_scene_add_icon
                        (CmacsLibregnumRenderCtx *r,
                         const char *svg_path,
                         float x, float y, float z,
                         float size, int px);

/* Push the graph's current positions into the retained drawables and
 * the node table's pick boxes, without rebuilding.  This is what an
 * animated tween calls each frame; skipping it leaves picking pointing
 * at where the nodes used to be. */
extern void cmacs_secondbrain_scene_sync_positions
                        (CmacsLibregnumRenderCtx *r, CmacsGraph *g);

/* Drop the retained drawable references (called before the render
 * context clears its drawable list out from under us). */
extern void cmacs_secondbrain_scene_reset (CmacsLibregnumRenderCtx *r);

/* Recolour the retained shapes from the render context's per-node flags
 * (search matches take an accent colour, dimmed nodes fade, edges follow
 * their endpoints).  In place -- recolouring on every search keystroke
 * must not mean rebuilding the scene. */
extern void cmacs_secondbrain_scene_apply_flags
                        (CmacsLibregnumRenderCtx *r, CmacsGraph *g);

/* Scene index for graph node I, or -1 when it was not emitted (a
 * collapsed subtree, or past the drawable budget).  Emission order is
 * NOT graph order, so anything addressing the scene by index -- the
 * camera, the selection marker -- has to come through here. */
extern gint cmacs_secondbrain_scene_emit_index
                        (CmacsLibregnumRenderCtx *r, guint i);

/* Ease the camera to frame graph node I, keeping CONTEXT_FRAC of the
 * whole scene's extent between camera and node so the node's
 * surroundings stay visible. */
extern gboolean cmacs_secondbrain_scene_focus_node
                        (CmacsLibregnumRenderCtx *r, guint i);

/* Camera.  FLAT gives a head-on view of the XY plane with orbit locked;
 * otherwise a free perspective view.  Both are PERSPECTIVE cameras --
 * orthographic is unusable here because graylib asserts `fovy < 180'
 * while raylib overloads fovy as the view volume's world height in
 * orthographic, so a graph wider than 180 units can never be framed. */
extern void     cmacs_secondbrain_scene_set_projection
                        (CmacsLibregnumRenderCtx *r, gboolean flat);
extern gboolean cmacs_secondbrain_scene_flat_p (CmacsLibregnumRenderCtx *r);

/* Frame the whole graph, respecting the current projection. */
extern void cmacs_secondbrain_scene_fit (CmacsLibregnumRenderCtx *r,
                                         CmacsGraph *g);

G_END_DECLS

#endif /* HAVE_CMACS_SECONDBRAIN */
#endif /* CMACS_SECONDBRAIN_SCENE_H */
