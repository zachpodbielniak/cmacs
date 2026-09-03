/* cmacs-roamgraph-scene.c --- libregnum render half of the roam graph.
 *
 * Copyright (C) 2026 Zach Podbielniak
 * SPDX-License-Identifier: AGPL-3.0-or-later
 *
 * Turns a CmacsGraph into libregnum drawables plus node-table
 * entries on a CmacsLibregnumRenderCtx.
 *
 * Translation-unit firewall: this file includes <libregnum.h> (and
 * therefore raylib.h), whose `Color' struct clashes with cmacs's
 * pgtkgui.h `Color' typedef, so it CANNOT include lisp.h/frame.h/
 * buffer.h.  It talks to cmacs only through the plain-C
 * cmacs-libregnum-render.h API, exactly like the scene-*.c builders
 * and cmacs-gnuseye-globe.c. */

#include <config.h>

#ifdef HAVE_CMACS_ROAMGRAPH

#include "cmacs-roamgraph-scene.h"
#include "cmacs-graphcore-layout.h"

#include <libregnum.h>
#include <glib.h>
#include <math.h>
#include <string.h>

/* Hard caps on emitted drawables.  A node costs one sphere, an edge
 * one line.
 *
 * Separate budgets, deliberately not one shared cap.
 *
 * These used to be a single 12000-drawable budget consumed edges-first.
 * On a dense graph the edges exhausted it before a single sphere was
 * emitted, so the view came up with every link drawn and NO nodes --
 * silently, because nothing overflowed or errored.  Nodes are the
 * content; edges are the garnish.  Giving each its own ceiling is what
 * fixes it -- edges are still emitted first, because that is what makes
 * them render BEHIND the nodes they join, and with separate budgets
 * they can no longer starve the nodes by doing so. */
#define ROAM_MAX_NODE_DRAWABLES 12000
#define ROAM_MAX_EDGE_DRAWABLES 24000

/* Edge alpha at rest.  Low: at a few thousand edges the lines are
 * texture, not information, and a solid web hides the nodes. */
#define ROAM_EDGE_ALPHA 56

/* Vertical field of view, in degrees, for both views.  Narrow enough
 * that the flat view reads as flat without being orthographic (see
 * cmacs_roamgraph_scene_set_projection for why it is not). */
#define ROAM_FOV 40.0

/* ── Retained drawable references ──────────────────────────────────
 * Kept so a position or colour change is an in-place mutation instead
 * of another full rebuild.  Rebuilding ~2700 GObjects per animation
 * step (or per search keystroke) is not viable.
 *
 * The pointers are BORROWED: cmacs_libregnum_render_ctx_add_drawable
 * takes ownership, and clear_drawables frees them.  So these arrays
 * must be reset in lock-step with every clear -- which is why
 * scene_build clears both before repopulating and why _reset exists.
 *
 * Keyed by render context so several graph buffers can coexist. */

typedef struct
{
  GPtrArray *node_shapes;   /* LrgSphere3D*, borrowed, emission order */
  GPtrArray *edge_shapes;   /* LrgLine3D*,   borrowed, emission order */

  /* Graph index -> emission index, or -1 when the node/edge was not
     emitted (invisible, or past its drawable budget).

     Not a convenience: the shape arrays and the render context's node
     table are in EMISSION order, while the graph is in GRAPH order,
     and the two diverge the moment anything is skipped.  Reading node
     flags with a graph index -- which apply_flags used to do for the
     match scan and for both edge endpoints -- then recolours the wrong
     spheres.  It was invisible only because nothing ever cleared
     `visible'; collapse does. */
  GArray    *node_emit;     /* gint32, one per graph node */
  GArray    *edge_emit;     /* gint32, one per graph edge */
  gboolean   flat;
} SceneState;

static GHashTable *s_states;    /* CmacsLibregnumRenderCtx* -> SceneState* */

