/* cmacs-graphcore-graph.h --- pure-C graph model.
 *
 * Copyright (C) 2026 Zach Podbielniak
 * SPDX-License-Identifier: AGPL-3.0-or-later
 *
 * The node/edge store shared by every cmacs graph visualiser -- today
 * roamgraph (an org-roam knowledge graph) and secondbrain (an ARMS
 * second brain).  It is deliberately domain-neutral: it knows about
 * ids, titles, groups, degrees and positions, and nothing about where
 * any of those came from.
 *
 * This header is deliberately in the THIRD translation-unit class: it
 * includes neither "lisp.h" nor <libregnum.h>, only <glib.h>.  Every
 * consumer shares it, and -- more importantly -- the graph and the
 * solver that sits on top of it can therefore be unit tested with no
 * Lisp VM and no GL context.  (Same reasoning as
 * cmacs-gnuseye-geomath.h.)  That property is why the layout maths has
 * real tests, so preserve it: a lisp.h or libregnum.h include here
 * costs the entire headless test tier.
 *
 * Identity: nodes are keyed by a caller-chosen id string, never by
 * index -- an org-roam UUID in roamgraph, a stable path-like key in
 * secondbrain.  Indices are dense and stable only within one finalized
 * generation; the id is what survives a rebuild, so it is also what
 * gets handed to the libregnum node table as the pick `path'.
 *
 * Adjacency is stored as a CSR (compressed sparse row) slice per node
 * covering BOTH directions, with a parallel direction byte, so the
 * navigation layer can walk forward links and backlinks without
 * building a second structure. */

#ifndef CMACS_GRAPHCORE_GRAPH_H
#define CMACS_GRAPHCORE_GRAPH_H

#include <config.h>

#ifdef HAVE_CMACS_GRAPHCORE

#include <glib.h>

G_BEGIN_DECLS

/* Edge provenance.  `id' edges are the real topology -- org-roam
 * [[id:]] links in roamgraph, containment and wiring in secondbrain;
 * `cite' from citations; `sim' from the ai-brigade semantic index (an
 * overlay, excluded from link navigation by default). */
typedef enum
{
  CMACS_GRAPH_EDGE_ID   = 0,
  CMACS_GRAPH_EDGE_CITE = 1,
  CMACS_GRAPH_EDGE_SIM  = 2
} CmacsGraphEdgeKind;

/* Direction byte stored alongside each CSR adjacency entry. */
typedef enum
{
  CMACS_GRAPH_DIR_OUT = 0,   /* this node links TO the neighbour */
  CMACS_GRAPH_DIR_IN  = 1    /* the neighbour links TO this node */
} CmacsGraphDir;

typedef struct
{
  gchar   *id;          /* node id (owned, the identity key) */
  gchar   *title;       /* display title (owned) */
  gchar   *file;        /* absolute path (owned, may be NULL) */
  gchar   *group;       /* PARA bucket / colour group (owned, may be NULL) */
  int      level;       /* 0 = file-level node, >0 = heading level */
  int      pos;         /* character position of the node in FILE */
  guint32  rgba;        /* 0xRRGGBBAA, assigned by the Lisp side */

  int      in_deg;      /* number of backlinks */
  int      out_deg;     /* number of forward links */

  guint    edge_first;  /* first index of this node's slice of adj[] */
  guint    edge_count;  /* length of that slice (in_deg + out_deg) */

  float    x, y, z;     /* layout position */
  float    vx, vy, vz;  /* per-step displacement scratch (solver-owned) */
  float    radius;      /* render radius, derived from degree */

  /* Tween endpoints.  Kept separate from x/y/z and from the solver's
   * vx/vy/vz scratch on purpose: a tween and a solve are different
   * animations and overlapping their storage makes an interrupted
   * transition land somewhere neither of them intended. */
  float    sx, sy, sz;  /* where this tween started */
  float    tx, ty, tz;  /* where it is going */

  /* Hierarchy, for collapse/expand.  A visualiser over 35k files
   * cannot draw 35k nodes; it draws hubs that expand. */
  gint32   parent;      /* index of the parent node, or -1 for a root */
  guint32  descendants; /* transitive child count, for hub sizing */
  guint8   ring;        /* concentric band, 0 = innermost (RINGS layout) */

  guint8   pinned;      /* user pinned: the solver must not move it */
  guint8   placed;      /* position is meaningful (survivor or seeded) */
  guint8   collapsed;   /* this node's subtree is folded into it */
  guint8   visible;     /* included in the rendered set */
} CmacsGraphNode;

typedef struct
{
  guint32 a;            /* source node index */
  guint32 b;            /* destination node index */
  guint8  kind;         /* CmacsGraphEdgeKind */
  float   w;            /* attraction weight */
} CmacsGraphEdge;

