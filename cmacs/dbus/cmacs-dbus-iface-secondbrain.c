/*
 * Copyright (C) 2026 Zach Podbielniak
 * SPDX-License-Identifier: AGPL-3.0-or-later
 */

/* cmacs-dbus-iface-secondbrain.c --- the second brain via D-Bus.
 *
 * org.cmacs.Editor1.SecondBrain
 *
 * MCP parity: mirrors the secondbrain_* tools in
 * cmacs/mcp/cmacs-mcp-tools-secondbrain.c (sync discipline: adding a
 * tool there requires a matching method here, and vice versa).  The
 * elisp bodies are the MCP handlers', so `emacsctl sb ingest' and an
 * agent calling secondbrain_ingest drive one implementation.
 *
 * Two halves.  The visualiser methods (Open, SetLayout, Search, Expand,
 * NodeInfo, Stats, Sources, Refresh) act on the open view and signal
 * when there is none.  The ingest methods (Ingest, IngestStatus,
 * IngestList, IngestCancel, Tree, Find, Doctor) need no view: they are
 * the front door of the notes tree itself.
 *
 * Ingest returns as soon as the jobs are QUEUED, with their ids.  The
 * work -- fetching, transcribing, the model -- runs asynchronously on
 * the editor's main loop and a caller polls IngestStatus.  Blocking the
 * reply until the note existed would hold the editor's main thread for
 * the duration, and under `emacs --gowl' that thread is the compositor.
 * The JSON option keys are the snake_case names of
 * `cmacs-secondbrain-ingest-normalize-options'.  */

#include <config.h>

#if defined(HAVE_CMACS_GLIB) && defined(HAVE_CMACS_SECONDBRAIN)

#include "cmacs-dbus.h"
#include "cmacs-dbus-internal.h"
#include "cmacs-eval-dispatch.h"

#include <gio/gio.h>
#include <string.h>

static const gchar *iface_xml =
  "<node>"
  "  <interface name='org.cmacs.Editor1.SecondBrain'>"
  "    <method name='Open'>"
  "      <arg type='b' name='three_d' direction='in'/>"
  "      <arg type='s' name='result' direction='out'/>"
  "    </method>"
  "    <method name='SetLayout'>"
  "      <arg type='s' name='kind' direction='in'/>"
  "      <arg type='s' name='result' direction='out'/>"
  "    </method>"
  "    <method name='Search'>"
  "      <arg type='s' name='query' direction='in'/>"
  "      <arg type='b' name='semantic' direction='in'/>"
  "      <arg type='s' name='result' direction='out'/>"
  "    </method>"
  "    <method name='Expand'>"
  "      <arg type='s' name='id' direction='in'/>"
  "      <arg type='b' name='collapse' direction='in'/>"
  "      <arg type='s' name='result' direction='out'/>"
  "    </method>"
  "    <method name='NodeInfo'>"
  "      <arg type='s' name='id' direction='in'/>"
  "      <arg type='s' name='record' direction='out'/>"
  "    </method>"
  "    <method name='Stats'>"
  "      <arg type='s' name='stats' direction='out'/>"
  "    </method>"
  "    <method name='Sources'>"
  "      <arg type='s' name='sources' direction='out'/>"
  "    </method>"
  "    <method name='Refresh'>"
  "      <arg type='s' name='result' direction='out'/>"
  "    </method>"
  "    <method name='Ingest'>"
  "      <arg type='s' name='inputs_json' direction='in'/>"
  "      <arg type='s' name='options_json' direction='in'/>"
  "      <arg type='s' name='jobs_json' direction='out'/>"
  "    </method>"
  "    <method name='IngestStatus'>"
  "      <arg type='s' name='id' direction='in'/>"
  "      <arg type='s' name='status_json' direction='out'/>"
  "    </method>"
  "    <method name='IngestList'>"
  "      <arg type='s' name='jobs_json' direction='out'/>"
  "    </method>"
  "    <method name='IngestCancel'>"
  "      <arg type='s' name='id' direction='in'/>"
  "      <arg type='s' name='status_json' direction='out'/>"
  "    </method>"
  "    <method name='Tree'>"
  "      <arg type='s' name='para' direction='in'/>"
  "      <arg type='s' name='category' direction='in'/>"
  "      <arg type='b' name='files' direction='in'/>"
  "      <arg type='s' name='paths_json' direction='out'/>"
  "    </method>"
  "    <method name='Find'>"
  "      <arg type='s' name='query' direction='in'/>"
  "      <arg type='i' name='limit' direction='in'/>"
  "      <arg type='s' name='results_json' direction='out'/>"
  "    </method>"
  "    <method name='Doctor'>"
  "      <arg type='s' name='report_json' direction='out'/>"
  "    </method>"
  "    <method name='Migrate'>"
  "      <arg type='s' name='dir' direction='in'/>"
  "      <arg type='s' name='options_json' direction='in'/>"
  "      <arg type='s' name='plan_json' direction='out'/>"
  "    </method>"
  "    <method name='Watch'>"
  "      <arg type='b' name='enable' direction='in'/>"
  "      <arg type='s' name='result' direction='out'/>"
  "    </method>"
  "  </interface>"
  "</node>";

