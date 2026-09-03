/* cmacs-roamgraph-defuns.c --- Elisp <-> roam graph boundary DEFUNs.
 *
 * Copyright (C) 2026 Zach Podbielniak
 * SPDX-License-Identifier: AGPL-3.0-or-later
 *
 * The Lisp-facing core of roamgraph.  Owns the per-buffer graph and
 * layout solver, turns node/edge plists into libregnum drawables via
 * the plain-C render half (cmacs-roamgraph-scene.h), and stashes each
 * node's plist as the scene node's libregnum payload so a pick returns
 * the full record.
 *
 * Never includes <libregnum.h> -- it talks to the render half through
 * the opaque CmacsLibregnumRenderCtx, exactly like
 * cmacs-gnuseye-defuns.c. */

#include <config.h>

#ifdef HAVE_CMACS_ROAMGRAPH

#include "lisp.h"
#include "buffer.h"
#include "coding.h"
#include "cmacs-roamgraph.h"
#include "cmacs-graphcore-graph.h"
#include "cmacs-graphcore-layout.h"
#include "cmacs-roamgraph-scene.h"
#include "cmacs-libregnum.h"
#include "cmacs-libregnum-render.h"

/* Cached keyword symbols for the node/edge plists (set in syms_of). */
static Lisp_Object QCrg_id, QCrg_title, QCrg_file, QCrg_level, QCrg_pos,
  QCrg_group, QCrg_color, QCrg_from, QCrg_to, QCrg_kind, QCrg_weight;

/* Edge-kind and direction symbols.  Interned rather than DEFSYM'd:
   `both' is already DEFSYM'd by xdisp.c, and a duplicate DEFSYM is a
   link error, so all of these go through intern_c_string for
   consistency. */
static Lisp_Object Qrg_id_kind, Qrg_cite, Qrg_sim;
static Lisp_Object Qrg_out, Qrg_in, Qrg_both;

/* buffer -> node-id-string -> node plist.  GC-rooted via staticpro:
   a Lisp_Object living in GLib-allocated memory would not be, so the
   payloads are deliberately kept in a Lisp hash rather than hung off
   the C graph. */
static Lisp_Object Vcmacs_roamgraph__payloads;

/* ── Per-buffer C state ────────────────────────────────────────────
 * Keyed by the CmacsLibregnumView, which the libregnum layer already
 * keys by buffer.  Torn down when the view goes away. */

typedef struct
{
  CmacsGraph  *graph;
  CmacsGraphLayout *layout;
  int              dims;
} RoamState;

static GHashTable *s_states;    /* CmacsLibregnumView* -> RoamState* */

static void
roam_state_free (gpointer p)
{
  RoamState *st = p;

  if (!st) return;
  cmacs_graph_layout_free (st->layout);
  cmacs_graph_free (st->graph);
  g_free (st);
}

static RoamState *
roam_state (CmacsLibregnumView *v, bool create)
{
  RoamState *st;

  if (!v) return NULL;
  if (!s_states)
    {
      if (!create) return NULL;
      s_states = g_hash_table_new_full (NULL, NULL, NULL, roam_state_free);
    }
  st = g_hash_table_lookup (s_states, v);
  if (!st && create)
    {
      st = g_new0 (RoamState, 1);
      st->graph  = cmacs_graph_new (0x9E3779B9u);
      st->layout = cmacs_graph_layout_new ();
      st->dims   = 3;
      g_hash_table_insert (s_states, v, st);
    }
  return st;
}

/* Resolve BUFFER to its view + state, or NULL. */
static RoamState *
state_for_buffer (Lisp_Object buffer, CmacsLibregnumView **v_out,
                  CmacsLibregnumRenderCtx **ctx_out)
{
  CmacsLibregnumView *v = cmacs_libregnum_view_for_buffer (buffer);
  RoamState *st;

  if (v_out)   *v_out   = NULL;
  if (ctx_out) *ctx_out = NULL;
  if (!v) return NULL;

  st = roam_state (v, false);
  if (!st) return NULL;

  if (v_out)   *v_out   = v;
  if (ctx_out) *ctx_out = cmacs_libregnum_view_get_render_ctx (v);
  return st;
}

