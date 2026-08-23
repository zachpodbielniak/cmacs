/* cmacs-org-ex-ink-capture.c — GTK3 modal ink capture window
 *
 * Copyright (C) 2026 Zach Podbielniak
 * SPDX-License-Identifier: AGPL-3.0-or-later
 *
 * Pure GTK3 + GDK; no xwidget, no Wayland protocol code, no
 * pgtkterm.c patching.  GTK is already linked into pgtk Emacs, so
 * this file just rides on the existing toolkit.
 *
 * Tablet input model (per the plan):
 *   1. Pen tip   (GDK_DEVICE_TOOL_TYPE_PEN)    → pen stroke
 *   2. Eraser    (GDK_DEVICE_TOOL_TYPE_ERASER) → eraser hit-test
 *   3. Side-button-as-eraser fallback for tools without an eraser end
 *
 * Erase semantic: whole-stroke removal.  An eraser path on commit
 * removes every existing pen stroke that has a point within
 * max(stroke_width, 6) px of the eraser path.
 *
 * Capture is synchronous from Elisp's perspective: a nested
 * g_main_loop is run while the window is up, mirroring how Emacs's
 * modal dialogs work.  The Emacs main loop's GLib hooks
 * (cmacs_glib_prepare/dispatch in cmacs/glib/) keep ticking because
 * the nested loop drives the same default GMainContext.
 */

#include <config.h>

#ifdef HAVE_CMACS_ORG_EX

#include "cmacs-org-ex-ink-capture.h"

#define ORG_EX_COMPILATION
#include "lib/org-ex.h"

#include <gtk/gtk.h>
#include <gdk/gdk.h>

#include <math.h>
#include <signal.h>
#include <string.h>

/* ------------------------------------------------------------------ */
/* Capture state                                                      */
/* ------------------------------------------------------------------ */

typedef struct
{
  GtkWidget   *window;
  GtkWidget   *canvas;
  GMainLoop   *loop;

  /* Canvas geometry */
  gint         width;
  gint         height;

  /* Pen defaults — toolbar updates these in place; new strokes
     pick up the current values.  Previously-drawn strokes keep
     the values that were active at their creation. */
  gchar       *pen_colour;
  gfloat       pen_base_width;

  /* Currently-selected tool.  Toolbar Pen / Hilite / Eraser
     toggles set this; the tablet eraser-end overrides regardless
     (real eraser always erases, see `classify_event'). */
  OrgExInkTool current_tool;

  /* Per-tool last-used widths so toggling between Pen and
     Highlighter doesn't lose the previous value the user set on
     the spin button.  Indexed by `OrgExInkTool'. */
  gfloat       pen_width_remembered;
  gfloat       hilite_width_remembered;
  gchar       *hilite_colour;            /* default "#ffd700" */

  /* Eraser fallback policy */
  gboolean     side_button_erases;

  /* Optional background surface (e.g. a screenshot of an Emacs region
     to be annotated).  When non-NULL, painted at canvas origin
     before the colour bg / white "page" fill is skipped. */
  cairo_surface_t *background_surface;

  /* Optional solid-colour background.  Used when there's no
     screenshot — `#+BEGIN_INK' canvas mode passes a theme-matched
     hex colour here so the canvas blends with the buffer.  NULL
     falls back to white. */
  gchar       *background_colour;

  /* Toolbar widgets — saved so callbacks can interact with them
     (e.g. tool toggle updates the spin button to that tool's
     last-used width). */
  GtkWidget   *btn_pen;
  GtkWidget   *btn_hilite;
  GtkWidget   *btn_eraser;
  GtkWidget   *btn_colour;
  GtkWidget   *spin_width;
  GtkWidget   *btn_bg;       /* may be NULL when not canvas mode */

  /* Stroke state.
     `committed_strokes` is the stable set rendered behind the cursor
     (initial input + finalised pen strokes).  `live_stroke` is the
     in-progress stroke being captured; flushed into committed (or
     applied as an eraser hit-test) on button-release. */
  GPtrArray       *committed_strokes;  /* OrgExInkStroke* */
  OrgExInkStroke  *live_stroke;
  gboolean         live_is_eraser;
  gint             live_kind;          /* 0=idle 1=draw 2=erase */

  /* Has a pen ever been seen?  When yes, ignore raw mouse events so
     palm-touch on a digitiser doesn't paint extra strokes.  Reset
     when the window opens; some users will draw with the mouse. */
  gboolean         saw_pen_tool;

  /* Final outcome */
  gboolean         cancelled;
} CaptureState;

/* ------------------------------------------------------------------ */
/* Helpers                                                            */
/* ------------------------------------------------------------------ */

/* Smallest squared distance from point P=(px,py) to any segment of
   stroke S, in canvas pixels squared.  Used by eraser hit-test. */
static gdouble
stroke_min_dist2_to_point (OrgExInkStroke *stroke, gdouble px, gdouble py)
{
  guint n = 0, i;
  const OrgExInkPoint *pts = org_ex_ink_stroke_get_points (stroke, &n);
  gdouble best = G_MAXDOUBLE;

  if (n == 0)
    return best;
  if (n == 1)
    {
      gdouble dx = px - pts[0].x, dy = py - pts[0].y;
      return dx * dx + dy * dy;
    }

  for (i = 1; i < n; i++)
    {
      gdouble x1 = pts[i - 1].x, y1 = pts[i - 1].y;
      gdouble x2 = pts[i].x,     y2 = pts[i].y;
      gdouble dx = x2 - x1, dy = y2 - y1;
      gdouble len2 = dx * dx + dy * dy;
      gdouble t, qx, qy, ex, ey, d2;

      if (len2 < 1e-6)
        {
          ex = px - x1; ey = py - y1;
          d2 = ex * ex + ey * ey;
        }
      else
        {
          t = ((px - x1) * dx + (py - y1) * dy) / len2;
          if (t < 0.0) t = 0.0;
          if (t > 1.0) t = 1.0;
          qx = x1 + t * dx; qy = y1 + t * dy;
          ex = px - qx;     ey = py - qy;
          d2 = ex * ex + ey * ey;
        }
      if (d2 < best) best = d2;
    }
  return best;
}

