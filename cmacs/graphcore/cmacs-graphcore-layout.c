/* cmacs-graphcore-layout.c --- force-directed graph layout.
 *
 * Copyright (C) 2026 Zach Podbielniak
 * SPDX-License-Identifier: AGPL-3.0-or-later
 *
 * See cmacs-graphcore-layout.h for the contract and the rationale.
 * Pure C -- no "lisp.h", no <libregnum.h>. */

#include <config.h>

#ifdef HAVE_CMACS_GRAPHCORE

#include "cmacs-graphcore-layout.h"

#include <math.h>
#include <stdlib.h>
#include <string.h>

/* Ideal edge length, in world units.
 *
 * Deliberately a CONSTANT, not the textbook k = C*sqrt(area/n).  That
 * formula exists to pack a graph into a fixed frame; here the camera
 * fits itself to the content instead, so making k depend on n only
 * makes the whole map's scale depend on how many notes you happen to
 * have.  A constant k means node spacing reads the same at 20 nodes and
 * at 2000, and the natural cluster extent stays k*cbrt(n) (3D) or
 * k*sqrt(n) (2D).  Nodes are ~0.3 units in radius, so 3.0 leaves a
 * comfortable gap. */
#define GRAPHCORE_K            3.0

/* Initial temperature as a fraction of the graph's nominal extent. */
#define GRAPHCORE_T0_FRACTION  0.10

/* Pull toward the origin.
 *
 * Constant in magnitude (not proportional to distance) and weighted by
 * degree.  Two reasons:
 *
 *  - It must scale with the node count at all.  An isolated node sits
 *    where n*k^2/d balances the pull, so a fixed gravity lets the cloud
 *    grow without bound as the graph grows.  With this form a leaf
 *    settles at d = k*sqrt(n/gravity); aiming that at roughly twice the
 *    natural extent gives gravity ~= cbrt(n)/4.
 *
 *  - Weighting by degree is what makes it look like a knowledge graph
 *    rather than a soap bubble.  Uniform distance-proportional gravity
 *    balances against repulsion at one radius, so every node drifts to
 *    the same shell and the middle hollows out.  Pulling hubs harder
 *    seats them centrally and lets their leaves fan outward, which is
 *    both the conventional reading and the useful one. */
#define GRAPHCORE_GRAVITY_SCALE 0.25

/* Similarity edges are a hint, not topology: they nudge, they must not
 * dominate the real link structure. */
#define GRAPHCORE_W_SIM        0.35f

/* Convergence: this many consecutive iterations below the threshold. */
#define GRAPHCORE_QUIET_RUNS   3

/* Octree recursion cap.  Coincident points would otherwise split
 * forever; past this depth a cell simply accumulates mass. */
#define GRAPHCORE_BH_MAX_DEPTH 24

/* Radial distance between adjacent rings / circles.  Twice the ideal
 * edge length, so a band reads as its own orbit rather than merging
 * into its neighbours. */
/* Ring bookkeeping is a fixed array indexed by the node's guint8 ring,
   so it covers every value that field can hold. */
#define GRAPHCORE_MAX_BANDS (256)
/* World units of arc each node wants to itself, and the radial gap
   between two rows of the same band.  Together they set how much room a
   band claims for its population. */
#define GRAPHCORE_NODE_ARC (0.95)
#define GRAPHCORE_ROW_GAP  (0.85)
/* Disc thickness, as a fraction of the LOCAL WARP AMPLITUDE (r*tan(tilt))
   rather than an absolute distance.  Two consequences, both wanted:

   - it scales with the disc, so a wide map is proportionally as thick as
     a narrow one and the shape survives any ring gap;
   - the maximum elevation any node can reach is exactly
     atan((1 + THICKNESS) * tan(TILT)) -- a bound that can be stated,
     documented and tested, which an absolute scatter cannot be.

   It is also azimuth-independent, unlike the warp: a real disc is thick
   everywhere, not only where it happens to bend.  Big enough to read as
   volume from any angle, small enough that the bands stay bands. */
#define GRAPHCORE_GALAXY_THICKNESS (0.34)
/* How sharply the warp turns up toward the rim.
 *
 * This exponent is the whole difference between a warp and a tilt, and
 * the linear case is a trap that looks right in the code and is a
 * rigid rotation in the picture: with h = r*tan(t)*sin(a) and the
 * in-plane coordinate v = r*sin(a), the height is just h = tan(t)*v --
 * a PLANE.  Every node moves, nothing bends, and orbiting reveals
 * exactly the flat disc the warp existed to get rid of.
 *
 * Squaring it gives the "integral sign" a real galaxy has: the inner
 * disc stays flat and legible while the rim turns up on one side and
 * down on the other, so the shape survives being looked at from any
 * angle.  The crest is unchanged -- at the reference radius the
 * exponent contributes exactly 1 -- so TILT still means what it says. */
#define GRAPHCORE_GALAXY_WARP_POWER (2.0)
#define GRAPHCORE_RING_GAP     6.0

/* Centre-to-centre spacing of the hex lattice, in the same world units
 * as GRAPHCORE_K. */
#define GRAPHCORE_HEX_SIZE     2.0

/* ── Barnes-Hut octree ────────────────────────────────────────────
 * A flat array of cells addressed by index rather than a pointer tree:
 * one contiguous allocation, retained across iterations, no per-step
 * malloc churn after the first pass. */

typedef struct
{
  float  cx, cy, cz;    /* centre of this cell's region */
  float  half;          /* half-extent of the region */
  float  mx, my, mz;    /* sum of member positions (COM numerator) */
  float  mass;          /* member count */
  gint32 child[8];      /* cell indices, -1 when empty */
  gint32 body;          /* node index when this is a single-body leaf */
  guint8 is_leaf;
} BhCell;

struct CmacsGraphLayout
{
  int      dims;
  int      iter;        /* iterations completed */
  int      iters;       /* schedule length */
  double   k;           /* ideal edge length */
  double   extent;      /* natural cluster radius, k * n^(1/dims) */
  double   gravity;     /* origin pull; scales with the node count */
  double   t0;          /* initial temperature */
  double   theta;       /* Barnes-Hut opening angle */
  int      quiet;       /* consecutive quiet iterations */
  gboolean converged;

  GArray  *cells;       /* BhCell */
  GArray  *disp;        /* float, 3 per node */

  /* Closed-form placement + tweening. */
  CmacsGraphLayoutKind kind;
  double   spin;        /* RINGS angular offset, radians */
  double   ring_gap;    /* radial distance between bands */
  double   galaxy_tilt; /* max out-of-plane angle, radians; 0 = flat */
  int      tween_frame; /* frames elapsed in the current tween */
  int      tween_frames;/* 0 = not tweening */

  /* Where RINGS actually put each band, published for whoever has to
     draw on top of it.  Radius 0 means "this band was not placed" --
     either the layout is not RINGS, or that band holds nothing.
     Recomputed by every place_rings, because the radii depend on the
     population and the population changes on every expand. */
  double   band_r[GRAPHCORE_MAX_BANDS];
  guint    band_rows[GRAPHCORE_MAX_BANDS];
  /* Radius the warp is normalised against: the outer edge of the
     outermost band, where the crest reaches TILT exactly. */
  double   warp_ref;
};

CmacsGraphLayout *
cmacs_graph_layout_new (void)
{
  CmacsGraphLayout *l = g_new0 (CmacsGraphLayout, 1);

  l->dims      = 3;
  l->theta     = 0.9;
  l->converged = TRUE;      /* nothing armed yet */
  l->kind      = CMACS_GRAPH_LAYOUT_FORCE;
  l->ring_gap  = GRAPHCORE_RING_GAP;
  /* Flat by default, so an existing consumer's picture does not change
     under it; a scene that wants the warp asks for it. */
  l->galaxy_tilt = 0.0;
  l->cells     = g_array_new (FALSE, FALSE, sizeof (BhCell));
  l->disp      = g_array_new (FALSE, TRUE, sizeof (float));
  return l;
}

void
cmacs_graph_layout_free (CmacsGraphLayout *l)
{
  if (!l) return;
  if (l->cells) g_array_free (l->cells, TRUE);
  if (l->disp)  g_array_free (l->disp, TRUE);
  g_free (l);
}

