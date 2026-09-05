/* cmacs-secondbrain-defuns.c --- Elisp <-> second brain boundary DEFUNs.
 *
 * Copyright (C) 2026 Zach Podbielniak
 * SPDX-License-Identifier: AGPL-3.0-or-later
 *
 * The Lisp-facing core of secondbrain.  Owns the per-buffer graph and
 * layout, turns node/edge plists into libregnum drawables via the
 * plain-C render half (cmacs-secondbrain-scene.h), and stashes each
 * node's plist as the scene node's payload so a pick returns the full
 * record.
 *
 * Never includes <libregnum.h> -- it talks to the render half through
 * the opaque CmacsLibregnumRenderCtx, exactly like
 * cmacs-roamgraph-defuns.c. */

#include <config.h>

#ifdef HAVE_CMACS_SECONDBRAIN

#include "lisp.h"
#include "buffer.h"
#include "coding.h"
#include "cmacs-secondbrain.h"
#include "cmacs-secondbrain-model.h"
#include "cmacs-secondbrain-scene.h"
#include "cmacs-graphcore-graph.h"
#include "cmacs-graphcore-layout.h"
#include "cmacs-libregnum.h"
#include "cmacs-libregnum-render.h"

/* Cached keyword symbols for the node/edge plists (set in syms_of). */
static Lisp_Object QCsb_id, QCsb_title, QCsb_file, QCsb_ring, QCsb_kind,
  QCsb_department, QCsb_parent, QCsb_color, QCsb_collapsed,
  QCsb_from, QCsb_to, QCsb_edge_kind, QCsb_weight;

/* Edge-kind symbols.  Interned rather than DEFSYM'd, for the same
   reason roamgraph does: a duplicate DEFSYM of a symbol another file
   already owns is a link error. */
static Lisp_Object Qsb_sim, Qsb_cite;

/* Layout-kind symbols. */
static Lisp_Object Qsb_force, Qsb_circle, Qsb_hex, Qsb_rings;

/* buffer -> node-id-string -> node plist.  GC-rooted via staticpro: a
   Lisp_Object living in GLib-allocated memory would not be, so the
   payloads are kept in a Lisp hash rather than hung off the C graph. */
static Lisp_Object Vcmacs_secondbrain__payloads;

/* ── Per-buffer C state ────────────────────────────────────────────
 * Keyed by the CmacsLibregnumView, which the libregnum layer already
 * keys by buffer. */

typedef struct
{
  CmacsGraph       *graph;
  CmacsGraphLayout *layout;
  int               dims;
  double            ring_gap;
  double            galaxy_tilt;   /* radians; 0 = coplanar rings */
  CmacsGraphGalaxyShape galaxy_shape;
  gboolean          band_guides;
  CmacsGraphLayoutKind kind;
} SbState;

static GHashTable *s_states;    /* CmacsLibregnumView* -> SbState* */

static void
sb_state_free (gpointer p)
{
  SbState *st = p;

  if (!st) return;
  cmacs_graph_layout_free (st->layout);
  cmacs_graph_free (st->graph);
  g_free (st);
}

static SbState *
sb_state (CmacsLibregnumView *v, bool create)
{
  SbState *st;

  if (!v) return NULL;
  if (!s_states)
    {
      if (!create) return NULL;
      s_states = g_hash_table_new_full (NULL, NULL, NULL, sb_state_free);
    }
  st = g_hash_table_lookup (s_states, v);
  if (!st && create)
    {
      st = g_new0 (SbState, 1);
      st->graph       = cmacs_graph_new (0x9E3779B9u);
      st->layout      = cmacs_graph_layout_new ();
      st->dims        = 2;   /* rings read flat by default */
      st->ring_gap    = 6.0;
      st->band_guides = TRUE;
      st->kind        = CMACS_GRAPH_LAYOUT_RINGS;
      g_hash_table_insert (s_states, v, st);
    }
  return st;
}

static SbState *
state_for_buffer (Lisp_Object buffer, CmacsLibregnumView **v_out,
                  CmacsLibregnumRenderCtx **ctx_out)
{
  CmacsLibregnumView *v = cmacs_libregnum_view_for_buffer (buffer);
  SbState *st;

  if (v_out)   *v_out   = NULL;
  if (ctx_out) *ctx_out = NULL;
  if (!v) return NULL;

  st = sb_state (v, false);
  if (!st) return NULL;

  if (v_out)   *v_out   = v;
  if (ctx_out) *ctx_out = cmacs_libregnum_view_get_render_ctx (v);
  return st;
}

/* ── plist readers ─────────────────────────────────────────────────── */

static double
sb_double (Lisp_Object plist, Lisp_Object key, double def)
{
  Lisp_Object v = plist_get (plist, key);
  if (FIXNUMP (v)) return (double) XFIXNUM (v);
  if (FLOATP (v))  return XFLOAT_DATA (v);
  return def;
}

/* Encoded-UTF-8 string field, or NULL.  Stores the encoded Lisp string
 * in *KEEP so its bytes stay live for the caller's use -- the C side
 * copies immediately, but the pointer must not dangle in between. */
static const char *
sb_string (Lisp_Object plist, Lisp_Object key, Lisp_Object *keep)
{
  Lisp_Object v = plist_get (plist, key);
  if (!STRINGP (v)) return NULL;
  *keep = ENCODE_UTF_8 (v);
  return SSDATA (*keep);
}

/* :ring accepts a name ("memory") or an index.  Anything unrecognised
   falls back to Memory rather than signalling: a source that grows a
   new category should degrade, not take the whole graph down. */
static CmacsSbRing
sb_ring_of (Lisp_Object plist)
{
  Lisp_Object v = plist_get (plist, QCsb_ring);
  CmacsSbRing ring = CMACS_SB_RING_MEMORY;

  if (FIXNUMP (v))
    {
      EMACS_INT i = XFIXNUM (v);
      if (i >= 0 && i < CMACS_SB_RING_COUNT) return (CmacsSbRing) i;
      return CMACS_SB_RING_MEMORY;
    }
  if (SYMBOLP (v) && !NILP (v))
    {
      Lisp_Object enc = ENCODE_UTF_8 (SYMBOL_NAME (v));
      cmacs_sb_ring_from_name (SSDATA (enc), &ring);
      return ring;
    }
  if (STRINGP (v))
    {
      Lisp_Object enc = ENCODE_UTF_8 (v);
      cmacs_sb_ring_from_name (SSDATA (enc), &ring);
      return ring;
    }
  return ring;
}

static CmacsSbKind
sb_kind_of (Lisp_Object plist)
{
  Lisp_Object v = plist_get (plist, QCsb_kind);
  CmacsSbKind kind = CMACS_SB_KIND_FILE;

  if (SYMBOLP (v) && !NILP (v))
    {
      Lisp_Object enc = ENCODE_UTF_8 (SYMBOL_NAME (v));
      cmacs_sb_kind_from_name (SSDATA (enc), &kind);
      return kind;
    }
  if (STRINGP (v))
    {
      Lisp_Object enc = ENCODE_UTF_8 (v);
      cmacs_sb_kind_from_name (SSDATA (enc), &kind);
      return kind;
    }
  return kind;
}

static CmacsGraphEdgeKind
sb_edge_kind (Lisp_Object plist)
{
  Lisp_Object v = plist_get (plist, QCsb_edge_kind);

  if (EQ (v, Qsb_sim))  return CMACS_GRAPH_EDGE_SIM;
  if (EQ (v, Qsb_cite)) return CMACS_GRAPH_EDGE_CITE;
  return CMACS_GRAPH_EDGE_ID;
}

static CmacsGraphLayoutKind
sb_layout_kind (Lisp_Object sym)
{
  if (EQ (sym, Qsb_circle)) return CMACS_GRAPH_LAYOUT_CIRCLE;
  if (EQ (sym, Qsb_hex))    return CMACS_GRAPH_LAYOUT_HEX;
  if (EQ (sym, Qsb_force))  return CMACS_GRAPH_LAYOUT_FORCE;
  return CMACS_GRAPH_LAYOUT_RINGS;
}

/* ── Payload table ─────────────────────────────────────────────────── */

static void
ensure_payloads (void)
{
  if (NILP (Vcmacs_secondbrain__payloads))
    Vcmacs_secondbrain__payloads = CALLN (Fmake_hash_table, QCtest, Qeq);
}

static Lisp_Object
buffer_payloads (Lisp_Object buffer, bool create)
{
  Lisp_Object inner;

  ensure_payloads ();
  inner = Fgethash (buffer, Vcmacs_secondbrain__payloads, Qnil);
  if (NILP (inner) && create)
    {
      inner = CALLN (Fmake_hash_table, QCtest, Qequal);
      Fputhash (buffer, inner, Vcmacs_secondbrain__payloads);
    }
  return inner;
}

/* Re-place the current layout and hand the result to the scene.  The
   one place that decides whether a change animates. */
static void
sb_relayout (SbState *st, CmacsLibregnumRenderCtx *ctx, int frames)
{
  cmacs_graph_layout_set_ring_gap (st->layout, st->ring_gap);
  /* Pushed here rather than only when it is set, for the same reason as
     the ring gap: every relayout must re-state the shape it wants, so a
     layout switch cannot quietly flatten the disc. */
  cmacs_graph_layout_set_galaxy_tilt (st->layout, st->galaxy_tilt);
  cmacs_graph_layout_set_galaxy_shape (st->layout, st->galaxy_shape);

  if (st->kind == CMACS_GRAPH_LAYOUT_FORCE)
    {
      cmacs_graph_layout_begin (st->layout, st->graph, st->dims, 0);
      return;
    }

  cmacs_graph_layout_place (st->layout, st->graph, st->kind, st->dims);
  if (frames > 0)
    cmacs_graph_layout_tween_begin (st->layout, st->graph, frames);
  else
    {
      cmacs_graph_layout_snap (st->graph);
      if (ctx) cmacs_secondbrain_scene_sync_positions (ctx, st->graph);
    }
}

