/* cmacs-office-package.c --- OPC / ODF package semantics.
 *
 * Copyright (C) 2026 Zach Podbielniak
 * SPDX-License-Identifier: AGPL-3.0-or-later
 *
 * See cmacs-office-package.h for how the two packaging conventions
 * differ and why detection reads the container rather than the file
 * name. */

#include <config.h>

#ifdef HAVE_CMACS_OFFICE

#include "cmacs-office-package.h"
#include "cmacs-office-xml.h"

#include <string.h>

/* Namespaces.  Matching is by local name plus href, never by prefix. */
#define NS_CONTENT_TYPES \
  "http://schemas.openxmlformats.org/package/2006/content-types"
#define NS_RELATIONSHIPS \
  "http://schemas.openxmlformats.org/package/2006/relationships"
#define NS_ODF_MANIFEST \
  "urn:oasis:names:tc:opendocument:xmlns:manifest:1.0"

/* The relationship that names the document body.  Transitional and
   strict OOXML use different URI stems, so the suffix is what is
   matched. */
#define REL_OFFICE_DOCUMENT_SUFFIX "/officeDocument"

#define PART_CONTENT_TYPES "[Content_Types].xml"
#define PART_ODF_MIMETYPE  "mimetype"
#define PART_ODF_MANIFEST  "META-INF/manifest.xml"
#define PART_ODF_META      "meta.xml"
#define PART_ODF_CONTENT   "content.xml"
#define PART_OOXML_CORE    "docProps/core.xml"
#define PART_OOXML_APP     "docProps/app.xml"

struct _CmacsOfficePackage
{
  CmacsOfficeZip         *zip;

  const CmacsOfficeCodec *codec;      /* NULL when unrecognised */
  CmacsOfficeFamily       family;
  gchar                  *main_part;  /* resolved; NULL when unrecognised */

  /* OOXML content types, parsed once at open. */
  GHashTable             *ct_override; /* part name -> content type */
  GHashTable             *ct_default;  /* lower-case extension -> type */

  /* ODF manifest, parsed once at open. */
  GHashTable             *manifest;    /* full-path -> media-type */
};

void
cmacs_office_rel_free (CmacsOfficeRel *rel)
{
  if (rel == NULL)
    return;
  g_free (rel->id);
  g_free (rel->type);
  g_free (rel->target);
  g_free (rel);
}

/* ------------------------------------------------------------------ */
/* Part-name arithmetic                                                */
/* ------------------------------------------------------------------ */

/* The _rels part that declares SOURCE's relationships.  The package
   root ("" or NULL) keeps its relationships in _rels/.rels; every
   other part P in directory D keeps them in D/_rels/<basename>.rels. */
static gchar *
rels_part_for (const gchar *source)
{
  const gchar *slash;

  if (source == NULL || *source == '\0')
    return g_strdup ("_rels/.rels");

  slash = strrchr (source, '/');
  if (slash == NULL)
    return g_strdup_printf ("_rels/%s.rels", source);

  return g_strdup_printf ("%.*s_rels/%s.rels",
                          (int) (slash - source + 1), source, slash + 1);
}

/* Collapse `.' and `..' segments.  Done on the package-relative name,
   never on a filesystem path -- and the zip layer validates names
   again before any lookup, so a target that tries to climb out of the
   package is rejected there rather than here. */
static gchar *
normalise (const gchar *path)
{
  gchar **parts;
  GPtrArray *out;
  gchar *joined;
  guint i;

  parts = g_strsplit (path, "/", -1);
  out = g_ptr_array_new ();

  for (i = 0; parts[i] != NULL; i++)
    {
      if (parts[i][0] == '\0' || g_strcmp0 (parts[i], ".") == 0)
        continue;
      if (g_strcmp0 (parts[i], "..") == 0)
        {
          if (out->len > 0)
            g_ptr_array_remove_index (out, out->len - 1);
          continue;
        }
      g_ptr_array_add (out, parts[i]);
    }

  g_ptr_array_add (out, NULL);
  joined = g_strjoinv ("/", (gchar **) out->pdata);
  g_ptr_array_free (out, TRUE);
  g_strfreev (parts);

  return joined;
}

