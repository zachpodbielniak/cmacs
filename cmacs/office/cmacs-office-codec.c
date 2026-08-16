/* cmacs-office-codec.c --- the format registry.
 *
 * Copyright (C) 2026 Zach Podbielniak
 * SPDX-License-Identifier: AGPL-3.0-or-later
 *
 * One table, six entries.  Everything format-specific in the subsystem
 * is supposed to end up here; if a format check starts appearing
 * anywhere else, that is the signal the abstraction is leaking. */

#include <config.h>

#ifdef HAVE_CMACS_OFFICE

#include "cmacs-office-codec.h"

#include <string.h>

/* ODF announces itself in the `mimetype' part.  The -template variants
   are the same document kind with a different intent, so they map to
   the same codec: an .ott is a .odt you are meant to copy. */
static const gchar *const odf_text_mimetypes[] = {
  "application/vnd.oasis.opendocument.text",
  "application/vnd.oasis.opendocument.text-template",
  "application/vnd.oasis.opendocument.text-master",
  NULL
};

static const gchar *const odf_sheet_mimetypes[] = {
  "application/vnd.oasis.opendocument.spreadsheet",
  "application/vnd.oasis.opendocument.spreadsheet-template",
  NULL
};

static const gchar *const odf_slides_mimetypes[] = {
  "application/vnd.oasis.opendocument.presentation",
  "application/vnd.oasis.opendocument.presentation-template",
  NULL
};

/* OOXML announces itself through the content type of its main part.
   The macro-enabled and template variants carry distinct content types
   but the same document structure, so they land on the same codec --
   the macro part itself is simply one more part we never parse and
   therefore never disturb. */
static const gchar *const ooxml_text_types[] = {
  "application/vnd.openxmlformats-officedocument.wordprocessingml.document.main+xml",
  "application/vnd.ms-word.document.macroEnabled.main+xml",
  "application/vnd.openxmlformats-officedocument.wordprocessingml.template.main+xml",
  "application/vnd.ms-word.template.macroEnabledTemplate.main+xml",
  NULL
};

static const gchar *const ooxml_sheet_types[] = {
  "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet.main+xml",
  "application/vnd.ms-excel.sheet.macroEnabled.main+xml",
  "application/vnd.openxmlformats-officedocument.spreadsheetml.template.main+xml",
  "application/vnd.ms-excel.template.macroEnabled.main+xml",
  NULL
};

static const gchar *const ooxml_slides_types[] = {
  "application/vnd.openxmlformats-officedocument.presentationml.presentation.main+xml",
  "application/vnd.ms-powerpoint.presentation.macroEnabled.main+xml",
  "application/vnd.openxmlformats-officedocument.presentationml.template.main+xml",
  "application/vnd.openxmlformats-officedocument.presentationml.slideshow.main+xml",
  "application/vnd.ms-powerpoint.slideshow.macroEnabled.main+xml",
  NULL
};

static const CmacsOfficeCodec codec_docx = {
  CMACS_OFFICE_FORMAT_DOCX, CMACS_OFFICE_KIND_TEXT, CMACS_OFFICE_FAMILY_OOXML,
  "docx", "Office Open XML word processing document", ".docx",
  NULL, ooxml_text_types, "word/document.xml"
};

static const CmacsOfficeCodec codec_xlsx = {
  CMACS_OFFICE_FORMAT_XLSX, CMACS_OFFICE_KIND_SHEET, CMACS_OFFICE_FAMILY_OOXML,
  "xlsx", "Office Open XML spreadsheet", ".xlsx",
  NULL, ooxml_sheet_types, "xl/workbook.xml"
};

static const CmacsOfficeCodec codec_pptx = {
  CMACS_OFFICE_FORMAT_PPTX, CMACS_OFFICE_KIND_SLIDES, CMACS_OFFICE_FAMILY_OOXML,
  "pptx", "Office Open XML presentation", ".pptx",
  NULL, ooxml_slides_types, "ppt/presentation.xml"
};

static const CmacsOfficeCodec codec_odt = {
  CMACS_OFFICE_FORMAT_ODT, CMACS_OFFICE_KIND_TEXT, CMACS_OFFICE_FAMILY_ODF,
  "odt", "OpenDocument text document", ".odt",
  odf_text_mimetypes, NULL, "content.xml"
};

