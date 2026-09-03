/* cmacs-graphcore-graph.c --- pure-C graph model.
 *
 * Copyright (C) 2026 Zach Podbielniak
 * SPDX-License-Identifier: AGPL-3.0-or-later
 *
 * See cmacs-graphcore-graph.h for the contract.  This translation unit
 * includes neither "lisp.h" nor <libregnum.h>, on purpose: it is the
 * part of every graph visualiser that can be exercised with no Lisp VM
 * and no GL context. */

#include <config.h>

#ifdef HAVE_CMACS_GRAPHCORE

#include "cmacs-graphcore-graph.h"

#include <math.h>
#include <stdlib.h>
#include <string.h>

/* Guard against a pathological notes tree wedging the solver.  Well
 * above the ~1200 nodes a mature org-roam database carries. */
#define GRAPHCORE_MAX_NODES 20000

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
cmacs_graph_rand (CmacsGraph *g)
{
  /* Top 24 bits scaled into [0,1) -- avoids the low-bit correlation
     xorshift is known for. */
  return (float) (xorshift32 (&g->rng) >> 8) / 16777216.0f;
}

void
cmacs_graph_reset_rand (CmacsGraph *g)
{
  g->rng = g->seed ? g->seed : 0x1234567u;
}

/* ── Node storage ─────────────────────────────────────────────────── */

static void
node_clear (CmacsGraphNode *n)
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
    node_clear (&g_array_index (a, CmacsGraphNode, i));
  g_array_free (a, TRUE);
}

CmacsGraph *
cmacs_graph_new (guint32 seed)
{
  CmacsGraph *g = g_new0 (CmacsGraph, 1);

  g->nodes   = g_array_new (FALSE, TRUE, sizeof (CmacsGraphNode));
  g->edges   = g_array_new (FALSE, TRUE, sizeof (CmacsGraphEdge));
  g->adj     = g_array_new (FALSE, TRUE, sizeof (guint32));
  g->adj_dir = g_array_new (FALSE, TRUE, sizeof (guint8));
  /* Keys are borrowed from the node's own `id' -- never freed here. */
  g->by_id   = g_hash_table_new (g_str_hash, g_str_equal);
  g->seed    = seed ? seed : 0x9E3779B9u;
  cmacs_graph_reset_rand (g);
  return g;
}

void
cmacs_graph_free (CmacsGraph *g)
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
cmacs_graph_begin_update (CmacsGraph *g)
{
  g_return_if_fail (g != NULL);

  /* Stash the previous generation so add_node can inherit positions.
     A refresh that reshuffled every node would make the graph useless
     as a spatial memory aid. */
  nodes_free (g->old_nodes);
  if (g->old_by_id) g_hash_table_destroy (g->old_by_id);
  g->old_nodes = g->nodes;
  g->old_by_id = g->by_id;

  g->nodes = g_array_new (FALSE, TRUE, sizeof (CmacsGraphNode));
  g->by_id = g_hash_table_new (g_str_hash, g_str_equal);
  g_array_set_size (g->edges, 0);

  if (g->edge_seen) g_hash_table_destroy (g->edge_seen);
  g->edge_seen = g_hash_table_new_full (g_str_hash, g_str_equal,
                                        g_free, NULL);
  g->updating = TRUE;
}

