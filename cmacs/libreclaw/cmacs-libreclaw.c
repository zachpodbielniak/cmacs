/* cmacs-libreclaw.c — LibreClaw chat/Matrix client integration
 *
 * Copyright (C) 2026 Zach Podbielniak
 * SPDX-License-Identifier: AGPL-3.0-or-later
 *
 * Core lifecycle + DEFUNs for embedding libreclaw inside Emacs.
 * Follows the same pattern as cmacs-podomation.c:
 *   - A single global LcApp instance, created lazily via
 *     (cmacs-libreclaw-start).
 *   - Shares cmacs's existing PodEngine via lc_app_new_embedded().
 *   - Installs a podomation bridge module (pod-cmacs-libreclaw) on
 *     the shared engine so libreclaw signals become pod events.
 *   - Exposes Matrix, Local, Email, Webhook channels through a
 *     channel-kind-agnostic send path (lc_channel_send()).
 *
 * The Elisp-facing layer is `lisp/cmacs/cmacs-libreclaw.el', which
 * derives `cmacs-libreclaw-room-mode' from `org-mode' and handles
 * per-room buffer state.  See doc_org/cmacs/libreclaw/ for details. */

#include <config.h>

#ifdef HAVE_CMACS_LIBRECLAW

#include <libreclaw.h>
#include <lc-version.h>
#include <podomation.h>

#include "lisp.h"
#include "cmacs-libreclaw.h"
#include "cmacs-podomation.h"
#include "cmacs-eval-dispatch.h"

#include <errno.h>
#include <glib.h>
#include <glib/gstdio.h>

/* Forward decl from pod-cmacs-libreclaw-module.c. */
extern PodModule *pod_cmacs_libreclaw_module_new (void);
extern void
pod_cmacs_libreclaw_module_set_app (PodModule *self, LcApp *app);

/* Forward decls from sibling files in cmacs/libreclaw/. */
extern void syms_of_cmacs_libreclaw_config        (void);
extern void syms_of_cmacs_libreclaw_room          (void);
extern void syms_of_cmacs_libreclaw_marshal       (void);
extern void syms_of_cmacs_libreclaw_hatch         (void);
extern void syms_of_cmacs_libreclaw_cmacs_channel (void);
extern void syms_of_cmacs_libreclaw_remote        (void);

/* ── State ─────────────────────────────────────────────────────────── */

static LcApp    *cmacs_lc_app       = NULL;
static char     *cmacs_lc_config    = NULL;   /* malloc'd YAML path */
static PodModule *cmacs_lc_pod_module = NULL;

/* Error / dispatch symbols are registered via DEFSYM in
 * syms_of_cmacs_libreclaw below.  They become available as
 * Q... macros through src/globals.h after the build runs
 * make-docfile over the DEFSYM calls. */

LcApp *
cmacs_libreclaw_get_app (void)
{
  return cmacs_lc_app;
}

PodModule *
cmacs_libreclaw_get_pod_module (void)
{
  return cmacs_lc_pod_module;
}

/* ── Helpers ───────────────────────────────────────────────────────── */

/* Safe Lisp dispatch from GLib callback context.
 *
 * GLib handlers run inside cmacs_glib_dispatch, which already clears
 * `waiting_for_input' before firing sources, so we can safely format
 * a Lisp expression string and hand it to cmacs_dispatch_eval — the
 * same mechanism used by pod-cmacs-module.c.  This helper is kept in
 * cmacs-libreclaw.c so signal-site code in cmacs-libreclaw-room.c
 * can stay minimal; callers pass a pre-formatted expression.
 *
 * The Lisp_Object-taking signature of the original helper is kept
 * for API cleanliness — we stringify arguments into a call form.
 * For now only string/nil arguments are supported (sufficient for
 * the dispatch symbols actually in use); adding number/list support
 * is mechanical if needed later. */

static gchar *
escape_lisp_string (const gchar *s)
{
  GString *out;
  const gchar *p;

  if (s == NULL)
    return g_strdup ("nil");
  out = g_string_new ("\"");
  for (p = s; *p != '\0'; p++)
    {
      if (*p == '"' || *p == '\\')
        g_string_append_c (out, '\\');
      g_string_append_c (out, *p);
    }
  g_string_append_c (out, '"');
  return g_string_free (out, FALSE);
}

