/* cmacs-gnuseye-globe.h --- plain-C render API for the GNU's Eye globe.
 *
 * Copyright (C) 2026 Zach Podbielniak
 * SPDX-License-Identifier: AGPL-3.0-or-later
 *
 * Implemented by cmacs-gnuseye-globe.c (the "render half"), which is the
 * ONLY gnuseye translation unit that includes <libregnum.h>/raylib.  This
 * header exposes the globe's drawing operations as plain C so the
 * lisp.h-side code (cmacs-gnuseye-defuns.c) can drive it without pulling
 * in the raylib `Color' typedef.  It mirrors cmacs-libregnum-scenes.h. */

#ifndef CMACS_GNUSEYE_GLOBE_H
#define CMACS_GNUSEYE_GLOBE_H

#include <config.h>

#ifdef HAVE_CMACS_GNUSEYE

#include <glib.h>
#include "cmacs-libregnum-render.h"   /* opaque CmacsLibregnumRenderCtx */

/* Marker visual kinds.  Must stay in sync with the Elisp kind table in
 * gnuseye.el (gnuseye-kind->code). */
typedef enum
{
  CMACS_GNUSEYE_MARKER_GENERIC = 0,
  CMACS_GNUSEYE_MARKER_SATELLITE,
  CMACS_GNUSEYE_MARKER_AIRCRAFT,
  CMACS_GNUSEYE_MARKER_SHIP,
  CMACS_GNUSEYE_MARKER_QUAKE,
  CMACS_GNUSEYE_MARKER_FIRE,
  CMACS_GNUSEYE_MARKER_LAUNCH,
  CMACS_GNUSEYE_MARKER_STORM,
  CMACS_GNUSEYE_MARKER_CAMERA,
  CMACS_GNUSEYE_MARKER_CITY,
  CMACS_GNUSEYE_N_MARKER_KINDS
} CmacsGnuseyeMarkerKind;

/* Build the persistent globe (textured Earth sphere) on render context R.
 * BASE_TEXTURE_PATH is an equirectangular image; NULL selects a built-in
 * procedural ocean/land fallback.  Idempotent (rebuilds if already built). */
extern gboolean cmacs_gnuseye_build (CmacsLibregnumRenderCtx *r,
                                     const char *base_texture_path);

/* True once the globe exists on R. */
extern gboolean cmacs_gnuseye_built_p (CmacsLibregnumRenderCtx *r);

/* Swap the base equirectangular texture (re-skins the whole sphere). */
extern gboolean cmacs_gnuseye_globe_set_base_texture
                (CmacsLibregnumRenderCtx *r, const char *path);

/* Live-tile overlay: blit an RGBA buffer (w*h*4, top-down) into the equirect
 * texture's sub-rectangle bounded by (lat0,lon0)..(lat1,lon1) in degrees.
 * Only the covered texels are uploaded (grl_texture_update_rec). */
extern gboolean cmacs_gnuseye_globe_update_region
                (CmacsLibregnumRenderCtx *r,
                 const unsigned char *rgba, int w, int h,
                 double lat0, double lon0, double lat1, double lon1);

/* Optional idle spin about the polar axis (degrees, absolute). */
extern void   cmacs_gnuseye_globe_set_spin (CmacsLibregnumRenderCtx *r,
                                            double deg);
extern double cmacs_gnuseye_globe_get_spin (CmacsLibregnumRenderCtx *r);

/* Per-frame marker set.  clear_markers drops all marker/arc drawables (the
 * persistent globe survives); add_marker places one and returns its pickable
 * node id (== cmacs_libregnum_render_ctx_add_node id), or -1.
 *
 *   KIND     CmacsGnuseyeMarkerKind
 *   LAT/LON  degrees;  ALT_M altitude above the sphere in metres
 *   HEADING  degrees clockwise from true north; < 0 == unoriented
 *   SCALE    marker size multiplier (1.0 nominal)
 *   RGBA     packed 0xRRGGBBAA colour
 *   ID/LABEL borrowed strings (ID becomes the node path, LABEL the name)
 *   LABEL_MODE  CmacsLibregnumLabelMode (never/selected/hover/always) */
