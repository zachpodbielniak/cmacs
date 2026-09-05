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
/* ...and even that is only right up to a point.  The real notes graph
   draws 4700 links, and at 26 each they sum into a solid haze that
   hides the disc.  So the rest alpha is HELD to 26 up to SB_EDGE_FULL
   edges and scaled down as 1/m past it, to a floor that keeps the
   structure faintly present.  One function, used by the build pass and
   the flag pass both, because the two must agree or a recolour
   flattens every edge. */
#define SB_EDGE_FULL  700
#define SB_EDGE_FLOOR 5

static guint8
edge_rest_alpha (guint m)
{
  double a = (double) SB_EDGE_ALPHA;
  if (m > SB_EDGE_FULL) a = a * (double) SB_EDGE_FULL / (double) m;
  return (guint8) CLAMP (a, (double) SB_EDGE_FLOOR, (double) SB_EDGE_ALPHA);
}

/* Camera field of view, in degrees.  A real angle -- both projections
 * here are perspective (see set_projection). */
#define SB_FOV 40.0

/* Vertices in a band guide.  High enough that a large ring reads as a
 * circle rather than a polygon. */
#define SB_BAND_VERTICES 96

/* The dressing: luminous band LANES and a galactic CORE.
 *
 * The lanes are additive ribbons under each band -- a skirt rising to
 * the hub circle, a fill across the rows the members sit in, a skirt
 * falling away outside -- in the ring's own colour.  They turn four thin
 * guide hoops into four bands of light the nodes lie IN, which is what
 * makes the disc read as a galaxy's dust lanes rather than as dots on
 * wire.  Intensities are additive alpha, and low on purpose: a lane is
 * a place, not a light, and the nodes have to stay the brightest thing
 * on it.  Widths are fractions of the ring gap so they scale with the
 * layout. */
#define SB_LANE_IN      0.30   /* inner skirt width, ring gaps */
#define SB_LANE_OUT     0.45   /* outer skirt width, ring gaps */
#define SB_LANE_PEAK    118    /* additive alpha on the hub circle */
#define SB_LANE_MID     66     /* additive alpha at the members' outer row */

/* The core is three additive glows and a fading disc on the origin:
   white-hot, then warm, then a cool corona, each wider than the last.
   The GLOWS are sized from the disc's OUTER edge -- a bulge is read
   against the galaxy it sits in, and sized from the innermost band
   (radius 6 on the real map, against a rim past 45) it came out as a
   pinprick under the centre label.  The DISC is sized from the
   innermost band, so the flat bright part stays inside the Skills ring
   and does not paint over it. */
#define SB_CORE_HOT_SIZE   0.11   /* x outer radius */
#define SB_CORE_WARM_SIZE  0.21
#define SB_CORE_COOL_SIZE  0.34   /* any wider and the corona paints the
                                     inner lanes blue */
#define SB_CORE_DISC       0.85   /* x innermost band radius */

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
  gboolean   dressing;     /* band lanes + galactic core; see
                              scene_dress */
  gboolean   isolate;      /* dim everything outside the selection's
                              neighbourhood */
  gint       ring_filter;  /* CmacsSbRing to keep, or -1 for all */
  GHashTable *keep;        /* node id -> present: the tag/category
                              filter's keep set, or NULL for "everything".
                              A paint-time decision like the ring filter,
                              for the same reason: DIM belongs to search,
                              and a second writer of it is the two-owners
                              bug. */
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
static void     scene_dress (CmacsLibregnumRenderCtx *r,
                             CmacsGraphLayout *layout, int dims,
                             double ring_gap);
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
  if (st->keep)        g_hash_table_unref (st->keep);
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

/* Forget everything about R, flags included -- not merely empty the
   arrays.  The state table is keyed by the render context's ADDRESS, and
   a freed context's address is exactly what the allocator hands the next
   one; a state left behind here would then be inherited whole by a
   view that never set it.  That is not hypothetical: two tests in a row
   that attach, configure and detach saw the second one come up with the
   first one's dressing on, and every count it read was off by that. */