/* ── plist readers ─────────────────────────────────────────────────── */

static int
rg_int (Lisp_Object plist, Lisp_Object key, int def)
{
  Lisp_Object v = plist_get (plist, key);
  if (FIXNUMP (v)) return (int) XFIXNUM (v);
  return def;
}

static double
rg_double (Lisp_Object plist, Lisp_Object key, double def)
{
  Lisp_Object v = plist_get (plist, key);
  if (FIXNUMP (v)) return (double) XFIXNUM (v);
  if (FLOATP (v))  return XFLOAT_DATA (v);
  return def;
}

/* Encoded-UTF-8 string field, or NULL.  Stores the encoded Lisp string
 * in *KEEP so its bytes stay live for the duration of the caller's use
 * -- the C side copies immediately, but the pointer must not dangle in
 * between. */
static const char *
rg_string (Lisp_Object plist, Lisp_Object key, Lisp_Object *keep)
{
  Lisp_Object v = plist_get (plist, key);
  if (!STRINGP (v)) return NULL;
  *keep = ENCODE_UTF_8 (v);
  return SSDATA (*keep);
}

static CmacsGraphEdgeKind
rg_edge_kind (Lisp_Object plist)
{
  Lisp_Object v = plist_get (plist, QCrg_kind);

  if (EQ (v, Qrg_sim))  return CMACS_GRAPH_EDGE_SIM;
  if (EQ (v, Qrg_cite)) return CMACS_GRAPH_EDGE_CITE;
  return CMACS_GRAPH_EDGE_ID;
}

/* ── Payload table ─────────────────────────────────────────────────── */

static void
ensure_payloads (void)
{
  if (NILP (Vcmacs_roamgraph__payloads))
    Vcmacs_roamgraph__payloads = CALLN (Fmake_hash_table, QCtest, Qeq);
}

static Lisp_Object
buffer_payloads (Lisp_Object buffer, bool create)
{
  Lisp_Object inner;

  ensure_payloads ();
  inner = Fgethash (buffer, Vcmacs_roamgraph__payloads, Qnil);
  if (NILP (inner) && create)
    {
      inner = CALLN (Fmake_hash_table, QCtest, Qequal);
      Fputhash (buffer, inner, Vcmacs_roamgraph__payloads);
    }
  return inner;
}

/* ── DEFUNs: lifecycle ─────────────────────────────────────────────── */

DEFUN ("cmacs-roamgraph-supported-p", Fcmacs_roamgraph_supported_p,
       Scmacs_roamgraph_supported_p, 0, 0, 0,
       doc: /* Return non-nil if this build includes the roamgraph subsystem.  */)
  (void)
{
  return Qt;
}

DEFUN ("cmacs-roamgraph-attach", Fcmacs_roamgraph_attach,
       Scmacs_roamgraph_attach, 1, 3, 0,
       doc: /* Attach a roam-graph viewport to BUFFER, WIDTH by HEIGHT pixels.
Creates the underlying libregnum view if BUFFER does not already have
one.  Idempotent.  Returns t.  */)
  (Lisp_Object buffer, Lisp_Object width, Lisp_Object height)
{
  CmacsLibregnumView *v;
  int w, h;

  CHECK_BUFFER (buffer);
  w = FIXNUMP (width)  ? (int) XFIXNUM (width)  : 800;
  h = FIXNUMP (height) ? (int) XFIXNUM (height) : 500;
  if (w < 16) w = 16;
  if (h < 16) h = 16;

  v = cmacs_libregnum_view_for_buffer (buffer);
  if (!v)
    v = cmacs_libregnum_view_new (buffer, w, h);
  if (!v)
    error ("cmacs-roamgraph: could not create a libregnum view");

  roam_state (v, true);
  return Qt;
}

DEFUN ("cmacs-roamgraph-detach", Fcmacs_roamgraph_detach,
       Scmacs_roamgraph_detach, 1, 1, 0,
       doc: /* Tear down BUFFER's roam-graph state and its libregnum view.  */)
  (Lisp_Object buffer)
{
  CmacsLibregnumView *v;

  CHECK_BUFFER (buffer);
  v = cmacs_libregnum_view_for_buffer (buffer);
  if (!v) return Qnil;

  if (s_states) g_hash_table_remove (s_states, v);
  if (!NILP (Vcmacs_roamgraph__payloads))
    Fremhash (buffer, Vcmacs_roamgraph__payloads);
  cmacs_libregnum_view_destroy (v);
  return Qt;
}