static const CmacsOfficeCodec codec_ods = {
  CMACS_OFFICE_FORMAT_ODS, CMACS_OFFICE_KIND_SHEET, CMACS_OFFICE_FAMILY_ODF,
  "ods", "OpenDocument spreadsheet", ".ods",
  odf_sheet_mimetypes, NULL, "content.xml"
};

static const CmacsOfficeCodec codec_odp = {
  CMACS_OFFICE_FORMAT_ODP, CMACS_OFFICE_KIND_SLIDES, CMACS_OFFICE_FAMILY_ODF,
  "odp", "OpenDocument presentation", ".odp",
  odf_slides_mimetypes, NULL, "content.xml"
};

static const CmacsOfficeCodec *const office_codecs[] = {
  &codec_docx, &codec_xlsx, &codec_pptx,
  &codec_odt,  &codec_ods,  &codec_odp,
  NULL
};

#define OFFICE_N_CODECS \
  ((guint) (G_N_ELEMENTS (office_codecs) - 1))

const CmacsOfficeCodec *const *
cmacs_office_codecs (guint *n_out)
{
  if (n_out != NULL)
    *n_out = OFFICE_N_CODECS;
  return office_codecs;
}

const CmacsOfficeCodec *
cmacs_office_codec_for_format (CmacsOfficeFormat format)
{
  guint i;

  for (i = 0; i < OFFICE_N_CODECS; i++)
    if (office_codecs[i]->format == format)
      return office_codecs[i];

  return NULL;
}

const CmacsOfficeCodec *
cmacs_office_codec_for_name (const gchar *name)
{
  guint i;

  if (name == NULL)
    return NULL;

  for (i = 0; i < OFFICE_N_CODECS; i++)
    if (g_ascii_strcasecmp (office_codecs[i]->name, name) == 0)
      return office_codecs[i];

  return NULL;
}

const CmacsOfficeCodec *
cmacs_office_codec_for_odf_mimetype (const gchar *mimetype)
{
  guint i;

  if (mimetype == NULL)
    return NULL;

  for (i = 0; i < OFFICE_N_CODECS; i++)
    {
      const gchar *const *m = office_codecs[i]->odf_mimetypes;
      guint k;

      if (m == NULL)
        continue;
      for (k = 0; m[k] != NULL; k++)
        if (g_strcmp0 (m[k], mimetype) == 0)
          return office_codecs[i];
    }

  return NULL;
}

const CmacsOfficeCodec *
cmacs_office_codec_for_ooxml_type (const gchar *content_type)
{
  guint i;

  if (content_type == NULL)
    return NULL;

  for (i = 0; i < OFFICE_N_CODECS; i++)
    {
      const gchar *const *t = office_codecs[i]->ooxml_types;
      guint k;

      if (t == NULL)
        continue;
      for (k = 0; t[k] != NULL; k++)
        if (g_strcmp0 (t[k], content_type) == 0)
          return office_codecs[i];
    }

  return NULL;
}

const gchar *
cmacs_office_format_name (CmacsOfficeFormat format)
{
  const CmacsOfficeCodec *c = cmacs_office_codec_for_format (format);

  return c ? c->name : "unknown";
}

const gchar *
cmacs_office_kind_name (CmacsOfficeKind kind)
{
  switch (kind)
    {
    case CMACS_OFFICE_KIND_TEXT:   return "text";
    case CMACS_OFFICE_KIND_SHEET:  return "sheet";
    case CMACS_OFFICE_KIND_SLIDES: return "slides";
    case CMACS_OFFICE_KIND_UNKNOWN:
    default:                       return "unknown";
    }
}

const gchar *
cmacs_office_family_name (CmacsOfficeFamily family)
{
  switch (family)
    {
    case CMACS_OFFICE_FAMILY_OOXML: return "ooxml";
    case CMACS_OFFICE_FAMILY_ODF:   return "odf";
    case CMACS_OFFICE_FAMILY_UNKNOWN:
    default:                        return "unknown";
    }
}

#endif /* HAVE_CMACS_OFFICE */
