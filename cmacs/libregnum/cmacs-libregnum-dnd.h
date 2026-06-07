/* cmacs-libregnum-dnd.h --- GTK drag-source for libregnum palette/asset rows.
 *
 * Copyright (C) 2026 Zach Podbielniak
 * SPDX-License-Identifier: AGPL-3.0-or-later
 *
 * This header is intentionally narrow: it only exposes what pgtkterm.c
 * needs to keep the upstream hunk small.
 *
 * Design: why not gtk_drag_source_set
 * ─────────────────────────────────────
 * gtk_drag_source_set operates at the GtkWidget level (the entire Emacs
 * frame).  It monitors every button-press on that widget and can initiate
 * a GDK pointer grab on any mouse click, which conflicts with Emacs's own
 * grab tracking (dpyinfo->grabbed), breaks text selection and scroll bars,
 * and cannot be gated on the current buffer's major mode.
 *
 * Instead we use a manual two-phase approach (no gtk_drag_source_set):
 *
 *   Phase 1 (Elisp, [down-mouse-1] in palette/asset mode maps):
 *     Emacs fires [down-mouse-1] on button-press while the button is still
 *     held.  The handler calls the DEFUN cmacs-libregnum-dnd-arm with the
 *     drag payload and the press pixel coordinates.  Those are stored in a
 *     C-side per-frame struct; no GDK grab occurs yet.
 *
 *   Phase 2 (C, existing #ifdef HAVE_CMACS_LIBREGNUM block in
 *             motion_notify_event inside pgtkterm.c):
 *     cmacs_libregnum_dnd_check_motion is called each time a motion event
 *     arrives.  When the armed flag is set, button-1 is still held (checked
 *     from the GDK event's state mask), and the pointer has moved beyond
 *     GTK's drag threshold (gtk_drag_check_threshold), we call
 *     gtk_drag_begin_with_coordinates using dpyinfo->last_click_event for
 *     the proper device and timestamp, then return TRUE to short-circuit
 *     the rest of the handler.  GTK now owns the pointer until the drop.
 *
 *   If button-1 is released before the threshold is crossed, Emacs delivers
 *   the normal mouse-1 / drag-mouse-1 events unchanged (the armed flag is
 *   auto-cleared when the next motion event sees button-1 not held, or when
 *   the drag actually begins).
 *
 *   drag-data-get: connected once per frame in pgtk_set_event_handler via
 *   cmacs_libregnum_dnd_setup_frame.  Its callback returns the stashed
 *   payload as text/plain and as the custom "application/x-libregnum"
 *   target without calling Lisp (safe from a GTK signal callback). */

#ifndef CMACS_LIBREGNUM_DND_H
#define CMACS_LIBREGNUM_DND_H

#include <config.h>

#ifdef HAVE_CMACS_LIBREGNUM
#ifdef HAVE_PGTK

#include <glib.h>

struct frame;

/* Connected once per frame in pgtk_set_event_handler to hook drag-data-get
 * on the frame's edit widget.  Idempotent (guarded by g_object_get_data). */
extern void    cmacs_libregnum_dnd_setup_frame    (struct frame *f);

/* Called in the existing #ifdef HAVE_CMACS_LIBREGNUM block inside
 * motion_notify_event.  Returns TRUE (and short-circuits the handler) when
 * it successfully initiates a GTK drag. */
extern gboolean cmacs_libregnum_dnd_check_motion (struct frame *f,
                                                  GdkEvent     *event);

/* Declared here so cmacs-libregnum-init.c can call defsubr for the DEFUN
 * cmacs-libregnum-dnd-arm which is defined in cmacs-libregnum-dnd.c.
 * (syms_of_cmacs_libregnum calls this file's syms_of helper.) */
extern void syms_of_cmacs_libregnum_dnd (void);

#endif /* HAVE_PGTK */
#endif /* HAVE_CMACS_LIBREGNUM */
#endif /* CMACS_LIBREGNUM_DND_H */