/* Apply an eraser stroke to the committed set: any pen stroke with a
   point within K px of any eraser-path point is removed wholesale. */
/* One GdkRGBA component as the 0..255 byte "%02x" wants.
   `unsigned', because %x expects unsigned int and passing a plain int
   is undefined; clamped, because a component outside 0..1 would
   otherwise print as ffffffNN and make a nonsense colour string. */
#define CMACS_INK_RGBA_BYTE(component) \
  ((unsigned int) CLAMP ((int) ((component) * 255 + 0.5), 0, 255))

static void
apply_eraser_to_committed (CaptureState *state, OrgExInkStroke *eraser)
{
  guint n_e = 0, i, j;
  const OrgExInkPoint *epts = org_ex_ink_stroke_get_points (eraser, &n_e);
  GArray *to_remove;

  if (n_e == 0) return;

  to_remove = g_array_new (FALSE, FALSE, sizeof (guint));

  for (i = 0; i < state->committed_strokes->len; i++)
    {
      OrgExInkStroke *s = g_ptr_array_index (state->committed_strokes, i);
      gfloat sw = org_ex_ink_stroke_get_base_width (s);
      gdouble k = sw > 6.0f ? sw : 6.0f;
      gdouble k2 = k * k;
      gboolean hit = FALSE;

      if (org_ex_ink_stroke_get_tool (s) == ORG_EX_INK_TOOL_ERASER)
        continue;

      for (j = 0; j < n_e && !hit; j++)
        {
          gdouble d2 = stroke_min_dist2_to_point (s, epts[j].x, epts[j].y);
          if (d2 <= k2)
            hit = TRUE;
        }
      if (hit)
        g_array_append_val (to_remove, i);
    }

  /* Remove highest-index first so earlier indices stay valid. */
  for (i = to_remove->len; i > 0; i--)
    {
      guint idx = g_array_index (to_remove, guint, i - 1);
      g_ptr_array_remove_index (state->committed_strokes, idx);
    }
  g_array_free (to_remove, TRUE);
}

/* Read a pressure value from a GdkEvent.  Returns 1.0 if the device
   doesn't expose pressure (mouse, fallback). */
static gfloat
read_pressure (GdkEvent *event)
{
  gdouble p = 1.0;
  if (gdk_event_get_axis (event, GDK_AXIS_PRESSURE, &p))
    {
      if (p < 0.0) p = 0.0;
      if (p > 1.0) p = 1.0;
      return (gfloat) p;
    }
  return 1.0f;
}

/* Decide which tool this event represents.  Output is the
   `OrgExInkTool' to apply to the new stroke; `*ignored' is set
   non-zero when the event should be dropped (e.g. raw mouse
   after we've already seen a tablet pen — avoids palm touch).

   Precedence (highest first):
     1. Tablet eraser-end       → ERASER
     2. Toolbar selection       → PEN / HIGHLIGHTER / ERASER
     3. Side-button-as-eraser   → ERASER (mouse fallback)
     4. Default                 → toolbar selection (or PEN). */
static OrgExInkTool
classify_event (CaptureState *state, GdkEvent *event, gboolean *ignored)
{
  GdkDevice *device = gdk_event_get_source_device (event);
  GdkInputSource source = device != NULL
    ? gdk_device_get_source (device) : GDK_SOURCE_MOUSE;
  GdkDeviceTool *tool = gdk_event_get_device_tool (event);

  *ignored = FALSE;

  if (tool != NULL)
    {
      GdkDeviceToolType t = gdk_device_tool_get_tool_type (tool);
      state->saw_pen_tool = TRUE;
      /* Real eraser end always erases regardless of toolbar. */
      if (t == GDK_DEVICE_TOOL_TYPE_ERASER)
        return ORG_EX_INK_TOOL_ERASER;
      /* Pen / pencil / brush / airbrush — honour the toolbar. */
      return state->current_tool;
    }

  /* Non-tool event.  If we've seen a pen this session, the pointer
     is probably a palm — ignore. */
  if (state->saw_pen_tool)
    {
      *ignored = TRUE;
      return ORG_EX_INK_TOOL_PEN;
    }

  /* Pure mouse path: check the side-button-as-eraser fallback. */
  if (source == GDK_SOURCE_MOUSE
      || source == GDK_SOURCE_TOUCHPAD
      || source == GDK_SOURCE_PEN)
    {
      if (state->side_button_erases)
        {
          GdkModifierType mods = 0;
          gdk_event_get_state (event, &mods);
          if (mods & GDK_BUTTON2_MASK)
            return ORG_EX_INK_TOOL_ERASER;
        }
      return state->current_tool;
    }
  return state->current_tool;
}

/* ------------------------------------------------------------------ */
/* Drawing                                                            */
/* ------------------------------------------------------------------ */

static void
parse_hex_colour (const gchar *hex, gdouble *r, gdouble *g, gdouble *b)
{
  GdkRGBA rgba;
  *r = 0.13; *g = 0.13; *b = 0.13;
  if (hex == NULL) return;
  if (gdk_rgba_parse (&rgba, hex))
    {
      *r = rgba.red; *g = rgba.green; *b = rgba.blue;
    }
}

static gdouble
segment_width (gfloat base, gfloat pressure)
{
  gdouble scale = 0.3 + (0.7 * pressure);
  gdouble w = base * scale;
  if (w < 0.5) w = 0.5;
  return w;
}

