/* cmacs-office-defuns.c --- Office document Lisp primitives.
 *
 * Copyright (C) 2026 Zach Podbielniak
 * SPDX-License-Identifier: AGPL-3.0-or-later
 *
 * The DEFUN surface for the OOXML / OpenDocument subsystem.  Each open
 * document is held in a small C registry and referenced from Lisp by an
 * integer handle, so no Lisp_Object is ever stored in GLib-allocated
 * memory (GC-safe).  This TU includes lisp.h and the plain-C bridge
 * headers ONLY -- it never sees zip.h or the libxml2 headers directly,
 * which keeps the container and the parsers replaceable without
 * touching the Lisp boundary.
 *
 * A handle refers to a CmacsOfficePackage, which owns its container.
 * Part-level primitives reach through to the zip; identity and
 * metadata primitives ask the package. */

#include <config.h>

#ifdef HAVE_CMACS_OFFICE

#include "lisp.h"
#include "coding.h"             /* ENCODE_FILE / DECODE_FILE / ENCODE_UTF_8 */
#include "cmacs-office.h"
#include "cmacs-office-package.h"
#include "cmacs-office-extract.h"
#include "cmacs-office-sheet.h"

/* Registry: handle == index; a NULL slot is free/closed. */
static GPtrArray *office_registry;

static EMACS_INT
of_register (CmacsOfficePackage *p)
{
  guint i;

  if (office_registry == NULL)
    office_registry = g_ptr_array_new ();
  for (i = 0; i < office_registry->len; i++)
    if (g_ptr_array_index (office_registry, i) == NULL)
      {
        office_registry->pdata[i] = p;
        return (EMACS_INT) i;
      }
  g_ptr_array_add (office_registry, p);
  return (EMACS_INT) (office_registry->len - 1);
}

static CmacsOfficePackage *
of_lookup (Lisp_Object handle)
{
  EMACS_INT h;
  CmacsOfficePackage *p;

  CHECK_FIXNUM (handle);
  h = XFIXNUM (handle);
  if (office_registry == NULL || h < 0
      || h >= (EMACS_INT) office_registry->len)
    xsignal2 (Qcmacs_office_error,
              build_string ("unknown or closed cmacs-office handle"), handle);
  p = g_ptr_array_index (office_registry, h);
  if (p == NULL)
    xsignal2 (Qcmacs_office_error,
              build_string ("unknown or closed cmacs-office handle"), handle);
  return p;
}

static CmacsOfficeZip *
of_zip (Lisp_Object handle)
{
  return cmacs_office_package_zip (of_lookup (handle));
}

/* Turn a GError into a Lisp signal and consume it.  Every failure path
   below funnels through here so the error domain stays one symbol. */
static _Noreturn void
of_signal (GError *err, const char *fallback)
{
  Lisp_Object msg = build_string (err && err->message ? err->message : fallback);

  if (err != NULL)
    g_error_free (err);
  xsignal1 (Qcmacs_office_error, msg);
}

/* A C string to a Lisp string, decoded as UTF-8.  Package part names
   and content types are UTF-8 by specification in both families. */
static Lisp_Object
of_utf8 (const gchar *s)
{
  return s ? code_convert_string_norecord (build_unibyte_string (s),
                                           Qutf_8, false)
           : Qnil;
}

DEFUN ("cmacs-office-supported-p", Fcmacs_office_supported_p,
       Scmacs_office_supported_p, 0, 0, 0,
       doc: /* Return non-nil if this build has Office document support.
That means cmacs was configured --with-cmacs-office, which links libzip
and libxml2 for the OOXML and OpenDocument package formats.  */)
  (void)
{
  return Qt;
}

DEFUN ("cmacs-office-open", Fcmacs_office_open, Scmacs_office_open, 1, 1, 0,
       doc: /* Open the Office document at PATH and return an integer handle.

PATH may be any OOXML or OpenDocument file -- .docx, .xlsx, .pptx, .odt,
.ods or .odp -- since all six are zip packages.  The format is detected
from the package contents rather than from the file name, so a
mis-named file still opens as what it actually is.

A zip that matches neither convention still opens; its format, kind and
family simply read as `unknown', which is more useful than refusing to
look at it.

The file is opened read-only; nothing is written until
`cmacs-office-save'.  Close the handle with `cmacs-office-close'.  */)
  (Lisp_Object path)
{
  CmacsOfficePackage *p;
  GError *err = NULL;
  Lisp_Object encoded;

  CHECK_STRING (path);
  encoded = ENCODE_FILE (Fexpand_file_name (path, Qnil));

  p = cmacs_office_package_open (SSDATA (encoded), &err);
  if (p == NULL)
    of_signal (err, "cannot open Office document");

  return make_fixnum (of_register (p));
}

