/* cmacs-office-sheet-edit.c --- writing one cell back into a sheet.
 *
 * Copyright (C) 2026 Zach Podbielniak
 * SPDX-License-Identifier: AGPL-3.0-or-later
 *
 * The write half of the spreadsheet model.  See cmacs-office-sheet.h
 * for why the edit is surgical rather than a regeneration.
 *
 * The hard part is not writing the value; it is FINDING the cell.
 * Neither format stores a dense grid:
 *
 *   OOXML  rows and cells are sparse and carry their own addresses, so
 *          a missing one has to be inserted in the right position for
 *          the file to stay ordered.
 *
 *   ODF    rows and cells are RUN-LENGTH ENCODED.  One <table-cell>
 *          with number-columns-repeated="500" is five hundred cells,
 *          and editing the third of them means splitting that run into
 *          three -- two before, the edited one, the rest after.  Get
 *          this wrong and every column to the right shifts.
 *
 * Only the sheet's own part is touched; the rest of the package is
 * never even read. */

#include <config.h>

#ifdef HAVE_CMACS_OFFICE

#include "cmacs-office-sheet.h"
#include "cmacs-office-xml.h"

#include <libxml/parser.h>
#include <string.h>

#define NS_S \
  "http://schemas.openxmlformats.org/spreadsheetml/2006/main"
#define NS_ODF_OFFICE "urn:oasis:names:tc:opendocument:xmlns:office:1.0"
#define NS_ODF_TABLE  "urn:oasis:names:tc:opendocument:xmlns:table:1.0"
#define NS_ODF_TEXT   "urn:oasis:names:tc:opendocument:xmlns:text:1.0"

/* ------------------------------------------------------------------ */
/* Shared                                                              */
/* ------------------------------------------------------------------ */

/* Does TEXT look like a number to a spreadsheet?  This decides whether
   the value is stored as a number or as text, which is the difference
   between a cell that sums and one that does not. */
static gboolean
looks_numeric (const gchar *text)
{
  gchar *end = NULL;

  if (text == NULL || *text == '\0')
    return FALSE;

  g_ascii_strtod (text, &end);
  return end != NULL && *end == '\0' && end != text;
}

/* Re-serialise DOC and queue it as PART's new content.  Nothing is
   written to the file here -- the zip layer holds it until save, which
   is what keeps every untouched part byte-identical. */
static gboolean
queue_doc (CmacsOfficePackage *pkg, const gchar *part, xmlDoc *doc,
           GError **error)
{
  xmlChar *buf = NULL;
  int len = 0;
  gboolean ok;

  /* Format 0: no gratuitous re-indenting.  Whitespace is significant
     in these parts, and reflowing them would turn a one-cell edit into
     a whole-part rewrite in any diff. */
  xmlDocDumpFormatMemoryEnc (doc, &buf, &len, "UTF-8", 0);
  if (buf == NULL || len <= 0)
    {
      if (buf != NULL)
        xmlFree (buf);
      g_set_error (error, CMACS_OFFICE_ZIP_ERROR, CMACS_OFFICE_ZIP_ERROR_WRITE,
                   "could not serialise %s", part);
      return FALSE;
    }

  ok = cmacs_office_zip_set_part (cmacs_office_package_zip (pkg), part,
                                  (const guint8 *) buf, (gsize) len, error);
  xmlFree (buf);
  return ok;
}

static xmlDoc *
load_part (CmacsOfficePackage *pkg, const gchar *part, GError **error)
{
  CmacsOfficeZip *zip = cmacs_office_package_zip (pkg);
  guint64 size = 0;
  guint8 *bytes;
  gsize len = 0;
  xmlDoc *doc;

  if (cmacs_office_zip_part_size (zip, part, &size, NULL)
      && size > CMACS_OFFICE_SHEET_MAX_DOM)
    {
      g_set_error (error, CMACS_OFFICE_ZIP_ERROR,
                   CMACS_OFFICE_ZIP_ERROR_TOO_LARGE,
                   "%s is %" G_GUINT64_FORMAT " bytes; editing needs the part "
                   "in memory and the limit is %" G_GUINT64_FORMAT,
                   part, size, CMACS_OFFICE_SHEET_MAX_DOM);
      return NULL;
    }

  bytes = cmacs_office_zip_read_part (zip, part, &len, error);
  if (bytes == NULL)
    return NULL;

  doc = cmacs_office_xml_parse (bytes, len, part, error);
  g_free (bytes);
  return doc;
}

/* ------------------------------------------------------------------ */
/* OOXML                                                               */
/* ------------------------------------------------------------------ */

