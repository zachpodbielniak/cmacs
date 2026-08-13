/* cmacs-roamgraph-layout.c --- force-directed graph layout.
 *
 * Copyright (C) 2026 Zach Podbielniak
 * SPDX-License-Identifier: AGPL-3.0-or-later
 *
 * See cmacs-roamgraph-layout.h for the contract and the rationale.
 * Pure C -- no "lisp.h", no <libregnum.h>. */

#include <config.h>

#ifdef HAVE_CMACS_ROAMGRAPH

#include "cmacs-roamgraph-layout.h"

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
#define ROAM_K            3.0

/* Initial temperature as a fraction of the graph's nominal extent. */
#define ROAM_T0_FRACTION  0.10

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
#define ROAM_GRAVITY_SCALE 0.25

/* Similarity edges are a hint, not topology: they nudge, they must not
 * dominate the real link structure. */
#define ROAM_W_SIM        0.35f

/* Convergence: this many consecutive iterations below the threshold. */
#define ROAM_QUIET_RUNS   3

/* Octree recursion cap.  Coincident points would otherwise split
 * forever; past this depth a cell simply accumulates mass. */
#define ROAM_BH_MAX_DEPTH 24

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

struct CmacsRoamLayout
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
};

CmacsRoamLayout *
cmacs_roam_layout_new (void)
{
  CmacsRoamLayout *l = g_new0 (CmacsRoamLayout, 1);

  l->dims      = 3;
  l->theta     = 0.9;
  l->converged = TRUE;      /* nothing armed yet */
  l->cells     = g_array_new (FALSE, FALSE, sizeof (BhCell));
  l->disp      = g_array_new (FALSE, TRUE, sizeof (float));
  return l;
}

void
cmacs_roam_layout_free (CmacsRoamLayout *l)
{
  if (!l) return;
  if (l->cells) g_array_free (l->cells, TRUE);
  if (l->disp)  g_array_free (l->disp, TRUE);
  g_free (l);
}

int
cmacs_roam_layout_dims (CmacsRoamLayout *l)
{
  return l ? l->dims : 3;
}

gboolean
cmacs_roam_layout_converged (CmacsRoamLayout *l)
{
  return l ? l->converged : TRUE;
}

double
cmacs_roam_layout_progress (CmacsRoamLayout *l)
{
  if (!l || l->iters <= 0) return 1.0;
  if (l->iter >= l->iters) return 1.0;
  return (double) l->iter / (double) l->iters;
}

void
cmacs_roam_layout_set_theta (CmacsRoamLayout *l, double theta)
{
  if (!l) return;
  l->theta = (theta < 0.0) ? 0.0 : theta;
}

double
cmacs_roam_layout_get_theta (CmacsRoamLayout *l)
{
  return l ? l->theta : 0.9;
}

