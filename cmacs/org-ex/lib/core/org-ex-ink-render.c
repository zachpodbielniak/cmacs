/* org-ex-ink-render.c — Strokes → SVG renderer
 *
 * Copyright (C) 2026 Zach Podbielniak
 * SPDX-License-Identifier: AGPL-3.0-or-later
 *
 * Variable-width strokes: split each stroke into per-segment <path>
 * fragments at pressure-change boundaries.  Quantize widths to one
 * decimal and only emit a fragment break when Δwidth > 0.3 px so the
 * SVG stays compact.  Single-pressure strokes collapse to one <path>.
 */

#ifndef ORG_EX_COMPILATION
#define ORG_EX_COMPILATION
#endif

#include "org-ex-ink-render.h"

#include <math.h>
#include <string.h>

#define INK_WIDTH_QUANTUM   0.3f
#define INK_MIN_BASE_WIDTH  0.5f

/* Effective stroke width at a given segment.  Pressure 0 maps to
   30 % of base; pressure 1 maps to 100 % of base.  Strokes captured
   without a tablet (pressure ≡ 1.0) render at full width. */
static gfloat
ink_segment_width (gfloat base, gfloat pressure)
{
  gfloat scale = 0.3f + (0.7f * pressure);
  gfloat w = base * scale;
  if (w < INK_MIN_BASE_WIDTH)
    w = INK_MIN_BASE_WIDTH;
  return w;
}

/* Append a width as `2` or `2.5` (no trailing zero). */
static void
ink_append_width (GString *out, gfloat w)
{
  gchar buf[32];
  gint scaled = (gint) ((w * 10.0f) + 0.5f);
  if (scaled % 10 == 0)
    g_snprintf (buf, sizeof buf, "%d", scaled / 10);
  else
    g_snprintf (buf, sizeof buf, "%d.%d", scaled / 10, scaled % 10);
  g_string_append (out, buf);
}

static void
ink_append_segment_path (GString             *out,
                         const gchar         *colour,
                         gfloat               width,
                         const OrgExInkPoint *pts,
                         guint                start,
                         guint                end)
{
  guint k;

  if (end <= start) return;

  g_string_append (out, "<path d=\"M ");
  g_string_append_printf (out, "%d %d", (gint) pts[start].x, (gint) pts[start].y);
  for (k = start + 1; k <= end && k < G_MAXUINT; k++)
    {
      g_string_append_printf (out, " L %d %d",
                              (gint) pts[k].x, (gint) pts[k].y);
      if (k == end) break;
    }
  g_string_append (out, "\" stroke=\"");
  /* Colours are user-supplied; sanitise the obvious XML-breakers. */
  {
    const gchar *p;
    for (p = colour; p != NULL && *p; p++)
      {
        switch (*p)
          {
          case '<': g_string_append (out, "&lt;");   break;
          case '>': g_string_append (out, "&gt;");   break;
          case '&': g_string_append (out, "&amp;");  break;
          case '"': g_string_append (out, "&quot;"); break;
          default:  g_string_append_c (out, *p);     break;
          }
      }
  }
  g_string_append (out, "\" stroke-width=\"");
  ink_append_width (out, width);
  g_string_append (out, "\" stroke-linecap=\"round\""
                        " stroke-linejoin=\"round\""
                        " fill=\"none\"/>\n");
}

static void
ink_render_stroke (GString *out, OrgExInkStroke *stroke)
{
  guint n_points = 0;
  const OrgExInkPoint *pts;
  const gchar *colour;
  gfloat base;
  guint seg_start;
  gfloat seg_width;
  guint i;

  if (org_ex_ink_stroke_get_tool (stroke) == ORG_EX_INK_TOOL_ERASER)
    return; /* hit-test trail; never persisted into the rendered SVG */

  pts = org_ex_ink_stroke_get_points (stroke, &n_points);
  if (n_points == 0)
    return;

  colour = org_ex_ink_stroke_get_colour (stroke);
  base   = org_ex_ink_stroke_get_base_width (stroke);
  if (base < INK_MIN_BASE_WIDTH)
    base = INK_MIN_BASE_WIDTH;

  if (n_points == 1)
    {
      gfloat w = ink_segment_width (base, pts[0].pressure);
      /* Single-point stroke renders as a tiny dot via a degenerate
         path so it's still visible. */
      g_string_append (out, "<circle cx=\"");
      g_string_append_printf (out, "%d", (gint) pts[0].x);
      g_string_append (out, "\" cy=\"");
      g_string_append_printf (out, "%d", (gint) pts[0].y);
      g_string_append (out, "\" r=\"");
      ink_append_width (out, w * 0.5f);
      g_string_append (out, "\" fill=\"");
      g_string_append (out, colour);
      g_string_append (out, "\"/>\n");
      return;
    }

  seg_start = 0;
  seg_width = ink_segment_width (base, pts[0].pressure);

  for (i = 1; i < n_points; i++)
    {
      gfloat w = ink_segment_width (base, pts[i].pressure);
      if (fabsf (w - seg_width) > INK_WIDTH_QUANTUM)
        {
          ink_append_segment_path (out, colour, seg_width,
                                   pts, seg_start, i);
          seg_start = i;
          seg_width = w;
        }
    }
  ink_append_segment_path (out, colour, seg_width,
                           pts, seg_start, n_points - 1);
}

gchar *
org_ex_ink_render_to_svg (GPtrArray *strokes,
                          gint       width,
                          gint       height)
{
  GString *out;
  guint i;

  if (width  <= 0) width  = 800;
  if (height <= 0) height = 400;

  out = g_string_new (NULL);
  g_string_append_printf (out,
    "<svg xmlns=\"http://www.w3.org/2000/svg\" "
    "viewBox=\"0 0 %d %d\" width=\"%d\" height=\"%d\">\n",
    width, height, width, height);

  /* Explicit white "page" background.  Without it, librsvg renders
     a transparent surface and the buffer's frame background shows
     through — on dark themes the dark default ink colour ("#222")
     becomes invisible against the bg.  This matches the white
     Cairo background painted by the capture window. */
  g_string_append_printf (out,
    "<rect x=\"0\" y=\"0\" width=\"%d\" height=\"%d\" fill=\"#ffffff\"/>\n",
    width, height);

  /* Subtle 1px border so the canvas extent is visible against the
     surrounding buffer text. */
  g_string_append_printf (out,
    "<rect x=\"0.5\" y=\"0.5\" width=\"%d\" height=\"%d\" "
    "fill=\"none\" stroke=\"#cccccc\" stroke-width=\"1\"/>\n",
    width - 1, height - 1);

  if (strokes != NULL)
    {
      for (i = 0; i < strokes->len; i++)
        {
          OrgExInkStroke *s = g_ptr_array_index (strokes, i);
          if (s != NULL)
            ink_render_stroke (out, s);
        }
    }

  g_string_append (out, "</svg>\n");
  return g_string_free (out, FALSE);
}
