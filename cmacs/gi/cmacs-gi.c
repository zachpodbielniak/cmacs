/* cmacs-gi.c — GObject Introspection bridge for elisp
 *
 * Copyright (C) 2026 Zach Podbielniak
 * SPDX-License-Identifier: AGPL-3.0-or-later
 *
 * How it works:
 *  1. (gi-require NAMESPACE VERSION) loads a .typelib via
 *     g_irepository_require()
 *  2. CMacs reflects the typelib: enumerates functions, objects,
 *     interfaces, enums, structs, constants
 *  3. Each symbol is available via (gi-call) or lazy elisp wrappers
 *  4. Calling a GI function marshals elisp args → C args via
 *     g_function_info_invoke(), and marshals the return back
 */

#include <config.h>

#ifdef HAVE_CMACS_GI

#include "lisp.h"
#include "../gobject/cmacs-gobject.h"

#include <girepository.h>
#include <string.h>

static Lisp_Object Qgi_error;

/* In-memory cache: namespace → loaded flag.
 * Typelib reflection is expensive; cache the results. */
static GHashTable *loaded_namespaces = NULL;

/* ──────────────────────────────────────────────────────────────────── */
/* GI argument marshaling                                              */
/* ──────────────────────────────────────────────────────────────────── */

static gboolean
cmacs_gi_lisp_to_arg (Lisp_Object obj, GITypeInfo *type_info,
                      GIArgument *arg)
{
  GITypeTag tag = g_type_info_get_tag (type_info);

  switch (tag)
    {
    case GI_TYPE_TAG_BOOLEAN:
      arg->v_boolean = !NILP (obj);
      return TRUE;

    case GI_TYPE_TAG_INT8:
      CHECK_FIXNUM (obj);
      arg->v_int8 = (gint8)XFIXNUM (obj);
      return TRUE;

    case GI_TYPE_TAG_UINT8:
      CHECK_FIXNUM (obj);
      arg->v_uint8 = (guint8)XFIXNUM (obj);
      return TRUE;

    case GI_TYPE_TAG_INT16:
      CHECK_FIXNUM (obj);
      arg->v_int16 = (gint16)XFIXNUM (obj);
      return TRUE;

    case GI_TYPE_TAG_UINT16:
      CHECK_FIXNUM (obj);
      arg->v_uint16 = (guint16)XFIXNUM (obj);
      return TRUE;

    case GI_TYPE_TAG_INT32:
      CHECK_FIXNUM (obj);
      arg->v_int32 = (gint32)XFIXNUM (obj);
      return TRUE;

    case GI_TYPE_TAG_UINT32:
      CHECK_FIXNUM (obj);
      arg->v_uint32 = (guint32)XFIXNUM (obj);
      return TRUE;

    case GI_TYPE_TAG_INT64:
      CHECK_FIXNUM (obj);
      arg->v_int64 = (gint64)XFIXNUM (obj);
      return TRUE;

    case GI_TYPE_TAG_UINT64:
      CHECK_FIXNUM (obj);
      arg->v_uint64 = (guint64)XFIXNUM (obj);
      return TRUE;

    case GI_TYPE_TAG_FLOAT:
      if (FIXNUMP (obj))
        arg->v_float = (gfloat)XFIXNUM (obj);
      else
        {
          CHECK_FLOAT (obj);
          arg->v_float = (gfloat)XFLOAT_DATA (obj);
        }
      return TRUE;

    case GI_TYPE_TAG_DOUBLE:
      if (FIXNUMP (obj))
        arg->v_double = (gdouble)XFIXNUM (obj);
      else
        {
          CHECK_FLOAT (obj);
          arg->v_double = XFLOAT_DATA (obj);
        }
      return TRUE;

    case GI_TYPE_TAG_UTF8:
    case GI_TYPE_TAG_FILENAME:
      if (NILP (obj))
        arg->v_string = NULL;
      else
        {
          CHECK_STRING (obj);
          arg->v_string = (gchar *)SSDATA (obj);
        }
      return TRUE;

    case GI_TYPE_TAG_INTERFACE:
      {
        GIBaseInfo *iface_info = g_type_info_get_interface (type_info);
        GIInfoType iface_type = g_base_info_get_type (iface_info);

        if (iface_type == GI_INFO_TYPE_OBJECT
            || iface_type == GI_INFO_TYPE_INTERFACE)
          {
            arg->v_pointer = cmacs_gobject_unwrap (obj);
            g_base_info_unref (iface_info);
            return TRUE;
          }

        if (iface_type == GI_INFO_TYPE_ENUM
            || iface_type == GI_INFO_TYPE_FLAGS)
          {
            CHECK_FIXNUM (obj);
            arg->v_int32 = (gint32)XFIXNUM (obj);
            g_base_info_unref (iface_info);
            return TRUE;
          }

        g_base_info_unref (iface_info);
        return FALSE;
      }

    default:
      return FALSE;
    }
}