DEFUN ("cmacs-office-close", Fcmacs_office_close, Scmacs_office_close, 1, 1, 0,
       doc: /* Close HANDLE and release the document it refers to.
Pending edits that were never saved are discarded.  */)
  (Lisp_Object handle)
{
  EMACS_INT h;
  CmacsOfficePackage *p;

  CHECK_FIXNUM (handle);
  h = XFIXNUM (handle);
  if (office_registry != NULL && h >= 0
      && h < (EMACS_INT) office_registry->len)
    {
      p = g_ptr_array_index (office_registry, h);
      if (p != NULL)
        {
          cmacs_office_package_free (p);
          office_registry->pdata[h] = NULL;
        }
    }
  return Qnil;
}

DEFUN ("cmacs-office-path", Fcmacs_office_path, Scmacs_office_path, 1, 1, 0,
       doc: /* Return the file name HANDLE was opened from.  */)
  (Lisp_Object handle)
{
  const gchar *p = cmacs_office_zip_path (of_zip (handle));

  return p ? DECODE_FILE (build_unibyte_string (p)) : Qnil;
}

/* ------------------------------------------------------------------ */
/* Identity                                                            */
/* ------------------------------------------------------------------ */

DEFUN ("cmacs-office-format", Fcmacs_office_format, Scmacs_office_format,
       1, 1, 0,
       doc: /* Return the format of HANDLE as a symbol.

One of `docx', `xlsx', `pptx', `odt', `ods', `odp', or `unknown'.

Determined from the package contents -- the OpenDocument `mimetype'
part, or the content type of the part the OOXML relationships name as
the document body -- never from the file extension.  Macro-enabled and
template variants report as their base format: an .xlsm is `xlsx',
because its structure is identical and the macro part is simply one
more part that is never parsed.  */)
  (Lisp_Object handle)
{
  CmacsOfficePackage *p = of_lookup (handle);

  return intern (cmacs_office_format_name (cmacs_office_package_format (p)));
}

DEFUN ("cmacs-office-kind", Fcmacs_office_kind, Scmacs_office_kind, 1, 1, 0,
       doc: /* Return what sort of document HANDLE is, as a symbol.

One of `text' (.docx/.odt), `sheet' (.xlsx/.ods), `slides'
(.pptx/.odp), or `unknown'.

This, rather than the format, is what decides which model and which
major mode a document gets: a .docx and a .odt are both `text' and are
handled by the same code above the codec layer.  */)
  (Lisp_Object handle)
{
  CmacsOfficePackage *p = of_lookup (handle);

  return intern (cmacs_office_kind_name (cmacs_office_package_kind (p)));
}

DEFUN ("cmacs-office-family", Fcmacs_office_family, Scmacs_office_family,
       1, 1, 0,
       doc: /* Return the packaging convention of HANDLE, as a symbol.

Either `ooxml' (the OPC convention, used by .docx/.xlsx/.pptx), `odf'
(the OpenDocument package, used by .odt/.ods/.odp), or `unknown'.  */)
  (Lisp_Object handle)
{
  CmacsOfficePackage *p = of_lookup (handle);

  return intern (cmacs_office_family_name (cmacs_office_package_family (p)));
}

DEFUN ("cmacs-office-main-part", Fcmacs_office_main_part,
       Scmacs_office_main_part, 1, 1, 0,
       doc: /* Return the part name holding HANDLE's document body.

For OpenDocument this is always "content.xml".  For OOXML it is
resolved through the package relationships rather than assumed, because
nothing requires a .docx to call its body "word/document.xml".

Returns nil when the package was not recognised.  */)
  (Lisp_Object handle)
{
  CmacsOfficePackage *p = of_lookup (handle);

  return of_utf8 (cmacs_office_package_main_part (p));
}