typedef struct
{
  GArray     *nodes;      /* CmacsGraphNode, dense */
  GArray     *edges;      /* CmacsGraphEdge, dense, deduped */
  GHashTable *by_id;      /* borrowed gchar* -> GUINT_TO_POINTER (idx + 1) */

  GArray     *adj;        /* guint32 neighbour indices (CSR) */
  GArray     *adj_dir;    /* guint8 CmacsGraphDir, parallel to adj */

  /* Retained across begin_update so surviving nodes keep their
   * positions -- a refresh must not teleport the whole layout. */
  GArray     *old_nodes;
  GHashTable *old_by_id;

  GHashTable *edge_seen;  /* dedup key during an update */

  guint32     generation; /* bumped on every finalize */
  guint32     seed;       /* deterministic RNG seed */
  guint32     rng;        /* xorshift32 state */
  gboolean    updating;   /* between begin_update and finalize */
} CmacsGraph;

/* Lifecycle.  SEED drives the layout jitter; the same seed and the same
 * input always produce byte-identical positions (there is deliberately
 * no g_random_* anywhere in the solver). */
extern CmacsGraph *cmacs_graph_new  (guint32 seed);
extern void            cmacs_graph_free (CmacsGraph *g);

/* Replace the contents.  Call begin_update, then add_node for every
 * node, then add_edge for every edge, then finalize.  Nodes whose id
 * was present in the previous generation inherit their position. */
extern void  cmacs_graph_begin_update (CmacsGraph *g);

/* Returns the new node's index.  A duplicate id is ignored and the
 * existing index returned.  All strings are copied. */
/* Returns the node's index, or -1 when the node cap is reached.
 * Signed on purpose: returning 0 for "full" aliased every overflowing
 * node onto node 0, which silently corrupted the graph instead of
 * dropping the node. */
extern gint cmacs_graph_add_node (CmacsGraph *g,
                                        const char *id,
                                        const char *title,
                                        const char *file,
                                        const char *group,
                                        int level, int pos,
                                        guint32 rgba);

/* Add an edge by id.  Silently drops self-loops, duplicates (same
 * unordered pair + kind), and links whose endpoints are not both
 * present -- dangling [[id:]] links are common in a live notes tree.
 * Returns TRUE if the edge was actually added. */
extern gboolean cmacs_graph_add_edge (CmacsGraph *g,
                                           const char *from_id,
                                           const char *to_id,
                                           CmacsGraphEdgeKind kind,
                                           float weight);

/* Build the CSR, degrees and render radii; bump the generation.  Must
 * be called before any accessor below is meaningful. */
extern void cmacs_graph_finalize (CmacsGraph *g);

/* Accessors. */
extern guint           cmacs_graph_n_nodes (CmacsGraph *g);
extern guint           cmacs_graph_n_edges (CmacsGraph *g);
extern CmacsGraphNode  *cmacs_graph_node    (CmacsGraph *g, guint i);
extern CmacsGraphEdge  *cmacs_graph_edge    (CmacsGraph *g, guint i);
/* -1 when ID is unknown. */
extern gint            cmacs_graph_index_of (CmacsGraph *g,
                                                  const char *id);

/* Borrowed view of node I's CSR slice.  *N_OUT receives the length;
 * DIRS, when non-NULL, receives the parallel direction array. */
extern const guint32 *cmacs_graph_neighbours (CmacsGraph *g,
                                                   guint i,
                                                   const guint8 **dirs,
                                                   guint *n_out);

/* Deterministic xorshift32 in [0,1).  Exposed so the solver and the
 * scene builder draw from the same reproducible stream. */
extern float cmacs_graph_rand (CmacsGraph *g);

/* Reset the RNG stream to the configured seed (called by finalize so a
 * rebuild of identical input is bit-reproducible). */
extern void cmacs_graph_reset_rand (CmacsGraph *g);

/* ---- Hierarchy ---------------------------------------------------
 *
 * Optional: a graph with no parents set behaves exactly as before,
 * every node a visible root.  Set parents between begin_update and
 * finalize; finalize computes `descendants' and initial visibility. */

/* Declare CHILD's parent.  Both are node indices from add_node.  A
 * cycle or an out-of-range index is refused rather than propagated --
 * the visibility walk below would not terminate. */
extern gboolean cmacs_graph_set_parent (CmacsGraph *g,
                                        guint child, gint parent);

/* Fold or unfold node IDX's subtree.  Descendants of a collapsed node
 * are invisible; a node is visible only when no ancestor is collapsed.
 * Returns TRUE when visibility actually changed. */
extern gboolean cmacs_graph_set_collapsed (CmacsGraph *g,
                                           guint idx, gboolean collapsed);

/* Collapse or expand every node that has children. */
extern void cmacs_graph_collapse_all (CmacsGraph *g, gboolean collapsed);

/* Recompute `visible' for every node from the collapsed flags.  Called
 * by finalize and by set_collapsed; exposed for a caller that sets
 * `collapsed' in bulk. */
extern void cmacs_graph_refresh_visibility (CmacsGraph *g);

/* Number of nodes with visible != 0. */
extern guint cmacs_graph_n_visible (CmacsGraph *g);

G_END_DECLS

#endif /* HAVE_CMACS_GRAPHCORE */
#endif /* CMACS_GRAPHCORE_GRAPH_H */
