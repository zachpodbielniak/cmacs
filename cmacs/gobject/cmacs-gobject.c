/* cmacs-gobject.c — GObject ↔ elisp type bridge
 *
 * Copyright (C) 2026 Zach Podbielniak
 * SPDX-License-Identifier: AGPL-3.0-or-later
 *
 * GObject instances are wrapped as Lisp_User_Ptr values.  The finalizer
 * calls g_object_unref() so Emacs GC handles the GObject lifecycle.
 *
 * Type marshaling table:
 *   gboolean   → t / nil
 *   gint/guint → integer
 *   gdouble    → float
 *   gchar*     → string
 *   GObject*   → user-ptr (this module)
 *   GList      → list
 *   GHashTable → alist
 *   GError     → signal error
 *   NULL       → nil
 */

#include <config.h>

#ifdef HAVE_CMACS_GLIB

#include "lisp.h"
#include "cmacs-gobject.h"
#include "cmacs-gclosure.h"

#include <glib-object.h>
#include <string.h>

#ifdef HAVE_CMACS_GI
#include <girepository.h>
#include <gmodule.h>
#endif

/* ──────────────────────────────────────────────────────────────────── */
/* GObject ↔ user-ptr                                                  */
/* ──────────────────────────────────────────────────────────────────── */

static void
cmacs_gobject_finalizer (void *ptr)
{
  if (ptr != NULL && G_IS_OBJECT (ptr))
    g_object_unref (G_OBJECT (ptr));
}

Lisp_Object
cmacs_gobject_wrap (GObject *obj)
{
  if (obj == NULL)
    return Qnil;

  g_object_ref (obj);
  return make_user_ptr (cmacs_gobject_finalizer, obj);
}

GObject *
cmacs_gobject_unwrap (Lisp_Object obj)
{
  if (NILP (obj))
    return NULL;
  if (!USER_PTRP (obj))
    return NULL;

  struct Lisp_User_Ptr *uptr = XUSER_PTR (obj);
  if (uptr->finalizer != cmacs_gobject_finalizer)
    return NULL;
  return G_OBJECT (uptr->p);
}

bool
cmacs_gobject_p (Lisp_Object obj)
{
  if (!USER_PTRP (obj))
    return false;
  struct Lisp_User_Ptr *uptr = XUSER_PTR (obj);
  return uptr->finalizer == cmacs_gobject_finalizer;
}

/* ──────────────────────────────────────────────────────────────────── */
/* Boxed type ↔ user-ptr                                               */
/* ──────────────────────────────────────────────────────────────────── */

static void
cmacs_boxed_finalizer (void *ptr)
{
  CmacsBoxedValue *bv = (CmacsBoxedValue *)ptr;
  if (bv != NULL)
    {
      if (bv->data != NULL)
        g_boxed_free (bv->type, bv->data);
      free (bv);
    }
}

Lisp_Object
cmacs_boxed_wrap (GType type, gpointer boxed)
{
  CmacsBoxedValue *bv;

  if (boxed == NULL)
    return Qnil;

  bv = (CmacsBoxedValue *)malloc (sizeof (CmacsBoxedValue));
  bv->type = type;
  bv->data = g_boxed_copy (type, boxed);

  return make_user_ptr (cmacs_boxed_finalizer, bv);
}

CmacsBoxedValue *
cmacs_boxed_unwrap (Lisp_Object obj)
{
  if (NILP (obj))
    return NULL;
  if (!USER_PTRP (obj))
    return NULL;

  struct Lisp_User_Ptr *uptr = XUSER_PTR (obj);
  if (uptr->finalizer != cmacs_boxed_finalizer)
    return NULL;
  return (CmacsBoxedValue *)uptr->p;
}

bool
cmacs_boxed_p (Lisp_Object obj)
{
  if (!USER_PTRP (obj))
    return false;
  struct Lisp_User_Ptr *uptr = XUSER_PTR (obj);
  return uptr->finalizer == cmacs_boxed_finalizer;
}

/* ──────────────────────────────────────────────────────────────────── */
/* GValue ↔ elisp marshaling                                           */
/* ──────────────────────────────────────────────────────────────────── */