DEFUN ("cmacs-roamgraph-attached-p", Fcmacs_roamgraph_attached_p,
       Scmacs_roamgraph_attached_p, 1, 1, 0,
       doc: /* Return non-nil if BUFFER has a live roam-graph viewport.  */)
  (Lisp_Object buffer)
{
  CHECK_BUFFER (buffer);
  return state_for_buffer (buffer, NULL, NULL) ? Qt : Qnil;
}

/* ── DEFUNs: the data contract ─────────────────────────────────────── */

DEFUN ("cmacs-roamgraph-set-graph", Fcmacs_roamgraph_set_graph,
       Scmacs_roamgraph_set_graph, 3, 4, 0,
       doc: /* Replace BUFFER's graph with NODES and EDGES, then lay it out.

NODES is a vector (or list) of plists.  Recognised keys:
  :id     the org-roam node id string -- required, and the identity key
  :title  display title (defaults to :id)
  :file   absolute path of the file the node lives in
  :level  0 for a file-level node, >0 for a heading-level one
  :pos    character position of the node within :file
  :group  colour/grouping bucket, e.g. the PARA directory
  :color  0xRRGGBBAA integer
Any other keys are preserved and returned by `cmacs-roamgraph-node-at'.

EDGES is a vector (or list) of plists with :from and :to node-id
strings, an optional :kind (`id', `cite' or `sim'; default `id') and an
optional :weight float.  Edges whose endpoints are not both present in
NODES are dropped -- dangling [[id:]] links are normal in a live notes
tree.

DIMS selects the layout: 2 lays the graph out in the XY plane, 3 (the
default) uses all three axes.

Returns the number of nodes actually emitted.  */)
  (Lisp_Object buffer, Lisp_Object nodes, Lisp_Object edges,
   Lisp_Object dims)
{
  CmacsLibregnumView *v;
  CmacsLibregnumRenderCtx *ctx;
  RoamState *st;
  Lisp_Object nvec, evec, payloads;
  ptrdiff_t i, nn, ne;
  int d;
  guint emitted;

  CHECK_BUFFER (buffer);
  st = state_for_buffer (buffer, &v, &ctx);
  if (!st || !ctx) return Qnil;

  /* Accept either a vector or a list; the Lisp side builds vectors,
     but a caller poking at this from M-: should not have to care. */
  nvec = VECTORP (nodes) ? nodes : Fvconcat (1, &nodes);
  evec = VECTORP (edges) ? edges : Fvconcat (1, &edges);
  nn = ASIZE (nvec);
  ne = ASIZE (evec);

  d = FIXNUMP (dims) ? (int) XFIXNUM (dims) : 3;
  st->dims = (d == 2) ? 2 : 3;

  payloads = buffer_payloads (buffer, true);
  Fclrhash (payloads);

  cmacs_graph_begin_update (st->graph);

  for (i = 0; i < nn; i++)
    {
      Lisp_Object e = AREF (nvec, i);
      Lisp_Object k_id = Qnil, k_title = Qnil, k_file = Qnil, k_group = Qnil;
      const char *id, *title, *file, *group;
      guint32 rgba;

      if (!CONSP (e)) continue;
      id = rg_string (e, QCrg_id, &k_id);
      if (!id || !*id) continue;

      title = rg_string (e, QCrg_title, &k_title);
      file  = rg_string (e, QCrg_file,  &k_file);
      group = rg_string (e, QCrg_group, &k_group);
      /* :color arrives as a Lisp integer, which may exceed a fixnum on
         a 32-bit build, so read it as a double and truncate. */
      rgba = (guint32) rg_double (e, QCrg_color, 0.0);

      if (cmacs_graph_add_node (st->graph, id, title, file, group,
                                rg_int (e, QCrg_level, 0),
                                rg_int (e, QCrg_pos, 1),
                                rgba) < 0)
        continue;   /* graph is full; do not record a payload for a
                       node that was not added */

      /* Keep the whole plist so a pick returns the full record. */
      Fputhash (build_string_from_utf8 (id), e, payloads);
    }

  for (i = 0; i < ne; i++)
    {
      Lisp_Object e = AREF (evec, i);
      Lisp_Object k_from = Qnil, k_to = Qnil;
      const char *from, *to;

      if (!CONSP (e)) continue;
      from = rg_string (e, QCrg_from, &k_from);
      to   = rg_string (e, QCrg_to,   &k_to);
      if (!from || !to) continue;

      cmacs_graph_add_edge (st->graph, from, to, rg_edge_kind (e),
                                 (float) rg_double (e, QCrg_weight, 1.0));
    }

  cmacs_graph_finalize (st->graph);
  cmacs_graph_layout_begin (st->layout, st->graph, st->dims, 0);

  emitted = cmacs_roamgraph_scene_build (ctx, st->graph, st->dims);
  cmacs_roamgraph_scene_set_projection (ctx, st->dims == 2);
  cmacs_roamgraph_scene_fit (ctx, st->graph);
  cmacs_libregnum_view_request_redraw (v);

  return make_fixnum ((EMACS_INT) emitted);
}

