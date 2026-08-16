/* cmacs-office-extract.c --- text extraction for documents and decks.
 *
 * Copyright (C) 2026 Zach Podbielniak
 * SPDX-License-Identifier: AGPL-3.0-or-later
 *
 * See cmacs-office-extract.h for the block model and the anchor
 * scheme.  Two families, two kinds, one flat output shape. */

#include <config.h>

#ifdef HAVE_CMACS_OFFICE

#include "cmacs-office-extract.h"
#include "cmacs-office-xml.h"

#include <string.h>

/* OOXML namespaces. */
#define NS_W \
  "http://schemas.openxmlformats.org/wordprocessingml/2006/main"
/* Slide text lives in DrawingML `a:t' elements, but it is matched by
   local name rather than by namespace -- the collector walks whatever
   is inside a shape, and the drawing namespace never needs naming. */
#define NS_P \
  "http://schemas.openxmlformats.org/presentationml/2006/main"

/* OpenDocument namespaces. */
#define NS_ODF_OFFICE "urn:oasis:names:tc:opendocument:xmlns:office:1.0"
#define NS_ODF_TEXT   "urn:oasis:names:tc:opendocument:xmlns:text:1.0"
#define NS_ODF_DRAW   "urn:oasis:names:tc:opendocument:xmlns:drawing:1.0"

#define REL_SLIDE_SUFFIX "/slide"

void
cmacs_office_block_free (CmacsOfficeBlock *block)
{
  if (block == NULL)
    return;
  g_free (block->part);
  g_free (block->id);
  g_free (block->style);
  g_free (block->shape);
  g_free (block->text);
  g_free (block);
}

static GPtrArray *
blocks_new (void)
{
  return g_ptr_array_new_with_free_func ((GDestroyNotify) cmacs_office_block_free);
}

/* ------------------------------------------------------------------ */
/* Text collection                                                     */
/* ------------------------------------------------------------------ */

/* Walk a subtree gathering the text that a reader would actually see.
 *
 * KEEP names the elements whose character data counts (w:t for OOXML,
 * NULL for ODF where the text is inline).  SKIP names subtrees to step
 * over entirely -- tracked deletions and comment bodies, which are in
 * the XML but are not part of the document as displayed.  Extracting
 * them would produce a projection that silently disagrees with Word
 * and LibreOffice. */
static void
collect_text (xmlNode *node, const gchar *keep, const gchar *const *skip,
              GString *out)
{
  xmlNode *n;

  for (n = node ? node->children : NULL; n != NULL; n = n->next)
    {
      if (n->type == XML_TEXT_NODE || n->type == XML_CDATA_SECTION_NODE)
        {
          /* Only meaningful when there is no `keep' filter: with one,
             text is taken from the keep elements alone. */
          if (keep == NULL && n->content != NULL)
            g_string_append (out, (const gchar *) n->content);
          continue;
        }

      if (n->type != XML_ELEMENT_NODE)
        continue;

      if (skip != NULL)
        {
          gboolean skipped = FALSE;
          guint i;

          for (i = 0; skip[i] != NULL; i++)
            if (g_strcmp0 ((const gchar *) n->name, skip[i]) == 0)
              {
                skipped = TRUE;
                break;
              }
          if (skipped)
            continue;
        }

      if (keep != NULL && g_strcmp0 ((const gchar *) n->name, keep) == 0)
        {
          gchar *t = cmacs_office_xml_text (n);

          g_string_append (out, t);
          g_free (t);
          continue;
        }

      /* A tab is a visible break between fields in both families; a
         line break inside a paragraph likewise.  Without these, table
         rows and multi-line paragraphs collapse into one run-on. */
      if (g_strcmp0 ((const gchar *) n->name, "tab") == 0)
        g_string_append_c (out, '\t');
      else if (g_strcmp0 ((const gchar *) n->name, "br") == 0
               || g_strcmp0 ((const gchar *) n->name, "line-break") == 0)
        g_string_append_c (out, '\n');

      collect_text (n, keep, skip, out);
    }
}

static gchar *
text_of (xmlNode *node, const gchar *keep, const gchar *const *skip)
{
  GString *s = g_string_new (NULL);

  collect_text (node, keep, skip, s);
  return g_string_free (s, FALSE);
}

/* ------------------------------------------------------------------ */
/* Reading a part                                                      */
/* ------------------------------------------------------------------ */

static xmlDoc *
read_xml (CmacsOfficePackage *pkg, const gchar *part, GError **error)
{
  CmacsOfficeZip *zip = cmacs_office_package_zip (pkg);
  guint8 *bytes;
  gsize len = 0;
  xmlDoc *doc;

  bytes = cmacs_office_zip_read_part (zip, part, &len, error);
  if (bytes == NULL)
    return NULL;

  doc = cmacs_office_xml_parse (bytes, len, part, error);
  g_free (bytes);
  return doc;
}

