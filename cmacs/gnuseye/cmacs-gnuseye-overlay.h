/* cmacs-gnuseye-overlay.h --- plain-C API for the weather overlay shells.
 *
 * Copyright (C) 2026 Zach Podbielniak
 * SPDX-License-Identifier: AGPL-3.0-or-later
 *
 * Draped raster overlays for the GNU's Eye globe: named channels (radar,
 * clouds, ...), each an LRU cache of mesh-UV-warped RGBA frames that are
 * alpha-composited (CPU-side, in z-order) over a pristine copy of the
 * globe's base texture -- the albedo stays opaque, so day/night shading,
 * spin, and marker registration all apply to the weather for free.
 * Implemented by cmacs-gnuseye-overlay-render.c (a render-half TU,
 * includes <libregnum.h>); driven from the lisp.h side by
 * cmacs-gnuseye-overlay.c through this header only, mirroring the
 * cmacs-gnuseye-globe.h firewall. */

#ifndef CMACS_GNUSEYE_OVERLAY_H
#define CMACS_GNUSEYE_OVERLAY_H

#include <config.h>

#ifdef HAVE_CMACS_GNUSEYE

#include <glib.h>
#include "cmacs-libregnum-render.h"   /* opaque CmacsLibregnumRenderCtx */

/* One tile placement on the compose canvas.  PATH is decoded with
 * gdk-pixbuf (PNG, JPEG, GIF, ...).  DST_W/DST_H <= 0 paste the tile at
 * its decoded size; otherwise it is nearest-scaled to DST_W x DST_H. */
typedef struct
{
  const char *path;
  int dst_x, dst_y;
  int dst_w, dst_h;
} CmacsGnuseyeTilePlace;

/* Compose-canvas projections. */
enum
{
  CMACS_GNUSEYE_OVERLAY_EQUIRECT = 0,   /* canvas rows span lat +-90 */
  CMACS_GNUSEYE_OVERLAY_MERCATOR = 1    /* web-mercator rows (+-85.0511),
                                           reprojected to equirect */
};

/* Create (or update) overlay channel NAME on R's globe.  RADIUS_SCALE is
 * the channel's z-order (higher composites over lower; the historical
 * shell-radius parameter).  TEX_W/TEX_H are accepted for compatibility
 * but ignored -- frames are warped to the globe texture's own mesh-UV
 * dimensions so they composite 1:1.  CACHE_BYTES caps the channel's
 * composed-frame cache (<= 0: 64 MiB).  Idempotent; FALSE when the globe
 * is absent or in flat-map mode (draped rasters are globe-only). */
extern gboolean cmacs_gnuseye_overlay_ensure   (CmacsLibregnumRenderCtx *r,
                                                const char *name,
                                                double radius_scale,
                                                int tex_w, int tex_h,
                                                gint64 cache_bytes);
extern gboolean cmacs_gnuseye_overlay_exists_p (CmacsLibregnumRenderCtx *r,
                                                const char *name);

/* Compose one animation frame for channel NAME: decode TILES onto a
 * transparent CANVAS_W x CANVAS_H RGBA canvas, reproject web-mercator
 * canvases to equirect (PROJECTION, +-85.0511 clamp, polar rows left
 * transparent), optionally map luminance to alpha (LUMA_LO/LUMA_GAIN in
 * 0..1 luma units, LUMA_LO < 0 disables; TINT_RGBA recolours, default
 * white) for opaque grayscale IR imagery, warp into the mesh-UV texture
 * layout, and cache the result under TAG (LRU-evicting, never the shown
 * frame).  SHOW also uploads it to the GPU and makes it current.
 * Returns the number of tiles decoded (0 = nothing composed/cached). */
extern int cmacs_gnuseye_overlay_compose_frame
                (CmacsLibregnumRenderCtx *r, const char *name,
                 const char *tag,
                 const CmacsGnuseyeTilePlace *tiles, int n_tiles,
                 int canvas_w, int canvas_h, int projection,
                 double luma_lo, double luma_gain, guint32 tint_rgba,
                 gboolean show);

/* Upload the cached frame TAG and remember it as current.  FALSE when TAG
 * is not cached (the caller composes it once, then steps cheaply). */
extern gboolean cmacs_gnuseye_overlay_show_frame (CmacsLibregnumRenderCtx *r,
                                                  const char *name,
                                                  const char *tag);

/* NULL-terminated vector of cached frame tags, most-recently-shown first
 * (g_strfreev), or NULL when the channel is absent. */
extern char **cmacs_gnuseye_overlay_frame_tags (CmacsLibregnumRenderCtx *r,
                                                const char *name);

extern gboolean cmacs_gnuseye_overlay_set_alpha   (CmacsLibregnumRenderCtx *r,
                                                   const char *name,
                                                   double alpha);
extern gboolean cmacs_gnuseye_overlay_set_enabled (CmacsLibregnumRenderCtx *r,
                                                   const char *name,
                                                   gboolean enabled);

/* Drop channel NAME (or ALL channels when NAME is NULL): render-slot
 * model, texture, shader, warp LUT, and frame cache. */
extern void cmacs_gnuseye_overlay_clear (CmacsLibregnumRenderCtx *r,
                                         const char *name);

#endif /* HAVE_CMACS_GNUSEYE */
#endif /* CMACS_GNUSEYE_OVERLAY_H */
