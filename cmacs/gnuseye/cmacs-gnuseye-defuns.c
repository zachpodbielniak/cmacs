/* cmacs-gnuseye-defuns.c --- Elisp <-> globe boundary DEFUNs.
 *
 * Copyright (C) 2026 Zach Podbielniak
 * SPDX-License-Identifier: AGPL-3.0-or-later
 *
 * The Lisp-facing core of GNU's Eye.  Owns the per-buffer layer store
 * (a hash of layer-id -> normalised entity vector), turns entities into
 * globe markers via the plain-C render half (cmacs-gnuseye-globe.h), and
 * stashes each entity's plist as the marker node's libregnum payload so a
 * pick returns the full record.  Never includes <libregnum.h> -- it talks
 * to the render half through the opaque CmacsLibregnumRenderCtx. */

#include <config.h>

#ifdef HAVE_CMACS_GNUSEYE

#include "lisp.h"
#include "buffer.h"
#include "coding.h"
#include "systime.h"
#include "cmacs-gnuseye.h"
#include "cmacs-gnuseye-globe.h"
#include "cmacs-gnuseye-geomath.h"
#include "cmacs-libregnum.h"
#include "cmacs-libregnum-render.h"

/* Cached keyword symbols for the normalised entity plist (set in syms_of). */
static Lisp_Object QCge_id, QCge_lat, QCge_lon, QCge_alt, QCge_heading,
  QCge_scale, QCge_kind, QCge_color, QCge_label, QCge_label_mode, QCge_trail,
  QCge_polygon;

/* buffer -> (hash layer-id -> entity-vector).  GC-rooted via staticpro. */
static Lisp_Object Vcmacs_gnuseye__layers;

static void
ensure_layers_table (void)
{
  if (NILP (Vcmacs_gnuseye__layers))
    Vcmacs_gnuseye__layers = CALLN (Fmake_hash_table, QCtest, Qeq);
}

/* Inner per-buffer layer hash, creating it on demand when CREATE. */
static Lisp_Object
buffer_layers (Lisp_Object buffer, bool create)
{
  ensure_layers_table ();
  Lisp_Object inner = Fgethash (buffer, Vcmacs_gnuseye__layers, Qnil);
  if (NILP (inner) && create)
    {
      inner = CALLN (Fmake_hash_table, QCtest, Qeq);
      Fputhash (buffer, inner, Vcmacs_gnuseye__layers);
    }
  return inner;
}

/* ── plist readers ─────────────────────────────────────────────────── */

static double
ge_double (Lisp_Object plist, Lisp_Object key, double def)
{
  Lisp_Object v = plist_get (plist, key);
  if (NILP (v)) return def;
  if (FIXNUMP (v)) return (double) XFIXNUM (v);
  if (FLOATP (v)) return XFLOAT_DATA (v);
  return def;
}

static int
ge_int (Lisp_Object plist, Lisp_Object key, int def)
{
  Lisp_Object v = plist_get (plist, key);
  if (FIXNUMP (v)) return (int) XFIXNUM (v);
  return def;
}

/* Encoded-UTF-8 string field, or NULL.  Stores the encoded Lisp string in
 * *KEEP so its bytes stay live for the duration of the caller's use. */
static const char *
ge_string (Lisp_Object plist, Lisp_Object key, Lisp_Object *keep)
{
  Lisp_Object v = plist_get (plist, key);
  if (!STRINGP (v)) return NULL;
  *keep = ENCODE_UTF_8 (v);
  return SSDATA (*keep);
}

