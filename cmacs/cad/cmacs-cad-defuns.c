/* cmacs-cad-defuns.c --- Lisp primitives for the CAD subsystem.
 *
 * Copyright (C) 2026 Zach Podbielniak
 * SPDX-License-Identifier: AGPL-3.0-or-later
 */

#include <config.h>

#ifdef HAVE_CMACS_CAD

#include "lisp.h"
#include "cmacs-cad.h"
#include "cmacs-cad-internal.h"
#include "../glib/cmacs-eval-dispatch.h"

#include <string.h>

/* Signal `cmacs-cad-error' carrying ERROR's message; frees ERROR.  Shared
 * with the sketch TU via cmacs-cad-internal.h. */
AVOID
cmacs_cad_signal (GError *error)
{
  Lisp_Object message =
    build_string (error != NULL ? error->message : "unknown CAD error");

  if (error != NULL)
    g_error_free (error);
  xsignal1 (Qcmacs_cad_error, message);
}

/* Signal `cmacs-cad-error' carrying the literal MSG (sketch TU helper). */
AVOID
cmacs_cad_error_str (const char *msg)
{
  xsignal1 (Qcmacs_cad_error, build_string (msg));
}

static CadDocument *
cmacs_cad_doc_require (Lisp_Object path)
{
  GError *error = NULL;
  CadDocument *document;

  CHECK_STRING (path);
  document = cmacs_cad_doc_open (SSDATA (path), &error);
  if (document == NULL)
    cmacs_cad_signal (error);

  return document;
}

/* Build a cad-glib override table from a Lisp alist ((NAME . VALUE)...).
 * Caller unrefs. */
static GHashTable *
cmacs_cad_overrides_from_alist (Lisp_Object alist)
{
  GHashTable *overrides;
  Lisp_Object tail;

  if (NILP (alist))
    return NULL;

  overrides = g_hash_table_new_full (g_str_hash, g_str_equal,
                                     g_free, g_free);
  for (tail = alist; CONSP (tail); tail = XCDR (tail))
    {
      Lisp_Object pair = XCAR (tail);
      gdouble *value;

      if (!CONSP (pair) || !STRINGP (XCAR (pair))
          || !NUMBERP (XCDR (pair)))
        continue;

      value = g_new (gdouble, 1);
      *value = XFLOATINT (XCDR (pair));
      g_hash_table_replace (overrides, g_strdup (SSDATA (XCAR (pair))),
                            value);
    }

  return overrides;
}

DEFUN ("cmacs-cad-supported-p", Fcmacs_cad_supported_p,
       Scmacs_cad_supported_p, 0, 0, 0,
       doc: /* Return t when the CAD subsystem is available.  */)
  (void)
{
  return Qt;
}

DEFUN ("cmacs-cad-version", Fcmacs_cad_version, Scmacs_cad_version,
       0, 0, 0,
       doc: /* Return the cad-glib version string.  */)
  (void)
{
  return build_string (CAD_GLIB_VERSION_STRING);
}

DEFUN ("cmacs-cad-doc-open", Fcmacs_cad_doc_open, Scmacs_cad_doc_open,
       1, 1, 0,
       doc: /* Open (or return the cached) CAD document for PATH.
The part language is chosen by extension (.cad = s-expressions,
.ccad = crispy).  Parsing errors signal `cmacs-cad-error'.
Returns a plist (:language LANG :capabilities (CAPS...)).  */)
  (Lisp_Object path)
{
  CadDocument *document = cmacs_cad_doc_require (path);
  CadFrontend *frontend = cad_document_get_frontend (document);
  CadFrontendCapabilities caps = cad_frontend_get_capabilities (frontend);
  Lisp_Object cap_list = Qnil;

  if (caps & CAD_FRONTEND_CAP_STATIC_PARAMS)
    cap_list = Fcons (intern (":static-params"), cap_list);
  if (caps & CAD_FRONTEND_CAP_FORM_SPANS)
    cap_list = Fcons (intern (":form-spans"), cap_list);
  if (caps & CAD_FRONTEND_CAP_SKETCH_WRITEBACK)
    cap_list = Fcons (intern (":sketch-writeback"), cap_list);

  return list4 (QClanguage,
                build_string (cad_frontend_get_name (frontend)),
                QCcapabilities, cap_list);
}