/* ── DEFUNs: lifecycle ─────────────────────────────────────────────── */

DEFUN ("cmacs-secondbrain-supported-p", Fcmacs_secondbrain_supported_p,
       Scmacs_secondbrain_supported_p, 0, 0, 0,
       doc: /* Return non-nil if this build includes the secondbrain subsystem.  */)
  (void)
{
  return Qt;
}

DEFUN ("cmacs-secondbrain-attach", Fcmacs_secondbrain_attach,
       Scmacs_secondbrain_attach, 1, 3, 0,
       doc: /* Attach a second-brain view to BUFFER at WIDTH x HEIGHT.
Returns t on success.  Idempotent: attaching an already-attached buffer
is a no-op.  */)
  (Lisp_Object buffer, Lisp_Object width, Lisp_Object height)
{
  CmacsLibregnumView *v;
  int w = FIXNUMP (width)  ? (int) XFIXNUM (width)  : 800;
  int h = FIXNUMP (height) ? (int) XFIXNUM (height) : 600;

  CHECK_BUFFER (buffer);

  if (NILP (Fcmacs_libregnum_attach (buffer, make_fixnum (w),
                                     make_fixnum (h))))
    return Qnil;

  v = cmacs_libregnum_view_for_buffer (buffer);
  if (!v) return Qnil;

  sb_state (v, true);
  return Qt;
}

DEFUN ("cmacs-secondbrain-detach", Fcmacs_secondbrain_detach,
       Scmacs_secondbrain_detach, 1, 1, 0,
       doc: /* Detach BUFFER's second-brain view and free its graph.  */)
  (Lisp_Object buffer)
{
  CmacsLibregnumView *v;

  CHECK_BUFFER (buffer);
  v = cmacs_libregnum_view_for_buffer (buffer);
  if (v)
    {
      CmacsLibregnumRenderCtx *ctx = cmacs_libregnum_view_get_render_ctx (v);
      if (ctx) cmacs_secondbrain_scene_reset (ctx);
      if (s_states) g_hash_table_remove (s_states, v);
    }

  ensure_payloads ();
  Fremhash (buffer, Vcmacs_secondbrain__payloads);
  return Fcmacs_libregnum_detach (buffer);
}

DEFUN ("cmacs-secondbrain-attached-p", Fcmacs_secondbrain_attached_p,
       Scmacs_secondbrain_attached_p, 1, 1, 0,
       doc: /* Return t when BUFFER has a second-brain view.  */)
  (Lisp_Object buffer)
{
  CHECK_BUFFER (buffer);
  return state_for_buffer (buffer, NULL, NULL) ? Qt : Qnil;
}

/* ── DEFUNs: data ──────────────────────────────────────────────────── */

DEFUN ("cmacs-secondbrain-set-graph", Fcmacs_secondbrain_set_graph,
       Scmacs_secondbrain_set_graph, 3, 4, 0,
       doc: /* Replace BUFFER's graph with NODES and EDGES, then lay it out.

NODES is a vector (or list) of plists.  Recognised keys:
  :id          identity key -- required, and what every piece of state
               is keyed on.  Scene indices churn on rebuild; this does
               not.
  :title       display title (defaults to :id)
  :file        absolute path, when the node is backed by one
  :ring        `skills', `memory', `routines' or `applications' (or an
               index).  Unrecognised falls back to `memory' rather than
               signalling -- a source that grows a category should
               degrade, not take the graph down.
  :kind        `hub', `file', `folder', `app', `routine', `skill' or
               `centre'.  Chooses the glyph.
  :department  grouping within a ring; departments are laid out as
               contiguous arcs so one reads as a wedge
  :parent      the :id of the parent node, for collapse
  :collapsed   non-nil to fold this node's subtree
  :color       0xRRGGBBAA integer; defaults to the ring's colour

Any other key is preserved and returned by `cmacs-secondbrain-node-at'.

EDGES is a vector (or list) of plists with :from and :to id strings, an
optional :edge-kind (`id', `cite' or `sim'; default `id') and an
optional :weight.  Edges whose endpoints are not both present are
dropped.

DIMS selects the layout plane: 2 (the default here -- concentric rings
read flat) or 3.

Returns the number of nodes emitted.  */)
  (Lisp_Object buffer, Lisp_Object nodes, Lisp_Object edges,
   Lisp_Object dims)
{
  CmacsLibregnumView *v;
  CmacsLibregnumRenderCtx *ctx;
  SbState *st;
  Lisp_Object nvec, evec, payloads;
  ptrdiff_t i, nn, ne;
  int d;
  guint emitted;

  CHECK_BUFFER (buffer);
  st = state_for_buffer (buffer, &v, &ctx);
  if (!st || !ctx) return Qnil;

  nvec = VECTORP (nodes) ? nodes : Fvconcat (1, &nodes);
  evec = VECTORP (edges) ? edges : Fvconcat (1, &edges);
  nn = ASIZE (nvec);
  ne = ASIZE (evec);

  d = FIXNUMP (dims) ? (int) XFIXNUM (dims) : st->dims;
  st->dims = (d == 3) ? 3 : 2;

  payloads = buffer_payloads (buffer, true);
  Fclrhash (payloads);

  cmacs_graph_begin_update (st->graph);

  for (i = 0; i < nn; i++)
    {
      Lisp_Object e = AREF (nvec, i);
      Lisp_Object k_id = Qnil, k_title = Qnil, k_file = Qnil, k_dept = Qnil;
      const char *id, *title, *file, *dept;
      CmacsSbRing ring;
      CmacsSbKind kind;
      guint32 rgba;
      gint idx;

      if (!CONSP (e)) continue;
      id = sb_string (e, QCsb_id, &k_id);
      if (!id || !*id) continue;

      title = sb_string (e, QCsb_title, &k_title);
      file  = sb_string (e, QCsb_file,  &k_file);
      dept  = sb_string (e, QCsb_department, &k_dept);

      ring = sb_ring_of (e);
      kind = sb_kind_of (e);
      /* :color arrives as a Lisp integer, which may exceed a fixnum on
         a 32-bit build, so read it as a double and truncate. */
      rgba = (guint32) sb_double (e, QCsb_color, 0.0);
      if (rgba == 0) rgba = cmacs_sb_ring_color (ring);

      /* The role rides in `level', which graphcore carries for
         roamgraph's heading depth and which this subsystem has no
         other use for -- cheaper than widening the shared struct for
         one consumer's enum. */
      idx = cmacs_graph_add_node (st->graph, id, title, file, dept,
                                  (int) kind, 0, rgba);
      if (idx < 0) continue;   /* graph full: drop it, payload and all */

      cmacs_graph_node (st->graph, (guint) idx)->ring = (guint8) ring;

      Fputhash (build_string_from_utf8 (id), e, payloads);
    }

  /* Parents in a second pass: :parent names an id, and the parent may
     appear after the child in NODES.  A single pass would silently drop
     every forward reference. */
  for (i = 0; i < nn; i++)
    {
      Lisp_Object e = AREF (nvec, i);
      Lisp_Object k_id = Qnil, k_parent = Qnil;
      const char *id, *parent;
      gint ci, pi;

      if (!CONSP (e)) continue;
      id = sb_string (e, QCsb_id, &k_id);
      parent = sb_string (e, QCsb_parent, &k_parent);
      if (!id || !parent) continue;

      ci = cmacs_graph_index_of (st->graph, id);
      pi = cmacs_graph_index_of (st->graph, parent);
      if (ci < 0 || pi < 0) continue;
      cmacs_graph_set_parent (st->graph, (guint) ci, pi);
    }

  for (i = 0; i < ne; i++)
    {
      Lisp_Object e = AREF (evec, i);
      Lisp_Object k_from = Qnil, k_to = Qnil;
      const char *from, *to;

      if (!CONSP (e)) continue;
      from = sb_string (e, QCsb_from, &k_from);
      to   = sb_string (e, QCsb_to,   &k_to);
      if (!from || !to) continue;

      cmacs_graph_add_edge (st->graph, from, to, sb_edge_kind (e),
                            (float) sb_double (e, QCsb_weight, 1.0));
    }

  cmacs_graph_finalize (st->graph);

  /* Collapse flags after finalize: finalize computes the descendant
     counts that make a hub worth collapsing in the first place. */
  for (i = 0; i < nn; i++)
    {
      Lisp_Object e = AREF (nvec, i);
      Lisp_Object k_id = Qnil;
      const char *id;
      gint ci;

      if (!CONSP (e)) continue;
      if (NILP (plist_get (e, QCsb_collapsed))) continue;
      id = sb_string (e, QCsb_id, &k_id);
      if (!id) continue;
      ci = cmacs_graph_index_of (st->graph, id);
      if (ci >= 0) cmacs_graph_set_collapsed (st->graph, (guint) ci, TRUE);
    }

  /* Radii come from the role and the subtree size, not from degree:
     a collapsed department's whole signal is how much it is hiding. */
  {
    guint gi, gn = cmacs_graph_n_nodes (st->graph);
    for (gi = 0; gi < gn; gi++)
      {
        CmacsGraphNode *nd = cmacs_graph_node (st->graph, gi);
        nd->radius = (float) cmacs_sb_node_radius ((CmacsSbKind) nd->level,
                                                   nd->descendants);
      }
  }

  sb_relayout (st, ctx, 0);
  emitted = cmacs_secondbrain_scene_build (ctx, st->graph, st->layout, st->dims,
                                           st->ring_gap, st->band_guides);
  cmacs_secondbrain_scene_set_projection (ctx, st->dims == 2);
  cmacs_secondbrain_scene_fit (ctx, st->graph, st->layout);
  cmacs_libregnum_view_request_redraw (v);

  return make_fixnum ((EMACS_INT) emitted);
}