/* Find <row r="ROW">, creating it in address order if absent. */
static xmlNode *
xlsx_row (xmlNode *data, gint row)
{
  xmlNode *n, *prev = NULL, *fresh;
  gchar num[32];

  for (n = cmacs_office_xml_first (data, "row", NS_S);
       n != NULL;
       n = cmacs_office_xml_next (n, "row", NS_S))
    {
      gchar *r = cmacs_office_xml_attr (n, "r");
      gint have = r ? (gint) g_ascii_strtoll (r, NULL, 10) : 0;

      g_free (r);
      if (have == row)
        return n;
      if (have > row)
        break;                  /* insert before this one */
      prev = n;
    }

  fresh = xmlNewNode (data->ns, (const xmlChar *) "row");
  g_snprintf (num, sizeof num, "%d", row);
  xmlSetProp (fresh, (const xmlChar *) "r", (const xmlChar *) num);

  if (prev != NULL)
    xmlAddNextSibling (prev, fresh);
  else if (n != NULL)
    xmlAddPrevSibling (n, fresh);
  else
    xmlAddChild (data, fresh);

  return fresh;
}

/* Find <c r="REF">, creating it in column order if absent. */
static xmlNode *
xlsx_cell (xmlNode *row, gint col, const gchar *ref)
{
  xmlNode *n, *prev = NULL, *fresh;

  for (n = cmacs_office_xml_first (row, "c", NS_S);
       n != NULL;
       n = cmacs_office_xml_next (n, "c", NS_S))
    {
      gchar *r = cmacs_office_xml_attr (n, "r");
      gint have_col = 0;

      if (r != NULL && cmacs_office_sheet_parse (r, NULL, &have_col))
        {
          g_free (r);
          if (have_col == col)
            return n;
          if (have_col > col)
            break;
          prev = n;
          continue;
        }
      g_free (r);
      prev = n;
    }

  fresh = xmlNewNode (row->ns, (const xmlChar *) "c");
  xmlSetProp (fresh, (const xmlChar *) "r", (const xmlChar *) ref);

  if (prev != NULL)
    xmlAddNextSibling (prev, fresh);
  else if (n != NULL)
    xmlAddPrevSibling (n, fresh);
  else
    xmlAddChild (row, fresh);

  return fresh;
}

static void
xlsx_clear_value (xmlNode *cell)
{
  const gchar *const kill[] = { "v", "f", "is", NULL };
  guint i;

  for (i = 0; kill[i] != NULL; i++)
    {
      xmlNode *n = cmacs_office_xml_child (cell, kill[i], NS_S);

      while (n != NULL)
        {
          xmlNode *next = cmacs_office_xml_next (n, kill[i], NS_S);

          xmlUnlinkNode (n);
          xmlFreeNode (n);
          n = next;
        }
    }
  xmlUnsetProp (cell, (const xmlChar *) "t");
}

static gboolean
xlsx_set (CmacsOfficePackage *pkg, const gchar *part, gint row, gint col,
          const gchar *text, const gchar *formula, GError **error)
{
  xmlDoc *doc;
  xmlNode *root, *data, *r, *c;
  gchar *ref;
  gboolean ok;

  doc = load_part (pkg, part, error);
  if (doc == NULL)
    return FALSE;

  root = cmacs_office_xml_root (doc);
  data = cmacs_office_xml_child (root, "sheetData", NS_S);
  if (data == NULL)
    data = xmlAddChild (root, xmlNewNode (root->ns,
                                          (const xmlChar *) "sheetData"));

  ref = cmacs_office_sheet_ref (row, col);
  r = xlsx_row (data, row);
  c = xlsx_cell (r, col, ref);
  g_free (ref);

  /* Attributes other than the value -- notably `s', the style index --
     survive, because only the value children are replaced. */
  xlsx_clear_value (c);

  if (formula != NULL && *formula != '\0')
    xmlNewTextChild (c, c->ns, (const xmlChar *) "f",
                     (const xmlChar *) formula);

  if (text != NULL && *text != '\0')
    {
      if (looks_numeric (text))
        xmlNewTextChild (c, c->ns, (const xmlChar *) "v",
                         (const xmlChar *) text);
      else
        {
          /* An inline string rather than a shared-string index: it
             avoids rewriting sharedStrings.xml, which would touch a
             second part and put every other cell's index at risk for
             the sake of one edit. */
          xmlNode *is;

          xmlSetProp (c, (const xmlChar *) "t", (const xmlChar *) "inlineStr");
          is = xmlNewChild (c, c->ns, (const xmlChar *) "is", NULL);
          xmlNewTextChild (is, c->ns, (const xmlChar *) "t",
                           (const xmlChar *) text);
        }
    }

  ok = queue_doc (pkg, part, doc, error);
  xmlFreeDoc (doc);
  return ok;
}

