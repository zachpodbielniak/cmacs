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
  double     link_phase;   /* travelling-light phase, radians */
  GPtrArray *spark_shapes; /* LrgLine3D pool, repositioned each frame */
  GPtrArray *node_hilite;  /* LrgSphere3D*, one per emitted node */
  GArray    *node_orb;     /* gint32 billboard index, or -1, per node */
  GArray    *node_glow;    /* gint32 glow billboard index, or -1 */
  gboolean   shading;      /* light the nodes */
  gboolean   glow;         /* halo billboard behind each node */
  gboolean   isolate;      /* dim everything outside the selection's
                              neighbourhood */
  gint       ring_filter;  /* CmacsSbRing to keep, or -1 for all */
} SceneState;

/* A node is a flat disc without one.  raylib draws an unlit sphere in a
   single colour, so size is the only depth cue the glyphs have; a small
   bright sphere set toward a fixed light gives the specular that makes
   the eye read a ball.  Cheaper and far more robust than a shader: the
   lighting path in this renderer only applies to MESH_ASSET models and
   only inside the editor build.

   Spheres do not use that trick any more -- they are drawn as real, lit
   geometry by the renderer's orb pass (see orb_lod_for).  The offset
   highlight is still what shades the glyphs that are NOT spheres, whose
   shape carries meaning an orb cannot. */
#define SB_LIGHT_X (-0.45)
#define SB_LIGHT_Y ( 0.60)
#define SB_LIGHT_Z ( 0.65)
/* The highlight has to break the SURFACE to be seen at all: at offset
   O and radius R (both fractions of the node radius) it reaches O + R,
   so anything under 1.0 leaves it buried inside an opaque sphere,
   perfectly computed and completely invisible.  These put its cap just
   proud of the surface, which is what reads as a specular rather than
   as a bump. */
/* Which glyphs are spheres, and may therefore be drawn by the orb pass
   without losing anything.  A skill is a faceted gem and an application
   is a hex prism; their shape carries meaning a sphere cannot. */
static gboolean
orb_kind_p (CmacsSbKind kind)
{
  switch (kind)
    {
    case CMACS_SB_KIND_SKILL:
    case CMACS_SB_KIND_APP:
      return FALSE;
    default:
      return TRUE;
    }
}

/* How many triangles a node is worth.
 *
 * Real geometry costs vertices, and this map routinely draws well over a
 * thousand nodes at once, so the LOD is the whole reason the change from
 * flat impostors to lit spheres is affordable.  A department hub is a
 * landmark you fly to and look at; a leaf is a few pixels across, where
 * the difference between twenty facets and two hundred is invisible and
 * the difference in cost is not.
 *
 * The floor drops one step further once the map is busy: past
 * SB_ORB_CROWD nodes no individual leaf is being examined -- you are
 * reading structure, not looking at one ball -- and the cheapest sphere
 * still reads as round at that size.  Measured at 1200x900 on the real
 * notes graph, 1400 nodes cost 12.1 ms a frame at the middle tier and
 * 7.0 ms at the low one; a threshold above the map's own node count
 * would therefore have made the ladder decorative. */
#define SB_ORB_CROWD 1200

static int
orb_lod_for (CmacsSbKind kind, guint n_visible)
{
  if (kind == CMACS_SB_KIND_HUB || kind == CMACS_SB_KIND_CENTRE)
    return CMACS_LIBREGNUM_ORB_LOD_HIGH;
  if (n_visible > SB_ORB_CROWD)
    return CMACS_LIBREGNUM_ORB_LOD_LOW;
  return CMACS_LIBREGNUM_ORB_LOD_MED;
}

#define SB_HILITE_R    0.34   /* highlight radius, as a fraction */
#define SB_HILITE_OFF  0.78   /* how far toward the light, as a fraction */

/* Beads are a fixed pool, not one drawable per lit edge: a note with a
   hundred links would otherwise add a hundred drawables on every
   selection change, and removing them again means a rebuild. */
#define SB_N_SPARKS 1024
/* Beads per lit edge, and how much of the gap between two of them one
   bead fills.  Evenly spaced and marching together, which is what makes
   a line of them read as a rope light rather than as dashes: the eye
   picks up the direction from the whole run, not from one segment. */