static void
scene_state_free (gpointer p)
{
  SceneState *st = p;

  if (!st) return;
  if (st->node_shapes) g_ptr_array_free (st->node_shapes, TRUE);
  if (st->edge_shapes) g_ptr_array_free (st->edge_shapes, TRUE);
  if (st->node_emit)   g_array_free (st->node_emit, TRUE);
  if (st->edge_emit)   g_array_free (st->edge_emit, TRUE);
  g_free (st);
}

static SceneState *
scene_state (CmacsLibregnumRenderCtx *r, gboolean create)
{
  SceneState *st;

  if (!r) return NULL;
  if (!s_states)
    {
      if (!create) return NULL;
      s_states = g_hash_table_new_full (NULL, NULL, NULL, scene_state_free);
    }
  st = g_hash_table_lookup (s_states, r);
  if (!st && create)
    {
      st = g_new0 (SceneState, 1);
      /* No element free func: the entries are borrowed. */
      st->node_shapes = g_ptr_array_new ();
      st->edge_shapes = g_ptr_array_new ();
      st->node_emit   = g_array_new (FALSE, FALSE, sizeof (gint32));
      st->edge_emit   = g_array_new (FALSE, FALSE, sizeof (gint32));
      g_hash_table_insert (s_states, r, st);
    }
  return st;
}

void
cmacs_roamgraph_scene_reset (CmacsLibregnumRenderCtx *r)
{
  SceneState *st = scene_state (r, FALSE);

  if (!st) return;
  g_ptr_array_set_size (st->node_shapes, 0);
  g_ptr_array_set_size (st->edge_shapes, 0);
}

/* ── Colours ──────────────────────────────────────────────────────── */

static void
unpack_rgba (guint32 rgba, guint8 *cr, guint8 *cg, guint8 *cb, guint8 *ca)
{
  *cr = (guint8) ((rgba >> 24) & 0xFF);
  *cg = (guint8) ((rgba >> 16) & 0xFF);
  *cb = (guint8) ((rgba >>  8) & 0xFF);
  *ca = (guint8) (rgba & 0xFF);
  if (*ca == 0) *ca = 255;      /* an unset alpha means opaque, not invisible */
}

/* Average two channel values and pull the result toward grey, so an
 * edge hints at its endpoints without competing with the nodes. */
static guint8
edge_tint (guint8 x, guint8 y)
{
  int avg = ((int) x + (int) y) / 2;
  return (guint8) ((avg + 150 * 2) / 3);
}

/* An edge's resting colour at ALPHA.  Single source of truth: the build
 * pass and the flag pass must agree, or recolouring silently discards
 * the endpoint tint and every edge turns flat grey. */
static GrlColor *
edge_base_color (CmacsGraphEdge *e, CmacsGraphNode *a, CmacsGraphNode *b,
                 guint8 alpha)
{
  guint8 ar, ag, ab, aa, br, bg, bb, ba;

  if (e->kind == CMACS_GRAPH_EDGE_SIM)
    return grl_color_new (150, 110, 210, alpha);

  unpack_rgba (a->rgba ? a->rgba : 0x7FA8D8FFu, &ar, &ag, &ab, &aa);
  unpack_rgba (b->rgba ? b->rgba : 0x7FA8D8FFu, &br, &bg, &bb, &ba);
  return grl_color_new (edge_tint (ar, br), edge_tint (ag, bg),
                        edge_tint (ab, bb), alpha);
}

/* ── Build ────────────────────────────────────────────────────────── */

