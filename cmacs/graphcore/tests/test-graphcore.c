/*
 * Copyright (C) 2026 Zach Podbielniak
 * SPDX-License-Identifier: AGPL-3.0-or-later
 */

/* test-graphcore.c --- unit tests for the shared graph model and layout
 * solver.  No Emacs, no GL, no display: graphcore includes neither
 * "lisp.h" nor <libregnum.h>, so all of this runs anywhere, including a
 * headless CI box.  That is the whole reason the layout maths is in its
 * own translation unit.
 *
 * Run via `make -C cmacs/graphcore/tests check'. */

#include "cmacs-graphcore-graph.h"
#include "cmacs-graphcore-layout.h"

#include <glib.h>
#include <math.h>
#include <string.h>

/* ---- helpers ------------------------------------------------------ */

/* A graph of N nodes named "n0".."n<N-1>", no edges, finalized. */
static CmacsGraph *
mk_nodes (guint n)
{
  CmacsGraph *g = cmacs_graph_new (1234);
  guint i;

  cmacs_graph_begin_update (g);
  for (i = 0; i < n; i++)
    {
      gchar *id = g_strdup_printf ("n%u", i);
      cmacs_graph_add_node (g, id, id, NULL, NULL, 0, 1, 0xFFFFFFFFu);
      g_free (id);
    }
  cmacs_graph_finalize (g);
  return g;
}

static CmacsGraphNode *
node_by_id (CmacsGraph *g, const char *id)
{
  gint i = cmacs_graph_index_of (g, id);
  return (i < 0) ? NULL : cmacs_graph_node (g, (guint) i);
}

/* ---- graph store -------------------------------------------------- */

static void
test_graph_add_and_lookup (void)
{
  CmacsGraph *g = mk_nodes (3);

  g_assert_cmpuint (cmacs_graph_n_nodes (g), ==, 3);
  g_assert_cmpint (cmacs_graph_index_of (g, "n0"), ==, 0);
  g_assert_cmpint (cmacs_graph_index_of (g, "n2"), ==, 2);
  /* An unknown id is -1, not 0: 0 is a perfectly good node. */
  g_assert_cmpint (cmacs_graph_index_of (g, "nope"), ==, -1);
  cmacs_graph_free (g);
}

static void
test_graph_duplicate_id_is_first_wins (void)
{
  CmacsGraph *g = cmacs_graph_new (1);
  gint a, b;

  cmacs_graph_begin_update (g);
  a = cmacs_graph_add_node (g, "dup", "first", NULL, NULL, 0, 1, 0);
  b = cmacs_graph_add_node (g, "dup", "second", NULL, NULL, 0, 1, 0);
  cmacs_graph_finalize (g);

  g_assert_cmpint (a, ==, b);
  g_assert_cmpuint (cmacs_graph_n_nodes (g), ==, 1);
  g_assert_cmpstr (cmacs_graph_node (g, 0)->title, ==, "first");
  cmacs_graph_free (g);
}

/* The regression this file exists for as much as any: overflow used to
 * return 0, which silently aliased every excess node onto node 0. */
static void
test_graph_overflow_returns_minus_one (void)
{
  CmacsGraph *g = cmacs_graph_new (1);
  gint last = 0;
  guint i;
  const guint cap = 20000;   /* GRAPHCORE_MAX_NODES */

  cmacs_graph_begin_update (g);
  for (i = 0; i < cap + 8; i++)
    {
      gchar *id = g_strdup_printf ("n%u", i);
      last = cmacs_graph_add_node (g, id, id, NULL, NULL, 0, 1, 0);
      g_free (id);
      if (i < cap)
        g_assert_cmpint (last, ==, (gint) i);
      else
        g_assert_cmpint (last, ==, -1);   /* dropped, not aliased */
    }
  cmacs_graph_finalize (g);
  g_assert_cmpuint (cmacs_graph_n_nodes (g), ==, cap);
  cmacs_graph_free (g);
}

static void
test_graph_edges_sanitised (void)
{
  CmacsGraph *g = cmacs_graph_new (7);

  cmacs_graph_begin_update (g);
  cmacs_graph_add_node (g, "a", "a", NULL, NULL, 0, 1, 0);
  cmacs_graph_add_node (g, "b", "b", NULL, NULL, 0, 1, 0);

  g_assert_true  (cmacs_graph_add_edge (g, "a", "b", CMACS_GRAPH_EDGE_ID, 1.0f));
  /* Same unordered pair + kind: one spring, not two. */
  g_assert_false (cmacs_graph_add_edge (g, "b", "a", CMACS_GRAPH_EDGE_ID, 1.0f));
  g_assert_false (cmacs_graph_add_edge (g, "a", "a", CMACS_GRAPH_EDGE_ID, 1.0f));
  /* Dangling endpoints are normal in a live notes tree. */
  g_assert_false (cmacs_graph_add_edge (g, "a", "ghost", CMACS_GRAPH_EDGE_ID, 1.0f));
  cmacs_graph_finalize (g);

  g_assert_cmpuint (cmacs_graph_n_edges (g), ==, 1);
  cmacs_graph_free (g);
}

