/* cmacs-office-sheet.c --- spreadsheet cell extraction.
 *
 * Copyright (C) 2026 Zach Podbielniak
 * SPDX-License-Identifier: AGPL-3.0-or-later
 *
 * See cmacs-office-sheet.h for the Phase 2 DOM limitation and why
 * empty cells are dropped rather than emitted. */

#include <config.h>

#ifdef HAVE_CMACS_OFFICE

#include "cmacs-office-sheet.h"
#include "cmacs-office-xml.h"

#include <stdlib.h>
#include <string.h>

#define NS_S \
  "http://schemas.openxmlformats.org/spreadsheetml/2006/main"
#define NS_ODF_OFFICE "urn:oasis:names:tc:opendocument:xmlns:office:1.0"
#define NS_ODF_TABLE  "urn:oasis:names:tc:opendocument:xmlns:table:1.0"

#define REL_WORKSHEET_SUFFIX     "/worksheet"
#define REL_SHARED_STRINGS_SUFFIX "/sharedStrings"

void
cmacs_office_cell_free (CmacsOfficeCell *cell)
{
  if (cell == NULL)
    return;
  g_free (cell->sheet);
  g_free (cell->ref);
  g_free (cell->text);
  g_free (cell->formula);
  g_free (cell);
}

/* ------------------------------------------------------------------ */
/* Addresses                                                           */
/* ------------------------------------------------------------------ */

/* Spreadsheet columns are bijective base-26: A..Z, AA..AZ, BA.., so
   there is no zero digit and the usual base conversion is off by one
   at every carry. */
gchar *
cmacs_office_sheet_ref (gint row, gint col)
{
  gchar buf[16];
  gint i = (gint) sizeof buf - 1;

  if (row < 1 || col < 1)
    return NULL;

  buf[i] = '\0';
  while (col > 0 && i > 0)
    {
      gint rem = (col - 1) % 26;

      buf[--i] = (gchar) ('A' + rem);
      col = (col - 1) / 26;
    }

  return g_strdup_printf ("%s%d", buf + i, row);
}

gboolean
cmacs_office_sheet_parse (const gchar *ref, gint *row, gint *col)
{
  gint c = 0;
  gint r = 0;
  const gchar *p = ref;

  if (ref == NULL || *ref == '\0')
    return FALSE;

  /* Absolute references ("$A$1") appear in formulas; tolerate them. */
  while (*p != '\0' && (g_ascii_isalpha (*p) || *p == '$'))
    {
      if (*p != '$')
        c = c * 26 + (g_ascii_toupper (*p) - 'A' + 1);
      p++;
    }
  while (*p != '\0' && (g_ascii_isdigit (*p) || *p == '$'))
    {
      if (*p != '$')
        r = r * 10 + (*p - '0');
      p++;
    }

  if (*p != '\0' || c < 1 || r < 1)
    return FALSE;

  if (row != NULL) *row = r;
  if (col != NULL) *col = c;
  return TRUE;
}

/* ------------------------------------------------------------------ */
/* Shared helpers                                                      */
/* ------------------------------------------------------------------ */

static xmlDoc *
read_xml_capped (CmacsOfficePackage *pkg, const gchar *part, GError **error)
{
  CmacsOfficeZip *zip = cmacs_office_package_zip (pkg);
  guint64 size = 0;
  guint8 *bytes;
  gsize len = 0;
  xmlDoc *doc;

  /* Consulting the declared size first costs no decompression, which
     is the whole point: refuse the enormous sheet before inflating it
     rather than after. */
  if (cmacs_office_zip_part_size (zip, part, &size, NULL)
      && size > CMACS_OFFICE_SHEET_MAX_DOM)
    {
      g_set_error (error, CMACS_OFFICE_ZIP_ERROR,
                   CMACS_OFFICE_ZIP_ERROR_TOO_LARGE,
                   "%s is %" G_GUINT64_FORMAT " bytes, past the %"
                   G_GUINT64_FORMAT " byte limit this reader parses in "
                   "memory; streaming support for sheets this large is "
                   "not implemented yet", part, size,
                   CMACS_OFFICE_SHEET_MAX_DOM);
      return NULL;
    }

  bytes = cmacs_office_zip_read_part (zip, part, &len, error);
  if (bytes == NULL)
    return NULL;

  doc = cmacs_office_xml_parse (bytes, len, part, error);
  g_free (bytes);
  return doc;
}

