/* cmacs-gnuseye-render-internal.h --- render-half-only shared decls.
 *
 * Copyright (C) 2026 Zach Podbielniak
 * SPDX-License-Identifier: AGPL-3.0-or-later
 *
 * Declarations shared between the gnuseye render-half translation units
 * (cmacs-gnuseye-globe.c and cmacs-gnuseye-overlay-render.c), both of
 * which include <libregnum.h>.  Include this ONLY after <libregnum.h>,
 * and NEVER from a lisp.h translation unit -- raylib's `Color' typedef
 * clashes with pgtkgui.h's (the firewall documented in cmacs-gnuseye.h). */

#ifndef CMACS_GNUSEYE_RENDER_INTERNAL_H
#define CMACS_GNUSEYE_RENDER_INTERNAL_H

#include <config.h>

#ifdef HAVE_CMACS_GNUSEYE

#include <glib.h>
#include "cmacs-libregnum-render.h"

/* Shared vertex shader source (globe, celestial bodies, weather overlays);
 * defined in cmacs-gnuseye-globe.c. */
extern const char *cmacs_gnuseye_globe_vs_src;

/* Warp an equirectangular RGBA image into the par_shapes sphere mesh's
 * transposed UV layout at OUT_W x OUT_H (see the long comment above the
 * implementation in cmacs-gnuseye-globe.c).  Anything draped on a gnuseye
 * sphere MUST go through this warp or it will not register with the
 * lat/lon marker convention.  Returns a new RGBA8 GrlImage* (transfer
 * full), or NULL. */
extern GrlImage *cmacs_gnuseye_warp_equirect_to_mesh (GrlImage *src,
                                                      int out_w, int out_h);

/* Decode ANY gdk-pixbuf-readable image file (JPEG, PNG, GIF, ...) into an
 * RGBA8 GrlImage (the bundled raylib has no JPEG support).  Returns a new
 * GrlImage* (transfer full), or NULL. */
extern GrlImage *cmacs_gnuseye_image_load_any (const char *path);

/* Last sun unit direction set on the globe (world space, gnuseye -Z
 * winding). */
extern void cmacs_gnuseye_get_sun_dir (float out[3]);

/* Borrowed access to the globe's CPU master image + GPU albedo texture
 * (both already in the warped mesh-UV layout).  FALSE when the globe is
 * not built or has no texture (flat map / procedural failure).  The
 * weather overlays composite into copies of these. */
extern gboolean cmacs_gnuseye_globe_master (CmacsLibregnumRenderCtx *r,
                                            GrlImage **img,
                                            GrlTexture **tex);

/* Hook called by the weather-overlay TU when the sun moves (currently a
 * no-op: the weather lives in the albedo, so the base globe shader
 * already lights it). */
extern void cmacs_gnuseye_overlay_update_sun (CmacsLibregnumRenderCtx *r,
                                              float x, float y, float z);

/* Notify the weather overlays that the base albedo was swapped ("Earth
 * today"): they recapture their pristine copy and re-drape.  Implemented
 * in cmacs-gnuseye-overlay-render.c. */
extern void cmacs_gnuseye_overlay_base_changed (CmacsLibregnumRenderCtx *r);

#endif /* HAVE_CMACS_GNUSEYE */
#endif /* CMACS_GNUSEYE_RENDER_INTERNAL_H */
