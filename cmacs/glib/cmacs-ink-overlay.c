/* cmacs-ink-overlay.c — Post-glyph stroke overlay paint pass
 *
 * Copyright (C) 2026 Zach Podbielniak
 * SPDX-License-Identifier: AGPL-3.0-or-later
 *
 * For each leaf window of FRAME:
 *   1. Read `cmacs-ink-region--annotations' from the displayed
 *      buffer via `buffer_local_value' (safe to call from a
 *      redisplay-finish hook; doesn't recurse into redisplay).
 *   2. For each annotation, ask `pos_visible_p' for the pixel
 *      position of its start-marker.  If off-screen above, skip.
 *      If off-screen below, skip.
 *   3. Translate to frame-absolute coords (window box edges +
 *      window-relative x,y).
 *   4. Clip to the window's text area so strokes never bleed into
 *      mode-line, header-line, or fringe.
 *   5. Paint the stroke set via `org_ex_ink_paint_strokes_cairo'
 *      with the user-tunable alpha (`cmacs-ink-region-default-alpha').
 */

#include <config.h>

#ifdef HAVE_CMACS_GLIB

#include "lisp.h"
#include "frame.h"
#include "buffer.h"
#include "window.h"
#include "cmacs-ink-overlay.h"

#ifdef HAVE_PGTK
#include "pgtkterm.h"
#include <cairo.h>

#define ORG_EX_COMPILATION
#include "org-ex.h"

/* Reach into the frame's Cairo context without depending on the
   file-local FRAME_CR_CONTEXT macro from src/pgtkterm.c. */
#define CMACS_FRAME_CR_CONTEXT(f) ((f)->output_data.pgtk->cr_context)

/* Symbol referencing the buffer-local annotations list, defined in
   `cmacs-ink-region.el' via `defvar-local'.  Cached on first use. */
static Lisp_Object Qcmacs_ink_region__annotations;
static Lisp_Object Qcmacs_ink_overlay_mode;
static Lisp_Object Qcmacs_ink_region_default_alpha;

/* Plist keys; same caching rationale as the symbols above. */
static Lisp_Object QCstart_marker;
static Lisp_Object QCstrokes_string;
static Lisp_Object QCstrokes_ptr;
static Lisp_Object QCorphan;
static Lisp_Object QCcapture_dx;
static Lisp_Object QCcapture_dy;

/* Wrapper that returns Qunbound for variables that haven't been
   defined yet — the post-glyph paint hook runs on every redisplay
   from the moment the frame is mapped, including before
   `cmacs-ink-region.el' is autoloaded.  Touching `buffer_local_value'
   on an unbound symbol cascades into `Fdefault_value' which signals
   `void-variable' (caught here as Doom's `doom-after-init-hook'
   error). */
static Lisp_Object
cmacs_ink_safe_blv (Lisp_Object var, Lisp_Object buffer)
{
  if (NILP (Fboundp (var)))
    return Qunbound;
  return buffer_local_value (var, buffer);
}

static Lisp_Object
cmacs_ink_safe_blv (Lisp_Object var, Lisp_Object buffer);

static double
cmacs_ink_overlay_alpha_for_buffer (Lisp_Object buffer)
{
  /* `cmacs-ink-region-default-alpha' is buffer-local; the previous
     implementation called `find_symbol_value' which returns the
     value in the *current* buffer at the time of the call — not the
     buffer being painted.  When painting a window for buffer B
     while the user is interacting with buffer A, alpha would be
     read from A.  Fix: explicitly look up in B. */
  Lisp_Object v = cmacs_ink_safe_blv (Qcmacs_ink_region_default_alpha,
                                      buffer);
  if (BASE_EQ (v, Qunbound))
    return 0.85;
  if (FLOATP (v))
    {
      double a = XFLOAT_DATA (v);
      if (a < 0.0) a = 0.0;
      if (a > 1.0) a = 1.0;
      return a;
    }
  if (FIXNUMP (v))
    {
      EMACS_INT a = XFIXNUM (v);
      return a >= 1 ? 1.0 : (a <= 0 ? 0.0 : a);
    }
  return 0.85;
}

static GPtrArray *
cmacs_ink_overlay_parse_strokes (Lisp_Object strokes_string)
{
  GPtrArray *strokes;
  GError *err = NULL;
  if (!STRINGP (strokes_string))
    return NULL;
  strokes = org_ex_ink_strokes_from_string (SSDATA (strokes_string), &err);
  if (err != NULL)
    g_error_free (err);
  return strokes;
}

/* Paint annotations for one leaf window.  CR is the per-draw GTK
   context (NOT the persistent back-surface context); each draw
   signal supplies a fresh cr targeting the GdkWindow, which is why
   alpha-blended strokes don't accumulate across redisplays now. */