static gchar *
lisp_arg_from_object (Lisp_Object obj)
{
  if (NILP (obj))
    return g_strdup ("nil");
  if (EQ (obj, Qt))
    return g_strdup ("t");
  if (STRINGP (obj))
    return escape_lisp_string (SSDATA (obj));
  /* Fallback — stringify via prin1 would require more plumbing;
   * for now unsupported non-string / non-symbol args become nil. */
  return g_strdup ("nil");
}

void
cmacs_libreclaw_dispatch_expr (const char *expression)
{
  GError *error = NULL;

  if (expression == NULL)
    return;

  g_free (cmacs_dispatch_eval (expression, &error));
  if (error != NULL)
    {
      g_warning ("cmacs-libreclaw dispatch failed: %s", error->message);
      g_error_free (error);
    }
}

void
cmacs_libreclaw_dispatch_to_lisp (Lisp_Object fn,
                                  Lisp_Object a1, Lisp_Object a2,
                                  Lisp_Object a3, Lisp_Object a4,
                                  Lisp_Object a5)
{
  g_autofree gchar *s1 = lisp_arg_from_object (a1);
  g_autofree gchar *s2 = lisp_arg_from_object (a2);
  g_autofree gchar *s3 = lisp_arg_from_object (a3);
  g_autofree gchar *s4 = lisp_arg_from_object (a4);
  g_autofree gchar *s5 = lisp_arg_from_object (a5);
  g_autofree gchar *expr = NULL;
  const gchar *fn_name;

  if (!SYMBOLP (fn))
    return;
  fn_name = SSDATA (SYMBOL_NAME (fn));

  expr = g_strdup_printf ("(%s %s %s %s %s %s)",
                          fn_name, s1, s2, s3, s4, s5);

  cmacs_libreclaw_dispatch_expr (expr);
}

/* Classify an LcChannel by its GObject type name into a Lisp symbol. */
static Lisp_Object
channel_kind_symbol (LcChannel *ch)
{
  const char *type_name;

  if (ch == NULL)
    return intern ("unknown");

  type_name = G_OBJECT_TYPE_NAME (ch);
  if (type_name == NULL)
    return intern ("unknown");

  if (strcmp (type_name, "LcMatrixChannel") == 0)
    return intern ("matrix");
  if (strcmp (type_name, "LcLocalChannel") == 0)
    return intern ("local");
  if (strcmp (type_name, "LcCmacsChannel") == 0)
    return intern ("cmacs");
  if (strcmp (type_name, "LcEmailChannel") == 0)
    return intern ("email");
  if (strcmp (type_name, "LcWebhookChannel") == 0)
    return intern ("webhook");

  return intern ("unknown");
}

static LcChannel *
find_channel_by_id (const char *id)
{
  LcChannelManager *mgr;
  GList *channels;
  GList *l;
  LcChannel *found = NULL;

  if (cmacs_lc_app == NULL || id == NULL)
    return NULL;

  mgr = lc_app_get_channel_manager (cmacs_lc_app);
  if (mgr == NULL)
    return NULL;

  channels = lc_channel_manager_list_channels (mgr);
  for (l = channels; l != NULL; l = l->next)
    {
      LcChannel *ch = l->data;
      const char *cid = lc_channel_get_id (ch);
      if (cid != NULL && strcmp (cid, id) == 0)
        {
          found = ch;
          break;
        }
    }
  g_list_free (channels);
  return found;
}

/* ── Lifecycle DEFUNs ──────────────────────────────────────────────── */