static Lisp_Object
cmacs_gi_arg_to_lisp (GIArgument *arg, GITypeInfo *type_info)
{
  GITypeTag tag = g_type_info_get_tag (type_info);

  switch (tag)
    {
    case GI_TYPE_TAG_VOID:
      return Qnil;

    case GI_TYPE_TAG_BOOLEAN:
      return arg->v_boolean ? Qt : Qnil;

    case GI_TYPE_TAG_INT8:
      return make_fixnum (arg->v_int8);
    case GI_TYPE_TAG_UINT8:
      return make_fixnum (arg->v_uint8);
    case GI_TYPE_TAG_INT16:
      return make_fixnum (arg->v_int16);
    case GI_TYPE_TAG_UINT16:
      return make_fixnum (arg->v_uint16);
    case GI_TYPE_TAG_INT32:
      return make_fixnum (arg->v_int32);
    case GI_TYPE_TAG_UINT32:
      return make_fixnum ((EMACS_INT)arg->v_uint32);
    case GI_TYPE_TAG_INT64:
      return make_fixnum ((EMACS_INT)arg->v_int64);
    case GI_TYPE_TAG_UINT64:
      return make_fixnum ((EMACS_INT)arg->v_uint64);

    case GI_TYPE_TAG_FLOAT:
      return make_float ((double)arg->v_float);
    case GI_TYPE_TAG_DOUBLE:
      return make_float (arg->v_double);

    case GI_TYPE_TAG_UTF8:
    case GI_TYPE_TAG_FILENAME:
      return arg->v_string ? build_string (arg->v_string) : Qnil;

    case GI_TYPE_TAG_INTERFACE:
      {
        GIBaseInfo *iface_info = g_type_info_get_interface (type_info);
        GIInfoType iface_type = g_base_info_get_type (iface_info);
        Lisp_Object result = Qnil;

        if ((iface_type == GI_INFO_TYPE_OBJECT
             || iface_type == GI_INFO_TYPE_INTERFACE)
            && arg->v_pointer != NULL)
          result = cmacs_gobject_wrap (G_OBJECT (arg->v_pointer));
        else if (iface_type == GI_INFO_TYPE_ENUM
                 || iface_type == GI_INFO_TYPE_FLAGS)
          result = make_fixnum (arg->v_int32);

        g_base_info_unref (iface_info);
        return result;
      }

    default:
      return Qnil;
    }
}

/* ──────────────────────────────────────────────────────────────────── */
/* DEFUN primitives                                                    */
/* ──────────────────────────────────────────────────────────────────── */

DEFUN ("gi-require", Fgi_require, Sgi_require, 1, 2, 0,
       doc: /* Load a GObject Introspection typelib.
NAMESPACE is a string like \"Gio\", \"Gtk\", \"GLib\".
Optional VERSION is a string like \"2.0\", \"4.0\".
Returns non-nil on success, signals an error on failure. */)
  (Lisp_Object namespace, Lisp_Object version)
{
  GIRepository *repo;
  GError *err = NULL;
  const gchar *ns;
  const gchar *ver = NULL;

  CHECK_STRING (namespace);
  ns = SSDATA (namespace);

  if (!NILP (version))
    {
      CHECK_STRING (version);
      ver = SSDATA (version);
    }

  repo = g_irepository_get_default ();

  if (g_irepository_require (repo, ns, ver, 0, &err) == NULL)
    {
      Lisp_Object msg = build_string (err->message);
      g_error_free (err);
      xsignal1 (Qgi_error, msg);
    }

  /* Record loaded namespace. */
  if (loaded_namespaces == NULL)
    loaded_namespaces = g_hash_table_new_full (g_str_hash, g_str_equal,
                                               g_free, NULL);
  g_hash_table_insert (loaded_namespaces, g_strdup (ns),
                       GINT_TO_POINTER (1));

  return Qt;
}