static Lisp_Object
cmacs_gvalue_to_lisp (const GValue *val)
{
  GType type;

  if (val == NULL)
    return Qnil;

  type = G_VALUE_TYPE (val);

  if (type == G_TYPE_BOOLEAN)
    return g_value_get_boolean (val) ? Qt : Qnil;

  if (type == G_TYPE_INT)
    return make_fixnum (g_value_get_int (val));

  if (type == G_TYPE_UINT)
    return make_fixnum ((EMACS_INT)g_value_get_uint (val));

  if (type == G_TYPE_LONG)
    return make_fixnum ((EMACS_INT)g_value_get_long (val));

  if (type == G_TYPE_ULONG)
    return make_fixnum ((EMACS_INT)g_value_get_ulong (val));

  if (type == G_TYPE_INT64)
    return make_fixnum ((EMACS_INT)g_value_get_int64 (val));

  if (type == G_TYPE_UINT64)
    return make_fixnum ((EMACS_INT)g_value_get_uint64 (val));

  if (type == G_TYPE_FLOAT)
    return make_float ((double)g_value_get_float (val));

  if (type == G_TYPE_DOUBLE)
    return make_float (g_value_get_double (val));

  if (type == G_TYPE_STRING)
    {
      const gchar *str = g_value_get_string (val);
      return str != NULL ? build_string (str) : Qnil;
    }

  if (type == G_TYPE_ENUM)
    return make_fixnum (g_value_get_enum (val));

  if (type == G_TYPE_FLAGS)
    return make_fixnum ((EMACS_INT)g_value_get_flags (val));

  if (g_type_is_a (type, G_TYPE_OBJECT))
    return cmacs_gobject_wrap (g_value_get_object (val));

  /* Fallback: return string representation. */
  {
    gchar *str = g_strdup_value_contents (val);
    Lisp_Object result = build_string (str);
    g_free (str);
    return result;
  }
}

static gboolean
cmacs_lisp_to_gvalue (Lisp_Object obj, GValue *val)
{
  GType type = G_VALUE_TYPE (val);

  if (type == G_TYPE_BOOLEAN)
    {
      g_value_set_boolean (val, !NILP (obj));
      return TRUE;
    }

  if (type == G_TYPE_INT)
    {
      CHECK_FIXNUM (obj);
      g_value_set_int (val, (gint)XFIXNUM (obj));
      return TRUE;
    }

  if (type == G_TYPE_UINT)
    {
      CHECK_FIXNUM (obj);
      g_value_set_uint (val, (guint)XFIXNUM (obj));
      return TRUE;
    }

  if (type == G_TYPE_LONG)
    {
      CHECK_FIXNUM (obj);
      g_value_set_long (val, (glong)XFIXNUM (obj));
      return TRUE;
    }

  if (type == G_TYPE_INT64)
    {
      CHECK_FIXNUM (obj);
      g_value_set_int64 (val, (gint64)XFIXNUM (obj));
      return TRUE;
    }

  if (type == G_TYPE_FLOAT)
    {
      CHECK_NUMBER (obj);
      g_value_set_float (val, (gfloat)XFLOAT_DATA (obj));
      return TRUE;
    }

  if (type == G_TYPE_DOUBLE)
    {
      if (FIXNUMP (obj))
        g_value_set_double (val, (gdouble)XFIXNUM (obj));
      else
        {
          CHECK_NUMBER (obj);
          g_value_set_double (val, XFLOAT_DATA (obj));
        }
      return TRUE;
    }

  if (type == G_TYPE_STRING)
    {
      if (NILP (obj))
        g_value_set_string (val, NULL);
      else
        {
          CHECK_STRING (obj);
          g_value_set_string (val, SSDATA (obj));
        }
      return TRUE;
    }

  if (G_TYPE_IS_ENUM (type))
    {
      CHECK_FIXNUM (obj);
      g_value_set_enum (val, (gint)XFIXNUM (obj));
      return TRUE;
    }

  if (G_TYPE_IS_FLAGS (type))
    {
      CHECK_FIXNUM (obj);
      g_value_set_flags (val, (guint)XFIXNUM (obj));
      return TRUE;
    }

  if (g_type_is_a (type, G_TYPE_OBJECT))
    {
      GObject *gobj = cmacs_gobject_unwrap (obj);
      g_value_set_object (val, gobj);
      return TRUE;
    }

  return FALSE;
}

/* ──────────────────────────────────────────────────────────────────── */
/* DEFUN primitives                                                    */
/* ──────────────────────────────────────────────────────────────────── */

DEFUN ("gobject-p", Fgobject_p, Sgobject_p, 1, 1, 0,
       doc: /* Return non-nil if OBJECT is a wrapped GObject. */)
  (Lisp_Object object)
{
  return cmacs_gobject_p (object) ? Qt : Qnil;
}

