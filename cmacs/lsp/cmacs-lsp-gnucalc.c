/* cmacs-lsp-gnucalc.c --- gnucalc language server for .calc sheets

Copyright (C) 2026 Zach Podbielniak

SPDX-License-Identifier: AGPL-3.0-or-later

This file is part of CMacs.  */

/* The `gnucalc' backend for `emacs --cmacs-lsp': completion, hover,
   signature help, definition, document symbols, semantic tokens and
   lexical diagnostics for `.calc' calculator sheets.

   The language surface -- all GNU Calc built-ins, every registered
   cmacs calculator (defcalc), the symbolic constants and Calc's units
   table -- comes from the GENERATED cmacs-lsp-gnucalc-data.h, emitted
   by admin/cmacs-calc-builtins-catalog.el from the same catalog and
   registry the Elisp side uses, so the two can never disagree.

   The line model mirrors cmacs-calculator-sheet.el (its defconsts at
   lisp/cmacs/cmacs-calculator-sheet.el:111): one expression per line;
   a line whose first non-blank char is `#' is a comment; a trailing
   " => RESULT" annotation (the sheet's ⇒ marker) is stripped before
   analysis; "NAME := EXPR" at the start of a line binds a sheet-local
   variable.  Diagnostics are deliberately LEXICAL ONLY (unbalanced
   delimiters, unknown call heads): the authoritative validator is the
   Elisp walker, which needs the Lisp VM this process never starts.
   Unknown call heads are warnings, not errors, and single-letter heads
   are exempt -- CAS usage legitimately writes `deriv(f(x), x)'.  */

#include <config.h>

#ifdef HAVE_CMACS_LSP_GNUCALC

#include "cmacs-lsp-gnucalc.h"
#include "cmacs-lsp-gnucalc-data.h"
#include "cmacs-lsp-server.h"
#include "cmacs-lsp-io.h"

#include <string.h>

/* The sheet's result-annotation marker, UTF-8 for ⇒ (U+21D2); keep in
   sync with `cmacs-calculator-sheet-result-marker'.  */
static const gchar GNUCALC_RESULT_MARKER[] = "\xe2\x87\x92";

/* ------------------------------------------------------------------ */
/* Lexing                                                             */
/* ------------------------------------------------------------------ */

static gboolean
ident_start_p (gchar c)
{
  return (c >= 'A' && c <= 'Z') || (c >= 'a' && c <= 'z') || c == '_';
}

static gboolean
ident_char_p (gchar c)
{
  return ident_start_p (c) || (c >= '0' && c <= '9');
}

static gboolean
digit_p (gchar c)
{
  return c >= '0' && c <= '9';
}

/* One analyzed line.  All offsets are BYTE offsets into the line.  */
typedef struct
{
  gboolean comment;       /* first non-blank char is '#' */
  guint code_end;         /* end of the expression text (annotation and
                             trailing blanks stripped) */
  gboolean has_assign;    /* "NAME := EXPR" line */
  guint name_start;       /* assignment NAME span */
  guint name_end;
} GnucalcLine;

/* Analyze LINE (NUL-terminated, no newline) into *INFO.  */

static void
analyze_line (const gchar *line, GnucalcLine *info)
{
  guint i;
  guint len = strlen (line);
  const gchar *marker;

  memset (info, 0, sizeof *info);

  /* Strip the " => RESULT" annotation tail.  */
  marker = strstr (line, GNUCALC_RESULT_MARKER);
  if (marker != NULL)
    len = marker - line;
  while (len > 0 && (line[len - 1] == ' ' || line[len - 1] == '\t'))
    len--;
  info->code_end = len;

  i = 0;
  while (i < len && (line[i] == ' ' || line[i] == '\t'))
    i++;

  if (i < len && line[i] == '#')
    {
      info->comment = TRUE;
      return;
    }

  /* "NAME := EXPR"?  Anchored to the line start, so a `:=' inside a
     rewrite rule never matches -- its head contains parens.  */
  if (i < len && ident_start_p (line[i]))
    {
      guint s = i;
      guint e = i;

      while (e < len && ident_char_p (line[e]))
        e++;
      i = e;
      while (i < len && (line[i] == ' ' || line[i] == '\t'))
        i++;
      if (i + 1 < len && line[i] == ':' && line[i + 1] == '=')
        {
          info->has_assign = TRUE;
          info->name_start = s;
          info->name_end = e;
        }
    }
}