/* ------------------------------------------------------------------ */
/* Traversal                                                           */
/* ------------------------------------------------------------------ */

/* Extraction and editing MUST agree on what the Nth block is, or an
   edit lands on the wrong paragraph.  The only way to guarantee that
   is for both to use one traversal, so the walkers below take a
   visitor rather than being duplicated per caller. */
typedef void (*BlockFn) (xmlNode *node, const gchar *part, gint index,
                         gpointer user);

typedef struct
{
  GPtrArray *out;          /* collecting: where blocks accumulate */
  const gchar *want_id;    /* finding: the id to match, or NULL */
  gint want_index;         /* finding: the ordinal to match */
  xmlNode *found;          /* finding: the hit */
  const gchar *id_attr;    /* which attribute carries the id */
} BlockCtx;

/* Match by id when the file supplied one, else by ordinal.  Preferring
   the id is what makes an anchor survive edits made above it. */
static void
find_block (xmlNode *node, const gchar *part, gint index, gpointer user)
{
  BlockCtx *ctx = user;

  (void) part;
  if (ctx->found != NULL)
    return;

  if (ctx->want_id != NULL)
    {
      gchar *id = cmacs_office_xml_attr (node, ctx->id_attr);
      gboolean hit = (id != NULL && g_strcmp0 (id, ctx->want_id) == 0);

      g_free (id);
      if (hit)
        {
          ctx->found = node;
          return;
        }
    }
  else if (index == ctx->want_index)
    ctx->found = node;
}

/* ------------------------------------------------------------------ */
/* Word processing: .docx                                              */
/* ------------------------------------------------------------------ */

/* Word records a heading as a paragraph style named "Heading 3" or
   "Heading3" (and localised builds vary further).  There is no
   structural marker, so the style name is all there is to go on. */
static gint
docx_heading_level (const gchar *style)
{
  const gchar *digits;

  if (style == NULL)
    return 0;
  if (!g_str_has_prefix (style, "Heading") && !g_str_has_prefix (style, "heading"))
    return 0;

  digits = style + strlen ("Heading");
  while (*digits == ' ')
    digits++;
  if (*digits >= '1' && *digits <= '9' && digits[1] == '\0')
    return *digits - '0';

  return 0;
}

/* Deleted runs and comment/footnote bodies are present in the XML but
   are not the document's visible text. */
static const gchar *const docx_skip[] = { "del", "commentRangeStart", NULL };

static void
docx_paragraph (xmlNode *p, const gchar *part, gint index, gpointer user)
{
  BlockCtx *ctx = user;
  GPtrArray *out = ctx->out;
  CmacsOfficeBlock *b;
  xmlNode *ppr;

  b = g_new0 (CmacsOfficeBlock, 1);

  b->part = g_strdup (part);
  b->index = index;
  b->id = cmacs_office_xml_attr (p, "paraId");   /* w14:paraId */
  b->text = text_of (p, "t", docx_skip);

  ppr = cmacs_office_xml_child (p, "pPr", NS_W);
  if (ppr != NULL)
    {
      xmlNode *style = cmacs_office_xml_child (ppr, "pStyle", NS_W);

      if (style != NULL)
        b->style = cmacs_office_xml_attr (style, "val");
    }
  b->level = docx_heading_level (b->style);

  g_ptr_array_add (out, b);
}

/* Paragraphs nest inside tables, so the body is walked recursively
   rather than one level deep.  The ordinal is shared across the whole
   part, which is what makes it usable as an anchor. */
static void
docx_walk (xmlNode *node, const gchar *part, gint *index, BlockFn fn,
           gpointer user)
{
  xmlNode *n;

  for (n = cmacs_office_xml_first (node, NULL, NULL);
       n != NULL;
       n = cmacs_office_xml_next (n, NULL, NULL))
    {
      if (cmacs_office_xml_is (n, "p", NS_W))
        {
          fn (n, part, *index, user);
          (*index)++;
        }
      else if (cmacs_office_xml_is (n, "tbl", NS_W)
               || cmacs_office_xml_is (n, "tr", NS_W)
               || cmacs_office_xml_is (n, "tc", NS_W)
               || cmacs_office_xml_is (n, "sdt", NS_W)
               || cmacs_office_xml_is (n, "sdtContent", NS_W))
        docx_walk (n, part, index, fn, user);
    }
}

