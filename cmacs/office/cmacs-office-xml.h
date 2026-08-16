/* cmacs-office-xml.h --- libxml2 helpers for package parts.
 *
 * Copyright (C) 2026 Zach Podbielniak
 * SPDX-License-Identifier: AGPL-3.0-or-later
 *
 * Every part of every one of the six formats is XML, and all of it is
 * namespaced -- heavily, and with prefixes that are not stable between
 * producers.  Word writes `w:document', but nothing stops a conforming
 * writer from binding that namespace to a different prefix.  So these
 * helpers match on LOCAL NAME plus (optionally) namespace href, never
 * on the prefix that happens to be in the file.
 *
 * Parsing is deliberately hostile-input shaped: no network access, and
 * entities are NOT expanded, which is what closes the billion-laughs
 * hole.  XML_PARSE_HUGE is never set, so libxml2's depth and size
 * limits stay in force.
 *
 * This TU includes neither lisp.h nor zip.h -- it is pure glib plus
 * libxml2, so it is testable on its own. */

#ifndef CMACS_OFFICE_XML_H
#define CMACS_OFFICE_XML_H

#include <config.h>

#ifdef HAVE_CMACS_OFFICE

#include <glib.h>
#include <libxml/tree.h>

G_BEGIN_DECLS

#define CMACS_OFFICE_XML_ERROR (cmacs_office_xml_error_quark ())

typedef enum
{
  CMACS_OFFICE_XML_ERROR_PARSE,      /* not well-formed */
  CMACS_OFFICE_XML_ERROR_EMPTY       /* parsed, but no root element */
} CmacsOfficeXmlError;

GQuark cmacs_office_xml_error_quark (void);

/* Call once at subsystem init.  libxml2 is also used by upstream Emacs
   (src/xml.c), so this only initialises -- it must never tear down. */
void cmacs_office_xml_init (void);

/* Parse LEN bytes of XML.  NAME is used only in error messages.  The
   returned document must be freed with xmlFreeDoc. */
xmlDoc *cmacs_office_xml_parse (const guint8 *data,
                                gsize len,
                                const gchar *name,
                                GError **error);

/* Root element, or NULL for an empty document. */
xmlNode *cmacs_office_xml_root (xmlDoc *doc);

/* Serialise DOC back to UTF-8 bytes for storing as a part.  Transfer
   full; free with g_free.

   Deliberately unformatted: whitespace is significant in these parts,
   and re-indenting would turn a one-element edit into a whole-part
   rewrite in every diff. */
guint8 *cmacs_office_xml_serialize (xmlDoc *doc,
                                    gsize *len_out,
                                    GError **error);

/* TRUE when NODE is an element whose local name is LOCAL.  When NS is
   non-NULL the namespace href must match it too. */
gboolean cmacs_office_xml_is (xmlNode *node,
                              const gchar *local,
                              const gchar *ns);

/* First child element of PARENT matching LOCAL (and NS if non-NULL). */
xmlNode *cmacs_office_xml_child (xmlNode *parent,
                                 const gchar *local,
                                 const gchar *ns);

/* Next sibling element matching LOCAL (and NS if non-NULL).  A NULL
   LOCAL matches any element, which is how you iterate children:

     for (n = cmacs_office_xml_first (parent, NULL, NULL);
          n != NULL;
          n = cmacs_office_xml_next (n, NULL, NULL))  */
xmlNode *cmacs_office_xml_first (xmlNode *parent,
                                 const gchar *local,
                                 const gchar *ns);
xmlNode *cmacs_office_xml_next (xmlNode *node,
                                const gchar *local,
                                const gchar *ns);

/* Attribute value by local name, ignoring prefix.  Transfer full.

   Beware where local names collide: a PresentationML <p:sldId> carries
   BOTH an unprefixed `id' (the slide's own number) and an `r:id' (the
   relationship naming its part).  Use cmacs_office_xml_attr_ns when
   which namespace it came from actually matters. */
gchar *cmacs_office_xml_attr (xmlNode *node, const gchar *name);

/* Attribute value by local name AND namespace href.  Transfer full. */
gchar *cmacs_office_xml_attr_ns (xmlNode *node,
                                 const gchar *name,
                                 const gchar *ns);

/* All descendant text, concatenated.  Transfer full; never NULL. */
gchar *cmacs_office_xml_text (xmlNode *node);

/* Depth-first search for the first element matching LOCAL (and NS),
   starting below ROOT.  Returns NULL when there is none. */
xmlNode *cmacs_office_xml_find (xmlNode *root,
                                const gchar *local,
                                const gchar *ns);

G_END_DECLS

#endif /* HAVE_CMACS_OFFICE */
#endif /* CMACS_OFFICE_XML_H */