int
cmacs_graph_layout_dims (CmacsGraphLayout *l)
{
  return l ? l->dims : 3;
}

gboolean
cmacs_graph_layout_converged (CmacsGraphLayout *l)
{
  return l ? l->converged : TRUE;
}

double
cmacs_graph_layout_progress (CmacsGraphLayout *l)
{
  if (!l || l->iters <= 0) return 1.0;
  if (l->iter >= l->iters) return 1.0;
  return (double) l->iter / (double) l->iters;
}

void
cmacs_graph_layout_set_theta (CmacsGraphLayout *l, double theta)
{
  if (!l) return;
  l->theta = (theta < 0.0) ? 0.0 : theta;
}

double
cmacs_graph_layout_get_theta (CmacsGraphLayout *l)
{
  return l ? l->theta : 0.9;
}

gboolean
cmacs_graph_layout_bounds (CmacsGraph *g, float *min, float *max)
{
  guint n = cmacs_graph_n_nodes (g), i;
  float lo[3], hi[3];
  gboolean any = FALSE;

  if (n == 0) return FALSE;

  lo[0] = lo[1] = lo[2] =  G_MAXFLOAT;
  hi[0] = hi[1] = hi[2] = -G_MAXFLOAT;

  for (i = 0; i < n; i++)
    {
      CmacsGraphNode *nd = cmacs_graph_node (g, i);
      if (!nd || !nd->visible) continue;
      if (nd->x < lo[0]) lo[0] = nd->x;
      if (nd->y < lo[1]) lo[1] = nd->y;
      if (nd->z < lo[2]) lo[2] = nd->z;
      if (nd->x > hi[0]) hi[0] = nd->x;
      if (nd->y > hi[1]) hi[1] = nd->y;
      if (nd->z > hi[2]) hi[2] = nd->z;
      any = TRUE;
    }
  if (!any) return FALSE;

  if (min) memcpy (min, lo, sizeof lo);
  if (max) memcpy (max, hi, sizeof hi);
  return TRUE;
}

/* ── Union-find over the edge set, for component seeding ─────────── */

static guint
uf_find (guint *parent, guint i)
{
  while (parent[i] != i)
    {
      parent[i] = parent[parent[i]];    /* path halving */
      i = parent[i];
    }
  return i;
}

static void
uf_union (guint *parent, guint a, guint b)
{
  guint ra = uf_find (parent, a), rb = uf_find (parent, b);
  if (ra != rb) parent[rb] = ra;
}

/* Direction for component slot I of C, on a Fibonacci sphere (3D) or a
 * phyllotaxis disc in the XY plane (2D).  Both are deterministic and
 * spread successive slots as far apart as possible. */
static void
component_direction (int dims, guint i, guint c, float *ox, float *oy,
                     float *oz)
{
  const double golden = 2.39996322972865332;    /* pi * (3 - sqrt 5) */

  if (dims == 2)
    {
      double a = golden * (double) i;
      *ox = (float) cos (a);
      *oy = (float) sin (a);
      *oz = 0.0f;
    }
  else
    {
      double y = (c > 1)
                 ? 1.0 - 2.0 * ((double) i + 0.5) / (double) c
                 : 0.0;
      double r = sqrt (MAX (0.0, 1.0 - y * y));
      double a = golden * (double) i;
      *ox = (float) (cos (a) * r);
      *oy = (float) y;
      *oz = (float) (sin (a) * r);
    }
}

/* ── begin: seed positions and arm the schedule ───────────────────── */

void
cmacs_graph_layout_begin (CmacsGraphLayout *l, CmacsGraph *g,
                         int dims, int iters)
{
  guint n, i, pass;
  guint *parent = NULL;
  double count;

  g_return_if_fail (l != NULL && g != NULL);

  n = cmacs_graph_n_nodes (g);
  l->dims      = (dims == 2) ? 2 : 3;
  l->iter      = 0;
  l->quiet     = 0;
  l->converged = (n < 2);

  if (iters > 0)
    l->iters = iters;
  else
    /* Enough to settle without dragging on: a few hundred iterations
       covers everything up to a few thousand nodes. */
    l->iters = CLAMP (120 + (int) (n / 4), 150, 600);

  if (n == 0)
    {
      l->k = 1.0;
      l->t0 = 0.0;
      return;
    }

  /* Ideal edge length is fixed (see GRAPHCORE_K); what depends on the node
     count is the resulting cluster extent, and therefore the starting
     temperature and how hard the origin has to pull. */
  count = (double) n;
  l->k = GRAPHCORE_K;
  l->extent = l->k * ((l->dims == 2) ? sqrt (count) : cbrt (count));
  l->gravity = GRAPHCORE_GRAVITY_SCALE * cbrt (count);
  if (l->gravity < 0.05) l->gravity = 0.05;
  l->t0 = GRAPHCORE_T0_FRACTION * l->extent;

  cmacs_graph_reset_rand (g);

  /* In 2D, flatten anything inherited from a previous 3D layout. */
  if (l->dims == 2)
    for (i = 0; i < n; i++)
      {
        CmacsGraphNode *nd = cmacs_graph_node (g, i);
        nd->z = 0.0f;
      }

  /* Going the other way -- 2D to 3D -- the inherited layout is
     perfectly planar, and a plane is an EXACT equilibrium in three
     dimensions: every force's z-component cancels by symmetry, so the
     solver would keep it flat forever and the "3D" view would be a
     disc floating in space.  Detect the degenerate case and break the
     symmetry deliberately.  Only z is perturbed, so the x/y structure
     the user was already looking at carries over. */
  if (l->dims == 3 && n > 1)
    {
      float zlo = G_MAXFLOAT, zhi = -G_MAXFLOAT;

      for (i = 0; i < n; i++)
        {
          CmacsGraphNode *nd = cmacs_graph_node (g, i);
          if (!nd->placed) continue;
          if (nd->z < zlo) zlo = nd->z;
          if (nd->z > zhi) zhi = nd->z;
        }
      if (zhi >= zlo && (double) (zhi - zlo) < 0.01 * l->extent)
        for (i = 0; i < n; i++)
          {
            CmacsGraphNode *nd = cmacs_graph_node (g, i);
            if (!nd->placed) continue;
            nd->z += (cmacs_graph_rand (g) - 0.5f)
                     * (float) (l->extent * 0.5);
          }
    }

  /* Pass 1: unplaced nodes that have a placed neighbour start at that
     neighbourhood's centroid.  Repeat a few times so chains of new
     nodes fill inward from the existing layout rather than all landing
     on the origin. */
  for (pass = 0; pass < 3; pass++)
    {
      gboolean progressed = FALSE;

      for (i = 0; i < n; i++)
        {
          CmacsGraphNode *nd = cmacs_graph_node (g, i);
          const guint32 *nb;
          guint cnt = 0, j, seen = 0;
          float sx = 0, sy = 0, sz = 0;

          if (nd->placed) continue;
          nb = cmacs_graph_neighbours (g, i, NULL, &cnt);
          for (j = 0; j < cnt; j++)
            {
              CmacsGraphNode *o = cmacs_graph_node (g, nb[j]);
              if (!o || !o->placed) continue;
              sx += o->x; sy += o->y; sz += o->z;
              seen++;
            }
          if (seen == 0) continue;

          nd->x = sx / (float) seen
                  + (float) (((double) cmacs_graph_rand (g) - 0.5)
                             * l->k);
          nd->y = sy / (float) seen
                  + (float) (((double) cmacs_graph_rand (g) - 0.5)
                             * l->k);
          nd->z = (l->dims == 2)
                  ? 0.0f
                  : sz / (float) seen
                    + (float) (((double) cmacs_graph_rand (g) - 0.5)
                               * l->k);
          nd->placed = 1;
          progressed = TRUE;
        }
      if (!progressed) break;
    }

  /* Pass 2: whatever is left belongs to a component with no placed
     member at all.  Give each such component its own slot so the
     orphan notes (a mature notes tree has hundreds of unlinked
     dailies) spread out instead of piling up at the origin. */
  {
    guint m = cmacs_graph_n_edges (g);
    GHashTable *slot;
    guint n_unplaced = 0, n_comp = 0, next_slot = 0;

    for (i = 0; i < n; i++)
      if (!cmacs_graph_node (g, i)->placed) n_unplaced++;
    if (n_unplaced == 0) goto seeded;

    parent = g_new (guint, n);
    for (i = 0; i < n; i++) parent[i] = i;
    for (i = 0; i < m; i++)
      {
        CmacsGraphEdge *e = cmacs_graph_edge (g, i);
        uf_union (parent, e->a, e->b);
      }

    /* Count the components that actually need seeding. */
    slot = g_hash_table_new (NULL, NULL);
    for (i = 0; i < n; i++)
      {
        guint root;
        if (cmacs_graph_node (g, i)->placed) continue;
        root = uf_find (parent, i);
        if (!g_hash_table_contains (slot, GUINT_TO_POINTER (root + 1)))
          {
            g_hash_table_insert (slot, GUINT_TO_POINTER (root + 1),
                                 GUINT_TO_POINTER (++next_slot));
            n_comp++;
          }
      }

    {
      double spread = l->extent;

      for (i = 0; i < n; i++)
        {
          CmacsGraphNode *nd = cmacs_graph_node (g, i);
          guint root, s;
          float dx, dy, dz, jitter;
          double dist;

          if (nd->placed) continue;
          root = uf_find (parent, i);
          s = GPOINTER_TO_UINT (g_hash_table_lookup
                                (slot, GUINT_TO_POINTER (root + 1))) - 1;

          component_direction (l->dims, s, n_comp, &dx, &dy, &dz);
          /* Slot 0 sits at the origin -- normally the giant connected
             component -- and the rest ring outward. */
          dist = (s == 0)
                 ? 0.0
                 : spread * (0.35 + 0.65 * (double) s / (double) MAX (1u, n_comp));
          jitter = (float) (l->k * 1.5);

          nd->x = (float) ((double) dx * dist)
                  + (cmacs_graph_rand (g) - 0.5f) * jitter;
          nd->y = (float) ((double) dy * dist)
                  + (cmacs_graph_rand (g) - 0.5f) * jitter;
          nd->z = (l->dims == 2)
                  ? 0.0f
                  : (float) ((double) dz * dist)
                    + (cmacs_graph_rand (g) - 0.5f) * jitter;
          nd->placed = 1;
        }
    }
    g_hash_table_destroy (slot);
    g_free (parent);
  }

 seeded:
  g_array_set_size (l->disp, n * 3);
}