DEFUN ("cmacs-roamgraph-node-at", Fcmacs_roamgraph_node_at,
       Scmacs_roamgraph_node_at, 2, 2, 0,
       doc: /* Return the node plist for NODE-ID in BUFFER, or nil.
NODE-ID is the org-roam id string.  Numeric scene ids are deliberately
not accepted: they are insertion indices and go stale on every
rebuild.  */)
  (Lisp_Object buffer, Lisp_Object node_id)
{
  Lisp_Object payloads;

  CHECK_BUFFER (buffer);
  CHECK_STRING (node_id);
  payloads = buffer_payloads (buffer, false);
  if (NILP (payloads)) return Qnil;
  return Fgethash (node_id, payloads, Qnil);
}

DEFUN ("cmacs-roamgraph-node-index", Fcmacs_roamgraph_node_index,
       Scmacs_roamgraph_node_index, 2, 2, 0,
       doc: /* Return the graph index of NODE-ID in BUFFER, or nil.  */)
  (Lisp_Object buffer, Lisp_Object node_id)
{
  RoamState *st;
  Lisp_Object enc;
  gint idx;

  CHECK_BUFFER (buffer);
  CHECK_STRING (node_id);
  st = state_for_buffer (buffer, NULL, NULL);
  if (!st) return Qnil;

  enc = ENCODE_UTF_8 (node_id);
  idx = cmacs_graph_index_of (st->graph, SSDATA (enc));
  return (idx < 0) ? Qnil : make_fixnum (idx);
}

DEFUN ("cmacs-roamgraph-node-id", Fcmacs_roamgraph_node_id,
       Scmacs_roamgraph_node_id, 2, 2, 0,
       doc: /* Return the org-roam id string at graph INDEX in BUFFER, or nil.  */)
  (Lisp_Object buffer, Lisp_Object index)
{
  RoamState *st;
  CmacsGraphNode *nd;

  CHECK_BUFFER (buffer);
  CHECK_FIXNUM (index);
  st = state_for_buffer (buffer, NULL, NULL);
  if (!st || XFIXNUM (index) < 0) return Qnil;

  nd = cmacs_graph_node (st->graph, (guint) XFIXNUM (index));
  return nd ? build_string_from_utf8 (nd->id) : Qnil;
}