static void
draw_pen_stroke (cairo_t *cr, OrgExInkStroke *s, gboolean ghost)
{
  guint n = 0, i;
  const OrgExInkPoint *pts = org_ex_ink_stroke_get_points (s, &n);
  gdouble r, g, b;
  gfloat base = org_ex_ink_stroke_get_base_width (s);
  OrgExInkTool tool = org_ex_ink_stroke_get_tool (s);
  gdouble alpha;

  if (n == 0) return;
  parse_hex_colour (org_ex_ink_stroke_get_colour (s), &r, &g, &b);

  /* Highlighter is always semi-transparent (matches the persisted
     SVG render's `stroke-opacity="0.5"' so the live capture and the
     post-commit Emacs overlay render look identical).  Ghost
     (in-progress) strokes are slightly faded (0.45) for both pen
     and highlighter so the user sees their drawing-in-progress
     before commit. */
  if (tool == ORG_EX_INK_TOOL_HIGHLIGHTER)
    alpha = ghost ? 0.30 : 0.5;
  else
    alpha = ghost ? 0.45 : 1.0;

  cairo_set_source_rgba (cr, r, g, b, alpha);
  cairo_set_line_cap (cr, CAIRO_LINE_CAP_ROUND);
  cairo_set_line_join (cr, CAIRO_LINE_JOIN_ROUND);

  if (tool == ORG_EX_INK_TOOL_HIGHLIGHTER)
    {
      /* Uniform width, no pressure modulation. */
      cairo_set_line_width (cr, base);
      if (n == 1)
        {
          cairo_arc (cr, pts[0].x, pts[0].y, base * 0.5, 0, 2 * G_PI);
          cairo_fill (cr);
          return;
        }
      cairo_move_to (cr, pts[0].x, pts[0].y);
      for (i = 1; i < n; i++)
        cairo_line_to (cr, pts[i].x, pts[i].y);
      cairo_stroke (cr);
      return;
    }

  if (n == 1)
    {
      gdouble w = segment_width (base, pts[0].pressure);
      cairo_arc (cr, pts[0].x, pts[0].y, w * 0.5, 0, 2 * G_PI);
      cairo_fill (cr);
      return;
    }

  for (i = 1; i < n; i++)
    {
      cairo_set_line_width (cr, segment_width (base, pts[i].pressure));
      cairo_move_to (cr, pts[i - 1].x, pts[i - 1].y);
      cairo_line_to (cr, pts[i].x, pts[i].y);
      cairo_stroke (cr);
    }
}

static void
draw_eraser_trail (cairo_t *cr, OrgExInkStroke *s)
{
  guint n = 0, i;
  const OrgExInkPoint *pts = org_ex_ink_stroke_get_points (s, &n);
  if (n == 0) return;

  cairo_set_source_rgba (cr, 1.0, 0.4, 0.55, 0.45);
  cairo_set_line_cap (cr, CAIRO_LINE_CAP_ROUND);
  cairo_set_line_width (cr, 12.0);
  if (n == 1)
    {
      cairo_arc (cr, pts[0].x, pts[0].y, 6.0, 0, 2 * G_PI);
      cairo_fill (cr);
      return;
    }
  cairo_move_to (cr, pts[0].x, pts[0].y);
  for (i = 1; i < n; i++)
    cairo_line_to (cr, pts[i].x, pts[i].y);
  cairo_stroke (cr);
}

static gboolean
on_draw (GtkWidget *widget, cairo_t *cr, gpointer user_data)
{
  CaptureState *state = user_data;
  guint i;

  (void) widget;

  if (state->background_surface != NULL)
    {
      /* Annotation surface — paint the supplied screenshot at origin.
         No fill behind it: we want strokes to land directly on top
         of the source pixels for "drawing on the page" feel. */
      cairo_set_source_surface (cr, state->background_surface, 0, 0);
      cairo_paint (cr);
    }
  else if (state->background_colour != NULL && *state->background_colour)
    {
      /* Solid-colour canvas (e.g. theme-matched bg for #+BEGIN_INK).
         Use parse_hex_colour which already handles #RGB / #RRGGBB
         and named colours (via GdkRGBA). */
      gdouble r, g, b;
      parse_hex_colour (state->background_colour, &r, &g, &b);
      cairo_set_source_rgb (cr, r, g, b);
      cairo_paint (cr);
    }
  else
    {
      /* White "page" background — fallback for callers that don't
         pass either a surface or a colour. */
      cairo_set_source_rgb (cr, 1.0, 1.0, 1.0);
      cairo_paint (cr);
    }

  /* Subtle border so the canvas extent is visible. */
  cairo_set_source_rgba (cr, 0.0, 0.0, 0.0, 0.15);
  cairo_set_line_width (cr, 1.0);
  cairo_rectangle (cr, 0.5, 0.5, state->width - 1, state->height - 1);
  cairo_stroke (cr);

  for (i = 0; i < state->committed_strokes->len; i++)
    {
      OrgExInkStroke *s = g_ptr_array_index (state->committed_strokes, i);
      if (org_ex_ink_stroke_get_tool (s) == ORG_EX_INK_TOOL_ERASER)
        continue;
      draw_pen_stroke (cr, s, FALSE);
    }

  if (state->live_stroke != NULL)
    {
      if (state->live_is_eraser)
        draw_eraser_trail (cr, state->live_stroke);
      else
        draw_pen_stroke (cr, state->live_stroke, TRUE);
    }
  return FALSE;
}

/* ------------------------------------------------------------------ */
/* Event handlers                                                     */
/* ------------------------------------------------------------------ */