static void
test_graph_rebuild_keeps_positions (void)
{
  CmacsGraph *g = mk_nodes (4);
  float x, y, z;

  cmacs_graph_node (g, 0)->x = 4.0f;
  cmacs_graph_node (g, 0)->y = -2.0f;
  cmacs_graph_node (g, 0)->z = 1.5f;
  x = cmacs_graph_node (g, 0)->x;
  y = cmacs_graph_node (g, 0)->y;
  z = cmacs_graph_node (g, 0)->z;

  /* A refresh must not teleport the whole layout. */
  cmacs_graph_begin_update (g);
  {
    guint i;
    for (i = 0; i < 4; i++)
      {
        gchar *id = g_strdup_printf ("n%u", i);
        cmacs_graph_add_node (g, id, id, NULL, NULL, 0, 1, 0);
        g_free (id);
      }
  }
  cmacs_graph_finalize (g);

  g_assert_cmpfloat (cmacs_graph_node (g, 0)->x, ==, x);
  g_assert_cmpfloat (cmacs_graph_node (g, 0)->y, ==, y);
  g_assert_cmpfloat (cmacs_graph_node (g, 0)->z, ==, z);
  cmacs_graph_free (g);
}

/* ---- hierarchy ---------------------------------------------------- */

/* Build "root" with C children, each child with GC grandchildren. */
static CmacsGraph *
mk_tree (guint children, guint grandchildren)
{
  CmacsGraph *g = cmacs_graph_new (99);
  guint c, k;

  cmacs_graph_begin_update (g);
  cmacs_graph_add_node (g, "root", "root", NULL, NULL, 0, 1, 0);
  for (c = 0; c < children; c++)
    {
      gchar *cid = g_strdup_printf ("c%u", c);
      cmacs_graph_add_node (g, cid, cid, NULL, NULL, 0, 1, 0);
      for (k = 0; k < grandchildren; k++)
        {
          gchar *gid = g_strdup_printf ("c%u.g%u", c, k);
          cmacs_graph_add_node (g, gid, gid, NULL, NULL, 0, 1, 0);
          g_free (gid);
        }
      g_free (cid);
    }

  /* Parents are indices, so set them before finalize. */
  for (c = 0; c < children; c++)
    {
      gchar *cid = g_strdup_printf ("c%u", c);
      gint ci = cmacs_graph_index_of (g, cid);
      cmacs_graph_set_parent (g, (guint) ci, 0);
      for (k = 0; k < grandchildren; k++)
        {
          gchar *gid = g_strdup_printf ("c%u.g%u", c, k);
          gint gi = cmacs_graph_index_of (g, gid);
          cmacs_graph_set_parent (g, (guint) gi, ci);
          g_free (gid);
        }
      g_free (cid);
    }
  cmacs_graph_finalize (g);
  return g;
}

static void
test_hierarchy_absent_by_default (void)
{
  CmacsGraph *g = mk_nodes (5);
  guint i;

  /* A graph that never sets a parent behaves exactly as before: every
     node a visible root with no descendants. */
  for (i = 0; i < 5; i++)
    {
      g_assert_cmpint (cmacs_graph_node (g, i)->parent, ==, -1);
      g_assert_cmpuint (cmacs_graph_node (g, i)->descendants, ==, 0);
      g_assert_cmpuint (cmacs_graph_node (g, i)->visible, ==, 1);
    }
  g_assert_cmpuint (cmacs_graph_n_visible (g), ==, 5);
  cmacs_graph_free (g);
}

static void
test_hierarchy_descendant_counts (void)
{
  CmacsGraph *g = mk_tree (3, 4);   /* 1 + 3 + 12 = 16 nodes */

  g_assert_cmpuint (cmacs_graph_n_nodes (g), ==, 16);
  g_assert_cmpuint (node_by_id (g, "root")->descendants, ==, 15);
  g_assert_cmpuint (node_by_id (g, "c0")->descendants,   ==, 4);
  g_assert_cmpuint (node_by_id (g, "c0.g0")->descendants, ==, 0);
  cmacs_graph_free (g);
}

static void
test_hierarchy_collapse_hides_subtree (void)
{
  CmacsGraph *g = mk_tree (3, 4);
  gint c0 = cmacs_graph_index_of (g, "c0");

  g_assert_cmpuint (cmacs_graph_n_visible (g), ==, 16);

  g_assert_true (cmacs_graph_set_collapsed (g, (guint) c0, TRUE));
  /* c0 itself stays visible; its four grandchildren do not. */
  g_assert_cmpuint (node_by_id (g, "c0")->visible, ==, 1);
  g_assert_cmpuint (node_by_id (g, "c0.g0")->visible, ==, 0);
  g_assert_cmpuint (cmacs_graph_n_visible (g), ==, 12);

  /* Setting the same value again reports "no change". */
  g_assert_false (cmacs_graph_set_collapsed (g, (guint) c0, TRUE));

  /* And it round-trips exactly. */
  g_assert_true (cmacs_graph_set_collapsed (g, (guint) c0, FALSE));
  g_assert_cmpuint (cmacs_graph_n_visible (g), ==, 16);
  cmacs_graph_free (g);
}