/* ── Barnes-Hut construction ──────────────────────────────────────── */

static gint32
bh_new_cell (GArray *cells, float cx, float cy, float cz, float half)
{
  BhCell c;
  int i;

  c.cx = cx; c.cy = cy; c.cz = cz;
  c.half = half;
  c.mx = c.my = c.mz = 0.0f;
  c.mass = 0.0f;
  c.body = -1;
  c.is_leaf = 1;
  for (i = 0; i < 8; i++) c.child[i] = -1;
  g_array_append_val (cells, c);
  return (gint32) cells->len - 1;
}

static int
bh_octant (const BhCell *c, float x, float y, float z)
{
  return (x >= c->cx ? 1 : 0) | (y >= c->cy ? 2 : 0) | (z >= c->cz ? 4 : 0);
}

static void
bh_child_centre (const BhCell *c, int oct, float *cx, float *cy, float *cz,
                 float *half)
{
  float h = c->half * 0.5f;

  *half = h;
  *cx = c->cx + ((oct & 1) ? h : -h);
  *cy = c->cy + ((oct & 2) ? h : -h);
  *cz = c->cz + ((oct & 4) ? h : -h);
}

static void
bh_insert (GArray *cells, gint32 ci, CmacsGraph *g, guint body,
           int depth)
{
  CmacsGraphNode *nd = cmacs_graph_node (g, body);
  BhCell *c;
  int oct;
  gint32 kid;

  for (;;)
    {
      c = &g_array_index (cells, BhCell, ci);

      /* Accumulate the centre-of-mass numerator on the way down. */
      c->mx += nd->x; c->my += nd->y; c->mz += nd->z;
      c->mass += 1.0f;

      if (c->is_leaf)
        {
          if (c->body < 0)
            {
              c->body = (gint32) body;
              return;
            }
          if (depth >= GRAPHCORE_BH_MAX_DEPTH)
            /* Coincident (or near-coincident) points: stop splitting
               and let the cell hold several bodies.  The repulsion
               kernel's epsilon keeps the forces finite. */
            return;

          /* Split: push the resident body one level down, then fall
             through and place the incoming one. */
          {
            guint resident = (guint) c->body;
            CmacsGraphNode *rn = cmacs_graph_node (g, resident);
            float kx, ky, kz, kh;
            int roct;

            c->body = -1;
            c->is_leaf = 0;
            roct = bh_octant (c, rn->x, rn->y, rn->z);
            bh_child_centre (c, roct, &kx, &ky, &kz, &kh);
            kid = bh_new_cell (cells, kx, ky, kz, kh);
            /* bh_new_cell may realloc; refresh C before writing. */
            c = &g_array_index (cells, BhCell, ci);
            c->child[roct] = kid;
            bh_insert (cells, kid, g, resident, depth + 1);
            c = &g_array_index (cells, BhCell, ci);
          }
        }

      oct = bh_octant (c, nd->x, nd->y, nd->z);
      if (c->child[oct] < 0)
        {
          float kx, ky, kz, kh;
          bh_child_centre (c, oct, &kx, &ky, &kz, &kh);
          kid = bh_new_cell (cells, kx, ky, kz, kh);
          c = &g_array_index (cells, BhCell, ci);
          c->child[oct] = kid;
        }
      ci = g_array_index (cells, BhCell, ci).child[oct];
      depth++;
    }
}

static void
bh_build (CmacsGraphLayout *l, CmacsGraph *g)
{
  guint n = cmacs_graph_n_nodes (g), i;
  float lo[3], hi[3], cx, cy, cz, half = 1.0f;

  g_array_set_size (l->cells, 0);
  if (n == 0) return;

  if (!cmacs_graph_layout_bounds (g, lo, hi))
    return;

  cx = 0.5f * (lo[0] + hi[0]);
  cy = 0.5f * (lo[1] + hi[1]);
  cz = 0.5f * (lo[2] + hi[2]);
  half = MAX (MAX (hi[0] - lo[0], hi[1] - lo[1]), hi[2] - lo[2]) * 0.5f;
  if (half < 1e-3f) half = 1e-3f;
  half *= 1.05f;                        /* keep every body strictly inside */

  bh_new_cell (l->cells, cx, cy, cz, half);
  for (i = 0; i < n; i++)
    {
      CmacsGraphNode *nd = cmacs_graph_node (g, i);
      if (nd->visible) bh_insert (l->cells, 0, g, i, 0);
    }
}

/* Repulsive force on node BODY from cell CI's subtree, accumulated
 * into (*fx,*fy,*fz).  k2 is k^2, the FR repulsion numerator. */
