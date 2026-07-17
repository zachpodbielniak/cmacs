/* cmacs-calculator-defuns.c --- calculator DEFUNs

Copyright (C) 2026 Zach Podbielniak

SPDX-License-Identifier: AGPL-3.0-or-later

This file is part of CMacs.  */

/* The Lisp boundary of the calculator's C half.
 *
 * The calculator engine itself is Elisp (it wraps GNU Calc); the only thing
 * that must be C is GPU chart rendering, which needs libregnum.  So this file
 * is small: it binds a buffer to a libregnum view, hands the view's render
 * context an LrgChart built by cmacs-calculator-chart.c, and asks for a
 * redraw.
 *
 * This TU includes lisp.h and the plain-C bridge headers ONLY (never
 * <libregnum.h>), so raylib's `Color' typedef cannot collide with cmacs
 * internals.  See cmacs-calculator-chart.h.
 *
 * Nothing here is backend-specific.  Attaching a CmacsLibregnumView is all it
 * takes to render under both pgtk (cairo blit of the FBO readback) and
 * `emacs --lrg' (direct GL blit of the FBO texture) -- cmacs/libregnum/ owns
 * that difference, and the chart_mode branch it dispatches to handles the
 * DST==NULL case the lrg path uses.  */

#include <config.h>

#ifdef HAVE_CMACS_CALCULATOR

#include "lisp.h"
#include "buffer.h"

#ifdef HAVE_CMACS_CALCULATOR_CHART
#include "cmacs-calculator-chart.h"
#include "cmacs-libregnum.h"
#include "cmacs-libregnum-render.h"
#endif

#include "cmacs-calculator.h"

/* Qcmacs_calculator_error is DEFSYM'd in syms_of_cmacs_calculator_defuns
   below; make-docfile generates its global slot, so it must NOT be declared
   as a file-local variable.  */

#ifdef HAVE_CMACS_CALCULATOR_CHART

/* Default chart view size, used when the caller does not say.  */
#define CALC_CHART_DEFAULT_W 640
#define CALC_CHART_DEFAULT_H 400

/* Return BUFFER's libregnum view, or signal if it has none.  */
static CmacsLibregnumView *
calc_chart_view (Lisp_Object buffer)
{
  CmacsLibregnumView *v = cmacs_libregnum_view_for_buffer (buffer);

  if (v == NULL)
    xsignal1 (Qcmacs_calculator_error,
              build_string ("buffer has no chart view; call"
                            " cmacs-calculator-chart-attach first"));
  return v;
}

/* Return the LrgChart bound to BUFFER's view, or signal.  */
static void *
calc_chart_widget (Lisp_Object buffer)
{
  CmacsLibregnumView *v = calc_chart_view (buffer);
  CmacsLibregnumRenderCtx *ctx = cmacs_libregnum_view_get_render_ctx (v);
  void *chart = ctx ? cmacs_libregnum_render_ctx_chart_get_widget (ctx) : NULL;

  if (chart == NULL)
    xsignal1 (Qcmacs_calculator_error,
              build_string ("buffer has no chart; call"
                            " cmacs-calculator-chart-set-type first"));
  return chart;
}

DEFUN ("cmacs-calculator-chart-supported-p",
       Fcmacs_calculator_chart_supported_p,
       Scmacs_calculator_chart_supported_p, 0, 0, 0,
       doc: /* Return t when GPU charting is built into this cmacs.
Compile-time only, like `cmacs-libregnum-supported-p': a usable GL
display is a separate question, discovered when
`cmacs-calculator-chart-attach' runs and signalled there if absent.  The
Elisp SVG chart tier needs neither and is always available.  */)
  (void)
{
  return Qt;
}