static void
test_hierarchy_collapse_is_transitive (void)
{
  CmacsGraph *g = mk_tree (3, 4);

  /* Collapsing the root hides everything beneath it, at every depth. */
  cmacs_graph_set_collapsed (g, 0, TRUE);
  g_assert_cmpuint (cmacs_graph_n_visible (g), ==, 1);
  g_assert_cmpuint (node_by_id (g, "c1")->visible, ==, 0);
  g_assert_cmpuint (node_by_id (g, "c1.g2")->visible, ==, 0);
  cmacs_graph_free (g);
}

static void
test_hierarchy_collapse_all (void)
{
  CmacsGraph *g = mk_tree (3, 4);

  cmacs_graph_collapse_all (g, TRUE);
  /* Only leaves lack a subtree, so root + the three children collapse;
     what remains visible is the root and its three children. */
  g_assert_cmpuint (cmacs_graph_n_visible (g), ==, 1);

  cmacs_graph_collapse_all (g, FALSE);
  g_assert_cmpuint (cmacs_graph_n_visible (g), ==, 16);
  cmacs_graph_free (g);
}

static void
test_hierarchy_refuses_cycles (void)
{
  CmacsGraph *g = mk_nodes (3);

  g_assert_true  (cmacs_graph_set_parent (g, 1, 0));
  g_assert_true  (cmacs_graph_set_parent (g, 2, 1));
  /* 0 -> 2 would close the loop; every consumer walks upward, so a
     cycle is a hang, not a wrong answer. */
  g_assert_false (cmacs_graph_set_parent (g, 0, 2));
  g_assert_false (cmacs_graph_set_parent (g, 0, 0));
  g_assert_false (cmacs_graph_set_parent (g, 0, 99));
  cmacs_graph_free (g);
}

/* ---- force layout ------------------------------------------------- */

static void
test_layout_converges (void)
{
  CmacsGraph *g = mk_nodes (40);
  CmacsGraphLayout *l = cmacs_graph_layout_new ();
  int rounds = 0;

  cmacs_graph_layout_begin (l, g, 3, 0);
  while (!cmacs_graph_layout_step (l, g, 8) && rounds < 500) rounds++;

  g_assert_true (cmacs_graph_layout_converged (l));
  cmacs_graph_layout_free (l);
  cmacs_graph_free (g);
}

static void
test_layout_2d_is_planar (void)
{
  CmacsGraph *g = mk_nodes (30);
  CmacsGraphLayout *l = cmacs_graph_layout_new ();
  guint i;
  int rounds = 0;

  cmacs_graph_layout_begin (l, g, 2, 0);
  while (!cmacs_graph_layout_step (l, g, 8) && rounds < 500) rounds++;

  for (i = 0; i < cmacs_graph_n_nodes (g); i++)
    g_assert_cmpfloat (fabsf (cmacs_graph_node (g, i)->z), <, 1e-6f);

  cmacs_graph_layout_free (l);
  cmacs_graph_free (g);
}

static void
test_layout_is_deterministic (void)
{
  guint i;
  CmacsGraph *a = mk_nodes (25), *b = mk_nodes (25);
  CmacsGraphLayout *la = cmacs_graph_layout_new ();
  CmacsGraphLayout *lb = cmacs_graph_layout_new ();
  int r;

  cmacs_graph_layout_begin (la, a, 3, 0);
  cmacs_graph_layout_begin (lb, b, 3, 0);
  for (r = 0; r < 40; r++)
    {
      cmacs_graph_layout_step (la, a, 4);
      cmacs_graph_layout_step (lb, b, 4);
    }

  /* Same seed, same input, same result -- otherwise an animation
     re-run would jitter and a test could not assert anything. */
  for (i = 0; i < cmacs_graph_n_nodes (a); i++)
    {
      g_assert_cmpfloat (cmacs_graph_node (a, i)->x, ==,
                         cmacs_graph_node (b, i)->x);
      g_assert_cmpfloat (cmacs_graph_node (a, i)->y, ==,
                         cmacs_graph_node (b, i)->y);
    }

  cmacs_graph_layout_free (la);
  cmacs_graph_layout_free (lb);
  cmacs_graph_free (a);
  cmacs_graph_free (b);
}

/* ---- closed-form layouts ------------------------------------------ */

/* Every finite, and nothing left at the origin in a heap. */
static void
assert_placed_sanely (CmacsGraph *g)
{
  guint i, n = cmacs_graph_n_nodes (g);
  guint at_origin = 0;

  for (i = 0; i < n; i++)
    {
      const CmacsGraphNode *nd = cmacs_graph_node (g, i);
      if (!nd->visible) continue;
      g_assert_true (isfinite (nd->tx));
      g_assert_true (isfinite (nd->ty));
      g_assert_true (isfinite (nd->tz));
      if (fabsf (nd->tx) < 1e-6f && fabsf (nd->ty) < 1e-6f) at_origin++;
    }
  /* At most one node may legitimately sit dead centre (hex's seed). */
  g_assert_cmpuint (at_origin, <=, 1);
}