void
cmacs_secondbrain_scene_reset (CmacsLibregnumRenderCtx *r)
{
  if (!r || !s_states) return;
  g_hash_table_remove (s_states, r);
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

/* ── Dressing ─────────────────────────────────────────────────────── */

/* One station of a ring at radius RAD and azimuth A, in the layout's
   own frame: XY in 2D, the ground plane with the warp on Y in 3D. */
static void
ring_point (CmacsGraphLayout *layout, int dims, double rad, double a,
            float *out)
{
  double h = (dims == 2 || rad <= 0.0)
               ? 0.0 : cmacs_graph_layout_warp_height (layout, rad, a);

  if (dims == 2)
    { out[0] = (float) (rad * cos (a)); out[1] = (float) (rad * sin (a));
      out[2] = 0.0f; }
  else
    { out[0] = (float) (rad * cos (a)); out[1] = (float) h;
      out[2] = (float) (rad * sin (a)); }
}

/* A closed annulus between radii R_IN and R_OUT, alpha A_IN on the inner
   rail and A_OUT on the outer, following the warp.  Either radius may
   be zero, which collapses that rail onto the origin and makes the
   ribbon a disc. */
static void
dress_annulus (CmacsLibregnumRenderCtx *r, CmacsGraphLayout *layout,
               int dims, double r_in, double r_out,
               guint8 cr, guint8 cg, guint8 cb, guint8 a_in, guint8 a_out)
{
  float   in_xyz[SB_BAND_VERTICES * 3], out_xyz[SB_BAND_VERTICES * 3];
  guint32 in_c[SB_BAND_VERTICES], out_c[SB_BAND_VERTICES];
  guint32 base = ((guint32) cr << 24) | ((guint32) cg << 16)
                 | ((guint32) cb << 8);
  int v;

  for (v = 0; v < SB_BAND_VERTICES; v++)
    {
      double a = 2.0 * G_PI * (double) v / SB_BAND_VERTICES;
      ring_point (layout, dims, r_in,  a, &in_xyz[v * 3]);
      ring_point (layout, dims, r_out, a, &out_xyz[v * 3]);
      in_c[v]  = base | a_in;
      out_c[v] = base | a_out;
    }
  cmacs_libregnum_render_ctx_add_ribbon (r, in_xyz, out_xyz, in_c, out_c,
                                         SB_BAND_VERTICES, TRUE);
}

static void
scene_dress (CmacsLibregnumRenderCtx *r, CmacsGraphLayout *layout,
             int dims, double ring_gap)
{
  double r0 = 0.0, rout = 0.0;
  int band;

  if (ring_gap <= 0.0) ring_gap = 6.0;

  /* Lanes: one per band, at the radius the layout placed it -- the same
     rule the guides follow, for the same reason (see the guides). */
  for (band = 0; band < CMACS_SB_RING_COUNT; band++)
    {
      double rad = cmacs_graph_layout_band_radius (layout, (guint) band);
      double dep = cmacs_graph_layout_band_depth (layout, (guint) band);
      guint8 cr, cg, cb, ca;

      if (rad <= 0.0)
        {
          rad = cmacs_sb_ring_radius ((CmacsSbRing) band, ring_gap);
          dep = ring_gap * 0.35;
        }
      if (dep <= 0.0) dep = ring_gap * 0.35;
      if (band == 0 || r0 <= 0.0) r0 = rad;
      rout = MAX (rout, rad + dep);

      unpack_rgba (cmacs_sb_ring_color ((CmacsSbRing) band),
                   &cr, &cg, &cb, &ca);
      /* Skirt in, fill across the members, skirt out.  The peak is on
         the hub circle, where the guide line runs. */
      dress_annulus (r, layout, dims, MAX (0.0, rad - SB_LANE_IN * ring_gap),
                     rad, cr, cg, cb, 0, SB_LANE_PEAK);
      dress_annulus (r, layout, dims, rad, rad + dep,
                     cr, cg, cb, SB_LANE_PEAK, SB_LANE_MID);
      dress_annulus (r, layout, dims, rad + dep,
                     rad + dep + SB_LANE_OUT * ring_gap,
                     cr, cg, cb, SB_LANE_MID, 0);
    }

  /* The core.  A disc fading out toward the innermost band, and three
     glows stacked on the origin.  Warm at the centre and cool at the
     edge, which is the palette every picture of a galactic bulge has
     taught the eye to expect.  The centre node sits inside all of it
     and comes out white-hot, which is the right thing to happen to the
     one node everything else hangs off. */
  if (r0 <= 0.0) r0 = ring_gap;
  if (rout <= 0.0) rout = ring_gap * 4.0;
  dress_annulus (r, layout, dims, 0.0, r0 * SB_CORE_DISC,
                 255, 236, 200, 96, 0);
  cmacs_libregnum_render_ctx_add_billboard_glow
    (r, 0.0f, 0.0f, 0.0f, (float) (rout * SB_CORE_HOT_SIZE),  0xFFF4D6A0u);
  cmacs_libregnum_render_ctx_add_billboard_glow
    (r, 0.0f, 0.0f, 0.0f, (float) (rout * SB_CORE_WARM_SIZE), 0xFFB86E5Au);
  cmacs_libregnum_render_ctx_add_billboard_glow
    (r, 0.0f, 0.0f, 0.0f, (float) (rout * SB_CORE_COOL_SIZE), 0x6E8CFF1Cu);
}

/* ── Build ────────────────────────────────────────────────────────── */

guint
cmacs_secondbrain_scene_build (CmacsLibregnumRenderCtx *r, CmacsGraph *g,
                               CmacsGraphLayout *layout,
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
  cmacs_libregnum_render_ctx_clear_ribbons (r);
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

  /* The dressing goes under everything: lanes and core are additive
     ribbons and glows that write no depth, so whatever is drawn after
     them sits on them. */
  if (st->dressing)
    scene_dress (r, layout, dims, ring_gap);

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
          /* Where the band ACTUALLY is, not where its index suggests.
             A band's radius grows with its population -- a department of
             a thousand notes needs the circumference to spread over --
             so the fixed per-index formula this used to call was simply
             a different number: it drew guides at 6/12/18/24 while the
             bands sat at 6/29/41/45, four small hoops adrift in the
             middle of a map five times their size.  The formula is kept
             only for a band the layout never placed, so the ARMS frame
             still shows all four rings when one is empty. */
          double rad = cmacs_graph_layout_band_radius (layout, (guint) band);
          guint32 rgba = cmacs_sb_ring_color ((CmacsSbRing) band);
          guint8 cr, cg, cb, ca;
          int v;

          if (rad <= 0.0)
            rad = cmacs_sb_ring_radius ((CmacsSbRing) band, ring_gap);
          unpack_rgba (rgba, &cr, &cg, &cb, &ca);

          /* Drawn as a polyline rather than as an LrgCircle3D, because a
             circle is flat and the band it names is not: the galaxy warp
             lifts one side of the disc and drops the other, and a flat
             ring cuts straight through that instead of following it.
             Sampling the layout's own warp is also what keeps the two in
             step when the tilt changes. */
          for (v = 0; v < SB_BAND_VERTICES; v++)
            {
              double a0 = 2.0 * G_PI * (double) v / SB_BAND_VERTICES;
              double a1 = 2.0 * G_PI * (double) (v + 1) / SB_BAND_VERTICES;
              double h0 = (dims == 2)
                            ? 0.0
                            : cmacs_graph_layout_warp_height (layout, rad, a0);
              double h1 = (dims == 2)
                            ? 0.0
                            : cmacs_graph_layout_warp_height (layout, rad, a1);
              LrgLine3D *seg;
              /* Brighter over a lane than it needed to be alone: the
                 crisp line is what the eye locks onto in the soft
                 fill. */
              g_autoptr (GrlColor) col =
                grl_color_new (cr, cg, cb, st->dressing ? 96 : 70);

              if (dims == 2)
                seg = lrg_line3d_new_from_to
                        ((float) (rad * cos (a0)), (float) (rad * sin (a0)), 0.0f,
                         (float) (rad * cos (a1)), (float) (rad * sin (a1)), 0.0f);
              else
                seg = lrg_line3d_new_from_to
                        ((float) (rad * cos (a0)), (float) h0,
                         (float) (rad * sin (a0)),
                         (float) (rad * cos (a1)), (float) h1,
                         (float) (rad * sin (a1)));
              lrg_shape_set_color (LRG_SHAPE (seg), col);
              cmacs_libregnum_render_ctx_add_drawable (r, seg);
            }
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
      col = edge_base_color (e, a, b, edge_rest_alpha (m));
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
  /* The keep set: whatever the Lisp side's tag/category filter decided
     survives.  The centre is exempt for the same reason as above; a hub
     is the Lisp side's call -- it puts a department's hub in the set
     when any member is kept, so a filtered map still shows which wedges
     the survivors live in. */
  if (st->keep
      && kind_of (nd) != CMACS_SB_KIND_CENTRE
      && !(nd->id && g_hash_table_contains (st->keep, nd->id)))
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
      guint8 alpha = edge_rest_alpha (m);
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
cmacs_secondbrain_scene_set_dressing (CmacsLibregnumRenderCtx *r, gboolean on)
{
  SceneState *st = scene_state (r, TRUE);
  if (st) st->dressing = on;
}

gboolean
cmacs_secondbrain_scene_dressing_p (CmacsLibregnumRenderCtx *r)
{
  SceneState *st = scene_state (r, FALSE);
  return st ? st->dressing : FALSE;
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
cmacs_secondbrain_scene_set_keep_set (CmacsLibregnumRenderCtx *r,
                                      const char *const *ids, guint n)
{
  SceneState *st = scene_state (r, TRUE);
  guint i;

  if (!st) return;
  if (st->keep) g_hash_table_unref (st->keep);
  st->keep = NULL;
  if (!ids) return;
  /* An EMPTY set is a real filter that keeps nothing -- the honest
     answer to "show me the nodes tagged X" when nothing is.  NULL ids
     is the only way to say "no filter". */
  st->keep = g_hash_table_new_full (g_str_hash, g_str_equal, g_free, NULL);
  for (i = 0; i < n; i++)
    if (ids[i]) g_hash_table_add (st->keep, g_strdup (ids[i]));
}

gboolean
cmacs_secondbrain_scene_keep_set_p (CmacsLibregnumRenderCtx *r)
{
  SceneState *st = scene_state (r, FALSE);
  return st && st->keep != NULL;
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
cmacs_secondbrain_scene_fit (CmacsLibregnumRenderCtx *r, CmacsGraph *g,
                             CmacsGraphLayout *layout)
{
  SceneState *st = scene_state (r, TRUE);
  float lo[3], hi[3];
  double cx, cy, cz, extent, dist;
  double w, h;
  gboolean concentric;

  if (!r || !g) return;
  if (!cmacs_graph_layout_bounds (g, lo, hi))
    {
      cmacs_libregnum_render_ctx_set_camera_state (r, 0.0, 0.0, 20.0,
                                                   0.0, 0.0, 0.0, SB_FOV);
      return;
    }

  /* A ring layout is centred on the ORIGIN by construction, so that is
     what the camera aims at -- not the middle of the bounding box.
     They are not the same point: the rim is lopsided (a department's
     members fan outward from wherever its wedge happens to be, and the
     outermost ring may hold four nodes at four arbitrary angles), so
     framing the box slides the whole ring system off to one side of the
     picture and makes the concentric structure the map is built around
     look like it is sitting in a corner of the cloud. */
  /* Every closed-form layout here is built around the origin -- rings,
     circles and the hex spiral all start there.  Only the force solver
     puts the graph wherever it happens to settle, and only it wants the
     bounding box.  (Asking whether the innermost BAND was placed looks
     equivalent and is not: a map with an empty Skills ring would fall
     back to box framing for no reason a reader could see.) */
  concentric = (layout != NULL
                && cmacs_graph_layout_get_kind (layout)
                     != CMACS_GRAPH_LAYOUT_FORCE);

  if (concentric)
    {
      /* Centred on the axis of symmetry, which is the origin IN THE
         PLANE and the mid-height on the way up: the layout is concentric
         in X and Z, and the height axis has no such symmetry -- a
         saucer rises from its centre, so its mass sits entirely above
         the plane and aiming at y = 0 would hang the whole map in the
         top of the frame. */
      cx = cz = 0.0;
      cy = 0.5 * ((double) lo[1] + (double) hi[1]);
      /* Half-extents measured about those centres, so the far side of a
         lopsided rim still fits. */
      w = 2.0 * MAX (fabs ((double) lo[0]), fabs ((double) hi[0]));
      h = (double) hi[1] - (double) lo[1];
      extent = MAX (MAX (w, h),
                    2.0 * MAX (fabs ((double) lo[2]), fabs ((double) hi[2])));
    }
  else
    {
      cx = 0.5 * ((double) lo[0] + (double) hi[0]);
      cy = 0.5 * ((double) lo[1] + (double) hi[1]);
      cz = 0.5 * ((double) lo[2] + (double) hi[2]);
      w  = (double) hi[0] - (double) lo[0];
      h  = (double) hi[1] - (double) lo[1];
      extent = MAX (MAX (w, h), (double) hi[2] - (double) lo[2]);
    }
  if (extent < 1.0) extent = 1.0;

  if (st->flat)
    {
      /* Back off far enough that the bounding box fits the frustum in
         BOTH axes: the horizontal half-angle is the vertical one scaled
         by the aspect ratio, so a wide ring in a wide window needs the
         larger of the two distances. */
      double half_v = tan (SB_FOV * 0.5 * G_PI / 180.0);
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