extern void cmacs_gnuseye_clear_markers (CmacsLibregnumRenderCtx *r);
extern int  cmacs_gnuseye_add_marker (CmacsLibregnumRenderCtx *r,
                                      int kind, double lat, double lon,
                                      double alt_m, double heading,
                                      double scale, unsigned int rgba,
                                      const char *id, const char *label,
                                      int label_mode);

/* Persistent coastline/landmass overlay drawn in OUR lat/lon convention, so
 * it always aligns with the markers (unlike a raster texture, which is bound
 * to the sphere mesh's own UV layout).  add appends one polyline (lat/lon
 * arrays, degrees) as a static drawable lifted just above the surface; clear
 * removes them all. */
extern void cmacs_gnuseye_add_coastline (CmacsLibregnumRenderCtx *r,
                                         const double *lats, const double *lons,
                                         int n, unsigned int rgba);
extern void cmacs_gnuseye_clear_coastlines (CmacsLibregnumRenderCtx *r);

/* Country flag: a camera-facing billboard at (lat,lon) textured with the
 * image at FLAG_PATH (PNG), SIZE world units.  Shown only when zoomed in.
 * Returns 0 on success, -1 if the image failed to load. */
extern int  cmacs_gnuseye_add_flag (CmacsLibregnumRenderCtx *r,
                                    double lat, double lon,
                                    const char *flag_path, double size);
extern void cmacs_gnuseye_clear_flags (CmacsLibregnumRenderCtx *r);

/* Polyline arc following a sampled (lat,lon[,alt_m]) path (ALTS may be NULL
 * for a surface track).  For orbits, flight paths, ship wakes, cables. */
extern void cmacs_gnuseye_add_arc (CmacsLibregnumRenderCtx *r,
                                   const double *lats, const double *lons,
                                   const double *alts, int n,
                                   unsigned int rgba);

/* Point the orbit camera at (lat,lon) from RANGE world units out.  When
 * ANIMATE is true, uses libregnum's focus tween; otherwise snaps. */
extern void cmacs_gnuseye_camera_goto (CmacsLibregnumRenderCtx *r,
                                       double lat, double lon, double range,
                                       gboolean animate);

/* Day/night terminator: set the globe shader's sun direction.  set_direction
 * takes a world-space unit vector (gnuseye -Z winding); set_time computes the
 * real subsolar unit vector for Unix time UNIX_S and applies it.  No-op when
 * the globe was built without the lit shader. */
extern void cmacs_gnuseye_set_sun_direction (CmacsLibregnumRenderCtx *r,
                                             double x, double y, double z);
extern void cmacs_gnuseye_set_sun_time (CmacsLibregnumRenderCtx *r,
                                        double unix_s);

/* Filled translucent polygon draped on the globe (alert zones, choropleth,
 * aurora, AOIs).  LATS/LONS are an equal-length ring of degrees (the closing
 * vertex may be omitted).  RGBA is packed 0xRRGGBBAA; a moderate alpha gives a
 * see-through wash.  When PERSISTENT, the fill survives marker rebuilds (use
 * for choropleth/aurora and clear with clear_polygons(r,TRUE)); otherwise it is
 * a per-tick fill cleared with the markers. */
extern void cmacs_gnuseye_add_polygon (CmacsLibregnumRenderCtx *r,
                                       const double *lats, const double *lons,
                                       int n, unsigned int rgba,
                                       gboolean persistent);
extern void cmacs_gnuseye_clear_polygons (CmacsLibregnumRenderCtx *r,
                                          gboolean persistent);

#endif /* HAVE_CMACS_GNUSEYE */
#endif /* CMACS_GNUSEYE_GLOBE_H */