DEFUN ("cmacs-calculator-chart-attach", Fcmacs_calculator_chart_attach,
       Scmacs_calculator_chart_attach, 1, 3, 0,
       doc: /* Give BUFFER a chart view, WIDTH by HEIGHT pixels.
Reuses BUFFER's existing view when it already has one.  WIDTH and HEIGHT
default to 640x400.  Returns t.

The view renders under both pgtk and `emacs --lrg'.  */)
  (Lisp_Object buffer, Lisp_Object width, Lisp_Object height)
{
  CmacsLibregnumView *v;
  CmacsLibregnumRenderCtx *ctx;
  int w = NILP (width) ? CALC_CHART_DEFAULT_W : (int) XFIXNUM (width);
  int h = NILP (height) ? CALC_CHART_DEFAULT_H : (int) XFIXNUM (height);

  CHECK_BUFFER (buffer);
  if (!NILP (width)) CHECK_FIXNUM (width);
  if (!NILP (height)) CHECK_FIXNUM (height);
  if (w <= 0 || h <= 0)
    xsignal2 (Qcmacs_calculator_error,
              build_string ("chart size must be positive"),
              list2 (make_fixnum (w), make_fixnum (h)));

  v = cmacs_libregnum_view_for_buffer (buffer);
  if (v == NULL)
    v = cmacs_libregnum_view_new (buffer, w, h);
  if (v == NULL)
    xsignal1 (Qcmacs_calculator_error,
              build_string ("cannot create a chart view:"
                            " no GL display available"));

  ctx = cmacs_libregnum_view_get_render_ctx (v);
  if (ctx == NULL)
    xsignal1 (Qcmacs_calculator_error,
              build_string ("chart view has no render context"));
  /* Switch the view out of the 3D scene pass and into the 2D chart pass. */
  cmacs_libregnum_render_ctx_chart_enter (ctx, true);
  return Qt;
}

DEFUN ("cmacs-calculator-chart-detach", Fcmacs_calculator_chart_detach,
       Scmacs_calculator_chart_detach, 1, 1, 0,
       doc: /* Drop BUFFER's chart view and free its resources.
Returns t if BUFFER had a view, nil otherwise.  */)
  (Lisp_Object buffer)
{
  CmacsLibregnumView *v;

  CHECK_BUFFER (buffer);
  v = cmacs_libregnum_view_for_buffer (buffer);
  if (v == NULL)
    return Qnil;
  cmacs_libregnum_view_destroy (v);
  return Qt;
}

DEFUN ("cmacs-calculator-chart-set-type", Fcmacs_calculator_chart_set_type,
       Scmacs_calculator_chart_set_type, 2, 2, 0,
       doc: /* Make BUFFER's chart be of TYPE, discarding any previous chart.
TYPE is a symbol: `line', `bar', `area', `scatter', `pie', `candlestick',
`histogram', `radar', `gauge' or `heatmap'.  Returns t.

See `cmacs-calculator-chart-types' for the list this build supports.  */)
  (Lisp_Object buffer, Lisp_Object type)
{
  CmacsLibregnumView *v;
  CmacsLibregnumRenderCtx *ctx;
  CmacsCalcChartKind kind;
  void *chart;

  CHECK_BUFFER (buffer);
  CHECK_SYMBOL (type);

  kind = cmacs_calculator_chart_kind_from_name (SSDATA (SYMBOL_NAME (type)));
  if (kind == CMACS_CALC_CHART_INVALID)
    xsignal2 (Qcmacs_calculator_error,
              build_string ("unknown chart type"), type);

  v = calc_chart_view (buffer);
  ctx = cmacs_libregnum_view_get_render_ctx (v);
  if (ctx == NULL)
    xsignal1 (Qcmacs_calculator_error,
              build_string ("chart view has no render context"));

  chart = cmacs_calculator_chart_new (kind);
  if (chart == NULL)
    xsignal2 (Qcmacs_calculator_error,
              build_string ("cannot create chart of type"), type);

  /* The ctx takes its own ref; drop ours so the chart is owned solely by the
     view and dies with it.  */
  cmacs_libregnum_render_ctx_chart_set_widget (ctx, chart);
  cmacs_calculator_chart_unref (chart);
  return Qt;
}

DEFUN ("cmacs-calculator-chart-types", Fcmacs_calculator_chart_types,
       Scmacs_calculator_chart_types, 0, 0, 0,
       doc: /* Return the list of chart type symbols this build supports.  */)
  (void)
{
  const char *const *names = cmacs_calculator_chart_kind_names ();
  Lisp_Object out = Qnil;
  int i;

  for (i = 0; names[i] != NULL; i++)
    out = Fcons (intern (names[i]), out);
  return Fnreverse (out);
}

DEFUN ("cmacs-calculator-chart-set-title", Fcmacs_calculator_chart_set_title,
       Scmacs_calculator_chart_set_title, 2, 2, 0,
       doc: /* Set the title of BUFFER's chart to TITLE.
TITLE may be nil to clear it.  Returns t.  */)
  (Lisp_Object buffer, Lisp_Object title)
{
  void *chart;

  CHECK_BUFFER (buffer);
  if (!NILP (title)) CHECK_STRING (title);

  chart = calc_chart_widget (buffer);
  cmacs_calculator_chart_set_title (chart,
                                    NILP (title) ? NULL : SSDATA (title));
  return Qt;
}