gint
cmacs_graph_add_node (CmacsGraph *g,
                           const char *id, const char *title,
                           const char *file, const char *group,
                           int level, int pos, guint32 rgba)
{
  CmacsGraphNode n;
  gpointer found;
  guint idx;

  g_return_val_if_fail (g != NULL, -1);
  g_return_val_if_fail (id != NULL && *id != '\0', -1);

  /* Duplicate id: org-roam should not emit one, but a hand-edited
     :ID: can be pasted twice.  First wins. */
  found = g_hash_table_lookup (g->by_id, id);
  if (found) return (gint) (GPOINTER_TO_UINT (found) - 1);

  /* -1, not 0: see the header.  A full graph must drop the node, not
     quietly merge it into whichever node happens to be first. */
  if (g->nodes->len >= GRAPHCORE_MAX_NODES) return -1;

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
  n.parent  = -1;

  /* Inherit the previous generation's position when this id survived. */
  if (g->old_by_id)
    {
      gpointer old = g_hash_table_lookup (g->old_by_id, id);
      if (old)
        {
          const CmacsGraphNode *o =
            &g_array_index (g->old_nodes, CmacsGraphNode,
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
                       g_array_index (g->nodes, CmacsGraphNode, idx).id,
                       GUINT_TO_POINTER (idx + 1));
  return (gint) idx;
}

gboolean
cmacs_graph_add_edge (CmacsGraph *g,
                           const char *from_id, const char *to_id,
                           CmacsGraphEdgeKind kind, float weight)
{
  CmacsGraphEdge e;
  gint a, b;
  gchar *key;

  g_return_val_if_fail (g != NULL, FALSE);
  if (!from_id || !to_id) return FALSE;

  a = cmacs_graph_index_of (g, from_id);
  b = cmacs_graph_index_of (g, to_id);

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

/* Defined with the rest of the hierarchy code at the end of the file;
   finalize is the only caller. */
static void graph_recount_descendants (CmacsGraph *g);

void
cmacs_graph_finalize (CmacsGraph *g)
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
      CmacsGraphNode *nd = &g_array_index (g->nodes, CmacsGraphNode, i);
      nd->in_deg = nd->out_deg = 0;
      nd->edge_first = nd->edge_count = 0;
    }
  for (i = 0; i < m; i++)
    {
      CmacsGraphEdge *e = &g_array_index (g->edges, CmacsGraphEdge, i);
      g_array_index (g->nodes, CmacsGraphNode, e->a).out_deg++;
      g_array_index (g->nodes, CmacsGraphNode, e->b).in_deg++;
    }

  /* 2. prefix-sum the slice offsets */
  {
    guint off = 0;
    for (i = 0; i < n; i++)
      {
        CmacsGraphNode *nd = &g_array_index (g->nodes, CmacsGraphNode, i);
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
      CmacsGraphEdge *e = &g_array_index (g->edges, CmacsGraphEdge, i);
      CmacsGraphNode *na = &g_array_index (g->nodes, CmacsGraphNode, e->a);
      CmacsGraphNode *nb = &g_array_index (g->nodes, CmacsGraphNode, e->b);
      guint pa = na->edge_first + cursor[e->a]++;
      guint pb = nb->edge_first + cursor[e->b]++;

      slice[pa].nb  = e->b;
      slice[pa].dir = CMACS_GRAPH_DIR_OUT;
      slice[pa].title = nb->title;

      slice[pb].nb  = e->a;
      slice[pb].dir = CMACS_GRAPH_DIR_IN;
      slice[pb].title = na->title;
    }
  g_free (cursor);

  /* 4. sort each slice, then flatten into the parallel arrays */
  for (i = 0; i < n; i++)
    {
      CmacsGraphNode *nd = &g_array_index (g->nodes, CmacsGraphNode, i);
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
        CmacsGraphNode *nd = &g_array_index (g->nodes, CmacsGraphNode, i);
        double t = log2 (1.0 + (double) nd->edge_count) / denom;
        nd->radius = (float) (0.30 * (0.55 + 0.45 * t));
      }
  }

  /* 5b. hierarchy: transitive child counts and initial visibility.
     Cheap when nothing set a parent (the common case) -- the counting
     pass short-circuits and every node stays a visible root. */
  graph_recount_descendants (g);
  cmacs_graph_refresh_visibility (g);

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
  cmacs_graph_reset_rand (g);
}

/* ── Accessors ────────────────────────────────────────────────────── */

guint
cmacs_graph_n_nodes (CmacsGraph *g)
{
  return (g && g->nodes) ? g->nodes->len : 0;
}

guint
cmacs_graph_n_edges (CmacsGraph *g)
{
  return (g && g->edges) ? g->edges->len : 0;
}

CmacsGraphNode *
cmacs_graph_node (CmacsGraph *g, guint i)
{
  if (!g || !g->nodes || i >= g->nodes->len) return NULL;
  return &g_array_index (g->nodes, CmacsGraphNode, i);
}

CmacsGraphEdge *
cmacs_graph_edge (CmacsGraph *g, guint i)
{
  if (!g || !g->edges || i >= g->edges->len) return NULL;
  return &g_array_index (g->edges, CmacsGraphEdge, i);
}

gint
cmacs_graph_index_of (CmacsGraph *g, const char *id)
{
  gpointer p;

  if (!g || !g->by_id || !id) return -1;
  p = g_hash_table_lookup (g->by_id, id);
  return p ? (gint) (GPOINTER_TO_UINT (p) - 1) : -1;
}

const guint32 *
cmacs_graph_neighbours (CmacsGraph *g, guint i,
                             const guint8 **dirs, guint *n_out)
{
  CmacsGraphNode *nd = cmacs_graph_node (g, i);

  if (n_out) *n_out = 0;
  if (dirs)  *dirs  = NULL;
  if (!nd || nd->edge_count == 0) return NULL;

  if (n_out) *n_out = nd->edge_count;
  if (dirs)
    *dirs = &g_array_index (g->adj_dir, guint8, nd->edge_first);
  return &g_array_index (g->adj, guint32, nd->edge_first);
}


/* ---- Hierarchy ----------------------------------------------------
 *
 * Parents are optional and default to -1, so a graph that never calls
 * set_parent behaves exactly as it did before this existed: every node
 * a visible root, no walks, no cost.
 *
 * The two derived quantities are kept as stored fields rather than
 * recomputed per frame because both are read by the scene builder for
 * every node on every rebuild: `descendants' sizes a collapsed hub,
 * and `visible' decides whether the node is emitted at all. */

/* Transitive child count for every node.
 *
 * Bottom-up over a depth-sorted order rather than a recursive walk:
 * recursion on a pathological tree (35k files nested one per level)
 * would overflow the C stack, and this is O(n) either way. */
static void
graph_recount_descendants (CmacsGraph *g)
{
  guint n = g->nodes->len;
  guint i;
  guint32 *depth;
  guint *order;
  gboolean any_parent = FALSE;

  for (i = 0; i < n; i++)
    {
      CmacsGraphNode *nd = &g_array_index (g->nodes, CmacsGraphNode, i);
      nd->descendants = 0;
      if (nd->parent >= 0) any_parent = TRUE;
    }
  if (!any_parent || n == 0) return;

  /* Depth of each node, capped so a cycle that slipped past
     set_parent cannot spin here. */
  depth = g_new0 (guint32, n);
  for (i = 0; i < n; i++)
    {
      gint p = g_array_index (g->nodes, CmacsGraphNode, i).parent;
      guint32 d = 0;
      while (p >= 0 && d < n)
        {
          d++;
          p = g_array_index (g->nodes, CmacsGraphNode, (guint) p).parent;
        }
      depth[i] = d;
    }

  /* Counting sort by depth, deepest first, then add each node's own
     subtree size into its parent. */
  order = g_new0 (guint, n);
  {
    guint32 maxd = 0;
    guint32 *bucket;
    guint32 acc = 0;
    for (i = 0; i < n; i++) if (depth[i] > maxd) maxd = depth[i];
    bucket = g_new0 (guint32, maxd + 2);
    for (i = 0; i < n; i++) bucket[maxd - depth[i]]++;
    for (i = 0; i <= maxd; i++)
      { guint32 c = bucket[i]; bucket[i] = acc; acc += c; }
    for (i = 0; i < n; i++) order[bucket[maxd - depth[i]]++] = i;
    g_free (bucket);
  }

  for (i = 0; i < n; i++)
    {
      guint idx = order[i];
      CmacsGraphNode *nd = &g_array_index (g->nodes, CmacsGraphNode, idx);
      if (nd->parent >= 0)
        {
          CmacsGraphNode *pn =
            &g_array_index (g->nodes, CmacsGraphNode, (guint) nd->parent);
          pn->descendants += nd->descendants + 1;
        }
    }

  g_free (depth);
  g_free (order);
}

gboolean
cmacs_graph_set_parent (CmacsGraph *g, guint child, gint parent)
{
  CmacsGraphNode *nd;
  gint walk;
  guint guard;

  g_return_val_if_fail (g != NULL, FALSE);
  g_return_val_if_fail (child < g->nodes->len, FALSE);

  if (parent >= 0 && (guint) parent >= g->nodes->len) return FALSE;
  if (parent == (gint) child) return FALSE;   /* self-parenting */

  /* Refuse a cycle rather than propagate it: every consumer of this
     field walks upward, and a cycle turns each of those walks into a
     hang.  Cheap to check here, impossible to diagnose later. */
  for (walk = parent, guard = 0;
       walk >= 0 && guard <= g->nodes->len;
       guard++)
    {
      if ((guint) walk == child) return FALSE;
      walk = g_array_index (g->nodes, CmacsGraphNode, (guint) walk).parent;
    }

  nd = &g_array_index (g->nodes, CmacsGraphNode, child);
  nd->parent = parent;
  return TRUE;
}

void
cmacs_graph_refresh_visibility (CmacsGraph *g)
{
  guint n, i;

  g_return_if_fail (g != NULL);
  n = g->nodes->len;

  for (i = 0; i < n; i++)
    {
      CmacsGraphNode *nd = &g_array_index (g->nodes, CmacsGraphNode, i);
      gint p = nd->parent;
      guint guard = 0;
      guint8 vis = 1;

      /* Visible unless some ancestor is collapsed.  The guard is the
         same cycle backstop as above; set_parent should make it
         unreachable, but a hang here would be a frozen editor. */
      while (p >= 0 && guard <= n)
        {
          const CmacsGraphNode *pn =
            &g_array_index (g->nodes, CmacsGraphNode, (guint) p);
          if (pn->collapsed) { vis = 0; break; }
          p = pn->parent;
          guard++;
        }
      nd->visible = vis;
    }
}

gboolean
cmacs_graph_set_collapsed (CmacsGraph *g, guint idx, gboolean collapsed)
{
  CmacsGraphNode *nd;

  g_return_val_if_fail (g != NULL, FALSE);
  g_return_val_if_fail (idx < g->nodes->len, FALSE);

  nd = &g_array_index (g->nodes, CmacsGraphNode, idx);
  if ((!!nd->collapsed) == (!!collapsed)) return FALSE;

  nd->collapsed = collapsed ? 1 : 0;
  cmacs_graph_refresh_visibility (g);
  return TRUE;
}

void
cmacs_graph_collapse_all (CmacsGraph *g, gboolean collapsed)
{
  guint n, i;

  g_return_if_fail (g != NULL);
  n = g->nodes->len;

  for (i = 0; i < n; i++)
    {
      CmacsGraphNode *nd = &g_array_index (g->nodes, CmacsGraphNode, i);
      /* Only nodes that actually have a subtree; collapsing a leaf
         would hide nothing and still cost a visibility walk. */
      if (nd->descendants > 0) nd->collapsed = collapsed ? 1 : 0;
    }
  cmacs_graph_refresh_visibility (g);
}

guint
cmacs_graph_n_visible (CmacsGraph *g)
{
  guint n, i, count = 0;

  g_return_val_if_fail (g != NULL, 0);
  n = g->nodes->len;
  for (i = 0; i < n; i++)
    if (g_array_index (g->nodes, CmacsGraphNode, i).visible) count++;
  return count;
}

#endif /* HAVE_CMACS_GRAPHCORE */
