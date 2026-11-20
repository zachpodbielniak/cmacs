/*
 * Copyright (C) 2026 Zach Podbielniak
 * SPDX-License-Identifier: AGPL-3.0-or-later
 */

/* cmacs-dbus-iface-tools.c --- the capability table on D-Bus.
 *
 * org.cmacs.Editor1.Tools
 *
 *   List     ()                       -> s   the table, as JSON
 *   Describe (s name)                 -> s   one tool, as JSON
 *   Call     (s name, s json_args)    -> s   the tool's result
 *
 * This is the generic interface.  The other cmacs-dbus-iface-*.c files
 * each carry a hand-written method per capability, a matching MCP
 * handler in cmacs/mcp/ and a matching row in emacsctl, kept in step by
 * comments and parity scripts.  Here there is one method for every
 * capability, and which capabilities exist is not written in this file
 * at all: it is whatever `cmacs-brigade-deftool' registered, read
 * through lisp/cmacs/cmacs-capability.el.  A tool added in Lisp is
 * callable here, and from `emacsctl tool', with no C change.
 *
 * ── Why Call holds the invocation ───────────────────────────────────
 *
 * A tool may be :async -- it starts work and calls `done' later.  The
 * two ways to put that on D-Bus are a second method that returns a
 * token plus a ToolFinished signal, or one method whose reply is simply
 * sent later.  This file does the second:
 *
 *   - A caller does not need to know which tools are async.  `gdbus
 *     call ... Tools.Call' works for all of them, and so does any
 *     binding's ordinary method call.  The signal form makes every
 *     client subscribe first, buffer, and match tokens, to learn what a
 *     method reply already says.
 *   - A signal is a broadcast.  Every process on the session bus would
 *     be handed every tool's result.  A method reply goes to the caller.
 *   - Exactly-once has one owner.  A parked invocation is answered by
 *     taking it out of a table; whoever comes second finds nothing.
 *
 * The cost is that the caller's method timeout has to cover the tool.
 * The table carries each tool's timeout so a client can set it
 * (emacsctl does), and a caller that gives up early loses only its own
 * answer: GDBus drops a reply nobody is waiting for.
 *
 * Nothing here waits.  The dispatch runs on the main thread, which
 * under --gowl is the compositor's, so Call starts the tool and
 * returns; the reply is sent from `cmacs-capability--dbus-reply' when
 * the tool, or its timeout, says so.
 *
 * ── Caller text and Lisp source ─────────────────────────────────────
 *
 * The two strings a caller supplies are spliced into exactly one form,
 * as string literals, through cmacs_dispatch_lisp_escape, and that form
 * is read inside cmacs_dispatch_eval_string's condition-case.  The JSON
 * is parsed in Lisp with `json-parse-string'; no argument is ever part
 * of a form.  The tool name is additionally restricted to the alphabet
 * a wire name can have before it gets that far.  */

#include <config.h>

#if defined(HAVE_CMACS_GLIB) && defined(HAVE_CMACS_AI_BRIGADE)

#include "lisp.h"
#include "cmacs-dbus.h"
#include "cmacs-dbus-internal.h"
#include "cmacs-eval-dispatch.h"

#include <gio/gio.h>
#include <string.h>

#define TOOLS_ERROR_PREFIX "org.cmacs.Editor1.Error."

static const gchar *iface_xml =
  "<node>"
  "  <interface name='org.cmacs.Editor1.Tools'>"
  "    <method name='List'>"
  "      <arg type='s' name='table' direction='out'/>"
  "    </method>"
  "    <method name='Describe'>"
  "      <arg type='s' name='name' direction='in'/>"
  "      <arg type='s' name='tool' direction='out'/>"
  "    </method>"
  "    <method name='Call'>"
  "      <arg type='s' name='name' direction='in'/>"
  "      <arg type='s' name='json_args' direction='in'/>"
  "      <arg type='s' name='result' direction='out'/>"
  "    </method>"
  "  </interface>"
  "</node>";

static GDBusNodeInfo *iface_info = NULL;

/* ── Parked invocations ──────────────────────────────────────────────
 *
 * token -> GDBusMethodInvocation.  The table owns the one reference
 * GDBus handed to on_method_call, and tools_take gives it away again;
 * g_dbus_method_invocation_return_* consume it.  So an invocation is
 * answered by whoever takes it, and can be taken once.
 *
 * Tokens are integers, never the pointer: the token crosses into Lisp
 * and back, possibly much later, and a stale integer finds nothing
 * where a stale pointer would find freed memory.
 *
 * Main thread only -- the D-Bus dispatch and every Lisp caller of the
 * reply DEFUN run there -- so there is no lock.  */

static GHashTable *tools_pending = NULL;
static guint tools_next_token = 0;

