/*
 * Copyright (C) 2026 Zach Podbielniak
 * SPDX-License-Identifier: AGPL-3.0-or-later
 */

/* cmacs-dbus-emit.c --- signal emission helpers for cmacs D-Bus
 *
 * Two public C helpers funnel every D-Bus signal emit through the
 * single g_dbus_connection_emit_signal primitive:
 *
 *   cmacs_dbus_emit_signal              -- arbitrary signal at any path
 *   cmacs_dbus_emit_properties_changed  -- standard Properties signal
 *
 * Plus two DEFUNs so Elisp hooks (after-save, kill-buffer, etc.)
 * can broadcast without a C side-trip:
 *
 *   (cmacs-dbus-emit-signal PATH IFACE NAME &optional PARAMS)
 *   (cmacs-dbus-emit-properties-changed PATH IFACE CHANGED &optional INVALIDATED)
 *
 * No-op if the service is not running.  Errors during emit are logged
 * to *Messages* but never raise --- signal emission is fire-and-forget.
 */

#include <config.h>

#ifdef HAVE_CMACS_GLIB

#include "lisp.h"
#include "cmacs-dbus.h"
#include "cmacs-dbus-internal.h"

#include <gio/gio.h>

/* ── C helpers ───────────────────────────────────────────────────── */

void
cmacs_dbus_emit_signal (const gchar *path,
                        const gchar *iface,
                        const gchar *signal_name,
                        GVariant    *params)
{
  GDBusConnection *conn = cmacs_dbus_get_connection ();
  GError *err = NULL;

  if (conn == NULL)
    {
      /* Floating params would leak — sink them. */
      if (params != NULL && g_variant_is_floating (params))
        {
          g_variant_ref_sink (params);
          g_variant_unref (params);
        }
      return;
    }

  /* g_dbus_connection_emit_signal sinks/consumes a floating params. */
  if (!g_dbus_connection_emit_signal (conn, NULL, path, iface,
                                      signal_name, params, &err))
    {
      g_warning ("cmacs-dbus: emit_signal %s.%s on %s failed: %s",
                 iface, signal_name, path, err->message);
      g_error_free (err);
    }
}

void
cmacs_dbus_emit_properties_changed (const gchar  *path,
                                    const gchar  *iface,
                                    GVariant     *changed,
                                    const gchar **invalidated)
{
  GVariantBuilder *inv_b;
  GVariant *params;
  const gchar *empty[] = { NULL };
  const gchar **inv = invalidated ? invalidated : empty;
  gint i;

  /* Build "as" array of invalidated names. */
  inv_b = g_variant_builder_new (G_VARIANT_TYPE ("as"));
  for (i = 0; inv[i] != NULL; i++)
    g_variant_builder_add (inv_b, "s", inv[i]);

  if (changed == NULL)
    changed = g_variant_new ("a{sv}", NULL);

  /* Use @a{sv} (variant) form so changed (a GVariant *) marshals
     correctly — the unprefixed a{sv} format would expect a
     GVariantBuilder * and crash. */
  params = g_variant_new ("(s@a{sv}as)", iface, changed, inv_b);
  g_variant_builder_unref (inv_b);

  cmacs_dbus_emit_signal (path, "org.freedesktop.DBus.Properties",
                          "PropertiesChanged", params);
}

/* ── Lisp marshalling ────────────────────────────────────────────── */

/* Convert a Lisp object into a GVariant of best-fit type.  Used by the
 * cmacs-dbus-emit-signal DEFUN to let Elisp build typed signal
 * payloads.  Recursive on cons / vector.  Returns NULL on unsupported. */
static GVariant *
lisp_to_variant (Lisp_Object obj)
{
  if (NILP (obj))
    /* nil -> empty variant tuple, callers usually wrap further. */
    return g_variant_new_string ("");

  if (EQ (obj, Qt))
    return g_variant_new_boolean (TRUE);

  if (FIXNUMP (obj))
    return g_variant_new_int64 (XFIXNUM (obj));

  if (FLOATP (obj))
    return g_variant_new_double (XFLOAT_DATA (obj));

  if (STRINGP (obj))
    return g_variant_new_string (SSDATA (obj));

  if (SYMBOLP (obj))
    {
      Lisp_Object name = SYMBOL_NAME (obj);
      return g_variant_new_string (STRINGP (name) ? SSDATA (name) : "");
    }

  if (CONSP (obj))
    {
      /* List of strings -> "as".  List of mixed -> "av". */
      Lisp_Object tail;
      gboolean all_strings = TRUE;
      GVariantBuilder *b;
      GVariant *v;

      for (tail = obj; CONSP (tail); tail = XCDR (tail))
        if (!STRINGP (XCAR (tail)))
          {
            all_strings = FALSE;
            break;
          }

      if (all_strings)
        {
          b = g_variant_builder_new (G_VARIANT_TYPE ("as"));
          for (tail = obj; CONSP (tail); tail = XCDR (tail))
            g_variant_builder_add (b, "s", SSDATA (XCAR (tail)));
          v = g_variant_builder_end (b);
          g_variant_builder_unref (b);
          return v;
        }

      b = g_variant_builder_new (G_VARIANT_TYPE ("av"));
      for (tail = obj; CONSP (tail); tail = XCDR (tail))
        {
          GVariant *sub = lisp_to_variant (XCAR (tail));
          g_variant_builder_add (b, "v", sub ? sub
                                              : g_variant_new_string (""));
        }
      v = g_variant_builder_end (b);
      g_variant_builder_unref (b);
      return v;
    }

  return NULL;
}