static void
test_place_circle_groups_by_radius (void)
{
  CmacsGraph *g = cmacs_graph_new (5);
  CmacsGraphLayout *l = cmacs_graph_layout_new ();
  guint i;
  double r_a = -1.0, r_b = -1.0;

  cmacs_graph_begin_update (g);
  for (i = 0; i < 6; i++)
    {
      gchar *id = g_strdup_printf ("n%u", i);
      cmacs_graph_add_node (g, id, id, NULL, (i < 3) ? "A" : "B", 0, 1, 0);
      g_free (id);
    }
  cmacs_graph_finalize (g);

  cmacs_graph_layout_place (l, g, CMACS_GRAPH_LAYOUT_CIRCLE, 2);
  assert_placed_sanely (g);

  /* Each group sits on one circle, and the two circles differ. */
  for (i = 0; i < 6; i++)
    {
      const CmacsGraphNode *nd = cmacs_graph_node (g, i);
      double r = sqrt ((double) nd->tx * nd->tx + (double) nd->ty * nd->ty);
      double *slot = (i < 3) ? &r_a : &r_b;
      if (*slot < 0.0) *slot = r;
      else g_assert_cmpfloat (fabs (r - *slot), <, 1e-4);
    }
  g_assert_cmpfloat (fabs (r_a - r_b), >, 1e-3);

  cmacs_graph_layout_free (l);
  cmacs_graph_free (g);
}

static void
test_place_hex_is_a_lattice (void)
{
  CmacsGraph *g = mk_nodes (37);   /* centre + 3 full hex rings */
  CmacsGraphLayout *l = cmacs_graph_layout_new ();
  guint i, j, n = cmacs_graph_n_nodes (g);
  double nn_min = 1e30;

  cmacs_graph_layout_place (l, g, CMACS_GRAPH_LAYOUT_HEX, 2);
  assert_placed_sanely (g);

  /* No two cells coincide, and the closest pair defines a spacing the
     lattice holds to -- that is what makes it a lattice and not a
     scatter. */
  for (i = 0; i < n; i++)
    for (j = i + 1; j < n; j++)
      {
        const CmacsGraphNode *a = cmacs_graph_node (g, i);
        const CmacsGraphNode *b = cmacs_graph_node (g, j);
        double dx = (double) a->tx - b->tx, dy = (double) a->ty - b->ty;
        double d = sqrt (dx * dx + dy * dy);
        g_assert_cmpfloat (d, >, 1e-3);
        if (d < nn_min) nn_min = d;
      }
  g_assert_cmpfloat (nn_min, >, 1.0);

  cmacs_graph_layout_free (l);
  cmacs_graph_free (g);
}

static void
test_place_rings_bands_by_ring (void)
{
  CmacsGraph *g = mk_nodes (12);
  CmacsGraphLayout *l = cmacs_graph_layout_new ();
  guint i;
  double r_of[4] = { -1, -1, -1, -1 };

  /* Four bands, three nodes each -- the ARMS shape. */
  for (i = 0; i < 12; i++)
    cmacs_graph_node (g, i)->ring = (guint8) (i / 3);

  cmacs_graph_layout_place (l, g, CMACS_GRAPH_LAYOUT_RINGS, 2);
  assert_placed_sanely (g);

  for (i = 0; i < 12; i++)
    {
      const CmacsGraphNode *nd = cmacs_graph_node (g, i);
      double r = sqrt ((double) nd->tx * nd->tx + (double) nd->ty * nd->ty);
      guint band = i / 3;
      if (r_of[band] < 0.0) r_of[band] = r;
      else g_assert_cmpfloat (fabs (r - r_of[band]), <, 1e-4);
    }

  /* Radii increase outward, so ring 0 really is innermost. */
  g_assert_cmpfloat (r_of[0], <, r_of[1]);
  g_assert_cmpfloat (r_of[1], <, r_of[2]);
  g_assert_cmpfloat (r_of[2], <, r_of[3]);

  cmacs_graph_layout_free (l);
  cmacs_graph_free (g);
}

/* Angular half-width of a group about its own mean direction: how much
   arc its members actually occupy. */
static double
group_arc (CmacsGraph *g, guint lo, guint hi)
{
  double sx = 0.0, sy = 0.0, mid, worst = 0.0;
  guint i;

  for (i = lo; i < hi; i++)
    {
      const CmacsGraphNode *nd = cmacs_graph_node (g, i);
      sx += (double) nd->tx; sy += (double) nd->ty;
    }
  mid = atan2 (sy, sx);
  for (i = lo; i < hi; i++)
    {
      const CmacsGraphNode *nd = cmacs_graph_node (g, i);
      double d = atan2 ((double) nd->ty, (double) nd->tx) - mid;
      while (d >  G_PI) d -= 2.0 * G_PI;
      while (d < -G_PI) d += 2.0 * G_PI;
      if (fabs (d) > worst) worst = fabs (d);
    }
  return worst;
}