typedef enum
{
  GNUCALC_TOK_IDENT,
  GNUCALC_TOK_NUMBER,
  GNUCALC_TOK_OTHER
} GnucalcTokenType;

typedef struct
{
  guint start;                  /* byte offsets into the line */
  guint end;
  GnucalcTokenType type;
  gboolean call_head;           /* identifier immediately before `(' */
} GnucalcToken;

/* Tokenize LINE between START and END (from analyze_line) into a
   GArray of GnucalcToken.  */

static GArray *
tokenize_line (const gchar *line, guint start, guint end)
{
  GArray *tokens = g_array_new (FALSE, FALSE, sizeof (GnucalcToken));
  guint i = start;

  while (i < end)
    {
      GnucalcToken tok;
      gchar c = line[i];

      if (c == ' ' || c == '\t')
        {
          i++;
          continue;
        }

      tok.start = i;
      tok.call_head = FALSE;

      if (ident_start_p (c))
        {
          while (i < end && ident_char_p (line[i]))
            i++;
          tok.end = i;
          tok.type = GNUCALC_TOK_IDENT;
          tok.call_head = (i < end && line[i] == '(');
        }
      else if (digit_p (c)
               || (c == '.' && i + 1 < end && digit_p (line[i + 1])))
        {
          /* Numbers, pragmatically: covers 2.5, 2.5e3 and 16#FF radix
             literals (only a LEADING `#' starts a comment).  */
          while (i < end
                 && (ident_char_p (line[i]) || line[i] == '.'
                     || line[i] == '#'))
            i++;
          tok.end = i;
          tok.type = GNUCALC_TOK_NUMBER;
        }
      else
        {
          if ((c == ':' && i + 1 < end && line[i + 1] == '=')
              || (c == ':' && i + 1 < end && line[i + 1] == ':'))
            i += 2;
          else
            i++;
          tok.end = i;
          tok.type = GNUCALC_TOK_OTHER;
        }

      g_array_append_val (tokens, tok);
    }

  return tokens;
}

/* ------------------------------------------------------------------ */
/* Data table lookup                                                  */
/* ------------------------------------------------------------------ */

static const CmacsLspGnucalcEntry *
find_entry_n (const gchar *name, gsize len)
{
  size_t i;

  for (i = 0; i < cmacs_lsp_gnucalc_n_entries; i++)
    {
      const CmacsLspGnucalcEntry *e = &cmacs_lsp_gnucalc_entries[i];

      if (strlen (e->name) == len && memcmp (e->name, name, len) == 0)
        return e;
    }
  return NULL;
}

static const gchar *
kind_label (CmacsLspGnucalcKind kind)
{
  switch (kind)
    {
    case CMACS_LSP_GNUCALC_BUILTIN:
      return "Calc built-in";
    case CMACS_LSP_GNUCALC_DEFCALC:
      return "cmacs calculator";
    case CMACS_LSP_GNUCALC_CONSTANT:
      return "constant";
    case CMACS_LSP_GNUCALC_UNIT:
      return "unit";
    default:
      return "";
    }
}

/* LSP CompletionItemKind.  */

static gint
completion_kind (CmacsLspGnucalcKind kind)
{
  switch (kind)
    {
    case CMACS_LSP_GNUCALC_BUILTIN:
    case CMACS_LSP_GNUCALC_DEFCALC:
      return 3;                 /* Function */
    case CMACS_LSP_GNUCALC_CONSTANT:
      return 21;                /* Constant */
    case CMACS_LSP_GNUCALC_UNIT:
      return 11;                /* Unit */
    default:
      return 1;                 /* Text */
    }
}

/* ------------------------------------------------------------------ */
/* Sheet-local variables ("NAME := EXPR" lines)                       */
/* ------------------------------------------------------------------ */

typedef struct
{
  gchar *name;
  guint line;
  guint name_start;             /* byte offsets */
  guint name_end;
} GnucalcSheetVar;

static void
sheet_var_clear (gpointer data)
{
  GnucalcSheetVar *var = data;

  g_free (var->name);
}

/* Collect the sheet's := bindings, in document order.  */

static GArray *
collect_sheet_vars (CmacsLspDocument *doc)
{
  GArray *vars = g_array_new (FALSE, FALSE, sizeof (GnucalcSheetVar));
  guint nlines = cmacs_lsp_document_nlines (doc);
  guint ln;

  g_array_set_clear_func (vars, sheet_var_clear);

  for (ln = 0; ln < nlines; ln++)
    {
      gchar *line = cmacs_lsp_document_line (doc, ln);
      GnucalcLine info;

      if (line == NULL)
        break;
      analyze_line (line, &info);
      if (info.has_assign)
        {
          GnucalcSheetVar var;

          var.name = g_strndup (line + info.name_start,
                                info.name_end - info.name_start);
          var.line = ln;
          var.name_start = info.name_start;
          var.name_end = info.name_end;
          g_array_append_val (vars, var);
        }
      g_free (line);
    }

  return vars;
}

