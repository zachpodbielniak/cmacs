/* org-ex-ink-stroke.c — Ink stroke data + S-expression I/O
 *
 * Copyright (C) 2026 Zach Podbielniak
 * SPDX-License-Identifier: AGPL-3.0-or-later
 *
 * Stroke storage is deliberately small: one stroke = tool + colour +
 * base width + a GArray of (x,y,pressure) points.  The block-body
 * language is the canonical on-disk form; this file owns parse and
 * serialise so that callers (the OrgExWidgetInk render path, and the
 * Elisp DEFUN bridge) never reimplement it.
 */

#ifndef ORG_EX_COMPILATION
#define ORG_EX_COMPILATION
#endif

#include "org-ex-ink-stroke.h"
#include "../org-ex-types.h"

#include <stdlib.h>
#include <string.h>

struct _OrgExInkStroke
{
  gint           ref_count;
  OrgExInkTool   tool;
  gchar         *colour;
  gfloat         base_width;
  GArray        *points;       /* OrgExInkPoint */
};

GType
org_ex_ink_tool_get_type (void)
{
  static volatile gsize g_type_id = 0;

  if (g_once_init_enter (&g_type_id))
    {
      static const GEnumValue values[] = {
        { ORG_EX_INK_TOOL_PEN,         "ORG_EX_INK_TOOL_PEN",         "pen" },
        { ORG_EX_INK_TOOL_ERASER,      "ORG_EX_INK_TOOL_ERASER",      "eraser" },
        { ORG_EX_INK_TOOL_HIGHLIGHTER, "ORG_EX_INK_TOOL_HIGHLIGHTER", "highlighter" },
        { 0, NULL, NULL }
      };
      GType type_id = g_enum_register_static ("OrgExInkTool", values);
      g_once_init_leave (&g_type_id, type_id);
    }

  return (GType) g_type_id;
}

G_DEFINE_BOXED_TYPE (OrgExInkStroke, org_ex_ink_stroke,
                     org_ex_ink_stroke_ref, org_ex_ink_stroke_unref)

OrgExInkStroke *
org_ex_ink_stroke_new (OrgExInkTool tool,
                       const gchar *colour,
                       gfloat       base_width)
{
  OrgExInkStroke *self = g_new0 (OrgExInkStroke, 1);
  self->ref_count  = 1;
  self->tool       = tool;
  self->colour     = g_strdup (colour ? colour : "#222");
  self->base_width = base_width > 0.0f ? base_width : 2.0f;
  self->points     = g_array_new (FALSE, FALSE, sizeof (OrgExInkPoint));
  return self;
}

OrgExInkStroke *
org_ex_ink_stroke_ref (OrgExInkStroke *self)
{
  g_return_val_if_fail (self != NULL, NULL);
  g_atomic_int_inc (&self->ref_count);
  return self;
}

void
org_ex_ink_stroke_unref (OrgExInkStroke *self)
{
  if (self == NULL)
    return;

  if (g_atomic_int_dec_and_test (&self->ref_count))
    {
      g_free (self->colour);
      g_array_free (self->points, TRUE);
      g_free (self);
    }
}

void
org_ex_ink_stroke_append_point (OrgExInkStroke *self,
                                gint16          x,
                                gint16          y,
                                gfloat          pressure)
{
  OrgExInkPoint pt;

  g_return_if_fail (self != NULL);

  if (pressure < 0.0f) pressure = 0.0f;
  if (pressure > 1.0f) pressure = 1.0f;

  pt.x = x;
  pt.y = y;
  pt.pressure = pressure;
  g_array_append_val (self->points, pt);
}

OrgExInkTool
org_ex_ink_stroke_get_tool (OrgExInkStroke *self)
{
  g_return_val_if_fail (self != NULL, ORG_EX_INK_TOOL_PEN);
  return self->tool;
}

const gchar *
org_ex_ink_stroke_get_colour (OrgExInkStroke *self)
{
  g_return_val_if_fail (self != NULL, NULL);
  return self->colour;
}

gfloat
org_ex_ink_stroke_get_base_width (OrgExInkStroke *self)
{
  g_return_val_if_fail (self != NULL, 0.0f);
  return self->base_width;
}

guint
org_ex_ink_stroke_n_points (OrgExInkStroke *self)
{
  g_return_val_if_fail (self != NULL, 0);
  return self->points->len;
}

const OrgExInkPoint *
org_ex_ink_stroke_get_point (OrgExInkStroke *self,
                             guint           index)
{
  g_return_val_if_fail (self != NULL, NULL);
  g_return_val_if_fail (index < self->points->len, NULL);
  return &g_array_index (self->points, OrgExInkPoint, index);
}