DEFUN ("cmacs-office-content-type", Fcmacs_office_content_type,
       Scmacs_office_content_type, 2, 2, 0,
       doc: /* Return the declared content type of part NAME in HANDLE.

Resolved from the OpenDocument manifest, or from an OOXML Override,
falling back to the Default declared for the part's extension.  Returns
nil when the package declares no type for it.  */)
  (Lisp_Object handle, Lisp_Object name)
{
  CmacsOfficePackage *p = of_lookup (handle);
  gchar *type;
  Lisp_Object out;

  CHECK_STRING (name);
  type = cmacs_office_package_content_type (p, SSDATA (ENCODE_UTF_8 (name)));
  out = of_utf8 (type);
  g_free (type);

  return out;
}

DEFUN ("cmacs-office-relationships", Fcmacs_office_relationships,
       Scmacs_office_relationships, 1, 2, 0,
       doc: /* Return the relationships declared by PART in HANDLE.

PART defaults to the package root, whose relationships are the entry
point to everything else in an OOXML document.  Pass a part name to
follow the graph outward, for example the main part's relationships to
reach styles, numbering, images and embedded objects.

Each relationship is a plist with keys :id, :type, :target and
:external.  A non-external :target is a package part name, already
resolved against the directory of the part that declared it; an
external one is a URI pointing outside the package.

OpenDocument has no relationship graph, so this returns nil for it.  */)
  (Lisp_Object handle, Lisp_Object part)
{
  CmacsOfficePackage *p = of_lookup (handle);
  GError *err = NULL;
  GPtrArray *rels;
  Lisp_Object out = Qnil;
  const gchar *src = "";
  guint i;

  if (!NILP (part))
    {
      CHECK_STRING (part);
      src = SSDATA (ENCODE_UTF_8 (part));
    }

  rels = cmacs_office_package_rels (p, src, &err);
  if (rels == NULL)
    of_signal (err, "cannot read package relationships");

  for (i = rels->len; i > 0; i--)
    {
      CmacsOfficeRel *r = g_ptr_array_index (rels, i - 1);

      out = Fcons (list (QCid, of_utf8 (r->id),
                         QCtype, of_utf8 (r->type),
                         QCtarget, of_utf8 (r->target),
                         QCexternal, r->external ? Qt : Qnil),
                   out);
    }

  g_ptr_array_unref (rels);
  return out;
}

DEFUN ("cmacs-office-metadata", Fcmacs_office_metadata,
       Scmacs_office_metadata, 1, 1, 0,
       doc: /* Return HANDLE's document properties as a plist.

Keys are normalised across both families, so the same call works
whatever the format: :title, :subject, :description, :creator,
:last-modified-by, :keywords, :created, :modified, :generator,
:company and :language.  Properties the document does not carry are
simply absent.

Dates are returned as the strings the document stores, which are
ISO 8601 in practice but are not reformatted here.  */)
  (Lisp_Object handle)
{
  CmacsOfficePackage *p = of_lookup (handle);
  GError *err = NULL;
  GHashTable *meta;
  GHashTableIter iter;
  gpointer k, v;
  Lisp_Object out = Qnil;

  meta = cmacs_office_package_metadata (p, &err);
  if (meta == NULL)
    of_signal (err, "cannot read document metadata");

  g_hash_table_iter_init (&iter, meta);
  while (g_hash_table_iter_next (&iter, &k, &v))
    {
      gchar *kw = g_strconcat (":", (const gchar *) k, NULL);

      out = Fcons (intern (kw), Fcons (of_utf8 ((const gchar *) v), out));
      g_free (kw);
    }

  g_hash_table_unref (meta);
  return out;
}

/* ------------------------------------------------------------------ */
/* Content extraction                                                  */
/* ------------------------------------------------------------------ */