static void
bh_accumulate (CmacsGraphLayout *l, CmacsGraph *g, gint32 ci,
               guint body, double k2, float *fx, float *fy, float *fz)
{
  const BhCell *c;
  CmacsGraphNode *nd;
  float px, py, pz, dx, dy, dz;
  double d2, d, f;
  int i;

  if (ci < 0 || (guint) ci >= l->cells->len) return;
  c = &g_array_index (l->cells, BhCell, ci);
  if (c->mass <= 0.0f) return;

  nd = cmacs_graph_node (g, body);

  if (c->is_leaf)
    {
      /* A leaf can hold several coincident bodies past the depth cap;
         its centre of mass is then their average, which is the right
         thing to push away from. */
      if (c->body == (gint32) body && c->mass <= 1.0f) return;
      px = c->mx / c->mass;
      py = c->my / c->mass;
      pz = c->mz / c->mass;
    }
  else
    {
      px = c->mx / c->mass;
      py = c->my / c->mass;
      pz = c->mz / c->mass;
    }

  dx = nd->x - px;
  dy = nd->y - py;
  dz = nd->z - pz;
  d2 = (double) dx * (double) dx + (double) dy * (double) dy
       + (double) dz * (double) dz;
  d = sqrt (d2);

  if (!c->is_leaf)
    {
      /* Opening criterion.  theta == 0 never accepts, degenerating to
         an exact all-pairs sum -- the reference the tests compare
         against. */
      double s = 2.0 * (double) c->half;
      if (!(l->theta > 0.0 && d > 0.0 && s / d < l->theta))
        {
          for (i = 0; i < 8; i++)
            bh_accumulate (l, g, c->child[i], body, k2, fx, fy, fz);
          return;
        }
    }

  if (d < 1e-4)
    {
      /* Degenerate overlap: push along a deterministic axis derived
         from the node index, so coincident nodes separate reproducibly
         instead of jittering randomly. */
      double a = (double) body * 2.39996322972865332;
      dx = (float) cos (a);
      dy = (float) sin (a);
      dz = (l->dims == 2) ? 0.0f : (float) cos (a * 0.5);
      d = 1e-4;
    }

  /* FR repulsion: k^2 / d, scaled by the number of bodies represented. */
  f = k2 / d * (double) c->mass;
  *fx += (float) ((double) dx / d * f);
  *fy += (float) ((double) dy / d * f);
  *fz += (float) ((double) dz / d * f);
}

/* ── One iteration ────────────────────────────────────────────────── */

static double
layout_iteration (CmacsGraphLayout *l, CmacsGraph *g)
{
  guint n = cmacs_graph_n_nodes (g), m = cmacs_graph_n_edges (g);
  guint i;
  double k = l->k, k2 = k * k;
  double t, max_disp = 0.0;
  float *disp;

  if (n < 2) return 0.0;

  disp = &g_array_index (l->disp, float, 0);
  memset (disp, 0, sizeof (float) * n * 3);

  /* Temperature: cool along a slightly convex curve so the map takes
     its rough shape quickly and then settles gently. */
  {
    double frac = (l->iters > 0)
                  ? 1.0 - (double) l->iter / (double) l->iters
                  : 0.0;
    if (frac < 0.0) frac = 0.0;
    t = l->t0 * pow (frac, 1.5);
    if (t < 1e-6) t = 1e-6;
  }

  bh_build (l, g);

  /* Repulsion (Barnes-Hut) + origin gravity. */
  for (i = 0; i < n; i++)
    {
      CmacsGraphNode *nd = cmacs_graph_node (g, i);
      float fx = 0, fy = 0, fz = 0;

      if (!nd->visible) continue;
      bh_accumulate (l, g, 0, i, k2, &fx, &fy, &fz);

      /* Pull toward the origin: proportional to distance (a harmonic
         well, which bounds the cloud firmly) and to the square root of
         degree (so hubs seat centrally and their leaves fan out).  A
         leaf settles where n*k^2/d == gravity*d, i.e. at
         d = k*sqrt(n/gravity); a hub of degree m at 1/sqrt(m) of
         that. */
      {
        double gm = l->gravity * sqrt (1.0 + (double) nd->edge_count);

        disp[i * 3 + 0] = fx - (float) ((double) nd->x * gm);
        disp[i * 3 + 1] = fy - (float) ((double) nd->y * gm);
        disp[i * 3 + 2] = fz - (float) ((double) nd->z * gm);
      }
    }

  /* Attraction along edges: d^2 / k, weighted by edge kind. */
  for (i = 0; i < m; i++)
    {
      CmacsGraphEdge *e = cmacs_graph_edge (g, i);
      CmacsGraphNode *a = cmacs_graph_node (g, e->a);
      CmacsGraphNode *b = cmacs_graph_node (g, e->b);
      float dx, dy, dz;
      double d, f, w;

      if (!a || !b || !a->visible || !b->visible) continue;

      dx = a->x - b->x;
      dy = a->y - b->y;
      dz = a->z - b->z;
      d = sqrt ((double) dx * (double) dx + (double) dy * (double) dy
                + (double) dz * (double) dz);
      if (d < 1e-4) continue;

      w = (e->kind == CMACS_GRAPH_EDGE_SIM)
          ? (double) GRAPHCORE_W_SIM : (double) e->w;
      f = d * d / k * w;

      disp[e->a * 3 + 0] -= (float) ((double) dx / d * f);
      disp[e->a * 3 + 1] -= (float) ((double) dy / d * f);
      disp[e->a * 3 + 2] -= (float) ((double) dz / d * f);
      disp[e->b * 3 + 0] += (float) ((double) dx / d * f);
      disp[e->b * 3 + 1] += (float) ((double) dy / d * f);
      disp[e->b * 3 + 2] += (float) ((double) dz / d * f);
    }

  /* Apply, clamped to the temperature and damped by degree.  Without
     the degree damping the high-degree hubs whip around and drag the
     whole map with them. */
  for (i = 0; i < n; i++)
    {
      CmacsGraphNode *nd = cmacs_graph_node (g, i);
      double dx, dy, dz, len, scale, mass;

      if (!nd->visible || nd->pinned) continue;

      dx = disp[i * 3 + 0];
      dy = disp[i * 3 + 1];
      dz = (l->dims == 2) ? 0.0 : (double) disp[i * 3 + 2];

      mass = 1.0 + log2 (1.0 + (double) nd->edge_count);
      dx /= mass; dy /= mass; dz /= mass;

      len = sqrt (dx * dx + dy * dy + dz * dz);
      if (len < 1e-12) continue;

      scale = (len > t) ? t / len : 1.0;
      dx *= scale; dy *= scale; dz *= scale;

      nd->x += (float) dx;
      nd->y += (float) dy;
      nd->z = (l->dims == 2) ? 0.0f : nd->z + (float) dz;

      len *= scale;
      if (len > max_disp) max_disp = len;
    }

  return max_disp;
}

gboolean
cmacs_graph_layout_step (CmacsGraphLayout *l, CmacsGraph *g, int n_iters)
{
  int i;

  g_return_val_if_fail (l != NULL && g != NULL, TRUE);
  if (l->converged) return TRUE;
  if (n_iters <= 0) n_iters = 1;

  for (i = 0; i < n_iters; i++)
    {
      double moved = layout_iteration (l, g);

      l->iter++;

      /* Quiet for a few consecutive iterations means settled.  A single
         quiet pass is not enough: the very first iterations of a
         cold-started component can be near-still by accident. */
      if (moved < 1e-3 * l->k)
        {
          if (++l->quiet >= GRAPHCORE_QUIET_RUNS)
            {
              l->converged = TRUE;
              return TRUE;
            }
        }
      else
        l->quiet = 0;

      if (l->iter >= l->iters)
        {
          l->converged = TRUE;
          return TRUE;
        }
    }
  return FALSE;
}

void
cmacs_graph_layout_reheat (CmacsGraphLayout *l, double frac, int extra_iters)
{
  g_return_if_fail (l != NULL);

  if (frac <= 0.0) frac = 0.3;
  if (extra_iters <= 0) extra_iters = 120;

  /* Rewind the schedule so the cooling curve restarts at FRAC of the
     original temperature: t(iter) = t0 * (1 - iter/iters)^1.5. */
  l->iters = l->iter + extra_iters;
  l->t0 = l->t0 * frac / pow (MAX (1e-6, (double) extra_iters
                                   / (double) MAX (1, l->iters)), 1.5);
  l->quiet = 0;
  l->converged = FALSE;
}


/* ---- Closed-form placement ----------------------------------------
 *
 * Three layouts that compute a final position directly instead of
 * simulating one.  All of them write to tx/ty/tz and move nothing, and
 * all of them place only VISIBLE nodes -- a collapsed subtree has no
 * position to occupy, and including it would leave gaps in every ring.
 *
 * Determinism is a requirement, not a nicety: these are re-run on every
 * spin tick and every expand, and a layout that reshuffles under a
 * stable input would make the animation jitter.  Ordering is therefore
 * always by an explicit key (group name, then node index), never by
 * hash iteration order. */

/* Stable ordering key for placement: group name first so a group forms
 * one contiguous arc, then index so ties never reshuffle. */