static const GnucalcSheetVar *
find_sheet_var_n (GArray *vars, const gchar *name, gsize len)
{
  guint i;

  for (i = 0; i < vars->len; i++)
    {
      const GnucalcSheetVar *var =
        &g_array_index (vars, GnucalcSheetVar, i);

      if (strlen (var->name) == len && memcmp (var->name, name, len) == 0)
        return var;
    }
  return NULL;
}

/* ------------------------------------------------------------------ */
/* JSON helpers                                                       */
/* ------------------------------------------------------------------ */

/* Append a Range object member named "range" for LINE, byte columns
   [START_BYTE, END_BYTE) of LINE_TEXT (converted to UTF-16 here).  */

static void
add_range (JsonBuilder *b, const gchar *line_text, guint line,
           guint start_byte, guint end_byte)
{
  json_builder_set_member_name (b, "range");
  json_builder_begin_object (b);
  json_builder_set_member_name (b, "start");
  json_builder_begin_object (b);
  json_builder_set_member_name (b, "line");
  json_builder_add_int_value (b, line);
  json_builder_set_member_name (b, "character");
  json_builder_add_int_value
    (b, cmacs_lsp_byte_to_utf16 (line_text, start_byte));
  json_builder_end_object (b);
  json_builder_set_member_name (b, "end");
  json_builder_begin_object (b);
  json_builder_set_member_name (b, "line");
  json_builder_add_int_value (b, line);
  json_builder_set_member_name (b, "character");
  json_builder_add_int_value
    (b, cmacs_lsp_byte_to_utf16 (line_text, end_byte));
  json_builder_end_object (b);
  json_builder_end_object (b);
}

static void
add_markdown (JsonBuilder *b, const gchar *member, const gchar *value)
{
  json_builder_set_member_name (b, member);
  json_builder_begin_object (b);
  json_builder_set_member_name (b, "kind");
  json_builder_add_string_value (b, "markdown");
  json_builder_set_member_name (b, "value");
  json_builder_add_string_value (b, value);
  json_builder_end_object (b);
}

/* "name(args) — category" completion detail / hover header tail.  */

static gchar *
entry_detail_line (const CmacsLspGnucalcEntry *e)
{
  return g_strdup_printf ("%s%s \xe2\x80\x94 %s (%s)",
                          e->name, e->args != NULL ? e->args : "",
                          kind_label (e->kind), e->category);
}

/* The identifier around byte column COL of LINE, or FALSE.  */

static gboolean
identifier_at (const gchar *line, guint code_end, guint col,
               guint *start_out, guint *end_out)
{
  guint start;
  guint end;

  if (col > code_end)
    return FALSE;

  start = col;
  while (start > 0 && ident_char_p (line[start - 1]))
    start--;
  end = col;
  while (end < code_end && ident_char_p (line[end]))
    end++;

  if (start == end || !ident_start_p (line[start]))
    return FALSE;

  *start_out = start;
  *end_out = end;
  return TRUE;
}

/* ------------------------------------------------------------------ */
/* Capabilities                                                       */
/* ------------------------------------------------------------------ */

/* Semantic token type indices; must match the legend below.  */
enum
{
  GNUCALC_SEM_FUNCTION = 0,
  GNUCALC_SEM_VARIABLE,
  GNUCALC_SEM_CONSTANT,
  GNUCALC_SEM_NUMBER,
  GNUCALC_SEM_OPERATOR,
  GNUCALC_SEM_COMMENT
};

