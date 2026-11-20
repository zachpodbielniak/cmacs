/* cmacs-yaml.c — YAML file -> JSON text primitive
 *
 * Copyright (C) 2026 Zach Podbielniak
 * SPDX-License-Identifier: AGPL-3.0-or-later
 *
 * One DEFUN:
 *
 *   (cmacs-yaml-parse-file FILE)
 *       → the first document of the YAML file FILE, as a JSON string.
 *
 * Emacs has no YAML reader and cmacs links yaml-glib anyway, so this
 * is the whole bridge: yaml-glib parses, converts its node tree to a
 * JsonNode, json-glib prints it, and Elisp reads the text with
 * `json-parse-string'.  Going through JSON text rather than building
 * Lisp objects here keeps this file free of any opinion about how a
 * mapping should look in Lisp (alist, plist, hash table) -- the caller
 * picks with `json-parse-string's keywords.
 *
 * Gating.  yaml-glib is NOT part of the --with-cmacs-glib link line on
 * its own: its objects reach the binary inside libbacon-1.0.a, the
 * canonical copy (see "De-duplicate shared objects" in
 * src/Makefile.in), and its headers through CMACS_BACON_CFLAGS.  So the
 * DEFUN exists only when configure defined HAVE_CMACS_YAML, which it
 * does for a bundled bacon.  Without it this file compiles to an empty
 * syms_of_cmacs_yaml and Lisp sees no `cmacs-yaml-parse-file' -- which
 * callers must treat as "cannot read YAML", never as "the file is
 * empty".
 *
 * Nothing here runs Lisp or touches the compositor.  Every GLib object
 * is released before a Lisp error is signalled, because `xsignal' does
 * not return.
 */

#include <config.h>

#ifdef HAVE_CMACS_GLIB

#include "lisp.h"
#include "cmacs-yaml.h"

#ifdef HAVE_CMACS_YAML

#include "coding.h"

#include <glib.h>
#include <json-glib/json-glib.h>
#include <yaml-glib.h>

DEFUN ("cmacs-yaml-parse-file", Fcmacs_yaml_parse_file,
       Scmacs_yaml_parse_file, 1, 1, 0,
       doc: /* Parse the YAML file FILE and return its document as a JSON string.

Only the first document of FILE is returned.  An empty file gives the
string "null".  Turn the result into data with `json-parse-string':

  (json-parse-string (cmacs-yaml-parse-file "~/rules.yaml")
                     :object-type \\='alist :array-type \\='list)

YAML scalars become JSON strings, numbers, booleans or null as yaml-glib
resolves them.  Signals an `error' carrying yaml-glib's message when FILE
cannot be read or is not valid YAML.  */)
  (Lisp_Object file)
{
  Lisp_Object encoded, result;
  YamlParser *parser;
  YamlNode *root;
  JsonNode *json_root;
  JsonGenerator *generator;
  GError *gerror = NULL;
  gchar *message = NULL;
  gchar *json = NULL;
  gsize json_len = 0;

  CHECK_STRING (file);
  file = Fexpand_file_name (file, Qnil);
  encoded = ENCODE_FILE (file);

  /* Parse.  Nothing below allocates Lisp memory until every GLib
     object is gone, so SSDATA (encoded) stays put for the call.  */
  parser = yaml_parser_new ();
  if (!yaml_parser_load_from_file (parser, SSDATA (encoded), &gerror))
    {
      message = g_strdup_printf ("%s: %s", SSDATA (encoded),
                                 (gerror != NULL && gerror->message != NULL)
                                 ? gerror->message : "cannot parse YAML");
      g_clear_error (&gerror);
    }
  else
    {
      /* The parser owns the root node (transfer none).  */
      root = yaml_parser_get_root (parser);
      if (root == NULL)
        {
          /* An empty file, or one holding only comments.  */
          json = g_strdup ("null");
          json_len = strlen (json);
        }
      else
        {
          json_root = yaml_node_to_json_node (root);
          if (json_root == NULL)
            message = g_strdup_printf ("%s: cannot convert the document to JSON",
                                       SSDATA (encoded));
          else
            {
              generator = json_generator_new ();
              json_generator_set_root (generator, json_root);
              json = json_generator_to_data (generator, &json_len);
              g_object_unref (generator);
              json_node_unref (json_root);
              if (json == NULL)
                message = g_strdup_printf ("%s: cannot serialise the document",
                                           SSDATA (encoded));
            }
        }
    }
  g_object_unref (parser);

  /* Hand the text to Lisp and free the C copy before anything can
     signal.  */
  if (message != NULL)
    {
      Lisp_Object lmessage = build_string (message);
      g_free (message);
      xsignal1 (Qerror, lmessage);
    }

  result = make_unibyte_string (json, (ptrdiff_t) json_len);
  g_free (json);
  return code_convert_string_norecord (result, Qutf_8, false);
}

#endif /* HAVE_CMACS_YAML */

void
syms_of_cmacs_yaml (void)
{
#ifdef HAVE_CMACS_YAML
  defsubr (&Scmacs_yaml_parse_file);
#endif
}

#endif /* HAVE_CMACS_GLIB */