static gint
attr_int (xmlNode *n, const gchar *name, gint dflt)
{
  gchar *v = cmacs_office_xml_attr (n, name);
  gint out = dflt;

  if (v != NULL && *v != '\0')
    out = (gint) g_ascii_strtoll (v, NULL, 10);
  g_free (v);
  return out;
}

static void
add_cell (GPtrArray *out, const gchar *sheet, gint row, gint col,
          gchar *text, gchar *formula)
{
  CmacsOfficeCell *c;

  /* Nothing to say about a blank cell, and saying it a million times
     is how a ten-cell sheet becomes unusable. */
  if ((text == NULL || *text == '\0') && formula == NULL)
    {
      g_free (text);
      return;
    }

  c = g_new0 (CmacsOfficeCell, 1);
  c->sheet = g_strdup (sheet);
  c->row = row;
  c->col = col;
  c->ref = cmacs_office_sheet_ref (row, col);
  c->text = text ? text : g_strdup ("");
  c->formula = formula;
  g_ptr_array_add (out, c);
}

/* ------------------------------------------------------------------ */
/* OOXML: .xlsx                                                        */
/* ------------------------------------------------------------------ */

/* The workbook names its sheets and points at them by relationship id;
   the parts themselves may be called anything. */
static GPtrArray *
xlsx_sheets (CmacsOfficePackage *pkg, GPtrArray **parts_out, GError **error)
{
  const gchar *main_part = cmacs_office_package_main_part (pkg);
  GPtrArray *names = g_ptr_array_new_with_free_func (g_free);
  GPtrArray *parts = g_ptr_array_new_with_free_func (g_free);
  GPtrArray *rels;
  GHashTable *by_id;
  xmlDoc *doc;
  xmlNode *sheets, *n;
  guint i;

  if (main_part == NULL)
    goto done;

  rels = cmacs_office_package_rels (pkg, main_part, error);
  if (rels == NULL)
    {
      g_ptr_array_unref (names);
      g_ptr_array_unref (parts);
      return NULL;
    }

  by_id = g_hash_table_new (g_str_hash, g_str_equal);
  for (i = 0; i < rels->len; i++)
    {
      CmacsOfficeRel *r = g_ptr_array_index (rels, i);

      if (r->id != NULL && r->target != NULL && !r->external
          && r->type != NULL
          && g_str_has_suffix (r->type, REL_WORKSHEET_SUFFIX))
        g_hash_table_insert (by_id, r->id, r->target);
    }

  doc = read_xml_capped (pkg, main_part, error);
  if (doc == NULL)
    {
      g_hash_table_destroy (by_id);
      g_ptr_array_unref (rels);
      g_ptr_array_unref (names);
      g_ptr_array_unref (parts);
      return NULL;
    }

  sheets = cmacs_office_xml_child (cmacs_office_xml_root (doc), "sheets", NS_S);
  for (n = cmacs_office_xml_first (sheets, "sheet", NS_S);
       n != NULL;
       n = cmacs_office_xml_next (n, "sheet", NS_S))
    {
      /* Namespace-qualified for the same reason as slides: relying on
         <sheet> happening to spell its own id `sheetId' would be luck,
         not correctness. */
      gchar *rid = cmacs_office_xml_attr_ns (n, "id",
                                             CMACS_OFFICE_NS_DOC_RELATIONSHIPS);
      gchar *name = cmacs_office_xml_attr (n, "name");
      const gchar *target = rid ? g_hash_table_lookup (by_id, rid) : NULL;

      if (target != NULL)
        {
          g_ptr_array_add (names, name ? name : g_strdup (""));
          g_ptr_array_add (parts, g_strdup (target));
        }
      else
        g_free (name);
      g_free (rid);
    }

  xmlFreeDoc (doc);
  g_hash_table_destroy (by_id);
  g_ptr_array_unref (rels);

 done:
  *parts_out = parts;
  return names;
}