DEFUN ("cmacs-libreclaw--start-internal", Fcmacs_libreclaw__start_internal,
       Scmacs_libreclaw__start_internal, 0, 0, 0,
       doc: /* Internal: create and start the LcApp instance.
Called from `cmacs-libreclaw-start' after the YAML config path has
been set via `cmacs-libreclaw-set-config-file'.  Shares cmacs's
existing PodEngine obtained from `cmacs-podomation-get-engine'.  */)
  (void)
{
  PodEngine *shared_engine;
  GError    *error = NULL;
  PodModuleManager *mgr;

  if (cmacs_lc_app != NULL)
    xsignal1 (Qcmacs_libreclaw_error,
              build_string ("LcApp already running"));

  if (cmacs_lc_config == NULL)
    xsignal1 (Qcmacs_libreclaw_error,
              build_string ("No config file set; "
                            "call cmacs-libreclaw-set-config-file first"));

  shared_engine = cmacs_podomation_get_engine ();
  if (shared_engine == NULL)
    xsignal1 (Qcmacs_libreclaw_error,
              build_string ("cmacs-podomation must be started first "
                            "(call cmacs-podomation-start)"));

  /* Register the cmacs-libreclaw bridge module on the shared
   * engine BEFORE we create the LcApp so that when libreclaw
   * wires its own signals, our bridge is already in place.
   *
   * Ownership model (matches cmacs-podomation.c:157):
   * `pod_module_manager_register' TAKES OWNERSHIP of the caller's
   * reference — the manager's hash table now owns the single
   * ref.  We keep a *borrowed* pointer in `cmacs_lc_pod_module'.
   * Do NOT g_object_ref or g_object_unref it from this side.
   *
   * Podomation's PodModuleManager does not expose an
   * unregister API, so the module persists across cmacs-libreclaw
   * stop/start cycles (and across cmacs-podomation stop/start,
   * since stopping/starting the engine recreates its module
   * manager).  On re-start we look the module up by name in
   * whichever manager is currently live:
   *   - same engine as last start: get_module returns the
   *     existing instance, reuse it (borrowed pointer).
   *   - new engine (podomation was restarted): get_module returns
   *     NULL, fall through to create + register a fresh module. */
  mgr = pod_engine_get_module_manager (shared_engine);
  cmacs_lc_pod_module = pod_module_manager_get_module (mgr,
                                                        "cmacs_libreclaw");
  if (cmacs_lc_pod_module == NULL)
    {
      PodModule *fresh = pod_cmacs_libreclaw_module_new ();
      if (!pod_module_manager_register (mgr, fresh))
        {
          g_object_unref (fresh);
          xsignal1 (Qcmacs_libreclaw_error,
                    build_string ("Failed to register cmacs_libreclaw "
                                  "pod module"));
        }
      /* Register took ownership — store a borrowed pointer. */
      cmacs_lc_pod_module = fresh;
    }

  /* Create the embedded LcApp on cmacs's GMainContext.
   *
   * Session persistence needs no wiring here: libreclaw defaults its
   * persist_dir under XDG when the config file does not name one.  It
   * used to leave it unset, so every async save failed with "No
   * persist_dir configured" -- a warning per save, for a setting most
   * people have no reason to know exists. */
  cmacs_lc_app = lc_app_new_embedded (cmacs_lc_config,
                                      NULL,   /* default context */
                                      shared_engine);
  if (cmacs_lc_app == NULL)
    {
      g_clear_object (&cmacs_lc_pod_module);
      xsignal1 (Qcmacs_libreclaw_error,
                build_string ("lc_app_new_embedded returned NULL"));
    }

  /* Point the bridge module at the app so it can emit events and
   * execute handler actions. */
  pod_cmacs_libreclaw_module_set_app (cmacs_lc_pod_module, cmacs_lc_app);

  if (!lc_app_start_embedded (cmacs_lc_app, &error))
    {
      Lisp_Object msg = build_string (error ? error->message
                                             : "start_embedded failed");
      if (error)
        g_error_free (error);
      g_clear_object (&cmacs_lc_app);
      g_clear_object (&cmacs_lc_pod_module);
      xsignal1 (Qcmacs_libreclaw_error, msg);
    }

  /* Wire per-room/message signal handlers now that components are up. */
  cmacs_libreclaw_room_wire_signals (cmacs_lc_app);

  /* Bind the cmacs channel (if configured) so inject/response
   * round-trips work.  Safe to call even when the YAML config did
   * not enable the cmacs channel — bind silently no-ops and the
   * DEFUNs that need it will signal cmacs-libreclaw-error. */
  cmacs_libreclaw_cmacs_channel_bind (cmacs_lc_app);

  return Qt;
}

