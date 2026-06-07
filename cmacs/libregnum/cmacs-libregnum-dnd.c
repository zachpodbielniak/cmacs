/* cmacs-libregnum-dnd.c --- GTK drag-source for libregnum palette/asset rows.
 *
 * Copyright (C) 2026 Zach Podbielniak
 * SPDX-License-Identifier: AGPL-3.0-or-later
 *
 * See cmacs-libregnum-dnd.h for the design rationale.  This file:
 *
 *   - Defines the per-frame DnD armed state.
 *   - Implements the drag-data-get GLib callback (no Lisp calls).
 *   - Exposes cmacs_libregnum_dnd_setup_frame and
 *     cmacs_libregnum_dnd_check_motion for the thin upstream hunk in
 *     pgtkterm.c.
 *   - Exposes the DEFUN cmacs-libregnum-dnd-arm so Elisp can arm a drag
 *     from a [down-mouse-1] handler in palette/asset mode maps.
 *
 * MIME targets offered:
 *   "text/plain"                -- generic; accepted by most GTK apps.
 *   "application/x-libregnum"  -- custom; lets the viewport drop handler
 *                                  identify libregnum payloads reliably.
 *
 * Payload format (same for both targets):
 *   "lrg-prim:<name>"          -- a primitive (cube, sphere, …)
 *   "lrg-kind:<value>"         -- a visual-kind node (light, camera, …)
 *   "lrg-asset:<abs-path>"     -- a mesh/sprite file
 */

#include <config.h>

#ifdef HAVE_CMACS_LIBREGNUM
#ifdef HAVE_PGTK

#include "lisp.h"
#include "frame.h"
#include "buffer.h"
#include "window.h"
#include "pgtkterm.h"          /* FRAME_GTK_WIDGET, FRAME_DISPLAY_INFO */

#include "cmacs-libregnum-dnd.h"

#include <gtk/gtk.h>
#include <string.h>

/* ── MIME targets ───────────────────────────────────────────────────── */

/* Target IDs passed through the drag machinery.  Values are arbitrary;
 * 0 and 1 keep them distinct from GTK's built-in target IDs. */
#define LRG_DND_TARGET_TEXT_PLAIN   0
#define LRG_DND_TARGET_APP_LRG      1

static const GtkTargetEntry lrg_dnd_targets[] = {
  { (gchar *) "text/plain",               0, LRG_DND_TARGET_TEXT_PLAIN },
  { (gchar *) "application/x-libregnum", 0, LRG_DND_TARGET_APP_LRG   },
};
static const guint lrg_dnd_n_targets = G_N_ELEMENTS (lrg_dnd_targets);

/* ── Per-drag stash ─────────────────────────────────────────────────── */
/*
 * A single drag is active at most once in the whole process, so a single
 * global struct is sufficient.  There are no threading concerns here: all
 * GTK callbacks run on the main thread, same as the Emacs event loop.
 *
 * lrg_dnd_payload is set by cmacs-libregnum-dnd-arm (called from Elisp),
 * read by drag_data_get_cb (called from GTK drag machinery), and freed
 * when the drag ends or is preempted.  It is a plain malloc'd C string,
 * not a Lisp_Object -- no GC involvement needed.
 */
static char  *lrg_dnd_payload = NULL;  /* NULL means no armed drag */
static gint   lrg_dnd_press_x = 0;    /* button-press pixel (frame-local) */
static gint   lrg_dnd_press_y = 0;
static struct frame *lrg_dnd_frame = NULL; /* frame that armed the drag */

static void
lrg_dnd_clear (void)
{
  if (lrg_dnd_payload)
    {
      free (lrg_dnd_payload);
      lrg_dnd_payload = NULL;
    }
  lrg_dnd_frame = NULL;
}

/* ── drag-data-get callback ─────────────────────────────────────────── */
/*
 * Called by GTK when the drop target requests the data.  Must NOT call
 * any Lisp function (we are inside a GTK signal emission).  We simply
 * return the stashed payload string for whichever target was requested.
 */
static void
drag_data_get_cb (GtkWidget        *widget,
                  GdkDragContext   *context,
                  GtkSelectionData *data,
                  guint             info,
                  guint             time,
                  gpointer          user_data)
{
  (void) widget; (void) context; (void) time; (void) user_data;

  if (!lrg_dnd_payload)
    return;

  if (info == LRG_DND_TARGET_TEXT_PLAIN || info == LRG_DND_TARGET_APP_LRG)
    gtk_selection_data_set_text (data, lrg_dnd_payload, -1);
}

/* ── drag-end callback ──────────────────────────────────────────────── */
/*
 * Called by GTK when the drag ends (drop or cancel).  Free the stash so a
 * subsequent [down-mouse-1] arm starts clean.
 */
static void
drag_end_cb (GtkWidget      *widget,
             GdkDragContext *context,
             gpointer        user_data)
{
  (void) widget; (void) context; (void) user_data;
  lrg_dnd_clear ();
}

/* ── cmacs_libregnum_dnd_setup_frame ────────────────────────────────── */
/*
 * Called once per frame from pgtk_set_event_handler (the upstream hunk in
 * pgtkterm.c).  Connects drag-data-get and drag-end to the frame's edit
 * widget so they fire whenever we initiate a drag on that widget.
 * Idempotent: we tag the widget with a sentinel via g_object_set_data.
 */
void
cmacs_libregnum_dnd_setup_frame (struct frame *f)
{
  GtkWidget *widget = FRAME_GTK_WIDGET (f);
  if (!widget)
    return;

  /* Sentinel: only connect once per widget instance. */
  if (g_object_get_data (G_OBJECT (widget), "cmacs-lrg-dnd-setup"))
    return;
  g_object_set_data (G_OBJECT (widget), "cmacs-lrg-dnd-setup",
                     GINT_TO_POINTER (1));

  g_signal_connect (G_OBJECT (widget), "drag-data-get",
                    G_CALLBACK (drag_data_get_cb), NULL);
  g_signal_connect (G_OBJECT (widget), "drag-end",
                    G_CALLBACK (drag_end_cb), NULL);
}

