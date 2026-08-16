/* cmacs-office-xml.c --- libxml2 helpers for package parts.
 *
 * Copyright (C) 2026 Zach Podbielniak
 * SPDX-License-Identifier: AGPL-3.0-or-later
 *
 * See cmacs-office-xml.h for why matching is by local name rather than
 * by prefix, and for the parser hardening. */

#include <config.h>

#ifdef HAVE_CMACS_OFFICE

#include "cmacs-office-xml.h"

#include <libxml/parser.h>
#include <libxml/xmlerror.h>
#include <string.h>

G_DEFINE_QUARK (cmacs-office-xml-error-quark, cmacs_office_xml_error)

void
cmacs_office_xml_init (void)
{
  /* Idempotent, and deliberately paired with NO xmlCleanupParser: this
     process shares libxml2 with upstream Emacs's src/xml.c, and tearing
     the library down underneath `libxml-parse-xml-region' would be a
     use-after-free in code we do not own. */
  xmlInitParser ();
}

xmlDoc *
cmacs_office_xml_parse (const guint8 *data, gsize len, const gchar *name,
                        GError **error)
{
  xmlDoc *doc;
  int opts;

  g_return_val_if_fail (data != NULL || len == 0, NULL);

  if (len > (gsize) G_MAXINT)
    {
      g_set_error (error, CMACS_OFFICE_XML_ERROR, CMACS_OFFICE_XML_ERROR_PARSE,
                   "%s: part is too large to parse as XML",
                   name ? name : "(unnamed)");
      return NULL;
    }

  /* NONET: a package part must never cause a network fetch.
     NOERROR/NOWARNING: libxml2 writes to stderr by default, which in
     Emacs means scribbling on the user's terminal; failures are
     reported through GError instead.
     Note what is absent: XML_PARSE_NOENT would expand entities (the
     billion-laughs vector) and XML_PARSE_HUGE would lift libxml2's
     depth and size limits.  Neither is ever wanted here. */
  opts = XML_PARSE_NONET | XML_PARSE_NOERROR | XML_PARSE_NOWARNING;

  doc = xmlReadMemory ((const char *) data, (int) len,
                       name ? name : "part.xml", NULL, opts);
  if (doc == NULL)
    {
      g_set_error (error, CMACS_OFFICE_XML_ERROR, CMACS_OFFICE_XML_ERROR_PARSE,
                   "%s: not well-formed XML", name ? name : "(unnamed)");
      return NULL;
    }

  if (xmlDocGetRootElement (doc) == NULL)
    {
      xmlFreeDoc (doc);
      g_set_error (error, CMACS_OFFICE_XML_ERROR, CMACS_OFFICE_XML_ERROR_EMPTY,
                   "%s: XML document has no root element",
                   name ? name : "(unnamed)");
      return NULL;
    }

  return doc;
}

xmlNode *
cmacs_office_xml_root (xmlDoc *doc)
{
  return doc ? xmlDocGetRootElement (doc) : NULL;
}

guint8 *
cmacs_office_xml_serialize (xmlDoc *doc, gsize *len_out, GError **error)
{
  xmlChar *buf = NULL;
  int len = 0;
  guint8 *out;

  g_return_val_if_fail (doc != NULL, NULL);

  /* Format 0: no re-indenting.  See the header for why. */
  xmlDocDumpFormatMemoryEnc (doc, &buf, &len, "UTF-8", 0);
  if (buf == NULL || len <= 0)
    {
      if (buf != NULL)
        xmlFree (buf);
      g_set_error (error, CMACS_OFFICE_XML_ERROR, CMACS_OFFICE_XML_ERROR_PARSE,
                   "could not serialise XML document");
      return NULL;
    }

  out = g_memdup2 (buf, (gsize) len);
  xmlFree (buf);

  if (len_out != NULL)
    *len_out = (gsize) len;
  return out;
}