/* The string pool.  Indices in cells refer into this by position. */
static GPtrArray *
xlsx_shared_strings (CmacsOfficePackage *pkg)
{
  GPtrArray *out = g_ptr_array_new_with_free_func (g_free);
  const gchar *main_part = cmacs_office_package_main_part (pkg);
  GPtrArray *rels;
  gchar *part = NULL;
  xmlDoc *doc;
  xmlNode *n;
  guint i;

  if (main_part == NULL)
    return out;

  rels = cmacs_office_package_rels (pkg, main_part, NULL);
  if (rels == NULL)
    return out;

  for (i = 0; i < rels->len && part == NULL; i++)
    {
      CmacsOfficeRel *r = g_ptr_array_index (rels, i);

      if (r->type != NULL && !r->external
          && g_str_has_suffix (r->type, REL_SHARED_STRINGS_SUFFIX))
        part = g_strdup (r->target);
    }
  g_ptr_array_unref (rels);

  if (part == NULL)
    return out;                 /* a workbook may have no strings at all */

  doc = read_xml_capped (pkg, part, NULL);
  g_free (part);
  if (doc == NULL)
    return out;

  for (n = cmacs_office_xml_first (cmacs_office_xml_root (doc), "si", NS_S);
       n != NULL;
       n = cmacs_office_xml_next (n, "si", NS_S))
    g_ptr_array_add (out, cmacs_office_xml_text (n));

  xmlFreeDoc (doc);
  return out;
}

static void
xlsx_cells (CmacsOfficePackage *pkg, const gchar *sheet, const gchar *part,
            GPtrArray *strings, GPtrArray *out)
{
  xmlDoc *doc = read_xml_capped (pkg, part, NULL);
  xmlNode *data, *row;
  gint row_no = 0;

  if (doc == NULL)
    return;

  data = cmacs_office_xml_child (cmacs_office_xml_root (doc),
                                 "sheetData", NS_S);

  for (row = cmacs_office_xml_first (data, "row", NS_S);
       row != NULL;
       row = cmacs_office_xml_next (row, "row", NS_S))
    {
      xmlNode *c;
      gint col_no = 0;

      row_no = attr_int (row, "r", row_no + 1);

      for (c = cmacs_office_xml_first (row, "c", NS_S);
           c != NULL;
           c = cmacs_office_xml_next (c, "c", NS_S))
        {
          gchar *ref = cmacs_office_xml_attr (c, "r");
          gchar *type = cmacs_office_xml_attr (c, "t");
          xmlNode *f = cmacs_office_xml_child (c, "f", NS_S);
          xmlNode *v = cmacs_office_xml_child (c, "v", NS_S);
          gchar *text = NULL;
          gchar *formula = NULL;
          gint r = row_no;

          /* The address is authoritative when present; sparse rows omit
             cells entirely, so counting position would drift. */
          if (ref == NULL || !cmacs_office_sheet_parse (ref, &r, &col_no))
            col_no++;
          else
            row_no = r;

          if (f != NULL)
            {
              formula = cmacs_office_xml_text (f);
              if (*formula == '\0')
                g_clear_pointer (&formula, g_free);
            }

          if (g_strcmp0 (type, "s") == 0 && v != NULL)
            {
              gchar *idx = cmacs_office_xml_text (v);
              gint64 i = g_ascii_strtoll (idx, NULL, 10);

              if (i >= 0 && i < (gint64) strings->len)
                text = g_strdup (g_ptr_array_index (strings, (guint) i));
              g_free (idx);
            }
          else if (g_strcmp0 (type, "inlineStr") == 0)
            {
              xmlNode *is = cmacs_office_xml_child (c, "is", NS_S);

              text = cmacs_office_xml_text (is);
            }
          else if (v != NULL)
            text = cmacs_office_xml_text (v);

          add_cell (out, sheet, row_no, col_no, text, formula);

          g_free (ref);
          g_free (type);
        }
    }

  xmlFreeDoc (doc);
}