DEFUN ("cmacs-office-blocks", Fcmacs_office_blocks, Scmacs_office_blocks,
       1, 1, 0,
       doc: /* Return the readable content of HANDLE as a list of plists.

Applies to word processing documents and presentations; spreadsheets
extract through `cmacs-office-cells' instead, and return nil here.

Each block is one paragraph, heading, or slide shape, in document
order, with these keys:

  :part   the package part it came from
  :id     a stable identifier the FILE provides, or nil
  :index  the block's ordinal within its part
  :level  heading level 1-9, or 0 for a body paragraph
  :style  the style name the document gives it, or nil
  :slide  1-based slide number, or 0 outside a presentation
  :shape  slide shape name, or nil
  :text   the readable text

:id and :index together are the writeback anchor.  Prefer :id, which
survives edits elsewhere in the document; :index only holds while
nothing above the block is inserted or removed.

Text that is present in the file but not visible in the document --
tracked deletions, comment bodies -- is deliberately excluded, so this
matches what a reader sees rather than what the XML contains.  */)
  (Lisp_Object handle)
{
  CmacsOfficePackage *p = of_lookup (handle);
  GError *err = NULL;
  GPtrArray *blocks;
  Lisp_Object out = Qnil;
  guint i;

  blocks = cmacs_office_extract (p, &err);
  if (blocks == NULL)
    of_signal (err, "cannot extract document content");

  for (i = blocks->len; i > 0; i--)
    {
      CmacsOfficeBlock *b = g_ptr_array_index (blocks, i - 1);

      out = Fcons (list (QCpart, of_utf8 (b->part),
                         QCid, of_utf8 (b->id),
                         QCindex, make_fixnum (b->index),
                         QClevel, make_fixnum (b->level),
                         QCstyle, of_utf8 (b->style),
                         QCslide, make_fixnum (b->slide),
                         QCshape, of_utf8 (b->shape),
                         QCtext, of_utf8 (b->text)),
                   out);
    }

  g_ptr_array_unref (blocks);
  return out;
}

DEFUN ("cmacs-office-sheet-names", Fcmacs_office_sheet_names,
       Scmacs_office_sheet_names, 1, 1, 0,
       doc: /* Return the sheet names of the spreadsheet HANDLE, in workbook order.
Returns nil for documents that are not spreadsheets.  */)
  (Lisp_Object handle)
{
  CmacsOfficePackage *p = of_lookup (handle);
  GError *err = NULL;
  GPtrArray *names;
  Lisp_Object out = Qnil;
  guint i;

  names = cmacs_office_sheet_names (p, &err);
  if (names == NULL)
    of_signal (err, "cannot read sheet names");

  for (i = names->len; i > 0; i--)
    out = Fcons (of_utf8 (g_ptr_array_index (names, i - 1)), out);

  g_ptr_array_unref (names);
  return out;
}

DEFUN ("cmacs-office-cells", Fcmacs_office_cells, Scmacs_office_cells,
       1, 1, 0,
       doc: /* Return the non-empty cells of the spreadsheet HANDLE, as plists.

Ordered sheet by sheet in workbook order, then by row, then column.
Returns nil for documents that are not spreadsheets.

Each cell has these keys:

  :sheet    the sheet name
  :row      1-based row
  :col      1-based column
  :ref      the "A1" style address, which is the anchor
  :text     the display text
  :formula  the source formula, or nil

Only cells carrying text or a formula are returned.  Spreadsheet files
pad their rows out to a thousand or more empty cells using repeat
counts, and honouring those literally would bury a ten-cell sheet in
millions of blanks.

Signals `cmacs-office-error' on a sheet too large to parse in memory;
streaming for sheets that size is not implemented yet.  */)
  (Lisp_Object handle)
{
  CmacsOfficePackage *p = of_lookup (handle);
  GError *err = NULL;
  GPtrArray *cells;
  Lisp_Object out = Qnil;
  guint i;

  cells = cmacs_office_sheet_cells (p, &err);
  if (cells == NULL)
    of_signal (err, "cannot read spreadsheet cells");

  for (i = cells->len; i > 0; i--)
    {
      CmacsOfficeCell *c = g_ptr_array_index (cells, i - 1);

      out = Fcons (list (QCsheet, of_utf8 (c->sheet),
                         QCrow, make_fixnum (c->row),
                         QCcol, make_fixnum (c->col),
                         QCref, of_utf8 (c->ref),
                         QCtext, of_utf8 (c->text),
                         QCformula, of_utf8 (c->formula)),
                   out);
    }

  g_ptr_array_unref (cells);
  return out;
}