static void
test_place_rings_wedge_scales_with_size (void)
{
  /* Two departments on one band, one ten times the other.  The big one
     must get the bigger arc.  Equal wedges are what makes "show me
     everything" unreadable: the big group piles onto itself while the
     small one floats in empty space. */
  CmacsGraph *g = mk_nodes (24);
  CmacsGraphLayout *l = cmacs_graph_layout_new ();
  guint i;

  for (i = 0; i < 24; i++) cmacs_graph_node (g, i)->ring = 1;
  /* 0 = small hub with 2 members; 1 = big hub with 20. */
  for (i = 2;  i < 4;  i++) cmacs_graph_set_parent (g, i, 0);
  for (i = 4;  i < 24; i++) cmacs_graph_set_parent (g, i, 1);

  cmacs_graph_layout_place (l, g, CMACS_GRAPH_LAYOUT_RINGS, 2);
  assert_placed_sanely (g);

  g_assert_cmpfloat (group_arc (g, 4, 24), >, group_arc (g, 2, 4));

  cmacs_graph_layout_free (l);
  cmacs_graph_free (g);
}

static void
test_place_rings_members_stay_in_their_wedge (void)
{
  /* Every member must be nearer its own hub, by angle, than the other
     hub -- that is what "contiguous wedge" has to mean for the map to
     be readable with everything open. */
  CmacsGraph *g = mk_nodes (22);
  CmacsGraphLayout *l = cmacs_graph_layout_new ();
  guint i;
  double ha[2];

  for (i = 0; i < 22; i++) cmacs_graph_node (g, i)->ring = 2;
  for (i = 2;  i < 12; i++) cmacs_graph_set_parent (g, i, 0);
  for (i = 12; i < 22; i++) cmacs_graph_set_parent (g, i, 1);

  cmacs_graph_layout_place (l, g, CMACS_GRAPH_LAYOUT_RINGS, 2);
  assert_placed_sanely (g);

  for (i = 0; i < 2; i++)
    ha[i] = atan2 ((double) cmacs_graph_node (g, i)->ty,
                   (double) cmacs_graph_node (g, i)->tx);

  for (i = 2; i < 22; i++)
    {
      const CmacsGraphNode *nd = cmacs_graph_node (g, i);
      guint mine = (i < 12) ? 0 : 1;
      double a = atan2 ((double) nd->ty, (double) nd->tx);
      double dm = fabs (a - ha[mine]), dow = fabs (a - ha[1 - mine]);
      while (dm  >  G_PI) dm  = fabs (dm  - 2.0 * G_PI);
      while (dow >  G_PI) dow = fabs (dow - 2.0 * G_PI);
      g_assert_cmpfloat (dm, <, dow);
    }

  cmacs_graph_layout_free (l);
  cmacs_graph_free (g);
}

static void
test_place_rings_grandchildren_join_their_department (void)
{
  /* A node two levels down belongs to its DEPARTMENT, not to its
     immediate folder: the group root is the outermost visible ancestor,
     so opening a subfolder must not eject its contents from the wedge. */
  CmacsGraph *g = mk_nodes (10);
  CmacsGraphLayout *l = cmacs_graph_layout_new ();
  guint i;
  double ha, worst = 0.0;

  for (i = 0; i < 10; i++) cmacs_graph_node (g, i)->ring = 1;
  cmacs_graph_set_parent (g, 1, 0);              /* folder under hub 0 */
  for (i = 2; i < 10; i++) cmacs_graph_set_parent (g, i, 1);   /* leaves */

  cmacs_graph_layout_place (l, g, CMACS_GRAPH_LAYOUT_RINGS, 2);
  assert_placed_sanely (g);

  /* One department: everything sits within a wedge of the whole circle,
     centred on the hub, rather than being scattered. */
  ha = atan2 ((double) cmacs_graph_node (g, 0)->ty,
              (double) cmacs_graph_node (g, 0)->tx);
  for (i = 1; i < 10; i++)
    {
      const CmacsGraphNode *nd = cmacs_graph_node (g, i);
      double d = atan2 ((double) nd->ty, (double) nd->tx) - ha;
      while (d >  G_PI) d -= 2.0 * G_PI;
      while (d < -G_PI) d += 2.0 * G_PI;
      if (fabs (d) > worst) worst = fabs (d);
    }
  g_assert_cmpfloat (worst, <=, G_PI + 1e-6);

  cmacs_graph_layout_free (l);
  cmacs_graph_free (g);
}