static gboolean
extract_docx (CmacsOfficePackage *pkg, GPtrArray *out, GError **error)
{
  const gchar *part = cmacs_office_package_main_part (pkg);
  xmlDoc *doc;
  xmlNode *body;
  gint index = 0;

  if (part == NULL)
    return TRUE;

  doc = read_xml (pkg, part, error);
  if (doc == NULL)
    return FALSE;

  body = cmacs_office_xml_child (cmacs_office_xml_root (doc), "body", NS_W);
  {
    BlockCtx ctx = { out, NULL, -1, NULL, "paraId" };

    docx_walk (body, part, &index, docx_paragraph, &ctx);
  }

  xmlFreeDoc (doc);
  return TRUE;
}

/* ------------------------------------------------------------------ */
/* Word processing: .odt                                               */
/* ------------------------------------------------------------------ */

/* Annotations carry their own paragraphs, and tracked deletions live
   under text:tracked-changes; neither is visible body text. */
static const gchar *const odf_skip[] = {
  "annotation", "tracked-changes", "note-body", NULL
};

static void
odf_paragraph_1 (xmlNode *p, const gchar *part, gint index, gboolean heading,
                 GPtrArray *out)
{
  CmacsOfficeBlock *b = g_new0 (CmacsOfficeBlock, 1);

  b->part = g_strdup (part);
  b->index = index;
  /* ODF gives paragraphs an id only when something references them, so
     this is often absent -- which is exactly why index exists. */
  b->id = cmacs_office_xml_attr (p, "id");
  b->style = cmacs_office_xml_attr (p, "style-name");
  b->text = text_of (p, NULL, odf_skip);

  if (heading)
    {
      gchar *lvl = cmacs_office_xml_attr (p, "outline-level");

      b->level = lvl ? (gint) g_ascii_strtoll (lvl, NULL, 10) : 1;
      if (b->level < 1)
        b->level = 1;
      g_free (lvl);
    }

  g_ptr_array_add (out, b);
}

/* The visitor signature carries no heading flag, so it is recovered
   from the element itself -- text:h is a heading, text:p is not. */
static void
odf_paragraph (xmlNode *p, const gchar *part, gint index, gpointer user)
{
  BlockCtx *ctx = user;

  odf_paragraph_1 (p, part, index,
                   cmacs_office_xml_is (p, "h", NS_ODF_TEXT), ctx->out);
}

static void
odf_walk (xmlNode *node, const gchar *part, gint *index, BlockFn fn,
          gpointer user)
{
  xmlNode *n;

  for (n = cmacs_office_xml_first (node, NULL, NULL);
       n != NULL;
       n = cmacs_office_xml_next (n, NULL, NULL))
    {
      if (cmacs_office_xml_is (n, "h", NS_ODF_TEXT)
          || cmacs_office_xml_is (n, "p", NS_ODF_TEXT))
        {
          fn (n, part, *index, user);
          (*index)++;
        }
      else if (cmacs_office_xml_is (n, "list", NS_ODF_TEXT)
               || cmacs_office_xml_is (n, "list-item", NS_ODF_TEXT)
               || cmacs_office_xml_is (n, "section", NS_ODF_TEXT)
               || g_strcmp0 ((const gchar *) n->name, "table") == 0
               || g_strcmp0 ((const gchar *) n->name, "table-row") == 0
               || g_strcmp0 ((const gchar *) n->name, "table-cell") == 0)
        odf_walk (n, part, index, fn, user);
    }
}

static gboolean
extract_odt (CmacsOfficePackage *pkg, GPtrArray *out, GError **error)
{
  const gchar *part = cmacs_office_package_main_part (pkg);
  xmlDoc *doc;
  xmlNode *body, *text;
  gint index = 0;

  if (part == NULL)
    return TRUE;

  doc = read_xml (pkg, part, error);
  if (doc == NULL)
    return FALSE;

  body = cmacs_office_xml_child (cmacs_office_xml_root (doc),
                                 "body", NS_ODF_OFFICE);
  text = cmacs_office_xml_child (body, "text", NS_ODF_OFFICE);
  {
    BlockCtx ctx = { out, NULL, -1, NULL, "id" };

    odf_walk (text, part, &index, odf_paragraph, &ctx);
  }

  xmlFreeDoc (doc);
  return TRUE;
}

/* ------------------------------------------------------------------ */
/* Presentations: .pptx                                                */
/* ------------------------------------------------------------------ */

/* Slide order lives in presentation.xml as a list of relationship ids;
   the parts themselves are named by those relationships.  Walking
   ppt/slides/ in filename order would get slide10 before slide2. */