/* Build an a{sv} from a Lisp plist (:KEY VALUE :KEY VALUE ...). */
static GVariant *
plist_to_a_sv (Lisp_Object plist)
{
  GVariantBuilder *b;
  GVariant *v;
  Lisp_Object tail;

  b = g_variant_builder_new (G_VARIANT_TYPE ("a{sv}"));
  for (tail = plist; CONSP (tail) && CONSP (XCDR (tail));
       tail = XCDR (XCDR (tail)))
    {
      Lisp_Object key = XCAR (tail);
      Lisp_Object val = XCAR (XCDR (tail));
      const gchar *kname;
      GVariant *sub;

      if (!SYMBOLP (key) && !STRINGP (key))
        continue;
      kname = SYMBOLP (key) ? SSDATA (SYMBOL_NAME (key)) : SSDATA (key);
      /* Strip leading ':' from keyword symbols. */
      if (kname[0] == ':')
        kname++;
      sub = lisp_to_variant (val);
      if (sub == NULL)
        sub = g_variant_new_string ("");
      g_variant_builder_add (b, "{sv}", kname, g_variant_new_variant (sub));
    }
  v = g_variant_builder_end (b);
  g_variant_builder_unref (b);
  return v;
}

/* ── DEFUNs ──────────────────────────────────────────────────────── */

DEFUN ("cmacs-dbus-emit-signal", Fcmacs_dbus_emit_signal,
       Scmacs_dbus_emit_signal, 3, 4, 0,
       doc: /* Emit a D-Bus signal at PATH on IFACE named NAME.
Optional PARAMS is a list whose elements are marshalled into a tuple
of best-fit GVariant types (string, integer, float, t/nil -> bool,
nested list -> as / av).  Returns t on success, nil if the D-Bus
service is not running.  */)
  (Lisp_Object path, Lisp_Object iface, Lisp_Object name,
   Lisp_Object params)
{
  GVariantBuilder *tup_b;
  GVariant *tup = NULL;
  Lisp_Object tail;

  CHECK_STRING (path);
  CHECK_STRING (iface);
  CHECK_STRING (name);

  if (cmacs_dbus_get_connection () == NULL)
    return Qnil;

  if (!NILP (params))
    {
      tup_b = g_variant_builder_new (G_VARIANT_TYPE_TUPLE);
      for (tail = params; CONSP (tail); tail = XCDR (tail))
        {
          GVariant *sub = lisp_to_variant (XCAR (tail));
          if (sub != NULL)
            g_variant_builder_add_value (tup_b, sub);
        }
      tup = g_variant_builder_end (tup_b);
      g_variant_builder_unref (tup_b);
    }

  cmacs_dbus_emit_signal (SSDATA (path), SSDATA (iface),
                          SSDATA (name), tup);
  return Qt;
}

DEFUN ("cmacs-dbus-emit-properties-changed",
       Fcmacs_dbus_emit_properties_changed,
       Scmacs_dbus_emit_properties_changed, 3, 4, 0,
       doc: /* Emit org.freedesktop.DBus.Properties.PropertiesChanged
at PATH for IFACE.  CHANGED is a plist of property names and new
values.  Optional INVALIDATED is a list of property names whose values
should be marked invalidated rather than carried.  Returns t on
success, nil if the D-Bus service is not running.  */)
  (Lisp_Object path, Lisp_Object iface, Lisp_Object changed,
   Lisp_Object invalidated)
{
  GVariant *changed_v;
  const gchar **inv_array = NULL;
  Lisp_Object tail;
  gint count, i;

  CHECK_STRING (path);
  CHECK_STRING (iface);

  if (cmacs_dbus_get_connection () == NULL)
    return Qnil;

  changed_v = plist_to_a_sv (changed);

  if (!NILP (invalidated))
    {
      count = 0;
      for (tail = invalidated; CONSP (tail); tail = XCDR (tail))
        count++;
      inv_array = xnmalloc (count + 1, sizeof *inv_array);
      i = 0;
      for (tail = invalidated; CONSP (tail); tail = XCDR (tail))
        {
          Lisp_Object e = XCAR (tail);
          if (STRINGP (e))
            inv_array[i++] = SSDATA (e);
          else if (SYMBOLP (e))
            inv_array[i++] = SSDATA (SYMBOL_NAME (e));
        }
      inv_array[i] = NULL;
    }

  cmacs_dbus_emit_properties_changed (SSDATA (path), SSDATA (iface),
                                       changed_v, inv_array);

  if (inv_array != NULL)
    xfree (inv_array);

  return Qt;
}

void
syms_of_cmacs_dbus_emit (void)
{
  defsubr (&Scmacs_dbus_emit_signal);
  defsubr (&Scmacs_dbus_emit_properties_changed);
}

#endif /* HAVE_CMACS_GLIB */