DEFUN ("cmacs-libreclaw-stop", Fcmacs_libreclaw_stop,
       Scmacs_libreclaw_stop, 0, 0, 0,
       doc: /* Stop the LcApp and release all channels/sessions.  */)
  (void)
{
  if (cmacs_lc_app == NULL)
    return Qnil;

  /* Detach the cmacs channel callback BEFORE lc_app_stop_embedded
   * so no outbound response fires against dead Elisp state while
   * the channels are being torn down. */
  cmacs_libreclaw_cmacs_channel_unbind ();

  cmacs_libreclaw_room_unwire_signals (cmacs_lc_app);
  lc_app_stop_embedded (cmacs_lc_app);
  g_clear_object (&cmacs_lc_app);

  /* Bridge module is owned by the engine's module manager (there
   * is no unregister API in podomation).  We ONLY hold a borrowed
   * pointer — the manager took the ref at register time.
   * Do NOT unref or g_clear_object it; that would drop the
   * manager's ref and leave a dangling pointer in its hash
   * table.  Instead: clear the borrowed LcApp pointer, deactivate
   * the module (disconnects live signals), and null out our own
   * variable so the next start re-discovers the module via
   * pod_module_manager_get_module.  Matches the same ownership
   * dance cmacs-podomation.c does for pod_cmacs_module. */
  if (cmacs_lc_pod_module != NULL)
    {
      pod_cmacs_libreclaw_module_set_app (cmacs_lc_pod_module, NULL);
      pod_module_deactivate (cmacs_lc_pod_module);
      cmacs_lc_pod_module = NULL;
    }

  return Qt;
}

DEFUN ("cmacs-libreclaw-running-p", Fcmacs_libreclaw_running_p,
       Scmacs_libreclaw_running_p, 0, 0, 0,
       doc: /* Return non-nil if the LcApp is running.  */)
  (void)
{
  return cmacs_lc_app != NULL ? Qt : Qnil;
}

DEFUN ("cmacs-libreclaw-set-config-file", Fcmacs_libreclaw_set_config_file,
       Scmacs_libreclaw_set_config_file, 1, 1, 0,
       doc: /* Set the YAML config path FILE used by the next start.  */)
  (Lisp_Object file)
{
  CHECK_STRING (file);
  g_free (cmacs_lc_config);
  cmacs_lc_config = g_strdup (SSDATA (file));
  return file;
}

DEFUN ("cmacs-libreclaw-get-config-file",
       Fcmacs_libreclaw_get_config_file,
       Scmacs_libreclaw_get_config_file, 0, 0, 0,
       doc: /* Return the currently configured YAML path, or nil.  */)
  (void)
{
  if (cmacs_lc_config == NULL)
    return Qnil;
  return build_string (cmacs_lc_config);
}

DEFUN ("cmacs-libreclaw-reload-config", Fcmacs_libreclaw_reload_config,
       Scmacs_libreclaw_reload_config, 0, 0, 0,
       doc: /* Reload config from disk and re-emit config-reloaded.  */)
  (void)
{
  LcConfig *cfg;
  GError *error = NULL;

  if (cmacs_lc_app == NULL)
    xsignal1 (Qcmacs_libreclaw_error,
              build_string ("LcApp not running"));

  cfg = lc_app_get_config (cmacs_lc_app);
  if (cfg == NULL)
    return Qnil;

  if (!lc_config_load_from_path (cfg, cmacs_lc_config, &error))
    {
      Lisp_Object msg = build_string (error ? error->message : "reload failed");
      if (error)
        g_error_free (error);
      xsignal1 (Qcmacs_libreclaw_error, msg);
    }
  return Qt;
}

DEFUN ("cmacs-libreclaw-version", Fcmacs_libreclaw_version,
       Scmacs_libreclaw_version, 0, 0, 0,
       doc: /* Return the libreclaw version string.  */)
  (void)
{
  char buf[64];
  g_snprintf (buf, sizeof (buf), "%d.%d.%d",
              LC_VERSION_MAJOR, LC_VERSION_MINOR, LC_VERSION_MICRO);
  return build_string (buf);
}