DEFUN ("cmacs-cad-doc-close", Fcmacs_cad_doc_close, Scmacs_cad_doc_close,
       1, 1, 0,
       doc: /* Drop the cached CAD document for PATH.  */)
  (Lisp_Object path)
{
  CHECK_STRING (path);

  return cmacs_cad_doc_close (SSDATA (path)) ? Qt : Qnil;
}

DEFUN ("cmacs-cad-set-source", Fcmacs_cad_set_source,
       Scmacs_cad_set_source, 2, 2, 0,
       doc: /* Replace the in-memory source of the CAD document at PATH.
SOURCE is the new part text (typically the unsaved buffer string).
Results become stale until the next evaluation.  */)
  (Lisp_Object path, Lisp_Object source)
{
  GError *error = NULL;

  CHECK_STRING (path);
  CHECK_STRING (source);

  if (!cmacs_cad_doc_set_source (SSDATA (path), SSDATA (source), &error))
    cmacs_cad_signal (error);

  return Qt;
}

DEFUN ("cmacs-cad-eval", Fcmacs_cad_eval, Scmacs_cad_eval, 1, 2, 0,
       doc: /* Synchronously evaluate the CAD document at PATH.
Optional PARAMS is an alist of (NAME . VALUE) parameter overrides.
Signals `cmacs-cad-error' on failure.  Prefer
`cmacs-cad-eval-async' from UI code.  */)
  (Lisp_Object path, Lisp_Object params)
{
  CadDocument *document = cmacs_cad_doc_require (path);
  GHashTable *overrides = cmacs_cad_overrides_from_alist (params);
  GError *error = NULL;
  gboolean ok;

  ok = cad_document_eval (document, overrides, NULL, &error);
  if (overrides != NULL)
    g_hash_table_unref (overrides);
  if (!ok)
    cmacs_cad_signal (error);

  return Qt;
}

DEFUN ("cmacs-cad-eval-async", Fcmacs_cad_eval_async,
       Scmacs_cad_eval_async, 2, 3, 0,
       doc: /* Asynchronously evaluate the CAD document at PATH.
CALLBACK is invoked on the main loop with a plist: (:ok t) on
success or (:error MESSAGE) on failure.  Optional PARAMS is an
alist of (NAME . VALUE) overrides.  A newer evaluation of the same
document cancels this one; stale completions are dropped.  */)
  (Lisp_Object path, Lisp_Object callback, Lisp_Object params)
{
  GHashTable *overrides;
  uint64_t cookie;

  CHECK_STRING (path);

  overrides = cmacs_cad_overrides_from_alist (params);
  cookie = cmacs_dispatch_callback_register (callback);
  cmacs_cad_doc_eval_async (SSDATA (path), overrides, cookie);
  if (overrides != NULL)
    g_hash_table_unref (overrides);

  return Qt;
}

DEFUN ("cmacs-cad-params", Fcmacs_cad_params, Scmacs_cad_params, 1, 1, 0,
       doc: /* Return parameter metadata for the CAD document at PATH.
A list of plists (:name NAME :value V :default D :min MIN :max MAX
:doc DOC :line LINE).  For languages without static parameters the
list is empty until the first evaluation.  */)
  (Lisp_Object path)
{
  CadDocument *document = cmacs_cad_doc_require (path);
  GPtrArray *params = cad_document_get_params (document);
  Lisp_Object result = Qnil;
  guint i;

  for (i = 0; i < params->len; i++)
    {
      CadParam *param = g_ptr_array_index (params, i);
      Lisp_Object plist = Qnil;

      if (param->span != NULL)
        plist = Fcons (intern (":line"),
                       Fcons (make_fixnum (param->span->line), plist));
      if (param->doc != NULL)
        plist = Fcons (intern (":doc"),
                       Fcons (build_string (param->doc), plist));
      if (param->maximum < G_MAXDOUBLE)
        plist = Fcons (intern (":max"),
                       Fcons (make_float (param->maximum), plist));
      if (param->minimum > -G_MAXDOUBLE)
        plist = Fcons (intern (":min"),
                       Fcons (make_float (param->minimum), plist));
      plist = Fcons (intern (":default"),
                     Fcons (make_float (param->default_value), plist));
      plist = Fcons (intern (":value"),
                     Fcons (make_float (param->value), plist));
      plist = Fcons (intern (":name"),
                     Fcons (build_string (param->name), plist));

      result = Fcons (plist, result);
    }

  return Fnreverse (result);
}