/* ------------------------------------------------------------------ */
/* OpenDocument                                                        */
/* ------------------------------------------------------------------ */

static gint
repeat_of (xmlNode *n, const gchar *attr)
{
  gchar *v = cmacs_office_xml_attr (n, attr);
  gint out = 1;

  if (v != NULL && *v != '\0')
    out = (gint) g_ascii_strtoll (v, NULL, 10);
  g_free (v);
  return out < 1 ? 1 : out;
}

static void
set_repeat (xmlNode *n, const gchar *attr, gint value, xmlNs *ns)
{
  if (value <= 1)
    xmlUnsetNsProp (n, ns, (const xmlChar *) attr);
  else
    {
      gchar num[32];

      g_snprintf (num, sizeof num, "%d", value);
      xmlSetNsProp (n, ns, (const xmlChar *) attr, (const xmlChar *) num);
    }
}

/* Split a run of repeated siblings so that the INDEX-th one (0-based
   within the run) stands alone, and return it.
 *
 * A run of N identical elements becomes up to three: the `before'
 * copies, the single one the caller will edit, and the `after' copies.
 * Copies are deep clones, so whatever styling the run carried is kept
 * on all of them. */
static xmlNode *
split_run (xmlNode *node, const gchar *attr, gint index, xmlNs *ns)
{
  gint total = repeat_of (node, attr);
  gint after;

  if (total <= 1)
    return node;

  if (index > 0)
    {
      xmlNode *before = xmlCopyNode (node, 1);

      set_repeat (before, attr, index, ns);
      xmlAddPrevSibling (node, before);
    }

  after = total - index - 1;
  if (after > 0)
    {
      xmlNode *rest = xmlCopyNode (node, 1);

      set_repeat (rest, attr, after, ns);
      xmlAddNextSibling (node, rest);
    }

  set_repeat (node, attr, 1, ns);
  return node;
}

/* Walk to row ROW (1-based), expanding repeats as needed. */
static xmlNode *
ods_row (xmlNode *table, gint row, xmlNs *table_ns)
{
  xmlNode *n;
  gint seen = 0;

  for (n = cmacs_office_xml_first (table, "table-row", NS_ODF_TABLE);
       n != NULL;
       n = cmacs_office_xml_next (n, "table-row", NS_ODF_TABLE))
    {
      gint rep = repeat_of (n, "number-rows-repeated");

      if (row <= seen + rep)
        return split_run (n, "number-rows-repeated", row - seen - 1, table_ns);
      seen += rep;
    }

  /* Past the last row: pad with empty rows, then append. */
  while (seen < row - 1)
    {
      xmlNewChild (table, table_ns, (const xmlChar *) "table-row", NULL);
      seen++;
    }
  return xmlNewChild (table, table_ns, (const xmlChar *) "table-row", NULL);
}

static xmlNode *
ods_cell (xmlNode *row, gint col, xmlNs *table_ns)
{
  xmlNode *n;
  gint seen = 0;

  for (n = cmacs_office_xml_first (row, "table-cell", NS_ODF_TABLE);
       n != NULL;
       n = cmacs_office_xml_next (n, "table-cell", NS_ODF_TABLE))
    {
      gint rep = repeat_of (n, "number-columns-repeated");

      if (col <= seen + rep)
        return split_run (n, "number-columns-repeated", col - seen - 1,
                          table_ns);
      seen += rep;
    }

  while (seen < col - 1)
    {
      xmlNewChild (row, table_ns, (const xmlChar *) "table-cell", NULL);
      seen++;
    }
  return xmlNewChild (row, table_ns, (const xmlChar *) "table-cell", NULL);
}

static xmlNs *
find_ns (xmlNode *node, const gchar *href, const gchar *prefix)
{
  xmlNs *ns = xmlSearchNsByHref (node->doc, node, (const xmlChar *) href);

  if (ns == NULL)
    ns = xmlNewNs (xmlDocGetRootElement (node->doc),
                   (const xmlChar *) href, (const xmlChar *) prefix);
  return ns;
}

