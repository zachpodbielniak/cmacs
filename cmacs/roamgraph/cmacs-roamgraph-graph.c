/* cmacs-roamgraph-graph.c --- pure-C org-roam graph model.
 *
 * Copyright (C) 2026 Zach Podbielniak
 * SPDX-License-Identifier: AGPL-3.0-or-later
 *
 * See cmacs-roamgraph-graph.h for the contract.  This translation unit
 * includes neither "lisp.h" nor <libregnum.h>, on purpose: it is the
 * part of the subsystem that can be exercised with no Lisp VM and no GL
 * context. */

#include <config.h>

#ifdef HAVE_CMACS_ROAMGRAPH

#include "cmacs-roamgraph-graph.h"

#include <math.h>
#include <stdlib.h>
#include <string.h>

/* Guard against a pathological notes tree wedging the solver.  Well
 * above the ~1200 nodes a mature org-roam database carries. */
#define ROAM_MAX_NODES 20000

/* ── Deterministic RNG ────────────────────────────────────────────
 * xorshift32.  Deliberately NOT g_random_*: that draws from a global
 * stream, which makes the layout unreproducible and the solver
 * untestable. */

static guint32
xorshift32 (guint32 *state)
{
  guint32 x = *state;
  x ^= x << 13;
  x ^= x >> 17;
  x ^= x << 5;
  *state = x ? x : 0x1234567u;
  return *state;
}

float
cmacs_roam_graph_rand (CmacsRoamGraph *g)
{
  /* Top 24 bits scaled into [0,1) -- avoids the low-bit correlation
     xorshift is known for. */
  return (float) (xorshift32 (&g->rng) >> 8) / 16777216.0f;
}

void
cmacs_roam_graph_reset_rand (CmacsRoamGraph *g)
{
  g->rng = g->seed ? g->seed : 0x1234567u;
}

/* ── Node storage ─────────────────────────────────────────────────── */

static void
node_clear (CmacsRoamNode *n)
{
  g_free (n->id);
  g_free (n->title);
  g_free (n->file);
  g_free (n->group);
}

static void
nodes_free (GArray *a)
{
  guint i;

  if (!a) return;
  for (i = 0; i < a->len; i++)
    node_clear (&g_array_index (a, CmacsRoamNode, i));
  g_array_free (a, TRUE);
}

CmacsRoamGraph *
cmacs_roam_graph_new (guint32 seed)
{
  CmacsRoamGraph *g = g_new0 (CmacsRoamGraph, 1);

  g->nodes   = g_array_new (FALSE, TRUE, sizeof (CmacsRoamNode));
  g->edges   = g_array_new (FALSE, TRUE, sizeof (CmacsRoamEdge));
  g->adj     = g_array_new (FALSE, TRUE, sizeof (guint32));
  g->adj_dir = g_array_new (FALSE, TRUE, sizeof (guint8));
  /* Keys are borrowed from the node's own `id' -- never freed here. */
  g->by_id   = g_hash_table_new (g_str_hash, g_str_equal);
  g->seed    = seed ? seed : 0x9E3779B9u;
  cmacs_roam_graph_reset_rand (g);
  return g;
}

void
cmacs_roam_graph_free (CmacsRoamGraph *g)
{
  if (!g) return;
  nodes_free (g->nodes);
  nodes_free (g->old_nodes);
  if (g->edges)     g_array_free (g->edges, TRUE);
  if (g->adj)       g_array_free (g->adj, TRUE);
  if (g->adj_dir)   g_array_free (g->adj_dir, TRUE);
  if (g->by_id)     g_hash_table_destroy (g->by_id);
  if (g->old_by_id) g_hash_table_destroy (g->old_by_id);
  if (g->edge_seen) g_hash_table_destroy (g->edge_seen);
  g_free (g);
}

/* ── Update transaction ───────────────────────────────────────────── */

void
cmacs_roam_graph_begin_update (CmacsRoamGraph *g)
{
  g_return_if_fail (g != NULL);

  /* Stash the previous generation so add_node can inherit positions.
     A refresh that reshuffled every node would make the graph useless
     as a spatial memory aid. */
  nodes_free (g->old_nodes);
  if (g->old_by_id) g_hash_table_destroy (g->old_by_id);
  g->old_nodes = g->nodes;
  g->old_by_id = g->by_id;

  g->nodes = g_array_new (FALSE, TRUE, sizeof (CmacsRoamNode));
  g->by_id = g_hash_table_new (g_str_hash, g_str_equal);
  g_array_set_size (g->edges, 0);

  if (g->edge_seen) g_hash_table_destroy (g->edge_seen);
  g->edge_seen = g_hash_table_new_full (g_str_hash, g_str_equal,
                                        g_free, NULL);
  g->updating = TRUE;
}