static void
test_place_children_fan_around_their_parent (void)
{
  /* Two hubs on the same band, four children each.  What an expanded
     department has to look like: a child must sit by the hub it came
     from.  Spreading every band member evenly on the circle instead --
     which is what a naive "one ring, all members" pass does -- puts a
     child next to a sibling of the OTHER hub and destroys exactly the
     relationship the expand was asking about. */
  CmacsGraph *g = mk_nodes (10);
  CmacsGraphLayout *l = cmacs_graph_layout_new ();
  guint i, c;
  double hx[2], hy[2];

  for (i = 0; i < 10; i++)
    cmacs_graph_node (g, i)->ring = 1;
  for (c = 2; c < 10; c++)
    cmacs_graph_set_parent (g, c, (c < 6) ? 0 : 1);

  cmacs_graph_layout_place (l, g, CMACS_GRAPH_LAYOUT_RINGS, 2);
  assert_placed_sanely (g);

  for (i = 0; i < 2; i++)
    {
      hx[i] = (double) cmacs_graph_node (g, i)->tx;
      hy[i] = (double) cmacs_graph_node (g, i)->ty;
    }

  for (c = 2; c < 10; c++)
    {
      const CmacsGraphNode *nd = cmacs_graph_node (g, c);
      guint mine = (c < 6) ? 0 : 1, other = 1 - mine;
      double dm = hypot ((double) nd->tx - hx[mine],
                         (double) nd->ty - hy[mine]);
      double dow = hypot ((double) nd->tx - hx[other],
                          (double) nd->ty - hy[other]);

      /* Nearer its own hub than the other one, and actually offset from
         it rather than stacked on top of it. */
      g_assert_cmpfloat (dm, <, dow);
      g_assert_cmpfloat (dm, >, 1e-3);
    }

  /* And distinct from each other: a fan that collapses to one point is
     no more legible than the band it replaced. */
  for (c = 2; c < 9; c++)
    {
      const CmacsGraphNode *a = cmacs_graph_node (g, c);
      const CmacsGraphNode *b = cmacs_graph_node (g, c + 1);
      if ((c < 5) || (c > 5))
        g_assert_cmpfloat (hypot ((double) a->tx - b->tx,
                                  (double) a->ty - b->ty), >, 1e-3);
    }

  cmacs_graph_layout_free (l);
  cmacs_graph_free (g);
}

static void
test_place_children_of_collapsed_parent_stay_hidden (void)
{
  /* The fan pass must respect collapse: a hub that is shut has no
     children to fan, and placing them anyway would scatter invisible
     nodes through the band that the next expand then animates FROM. */
  CmacsGraph *g = mk_nodes (6);
  CmacsGraphLayout *l = cmacs_graph_layout_new ();
  guint c;

  for (c = 0; c < 6; c++) cmacs_graph_node (g, c)->ring = 1;
  for (c = 1; c < 6; c++) cmacs_graph_set_parent (g, c, 0);
  cmacs_graph_set_collapsed (g, 0, TRUE);
  for (c = 0; c < 6; c++) cmacs_graph_node (g, c)->placed = 0;

  cmacs_graph_layout_place (l, g, CMACS_GRAPH_LAYOUT_RINGS, 2);

  g_assert_cmpuint (cmacs_graph_node (g, 0)->placed, ==, 1);
  for (c = 1; c < 6; c++)
    g_assert_cmpuint (cmacs_graph_node (g, c)->placed, ==, 0);

  cmacs_graph_layout_free (l);
  cmacs_graph_free (g);
}

static void
test_place_skips_invisible (void)
{
  CmacsGraph *g = mk_tree (3, 4);
  CmacsGraphLayout *l = cmacs_graph_layout_new ();
  guint i, n = cmacs_graph_n_nodes (g);
  guint visible_placed = 0;

  cmacs_graph_collapse_all (g, TRUE);
  for (i = 0; i < n; i++) cmacs_graph_node (g, i)->placed = 0;

  cmacs_graph_layout_place (l, g, CMACS_GRAPH_LAYOUT_RINGS, 2);

  /* A collapsed subtree has no position to occupy; placing it anyway
     would leave gaps in every ring. */
  for (i = 0; i < n; i++)
    {
      const CmacsGraphNode *nd = cmacs_graph_node (g, i);
      if (nd->visible) { visible_placed++; g_assert_cmpuint (nd->placed, ==, 1); }
      else             g_assert_cmpuint (nd->placed, ==, 0);
    }
  g_assert_cmpuint (visible_placed, ==, cmacs_graph_n_visible (g));

  cmacs_graph_layout_free (l);
  cmacs_graph_free (g);
}

static void
test_place_is_deterministic (void)
{
  CmacsGraph *a = mk_nodes (20), *b = mk_nodes (20);
  CmacsGraphLayout *la = cmacs_graph_layout_new ();
  CmacsGraphLayout *lb = cmacs_graph_layout_new ();
  guint i;

  for (i = 0; i < 20; i++)
    {
      cmacs_graph_node (a, i)->ring = (guint8) (i % 4);
      cmacs_graph_node (b, i)->ring = (guint8) (i % 4);
    }
  cmacs_graph_layout_place (la, a, CMACS_GRAPH_LAYOUT_RINGS, 2);
  cmacs_graph_layout_place (lb, b, CMACS_GRAPH_LAYOUT_RINGS, 2);

  /* Re-placing on every spin tick means a non-deterministic layout
     would visibly shuffle rather than rotate. */
  for (i = 0; i < 20; i++)
    {
      g_assert_cmpfloat (cmacs_graph_node (a, i)->tx, ==,
                         cmacs_graph_node (b, i)->tx);
      g_assert_cmpfloat (cmacs_graph_node (a, i)->ty, ==,
                         cmacs_graph_node (b, i)->ty);
    }

  cmacs_graph_layout_free (la);
  cmacs_graph_layout_free (lb);
  cmacs_graph_free (a);
  cmacs_graph_free (b);
}