static gint
place_cmp (gconstpointer pa, gconstpointer pb, gpointer user)
{
  CmacsGraph *g = user;
  guint ia = *(const guint *) pa, ib = *(const guint *) pb;
  const CmacsGraphNode *a = &g_array_index (g->nodes, CmacsGraphNode, ia);
  const CmacsGraphNode *b = &g_array_index (g->nodes, CmacsGraphNode, ib);
  int c;

  if (a->ring != b->ring) return (a->ring < b->ring) ? -1 : 1;
  c = g_strcmp0 (a->group, b->group);
  if (c) return c;
  return (ia < ib) ? -1 : (ia > ib) ? 1 : 0;
}

/* Indices of the visible nodes, in placement order. */
static GArray *
place_order (CmacsGraph *g)
{
  GArray *order = g_array_new (FALSE, FALSE, sizeof (guint));
  guint n = cmacs_graph_n_nodes (g), i;

  for (i = 0; i < n; i++)
    if (g_array_index (g->nodes, CmacsGraphNode, i).visible)
      g_array_append_val (order, i);

  g_array_sort_with_data (order, place_cmp, g);
  return order;
}

static void
place_set (CmacsGraphNode *nd, double x, double y, double z, int dims)
{
  /* A pinned node keeps where it is.  `pinned' used to mean only "the
     force solver must not move this", which was enough while the solver
     was the only thing that moved anything -- but a closed-form layout
     re-places every node from scratch, so switching layout (or any
     re-place at all) silently undid a drag.  Aiming the tween at the
     current position is what makes the pin hold through both. */
  if (nd->pinned)
    {
      nd->tx = nd->x;
      nd->ty = nd->y;
      nd->tz = nd->z;
      nd->placed = 1;
      return;
    }
  nd->tx = (float) x;
  nd->ty = (float) y;
  nd->tz = (dims == 2) ? 0.0f : (float) z;
  nd->placed = 1;
}

/* ── The plane a closed-form layout lives in ───────────────────────
 *
 * Every closed-form layout here is planar by construction: a circle, a
 * hex lattice, a set of concentric bands.  Which plane that is matters,
 * and the obvious answer is wrong.
 *
 * In 2D it is XY, because that is what "right and up" mean on a screen.
 *
 * In 3D it is the GROUND plane, XZ, with the out-of-plane axis on Y.
 * The renderer's world is Y-up and so is its orbit camera, whose drag
 * gestures are azimuth about Y and elevation from the XZ plane.  Lay a
 * disc in XY instead and those two gestures no longer match the thing
 * being looked at: the elevation drag walks the camera along the disc's
 * own plane and slams into the pole clamp edge-on, so the map presents
 * as a flat streak and the drag appears to stop for no reason.  In XZ
 * the same two gestures are "spin the galaxy" and "raise your eye above
 * it", which is the whole interaction anyone wants with a disc.
 *
 * U is the in-plane axis that reads as X on screen in 2D, V the one that
 * reads as Y, and H is the height out of the plane. */
static void
place_plane (CmacsGraphNode *nd, double u, double v, double h, int dims)
{
  if (dims == 2) place_set (nd, u, v, 0.0, dims);
  else           place_set (nd, u, h, v, dims);
}

/* Read a node's in-plane coordinates back out, whichever plane it is
   in.  Used by the fan pass, which needs the direction from the origin
   to a parent and would otherwise silently read the height axis. */
static void
plane_uv (const CmacsGraphNode *nd, int dims, double *u, double *v)
{
  *u = (double) nd->tx;
  *v = (dims == 2) ? (double) nd->ty : (double) nd->tz;
}

/* Place every visible node that has a VISIBLE parent in a disc around
 * that parent, biased outward from the origin.
 *
 * This is what an expanded department looks like: the children fan out
 * of the hub they came from, so the relationship is legible.  Spreading
 * them along the band instead -- which is what a naive "one ring, all
 * members" pass does -- loses exactly the information the expand was
 * asking for, and buries the hub among its own contents.
 *
 * Phyllotaxis (golden angle, radius as sqrt of the index) rather than
 * concentric rows: it packs evenly at any count without the caller
 * choosing a row size, and it degrades gracefully from three children
 * to three thousand.
 *
 * Returns the number of nodes it placed. */
static guint
place_children_around_parents (CmacsGraph *g, GArray *order, int dims,
                               double gap)
{
  guint n = order->len, i, placed = 0;
  GHashTable *counts;   /* parent index -> how many placed so far */
  GHashTable *totals;   /* parent index -> total children */

  counts = g_hash_table_new (g_direct_hash, g_direct_equal);
  totals = g_hash_table_new (g_direct_hash, g_direct_equal);

  /* Count first: the spread has to know the total before placing any,
     or the first child sits where the last one should. */
  for (i = 0; i < n; i++)
    {
      guint idx = g_array_index (order, guint, i);
      CmacsGraphNode *nd = &g_array_index (g->nodes, CmacsGraphNode, idx);
      if (nd->parent < 0) continue;
      {
        CmacsGraphNode *pn =
          &g_array_index (g->nodes, CmacsGraphNode, (guint) nd->parent);
        if (!pn->visible) continue;
      }
      g_hash_table_insert (totals, GINT_TO_POINTER (nd->parent),
                           GUINT_TO_POINTER (GPOINTER_TO_UINT (
                             g_hash_table_lookup (totals,
                               GINT_TO_POINTER (nd->parent))) + 1));
    }

  for (i = 0; i < n; i++)
    {
      guint idx = g_array_index (order, guint, i);
      CmacsGraphNode *nd = &g_array_index (g->nodes, CmacsGraphNode, idx);
      CmacsGraphNode *pn;
      guint seen, total;
      double px, py, len, dirx, diry, spread, a, r;

      if (nd->parent < 0) continue;
      pn = &g_array_index (g->nodes, CmacsGraphNode, (guint) nd->parent);
      if (!pn->visible) continue;

      total = GPOINTER_TO_UINT (g_hash_table_lookup (totals,
                                  GINT_TO_POINTER (nd->parent)));
      if (total == 0) total = 1;
      seen = GPOINTER_TO_UINT (g_hash_table_lookup (counts,
                                 GINT_TO_POINTER (nd->parent)));
      g_hash_table_insert (counts, GINT_TO_POINTER (nd->parent),
                           GUINT_TO_POINTER (seen + 1));

      /* Grow the disc with the count, but sub-linearly: a department of
         three should not be a dot and one of three thousand should not
         swallow its neighbours. */
      spread = gap * 0.45 * (0.6 + sqrt ((double) total) / 6.0);

      /* Outward from the origin, so a fan opens away from the centre
         rather than back across the rings it came from. */
      plane_uv (pn, dims, &px, &py);
      len = sqrt (px * px + py * py);
      if (len < 1e-6) { dirx = 1.0; diry = 0.0; }
      else            { dirx = px / len; diry = py / len; }

      a = (double) seen * 2.39996322972865332;   /* golden angle */
      r = spread * sqrt (((double) seen + 0.5) / (double) total);

      place_plane (nd,
                   px + dirx * spread * 0.75 + r * cos (a),
                   py + diry * spread * 0.75 + r * sin (a),
                   0.0, dims);
      placed++;
    }

  g_hash_table_destroy (counts);
  g_hash_table_destroy (totals);
  return placed;
}

/* CIRCLE: one concentric circle per distinct group, in first-appearance
 * order, each node evenly spaced around its own circle. */