DEFUN ("cmacs-roamgraph-neighbors", Fcmacs_roamgraph_neighbors,
       Scmacs_roamgraph_neighbors, 2, 3, 0,
       doc: /* Return NODE-ID's neighbours in BUFFER as a list of id strings.

DIRECTION selects which: `out' for forward links, `in' for backlinks,
nil or `both' for everything.  The order is stable across rebuilds
(forward links first, then backlinks, alphabetical by title within
each), which is what makes peer cycling return you where you
started.  */)
  (Lisp_Object buffer, Lisp_Object node_id, Lisp_Object direction)
{
  RoamState *st;
  Lisp_Object enc, out = Qnil;
  const guint32 *nb;
  const guint8 *dirs;
  guint cnt = 0, j;
  gint idx;
  bool want_out, want_in;

  CHECK_BUFFER (buffer);
  CHECK_STRING (node_id);
  st = state_for_buffer (buffer, NULL, NULL);
  if (!st) return Qnil;

  want_out = NILP (direction) || EQ (direction, Qrg_both)
             || EQ (direction, Qrg_out);
  want_in  = NILP (direction) || EQ (direction, Qrg_both)
             || EQ (direction, Qrg_in);

  enc = ENCODE_UTF_8 (node_id);
  idx = cmacs_graph_index_of (st->graph, SSDATA (enc));
  if (idx < 0) return Qnil;

  nb = cmacs_graph_neighbours (st->graph, (guint) idx, &dirs, &cnt);
  if (!nb) return Qnil;

  /* Build back-to-front so the result comes out in slice order. */
  for (j = cnt; j > 0; j--)
    {
      guint p = j - 1;
      CmacsGraphNode *o = cmacs_graph_node (st->graph, nb[p]);

      if (!o) continue;
      if (dirs[p] == CMACS_GRAPH_DIR_OUT ? !want_out : !want_in) continue;
      out = Fcons (build_string_from_utf8 (o->id), out);
    }
  return out;
}

DEFUN ("cmacs-roamgraph-node-count", Fcmacs_roamgraph_node_count,
       Scmacs_roamgraph_node_count, 1, 1, 0,
       doc: /* Return the number of nodes in BUFFER's graph.  */)
  (Lisp_Object buffer)
{
  RoamState *st;

  CHECK_BUFFER (buffer);
  st = state_for_buffer (buffer, NULL, NULL);
  if (!st) return Qnil;
  return make_fixnum ((EMACS_INT) cmacs_graph_n_nodes (st->graph));
}

DEFUN ("cmacs-roamgraph-edge-count", Fcmacs_roamgraph_edge_count,
       Scmacs_roamgraph_edge_count, 1, 1, 0,
       doc: /* Return the number of edges in BUFFER's graph.  */)
  (Lisp_Object buffer)
{
  RoamState *st;

  CHECK_BUFFER (buffer);
  st = state_for_buffer (buffer, NULL, NULL);
  if (!st) return Qnil;
  return make_fixnum ((EMACS_INT) cmacs_graph_n_edges (st->graph));
}

/* ── DEFUNs: layout ────────────────────────────────────────────────── */

DEFUN ("cmacs-roamgraph-layout-step", Fcmacs_roamgraph_layout_step,
       Scmacs_roamgraph_layout_step, 1, 2, 0,
       doc: /* Advance BUFFER's layout by N iterations (default 1).
Pushes the new positions into the scene and requests a redraw.  Returns
t once the layout has converged, so the caller's timer knows to stop.  */)
  (Lisp_Object buffer, Lisp_Object n)
{
  CmacsLibregnumView *v;
  CmacsLibregnumRenderCtx *ctx;
  RoamState *st;
  bool done;

  CHECK_BUFFER (buffer);
  st = state_for_buffer (buffer, &v, &ctx);
  if (!st || !ctx) return Qt;

  done = cmacs_graph_layout_step (st->layout, st->graph,
                                 FIXNUMP (n) ? (int) XFIXNUM (n) : 1);
  cmacs_roamgraph_scene_sync_positions (ctx, st->graph);
  cmacs_libregnum_view_request_redraw (v);
  return done ? Qt : Qnil;
}

DEFUN ("cmacs-roamgraph-layout-converged-p",
       Fcmacs_roamgraph_layout_converged_p,
       Scmacs_roamgraph_layout_converged_p, 1, 1, 0,
       doc: /* Return non-nil if BUFFER's layout has settled.  */)
  (Lisp_Object buffer)
{
  RoamState *st;

  CHECK_BUFFER (buffer);
  st = state_for_buffer (buffer, NULL, NULL);
  if (!st) return Qt;
  return cmacs_graph_layout_converged (st->layout) ? Qt : Qnil;
}