static void
test_place_spin_rotates_without_reshaping (void)
{
  CmacsGraph *g = mk_nodes (8);
  CmacsGraphLayout *l = cmacs_graph_layout_new ();
  guint i;
  double r_before[8], r_after[8];
  gboolean moved = FALSE;

  for (i = 0; i < 8; i++) cmacs_graph_node (g, i)->ring = 0;

  cmacs_graph_layout_place (l, g, CMACS_GRAPH_LAYOUT_RINGS, 2);
  for (i = 0; i < 8; i++)
    {
      const CmacsGraphNode *nd = cmacs_graph_node (g, i);
      r_before[i] = sqrt ((double) nd->tx * nd->tx + (double) nd->ty * nd->ty);
    }

  cmacs_graph_layout_set_spin (l, 0.7);
  cmacs_graph_layout_place (l, g, CMACS_GRAPH_LAYOUT_RINGS, 2);
  for (i = 0; i < 8; i++)
    {
      const CmacsGraphNode *nd = cmacs_graph_node (g, i);
      r_after[i] = sqrt ((double) nd->tx * nd->tx + (double) nd->ty * nd->ty);
      if (fabsf (nd->tx) > 1e-6f) moved = TRUE;
    }

  /* Spinning is a rotation: radii are invariant, angles are not. */
  for (i = 0; i < 8; i++)
    g_assert_cmpfloat (fabs (r_before[i] - r_after[i]), <, 1e-4);
  g_assert_true (moved);

  cmacs_graph_layout_free (l);
  cmacs_graph_free (g);
}

/* ---- tweening ----------------------------------------------------- */

static void
test_tween_reaches_target_exactly (void)
{
  CmacsGraph *g = mk_nodes (4);
  CmacsGraphLayout *l = cmacs_graph_layout_new ();
  int frames = 10, i;

  cmacs_graph_node (g, 0)->x = 0.0f;
  cmacs_graph_node (g, 0)->tx = 5.0f;
  cmacs_graph_node (g, 0)->ty = -3.0f;
  cmacs_graph_node (g, 0)->tz = 2.0f;

  cmacs_graph_layout_tween_begin (l, g, frames);
  g_assert_true (cmacs_graph_layout_tweening (l));

  for (i = 0; i < frames - 1; i++)
    g_assert_false (cmacs_graph_layout_tween_step (l, g));
  g_assert_true (cmacs_graph_layout_tween_step (l, g));

  /* Exactly, not nearly: accumulated float error would otherwise leave
     the graph a hair off its own layout and drift over repeats. */
  g_assert_cmpfloat (cmacs_graph_node (g, 0)->x, ==, 5.0f);
  g_assert_cmpfloat (cmacs_graph_node (g, 0)->y, ==, -3.0f);
  g_assert_cmpfloat (cmacs_graph_node (g, 0)->z, ==, 2.0f);
  g_assert_false (cmacs_graph_layout_tweening (l));

  cmacs_graph_layout_free (l);
  cmacs_graph_free (g);
}

static void
test_tween_is_monotonic (void)
{
  CmacsGraph *g = mk_nodes (1);
  CmacsGraphLayout *l = cmacs_graph_layout_new ();
  int i;
  float prev;

  cmacs_graph_node (g, 0)->x = 0.0f;
  cmacs_graph_node (g, 0)->tx = 10.0f;
  cmacs_graph_node (g, 0)->ty = 0.0f;
  cmacs_graph_node (g, 0)->tz = 0.0f;

  cmacs_graph_layout_tween_begin (l, g, 20);
  prev = cmacs_graph_node (g, 0)->x;
  for (i = 0; i < 20; i++)
    {
      float now;
      cmacs_graph_layout_tween_step (l, g);
      now = cmacs_graph_node (g, 0)->x;
      /* Eased, but never overshooting or reversing. */
      g_assert_cmpfloat (now, >=, prev);
      g_assert_cmpfloat (now, <=, 10.0f);
      prev = now;
    }

  cmacs_graph_layout_free (l);
  cmacs_graph_free (g);
}

static void
test_tween_zero_frames_snaps (void)
{
  CmacsGraph *g = mk_nodes (1);
  CmacsGraphLayout *l = cmacs_graph_layout_new ();

  cmacs_graph_node (g, 0)->x  = 0.0f;
  cmacs_graph_node (g, 0)->tx = 7.0f;

  cmacs_graph_layout_tween_begin (l, g, 0);
  g_assert_false (cmacs_graph_layout_tweening (l));
  g_assert_cmpfloat (cmacs_graph_node (g, 0)->x, ==, 7.0f);

  cmacs_graph_layout_free (l);
  cmacs_graph_free (g);
}

static void
test_tween_restart_continues_from_current (void)
{
  CmacsGraph *g = mk_nodes (1);
  CmacsGraphLayout *l = cmacs_graph_layout_new ();
  float midway;
  int i;

  cmacs_graph_node (g, 0)->x  = 0.0f;
  cmacs_graph_node (g, 0)->tx = 10.0f;
  cmacs_graph_layout_tween_begin (l, g, 20);
  for (i = 0; i < 10; i++) cmacs_graph_layout_tween_step (l, g);
  midway = cmacs_graph_node (g, 0)->x;
  g_assert_cmpfloat (midway, >, 0.0f);

  /* Re-aiming mid-flight must continue from here, not rewind to 0. */
  cmacs_graph_node (g, 0)->tx = -5.0f;
  cmacs_graph_layout_tween_begin (l, g, 10);
  cmacs_graph_layout_tween_step (l, g);
  g_assert_cmpfloat (cmacs_graph_node (g, 0)->x, <, midway);
  g_assert_cmpfloat (cmacs_graph_node (g, 0)->x, >, -5.0f);

  cmacs_graph_layout_free (l);
  cmacs_graph_free (g);
}