static void
place_circle (CmacsGraphLayout *l, CmacsGraph *g, GArray *order, int dims)
{
  guint n = order->len, i, start = 0;
  guint circle = 0;

  while (start < n)
    {
      guint idx0 = g_array_index (order, guint, start);
      const gchar *grp =
        g_array_index (g->nodes, CmacsGraphNode, idx0).group;
      guint end = start;
      double r, step;

      while (end < n)
        {
          guint idx = g_array_index (order, guint, end);
          if (g_strcmp0 (g_array_index (g->nodes, CmacsGraphNode, idx).group,
                         grp) != 0)
            break;
          end++;
        }

      /* Radius grows with the circle index; the innermost circle still
         gets a non-zero radius so its members do not stack. */
      r    = l->ring_gap * (double) (circle + 1);
      step = 2.0 * G_PI / (double) MAX (1u, end - start);

      for (i = start; i < end; i++)
        {
          CmacsGraphNode *nd =
            &g_array_index (g->nodes, CmacsGraphNode,
                            g_array_index (order, guint, i));
          double a = step * (double) (i - start) + l->spin;
          /* Children are placed around their parent afterwards. */
          if (nd->parent >= 0
              && g_array_index (g->nodes, CmacsGraphNode,
                                (guint) nd->parent).visible)
            continue;
          place_plane (nd, r * cos (a), r * sin (a), 0.0, dims);
        }

      start = end;
      circle++;
    }
}

/* HEX: axial hex lattice spiralling out from the origin.
 *
 * Ring r holds 6r cells; walking the six edges of each ring in turn
 * visits them all exactly once.  Axial (q, s) converts to a pointy-top
 * pixel position with the standard basis. */
static void
place_hex (CmacsGraphLayout *l, CmacsGraph *g, GArray *order, int dims)
{
  /* The six axial steps, one per edge of a hex ring. */
  static const int DQ[6] = {  1,  0, -1, -1,  0,  1 };
  static const int DS[6] = {  0,  1,  1,  0, -1, -1 };
  const double size = GRAPHCORE_HEX_SIZE;
  guint placed = 0;
  int ring = 0;
  int q = 0, sx = 0;

  (void) l;

  while (placed < order->len)
    {
      int e, step;

      if (ring == 0)
        {
          CmacsGraphNode *nd =
            &g_array_index (g->nodes, CmacsGraphNode,
                            g_array_index (order, guint, placed));
          place_plane (nd, 0.0, 0.0, 0.0, dims);
          placed++;
          ring = 1;
          continue;
        }

      /* Start at the ring's DIR[2] corner and walk the six edges.  The
         first edge must be DIR[4], not DIR[0]: starting at r*DIR[i] the
         traversal that closes the ring begins at DIR[i+2].  Walking
         from DIR[0] instead re-visits cells, which lands two nodes on
         the same point -- caught by the lattice test. */
      q = -ring; sx = ring;
      for (e = 0; e < 6 && placed < order->len; e++)
        {
          int d = (e + 4) % 6;
          for (step = 0; step < ring && placed < order->len; step++)
            {
              CmacsGraphNode *nd =
                &g_array_index (g->nodes, CmacsGraphNode,
                                g_array_index (order, guint, placed));
              double px = size * 1.5 * (double) q;
              double py = size * sqrt (3.0) * ((double) sx + 0.5 * (double) q);
              place_plane (nd, px, py, 0.0, dims);
              placed++;
              q += DQ[d]; sx += DS[d];
            }
        }
      ring++;
    }
}

/* RINGS: concentric bands taken from node->ring, each band's members
 * spread by angle, groups kept contiguous so a department reads as one
 * wedge.  This is the ARMS layout. */
/* ── The galaxy warp ───────────────────────────────────────────────
 *
 * Concentric rings viewed in 3D are a disappointment: they are coplanar,
 * so orbiting them only proves they are flat, and the third dimension
 * buys nothing.  Lifting each node out of the plane by a smooth function
 * of WHERE IT SITS turns the same layout into a warped disc -- which is
 * what a galaxy is, and why some of it reads as "higher" than the rest.
 *
 * Two terms, and the split is the whole design:
 *
 *   The WARP is a mode-1 (integral-sign) bend: height grows with radius
 *   and varies as sin of the azimuth, so one side of the disc lifts and
 *   the opposite side drops.  Coherent, not random -- neighbours stay
 *   neighbours, a department stays a clump, and the eye reads a shape
 *   rather than scatter.  Growing with radius is what keeps the middle
 *   legible while the rim does the moving.
 *
 *   The THICKNESS is a per-node offset so members of one wedge are not
 *   perfectly coplanar.  Without it the map is a bent sheet; with it the
 *   disc has substance.  It does NOT vary with azimuth -- a real disc is
 *   thick everywhere, not only where it bends -- and it is a fraction of
 *   the same r*tan(tilt) amplitude the warp uses, so the two stay in
 *   proportion at any tilt and any scale.
 *
 * The height axis is Y in 3D and does not exist in 2D; see place_plane
 * for why a planar layout lies in the world's ground plane.
 *
 * TILT is the elevation of the warp term at its crest, in radians, and
 * there it is exact: h = r*tan(tilt) means atan(h/r) == tilt.  The
 * thickness rides on top, so a node may sit beyond it -- but by a stated
 * amount: no node can exceed atan((1 + THICKNESS) * tan(TILT)).  TILT is
 * the shape of the disc, not a per-node ceiling.  The
 * angle is the node's FINAL azimuth, spin included, so the warp is fixed
 * in world space and a spinning ring flows through it the way stars orbit
 * through a real warped disc, rather than the whole sheet rotating
 * rigidly.
 *
 * Deterministic, and keyed on the node's ID rather than its index: index
 * order churns whenever the graph is rebuilt, so hashing it would
 * reshuffle every height on refresh, which reads as the map twitching.  */

/* FNV-1a, folded to [-1, 1].  Any stable, well-mixed hash would do; this
   one is four lines and has no dependency. */
static double
graphcore_id_jitter (const gchar *id)
{
  guint32 h = 2166136261u;

  if (id == NULL) return 0.0;
  for (const gchar *p = id; *p; p++)
    {
      h ^= (guint32) (guchar) *p;
      h *= 16777619u;
    }
  return ((double) (h & 0xFFFFu) / 32767.5) - 1.0;
}

/* The warp alone, without any per-node thickness: the SURFACE the nodes
   are scattered around.  Exposed so a caller drawing on top of the disc
   -- a ring guide, a legend arc -- can trace the same shape rather than
   cutting a flat curve through it. */
static double
graphcore_galaxy_warp (CmacsGraphLayout *l, double r, double angle)
{
  double ref, t;

  if (l->galaxy_tilt <= 0.0) return 0.0;
  ref = (l->warp_ref > 1e-6) ? l->warp_ref : MAX (r, 1e-6);
  t   = r / ref;
  return ref * tan (l->galaxy_tilt)
           * pow (t, GRAPHCORE_GALAXY_WARP_POWER) * sin (angle);
}

static double
graphcore_galaxy_z (CmacsGraphLayout *l, CmacsGraphNode *nd,
                    double r, double angle)
{
  double warp, thick;

  if (l->galaxy_tilt <= 0.0) return 0.0;

  /* Two terms, two jobs.  The warp is the disc's SHAPE -- it varies with
     azimuth, so one side lifts and the other drops, and it grows faster
     than linearly with radius so that it BENDS instead of tilting.  The
     thickness is its SUBSTANCE -- azimuth-independent, because a real
     disc is thick everywhere and not only where it bends -- and stays
     linear in r so the inner disc keeps some depth of its own rather
     than collapsing to a sheet where the warp has yet to take hold. */
  warp  = graphcore_galaxy_warp (l, r, angle);
  thick = r * tan (l->galaxy_tilt) * GRAPHCORE_GALAXY_THICKNESS
            * graphcore_id_jitter (nd->id);
  return warp + thick;
}