DEFUN ("cmacs-secondbrain-node-at", Fcmacs_secondbrain_node_at,
       Scmacs_secondbrain_node_at, 2, 2, 0,
       doc: /* Return BUFFER's node plist for ID, or nil.

ID is the id string.  Numeric scene ids are deliberately not accepted:
they are insertion indices and go stale on every rebuild.  */)
  (Lisp_Object buffer, Lisp_Object id)
{
  Lisp_Object payloads;

  CHECK_BUFFER (buffer);
  CHECK_STRING (id);

  payloads = buffer_payloads (buffer, false);
  if (NILP (payloads)) return Qnil;
  return Fgethash (id, payloads, Qnil);
}

DEFUN ("cmacs-secondbrain-node-count", Fcmacs_secondbrain_node_count,
       Scmacs_secondbrain_node_count, 1, 1, 0,
       doc: /* Return the number of nodes in BUFFER's graph.  */)
  (Lisp_Object buffer)
{
  SbState *st;

  CHECK_BUFFER (buffer);
  st = state_for_buffer (buffer, NULL, NULL);
  if (!st) return Qnil;
  return make_fixnum ((EMACS_INT) cmacs_graph_n_nodes (st->graph));
}

DEFUN ("cmacs-secondbrain-edge-count", Fcmacs_secondbrain_edge_count,
       Scmacs_secondbrain_edge_count, 1, 1, 0,
       doc: /* Return the number of edges in BUFFER's graph.  */)
  (Lisp_Object buffer)
{
  SbState *st;

  CHECK_BUFFER (buffer);
  st = state_for_buffer (buffer, NULL, NULL);
  if (!st) return Qnil;
  return make_fixnum ((EMACS_INT) cmacs_graph_n_edges (st->graph));
}

DEFUN ("cmacs-secondbrain-visible-count", Fcmacs_secondbrain_visible_count,
       Scmacs_secondbrain_visible_count, 1, 1, 0,
       doc: /* Return how many of BUFFER's nodes are currently visible.

Differs from `cmacs-secondbrain-node-count' whenever anything is
collapsed, which by default is every department.  */)
  (Lisp_Object buffer)
{
  SbState *st;

  CHECK_BUFFER (buffer);
  st = state_for_buffer (buffer, NULL, NULL);
  if (!st) return Qnil;
  return make_fixnum ((EMACS_INT) cmacs_graph_n_visible (st->graph));
}

DEFUN ("cmacs-secondbrain-focus", Fcmacs_secondbrain_focus,
       Scmacs_secondbrain_focus, 2, 2, 0,
       doc: /* Ease BUFFER's camera to frame node ID.  Returns nil if unknown.

Deliberate, because a click does not do this: clicking a department
starts an animation, and moving the camera at the same time hides the
thing the click was for.

Takes the id STRING, not a scene index, because scene indices are
emission order and churn on every rebuild.  */)
  (Lisp_Object buffer, Lisp_Object id)
{
  SbState *st;
  CmacsLibregnumView *v = NULL;
  CmacsLibregnumRenderCtx *ctx = NULL;
  gint idx;
  Lisp_Object enc;

  CHECK_BUFFER (buffer);
  CHECK_STRING (id);
  st = state_for_buffer (buffer, &v, &ctx);
  if (!st || !ctx) return Qnil;

  enc = ENCODE_UTF_8 (id);
  idx = cmacs_graph_index_of (st->graph, SSDATA (enc));
  if (idx < 0) return Qnil;

  if (!cmacs_secondbrain_scene_focus_node (ctx, (guint) idx))
    return Qnil;
  if (v) cmacs_libregnum_view_request_redraw (v);
  return id;
}

DEFUN ("cmacs-secondbrain-select", Fcmacs_secondbrain_select,
       Scmacs_secondbrain_select, 2, 2, 0,
       doc: /* Mark node ID as selected in BUFFER's scene (nil clears it).

The scene keeps its own selection -- that is what draws the halo and
what lights a node's links -- and a click sets it in C.  Selecting from
Lisp (keyboard navigation, search, the inspector) has to say so too, or
those only ever respond to the mouse.

Takes the id STRING: scene indices are emission order and churn on every
rebuild.  Returns ID, or nil if it is not on screen.  */)
  (Lisp_Object buffer, Lisp_Object id)
{
  SbState *st;
  CmacsLibregnumView *v = NULL;
  CmacsLibregnumRenderCtx *ctx = NULL;
  gint idx, emit;
  Lisp_Object enc;

  CHECK_BUFFER (buffer);
  st = state_for_buffer (buffer, &v, &ctx);
  if (!st || !ctx) return Qnil;

  if (NILP (id))
    {
      cmacs_libregnum_render_ctx_set_selected (ctx, -1);
      if (v) cmacs_libregnum_view_request_redraw (v);
      return Qnil;
    }

  CHECK_STRING (id);
  enc = ENCODE_UTF_8 (id);
  idx = cmacs_graph_index_of (st->graph, SSDATA (enc));
  if (idx < 0) return Qnil;
  emit = cmacs_secondbrain_scene_emit_index (ctx, (guint) idx);
  if (emit < 0) return Qnil;          /* collapsed, or past the budget */

  cmacs_libregnum_render_ctx_set_selected (ctx, emit);
  if (v) cmacs_libregnum_view_request_redraw (v);
  return id;
}

DEFUN ("cmacs-secondbrain-scene-index", Fcmacs_secondbrain_scene_index,
       Scmacs_secondbrain_scene_index, 2, 2, 0,
       doc: /* Return the scene node index for ID in BUFFER, or nil.

The scene index is what the libregnum-level calls take -- picking,
`cmacs-libregnum-nearest-in-direction', node flags.  It is EMISSION
order, not graph order: a collapsed department emits nothing, so its
members have no index at all and this returns nil for them.

Never store what this returns.  It is valid until the next rebuild and
no longer; ids are the only durable key.  */)
  (Lisp_Object buffer, Lisp_Object id)
{
  SbState *st;
  CmacsLibregnumRenderCtx *ctx = NULL;
  gint idx, emit;

  CHECK_BUFFER (buffer);
  CHECK_STRING (id);
  st = state_for_buffer (buffer, NULL, &ctx);
  if (!st || !ctx) return Qnil;

  idx = cmacs_graph_index_of (st->graph, SSDATA (ENCODE_UTF_8 (id)));
  if (idx < 0) return Qnil;
  emit = cmacs_secondbrain_scene_emit_index (ctx, (guint) idx);
  return (emit >= 0) ? make_fixnum (emit) : Qnil;
}

DEFUN ("cmacs-secondbrain-set-cursor", Fcmacs_secondbrain_set_cursor,
       Scmacs_secondbrain_set_cursor, 2, 2, 0,
       doc: /* Put the keyboard cursor on node ID in BUFFER; nil clears it.

The cursor is where the keyboard STANDS, as distinct from what is
selected.  Navigation anchors one node -- the selection, with its halo
and lit links -- and walks the cursor over that node's links; the
cursor is therefore the node the next key acts on, and it needs its own
mark: a white ring, and a label that is never dropped.

A flag on the emitted node, so it survives everything but a rebuild;
the Lisp side re-applies it after one.  A hidden node (its department
collapsed) has no scene entry and gets no ring, which is why the
navigation layer reveals before it moves.  Repaints immediately.
Returns ID, or nil when it was cleared or is not on screen.  */)
  (Lisp_Object buffer, Lisp_Object id)
{
  SbState *st;
  CmacsLibregnumView *v = NULL;
  CmacsLibregnumRenderCtx *ctx = NULL;
  Lisp_Object result = Qnil;

  CHECK_BUFFER (buffer);
  st = state_for_buffer (buffer, &v, &ctx);
  if (!st || !ctx) return Qnil;

  cmacs_libregnum_render_ctx_clear_node_flags (ctx, CMACS_LIBREGNUM_NODE_CURSOR);
  if (!NILP (id))
    {
      gint idx, emit;

      CHECK_STRING (id);
      idx = cmacs_graph_index_of (st->graph, SSDATA (ENCODE_UTF_8 (id)));
      emit = (idx >= 0) ? cmacs_secondbrain_scene_emit_index (ctx, (guint) idx)
                        : -1;
      if (emit >= 0)
        {
          cmacs_libregnum_render_ctx_set_node_flags
            (ctx, emit,
             cmacs_libregnum_render_ctx_get_node_flags (ctx, emit)
             | CMACS_LIBREGNUM_NODE_CURSOR);
          result = id;
        }
    }
  cmacs_secondbrain_scene_apply_flags (ctx, st->graph);
  if (v) cmacs_libregnum_view_request_redraw (v);
  return result;
}