DEFUN ("cmacs-office-set-block", Fcmacs_office_set_block,
       Scmacs_office_set_block, 4, 4, 0,
       doc: /* Replace the text of one block of HANDLE with TEXT.

ID and INDEX come from `cmacs-office-blocks'.  The block is found by ID
when the document gave it one, falling back to INDEX -- so pass both,
and pass nil for ID when the block has none.

Applies to word processing documents.  Presentations and spreadsheets
have their own shapes; use `cmacs-office-set-cell' for the latter.

The paragraph keeps its own style and the character formatting of its
first run, but formatting that VARIED inside the paragraph is
flattened: a sentence with one bold word comes back in the first run's
style throughout.  Everything outside the paragraph, and every other
part of the package, is untouched.

The edit is queued; `cmacs-office-save' is what reaches the file.

\(fn HANDLE ID INDEX TEXT)  */)
  (Lisp_Object handle, Lisp_Object id, Lisp_Object index, Lisp_Object text)
{
  CmacsOfficePackage *p = of_lookup (handle);
  GError *err = NULL;
  const char *id_s = NULL;
  const char *text_s = NULL;

  CHECK_FIXNUM (index);
  if (!NILP (id))
    {
      CHECK_STRING (id);
      id_s = SSDATA (ENCODE_UTF_8 (id));
    }
  if (!NILP (text))
    {
      CHECK_STRING (text);
      text_s = SSDATA (ENCODE_UTF_8 (text));
    }

  if (!cmacs_office_extract_set_block (p, id_s, (gint) XFIXNUM (index),
                                       text_s, &err))
    of_signal (err, "cannot set block text");

  return Qnil;
}

DEFUN ("cmacs-office-set-slide-text", Fcmacs_office_set_slide_text,
       Scmacs_office_set_slide_text, 4, 4, 0,
       doc: /* Replace the text of one shape on a slide of HANDLE.

SLIDE and INDEX come from `cmacs-office-blocks' -- its :slide and
:index keys.  SLIDE is 1-based; INDEX counts only shapes that hold
text, matching what extraction reports.

The shape keeps its geometry, its placeholder role and the character
formatting of its first run; formatting that varied inside the shape is
flattened.  The edit is queued until `cmacs-office-save'.

\(fn HANDLE SLIDE INDEX TEXT)  */)
  (Lisp_Object handle, Lisp_Object slide, Lisp_Object index, Lisp_Object text)
{
  CmacsOfficePackage *p = of_lookup (handle);
  GError *err = NULL;
  const char *text_s = NULL;

  CHECK_FIXNUM (slide);
  CHECK_FIXNUM (index);
  if (!NILP (text))
    {
      CHECK_STRING (text);
      text_s = SSDATA (ENCODE_UTF_8 (text));
    }

  if (!cmacs_office_extract_set_slide_text (p, (gint) XFIXNUM (slide),
                                            (gint) XFIXNUM (index),
                                            text_s, &err))
    of_signal (err, "cannot set slide text");

  return Qnil;
}

DEFUN ("cmacs-office-set-cell", Fcmacs_office_set_cell,
       Scmacs_office_set_cell, 4, 6, 0,
       doc: /* Set the cell at ROW and COL of SHEET in HANDLE to TEXT.

ROW and COL are 1-based.  SHEET is a name from `cmacs-office-sheet-names',
or nil for the first sheet.  TEXT nil or empty clears the cell.
FORMULA, when given, is the source formula WITHOUT its leading `=';
each format's own formula syntax is written as-is.

Text that parses as a number is stored as a number, so it sums; anything
else is stored as text.

The edit is queued like every other, so nothing reaches the file until
`cmacs-office-save'.  Only the one sheet part is rewritten, and within
it only the one cell element -- styles, column widths, merges and
everything else this build does not model are carried through.

\(fn HANDLE SHEET ROW COL &optional TEXT FORMULA)  */)
  (Lisp_Object handle, Lisp_Object sheet, Lisp_Object row, Lisp_Object col,
   Lisp_Object text, Lisp_Object formula)
{
  CmacsOfficePackage *p = of_lookup (handle);
  GError *err = NULL;
  const char *sheet_s = NULL;
  const char *text_s = NULL;
  const char *formula_s = NULL;

  CHECK_FIXNUM (row);
  CHECK_FIXNUM (col);
  if (!NILP (sheet))
    {
      CHECK_STRING (sheet);
      sheet_s = SSDATA (ENCODE_UTF_8 (sheet));
    }
  if (!NILP (text))
    {
      CHECK_STRING (text);
      text_s = SSDATA (ENCODE_UTF_8 (text));
    }
  if (!NILP (formula))
    {
      CHECK_STRING (formula);
      formula_s = SSDATA (ENCODE_UTF_8 (formula));
    }

  if (!cmacs_office_sheet_set_cell (p, sheet_s, (gint) XFIXNUM (row),
                                    (gint) XFIXNUM (col), text_s,
                                    formula_s, &err))
    of_signal (err, "cannot set cell");

  return Qnil;
}