static void
place_rings (CmacsGraphLayout *l, CmacsGraph *g, GArray *order, int dims)
{
  guint n = order->len, start = 0;
  GHashTable *root_of;   /* node index -> its top VISIBLE ancestor index */
  GHashTable *weight;    /* root index -> 1 + visible descendants shown */
  guint   band_n[GRAPHCORE_MAX_BANDS];
  double *band_r    = l->band_r;      /* published; see the struct */
  guint  *band_rows = l->band_rows;

  /* Every node's group root: the outermost visible ancestor, or itself.
     Walking up rather than trusting `parent' directly matters once more
     than one level can be open at a time -- a grandchild belongs to its
     department, not to its immediate folder. */
  root_of = g_hash_table_new (g_direct_hash, g_direct_equal);
  weight  = g_hash_table_new (g_direct_hash, g_direct_equal);

  for (guint i = 0; i < n; i++)
    {
      guint idx = g_array_index (order, guint, i);
      gint  cur = (gint) idx, guard = 0;

      /* Bounded: a cycle is refused at set_parent time, but a layout
         pass must not be the thing that discovers otherwise. */
      while (guard++ < 64)
        {
          CmacsGraphNode *nd =
            &g_array_index (g->nodes, CmacsGraphNode, (guint) cur);
          if (nd->parent < 0) break;
          if (!g_array_index (g->nodes, CmacsGraphNode,
                              (guint) nd->parent).visible)
            break;
          cur = nd->parent;
        }
      g_hash_table_insert (root_of, GUINT_TO_POINTER (idx),
                           GINT_TO_POINTER (cur));
      g_hash_table_insert (weight, GINT_TO_POINTER (cur),
                           GINT_TO_POINTER
                             (GPOINTER_TO_INT
                                (g_hash_table_lookup (weight,
                                                      GINT_TO_POINTER (cur)))
                              + 1));
    }

  /* Band geometry, sized to what each band actually holds.
     ------------------------------------------------------------------
     A fixed radius per ring only works while the rings are small.  Give
     the Memory band a thousand notes and every one of them lands on one
     circle of circumference 2*pi*12, which is not a ring of nodes but a
     solid line -- and the bands outside it are still where they were, so
     the crowding has nowhere to go.

     So each band gets as many ROWS as its population needs, and a RADIUS
     big enough that the arc length per node stays legible; bands are then
     pushed outward in turn so a fat one never grows into its neighbour. */
  {
    double prev_outer = 0.0;
    guint b;

    for (b = 0; b < GRAPHCORE_MAX_BANDS; b++)
      { band_n[b] = 0; band_r[b] = 0.0; band_rows[b] = 1; }

    for (guint i2 = 0; i2 < n; i2++)
      {
        guint8 bb = g_array_index (g->nodes, CmacsGraphNode,
                                   g_array_index (order, guint, i2)).ring;
        if (bb < GRAPHCORE_MAX_BANDS) band_n[bb]++;
      }

    for (b = 0; b < GRAPHCORE_MAX_BANDS; b++)
      {
        double needed, base, thick;
        guint rows;

        if (band_n[b] == 0) continue;

        /* Rows grow with the square root of population and are capped:
           past ten the band stops reading as a ring and starts reading
           as a disc. */
        rows = (guint) CLAMP (floor (sqrt ((double) band_n[b] / 12.0) + 0.5),
                              1.0, 10.0);
        band_rows[b] = rows;

        /* Radius that leaves every node about GRAPHCORE_NODE_ARC of arc
           to itself, given that many rows to spread over. */
        needed = (double) band_n[b] * GRAPHCORE_NODE_ARC
                   / (2.0 * G_PI * (double) rows);
        base   = l->ring_gap * (double) (b + 1);
        thick  = (double) rows * GRAPHCORE_ROW_GAP;

        band_r[b] = MAX (MAX (base, needed),
                         prev_outer + l->ring_gap * 0.55);
        prev_outer = band_r[b] + thick;
      }

    /* The warp is normalised against the disc's own outer edge, so the
       shape is the same whatever the ring gap or the population -- and
       so TILT keeps meaning "the elevation at the rim" rather than
       drifting with how many notes happen to exist. */
    l->warp_ref = prev_outer;
  }

  /* `order' is already sorted by ring, so each band is one run. */
  while (start < n)
    {
      guint idx0 = g_array_index (order, guint, start);
      guint8 band = g_array_index (g->nodes, CmacsGraphNode, idx0).ring;
      guint end = start, i;
      double r, thickness, dir, total_w = 0.0, cursor;
      guint band_row_n;
      GArray *roots;

      while (end < n
             && g_array_index (g->nodes, CmacsGraphNode,
                               g_array_index (order, guint, end)).ring == band)
        end++;

      band_row_n = (band < GRAPHCORE_MAX_BANDS) ? band_rows[band] : 1;
      r          = (band < GRAPHCORE_MAX_BANDS)
                     ? band_r[band] : l->ring_gap * (double) (band + 1);
      thickness  = (double) band_row_n * GRAPHCORE_ROW_GAP;
      /* Alternate bands counter-rotate, so spinning does not slide every
         ring the same way and the motion reads as depth. */
      dir        = (band & 1) ? -1.0 : 1.0;

      /* The roots present in this band, in `order' sequence so the
         result is deterministic. */
      roots = g_array_new (FALSE, FALSE, sizeof (guint));
      for (i = start; i < end; i++)
        {
          guint idx = g_array_index (order, guint, i);
          gint  rt  = GPOINTER_TO_INT (g_hash_table_lookup
                                         (root_of, GUINT_TO_POINTER (idx)));
          if ((guint) rt == idx)
            {
              g_array_append_val (roots, idx);
              total_w += (double) GPOINTER_TO_INT
                           (g_hash_table_lookup (weight,
                                                 GINT_TO_POINTER (rt)));
            }
        }

      if (roots->len == 0 || total_w <= 0.0)
        {
          g_array_free (roots, TRUE);
          start = end;
          continue;
        }

      /* Each department gets a contiguous wedge sized by how much it
         holds.  Equal wedges would give a department of four notes the
         same arc as one of four thousand, which is how "show me
         everything" turns into an unreadable smear: the big group's
         members pile on top of each other while the small one's float
         alone in empty space. */
      cursor = 0.0;
      for (guint k = 0; k < roots->len; k++)
        {
          guint root = g_array_index (roots, guint, k);
          double w = (double) GPOINTER_TO_INT
                       (g_hash_table_lookup (weight, GINT_TO_POINTER (root)));
          double span = 2.0 * G_PI * (w / total_w);
          double a0 = cursor + l->spin * dir;
          double mid = a0 + span * 0.5;
          CmacsGraphNode *hub =
            &g_array_index (g->nodes, CmacsGraphNode, root);
          guint kids = 0, cols, rows;

          cursor += span;

          place_plane (hub, r * cos (mid), r * sin (mid),
                       graphcore_galaxy_z (l, hub, r, mid), dims);

          /* Count this root's members (excluding itself) to shape the
             lattice they sit in. */
          for (i = start; i < end; i++)
            {
              guint idx = g_array_index (order, guint, i);
              if (idx != root
                  && (guint) GPOINTER_TO_INT
                       (g_hash_table_lookup (root_of,
                                             GUINT_TO_POINTER (idx))) == root)
                kids++;
            }
          if (kids == 0) continue;

          /* Rows come from the BAND, not the department: neighbouring
             wedges that each chose their own depth would leave ragged
             steps between them where the ring should be continuous. */
          rows = MAX (1u, MIN (band_row_n, kids));
          cols = (kids + rows - 1) / rows;

          {
            guint seen = 0;
            /* Keep a margin at both edges so neighbouring departments
               stay visually separate. */
            double m = span * 0.08;
            double usable = span - 2.0 * m;

            for (i = start; i < end; i++)
              {
                guint idx = g_array_index (order, guint, i);
                CmacsGraphNode *nd;
                guint row, col;
                double a, rr;

                if (idx == root) continue;
                if ((guint) GPOINTER_TO_INT
                      (g_hash_table_lookup (root_of,
                                            GUINT_TO_POINTER (idx))) != root)
                  continue;

                nd  = &g_array_index (g->nodes, CmacsGraphNode, idx);
                row = seen / cols;
                col = seen % cols;
                seen++;

                a = a0 + m + ((double) col + 0.5) / (double) cols * usable;
                /* Just OUTSIDE the hub rather than straddling it: the
                   group then reads as hanging off its department, and
                   an expand animates outward, which is the direction
                   the gesture implies. */
                rr = r + GRAPHCORE_ROW_GAP * 0.9
                       + thickness * (((double) row + 0.5) / (double) rows);
                place_plane (nd, rr * cos (a), rr * sin (a),
                             graphcore_galaxy_z (l, nd, rr, a), dims);
              }
          }
        }

      g_array_free (roots, TRUE);
      start = end;
    }

  g_hash_table_destroy (root_of);
  g_hash_table_destroy (weight);
}