DEFUN ("cmacs-cad-part-names", Fcmacs_cad_part_names,
       Scmacs_cad_part_names, 1, 1, 0,
       doc: /* Return the part names defined by the last evaluation of PATH.  */)
  (Lisp_Object path)
{
  CadDocument *document = cmacs_cad_doc_require (path);
  GPtrArray *names = cad_document_get_part_names (document);
  Lisp_Object result = Qnil;
  guint i;

  for (i = 0; i < names->len; i++)
    result = Fcons (build_string (g_ptr_array_index (names, i)), result);
  g_ptr_array_unref (names);

  return Fnreverse (result);
}

static Lisp_Object
cmacs_cad_tree_to_lisp (CadFeatureNode *node)
{
  GPtrArray *children = cad_feature_node_get_children (node);
  CadSpan *span = cad_feature_node_get_span (node);
  Lisp_Object child_list = Qnil;
  Lisp_Object plist = Qnil;
  GEnumClass *klass;
  GEnumValue *value;
  guint i;

  for (i = 0; i < children->len; i++)
    child_list = Fcons (cmacs_cad_tree_to_lisp (
                          g_ptr_array_index (children, i)),
                        child_list);
  child_list = Fnreverse (child_list);

  plist = Fcons (intern (":children"), Fcons (child_list, plist));
  if (span != NULL)
    plist = Fcons (intern (":span"),
                   Fcons (Fcons (make_fixnum (span->start),
                                 make_fixnum (span->end)),
                          plist));

  klass = g_type_class_ref (CAD_TYPE_FEATURE_KIND);
  value = g_enum_get_value (klass, cad_feature_node_get_kind (node));
  plist = Fcons (intern (":kind"),
                 Fcons (intern (value != NULL ? value->value_nick : "none"),
                        plist));
  g_type_class_unref (klass);

  plist = Fcons (intern (":label"),
                 Fcons (build_string (cad_feature_node_get_label (node)),
                        plist));
  plist = Fcons (intern (":id"),
                 Fcons (make_fixnum (cad_feature_node_get_id (node)),
                        plist));

  return plist;
}

DEFUN ("cmacs-cad-feature-tree", Fcmacs_cad_feature_tree,
       Scmacs_cad_feature_tree, 1, 2, 0,
       doc: /* Return PART's feature tree for the CAD document at PATH.
PART nil means the first part.  A nested plist with :id :kind
:label :span (START . END byte offsets into the source) and
:children.  Requires a prior successful evaluation.  */)
  (Lisp_Object path, Lisp_Object part)
{
  CadDocument *document = cmacs_cad_doc_require (path);
  CadFeatureNode *tree;

  tree = cad_document_get_feature_tree (document,
                                        NILP (part) ? NULL
                                                    : SSDATA (part));
  if (tree == NULL)
    return Qnil;

  return cmacs_cad_tree_to_lisp (tree);
}