static void
state_clear_live (CaptureState *state)
{
  if (state->live_stroke != NULL)
    {
      org_ex_ink_stroke_unref (state->live_stroke);
      state->live_stroke = NULL;
    }
  state->live_is_eraser = FALSE;
  state->live_kind = 0;
}

static gboolean
on_button_press (GtkWidget *w, GdkEventButton *evt, gpointer user_data)
{
  CaptureState *state = user_data;
  GdkEvent *event = (GdkEvent *) evt;
  OrgExInkTool tool;
  gboolean ignored = FALSE;
  gfloat pressure;
  const gchar *colour;
  gfloat base_width;

  (void) w;

  if (evt->button != 1)
    return FALSE;

  tool = classify_event (state, event, &ignored);
  if (ignored)
    return FALSE;

  state_clear_live (state);

  /* Pick colour + width based on the resolved tool: highlighter
     uses its own (default gold/12); pen uses the pen settings;
     eraser is colourless (the colour is only relevant to pen
     strokes anyway). */
  switch (tool)
    {
    case ORG_EX_INK_TOOL_HIGHLIGHTER:
      colour = state->hilite_colour ? state->hilite_colour : "#ffd700";
      base_width = state->hilite_width_remembered;
      break;
    case ORG_EX_INK_TOOL_ERASER:
      colour = state->pen_colour;
      base_width = state->pen_base_width;
      break;
    case ORG_EX_INK_TOOL_PEN:
    default:
      colour = state->pen_colour;
      base_width = state->pen_base_width;
      break;
    }

  pressure = read_pressure (event);
  state->live_is_eraser = (tool == ORG_EX_INK_TOOL_ERASER);
  state->live_kind = (tool == ORG_EX_INK_TOOL_ERASER ? 2 : 1);
  state->live_stroke =
    org_ex_ink_stroke_new (tool, colour, base_width);
  org_ex_ink_stroke_append_point (state->live_stroke,
                                  (gint16) evt->x, (gint16) evt->y,
                                  pressure);
  gtk_widget_queue_draw (state->canvas);
  return TRUE;
}

static gboolean
on_motion (GtkWidget *w, GdkEventMotion *evt, gpointer user_data)
{
  CaptureState *state = user_data;
  GdkEvent *event = (GdkEvent *) evt;
  gfloat pressure;

  (void) w;

  if (state->live_stroke == NULL)
    return FALSE;
  if (!(evt->state & GDK_BUTTON1_MASK))
    return FALSE;

  pressure = read_pressure (event);
  org_ex_ink_stroke_append_point (state->live_stroke,
                                  (gint16) evt->x, (gint16) evt->y,
                                  pressure);
  gtk_widget_queue_draw (state->canvas);
  return TRUE;
}

static gboolean
on_button_release (GtkWidget *w, GdkEventButton *evt, gpointer user_data)
{
  CaptureState *state = user_data;
  (void) w;

  if (evt->button != 1)
    return FALSE;
  if (state->live_stroke == NULL)
    return FALSE;

  if (state->live_is_eraser)
    {
      apply_eraser_to_committed (state, state->live_stroke);
    }
  else
    {
      g_ptr_array_add (state->committed_strokes,
                       org_ex_ink_stroke_ref (state->live_stroke));
    }

  state_clear_live (state);
  gtk_widget_queue_draw (state->canvas);
  return TRUE;
}

/* ------------------------------------------------------------------ */
/* Toolbar actions                                                    */
/* ------------------------------------------------------------------ */

static void
finish_capture (CaptureState *state, gboolean cancelled)
{
  state->cancelled = cancelled;
  if (state->loop != NULL && g_main_loop_is_running (state->loop))
    g_main_loop_quit (state->loop);
}

static void
on_done_clicked (GtkButton *btn, gpointer user_data)
{
  (void) btn;
  finish_capture ((CaptureState *) user_data, FALSE);
}

static void
on_cancel_clicked (GtkButton *btn, gpointer user_data)
{
  (void) btn;
  finish_capture ((CaptureState *) user_data, TRUE);
}

static void
on_clear_clicked (GtkButton *btn, gpointer user_data)
{
  CaptureState *state = user_data;
  (void) btn;
  state_clear_live (state);
  g_ptr_array_set_size (state->committed_strokes, 0);
  gtk_widget_queue_draw (state->canvas);
}

static void
on_undo_clicked (GtkButton *btn, gpointer user_data)
{
  CaptureState *state = user_data;
  (void) btn;
  if (state->committed_strokes->len > 0)
    {
      g_ptr_array_remove_index (state->committed_strokes,
                                state->committed_strokes->len - 1);
      gtk_widget_queue_draw (state->canvas);
    }
}

static gboolean
on_key_press (GtkWidget *w, GdkEventKey *evt, gpointer user_data)
{
  CaptureState *state = user_data;
  (void) w;

  switch (evt->keyval)
    {
    case GDK_KEY_Escape:
      finish_capture (state, TRUE);
      return TRUE;
    case GDK_KEY_Return:
    case GDK_KEY_KP_Enter:
      if (evt->state & GDK_CONTROL_MASK)
        {
          finish_capture (state, FALSE);
          return TRUE;
        }
      break;
    case GDK_KEY_z:
      if (evt->state & GDK_CONTROL_MASK)
        {
          on_undo_clicked (NULL, state);
          return TRUE;
        }
      break;
    default:
      break;
    }
  return FALSE;
}

static gboolean
on_window_delete (GtkWidget *w, GdkEvent *evt, gpointer user_data)
{
  (void) w; (void) evt;
  finish_capture ((CaptureState *) user_data, TRUE);
  return TRUE; /* don't destroy yet — main path will */
}

/* ------------------------------------------------------------------ */
/* Palette callbacks                                                   */
/* ------------------------------------------------------------------ */