static GDBusNodeInfo *iface_info = NULL;

/* The ingester, which needs no view. */
#define SB_INGEST "(progn (require 'cmacs-secondbrain-ingest) "

/* Eval EXPR (already fully built) and reply with the raw string. */
static void
sb_reply (GDBusMethodInvocation *iv, gchar *expr)
{
  gchar *result;
  GError *err = NULL;

  result = cmacs_dispatch_eval_string (expr, &err);
  g_free (expr);
  if (result == NULL)
    {
      cmacs_dbus_return_gerror (iv, err);
      return;
    }
  g_dbus_method_invocation_return_value (
    iv, g_variant_new ("(s)", result));
  g_free (result);
}

/* Quote S as an elisp string literal ("" when NULL). */
static gchar *
sb_lisp_str (const gchar *s)
{
  gchar *esc, *out;

  esc = cmacs_dbus_lisp_escape (s != NULL ? s : "");
  out = g_strdup_printf ("\"%s\"", esc);
  g_free (esc);
  return out;
}

/* Quote S, or `nil' when it is empty: an empty D-Bus string is how a
 * caller says "not given" for an optional argument. */
static gchar *
sb_lisp_str_or_nil (const gchar *s)
{
  if (s == NULL || *s == '\0')
    return g_strdup ("nil");
  return sb_lisp_str (s);
}

static void
on_method_call (GDBusConnection *c, const gchar *s, const gchar *o,
                const gchar *i, const gchar *m, GVariant *p,
                GDBusMethodInvocation *iv, gpointer u)
{
  (void) c; (void) s; (void) o; (void) i; (void) u;

  /* ── The visualiser ─────────────────────────────────────────────── */

  /* Served from the capability table when the method has a row in
     cmacs-dbus-forward-table.h; the bodies below are the methods
     that have none.  */
  if (cmacs_dbus_forward (i, m, p, iv))
    return;

  if (g_strcmp0 (m, "Ingest") == 0)
    {
      const gchar *inputs, *options;
      gchar *qi, *qo;

      g_variant_get (p, "(&s&s)", &inputs, &options);
      if (inputs == NULL || *inputs == '\0')
        {
          g_dbus_method_invocation_return_dbus_error (
            iv, "org.cmacs.Editor1.Error", "Ingest: missing inputs_json");
          return;
        }
      qi = sb_lisp_str (inputs);
      qo = sb_lisp_str ((options != NULL && *options != '\0') ? options : "{}");
      sb_reply (iv, g_strdup_printf
        (SB_INGEST "(cmacs-secondbrain-ingest-from-json %s %s))", qi, qo));
      g_free (qi);
      g_free (qo);
    }
  else if (g_strcmp0 (m, "Migrate") == 0)
    {
      /* Plans by default; only an options object saying "apply": true
       * writes anything.  The plan is the deliverable people want to
       * read before they let a bulk conversion loose on their notes. */
      const gchar *dir, *options;
      gchar *qd, *qo;

      g_variant_get (p, "(&s&s)", &dir, &options);
      qd = sb_lisp_str_or_nil (dir);
      qo = sb_lisp_str ((options != NULL && *options != '\0') ? options : "{}");
      sb_reply (iv, g_strdup_printf
        ("(progn (require 'cmacs-secondbrain-ingest-migrate)"
         " (cmacs-secondbrain-ingest-migrate-from-json %s %s))", qd, qo));
      g_free (qd);
      g_free (qo);
    }
  else if (g_strcmp0 (m, "Watch") == 0)
    {
      gboolean enable;

      g_variant_get (p, "(b)", &enable);
      sb_reply (iv, g_strdup_printf
        (SB_INGEST "(cmacs-secondbrain-ingest-watch-mode %s)"
         " (format \"watch %%s: %%s\" (if cmacs-secondbrain-ingest-watch-mode \"on\" \"off\")"
         "  (abbreviate-file-name (expand-file-name cmacs-secondbrain-ingest-drop-directory))))",
         enable ? "1" : "-1"));
    }
  else
    g_dbus_method_invocation_return_dbus_error (
      iv, "org.freedesktop.DBus.Error.UnknownMethod", m);
}

static const GDBusInterfaceVTable vtable = {
  on_method_call, NULL, NULL, { NULL }
};

guint
cmacs_dbus_iface_secondbrain_register (GDBusConnection *conn,
                                       const gchar *path, GError **error)
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
cmacs_dbus_iface_secondbrain_unregister (GDBusConnection *conn, guint id)
{
  if (id > 0) g_dbus_connection_unregister_object (conn, id);
  if (iface_info != NULL)
    { g_dbus_node_info_unref (iface_info); iface_info = NULL; }
}

#endif /* HAVE_CMACS_GLIB && HAVE_CMACS_SECONDBRAIN */
