/* cmacs-calculator-chart.h --- plain-C bridge to libregnum's chart module

Copyright (C) 2026 Zach Podbielniak

SPDX-License-Identifier: AGPL-3.0-or-later

This file is part of CMacs.  */

#ifndef CMACS_CALCULATOR_CHART_H
#define CMACS_CALCULATOR_CHART_H

#include <config.h>

#ifdef HAVE_CMACS_CALCULATOR_CHART

#include <glib.h>

G_BEGIN_DECLS

/* Plain-C wrapper around libregnum's LrgChart / LrgChartDataSeries.  Like
 * cmacs-libregnum-render.h and cmacs-gnuseye-globe.h, this header pulls in NO
 * libregnum / graylib / raylib types, so cmacs-internal sources -- which
 * define a conflicting `Color' typedef via pgtkgui.h -- can include it
 * freely.  The implementation (cmacs-calculator-chart.c) is the only
 * calculator TU that includes <libregnum.h>; it must never include lisp.h.
 *
 * Charts render through the shared CmacsLibregnumView, so a chart buffer
 * displays identically under pgtk (cairo blit of the FBO readback) and under
 * `emacs --lrg' (direct GL blit of the FBO texture).  Neither backend is
 * mentioned here or in the .c: that difference is owned entirely by
 * cmacs/libregnum/. */

/* Chart kinds, mirroring the LrgChart2D subclasses we expose.  Kept as a
 * plain enum so cmacs-calculator-defuns.c can map a Lisp symbol onto it
 * without seeing a libregnum type. */
typedef enum
{
  CMACS_CALC_CHART_LINE,
  CMACS_CALC_CHART_BAR,
  CMACS_CALC_CHART_AREA,
  CMACS_CALC_CHART_SCATTER,
  CMACS_CALC_CHART_PIE,
  CMACS_CALC_CHART_CANDLESTICK,
  CMACS_CALC_CHART_HISTOGRAM,
  CMACS_CALC_CHART_RADAR,
  CMACS_CALC_CHART_GAUGE,
  CMACS_CALC_CHART_HEATMAP,
  CMACS_CALC_CHART_INVALID
} CmacsCalcChartKind;

/* Map a chart-kind name ("line", "candlestick", ...) onto its enum value,
 * or CMACS_CALC_CHART_INVALID.  */
CmacsCalcChartKind cmacs_calculator_chart_kind_from_name (const char *name);

/* Return a NULL-terminated array of the supported chart-kind names.
 * Borrowed; do not free.  */
const char *const *cmacs_calculator_chart_kind_names (void);

/* Create a chart of KIND.  Returns an owned LrgChart* as an opaque pointer,
 * or NULL if KIND is invalid.  Release with cmacs_calculator_chart_unref.  */
void *cmacs_calculator_chart_new (CmacsCalcChartKind kind);

/* Drop one reference to CHART.  A plain g_object_unref, wrapped so callers
 * that must not see GObject/libregnum types can still own a ref.  */
void cmacs_calculator_chart_unref (void *chart);

/* Set the chart title (may be NULL to clear).  */
void cmacs_calculator_chart_set_title (void *chart, const char *title);

/* Drop every data series from CHART.  */
void cmacs_calculator_chart_clear_series (void *chart);

/* Append a series named NAME, coloured (CR,CG,CB), holding N points read
 * from the XS and YS arrays.  Returns TRUE on success.  */
gboolean cmacs_calculator_chart_add_series (void *chart, const char *name,
                                            guint8 cr, guint8 cg, guint8 cb,
                                            const double *xs, const double *ys,
                                            gsize n);

G_END_DECLS

#endif /* HAVE_CMACS_CALCULATOR_CHART */
#endif /* CMACS_CALCULATOR_CHART_H */