static void
cmacs_ink_overlay_paint_window (struct frame *f, struct window *w,
                                cairo_t *cr)
{
  Lisp_Object buffer, annotations, tail;
  int win_x, win_y, win_w, win_h;
  int text_area_left, text_area_top;
  double alpha;

  if (!WINDOW_LEAF_P (w))
    return;
  buffer = w->contents;
  if (!BUFFERP (buffer))
    return;

  /* Mode check: skip the entire window if `cmacs-ink-overlay-mode'
     is not on in this buffer.  Cheap fast path for buffers that
     never opted in. */
  {
    Lisp_Object mode_on
      = cmacs_ink_safe_blv (Qcmacs_ink_overlay_mode, buffer);
    if (NILP (mode_on) || BASE_EQ (mode_on, Qunbound))
      return;
  }

  annotations = cmacs_ink_safe_blv (Qcmacs_ink_region__annotations,
                                    buffer);
  if (NILP (annotations) || BASE_EQ (annotations, Qunbound))
    return;

  /* Per-buffer alpha — see `cmacs_ink_overlay_alpha_for_buffer'. */
  alpha = cmacs_ink_overlay_alpha_for_buffer (buffer);

  /* Frame-absolute origin of the *text area* (NOT the outer
     window).  Strokes were captured against a screenshot whose
     top-left = frame-absolute glyph origin = (window_box_left
     (TEXT_AREA), WINDOW_TOP_EDGE_Y + tab + header).  Adding
     pos_visible_p's (text-area-relative x, window-box-relative y)
     to this origin lands strokes back at the glyph they were drawn
     over.  Using WINDOW_BOX_LEFT_PIXEL_EDGE / WINDOW_TOP_PIXEL_EDGE
     here would re-introduce the (tab+header) y-offset bug —
     pos_visible_p's y already includes header+tab, so we must NOT
     add them again via WINDOW_TOP_PIXEL_EDGE.  See
     `cmacs-ink-region--region-pixel-rect' in the elisp side, which
     mirrors this via `window-body-pixel-edges'. */
  text_area_left = window_box_left (w, TEXT_AREA);
  text_area_top  = WINDOW_TOP_EDGE_Y (w);

  /* Generous clip rectangle: the whole window box.  Keeps strokes
     from bleeding into adjacent windows / mode-line area in split
     layouts.  We don't clip tighter to the text area because
     pos_visible_p's window-box-relative y is already inside the
     text area for visible glyphs, and a slightly permissive clip
     leaves room for stroke widths near the boundaries. */
  win_x = WINDOW_BOX_LEFT_PIXEL_EDGE (w);
  win_y = WINDOW_TOP_PIXEL_EDGE (w);
  win_w = WINDOW_PIXEL_WIDTH (w);
  win_h = WINDOW_PIXEL_HEIGHT (w);

  cairo_save (cr);
  cairo_rectangle (cr, win_x, win_y, win_w, win_h);
  cairo_clip (cr);

  for (tail = annotations; CONSP (tail); tail = XCDR (tail))
    {
      Lisp_Object plist = XCAR (tail);
      Lisp_Object start_marker, strokes_ptr, strokes_string, orphan;
      Lisp_Object capture_dx, capture_dy;
      ptrdiff_t start_pos;
      int x, y, rtop = 0, rbot = 0, rowh = 0, vpos = 0;
      int dx = 0, dy = 0;
      bool visible;
      GPtrArray *strokes = NULL;
      bool owned = false;

      if (!CONSP (plist))
        continue;

      start_marker   = Fplist_get (plist, QCstart_marker, Qnil);
      strokes_ptr    = Fplist_get (plist, QCstrokes_ptr, Qnil);
      strokes_string = Fplist_get (plist, QCstrokes_string, Qnil);
      orphan         = Fplist_get (plist, QCorphan, Qnil);
      capture_dx     = Fplist_get (plist, QCcapture_dx, Qnil);
      capture_dy     = Fplist_get (plist, QCcapture_dy, Qnil);
      if (FIXNUMP (capture_dx)) dx = (int) XFIXNUM (capture_dx);
      if (FIXNUMP (capture_dy)) dy = (int) XFIXNUM (capture_dy);
      (void) orphan;  /* tracked in the plist for `cmacs-ink-region-list',
                         but not a paint-skip — see comment below. */

      if (!MARKERP (start_marker))
        continue;
      if (!EQ (Fmarker_buffer (start_marker), buffer))
        continue;
      /* NB: we used to `continue' on orphan here, but that hid
         strokes whose hash mismatched even though the marker was
         correctly placed at the saved line.  The marker is the
         source of truth for "where to paint"; the orphan flag is
         purely informational (shown in `cmacs-ink-region-list').
         Hiding strokes silently was confusing; paint always when
         we have a marker, let the user re-anchor or delete via
         the list/edit commands. */

      start_pos = marker_position (start_marker);

      visible = pos_visible_p (w, start_pos, &x, &y,
                               &rtop, &rbot, &rowh, &vpos);
      if (!visible)
        continue;

      /* Prefer the cached pre-parsed user-ptr — set up once at load
         time / capture commit, so the redisplay-finish hot path
         skips the per-frame parse cycle.  Fall back to parsing the
         strokes-string for legacy in-memory anchors that haven't
         been refreshed yet. */
      if (USER_PTRP (strokes_ptr))
        {
          strokes = (GPtrArray *) XUSER_PTR (strokes_ptr)->p;
          owned = false;          /* GC owns; do NOT unref */
        }
      else
        {
          strokes = cmacs_ink_overlay_parse_strokes (strokes_string);
          owned = (strokes != NULL);
        }

      if (strokes == NULL)
        continue;

      /* pos_visible_p returns x in text-area-relative coords and y
         in window-box-relative coords (its iterator's current_y is
         seeded with tab-line + header-line height, so y already
         includes those).  Add to the frame-absolute text-area
         origin to get the frame-absolute glyph position — which is
         exactly where the screenshot top-left was captured by the
         elisp side, so strokes recorded against the screenshot's
         (0, 0) land back on the same glyph. */
      /* Subtract (dx, dy) so paint origin = rect-top-left at capture
         time, regardless of where in the rect the start-marker
         sits.  For multi-line regions whose end column is leftward
         of start, dx > 0 and the rect extends left of start; paint
         must compensate or strokes drift right by dx px. */
      org_ex_ink_paint_strokes_cairo (
        cr, strokes,
        (double) (text_area_left + x - dx),
        (double) (text_area_top  + y - dy),
        alpha);

      if (owned)
        g_ptr_array_unref (strokes);
    }

  cairo_restore (cr);
}