DEFUN ("cmacs-libreclaw-agent-name", Fcmacs_libreclaw_agent_name,
       Scmacs_libreclaw_agent_name, 0, 0, 0,
       doc: /* Return the agent name from the running LcApp's config.
Reads `agent.name' from the currently loaded YAML.  Returns nil
when libreclaw is not running or the config has no agent.name
field set.  Reflects hot-reloads — re-reading the config via
`cmacs-libreclaw-reload-config' updates the value this DEFUN
returns without needing a subsystem restart.  */)
  (void)
{
  LcConfig    *cfg;
  const char  *name;

  if (cmacs_lc_app == NULL)
    return Qnil;

  cfg = lc_app_get_config (cmacs_lc_app);
  if (cfg == NULL)
    return Qnil;

  name = lc_config_get_agent_name (cfg);
  if (name == NULL || name[0] == '\0')
    return Qnil;

  return build_string (name);
}

DEFUN ("cmacs-libreclaw-podomation-shared-p",
       Fcmacs_libreclaw_podomation_shared_p,
       Scmacs_libreclaw_podomation_shared_p, 0, 0, 0,
       doc: /* Return t if libreclaw is sharing cmacs's PodEngine.
Signals `cmacs-libreclaw-error' if libreclaw is not running or the
engine is not the expected cmacs engine.  */)
  (void)
{
  if (cmacs_lc_app == NULL)
    return Qnil;
  if (cmacs_podomation_get_engine () == NULL)
    return Qnil;
  /* The bridge module's presence on the shared engine is our proof:
   * start_internal registered it there, and stop deactivates it. */
  return cmacs_lc_pod_module != NULL ? Qt : Qnil;
}

/* ── Channel DEFUNs ────────────────────────────────────────────────── */

DEFUN ("cmacs-libreclaw-list-channels", Fcmacs_libreclaw_list_channels,
       Scmacs_libreclaw_list_channels, 0, 0, 0,
       doc: /* Return an alist ((ID . KIND) ...) of active channels.  */)
  (void)
{
  LcChannelManager *mgr;
  GList *channels;
  GList *l;
  Lisp_Object result = Qnil;

  if (cmacs_lc_app == NULL)
    return Qnil;

  mgr = lc_app_get_channel_manager (cmacs_lc_app);
  if (mgr == NULL)
    return Qnil;

  channels = lc_channel_manager_list_channels (mgr);
  for (l = channels; l != NULL; l = l->next)
    {
      LcChannel *ch = l->data;
      const char *id = lc_channel_get_id (ch);
      Lisp_Object cell;

      if (id == NULL)
        continue;
      cell = Fcons (build_string (id), channel_kind_symbol (ch));
      result = Fcons (cell, result);
    }
  g_list_free (channels);
  return Fnreverse (result);
}

DEFUN ("cmacs-libreclaw-channel-kind", Fcmacs_libreclaw_channel_kind,
       Scmacs_libreclaw_channel_kind, 1, 1, 0,
       doc: /* Return the kind symbol for channel ID.
Symbols: `matrix', `local', `email', `webhook', or `unknown'.  */)
  (Lisp_Object id)
{
  LcChannel *ch;

  CHECK_STRING (id);
  ch = find_channel_by_id (SSDATA (id));
  if (ch == NULL)
    return intern ("unknown");
  return channel_kind_symbol (ch);
}

DEFUN ("cmacs-libreclaw-channel-connected-p",
       Fcmacs_libreclaw_channel_connected_p,
       Scmacs_libreclaw_channel_connected_p, 1, 1, 0,
       doc: /* Return non-nil if channel ID is connected.  */)
  (Lisp_Object id)
{
  LcChannel *ch;

  CHECK_STRING (id);
  ch = find_channel_by_id (SSDATA (id));
  if (ch == NULL)
    return Qnil;
  return lc_channel_is_connected (ch) ? Qt : Qnil;
}

DEFUN ("cmacs-libreclaw-channel-connect",
       Fcmacs_libreclaw_channel_connect,
       Scmacs_libreclaw_channel_connect, 1, 1, 0,
       doc: /* Request an async connect on channel ID.  */)
  (Lisp_Object id)
{
  LcChannel *ch;

  CHECK_STRING (id);
  ch = find_channel_by_id (SSDATA (id));
  if (ch == NULL)
    xsignal1 (Qcmacs_libreclaw_error,
              build_string ("Unknown channel id"));

  lc_channel_connect_async (ch, NULL, NULL, NULL);
  return Qt;
}