static void
gnucalc_init_capabilities (JsonBuilder *b)
{
  json_builder_set_member_name (b, "signatureHelpProvider");
  json_builder_begin_object (b);
  json_builder_set_member_name (b, "triggerCharacters");
  json_builder_begin_array (b);
  json_builder_add_string_value (b, "(");
  json_builder_add_string_value (b, ",");
  json_builder_end_array (b);
  json_builder_end_object (b);

  json_builder_set_member_name (b, "semanticTokensProvider");
  json_builder_begin_object (b);
  json_builder_set_member_name (b, "legend");
  json_builder_begin_object (b);
  json_builder_set_member_name (b, "tokenTypes");
  json_builder_begin_array (b);
  json_builder_add_string_value (b, "function");
  json_builder_add_string_value (b, "variable");
  json_builder_add_string_value (b, "constant");
  json_builder_add_string_value (b, "number");
  json_builder_add_string_value (b, "operator");
  json_builder_add_string_value (b, "comment");
  json_builder_end_array (b);
  json_builder_set_member_name (b, "tokenModifiers");
  json_builder_begin_array (b);
  json_builder_end_array (b);
  json_builder_end_object (b);  /* legend */
  json_builder_set_member_name (b, "full");
  json_builder_add_boolean_value (b, TRUE);
  json_builder_end_object (b);  /* semanticTokensProvider */
}

/* ------------------------------------------------------------------ */
/* completion                                                         */
/* ------------------------------------------------------------------ */

static void
gnucalc_completion (CmacsLspServer *server, CmacsLspDocument *doc,
                    guint line, guint col, gint64 id)
{
  gchar *text;
  guint byte_col;
  guint start;
  const gchar *prefix;
  gsize prefix_len;
  GnucalcLine info;
  GArray *vars;
  JsonBuilder *b;
  size_t i;
  guint v;

  (void) server;

  text = cmacs_lsp_document_line (doc, line);
  if (text == NULL)
    {
      cmacs_lsp_send_response (id, NULL);
      return;
    }

  analyze_line (text, &info);
  byte_col = cmacs_lsp_utf16_to_byte (text, col);
  if (byte_col > info.code_end)
    byte_col = info.code_end;

  start = byte_col;
  while (start > 0 && ident_char_p (text[start - 1]))
    start--;
  prefix = text + start;
  prefix_len = byte_col - start;

  vars = collect_sheet_vars (doc);

  b = json_builder_new ();
  json_builder_begin_array (b);

  for (i = 0; i < cmacs_lsp_gnucalc_n_entries; i++)
    {
      const CmacsLspGnucalcEntry *e = &cmacs_lsp_gnucalc_entries[i];

      if (strncmp (e->name, prefix, prefix_len) != 0)
        continue;

      json_builder_begin_object (b);
      json_builder_set_member_name (b, "label");
      json_builder_add_string_value (b, e->name);
      json_builder_set_member_name (b, "kind");
      json_builder_add_int_value (b, completion_kind (e->kind));
      {
        gchar *detail = entry_detail_line (e);

        json_builder_set_member_name (b, "detail");
        json_builder_add_string_value (b, detail);
        g_free (detail);
      }
      add_markdown (b, "documentation", e->detail);
      json_builder_end_object (b);
    }

  for (v = 0; v < vars->len; v++)
    {
      const GnucalcSheetVar *var = &g_array_index (vars, GnucalcSheetVar, v);

      if (strncmp (var->name, prefix, prefix_len) != 0)
        continue;

      json_builder_begin_object (b);
      json_builder_set_member_name (b, "label");
      json_builder_add_string_value (b, var->name);
      json_builder_set_member_name (b, "kind");
      json_builder_add_int_value (b, 6);        /* Variable */
      json_builder_set_member_name (b, "detail");
      {
        gchar *detail = g_strdup_printf ("sheet variable (line %u)",
                                         var->line + 1);

        json_builder_add_string_value (b, detail);
        g_free (detail);
      }
      json_builder_end_object (b);
    }

  json_builder_end_array (b);
  cmacs_lsp_send_response_builder (id, b);
  g_object_unref (b);
  g_array_unref (vars);
  g_free (text);
}

/* ------------------------------------------------------------------ */
/* hover                                                              */
/* ------------------------------------------------------------------ */