/* Render one entity plist onto CTX/V; returns the marker node id or -1. */
static int
render_entity (CmacsLibregnumView *v, CmacsLibregnumRenderCtx *ctx,
               Lisp_Object e)
{
  if (!CONSP (e)) return -1;
  double lat = ge_double (e, QCge_lat, 0.0);
  double lon = ge_double (e, QCge_lon, 0.0);
  double alt = ge_double (e, QCge_alt, 0.0);
  double hdg = ge_double (e, QCge_heading, -1.0);
  double scl = ge_double (e, QCge_scale, 1.0);
  int kind = ge_int (e, QCge_kind, CMACS_GNUSEYE_MARKER_GENERIC);
  unsigned int rgba = (unsigned int) ge_int (e, QCge_color, 0xffd24aff);
  int lmode = ge_int (e, QCge_label_mode, 1 /* selected */);
  Lisp_Object keep_id = Qnil, keep_label = Qnil;
  const char *id = ge_string (e, QCge_id, &keep_id);
  const char *label = ge_string (e, QCge_label, &keep_label);

  int nid = cmacs_gnuseye_add_marker (ctx, kind, lat, lon, alt, hdg, scl,
                                      rgba, id, label, lmode);
  if (nid >= 0)
    cmacs_libregnum_view_set_payload (v, (guint) nid, e);

  /* Optional trail: a vector/list of [lat lon alt] samples -> arc. */
  Lisp_Object trail = plist_get (e, QCge_trail);
  if (VECTORP (trail) && ASIZE (trail) >= 2)
    {
      ptrdiff_t n = ASIZE (trail);
      double *la = xmalloc (sizeof (double) * n);
      double *lo = xmalloc (sizeof (double) * n);
      double *al = xmalloc (sizeof (double) * n);
      for (ptrdiff_t i = 0; i < n; i++)
        {
          Lisp_Object p = AREF (trail, i);
          double a = 0, b = 0, c = 0;
          if (VECTORP (p) && ASIZE (p) >= 2)
            {
              a = XFLOATINT (AREF (p, 0));
              b = XFLOATINT (AREF (p, 1));
              c = ASIZE (p) >= 3 ? XFLOATINT (AREF (p, 2)) : 0.0;
            }
          else if (CONSP (p))
            {
              a = XFLOATINT (XCAR (p));
              Lisp_Object r = XCDR (p);
              if (CONSP (r)) { b = XFLOATINT (XCAR (r)); r = XCDR (r); }
              if (CONSP (r)) c = XFLOATINT (XCAR (r));
            }
          la[i] = a; lo[i] = b; al[i] = c;
        }
      cmacs_gnuseye_add_arc (ctx, la, lo, al, (int) n, rgba & 0xffffffb0);
      xfree (la); xfree (lo); xfree (al);
    }

  /* Optional polygon: a vector/list of [lat lon] vertices -> a translucent
   * filled region draped on the globe (weather alert zones, AOIs).  Drawn
   * per-tick (cleared with the markers).  The entity's :color carries the
   * fill colour + alpha (use "#rrggbbaa" for a see-through wash). */
  Lisp_Object poly = plist_get (e, QCge_polygon);
  if (VECTORP (poly) && ASIZE (poly) >= 3)
    {
      ptrdiff_t n = ASIZE (poly);
      double *la = xmalloc (sizeof (double) * n);
      double *lo = xmalloc (sizeof (double) * n);
      for (ptrdiff_t i = 0; i < n; i++)
        {
          Lisp_Object p = AREF (poly, i);
          double a = 0, b = 0;
          if (VECTORP (p) && ASIZE (p) >= 2)
            { a = XFLOATINT (AREF (p, 0)); b = XFLOATINT (AREF (p, 1)); }
          else if (CONSP (p))
            {
              a = XFLOATINT (XCAR (p));
              if (CONSP (XCDR (p))) b = XFLOATINT (XCAR (XCDR (p)));
            }
          la[i] = a; lo[i] = b;
        }
      /* Force a translucent wash for the fill regardless of the entity's
       * (opaque) marker colour, so a zone overlay stays see-through. */
      cmacs_gnuseye_add_polygon (ctx, la, lo, (int) n,
                                 (rgba & 0xffffff00u) | 0x66u, FALSE);
      xfree (la); xfree (lo);
    }
  return nid;
}

/* Rebuild the whole marker set for BUFFER from every registered layer.
 * The persistent globe (background sphere) survives; only markers/arcs
 * are cleared and re-added. */
static void
rebuild_buffer (Lisp_Object buffer)
{
  CmacsLibregnumView *v = cmacs_libregnum_view_for_buffer (buffer);
  if (!v) return;
  CmacsLibregnumRenderCtx *ctx = cmacs_libregnum_view_get_render_ctx (v);
  if (!ctx) return;

  cmacs_gnuseye_clear_markers (ctx);

  Lisp_Object inner = buffer_layers (buffer, false);
  if (HASH_TABLE_P (inner))
    {
      struct Lisp_Hash_Table *h = XHASH_TABLE (inner);
      DOHASH (h, k, val)
        {
          (void) k;
          if (!VECTORP (val)) continue;
          ptrdiff_t n = ASIZE (val);
          for (ptrdiff_t i = 0; i < n; i++)
            render_entity (v, ctx, AREF (val, i));
        }
    }
  cmacs_libregnum_view_request_redraw (v);
}

