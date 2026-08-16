/* cmacs-office-package.h --- OPC / ODF package semantics.
 *
 * Copyright (C) 2026 Zach Podbielniak
 * SPDX-License-Identifier: AGPL-3.0-or-later
 *
 * cmacs-office-zip.c knows a package is a zip.  This layer knows what
 * the zip MEANS: which part is the document body, what type each part
 * is, what points at what, and who wrote it.
 *
 * The two families answer those questions differently and this is the
 * only file that cares:
 *
 *   OOXML (OPC)   [Content_Types].xml maps parts to content types, and
 *                 _rels/.rels names the "officeDocument" relationship
 *                 whose target IS the body.  The body part is NOT
 *                 required to be called word/document.xml, so it is
 *                 resolved rather than assumed.
 *
 *   OpenDocument  A stored `mimetype' part states the document type
 *                 outright, META-INF/manifest.xml types every part,
 *                 and the body is always content.xml.
 *
 * Detection reads the CONTAINER, never the file extension, so a
 * mis-named file still opens as what it actually is.  A package that
 * matches neither convention still opens -- with format, kind and
 * family reported as unknown -- because being able to inspect an odd
 * zip is more useful than refusing it.
 *
 * Metadata from both families is normalised onto one vocabulary
 * (title, creator, created, ...), so callers never branch on format to
 * ask who wrote a document.
 *
 * This TU includes no Emacs headers. */

#ifndef CMACS_OFFICE_PACKAGE_H
#define CMACS_OFFICE_PACKAGE_H

#include <config.h>

#ifdef HAVE_CMACS_OFFICE

#include <glib.h>

#include "cmacs-office-codec.h"
#include "cmacs-office-zip.h"

G_BEGIN_DECLS

/* OPC has TWO relationship namespaces and confusing them silently
   finds nothing:

     package/2006/relationships        the <Relationships> elements
                                       inside a _rels part (private to
                                       cmacs-office-package.c)
     officeDocument/2006/relationships the `r:' prefix used for r:id
                                       attributes in document parts
                                       (this one)

   Exported because `r:id' must be looked up by namespace rather than by
   local name: a <p:sldId> carries both an unprefixed `id' -- the
   slide's own number -- and an `r:id' naming its part. */
#define CMACS_OFFICE_NS_DOC_RELATIONSHIPS \
  "http://schemas.openxmlformats.org/officeDocument/2006/relationships"

/* Editing any part needs it as a tree, so a part above this is refused
   rather than allowed to exhaust memory.  Reading is not limited this
   way -- only the write path has to hold the whole thing at once. */
#define CMACS_OFFICE_MAX_EDIT_DOM ((guint64) 64 * 1024 * 1024)

typedef struct _CmacsOfficePackage CmacsOfficePackage;

/* One OPC relationship.  ODF packages have no equivalent, so
   cmacs_office_package_rels returns an empty array for them. */
typedef struct
{
  gchar   *id;       /* rId3 */
  gchar   *type;     /* the full relationship type URI */
  gchar   *target;   /* package-absolute part name, or a URI when external */
  gboolean external; /* TargetMode="External": target is a URI, not a part */
} CmacsOfficeRel;

void cmacs_office_rel_free (CmacsOfficeRel *rel);

/* Lifecycle.  The package owns its zip. */
CmacsOfficePackage *cmacs_office_package_open (const gchar *path,
                                               GError **error);
void                cmacs_office_package_free (CmacsOfficePackage *pkg);

/* The container underneath, borrowed.  Part-level reads and writes go
   through this; the package layer holds no copy of part contents. */
CmacsOfficeZip *cmacs_office_package_zip (CmacsOfficePackage *pkg);

/* Identity, determined from the container's contents at open time. */
CmacsOfficeFormat       cmacs_office_package_format (CmacsOfficePackage *pkg);
CmacsOfficeKind         cmacs_office_package_kind   (CmacsOfficePackage *pkg);
CmacsOfficeFamily       cmacs_office_package_family (CmacsOfficePackage *pkg);
const CmacsOfficeCodec *cmacs_office_package_codec  (CmacsOfficePackage *pkg);

/* The document body's part name, resolved rather than assumed.  NULL
   when the package was not recognised. */
const gchar *cmacs_office_package_main_part (CmacsOfficePackage *pkg);

/* Content type of PART: an OPC Override, else the Default for its
   extension, else the ODF manifest's media-type.  NULL when unknown.
   Transfer full. */
gchar *cmacs_office_package_content_type (CmacsOfficePackage *pkg,
                                          const gchar *part);

/* Relationships declared BY a part.  Pass "" for the package root
   (_rels/.rels).  Returns a GPtrArray of CmacsOfficeRel* -- empty, not
   NULL, when the part simply has no relationships.  Transfer full. */
GPtrArray *cmacs_office_package_rels (CmacsOfficePackage *pkg,
                                      const gchar *part,
                                      GError **error);

/* Document properties, normalised across both families onto shared
   keys: title, subject, description, creator, last-modified-by,
   keywords, created, modified, generator.  Absent properties are
   simply absent.  Transfer full; a GHashTable of gchar* to gchar*. */
GHashTable *cmacs_office_package_metadata (CmacsOfficePackage *pkg,
                                           GError **error);

/* Resolve a relationship target against the directory of the part that
   declared it, the way OPC requires.  Exposed because the rule is easy
   to get wrong and worth testing directly.  Transfer full. */
gchar *cmacs_office_package_resolve (const gchar *source_part,
                                     const gchar *target);

G_END_DECLS

#endif /* HAVE_CMACS_OFFICE */
#endif /* CMACS_OFFICE_PACKAGE_H */