/* ── cmacs_libregnum_dnd_check_motion ───────────────────────────────── */
/*
 * Called from the existing #ifdef HAVE_CMACS_LIBREGNUM block in
 * motion_notify_event (pgtkterm.c).  Returns TRUE and initiates a GTK drag
 * iff:
 *   1. A palette/asset drag was armed (lrg_dnd_payload != NULL).
 *   2. The event belongs to the armed frame.
 *   3. Button-1 is still held (GDK_BUTTON1_MASK in the event state).
 *   4. The pointer has moved past GTK's drag threshold.
 *
 * If button-1 is no longer held we auto-disarm (the user released without
 * dragging; Emacs handled the click normally).
 */
gboolean
cmacs_libregnum_dnd_check_motion (struct frame *f, GdkEvent *event)
{
  GtkWidget *widget;
  GdkModifierType state;

  if (!lrg_dnd_payload || f != lrg_dnd_frame)
    return FALSE;

  if (!gdk_event_get_state (event, &state))
    return FALSE;

  /* Auto-disarm if button-1 was released before threshold. */
  if (!(state & GDK_BUTTON1_MASK))
    {
      lrg_dnd_clear ();
      return FALSE;
    }

  widget = FRAME_GTK_WIDGET (f);
  if (!widget)
    return FALSE;

  /* Check whether the pointer has moved past the drag threshold.
   * gtk_drag_check_threshold uses the GTK setting "gtk-dnd-drag-threshold". */
  {
    gdouble cur_x, cur_y;
    if (!gdk_event_get_coords (event, &cur_x, &cur_y))
      return FALSE;

    if (!gtk_drag_check_threshold (widget,
                                   lrg_dnd_press_x, lrg_dnd_press_y,
                                   (gint) cur_x, (gint) cur_y))
      return FALSE;
  }

  /* Threshold crossed: initiate the GTK drag. */
  {
    GtkTargetList *targets;
    struct pgtk_display_info *dpyinfo = FRAME_DISPLAY_INFO (f);
    GdkEvent *press_event = dpyinfo ? dpyinfo->last_click_event : NULL;

    targets = gtk_target_list_new (lrg_dnd_targets, lrg_dnd_n_targets);

    /* gtk_drag_begin_with_coordinates wants the original button-press event
     * for its device/timestamp.  dpyinfo->last_click_event is stashed in
     * button_event (pgtkterm.c) on every button press, so it is the correct
     * GdkEvent here.  Passing NULL is also valid (GTK falls back to the
     * default seat's pointer) but may use the wrong timestamp. */
    gtk_drag_begin_with_coordinates (widget, targets,
                                     GDK_ACTION_COPY,
                                     1,           /* button */
                                     press_event,
                                     lrg_dnd_press_x, lrg_dnd_press_y);

    gtk_target_list_unref (targets);

    /* Clear the armed flag NOW; drag_end_cb will also call lrg_dnd_clear but
     * we want the frame pointer cleared immediately so a re-arm after a very
     * fast drag does not confuse things. */
    lrg_dnd_frame = NULL;   /* payload left for drag-data-get, cleared in drag_end_cb */
  }

  return TRUE;   /* short-circuit motion_notify_event */
}

/* ── DEFUN cmacs-libregnum-dnd-arm ─────────────────────────────────── */

DEFUN ("cmacs-libregnum-dnd-arm", Fcmacs_libregnum_dnd_arm,
       Scmacs_libregnum_dnd_arm, 3, 4, 0,
       doc: /* Arm a GTK drag-source for the libregnum palette/asset panel.

PAYLOAD is a string describing the dragged item in one of these formats:
  \"lrg-prim:NAME\"      -- a named primitive shape
  \"lrg-kind:VALUE\"     -- a visual-kind integer as a string
  \"lrg-asset:PATH\"     -- absolute path to a mesh/sprite file

PRESS-X and PRESS-Y are the frame-relative pixel coordinates of the
button-press that initiated the drag (typically from (posn-x-y
\(event-start last-input-event\))).

FRAME defaults to the selected frame.

After calling this function, the C motion handler checks each subsequent
motion event; when the pointer has moved past GTK's drag threshold the GTK
drag is initiated automatically (no further Lisp action needed).

This function is intended to be called from a [down-mouse-1] binding in
`cmacs-libregnum-palette-mode-map' or `cmacs-libregnum-assets-mode-map'.  */)
  (Lisp_Object payload, Lisp_Object press_x, Lisp_Object press_y,
   Lisp_Object frame)
{
  struct frame *f;

  CHECK_STRING (payload);
  CHECK_FIXNUM (press_x);
  CHECK_FIXNUM (press_y);

  f = decode_window_system_frame (frame);

  /* Discard any previous un-triggered arm (e.g. rapid successive clicks). */
  lrg_dnd_clear ();

  lrg_dnd_payload = xstrdup (SSDATA (payload));
  lrg_dnd_press_x = (gint) XFIXNUM (press_x);
  lrg_dnd_press_y = (gint) XFIXNUM (press_y);
  lrg_dnd_frame   = f;

  return Qnil;
}

/* ── syms_of_cmacs_libregnum_dnd ────────────────────────────────────── */

void
syms_of_cmacs_libregnum_dnd (void)
{
  defsubr (&Scmacs_libregnum_dnd_arm);
}

#endif /* HAVE_PGTK */
#endif /* HAVE_CMACS_LIBREGNUM */