DEFUN ("gobject-type-name", Fgobject_type_name, Sgobject_type_name, 1, 1, 0,
       doc: /* Return the GType name of OBJECT as a string. */)
  (Lisp_Object object)
{
  GObject *obj = cmacs_gobject_unwrap (object);
  if (obj == NULL)
    error ("Not a GObject");

  return build_string (G_OBJECT_TYPE_NAME (obj));
}

DEFUN ("gobject-get", Fgobject_get, Sgobject_get, 2, 2, 0,
       doc: /* Get PROPERTY from GObject OBJECT.
Returns the property value converted to an appropriate elisp type. */)
  (Lisp_Object object, Lisp_Object property)
{
  GObject *obj;
  GParamSpec *pspec;
  GValue val = G_VALUE_INIT;
  Lisp_Object result;

  obj = cmacs_gobject_unwrap (object);
  if (obj == NULL)
    error ("Not a GObject");

  CHECK_STRING (property);

  pspec = g_object_class_find_property (G_OBJECT_GET_CLASS (obj),
                                        SSDATA (property));
  if (pspec == NULL)
    error ("GObject has no property '%s'", SSDATA (property));

  g_value_init (&val, pspec->value_type);
  g_object_get_property (obj, SSDATA (property), &val);
  result = cmacs_gvalue_to_lisp (&val);
  g_value_unset (&val);

  return result;
}

DEFUN ("gobject-set", Fgobject_set, Sgobject_set, 3, 3, 0,
       doc: /* Set PROPERTY on GObject OBJECT to VALUE.
VALUE is marshaled from elisp to the appropriate GLib type. */)
  (Lisp_Object object, Lisp_Object property, Lisp_Object value)
{
  GObject *obj;
  GParamSpec *pspec;
  GValue val = G_VALUE_INIT;

  obj = cmacs_gobject_unwrap (object);
  if (obj == NULL)
    error ("Not a GObject");

  CHECK_STRING (property);

  pspec = g_object_class_find_property (G_OBJECT_GET_CLASS (obj),
                                        SSDATA (property));
  if (pspec == NULL)
    error ("GObject has no property '%s'", SSDATA (property));

  g_value_init (&val, pspec->value_type);
  if (!cmacs_lisp_to_gvalue (value, &val))
    {
      g_value_unset (&val);
      error ("Cannot convert elisp value to GType '%s'",
             g_type_name (pspec->value_type));
    }

  g_object_set_property (obj, SSDATA (property), &val);
  g_value_unset (&val);

  return value;
}

DEFUN ("gobject-connect", Fgobject_connect, Sgobject_connect, 3, 3, 0,
       doc: /* Connect CALLBACK to SIGNAL on GObject OBJECT.
CALLBACK is an elisp function called when the signal is emitted.
Returns a handler ID (integer) for disconnecting. */)
  (Lisp_Object object, Lisp_Object signal, Lisp_Object callback)
{
  GObject *obj;
  gulong handler_id;

  obj = cmacs_gobject_unwrap (object);
  if (obj == NULL)
    error ("Not a GObject");

  CHECK_STRING (signal);
  CHECK_TYPE (FUNCTIONP (callback), Qfunctionp, callback);

  handler_id = cmacs_gclosure_connect (obj, SSDATA (signal), callback);

  return make_fixnum ((EMACS_INT)handler_id);
}

DEFUN ("gobject-disconnect", Fgobject_disconnect, Sgobject_disconnect,
       2, 2, 0,
       doc: /* Disconnect a signal handler from OBJECT by HANDLER-ID. */)
  (Lisp_Object object, Lisp_Object handler_id)
{
  GObject *obj;

  obj = cmacs_gobject_unwrap (object);
  if (obj == NULL)
    error ("Not a GObject");

  CHECK_FIXNAT (handler_id);

  g_signal_handler_disconnect (obj, (gulong)XFIXNAT (handler_id));
  return Qnil;
}