guint
cmacs_roamgraph_scene_build (CmacsLibregnumRenderCtx *r, CmacsGraph *g,
                             int dims)
{
  SceneState *st;
  guint n, m, i, emitted = 0;
  guint n_nodes_drawn = 0, n_edges_drawn = 0;

  if (!r || !g) return 0;

  st = scene_state (r, TRUE);
  st->flat = (dims == 2);

  /* clear_drawables also clears the node table, so both of our
     borrowed-pointer arrays must be dropped at the same moment. */
  cmacs_libregnum_render_ctx_clear_drawables (r);
  g_ptr_array_set_size (st->node_shapes, 0);
  g_ptr_array_set_size (st->edge_shapes, 0);

  n = cmacs_graph_n_nodes (g);
  m = cmacs_graph_n_edges (g);

  /* -1 everywhere, then filled in as each node/edge is emitted. */
  g_array_set_size (st->node_emit, n);
  g_array_set_size (st->edge_emit, m);
  {
    guint z;
    for (z = 0; z < n; z++) g_array_index (st->node_emit, gint32, z) = -1;
    for (z = 0; z < m; z++) g_array_index (st->edge_emit, gint32, z) = -1;
  }

  /* Edges first, so they render behind the nodes they connect. */
  for (i = 0; i < m; i++)
    {
      CmacsGraphEdge *e = cmacs_graph_edge (g, i);
      CmacsGraphNode *a = cmacs_graph_node (g, e->a);
      CmacsGraphNode *b = cmacs_graph_node (g, e->b);
      LrgLine3D *line;
      g_autoptr (GrlColor) col = NULL;

      if (!a || !b) continue;
      if (!a->visible || !b->visible) continue;
      if (n_edges_drawn >= ROAM_MAX_EDGE_DRAWABLES) break;

      line = lrg_line3d_new_from_to (a->x, a->y, a->z, b->x, b->y, b->z);
      /* Tinted with the average of the two notes it joins, muted toward
         grey: links inside one PARA bucket then read as that bucket's
         colour and cross-bucket links read as neutral, which makes the
         structure legible without drawing anything extra.  Similarity
         edges keep their own violet so they are never mistaken for a
         link the user actually wrote. */
      col = edge_base_color (e, a, b, ROAM_EDGE_ALPHA);
      lrg_shape_set_color (LRG_SHAPE (line), col);

      g_array_index (st->edge_emit, gint32, i) = (gint32) n_edges_drawn;
      g_ptr_array_add (st->edge_shapes, line);
      cmacs_libregnum_render_ctx_add_drawable (r, line);
      n_edges_drawn++;
    }

  /* Nodes.  One sphere and one node-table entry each; the node-table
     `path' is the org-roam id, because the numeric scene id is
     insertion order and is stale the moment the scene is rebuilt --
     the pick dispatch resolves by string. */
  for (i = 0; i < n; i++)
    {
      CmacsGraphNode *nd = cmacs_graph_node (g, i);
      LrgSphere3D *s;
      g_autoptr (GrlColor) col = NULL;
      guint8 cr, cg, cb, ca;
      guint id;

      if (!nd || !nd->visible) continue;
      if (n_nodes_drawn >= ROAM_MAX_NODE_DRAWABLES) break;

      s = lrg_sphere3d_new_at (nd->x, nd->y, nd->z, nd->radius);
      unpack_rgba (nd->rgba ? nd->rgba : 0x7FA8D8FFu, &cr, &cg, &cb, &ca);
      col = grl_color_new (cr, cg, cb, ca);
      lrg_shape_set_color (LRG_SHAPE (s), col);
      /* Spend triangles where they show.  A leaf is a few pixels across
         and a default sphere is wasted on it; a hub is large enough
         that the facets are obvious. */
      if (nd->edge_count >= 12)
        { lrg_sphere3d_set_rings (s, 12); lrg_sphere3d_set_slices (s, 18); }
      else if (nd->edge_count >= 4)
        { lrg_sphere3d_set_rings (s, 8);  lrg_sphere3d_set_slices (s, 12); }
      else
        { lrg_sphere3d_set_rings (s, 6);  lrg_sphere3d_set_slices (s, 8); }

      g_array_index (st->node_emit, gint32, i) = (gint32) n_nodes_drawn;
      g_ptr_array_add (st->node_shapes, s);
      cmacs_libregnum_render_ctx_add_drawable (r, s);
      n_nodes_drawn++;

      id = cmacs_libregnum_render_ctx_add_node (r, nd->id, nd->title,
                                                FALSE, nd->level, -1,
                                                nd->x, nd->y, nd->z,
                                                nd->radius, nd->radius,
                                                nd->radius);
      /* Ordinary nodes label on hover; hubs are permanent landmarks so
         the map is readable without pointing at anything. */
      cmacs_libregnum_render_ctx_set_node_label_mode
        (r, (gint) id,
         (nd->edge_count >= 12) ? CMACS_LIBREGNUM_LABEL_ALWAYS
                                : CMACS_LIBREGNUM_LABEL_HOVER);
      emitted++;
    }

  return emitted;
}