static void
test_tween_force_kind_holds_still (void)
{
  CmacsGraph *g = mk_nodes (6);
  CmacsGraphLayout *l = cmacs_graph_layout_new ();
  guint i;
  float sx[6], sy[6];

  cmacs_graph_layout_begin (l, g, 3, 0);
  for (i = 0; i < 20; i++) cmacs_graph_layout_step (l, g, 4);
  for (i = 0; i < 6; i++)
    { sx[i] = cmacs_graph_node (g, i)->x; sy[i] = cmacs_graph_node (g, i)->y; }

  /* Placing FORCE aims every node where it already is, so a caller that
     tweens unconditionally does not drag the graph to the origin. */
  cmacs_graph_layout_place (l, g, CMACS_GRAPH_LAYOUT_FORCE, 3);
  cmacs_graph_layout_tween_begin (l, g, 5);
  while (!cmacs_graph_layout_tween_step (l, g)) ;

  for (i = 0; i < 6; i++)
    {
      g_assert_cmpfloat (cmacs_graph_node (g, i)->x, ==, sx[i]);
      g_assert_cmpfloat (cmacs_graph_node (g, i)->y, ==, sy[i]);
    }

  cmacs_graph_layout_free (l);
  cmacs_graph_free (g);
}

/* ---- main --------------------------------------------------------- */

int
main (int argc, char **argv)
{
  g_test_init (&argc, &argv, NULL);

  g_test_add_func ("/graphcore/graph/add-and-lookup", test_graph_add_and_lookup);
  g_test_add_func ("/graphcore/graph/duplicate-id", test_graph_duplicate_id_is_first_wins);
  g_test_add_func ("/graphcore/graph/overflow-returns-minus-one", test_graph_overflow_returns_minus_one);
  g_test_add_func ("/graphcore/graph/edges-sanitised", test_graph_edges_sanitised);
  g_test_add_func ("/graphcore/graph/rebuild-keeps-positions", test_graph_rebuild_keeps_positions);

  g_test_add_func ("/graphcore/hierarchy/absent-by-default", test_hierarchy_absent_by_default);
  g_test_add_func ("/graphcore/hierarchy/descendant-counts", test_hierarchy_descendant_counts);
  g_test_add_func ("/graphcore/hierarchy/collapse-hides-subtree", test_hierarchy_collapse_hides_subtree);
  g_test_add_func ("/graphcore/hierarchy/collapse-is-transitive", test_hierarchy_collapse_is_transitive);
  g_test_add_func ("/graphcore/hierarchy/collapse-all", test_hierarchy_collapse_all);
  g_test_add_func ("/graphcore/hierarchy/refuses-cycles", test_hierarchy_refuses_cycles);

  g_test_add_func ("/graphcore/layout/converges", test_layout_converges);
  g_test_add_func ("/graphcore/layout/2d-is-planar", test_layout_2d_is_planar);
  g_test_add_func ("/graphcore/layout/deterministic", test_layout_is_deterministic);

  g_test_add_func ("/graphcore/place/circle-groups-by-radius", test_place_circle_groups_by_radius);
  g_test_add_func ("/graphcore/place/hex-is-a-lattice", test_place_hex_is_a_lattice);
  g_test_add_func ("/graphcore/place/rings-bands-by-ring", test_place_rings_bands_by_ring);
  g_test_add_func ("/graphcore/place/rings-wedge-scales-with-size",
                   test_place_rings_wedge_scales_with_size);
  g_test_add_func ("/graphcore/place/rings-members-stay-in-wedge",
                   test_place_rings_members_stay_in_their_wedge);
  g_test_add_func ("/graphcore/place/rings-grandchildren-join-department",
                   test_place_rings_grandchildren_join_their_department);
  g_test_add_func ("/graphcore/place/children-fan-around-parent",
                   test_place_children_fan_around_their_parent);
  g_test_add_func ("/graphcore/place/collapsed-children-stay-hidden",
                   test_place_children_of_collapsed_parent_stay_hidden);
  g_test_add_func ("/graphcore/place/skips-invisible", test_place_skips_invisible);
  g_test_add_func ("/graphcore/place/deterministic", test_place_is_deterministic);
  g_test_add_func ("/graphcore/place/spin-rotates", test_place_spin_rotates_without_reshaping);

  g_test_add_func ("/graphcore/tween/reaches-target-exactly", test_tween_reaches_target_exactly);
  g_test_add_func ("/graphcore/tween/monotonic", test_tween_is_monotonic);
  g_test_add_func ("/graphcore/tween/zero-frames-snaps", test_tween_zero_frames_snaps);
  g_test_add_func ("/graphcore/tween/restart-continues", test_tween_restart_continues_from_current);
  g_test_add_func ("/graphcore/tween/force-holds-still", test_tween_force_kind_holds_still);

  return g_test_run ();
}