/* ── DEFUNs ─────────────────────────────────────────────────────────── */

DEFUN ("cmacs-gnuseye-supported-p", Fcmacs_gnuseye_supported_p,
       Scmacs_gnuseye_supported_p, 0, 0, 0,
       doc: /* Return t when cmacs-gnuseye (GNU's Eye) is built into this cmacs.  */)
  (void)
{
  return Qt;
}

DEFUN ("cmacs-gnuseye-attach", Fcmacs_gnuseye_attach,
       Scmacs_gnuseye_attach, 1, 4, 0,
       doc: /* Attach a GNU's Eye globe view to BUFFER.
WIDTH and HEIGHT default to 900x600.  BASE-TEXTURE is the path of an
equirectangular Earth image (nil uses a built-in fallback).  Builds the
persistent globe and enables continuous animation.  Idempotent.  */)
  (Lisp_Object buffer, Lisp_Object width, Lisp_Object height,
   Lisp_Object base_texture)
{
  CHECK_BUFFER (buffer);
  int w = NILP (width)  ? 900 : (CHECK_FIXNAT (width),  XFIXNUM (width));
  int h = NILP (height) ? 600 : (CHECK_FIXNAT (height), XFIXNUM (height));

  CmacsLibregnumView *v = cmacs_libregnum_view_for_buffer (buffer);
  if (!v)
    v = cmacs_libregnum_view_new (buffer, w, h);
  if (!v)
    xsignal1 (Qcmacs_gnuseye_error, build_string ("could not create view"));

  CmacsLibregnumRenderCtx *ctx = cmacs_libregnum_view_get_render_ctx (v);
  const char *tex = NULL;
  Lisp_Object keep = Qnil;
  if (STRINGP (base_texture))
    {
      keep = ENCODE_FILE (base_texture);
      tex = SSDATA (keep);
    }
  if (!cmacs_gnuseye_build (ctx, tex))
    xsignal1 (Qcmacs_gnuseye_error, build_string ("globe build failed"));

  /* 30 FPS is plenty for a globe; the clock idles when off-screen. */
  cmacs_libregnum_view_set_animated (v, true, 30);
  cmacs_libregnum_view_request_redraw (v);
  return Qt;
}

DEFUN ("cmacs-gnuseye-detach", Fcmacs_gnuseye_detach,
       Scmacs_gnuseye_detach, 1, 1, 0,
       doc: /* Detach and destroy the GNU's Eye view bound to BUFFER.  */)
  (Lisp_Object buffer)
{
  CHECK_BUFFER (buffer);
  if (!NILP (Vcmacs_gnuseye__layers))
    Fremhash (buffer, Vcmacs_gnuseye__layers);
  CmacsLibregnumView *v = cmacs_libregnum_view_for_buffer (buffer);
  if (v) cmacs_libregnum_view_destroy (v);
  return Qt;
}

DEFUN ("cmacs-gnuseye-attached-p", Fcmacs_gnuseye_attached_p,
       Scmacs_gnuseye_attached_p, 1, 1, 0,
       doc: /* Return t if BUFFER has an attached GNU's Eye globe view.  */)
  (Lisp_Object buffer)
{
  CHECK_BUFFER (buffer);
  return cmacs_libregnum_view_for_buffer (buffer) ? Qt : Qnil;
}

DEFUN ("cmacs-gnuseye-set-entities", Fcmacs_gnuseye_set_entities,
       Scmacs_gnuseye_set_entities, 3, 3, 0,
       doc: /* Set LAYER-ID's ENTITIES on BUFFER's globe and rebuild markers.
LAYER-ID is a symbol identifying the data layer.  ENTITIES is a vector of
normalised entity plists with keys :id :lat :lon :alt :heading :scale
:kind (integer) :color (integer 0xRRGGBBAA) :label :label-mode :trail,
plus any extra keys (e.g. :detail :data) preserved as the marker's pick
payload.  Replaces this layer's entities; other layers are unaffected.  */)
  (Lisp_Object buffer, Lisp_Object layer_id, Lisp_Object entities)
{
  CHECK_BUFFER (buffer);
  CHECK_SYMBOL (layer_id);
  if (!VECTORP (entities))
    xsignal1 (Qcmacs_gnuseye_error,
              build_string ("ENTITIES must be a vector"));
  if (!cmacs_libregnum_view_for_buffer (buffer))
    xsignal1 (Qcmacs_gnuseye_error,
              build_string ("no GNU's Eye view attached to buffer"));
  Lisp_Object inner = buffer_layers (buffer, true);
  Fputhash (layer_id, entities, inner);
  rebuild_buffer (buffer);
  return Qt;
}