DEFUN ("cmacs-secondbrain-node-id-at", Fcmacs_secondbrain_node_id_at,
       Scmacs_secondbrain_node_id_at, 2, 2, 0,
       doc: /* Return the id string of the node at scene INDEX in BUFFER.

The inverse of `cmacs-secondbrain-scene-index', and the reason the
libregnum navigation calls are usable from here at all: they answer in
scene indices, and everything on the Lisp side keys on ids.  */)
  (Lisp_Object buffer, Lisp_Object index)
{
  SbState *st;
  CmacsLibregnumRenderCtx *ctx = NULL;
  guint n, i;
  gint want;

  CHECK_BUFFER (buffer);
  CHECK_FIXNUM (index);
  st = state_for_buffer (buffer, NULL, &ctx);
  if (!st || !ctx) return Qnil;

  want = (gint) XFIXNUM (index);
  if (want < 0) return Qnil;

  /* Walk the graph asking each node for its emission index rather than
     indexing an emission-ordered table: the mapping is owned by the
     scene, and duplicating it here is how the two drift apart. */
  n = cmacs_graph_n_nodes (st->graph);
  for (i = 0; i < n; i++)
    if (cmacs_secondbrain_scene_emit_index (ctx, i) == want)
      {
        CmacsGraphNode *nd = cmacs_graph_node (st->graph, i);
        return (nd && nd->id) ? build_string (nd->id) : Qnil;
      }
  return Qnil;
}

DEFUN ("cmacs-secondbrain-set-match-set", Fcmacs_secondbrain_set_match_set,
       Scmacs_secondbrain_set_match_set, 2, 3, 0,
       doc: /* Mark node IDS in BUFFER as search matches, dimming the rest.

IDS is a list or vector of id STRINGS; nil clears the set.  With non-nil
DIM-REST every other node is de-emphasised, which is what makes a
handful of matches readable on a crowded map.

This exists rather than calling `cmacs-libregnum-set-match-set' directly
because that one takes SCENE indices, and ids are the only stable key
here: emission order changes on every rebuild, and a collapsed
department is not emitted at all.  Passing it strings silently matched
NOTHING -- it keeps the integers and drops the rest -- so search
highlighted nothing while reporting a match count.

A match inside a COLLAPSED department flags that department instead --
the map opens collapsed, so without that a fresh view highlights
nothing at all.  Duplicates that fold onto the same hub count once, and
ids that are unknown are skipped, so the return -- the number of scene
nodes actually flagged -- is <= (length IDS).  */)
  (Lisp_Object buffer, Lisp_Object ids, Lisp_Object dim_rest)
{
  SbState *st;
  CmacsLibregnumView *v = NULL;
  CmacsLibregnumRenderCtx *ctx = NULL;
  Lisp_Object vec;
  ptrdiff_t n, i;
  gint *emit;
  gsize k = 0;

  CHECK_BUFFER (buffer);
  st = state_for_buffer (buffer, &v, &ctx);
  if (!st || !ctx) return Qnil;

  if (NILP (ids))
    {
      cmacs_libregnum_render_ctx_set_match_set (ctx, NULL, 0, FALSE);
      cmacs_secondbrain_scene_apply_flags (ctx, st->graph);
      if (v) cmacs_libregnum_view_request_redraw (v);
      return make_fixnum (0);
    }

  vec = VECTORP (ids) ? ids : Fvconcat (1, &ids);
  n = ASIZE (vec);
  emit = (n > 0) ? xnmalloc (n, sizeof *emit) : NULL;

  for (i = 0; i < n; i++)
    {
      Lisp_Object e = AREF (vec, i);
      gint idx, em, guard = 0;
      gsize j;

      if (!STRINGP (e)) continue;
      idx = cmacs_graph_index_of (st->graph, SSDATA (ENCODE_UTF_8 (e)));
      if (idx < 0) continue;

      /* A match inside a collapsed department has no drawable of its
         own, so flag the nearest VISIBLE ancestor instead: the
         department lights up saying "your hits are in here".
         Without this the whole feature is dead on the map people
         actually see -- it opens fully collapsed, so on a fresh view
         every single match resolves to nothing and the search
         highlights an empty screen.  Expanding everything instead is
         not the answer: two thousand hits would bury the answer in
         the noise it is meant to cut through. */
      em = cmacs_secondbrain_scene_emit_index (ctx, (guint) idx);
      while (em < 0 && guard++ < 64)
        {
          CmacsGraphNode *nd = cmacs_graph_node (st->graph, (guint) idx);
          if (!nd || nd->parent < 0) break;
          idx = nd->parent;
          em = cmacs_secondbrain_scene_emit_index (ctx, (guint) idx);
        }
      if (em < 0) continue;           /* nothing on screen to stand for it */

      /* Many members of one collapsed department collapse onto the same
         hub, and flagging it twenty times would only cost time. */
      for (j = 0; j < k; j++)
        if (emit[j] == em) break;
      if (j == k) emit[k++] = em;
    }

  cmacs_libregnum_render_ctx_set_match_set (ctx, emit, k, !NILP (dim_rest));
  xfree (emit);
  /* Repaint from the flags just written: the flags decide the colours,
     and nothing else is going to run apply_flags on our behalf. */
  cmacs_secondbrain_scene_apply_flags (ctx, st->graph);
  if (v) cmacs_libregnum_view_request_redraw (v);
  return make_fixnum ((EMACS_INT) k);
}

DEFUN ("cmacs-secondbrain-set-shading", Fcmacs_secondbrain_set_shading,
       Scmacs_secondbrain_set_shading, 1, 2, 0,
       doc: /* Draw a specular highlight on each node in BUFFER (ON nil off).

raylib draws an unlit sphere in a single colour, so without one a node
is a flat disc and size is the only depth cue the glyphs have.  A small
bright sphere set toward a fixed light gives the specular that makes the
eye read a ball.

Read when the scene is built, so it takes effect on the next refresh.  */)
  (Lisp_Object buffer, Lisp_Object on)
{
  SbState *st;
  CmacsLibregnumRenderCtx *ctx = NULL;

  CHECK_BUFFER (buffer);
  st = state_for_buffer (buffer, NULL, &ctx);
  if (!st || !ctx) return Qnil;
  cmacs_secondbrain_scene_set_shading (ctx, !NILP (on));
  return NILP (on) ? Qnil : Qt;
}

DEFUN ("cmacs-secondbrain-set-glow", Fcmacs_secondbrain_set_glow,
       Scmacs_secondbrain_set_glow, 1, 2, 0,
       doc: /* Draw an additive halo behind each node in BUFFER (ON nil off).

The halo is what seats the map in a dark background: against the nebula
a flat-lit glyph reads as a sticker, a glowing one as a light source.
Landmarks (hubs and the centre) glow wider and brighter, matches glow
gold, dimmed nodes barely at all, and the selection's halo breathes on
the same clock as the link light.

Read when the scene is built, so it takes effect on the next refresh.  */)
  (Lisp_Object buffer, Lisp_Object on)
{
  SbState *st;
  CmacsLibregnumRenderCtx *ctx = NULL;

  CHECK_BUFFER (buffer);
  st = state_for_buffer (buffer, NULL, &ctx);
  if (!st || !ctx) return Qnil;
  cmacs_secondbrain_scene_set_glow (ctx, !NILP (on));
  return NILP (on) ? Qnil : Qt;
}

DEFUN ("cmacs-secondbrain-set-dressing", Fcmacs_secondbrain_set_dressing,
       Scmacs_secondbrain_set_dressing, 2, 2, 0,
       doc: /* Turn BUFFER's band lanes and galactic core on or off.

The lanes are soft additive fills under each ARMS band in its own colour
-- a skirt rising to the hub circle, a fill across the rows the members
sit in, a skirt falling away outside -- so the four rings read as bands
of light the nodes lie IN rather than as dots on wire.  The core is a
warm-to-cool stack of glows on the origin, sized from the innermost
band.  Neither carries meaning.

Takes effect at the next scene build (`cmacs-secondbrain-set-graph' or a
refresh).  Returns ON.  */)
  (Lisp_Object buffer, Lisp_Object on)
{
  CmacsLibregnumView *v;
  CmacsLibregnumRenderCtx *ctx;
  SbState *st;

  CHECK_BUFFER (buffer);
  st = state_for_buffer (buffer, &v, &ctx);
  if (!st || !ctx) return Qnil;
  cmacs_secondbrain_scene_set_dressing (ctx, !NILP (on));
  return on;
}

DEFUN ("cmacs-secondbrain-set-isolate", Fcmacs_secondbrain_set_isolate,
       Scmacs_secondbrain_set_isolate, 1, 2, 0,
       doc: /* Dim everything outside BUFFER's selection neighbourhood (ON nil off).

While a node is selected, only it, its subtree and its direct
neighbours keep their colour; the rest of the map recedes.  With no
selection this is inert.  A search MATCH still lights up through it --
you searched for it.

Repaints immediately; the mode then follows the selection as it moves.
Returns the new state.  */)
  (Lisp_Object buffer, Lisp_Object on)
{
  SbState *st;
  CmacsLibregnumView *v = NULL;
  CmacsLibregnumRenderCtx *ctx = NULL;

  CHECK_BUFFER (buffer);
  st = state_for_buffer (buffer, &v, &ctx);
  if (!st || !ctx) return Qnil;
  cmacs_secondbrain_scene_set_isolate (ctx, !NILP (on));
  cmacs_secondbrain_scene_apply_flags (ctx, st->graph);
  if (v) cmacs_libregnum_view_request_redraw (v);
  return NILP (on) ? Qnil : Qt;
}