static void
gnucalc_hover (CmacsLspServer *server, CmacsLspDocument *doc,
               guint line, guint col, gint64 id)
{
  gchar *text;
  guint byte_col;
  guint start;
  guint end;
  GnucalcLine info;
  const CmacsLspGnucalcEntry *e;
  GArray *vars;
  const GnucalcSheetVar *var;
  gchar *value;
  JsonBuilder *b;

  (void) server;

  text = cmacs_lsp_document_line (doc, line);
  if (text == NULL)
    {
      cmacs_lsp_send_response (id, NULL);
      return;
    }

  analyze_line (text, &info);
  byte_col = cmacs_lsp_utf16_to_byte (text, col);
  if (info.comment
      || !identifier_at (text, info.code_end, byte_col, &start, &end))
    {
      cmacs_lsp_send_response (id, NULL);
      g_free (text);
      return;
    }

  value = NULL;
  vars = collect_sheet_vars (doc);
  var = find_sheet_var_n (vars, text + start, end - start);
  e = find_entry_n (text + start, end - start);

  /* A sheet binding shadows the table except for call heads --
     `rate := 0.05' does not hide the `rate(...)' of a data table.  */
  if (var != NULL && !(e != NULL && end < info.code_end
                       && text[end] == '('))
    {
      gchar *def = cmacs_lsp_document_line (doc, var->line);
      GnucalcLine dinfo;

      analyze_line (def, &dinfo);
      value = g_strdup_printf ("**%s** \xe2\x80\x94 sheet variable"
                               " (line %u)\n\n```\n%.*s\n```",
                               var->name, var->line + 1,
                               (int) dinfo.code_end, def);
      g_free (def);
    }
  else if (e != NULL)
    {
      gchar *head = entry_detail_line (e);

      value = g_strdup_printf ("**%s**  \n%s\n\n%s",
                               e->name, head, e->detail);
      g_free (head);
    }

  if (value == NULL)
    {
      cmacs_lsp_send_response (id, NULL);
      g_array_unref (vars);
      g_free (text);
      return;
    }

  b = json_builder_new ();
  json_builder_begin_object (b);
  add_markdown (b, "contents", value);
  add_range (b, text, line, start, end);
  json_builder_end_object (b);
  cmacs_lsp_send_response_builder (id, b);

  g_object_unref (b);
  g_free (value);
  g_array_unref (vars);
  g_free (text);
}

/* ------------------------------------------------------------------ */
/* signatureHelp                                                      */
/* ------------------------------------------------------------------ */

static void
gnucalc_signature_help (CmacsLspServer *server, CmacsLspDocument *doc,
                        guint line, guint col, gint64 id)
{
  gchar *text;
  guint byte_col;
  GnucalcLine info;
  gint i;
  guint depth;
  guint commas;
  gint open_paren;
  guint head_start;
  guint head_end;
  const CmacsLspGnucalcEntry *e;
  guint active;
  JsonBuilder *b;
  guint a;

  (void) server;

  text = cmacs_lsp_document_line (doc, line);
  if (text == NULL)
    {
      cmacs_lsp_send_response (id, NULL);
      return;
    }

  analyze_line (text, &info);
  byte_col = cmacs_lsp_utf16_to_byte (text, col);
  if (byte_col > info.code_end)
    byte_col = info.code_end;

  /* Scan left for the innermost unclosed `(', counting the commas at
     its depth.  An unclosed `[' on the way means the commas seen so
     far were vector elements, not arguments: discard and continue.  */
  depth = 0;
  commas = 0;
  open_paren = -1;
  for (i = (gint) byte_col - 1; i >= 0; i--)
    {
      gchar c = text[i];

      if (c == ')' || c == ']')
        depth++;
      else if (c == '(')
        {
          if (depth == 0)
            {
              open_paren = i;
              break;
            }
          depth--;
        }
      else if (c == '[')
        {
          if (depth == 0)
            commas = 0;
          else
            depth--;
        }
      else if (c == ',' && depth == 0)
        commas++;
    }

  if (open_paren <= 0
      || !identifier_at (text, (guint) open_paren, (guint) open_paren - 1,
                         &head_start, &head_end)
      || head_end != (guint) open_paren)
    {
      cmacs_lsp_send_response (id, NULL);
      g_free (text);
      return;
    }

  e = find_entry_n (text + head_start, head_end - head_start);
  if (e == NULL || e->args == NULL)
    {
      cmacs_lsp_send_response (id, NULL);
      g_free (text);
      return;
    }

  active = commas;
  if (e->n_args > 0 && active > e->n_args - 1)
    active = e->n_args - 1;

  b = json_builder_new ();
  json_builder_begin_object (b);
  json_builder_set_member_name (b, "signatures");
  json_builder_begin_array (b);
  json_builder_begin_object (b);
  {
    gchar *label = g_strdup_printf ("%s%s", e->name, e->args);

    json_builder_set_member_name (b, "label");
    json_builder_add_string_value (b, label);
    g_free (label);
  }
  add_markdown (b, "documentation", e->detail);
  json_builder_set_member_name (b, "parameters");
  json_builder_begin_array (b);
  for (a = 0; a < e->n_args; a++)
    {
      json_builder_begin_object (b);
      json_builder_set_member_name (b, "label");
      json_builder_add_string_value (b, e->arg_docs[a].name);
      json_builder_set_member_name (b, "documentation");
      json_builder_add_string_value (b, e->arg_docs[a].doc);
      json_builder_end_object (b);
    }
  json_builder_end_array (b);
  json_builder_end_object (b);
  json_builder_end_array (b);
  json_builder_set_member_name (b, "activeSignature");
  json_builder_add_int_value (b, 0);
  json_builder_set_member_name (b, "activeParameter");
  json_builder_add_int_value (b, active);
  json_builder_end_object (b);
  cmacs_lsp_send_response_builder (id, b);

  g_object_unref (b);
  g_free (text);
}