gboolean
cmacs_office_xml_is (xmlNode *node, const gchar *local, const gchar *ns)
{
  if (node == NULL || node->type != XML_ELEMENT_NODE)
    return FALSE;

  if (local != NULL
      && g_strcmp0 ((const gchar *) node->name, local) != 0)
    return FALSE;

  if (ns != NULL)
    {
      if (node->ns == NULL || node->ns->href == NULL)
        return FALSE;
      if (g_strcmp0 ((const gchar *) node->ns->href, ns) != 0)
        return FALSE;
    }

  return TRUE;
}

xmlNode *
cmacs_office_xml_first (xmlNode *parent, const gchar *local, const gchar *ns)
{
  xmlNode *n;

  if (parent == NULL)
    return NULL;

  for (n = parent->children; n != NULL; n = n->next)
    if (cmacs_office_xml_is (n, local, ns))
      return n;

  return NULL;
}

xmlNode *
cmacs_office_xml_child (xmlNode *parent, const gchar *local, const gchar *ns)
{
  return cmacs_office_xml_first (parent, local, ns);
}

xmlNode *
cmacs_office_xml_next (xmlNode *node, const gchar *local, const gchar *ns)
{
  xmlNode *n;

  if (node == NULL)
    return NULL;

  for (n = node->next; n != NULL; n = n->next)
    if (cmacs_office_xml_is (n, local, ns))
      return n;

  return NULL;
}

static gchar *
attr_matching (xmlNode *node, const gchar *name, const gchar *ns)
{
  xmlAttr *a;

  if (node == NULL || name == NULL || node->type != XML_ELEMENT_NODE)
    return NULL;

  for (a = node->properties; a != NULL; a = a->next)
    {
      if (g_strcmp0 ((const gchar *) a->name, name) != 0)
        continue;
      if (ns != NULL
          && (a->ns == NULL || a->ns->href == NULL
              || g_strcmp0 ((const gchar *) a->ns->href, ns) != 0))
        continue;

      {
        xmlChar *v = xmlNodeListGetString (node->doc, a->children, 1);
        gchar *out = g_strdup (v ? (const gchar *) v : "");

        if (v != NULL)
          xmlFree (v);
        return out;
      }
    }

  return NULL;
}

gchar *
cmacs_office_xml_attr_ns (xmlNode *node, const gchar *name, const gchar *ns)
{
  return attr_matching (node, name, ns);
}

gchar *
cmacs_office_xml_attr (xmlNode *node, const gchar *name)
{
  xmlAttr *a;

  if (node == NULL || name == NULL || node->type != XML_ELEMENT_NODE)
    return NULL;

  /* By local name: OPC relationship attributes are unprefixed, but
     ODF's are namespaced (manifest:full-path), and callers should not
     have to care which. */
  for (a = node->properties; a != NULL; a = a->next)
    if (g_strcmp0 ((const gchar *) a->name, name) == 0)
      {
        xmlChar *v = xmlNodeListGetString (node->doc, a->children, 1);
        gchar *out = g_strdup (v ? (const gchar *) v : "");

        if (v != NULL)
          xmlFree (v);
        return out;
      }

  return NULL;
}

gchar *
cmacs_office_xml_text (xmlNode *node)
{
  xmlChar *content;
  gchar *out;

  if (node == NULL)
    return g_strdup ("");

  content = xmlNodeGetContent (node);
  out = g_strdup (content ? (const gchar *) content : "");
  if (content != NULL)
    xmlFree (content);

  return out;
}

xmlNode *
cmacs_office_xml_find (xmlNode *root, const gchar *local, const gchar *ns)
{
  xmlNode *n;

  if (root == NULL)
    return NULL;

  for (n = root->children; n != NULL; n = n->next)
    {
      xmlNode *hit;

      if (n->type != XML_ELEMENT_NODE)
        continue;
      if (cmacs_office_xml_is (n, local, ns))
        return n;
      hit = cmacs_office_xml_find (n, local, ns);
      if (hit != NULL)
        return hit;
    }

  return NULL;
}

#endif /* HAVE_CMACS_OFFICE */