guint
cmacs_roam_graph_add_node (CmacsRoamGraph *g,
                           const char *id, const char *title,
                           const char *file, const char *group,
                           int level, int pos, guint32 rgba)
{
  CmacsRoamNode n;
  gpointer found;
  guint idx;

  g_return_val_if_fail (g != NULL, 0);
  g_return_val_if_fail (id != NULL && *id != '\0', 0);

  /* Duplicate id: org-roam should not emit one, but a hand-edited
     :ID: can be pasted twice.  First wins. */
  found = g_hash_table_lookup (g->by_id, id);
  if (found) return GPOINTER_TO_UINT (found) - 1;

  if (g->nodes->len >= ROAM_MAX_NODES) return 0;

  memset (&n, 0, sizeof n);
  n.id      = g_strdup (id);
  n.title   = g_strdup (title && *title ? title : id);
  n.file    = file  ? g_strdup (file)  : NULL;
  n.group   = group ? g_strdup (group) : NULL;
  n.level   = level;
  n.pos     = pos;
  n.rgba    = rgba;
  n.radius  = 0.30f;
  n.visible = 1;

  /* Inherit the previous generation's position when this id survived. */
  if (g->old_by_id)
    {
      gpointer old = g_hash_table_lookup (g->old_by_id, id);
      if (old)
        {
          const CmacsRoamNode *o =
            &g_array_index (g->old_nodes, CmacsRoamNode,
                            GPOINTER_TO_UINT (old) - 1);
          n.x = o->x; n.y = o->y; n.z = o->z;
          n.pinned = o->pinned;
          n.placed = 1;
        }
    }

  g_array_append_val (g->nodes, n);
  idx = g->nodes->len - 1;
  /* Key is borrowed from the node we just appended.  GArray may
     realloc the element storage, but `id' is a separate heap pointer
     that the move copies verbatim, so the key stays valid. */
  g_hash_table_insert (g->by_id,
                       g_array_index (g->nodes, CmacsRoamNode, idx).id,
                       GUINT_TO_POINTER (idx + 1));
  return idx;
}

gboolean
cmacs_roam_graph_add_edge (CmacsRoamGraph *g,
                           const char *from_id, const char *to_id,
                           CmacsRoamEdgeKind kind, float weight)
{
  CmacsRoamEdge e;
  gint a, b;
  gchar *key;

  g_return_val_if_fail (g != NULL, FALSE);
  if (!from_id || !to_id) return FALSE;

  a = cmacs_roam_graph_index_of (g, from_id);
  b = cmacs_roam_graph_index_of (g, to_id);

  /* Dangling links are normal: a note can reference an id that was
     deleted, or one that lives outside the filtered subgraph. */
  if (a < 0 || b < 0) return FALSE;
  if (a == b) return FALSE;                     /* self-loop */

  /* Dedup on the unordered pair plus kind, so A->B and B->A collapse
     into one spring rather than double-weighting it. */
  key = (a < b)
        ? g_strdup_printf ("%d:%d:%d", a, b, (int) kind)
        : g_strdup_printf ("%d:%d:%d", b, a, (int) kind);
  if (g_hash_table_contains (g->edge_seen, key))
    {
      g_free (key);
      return FALSE;
    }
  g_hash_table_add (g->edge_seen, key);         /* takes KEY */

  e.a    = (guint32) a;
  e.b    = (guint32) b;
  e.kind = (guint8) kind;
  e.w    = (weight > 0.0f) ? weight : 1.0f;
  g_array_append_val (g->edges, e);
  return TRUE;
}

/* ── Finalize: CSR, degrees, radii ────────────────────────────────── */

/* Sort key for the entries inside one node's CSR slice.  Out-edges
 * come first, then backlinks; within each group, alphabetically by the
 * neighbour's title.  Determinism here is what makes `<'/`>' peer
 * cycling return you to where you started. */
typedef struct
{
  guint32 nb;
  guint8  dir;
  const char *title;
} SliceEnt;

static gint
slice_cmp (gconstpointer pa, gconstpointer pb)
{
  const SliceEnt *a = pa, *b = pb;
  int c;

  if (a->dir != b->dir) return (a->dir < b->dir) ? -1 : 1;
  c = g_ascii_strcasecmp (a->title ? a->title : "",
                          b->title ? b->title : "");
  if (c) return c;
  /* Final tie-break on index so the order is total. */
  return (a->nb < b->nb) ? -1 : (a->nb > b->nb) ? 1 : 0;
}