/* ------------------------------------------------------------------ */
/* definition                                                         */
/* ------------------------------------------------------------------ */

static void
gnucalc_definition (CmacsLspServer *server, CmacsLspDocument *doc,
                    guint line, guint col, gint64 id)
{
  gchar *text;
  guint byte_col;
  guint start;
  guint end;
  GnucalcLine info;
  GArray *vars;
  const GnucalcSheetVar *var;

  (void) server;

  text = cmacs_lsp_document_line (doc, line);
  if (text == NULL)
    {
      cmacs_lsp_send_response (id, NULL);
      return;
    }

  analyze_line (text, &info);
  byte_col = cmacs_lsp_utf16_to_byte (text, col);
  if (info.comment
      || !identifier_at (text, info.code_end, byte_col, &start, &end))
    {
      cmacs_lsp_send_response (id, NULL);
      g_free (text);
      return;
    }

  vars = collect_sheet_vars (doc);
  var = find_sheet_var_n (vars, text + start, end - start);

  if (var == NULL)
    cmacs_lsp_send_response (id, NULL);
  else
    {
      gchar *def = cmacs_lsp_document_line (doc, var->line);
      JsonBuilder *b = json_builder_new ();

      json_builder_begin_object (b);
      json_builder_set_member_name (b, "uri");
      json_builder_add_string_value (b, doc->uri);
      add_range (b, def, var->line, var->name_start, var->name_end);
      json_builder_end_object (b);
      cmacs_lsp_send_response_builder (id, b);
      g_object_unref (b);
      g_free (def);
    }

  g_array_unref (vars);
  g_free (text);
}

/* ------------------------------------------------------------------ */
/* documentSymbol                                                     */
/* ------------------------------------------------------------------ */

static void
gnucalc_document_symbol (CmacsLspServer *server, CmacsLspDocument *doc,
                         gint64 id)
{
  GArray *vars;
  JsonBuilder *b;
  guint v;

  (void) server;

  vars = collect_sheet_vars (doc);
  b = json_builder_new ();
  json_builder_begin_array (b);

  for (v = 0; v < vars->len; v++)
    {
      const GnucalcSheetVar *var = &g_array_index (vars, GnucalcSheetVar, v);
      gchar *def = cmacs_lsp_document_line (doc, var->line);
      GnucalcLine info;

      analyze_line (def, &info);
      json_builder_begin_object (b);
      json_builder_set_member_name (b, "name");
      json_builder_add_string_value (b, var->name);
      json_builder_set_member_name (b, "kind");
      json_builder_add_int_value (b, 13);       /* Variable */
      json_builder_set_member_name (b, "location");
      json_builder_begin_object (b);
      json_builder_set_member_name (b, "uri");
      json_builder_add_string_value (b, doc->uri);
      add_range (b, def, var->line, 0, info.code_end);
      json_builder_end_object (b);
      json_builder_end_object (b);
      g_free (def);
    }

  json_builder_end_array (b);
  cmacs_lsp_send_response_builder (id, b);
  g_object_unref (b);
  g_array_unref (vars);
}

/* ------------------------------------------------------------------ */
/* semanticTokens/full                                                */
/* ------------------------------------------------------------------ */