DEFUN ("cmacs-gnuseye-clear-layer", Fcmacs_gnuseye_clear_layer,
       Scmacs_gnuseye_clear_layer, 2, 2, 0,
       doc: /* Remove LAYER-ID's entities from BUFFER's globe and rebuild.  */)
  (Lisp_Object buffer, Lisp_Object layer_id)
{
  CHECK_BUFFER (buffer);
  CHECK_SYMBOL (layer_id);
  Lisp_Object inner = buffer_layers (buffer, false);
  if (HASH_TABLE_P (inner))
    {
      Fremhash (layer_id, inner);
      rebuild_buffer (buffer);
    }
  return Qt;
}

DEFUN ("cmacs-gnuseye-entity-at", Fcmacs_gnuseye_entity_at,
       Scmacs_gnuseye_entity_at, 2, 2, 0,
       doc: /* Return the entity plist for marker NODE-ID in BUFFER, or nil.  */)
  (Lisp_Object buffer, Lisp_Object node_id)
{
  CHECK_BUFFER (buffer);
  CHECK_FIXNAT (node_id);
  CmacsLibregnumView *v = cmacs_libregnum_view_for_buffer (buffer);
  if (!v) return Qnil;
  return cmacs_libregnum_view_get_payload (v, (guint) XFIXNUM (node_id));
}

DEFUN ("cmacs-gnuseye-fly-to", Fcmacs_gnuseye_fly_to,
       Scmacs_gnuseye_fly_to, 3, 5, 0,
       doc: /* Point BUFFER's globe camera at LAT, LON.
RANGE is the camera distance in world units (default 18).  When ANIMATE
is non-nil, tween there; otherwise snap.  */)
  (Lisp_Object buffer, Lisp_Object lat, Lisp_Object lon, Lisp_Object range,
   Lisp_Object animate)
{
  CHECK_BUFFER (buffer);
  CmacsLibregnumView *v = cmacs_libregnum_view_for_buffer (buffer);
  if (!v) return Qnil;
  CmacsLibregnumRenderCtx *ctx = cmacs_libregnum_view_get_render_ctx (v);
  double rng = NILP (range) ? 18.0 : XFLOATINT (range);
  cmacs_gnuseye_camera_goto (ctx, XFLOATINT (lat), XFLOATINT (lon), rng,
                             !NILP (animate));
  cmacs_libregnum_view_request_redraw (v);
  return Qt;
}

DEFUN ("cmacs-gnuseye-set-spin", Fcmacs_gnuseye_set_spin,
       Scmacs_gnuseye_set_spin, 2, 2, 0,
       doc: /* Set BUFFER's globe spin to DEG degrees about the polar axis.  */)
  (Lisp_Object buffer, Lisp_Object deg)
{
  CHECK_BUFFER (buffer);
  CmacsLibregnumView *v = cmacs_libregnum_view_for_buffer (buffer);
  if (!v) return Qnil;
  cmacs_gnuseye_globe_set_spin (cmacs_libregnum_view_get_render_ctx (v),
                                XFLOATINT (deg));
  cmacs_libregnum_view_request_redraw (v);
  return Qt;
}

DEFUN ("cmacs-gnuseye-redraw", Fcmacs_gnuseye_redraw,
       Scmacs_gnuseye_redraw, 1, 1, 0,
       doc: /* Request a redraw of BUFFER's globe view.  */)
  (Lisp_Object buffer)
{
  CHECK_BUFFER (buffer);
  CmacsLibregnumView *v = cmacs_libregnum_view_for_buffer (buffer);
  if (v) cmacs_libregnum_view_request_redraw (v);
  return Qt;
}

