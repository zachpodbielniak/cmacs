/* cmacs-secondbrain-scene.c --- libregnum render half of the second brain.
 *
 * Copyright (C) 2026 Zach Podbielniak
 * SPDX-License-Identifier: AGPL-3.0-or-later
 *
 * Turns a CmacsGraph into libregnum drawables plus node-table entries
 * on a CmacsLibregnumRenderCtx.
 *
 * Translation-unit firewall: this file includes <libregnum.h> (and
 * therefore raylib.h), whose `Color' struct clashes with cmacs's
 * pgtkgui.h `Color' typedef, so it CANNOT include lisp.h/frame.h/
 * buffer.h.  It talks to cmacs only through the plain-C
 * cmacs-libregnum-render.h API, exactly like cmacs-roamgraph-scene.c.
 *
 * Where this differs from roamgraph, deliberately: roamgraph keeps ONE
 * visual vocabulary (a sphere per note) because every node there is the
 * same kind of thing.  Here they are not -- an application, a cron
 * routine, a note and a skill are different kinds of object, and the
 * shape is the primary signal.  The map should be readable before any
 * label resolves. */

#include <config.h>

#ifdef HAVE_CMACS_SECONDBRAIN

#include "cmacs-secondbrain-scene.h"
#include "cmacs-secondbrain-model.h"
#include "cmacs-graphcore-layout.h"

#include <libregnum.h>
#include <glib.h>
#include <math.h>
#include <string.h>

/* Separate node and edge budgets, never one shared cap.  A shared
 * budget spent edges-first can exhaust itself before a single node is
 * drawn -- the view then comes up with every link and no content, and
 * nothing errors.  See the same note in cmacs-roamgraph-scene.c. */
#define SB_MAX_NODE_DRAWABLES 12000
#define SB_MAX_EDGE_DRAWABLES 24000

/* Edge alpha at rest.  Very low, and it has to be: with every
 * department open this graph draws well over a thousand links, and at
 * any alpha you would pick by looking at ONE edge, a thousand of them
 * overlap into a solid white mat across the middle of the map that
 * hides the nodes they exist to relate. */
#define SB_EDGE_ALPHA 26

/* Camera field of view, in degrees.  A real angle -- both projections
 * here are perspective (see set_projection). */
#define SB_FOV 40.0

/* Vertices in a band guide.  High enough that a large ring reads as a
 * circle rather than a polygon. */
#define SB_BAND_VERTICES 96

/* ── Retained drawable references ──────────────────────────────────
 * Kept so a position or colour change is an in-place mutation rather
 * than another full rebuild.  Pointers are BORROWED: add_drawable takes
 * ownership and clear_drawables frees them, so these arrays must be
 * reset in lock-step with every clear. */

