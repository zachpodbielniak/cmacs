/* cmacs-roamgraph-graph.h --- pure-C org-roam graph model.
 *
 * Copyright (C) 2026 Zach Podbielniak
 * SPDX-License-Identifier: AGPL-3.0-or-later
 *
 * The node/edge store behind the roamgraph visualiser.  This header is
 * deliberately in the THIRD translation-unit class: it includes neither
 * "lisp.h" nor <libregnum.h>, only <glib.h>.  Both halves of the
 * subsystem share it, and -- more importantly -- the graph and the
 * force-directed solver that sits on top of it can therefore be unit
 * tested with no Lisp VM and no GL context.  (Same reasoning as
 * cmacs-gnuseye-geomath.h.)
 *
 * Identity: nodes are keyed by their org-roam id string, never by
 * index.  Indices are dense and stable only within one finalized
 * generation; the id is what survives a rebuild, so it is also what
 * gets handed to the libregnum node table as the pick `path'.
 *
 * Adjacency is stored as a CSR (compressed sparse row) slice per node
 * covering BOTH directions, with a parallel direction byte, so the
 * navigation layer can walk forward links and backlinks without
 * building a second structure. */

#ifndef CMACS_ROAMGRAPH_GRAPH_H
#define CMACS_ROAMGRAPH_GRAPH_H

#include <config.h>

#ifdef HAVE_CMACS_ROAMGRAPH

#include <glib.h>

G_BEGIN_DECLS

/* Edge provenance.  `id' edges come from org-roam [[id:]] links and are
 * the real topology; `cite' from citations; `sim' from the ai-brigade
 * semantic index (an overlay, excluded from link navigation by
 * default). */
typedef enum
{
  CMACS_ROAM_EDGE_ID   = 0,
  CMACS_ROAM_EDGE_CITE = 1,
  CMACS_ROAM_EDGE_SIM  = 2
} CmacsRoamEdgeKind;

/* Direction byte stored alongside each CSR adjacency entry. */
typedef enum
{
  CMACS_ROAM_DIR_OUT = 0,   /* this node links TO the neighbour */
  CMACS_ROAM_DIR_IN  = 1    /* the neighbour links TO this node */
} CmacsRoamDir;

typedef struct
{
  gchar   *id;          /* org-roam node id (owned, the identity key) */
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

  guint8   pinned;      /* user pinned: the solver must not move it */
  guint8   placed;      /* position is meaningful (survivor or seeded) */
  guint8   visible;     /* included in the rendered set */
} CmacsRoamNode;

typedef struct
{
  guint32 a;            /* source node index */
  guint32 b;            /* destination node index */
  guint8  kind;         /* CmacsRoamEdgeKind */
  float   w;            /* attraction weight */
} CmacsRoamEdge;

typedef struct
{
  GArray     *nodes;      /* CmacsRoamNode, dense */
  GArray     *edges;      /* CmacsRoamEdge, dense, deduped */
  GHashTable *by_id;      /* borrowed gchar* -> GUINT_TO_POINTER (idx + 1) */

  GArray     *adj;        /* guint32 neighbour indices (CSR) */
  GArray     *adj_dir;    /* guint8 CmacsRoamDir, parallel to adj */

  /* Retained across begin_update so surviving nodes keep their
   * positions -- a refresh must not teleport the whole layout. */
  GArray     *old_nodes;
  GHashTable *old_by_id;

  GHashTable *edge_seen;  /* dedup key during an update */

  guint32     generation; /* bumped on every finalize */
  guint32     seed;       /* deterministic RNG seed */
  guint32     rng;        /* xorshift32 state */
  gboolean    updating;   /* between begin_update and finalize */
} CmacsRoamGraph;

/* Lifecycle.  SEED drives the layout jitter; the same seed and the same
 * input always produce byte-identical positions (there is deliberately
 * no g_random_* anywhere in the solver). */
extern CmacsRoamGraph *cmacs_roam_graph_new  (guint32 seed);
extern void            cmacs_roam_graph_free (CmacsRoamGraph *g);

/* Replace the contents.  Call begin_update, then add_node for every
 * node, then add_edge for every edge, then finalize.  Nodes whose id
 * was present in the previous generation inherit their position. */
extern void  cmacs_roam_graph_begin_update (CmacsRoamGraph *g);

/* Returns the new node's index.  A duplicate id is ignored and the
 * existing index returned.  All strings are copied. */
extern guint cmacs_roam_graph_add_node (CmacsRoamGraph *g,
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
extern gboolean cmacs_roam_graph_add_edge (CmacsRoamGraph *g,
                                           const char *from_id,
                                           const char *to_id,
                                           CmacsRoamEdgeKind kind,
                                           float weight);

/* Build the CSR, degrees and render radii; bump the generation.  Must
 * be called before any accessor below is meaningful. */
extern void cmacs_roam_graph_finalize (CmacsRoamGraph *g);

/* Accessors. */
extern guint           cmacs_roam_graph_n_nodes (CmacsRoamGraph *g);
extern guint           cmacs_roam_graph_n_edges (CmacsRoamGraph *g);
extern CmacsRoamNode  *cmacs_roam_graph_node    (CmacsRoamGraph *g, guint i);
extern CmacsRoamEdge  *cmacs_roam_graph_edge    (CmacsRoamGraph *g, guint i);
/* -1 when ID is unknown. */
extern gint            cmacs_roam_graph_index_of (CmacsRoamGraph *g,
                                                  const char *id);

/* Borrowed view of node I's CSR slice.  *N_OUT receives the length;
 * DIRS, when non-NULL, receives the parallel direction array. */
extern const guint32 *cmacs_roam_graph_neighbours (CmacsRoamGraph *g,
                                                   guint i,
                                                   const guint8 **dirs,
                                                   guint *n_out);

/* Deterministic xorshift32 in [0,1).  Exposed so the solver and the
 * scene builder draw from the same reproducible stream. */
extern float cmacs_roam_graph_rand (CmacsRoamGraph *g);

/* Reset the RNG stream to the configured seed (called by finalize so a
 * rebuild of identical input is bit-reproducible). */
extern void cmacs_roam_graph_reset_rand (CmacsRoamGraph *g);

G_END_DECLS

#endif /* HAVE_CMACS_ROAMGRAPH */
#endif /* CMACS_ROAMGRAPH_GRAPH_H */