static void
cmacs_ink_overlay_walk (struct frame *f, struct window *w, cairo_t *cr)
{
  while (w != NULL)
    {
      if (WINDOW_LEAF_P (w))
        {
          cmacs_ink_overlay_paint_window (f, w, cr);
        }
      else if (WINDOWP (w->contents))
        {
          /* Internal window: recurse into the child tree. */
          cmacs_ink_overlay_walk (f, XWINDOW (w->contents), cr);
        }

      if (NILP (w->next))
        break;
      w = XWINDOW (w->next);
    }
}

void
cmacs_ink_overlay_paint (struct frame *f, cairo_t *cr)
{
  Lisp_Object root;

  if (f == NULL || cr == NULL)
    return;
  if (!FRAME_PGTK_P (f))
    return;

  root = FRAME_ROOT_WINDOW (f);
  if (!WINDOWP (root))
    return;

  /* Alpha is now resolved per-window-buffer inside the walk so each
     buffer's local override is honoured.  CR is the GTK draw-signal
     context — paint goes onto the screen-bound surface, not the
     persistent back buffer, so strokes are recomposed fresh on
     every draw event. */
  cmacs_ink_overlay_walk (f, XWINDOW (root), cr);
}

#endif /* HAVE_PGTK */

void
syms_of_cmacs_ink_overlay (void)
{
#ifdef HAVE_PGTK
  Qcmacs_ink_region__annotations =
    intern_c_string ("cmacs-ink-region--annotations");
  staticpro (&Qcmacs_ink_region__annotations);

  Qcmacs_ink_overlay_mode =
    intern_c_string ("cmacs-ink-overlay-mode");
  staticpro (&Qcmacs_ink_overlay_mode);

  Qcmacs_ink_region_default_alpha =
    intern_c_string ("cmacs-ink-region-default-alpha");
  staticpro (&Qcmacs_ink_region_default_alpha);

  QCstart_marker   = intern_c_string (":start-marker");
  QCstrokes_string = intern_c_string (":strokes-string");
  QCstrokes_ptr    = intern_c_string (":strokes-ptr");
  QCorphan         = intern_c_string (":orphan");
  QCcapture_dx     = intern_c_string (":capture-dx");
  QCcapture_dy     = intern_c_string (":capture-dy");
  staticpro (&QCstart_marker);
  staticpro (&QCstrokes_string);
  staticpro (&QCstrokes_ptr);
  staticpro (&QCorphan);
  staticpro (&QCcapture_dx);
  staticpro (&QCcapture_dy);
#endif
}

#endif /* HAVE_CMACS_GLIB */