const OrgExInkPoint *
org_ex_ink_stroke_get_points (OrgExInkStroke *self,
                              guint          *n_points)
{
  g_return_val_if_fail (self != NULL, NULL);
  if (n_points != NULL)
    *n_points = self->points->len;
  return (const OrgExInkPoint *) self->points->data;
}

/* ---- Stroke array helpers ---- */

GPtrArray *
org_ex_ink_strokes_new (void)
{
  return g_ptr_array_new_with_free_func (
    (GDestroyNotify) org_ex_ink_stroke_unref);
}

void
org_ex_ink_strokes_free (GPtrArray *strokes)
{
  if (strokes != NULL)
    g_ptr_array_unref (strokes);
}

/* ---- S-expression parser ----
   Hand-rolled recursive-descent over the small grammar of stroke
   forms.  Avoiding a generic sexpr parser keeps the binary small and
   the error messages tight. */

typedef struct
{
  const gchar *p;
  const gchar *end;
} InkParser;

static void
ink_skip_ws (InkParser *parser)
{
  while (parser->p < parser->end)
    {
      gchar c = *parser->p;
      if (c == ' ' || c == '\t' || c == '\n' || c == '\r')
        parser->p++;
      else
        break;
    }
}

static gboolean
ink_at_eof (InkParser *parser)
{
  return parser->p >= parser->end;
}

static gboolean
ink_consume_char (InkParser *parser, gchar expected)
{
  if (ink_at_eof (parser) || *parser->p != expected)
    return FALSE;
  parser->p++;
  return TRUE;
}

static gboolean
ink_parse_number (InkParser *parser, gdouble *out)
{
  gchar *endp = NULL;
  gdouble v;

  ink_skip_ws (parser);
  if (ink_at_eof (parser))
    return FALSE;

  v = g_ascii_strtod (parser->p, &endp);
  if (endp == parser->p)
    return FALSE;

  parser->p = endp;
  *out = v;
  return TRUE;
}

/* Parse `:keyword` returning the token after the colon (without the
   colon).  Caller frees with g_free.  Returns NULL on no-match. */
static gchar *
ink_parse_keyword (InkParser *parser)
{
  const gchar *start;

  ink_skip_ws (parser);
  if (ink_at_eof (parser) || *parser->p != ':')
    return NULL;
  parser->p++;
  start = parser->p;
  while (parser->p < parser->end)
    {
      gchar c = *parser->p;
      if (g_ascii_isalnum (c) || c == '-' || c == '_')
        parser->p++;
      else
        break;
    }
  if (parser->p == start)
    return NULL;
  return g_strndup (start, parser->p - start);
}

/* Parse a quoted string `"..."`.  Supports backslash escapes only for
   `\"` and `\\` — colours never need anything richer. */
static gchar *
ink_parse_string (InkParser *parser)
{
  GString *buf;

  ink_skip_ws (parser);
  if (!ink_consume_char (parser, '"'))
    return NULL;

  buf = g_string_new (NULL);
  while (parser->p < parser->end && *parser->p != '"')
    {
      gchar c = *parser->p++;
      if (c == '\\' && parser->p < parser->end)
        {
          gchar e = *parser->p++;
          g_string_append_c (buf, e);
        }
      else
        {
          g_string_append_c (buf, c);
        }
    }
  if (!ink_consume_char (parser, '"'))
    {
      g_string_free (buf, TRUE);
      return NULL;
    }
  return g_string_free (buf, FALSE);
}

/* Parse a bare symbol token (e.g. `pen`, `eraser`, `s`). */
static gchar *
ink_parse_symbol (InkParser *parser)
{
  const gchar *start;

  ink_skip_ws (parser);
  start = parser->p;
  while (parser->p < parser->end)
    {
      gchar c = *parser->p;
      if (g_ascii_isalnum (c) || c == '-' || c == '_')
        parser->p++;
      else
        break;
    }
  if (parser->p == start)
    return NULL;
  return g_strndup (start, parser->p - start);
}

/* Parse the points list `((X Y P) (X Y P) ...)` directly into the
   stroke.  The leading paren has been consumed. */