DEFUN ("cmacs-roamgraph-layout-progress", Fcmacs_roamgraph_layout_progress,
       Scmacs_roamgraph_layout_progress, 1, 1, 0,
       doc: /* Return BUFFER's layout progress as a float in [0,1].  */)
  (Lisp_Object buffer)
{
  RoamState *st;

  CHECK_BUFFER (buffer);
  st = state_for_buffer (buffer, NULL, NULL);
  if (!st) return make_float (1.0);
  return make_float (cmacs_graph_layout_progress (st->layout));
}

DEFUN ("cmacs-roamgraph-layout-reheat", Fcmacs_roamgraph_layout_reheat,
       Scmacs_roamgraph_layout_reheat, 1, 3, 0,
       doc: /* Re-arm BUFFER's settled layout so it relaxes again.
FRAC is the fraction of the initial temperature to restart at (default
0.3) and ITERS how many extra iterations to run (default 120).  */)
  (Lisp_Object buffer, Lisp_Object frac, Lisp_Object iters)
{
  RoamState *st;

  CHECK_BUFFER (buffer);
  st = state_for_buffer (buffer, NULL, NULL);
  if (!st) return Qnil;

  cmacs_graph_layout_reheat (st->layout,
                            FLOATP (frac) ? XFLOAT_DATA (frac) : 0.3,
                            FIXNUMP (iters) ? (int) XFIXNUM (iters) : 120);
  return Qt;
}

DEFUN ("cmacs-roamgraph-set-layout-theta", Fcmacs_roamgraph_set_layout_theta,
       Scmacs_roamgraph_set_layout_theta, 2, 2, 0,
       doc: /* Set BUFFER's Barnes-Hut opening angle to THETA.
Larger is faster and coarser; the default is 0.9.  THETA of 0 forces an
exact all-pairs repulsion sum, which is the reference the tests compare
the approximation against.  */)
  (Lisp_Object buffer, Lisp_Object theta)
{
  RoamState *st;

  CHECK_BUFFER (buffer);
  st = state_for_buffer (buffer, NULL, NULL);
  if (!st) return Qnil;

  cmacs_graph_layout_set_theta (st->layout,
                               FLOATP (theta) ? XFLOAT_DATA (theta)
                               : (double) XFIXNUM (theta));
  return Qt;
}

DEFUN ("cmacs-roamgraph-node-position", Fcmacs_roamgraph_node_position,
       Scmacs_roamgraph_node_position, 2, 2, 0,
       doc: /* Return NODE-ID's layout position in BUFFER as (X Y Z), or nil.  */)
  (Lisp_Object buffer, Lisp_Object node_id)
{
  RoamState *st;
  CmacsGraphNode *nd;
  Lisp_Object enc;
  gint idx;

  CHECK_BUFFER (buffer);
  CHECK_STRING (node_id);
  st = state_for_buffer (buffer, NULL, NULL);
  if (!st) return Qnil;

  enc = ENCODE_UTF_8 (node_id);
  idx = cmacs_graph_index_of (st->graph, SSDATA (enc));
  if (idx < 0) return Qnil;

  nd = cmacs_graph_node (st->graph, (guint) idx);
  return list3 (make_float (nd->x), make_float (nd->y), make_float (nd->z));
}

DEFUN ("cmacs-roamgraph-set-pinned", Fcmacs_roamgraph_set_pinned,
       Scmacs_roamgraph_set_pinned, 3, 3, 0,
       doc: /* Pin (ON non-nil) or unpin NODE-ID in BUFFER.
A pinned node is never moved by the layout solver.  */)
  (Lisp_Object buffer, Lisp_Object node_id, Lisp_Object on)
{
  RoamState *st;
  CmacsGraphNode *nd;
  Lisp_Object enc;
  gint idx;

  CHECK_BUFFER (buffer);
  CHECK_STRING (node_id);
  st = state_for_buffer (buffer, NULL, NULL);
  if (!st) return Qnil;

  enc = ENCODE_UTF_8 (node_id);
  idx = cmacs_graph_index_of (st->graph, SSDATA (enc));
  if (idx < 0) return Qnil;

  nd = cmacs_graph_node (st->graph, (guint) idx);
  nd->pinned = NILP (on) ? 0 : 1;
  return Qt;
}

/* ── DEFUNs: camera / view ─────────────────────────────────────────── */