static void
gnucalc_semantic_tokens (CmacsLspServer *server, CmacsLspDocument *doc,
                         gint64 id)
{
  JsonBuilder *b;
  guint nlines;
  guint ln;
  guint prev_line;
  guint prev_start;

  (void) server;

  b = json_builder_new ();
  json_builder_begin_object (b);
  json_builder_set_member_name (b, "data");
  json_builder_begin_array (b);

  nlines = cmacs_lsp_document_nlines (doc);
  prev_line = 0;
  prev_start = 0;

  for (ln = 0; ln < nlines; ln++)
    {
      gchar *text = cmacs_lsp_document_line (doc, ln);
      GnucalcLine info;
      guint line_len;

      if (text == NULL)
        break;
      line_len = strlen (text);
      analyze_line (text, &info);

      /* Emit one token: LINE/START/LEN in UTF-16, delta-encoded.  */
#define EMIT_TOKEN(START_BYTE, END_BYTE, TYPE)                          \
      do                                                                \
        {                                                               \
          guint tu_start = cmacs_lsp_byte_to_utf16 (text, (START_BYTE)); \
          guint tu_end = cmacs_lsp_byte_to_utf16 (text, (END_BYTE));    \
          guint delta_line = ln - prev_line;                            \
          guint delta_start = delta_line ? tu_start                     \
            : tu_start - prev_start;                                    \
          json_builder_add_int_value (b, delta_line);                   \
          json_builder_add_int_value (b, delta_start);                  \
          json_builder_add_int_value (b, tu_end - tu_start);            \
          json_builder_add_int_value (b, (TYPE));                       \
          json_builder_add_int_value (b, 0);                            \
          prev_line = ln;                                               \
          prev_start = tu_start;                                        \
        }                                                               \
      while (0)

      if (info.comment)
        {
          if (line_len > 0)
            EMIT_TOKEN (0, line_len, GNUCALC_SEM_COMMENT);
        }
      else
        {
          GArray *tokens = tokenize_line (text, 0, info.code_end);
          guint t;

          for (t = 0; t < tokens->len; t++)
            {
              const GnucalcToken *tok =
                &g_array_index (tokens, GnucalcToken, t);

              switch (tok->type)
                {
                case GNUCALC_TOK_IDENT:
                  {
                    const CmacsLspGnucalcEntry *e =
                      find_entry_n (text + tok->start,
                                    tok->end - tok->start);
                    guint type = GNUCALC_SEM_VARIABLE;

                    if (tok->call_head
                        || (e != NULL
                            && (e->kind == CMACS_LSP_GNUCALC_BUILTIN
                                || e->kind == CMACS_LSP_GNUCALC_DEFCALC)))
                      type = GNUCALC_SEM_FUNCTION;
                    else if (e != NULL
                             && e->kind == CMACS_LSP_GNUCALC_CONSTANT)
                      type = GNUCALC_SEM_CONSTANT;
                    EMIT_TOKEN (tok->start, tok->end, type);
                  }
                  break;
                case GNUCALC_TOK_NUMBER:
                  EMIT_TOKEN (tok->start, tok->end, GNUCALC_SEM_NUMBER);
                  break;
                case GNUCALC_TOK_OTHER:
                  EMIT_TOKEN (tok->start, tok->end, GNUCALC_SEM_OPERATOR);
                  break;
                }
            }
          g_array_unref (tokens);

          /* The stripped " => RESULT" annotation renders as comment.  */
          if (info.code_end < line_len)
            {
              guint s = info.code_end;

              while (s < line_len && (text[s] == ' ' || text[s] == '\t'))
                s++;
              if (s < line_len)
                EMIT_TOKEN (s, line_len, GNUCALC_SEM_COMMENT);
            }
        }
#undef EMIT_TOKEN

      g_free (text);
    }

  json_builder_end_array (b);
  json_builder_end_object (b);
  cmacs_lsp_send_response_builder (id, b);
  g_object_unref (b);
}

/* ------------------------------------------------------------------ */
/* diagnostics                                                        */
/* ------------------------------------------------------------------ */

/* Append one Diagnostic object to the open array in B.  */

static void
add_diagnostic (JsonBuilder *b, const gchar *line_text, guint line,
                guint start_byte, guint end_byte, gint severity,
                const gchar *code, const gchar *message)
{
  json_builder_begin_object (b);
  add_range (b, line_text, line, start_byte, end_byte);
  json_builder_set_member_name (b, "severity");
  json_builder_add_int_value (b, severity);
  json_builder_set_member_name (b, "code");
  json_builder_add_string_value (b, code);
  json_builder_set_member_name (b, "source");
  json_builder_add_string_value (b, "cmacs-lsp-gnucalc");
  json_builder_set_member_name (b, "message");
  json_builder_add_string_value (b, message);
  json_builder_end_object (b);
}