static gboolean
ink_parse_points (InkParser *parser, OrgExInkStroke *stroke,
                  GError **error)
{
  ink_skip_ws (parser);
  if (!ink_consume_char (parser, '('))
    {
      g_set_error_literal (error, ORG_EX_ERROR, ORG_EX_ERROR_STATE,
                           "ink: expected '(' opening points list");
      return FALSE;
    }

  while (TRUE)
    {
      gdouble nx, ny, np;

      ink_skip_ws (parser);
      if (ink_consume_char (parser, ')'))
        break;
      if (!ink_consume_char (parser, '('))
        {
          g_set_error_literal (error, ORG_EX_ERROR, ORG_EX_ERROR_STATE,
                               "ink: expected '(' opening point");
          return FALSE;
        }
      if (!ink_parse_number (parser, &nx)
          || !ink_parse_number (parser, &ny)
          || !ink_parse_number (parser, &np))
        {
          g_set_error_literal (error, ORG_EX_ERROR, ORG_EX_ERROR_STATE,
                               "ink: malformed point — expected (X Y P)");
          return FALSE;
        }
      ink_skip_ws (parser);
      if (!ink_consume_char (parser, ')'))
        {
          g_set_error_literal (error, ORG_EX_ERROR, ORG_EX_ERROR_STATE,
                               "ink: expected ')' closing point");
          return FALSE;
        }
      if (np > 1000.0) np = 1000.0;
      if (np < 0.0)    np = 0.0;
      org_ex_ink_stroke_append_point (stroke,
                                      (gint16) nx,
                                      (gint16) ny,
                                      (gfloat) (np / 1000.0));
    }
  return TRUE;
}

/* Parse one `(s :t pen :c "#222" :w 2 :p ((...) (...)))` form.  The
   leading paren has been consumed.  Returns NULL on error. */
static OrgExInkStroke *
ink_parse_stroke_form (InkParser *parser, GError **error)
{
  OrgExInkStroke *stroke;
  gchar *head;
  OrgExInkTool tool = ORG_EX_INK_TOOL_PEN;
  gchar *colour = NULL;
  gfloat base_width = 2.0f;
  gboolean got_points = FALSE;

  head = ink_parse_symbol (parser);
  if (head == NULL || g_strcmp0 (head, "s") != 0)
    {
      g_set_error_literal (error, ORG_EX_ERROR, ORG_EX_ERROR_STATE,
                           "ink: expected stroke head 's'");
      g_free (head);
      return NULL;
    }
  g_free (head);

  stroke = org_ex_ink_stroke_new (ORG_EX_INK_TOOL_PEN, "#222", 2.0f);

  while (TRUE)
    {
      gchar *kw;

      ink_skip_ws (parser);
      if (ink_consume_char (parser, ')'))
        break;

      kw = ink_parse_keyword (parser);
      if (kw == NULL)
        {
          g_set_error_literal (error, ORG_EX_ERROR, ORG_EX_ERROR_STATE,
                               "ink: expected keyword inside stroke");
          org_ex_ink_stroke_unref (stroke);
          return NULL;
        }

      if (g_strcmp0 (kw, "t") == 0)
        {
          gchar *sym = ink_parse_symbol (parser);
          if (sym == NULL)
            {
              g_free (kw);
              g_set_error_literal (error, ORG_EX_ERROR, ORG_EX_ERROR_STATE,
                                   "ink: :t expects a symbol");
              org_ex_ink_stroke_unref (stroke);
              return NULL;
            }
          if (g_strcmp0 (sym, "pen") == 0)
            tool = ORG_EX_INK_TOOL_PEN;
          else if (g_strcmp0 (sym, "eraser") == 0)
            tool = ORG_EX_INK_TOOL_ERASER;
          else if (g_strcmp0 (sym, "highlighter") == 0)
            tool = ORG_EX_INK_TOOL_HIGHLIGHTER;
          g_free (sym);
        }
      else if (g_strcmp0 (kw, "c") == 0)
        {
          g_free (colour);
          colour = ink_parse_string (parser);
        }
      else if (g_strcmp0 (kw, "w") == 0)
        {
          gdouble v;
          if (!ink_parse_number (parser, &v))
            {
              g_free (kw);
              g_set_error_literal (error, ORG_EX_ERROR, ORG_EX_ERROR_STATE,
                                   "ink: :w expects a number");
              org_ex_ink_stroke_unref (stroke);
              g_free (colour);
              return NULL;
            }
          base_width = (gfloat) v;
        }
      else if (g_strcmp0 (kw, "p") == 0)
        {
          got_points = TRUE;
          if (!ink_parse_points (parser, stroke, error))
            {
              g_free (kw);
              g_free (colour);
              org_ex_ink_stroke_unref (stroke);
              return NULL;
            }
        }
      else
        {
          /* Skip unknown keyword's value: a single token (string,
             number, or symbol).  This keeps forward-compat tokens
             from breaking older parsers. */
          ink_skip_ws (parser);
          if (parser->p < parser->end)
            {
              gchar c = *parser->p;
              if (c == '"')
                {
                  gchar *s = ink_parse_string (parser);
                  g_free (s);
                }
              else if (c == '(')
                {
                  /* skip parenthesised sub-form */
                  gint depth = 0;
                  do {
                    gchar cc = *parser->p++;
                    if (cc == '(') depth++;
                    else if (cc == ')') depth--;
                  } while (depth > 0 && parser->p < parser->end);
                }
              else
                {
                  gdouble v;
                  if (!ink_parse_number (parser, &v))
                    {
                      gchar *s = ink_parse_symbol (parser);
                      g_free (s);
                    }
                }
            }
        }

      g_free (kw);
    }

  /* Patch the constructed stroke with the parsed metadata. */
  stroke->tool = tool;
  if (colour != NULL)
    {
      g_free (stroke->colour);
      stroke->colour = colour;
    }
  if (base_width > 0.0f)
    stroke->base_width = base_width;

  if (!got_points)
    {
      /* Strokes without points are valid but useless — keep them so
         malformed editors don't lose data on round-trip. */
    }

  return stroke;
}