static GPtrArray *
pptx_slide_parts (CmacsOfficePackage *pkg, GError **error)
{
  const gchar *main_part = cmacs_office_package_main_part (pkg);
  GPtrArray *parts = g_ptr_array_new_with_free_func (g_free);
  GPtrArray *rels;
  xmlDoc *doc;
  xmlNode *lst, *n;
  GHashTable *by_id;
  guint i;

  if (main_part == NULL)
    return parts;

  rels = cmacs_office_package_rels (pkg, main_part, error);
  if (rels == NULL)
    {
      g_ptr_array_unref (parts);
      return NULL;
    }

  by_id = g_hash_table_new (g_str_hash, g_str_equal);
  for (i = 0; i < rels->len; i++)
    {
      CmacsOfficeRel *r = g_ptr_array_index (rels, i);

      if (r->id != NULL && r->target != NULL && !r->external
          && r->type != NULL && g_str_has_suffix (r->type, REL_SLIDE_SUFFIX))
        g_hash_table_insert (by_id, r->id, r->target);
    }

  doc = read_xml (pkg, main_part, error);
  if (doc == NULL)
    {
      g_hash_table_destroy (by_id);
      g_ptr_array_unref (rels);
      g_ptr_array_unref (parts);
      return NULL;
    }

  lst = cmacs_office_xml_child (cmacs_office_xml_root (doc), "sldIdLst", NS_P);
  for (n = cmacs_office_xml_first (lst, "sldId", NS_P);
       n != NULL;
       n = cmacs_office_xml_next (n, "sldId", NS_P))
    {
      /* MUST be namespace-qualified.  <p:sldId id="256" r:id="rId3"/>
         carries two attributes with local name "id"; the unprefixed one
         is the slide's own number and names no part at all. */
      gchar *rid = cmacs_office_xml_attr_ns (n, "id",
                                             CMACS_OFFICE_NS_DOC_RELATIONSHIPS);
      const gchar *target;

      target = rid ? g_hash_table_lookup (by_id, rid) : NULL;
      if (target != NULL)
        g_ptr_array_add (parts, g_strdup (target));
      g_free (rid);
    }

  xmlFreeDoc (doc);
  g_hash_table_destroy (by_id);
  g_ptr_array_unref (rels);

  return parts;
}

static void
pptx_shapes (xmlNode *node, const gchar *part, gint slide, gint *index,
             GPtrArray *out)
{
  xmlNode *n;

  for (n = cmacs_office_xml_first (node, NULL, NULL);
       n != NULL;
       n = cmacs_office_xml_next (n, NULL, NULL))
    {
      if (cmacs_office_xml_is (n, "sp", NS_P)
          || cmacs_office_xml_is (n, "graphicFrame", NS_P)
          || cmacs_office_xml_is (n, "pic", NS_P))
        {
          gchar *text = text_of (n, "t", NULL);

          if (*text != '\0')
            {
              CmacsOfficeBlock *b = g_new0 (CmacsOfficeBlock, 1);
              xmlNode *nv = cmacs_office_xml_find (n, "cNvPr", NS_P);

              b->part = g_strdup (part);
              b->slide = slide;
              b->index = *index;
              b->text = g_steal_pointer (&text);
              if (nv != NULL)
                {
                  b->shape = cmacs_office_xml_attr (nv, "name");
                  b->id = cmacs_office_xml_attr (nv, "id");
                }
              g_ptr_array_add (out, b);
              (*index)++;
            }
          g_free (text);
        }
      else if (cmacs_office_xml_is (n, "grpSp", NS_P)
               || cmacs_office_xml_is (n, "spTree", NS_P))
        pptx_shapes (n, part, slide, index, out);
    }
}

static gboolean
extract_pptx (CmacsOfficePackage *pkg, GPtrArray *out, GError **error)
{
  GPtrArray *parts;
  guint i;

  parts = pptx_slide_parts (pkg, error);
  if (parts == NULL)
    return FALSE;

  for (i = 0; i < parts->len; i++)
    {
      const gchar *part = g_ptr_array_index (parts, i);
      xmlDoc *doc = read_xml (pkg, part, NULL);
      xmlNode *tree;
      gint index = 0;

      if (doc == NULL)
        continue;               /* a damaged slide should not lose the deck */

      tree = cmacs_office_xml_find (cmacs_office_xml_root (doc),
                                    "spTree", NS_P);
      pptx_shapes (tree, part, (gint) i + 1, &index, out);
      xmlFreeDoc (doc);
    }

  g_ptr_array_unref (parts);
  return TRUE;
}

/* ------------------------------------------------------------------ */
/* Presentations: .odp                                                 */
/* ------------------------------------------------------------------ */

/* Which children of a draw:page can hold text.
 *
 * NOT just draw:frame.  LibreOffice writes a plain text box as
 * draw:frame, but anything that came from PowerPoint arrives as
 * draw:custom-shape -- so a reader that only knew about frames would
 * silently return nothing for half the decks in the world.
 *
 * presentation:notes is deliberately excluded: speaker notes are a
 * separate surface, and folding them into the slide's text would put
 * words on the slide that nobody put there. */