/* ------------------------------------------------------------------ */
/* Parts                                                               */
/* ------------------------------------------------------------------ */

DEFUN ("cmacs-office-part-count", Fcmacs_office_part_count,
       Scmacs_office_part_count, 1, 1, 0,
       doc: /* Return the number of parts in the document HANDLE.
Counts pending additions and excludes pending deletions.  */)
  (Lisp_Object handle)
{
  return make_fixnum ((EMACS_INT) cmacs_office_zip_n_parts (of_zip (handle)));
}

DEFUN ("cmacs-office-part-names", Fcmacs_office_part_names,
       Scmacs_office_part_names, 1, 1, 0,
       doc: /* Return the names of every part in the document HANDLE, as a list.

The order is the archive's own, which matters: an OpenDocument package
is only valid when its `mimetype' part comes first.  Parts queued by
`cmacs-office-set-part-bytes' that the file does not have yet are
appended in the order they were added.  */)
  (Lisp_Object handle)
{
  CmacsOfficeZip *z = of_zip (handle);
  Lisp_Object out = Qnil;
  gchar **names;
  guint n = 0, i;

  names = cmacs_office_zip_part_names (z, &n);
  if (names == NULL)
    return Qnil;

  for (i = n; i > 0; i--)
    out = Fcons (of_utf8 (names[i - 1]), out);

  g_strfreev (names);
  return out;
}

DEFUN ("cmacs-office-part-p", Fcmacs_office_part_p, Scmacs_office_part_p,
       2, 2, 0,
       doc: /* Return non-nil if the document HANDLE contains a part named NAME.
Returns nil rather than signalling when NAME is malformed.  */)
  (Lisp_Object handle, Lisp_Object name)
{
  CmacsOfficeZip *z = of_zip (handle);

  CHECK_STRING (name);
  return cmacs_office_zip_has_part (z, SSDATA (ENCODE_UTF_8 (name)))
         ? Qt : Qnil;
}

DEFUN ("cmacs-office-part-size", Fcmacs_office_part_size,
       Scmacs_office_part_size, 2, 2, 0,
       doc: /* Return the uncompressed size in bytes of part NAME in HANDLE.

Read from the central directory, so this costs no decompression and is
safe to consult before deciding whether to read a part at all.  */)
  (Lisp_Object handle, Lisp_Object name)
{
  CmacsOfficeZip *z = of_zip (handle);
  GError *err = NULL;
  guint64 size = 0;

  CHECK_STRING (name);
  if (!cmacs_office_zip_part_size (z, SSDATA (ENCODE_UTF_8 (name)), &size, &err))
    of_signal (err, "cannot stat package part");

  return make_int ((EMACS_INT) size);
}

DEFUN ("cmacs-office-part-bytes", Fcmacs_office_part_bytes,
       Scmacs_office_part_bytes, 2, 2, 0,
       doc: /* Return the raw bytes of part NAME in HANDLE, as a unibyte string.

No decoding is done: package parts are XML in an encoding the XML
declaration names, or opaque media.  Decode with `decode-coding-string'
or hand the result to `libxml-parse-xml-region' yourself.

A part queued by `cmacs-office-set-part-bytes' reads back as the queued
content, not as what is still on disk.  */)
  (Lisp_Object handle, Lisp_Object name)
{
  CmacsOfficeZip *z = of_zip (handle);
  GError *err = NULL;
  guint8 *buf;
  gsize len = 0;
  Lisp_Object out;

  CHECK_STRING (name);
  buf = cmacs_office_zip_read_part (z, SSDATA (ENCODE_UTF_8 (name)), &len, &err);
  if (buf == NULL)
    of_signal (err, "cannot read package part");

  out = make_unibyte_string ((const char *) buf, (ptrdiff_t) len);
  g_free (buf);
  return out;
}