DEFUN ("cmacs-roamgraph-set-projection", Fcmacs_roamgraph_set_projection,
       Scmacs_roamgraph_set_projection, 2, 2, 0,
       doc: /* Switch BUFFER to a flat 2D view when FLAT is non-nil, else 3D.
This only changes the camera; re-run `cmacs-roamgraph-set-graph' with a
DIMS argument to also re-solve the layout in that dimensionality.  */)
  (Lisp_Object buffer, Lisp_Object flat)
{
  CmacsLibregnumView *v;
  CmacsLibregnumRenderCtx *ctx;
  RoamState *st;

  CHECK_BUFFER (buffer);
  st = state_for_buffer (buffer, &v, &ctx);
  if (!st || !ctx) return Qnil;

  cmacs_roamgraph_scene_set_projection (ctx, !NILP (flat));
  cmacs_roamgraph_scene_fit (ctx, st->graph);
  cmacs_libregnum_view_request_redraw (v);
  return Qt;
}

DEFUN ("cmacs-roamgraph-flat-p", Fcmacs_roamgraph_flat_p,
       Scmacs_roamgraph_flat_p, 1, 1, 0,
       doc: /* Return non-nil if BUFFER is showing the flat 2D view.  */)
  (Lisp_Object buffer)
{
  CmacsLibregnumRenderCtx *ctx;

  CHECK_BUFFER (buffer);
  if (!state_for_buffer (buffer, NULL, &ctx) || !ctx) return Qnil;
  return cmacs_roamgraph_scene_flat_p (ctx) ? Qt : Qnil;
}

DEFUN ("cmacs-roamgraph-apply-flags", Fcmacs_roamgraph_apply_flags,
       Scmacs_roamgraph_apply_flags, 1, 1, 0,
       doc: /* Recolour BUFFER's scene from the current per-node flags.
Call after `cmacs-libregnum-set-match-set' so search matches take their
accent colour and the rest of the graph dims.  Mutates the existing
drawables rather than rebuilding, so it is cheap enough to run on every
keystroke.  */)
  (Lisp_Object buffer)
{
  CmacsLibregnumView *v;
  CmacsLibregnumRenderCtx *ctx;
  RoamState *st;

  CHECK_BUFFER (buffer);
  st = state_for_buffer (buffer, &v, &ctx);
  if (!st || !ctx) return Qnil;

  cmacs_roamgraph_scene_apply_flags (ctx, st->graph);
  cmacs_libregnum_view_request_redraw (v);
  return Qt;
}

DEFUN ("cmacs-roamgraph-zoom", Fcmacs_roamgraph_zoom,
       Scmacs_roamgraph_zoom, 2, 2, 0,
       doc: /* Zoom BUFFER's camera by AMOUNT (negative moves closer).  */)
  (Lisp_Object buffer, Lisp_Object amount)
{
  CmacsLibregnumView *v;
  CmacsLibregnumRenderCtx *ctx;

  CHECK_BUFFER (buffer);
  if (!state_for_buffer (buffer, &v, &ctx) || !ctx) return Qnil;

  cmacs_libregnum_render_ctx_zoom_camera
    (ctx, FLOATP (amount) ? XFLOAT_DATA (amount)
     : FIXNUMP (amount) ? (double) XFIXNUM (amount) : 0.0);
  cmacs_libregnum_view_request_redraw (v);
  return Qt;
}

DEFUN ("cmacs-roamgraph-pan", Fcmacs_roamgraph_pan,
       Scmacs_roamgraph_pan, 3, 3, 0,
       doc: /* Slide BUFFER's view by DX and DY screen pixels.
Works the same in the flat and three-dimensional views: the camera
moves across its own view plane, which is what "move around" means in
both.  */)
  (Lisp_Object buffer, Lisp_Object dx, Lisp_Object dy)
{
  CmacsLibregnumView *v;
  CmacsLibregnumRenderCtx *ctx;

  CHECK_BUFFER (buffer);
  if (!state_for_buffer (buffer, &v, &ctx) || !ctx) return Qnil;

  cmacs_libregnum_render_ctx_pan_camera
    (ctx,
     FLOATP (dx) ? XFLOAT_DATA (dx) : (double) XFIXNUM (dx),
     FLOATP (dy) ? XFLOAT_DATA (dy) : (double) XFIXNUM (dy));
  cmacs_libregnum_view_request_redraw (v);
  return Qt;
}