DEFUN ("cmacs-gnuseye-snapshot", Fcmacs_gnuseye_snapshot,
       Scmacs_gnuseye_snapshot, 2, 2, 0,
       doc: /* Render BUFFER's globe to PATH as a PNG (headless-safe).
Returns t on success or signals `cmacs-gnuseye-error' with the reason.  */)
  (Lisp_Object buffer, Lisp_Object path)
{
  CHECK_BUFFER (buffer);
  CHECK_STRING (path);
  CmacsLibregnumView *v = cmacs_libregnum_view_for_buffer (buffer);
  if (!v)
    xsignal1 (Qcmacs_gnuseye_error, build_string ("no view attached"));
  Lisp_Object enc = ENCODE_FILE (path);
  char *err = NULL;
  if (!cmacs_libregnum_render_ctx_snapshot_png (
        cmacs_libregnum_view_get_render_ctx (v), SSDATA (enc), &err))
    {
      Lisp_Object m = build_string (err ? err : "snapshot failed");
      g_free (err);
      xsignal1 (Qcmacs_gnuseye_error, m);
    }
  return Qt;
}

DEFUN ("cmacs-gnuseye-add-coastline", Fcmacs_gnuseye_add_coastline,
       Scmacs_gnuseye_add_coastline, 3, 4, 0,
       doc: /* Add one coastline polyline to BUFFER's globe.
LATS and LONS are equal-length vectors of degrees.  COLOR is a packed
integer 0xRRGGBBAA (default a land tan).  Coastlines are drawn in the
globe's own lat/lon convention, so they always align with the markers,
and persist across marker refreshes.  */)
  (Lisp_Object buffer, Lisp_Object lats, Lisp_Object lons, Lisp_Object color)
{
  CHECK_BUFFER (buffer);
  if (!VECTORP (lats) || !VECTORP (lons)) return Qnil;
  ptrdiff_t n = ASIZE (lats);
  if (ASIZE (lons) < n) n = ASIZE (lons);
  if (n < 2) return Qnil;
  CmacsLibregnumView *v = cmacs_libregnum_view_for_buffer (buffer);
  if (!v) return Qnil;
  unsigned int rgba = 0xd2c39bffu;            /* land tan default */
  if (FIXNUMP (color)) rgba = (unsigned int) XFIXNUM (color);
  double *la = xmalloc (sizeof (double) * n);
  double *lo = xmalloc (sizeof (double) * n);
  for (ptrdiff_t i = 0; i < n; i++)
    {
      la[i] = XFLOATINT (AREF (lats, i));
      lo[i] = XFLOATINT (AREF (lons, i));
    }
  cmacs_gnuseye_add_coastline (cmacs_libregnum_view_get_render_ctx (v),
                              la, lo, (int) n, rgba);
  xfree (la); xfree (lo);
  return Qt;
}

DEFUN ("cmacs-gnuseye-clear-coastlines", Fcmacs_gnuseye_clear_coastlines,
       Scmacs_gnuseye_clear_coastlines, 1, 1, 0,
       doc: /* Remove BUFFER's globe coastline overlay.  */)
  (Lisp_Object buffer)
{
  CHECK_BUFFER (buffer);
  CmacsLibregnumView *v = cmacs_libregnum_view_for_buffer (buffer);
  if (v)
    cmacs_gnuseye_clear_coastlines (cmacs_libregnum_view_get_render_ctx (v));
  return Qt;
}

DEFUN ("cmacs-gnuseye-add-polygon", Fcmacs_gnuseye_add_polygon,
       Scmacs_gnuseye_add_polygon, 3, 5, 0,
       doc: /* Add a filled translucent polygon to BUFFER's globe.
LATS and LONS are equal-length vectors of degrees forming the boundary ring.
COLOR is a packed integer 0xRRGGBBAA (a moderate alpha gives a see-through
wash; default a light blue wash).  When PERSISTENT is non-nil the fill
survives marker refreshes (use for choropleth / aurora / AOIs and clear it
with `cmacs-gnuseye-clear-polygons' with PERSISTENT non-nil); otherwise it is
a per-tick fill cleared with the markers.  */)
  (Lisp_Object buffer, Lisp_Object lats, Lisp_Object lons, Lisp_Object color,
   Lisp_Object persistent)
{
  CHECK_BUFFER (buffer);
  if (!VECTORP (lats) || !VECTORP (lons)) return Qnil;
  ptrdiff_t n = ASIZE (lats);
  if (ASIZE (lons) < n) n = ASIZE (lons);
  if (n < 3) return Qnil;
  CmacsLibregnumView *v = cmacs_libregnum_view_for_buffer (buffer);
  if (!v) return Qnil;
  unsigned int rgba = 0x6f93ba66u;             /* light blue wash default */
  if (FIXNUMP (color)) rgba = (unsigned int) XFIXNUM (color);
  double *la = xmalloc (sizeof (double) * n);
  double *lo = xmalloc (sizeof (double) * n);
  for (ptrdiff_t i = 0; i < n; i++)
    {
      la[i] = XFLOATINT (AREF (lats, i));
      lo[i] = XFLOATINT (AREF (lons, i));
    }
  cmacs_gnuseye_add_polygon (cmacs_libregnum_view_get_render_ctx (v),
                             la, lo, (int) n, rgba, !NILP (persistent));
  xfree (la); xfree (lo);
  return Qt;
}

