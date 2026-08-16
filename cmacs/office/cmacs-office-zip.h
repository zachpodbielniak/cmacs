/* cmacs-office-zip.h --- the OPC / ODF package container.
 *
 * Copyright (C) 2026 Zach Podbielniak
 * SPDX-License-Identifier: AGPL-3.0-or-later
 *
 * All six office formats are zip archives: OOXML calls the convention
 * OPC, OpenDocument calls it an ODF package, but both are a zip whose
 * members ("parts") are XML plus media.  This TU is the only place that
 * knows that, and it includes neither lisp.h nor any Emacs header --
 * only glib and libzip -- so the container is testable with no Lisp VM.
 *
 * Deferred writes.  Mutations are held in a pending table and are only
 * pushed into libzip at save time.  Three things fall out of that:
 *
 *   - Saving an unmodified package is a no-op (or a plain file copy for
 *     save-as), so it is byte-identical by construction.
 *   - Saving a modified package lets libzip copy every untouched
 *     entry's ALREADY-COMPRESSED bytes through verbatim rather than
 *     re-deflating them.  A one-word edit to a deck with 100 MB of
 *     embedded media stays cheap, and -- more importantly -- the
 *     untouched parts come out bit-for-bit identical.
 *   - Read-back is consistent: cmacs_office_zip_read_part sees pending
 *     writes before it sees the on-disk entry.
 *
 * ODF ordering.  An ODF package must begin with an uncompressed
 * `mimetype' entry.  libzip preserves both the entry order and the
 * per-entry compression method for entries it copies through
 * untouched, so that invariant survives as long as nothing rewrites
 * `mimetype'.  cmacs_office_zip_set_part therefore REFUSES to replace
 * it -- see the guard in the implementation, and the ERT test that
 * pins the behaviour.
 *
 * Hostile input.  These files arrive as mail attachments, so the
 * reader is written to distrust them: part names are validated against
 * path traversal before any lookup, and both per-part and whole-archive
 * inflated-size caps bound a zip bomb.  See cmacs_office_zip_set_limits. */

#ifndef CMACS_OFFICE_ZIP_H
#define CMACS_OFFICE_ZIP_H

#include <config.h>

#ifdef HAVE_CMACS_OFFICE

#include <glib.h>

G_BEGIN_DECLS

#define CMACS_OFFICE_ZIP_ERROR (cmacs_office_zip_error_quark ())

typedef enum
{
  CMACS_OFFICE_ZIP_ERROR_OPEN,        /* archive could not be opened */
  CMACS_OFFICE_ZIP_ERROR_NO_PART,     /* no such part in the package */
  CMACS_OFFICE_ZIP_ERROR_BAD_NAME,    /* part name failed validation */
  CMACS_OFFICE_ZIP_ERROR_TOO_LARGE,   /* an inflated-size cap was hit */
  CMACS_OFFICE_ZIP_ERROR_READ,        /* truncated or corrupt member */
  CMACS_OFFICE_ZIP_ERROR_WRITE,       /* save failed */
  CMACS_OFFICE_ZIP_ERROR_READONLY     /* part is structurally immutable */
} CmacsOfficeZipError;

GQuark cmacs_office_zip_error_quark (void);

typedef struct _CmacsOfficeZip CmacsOfficeZip;

/* Default caps.  Generous enough for a real spreadsheet -- a 200 MB
   sheet part is unusual but legitimate -- and small enough that a
   decompression bomb fails fast instead of eating the machine. */
#define CMACS_OFFICE_ZIP_DEFAULT_MAX_PART  ((guint64) 512 * 1024 * 1024)
#define CMACS_OFFICE_ZIP_DEFAULT_MAX_TOTAL ((guint64) 2048 * 1024 * 1024)

/* Lifecycle. */
CmacsOfficeZip *cmacs_office_zip_open (const gchar *path, GError **error);
void            cmacs_office_zip_free (CmacsOfficeZip *zip);

/* Bound how much this package is allowed to inflate to.  Zero on
   either argument means "leave that cap unchanged". */
void cmacs_office_zip_set_limits (CmacsOfficeZip *zip,
                                  guint64 max_part,
                                  guint64 max_total);

/* Introspection. */
const gchar *cmacs_office_zip_path      (CmacsOfficeZip *zip);
guint        cmacs_office_zip_n_parts   (CmacsOfficeZip *zip);
gboolean     cmacs_office_zip_dirty     (CmacsOfficeZip *zip);
gboolean     cmacs_office_zip_has_part  (CmacsOfficeZip *zip, const gchar *name);

/* Part names in archive order, NULL-terminated, transfer full.  Archive
   order matters: ODF requires `mimetype' first, and round-trip
   diffing is far easier when the order is the file's own. */
gchar **cmacs_office_zip_part_names (CmacsOfficeZip *zip, guint *n_out);

/* Uncompressed size as declared by the central directory.  Cheap --
   no inflation -- so it is safe to call before deciding to read. */
gboolean cmacs_office_zip_part_size (CmacsOfficeZip *zip,
                                     const gchar *name,
                                     guint64 *size_out,
                                     GError **error);

/* Read a part.  Pending writes win over on-disk content.  The returned
   buffer is NUL-terminated one byte past `len_out' so it can be handed
   straight to an XML parser as a C string; the NUL is not counted in
   the length.  Transfer full. */
guint8 *cmacs_office_zip_read_part (CmacsOfficeZip *zip,
                                    const gchar *name,
                                    gsize *len_out,
                                    GError **error);

/* Queue a replacement (or an addition) for `name'.  Nothing touches
   the file until save.  Copies `data'. */
gboolean cmacs_office_zip_set_part (CmacsOfficeZip *zip,
                                    const gchar *name,
                                    const guint8 *data,
                                    gsize len,
                                    GError **error);

/* Queue a deletion.  Same deferral. */
gboolean cmacs_office_zip_delete_part (CmacsOfficeZip *zip,
                                       const gchar *name,
                                       GError **error);

/* Drop every pending write without touching the file. */
void cmacs_office_zip_revert (CmacsOfficeZip *zip);

/* Flush pending writes.  `save' rewrites in place; `save_as' copies to
   `dest' first so the original is untouched even if the write fails.
   With nothing pending, `save' does nothing at all and `save_as'
   degrades to a byte-exact file copy. */
gboolean cmacs_office_zip_save    (CmacsOfficeZip *zip, GError **error);
gboolean cmacs_office_zip_save_as (CmacsOfficeZip *zip,
                                   const gchar *dest,
                                   GError **error);

/* Exposed for the validator's own tests: TRUE when `name' is a safe
   package-relative part name (no absolute path, no `..' component, no
   backslash, no NUL, non-empty, within length bounds). */
gboolean cmacs_office_zip_name_valid (const gchar *name);

G_END_DECLS

#endif /* HAVE_CMACS_OFFICE */
#endif /* CMACS_OFFICE_ZIP_H */