gchar *
cmacs_office_package_resolve (const gchar *source_part, const gchar *target)
{
  const gchar *slash;
  gchar *dir, *joined, *out;

  if (target == NULL || *target == '\0')
    return NULL;

  /* A leading slash means package-absolute already. */
  if (target[0] == '/')
    return normalise (target + 1);

  if (source_part == NULL || *source_part == '\0')
    return normalise (target);

  slash = strrchr (source_part, '/');
  if (slash == NULL)
    return normalise (target);

  dir = g_strndup (source_part, (gsize) (slash - source_part + 1));
  joined = g_strconcat (dir, target, NULL);
  out = normalise (joined);
  g_free (joined);
  g_free (dir);

  return out;
}

/* ------------------------------------------------------------------ */
/* Reading a part as XML                                               */
/* ------------------------------------------------------------------ */

static xmlDoc *
part_as_xml (CmacsOfficePackage *pkg, const gchar *part, GError **error)
{
  guint8 *bytes;
  gsize len = 0;
  xmlDoc *doc;

  bytes = cmacs_office_zip_read_part (pkg->zip, part, &len, error);
  if (bytes == NULL)
    return NULL;

  doc = cmacs_office_xml_parse (bytes, len, part, error);
  g_free (bytes);

  return doc;
}

/* ------------------------------------------------------------------ */
/* OOXML: [Content_Types].xml                                          */
/* ------------------------------------------------------------------ */

static void
load_content_types (CmacsOfficePackage *pkg)
{
  xmlDoc *doc;
  xmlNode *root, *n;

  pkg->ct_override = g_hash_table_new_full (g_str_hash, g_str_equal,
                                            g_free, g_free);
  pkg->ct_default = g_hash_table_new_full (g_str_hash, g_str_equal,
                                           g_free, g_free);

  doc = part_as_xml (pkg, PART_CONTENT_TYPES, NULL);
  if (doc == NULL)
    return;

  root = cmacs_office_xml_root (doc);
  for (n = cmacs_office_xml_first (root, NULL, NULL);
       n != NULL;
       n = cmacs_office_xml_next (n, NULL, NULL))
    {
      if (cmacs_office_xml_is (n, "Override", NS_CONTENT_TYPES))
        {
          gchar *name = cmacs_office_xml_attr (n, "PartName");
          gchar *type = cmacs_office_xml_attr (n, "ContentType");

          if (name != NULL && type != NULL)
            /* PartName is package-absolute ("/word/document.xml"); the
               rest of the subsystem names parts without the slash. */
            g_hash_table_replace (pkg->ct_override,
                                  g_strdup (name[0] == '/' ? name + 1 : name),
                                  g_steal_pointer (&type));
          g_free (name);
          g_free (type);
        }
      else if (cmacs_office_xml_is (n, "Default", NS_CONTENT_TYPES))
        {
          gchar *ext = cmacs_office_xml_attr (n, "Extension");
          gchar *type = cmacs_office_xml_attr (n, "ContentType");

          if (ext != NULL && type != NULL)
            g_hash_table_replace (pkg->ct_default,
                                  g_ascii_strdown (ext, -1),
                                  g_steal_pointer (&type));
          g_free (ext);
          g_free (type);
        }
    }

  xmlFreeDoc (doc);
}

/* ------------------------------------------------------------------ */
/* ODF: META-INF/manifest.xml                                          */
/* ------------------------------------------------------------------ */

static void
load_manifest (CmacsOfficePackage *pkg)
{
  xmlDoc *doc;
  xmlNode *root, *n;

  pkg->manifest = g_hash_table_new_full (g_str_hash, g_str_equal,
                                         g_free, g_free);

  doc = part_as_xml (pkg, PART_ODF_MANIFEST, NULL);
  if (doc == NULL)
    return;

  root = cmacs_office_xml_root (doc);
  for (n = cmacs_office_xml_first (root, "file-entry", NS_ODF_MANIFEST);
       n != NULL;
       n = cmacs_office_xml_next (n, "file-entry", NS_ODF_MANIFEST))
    {
      gchar *path = cmacs_office_xml_attr (n, "full-path");
      gchar *type = cmacs_office_xml_attr (n, "media-type");

      if (path != NULL && type != NULL)
        g_hash_table_replace (pkg->manifest, g_steal_pointer (&path),
                              g_steal_pointer (&type));
      g_free (path);
      g_free (type);
    }

  xmlFreeDoc (doc);
}