/* When the user toggles a tool button, update state.current_tool
   AND swap the spin button + colour button to that tool's
   remembered settings.  Setting the widget values fires their
   "value-changed"/"color-set" signals which we ignore via a
   recursion guard (a sub-zero spin value), but a simpler approach
   is to block the relevant signal handlers for the duration of
   the swap.  GTK provides g_signal_handlers_block_by_func for
   this — we use it on_colour_set / on_width_changed callbacks. */

static void on_colour_set   (GtkColorButton *btn, gpointer ud);
static void on_width_changed (GtkSpinButton  *btn, gpointer ud);
static void on_bg_set       (GtkColorButton *btn, gpointer ud);

static void
sync_palette_widgets_to_tool (CaptureState *state)
{
  /* Block the 'changed' signals so the in-place updates of the
     spin button + colour button don't fire their callbacks (which
     would update state and cause feedback loops). */
  g_signal_handlers_block_by_func (state->btn_colour,
                                   (gpointer) on_colour_set, state);
  g_signal_handlers_block_by_func (state->spin_width,
                                   (gpointer) on_width_changed, state);

  switch (state->current_tool)
    {
    case ORG_EX_INK_TOOL_HIGHLIGHTER:
      {
        GdkRGBA c;
        if (gdk_rgba_parse (
              &c, state->hilite_colour ? state->hilite_colour : "#ffd700"))
          gtk_color_chooser_set_rgba (
            GTK_COLOR_CHOOSER (state->btn_colour), &c);
        gtk_spin_button_set_value (
          GTK_SPIN_BUTTON (state->spin_width),
          state->hilite_width_remembered);
        break;
      }
    case ORG_EX_INK_TOOL_ERASER:
    case ORG_EX_INK_TOOL_PEN:
    default:
      {
        GdkRGBA c;
        if (gdk_rgba_parse (
              &c, state->pen_colour ? state->pen_colour : "#222222"))
          gtk_color_chooser_set_rgba (
            GTK_COLOR_CHOOSER (state->btn_colour), &c);
        gtk_spin_button_set_value (
          GTK_SPIN_BUTTON (state->spin_width),
          state->pen_base_width);
        break;
      }
    }

  g_signal_handlers_unblock_by_func (state->btn_colour,
                                     (gpointer) on_colour_set, state);
  g_signal_handlers_unblock_by_func (state->spin_width,
                                     (gpointer) on_width_changed, state);
}

static void
on_tool_toggled (GtkToggleButton *btn, gpointer user_data)
{
  CaptureState *state = user_data;
  if (!gtk_toggle_button_get_active (btn))
    return;  /* radio behaviour: only act on the new selection */

  /* Block our own callback while we deactivate the other two
     toggles — otherwise their state-change fires us recursively. */
  g_signal_handlers_block_by_func (state->btn_pen,
                                   (gpointer) on_tool_toggled, state);
  g_signal_handlers_block_by_func (state->btn_hilite,
                                   (gpointer) on_tool_toggled, state);
  g_signal_handlers_block_by_func (state->btn_eraser,
                                   (gpointer) on_tool_toggled, state);

  if      ((GtkWidget *) btn == state->btn_pen)
    {
      state->current_tool = ORG_EX_INK_TOOL_PEN;
      gtk_toggle_button_set_active (
        GTK_TOGGLE_BUTTON (state->btn_hilite), FALSE);
      gtk_toggle_button_set_active (
        GTK_TOGGLE_BUTTON (state->btn_eraser), FALSE);
    }
  else if ((GtkWidget *) btn == state->btn_hilite)
    {
      state->current_tool = ORG_EX_INK_TOOL_HIGHLIGHTER;
      gtk_toggle_button_set_active (
        GTK_TOGGLE_BUTTON (state->btn_pen),    FALSE);
      gtk_toggle_button_set_active (
        GTK_TOGGLE_BUTTON (state->btn_eraser), FALSE);
    }
  else if ((GtkWidget *) btn == state->btn_eraser)
    {
      state->current_tool = ORG_EX_INK_TOOL_ERASER;
      gtk_toggle_button_set_active (
        GTK_TOGGLE_BUTTON (state->btn_pen),    FALSE);
      gtk_toggle_button_set_active (
        GTK_TOGGLE_BUTTON (state->btn_hilite), FALSE);
    }

  g_signal_handlers_unblock_by_func (state->btn_pen,
                                     (gpointer) on_tool_toggled, state);
  g_signal_handlers_unblock_by_func (state->btn_hilite,
                                     (gpointer) on_tool_toggled, state);
  g_signal_handlers_unblock_by_func (state->btn_eraser,
                                     (gpointer) on_tool_toggled, state);

  sync_palette_widgets_to_tool (state);
}

static void
on_colour_set (GtkColorButton *btn, gpointer user_data)
{
  CaptureState *state = user_data;
  GdkRGBA c;
  gchar *hex;
  gtk_color_chooser_get_rgba (GTK_COLOR_CHOOSER (btn), &c);
  hex = g_strdup_printf ("#%02x%02x%02x",
                        CMACS_INK_RGBA_BYTE (c.red),
                        CMACS_INK_RGBA_BYTE (c.green),
                        CMACS_INK_RGBA_BYTE (c.blue));
  /* Update whichever tool's colour slot is current.  Eraser
     doesn't have a colour; we still record into pen_colour so
     the user's choice persists when they switch back to pen. */
  switch (state->current_tool)
    {
    case ORG_EX_INK_TOOL_HIGHLIGHTER:
      g_free (state->hilite_colour);
      state->hilite_colour = hex;
      break;
    default:
      g_free (state->pen_colour);
      state->pen_colour = hex;
      break;
    }
}