void
cmacs_roam_graph_finalize (CmacsRoamGraph *g)
{
  guint n, m, i, max_deg = 0;
  guint *cursor;
  SliceEnt *slice;

  g_return_if_fail (g != NULL);

  n = g->nodes->len;
  m = g->edges->len;

  /* 1. degrees */
  for (i = 0; i < n; i++)
    {
      CmacsRoamNode *nd = &g_array_index (g->nodes, CmacsRoamNode, i);
      nd->in_deg = nd->out_deg = 0;
      nd->edge_first = nd->edge_count = 0;
    }
  for (i = 0; i < m; i++)
    {
      CmacsRoamEdge *e = &g_array_index (g->edges, CmacsRoamEdge, i);
      g_array_index (g->nodes, CmacsRoamNode, e->a).out_deg++;
      g_array_index (g->nodes, CmacsRoamNode, e->b).in_deg++;
    }

  /* 2. prefix-sum the slice offsets */
  {
    guint off = 0;
    for (i = 0; i < n; i++)
      {
        CmacsRoamNode *nd = &g_array_index (g->nodes, CmacsRoamNode, i);
        nd->edge_first = off;
        nd->edge_count = (guint) (nd->in_deg + nd->out_deg);
        off += nd->edge_count;
      }
    g_array_set_size (g->adj, off);
    g_array_set_size (g->adj_dir, off);
    slice = g_new0 (SliceEnt, off ? off : 1);
  }

  /* 3. scatter both directions into the slices */
  cursor = g_new0 (guint, n ? n : 1);
  for (i = 0; i < m; i++)
    {
      CmacsRoamEdge *e = &g_array_index (g->edges, CmacsRoamEdge, i);
      CmacsRoamNode *na = &g_array_index (g->nodes, CmacsRoamNode, e->a);
      CmacsRoamNode *nb = &g_array_index (g->nodes, CmacsRoamNode, e->b);
      guint pa = na->edge_first + cursor[e->a]++;
      guint pb = nb->edge_first + cursor[e->b]++;

      slice[pa].nb  = e->b;
      slice[pa].dir = CMACS_ROAM_DIR_OUT;
      slice[pa].title = nb->title;

      slice[pb].nb  = e->a;
      slice[pb].dir = CMACS_ROAM_DIR_IN;
      slice[pb].title = na->title;
    }
  g_free (cursor);

  /* 4. sort each slice, then flatten into the parallel arrays */
  for (i = 0; i < n; i++)
    {
      CmacsRoamNode *nd = &g_array_index (g->nodes, CmacsRoamNode, i);
      guint j;

      if (nd->edge_count > 1)
        qsort (slice + nd->edge_first, nd->edge_count,
               sizeof (SliceEnt), slice_cmp);
      for (j = 0; j < nd->edge_count; j++)
        {
          guint p = nd->edge_first + j;
          g_array_index (g->adj, guint32, p)    = slice[p].nb;
          g_array_index (g->adj_dir, guint8, p) = slice[p].dir;
        }
      if (nd->edge_count > max_deg) max_deg = nd->edge_count;
    }
  g_free (slice);

  /* 5. render radius from degree.  log-scaled: a 200-backlink hub
     should read as bigger than a leaf without dwarfing the map. */
  {
    double denom = log2 (1.0 + (double) max_deg);
    if (denom < 1e-6) denom = 1.0;
    for (i = 0; i < n; i++)
      {
        CmacsRoamNode *nd = &g_array_index (g->nodes, CmacsRoamNode, i);
        double t = log2 (1.0 + (double) nd->edge_count) / denom;
        nd->radius = (float) (0.30 * (0.55 + 0.45 * t));
      }
  }

  /* 6. release the previous generation */
  nodes_free (g->old_nodes);
  g->old_nodes = NULL;
  if (g->old_by_id)
    {
      g_hash_table_destroy (g->old_by_id);
      g->old_by_id = NULL;
    }
  if (g->edge_seen)
    {
      g_hash_table_destroy (g->edge_seen);
      g->edge_seen = NULL;
    }

  g->updating = FALSE;
  g->generation++;
  cmacs_roam_graph_reset_rand (g);
}

/* ── Accessors ────────────────────────────────────────────────────── */

guint
cmacs_roam_graph_n_nodes (CmacsRoamGraph *g)
{
  return (g && g->nodes) ? g->nodes->len : 0;
}

guint
cmacs_roam_graph_n_edges (CmacsRoamGraph *g)
{
  return (g && g->edges) ? g->edges->len : 0;
}

CmacsRoamNode *
cmacs_roam_graph_node (CmacsRoamGraph *g, guint i)
{
  if (!g || !g->nodes || i >= g->nodes->len) return NULL;
  return &g_array_index (g->nodes, CmacsRoamNode, i);
}

CmacsRoamEdge *
cmacs_roam_graph_edge (CmacsRoamGraph *g, guint i)
{
  if (!g || !g->edges || i >= g->edges->len) return NULL;
  return &g_array_index (g->edges, CmacsRoamEdge, i);
}

gint
cmacs_roam_graph_index_of (CmacsRoamGraph *g, const char *id)
{
  gpointer p;

  if (!g || !g->by_id || !id) return -1;
  p = g_hash_table_lookup (g->by_id, id);
  return p ? (gint) (GPOINTER_TO_UINT (p) - 1) : -1;
}

const guint32 *
cmacs_roam_graph_neighbours (CmacsRoamGraph *g, guint i,
                             const guint8 **dirs, guint *n_out)
{
  CmacsRoamNode *nd = cmacs_roam_graph_node (g, i);

  if (n_out) *n_out = 0;
  if (dirs)  *dirs  = NULL;
  if (!nd || nd->edge_count == 0) return NULL;

  if (n_out) *n_out = nd->edge_count;
  if (dirs)
    *dirs = &g_array_index (g->adj_dir, guint8, nd->edge_first);
  return &g_array_index (g->adj, guint32, nd->edge_first);
}

#endif /* HAVE_CMACS_ROAMGRAPH */