DEFUN ("cmacs-secondbrain-set-keep-set", Fcmacs_secondbrain_set_keep_set,
       Scmacs_secondbrain_set_keep_set, 2, 2, 0,
       doc: /* Keep only the nodes whose ids are in IDS lit in BUFFER.

IDS is a vector (or list) of id strings, or nil to lift the filter.  An
EMPTY VECTOR is a real filter that keeps nothing -- the honest picture
of "the nodes tagged X" when there are none.  It has to be a vector: in
Lisp the empty list IS nil, so a list can never say "keep nothing".

Everything outside the set is painted dim and its links near-invisible,
exactly as under the ring filter, and the two compose.  The centre is
always kept.  A search MATCH still lights up through it.  This is how
the tag and category filter reaches the scene; the decision of what is
in the set belongs to Lisp, which owns the tags.

Repaints immediately.  Returns the number of ids kept, or nil when the
filter was lifted.  */)
  (Lisp_Object buffer, Lisp_Object ids)
{
  SbState *st;
  CmacsLibregnumView *v = NULL;
  CmacsLibregnumRenderCtx *ctx = NULL;
  const char **arr = NULL;
  guint n = 0, i;
  Lisp_Object tail;

  CHECK_BUFFER (buffer);
  st = state_for_buffer (buffer, &v, &ctx);
  if (!st || !ctx) return Qnil;

  if (NILP (ids))
    cmacs_secondbrain_scene_set_keep_set (ctx, NULL, 0);
  else
    {
      /* Two arguments to `append', because its LAST argument is
         returned as-is rather than copied: (append [v]) is the vector
         itself, and CHECK_LIST then rejects the very thing this was
         meant to convert. */
      Lisp_Object args[2] = { ids, Qnil };
      Lisp_Object seq = VECTORP (ids) ? Fappend (2, args) : ids;
      CHECK_LIST (seq);
      n = (guint) list_length (seq);
      arr = g_new0 (const char *, n ? n : 1);
      i = 0;
      for (tail = seq; CONSP (tail); tail = XCDR (tail))
        {
          Lisp_Object id = XCAR (tail);
          if (STRINGP (id)) arr[i++] = SSDATA (id);
        }
      cmacs_secondbrain_scene_set_keep_set (ctx, arr, i);
      n = i;
      g_free (arr);
    }
  cmacs_secondbrain_scene_apply_flags (ctx, st->graph);
  if (v) cmacs_libregnum_view_request_redraw (v);
  return NILP (ids) ? Qnil : make_fixnum (n);
}

DEFUN ("cmacs-secondbrain-set-ring-filter", Fcmacs_secondbrain_set_ring_filter,
       Scmacs_secondbrain_set_ring_filter, 1, 2, 0,
       doc: /* Keep only RING at full strength in BUFFER; nil shows every ring.

RING is one of the symbols from `cmacs-secondbrain-ring-names' (or its
name as a string).  Everything outside it is painted dim and its links
near-invisible, so one ring can be read without the other three's
clutter.  The centre is exempt -- it belongs to every ring -- and a
search MATCH still lights up through the filter.

Repaints immediately.  Returns the ring kept, or nil.  */)
  (Lisp_Object buffer, Lisp_Object ring)
{
  SbState *st;
  CmacsLibregnumView *v = NULL;
  CmacsLibregnumRenderCtx *ctx = NULL;
  gint want = -1;

  CHECK_BUFFER (buffer);
  st = state_for_buffer (buffer, &v, &ctx);
  if (!st || !ctx) return Qnil;

  if (!NILP (ring))
    {
      Lisp_Object name = SYMBOLP (ring) ? SYMBOL_NAME (ring) : ring;
      CmacsSbRing rv;

      CHECK_STRING (name);
      if (!cmacs_sb_ring_from_name (SSDATA (ENCODE_UTF_8 (name)), &rv))
        xsignal2 (Qerror, build_string ("Unknown ring"), ring);
      want = (gint) rv;
    }

  cmacs_secondbrain_scene_set_ring_filter (ctx, want);
  cmacs_secondbrain_scene_apply_flags (ctx, st->graph);
  if (v) cmacs_libregnum_view_request_redraw (v);
  return (want >= 0)
         ? intern (cmacs_sb_ring_name ((CmacsSbRing) want))
         : Qnil;
}

DEFUN ("cmacs-secondbrain-set-link-phase",
       Fcmacs_secondbrain_set_link_phase,
       Scmacs_secondbrain_set_link_phase, 2, 2, 0,
       doc: /* Set the travelling-light PHASE, in radians, for BUFFER.

Advance it each frame and the selected node's links read as light
running along them.  Every link drawn identically is honest and useless
once there are a few hundred: the answer to "what is this connected to"
is invisible inside its own hairball.  */)
  (Lisp_Object buffer, Lisp_Object phase)
{
  SbState *st;
  CmacsLibregnumRenderCtx *ctx = NULL;

  CHECK_BUFFER (buffer);
  st = state_for_buffer (buffer, NULL, &ctx);
  if (!st || !ctx) return Qnil;
  cmacs_secondbrain_scene_set_link_phase
    (ctx, NUMBERP (phase) ? XFLOATINT (phase) : 0.0);
  return phase;
}

DEFUN ("cmacs-secondbrain-set-pinned", Fcmacs_secondbrain_set_pinned,
       Scmacs_secondbrain_set_pinned, 2, 3, 0,
       doc: /* Pin or unpin node ID in BUFFER (nil ID means every node).

A pinned node is one the force layout must not move -- that is what
makes a dragged node stay where it was dropped.  Returns the number of
nodes changed.  */)
  (Lisp_Object buffer, Lisp_Object id, Lisp_Object pinned)
{
  SbState *st;
  guint8 want = NILP (pinned) ? 0 : 1;
  EMACS_INT n = 0;

  CHECK_BUFFER (buffer);
  st = state_for_buffer (buffer, NULL, NULL);
  if (!st) return make_fixnum (0);

  if (NILP (id))
    {
      guint i, cnt = cmacs_graph_n_nodes (st->graph);
      for (i = 0; i < cnt; i++)
        {
          CmacsGraphNode *nd = cmacs_graph_node (st->graph, i);
          if (nd && nd->pinned != want) { nd->pinned = want; n++; }
        }
    }
  else
    {
      Lisp_Object enc;
      gint idx;
      CHECK_STRING (id);
      enc = ENCODE_UTF_8 (id);
      idx = cmacs_graph_index_of (st->graph, SSDATA (enc));
      if (idx >= 0)
        {
          CmacsGraphNode *nd = cmacs_graph_node (st->graph, (guint) idx);
          if (nd && nd->pinned != want) { nd->pinned = want; n = 1; }
        }
    }
  return make_fixnum (n);
}

DEFUN ("cmacs-secondbrain-move-node", Fcmacs_secondbrain_move_node,
       Scmacs_secondbrain_move_node, 5, 6, 0,
       doc: /* Move node ID in BUFFER to X Y Z.  Returns nil if unknown.

With PIN non-nil (the default) the node is pinned, so the force solver
leaves it where you put it.  A dragged node that the next solver step
quietly pulls back is worse than one you cannot drag at all.

Writes the position into the graph and syncs the scene from it, so the
move survives a re-layout -- moving only the drawable would look right
until the next layout pass.  */)
  (Lisp_Object buffer, Lisp_Object id, Lisp_Object x, Lisp_Object y,
   Lisp_Object z, Lisp_Object pin)
{
  SbState *st;
  CmacsLibregnumView *v = NULL;
  CmacsLibregnumRenderCtx *ctx = NULL;
  CmacsGraphNode *nd;
  gint idx;
  Lisp_Object enc;

  CHECK_BUFFER (buffer);
  CHECK_STRING (id);
  st = state_for_buffer (buffer, &v, &ctx);
  if (!st || !ctx) return Qnil;

  enc = ENCODE_UTF_8 (id);
  idx = cmacs_graph_index_of (st->graph, SSDATA (enc));
  if (idx < 0) return Qnil;
  nd = cmacs_graph_node (st->graph, (guint) idx);
  if (!nd) return Qnil;

  nd->x = (float) (NUMBERP (x) ? XFLOATINT (x) : 0.0);
  nd->y = (float) (NUMBERP (y) ? XFLOATINT (y) : 0.0);
  nd->z = (float) (NUMBERP (z) ? XFLOATINT (z) : 0.0);
  /* Aim the tween at where it now is, or a tween still in flight would
     drag it straight back out from under the pointer. */
  nd->tx = nd->x; nd->ty = nd->y; nd->tz = nd->z;
  nd->placed = 1;
  nd->pinned = NILP (pin) ? 0 : 1;

  cmacs_secondbrain_scene_sync_positions (ctx, st->graph);
  if (v) cmacs_libregnum_view_request_redraw (v);
  return id;
}

DEFUN ("cmacs-secondbrain-node-position", Fcmacs_secondbrain_node_position,
       Scmacs_secondbrain_node_position, 2, 2, 0,
       doc: /* Return (X Y Z) for node ID in BUFFER, or nil.  */)
  (Lisp_Object buffer, Lisp_Object id)
{
  SbState *st;
  gint idx;
  CmacsGraphNode *nd;
  Lisp_Object enc;

  CHECK_BUFFER (buffer);
  CHECK_STRING (id);
  st = state_for_buffer (buffer, NULL, NULL);
  if (!st) return Qnil;

  enc = ENCODE_UTF_8 (id);
  idx = cmacs_graph_index_of (st->graph, SSDATA (enc));
  if (idx < 0) return Qnil;
  nd = cmacs_graph_node (st->graph, (guint) idx);
  if (!nd) return Qnil;

  return list3 (make_float ((double) nd->x),
                make_float ((double) nd->y),
                make_float ((double) nd->z));
}

/* ── DEFUNs: layout ────────────────────────────────────────────────── */

