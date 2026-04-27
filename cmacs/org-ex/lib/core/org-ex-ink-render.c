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

/* Emit one <path> covering the whole stroke as-is — used for
   highlighter (no pressure modulation, uniform width, semi-
   transparent).  The stroke-opacity attribute lives on the path
   itself rather than the global SVG so individual highlighter
   strokes can co-exist with opaque pen strokes. */
static void
ink_append_uniform_path (GString *out,
                         const gchar *colour,
                         gfloat width,
                         gdouble opacity,
                         const OrgExInkPoint *pts,
                         guint n_points)
{
  guint k;
  if (n_points == 0) return;

  g_string_append (out, "<path d=\"M ");
  g_string_append_printf (out, "%d %d",
                          (gint) pts[0].x, (gint) pts[0].y);
  for (k = 1; k < n_points; k++)
    g_string_append_printf (out, " L %d %d",
                            (gint) pts[k].x, (gint) pts[k].y);
  g_string_append (out, "\" stroke=\"");
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
                        " fill=\"none\"");
  if (opacity < 1.0)
    {
      gchar buf[16];
      gint q = (gint) ((opacity * 100.0) + 0.5);
      if (q < 0) q = 0;
      if (q > 100) q = 100;
      g_snprintf (buf, sizeof buf, "%.2f", q / 100.0);
      g_string_append_printf (out, " stroke-opacity=\"%s\"", buf);
    }
  g_string_append (out, "/>\n");
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
  OrgExInkTool tool;

  tool = org_ex_ink_stroke_get_tool (stroke);
  if (tool == ORG_EX_INK_TOOL_ERASER)
    return; /* hit-test trail; never persisted into the rendered SVG */

  pts = org_ex_ink_stroke_get_points (stroke, &n_points);
  if (n_points == 0)
    return;

  colour = org_ex_ink_stroke_get_colour (stroke);
  base   = org_ex_ink_stroke_get_base_width (stroke);
  if (base < INK_MIN_BASE_WIDTH)
    base = INK_MIN_BASE_WIDTH;

  /* Highlighter: uniform width, alpha 0.5, no pressure splitting.
     Even single-point taps render as a small flat circle. */
  if (tool == ORG_EX_INK_TOOL_HIGHLIGHTER)
    {
      if (n_points == 1)
        {
          g_string_append (out, "<circle cx=\"");
          g_string_append_printf (out, "%d", (gint) pts[0].x);
          g_string_append (out, "\" cy=\"");
          g_string_append_printf (out, "%d", (gint) pts[0].y);
          g_string_append (out, "\" r=\"");
          ink_append_width (out, base * 0.5f);
          g_string_append (out, "\" fill=\"");
          g_string_append (out, colour);
          g_string_append (out, "\" fill-opacity=\"0.5\"/>\n");
          return;
        }
      ink_append_uniform_path (out, colour, base, 0.5, pts, n_points);
      return;
    }

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

/* Emit BG_COLOUR as an XML-attribute value, escaping `"` and
   the obvious XML-breakers so users can pass arbitrary CSS-style
   colour strings (named, hex, rgb()...).  NULL → "#ffffff". */