static void
gnucalc_diagnose (CmacsLspServer *server, CmacsLspDocument *doc)
{
  JsonBuilder *b;
  JsonNode *params;
  GArray *vars;
  guint nlines;
  guint ln;

  (void) server;

  vars = collect_sheet_vars (doc);

  b = json_builder_new ();
  json_builder_begin_object (b);
  json_builder_set_member_name (b, "uri");
  json_builder_add_string_value (b, doc->uri);
  json_builder_set_member_name (b, "version");
  json_builder_add_int_value (b, doc->version);
  json_builder_set_member_name (b, "diagnostics");
  json_builder_begin_array (b);

  nlines = cmacs_lsp_document_nlines (doc);
  for (ln = 0; ln < nlines; ln++)
    {
      gchar *text = cmacs_lsp_document_line (doc, ln);
      GnucalcLine info;
      GArray *tokens;
      guint t;
      guint stack[64];
      guint depth;
      gboolean delim_error;

      if (text == NULL)
        break;
      analyze_line (text, &info);
      if (info.comment || info.code_end == 0)
        {
          g_free (text);
          continue;
        }

      /* One expression per line, so per-line delimiter balance is
         exact.  STACK holds the byte offsets of open delimiters.  */
      depth = 0;
      delim_error = FALSE;
      for (t = 0; t < info.code_end && !delim_error; t++)
        {
          gchar c = text[t];

          if (c == '(' || c == '[')
            {
              if (depth < G_N_ELEMENTS (stack))
                stack[depth] = t;
              depth++;
            }
          else if (c == ')' || c == ']')
            {
              gchar want = (c == ')') ? '(' : '[';

              if (depth == 0
                  || (depth <= G_N_ELEMENTS (stack)
                      && text[stack[depth - 1]] != want))
                {
                  add_diagnostic (b, text, ln, t, t + 1, 1,
                                  "unbalanced-delimiter",
                                  (c == ')')
                                  ? "Unmatched `)'"
                                  : "Unmatched `]'");
                  delim_error = TRUE;
                }
              else
                depth--;
            }
        }
      if (!delim_error && depth > 0)
        {
          guint at = stack[depth <= G_N_ELEMENTS (stack)
                           ? depth - 1 : G_N_ELEMENTS (stack) - 1];

          add_diagnostic (b, text, ln, at, at + 1, 1,
                          "unbalanced-delimiter",
                          (text[at] == '(')
                          ? "Unclosed `('" : "Unclosed `['");
          delim_error = TRUE;
        }

      /* Unknown call heads.  Single-letter heads are exempt (symbolic
         `f(x)'), and a sheet := binding counts as known.  */
      tokens = tokenize_line (text, 0, info.code_end);
      for (t = 0; t < tokens->len; t++)
        {
          const GnucalcToken *tok = &g_array_index (tokens, GnucalcToken, t);
          gsize len;

          if (tok->type != GNUCALC_TOK_IDENT || !tok->call_head)
            continue;
          len = tok->end - tok->start;
          if (len <= 1)
            continue;
          if (find_entry_n (text + tok->start, len) != NULL)
            continue;
          if (find_sheet_var_n (vars, text + tok->start, len) != NULL)
            continue;
          {
            gchar *name = g_strndup (text + tok->start, len);
            gchar *msg = g_strdup_printf
              ("Unknown function `%s' (not a Calc built-in, cmacs"
               " calculator, or sheet definition)", name);

            add_diagnostic (b, text, ln, tok->start, tok->end, 2,
                            "unknown-function", msg);
            g_free (msg);
            g_free (name);
          }
        }
      g_array_unref (tokens);
      g_free (text);
    }

  json_builder_end_array (b);
  json_builder_end_object (b);

  params = json_builder_get_root (b);
  cmacs_lsp_send_notification ("textDocument/publishDiagnostics", params);
  json_node_unref (params);
  g_object_unref (b);
  g_array_unref (vars);
}

/* ------------------------------------------------------------------ */
/* Entry point                                                        */
/* ------------------------------------------------------------------ */

static const CmacsLspServerOps gnucalc_ops =
{
  "cmacs-lsp-gnucalc",          /* server_name */
  "0.1.0",                      /* server_version */
  gnucalc_init_capabilities,
  gnucalc_completion,
  gnucalc_hover,
  gnucalc_signature_help,
  gnucalc_definition,
  gnucalc_document_symbol,
  gnucalc_semantic_tokens,
  gnucalc_diagnose
};

int
cmacs_lsp_gnucalc_run (int argc, char **argv)
{
  CmacsLspServer *server;
  int status;

  (void) argc;
  (void) argv;

  server = cmacs_lsp_server_new (&gnucalc_ops);
  status = cmacs_lsp_server_run (server);
  cmacs_lsp_server_free (server);
  return status;
}

#endif /* HAVE_CMACS_LSP_GNUCALC */