DEFUN ("cmacs-roamgraph-fit", Fcmacs_roamgraph_fit,
       Scmacs_roamgraph_fit, 1, 1, 0,
       doc: /* Frame BUFFER's whole graph in the viewport.  */)
  (Lisp_Object buffer)
{
  CmacsLibregnumView *v;
  CmacsLibregnumRenderCtx *ctx;
  RoamState *st;

  CHECK_BUFFER (buffer);
  st = state_for_buffer (buffer, &v, &ctx);
  if (!st || !ctx) return Qnil;

  cmacs_roamgraph_scene_fit (ctx, st->graph);
  cmacs_libregnum_view_request_redraw (v);
  return Qt;
}

/* ── syms_of ───────────────────────────────────────────────────────── */

void
syms_of_cmacs_roamgraph_defuns (void)
{
  QCrg_id     = intern_c_string (":id");
  QCrg_title  = intern_c_string (":title");
  QCrg_file   = intern_c_string (":file");
  QCrg_level  = intern_c_string (":level");
  QCrg_pos    = intern_c_string (":pos");
  QCrg_group  = intern_c_string (":group");
  QCrg_color  = intern_c_string (":color");
  QCrg_from   = intern_c_string (":from");
  QCrg_to     = intern_c_string (":to");
  QCrg_kind   = intern_c_string (":kind");
  QCrg_weight = intern_c_string (":weight");
  staticpro (&QCrg_id);
  staticpro (&QCrg_title);
  staticpro (&QCrg_file);
  staticpro (&QCrg_level);
  staticpro (&QCrg_pos);
  staticpro (&QCrg_group);
  staticpro (&QCrg_color);
  staticpro (&QCrg_from);
  staticpro (&QCrg_to);
  staticpro (&QCrg_kind);
  staticpro (&QCrg_weight);

  Qrg_id_kind = intern_c_string ("id");
  Qrg_cite    = intern_c_string ("cite");
  Qrg_sim     = intern_c_string ("sim");
  staticpro (&Qrg_id_kind);
  staticpro (&Qrg_cite);
  staticpro (&Qrg_sim);

  Qrg_out  = intern_c_string ("out");
  Qrg_in   = intern_c_string ("in");
  Qrg_both = intern_c_string ("both");
  staticpro (&Qrg_out);
  staticpro (&Qrg_in);
  staticpro (&Qrg_both);

  Vcmacs_roamgraph__payloads = Qnil;
  staticpro (&Vcmacs_roamgraph__payloads);

  defsubr (&Scmacs_roamgraph_supported_p);
  defsubr (&Scmacs_roamgraph_attach);
  defsubr (&Scmacs_roamgraph_detach);
  defsubr (&Scmacs_roamgraph_attached_p);
  defsubr (&Scmacs_roamgraph_set_graph);
  defsubr (&Scmacs_roamgraph_node_at);
  defsubr (&Scmacs_roamgraph_node_index);
  defsubr (&Scmacs_roamgraph_node_id);
  defsubr (&Scmacs_roamgraph_neighbors);
  defsubr (&Scmacs_roamgraph_node_count);
  defsubr (&Scmacs_roamgraph_edge_count);
  defsubr (&Scmacs_roamgraph_layout_step);
  defsubr (&Scmacs_roamgraph_layout_converged_p);
  defsubr (&Scmacs_roamgraph_layout_progress);
  defsubr (&Scmacs_roamgraph_layout_reheat);
  defsubr (&Scmacs_roamgraph_set_layout_theta);
  defsubr (&Scmacs_roamgraph_node_position);
  defsubr (&Scmacs_roamgraph_set_pinned);
  defsubr (&Scmacs_roamgraph_set_projection);
  defsubr (&Scmacs_roamgraph_flat_p);
  defsubr (&Scmacs_roamgraph_fit);
  defsubr (&Scmacs_roamgraph_apply_flags);
  defsubr (&Scmacs_roamgraph_zoom);
  defsubr (&Scmacs_roamgraph_pan);
}

#endif /* HAVE_CMACS_ROAMGRAPH */