GPtrArray *
org_ex_ink_strokes_from_string (const gchar *text,
                                GError     **error)
{
  GPtrArray *strokes;
  InkParser parser;

  g_return_val_if_fail (text != NULL, NULL);

  strokes = org_ex_ink_strokes_new ();
  parser.p = text;
  parser.end = text + strlen (text);

  while (parser.p < parser.end)
    {
      ink_skip_ws (&parser);
      if (parser.p >= parser.end)
        break;

      /* Comment line — skip to end of line. */
      if (parser.p + 1 < parser.end
          && parser.p[0] == ';' && parser.p[1] == ';')
        {
          while (parser.p < parser.end && *parser.p != '\n')
            parser.p++;
          continue;
        }

      if (*parser.p == '(')
        {
          OrgExInkStroke *stroke;
          parser.p++;
          stroke = ink_parse_stroke_form (&parser, error);
          if (stroke == NULL)
            {
              org_ex_ink_strokes_free (strokes);
              return NULL;
            }
          g_ptr_array_add (strokes, stroke);
          continue;
        }

      /* Unrecognised junk between strokes — skip to next newline so
         the parser doesn't loop forever on a stray character. */
      while (parser.p < parser.end && *parser.p != '\n')
        parser.p++;
    }

  return strokes;
}

/* ---- S-expression serialiser ----
   Stable key order (`:t :c :w :p`); one stroke per line; integers
   for X,Y; pressure as `pressure*1000` rounded to nearest int so
   the on-disk value is stable across float-format jitter. */

static const gchar *
ink_tool_to_string (OrgExInkTool tool)
{
  switch (tool)
    {
    case ORG_EX_INK_TOOL_PEN:         return "pen";
    case ORG_EX_INK_TOOL_ERASER:      return "eraser";
    case ORG_EX_INK_TOOL_HIGHLIGHTER: return "highlighter";
    default:                          return "pen";
    }
}

static void
ink_append_width (GString *out, gfloat w)
{
  /* Render trailing-zero-free with up to 1 decimal — e.g. "2",
     "2.5", but never "2.0".  Keeps diffs minimal across sessions
     where exact float reps may wobble. */
  gchar buf[32];
  gint scaled = (gint) ((w * 10.0f) + 0.5f);
  if (scaled % 10 == 0)
    g_snprintf (buf, sizeof buf, "%d", scaled / 10);
  else
    g_snprintf (buf, sizeof buf, "%d.%d", scaled / 10, scaled % 10);
  g_string_append (out, buf);
}

gchar *
org_ex_ink_strokes_to_string (GPtrArray *strokes)
{
  GString *out;
  guint i, j;

  g_return_val_if_fail (strokes != NULL, NULL);

  out = g_string_new (NULL);

  for (i = 0; i < strokes->len; i++)
    {
      OrgExInkStroke *s = g_ptr_array_index (strokes, i);
      guint n_points;
      const OrgExInkPoint *pts;

      g_string_append (out, "(s :t ");
      g_string_append (out, ink_tool_to_string (s->tool));
      g_string_append (out, " :c \"");
      /* Colours are simple hex strings; no escape needed in practice.
         Be conservative and escape `"` and `\\` regardless. */
      {
        const gchar *p;
        for (p = s->colour; p != NULL && *p; p++)
          {
            if (*p == '"' || *p == '\\')
              g_string_append_c (out, '\\');
            g_string_append_c (out, *p);
          }
      }
      g_string_append (out, "\" :w ");
      ink_append_width (out, s->base_width);
      g_string_append (out, " :p (");

      pts = org_ex_ink_stroke_get_points (s, &n_points);
      for (j = 0; j < n_points; j++)
        {
          gint p1000 = (gint) ((pts[j].pressure * 1000.0f) + 0.5f);
          if (p1000 < 0)    p1000 = 0;
          if (p1000 > 1000) p1000 = 1000;
          if (j > 0) g_string_append_c (out, ' ');
          g_string_append_printf (out, "(%d %d %d)",
                                  (gint) pts[j].x,
                                  (gint) pts[j].y,
                                  p1000);
        }

      g_string_append (out, "))\n");
    }

  return g_string_free (out, FALSE);
}