/* ------------------------------------------------------------------ */
/* Relationships                                                       */
/* ------------------------------------------------------------------ */

GPtrArray *
cmacs_office_package_rels (CmacsOfficePackage *pkg, const gchar *part,
                           GError **error)
{
  GPtrArray *out;
  gchar *rels_part;
  xmlDoc *doc;
  xmlNode *root, *n;

  g_return_val_if_fail (pkg != NULL, NULL);

  out = g_ptr_array_new_with_free_func ((GDestroyNotify) cmacs_office_rel_free);
  rels_part = rels_part_for (part);

  /* No _rels part is normal, not an error: most parts declare none. */
  if (!cmacs_office_zip_has_part (pkg->zip, rels_part))
    {
      g_free (rels_part);
      return out;
    }

  doc = part_as_xml (pkg, rels_part, error);
  if (doc == NULL)
    {
      g_free (rels_part);
      g_ptr_array_unref (out);
      return NULL;
    }

  root = cmacs_office_xml_root (doc);
  for (n = cmacs_office_xml_first (root, "Relationship", NS_RELATIONSHIPS);
       n != NULL;
       n = cmacs_office_xml_next (n, "Relationship", NS_RELATIONSHIPS))
    {
      CmacsOfficeRel *rel = g_new0 (CmacsOfficeRel, 1);
      gchar *target = cmacs_office_xml_attr (n, "Target");
      gchar *mode = cmacs_office_xml_attr (n, "TargetMode");

      rel->id = cmacs_office_xml_attr (n, "Id");
      rel->type = cmacs_office_xml_attr (n, "Type");
      rel->external = (g_strcmp0 (mode, "External") == 0);
      /* An external target is a URI into the wider world; resolving it
         against a package directory would be meaningless. */
      rel->target = rel->external
        ? g_strdup (target ? target : "")
        : cmacs_office_package_resolve (part, target);

      g_free (target);
      g_free (mode);
      g_ptr_array_add (out, rel);
    }

  xmlFreeDoc (doc);
  g_free (rels_part);

  return out;
}

/* ------------------------------------------------------------------ */
/* Detection                                                           */
/* ------------------------------------------------------------------ */

/* ODF states its type outright.  The part is a bare media type with no
   trailing newline by spec, but producers vary, so it is trimmed. */
static gboolean
detect_odf (CmacsOfficePackage *pkg)
{
  guint8 *bytes;
  gsize len = 0;
  gchar *mime;

  if (!cmacs_office_zip_has_part (pkg->zip, PART_ODF_MIMETYPE))
    return FALSE;

  bytes = cmacs_office_zip_read_part (pkg->zip, PART_ODF_MIMETYPE, &len, NULL);
  if (bytes == NULL)
    return FALSE;

  mime = g_strndup ((const gchar *) bytes, len);
  g_strstrip (mime);
  g_free (bytes);

  pkg->family = CMACS_OFFICE_FAMILY_ODF;
  pkg->codec = cmacs_office_codec_for_odf_mimetype (mime);
  g_free (mime);

  if (pkg->codec != NULL)
    pkg->main_part = g_strdup (PART_ODF_CONTENT);

  return TRUE;
}

/* Walk _rels/.rels for the officeDocument relationship and take the
   content type of whatever it points at.  This is the spec-correct
   route, and it is why a .docx whose body is not called
   word/document.xml still resolves. */
static gboolean
detect_ooxml_via_rels (CmacsOfficePackage *pkg)
{
  GPtrArray *rels;
  guint i;
  gboolean found = FALSE;

  rels = cmacs_office_package_rels (pkg, "", NULL);
  if (rels == NULL)
    return FALSE;

  for (i = 0; i < rels->len && !found; i++)
    {
      CmacsOfficeRel *rel = g_ptr_array_index (rels, i);
      const gchar *type;

      if (rel->external || rel->type == NULL || rel->target == NULL)
        continue;
      if (!g_str_has_suffix (rel->type, REL_OFFICE_DOCUMENT_SUFFIX))
        continue;

      type = g_hash_table_lookup (pkg->ct_override, rel->target);
      if (type == NULL)
        continue;

      pkg->codec = cmacs_office_codec_for_ooxml_type (type);
      if (pkg->codec != NULL)
        {
          pkg->main_part = g_strdup (rel->target);
          found = TRUE;
        }
    }

  g_ptr_array_unref (rels);
  return found;
}