typedef struct
{
  GPtrArray *node_shapes;   /* LrgShape3D*, borrowed, emission order */
  GPtrArray *edge_shapes;   /* LrgLine3D*,  borrowed, emission order */

  /* Graph index -> emission index, or -1 when not emitted.  The shape
     arrays and the render context's node table are in EMISSION order
     while the graph is in GRAPH order, and the two diverge the moment
     anything is skipped -- which here is constant, because a collapsed
     department hides its whole subtree.  Reading node flags with a
     graph index would recolour the wrong nodes. */
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
cmacs_secondbrain_scene_reset (CmacsLibregnumRenderCtx *r)
{
  SceneState *st = scene_state (r, FALSE);

  if (!st) return;
  g_ptr_array_set_size (st->node_shapes, 0);
  g_ptr_array_set_size (st->edge_shapes, 0);
  g_array_set_size (st->node_emit, 0);
  g_array_set_size (st->edge_emit, 0);
}

/* ── Colour ───────────────────────────────────────────────────────── */

static void
unpack_rgba (guint32 rgba, guint8 *cr, guint8 *cg, guint8 *cb, guint8 *ca)
{
  *cr = (guint8) ((rgba >> 24) & 0xFF);
  *cg = (guint8) ((rgba >> 16) & 0xFF);
  *cb = (guint8) ((rgba >> 8) & 0xFF);
  *ca = (guint8) (rgba & 0xFF);
  /* Alpha 0 means "opaque", not "invisible": a caller that packs a
     colour without thinking about alpha wants to see the node. */
  if (*ca == 0) *ca = 0xFF;
}

/* Mute an edge toward its endpoints' own colour, lifted slightly.  The
   lift keeps a link between two dark nodes visible; keeping most of the
   hue is what makes a bundle of links read as belonging to the
   departments it joins rather than as generic white noise laid over
   them.  Same single-source-of-truth rule as roamgraph: the build pass
   and the flag pass must agree or recolouring flattens every edge. */
static guint8
edge_tint (guint8 x, guint8 y)
{
  int avg = ((int) x + (int) y) / 2;
  return (guint8) ((avg * 2 + 110) / 3);
}

static GrlColor *
edge_base_color (CmacsGraphEdge *e, CmacsGraphNode *a, CmacsGraphNode *b,
                 guint8 alpha)
{
  guint8 ar, ag, ab, aa, br, bg, bb, ba;

  /* Similarity edges keep their own violet so they are never mistaken
     for a connection the user actually made. */
  if (e->kind == CMACS_GRAPH_EDGE_SIM)
    return grl_color_new (150, 110, 210, alpha);

  unpack_rgba (a->rgba ? a->rgba : 0x7FA8D8FFu, &ar, &ag, &ab, &aa);
  unpack_rgba (b->rgba ? b->rgba : 0x7FA8D8FFu, &br, &bg, &bb, &ba);
  return grl_color_new (edge_tint (ar, br), edge_tint (ag, bg),
                        edge_tint (ab, bb), alpha);
}

/* ── Glyphs ───────────────────────────────────────────────────────── */

/* One drawable per node, shaped by its ARMS role.
 *
 * A 6-slice cylinder is a hex prism -- libregnum has no hex primitive,
 * and this is the same thing with no new geometry code.  A skill is a
 * low-subdivision icosphere, which reads as a faceted gem against the
 * smooth spheres of memory.  (The reference design draws skills as
 * four-pointed stars; that needs a custom mesh and is deliberately not
 * done here.) */
static LrgShape3D *
glyph_for (CmacsSbKind kind, CmacsGraphNode *nd, GrlColor *col)
{
  float x = nd->x, y = nd->y, z = nd->z;
  float rad = nd->radius;

  switch (kind)
    {
    case CMACS_SB_KIND_APP:
      return LRG_SHAPE3D (lrg_cylinder3d_new_full (x, y, z, rad,
                                                   rad * 0.45f, 6, col));
    case CMACS_SB_KIND_SKILL:
      /* 1 subdivision, the coarsest the property allows (its range is
         1..6).  Passing 0 is a GObject CRITICAL per node -- and the
         shape still constructs, so it is a warning storm rather than a
         failure.  Coarse is what is wanted here: the facets are the
         point, so a skill reads as a gem beside memory's smooth
         spheres. */
      return LRG_SHAPE3D (lrg_icosphere3d_new_full (x, y, z, rad, 1, col));
    case CMACS_SB_KIND_ROUTINE:
    case CMACS_SB_KIND_HUB:
    case CMACS_SB_KIND_CENTRE:
    case CMACS_SB_KIND_FOLDER:
    case CMACS_SB_KIND_FILE:
    default:
      {
        LrgSphere3D *s = lrg_sphere3d_new_at (x, y, z, rad);
        lrg_shape_set_color (LRG_SHAPE (s), col);
        /* Spend triangles where they show: a hub is large enough that
           facets are obvious, a leaf is a few pixels across. */
        if (kind == CMACS_SB_KIND_HUB || kind == CMACS_SB_KIND_CENTRE)
          { lrg_sphere3d_set_rings (s, 12); lrg_sphere3d_set_slices (s, 18); }
        else
          { lrg_sphere3d_set_rings (s, 6);  lrg_sphere3d_set_slices (s, 10); }
        return LRG_SHAPE3D (s);
      }
    }
}

static CmacsSbKind
kind_of (CmacsGraphNode *nd)
{
  /* The Lisp side packs the role into the node's `level' field, which
     is otherwise unused here -- graphcore carries it for roamgraph's
     heading depth.  Reusing it avoids widening the shared struct for
     one consumer's enum. */
  int k = nd->level;
  if (k < 0 || k >= CMACS_SB_KIND_COUNT) return CMACS_SB_KIND_FILE;
  return (CmacsSbKind) k;
}

/* ── Build ────────────────────────────────────────────────────────── */

guint
cmacs_secondbrain_scene_build (CmacsLibregnumRenderCtx *r, CmacsGraph *g,
                               int dims, double ring_gap,
                               gboolean band_guides)
{
  SceneState *st;
  guint n, m, i, emitted = 0;
  guint n_nodes_drawn = 0, n_edges_drawn = 0;

  if (!r || !g) return 0;
  st = scene_state (r, TRUE);

  /* clear_drawables also clears the node table, so both of our
     borrowed-pointer arrays must be dropped at the same moment. */
  cmacs_libregnum_render_ctx_clear_drawables (r);
  g_ptr_array_set_size (st->node_shapes, 0);
  g_ptr_array_set_size (st->edge_shapes, 0);

  n = cmacs_graph_n_nodes (g);
  m = cmacs_graph_n_edges (g);

  g_array_set_size (st->node_emit, n);
  g_array_set_size (st->edge_emit, m);
  {
    guint z;
    for (z = 0; z < n; z++) g_array_index (st->node_emit, gint32, z) = -1;
    for (z = 0; z < m; z++) g_array_index (st->edge_emit, gint32, z) = -1;
  }

  st->flat = (dims == 2);

  /* Band guides first, so everything else draws over them.  They are
     static scenery: a translucent circle per ARMS ring, which is what
     turns four arcs of dots into four named layers.  They carry no node
     table entry -- they are not pickable, and a stray click on the
     ring you were aiming past is worse than no target at all. */
  if (band_guides)
    {
      int band;
      for (band = 0; band < CMACS_SB_RING_COUNT; band++)
        {
          double rad = cmacs_sb_ring_radius ((CmacsSbRing) band, ring_gap);
          guint32 rgba = cmacs_sb_ring_color ((CmacsSbRing) band);
          guint8 cr, cg, cb, ca;
          LrgCircle3D *ring;
          g_autoptr (GrlColor) col = NULL;

          unpack_rgba (rgba, &cr, &cg, &cb, &ca);
          col = grl_color_new (cr, cg, cb, 70);
          ring = lrg_circle3d_new_full (0.0f, 0.0f, 0.0f, (float) rad,
                                        SB_BAND_VERTICES, col);
          cmacs_libregnum_render_ctx_add_drawable (r, ring);
        }
    }

  /* Edges next, so they render behind the nodes they connect.  With
     separate budgets they can no longer starve the nodes by going
     first. */
  for (i = 0; i < m; i++)
    {
      CmacsGraphEdge *e = cmacs_graph_edge (g, i);
      CmacsGraphNode *a, *b;
      LrgLine3D *line;
      g_autoptr (GrlColor) col = NULL;

      if (!e) continue;
      a = cmacs_graph_node (g, e->a);
      b = cmacs_graph_node (g, e->b);
      if (!a || !b) continue;
      /* An edge into a collapsed subtree has no visible endpoint to
         join, so it would be a line to nowhere. */
      if (!a->visible || !b->visible) continue;
      if (n_edges_drawn >= SB_MAX_EDGE_DRAWABLES) break;

      line = lrg_line3d_new_from_to (a->x, a->y, a->z, b->x, b->y, b->z);
      col = edge_base_color (e, a, b, SB_EDGE_ALPHA);
      lrg_shape_set_color (LRG_SHAPE (line), col);

      g_array_index (st->edge_emit, gint32, i) = (gint32) n_edges_drawn;
      g_ptr_array_add (st->edge_shapes, line);
      cmacs_libregnum_render_ctx_add_drawable (r, line);
      n_edges_drawn++;
    }

  /* Nodes.  One glyph and one node-table entry each; the node-table
     `path' is the caller's id string, because the numeric scene id is
     insertion order and is stale the moment the scene is rebuilt. */
  for (i = 0; i < n; i++)
    {
      CmacsGraphNode *nd = cmacs_graph_node (g, i);
      CmacsSbKind kind;
      LrgShape3D *shape;
      g_autoptr (GrlColor) col = NULL;
      guint8 cr, cg, cb, ca;
      guint id;

      if (!nd || !nd->visible) continue;
      if (n_nodes_drawn >= SB_MAX_NODE_DRAWABLES) break;

      kind = kind_of (nd);
      unpack_rgba (nd->rgba ? nd->rgba
                            : cmacs_sb_ring_color ((CmacsSbRing) nd->ring),
                   &cr, &cg, &cb, &ca);
      col = grl_color_new (cr, cg, cb, ca);

      shape = glyph_for (kind, nd, col);
      lrg_shape_set_color (LRG_SHAPE (shape), col);

      g_array_index (st->node_emit, gint32, i) = (gint32) n_nodes_drawn;
      g_ptr_array_add (st->node_shapes, shape);
      cmacs_libregnum_render_ctx_add_drawable (r, shape);
      n_nodes_drawn++;

      id = cmacs_libregnum_render_ctx_add_node (r, nd->id, nd->title,
                                                FALSE, 0, -1,
                                                nd->x, nd->y, nd->z,
                                                nd->radius, nd->radius,
                                                nd->radius);
      /* Hubs and the centre are permanent landmarks, so the ring names
         and department names are readable without pointing at
         anything; leaves label on hover or the map is unreadable. */
      cmacs_libregnum_render_ctx_set_node_label_mode
        (r, (gint) id,
         (kind == CMACS_SB_KIND_HUB || kind == CMACS_SB_KIND_CENTRE)
           ? CMACS_LIBREGNUM_LABEL_ALWAYS
           : CMACS_LIBREGNUM_LABEL_HOVER);
      emitted++;
    }

  return emitted;
}

/* ── Icons ────────────────────────────────────────────────────────
 *
 * libregnum ships LrgVectorImage -- an SVG rasteriser that renders to a
 * GrlTexture at any target size -- and until now nothing in cmacs used
 * it.  Pairing it with the render context's billboard list gives real
 * application icons with no new render plumbing: the billboard path
 * already draws camera-facing textured quads every frame.
 *
 * Rasterised at a fixed pixel size and uploaded once.  Re-rendering per
 * frame would be the obvious mistake: an SVG rasterise is orders of
 * magnitude more expensive than the draw it feeds. */

gboolean
cmacs_secondbrain_scene_add_icon (CmacsLibregnumRenderCtx *r,
                                  const char *svg_path,
                                  float x, float y, float z,
                                  float size, int px)
{
  g_autoptr (GError) error = NULL;
  g_autoptr (LrgVectorImage) img = NULL;
  GrlTexture *tex;

  if (!r || !svg_path || !*svg_path) return FALSE;
  if (px <= 0) px = 128;

  img = lrg_vector_image_new_from_file (svg_path, &error);
  if (!img) return FALSE;

  /* Transparent background, aspect preserved: an icon squashed to fill
     a square reads as a different icon. */
  tex = lrg_vector_image_render_to_texture (img, px, px, NULL, TRUE);
  if (!tex) return FALSE;

  /* add_billboard takes ownership of the texture. */
  cmacs_libregnum_render_ctx_add_billboard (r, x, y, z, tex, size);
  return TRUE;
}

/* ── Position sync ────────────────────────────────────────────────── */

void
cmacs_secondbrain_scene_sync_positions (CmacsLibregnumRenderCtx *r,
                                        CmacsGraph *g)
{
  SceneState *st = scene_state (r, FALSE);
  guint n, m, i, node_i = 0;

  if (!st || !g) return;

  n = cmacs_graph_n_nodes (g);
  m = cmacs_graph_n_edges (g);

  for (i = 0; i < m; i++)
    {
      CmacsGraphEdge *e = cmacs_graph_edge (g, i);
      CmacsGraphNode *a, *b;
      LrgLine3D *line;
      gint32 ei;

      if (!e) continue;
      ei = (st->edge_emit && i < st->edge_emit->len)
             ? g_array_index (st->edge_emit, gint32, i) : -1;
      if (ei < 0 || (guint) ei >= st->edge_shapes->len) continue;
      line = g_ptr_array_index (st->edge_shapes, (guint) ei);

      a = cmacs_graph_node (g, e->a);
      b = cmacs_graph_node (g, e->b);
      if (!a || !b || !line) continue;
      lrg_shape3d_set_position_xyz (LRG_SHAPE3D (line), a->x, a->y, a->z);
      lrg_line3d_set_end_xyz (line, b->x, b->y, b->z);
    }

  for (i = 0; i < n && node_i < st->node_shapes->len; i++)
    {
      CmacsGraphNode *nd = cmacs_graph_node (g, i);
      LrgShape3D *shape;

      if (!nd || !nd->visible) continue;
      shape = g_ptr_array_index (st->node_shapes, node_i);
      if (shape)
        lrg_shape3d_set_position_xyz (shape, nd->x, nd->y, nd->z);
      /* Keep the pick box under the glyph, or clicking lands on
         wherever the node used to be -- which during a tween is every
         frame. */
      cmacs_libregnum_render_ctx_move_node (r, (gint) node_i,
                                            nd->x, nd->y, nd->z);
      node_i++;
    }
}

/* ── Highlighting ─────────────────────────────────────────────────── */

static guint8
bump (guint8 c)
{
  int v = (int) c + (255 - (int) c) / 2;
  return (guint8) MIN (255, v);
}

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
cmacs_secondbrain_scene_apply_flags (CmacsLibregnumRenderCtx *r,
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
      LrgShape3D *shape;
      guint flags;
      guint8 cr, cg, cb, ca;

      if (!nd || !nd->visible) continue;
      shape = g_ptr_array_index (st->node_shapes, node_i);
      node_i++;
      if (!shape) continue;

      flags = emitted_node_flags (r, st, i);
      unpack_rgba (nd->rgba ? nd->rgba
                            : cmacs_sb_ring_color ((CmacsSbRing) nd->ring),
                   &cr, &cg, &cb, &ca);

      if (flags & CMACS_LIBREGNUM_NODE_MATCH)
        {
          /* One accent for every hit, so the eye groups them. */
          g_autoptr (GrlColor) col = grl_color_new (255, 210, 74, 255);
          lrg_shape_set_color (LRG_SHAPE (shape), col);
        }
      else if (flags & CMACS_LIBREGNUM_NODE_DIM)
        {
          g_autoptr (GrlColor) col =
            grl_color_new ((guint8) (cr / 3), (guint8) (cg / 3),
                           (guint8) (cb / 3), 90);
          lrg_shape_set_color (LRG_SHAPE (shape), col);
        }
      else if (flags & CMACS_LIBREGNUM_NODE_NEIGHBOUR)
        {
          /* Brightened rather than recoloured, so it still reads as
             its own ring. */
          g_autoptr (GrlColor) col =
            grl_color_new (bump (cr), bump (cg), bump (cb), 255);
          lrg_shape_set_color (LRG_SHAPE (shape), col);
        }
      else
        {
          g_autoptr (GrlColor) col = grl_color_new (cr, cg, cb, ca);
          lrg_shape_set_color (LRG_SHAPE (shape), col);
        }
    }

  for (i = 0; i < m; i++)
    {
      CmacsGraphEdge *e = cmacs_graph_edge (g, i);
      CmacsGraphNode *ea, *eb;
      LrgLine3D *line;
      gint32 ei;
      guint fa, fb;
      guint8 alpha = SB_EDGE_ALPHA;
      g_autoptr (GrlColor) col = NULL;

      if (!e) continue;
      ei = (st->edge_emit && i < st->edge_emit->len)
             ? g_array_index (st->edge_emit, gint32, i) : -1;
      if (ei < 0 || (guint) ei >= st->edge_shapes->len) continue;
      line = g_ptr_array_index (st->edge_shapes, (guint) ei);

      ea = cmacs_graph_node (g, e->a);
      eb = cmacs_graph_node (g, e->b);
      if (!line || !ea || !eb) continue;

      fa = emitted_node_flags (r, st, e->a);
      fb = emitted_node_flags (r, st, e->b);

      /* An edge between two dimmed nodes is noise; one touching a match
         is context worth seeing. */
      if (any_match)
        alpha = ((fa | fb) & CMACS_LIBREGNUM_NODE_MATCH) ? 160 : 18;

      col = edge_base_color (e, ea, eb, alpha);
      lrg_shape_set_color (LRG_SHAPE (line), col);
    }
}