void
cmacs_roamgraph_scene_sync_positions (CmacsLibregnumRenderCtx *r,
                                      CmacsGraph *g)
{
  SceneState *st = scene_state (r, FALSE);
  guint n, m, i, node_i = 0;

  if (!st || !g) return;

  n = cmacs_graph_n_nodes (g);
  m = cmacs_graph_n_edges (g);

  for (i = 0; i < m && i < st->edge_shapes->len; i++)
    {
      CmacsGraphEdge *e = cmacs_graph_edge (g, i);
      CmacsGraphNode *a = cmacs_graph_node (g, e->a);
      CmacsGraphNode *b = cmacs_graph_node (g, e->b);
      LrgLine3D *line = g_ptr_array_index (st->edge_shapes, i);

      if (!a || !b || !line) continue;
      lrg_shape3d_set_position_xyz (LRG_SHAPE3D (line), a->x, a->y, a->z);
      lrg_line3d_set_end_xyz (line, b->x, b->y, b->z);
    }

  /* The node-shape array skips invisible nodes, so it is indexed by
     emission order, not by graph index -- walk both in step. */
  for (i = 0; i < n && node_i < st->node_shapes->len; i++)
    {
      CmacsGraphNode *nd = cmacs_graph_node (g, i);
      LrgSphere3D *s;

      if (!nd || !nd->visible) continue;
      s = g_ptr_array_index (st->node_shapes, node_i);
      if (s)
        lrg_shape3d_set_position_xyz (LRG_SHAPE3D (s), nd->x, nd->y, nd->z);
      /* Keep the pick box under the sphere; otherwise clicking lands
         on wherever the node used to be. */
      cmacs_libregnum_render_ctx_move_node (r, (gint) node_i,
                                            nd->x, nd->y, nd->z);
      node_i++;
    }
}

/* ── Highlighting ─────────────────────────────────────────────────
 * Recolour the retained shapes from the render context's per-node
 * flags.  In place: rebuilding a few thousand GObjects on every search
 * keystroke is not viable, which is exactly why the shape references
 * are retained in the first place. */

/* Brighten a channel toward white without washing out its hue. */
static guint8
bump (guint8 c)
{
  int v = (int) c + (255 - (int) c) / 2;
  return (guint8) MIN (255, v);
}

/* Node flags for GRAPH index I, resolved through the emission map.
   0 when the node was not emitted -- it has no scene entry to carry
   flags, and reading some other node's would be worse than nothing. */
static guint
emitted_node_flags (CmacsLibregnumRenderCtx *r, SceneState *st, guint i)
{
  gint32 e;

  if (!st->node_emit || i >= st->node_emit->len) return 0;
  e = g_array_index (st->node_emit, gint32, i);
  if (e < 0) return 0;
  return cmacs_libregnum_render_ctx_get_node_flags (r, e);
}