/* ------------------------------------------------------------------ */
/* OpenDocument: .ods                                                  */
/* ------------------------------------------------------------------ */

static gint
clamp_repeat (gint n)
{
  if (n < 1)
    return 1;
  if (n > CMACS_OFFICE_SHEET_MAX_REPEAT)
    return CMACS_OFFICE_SHEET_MAX_REPEAT;
  return n;
}

static void
ods_table (xmlNode *table, GPtrArray *out)
{
  gchar *sheet = cmacs_office_xml_attr (table, "name");
  xmlNode *row;
  gint row_no = 0;

  for (row = cmacs_office_xml_first (table, "table-row", NS_ODF_TABLE);
       row != NULL;
       row = cmacs_office_xml_next (row, "table-row", NS_ODF_TABLE))
    {
      gint row_rep = attr_int (row, "number-rows-repeated", 1);
      xmlNode *cell;
      gint col_no;
      gint rr;

      /* A repeated EMPTY row is padding and expanding it would be
         millions of nothing; a repeated row with content is real and
         is expanded, up to the cap. */
      row_rep = clamp_repeat (row_rep);

      for (rr = 0; rr < row_rep; rr++)
        {
          gboolean any = FALSE;

          row_no++;
          col_no = 0;

          for (cell = cmacs_office_xml_first (row, "table-cell", NS_ODF_TABLE);
               cell != NULL;
               cell = cmacs_office_xml_next (cell, "table-cell", NS_ODF_TABLE))
            {
              gint rep = clamp_repeat (attr_int (cell, "number-columns-repeated", 1));
              gchar *text = cmacs_office_xml_text (cell);
              gchar *formula = cmacs_office_xml_attr (cell, "formula");
              gint k;

              g_strchomp (text);

              if (*text == '\0' && formula == NULL)
                {
                  /* Padding: advance the column and emit nothing. */
                  col_no += rep;
                  g_free (text);
                  continue;
                }

              any = TRUE;
              for (k = 0; k < rep; k++)
                {
                  col_no++;
                  add_cell (out, sheet, row_no, col_no,
                            g_strdup (text),
                            formula ? g_strdup (formula) : NULL);
                }
              g_free (text);
              g_free (formula);
            }

          /* Repeating an entirely empty row any further is pointless. */
          if (!any)
            {
              row_no += row_rep - rr - 1;
              break;
            }
        }
    }

  g_free (sheet);
}

static gboolean
extract_ods (CmacsOfficePackage *pkg, GPtrArray *out, GError **error)
{
  const gchar *part = cmacs_office_package_main_part (pkg);
  xmlDoc *doc;
  xmlNode *body, *sp, *table;

  if (part == NULL)
    return TRUE;

  doc = read_xml_capped (pkg, part, error);
  if (doc == NULL)
    return FALSE;

  body = cmacs_office_xml_child (cmacs_office_xml_root (doc),
                                 "body", NS_ODF_OFFICE);
  sp = cmacs_office_xml_child (body, "spreadsheet", NS_ODF_OFFICE);

  for (table = cmacs_office_xml_first (sp, "table", NS_ODF_TABLE);
       table != NULL;
       table = cmacs_office_xml_next (table, "table", NS_ODF_TABLE))
    ods_table (table, out);

  xmlFreeDoc (doc);
  return TRUE;
}

/* ------------------------------------------------------------------ */
/* Entry points                                                        */
/* ------------------------------------------------------------------ */