static gboolean
ods_set (CmacsOfficePackage *pkg, const gchar *part, const gchar *sheet,
         gint row, gint col, const gchar *text, const gchar *formula,
         GError **error)
{
  xmlDoc *doc;
  xmlNode *root, *body, *sp, *table = NULL, *r, *c, *kid;
  xmlNs *table_ns, *office_ns, *text_ns;
  gboolean ok;

  doc = load_part (pkg, part, error);
  if (doc == NULL)
    return FALSE;

  root = cmacs_office_xml_root (doc);
  body = cmacs_office_xml_child (root, "body", NS_ODF_OFFICE);
  sp = cmacs_office_xml_child (body, "spreadsheet", NS_ODF_OFFICE);

  for (table = cmacs_office_xml_first (sp, "table", NS_ODF_TABLE);
       table != NULL;
       table = cmacs_office_xml_next (table, "table", NS_ODF_TABLE))
    {
      gchar *name = cmacs_office_xml_attr (table, "name");
      gboolean hit = (sheet == NULL || g_strcmp0 (name, sheet) == 0);

      g_free (name);
      if (hit)
        break;
    }

  if (table == NULL)
    {
      xmlFreeDoc (doc);
      g_set_error (error, CMACS_OFFICE_ZIP_ERROR, CMACS_OFFICE_ZIP_ERROR_NO_PART,
                   "no sheet named %s", sheet ? sheet : "(any)");
      return FALSE;
    }

  table_ns = find_ns (table, NS_ODF_TABLE, "table");
  office_ns = find_ns (table, NS_ODF_OFFICE, "office");
  text_ns = find_ns (table, NS_ODF_TEXT, "text");

  r = ods_row (table, row, table_ns);
  c = ods_cell (r, col, table_ns);

  /* Drop the old content and value typing, keeping style attributes. */
  kid = c->children;
  while (kid != NULL)
    {
      xmlNode *next = kid->next;

      xmlUnlinkNode (kid);
      xmlFreeNode (kid);
      kid = next;
    }
  xmlUnsetNsProp (c, office_ns, (const xmlChar *) "value-type");
  xmlUnsetNsProp (c, office_ns, (const xmlChar *) "value");
  xmlUnsetNsProp (c, office_ns, (const xmlChar *) "string-value");
  xmlUnsetNsProp (c, table_ns, (const xmlChar *) "formula");

  if (formula != NULL && *formula != '\0')
    {
      /* ODF namespaces its formulas; `of:' is the OpenFormula dialect
         LibreOffice writes and reads. */
      gchar *of = g_strconcat ("of:=", formula, NULL);

      xmlSetNsProp (c, table_ns, (const xmlChar *) "formula",
                    (const xmlChar *) of);
      g_free (of);
    }

  if (text != NULL && *text != '\0')
    {
      if (looks_numeric (text))
        {
          xmlSetNsProp (c, office_ns, (const xmlChar *) "value-type",
                        (const xmlChar *) "float");
          xmlSetNsProp (c, office_ns, (const xmlChar *) "value",
                        (const xmlChar *) text);
        }
      else
        xmlSetNsProp (c, office_ns, (const xmlChar *) "value-type",
                      (const xmlChar *) "string");

      xmlNewTextChild (c, text_ns, (const xmlChar *) "p",
                       (const xmlChar *) text);
    }

  ok = queue_doc (pkg, part, doc, error);
  xmlFreeDoc (doc);
  return ok;
}

/* ------------------------------------------------------------------ */
/* Entry point                                                         */
/* ------------------------------------------------------------------ */

gboolean
cmacs_office_sheet_set_cell (CmacsOfficePackage *pkg, const gchar *sheet,
                             gint row, gint col, const gchar *text,
                             const gchar *formula, GError **error)
{
  gchar *part;
  gboolean ok;

  g_return_val_if_fail (pkg != NULL, FALSE);

  if (row < 1 || col < 1)
    {
      g_set_error (error, CMACS_OFFICE_ZIP_ERROR, CMACS_OFFICE_ZIP_ERROR_BAD_NAME,
                   "cell coordinates are 1-based; got row %d column %d",
                   row, col);
      return FALSE;
    }

  if (cmacs_office_package_kind (pkg) != CMACS_OFFICE_KIND_SHEET)
    {
      g_set_error (error, CMACS_OFFICE_ZIP_ERROR, CMACS_OFFICE_ZIP_ERROR_NO_PART,
                   "this document is not a spreadsheet");
      return FALSE;
    }

  part = cmacs_office_sheet_part (pkg, sheet, error);
  if (part == NULL)
    {
      if (error != NULL && *error == NULL)
        g_set_error (error, CMACS_OFFICE_ZIP_ERROR,
                     CMACS_OFFICE_ZIP_ERROR_NO_PART,
                     "no sheet named %s", sheet ? sheet : "(any)");
      return FALSE;
    }

  ok = (cmacs_office_package_family (pkg) == CMACS_OFFICE_FAMILY_ODF)
    ? ods_set (pkg, part, sheet, row, col, text, formula, error)
    : xlsx_set (pkg, part, row, col, text, formula, error);

  g_free (part);
  return ok;
}

#endif /* HAVE_CMACS_OFFICE */
