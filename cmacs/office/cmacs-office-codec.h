/* cmacs-office-codec.h --- the format registry.
 *
 * Copyright (C) 2026 Zach Podbielniak
 * SPDX-License-Identifier: AGPL-3.0-or-later
 *
 * Six formats times three kinds of document is a six-way problem only
 * if each format gets its own everything.  It collapses to three
 * document models plus six thin codecs once the model is the narrow
 * waist, and this table is the registry those codecs live in.
 *
 * Right now a codec carries identity and detection: what the format is
 * called, which document kind it holds, which package family it
 * belongs to, and the two facts that let a file be identified from its
 * CONTENTS rather than its extension -- the ODF `mimetype' string, and
 * the OOXML main-part content types.
 *
 * There are deliberately no load/save function pointers yet.  Adding a
 * vtable slot before there is a document model to load into would be
 * guessing at the signature; the slot arrives with the model, when its
 * shape is known.  What matters for now is that everything
 * format-specific is confined to one table, so adding RTF or legacy
 * .doc later touches this file and nothing else.
 *
 * This TU includes neither lisp.h nor zip.h. */

#ifndef CMACS_OFFICE_CODEC_H
#define CMACS_OFFICE_CODEC_H

#include <config.h>

#ifdef HAVE_CMACS_OFFICE

#include <glib.h>

G_BEGIN_DECLS

/* Which packaging convention: OOXML calls it OPC, OpenDocument calls
   it an ODF package.  Both are a zip of XML parts, but they announce
   themselves differently, which is what detection keys on. */
typedef enum
{
  CMACS_OFFICE_FAMILY_UNKNOWN,
  CMACS_OFFICE_FAMILY_OOXML,
  CMACS_OFFICE_FAMILY_ODF
} CmacsOfficeFamily;

/* What sort of document it is.  This -- not the format -- is what
   decides which model and which major mode a file gets. */
typedef enum
{
  CMACS_OFFICE_KIND_UNKNOWN,
  CMACS_OFFICE_KIND_TEXT,       /* .docx / .odt */
  CMACS_OFFICE_KIND_SHEET,      /* .xlsx / .ods */
  CMACS_OFFICE_KIND_SLIDES      /* .pptx / .odp */
} CmacsOfficeKind;

typedef enum
{
  CMACS_OFFICE_FORMAT_UNKNOWN,
  CMACS_OFFICE_FORMAT_DOCX,
  CMACS_OFFICE_FORMAT_XLSX,
  CMACS_OFFICE_FORMAT_PPTX,
  CMACS_OFFICE_FORMAT_ODT,
  CMACS_OFFICE_FORMAT_ODS,
  CMACS_OFFICE_FORMAT_ODP
} CmacsOfficeFormat;

typedef struct
{
  CmacsOfficeFormat   format;
  CmacsOfficeKind     kind;
  CmacsOfficeFamily   family;

  const gchar        *name;          /* "docx" -- the Lisp-facing symbol */
  const gchar        *description;   /* one line, for humans */
  const gchar        *extension;     /* ".docx" */

  /* Detection.  Exactly one of these is meaningful per family. */
  const gchar *const *odf_mimetypes;  /* ODF: NULL-terminated */
  const gchar *const *ooxml_types;    /* OOXML: main-part content types */

  /* Where the document body lives.  For ODF this is literal; for OOXML
     it is only a hint, because the real answer comes from the package
     relationships (a .docx may name its main part anything). */
  const gchar        *main_part;
} CmacsOfficeCodec;

/* The whole table, NULL-terminated. */
const CmacsOfficeCodec *const *cmacs_office_codecs (guint *n_out);

/* Lookups.  All return NULL when nothing matches. */
const CmacsOfficeCodec *cmacs_office_codec_for_format (CmacsOfficeFormat format);
const CmacsOfficeCodec *cmacs_office_codec_for_name (const gchar *name);
const CmacsOfficeCodec *cmacs_office_codec_for_odf_mimetype (const gchar *mimetype);
const CmacsOfficeCodec *cmacs_office_codec_for_ooxml_type (const gchar *content_type);

/* Stable lower-case names, for the Lisp surface and for messages.
   Never NULL: unknown values render as "unknown". */
const gchar *cmacs_office_format_name (CmacsOfficeFormat format);
const gchar *cmacs_office_kind_name   (CmacsOfficeKind kind);
const gchar *cmacs_office_family_name (CmacsOfficeFamily family);

G_END_DECLS

#endif /* HAVE_CMACS_OFFICE */
#endif /* CMACS_OFFICE_CODEC_H */