DEFUN ("gi-call", Fgi_call, Sgi_call, 2, MANY, 0,
       doc: /* Call a GI function.
NAMESPACE is a string (e.g., \"Gio\").
FUNCTION is a string (e.g., \"file_new_for_path\").
Remaining arguments are passed to the function.
usage: (gi-call NAMESPACE FUNCTION &rest ARGS) */)
  (ptrdiff_t nargs, Lisp_Object *args)
{
  GIRepository *repo;
  GIFunctionInfo *func_info;
  GICallableInfo *callable;
  gint n_gi_args;
  GIArgument *in_args = NULL;
  GIArgument retval;
  GError *err = NULL;
  gboolean ok;
  Lisp_Object result;
  gint in_count;
  gint arg_idx;

  if (nargs < 2)
    error ("gi-call requires at least NAMESPACE and FUNCTION");

  CHECK_STRING (args[0]);
  CHECK_STRING (args[1]);

  repo = g_irepository_get_default ();

  func_info = g_irepository_find_by_name (repo, SSDATA (args[0]),
                                          SSDATA (args[1]));
  if (func_info == NULL)
    error ("GI function '%s.%s' not found", SSDATA (args[0]),
           SSDATA (args[1]));

  if (g_base_info_get_type ((GIBaseInfo *)func_info) != GI_INFO_TYPE_FUNCTION)
    {
      g_base_info_unref ((GIBaseInfo *)func_info);
      error ("'%s.%s' is not a function", SSDATA (args[0]),
             SSDATA (args[1]));
    }

  callable = (GICallableInfo *)func_info;
  n_gi_args = g_callable_info_get_n_args (callable);

  /* Count in-args (skip out args). */
  in_count = 0;
  for (gint i = 0; i < n_gi_args; i++)
    {
      GIArgInfo *ai = g_callable_info_get_arg (callable, i);
      GIDirection dir = g_arg_info_get_direction (ai);
      if (dir == GI_DIRECTION_IN || dir == GI_DIRECTION_INOUT)
        in_count++;
      g_base_info_unref ((GIBaseInfo *)ai);
    }

  if (nargs - 2 < in_count)
    {
      g_base_info_unref ((GIBaseInfo *)func_info);
      error ("gi-call: %s.%s expects %d args, got %td",
             SSDATA (args[0]), SSDATA (args[1]),
             in_count, nargs - 2);
    }

  /* Marshal elisp args → GIArgument. */
  in_args = g_new0 (GIArgument, in_count > 0 ? in_count : 1);
  arg_idx = 0;

  for (gint i = 0; i < n_gi_args && arg_idx < in_count; i++)
    {
      GIArgInfo *ai = g_callable_info_get_arg (callable, i);
      GIDirection dir = g_arg_info_get_direction (ai);

      if (dir == GI_DIRECTION_IN || dir == GI_DIRECTION_INOUT)
        {
          GITypeInfo *ti = g_arg_info_get_type (ai);
          if (!cmacs_gi_lisp_to_arg (args[2 + arg_idx], ti,
                                     &in_args[arg_idx]))
            {
              g_base_info_unref ((GIBaseInfo *)ti);
              g_base_info_unref ((GIBaseInfo *)ai);
              g_free (in_args);
              g_base_info_unref ((GIBaseInfo *)func_info);
              error ("gi-call: cannot marshal arg %d for %s.%s",
                     arg_idx, SSDATA (args[0]), SSDATA (args[1]));
            }
          g_base_info_unref ((GIBaseInfo *)ti);
          arg_idx++;
        }

      g_base_info_unref ((GIBaseInfo *)ai);
    }

  /* Invoke the function. */
  memset (&retval, 0, sizeof (retval));
  ok = g_function_info_invoke (func_info, in_args, in_count,
                               NULL, 0, &retval, &err);

  g_free (in_args);

  if (!ok)
    {
      Lisp_Object msg = build_string (err->message);
      g_error_free (err);
      g_base_info_unref ((GIBaseInfo *)func_info);
      xsignal1 (Qgi_error, msg);
    }

  /* Marshal return value. */
  {
    GITypeInfo *ret_type = g_callable_info_get_return_type (callable);
    result = cmacs_gi_arg_to_lisp (&retval, ret_type);
    g_base_info_unref ((GIBaseInfo *)ret_type);
  }

  g_base_info_unref ((GIBaseInfo *)func_info);
  return result;
}

