/* cmacs-gowl.h — Gowl Wayland compositor integration
 *
 * Copyright (C) 2026 Zach Podbielniak
 * SPDX-License-Identifier: AGPL-3.0-or-later
 *
 * Embeds gowl (GObject Wayland compositor) into CMacs so that Emacs
 * itself becomes the Wayland window manager.
 */

#ifndef CMACS_GOWL_H
#define CMACS_GOWL_H

#include <config.h>

#ifdef HAVE_CMACS_GOWL

#include <gowl.h>

/* Start the compositor dispatch thread. */
extern void cmacs_gowl_start_thread (void);

/* Inhibit parent compositor keyboard shortcuts (nested mode). */
extern void cmacs_gowl_inhibit_parent_shortcuts (GowlCompositor *comp);

#endif /* HAVE_CMACS_GOWL */
#endif /* CMACS_GOWL_H */