gboolean
cmacs_roam_layout_bounds (CmacsRoamGraph *g, float *min, float *max)
{
  guint n = cmacs_roam_graph_n_nodes (g), i;
  float lo[3], hi[3];
  gboolean any = FALSE;

  if (n == 0) return FALSE;

  lo[0] = lo[1] = lo[2] =  G_MAXFLOAT;
  hi[0] = hi[1] = hi[2] = -G_MAXFLOAT;

  for (i = 0; i < n; i++)
    {
      CmacsRoamNode *nd = cmacs_roam_graph_node (g, i);
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
cmacs_roam_layout_begin (CmacsRoamLayout *l, CmacsRoamGraph *g,
                         int dims, int iters)
{
  guint n, i, pass;
  guint *parent = NULL;
  double count;

  g_return_if_fail (l != NULL && g != NULL);

  n = cmacs_roam_graph_n_nodes (g);
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

  /* Ideal edge length is fixed (see ROAM_K); what depends on the node
     count is the resulting cluster extent, and therefore the starting
     temperature and how hard the origin has to pull. */
  count = (double) n;
  l->k = ROAM_K;
  l->extent = l->k * ((l->dims == 2) ? sqrt (count) : cbrt (count));
  l->gravity = ROAM_GRAVITY_SCALE * cbrt (count);
  if (l->gravity < 0.05) l->gravity = 0.05;
  l->t0 = ROAM_T0_FRACTION * l->extent;

  cmacs_roam_graph_reset_rand (g);

  /* In 2D, flatten anything inherited from a previous 3D layout. */
  if (l->dims == 2)
    for (i = 0; i < n; i++)
      {
        CmacsRoamNode *nd = cmacs_roam_graph_node (g, i);
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
          CmacsRoamNode *nd = cmacs_roam_graph_node (g, i);
          if (!nd->placed) continue;
          if (nd->z < zlo) zlo = nd->z;
          if (nd->z > zhi) zhi = nd->z;
        }
      if (zhi >= zlo && (double) (zhi - zlo) < 0.01 * l->extent)
        for (i = 0; i < n; i++)
          {
            CmacsRoamNode *nd = cmacs_roam_graph_node (g, i);
            if (!nd->placed) continue;
            nd->z += (cmacs_roam_graph_rand (g) - 0.5f)
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
          CmacsRoamNode *nd = cmacs_roam_graph_node (g, i);
          const guint32 *nb;
          guint cnt = 0, j, seen = 0;
          float sx = 0, sy = 0, sz = 0;

          if (nd->placed) continue;
          nb = cmacs_roam_graph_neighbours (g, i, NULL, &cnt);
          for (j = 0; j < cnt; j++)
            {
              CmacsRoamNode *o = cmacs_roam_graph_node (g, nb[j]);
              if (!o || !o->placed) continue;
              sx += o->x; sy += o->y; sz += o->z;
              seen++;
            }
          if (seen == 0) continue;

          nd->x = sx / (float) seen
                  + (float) (((double) cmacs_roam_graph_rand (g) - 0.5)
                             * l->k);
          nd->y = sy / (float) seen
                  + (float) (((double) cmacs_roam_graph_rand (g) - 0.5)
                             * l->k);
          nd->z = (l->dims == 2)
                  ? 0.0f
                  : sz / (float) seen
                    + (float) (((double) cmacs_roam_graph_rand (g) - 0.5)
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
    guint m = cmacs_roam_graph_n_edges (g);
    GHashTable *slot;
    guint n_unplaced = 0, n_comp = 0, next_slot = 0;

    for (i = 0; i < n; i++)
      if (!cmacs_roam_graph_node (g, i)->placed) n_unplaced++;
    if (n_unplaced == 0) goto seeded;

    parent = g_new (guint, n);
    for (i = 0; i < n; i++) parent[i] = i;
    for (i = 0; i < m; i++)
      {
        CmacsRoamEdge *e = cmacs_roam_graph_edge (g, i);
        uf_union (parent, e->a, e->b);
      }

    /* Count the components that actually need seeding. */
    slot = g_hash_table_new (NULL, NULL);
    for (i = 0; i < n; i++)
      {
        guint root;
        if (cmacs_roam_graph_node (g, i)->placed) continue;
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
          CmacsRoamNode *nd = cmacs_roam_graph_node (g, i);
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
                  + (cmacs_roam_graph_rand (g) - 0.5f) * jitter;
          nd->y = (float) ((double) dy * dist)
                  + (cmacs_roam_graph_rand (g) - 0.5f) * jitter;
          nd->z = (l->dims == 2)
                  ? 0.0f
                  : (float) ((double) dz * dist)
                    + (cmacs_roam_graph_rand (g) - 0.5f) * jitter;
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
bh_insert (GArray *cells, gint32 ci, CmacsRoamGraph *g, guint body,
           int depth)
{
  CmacsRoamNode *nd = cmacs_roam_graph_node (g, body);
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
          if (depth >= ROAM_BH_MAX_DEPTH)
            /* Coincident (or near-coincident) points: stop splitting
               and let the cell hold several bodies.  The repulsion
               kernel's epsilon keeps the forces finite. */
            return;

          /* Split: push the resident body one level down, then fall
             through and place the incoming one. */
          {
            guint resident = (guint) c->body;
            CmacsRoamNode *rn = cmacs_roam_graph_node (g, resident);
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
bh_build (CmacsRoamLayout *l, CmacsRoamGraph *g)
{
  guint n = cmacs_roam_graph_n_nodes (g), i;
  float lo[3], hi[3], cx, cy, cz, half = 1.0f;

  g_array_set_size (l->cells, 0);
  if (n == 0) return;

  if (!cmacs_roam_layout_bounds (g, lo, hi))
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
      CmacsRoamNode *nd = cmacs_roam_graph_node (g, i);
      if (nd->visible) bh_insert (l->cells, 0, g, i, 0);
    }
}

/* Repulsive force on node BODY from cell CI's subtree, accumulated
 * into (*fx,*fy,*fz).  k2 is k^2, the FR repulsion numerator. */
static void
bh_accumulate (CmacsRoamLayout *l, CmacsRoamGraph *g, gint32 ci,
               guint body, double k2, float *fx, float *fy, float *fz)
{
  const BhCell *c;
  CmacsRoamNode *nd;
  float px, py, pz, dx, dy, dz;
  double d2, d, f;
  int i;

  if (ci < 0 || (guint) ci >= l->cells->len) return;
  c = &g_array_index (l->cells, BhCell, ci);
  if (c->mass <= 0.0f) return;

  nd = cmacs_roam_graph_node (g, body);

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
layout_iteration (CmacsRoamLayout *l, CmacsRoamGraph *g)
{
  guint n = cmacs_roam_graph_n_nodes (g), m = cmacs_roam_graph_n_edges (g);
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
      CmacsRoamNode *nd = cmacs_roam_graph_node (g, i);
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
      CmacsRoamEdge *e = cmacs_roam_graph_edge (g, i);
      CmacsRoamNode *a = cmacs_roam_graph_node (g, e->a);
      CmacsRoamNode *b = cmacs_roam_graph_node (g, e->b);
      float dx, dy, dz;
      double d, f, w;

      if (!a || !b || !a->visible || !b->visible) continue;

      dx = a->x - b->x;
      dy = a->y - b->y;
      dz = a->z - b->z;
      d = sqrt ((double) dx * (double) dx + (double) dy * (double) dy
                + (double) dz * (double) dz);
      if (d < 1e-4) continue;

      w = (e->kind == CMACS_ROAM_EDGE_SIM)
          ? (double) ROAM_W_SIM : (double) e->w;
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
      CmacsRoamNode *nd = cmacs_roam_graph_node (g, i);
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
cmacs_roam_layout_step (CmacsRoamLayout *l, CmacsRoamGraph *g, int n_iters)
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
          if (++l->quiet >= ROAM_QUIET_RUNS)
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
cmacs_roam_layout_reheat (CmacsRoamLayout *l, double frac, int extra_iters)
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

#endif /* HAVE_CMACS_ROAMGRAPH */