DEFUN ("gi-method", Fgi_method, Sgi_method, 2, MANY, 0,
       doc: /* Call METHOD on a GObject OBJECT via GI.
OBJECT is a wrapped GObject.
METHOD is a string (method name).
Remaining arguments are passed to the method.
usage: (gi-method OBJECT METHOD &rest ARGS) */)
  (ptrdiff_t nargs, Lisp_Object *args)
{
  GObject *obj;
  GIRepository *repo;
  GIObjectInfo *obj_info;
  GIFunctionInfo *method_info = NULL;
  GICallableInfo *callable;
  gint n_gi_args;
  GIArgument *in_args = NULL;
  GIArgument retval;
  GError *err = NULL;
  gboolean ok;
  Lisp_Object result;
  gint in_count;
  gint arg_idx;
  const gchar *type_name;

  if (nargs < 2)
    error ("gi-method requires at least OBJECT and METHOD");

  obj = cmacs_gobject_unwrap (args[0]);
  if (obj == NULL)
    error ("Not a GObject");

  CHECK_STRING (args[1]);

  /* Look up the object type in the GI repository. */
  type_name = G_OBJECT_TYPE_NAME (obj);
  repo = g_irepository_get_default ();

  /* Search loaded namespaces for this type. */
  {
    GIBaseInfo *base = NULL;
    GList *namespaces = NULL;
    const gchar * const *loaded;
    gint i;

    loaded = g_irepository_get_loaded_namespaces (repo);
    for (i = 0; loaded[i] != NULL; i++)
      {
        base = g_irepository_find_by_name (repo, loaded[i], type_name);
        if (base != NULL)
          break;
      }

    if (base == NULL)
      error ("GI type info not found for '%s'", type_name);

    if (g_base_info_get_type (base) != GI_INFO_TYPE_OBJECT)
      {
        g_base_info_unref (base);
        error ("'%s' is not a GObject type in GI", type_name);
      }

    obj_info = (GIObjectInfo *)base;
    (void)namespaces;
  }

  /* Find the method. */
  method_info = g_object_info_find_method (obj_info, SSDATA (args[1]));
  if (method_info == NULL)
    {
      g_base_info_unref ((GIBaseInfo *)obj_info);
      error ("GI method '%s' not found on type '%s'",
             SSDATA (args[1]), type_name);
    }

  callable = (GICallableInfo *)method_info;
  n_gi_args = g_callable_info_get_n_args (callable);

  /* Count in-args. */
  in_count = 1; /* instance arg */
  for (gint i = 0; i < n_gi_args; i++)
    {
      GIArgInfo *ai = g_callable_info_get_arg (callable, i);
      GIDirection dir = g_arg_info_get_direction (ai);
      if (dir == GI_DIRECTION_IN || dir == GI_DIRECTION_INOUT)
        in_count++;
      g_base_info_unref ((GIBaseInfo *)ai);
    }

  /* Marshal args. */
  in_args = g_new0 (GIArgument, in_count);
  in_args[0].v_pointer = obj; /* instance */
  arg_idx = 1;

  for (gint i = 0; i < n_gi_args && arg_idx < in_count; i++)
    {
      GIArgInfo *ai = g_callable_info_get_arg (callable, i);
      GIDirection dir = g_arg_info_get_direction (ai);

      if (dir == GI_DIRECTION_IN || dir == GI_DIRECTION_INOUT)
        {
          gint lisp_idx = 2 + (arg_idx - 1);
          if (lisp_idx >= nargs)
            {
              g_base_info_unref ((GIBaseInfo *)ai);
              g_free (in_args);
              g_base_info_unref ((GIBaseInfo *)method_info);
              g_base_info_unref ((GIBaseInfo *)obj_info);
              error ("gi-method: not enough args for '%s'",
                     SSDATA (args[1]));
            }

          GITypeInfo *ti = g_arg_info_get_type (ai);
          if (!cmacs_gi_lisp_to_arg (args[lisp_idx], ti,
                                     &in_args[arg_idx]))
            {
              g_base_info_unref ((GIBaseInfo *)ti);
              g_base_info_unref ((GIBaseInfo *)ai);
              g_free (in_args);
              g_base_info_unref ((GIBaseInfo *)method_info);
              g_base_info_unref ((GIBaseInfo *)obj_info);
              error ("gi-method: cannot marshal arg %d", arg_idx - 1);
            }
          g_base_info_unref ((GIBaseInfo *)ti);
          arg_idx++;
        }

      g_base_info_unref ((GIBaseInfo *)ai);
    }

  /* Invoke. */
  memset (&retval, 0, sizeof (retval));
  ok = g_function_info_invoke (method_info, in_args, in_count,
                               NULL, 0, &retval, &err);

  g_free (in_args);

  if (!ok)
    {
      Lisp_Object msg = build_string (err->message);
      g_error_free (err);
      g_base_info_unref ((GIBaseInfo *)method_info);
      g_base_info_unref ((GIBaseInfo *)obj_info);
      xsignal1 (Qgi_error, msg);
    }

  /* Marshal return value. */
  {
    GITypeInfo *ret_type = g_callable_info_get_return_type (callable);
    result = cmacs_gi_arg_to_lisp (&retval, ret_type);
    g_base_info_unref ((GIBaseInfo *)ret_type);
  }

  g_base_info_unref ((GIBaseInfo *)method_info);
  g_base_info_unref ((GIBaseInfo *)obj_info);
  return result;
}