#define SB_BEADS_MAX 6
#define SB_BEAD_FILL 0.30

/* Defined below, used by apply_flags which appears first. */
static gboolean node_in_selection (CmacsGraph *g, gint sel, guint i);
static void     scene_step_sparks (CmacsLibregnumRenderCtx *r, SceneState *st,
                                   CmacsGraph *g, gint sel_graph);

static GHashTable *s_states;    /* CmacsLibregnumRenderCtx* -> SceneState* */

static void
scene_state_free (gpointer p)
{
  SceneState *st = p;

  if (!st) return;
  if (st->node_shapes) g_ptr_array_free (st->node_shapes, TRUE);
  if (st->edge_shapes) g_ptr_array_free (st->edge_shapes, TRUE);
  if (st->spark_shapes) g_ptr_array_free (st->spark_shapes, TRUE);
  if (st->node_hilite) g_ptr_array_free (st->node_hilite, TRUE);
  if (st->node_orb) g_array_free (st->node_orb, TRUE);
  if (st->node_glow) g_array_free (st->node_glow, TRUE);
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
      st->spark_shapes = g_ptr_array_new ();
      st->node_hilite = g_ptr_array_new ();
      st->node_orb = g_array_new (FALSE, FALSE, sizeof (gint32));
      st->node_glow = g_array_new (FALSE, FALSE, sizeof (gint32));
      st->shading = TRUE;
      st->glow = TRUE;
      st->ring_filter = -1;
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
  g_ptr_array_set_size (st->spark_shapes, 0);
  g_ptr_array_set_size (st->node_hilite, 0);
  g_array_set_size (st->node_orb, 0);
  g_array_set_size (st->node_glow, 0);
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
     borrowed-pointer arrays must be dropped at the same moment.
     Billboards go with them now that nodes own some: they are not
     cleared by clear_drawables, so without this every refresh would
     append another impostor per node -- thousands of them, stacking up
     at the positions the nodes used to be in.  Icons are re-applied
     after the build, which is why clearing here is safe. */
  cmacs_libregnum_render_ctx_clear_drawables (r);
  cmacs_libregnum_render_ctx_clear_billboards (r);
  cmacs_libregnum_render_ctx_clear_orbs (r);
  g_ptr_array_set_size (st->node_shapes, 0);
  g_ptr_array_set_size (st->edge_shapes, 0);
  g_ptr_array_set_size (st->spark_shapes, 0);
  g_ptr_array_set_size (st->node_hilite, 0);
  g_array_set_size (st->node_orb, 0);
  g_array_set_size (st->node_glow, 0);

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
          /* A guide has to lie in the same plane as the band it names.
             raylib draws a 3D circle in XY; in 3D the layout is in the
             world's ground plane (XZ), so the guide is turned a quarter
             turn about X to match.  Left alone it stands vertically
             through the disc, which reads as four random hoops. */
          if (dims != 2)
            {
              g_autoptr (GrlVector3) axis = grl_vector3_new (1.0f, 0.0f, 0.0f);
              lrg_circle3d_set_rotation_axis (ring, axis);
              lrg_circle3d_set_rotation_angle (ring, 90.0f);
            }
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

  /* Spark pool for the travelling light.  Created once, parked at the
     origin with zero alpha, and repositioned each frame -- so lighting a
     note's links costs no drawable churn and no rebuild. */
  {
    guint sp;
    for (sp = 0; sp < SB_N_SPARKS; sp++)
      {
        LrgLine3D *sl = lrg_line3d_new_from_to (0, 0, 0, 0, 0, 0);
        g_autoptr (GrlColor) c0 = grl_color_new (255, 255, 255, 0);
        lrg_shape_set_color (LRG_SHAPE (sl), c0);
        g_ptr_array_add (st->spark_shapes, sl);
        cmacs_libregnum_render_ctx_add_drawable (r, sl);
      }
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

      g_array_index (st->node_emit, gint32, i) = (gint32) n_nodes_drawn;

      /* A sphere-shaped node is drawn ONLY by the orb pass, with no
         LrgSphere3D under it.  Keeping both would draw the same ball
         twice: the unlit one is a flat disc of colour and would show
         through the shaded one wherever the two tessellations disagree.
         node_shapes still gets an entry -- NULL -- so it stays
         index-aligned with the other per-node arrays. */
      if (st->shading && orb_kind_p (kind))
        shape = NULL;
      else
        {
          shape = glyph_for (kind, nd, col);
          lrg_shape_set_color (LRG_SHAPE (shape), col);
          cmacs_libregnum_render_ctx_add_drawable (r, shape);
        }
      g_ptr_array_add (st->node_shapes, shape);

      /* Lighting.  Spheres become ORBS -- real, per-vertex-lit sphere
         geometry drawn by the renderer's orb pass -- rather than the
         camera-facing impostor quads this used to draw.  An impostor is
         a picture of a sphere with its highlight baked into screen
         space, so orbiting never changes how anything is lit and a
         field of them reads as stickers on a sheet; real geometry has a
         real silhouette, occludes properly, and turns with the camera.

         Shapes that are not spheres keep their own geometry, because
         their shape is the signal: a gem must show facets and a prism
         must show edges.  Those get the small offset highlight instead.

         Both arrays get an entry either way -- a NULL or a -1 -- so they
         stay index-aligned with node_shapes and sync_positions can move
         all three from one loop.  A shorter array would silently pair a
         node with someone else's highlight. */
      {
        gint32 orb = -1;

        if (shape == NULL)
          {
            orb = cmacs_libregnum_render_ctx_add_orb
                    (r, nd->x, nd->y, nd->z, nd->radius,
                     ((guint32) cr << 24) | ((guint32) cg << 16)
                     | ((guint32) cb << 8) | (guint32) ca,
                     orb_lod_for (kind, n));
            if (orb < 0)
              {
                /* The orb pass refused it: fall back to plain geometry
                   rather than leaving an invisible node.  A node that
                   silently stops being drawn is far worse than one that
                   is drawn flat. */
                shape = glyph_for (kind, nd, col);
                lrg_shape_set_color (LRG_SHAPE (shape), col);
                cmacs_libregnum_render_ctx_add_drawable (r, shape);
                g_ptr_array_index (st->node_shapes,
                                   st->node_shapes->len - 1) = shape;
              }
          }
        g_array_append_val (st->node_orb, orb);

        if (st->shading && orb < 0)
          {
            double rad = (double) nd->radius;
            double hr = rad * SB_HILITE_R;
            double nx = (double) nd->x, ny = (double) nd->y;
            double nz = (double) nd->z;
            LrgSphere3D *hl =
              lrg_sphere3d_new_at ((float) (nx + rad * SB_HILITE_OFF * SB_LIGHT_X),
                                   (float) (ny + rad * SB_HILITE_OFF * SB_LIGHT_Y),
                                   (float) (nz + rad * SB_HILITE_OFF * SB_LIGHT_Z),
                                   (float) hr);
            g_autoptr (GrlColor) hc =
              grl_color_new ((guint8) (255 - (255 - (int) cr) * 35 / 100),
                             (guint8) (255 - (255 - (int) cg) * 35 / 100),
                             (guint8) (255 - (255 - (int) cb) * 35 / 100),
                             ca);
            lrg_shape_set_color (LRG_SHAPE (hl), hc);
            g_ptr_array_add (st->node_hilite, hl);
            cmacs_libregnum_render_ctx_add_drawable (r, hl);
          }
        else
          g_ptr_array_add (st->node_hilite, NULL);
      }

      /* The glow: a soft additive halo in the node's own colour, drawn
         by the renderer's glow layer.  This is what seats the map in
         its background -- against the nebula a flat-lit glyph reads as
         a sticker, a glowing one as a light source.  The halo uses the
         RAW node colour, not the lifted impostor tint: additive
         blending can only brighten, so there is no specular to buy
         headroom for, and the halo's job is to say the category as
         loudly as the node does.  Landmarks glow wider and brighter --
         they are the wayfinding.  Alpha scales the additive intensity;
         these rest values leave room above for the flag states. */
      {
        gint32 glow = -1;

        if (st->glow)
          {
            gboolean landmark = (kind == CMACS_SB_KIND_HUB
                                 || kind == CMACS_SB_KIND_CENTRE);
            float gsize = nd->radius * (landmark ? 4.6f : 3.2f);
            guint32 grgba = ((guint32) cr << 24) | ((guint32) cg << 16)
                            | ((guint32) cb << 8)
                            | (guint32) (landmark ? 64 : 44);
            glow = cmacs_libregnum_render_ctx_add_billboard_glow
                     (r, nd->x, nd->y, nd->z, gsize, grgba);
          }
        g_array_append_val (st->node_glow, glow);
      }

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

      /* The orb travels with its node.  It IS the node for every
         sphere-shaped glyph, so leaving it behind does not misplace a
         highlight -- it misplaces the node. */
      if (st->node_orb && node_i < st->node_orb->len)
        {
          gint32 orb = g_array_index (st->node_orb, gint32, node_i);
          if (orb >= 0)
            cmacs_libregnum_render_ctx_move_orb (r, orb,
                                                 nd->x, nd->y, nd->z);
        }

      /* And the glow: a halo left behind is a ghost light where the
         node used to be. */
      if (st->node_glow && node_i < st->node_glow->len)
        {
          gint32 glow = g_array_index (st->node_glow, gint32, node_i);
          if (glow >= 0)
            cmacs_libregnum_render_ctx_move_billboard (r, glow,
                                                       nd->x, nd->y, nd->z);
        }

      /* The specular travels with its node.  Left behind, it stops
         being a highlight and becomes a second, smaller node hanging in
         space -- and a tween moves every node every frame. */
      if (st->node_hilite && node_i < st->node_hilite->len)
        {
          LrgShape3D *hl = g_ptr_array_index (st->node_hilite, node_i);
          if (hl)
            {
              double rad = (double) nd->radius;
              double nx = (double) nd->x, ny = (double) nd->y;
              double nz = (double) nd->z;
              lrg_shape3d_set_position_xyz
                (hl,
                 (float) (nx + rad * SB_HILITE_OFF * SB_LIGHT_X),
                 (float) (ny + rad * SB_HILITE_OFF * SB_LIGHT_Y),
                 (float) (nz + rad * SB_HILITE_OFF * SB_LIGHT_Z));
            }
        }

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

/* Is graph node I excluded by the ring filter or by isolate mode?
 *
 * These are COLOUR decisions, not flag writes, on purpose.  The DIM
 * flag belongs to the search machinery (set_match_set), and a second
 * writer would have to agree with it about when to clear -- the classic
 * two-owners bug.  Deciding at paint time costs one comparison per node
 * per repaint and owns nothing.
 *
 * The centre is exempt from the ring filter: it belongs to every ring,
 * and a map filtered to Routines with its own centre dimmed looks
 * broken rather than filtered. */
static gboolean
node_filtered_out (SceneState *st, CmacsGraph *g, const guint8 *near,
                   guint i)
{
  CmacsGraphNode *nd = cmacs_graph_node (g, i);

  if (!nd) return FALSE;
  if (st->ring_filter >= 0
      && kind_of (nd) != CMACS_SB_KIND_CENTRE
      && (gint) nd->ring != st->ring_filter)
    return TRUE;
  if (st->isolate && near && near[i] == 0)
    return TRUE;
  return FALSE;
}

void
cmacs_secondbrain_scene_apply_flags (CmacsLibregnumRenderCtx *r,
                                     CmacsGraph *g)
{
  SceneState *st = scene_state (r, FALSE);
  guint n, m, i, node_i = 0;
  gboolean any_match = FALSE;
  gint sel_emit, sel_graph = -1;
  guint8 *near = NULL;

  if (!st || !g) return;

  n = cmacs_graph_n_nodes (g);
  m = cmacs_graph_n_edges (g);

  for (i = 0; i < n; i++)
    if (emitted_node_flags (r, st, i) & CMACS_LIBREGNUM_NODE_MATCH)
      { any_match = TRUE; break; }

  /* The selection is a SCENE index; edges are indexed by GRAPH index,
     and emission order is not graph order once anything is collapsed --
     so map back rather than comparing the two directly. */
  sel_emit = cmacs_libregnum_render_ctx_get_selected (r);
  if (sel_emit >= 0 && st->node_emit)
    for (i = 0; i < st->node_emit->len; i++)
      if (g_array_index (st->node_emit, gint32, i) == sel_emit)
        { sel_graph = i; break; }
  if (sel_graph < 0) sel_emit = -1;

  /* The selection's neighbourhood, computed ONCE and up front: 2 for
     the selection subtree, 1 for a node one visible edge away.  Both
     the colouring below and the NEIGHBOUR labels read from this, which
     is also what fixes a subtle latency the old order had -- flags were
     written after the colouring loop had already read them, so every
     repaint coloured from the PREVIOUS selection's neighbourhood and
     converged a frame late. */
  if (sel_graph >= 0)
    {
      near = g_new0 (guint8, n ? n : 1);
      for (i = 0; i < n; i++)
        if (node_in_selection (g, sel_graph, i))
          near[i] = 2;
      for (i = 0; i < m; i++)
        {
          CmacsGraphEdge *e = cmacs_graph_edge (g, i);
          CmacsGraphNode *ea, *eb;
          guint other;

          if (!e) continue;
          ea = cmacs_graph_node (g, e->a);
          eb = cmacs_graph_node (g, e->b);
          if (!ea || !eb || !ea->visible || !eb->visible) continue;
          if ((near[e->a] == 2) == (near[e->b] == 2)) continue;
          other = (near[e->a] == 2) ? e->b : e->a;
          if (near[other] == 0) near[other] = 1;
        }
    }

  /* Flag the selection's neighbours, which is what gets their names
     drawn: a lit rope running off to an unlabelled dot says something is
     connected without saying what, which is half an answer.
     Cleared first, so a previous selection's neighbours do not keep
     their labels after the selection moves. */
  cmacs_libregnum_render_ctx_clear_node_flags
    (r, CMACS_LIBREGNUM_NODE_NEIGHBOUR);
  if (near)
    for (i = 0; i < n; i++)
      if (near[i] == 1)
        {
          gint oe = cmacs_secondbrain_scene_emit_index (r, i);
          if (oe >= 0)
            cmacs_libregnum_render_ctx_set_node_flags
              (r, oe,
               cmacs_libregnum_render_ctx_get_node_flags (r, oe)
               | CMACS_LIBREGNUM_NODE_NEIGHBOUR);
        }

  for (i = 0; i < n && node_i < st->node_shapes->len; i++)
    {
      CmacsGraphNode *nd = cmacs_graph_node (g, i);
      LrgShape3D *shape;
      guint flags;
      guint8 cr, cg, cb, ca;
      gint32 orb, glow;
      gboolean fdim, dimmed;
      CmacsSbKind kind;

      if (!nd || !nd->visible) continue;
      shape = g_ptr_array_index (st->node_shapes, node_i);
      orb = (st->node_orb && node_i < st->node_orb->len)
              ? g_array_index (st->node_orb, gint32, node_i) : -1;
      glow = (st->node_glow && node_i < st->node_glow->len)
               ? g_array_index (st->node_glow, gint32, node_i) : -1;
      node_i++;
      if (!shape && orb < 0 && glow < 0) continue;

      kind = kind_of (nd);
      flags = emitted_node_flags (r, st, i);
      /* A filtered-out node is painted dim, not flagged dim: the DIM
         flag belongs to search, and a match beats a filter -- a search
         hit outside the filtered ring should still light up, because
         you searched for it. */
      fdim = node_filtered_out (st, g, near, i);
      dimmed = (fdim || (flags & CMACS_LIBREGNUM_NODE_DIM))
               && !(flags & CMACS_LIBREGNUM_NODE_MATCH);
      unpack_rgba (nd->rgba ? nd->rgba
                            : cmacs_sb_ring_color ((CmacsSbRing) nd->ring),
                   &cr, &cg, &cb, &ca);

      /* An orb answers to the same flags -- searching must dim it and a
         match must accent it, exactly as for a geometry glyph.  The
         colour goes in raw: the orb pass multiplies it by its own shade
         and adds a white specular on top, so unlike the impostor this
         replaced there is no tint ceiling to buy headroom under. */
      if (orb >= 0)
        {
          guint8 tr = cr, tg = cg, tb = cb, ta = ca;

          if (flags & CMACS_LIBREGNUM_NODE_MATCH)
            { tr = 255; tg = 210; tb = 74; ta = 255; }
          else if (dimmed)
            { tr = (guint8) (cr / 3); tg = (guint8) (cg / 3);
              tb = (guint8) (cb / 3); ta = 90; }
          else if (flags & CMACS_LIBREGNUM_NODE_NEIGHBOUR)
            { tr = bump (cr); tg = bump (cg); tb = bump (cb); ta = 255; }

          cmacs_libregnum_render_ctx_set_orb_color
            (r, orb,
             ((guint32) tr << 24) | ((guint32) tg << 16)
             | ((guint32) tb << 8) | (guint32) ta);
        }

      /* The glow answers to the same states, in intensity: additive
         blending means alpha IS brightness here.  The selection
         breathes -- its halo swells and settles on the same clock as
         the rope light, which is what makes "this one" unmistakable in
         a field of steady lights.  apply_flags runs every pulse frame
         while a selection exists, so the clock is already ticking. */
      if (glow >= 0)
        {
          gboolean landmark = (kind == CMACS_SB_KIND_HUB
                               || kind == CMACS_SB_KIND_CENTRE);
          guint8 gr = cr, gg = cg, gb = cb;
          guint8 galpha = landmark ? 64 : 44;

          if (flags & CMACS_LIBREGNUM_NODE_MATCH)
            { gr = 255; gg = 210; gb = 74; galpha = 110; }
          else if (dimmed)
            galpha = 6;
          else if (near && near[i] == 2)
            {
              double pulse = 0.5 + 0.5 * sin (st->link_phase * 2.0);
              galpha = (guint8) (70.0 + 60.0 * pulse);
            }
          else if (flags & CMACS_LIBREGNUM_NODE_NEIGHBOUR)
            galpha = 84;

          cmacs_libregnum_render_ctx_set_billboard_color
            (r, glow,
             ((guint32) gr << 24) | ((guint32) gg << 16)
             | ((guint32) gb << 8) | (guint32) galpha);
        }
      if (!shape) continue;

      if (flags & CMACS_LIBREGNUM_NODE_MATCH)
        {
          /* One accent for every hit, so the eye groups them. */
          g_autoptr (GrlColor) col = grl_color_new (255, 210, 74, 255);
          lrg_shape_set_color (LRG_SHAPE (shape), col);
        }
      else if (dimmed)
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

      /* A link touching the selection is THE thing you asked about, so
         it is lit and the rest recede.  At rest every link is drawn the
         same, which is honest but useless once there are more than a few
         hundred of them: the answer to "what is this note connected to"
         is invisible inside its own hairball.
         The light travels rather than merely brightening -- each edge
         offset by its own index -- because a bundle of static bright
         lines still reads as one mass, while motion separates them. */
      if (sel_graph >= 0
          && (node_in_selection (g, sel_graph, e->a)
              || node_in_selection (g, sel_graph, e->b)))
        {
          /* A lit link takes the colour of the node it belongs to,
             rather than the muted blend of its two ends: the point of
             lighting it is to say WHOSE link it is, and a grey line
             says nothing. */
          CmacsGraphNode *own = cmacs_graph_node (g, (guint) sel_graph);
          guint8 rr, gg, bb2, aa2;
          unpack_rgba ((own && own->rgba) ? own->rgba : 0x7FA8D8FFu,
                       &rr, &gg, &bb2, &aa2);
          /* The tube: the node's colour, clearly visible but well below
              the beads that run along it.  Equal brightness and the beads
              disappear into it, which is what a pale bead on a pale line
              looked like. */
          col = grl_color_new (rr, gg, bb2, 150);
          lrg_shape_set_color (LRG_SHAPE (line), col);
          continue;
        }
      if (sel_graph >= 0 && !any_match)
        alpha = 10;                 /* recede, but do not vanish */

      /* An edge with a filtered-out endpoint is part of what the filter
         asked to remove; leaving it at full strength redraws the very
         clutter the filter exists to cut.  Near-invisible rather than
         skipped, so the structure is still faintly there. */
      if (node_filtered_out (st, g, near, e->a)
          || node_filtered_out (st, g, near, e->b))
        alpha = MIN (alpha, 4);

      col = edge_base_color (e, ea, eb, alpha);
      lrg_shape_set_color (LRG_SHAPE (line), col);
    }

  scene_step_sparks (r, st, g, sel_graph);
  g_free (near);
}

/* Is node I the selection, or inside it?
 *
 * Inside it matters because selecting a DEPARTMENT should light what the
 * department is connected to.  A hub carries no org-roam links of its
 * own -- only its members do -- so comparing against the selected node
 * alone lights nothing at all, which is exactly how this looked when it
 * was first wired up. */
static gboolean
node_in_selection (CmacsGraph *g, gint sel, guint i)
{
  gint cur = (gint) i, guard = 0;

  if (sel < 0) return FALSE;
  while (guard++ < 64)
    {
      CmacsGraphNode *nd;
      if (cur == sel) return TRUE;
      nd = cmacs_graph_node (g, (guint) cur);
      if (!nd || nd->parent < 0) return FALSE;
      cur = nd->parent;
    }
  return FALSE;
}

/* Position the bead pool along the currently lit edges.
 *
 * Rope light, not fireflies: every lit edge carries a run of evenly
 * spaced beads that all advance together, so the run reads as motion in
 * the direction of the link.  A single travelling segment per edge does
 * not -- one dash sliding along a line is ambiguous about which way it
 * is going until you stare at it, and with a hundred links it is lost
 * among them entirely.
 *
 * The beads take the colour of the node whose links these are, matching
 * the lit edge underneath, so a bundle stays readable as one node's
 * connections rather than a generic glow.
 *
 * Spare beads are given zero alpha rather than removed, because removing
 * a drawable means rebuilding the scene. */
static void
scene_step_sparks (CmacsLibregnumRenderCtx *r, SceneState *st, CmacsGraph *g,
                   gint sel_graph)
{
  guint m = cmacs_graph_n_edges (g), i, lit = 0, slot = 0;
  guint *lit_edges;
  guint beads;
  guint8 cr = 255, cg = 250, cb = 210, ca;
  CmacsGraphNode *own;

  if (!st->spark_shapes || st->spark_shapes->len == 0) return;

  lit_edges = g_new (guint, m ? m : 1);
  if (sel_graph >= 0)
    for (i = 0; i < m; i++)
      {
        CmacsGraphEdge *e = cmacs_graph_edge (g, i);
        CmacsGraphNode *a, *b;
        if (!e) continue;
        a = cmacs_graph_node (g, e->a);
        b = cmacs_graph_node (g, e->b);
        if (!a || !b || !a->visible || !b->visible) continue;
        if (node_in_selection (g, sel_graph, e->a)
            || node_in_selection (g, sel_graph, e->b))
          lit_edges[lit++] = i;
      }

  /* Share the pool out over the lit edges.  Few links get a full rope;
     many links get fewer beads each rather than most edges getting none,
     which is what a first-come split would do. */
  beads = (lit > 0) ? (st->spark_shapes->len / lit) : 0;
  beads = CLAMP (beads, 1u, (guint) SB_BEADS_MAX);

  own = (sel_graph >= 0) ? cmacs_graph_node (g, (guint) sel_graph) : NULL;
  if (own)
    {
      guint8 aa;
      unpack_rgba (own->rgba ? own->rgba : 0x7FA8D8FFu, &cr, &cg, &cb, &aa);
      /* Most of the way to white, keeping just enough of the node's hue
         to say whose rope this is.  A rope light is bright lamps inside
         a coloured tube; lamps only a little brighter than the tube are
         not lamps.  Adding a fixed offset was not enough -- on an
         already-bright colour it saturates and the bead vanishes. */
      cr = (guint8) (255 - (255 - (int) cr) * 25 / 100);
      cg = (guint8) (255 - (255 - (int) cg) * 25 / 100);
      cb = (guint8) (255 - (255 - (int) cb) * 25 / 100);
    }

  for (slot = 0; slot < st->spark_shapes->len; slot++)
    {
      LrgLine3D *sp = g_ptr_array_index (st->spark_shapes, slot);
      guint ei_slot, bead;

      if (!sp) continue;

      ei_slot = (lit > 0) ? slot / beads : 0;
      bead    = (lit > 0) ? slot % beads : 0;

      if (lit == 0 || ei_slot >= lit)
        {
          g_autoptr (GrlColor) off = grl_color_new (255, 255, 255, 0);
          lrg_shape_set_color (LRG_SHAPE (sp), off);
          continue;
        }

      {
        guint ei = lit_edges[ei_slot];
        CmacsGraphEdge *e = cmacs_graph_edge (g, ei);
        CmacsGraphNode *a = cmacs_graph_node (g, e->a);
        CmacsGraphNode *b = cmacs_graph_node (g, e->b);
        double span = 1.0 / (double) beads;
        double t, t0, t1;
        g_autoptr (GrlColor) col = NULL;

        /* Beads sit one span apart and every one of them advances by the
           same phase, so the whole run travels together -- the direction
           is read off the run, not off any single bead. */
        t = (double) bead * span + st->link_phase * 0.05;
        t -= floor (t);
        t0 = t;
        t1 = t + span * SB_BEAD_FILL;
        if (t1 > 1.0) t1 = 1.0;

        /* Along the edge FROM the selected node, so every rope in the
           bundle runs the same way -- outward -- rather than each one
           following whichever endpoint the graph happened to store
           first. */
        if (!node_in_selection (g, sel_graph, e->a))
          {
            CmacsGraphNode *tmp = a; a = b; b = tmp;
          }

        {
          double ax = (double) a->x, ay = (double) a->y, az = (double) a->z;
          double dx = (double) b->x - ax, dy = (double) b->y - ay;
          double dz = (double) b->z - az;

          lrg_shape3d_set_position_xyz (LRG_SHAPE3D (sp),
                                        (float) (ax + dx * t0),
                                        (float) (ay + dy * t0),
                                        (float) (az + dz * t0));
          lrg_line3d_set_end_xyz (sp,
                                  (float) (ax + dx * t1),
                                  (float) (ay + dy * t1),
                                  (float) (az + dz * t1));
        }

        /* Fade in and out at the ends of the run so a bead arrives and
           leaves rather than popping in and out at the nodes. */
        ca = (guint8) CLAMP (170.0 + 85.0 * sin (t * G_PI), 0.0, 255.0);
        col = grl_color_new (cr, cg, cb, ca);
        lrg_shape_set_color (LRG_SHAPE (sp), col);
      }
    }
  g_free (lit_edges);
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

void
cmacs_secondbrain_scene_set_shading (CmacsLibregnumRenderCtx *r, gboolean on)
{
  SceneState *st = scene_state (r, TRUE);
  if (st) st->shading = on;
}

void
cmacs_secondbrain_scene_set_glow (CmacsLibregnumRenderCtx *r, gboolean on)
{
  SceneState *st = scene_state (r, TRUE);
  if (st) st->glow = on;
}

void
cmacs_secondbrain_scene_set_isolate (CmacsLibregnumRenderCtx *r, gboolean on)
{
  SceneState *st = scene_state (r, TRUE);
  if (st) st->isolate = on;
}

gboolean
cmacs_secondbrain_scene_isolate_p (CmacsLibregnumRenderCtx *r)
{
  SceneState *st = scene_state (r, FALSE);
  return st ? st->isolate : FALSE;
}

void
cmacs_secondbrain_scene_set_ring_filter (CmacsLibregnumRenderCtx *r,
                                         gint ring)
{
  SceneState *st = scene_state (r, TRUE);
  if (!st) return;
  st->ring_filter = (ring >= 0 && ring < CMACS_SB_RING_COUNT) ? ring : -1;
}

gint
cmacs_secondbrain_scene_ring_filter (CmacsLibregnumRenderCtx *r)
{
  SceneState *st = scene_state (r, FALSE);
  return st ? st->ring_filter : -1;
}

void
cmacs_secondbrain_scene_set_link_phase (CmacsLibregnumRenderCtx *r,
                                        double phase)
{
  SceneState *st = scene_state (r, TRUE);
  if (st) st->link_phase = phase;
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