static guint
tools_park (GDBusMethodInvocation *iv)
{
  if (tools_pending == NULL)
    tools_pending = g_hash_table_new (g_direct_hash, g_direct_equal);

  /* 0 is never issued, and a wrapped counter skips anything still
     parked, so a token names at most one invocation at a time.  */
  do
    tools_next_token++;
  while (tools_next_token == 0
         || g_hash_table_contains (tools_pending,
                                   GUINT_TO_POINTER (tools_next_token)));

  g_hash_table_insert (tools_pending, GUINT_TO_POINTER (tools_next_token), iv);
  return tools_next_token;
}

/* Remove and return the invocation parked under TOKEN, or NULL when it
   was already answered.  The caller now owns it and must answer it.  */
static GDBusMethodInvocation *
tools_take (guint token)
{
  GDBusMethodInvocation *iv;

  if (tools_pending == NULL)
    return NULL;
  iv = g_hash_table_lookup (tools_pending, GUINT_TO_POINTER (token));
  if (iv != NULL)
    g_hash_table_remove (tools_pending, GUINT_TO_POINTER (token));
  return iv;
}

/* True when KIND can be the last element of a D-Bus error name.  */
static gboolean
valid_error_kind (const gchar *kind)
{
  const gchar *p;

  if (kind == NULL || !g_ascii_isalpha (*kind))
    return FALSE;
  for (p = kind; *p != '\0'; p++)
    if (!g_ascii_isalnum (*p))
      return FALSE;
  return TRUE;
}

/* Answer the invocation parked under TOKEN: with TEXT as the result
   when KIND is NULL, otherwise with the D-Bus error
   org.cmacs.Editor1.Error.KIND and TEXT as its message.  Returns FALSE,
   having done nothing, when TOKEN was already answered -- which is what
   makes a second `done', or a `done' after the timeout, harmless.  */
static gboolean
tools_reply (guint token, const gchar *kind, const gchar *text)
{
  GDBusMethodInvocation *iv = tools_take (token);

  if (iv == NULL)
    return FALSE;

  if (kind == NULL)
    g_dbus_method_invocation_return_value (
      iv, g_variant_new ("(s)", text != NULL ? text : ""));
  else
    {
      g_autofree gchar *name =
        g_strconcat (TOOLS_ERROR_PREFIX,
                     valid_error_kind (kind) ? kind : "ToolFailed", NULL);

      g_dbus_method_invocation_return_dbus_error (
        iv, name, (text != NULL && *text != '\0') ? text : "tool failed");
    }
  return TRUE;
}

/* A wire name is [a-z0-9_]; registry symbols may also be written with
   hyphens.  Anything else cannot name a tool, so it is refused here
   rather than escaped and looked up.  */
static gboolean
valid_tool_name (const gchar *s)
{
  gsize n = 0;

  if (s == NULL || *s == '\0')
    return FALSE;
  for (; *s != '\0'; s++, n++)
    if (!(g_ascii_isalnum (*s) || *s == '_' || *s == '-'))
      return FALSE;
  return n <= 128;
}

/* Evaluate EXPR (taking ownership) and reply with its string value.
   For the two methods that only read the table.  */
static void
eval_to_reply (GDBusMethodInvocation *iv, gchar *expr)
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
  g_dbus_method_invocation_return_value (iv, g_variant_new ("(s)", result));
  g_free (result);
}

static void
on_method_call (GDBusConnection *c, const gchar *s, const gchar *o,
                const gchar *i, const gchar *m, GVariant *p,
                GDBusMethodInvocation *iv, gpointer u)
{
  (void) c; (void) s; (void) o; (void) i; (void) u;

  if (g_strcmp0 (m, "List") == 0)
    {
      /* Filtered to the dbus surface in Lisp: a tool that is not
         callable here is not listed here either.  */
      eval_to_reply (iv, g_strdup (
        "(progn (require 'cmacs-capability)"
        " (cmacs-capability-json 'dbus))"));
    }
  else if (g_strcmp0 (m, "Describe") == 0)
    {
      const gchar *name;
      g_autofree gchar *name_q = NULL;

      g_variant_get (p, "(&s)", &name);
      if (!valid_tool_name (name))
        {
          g_dbus_method_invocation_return_dbus_error (
            iv, TOOLS_ERROR_PREFIX "NoSuchTool",
            "name must be a tool name ([A-Za-z0-9_-]+)");
          return;
        }
      name_q = cmacs_dispatch_lisp_escape (name);
      eval_to_reply (iv, g_strdup_printf (
        "(progn (require 'cmacs-capability)"
        " (cmacs-capability-tool-json \"%s\" 'dbus))", name_q));
    }
  else if (g_strcmp0 (m, "Call") == 0)
    {
      const gchar *name, *args;
      g_autofree gchar *name_q = NULL;
      g_autofree gchar *args_q = NULL;
      g_autofree gchar *expr = NULL;
      g_autofree gchar *res = NULL;
      g_autoptr (GError) err = NULL;
      guint token;

      g_variant_get (p, "(&s&s)", &name, &args);
      if (!valid_tool_name (name))
        {
          g_dbus_method_invocation_return_dbus_error (
            iv, TOOLS_ERROR_PREFIX "NoSuchTool",
            "name must be a tool name ([A-Za-z0-9_-]+)");
          return;
        }

      /* From here the invocation belongs to the table, and every path
         answers it through tools_reply.  */
      token = tools_park (iv);

      name_q = cmacs_dispatch_lisp_escape (name);
      args_q = cmacs_dispatch_lisp_escape (args);
      expr = g_strdup_printf (
        "(progn (require 'cmacs-capability)"
        " (cmacs-capability-dbus-call %u \"%s\" \"%s\"))",
        token, name_q, args_q);

      res = cmacs_dispatch_eval_string (expr, &err);

      /* The Lisp side answers through `cmacs-capability--dbus-reply':
         before returning for a synchronous tool, later for an async
         one.  It reports its own failures the same way, so an error
         HERE means it never got that far -- the feature would not
         load, or something signalled outside its handlers.  Answer for
         it; if it did answer first, this finds nothing to do.  */
      if (res == NULL)
        tools_reply (token, "ToolFailed",
                     err != NULL ? err->message : "tool dispatch failed");
    }
  else
    g_dbus_method_invocation_return_dbus_error (
      iv, "org.freedesktop.DBus.Error.UnknownMethod", m);
}