DEFUN ("cmacs-cad-inspect", Fcmacs_cad_inspect, Scmacs_cad_inspect,
       1, 2, 0,
       doc: /* Return mass properties for PART of the CAD document at PATH.
PART nil means the first part.  A plist with :volume :area :bbox
(XMIN YMIN ZMIN XMAX YMAX ZMAX) :watertight and :triangles.
Requires a prior successful evaluation.  */)
  (Lisp_Object path, Lisp_Object part)
{
  CadDocument *document = cmacs_cad_doc_require (path);
  CadSolid *solid;
  GError *error = NULL;
  gdouble volume, area;
  gdouble mn[3], mx[3];
  CadMesh *mesh;
  Lisp_Object plist = Qnil;

  solid = cad_document_get_solid (document,
                                  NILP (part) ? NULL : SSDATA (part));
  if (solid == NULL)
    xsignal1 (Qcmacs_cad_error,
              build_string ("no evaluated part (run cmacs-cad-eval first)"));

  volume = cad_solid_get_volume (solid, &error);
  if (error != NULL)
    cmacs_cad_signal (error);
  area = cad_solid_get_surface_area (solid, &error);
  if (error != NULL)
    cmacs_cad_signal (error);
  cad_solid_get_bbox (solid, &mn[0], &mn[1], &mn[2],
                      &mx[0], &mx[1], &mx[2]);

  mesh = cad_solid_tessellate (solid, NULL, &error);
  if (mesh != NULL)
    {
      plist = Fcons (intern (":triangles"),
                     Fcons (make_fixnum (mesh->n_triangles), plist));
      cad_mesh_free (mesh);
    }
  else
    g_clear_error (&error);

  {
    gdouble cx, cy, cz;

    if (cad_solid_get_center_of_mass (solid, &cx, &cy, &cz, &error))
      plist = Fcons (intern (":center-of-mass"),
                     Fcons (listn (3, make_float (cx), make_float (cy),
                                   make_float (cz)),
                            plist));
    else
      g_clear_error (&error);
  }
  plist = Fcons (intern (":watertight"),
                 Fcons (cad_solid_is_watertight (solid) ? Qt : Qnil,
                        plist));
  plist = Fcons (intern (":bbox"),
                 Fcons (listn (6, make_float (mn[0]), make_float (mn[1]),
                               make_float (mn[2]), make_float (mx[0]),
                               make_float (mx[1]), make_float (mx[2])),
                        plist));
  plist = Fcons (intern (":area"), Fcons (make_float (area), plist));
  plist = Fcons (intern (":volume"), Fcons (make_float (volume), plist));

  return plist;
}

DEFUN ("cmacs-cad-export", Fcmacs_cad_export, Scmacs_cad_export, 3, 4, 0,
       doc: /* Export PART of the CAD document at PATH to OUT-PATH.
FORMAT is one of the symbols `stl', `stl-ascii', `obj', `step' or
`iges'.  PART nil means the first part.  Requires a prior
successful evaluation.  */)
  (Lisp_Object path, Lisp_Object out_path, Lisp_Object format,
   Lisp_Object part)
{
  CadDocument *document = cmacs_cad_doc_require (path);
  CadSolid *solid;
  CadFileFormat file_format;
  GError *error = NULL;

  CHECK_STRING (out_path);
  CHECK_SYMBOL (format);

  solid = cad_document_get_solid (document,
                                  NILP (part) ? NULL : SSDATA (part));
  if (solid == NULL)
    xsignal1 (Qcmacs_cad_error,
              build_string ("no evaluated part (run cmacs-cad-eval first)"));

  if (EQ (format, intern ("stl")))
    file_format = CAD_FILE_FORMAT_STL_BINARY;
  else if (EQ (format, intern ("stl-ascii")))
    file_format = CAD_FILE_FORMAT_STL_ASCII;
  else if (EQ (format, intern ("obj")))
    file_format = CAD_FILE_FORMAT_OBJ;
  else if (EQ (format, intern ("step")))
    file_format = CAD_FILE_FORMAT_STEP;
  else if (EQ (format, intern ("iges")))
    file_format = CAD_FILE_FORMAT_IGES;
  else
    xsignal1 (Qcmacs_cad_error, build_string ("unknown export format"));

  if (!cad_solid_export_file (solid, SSDATA (out_path), file_format,
                              NULL, &error))
    cmacs_cad_signal (error);

  return Qt;
}