static gboolean
odp_is_shape (xmlNode *n)
{
  static const gchar *const shapes[] = {
    "frame", "custom-shape", "text-box", "rect", "ellipse",
    "polygon", "path", "line", "connector", "caption", NULL
  };
  guint i;

  if (n == NULL || n->type != XML_ELEMENT_NODE)
    return FALSE;
  for (i = 0; shapes[i] != NULL; i++)
    if (g_strcmp0 ((const gchar *) n->name, shapes[i]) == 0)
      return TRUE;
  return FALSE;
}

typedef void (*ShapeFn) (xmlNode *shape, gint index, gchar *text,
                         gpointer user);

/* Visit every text-bearing shape of PAGE in document order.  TEXT is
   handed to the callback, which owns it. */
static void
odp_walk_shapes (xmlNode *page, gint *index, ShapeFn fn, gpointer user)
{
  xmlNode *n;

  for (n = cmacs_office_xml_first (page, NULL, NULL);
       n != NULL;
       n = cmacs_office_xml_next (n, NULL, NULL))
    {
      gchar *text;

      /* Speaker notes hang off the page too; step over them entirely. */
      if (g_strcmp0 ((const gchar *) n->name, "notes") == 0)
        continue;

      /* A group is a container, not a shape. */
      if (g_strcmp0 ((const gchar *) n->name, "g") == 0)
        {
          odp_walk_shapes (n, index, fn, user);
          continue;
        }

      if (!odp_is_shape (n))
        continue;

      text = text_of (n, NULL, odf_skip);
      if (*text == '\0')
        {
          g_free (text);
          continue;
        }
      fn (n, (*index)++, text, user);
    }
}

typedef struct
{
  GPtrArray *out;
  const gchar *part;
  gint slide;
} OdpCollect;

static void
odp_collect (xmlNode *shape, gint index, gchar *text, gpointer user)
{
  OdpCollect *c = user;
  CmacsOfficeBlock *b = g_new0 (CmacsOfficeBlock, 1);

  b->part = g_strdup (c->part);
  b->slide = c->slide;
  b->index = index;
  b->shape = cmacs_office_xml_attr (shape, "name");
  b->id = cmacs_office_xml_attr (shape, "id");
  b->text = text;               /* takes ownership */
  g_ptr_array_add (c->out, b);
}

typedef struct
{
  gint want;
  xmlNode *found;
} OdpFind;

static void
odp_find (xmlNode *shape, gint index, gchar *text, gpointer user)
{
  OdpFind *f = user;

  g_free (text);
  if (f->found == NULL && index == f->want)
    f->found = shape;
}

static gboolean
extract_odp (CmacsOfficePackage *pkg, GPtrArray *out, GError **error)
{
  const gchar *part = cmacs_office_package_main_part (pkg);
  xmlDoc *doc;
  xmlNode *body, *pres, *page;
  gint slide = 0;

  if (part == NULL)
    return TRUE;

  doc = read_xml (pkg, part, error);
  if (doc == NULL)
    return FALSE;

  body = cmacs_office_xml_child (cmacs_office_xml_root (doc),
                                 "body", NS_ODF_OFFICE);
  pres = cmacs_office_xml_child (body, "presentation", NS_ODF_OFFICE);

  for (page = cmacs_office_xml_first (pres, "page", NS_ODF_DRAW);
       page != NULL;
       page = cmacs_office_xml_next (page, "page", NS_ODF_DRAW))
    {
      gint index = 0;
      OdpCollect ctx;

      slide++;
      ctx.out = out;
      ctx.part = part;
      ctx.slide = slide;
      odp_walk_shapes (page, &index, odp_collect, &ctx);
    }

  xmlFreeDoc (doc);
  return TRUE;
}

/* ------------------------------------------------------------------ */
/* Entry points                                                        */
/* ------------------------------------------------------------------ */

GPtrArray *
cmacs_office_extract_text (CmacsOfficePackage *pkg, GError **error)
{
  GPtrArray *out;
  gboolean ok;

  g_return_val_if_fail (pkg != NULL, NULL);

  out = blocks_new ();
  ok = (cmacs_office_package_family (pkg) == CMACS_OFFICE_FAMILY_ODF)
    ? extract_odt (pkg, out, error)
    : extract_docx (pkg, out, error);

  if (!ok)
    {
      g_ptr_array_unref (out);
      return NULL;
    }
  return out;
}

GPtrArray *
cmacs_office_extract_slides (CmacsOfficePackage *pkg, GError **error)
{
  GPtrArray *out;
  gboolean ok;

  g_return_val_if_fail (pkg != NULL, NULL);

  out = blocks_new ();
  ok = (cmacs_office_package_family (pkg) == CMACS_OFFICE_FAMILY_ODF)
    ? extract_odp (pkg, out, error)
    : extract_pptx (pkg, out, error);

  if (!ok)
    {
      g_ptr_array_unref (out);
      return NULL;
    }
  return out;
}

