/*
 * Copyright (C) 2026 Zach Podbielniak
 * SPDX-License-Identifier: AGPL-3.0-or-later
 */

/* cmacs-dbus-iface-instance.c --- instance identity via D-Bus.
 *
 * org.cmacs.Editor1.Instance
 *
 * Info() returns a JSON document describing this cmacs process: PID,
 * Emacs version, whether it holds the well-known bus name (primary),
 * the compiled-in cmacs feature set, start time, uptime, and the MCP
 * socket path.  Consumed by `emacsctl instances' / `emacsctl describe
 * instance' and by dynamic shell completion. */

#include <config.h>

#ifdef HAVE_CMACS_GLIB

#include "cmacs-dbus.h"
#include "cmacs-dbus-internal.h"
#include "cmacs-eval-dispatch.h"

#ifdef HAVE_CMACS_MCP
#include "cmacs-mcp.h"
#endif

#include <gio/gio.h>
#include <string.h>
#include <unistd.h>

static const gchar *iface_xml =
  "<node>"
  "  <interface name='org.cmacs.Editor1.Instance'>"
  "    <method name='Info'>"
  "      <arg type='s' name='info_json' direction='out'/>"
  "    </method>"
  "    <method name='Features'>"
  "      <arg type='as' name='features' direction='out'/>"
  "    </method>"
  "  </interface>"
  "</node>";

static GDBusNodeInfo *iface_info = NULL;

/* Compiled-in cmacs subsystems, lower-case to match the
 * --with-cmacs-* configure flag names. */
static const gchar *cmacs_features[] = {
#ifdef HAVE_CMACS_GLIB
  "glib",
#endif
#ifdef HAVE_CMACS_GI
  "gi",
#endif
#ifdef HAVE_CMACS_CRISPY
  "crispy",
#endif
#ifdef HAVE_CMACS_BACON
  "bacon",
#endif
#ifdef HAVE_CMACS_GOWL
  "gowl",
#endif
#ifdef HAVE_CMACS_PODOMATION
  "podomation",
#endif
#ifdef HAVE_CMACS_LIBRECLAW
  "libreclaw",
#endif
#ifdef HAVE_CMACS_AI
  "ai",
#endif
#ifdef HAVE_CMACS_ORG_EX
  "org-ex",
#endif
#ifdef HAVE_CMACS_MCP
  "mcp",
#endif
#ifdef HAVE_CMACS_GSURF
  "gsurf",
#endif
#ifdef HAVE_CMACS_PRINT
  "print",
#endif
#ifdef HAVE_CMACS_VIDEO
  "video",
#endif
#ifdef HAVE_CMACS_AUDIO
  "audio",
#endif
#ifdef HAVE_CMACS_WHISPER
  "whisper",
#endif
#ifdef HAVE_CMACS_PIPER
  "piper",
#endif
#ifdef HAVE_CMACS_CINTROSPECT
  "cintrospect",
#endif
#ifdef HAVE_CMACS_CPATCH
  "cpatch",
#endif
#ifdef HAVE_CMACS_LIBREGNUM
  "libregnum",
#endif
#ifdef HAVE_CMACS_GNUSEYE
  "gnuseye",
#endif
  NULL
};

/* Append S to OUT as a JSON string literal. */
static void
json_append_string (GString *out, const gchar *s)
{
  g_string_append_c (out, '"');
  for (; s != NULL && *s != '\0'; s++)
    {
      switch (*s)
        {
        case '"':  g_string_append (out, "\\\""); break;
        case '\\': g_string_append (out, "\\\\"); break;
        case '\n': g_string_append (out, "\\n");  break;
        case '\r': g_string_append (out, "\\r");  break;
        case '\t': g_string_append (out, "\\t");  break;
        default:
          if ((guchar) *s < 0x20)
            g_string_append_printf (out, "\\u%04x", (guint) (guchar) *s);
          else
            g_string_append_c (out, *s);
        }
    }
  g_string_append_c (out, '"');
}

static void
on_method_call (GDBusConnection *c, const gchar *s, const gchar *o,
                const gchar *i, const gchar *m, GVariant *p,
                GDBusMethodInvocation *iv, gpointer u)
{
  (void) c; (void) s; (void) o; (void) i; (void) p; (void) u;

  if (g_strcmp0 (m, "Info") == 0)
    {
      GString *out;
      gchar *version;
      gchar *start_time;
      gchar *uptime;
      gint k;

      /* All three are best-effort: NULL just omits detail. */
      version = cmacs_dispatch_eval_string ("emacs-version", NULL);
      start_time = cmacs_dispatch_eval_string (
        "(format-time-string \"%Y-%m-%dT%H:%M:%S%z\" before-init-time)",
        NULL);
      uptime = cmacs_dispatch_eval_string ("(emacs-uptime)", NULL);

      out = g_string_new ("{");
      g_string_append_printf (out, "\"pid\":%d", (int) getpid ());

      g_string_append (out, ",\"version\":");
      json_append_string (out, version != NULL ? version : PACKAGE_VERSION);

      g_string_append_printf (out, ",\"primary\":%s",
        cmacs_dbus_get_well_known_name () != NULL ? "true" : "false");

      g_string_append (out, ",\"bus_name\":");
      json_append_string (out, cmacs_dbus_get_dominant_name ());

      g_string_append (out, ",\"features\":[");
      for (k = 0; cmacs_features[k] != NULL; k++)
        {
          if (k > 0)
            g_string_append_c (out, ',');
          json_append_string (out, cmacs_features[k]);
        }
      g_string_append_c (out, ']');

      if (start_time != NULL)
        {
          g_string_append (out, ",\"start_time\":");
          json_append_string (out, start_time);
        }
      if (uptime != NULL)
        {
          g_string_append (out, ",\"uptime\":");
          json_append_string (out, uptime);
        }

#ifdef HAVE_CMACS_MCP
      {
        const gchar *sock = cmacs_mcp_get_socket_path ();
        if (sock != NULL)
          {
            g_string_append (out, ",\"mcp_socket\":");
            json_append_string (out, sock);
          }
      }
#endif

      g_string_append_c (out, '}');

      g_dbus_method_invocation_return_value (
        iv, g_variant_new ("(s)", out->str));
      g_string_free (out, TRUE);
      g_free (version);
      g_free (start_time);
      g_free (uptime);
    }
  else if (g_strcmp0 (m, "Features") == 0)
    {
      GVariantBuilder b;
      gint k;
      g_variant_builder_init (&b, G_VARIANT_TYPE ("as"));
      for (k = 0; cmacs_features[k] != NULL; k++)
        g_variant_builder_add (&b, "s", cmacs_features[k]);
      g_dbus_method_invocation_return_value (
        iv, g_variant_new ("(as)", &b));
    }
}

static const GDBusInterfaceVTable vtable = {
  on_method_call, NULL, NULL, { NULL }
};

guint
cmacs_dbus_iface_instance_register (GDBusConnection *conn, const gchar *path,
                                    GError **error)
{
  if (iface_info == NULL)
    {
      iface_info = g_dbus_node_info_new_for_xml (iface_xml, error);
      if (iface_info == NULL) return 0;
    }
  return g_dbus_connection_register_object (
    conn, path, iface_info->interfaces[0], &vtable, NULL, NULL, error);
}

void
cmacs_dbus_iface_instance_unregister (GDBusConnection *conn, guint id)
{
  if (id > 0) g_dbus_connection_unregister_object (conn, id);
  if (iface_info != NULL)
    { g_dbus_node_info_unref (iface_info); iface_info = NULL; }
}

#endif /* HAVE_CMACS_GLIB */
