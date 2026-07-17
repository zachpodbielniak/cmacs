/* cmacs-calculator-chart.c --- libregnum chart construction for the calculator

Copyright (C) 2026 Zach Podbielniak

SPDX-License-Identifier: AGPL-3.0-or-later

This file is part of CMacs.  */

/* THE ONLY calculator TU that includes <libregnum.h>.  It must never include
 * lisp.h: raylib's `Color' struct collides with the `Color' typedef cmacs
 * pulls in through pgtkgui.h, so a TU sees one world or the other.  Everything
 * else in cmacs/calculator/ talks to this file through the plain-C
 * cmacs-calculator-chart.h.  Same firewall as cmacs-gnuseye-globe.c and
 * cmacs-imgedit-doc.c.
 *
 * Scope: build and populate the LrgChart.  DRAWING is not done here -- charts
 * are LrgWidgets drawn with immediate-mode grl_draw_* calls, which are only
 * legal inside the render bracket, so the draw lives in
 * cmacs/libregnum/cmacs-libregnum-render.c's chart_mode branch.  That is also
 * what makes a chart render identically under pgtk and `emacs --lrg'. */

#include <config.h>

#ifdef HAVE_CMACS_CALCULATOR_CHART

#include "cmacs-calculator-chart.h"

#include <libregnum.h>

/* Kind names, indexed by CmacsCalcChartKind.  Must stay in step with the enum
 * -- the NULL terminator lets callers iterate without a count. */
static const char *const chart_kind_names[] = {
  "line", "bar", "area", "scatter", "pie",
  "candlestick", "histogram", "radar", "gauge", "heatmap",
  NULL
};

const char *const *
cmacs_calculator_chart_kind_names (void)
{
  return chart_kind_names;
}

CmacsCalcChartKind
cmacs_calculator_chart_kind_from_name (const char *name)
{
  int i;

  if (name == NULL)
    return CMACS_CALC_CHART_INVALID;
  for (i = 0; chart_kind_names[i] != NULL; i++)
    if (g_strcmp0 (chart_kind_names[i], name) == 0)
      return (CmacsCalcChartKind) i;
  return CMACS_CALC_CHART_INVALID;
}

void *
cmacs_calculator_chart_new (CmacsCalcChartKind kind)
{
  switch (kind)
    {
    case CMACS_CALC_CHART_LINE:        return lrg_line_chart2d_new ();
    case CMACS_CALC_CHART_BAR:         return lrg_bar_chart2d_new ();
    case CMACS_CALC_CHART_AREA:        return lrg_area_chart2d_new ();
    case CMACS_CALC_CHART_SCATTER:     return lrg_scatter_chart2d_new ();
    case CMACS_CALC_CHART_PIE:         return lrg_pie_chart2d_new ();
    case CMACS_CALC_CHART_CANDLESTICK: return lrg_candlestick_chart2d_new ();
    case CMACS_CALC_CHART_HISTOGRAM:   return lrg_histogram_chart2d_new ();
    case CMACS_CALC_CHART_RADAR:       return lrg_radar_chart2d_new ();
    case CMACS_CALC_CHART_GAUGE:       return lrg_gauge_chart2d_new ();
    case CMACS_CALC_CHART_HEATMAP:     return lrg_heatmap_chart2d_new ();
    case CMACS_CALC_CHART_INVALID:
    default:
      return NULL;
    }
}

void
cmacs_calculator_chart_unref (void *chart)
{
  if (chart == NULL)
    return;
  g_object_unref (G_OBJECT (chart));
}

void
cmacs_calculator_chart_set_title (void *chart, const char *title)
{
  if (chart == NULL)
    return;
  lrg_chart_set_title (LRG_CHART (chart), title);
}

void
cmacs_calculator_chart_clear_series (void *chart)
{
  if (chart == NULL)
    return;
  lrg_chart_clear_series (LRG_CHART (chart));
}

gboolean
cmacs_calculator_chart_add_series (void *chart, const char *name,
                                   guint8 cr, guint8 cg, guint8 cb,
                                   const double *xs, const double *ys,
                                   gsize n)
{
  LrgChartDataSeries *series;
  g_autoptr (GrlColor) color = NULL;
  gsize i;

  if (chart == NULL || xs == NULL || ys == NULL)
    return FALSE;

  color = grl_color_new (cr, cg, cb, 255);
  series = lrg_chart_data_series_new_with_color (name ? name : "", color);
  if (series == NULL)
    return FALSE;

  for (i = 0; i < n; i++)
    lrg_chart_data_series_add_point (series, xs[i], ys[i]);

  /* lrg_chart_add_series takes ownership of the series ref we hold. */
  lrg_chart_add_series (LRG_CHART (chart), series);
  return TRUE;
}

#endif /* HAVE_CMACS_CALCULATOR_CHART */