/* ── Camera ───────────────────────────────────────────────────────── */

void
cmacs_secondbrain_scene_set_projection (CmacsLibregnumRenderCtx *r,
                                        gboolean flat)
{
  LrgCamera3D *cam;
  SceneState *st = scene_state (r, TRUE);

  if (!r) return;
  st->flat = flat;

  cam = (LrgCamera3D *) cmacs_libregnum_render_ctx_get_camera (r);
  if (!cam) return;

  /* PERSPECTIVE in both views, locked head-on for the flat one.
     Orthographic is the obvious choice and is unusable: raylib
     overloads `fovy' to mean the view volume's world height when the
     projection is orthographic, while graylib's set_fovy asserts
     `fovy < 180' -- a constraint that only makes sense for an angle.
     A graph wider than 180 world units then cannot be framed at all,
     silently, once per frame.  (Same reasoning, and the same fix, as
     roamgraph.) */
  lrg_camera3d_set_projection (cam, LRG_PROJECTION_PERSPECTIVE);

  if (flat)
    {
      /* X right, Y up: the conventional 2D reading, matching the
         layout's DIMS == 2, which snaps z to 0. */
      lrg_camera3d_set_up_xyz (cam, 0.0f, 1.0f, 0.0f);
      lrg_camera3d_set_fovy (cam, SB_FOV);
    }
  /* Concentric rings viewed head-on have nothing to orbit around, and
     tumbling them only reveals that they are coplanar. */
  cmacs_libregnum_render_ctx_set_orbit_locked (r, flat);
}