/* Fallback: some producers omit or mangle the root relationships.  Any
   Override carrying a known main-part content type identifies the
   document just as well. */
static void
detect_ooxml_via_overrides (CmacsOfficePackage *pkg)
{
  GHashTableIter iter;
  gpointer k, v;

  g_hash_table_iter_init (&iter, pkg->ct_override);
  while (g_hash_table_iter_next (&iter, &k, &v))
    {
      const CmacsOfficeCodec *c = cmacs_office_codec_for_ooxml_type (v);

      if (c != NULL)
        {
          pkg->codec = c;
          pkg->main_part = g_strdup (k);
          return;
        }
    }
}

static void
detect (CmacsOfficePackage *pkg)
{
  if (detect_odf (pkg))
    return;

  if (!cmacs_office_zip_has_part (pkg->zip, PART_CONTENT_TYPES))
    return;                     /* neither convention: stays unknown */

  pkg->family = CMACS_OFFICE_FAMILY_OOXML;
  load_content_types (pkg);

  if (!detect_ooxml_via_rels (pkg))
    detect_ooxml_via_overrides (pkg);
}

/* ------------------------------------------------------------------ */
/* Lifecycle                                                           */
/* ------------------------------------------------------------------ */

CmacsOfficePackage *
cmacs_office_package_open (const gchar *path, GError **error)
{
  CmacsOfficePackage *pkg;
  CmacsOfficeZip *zip;

  zip = cmacs_office_zip_open (path, error);
  if (zip == NULL)
    return NULL;

  pkg = g_new0 (CmacsOfficePackage, 1);
  pkg->zip = zip;
  pkg->family = CMACS_OFFICE_FAMILY_UNKNOWN;

  detect (pkg);

  /* The ODF manifest is only worth parsing once we know it is ODF. */
  if (pkg->family == CMACS_OFFICE_FAMILY_ODF)
    load_manifest (pkg);

  return pkg;
}

void
cmacs_office_package_free (CmacsOfficePackage *pkg)
{
  if (pkg == NULL)
    return;

  g_clear_pointer (&pkg->zip, cmacs_office_zip_free);
  g_clear_pointer (&pkg->ct_override, g_hash_table_unref);
  g_clear_pointer (&pkg->ct_default, g_hash_table_unref);
  g_clear_pointer (&pkg->manifest, g_hash_table_unref);
  g_free (pkg->main_part);
  g_free (pkg);
}

CmacsOfficeZip *
cmacs_office_package_zip (CmacsOfficePackage *pkg)
{
  g_return_val_if_fail (pkg != NULL, NULL);
  return pkg->zip;
}

CmacsOfficeFormat
cmacs_office_package_format (CmacsOfficePackage *pkg)
{
  g_return_val_if_fail (pkg != NULL, CMACS_OFFICE_FORMAT_UNKNOWN);
  return pkg->codec ? pkg->codec->format : CMACS_OFFICE_FORMAT_UNKNOWN;
}

CmacsOfficeKind
cmacs_office_package_kind (CmacsOfficePackage *pkg)
{
  g_return_val_if_fail (pkg != NULL, CMACS_OFFICE_KIND_UNKNOWN);
  return pkg->codec ? pkg->codec->kind : CMACS_OFFICE_KIND_UNKNOWN;
}

CmacsOfficeFamily
cmacs_office_package_family (CmacsOfficePackage *pkg)
{
  g_return_val_if_fail (pkg != NULL, CMACS_OFFICE_FAMILY_UNKNOWN);
  return pkg->family;
}

const CmacsOfficeCodec *
cmacs_office_package_codec (CmacsOfficePackage *pkg)
{
  g_return_val_if_fail (pkg != NULL, NULL);
  return pkg->codec;
}

const gchar *
cmacs_office_package_main_part (CmacsOfficePackage *pkg)
{
  g_return_val_if_fail (pkg != NULL, NULL);
  return pkg->main_part;
}