DEFUN ("gobject-new", Fgobject_new, Sgobject_new, 1, MANY, 0,
       doc: /* Create a new GObject of TYPE with optional PROPERTIES.
TYPE is a string naming a registered GType.
Remaining arguments are property name/value pairs.
usage: (gobject-new TYPE &rest PROPERTIES) */)
  (ptrdiff_t nargs, Lisp_Object *args)
{
  GType type;
  GObject *obj;
  ptrdiff_t i;

  CHECK_STRING (args[0]);

  type = g_type_from_name (SSDATA (args[0]));

#ifdef HAVE_CMACS_GI
  /* If the type isn't registered yet, try GI to find the _get_type()
     function and call it directly via dlsym.

     We must NOT use g_registered_type_info_get_g_type() because it
     can conflict with already-initialized GTK types (e.g. pgtk has
     registered GtkWidget but not GtkCheckButton — GI tries to
     re-register parent types and corrupts the g_once state, causing
     a deadlock).

     Instead: get the type_init function name from GI metadata
     (e.g. "gtk_check_button_get_type"), resolve it from the already-
     loaded library via g_module_symbol, and call it. */
  if (type == G_TYPE_INVALID)
    {
      GIRepository *repo = g_irepository_get_default ();
      gchar **loaded = g_irepository_get_loaded_namespaces (repo);
      if (loaded != NULL)
        {
          const char *ctype = SSDATA (args[0]);
          for (gint i = 0; loaded[i] != NULL && type == G_TYPE_INVALID; i++)
            {
              const char *ns = loaded[i];
              size_t ns_len = strlen (ns);
              const char *short_name = ctype;

              /* Strip namespace prefix: "GtkButton" → "Button".
                 Also handle namespaces with trailing version digits
                 that don't appear in C type names, e.g.
                 namespace "WebKit2" → C prefix "WebKit". */
              if (strncmp (ctype, ns, ns_len) == 0)
                short_name = ctype + ns_len;
              else
                {
                  size_t base_len = ns_len;
                  while (base_len > 0
                         && ns[base_len - 1] >= '0'
                         && ns[base_len - 1] <= '9')
                    base_len--;
                  if (base_len > 0 && base_len < ns_len
                      && strncmp (ctype, ns, base_len) == 0)
                    short_name = ctype + base_len;
                }

              GIBaseInfo *info =
                g_irepository_find_by_name (repo, ns, short_name);
              if (info != NULL)
                {
                  GIInfoType itype = g_base_info_get_type (info);
                  if (itype == GI_INFO_TYPE_OBJECT
                      || itype == GI_INFO_TYPE_INTERFACE)
                    {
                      const gchar *type_init =
                        g_registered_type_info_get_type_init (
                          (GIRegisteredTypeInfo *) info);
                      if (type_init != NULL)
                        {
                          typedef GType (*GetTypeFunc) (void);
                          GetTypeFunc get_type_fn = NULL;

                          /* First try the current process (works for
                             libraries already linked, e.g. GTK via pgtk). */
                          GModule *self_mod =
                            g_module_open (NULL, G_MODULE_BIND_LAZY);
                          if (self_mod != NULL)
                            {
                              g_module_symbol (self_mod, type_init,
                                               (gpointer *) &get_type_fn);
                              g_module_close (self_mod);
                            }

                          /* If not found, load the namespace's shared
                             library (e.g. libwebkit2gtk-4.1.so). */
                          if (get_type_fn == NULL)
                            {
                              const gchar *shlibs =
                                g_irepository_get_shared_library (repo, ns);
                              if (shlibs != NULL)
                                {
                                  gchar **libs = g_strsplit (shlibs, ",", -1);
                                  for (gint li = 0;
                                       libs[li] != NULL && get_type_fn == NULL;
                                       li++)
                                    {
                                      GModule *mod =
                                        g_module_open (libs[li],
                                                       G_MODULE_BIND_LAZY);
                                      if (mod != NULL)
                                        {
                                          g_module_symbol (
                                            mod, type_init,
                                            (gpointer *) &get_type_fn);
                                          /* Keep the module open — closing
                                             it would unload the library and
                                             invalidate the GType. */
                                        }
                                    }
                                  g_strfreev (libs);
                                }
                            }

                          if (get_type_fn != NULL)
                            type = get_type_fn ();
                        }
                    }
                  g_base_info_unref (info);
                }
            }
          g_strfreev (loaded);
        }
    }
#endif

  if (type == G_TYPE_INVALID)
    error ("Unknown GType: %s", SSDATA (args[0]));

  if (!g_type_is_a (type, G_TYPE_OBJECT))
    error ("GType '%s' is not a GObject type", SSDATA (args[0]));

  obj = g_object_new (type, NULL);
  if (obj == NULL)
    error ("Failed to create GObject of type '%s'", SSDATA (args[0]));

  /* Apply property pairs. */
  for (i = 1; i + 1 < nargs; i += 2)
    {
      GParamSpec *pspec;
      GValue val = G_VALUE_INIT;

      CHECK_STRING (args[i]);

      pspec = g_object_class_find_property (G_OBJECT_GET_CLASS (obj),
                                            SSDATA (args[i]));
      if (pspec == NULL)
        {
          g_object_unref (obj);
          error ("GObject has no property '%s'", SSDATA (args[i]));
        }

      g_value_init (&val, pspec->value_type);
      if (!cmacs_lisp_to_gvalue (args[i + 1], &val))
        {
          g_value_unset (&val);
          g_object_unref (obj);
          error ("Cannot convert elisp value for property '%s'",
                 SSDATA (args[i]));
        }

      g_object_set_property (obj, SSDATA (args[i]), &val);
      g_value_unset (&val);
    }

  /* Sink floating ref if this is a GInitiallyUnowned (e.g. GtkWidget).
     g_object_new returns a floating ref for these types — we must sink
     it to take proper ownership, otherwise g_object_unref in the
     finalizer triggers "floating object was finalized" warnings. */
  if (g_object_is_floating (obj))
    g_object_ref_sink (obj);

  Lisp_Object result = make_user_ptr (cmacs_gobject_finalizer, obj);
  return result;
}