void
cmacs_graph_layout_place (CmacsGraphLayout *l, CmacsGraph *g,
                          CmacsGraphLayoutKind kind, int dims)
{
  GArray *order;

  g_return_if_fail (l != NULL);
  g_return_if_fail (g != NULL);

  l->kind = kind;
  l->dims = (dims == 2) ? 2 : 3;

  if (kind == CMACS_GRAPH_LAYOUT_FORCE)
    {
      /* Nothing closed-form to compute: the solver owns this one.  Aim
         every node at where it already is, so a caller that tweens
         unconditionally does not drag the graph to the origin. */
      guint n = cmacs_graph_n_nodes (g), i;
      for (i = 0; i < n; i++)
        {
          CmacsGraphNode *nd = &g_array_index (g->nodes, CmacsGraphNode, i);
          nd->tx = nd->x; nd->ty = nd->y; nd->tz = nd->z;
        }
      return;
    }

  /* A published band radius belongs to the layout that produced it.
     Leaving RINGS' radii up while CIRCLE or HEX is showing would have a
     ring guide drawn around a hex lattice, at a radius nothing is at. */
  if (kind != CMACS_GRAPH_LAYOUT_RINGS)
    {
      guint b;
      for (b = 0; b < GRAPHCORE_MAX_BANDS; b++)
        { l->band_r[b] = 0.0; l->band_rows[b] = 1; }
    }

  order = place_order (g);
  switch (kind)
    {
    case CMACS_GRAPH_LAYOUT_CIRCLE: place_circle (l, g, order, l->dims); break;
    case CMACS_GRAPH_LAYOUT_HEX:    place_hex    (l, g, order, l->dims); break;
    case CMACS_GRAPH_LAYOUT_RINGS:  place_rings  (l, g, order, l->dims); break;
    default: break;
    }

  /* CIRCLE gets the fan pass: anything with a visible parent is placed
     around it rather than spread along the ring.  RINGS does its own,
     wedge-aware placement -- a fan sized independently of the wedge it
     sits in would overflow into the neighbouring department the moment
     a big group opened.  HEX is a lattice by definition, so it is left
     alone entirely. */
  if (kind == CMACS_GRAPH_LAYOUT_CIRCLE)
    place_children_around_parents (g, order, l->dims, l->ring_gap);

  g_array_free (order, TRUE);

  /* A closed-form layout is final by definition; leaving the solver
     armed would let a stray step() pull it apart. */
  l->converged = TRUE;
  l->quiet     = GRAPHCORE_QUIET_RUNS;
}

void
cmacs_graph_layout_snap (CmacsGraph *g)
{
  guint n, i;

  g_return_if_fail (g != NULL);
  n = cmacs_graph_n_nodes (g);
  for (i = 0; i < n; i++)
    {
      CmacsGraphNode *nd = &g_array_index (g->nodes, CmacsGraphNode, i);
      nd->x = nd->tx; nd->y = nd->ty; nd->z = nd->tz;
    }
}

void
cmacs_graph_layout_set_spin (CmacsGraphLayout *l, double radians)
{
  g_return_if_fail (l != NULL);
  l->spin = radians;
}

double
cmacs_graph_layout_get_spin (CmacsGraphLayout *l)
{
  return l ? l->spin : 0.0;
}

void
cmacs_graph_layout_set_ring_gap (CmacsGraphLayout *l, double gap)
{
  g_return_if_fail (l != NULL);
  if (gap > 0.0) l->ring_gap = gap;
}

double
cmacs_graph_layout_get_ring_gap (CmacsGraphLayout *l)
{
  return l ? l->ring_gap : GRAPHCORE_RING_GAP;
}

void
cmacs_graph_layout_set_galaxy_tilt (CmacsGraphLayout *l, double radians)
{
  if (!l) return;
  /* Clamped below a right angle: at 90 degrees tan blows up and the
     "disc" becomes a line through the pole. */
  l->galaxy_tilt = CLAMP (radians, 0.0, G_PI * 0.45);
}

double
cmacs_graph_layout_get_galaxy_tilt (CmacsGraphLayout *l)
{
  return l ? l->galaxy_tilt : 0.0;
}

double
cmacs_graph_layout_band_radius (CmacsGraphLayout *l, guint band)
{
  if (!l || band >= GRAPHCORE_MAX_BANDS) return 0.0;
  return l->band_r[band];
}

double
cmacs_graph_layout_band_depth (CmacsGraphLayout *l, guint band)
{
  if (!l || band >= GRAPHCORE_MAX_BANDS) return 0.0;
  if (l->band_r[band] <= 0.0) return 0.0;
  /* What place_rings spends on members: the gap that lifts them clear of
     the hub, plus one row gap per row. */
  return GRAPHCORE_ROW_GAP * (0.9 + (double) l->band_rows[band]);
}

double
cmacs_graph_layout_warp_height (CmacsGraphLayout *l, double r, double angle)
{
  if (!l) return 0.0;
  return graphcore_galaxy_warp (l, r, angle);
}

CmacsGraphLayoutKind
cmacs_graph_layout_get_kind (CmacsGraphLayout *l)
{
  return l ? l->kind : CMACS_GRAPH_LAYOUT_FORCE;
}

/* ---- Tweening ------------------------------------------------------ */

void
cmacs_graph_layout_tween_begin (CmacsGraphLayout *l, CmacsGraph *g, int frames)
{
  guint n, i;

  g_return_if_fail (l != NULL);
  g_return_if_fail (g != NULL);

  n = cmacs_graph_n_nodes (g);

  if (frames <= 0)
    {
      cmacs_graph_layout_snap (g);
      l->tween_frame = l->tween_frames = 0;
      return;
    }

  /* Snapshot from where the nodes ARE, not from where a previous tween
     started: interrupting a transition half way must continue from the
     current position, not rewind to the old one. */
  for (i = 0; i < n; i++)
    {
      CmacsGraphNode *nd = &g_array_index (g->nodes, CmacsGraphNode, i);
      nd->sx = nd->x; nd->sy = nd->y; nd->sz = nd->z;
    }

  l->tween_frame  = 0;
  l->tween_frames = frames;
}

gboolean
cmacs_graph_layout_tween_step (CmacsGraphLayout *l, CmacsGraph *g)
{
  guint n, i;
  double t, e;

  g_return_val_if_fail (l != NULL, TRUE);
  g_return_val_if_fail (g != NULL, TRUE);

  if (l->tween_frames <= 0) return TRUE;

  l->tween_frame++;
  t = (double) l->tween_frame / (double) l->tween_frames;
  if (t > 1.0) t = 1.0;

  /* Ease-in-out cubic.  A linear tween starts and stops abruptly, which
     reads as a jump-cut rather than as motion. */
  e = (t < 0.5) ? (4.0 * t * t * t)
                : (1.0 - pow (-2.0 * t + 2.0, 3.0) / 2.0);

  n = cmacs_graph_n_nodes (g);
  for (i = 0; i < n; i++)
    {
      CmacsGraphNode *nd = &g_array_index (g->nodes, CmacsGraphNode, i);
      nd->x = (float) ((double) nd->sx
                       + ((double) nd->tx - (double) nd->sx) * e);
      nd->y = (float) ((double) nd->sy
                       + ((double) nd->ty - (double) nd->sy) * e);
      nd->z = (float) ((double) nd->sz
                       + ((double) nd->tz - (double) nd->sz) * e);
    }

  if (l->tween_frame >= l->tween_frames)
    {
      /* Land exactly on the target.  Accumulated float error would
         otherwise leave the graph a hair off its own layout, which
         shows up as drift after repeated switches. */
      cmacs_graph_layout_snap (g);
      l->tween_frame = l->tween_frames = 0;
      return TRUE;
    }
  return FALSE;
}

gboolean
cmacs_graph_layout_tweening (CmacsGraphLayout *l)
{
  return l && l->tween_frames > 0;
}

double
cmacs_graph_layout_tween_progress (CmacsGraphLayout *l)
{
  if (!l || l->tween_frames <= 0) return 1.0;
  return (double) l->tween_frame / (double) l->tween_frames;
}

#endif /* HAVE_CMACS_GRAPHCORE */
