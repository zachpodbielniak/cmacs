/* cmacs-gnuseye.h --- GNU's Eye: live planetary situational-awareness globe.
 *
 * Copyright (C) 2026 Zach Podbielniak
 * SPDX-License-Identifier: AGPL-3.0-or-later
 *
 * gnuseye embeds a Google-Earth / Palantir-style 3D globe inside a cmacs
 * buffer.  It is rendered *through* the libregnum subsystem: a gnuseye
 * buffer owns a CmacsLibregnumView whose render context holds a persistent
 * textured Earth sphere plus per-tick marker/arc drawables built from live
 * geospatial feeds (satellites, aircraft, vessels, weather, ...).
 *
 * Architecture (firewall): raylib's `Color' struct clashes with cmacs's
 * pgtkgui.h `Color' typedef, so the only translation unit that includes
 * <libregnum.h> is cmacs-gnuseye-globe.c (the "render half"), exactly like
 * the libregnum scene-*.c builders.  Every other gnuseye .c includes
 * lisp.h and talks to the render half through the plain-C API in
 * cmacs-gnuseye-globe.h.  Pure geodesy lives in cmacs-gnuseye-geomath.h
 * (no Lisp, no libregnum) so both halves can share it. */

#ifndef CMACS_GNUSEYE_H
#define CMACS_GNUSEYE_H

#include <config.h>

#ifdef HAVE_CMACS_GNUSEYE

#include "lisp.h"

/* syms_of_cmacs_gnuseye / init_cmacs_gnuseye are declared in src/lisp.h
 * alongside the other cmacs subsystem entry points.  Each gnuseye
 * translation unit that registers DEFUNs exposes its own syms_of_ hook,
 * aggregated by syms_of_cmacs_gnuseye in cmacs-gnuseye-init.c. */
extern void syms_of_cmacs_gnuseye_defuns  (void);
extern void syms_of_cmacs_gnuseye_geo     (void);
extern void syms_of_cmacs_gnuseye_sgp4    (void);
extern void syms_of_cmacs_gnuseye_http    (void);
extern void syms_of_cmacs_gnuseye_overlay (void);

/* The error symbol `cmacs-gnuseye-error' is DEFSYM'd in
 * cmacs-gnuseye-defuns.c; DEFSYM auto-generates Qcmacs_gnuseye_error into
 * globals.h, so no extern declaration is needed (or allowed) here. */

/* One-time runtime init (SoupSession, etc.); safe to call repeatedly. */
extern void cmacs_gnuseye_http_init (void);
extern void cmacs_gnuseye_http_shutdown (void);

#endif /* HAVE_CMACS_GNUSEYE */
#endif /* CMACS_GNUSEYE_H */