DEFUN ("cmacs-gnuseye-clear-polygons", Fcmacs_gnuseye_clear_polygons,
       Scmacs_gnuseye_clear_polygons, 1, 2, 0,
       doc: /* Remove BUFFER's globe polygon fills.
With PERSISTENT non-nil, clear the persistent (choropleth/aurora) fills;
otherwise clear the per-tick fills (also cleared automatically on rebuild).  */)
  (Lisp_Object buffer, Lisp_Object persistent)
{
  CHECK_BUFFER (buffer);
  CmacsLibregnumView *v = cmacs_libregnum_view_for_buffer (buffer);
  if (v)
    cmacs_gnuseye_clear_polygons (cmacs_libregnum_view_get_render_ctx (v),
                                  !NILP (persistent));
  return Qt;
}

DEFUN ("cmacs-gnuseye-set-sun-time", Fcmacs_gnuseye_set_sun_time,
       Scmacs_gnuseye_set_sun_time, 1, 2, 0,
       doc: /* Set BUFFER's globe day/night terminator for TIME.
TIME is an Emacs time value (default: now).  Computes the real subsolar
point and points the globe shader's sun toward it, so the lit hemisphere
tracks the actual time of day.  No-op if the globe lacks the lit shader.  */)
  (Lisp_Object buffer, Lisp_Object time)
{
  CHECK_BUFFER (buffer);
  CmacsLibregnumView *v = cmacs_libregnum_view_for_buffer (buffer);
  if (!v) return Qnil;
  double unix_s = NILP (time) ? (double) current_timespec ().tv_sec
                              : (double) lisp_time_argument (time).tv_sec;
  cmacs_gnuseye_set_sun_time (cmacs_libregnum_view_get_render_ctx (v), unix_s);
  cmacs_libregnum_view_request_redraw (v);
  return Qt;
}

DEFUN ("cmacs-gnuseye-add-label", Fcmacs_gnuseye_add_label,
       Scmacs_gnuseye_add_label, 4, 5, 0,
       doc: /* Add a persistent map label TEXT at LAT, LON on BUFFER's globe.
COLOR is a packed integer 0xRRGGBBAA (default a soft white).  Labels show
only once the camera is zoomed in, and persist across marker refreshes.  */)
  (Lisp_Object buffer, Lisp_Object lat, Lisp_Object lon, Lisp_Object text,
   Lisp_Object color)
{
  CHECK_BUFFER (buffer);
  CHECK_STRING (text);
  CmacsLibregnumView *v = cmacs_libregnum_view_for_buffer (buffer);
  if (!v) return Qnil;
  double x, y, z;
  gnuseye_latlon_to_xyz (XFLOATINT (lat), XFLOATINT (lon), 20000.0,
                         &x, &y, &z);
  unsigned int rgba = FIXNUMP (color) ? (unsigned int) XFIXNUM (color)
                                      : 0xf0f0f0ffu;
  Lisp_Object enc = ENCODE_UTF_8 (text);
  cmacs_libregnum_render_ctx_add_map_label (
    cmacs_libregnum_view_get_render_ctx (v),
    (float) x, (float) y, (float) z, SSDATA (enc),
    (rgba >> 24) & 0xff, (rgba >> 16) & 0xff, (rgba >> 8) & 0xff);
  return Qt;
}

DEFUN ("cmacs-gnuseye-clear-labels", Fcmacs_gnuseye_clear_labels,
       Scmacs_gnuseye_clear_labels, 1, 1, 0,
       doc: /* Remove BUFFER's globe map labels.  */)
  (Lisp_Object buffer)
{
  CHECK_BUFFER (buffer);
  CmacsLibregnumView *v = cmacs_libregnum_view_for_buffer (buffer);
  if (v)
    cmacs_libregnum_render_ctx_clear_map_labels (
      cmacs_libregnum_view_get_render_ctx (v));
  return Qt;
}

