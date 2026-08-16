/* cmacs-office-extract.h --- text extraction for documents and decks.
 *
 * Copyright (C) 2026 Zach Podbielniak
 * SPDX-License-Identifier: AGPL-3.0-or-later
 *
 * Pulls the readable content out of a word processing document or a
 * presentation as a flat list of blocks.  Spreadsheets have a
 * different shape and live in cmacs-office-sheet.h.
 *
 * A block is a paragraph, a heading, or one shape's worth of text on a
 * slide -- deliberately flat rather than a tree, because the point of
 * this phase is to make documents greppable, yankable and readable by
 * an agent, not to model them.  The real models arrive with the
 * editing phases.
 *
 * Anchors.  Every block carries enough to find its way home:
 *
 *   part    which package part it came from
 *   id      a stable identifier the FILE provides -- w14:paraId in
 *           OOXML, text:id or xml:id in ODF -- or NULL when it has none
 *   index   the block's ordinal within its part
 *
 * `id' is preferred because it survives edits elsewhere in the
 * document; `index' is the fallback and only holds while nothing above
 * the block is inserted or deleted.  Writeback in later phases resolves
 * by id first and falls back to index, which is why both are recorded
 * now rather than bolted on later.
 *
 * Tracked deletions are NOT extracted.  Deleted text is still present
 * in the XML (that is the point of tracked changes), and silently
 * including it would produce a projection that does not match what
 * anyone sees in Word or LibreOffice.
 *
 * This TU includes no Emacs headers. */

#ifndef CMACS_OFFICE_EXTRACT_H
#define CMACS_OFFICE_EXTRACT_H

#include <config.h>

#ifdef HAVE_CMACS_OFFICE

#include <glib.h>

#include "cmacs-office-package.h"

G_BEGIN_DECLS

typedef struct
{
  gchar *part;    /* package part this block came from */
  gchar *id;      /* stable id from the file, or NULL */
  gint   index;   /* 0-based ordinal within the part */

  gint   level;   /* heading level, 1..9; 0 for a body paragraph */
  gchar *style;   /* style name as the document names it, or NULL */

  gint   slide;   /* 1-based slide number; 0 when not a presentation */
  gchar *shape;   /* slide shape name, or NULL */

  gchar *text;    /* the readable text; never NULL, may be empty */
} CmacsOfficeBlock;

void cmacs_office_block_free (CmacsOfficeBlock *block);

/* Extract blocks from a word processing document (.docx / .odt).
   Returns a GPtrArray of CmacsOfficeBlock*, in document order. */
GPtrArray *cmacs_office_extract_text (CmacsOfficePackage *pkg, GError **error);

/* Extract blocks from a presentation (.pptx / .odp), in slide order,
   then in shape order within each slide. */
GPtrArray *cmacs_office_extract_slides (CmacsOfficePackage *pkg,
                                        GError **error);

/* Dispatch on the package's kind.  Spreadsheets are not handled here;
   see cmacs_office_sheet_cells. */
GPtrArray *cmacs_office_extract (CmacsOfficePackage *pkg, GError **error);

/* Replace the text of one block, queueing the modified part for the
   next save.
 *
 * The block is located by ID when the file gave it one, falling back to
 * INDEX.  Both come from cmacs_office_extract, and the lookup walks the
 * document with the SAME traversal that produced them -- if the two
 * ever disagreed, an edit would land on the wrong paragraph.
 *
 * Fidelity.  The paragraph keeps its own properties (its style, its
 * outline level) and the character properties of its first run, but
 * formatting that VARIED within the paragraph is flattened: a sentence
 * with one bold word comes back with the replacement text in the first
 * run's style throughout.  Everything outside the paragraph, and every
 * other part of the package, is untouched.
 *
 * Editing needs the part as a tree, so it is subject to the same size
 * ceiling as the spreadsheet editor. */
gboolean cmacs_office_extract_set_block (CmacsOfficePackage *pkg,
                                         const gchar *id,
                                         gint index,
                                         const gchar *text,
                                         GError **error);

/* Replace the text of one slide shape, queueing the modified part.
 *
 * SLIDE is 1-based and INDEX is the shape's ordinal within it, both as
 * cmacs_office_extract reports them.  Same traversal, same numbering.
 *
 * Fidelity matches the document editor: the shape keeps its geometry,
 * its placeholder role and the character properties of its first run,
 * while formatting that varied inside the shape is flattened. */
gboolean cmacs_office_extract_set_slide_text (CmacsOfficePackage *pkg,
                                              gint slide,
                                              gint index,
                                              const gchar *text,
                                              GError **error);

G_END_DECLS

#endif /* HAVE_CMACS_OFFICE */
#endif /* CMACS_OFFICE_EXTRACT_H */