DEFUN ("gi-enum", Fgi_enum, Sgi_enum, 3, 3, 0,
       doc: /* Resolve an enum value.
NAMESPACE, ENUM, and MEMBER are all strings.
Returns the integer value. */)
  (Lisp_Object namespace, Lisp_Object enumname, Lisp_Object member)
{
  GIRepository *repo;
  GIBaseInfo *info;
  GIEnumInfo *enum_info;
  gint n_values;
  gint i;

  CHECK_STRING (namespace);
  CHECK_STRING (enumname);
  CHECK_STRING (member);

  repo = g_irepository_get_default ();
  info = g_irepository_find_by_name (repo, SSDATA (namespace),
                                     SSDATA (enumname));
  if (info == NULL)
    error ("GI enum '%s.%s' not found", SSDATA (namespace),
           SSDATA (enumname));

  if (g_base_info_get_type (info) != GI_INFO_TYPE_ENUM
      && g_base_info_get_type (info) != GI_INFO_TYPE_FLAGS)
    {
      g_base_info_unref (info);
      error ("'%s.%s' is not an enum", SSDATA (namespace),
             SSDATA (enumname));
    }

  enum_info = (GIEnumInfo *)info;
  n_values = g_enum_info_get_n_values (enum_info);

  for (i = 0; i < n_values; i++)
    {
      GIValueInfo *vi = g_enum_info_get_value (enum_info, i);
      const gchar *name = g_base_info_get_name ((GIBaseInfo *)vi);

      if (strcmp (name, SSDATA (member)) == 0)
        {
          gint64 val = g_value_info_get_value (vi);
          g_base_info_unref ((GIBaseInfo *)vi);
          g_base_info_unref (info);
          return make_fixnum ((EMACS_INT)val);
        }
      g_base_info_unref ((GIBaseInfo *)vi);
    }

  g_base_info_unref (info);
  error ("GI enum member '%s' not found in '%s.%s'",
         SSDATA (member), SSDATA (namespace), SSDATA (enumname));
}

