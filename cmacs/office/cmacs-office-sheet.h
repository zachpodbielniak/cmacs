/* cmacs-office-sheet.h --- spreadsheet cell extraction.
 *
 * Copyright (C) 2026 Zach Podbielniak
 * SPDX-License-Identifier: AGPL-3.0-or-later
 *
 * Spreadsheets do not fit the flat block model that documents and
 * decks share: a cell has a position, a display value and possibly a
 * formula, and its address is the anchor.  So they extract here.
 *
 * Only cells that carry something are emitted.  That matters more than
 * it sounds: LibreOffice pads rows out to a thousand-odd empty cells
 * with repeat counts, and a reader that honoured those literally would
 * produce millions of blank entries for a ten-cell sheet.
 *
 * Phase 2 scope.  This reads through a DOM, which is fine for ordinary
 * sheets and wrong for enormous ones -- so a sheet part above
 * CMACS_OFFICE_SHEET_MAX_DOM is refused with a clear error rather than
 * being allowed to exhaust memory.  The streaming reader that lifts
 * that limit arrives with the editing phase, along with the sparse
 * cell store it feeds.
 *
 * This TU includes no Emacs headers. */

#ifndef CMACS_OFFICE_SHEET_H
#define CMACS_OFFICE_SHEET_H

#include <config.h>

#ifdef HAVE_CMACS_OFFICE

#include <glib.h>

#include "cmacs-office-package.h"

G_BEGIN_DECLS

/* Above this, a sheet part is refused rather than parsed into a DOM.
   Shared with the other editors -- the constraint is "a part has to fit
   in memory as a tree", not anything about spreadsheets. */
#define CMACS_OFFICE_SHEET_MAX_DOM CMACS_OFFICE_MAX_EDIT_DOM

/* Repeated cells and rows are capped: a repeat count is a compression
   device, not a promise that anyone wants that many copies. */
#define CMACS_OFFICE_SHEET_MAX_REPEAT 4096

typedef struct
{
  gchar *sheet;    /* sheet name as the workbook names it */
  gint   row;      /* 1-based */
  gint   col;      /* 1-based */
  gchar *ref;      /* "A1" style address */
  gchar *text;     /* display text; never NULL */
  gchar *formula;  /* source formula, or NULL */
} CmacsOfficeCell;

void cmacs_office_cell_free (CmacsOfficeCell *cell);

/* Sheet names in workbook order.  A GPtrArray of gchar*. */
GPtrArray *cmacs_office_sheet_names (CmacsOfficePackage *pkg, GError **error);

/* Every non-empty cell, sheet by sheet in workbook order, then row
   then column.  A GPtrArray of CmacsOfficeCell*. */
GPtrArray *cmacs_office_sheet_cells (CmacsOfficePackage *pkg, GError **error);

/* Address helpers.  Column 1 is "A".  Exposed because off-by-ones here
   are easy and worth testing directly. */
gchar   *cmacs_office_sheet_ref   (gint row, gint col);
gboolean cmacs_office_sheet_parse (const gchar *ref, gint *row, gint *col);

/* The package part holding SHEET's cell data.  For OpenDocument every
   sheet lives in content.xml; for OOXML each is its own part, named by
   a relationship rather than by convention.  Transfer full; NULL when
   there is no such sheet. */
gchar *cmacs_office_sheet_part (CmacsOfficePackage *pkg,
                                const gchar *sheet,
                                GError **error);

/* Set one cell, queueing the modified part for the next save.
 *
 * TEXT is the display value; NULL or empty clears the cell.  FORMULA is
 * the source formula without its leading `=', or NULL.
 *
 * The edit is SURGICAL: the sheet part is parsed, the one cell element
 * is rewritten in place, and the part is re-serialised.  Everything
 * else in that part -- styles, column widths, merges, conditional
 * formatting, anything this build does not model -- is carried through
 * untouched, and every OTHER part of the package is never even read.
 *
 * Because it needs a tree, editing keeps the CMACS_OFFICE_SHEET_MAX_DOM
 * ceiling that streaming reads do not.  That is a deliberate trade:
 * regenerating a sheet part from a cell model would lift the ceiling
 * but would silently drop everything the model does not represent. */
gboolean cmacs_office_sheet_set_cell (CmacsOfficePackage *pkg,
                                      const gchar *sheet,
                                      gint row,
                                      gint col,
                                      const gchar *text,
                                      const gchar *formula,
                                      GError **error);

G_END_DECLS

#endif /* HAVE_CMACS_OFFICE */
#endif /* CMACS_OFFICE_SHEET_H */