static void
ink_append_bg_colour (GString *out, const gchar *bg_colour)
{
  const gchar *p = bg_colour && *bg_colour ? bg_colour : "#ffffff";
  for (; *p; p++)
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

gchar *
org_ex_ink_render_to_svg (GPtrArray   *strokes,
                          gint         width,
                          gint         height,
                          const gchar *bg_colour)
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

  /* "Page" background.  Defaults to white when bg_colour is NULL —
     without an explicit fill, librsvg renders a transparent
     surface and the buffer's frame background shows through, which
     makes dark ink invisible on dark themes.  Pass a theme-matched
     colour from Elisp via `cmacs-org-ex-ink--effective-bg' so the
     canvas blends into the surrounding buffer. */
  g_string_append (out,
    "<rect x=\"0\" y=\"0\" width=\"");
  g_string_append_printf (out, "%d\" height=\"%d", width, height);
  g_string_append (out, "\" fill=\"");
  ink_append_bg_colour (out, bg_colour);
  g_string_append (out, "\"/>\n");

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

/* ---- Direct Cairo painting --------------------------------------- */

static gint
ink_hex_nibble (gchar c)
{
  if (c >= '0' && c <= '9') return c - '0';
  if (c >= 'a' && c <= 'f') return 10 + c - 'a';
  if (c >= 'A' && c <= 'F') return 10 + c - 'A';
  return -1;
}

static void
ink_parse_hex_colour (const gchar *hex, gdouble *r, gdouble *g, gdouble *b)
{
  /* Minimal hex-colour parser supporting #RGB and #RRGGBB.  Avoids
     a GdkRGBA dependency so this helper stays toolkit-agnostic and
     can run in any Cairo context (including the redisplay-finish
     hook in pgtkterm where pulling in GdkRGBA would be awkward). */
  size_t len;
  *r = 0.13; *g = 0.13; *b = 0.13;
  if (hex == NULL || *hex != '#')
    return;
  hex++;
  len = strlen (hex);
  if (len >= 6)
    {
      gint r0 = ink_hex_nibble (hex[0]), r1 = ink_hex_nibble (hex[1]);
      gint g0 = ink_hex_nibble (hex[2]), g1 = ink_hex_nibble (hex[3]);
      gint b0 = ink_hex_nibble (hex[4]), b1 = ink_hex_nibble (hex[5]);
      if (r0 >= 0 && r1 >= 0 && g0 >= 0 && g1 >= 0
          && b0 >= 0 && b1 >= 0)
        {
          *r = (r0 * 16 + r1) / 255.0;
          *g = (g0 * 16 + g1) / 255.0;
          *b = (b0 * 16 + b1) / 255.0;
        }
    }
  else if (len >= 3)
    {
      gint r0 = ink_hex_nibble (hex[0]);
      gint g0 = ink_hex_nibble (hex[1]);
      gint b0 = ink_hex_nibble (hex[2]);
      if (r0 >= 0 && g0 >= 0 && b0 >= 0)
        {
          *r = r0 / 15.0;
          *g = g0 / 15.0;
          *b = b0 / 15.0;
        }
    }
}

static gdouble
ink_cairo_segment_width (gfloat base, gfloat pressure)
{
  gdouble scale = 0.3 + (0.7 * pressure);
  gdouble w = base * scale;
  if (w < INK_MIN_BASE_WIDTH) w = INK_MIN_BASE_WIDTH;
  return w;
}

static void
ink_paint_one_stroke (cairo_t *cr, OrgExInkStroke *stroke,
                      gdouble alpha)
{
  guint n = 0, i;
  const OrgExInkPoint *pts;
  const gchar *colour;
  gfloat base;
  gdouble r, g, b;
  OrgExInkTool tool;
  gdouble effective_alpha;

  tool = org_ex_ink_stroke_get_tool (stroke);
  if (tool == ORG_EX_INK_TOOL_ERASER)
    return;

  pts = org_ex_ink_stroke_get_points (stroke, &n);
  if (n == 0)
    return;

  colour = org_ex_ink_stroke_get_colour (stroke);
  base = org_ex_ink_stroke_get_base_width (stroke);
  if (base < INK_MIN_BASE_WIDTH)
    base = INK_MIN_BASE_WIDTH;

  ink_parse_hex_colour (colour, &r, &g, &b);

  /* Highlighter forces alpha 0.5 regardless of caller — the
     tool's defining property is "see-through".  Mirrors the SVG
     path's fixed `stroke-opacity="0.5"' so the live capture, the
     in-buffer overlay paint, and the rendered SVG all blend
     identically.  The caller's alpha applies to pen and any future
     opaque tools (region overlay default 0.85, capture window
     default 1.0). */
  if (tool == ORG_EX_INK_TOOL_HIGHLIGHTER)
    effective_alpha = 0.5;
  else
    effective_alpha = alpha;

  cairo_set_source_rgba (cr, r, g, b, effective_alpha);
  cairo_set_line_cap (cr, CAIRO_LINE_CAP_ROUND);
  cairo_set_line_join (cr, CAIRO_LINE_JOIN_ROUND);

  /* Highlighter: uniform width, no pressure modulation. */
  if (tool == ORG_EX_INK_TOOL_HIGHLIGHTER)
    {
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

  /* Pen: variable-width, pressure-driven. */
  if (n == 1)
    {
      gdouble w = ink_cairo_segment_width (base, pts[0].pressure);
      cairo_arc (cr, pts[0].x, pts[0].y, w * 0.5, 0, 2 * G_PI);
      cairo_fill (cr);
      return;
    }

  for (i = 1; i < n; i++)
    {
      cairo_set_line_width (
        cr, ink_cairo_segment_width (base, pts[i].pressure));
      cairo_move_to (cr, pts[i - 1].x, pts[i - 1].y);
      cairo_line_to (cr, pts[i].x,     pts[i].y);
      cairo_stroke (cr);
    }
}

void
org_ex_ink_paint_strokes_cairo (cairo_t   *cr,
                                GPtrArray *strokes,
                                gdouble    tx,
                                gdouble    ty,
                                gdouble    alpha)
{
  guint i;
  if (cr == NULL || strokes == NULL)
    return;
  if (alpha < 0.0) alpha = 0.0;
  if (alpha > 1.0) alpha = 1.0;

  cairo_save (cr);
  /* Force OPERATOR_OVER so alpha actually alpha-blends against the
     destination.  pgtk's redisplay flip uses OPERATOR_SOURCE to
     copy the back surface, and Emacs may leave the cr_context in
     that state when our post-glyph hook fires — under SOURCE, an
     alpha-0.5 source is *copied* into the dest (overwriting buffer
     pixels with a half-transparent yellow), making the highlighter
     look fully opaque against the surface beneath cr_context.  OVER
     is the standard Porter-Duff blend that gives the
     "see-through" highlighter effect we want. */
  cairo_set_operator (cr, CAIRO_OPERATOR_OVER);
  cairo_translate (cr, tx, ty);
  for (i = 0; i < strokes->len; i++)
    {
      OrgExInkStroke *s = g_ptr_array_index (strokes, i);
      if (s != NULL)
        ink_paint_one_stroke (cr, s, alpha);
    }
  cairo_restore (cr);
}