static const GDBusInterfaceVTable vtable = {
  on_method_call, NULL, NULL, { NULL }
};

guint
cmacs_dbus_iface_tools_register (GDBusConnection *conn,
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
cmacs_dbus_iface_tools_unregister (GDBusConnection *conn, guint id)
{
  if (id > 0) g_dbus_connection_unregister_object (conn, id);

  /* The service is going away with calls still parked.  Their tools
     may yet finish, and will then find their token gone; the callers
     are told now rather than left to time out.  Collect first: a reply
     removes its entry, and the table must not change under its own
     iterator.  */
  if (tools_pending != NULL)
    {
      guint n = 0;
      guint k;
      gpointer *keys = g_hash_table_get_keys_as_array (tools_pending, &n);

      for (k = 0; k < n; k++)
        tools_reply (GPOINTER_TO_UINT (keys[k]), "ServiceStopped",
                     "the cmacs D-Bus service stopped before the tool "
                     "finished");
      g_free (keys);
    }

  if (iface_info != NULL)
    { g_dbus_node_info_unref (iface_info); iface_info = NULL; }
}

/* ── DEFUNs ──────────────────────────────────────────────────────── */

DEFUN ("cmacs-capability--dbus-reply", Fcmacs_capability__dbus_reply,
       Scmacs_capability__dbus_reply, 3, 3, 0,
       doc: /* Answer the org.cmacs.Editor1.Tools.Call parked under TOKEN.

KIND nil sends TEXT as the method's result.  KIND a string sends the
D-Bus error org.cmacs.Editor1.Error.KIND with TEXT as its message; a
KIND that cannot be part of an error name is sent as ToolFailed.

Returns t when this call answered the invocation and nil when TOKEN
was already answered or never issued.  An invocation is answered at
most once, so a tool that calls `done' twice, or after its timeout has
fired, reaches the caller only the first time.

Internal: `cmacs-capability-dbus-call' is the caller.  */)
  (Lisp_Object token, Lisp_Object kind, Lisp_Object text)
{
  g_autofree gchar *ckind = NULL;
  g_autofree gchar *ctext = NULL;

  CHECK_FIXNAT (token);
  if (!NILP (kind))
    CHECK_STRING (kind);
  CHECK_STRING (text);

  /* Out of range for a token: nothing was ever parked under it.  */
  if (XFIXNAT (token) == 0 || (uintmax_t) XFIXNAT (token) > G_MAXUINT)
    return Qnil;

  /* Valid UTF-8 or the reply is rejected on its way out and the caller
     waits for nothing: tool output can hold raw bytes.  */
  if (!NILP (kind))
    ckind = cmacs_dispatch_string_to_utf8 (kind);
  ctext = cmacs_dispatch_string_to_utf8 (text);

  return tools_reply ((guint) XFIXNAT (token), ckind, ctext) ? Qt : Qnil;
}

DEFUN ("cmacs-capability--dbus-pending", Fcmacs_capability__dbus_pending,
       Scmacs_capability__dbus_pending, 0, 0, 0,
       doc: /* Return how many Tools.Call invocations await their answer.
Non-zero while an :async tool called over D-Bus is still running.  */)
  (void)
{
  return make_fixnum (tools_pending != NULL
                      ? g_hash_table_size (tools_pending) : 0);
}

void
syms_of_cmacs_dbus_tools (void)
{
  defsubr (&Scmacs_capability__dbus_reply);
  defsubr (&Scmacs_capability__dbus_pending);
}

#endif /* HAVE_CMACS_GLIB && HAVE_CMACS_AI_BRIGADE */