static void
on_width_changed (GtkSpinButton *btn, gpointer user_data)
{
  CaptureState *state = user_data;
  gdouble v = gtk_spin_button_get_value (btn);
  switch (state->current_tool)
    {
    case ORG_EX_INK_TOOL_HIGHLIGHTER:
      state->hilite_width_remembered = (gfloat) v;
      break;
    default:
      state->pen_base_width = (gfloat) v;
      state->pen_width_remembered = (gfloat) v;
      break;
    }
}

static void
on_bg_set (GtkColorButton *btn, gpointer user_data)
{
  CaptureState *state = user_data;
  GdkRGBA c;
  gtk_color_chooser_get_rgba (GTK_COLOR_CHOOSER (btn), &c);
  g_free (state->background_colour);
  state->background_colour =
    g_strdup_printf ("#%02x%02x%02x",
                     CMACS_INK_RGBA_BYTE (c.red),
                     CMACS_INK_RGBA_BYTE (c.green),
                     CMACS_INK_RGBA_BYTE (c.blue));
  gtk_widget_queue_draw (state->canvas);
}

/* ------------------------------------------------------------------ */
/* Public entry                                                       */
/* ------------------------------------------------------------------ */

GPtrArray *
cmacs_org_ex_ink_capture (GPtrArray   *initial,
                          gint         width,
                          gint         height,
                          const gchar *colour,
                          gfloat       base_width,
                          gboolean     side_button_erases,
                          gboolean    *cancelled)
{
  return cmacs_org_ex_ink_capture_full (
    NULL, NULL, initial, width, height, colour, base_width,
    NULL, 0.0f, 0 /* pen */, side_button_erases, cancelled);
}

GPtrArray *
cmacs_org_ex_ink_capture_with_background (
                          cairo_surface_t *background_surface,
                          GPtrArray       *initial,
                          gint             width,
                          gint             height,
                          const gchar     *colour,
                          gfloat           base_width,
                          gboolean         side_button_erases,
                          gboolean        *cancelled)
{
  return cmacs_org_ex_ink_capture_full (
    background_surface, NULL, initial, width, height,
    colour, base_width,
    NULL, 0.0f, 0 /* pen */, side_button_erases, cancelled);
}