gboolean
cmacs_secondbrain_scene_flat_p (CmacsLibregnumRenderCtx *r)
{
  SceneState *st = scene_state (r, FALSE);
  return st ? st->flat : FALSE;
}

gint
cmacs_secondbrain_scene_emit_index (CmacsLibregnumRenderCtx *r, guint i)
{
  SceneState *st = scene_state (r, FALSE);
  if (!st || !st->node_emit || i >= st->node_emit->len) return -1;
  return g_array_index (st->node_emit, gint32, i);
}

gboolean
cmacs_secondbrain_scene_focus_node (CmacsLibregnumRenderCtx *r, guint i)
{
  gint e = cmacs_secondbrain_scene_emit_index (r, i);
  if (e < 0) return FALSE;
  cmacs_libregnum_render_ctx_focus_node (r, e);
  return TRUE;
}

void
cmacs_secondbrain_scene_fit (CmacsLibregnumRenderCtx *r, CmacsGraph *g)
{
  SceneState *st = scene_state (r, TRUE);
  float lo[3], hi[3];
  double cx, cy, cz, extent, dist;

  if (!r || !g) return;
  if (!cmacs_graph_layout_bounds (g, lo, hi))
    {
      cmacs_libregnum_render_ctx_set_camera_state (r, 0.0, 0.0, 20.0,
                                                   0.0, 0.0, 0.0, SB_FOV);
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
      /* Back off far enough that the bounding box fits the frustum in
         BOTH axes: the horizontal half-angle is the vertical one scaled
         by the aspect ratio, so a wide ring in a wide window needs the
         larger of the two distances. */
      double half_v = tan (SB_FOV * 0.5 * G_PI / 180.0);
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
                                                   cx, cy, cz, SB_FOV);
    }
  else
    {
      /* A fixed three-quarter direction, so the initial view reads as
         three-dimensional rather than accidentally edge-on -- which,
         for a set of coplanar rings, it otherwise would be. */
      dist = extent * 1.25 + 4.0;
      cmacs_libregnum_render_ctx_set_camera_state
        (r,
         cx + dist * 0.45, cy + dist * 0.40, cz + dist * 0.80,
         cx, cy, cz, SB_FOV);
    }
}

#endif /* HAVE_CMACS_SECONDBRAIN */