DEFUN ("cmacs-calculator-chart-set-background",
       Fcmacs_calculator_chart_set_background,
       Scmacs_calculator_chart_set_background, 4, 5, 0,
       doc: /* Set the background of BUFFER's chart to RED GREEN BLUE, ALPHA.
Each component is 0-255; ALPHA defaults to 255.  Returns t.  */)
  (Lisp_Object buffer, Lisp_Object red, Lisp_Object green, Lisp_Object blue,
   Lisp_Object alpha)
{
  CmacsLibregnumView *v;
  CmacsLibregnumRenderCtx *ctx;

  CHECK_BUFFER (buffer);
  CHECK_FIXNUM (red);
  CHECK_FIXNUM (green);
  CHECK_FIXNUM (blue);
  if (!NILP (alpha)) CHECK_FIXNUM (alpha);

  v = calc_chart_view (buffer);
  ctx = cmacs_libregnum_view_get_render_ctx (v);
  if (ctx == NULL)
    xsignal1 (Qcmacs_calculator_error,
              build_string ("chart view has no render context"));

  cmacs_libregnum_render_ctx_chart_set_background
    (ctx,
     (unsigned char) (XFIXNUM (red) & 0xff),
     (unsigned char) (XFIXNUM (green) & 0xff),
     (unsigned char) (XFIXNUM (blue) & 0xff),
     (unsigned char) (NILP (alpha) ? 255 : (XFIXNUM (alpha) & 0xff)));
  return Qt;
}

DEFUN ("cmacs-calculator-chart-clear-series",
       Fcmacs_calculator_chart_clear_series,
       Scmacs_calculator_chart_clear_series, 1, 1, 0,
       doc: /* Remove every data series from BUFFER's chart.  Returns t.  */)
  (Lisp_Object buffer)
{
  CHECK_BUFFER (buffer);
  cmacs_calculator_chart_clear_series (calc_chart_widget (buffer));
  return Qt;
}

DEFUN ("cmacs-calculator-chart-add-series", Fcmacs_calculator_chart_add_series,
       Scmacs_calculator_chart_add_series, 4, 4, 0,
       doc: /* Add a series to BUFFER's chart.
NAME is the legend label.  COLOR is a "#rrggbb" string.  POINTS is a list
of (X . Y) number conses.  Returns t.  */)
  (Lisp_Object buffer, Lisp_Object name, Lisp_Object color, Lisp_Object points)
{
  void *chart;
  double *xs, *ys;
  ptrdiff_t n, i;
  Lisp_Object tail;
  int cr = 0x3b, cg = 0x6f, cb = 0xb0;
  bool ok;

  CHECK_BUFFER (buffer);
  CHECK_STRING (name);
  CHECK_LIST (points);

  /* "#rrggbb" -> components.  Anything else keeps the default blue rather
     than failing: a bad colour should not lose the data.  */
  if (STRINGP (color) && SBYTES (color) == 7 && SREF (color, 0) == '#')
    {
      char *s = SSDATA (color);
      char *end = NULL;
      long v = strtol (s + 1, &end, 16);
      if (end == s + 7)
        {
          cr = (int) ((v >> 16) & 0xff);
          cg = (int) ((v >> 8) & 0xff);
          cb = (int) (v & 0xff);
        }
    }

  n = list_length (points);
  if (n <= 0)
    xsignal1 (Qcmacs_calculator_error,
              build_string ("series has no points"));

  chart = calc_chart_widget (buffer);

  /* Plain malloc'd scratch, freed before returning: no Lisp_Object is stored
     in it, so there is nothing for GC to trace.  */
  xs = xnmalloc (n, sizeof *xs);
  ys = xnmalloc (n, sizeof *ys);

  i = 0;
  for (tail = points; CONSP (tail); tail = XCDR (tail))
    {
      Lisp_Object pt = XCAR (tail);

      if (!CONSP (pt) || !NUMBERP (XCAR (pt)) || !NUMBERP (XCDR (pt)))
        {
          xfree (xs);
          xfree (ys);
          xsignal2 (Qcmacs_calculator_error,
                    build_string ("chart point must be (NUMBER . NUMBER)"), pt);
        }
      xs[i] = XFLOATINT (XCAR (pt));
      ys[i] = XFLOATINT (XCDR (pt));
      i++;
    }

  ok = cmacs_calculator_chart_add_series (chart, SSDATA (name),
                                          (unsigned char) cr,
                                          (unsigned char) cg,
                                          (unsigned char) cb,
                                          xs, ys, (size_t) i);
  xfree (xs);
  xfree (ys);

  if (!ok)
    xsignal1 (Qcmacs_calculator_error, build_string ("cannot add chart series"));
  return Qt;
}