DEFUN ("gi-list-functions", Fgi_list_functions, Sgi_list_functions,
       1, 1, 0,
       doc: /* Return a list of function names in NAMESPACE. */)
  (Lisp_Object namespace)
{
  GIRepository *repo;
  gint n_infos;
  gint i;
  Lisp_Object result = Qnil;

  CHECK_STRING (namespace);

  repo = g_irepository_get_default ();
  n_infos = g_irepository_get_n_infos (repo, SSDATA (namespace));

  for (i = 0; i < n_infos; i++)
    {
      GIBaseInfo *info = g_irepository_get_info (repo,
                                                 SSDATA (namespace), i);
      GIInfoType type = g_base_info_get_type (info);

      if (type == GI_INFO_TYPE_FUNCTION)
        result = Fcons (build_string (g_base_info_get_name (info)),
                        result);

      g_base_info_unref (info);
    }

  return Fnreverse (result);
}

DEFUN ("gi-function-info", Fgi_function_info, Sgi_function_info,
       2, 2, 0,
       doc: /* Return signature info for FUNCTION in NAMESPACE.
Returns an alist with keys: name, args, return-type. */)
  (Lisp_Object namespace, Lisp_Object function)
{
  GIRepository *repo;
  GIFunctionInfo *func_info;
  GICallableInfo *callable;
  gint n_args;
  gint i;
  Lisp_Object arg_list = Qnil;
  Lisp_Object result;

  CHECK_STRING (namespace);
  CHECK_STRING (function);

  repo = g_irepository_get_default ();
  func_info = (GIFunctionInfo *)g_irepository_find_by_name (
    repo, SSDATA (namespace), SSDATA (function));

  if (func_info == NULL)
    return Qnil;

  callable = (GICallableInfo *)func_info;
  n_args = g_callable_info_get_n_args (callable);

  for (i = 0; i < n_args; i++)
    {
      GIArgInfo *ai = g_callable_info_get_arg (callable, i);
      GITypeInfo *ti = g_arg_info_get_type (ai);
      const gchar *arg_name = g_base_info_get_name ((GIBaseInfo *)ai);
      GITypeTag tag = g_type_info_get_tag (ti);

      Lisp_Object entry = Fcons (build_string (arg_name),
                                 build_string (g_type_tag_to_string (tag)));
      arg_list = Fcons (entry, arg_list);

      g_base_info_unref ((GIBaseInfo *)ti);
      g_base_info_unref ((GIBaseInfo *)ai);
    }

  /* Return type. */
  {
    GITypeInfo *ret = g_callable_info_get_return_type (callable);
    GITypeTag ret_tag = g_type_info_get_tag (ret);

    result = list3 (
      Fcons (intern_c_string ("name"),
             build_string (g_base_info_get_name ((GIBaseInfo *)func_info))),
      Fcons (intern_c_string ("args"), Fnreverse (arg_list)),
      Fcons (intern_c_string ("return-type"),
             build_string (g_type_tag_to_string (ret_tag))));

    g_base_info_unref ((GIBaseInfo *)ret);
  }

  g_base_info_unref ((GIBaseInfo *)func_info);
  return result;
}

/* ──────────────────────────────────────────────────────────────────── */
/* Init                                                                */
/* ──────────────────────────────────────────────────────────────────── */

void
syms_of_cmacs_gi (void)
{
  DEFSYM (Qgi_error, "gi-error");

  Fput (Qgi_error, Qerror_conditions,
        pure_list (Qgi_error, Qerror));
  Fput (Qgi_error, Qerror_message,
        build_pure_c_string ("GObject Introspection error"));

  defsubr (&Sgi_require);
  defsubr (&Sgi_call);
  defsubr (&Sgi_method);
  defsubr (&Sgi_enum);
  defsubr (&Sgi_list_functions);
  defsubr (&Sgi_function_info);
}

#endif /* HAVE_CMACS_GI */