gchar *
cmacs_office_package_content_type (CmacsOfficePackage *pkg, const gchar *part)
{
  const gchar *hit;
  const gchar *dot;

  g_return_val_if_fail (pkg != NULL, NULL);

  if (part == NULL || *part == '\0')
    return NULL;

  if (pkg->manifest != NULL)
    {
      hit = g_hash_table_lookup (pkg->manifest, part);
      if (hit != NULL)
        return g_strdup (hit);
    }

  if (pkg->ct_override != NULL)
    {
      hit = g_hash_table_lookup (pkg->ct_override, part);
      if (hit != NULL)
        return g_strdup (hit);
    }

  /* OPC falls back to a per-extension default. */
  dot = strrchr (part, '.');
  if (dot != NULL && pkg->ct_default != NULL)
    {
      gchar *ext = g_ascii_strdown (dot + 1, -1);

      hit = g_hash_table_lookup (pkg->ct_default, ext);
      g_free (ext);
      if (hit != NULL)
        return g_strdup (hit);
    }

  return NULL;
}

/* ------------------------------------------------------------------ */
/* Metadata                                                            */
/* ------------------------------------------------------------------ */

/* Both families keep document properties in a small flat XML part with
   near-identical element names under different namespaces, so one walk
   over local names serves both.  The mapping normalises them onto a
   single vocabulary: a caller asking who wrote a document should not
   have to know whether it is OOXML or ODF. */
static const struct
{
  const gchar *element;   /* local name in the meta part */
  const gchar *key;       /* normalised key */
} meta_map[] = {
  { "title",            "title" },
  { "subject",          "subject" },
  { "description",      "description" },
  { "creator",          "creator" },
  { "initial-creator",  "creator" },
  { "lastModifiedBy",   "last-modified-by" },
  { "keywords",         "keywords" },
  { "keyword",          "keywords" },
  { "created",          "created" },
  { "creation-date",    "created" },
  { "modified",         "modified" },
  { "date",             "modified" },
  { "generator",        "generator" },
  { "Application",      "generator" },
  { "Company",          "company" },
  { "language",         "language" }
};

static void
harvest_meta (xmlNode *container, GHashTable *out)
{
  xmlNode *n;

  for (n = cmacs_office_xml_first (container, NULL, NULL);
       n != NULL;
       n = cmacs_office_xml_next (n, NULL, NULL))
    {
      gsize i;

      for (i = 0; i < G_N_ELEMENTS (meta_map); i++)
        {
          gchar *text;

          if (g_strcmp0 ((const gchar *) n->name, meta_map[i].element) != 0)
            continue;

          text = cmacs_office_xml_text (n);
          g_strstrip (text);
          /* First writer wins: core.xml is read before app.xml, and the
             more specific `creator' should not be clobbered by a later
             generic match. */
          if (*text != '\0' && !g_hash_table_contains (out, meta_map[i].key))
            g_hash_table_replace (out, g_strdup (meta_map[i].key),
                                  g_steal_pointer (&text));
          g_free (text);
          break;
        }
    }
}

static void
harvest_part (CmacsOfficePackage *pkg, const gchar *part, gboolean descend,
              GHashTable *out)
{
  xmlDoc *doc;
  xmlNode *root;

  if (!cmacs_office_zip_has_part (pkg->zip, part))
    return;

  doc = part_as_xml (pkg, part, NULL);
  if (doc == NULL)
    return;

  root = cmacs_office_xml_root (doc);
  /* ODF nests the properties one level down, inside office:meta;
     OOXML's core.xml and app.xml put them directly under the root. */
  if (descend)
    {
      xmlNode *meta = cmacs_office_xml_find (root, "meta", NULL);

      if (meta != NULL)
        root = meta;
    }
  harvest_meta (root, out);

  xmlFreeDoc (doc);
}

GHashTable *
cmacs_office_package_metadata (CmacsOfficePackage *pkg, GError **error)
{
  GHashTable *out;

  g_return_val_if_fail (pkg != NULL, NULL);
  (void) error;                 /* a missing meta part is not a failure */

  out = g_hash_table_new_full (g_str_hash, g_str_equal, g_free, g_free);

  if (pkg->family == CMACS_OFFICE_FAMILY_ODF)
    harvest_part (pkg, PART_ODF_META, TRUE, out);
  else
    {
      harvest_part (pkg, PART_OOXML_CORE, FALSE, out);
      harvest_part (pkg, PART_OOXML_APP, FALSE, out);
    }

  return out;
}

#endif /* HAVE_CMACS_OFFICE */
