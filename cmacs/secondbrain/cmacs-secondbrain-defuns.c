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
  emitted = cmacs_secondbrain_scene_build (ctx, st->graph, st->dims,
                                           st->ring_gap, st->band_guides);
  cmacs_secondbrain_scene_set_projection (ctx, st->dims == 2);
  cmacs_secondbrain_scene_fit (ctx, st->graph);
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
  cmacs_secondbrain_scene_build (ctx, st->graph, st->dims,
                                 st->ring_gap, st->band_guides);
  cmacs_secondbrain_scene_fit (ctx, st->graph);
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
  cmacs_secondbrain_scene_build (ctx, st->graph, st->dims,
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
  cmacs_secondbrain_scene_build (ctx, st->graph, st->dims,
                                 st->ring_gap, st->band_guides);
  cmacs_secondbrain_scene_fit (ctx, st->graph);
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
  cmacs_secondbrain_scene_build (ctx, st->graph, st->dims,
                                 st->ring_gap, st->band_guides);
  cmacs_secondbrain_scene_fit (ctx, st->graph);
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
  cmacs_secondbrain_scene_build (ctx, st->graph, st->dims,
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

  cmacs_secondbrain_scene_fit (ctx, st->graph);
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
  defsubr (&Scmacs_secondbrain_node_position);
  defsubr (&Scmacs_secondbrain_set_layout);
  defsubr (&Scmacs_secondbrain_layout_kind);
  defsubr (&Scmacs_secondbrain_tween_step);
  defsubr (&Scmacs_secondbrain_tweening_p);
  defsubr (&Scmacs_secondbrain_layout_step);
  defsubr (&Scmacs_secondbrain_set_spin);
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
  defsubr (&Scmacs_secondbrain_fit);
  defsubr (&Scmacs_secondbrain_ring_names);
}

#endif /* HAVE_CMACS_SECONDBRAIN */