DEFUN ("cmacs-cad-section", Fcmacs_cad_section, Scmacs_cad_section,
       7, 8, 0,
       doc: /* Section PART of the CAD document at PATH by a plane.
The plane passes through (PX PY PZ) with normal (NX NY NZ).  Returns a
list of segments, each (X1 Y1 Z1 X2 Y2 Z2); an empty list means the
plane misses the solid.  PART nil means the first part.  Requires a
prior successful evaluation.  */)
  (Lisp_Object path, Lisp_Object px, Lisp_Object py, Lisp_Object pz,
   Lisp_Object nx, Lisp_Object ny, Lisp_Object nz, Lisp_Object part)
{
  CadDocument *document = cmacs_cad_doc_require (path);
  CadSolid *solid;
  GError *error = NULL;
  GArray *segs;
  Lisp_Object result = Qnil;
  guint i;

  solid = cad_document_get_solid (document,
                                  NILP (part) ? NULL : SSDATA (part));
  if (solid == NULL)
    xsignal1 (Qcmacs_cad_error,
              build_string ("no evaluated part (run cmacs-cad-eval first)"));

  segs = cad_solid_section (solid,
                            XFLOATINT (px), XFLOATINT (py), XFLOATINT (pz),
                            XFLOATINT (nx), XFLOATINT (ny), XFLOATINT (nz),
                            &error);
  if (segs == NULL)
    cmacs_cad_signal (error);

  /* Build the list back-to-front so it comes out in segment order. */
  for (i = segs->len; i >= 6; i -= 6)
    {
      guint b = i - 6;

      result = Fcons (listn (6,
                             make_float (g_array_index (segs, gdouble, b)),
                             make_float (g_array_index (segs, gdouble, b + 1)),
                             make_float (g_array_index (segs, gdouble, b + 2)),
                             make_float (g_array_index (segs, gdouble, b + 3)),
                             make_float (g_array_index (segs, gdouble, b + 4)),
                             make_float (g_array_index (segs, gdouble, b + 5))),
                      result);
    }
  g_array_unref (segs);

  return result;
}

DEFUN ("cmacs-cad-dsl-symbols", Fcmacs_cad_dsl_symbols,
       Scmacs_cad_dsl_symbols, 0, 1, 0,
       doc: /* Return the modeling vocabulary for LANGUAGE.
LANGUAGE is "sexp" (default) or "crispy".  A list of
(NAME SIGNATURE DOC) string triples for completion, eldoc and
font-lock.  */)
  (Lisp_Object language)
{
  CadFrontend *frontend;
  GPtrArray *vocab;
  Lisp_Object result = Qnil;
  guint i;

  cad_frontend_sexp_get_default ();
#ifdef CAD_HAVE_CRISPY
  cad_frontend_crispy_get_default ();
#endif

  frontend = cad_frontend_registry_lookup_by_name (
    NILP (language) ? "sexp" : SSDATA (language));
  if (frontend == NULL)
    return Qnil;

  vocab = cad_frontend_get_vocabulary (frontend);
  for (i = 0; i < vocab->len; i++)
    {
      CadVocabularyEntry *entry = g_ptr_array_index (vocab, i);

      result = Fcons (list3 (build_string (entry->name),
                             build_string (entry->signature),
                             entry->doc != NULL
                               ? build_string (entry->doc) : Qnil),
                      result);
    }
  g_ptr_array_unref (vocab);

  return Fnreverse (result);
}

void
syms_of_cmacs_cad_defuns (void)
{
  DEFSYM (Qcmacs_cad_error, "cmacs-cad-error");
  DEFSYM (QCok, ":ok");
  DEFSYM (QCerror, ":error");
  DEFSYM (QClanguage, ":language");
  DEFSYM (QCcapabilities, ":capabilities");

  Fput (Qcmacs_cad_error, Qerror_conditions,
        list2 (Qcmacs_cad_error, Qerror));
  Fput (Qcmacs_cad_error, Qerror_message,
        build_string ("CAD error"));

  defsubr (&Scmacs_cad_supported_p);
  defsubr (&Scmacs_cad_version);
  defsubr (&Scmacs_cad_doc_open);
  defsubr (&Scmacs_cad_doc_close);
  defsubr (&Scmacs_cad_set_source);
  defsubr (&Scmacs_cad_eval);
  defsubr (&Scmacs_cad_eval_async);
  defsubr (&Scmacs_cad_params);
  defsubr (&Scmacs_cad_part_names);
  defsubr (&Scmacs_cad_feature_tree);
  defsubr (&Scmacs_cad_inspect);
  defsubr (&Scmacs_cad_export);
  defsubr (&Scmacs_cad_section);
  defsubr (&Scmacs_cad_dsl_symbols);
}

#endif /* HAVE_CMACS_CAD */