GPtrArray *
cmacs_office_sheet_names (CmacsOfficePackage *pkg, GError **error)
{
  g_return_val_if_fail (pkg != NULL, NULL);

  if (cmacs_office_package_kind (pkg) != CMACS_OFFICE_KIND_SHEET)
    return g_ptr_array_new_with_free_func (g_free);

  if (cmacs_office_package_family (pkg) == CMACS_OFFICE_FAMILY_ODF)
    {
      GPtrArray *out = g_ptr_array_new_with_free_func (g_free);
      const gchar *part = cmacs_office_package_main_part (pkg);
      xmlDoc *doc;
      xmlNode *body, *sp, *table;

      if (part == NULL)
        return out;

      doc = read_xml_capped (pkg, part, error);
      if (doc == NULL)
        {
          g_ptr_array_unref (out);
          return NULL;
        }

      body = cmacs_office_xml_child (cmacs_office_xml_root (doc),
                                     "body", NS_ODF_OFFICE);
      sp = cmacs_office_xml_child (body, "spreadsheet", NS_ODF_OFFICE);
      for (table = cmacs_office_xml_first (sp, "table", NS_ODF_TABLE);
           table != NULL;
           table = cmacs_office_xml_next (table, "table", NS_ODF_TABLE))
        {
          gchar *name = cmacs_office_xml_attr (table, "name");

          g_ptr_array_add (out, name ? name : g_strdup (""));
        }

      xmlFreeDoc (doc);
      return out;
    }
  else
    {
      GPtrArray *parts = NULL;
      GPtrArray *names = xlsx_sheets (pkg, &parts, error);

      g_clear_pointer (&parts, g_ptr_array_unref);
      return names;
    }
}

gchar *
cmacs_office_sheet_part (CmacsOfficePackage *pkg, const gchar *sheet,
                         GError **error)
{
  GPtrArray *names, *parts = NULL;
  gchar *out = NULL;
  guint i;

  g_return_val_if_fail (pkg != NULL, NULL);

  if (cmacs_office_package_kind (pkg) != CMACS_OFFICE_KIND_SHEET)
    return NULL;

  /* Every ODF sheet is a table inside the one content.xml. */
  if (cmacs_office_package_family (pkg) == CMACS_OFFICE_FAMILY_ODF)
    return g_strdup (cmacs_office_package_main_part (pkg));

  names = xlsx_sheets (pkg, &parts, error);
  if (names == NULL)
    return NULL;

  for (i = 0; i < names->len && i < parts->len; i++)
    if (sheet == NULL
        || g_strcmp0 (sheet, g_ptr_array_index (names, i)) == 0)
      {
        out = g_strdup (g_ptr_array_index (parts, i));
        break;
      }

  g_ptr_array_unref (names);
  g_ptr_array_unref (parts);
  return out;
}

GPtrArray *
cmacs_office_sheet_cells (CmacsOfficePackage *pkg, GError **error)
{
  GPtrArray *out;

  g_return_val_if_fail (pkg != NULL, NULL);

  out = g_ptr_array_new_with_free_func ((GDestroyNotify) cmacs_office_cell_free);

  if (cmacs_office_package_kind (pkg) != CMACS_OFFICE_KIND_SHEET)
    return out;

  if (cmacs_office_package_family (pkg) == CMACS_OFFICE_FAMILY_ODF)
    {
      if (!extract_ods (pkg, out, error))
        {
          g_ptr_array_unref (out);
          return NULL;
        }
    }
  else
    {
      GPtrArray *parts = NULL;
      GPtrArray *names;
      GPtrArray *strings;
      guint i;

      names = xlsx_sheets (pkg, &parts, error);
      if (names == NULL)
        {
          g_ptr_array_unref (out);
          return NULL;
        }

      strings = xlsx_shared_strings (pkg);
      for (i = 0; i < names->len && i < parts->len; i++)
        xlsx_cells (pkg, g_ptr_array_index (names, i),
                    g_ptr_array_index (parts, i), strings, out);

      g_ptr_array_unref (strings);
      g_ptr_array_unref (names);
      g_ptr_array_unref (parts);
    }

  return out;
}

#endif /* HAVE_CMACS_OFFICE */