void
cmacs_roamgraph_scene_apply_flags (CmacsLibregnumRenderCtx *r,
                                   CmacsGraph *g)
{
  SceneState *st = scene_state (r, FALSE);
  guint n, m, i, node_i = 0;
  gboolean any_match = FALSE;

  if (!st || !g) return;

  n = cmacs_graph_n_nodes (g);
  m = cmacs_graph_n_edges (g);

  for (i = 0; i < n; i++)
    if (emitted_node_flags (r, st, i) & CMACS_LIBREGNUM_NODE_MATCH)
      { any_match = TRUE; break; }

  for (i = 0; i < n && node_i < st->node_shapes->len; i++)
    {
      CmacsGraphNode *nd = cmacs_graph_node (g, i);
      LrgSphere3D *s;
      guint flags;
      guint8 cr, cg, cb, ca;

      if (!nd || !nd->visible) continue;
      s = g_ptr_array_index (st->node_shapes, node_i);
      node_i++;
      if (!s) continue;

      flags = emitted_node_flags (r, st, i);
      unpack_rgba (nd->rgba ? nd->rgba : 0x7FA8D8FFu, &cr, &cg, &cb, &ca);

      if (flags & CMACS_LIBREGNUM_NODE_MATCH)
        {
          /* One accent colour for every hit, so the eye groups them. */
          g_autoptr (GrlColor) col = grl_color_new (255, 210, 74, 255);
          lrg_shape_set_color (LRG_SHAPE (s), col);
        }
      else if (flags & CMACS_LIBREGNUM_NODE_DIM)
        {
          g_autoptr (GrlColor) col =
            grl_color_new ((guint8) (cr / 3), (guint8) (cg / 3),
                           (guint8) (cb / 3), 90);
          lrg_shape_set_color (LRG_SHAPE (s), col);
        }
      else if (flags & CMACS_LIBREGNUM_NODE_NEIGHBOUR)
        {
          /* One hop from the selection: brightened rather than
             recoloured, so it still reads as its own PARA bucket. */
          g_autoptr (GrlColor) col =
            grl_color_new (bump (cr), bump (cg), bump (cb), 255);
          lrg_shape_set_color (LRG_SHAPE (s), col);
        }
      else
        {
          g_autoptr (GrlColor) col = grl_color_new (cr, cg, cb, ca);
          lrg_shape_set_color (LRG_SHAPE (s), col);
        }
    }

  /* Edges follow their endpoints: an edge between two dimmed nodes is
     noise, one touching a match is context worth seeing. */
  for (i = 0; i < m; i++)
    {
      CmacsGraphEdge *e = cmacs_graph_edge (g, i);
      LrgLine3D *line;
      CmacsGraphNode *ea, *eb;
      gint32 ei;
      guint fa, fb;
      guint8 alpha = ROAM_EDGE_ALPHA;

      if (!e) continue;
      /* Emission index, not graph index: skipped edges shift everything
         after them. */
      ei = (st->edge_emit && i < st->edge_emit->len)
             ? g_array_index (st->edge_emit, gint32, i) : -1;
      if (ei < 0 || (guint) ei >= st->edge_shapes->len) continue;
      line = g_ptr_array_index (st->edge_shapes, (guint) ei);

      ea = cmacs_graph_node (g, e->a);
      eb = cmacs_graph_node (g, e->b);
      if (!line || !ea || !eb) continue;
      fa = emitted_node_flags (r, st, e->a);
      fb = emitted_node_flags (r, st, e->b);

      if (any_match)
        alpha = ((fa | fb) & CMACS_LIBREGNUM_NODE_MATCH) ? 160 : 18;
      else if ((fa | fb) & CMACS_LIBREGNUM_NODE_NEIGHBOUR)
        /* An edge incident to the selection is the one thing you are
           actually looking at when you land on a node. */
        alpha = 200;

      {
        g_autoptr (GrlColor) col = edge_base_color (e, ea, eb, alpha);
        lrg_shape_set_color (LRG_SHAPE (line), col);
      }
    }
}

/* ── Camera ───────────────────────────────────────────────────────── */