/* ------------------------------------------------------------------ */
/* Editing                                                             */
/* ------------------------------------------------------------------ */

/* Drop every child of P except its properties element, whose name is
   KEEP (w:pPr for OOXML).  Returns the first run's w:rPr if there was
   one, so the replacement text can inherit its character formatting. */
static xmlNode *
strip_paragraph (xmlNode *p, const gchar *keep, const gchar *ns)
{
  xmlNode *kid = p->children;
  xmlNode *rpr = NULL;

  while (kid != NULL)
    {
      xmlNode *next = kid->next;

      if (keep != NULL && cmacs_office_xml_is (kid, keep, ns))
        {
          kid = next;
          continue;
        }

      /* Salvage the first run's properties before discarding the run:
         losing them would reset the text to the document default. */
      if (rpr == NULL && cmacs_office_xml_is (kid, "r", ns))
        {
          xmlNode *found = cmacs_office_xml_child (kid, "rPr", ns);

          if (found != NULL)
            rpr = xmlCopyNode (found, 1);
        }

      xmlUnlinkNode (kid);
      xmlFreeNode (kid);
      kid = next;
    }

  return rpr;
}

static gboolean
queue_part (CmacsOfficePackage *pkg, const gchar *part, xmlDoc *doc,
            GError **error)
{
  gsize len = 0;
  guint8 *bytes = cmacs_office_xml_serialize (doc, &len, error);
  gboolean ok;

  if (bytes == NULL)
    return FALSE;

  ok = cmacs_office_zip_set_part (cmacs_office_package_zip (pkg), part,
                                  bytes, len, error);
  g_free (bytes);
  return ok;
}

gboolean
cmacs_office_extract_set_block (CmacsOfficePackage *pkg, const gchar *id,
                                gint index, const gchar *text, GError **error)
{
  const gchar *part = cmacs_office_package_main_part (pkg);
  gboolean odf = (cmacs_office_package_family (pkg) == CMACS_OFFICE_FAMILY_ODF);
  CmacsOfficeKind kind = cmacs_office_package_kind (pkg);
  BlockCtx ctx = { NULL, id, index, NULL, odf ? "id" : "paraId" };
  xmlDoc *doc;
  xmlNode *container;
  gint walked = 0;
  guint64 size = 0;
  gboolean ok;

  g_return_val_if_fail (pkg != NULL, FALSE);

  if (kind != CMACS_OFFICE_KIND_TEXT)
    {
      g_set_error (error, CMACS_OFFICE_ZIP_ERROR, CMACS_OFFICE_ZIP_ERROR_NO_PART,
                   "this document is not a word processing document");
      return FALSE;
    }
  if (part == NULL)
    {
      g_set_error (error, CMACS_OFFICE_ZIP_ERROR, CMACS_OFFICE_ZIP_ERROR_NO_PART,
                   "the document body could not be located");
      return FALSE;
    }

  /* Editing needs the whole part as a tree; refuse before inflating
     rather than after, the same way the spreadsheet editor does. */
  if (cmacs_office_zip_part_size (cmacs_office_package_zip (pkg), part,
                                  &size, NULL)
      && size > CMACS_OFFICE_MAX_EDIT_DOM)
    {
      g_set_error (error, CMACS_OFFICE_ZIP_ERROR,
                   CMACS_OFFICE_ZIP_ERROR_TOO_LARGE,
                   "%s is %" G_GUINT64_FORMAT " bytes; editing needs the part "
                   "in memory and the limit is %" G_GUINT64_FORMAT,
                   part, size, CMACS_OFFICE_MAX_EDIT_DOM);
      return FALSE;
    }

  doc = read_xml (pkg, part, error);
  if (doc == NULL)
    return FALSE;

  if (odf)
    {
      xmlNode *body = cmacs_office_xml_child (cmacs_office_xml_root (doc),
                                              "body", NS_ODF_OFFICE);

      container = cmacs_office_xml_child (body, "text", NS_ODF_OFFICE);
      odf_walk (container, part, &walked, find_block, &ctx);
    }
  else
    {
      container = cmacs_office_xml_child (cmacs_office_xml_root (doc),
                                          "body", NS_W);
      docx_walk (container, part, &walked, find_block, &ctx);
    }

  /* An id that no longer resolves falls back to the ordinal, which is
     the whole reason both are recorded. */
  if (ctx.found == NULL && id != NULL && index >= 0)
    {
      ctx.want_id = NULL;
      walked = 0;
      if (odf)
        odf_walk (container, part, &walked, find_block, &ctx);
      else
        docx_walk (container, part, &walked, find_block, &ctx);
    }

  if (ctx.found == NULL)
    {
      xmlFreeDoc (doc);
      g_set_error (error, CMACS_OFFICE_ZIP_ERROR, CMACS_OFFICE_ZIP_ERROR_NO_PART,
                   "no block with id %s or index %d",
                   id ? id : "(none)", index);
      return FALSE;
    }

  if (odf)
    {
      /* ODF paragraph content is inline text plus spans; clearing the
         children and adding one text node keeps the paragraph's own
         attributes, which is where its style lives. */
      strip_paragraph (ctx.found, NULL, NS_ODF_TEXT);
      if (text != NULL && *text != '\0')
        xmlNodeAddContent (ctx.found, (const xmlChar *) text);
    }
  else
    {
      xmlNode *rpr = strip_paragraph (ctx.found, "pPr", NS_W);

      if (text != NULL && *text != '\0')
        {
          xmlNode *run = xmlNewChild (ctx.found, ctx.found->ns,
                                      (const xmlChar *) "r", NULL);
          xmlNode *t;

          if (rpr != NULL)
            xmlAddChild (run, rpr);
          t = xmlNewTextChild (run, ctx.found->ns, (const xmlChar *) "t",
                               (const xmlChar *) text);
          /* Without this, Word discards leading and trailing spaces. */
          xmlSetNsProp (t, xmlSearchNs (doc, t, (const xmlChar *) "xml"),
                        (const xmlChar *) "space", (const xmlChar *) "preserve");
        }
      else if (rpr != NULL)
        xmlFreeNode (rpr);
    }

  ok = queue_part (pkg, part, doc, error);
  xmlFreeDoc (doc);
  return ok;
}

