/* cmacs-glib-screenshot.h — Frame Cairo surface screenshot DEFUNs
 *
 * Copyright (C) 2026 Zach Podbielniak
 * SPDX-License-Identifier: AGPL-3.0-or-later
 *
 * Exposes the running pgtk frame's live Cairo back-surface to Elisp
 * as a user-ptr-wrapped cairo_surface_t.  Used by cmacs-ink-region
 * to seed the capture canvas with a snapshot of the selected text,
 * but the primitive is general — useful for any feature that wants
 * to compose Emacs-rendered pixels into a foreign GTK widget.
 */

#ifndef CMACS_GLIB_SCREENSHOT_H
#define CMACS_GLIB_SCREENSHOT_H

#include "lisp.h"

extern void syms_of_cmacs_glib_screenshot (void);

#endif /* CMACS_GLIB_SCREENSHOT_H */