DEFUN ("gobject-list-properties", Fgobject_list_properties,
       Sgobject_list_properties, 1, 1, 0,
       doc: /* Return a list of property names for OBJECT. */)
  (Lisp_Object object)
{
  GObject *obj;
  GParamSpec **props;
  guint n_props;
  guint i;
  Lisp_Object result = Qnil;

  obj = cmacs_gobject_unwrap (object);
  if (obj == NULL)
    error ("Not a GObject");

  props = g_object_class_list_properties (G_OBJECT_GET_CLASS (obj),
                                          &n_props);

  for (i = 0; i < n_props; i++)
    result = Fcons (build_string (props[i]->name), result);

  g_free (props);
  return Fnreverse (result);
}

DEFUN ("gobject-property-info", Fgobject_property_info,
       Sgobject_property_info, 2, 2, 0,
       doc: /* Return metadata for property NAME on OBJECT as a plist
\(:type TYPE-NAME :writable BOOL :readable BOOL :blurb STRING), or nil if no
such property.  Used to choose an editing widget.  */)
  (Lisp_Object object, Lisp_Object name)
{
  GObject *obj;
  GParamSpec *pspec;
  const char *blurb;
  obj = cmacs_gobject_unwrap (object);
  if (obj == NULL)
    error ("Not a GObject");
  CHECK_STRING (name);
  pspec = g_object_class_find_property (G_OBJECT_GET_CLASS (obj),
                                        SSDATA (name));
  if (pspec == NULL)
    return Qnil;
  blurb = g_param_spec_get_blurb (pspec);
  return CALLN (Flist,
                intern (":type"),
                build_string (g_type_name (pspec->value_type)),
                intern (":writable"),
                (pspec->flags & G_PARAM_WRITABLE) ? Qt : Qnil,
                intern (":readable"),
                (pspec->flags & G_PARAM_READABLE) ? Qt : Qnil,
                intern (":blurb"),
                blurb ? build_string (blurb) : Qnil);
}

DEFUN ("gobject-list-signals", Fgobject_list_signals,
       Sgobject_list_signals, 1, 1, 0,
       doc: /* Return a list of signal names for OBJECT. */)
  (Lisp_Object object)
{
  GObject *obj;
  guint *signal_ids;
  guint n_signals;
  guint i;
  Lisp_Object result = Qnil;

  obj = cmacs_gobject_unwrap (object);
  if (obj == NULL)
    error ("Not a GObject");

  signal_ids = g_signal_list_ids (G_OBJECT_TYPE (obj), &n_signals);

  for (i = 0; i < n_signals; i++)
    {
      const gchar *name = g_signal_name (signal_ids[i]);
      result = Fcons (build_string (name), result);
    }

  g_free (signal_ids);
  return Fnreverse (result);
}

/* ──────────────────────────────────────────────────────────────────── */
/* Init                                                                */
/* ──────────────────────────────────────────────────────────────────── */

void
syms_of_cmacs_gobject (void)
{
  DEFSYM (Qcmacs_gobject, "cmacs-gobject");
  DEFSYM (Qgobject_error, "gobject-error");

  Fput (Qgobject_error, Qerror_conditions,
        Fcons (Qgobject_error, Fcons (Qerror, Qnil)));
  Fput (Qgobject_error, Qerror_message,
        build_string ("GObject error"));

  defsubr (&Sgobject_p);
  defsubr (&Sgobject_type_name);
  defsubr (&Sgobject_get);
  defsubr (&Sgobject_set);
  defsubr (&Sgobject_connect);
  defsubr (&Sgobject_disconnect);
  defsubr (&Sgobject_new);
  defsubr (&Sgobject_list_properties);
  defsubr (&Sgobject_property_info);
  defsubr (&Sgobject_list_signals);

  cmacs_gclosure_init ();
}

#endif /* HAVE_CMACS_GLIB */
