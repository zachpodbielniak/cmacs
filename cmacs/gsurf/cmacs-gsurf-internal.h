/* cmacs-gsurf-internal.h --- shared gsurf-typed internals.
 *
 * Copyright (C) 2026 Zach Podbielniak
 * SPDX-License-Identifier: AGPL-3.0-or-later
 *
 * Internal header shared by the gsurf-typed translation units
 * (cmacs-gsurf-init.c, cmacs-gsurf-view.c, cmacs-gsurf-modules.c).  It
 * may include gsurf.h (which is itself GTK-free); the GTK/WebKit bits
 * are confined to cmacs-gsurf-view.c. */

#ifndef CMACS_GSURF_INTERNAL_H
#define CMACS_GSURF_INTERNAL_H

#include <config.h>

#ifdef HAVE_CMACS_GSURF

#include <gsurf/gsurf.h>
#include "cmacs-gsurf.h"

G_BEGIN_DECLS

/* The process-wide gsurf application + config, created lazily by
   cmacs_gsurf_runtime_ensure ().  NULL until then. */
GsurfApplication *cmacs_gsurf_app    (void);
GsurfConfig      *cmacs_gsurf_config (void);

#ifdef HAVE_CMACS_GSURF_LRG
/* LRG-backend view accessors (defined in cmacs-gsurf-view.c, used by
   cmacs-gsurf-lrg.c).  Kept here so cmacs-gsurf.h stays libregnum-free. */
gboolean        cmacs_gsurf_view_is_lrg        (CmacsGsurfView *v);
GsurfView      *cmacs_gsurf_view_gsurf         (CmacsGsurfView *v);
gboolean        cmacs_gsurf_view_focused_p     (CmacsGsurfView *v);
CmacsGsurfView *cmacs_gsurf_lrg_focused_view   (void);
#endif

G_END_DECLS

#endif /* HAVE_CMACS_GSURF */
#endif /* CMACS_GSURF_INTERNAL_H */