DEFUN ("cmacs-secondbrain-set-layout", Fcmacs_secondbrain_set_layout,
       Scmacs_secondbrain_set_layout, 2, 3, 0,
       doc: /* Set BUFFER's layout to KIND, animating over FRAMES frames.

KIND is `rings' (the ARMS layout, and the default), `circle', `hex' or
`force'.  The first three are closed-form -- they compute a final
position in one pass -- while `force' hands the graph to the solver,
which `cmacs-secondbrain-layout-step' then drives.

FRAMES defaults to 24; 0 switches instantly.  Animating is not
decoration: a layout change that teleports every node gives the eye no
way to follow which node went where.  */)
  (Lisp_Object buffer, Lisp_Object kind, Lisp_Object frames)
{
  CmacsLibregnumView *v;
  CmacsLibregnumRenderCtx *ctx;
  SbState *st;
  int f = FIXNUMP (frames) ? (int) XFIXNUM (frames) : 24;

  CHECK_BUFFER (buffer);
  st = state_for_buffer (buffer, &v, &ctx);
  if (!st || !ctx) return Qnil;

  st->kind = sb_layout_kind (kind);
  sb_relayout (st, ctx, f);
  cmacs_libregnum_view_request_redraw (v);
  return Qt;
}

DEFUN ("cmacs-secondbrain-layout-kind", Fcmacs_secondbrain_layout_kind,
       Scmacs_secondbrain_layout_kind, 1, 1, 0,
       doc: /* Return BUFFER's current layout kind, as a symbol.  */)
  (Lisp_Object buffer)
{
  SbState *st;

  CHECK_BUFFER (buffer);
  st = state_for_buffer (buffer, NULL, NULL);
  if (!st) return Qnil;

  switch (st->kind)
    {
    case CMACS_GRAPH_LAYOUT_CIRCLE: return Qsb_circle;
    case CMACS_GRAPH_LAYOUT_HEX:    return Qsb_hex;
    case CMACS_GRAPH_LAYOUT_FORCE:  return Qsb_force;
    default:                        return Qsb_rings;
    }
}

DEFUN ("cmacs-secondbrain-tween-step", Fcmacs_secondbrain_tween_step,
       Scmacs_secondbrain_tween_step, 1, 1, 0,
       doc: /* Advance BUFFER's transition one frame.

Returns t when the transition has finished (and every node is exactly
on its target), nil while it is still running.  */)
  (Lisp_Object buffer)
{
  CmacsLibregnumView *v;
  CmacsLibregnumRenderCtx *ctx;
  SbState *st;
  gboolean done;

  CHECK_BUFFER (buffer);
  st = state_for_buffer (buffer, &v, &ctx);
  if (!st || !ctx) return Qt;

  done = cmacs_graph_layout_tween_step (st->layout, st->graph);
  cmacs_secondbrain_scene_sync_positions (ctx, st->graph);
  cmacs_libregnum_view_request_redraw (v);
  return done ? Qt : Qnil;
}

DEFUN ("cmacs-secondbrain-tweening-p", Fcmacs_secondbrain_tweening_p,
       Scmacs_secondbrain_tweening_p, 1, 1, 0,
       doc: /* Return t while BUFFER has a transition in flight.  */)
  (Lisp_Object buffer)
{
  SbState *st;

  CHECK_BUFFER (buffer);
  st = state_for_buffer (buffer, NULL, NULL);
  if (!st) return Qnil;
  return cmacs_graph_layout_tweening (st->layout) ? Qt : Qnil;
}

DEFUN ("cmacs-secondbrain-layout-step", Fcmacs_secondbrain_layout_step,
       Scmacs_secondbrain_layout_step, 1, 2, 0,
       doc: /* Advance the force solver on BUFFER by N iterations.

Only meaningful under the `force' layout; the closed-form layouts have
nothing to step and report converged immediately.  Returns t once the
layout has settled.  */)
  (Lisp_Object buffer, Lisp_Object n)
{
  CmacsLibregnumView *v;
  CmacsLibregnumRenderCtx *ctx;
  SbState *st;
  gboolean done;
  int iters = FIXNUMP (n) ? (int) XFIXNUM (n) : 1;

  CHECK_BUFFER (buffer);
  st = state_for_buffer (buffer, &v, &ctx);
  if (!st || !ctx) return Qt;

  done = cmacs_graph_layout_step (st->layout, st->graph, iters);
  cmacs_secondbrain_scene_sync_positions (ctx, st->graph);
  cmacs_libregnum_view_request_redraw (v);
  return done ? Qt : Qnil;
}

DEFUN ("cmacs-secondbrain-set-spin", Fcmacs_secondbrain_set_spin,
       Scmacs_secondbrain_set_spin, 2, 3, 0,
       doc: /* Set BUFFER's ring spin to RADIANS, animating over FRAMES.

Only the `rings' and `circle' layouts respond.  Alternate bands
counter-rotate, so the motion reads as depth rather than as the whole
figure sliding.  FRAMES defaults to 0 -- a spin driven from a slider
wants to track the slider, not lag behind it.  */)
  (Lisp_Object buffer, Lisp_Object radians, Lisp_Object frames)
{
  CmacsLibregnumView *v;
  CmacsLibregnumRenderCtx *ctx;
  SbState *st;
  int f = FIXNUMP (frames) ? (int) XFIXNUM (frames) : 0;

  CHECK_BUFFER (buffer);
  st = state_for_buffer (buffer, &v, &ctx);
  if (!st || !ctx) return Qnil;

  cmacs_graph_layout_set_spin (st->layout,
                               FLOATP (radians) ? XFLOAT_DATA (radians)
                               : FIXNUMP (radians)
                                 ? (double) XFIXNUM (radians) : 0.0);
  sb_relayout (st, ctx, f);
  cmacs_libregnum_view_request_redraw (v);
  return Qt;
}

DEFUN ("cmacs-secondbrain-set-galaxy-tilt", Fcmacs_secondbrain_set_galaxy_tilt,
       Scmacs_secondbrain_set_galaxy_tilt, 2, 3, 0,
       doc: /* Bend BUFFER's rings out of the plane by up to DEGREES.

Concentric rings viewed in three dimensions are coplanar, so orbiting
them only proves they are flat and the third dimension buys nothing.
This warps the disc the way a galaxy is warped: height grows with
radius and varies with the azimuth, so one side of the map lifts and
the opposite side drops, with a little per-node thickness so a
department is not a perfectly flat sheet.

DEGREES sets the warp: at its crest the disc sits exactly that far
above the plane.  The small per-node thickness rides on top, so an
individual node can sit a few degrees beyond it -- the number is the
shape of the disc, not a hard ceiling on any one node.  20 to 30 keeps
the map readable as rings while giving it real depth; 0 is flat.

Affects the `rings' layout only, and only in 3D: a 2D layout flattens
every node to z = 0, so this can be left set in both views.  With
FRAMES, animate into the new shape over that many frames.

Returns the degrees applied.  */)
  (Lisp_Object buffer, Lisp_Object degrees, Lisp_Object frames)
{
  CmacsLibregnumView *v;
  CmacsLibregnumRenderCtx *ctx;
  SbState *st;
  double deg;

  CHECK_BUFFER (buffer);
  st = state_for_buffer (buffer, &v, &ctx);
  if (!st || !ctx) return Qnil;

  deg = FLOATP (degrees) ? XFLOAT_DATA (degrees)
        : FIXNUMP (degrees) ? (double) XFIXNUM (degrees) : 0.0;
  if (deg < 0.0) deg = 0.0;

  st->galaxy_tilt = deg * G_PI / 180.0;
  sb_relayout (st, ctx, FIXNUMP (frames) ? (int) XFIXNUM (frames) : 0);
  cmacs_libregnum_view_request_redraw (v);
  return make_float (deg);
}

DEFUN ("cmacs-secondbrain-set-ring-gap", Fcmacs_secondbrain_set_ring_gap,
       Scmacs_secondbrain_set_ring_gap, 2, 2, 0,
       doc: /* Set the radial distance between BUFFER's rings to GAP.  */)
  (Lisp_Object buffer, Lisp_Object gap)
{
  CmacsLibregnumView *v;
  CmacsLibregnumRenderCtx *ctx;
  SbState *st;
  double g;

  CHECK_BUFFER (buffer);
  st = state_for_buffer (buffer, &v, &ctx);
  if (!st || !ctx) return Qnil;

  g = FLOATP (gap) ? XFLOAT_DATA (gap)
      : FIXNUMP (gap) ? (double) XFIXNUM (gap) : 6.0;
  if (g <= 0.0) return Qnil;

  st->ring_gap = g;
  sb_relayout (st, ctx, 0);
  cmacs_secondbrain_scene_build (ctx, st->graph, st->layout, st->dims,
                                 st->ring_gap, st->band_guides);
  cmacs_secondbrain_scene_fit (ctx, st->graph, st->layout);
  cmacs_libregnum_view_request_redraw (v);
  return Qt;
}

/* ── DEFUNs: collapse ──────────────────────────────────────────────── */