GPtrArray *
cmacs_org_ex_ink_capture_full (
                          cairo_surface_t *background_surface,
                          const gchar     *background_colour,
                          GPtrArray       *initial,
                          gint             width,
                          gint             height,
                          const gchar     *colour,
                          gfloat           base_width,
                          const gchar     *hilite_colour,
                          gfloat           hilite_base_width,
                          gint             default_tool,
                          gboolean         side_button_erases,
                          gboolean        *cancelled)
{
  CaptureState state = { 0 };
  GtkWidget *vbox, *toolbar, *btn_done, *btn_cancel, *btn_clear, *btn_undo;
  GtkWidget *lbl_colour, *lbl_width, *lbl_bg;
  GPtrArray *result;

  if (width  <= 0) width  = 800;
  if (height <= 0) height = 400;

  state.width  = width;
  state.height = height;
  state.pen_colour     = g_strdup (colour && *colour ? colour : "#222");
  state.pen_base_width = base_width > 0.0f ? base_width : 2.0f;
  state.pen_width_remembered = state.pen_base_width;
  state.hilite_colour = g_strdup (
    hilite_colour && *hilite_colour ? hilite_colour : "#ffd700");
  state.hilite_width_remembered =
    hilite_base_width > 0.0f ? hilite_base_width : 12.0f;
  state.side_button_erases = side_button_erases;
  state.background_surface = background_surface;  /* borrowed; not owned */
  state.background_colour =
    (background_colour && *background_colour && background_surface == NULL)
    ? g_strdup (background_colour) : NULL;
  switch (default_tool)
    {
    case 1: state.current_tool = ORG_EX_INK_TOOL_HIGHLIGHTER; break;
    case 2: state.current_tool = ORG_EX_INK_TOOL_ERASER; break;
    default: state.current_tool = ORG_EX_INK_TOOL_PEN; break;
    }
  state.cancelled = TRUE; /* default to cancelled until commit */

  state.committed_strokes = org_ex_ink_strokes_new ();
  if (initial != NULL)
    {
      guint i;
      for (i = 0; i < initial->len; i++)
        {
          OrgExInkStroke *s = g_ptr_array_index (initial, i);
          if (s != NULL)
            g_ptr_array_add (state.committed_strokes,
                             org_ex_ink_stroke_ref (s));
        }
    }

  /* Window.
     On Wayland a "modal" window without a transient parent often
     fails to surface or layers behind everything.  We try to find
     an Emacs GTK toplevel to act as parent; failing that we drop
     the modal flag entirely so the window at least appears and the
     user can switch focus back to Emacs to commit/cancel. */
  state.window = gtk_window_new (GTK_WINDOW_TOPLEVEL);
  gtk_window_set_title (GTK_WINDOW (state.window), "cmacs-ink");
  gtk_window_set_default_size (GTK_WINDOW (state.window),
                               width + 20, height + 80);
  {
    GList *toplevels = gtk_window_list_toplevels ();
    GList *l;
    GtkWindow *parent = NULL;
    for (l = toplevels; l != NULL; l = l->next)
      {
        GtkWidget *tl = l->data;
        if (tl != state.window
            && GTK_IS_WINDOW (tl)
            && gtk_widget_get_visible (tl)
            && gtk_widget_get_mapped (tl))
          {
            parent = GTK_WINDOW (tl);
            break;
          }
      }
    g_list_free (toplevels);
    if (parent != NULL)
      {
        gtk_window_set_transient_for (GTK_WINDOW (state.window), parent);
        gtk_window_set_modal          (GTK_WINDOW (state.window), TRUE);
        gtk_window_set_destroy_with_parent (GTK_WINDOW (state.window),
                                            TRUE);
      }
    else
      {
        /* No parent → don't set modal.  Keep the window above so it
           lands in front on compositors that allow it. */
        gtk_window_set_keep_above (GTK_WINDOW (state.window), TRUE);
      }
  }
  gtk_window_set_position (GTK_WINDOW (state.window),
                           GTK_WIN_POS_CENTER);
  g_signal_connect (state.window, "delete-event",
                    G_CALLBACK (on_window_delete), &state);
  g_signal_connect (state.window, "key-press-event",
                    G_CALLBACK (on_key_press), &state);

  vbox = gtk_box_new (GTK_ORIENTATION_VERTICAL, 4);
  gtk_container_add (GTK_CONTAINER (state.window), vbox);

  /* Toolbar */
  toolbar = gtk_box_new (GTK_ORIENTATION_HORIZONTAL, 4);
  gtk_box_pack_start (GTK_BOX (vbox), toolbar, FALSE, FALSE, 4);

  btn_done   = gtk_button_new_with_label ("Commit (C-Return)");
  btn_cancel = gtk_button_new_with_label ("Cancel (Esc)");
  btn_clear  = gtk_button_new_with_label ("Clear");
  btn_undo   = gtk_button_new_with_label ("Undo (C-z)");
  gtk_box_pack_start (GTK_BOX (toolbar), btn_done,   FALSE, FALSE, 4);
  gtk_box_pack_start (GTK_BOX (toolbar), btn_undo,   FALSE, FALSE, 4);
  gtk_box_pack_start (GTK_BOX (toolbar), btn_clear,  FALSE, FALSE, 4);
  gtk_box_pack_end   (GTK_BOX (toolbar), btn_cancel, FALSE, FALSE, 4);
  g_signal_connect (btn_done,   "clicked",
                    G_CALLBACK (on_done_clicked),   &state);
  g_signal_connect (btn_cancel, "clicked",
                    G_CALLBACK (on_cancel_clicked), &state);
  g_signal_connect (btn_clear,  "clicked",
                    G_CALLBACK (on_clear_clicked),  &state);
  g_signal_connect (btn_undo,   "clicked",
                    G_CALLBACK (on_undo_clicked),   &state);

  /* --- Palette: tool selector + colour + width + (optional) bg ---
     These live in a SECOND row of the toolbar to keep the commit
     buttons visually distinct from the per-stroke controls. */
  {
    GtkWidget *palette = gtk_box_new (GTK_ORIENTATION_HORIZONTAL, 6);
    gtk_box_pack_start (GTK_BOX (vbox), palette, FALSE, FALSE, 4);

    /* Three radio-style toggles: only one is "active" at a time.
       GtkRadioButton would behave the same but draws as actual
       radio buttons; for a toolbar we want toggle-button styling
       with a manual radio implementation in `on_tool_toggled'. */
    state.btn_pen    = gtk_toggle_button_new_with_label ("Pen");
    state.btn_hilite = gtk_toggle_button_new_with_label ("Hilite");
    state.btn_eraser = gtk_toggle_button_new_with_label ("Eraser");
    gtk_box_pack_start (GTK_BOX (palette), state.btn_pen,    FALSE, FALSE, 0);
    gtk_box_pack_start (GTK_BOX (palette), state.btn_hilite, FALSE, FALSE, 0);
    gtk_box_pack_start (GTK_BOX (palette), state.btn_eraser, FALSE, FALSE, 0);
    /* Initialise the active toggle from the seeded current_tool. */
    gtk_toggle_button_set_active (
      GTK_TOGGLE_BUTTON (state.btn_pen),
      state.current_tool == ORG_EX_INK_TOOL_PEN);
    gtk_toggle_button_set_active (
      GTK_TOGGLE_BUTTON (state.btn_hilite),
      state.current_tool == ORG_EX_INK_TOOL_HIGHLIGHTER);
    gtk_toggle_button_set_active (
      GTK_TOGGLE_BUTTON (state.btn_eraser),
      state.current_tool == ORG_EX_INK_TOOL_ERASER);

    /* Manual radio: when one toggle is turned on, deactivate the
       other two.  GtkToggleButton's "toggled" signal fires for
       both turn-on and turn-off; on_tool_toggled returns early
       when the button is now inactive. */
    g_signal_connect (state.btn_pen,    "toggled",
                      G_CALLBACK (on_tool_toggled), &state);
    g_signal_connect (state.btn_hilite, "toggled",
                      G_CALLBACK (on_tool_toggled), &state);
    g_signal_connect (state.btn_eraser, "toggled",
                      G_CALLBACK (on_tool_toggled), &state);

    /* Colour picker — affects the next stroke (per-tool colour
       slot; see on_colour_set). */
    lbl_colour = gtk_label_new ("Colour:");
    gtk_box_pack_start (GTK_BOX (palette), lbl_colour, FALSE, FALSE, 8);
    state.btn_colour = gtk_color_button_new ();
    gtk_color_button_set_use_alpha (
      GTK_COLOR_BUTTON (state.btn_colour), FALSE);
    {
      GdkRGBA c;
      if (gdk_rgba_parse (
            &c, state.current_tool == ORG_EX_INK_TOOL_HIGHLIGHTER
                ? state.hilite_colour : state.pen_colour))
        gtk_color_chooser_set_rgba (
          GTK_COLOR_CHOOSER (state.btn_colour), &c);
    }
    gtk_box_pack_start (GTK_BOX (palette), state.btn_colour,
                        FALSE, FALSE, 0);
    g_signal_connect (state.btn_colour, "color-set",
                      G_CALLBACK (on_colour_set), &state);

    /* Width spin button — 0.5..20 in 0.5 increments.  Like
       colour, this is per-tool and reflects the current tool
       when the user toggles. */
    lbl_width = gtk_label_new ("Width:");
    gtk_box_pack_start (GTK_BOX (palette), lbl_width, FALSE, FALSE, 8);
    state.spin_width = gtk_spin_button_new_with_range (0.5, 20.0, 0.5);
    gtk_spin_button_set_digits (GTK_SPIN_BUTTON (state.spin_width), 1);
    gtk_spin_button_set_value (
      GTK_SPIN_BUTTON (state.spin_width),
      state.current_tool == ORG_EX_INK_TOOL_HIGHLIGHTER
        ? state.hilite_width_remembered : state.pen_base_width);
    gtk_box_pack_start (GTK_BOX (palette), state.spin_width,
                        FALSE, FALSE, 0);
    g_signal_connect (state.spin_width, "value-changed",
                      G_CALLBACK (on_width_changed), &state);

    /* Background colour — only meaningful in canvas mode (no
       screenshot).  In region-overlay mode the screenshot IS the
       bg; users editing one shouldn't see this knob. */
    if (state.background_surface == NULL)
      {
        lbl_bg = gtk_label_new ("Bg:");
        gtk_box_pack_start (GTK_BOX (palette), lbl_bg, FALSE, FALSE, 8);
        state.btn_bg = gtk_color_button_new ();
        gtk_color_button_set_use_alpha (
          GTK_COLOR_BUTTON (state.btn_bg), FALSE);
        if (state.background_colour != NULL)
          {
            GdkRGBA c;
            if (gdk_rgba_parse (&c, state.background_colour))
              gtk_color_chooser_set_rgba (
                GTK_COLOR_CHOOSER (state.btn_bg), &c);
          }
        gtk_box_pack_start (GTK_BOX (palette), state.btn_bg,
                            FALSE, FALSE, 0);
        g_signal_connect (state.btn_bg, "color-set",
                          G_CALLBACK (on_bg_set), &state);
      }
  }

  /* Canvas */
  state.canvas = gtk_drawing_area_new ();
  gtk_widget_set_size_request (state.canvas, width, height);
  gtk_widget_set_can_focus (state.canvas, TRUE);
  gtk_widget_add_events (state.canvas,
                         GDK_BUTTON_PRESS_MASK
                         | GDK_BUTTON_RELEASE_MASK
                         | GDK_POINTER_MOTION_MASK
                         | GDK_PROXIMITY_IN_MASK
                         | GDK_PROXIMITY_OUT_MASK
                         | GDK_KEY_PRESS_MASK
                         | GDK_TOUCH_MASK);
  g_signal_connect (state.canvas, "draw",
                    G_CALLBACK (on_draw), &state);
  g_signal_connect (state.canvas, "button-press-event",
                    G_CALLBACK (on_button_press), &state);
  g_signal_connect (state.canvas, "button-release-event",
                    G_CALLBACK (on_button_release), &state);
  g_signal_connect (state.canvas, "motion-notify-event",
                    G_CALLBACK (on_motion), &state);
  gtk_box_pack_start (GTK_BOX (vbox), state.canvas, TRUE, TRUE, 0);

  gtk_widget_show_all (state.window);
  gtk_window_present (GTK_WINDOW (state.window));
  gtk_widget_grab_focus (state.canvas);

  /* Pump the main loop a few times to ensure GTK has actually mapped
     and presented the surface before we go into the nested loop —
     otherwise some compositors (sway/gowl) won't paint until they
     see the next round-trip. */
  {
    int i;
    for (i = 0; i < 10 && gtk_events_pending (); i++)
      gtk_main_iteration_do (FALSE);
  }

  /* Block Emacs's atimer SIGALRM channel for the duration of the
     nested loop.  Without this, a SIGALRM firing while we're inside
     `g_main_loop_run' triggers `run_timers' from a GObject signal
     marshaller — and on Wayland with a Wacom tablet attached that
     reaches `pgtk_show_hourglass' → `gtk_fixed_put' →
     `gdk_window_new' → `gdk_window_set_cursor' while a tablet
     device-add event is mid-dispatch, asserting on a display
     mismatch and aborting (Gdk:ERROR ../gdk/gdkwindow.c:6529).
     Diagnosed via core-dump analysis 2026-04-26.  We also block
     SIGIO for symmetry with `block_atimers' in atimer.c. */
  {
    sigset_t blocked, oldset;
    sigemptyset (&blocked);
    sigaddset (&blocked, SIGALRM);
#ifdef SIGIO
    sigaddset (&blocked, SIGIO);
#endif
    pthread_sigmask (SIG_BLOCK, &blocked, &oldset);

    /* Nested main loop — keeps the default GMainContext spinning so
       cmacs_glib_dispatch keeps working for other GLib sources. */
    state.loop = g_main_loop_new (NULL, FALSE);
    g_main_loop_run (state.loop);
    g_main_loop_unref (state.loop);
    state.loop = NULL;

    pthread_sigmask (SIG_SETMASK, &oldset, NULL);
  }

  /* Tear down the window first so its event handlers can't run on
     freed state. */
  gtk_widget_destroy (state.window);
  state.window = NULL;
  state.canvas = NULL;
  state_clear_live (&state);

  if (cancelled != NULL)
    *cancelled = state.cancelled;

  if (state.cancelled)
    {
      g_ptr_array_unref (state.committed_strokes);
      result = NULL;
    }
  else
    {
      result = state.committed_strokes;
      state.committed_strokes = NULL;
    }

  g_free (state.pen_colour);
  g_free (state.hilite_colour);
  g_free (state.background_colour);
  return result;
}

#endif /* HAVE_CMACS_ORG_EX */