DEFUN ("cmacs-gnuseye-label-count", Fcmacs_gnuseye_label_count,
       Scmacs_gnuseye_label_count, 1, 1, 0,
       doc: /* Return the number of map labels on BUFFER's globe.  */)
  (Lisp_Object buffer)
{
  CHECK_BUFFER (buffer);
  CmacsLibregnumView *v = cmacs_libregnum_view_for_buffer (buffer);
  if (!v) return make_fixnum (0);
  return make_fixnum (cmacs_libregnum_render_ctx_map_label_count (
                        cmacs_libregnum_view_get_render_ctx (v)));
}

DEFUN ("cmacs-gnuseye-view-center", Fcmacs_gnuseye_view_center,
       Scmacs_gnuseye_view_center, 1, 1, 0,
       doc: /* Return (LAT LON DISTANCE) for BUFFER's globe camera.
LAT/LON are the sub-camera point (centre of the visible hemisphere) and
DISTANCE is the camera's distance from the globe centre (a zoom measure),
handy for scoping a regional data fetch to what the user is viewing.
Returns nil if BUFFER has no globe.  */)
  (Lisp_Object buffer)
{
  CHECK_BUFFER (buffer);
  CmacsLibregnumView *v = cmacs_libregnum_view_for_buffer (buffer);
  if (!v) return Qnil;
  double px, py, pz, tx, ty, tz, fov, lat, lon, alt;
  cmacs_libregnum_render_ctx_get_camera_state (
    cmacs_libregnum_view_get_render_ctx (v),
    &px, &py, &pz, &tx, &ty, &tz, &fov);
  gnuseye_xyz_to_latlon (px, py, pz, &lat, &lon, &alt);
  double dist = sqrt (px * px + py * py + pz * pz);
  return list3 (make_float (lat), make_float (lon), make_float (dist));
}

DEFUN ("cmacs-gnuseye-screen-to-globe", Fcmacs_gnuseye_screen_to_globe,
       Scmacs_gnuseye_screen_to_globe, 3, 3, 0,
       doc: /* Return (LAT LON) under view pixel (VX, VY) on BUFFER's globe.
VX/VY are view-local pixels (as delivered by the click hook).  Casts the
camera ray through the pixel and intersects the globe; returns nil if the
pixel is off the globe.  */)
  (Lisp_Object buffer, Lisp_Object vx, Lisp_Object vy)
{
  CHECK_BUFFER (buffer);
  CmacsLibregnumView *v = cmacs_libregnum_view_for_buffer (buffer);
  if (!v) return Qnil;
  int vw = 0, vh = 0;
  cmacs_libregnum_view_get_size (v, &vw, &vh);
  double lat = 0, lon = 0;
  if (cmacs_gnuseye_screen_to_globe (cmacs_libregnum_view_get_render_ctx (v),
                                     XFLOATINT (vx), XFLOATINT (vy), vw, vh,
                                     &lat, &lon))
    return list2 (make_float (lat), make_float (lon));
  return Qnil;
}

DEFUN ("cmacs-gnuseye-add-flag", Fcmacs_gnuseye_add_flag,
       Scmacs_gnuseye_add_flag, 4, 5, 0,
       doc: /* Add a country flag billboard at LAT, LON on BUFFER's globe.
FLAG-PATH is a PNG image; SIZE is the billboard size in world units
(default 0.25).  Flags face the camera and show only when zoomed in.
Returns t on success, nil if the image could not be loaded.  */)
  (Lisp_Object buffer, Lisp_Object lat, Lisp_Object lon, Lisp_Object flag_path,
   Lisp_Object size)
{
  CHECK_BUFFER (buffer);
  CHECK_STRING (flag_path);
  CmacsLibregnumView *v = cmacs_libregnum_view_for_buffer (buffer);
  if (!v) return Qnil;
  Lisp_Object enc = ENCODE_FILE (flag_path);
  double sz = NILP (size) ? 0.25 : XFLOATINT (size);
  int rc = cmacs_gnuseye_add_flag (cmacs_libregnum_view_get_render_ctx (v),
                                   XFLOATINT (lat), XFLOATINT (lon),
                                   SSDATA (enc), sz);
  return rc == 0 ? Qt : Qnil;
}