DEFUN ("cmacs-secondbrain-set-collapsed", Fcmacs_secondbrain_set_collapsed,
       Scmacs_secondbrain_set_collapsed, 2, 4, 0,
       doc: /* Fold or unfold node ID's subtree in BUFFER.

COLLAPSED non-nil folds it.  FRAMES defaults to 24; children animate
outward from the hub rather than appearing, which is what makes the
relationship legible.

Returns t when visibility actually changed.  */)
  (Lisp_Object buffer, Lisp_Object id, Lisp_Object collapsed,
   Lisp_Object frames)
{
  CmacsLibregnumView *v;
  CmacsLibregnumRenderCtx *ctx;
  SbState *st;
  gint idx;
  Lisp_Object enc;
  gboolean changed;
  int f = FIXNUMP (frames) ? (int) XFIXNUM (frames) : 24;

  CHECK_BUFFER (buffer);
  CHECK_STRING (id);
  st = state_for_buffer (buffer, &v, &ctx);
  if (!st || !ctx) return Qnil;

  enc = ENCODE_UTF_8 (id);
  idx = cmacs_graph_index_of (st->graph, SSDATA (enc));
  if (idx < 0) return Qnil;

  changed = cmacs_graph_set_collapsed (st->graph, (guint) idx,
                                       !NILP (collapsed));
  if (!changed) return Qnil;

  /* Expanding reveals nodes that have never been placed, so they must
     start somewhere sensible: at their parent, which is what makes them
     appear to unfold out of it. */
  if (NILP (collapsed))
    {
      guint gi, gn = cmacs_graph_n_nodes (st->graph);
      CmacsGraphNode *hub = cmacs_graph_node (st->graph, (guint) idx);
      for (gi = 0; gi < gn; gi++)
        {
          CmacsGraphNode *nd = cmacs_graph_node (st->graph, gi);
          if (nd->visible && !nd->placed && hub)
            { nd->x = hub->x; nd->y = hub->y; nd->z = hub->z; }
        }
    }

  sb_relayout (st, ctx, f);
  cmacs_secondbrain_scene_build (ctx, st->graph, st->layout, st->dims,
                                 st->ring_gap, st->band_guides);
  cmacs_libregnum_view_request_redraw (v);
  return Qt;
}

DEFUN ("cmacs-secondbrain-collapse-all", Fcmacs_secondbrain_collapse_all,
       Scmacs_secondbrain_collapse_all, 1, 3, 0,
       doc: /* Collapse (or with COLLAPSED nil, expand) every hub in BUFFER.  */)
  (Lisp_Object buffer, Lisp_Object collapsed, Lisp_Object frames)
{
  CmacsLibregnumView *v;
  CmacsLibregnumRenderCtx *ctx;
  SbState *st;
  int f = FIXNUMP (frames) ? (int) XFIXNUM (frames) : 24;

  CHECK_BUFFER (buffer);
  st = state_for_buffer (buffer, &v, &ctx);
  if (!st || !ctx) return Qnil;

  cmacs_graph_collapse_all (st->graph, !NILP (collapsed));
  sb_relayout (st, ctx, f);
  cmacs_secondbrain_scene_build (ctx, st->graph, st->layout, st->dims,
                                 st->ring_gap, st->band_guides);
  cmacs_secondbrain_scene_fit (ctx, st->graph, st->layout);
  cmacs_libregnum_view_request_redraw (v);
  return Qt;
}

DEFUN ("cmacs-secondbrain-collapsed-p", Fcmacs_secondbrain_collapsed_p,
       Scmacs_secondbrain_collapsed_p, 2, 2, 0,
       doc: /* Return t when node ID in BUFFER is collapsed.  */)
  (Lisp_Object buffer, Lisp_Object id)
{
  SbState *st;
  gint idx;
  Lisp_Object enc;
  CmacsGraphNode *nd;

  CHECK_BUFFER (buffer);
  CHECK_STRING (id);
  st = state_for_buffer (buffer, NULL, NULL);
  if (!st) return Qnil;

  enc = ENCODE_UTF_8 (id);
  idx = cmacs_graph_index_of (st->graph, SSDATA (enc));
  if (idx < 0) return Qnil;
  nd = cmacs_graph_node (st->graph, (guint) idx);
  return (nd && nd->collapsed) ? Qt : Qnil;
}

/* ── DEFUNs: view ──────────────────────────────────────────────────── */

DEFUN ("cmacs-secondbrain-set-projection", Fcmacs_secondbrain_set_projection,
       Scmacs_secondbrain_set_projection, 2, 2, 0,
       doc: /* Set BUFFER's view to flat (FLAT non-nil) or free 3D.  */)
  (Lisp_Object buffer, Lisp_Object flat)
{
  CmacsLibregnumView *v;
  CmacsLibregnumRenderCtx *ctx;
  SbState *st;

  CHECK_BUFFER (buffer);
  st = state_for_buffer (buffer, &v, &ctx);
  if (!st || !ctx) return Qnil;

  st->dims = NILP (flat) ? 3 : 2;
  cmacs_secondbrain_scene_set_projection (ctx, !NILP (flat));
  sb_relayout (st, ctx, 0);
  cmacs_secondbrain_scene_build (ctx, st->graph, st->layout, st->dims,
                                 st->ring_gap, st->band_guides);
  cmacs_secondbrain_scene_fit (ctx, st->graph, st->layout);
  cmacs_libregnum_view_request_redraw (v);
  return Qt;
}

DEFUN ("cmacs-secondbrain-flat-p", Fcmacs_secondbrain_flat_p,
       Scmacs_secondbrain_flat_p, 1, 1, 0,
       doc: /* Return t when BUFFER is showing the flat view.  */)
  (Lisp_Object buffer)
{
  CmacsLibregnumRenderCtx *ctx;

  CHECK_BUFFER (buffer);
  if (!state_for_buffer (buffer, NULL, &ctx) || !ctx) return Qnil;
  return cmacs_secondbrain_scene_flat_p (ctx) ? Qt : Qnil;
}

DEFUN ("cmacs-secondbrain-set-band-guides", Fcmacs_secondbrain_set_band_guides,
       Scmacs_secondbrain_set_band_guides, 2, 2, 0,
       doc: /* Show or hide BUFFER's ARMS ring guides.

The guides are what turn four arcs of dots into four named layers, so
they are on by default; hiding them is for a screenshot.  */)
  (Lisp_Object buffer, Lisp_Object on)
{
  CmacsLibregnumView *v;
  CmacsLibregnumRenderCtx *ctx;
  SbState *st;

  CHECK_BUFFER (buffer);
  st = state_for_buffer (buffer, &v, &ctx);
  if (!st || !ctx) return Qnil;

  st->band_guides = !NILP (on);
  cmacs_secondbrain_scene_build (ctx, st->graph, st->layout, st->dims,
                                 st->ring_gap, st->band_guides);
  cmacs_libregnum_view_request_redraw (v);
  return Qt;
}

DEFUN ("cmacs-secondbrain-add-icon", Fcmacs_secondbrain_add_icon,
       Scmacs_secondbrain_add_icon, 3, 4, 0,
       doc: /* Draw the SVG at SVG-PATH on node ID in BUFFER.

Rasterised once at PX pixels square (default 128) and uploaded as a
texture, so it stays crisp at any zoom instead of being a scaled bitmap.
Returns t when the icon loaded, nil when it did not -- an icon that will
not render leaves the node with its glyph rather than failing the build.

Icons are cleared along with the drawables, so this must be called after
the graph is set, and again after anything that rebuilds the scene.  */)
  (Lisp_Object buffer, Lisp_Object id, Lisp_Object svg_path, Lisp_Object px)
{
  CmacsLibregnumView *v;
  CmacsLibregnumRenderCtx *ctx;
  SbState *st;
  gint idx;
  CmacsGraphNode *nd;
  Lisp_Object enc_id, enc_path;
  gboolean ok;

  CHECK_BUFFER (buffer);
  CHECK_STRING (id);
  CHECK_STRING (svg_path);

  st = state_for_buffer (buffer, &v, &ctx);
  if (!st || !ctx) return Qnil;

  enc_id = ENCODE_UTF_8 (id);
  idx = cmacs_graph_index_of (st->graph, SSDATA (enc_id));
  if (idx < 0) return Qnil;
  nd = cmacs_graph_node (st->graph, (guint) idx);
  if (!nd || !nd->visible) return Qnil;

  enc_path = ENCODE_UTF_8 (svg_path);
  ok = cmacs_secondbrain_scene_add_icon (ctx, SSDATA (enc_path),
                                         nd->x, nd->y, nd->z,
                                         nd->radius * 1.9f,
                                         FIXNUMP (px) ? (int) XFIXNUM (px) : 128);
  if (ok) cmacs_libregnum_view_request_redraw (v);
  return ok ? Qt : Qnil;
}

DEFUN ("cmacs-secondbrain-clear-icons", Fcmacs_secondbrain_clear_icons,
       Scmacs_secondbrain_clear_icons, 1, 1, 0,
       doc: /* Remove every icon from BUFFER's view.  */)
  (Lisp_Object buffer)
{
  CmacsLibregnumView *v;
  CmacsLibregnumRenderCtx *ctx;

  CHECK_BUFFER (buffer);
  if (!state_for_buffer (buffer, &v, &ctx) || !ctx) return Qnil;
  cmacs_libregnum_render_ctx_clear_billboards (ctx);
  cmacs_libregnum_view_request_redraw (v);
  return Qt;
}

DEFUN ("cmacs-secondbrain-apply-flags", Fcmacs_secondbrain_apply_flags,
       Scmacs_secondbrain_apply_flags, 1, 1, 0,
       doc: /* Recolour BUFFER's shapes from the render context's node flags.

In place: recolouring on every search keystroke must not mean
rebuilding the scene.  */)
  (Lisp_Object buffer)
{
  CmacsLibregnumView *v;
  CmacsLibregnumRenderCtx *ctx;
  SbState *st;

  CHECK_BUFFER (buffer);
  st = state_for_buffer (buffer, &v, &ctx);
  if (!st || !ctx) return Qnil;

  cmacs_secondbrain_scene_apply_flags (ctx, st->graph);
  cmacs_libregnum_view_request_redraw (v);
  return Qt;
}

