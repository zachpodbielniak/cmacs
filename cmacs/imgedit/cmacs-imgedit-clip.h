/* cmacs-imgedit-clip.h --- in-process GTK image clipboard (pgtk).
 *
 * Copyright (C) 2026 Zach Podbielniak
 * SPDX-License-Identifier: AGPL-3.0-or-later
 *
 * Plain-C bridge (no lisp.h): puts/reads PNG image bytes on the session
 * clipboard through Emacs's own GTK connection, so it behaves like any
 * GTK application's clipboard -- identical under gowl, Mutter/GNOME, KDE
 * or X11, with no external tools or wlr-data-control requirement.  On
 * non-pgtk builds (or when no GDK display is connected, e.g. --lrg / tty)
 * the calls report unavailable and callers fall back to wl-clipboard.  */

#ifndef CMACS_IMGEDIT_CLIP_H
#define CMACS_IMGEDIT_CLIP_H

#include <glib.h>

/* Non-zero when an in-process GTK clipboard is usable right now.  */
extern gboolean cmacs_imgedit_clip_available (void);

/* Put PNG bytes on the clipboard as an image.  FALSE + *ERROR_MSG
   (g_free-able) on failure.  */
extern gboolean cmacs_imgedit_clip_set_png (const guint8 *png, gsize n,
                                            char **error_msg);

/* Read an image off the clipboard as PNG bytes (g_malloc'd, caller
   g_free's; length in *OUT_N).  NULL when unavailable or no image.  */
extern guint8 *cmacs_imgedit_clip_get_png (gsize *out_n, char **error_msg);

#endif /* CMACS_IMGEDIT_CLIP_H */