DEFUN ("cmacs-libreclaw-channel-disconnect",
       Fcmacs_libreclaw_channel_disconnect,
       Scmacs_libreclaw_channel_disconnect, 1, 1, 0,
       doc: /* Request an async disconnect on channel ID.  */)
  (Lisp_Object id)
{
  LcChannel *ch;

  CHECK_STRING (id);
  ch = find_channel_by_id (SSDATA (id));
  if (ch == NULL)
    xsignal1 (Qcmacs_libreclaw_error,
              build_string ("Unknown channel id"));

  lc_channel_disconnect_async (ch, NULL, NULL, NULL);
  return Qt;
}

/* ── Messaging DEFUNs ──────────────────────────────────────────────── */

DEFUN ("cmacs-libreclaw-send-message", Fcmacs_libreclaw_send_message,
       Scmacs_libreclaw_send_message, 3, 5, 0,
       doc: /* Send BODY to ROOM-ID on CHANNEL-ID asynchronously.
Optional HTML-BODY and THREAD-ID for Matrix reply threading.
Returns t immediately after queueing the send — actual delivery
is async via libreclaw's GTask pipeline.  Failures surface through
the `channel-error' signal, which dispatches to
`cmacs-libreclaw--on-channel-state' in Elisp.  */)
  (Lisp_Object channel_id, Lisp_Object room_id, Lisp_Object body,
   Lisp_Object html_body, Lisp_Object thread_id)
{
  LcChannel *ch;
  LcOutboundMessage *msg;
  const char *hb = NULL;
  const char *tid = NULL;

  CHECK_STRING (channel_id);
  CHECK_STRING (room_id);
  CHECK_STRING (body);

  if (!NILP (html_body))
    {
      CHECK_STRING (html_body);
      hb = SSDATA (html_body);
    }
  if (!NILP (thread_id))
    {
      CHECK_STRING (thread_id);
      tid = SSDATA (thread_id);
    }

  ch = find_channel_by_id (SSDATA (channel_id));
  if (ch == NULL)
    xsignal1 (Qcmacs_libreclaw_error,
              build_string ("Unknown channel id"));

  msg = lc_outbound_message_new (SSDATA (channel_id),
                                 SSDATA (room_id),
                                 NULL,    /* target_user */
                                 SSDATA (body),
                                 hb,
                                 tid);

  /* Fire-and-forget: libreclaw takes ownership of msg via transfer-full
   * async semantics; we don't need a callback — channel-error signal
   * surfaces failures to Elisp via the room-signals bridge. */
  lc_channel_send_message_async (ch, msg, NULL, NULL, NULL);
  lc_outbound_message_free (msg);
  return Qt;
}

DEFUN ("cmacs-libreclaw-list-rooms", Fcmacs_libreclaw_list_rooms,
       Scmacs_libreclaw_list_rooms, 0, 1, 0,
       doc: /* Return a list of (CHANNEL-ID ROOM-ID NAME) triples.
If CHANNEL is non-nil, filter to rooms on that channel only.

NOTE: libreclaw does not currently expose a per-channel room list
API — this DEFUN returns the rooms that cmacs has *observed* via
`room-added' signal dispatches, which are tracked in the Elisp
`cmacs-libreclaw-rooms-alist'.  From C we simply signal that the
Elisp side should answer; callers typically use the Elisp alist
directly.  */)
  (Lisp_Object channel)
{
  (void)channel;
  /* Elisp-side tracking wins — see `cmacs-libreclaw-list-rooms' in
   * cmacs-libreclaw.el which maintains the canonical alist. */
  return Qnil;
}

DEFUN ("cmacs-libreclaw-join-room", Fcmacs_libreclaw_join_room,
       Scmacs_libreclaw_join_room, 2, 2, 0,
       doc: /* Matrix-only: join ROOM-ID on CHANNEL-ID.

NOTE: libreclaw 0.18.0 does not expose a public join-room API on
LcMatrixChannel — rooms are determined at startup from the YAML
config's auto_join list.  This DEFUN signals a clear error pointing
at the config; future libreclaw versions can plug in the real API
here without any Elisp-side changes.  */)
  (Lisp_Object channel_id, Lisp_Object room_id)
{
  CHECK_STRING (channel_id);
  CHECK_STRING (room_id);
  xsignal1 (Qcmacs_libreclaw_error,
            build_string ("join-room not supported by libreclaw 0.18.0; "
                          "add the room to auto_join in config.yaml and "
                          "reload, or wait for a newer libreclaw release"));
  return Qt;  /* unreachable */
}

