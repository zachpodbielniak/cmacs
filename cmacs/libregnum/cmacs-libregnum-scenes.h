/* cmacs-libregnum-scenes.h --- scene-builder plain-C API.
 *
 * Copyright (C) 2026 Zach Podbielniak
 * SPDX-License-Identifier: AGPL-3.0-or-later
 *
 * Scene builders live in cmacs-libregnum-scene-*.c files and call
 * libregnum.h directly.  This header exposes their plain-C entry
 * points so cmacs-internal code (defuns.c) can invoke them without
 * pulling in the Color-typedef-clashing libregnum/raylib headers. */

#ifndef CMACS_LIBREGNUM_SCENES_H
#define CMACS_LIBREGNUM_SCENES_H

#include <config.h>

#ifdef HAVE_CMACS_LIBREGNUM

#include <glib.h>
#include "cmacs-libregnum-render.h"

/* Each builder repopulates the render context's drawable list from
 * the scene-type-specific source data.  Idempotent: safe to call
 * again to refresh after underlying data changes. */

extern gboolean cmacs_libregnum_scene_tree_build
                      (CmacsLibregnumRenderCtx *r,
                       const gchar *root_path);

extern gboolean cmacs_libregnum_scene_gobject_build
                      (CmacsLibregnumRenderCtx *r,
                       const gchar *namespace_name);

extern gboolean cmacs_libregnum_scene_mindmap_build
                      (CmacsLibregnumRenderCtx *r,
                       const gchar *org_file_path);

#endif /* HAVE_CMACS_LIBREGNUM */
#endif /* CMACS_LIBREGNUM_SCENES_H */