DEFUN ("cmacs-secondbrain-set-galaxy-shape",
       Fcmacs_secondbrain_set_galaxy_shape,
       Scmacs_secondbrain_set_galaxy_shape, 2, 3, 0,
       doc: /* Set how BUFFER's 3D disc is bent.  Returns SHAPE.

SHAPE is `flare' or `warp'.  FRAMES, if given, animates the change.

`flare' is a saucer: the height depends only on the radius, so the disc
dips through the middle and curves up evenly all the way round.  Being
rotationally symmetric is the point -- the silhouette is the same from
every direction, so the map reads level however you have orbited it.

`warp' is the mode-1 "integral sign" a real galaxy has: one side lifts
and the opposite side drops.  Astrophysically the honest one, and
visually it has a direction -- look along its node line and the whole
disc presents as a diagonal streak, which reads as a crooked picture
rather than as depth.  */)
  (Lisp_Object buffer, Lisp_Object shape, Lisp_Object frames)
{
  CmacsLibregnumView *v;
  CmacsLibregnumRenderCtx *ctx;
  SbState *st;
  Lisp_Object name;

  CHECK_BUFFER (buffer);
  st = state_for_buffer (buffer, &v, &ctx);
  if (!st || !ctx) return Qnil;

  name = SYMBOLP (shape) ? SYMBOL_NAME (shape) : shape;
  CHECK_STRING (name);
  if (!strcmp (SSDATA (ENCODE_UTF_8 (name)), "warp"))
    st->galaxy_shape = CMACS_GRAPH_GALAXY_WARP;
  else if (!strcmp (SSDATA (ENCODE_UTF_8 (name)), "flare"))
    st->galaxy_shape = CMACS_GRAPH_GALAXY_FLARE;
  else
    xsignal2 (Qerror, build_string ("Unknown galaxy shape"), shape);

  sb_relayout (st, ctx, FIXNUMP (frames) ? (int) XFIXNUM (frames) : 0);
  cmacs_secondbrain_scene_build (ctx, st->graph, st->layout, st->dims,
                                 st->ring_gap, st->band_guides);
  cmacs_libregnum_view_request_redraw (v);
  return shape;
}

DEFUN ("cmacs-secondbrain-band-radius", Fcmacs_secondbrain_band_radius,
       Scmacs_secondbrain_band_radius, 2, 2, 0,
       doc: /* Return the world radius BUFFER's RING band was placed at.

RING is a ring symbol (`skills', `memory', `routines', `applications').
Returns nil when that band holds nothing, or when the current layout is
not `rings'.

This is where the band's hubs sit and where its guide circle is drawn,
and it is NOT a function of the ring's index: a band's radius grows with
its population so that a department of a thousand notes has the
circumference to spread over.  Anything that recomputes it from the
index instead lands somewhere plausible and wrong.  */)
  (Lisp_Object buffer, Lisp_Object ring)
{
  SbState *st;
  Lisp_Object name;
  CmacsSbRing rv;
  double rad;

  CHECK_BUFFER (buffer);
  st = state_for_buffer (buffer, NULL, NULL);
  if (!st || !st->layout) return Qnil;

  name = SYMBOLP (ring) ? SYMBOL_NAME (ring) : ring;
  CHECK_STRING (name);
  if (!cmacs_sb_ring_from_name (SSDATA (ENCODE_UTF_8 (name)), &rv))
    xsignal2 (Qerror, build_string ("Unknown ring"), ring);

  rad = cmacs_graph_layout_band_radius (st->layout, (guint) rv);
  return (rad > 0.0) ? make_float (rad) : Qnil;
}

DEFUN ("cmacs-secondbrain-fit", Fcmacs_secondbrain_fit,
       Scmacs_secondbrain_fit, 1, 1, 0,
       doc: /* Frame BUFFER's whole graph.  */)
  (Lisp_Object buffer)
{
  CmacsLibregnumView *v;
  CmacsLibregnumRenderCtx *ctx;
  SbState *st;

  CHECK_BUFFER (buffer);
  st = state_for_buffer (buffer, &v, &ctx);
  if (!st || !ctx) return Qnil;

  cmacs_secondbrain_scene_fit (ctx, st->graph, st->layout);
  cmacs_libregnum_view_request_redraw (v);
  return Qt;
}

DEFUN ("cmacs-secondbrain-ring-names", Fcmacs_secondbrain_ring_names,
       Scmacs_secondbrain_ring_names, 0, 0, 0,
       doc: /* Return the ARMS ring names, innermost first.  */)
  (void)
{
  Lisp_Object out = Qnil;
  int i;

  for (i = CMACS_SB_RING_COUNT - 1; i >= 0; i--)
    {
      const char *n = cmacs_sb_ring_name ((CmacsSbRing) i);
      if (n) out = Fcons (intern (n), out);
    }
  return out;
}

/* ── Registration ──────────────────────────────────────────────────── */

void
syms_of_cmacs_secondbrain_defuns (void)
{
  QCsb_id         = intern_c_string (":id");
  QCsb_title      = intern_c_string (":title");
  QCsb_file       = intern_c_string (":file");
  QCsb_ring       = intern_c_string (":ring");
  QCsb_kind       = intern_c_string (":kind");
  QCsb_department = intern_c_string (":department");
  QCsb_parent     = intern_c_string (":parent");
  QCsb_color      = intern_c_string (":color");
  QCsb_collapsed  = intern_c_string (":collapsed");
  QCsb_from       = intern_c_string (":from");
  QCsb_to         = intern_c_string (":to");
  QCsb_edge_kind  = intern_c_string (":edge-kind");
  QCsb_weight     = intern_c_string (":weight");

  Qsb_sim    = intern_c_string ("sim");
  Qsb_cite   = intern_c_string ("cite");
  Qsb_force  = intern_c_string ("force");
  Qsb_circle = intern_c_string ("circle");
  Qsb_hex    = intern_c_string ("hex");
  Qsb_rings  = intern_c_string ("rings");

  /* staticpro every one of them.  These are plain C statics holding
     Lisp_Objects: syms_of_ runs while dumping, and without a root the
     pdumper has no reason to preserve them, so at runtime the keywords
     come back as garbage and every plist lookup silently misses -- the
     graph then builds with zero nodes and nothing reports an error. */
  staticpro (&QCsb_id);
  staticpro (&QCsb_title);
  staticpro (&QCsb_file);
  staticpro (&QCsb_ring);
  staticpro (&QCsb_kind);
  staticpro (&QCsb_department);
  staticpro (&QCsb_parent);
  staticpro (&QCsb_color);
  staticpro (&QCsb_collapsed);
  staticpro (&QCsb_from);
  staticpro (&QCsb_to);
  staticpro (&QCsb_edge_kind);
  staticpro (&QCsb_weight);

  staticpro (&Qsb_sim);
  staticpro (&Qsb_cite);
  staticpro (&Qsb_force);
  staticpro (&Qsb_circle);
  staticpro (&Qsb_hex);
  staticpro (&Qsb_rings);

  Vcmacs_secondbrain__payloads = Qnil;
  staticpro (&Vcmacs_secondbrain__payloads);

  defsubr (&Scmacs_secondbrain_supported_p);
  defsubr (&Scmacs_secondbrain_attach);
  defsubr (&Scmacs_secondbrain_detach);
  defsubr (&Scmacs_secondbrain_attached_p);
  defsubr (&Scmacs_secondbrain_set_graph);
  defsubr (&Scmacs_secondbrain_node_at);
  defsubr (&Scmacs_secondbrain_node_count);
  defsubr (&Scmacs_secondbrain_edge_count);
  defsubr (&Scmacs_secondbrain_visible_count);
  defsubr (&Scmacs_secondbrain_focus);
  defsubr (&Scmacs_secondbrain_select);
  defsubr (&Scmacs_secondbrain_scene_index);
  defsubr (&Scmacs_secondbrain_set_cursor);
  defsubr (&Scmacs_secondbrain_node_id_at);
  defsubr (&Scmacs_secondbrain_set_match_set);
  defsubr (&Scmacs_secondbrain_set_shading);
  defsubr (&Scmacs_secondbrain_set_glow);
  defsubr (&Scmacs_secondbrain_set_dressing);
  defsubr (&Scmacs_secondbrain_set_isolate);
  defsubr (&Scmacs_secondbrain_set_ring_filter);
  defsubr (&Scmacs_secondbrain_set_keep_set);
  defsubr (&Scmacs_secondbrain_set_link_phase);
  defsubr (&Scmacs_secondbrain_set_pinned);
  defsubr (&Scmacs_secondbrain_move_node);
  defsubr (&Scmacs_secondbrain_node_position);
  defsubr (&Scmacs_secondbrain_set_layout);
  defsubr (&Scmacs_secondbrain_layout_kind);
  defsubr (&Scmacs_secondbrain_tween_step);
  defsubr (&Scmacs_secondbrain_tweening_p);
  defsubr (&Scmacs_secondbrain_layout_step);
  defsubr (&Scmacs_secondbrain_set_spin);
  defsubr (&Scmacs_secondbrain_set_galaxy_tilt);
  defsubr (&Scmacs_secondbrain_set_ring_gap);
  defsubr (&Scmacs_secondbrain_set_collapsed);
  defsubr (&Scmacs_secondbrain_collapse_all);
  defsubr (&Scmacs_secondbrain_collapsed_p);
  defsubr (&Scmacs_secondbrain_set_projection);
  defsubr (&Scmacs_secondbrain_flat_p);
  defsubr (&Scmacs_secondbrain_set_band_guides);
  defsubr (&Scmacs_secondbrain_add_icon);
  defsubr (&Scmacs_secondbrain_clear_icons);
  defsubr (&Scmacs_secondbrain_apply_flags);
  defsubr (&Scmacs_secondbrain_set_galaxy_shape);
  defsubr (&Scmacs_secondbrain_band_radius);
  defsubr (&Scmacs_secondbrain_fit);
  defsubr (&Scmacs_secondbrain_ring_names);
}

#endif /* HAVE_CMACS_SECONDBRAIN */