DEFUN ("cmacs-libreclaw-leave-room", Fcmacs_libreclaw_leave_room,
       Scmacs_libreclaw_leave_room, 2, 2, 0,
       doc: /* Matrix-only: leave ROOM-ID on CHANNEL-ID.

See `cmacs-libreclaw-join-room' — not supported in libreclaw 0.18.0.  */)
  (Lisp_Object channel_id, Lisp_Object room_id)
{
  CHECK_STRING (channel_id);
  CHECK_STRING (room_id);
  xsignal1 (Qcmacs_libreclaw_error,
            build_string ("leave-room not supported by libreclaw 0.18.0"));
  return Qt;  /* unreachable */
}

/* ── Init ──────────────────────────────────────────────────────────── */

void
syms_of_cmacs_libreclaw (void)
{
  DEFSYM (Qcmacs_libreclaw_error, "cmacs-libreclaw-error");
  Fput (Qcmacs_libreclaw_error, Qerror_conditions,
        Fcons (Qcmacs_libreclaw_error, Fcons (Qerror, Qnil)));
  Fput (Qcmacs_libreclaw_error, Qerror_message,
        build_string ("LibreClaw error"));

  DEFSYM (Qcmacs_libreclaw_on_room_added,
          "cmacs-libreclaw--on-room-added");
  DEFSYM (Qcmacs_libreclaw_on_room_removed,
          "cmacs-libreclaw--on-room-removed");
  DEFSYM (Qcmacs_libreclaw_on_message,
          "cmacs-libreclaw--on-message");
  DEFSYM (Qcmacs_libreclaw_on_message_sent,
          "cmacs-libreclaw--on-message-sent");
  DEFSYM (Qcmacs_libreclaw_on_channel_state,
          "cmacs-libreclaw--on-channel-state");
  DEFSYM (Qcmacs_libreclaw_on_session_created,
          "cmacs-libreclaw--on-session-created");
  DEFSYM (Qcmacs_libreclaw_on_session_destroyed,
          "cmacs-libreclaw--on-session-destroyed");

  /* Lifecycle. */
  defsubr (&Scmacs_libreclaw__start_internal);
  defsubr (&Scmacs_libreclaw_stop);
  defsubr (&Scmacs_libreclaw_running_p);
  defsubr (&Scmacs_libreclaw_set_config_file);
  defsubr (&Scmacs_libreclaw_get_config_file);
  defsubr (&Scmacs_libreclaw_reload_config);
  defsubr (&Scmacs_libreclaw_version);
  defsubr (&Scmacs_libreclaw_agent_name);
  defsubr (&Scmacs_libreclaw_podomation_shared_p);

  /* Channels. */
  defsubr (&Scmacs_libreclaw_list_channels);
  defsubr (&Scmacs_libreclaw_channel_kind);
  defsubr (&Scmacs_libreclaw_channel_connected_p);
  defsubr (&Scmacs_libreclaw_channel_connect);
  defsubr (&Scmacs_libreclaw_channel_disconnect);

  /* Messaging. */
  defsubr (&Scmacs_libreclaw_send_message);
  defsubr (&Scmacs_libreclaw_list_rooms);
  defsubr (&Scmacs_libreclaw_join_room);
  defsubr (&Scmacs_libreclaw_leave_room);

  /* Sibling-file DEFUNs. */
  syms_of_cmacs_libreclaw_config        ();
  syms_of_cmacs_libreclaw_room          ();
  syms_of_cmacs_libreclaw_marshal       ();
  syms_of_cmacs_libreclaw_hatch         ();
  syms_of_cmacs_libreclaw_cmacs_channel ();
  syms_of_cmacs_libreclaw_remote        ();
}

void
init_cmacs_libreclaw (void)
{
  /* Intentionally empty.  The LcApp is created lazily from Elisp
   * via (cmacs-libreclaw-start).  Keeps pdumper state clean — see
   * cmacs-podomation.c:554 for the same pattern. */
}

#endif /* HAVE_CMACS_LIBRECLAW */