DEFUN ("cmacs-calculator-chart-refresh", Fcmacs_calculator_chart_refresh,
       Scmacs_calculator_chart_refresh, 1, 1, 0,
       doc: /* Redraw BUFFER's chart.  Returns t.

Only requests a redraw: the GPU work happens at frame top, inside the
render bracket, so this is safe to call from any Lisp code.  */)
  (Lisp_Object buffer)
{
  CHECK_BUFFER (buffer);
  cmacs_libregnum_view_request_redraw (calc_chart_view (buffer));
  return Qt;
}

DEFUN ("cmacs-calculator-chart-snapshot", Fcmacs_calculator_chart_snapshot,
       Scmacs_calculator_chart_snapshot, 2, 2, 0,
       doc: /* Render BUFFER's chart to PATH as a PNG.
Synchronous -- it renders and reads back immediately, independent of the
animation clock -- so it works for automated render verification.
Returns t on success.  */)
  (Lisp_Object buffer, Lisp_Object path)
{
  CmacsLibregnumView *v;
  CmacsLibregnumRenderCtx *ctx;

  CHECK_BUFFER (buffer);
  CHECK_STRING (path);

  v = calc_chart_view (buffer);
  ctx = cmacs_libregnum_view_get_render_ctx (v);
  if (ctx == NULL)
    xsignal1 (Qcmacs_calculator_error,
              build_string ("chart view has no render context"));

  {
    char *msg = NULL;

    if (!cmacs_libregnum_render_ctx_snapshot_png (ctx, SSDATA (path), &msg))
      {
        /* Copy the reason into a Lisp string before freeing it, so the
           signal carries what actually went wrong.  */
        Lisp_Object reason
          = build_string (msg ? msg : "cannot write chart snapshot");
        g_free (msg);
        xsignal2 (Qcmacs_calculator_error, reason, path);
      }
  }
  return Qt;
}

#else /* !HAVE_CMACS_CALCULATOR_CHART */

DEFUN ("cmacs-calculator-chart-supported-p",
       Fcmacs_calculator_chart_supported_p,
       Scmacs_calculator_chart_supported_p, 0, 0, 0,
       doc: /* Return non-nil if GPU charts can be rendered in this session.
Always nil in this build, which was configured without libregnum; the
Elisp SVG chart tier is unaffected.  */)
  (void)
{
  return Qnil;
}

DEFUN ("cmacs-calculator-chart-types", Fcmacs_calculator_chart_types,
       Scmacs_calculator_chart_types, 0, 0, 0,
       doc: /* Return the list of chart type symbols this build supports.
Always nil in this build, which was configured without libregnum.  */)
  (void)
{
  return Qnil;
}

#endif /* !HAVE_CMACS_CALCULATOR_CHART */

DEFUN ("cmacs-calculator-c-supported-p", Fcmacs_calculator_c_supported_p,
       Scmacs_calculator_c_supported_p, 0, 0, 0,
       doc: /* Return non-nil if the calculator's C half is compiled in.
The calculator engine itself is Elisp over GNU Calc and does not need
this; only GPU charting does.  See `cmacs-calculator-supported-p'.  */)
  (void)
{
  return Qt;
}

void
syms_of_cmacs_calculator_defuns (void)
{
  DEFSYM (Qcmacs_calculator_error, "cmacs-calculator-error");
  Fput (Qcmacs_calculator_error, Qerror_conditions,
        list2 (Qcmacs_calculator_error, Qerror));
  Fput (Qcmacs_calculator_error, Qerror_message,
        build_string ("CMacs calculator error"));

  defsubr (&Scmacs_calculator_c_supported_p);
  defsubr (&Scmacs_calculator_chart_supported_p);
  defsubr (&Scmacs_calculator_chart_types);
#ifdef HAVE_CMACS_CALCULATOR_CHART
  defsubr (&Scmacs_calculator_chart_attach);
  defsubr (&Scmacs_calculator_chart_detach);
  defsubr (&Scmacs_calculator_chart_set_type);
  defsubr (&Scmacs_calculator_chart_set_title);
  defsubr (&Scmacs_calculator_chart_set_background);
  defsubr (&Scmacs_calculator_chart_clear_series);
  defsubr (&Scmacs_calculator_chart_add_series);
  defsubr (&Scmacs_calculator_chart_refresh);
  defsubr (&Scmacs_calculator_chart_snapshot);
#endif
}

#endif /* HAVE_CMACS_CALCULATOR */