DEFUN ("cmacs-gnuseye-clear-flags", Fcmacs_gnuseye_clear_flags,
       Scmacs_gnuseye_clear_flags, 1, 1, 0,
       doc: /* Remove BUFFER's globe country flags.  */)
  (Lisp_Object buffer)
{
  CHECK_BUFFER (buffer);
  CmacsLibregnumView *v = cmacs_libregnum_view_for_buffer (buffer);
  if (v) cmacs_gnuseye_clear_flags (cmacs_libregnum_view_get_render_ctx (v));
  return Qt;
}

DEFUN ("cmacs-gnuseye-flag-count", Fcmacs_gnuseye_flag_count,
       Scmacs_gnuseye_flag_count, 1, 1, 0,
       doc: /* Return the number of flag billboards on BUFFER's globe.  */)
  (Lisp_Object buffer)
{
  CHECK_BUFFER (buffer);
  CmacsLibregnumView *v = cmacs_libregnum_view_for_buffer (buffer);
  if (!v) return make_fixnum (0);
  return make_fixnum (cmacs_libregnum_render_ctx_billboard_count (
                        cmacs_libregnum_view_get_render_ctx (v)));
}

void
syms_of_cmacs_gnuseye_defuns (void)
{
  DEFSYM (Qcmacs_gnuseye_error, "cmacs-gnuseye-error");
  Fput (Qcmacs_gnuseye_error, Qerror_conditions,
        list2 (Qcmacs_gnuseye_error, Qerror));
  Fput (Qcmacs_gnuseye_error, Qerror_message,
        build_string ("GNU's Eye error"));

  QCge_id         = intern_c_string (":id");
  QCge_lat        = intern_c_string (":lat");
  QCge_lon        = intern_c_string (":lon");
  QCge_alt        = intern_c_string (":alt");
  QCge_heading    = intern_c_string (":heading");
  QCge_scale      = intern_c_string (":scale");
  QCge_kind       = intern_c_string (":kind");
  QCge_color      = intern_c_string (":color");
  QCge_label      = intern_c_string (":label");
  QCge_label_mode = intern_c_string (":label-mode");
  QCge_trail      = intern_c_string (":trail");
  QCge_polygon    = intern_c_string (":polygon");
  staticpro (&QCge_id);
  staticpro (&QCge_lat);
  staticpro (&QCge_lon);
  staticpro (&QCge_alt);
  staticpro (&QCge_heading);
  staticpro (&QCge_scale);
  staticpro (&QCge_kind);
  staticpro (&QCge_color);
  staticpro (&QCge_label);
  staticpro (&QCge_label_mode);
  staticpro (&QCge_trail);
  staticpro (&QCge_polygon);

  Vcmacs_gnuseye__layers = Qnil;
  staticpro (&Vcmacs_gnuseye__layers);

  defsubr (&Scmacs_gnuseye_supported_p);
  defsubr (&Scmacs_gnuseye_attach);
  defsubr (&Scmacs_gnuseye_detach);
  defsubr (&Scmacs_gnuseye_attached_p);
  defsubr (&Scmacs_gnuseye_set_entities);
  defsubr (&Scmacs_gnuseye_clear_layer);
  defsubr (&Scmacs_gnuseye_entity_at);
  defsubr (&Scmacs_gnuseye_fly_to);
  defsubr (&Scmacs_gnuseye_set_spin);
  defsubr (&Scmacs_gnuseye_redraw);
  defsubr (&Scmacs_gnuseye_snapshot);
  defsubr (&Scmacs_gnuseye_add_coastline);
  defsubr (&Scmacs_gnuseye_clear_coastlines);
  defsubr (&Scmacs_gnuseye_add_polygon);
  defsubr (&Scmacs_gnuseye_clear_polygons);
  defsubr (&Scmacs_gnuseye_set_sun_time);
  defsubr (&Scmacs_gnuseye_add_label);
  defsubr (&Scmacs_gnuseye_clear_labels);
  defsubr (&Scmacs_gnuseye_label_count);
  defsubr (&Scmacs_gnuseye_add_flag);
  defsubr (&Scmacs_gnuseye_clear_flags);
  defsubr (&Scmacs_gnuseye_flag_count);
  defsubr (&Scmacs_gnuseye_view_center);
  defsubr (&Scmacs_gnuseye_screen_to_globe);
}

#endif /* HAVE_CMACS_GNUSEYE */