DEFUN ("cmacs-office-set-part-bytes", Fcmacs_office_set_part_bytes,
       Scmacs_office_set_part_bytes, 3, 3, 0,
       doc: /* Queue BYTES as the new content of part NAME in HANDLE.

BYTES is used as raw bytes; encode it first if it is multibyte text.
Nothing touches the file until `cmacs-office-save' or
`cmacs-office-save-as' -- which is what lets every part you did not
touch be copied through with its compressed bytes intact.

Nothing here maintains the package's own bookkeeping: adding a part
does not register it in the OOXML content types or in any relationship,
and those must be updated too for a consumer to see it.

Signals `cmacs-office-error' when NAME is the `mimetype' part of an
existing OpenDocument package: it must stay first and uncompressed, and
rewriting it would move it to the end.  */)
  (Lisp_Object handle, Lisp_Object name, Lisp_Object bytes)
{
  CmacsOfficeZip *z = of_zip (handle);
  GError *err = NULL;

  CHECK_STRING (name);
  CHECK_STRING (bytes);

  if (!cmacs_office_zip_set_part (z, SSDATA (ENCODE_UTF_8 (name)),
                                  (const guint8 *) SDATA (bytes),
                                  (gsize) SBYTES (bytes), &err))
    of_signal (err, "cannot stage package part");

  return Qnil;
}

DEFUN ("cmacs-office-delete-part", Fcmacs_office_delete_part,
       Scmacs_office_delete_part, 2, 2, 0,
       doc: /* Queue the removal of part NAME from HANDLE.
Deferred like `cmacs-office-set-part-bytes'.  */)
  (Lisp_Object handle, Lisp_Object name)
{
  CmacsOfficeZip *z = of_zip (handle);
  GError *err = NULL;

  CHECK_STRING (name);
  if (!cmacs_office_zip_delete_part (z, SSDATA (ENCODE_UTF_8 (name)), &err))
    of_signal (err, "cannot delete package part");

  return Qnil;
}

DEFUN ("cmacs-office-dirty-p", Fcmacs_office_dirty_p, Scmacs_office_dirty_p,
       1, 1, 0,
       doc: /* Return non-nil if HANDLE has edits that have not been saved.  */)
  (Lisp_Object handle)
{
  return cmacs_office_zip_dirty (of_zip (handle)) ? Qt : Qnil;
}

DEFUN ("cmacs-office-revert", Fcmacs_office_revert, Scmacs_office_revert,
       1, 1, 0,
       doc: /* Discard every queued edit on HANDLE without touching the file.  */)
  (Lisp_Object handle)
{
  cmacs_office_zip_revert (of_zip (handle));
  return Qnil;
}

DEFUN ("cmacs-office-save", Fcmacs_office_save, Scmacs_office_save, 1, 1, 0,
       doc: /* Write HANDLE's queued edits back to the file it came from.

With no queued edits this does nothing at all -- not as an optimisation
but as a guarantee: opening a document and saving it without editing
cannot perturb a single byte.  With edits, every untouched part is
copied through with its compressed bytes intact, so unknown features
survive that this build cannot parse.  */)
  (Lisp_Object handle)
{
  CmacsOfficeZip *z = of_zip (handle);
  GError *err = NULL;

  if (!cmacs_office_zip_save (z, &err))
    of_signal (err, "cannot save Office document");

  return Qnil;
}

DEFUN ("cmacs-office-save-as", Fcmacs_office_save_as, Scmacs_office_save_as,
       2, 2, 0,
       doc: /* Write HANDLE, with its queued edits applied, to DEST.

This is an export: the file HANDLE was opened from is left alone, and
the queued edits stay queued.  DEST is overwritten if it exists.  */)
  (Lisp_Object handle, Lisp_Object dest)
{
  CmacsOfficeZip *z = of_zip (handle);
  GError *err = NULL;
  Lisp_Object encoded;

  CHECK_STRING (dest);
  encoded = ENCODE_FILE (Fexpand_file_name (dest, Qnil));

  if (!cmacs_office_zip_save_as (z, SSDATA (encoded), &err))
    of_signal (err, "cannot export Office document");

  return Qnil;
}

DEFUN ("cmacs-office-set-limits", Fcmacs_office_set_limits,
       Scmacs_office_set_limits, 3, 3, 0,
       doc: /* Set the inflated-size caps on HANDLE to MAX-PART and MAX-TOTAL.

These bound how far a hostile package is allowed to decompress, which
matters because these files routinely arrive as mail attachments.  Zero
for either argument leaves that cap unchanged.  */)
  (Lisp_Object handle, Lisp_Object max_part, Lisp_Object max_total)
{
  CmacsOfficeZip *z = of_zip (handle);

  CHECK_INTEGER (max_part);
  CHECK_INTEGER (max_total);

  cmacs_office_zip_set_limits (z, (guint64) XFIXNUM (max_part),
                               (guint64) XFIXNUM (max_total));
  return Qnil;
}