void
cmacs_roamgraph_scene_set_projection (CmacsLibregnumRenderCtx *r,
                                      gboolean flat)
{
  LrgCamera3D *cam;
  SceneState *st = scene_state (r, TRUE);

  if (!r) return;
  st->flat = flat;

  cam = (LrgCamera3D *) cmacs_libregnum_render_ctx_get_camera (r);
  if (!cam) return;

  /* The flat view is a PERSPECTIVE camera locked head-on, not an
     orthographic one.

     Orthographic would be the obvious choice, but raylib overloads
     `fovy' to mean the view volume's world height when the projection
     is orthographic -- while graylib's grl_camera3d_set_fovy asserts
     `fovy < 180', a constraint that only makes sense for an angle.  A
     graph wider than 180 world units therefore cannot be framed: the
     assertion fires, g_return_if_fail bails, and the camera silently
     keeps a stale fovy -- once per frame, forever.

     Head-on perspective sidesteps that entirely, keeps fovy a real
     angle, and makes zoom (which dollies the camera) actually do
     something -- in orthographic, dollying changes nothing at all.  The
     foreshortening across a planar layout at this distance is not
     perceptible. */
  lrg_camera3d_set_projection (cam, LRG_PROJECTION_PERSPECTIVE);

  if (flat)
    {
      /* X right, Y up: the conventional 2D reading, matching the
         solver's DIMS == 2 layout, which snaps z to 0. */
      lrg_camera3d_set_up_xyz (cam, 0.0f, 1.0f, 0.0f);
      lrg_camera3d_set_fovy (cam, ROAM_FOV);
    }
  /* A flat view has nothing to orbit around; pan and zoom stay live. */
  cmacs_libregnum_render_ctx_set_orbit_locked (r, flat);
}

gboolean
cmacs_roamgraph_scene_flat_p (CmacsLibregnumRenderCtx *r)
{
  SceneState *st = scene_state (r, FALSE);
  return st ? st->flat : FALSE;
}

void
cmacs_roamgraph_scene_fit (CmacsLibregnumRenderCtx *r, CmacsGraph *g)
{
  SceneState *st = scene_state (r, TRUE);
  float lo[3], hi[3];
  double cx, cy, cz, extent, dist;

  if (!r || !g) return;
  if (!cmacs_graph_layout_bounds (g, lo, hi))
    {
      cmacs_libregnum_render_ctx_set_camera_state (r, 0.0, 0.0, 20.0,
                                                   0.0, 0.0, 0.0, ROAM_FOV);
      return;
    }

  cx = 0.5 * ((double) lo[0] + (double) hi[0]);
  cy = 0.5 * ((double) lo[1] + (double) hi[1]);
  cz = 0.5 * ((double) lo[2] + (double) hi[2]);

  extent = MAX (MAX ((double) hi[0] - (double) lo[0],
                     (double) hi[1] - (double) lo[1]),
                (double) hi[2] - (double) lo[2]);
  if (extent < 1.0) extent = 1.0;

  if (st->flat)
    {
      /* Head-on, backed off far enough that the bounding box fits the
         frustum in BOTH axes -- the horizontal half-angle is the
         vertical one scaled by the aspect ratio, so a wide graph in a
         wide window needs the larger of the two distances. */
      double half_v = tan (ROAM_FOV * 0.5 * G_PI / 180.0);
      double w = (double) hi[0] - (double) lo[0];
      double h = (double) hi[1] - (double) lo[1];
      double aspect = 1.6;
      int vw = 0, vh = 0;
      double dv, dh;

      cmacs_libregnum_render_ctx_get_size (r, &vw, &vh);
      if (vw > 0 && vh > 0) aspect = (double) vw / (double) vh;

      if (half_v < 1e-6) half_v = 0.4;
      dv = (h * 0.5) / half_v;
      dh = (w * 0.5) / (half_v * aspect);
      dist = MAX (dv, dh) * 1.15 + 2.0;

      cmacs_libregnum_render_ctx_set_camera_state (r, cx, cy, cz + dist,
                                                   cx, cy, cz, ROAM_FOV);
    }
  else
    {
      /* Back off along a fixed three-quarter direction so the initial
         view reads as three-dimensional rather than accidentally
         edge-on. */
      dist = extent * 1.25 + 4.0;
      cmacs_libregnum_render_ctx_set_camera_state
        (r,
         cx + dist * 0.45, cy + dist * 0.40, cz + dist * 0.80,
         cx, cy, cz, ROAM_FOV);
    }
}

#endif /* HAVE_CMACS_ROAMGRAPH */