/* Replace a shape's text body with one run carrying TEXT.
 *
 * PresentationML nests text two levels deeper than WordprocessingML --
 * shape, txBody, paragraph, run -- so the first paragraph is reused and
 * the rest are dropped, which is what "the shape now says this" means. */
static void
pptx_set_shape_text (xmlNode *sp, const gchar *text)
{
  xmlNode *body = cmacs_office_xml_find (sp, "txBody", NULL);
  xmlNode *para, *kid, *rpr = NULL, *run;

  if (body == NULL)
    return;

  para = cmacs_office_xml_first (body, "p", NULL);
  if (para == NULL)
    return;

  /* Drop every paragraph after the first. */
  {
    xmlNode *extra = cmacs_office_xml_next (para, "p", NULL);

    while (extra != NULL)
      {
        xmlNode *next = cmacs_office_xml_next (extra, "p", NULL);

        xmlUnlinkNode (extra);
        xmlFreeNode (extra);
        extra = next;
      }
  }

  /* Clear the first paragraph, salvaging its run properties so the
     replacement keeps the shape's font rather than reverting. */
  kid = para->children;
  while (kid != NULL)
    {
      xmlNode *next = kid->next;

      if (rpr == NULL && cmacs_office_xml_is (kid, "r", NULL))
        {
          xmlNode *found = cmacs_office_xml_child (kid, "rPr", NULL);

          if (found != NULL)
            rpr = xmlCopyNode (found, 1);
        }
      if (cmacs_office_xml_is (kid, "pPr", NULL))
        {
          kid = next;
          continue;
        }
      xmlUnlinkNode (kid);
      xmlFreeNode (kid);
      kid = next;
    }

  if (text == NULL || *text == '\0')
    {
      if (rpr != NULL)
        xmlFreeNode (rpr);
      return;
    }

  run = xmlNewChild (para, para->ns, (const xmlChar *) "r", NULL);
  if (rpr != NULL)
    xmlAddChild (run, rpr);
  xmlNewTextChild (run, para->ns, (const xmlChar *) "t",
                   (const xmlChar *) text);
}