DEFUN ("cmacs-office-known-formats", Fcmacs_office_known_formats,
       Scmacs_office_known_formats, 0, 0, 0,
       doc: /* Return the formats this build understands, as a list of plists.

Each entry has :format, :kind, :family, :extension, :main-part and
:description.  This is the codec registry itself, so a format appears
here exactly when the subsystem can identify it.  */)
  (void)
{
  const CmacsOfficeCodec *const *codecs;
  Lisp_Object out = Qnil;
  guint n = 0, i;

  codecs = cmacs_office_codecs (&n);
  for (i = n; i > 0; i--)
    {
      const CmacsOfficeCodec *c = codecs[i - 1];

      out = Fcons (list (QCformat, intern (c->name),
                         QCkind, intern (cmacs_office_kind_name (c->kind)),
                         QCfamily, intern (cmacs_office_family_name (c->family)),
                         QCextension, of_utf8 (c->extension),
                         QCmain_part, of_utf8 (c->main_part),
                         QCdescription, of_utf8 (c->description)),
                   out);
    }

  return out;
}

void
syms_of_cmacs_office_defuns (void)
{
  DEFSYM (Qcmacs_office_error, "cmacs-office-error");
  Fput (Qcmacs_office_error, Qerror_conditions,
        list2 (Qcmacs_office_error, Qerror));
  Fput (Qcmacs_office_error, Qerror_message,
        build_string ("CMacs Office document error"));

  /* Re-DEFSYM'ing a symbol another TU also declares is harmless -- see
     QCtype, which upstream declares in both gnutls.c and process.c --
     and keeps this file's symbol set self-contained. */
  DEFSYM (QCid, ":id");
  DEFSYM (QCtype, ":type");
  DEFSYM (QCtarget, ":target");
  DEFSYM (QCexternal, ":external");
  DEFSYM (QCformat, ":format");
  DEFSYM (QCkind, ":kind");
  DEFSYM (QCfamily, ":family");
  DEFSYM (QCextension, ":extension");
  DEFSYM (QCmain_part, ":main-part");
  DEFSYM (QCdescription, ":description");
  DEFSYM (QCpart, ":part");
  DEFSYM (QCindex, ":index");
  DEFSYM (QClevel, ":level");
  DEFSYM (QCstyle, ":style");
  DEFSYM (QCslide, ":slide");
  DEFSYM (QCshape, ":shape");
  DEFSYM (QCtext, ":text");
  DEFSYM (QCsheet, ":sheet");
  DEFSYM (QCrow, ":row");
  DEFSYM (QCcol, ":col");
  DEFSYM (QCref, ":ref");
  DEFSYM (QCformula, ":formula");

  defsubr (&Scmacs_office_supported_p);
  defsubr (&Scmacs_office_open);
  defsubr (&Scmacs_office_close);
  defsubr (&Scmacs_office_path);
  defsubr (&Scmacs_office_format);
  defsubr (&Scmacs_office_kind);
  defsubr (&Scmacs_office_family);
  defsubr (&Scmacs_office_main_part);
  defsubr (&Scmacs_office_content_type);
  defsubr (&Scmacs_office_relationships);
  defsubr (&Scmacs_office_metadata);
  defsubr (&Scmacs_office_blocks);
  defsubr (&Scmacs_office_sheet_names);
  defsubr (&Scmacs_office_cells);
  defsubr (&Scmacs_office_set_block);
  defsubr (&Scmacs_office_set_slide_text);
  defsubr (&Scmacs_office_set_cell);
  defsubr (&Scmacs_office_part_count);
  defsubr (&Scmacs_office_part_names);
  defsubr (&Scmacs_office_part_p);
  defsubr (&Scmacs_office_part_size);
  defsubr (&Scmacs_office_part_bytes);
  defsubr (&Scmacs_office_set_part_bytes);
  defsubr (&Scmacs_office_delete_part);
  defsubr (&Scmacs_office_dirty_p);
  defsubr (&Scmacs_office_revert);
  defsubr (&Scmacs_office_save);
  defsubr (&Scmacs_office_save_as);
  defsubr (&Scmacs_office_set_limits);
  defsubr (&Scmacs_office_known_formats);
}

#endif /* HAVE_CMACS_OFFICE */