gboolean
cmacs_office_extract_set_slide_text (CmacsOfficePackage *pkg, gint slide,
                                     gint index, const gchar *text,
                                     GError **error)
{
  gboolean odf = (cmacs_office_package_family (pkg) == CMACS_OFFICE_FAMILY_ODF);
  xmlDoc *doc = NULL;
  gchar *part = NULL;
  xmlNode *target = NULL;
  gboolean ok;

  g_return_val_if_fail (pkg != NULL, FALSE);

  if (cmacs_office_package_kind (pkg) != CMACS_OFFICE_KIND_SLIDES)
    {
      g_set_error (error, CMACS_OFFICE_ZIP_ERROR, CMACS_OFFICE_ZIP_ERROR_NO_PART,
                   "this document is not a presentation");
      return FALSE;
    }
  if (slide < 1 || index < 0)
    {
      g_set_error (error, CMACS_OFFICE_ZIP_ERROR, CMACS_OFFICE_ZIP_ERROR_BAD_NAME,
                   "slides are 1-based and shape indices 0-based; got %d/%d",
                   slide, index);
      return FALSE;
    }

  if (odf)
    {
      xmlNode *body, *pres, *page;
      gint n = 0;

      part = g_strdup (cmacs_office_package_main_part (pkg));
      doc = part ? read_xml (pkg, part, error) : NULL;
      if (doc == NULL)
        {
          g_free (part);
          return FALSE;
        }

      body = cmacs_office_xml_child (cmacs_office_xml_root (doc),
                                     "body", NS_ODF_OFFICE);
      pres = cmacs_office_xml_child (body, "presentation", NS_ODF_OFFICE);
      for (page = cmacs_office_xml_first (pres, "page", NS_ODF_DRAW);
           page != NULL;
           page = cmacs_office_xml_next (page, "page", NS_ODF_DRAW))
        if (++n == slide)
          break;

      if (page != NULL)
        {
          /* The SAME walker extraction uses, so shape N here is shape N
             there -- indices that disagreed would edit the wrong box. */
          OdpFind find = { index, NULL };
          gint k = 0;

          odp_walk_shapes (page, &k, odp_find, &find);
          target = find.found;
        }

      if (target != NULL)
        {
          /* A draw:frame wraps its text in a draw:text-box; a
             draw:custom-shape holds text:p directly. */
          xmlNode *box = cmacs_office_xml_find (target, "text-box", NULL);
          xmlNode *para = cmacs_office_xml_first (box ? box : target,
                                                  "p", NS_ODF_TEXT);

          if (para != NULL)
            {
              xmlNode *extra = cmacs_office_xml_next (para, "p", NS_ODF_TEXT);

              while (extra != NULL)
                {
                  xmlNode *next = cmacs_office_xml_next (extra, "p", NS_ODF_TEXT);

                  xmlUnlinkNode (extra);
                  xmlFreeNode (extra);
                  extra = next;
                }
              strip_paragraph (para, NULL, NS_ODF_TEXT);
              if (text != NULL && *text != '\0')
                xmlNodeAddContent (para, (const xmlChar *) text);
            }
          else
            target = NULL;
        }
    }
  else
    {
      GPtrArray *parts = pptx_slide_parts (pkg, error);
      xmlNode *tree, *n;
      gint k = 0;

      if (parts == NULL)
        return FALSE;
      if ((guint) slide > parts->len)
        {
          g_ptr_array_unref (parts);
          g_set_error (error, CMACS_OFFICE_ZIP_ERROR,
                       CMACS_OFFICE_ZIP_ERROR_NO_PART,
                       "no slide %d", slide);
          return FALSE;
        }

      part = g_strdup (g_ptr_array_index (parts, slide - 1));
      g_ptr_array_unref (parts);

      doc = read_xml (pkg, part, error);
      if (doc == NULL)
        {
          g_free (part);
          return FALSE;
        }

      tree = cmacs_office_xml_find (cmacs_office_xml_root (doc), "spTree", NS_P);
      for (n = cmacs_office_xml_first (tree, NULL, NULL);
           n != NULL && target == NULL;
           n = cmacs_office_xml_next (n, NULL, NULL))
        {
          gchar *t;
          gboolean has;

          if (!cmacs_office_xml_is (n, "sp", NS_P)
              && !cmacs_office_xml_is (n, "graphicFrame", NS_P)
              && !cmacs_office_xml_is (n, "pic", NS_P))
            continue;

          t = text_of (n, "t", NULL);
          has = (*t != '\0');
          g_free (t);
          if (!has)
            continue;
          if (k++ == index)
            target = n;
        }

      if (target != NULL)
        pptx_set_shape_text (target, text);
    }

  if (target == NULL)
    {
      if (doc != NULL)
        xmlFreeDoc (doc);
      g_free (part);
      g_set_error (error, CMACS_OFFICE_ZIP_ERROR, CMACS_OFFICE_ZIP_ERROR_NO_PART,
                   "no text shape %d on slide %d", index, slide);
      return FALSE;
    }

  ok = queue_part (pkg, part, doc, error);
  xmlFreeDoc (doc);
  g_free (part);
  return ok;
}

GPtrArray *
cmacs_office_extract (CmacsOfficePackage *pkg, GError **error)
{
  g_return_val_if_fail (pkg != NULL, NULL);

  switch (cmacs_office_package_kind (pkg))
    {
    case CMACS_OFFICE_KIND_TEXT:
      return cmacs_office_extract_text (pkg, error);
    case CMACS_OFFICE_KIND_SLIDES:
      return cmacs_office_extract_slides (pkg, error);
    case CMACS_OFFICE_KIND_SHEET:
    case CMACS_OFFICE_KIND_UNKNOWN:
    default:
      /* Not an error: a spreadsheet extracts through the cell reader,
         and an unrecognised package simply has no blocks. */
      return blocks_new ();
    }
}

#endif /* HAVE_CMACS_OFFICE */
