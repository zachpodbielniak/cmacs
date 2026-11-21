/*
 * Copyright (C) 2026 Zach Podbielniak
 * SPDX-License-Identifier: AGPL-3.0-or-later
 */

/* cmacs-dbus-forward.c --- legacy D-Bus methods served from the
 * capability table.
 *
 * The per-subsystem interfaces (org.cmacs.Editor1.Compositor, .Gsurf,
 * .BufferManager, ...) each carried a hand-written body per method: a
 * Lisp form built with printf, evaluated, its printed value sent back.
 * The registry (`cmacs-brigade-deftool') now provides most of those
 * capabilities as tools, and org.cmacs.Editor1.Tools.Call reaches any
 * of them -- so the bodies had become a second copy, and one that had
 * drifted: no redaction, no argument validation, no confirmation
 * policy, a blocked main thread where the tool is asynchronous.
 *
 * This file replaces the bodies, not the methods.  Every interface
 * name, method name and signature stays exactly as it was, in the
 * introspection XML of the file that registers it.  What changes is
 * that each interface's method handler begins with
 *
 *     if (cmacs_dbus_forward (iface, method, params, invocation))
 *       return;
 *
 * and a method with a row in cmacs-dbus-forward-table.h is answered
 * from here:
 *
 *   1. the row's argument map turns the method's typed arguments into
 *      one JSON object;
 *   2. the invocation is parked under an integer token;
 *   3. `cmacs-dbus-forward-call' (lisp/cmacs/cmacs-dbus-forward.el)
 *      runs the row's target -- a registry tool through the gates
 *      Tools.Call uses, or a Lisp method function -- and answers the
 *      token, at once or, for an :async tool, when it finishes;
 *   4. the answer is converted to the method's own declared reply type
 *      and sent.
 *
 * So a forwarded method is a row, not code, and it inherits what the
 * tool has.  A method without a row returns FALSE from here and runs
 * its hand-written body as before.
 *
 * ── Ownership of the invocation ─────────────────────────────────────
 *
 * GDBus hands a method handler the invocation transfer-full, and each
 * g_dbus_method_invocation_return_* consumes it.  cmacs_dbus_forward
 * takes that one reference when, and only when, it returns TRUE; from
 * then on it sits in a table keyed by the token, and is answered by
 * whoever takes it out -- which can therefore happen once.  A second
 * `done', a `done' after the timeout, a reply after the service
 * stopped: each finds nothing under the token and does nothing.
 *
 * The token is an integer because it crosses into Lisp and comes back
 * later.  A stale integer finds an empty slot; a stale pointer would
 * find freed memory.
 *
 * ── Nothing waits ───────────────────────────────────────────────────
 *
 * The dispatch runs on the main thread, which under --gowl is the
 * compositor's.  cmacs_dbus_forward starts the target and returns; the
 * reply is sent from `cmacs-dbus-forward--reply'.  Several of the
 * bodies this replaces (Ai.Prompt, Project.Grep, DbExplorer.Query)
 * held that thread for as long as a model, grep or a database took.
 *
 * ── Caller text and Lisp source ─────────────────────────────────────
 *
 * Arguments reach Lisp as ONE string literal holding JSON, escaped by
 * cmacs_dispatch_lisp_escape and read inside the dispatch's
 * condition-case; the JSON is parsed by `json-parse-string'.  No
 * argument is ever part of a form, which the bodies this replaces
 * could not say (they spliced each one, and whitelisted the ones that
 * became bare symbols).  The other strings in the form come from the
 * table.  */

#include <config.h>

#ifdef HAVE_CMACS_GLIB

#include "lisp.h"
#include "cmacs-dbus.h"
#include "cmacs-dbus-internal.h"
#include "cmacs-eval-dispatch.h"

#include <gio/gio.h>
#include <math.h>
#include <string.h>

#define FORWARD_IFACE_ROOT   "org.cmacs.Editor1"
#define FORWARD_ERROR_PREFIX "org.cmacs.Editor1.Error."

/* Row flags.  The Lisp side reads the same two bits
   (`cmacs-dbus-forward-flag-legacy-reach', `-flag-approve').  */
#define CMACS_DBUS_FWD_LEGACY  (1u << 0)
#define CMACS_DBUS_FWD_APPROVE (1u << 1)

typedef struct
{
  const gchar *iface;    /* after "org.cmacs.Editor1."; "" is the root */
  const gchar *method;
  const gchar *target;   /* tool wire name, or "@lisp-method" */
  const gchar *args;     /* argument map; see the table's header */
  const gchar *reply;    /* reply adapter name */
  guint flags;
} CmacsDbusForwardRow;

/* The table.  Its file is also read as text by the tests and the
   audit, which is why the rows are spelt with a macro that has no
   other use.  */
#define LEGACY  CMACS_DBUS_FWD_LEGACY
#define APPROVE CMACS_DBUS_FWD_APPROVE
#define FWD(iface_, method_, target_, args_, reply_, flags_)           \
  { iface_, method_, target_, args_, reply_, flags_ },

static const CmacsDbusForwardRow forward_rows[] = {
#include "cmacs-dbus-forward-table.h"
};

#undef FWD
#undef APPROVE
#undef LEGACY

/* ── Parked invocations ──────────────────────────────────────────── */

typedef struct
{
  GDBusMethodInvocation *iv;   /* the reference GDBus gave the handler */
  gchar *signature;            /* the method's out signature, a tuple */
} ForwardPending;

/* token -> ForwardPending.  Main thread only: the D-Bus dispatch and
   every Lisp caller of the reply DEFUN run there, so there is no
   lock.  */
static GHashTable *forward_pending = NULL;
static guint forward_next_token = 0;

static guint
forward_park (GDBusMethodInvocation *iv, gchar *signature)
{
  ForwardPending *p = g_new0 (ForwardPending, 1);

  if (forward_pending == NULL)
    forward_pending = g_hash_table_new (g_direct_hash, g_direct_equal);

  /* 0 is never issued, and a wrapped counter skips anything still
     parked, so a token names at most one invocation at a time.  */
  do
    forward_next_token++;
  while (forward_next_token == 0
         || g_hash_table_contains (forward_pending,
                                   GUINT_TO_POINTER (forward_next_token)));

  p->iv = iv;
  p->signature = signature;
  g_hash_table_insert (forward_pending,
                       GUINT_TO_POINTER (forward_next_token), p);
  return forward_next_token;
}

/* Remove and return what is parked under TOKEN, or NULL when it was
   already answered.  The caller owns the result and must answer the
   invocation and free the rest.  */
static ForwardPending *
forward_take (guint token)
{
  ForwardPending *p;

  if (forward_pending == NULL)
    return NULL;
  p = g_hash_table_lookup (forward_pending, GUINT_TO_POINTER (token));
  if (p != NULL)
    g_hash_table_remove (forward_pending, GUINT_TO_POINTER (token));
  return p;
}

/* True when KIND can be the last element of a D-Bus error name.  */
static gboolean
forward_valid_kind (const gchar *kind)
{
  const gchar *c;

  if (kind == NULL || !g_ascii_isalpha (*kind))
    return FALSE;
  for (c = kind; *c != '\0'; c++)
    if (!g_ascii_isalnum (*c))
      return FALSE;
  return TRUE;
}

/* Answer the invocation parked under TOKEN.  With KIND, the D-Bus
   error org.cmacs.Editor1.Error.KIND and TEXT as its message.
   Without, TEXT is the result: sent verbatim when the method replies
   with one string, and otherwise parsed as GVariant text against the
   method's own out signature -- so what goes on the wire has the
   declared type or the call fails; it can never have another.

   Returns FALSE, having done nothing, when TOKEN was already
   answered.  */
static gboolean
forward_reply (guint token, const gchar *kind, const gchar *text)
{
  ForwardPending *p = forward_take (token);

  if (p == NULL)
    return FALSE;

  if (kind != NULL)
    {
      g_autofree gchar *name =
        g_strconcat (FORWARD_ERROR_PREFIX,
                     forward_valid_kind (kind) ? kind : "ToolFailed", NULL);

      g_dbus_method_invocation_return_dbus_error (
        p->iv, name, (text != NULL && *text != '\0') ? text : "call failed");
    }
  else if (strcmp (p->signature, "(s)") == 0)
    g_dbus_method_invocation_return_value (
      p->iv, g_variant_new ("(s)", text != NULL ? text : ""));
  else
    {
      g_autoptr (GError) err = NULL;
      GVariant *value =
        g_variant_parse (G_VARIANT_TYPE (p->signature),
                         text != NULL ? text : "", NULL, NULL, &err);

      if (value == NULL)
        {
          g_autofree gchar *msg =
            g_strdup_printf ("the result could not be sent as %s: %s",
                             p->signature,
                             err != NULL ? err->message : "unparsable");

          g_dbus_method_invocation_return_dbus_error (
            p->iv, FORWARD_ERROR_PREFIX "ToolFailed", msg);
        }
      else
        {
          /* g_variant_parse returns a full reference, and the return
             takes one of its own.  */
          g_dbus_method_invocation_return_value (p->iv, value);
          g_variant_unref (value);
        }
    }

  g_free (p->signature);
  g_free (p);
  return TRUE;
}

/* ── The table ───────────────────────────────────────────────────── */

/* The row for METHOD of the interface IFACE (a full interface name),
   or NULL.  A linear scan: a few hundred string compares against a
   D-Bus round trip is nothing, and a sorted table would be one more
   thing to keep true.  */
static const CmacsDbusForwardRow *
forward_find (const gchar *iface, const gchar *method)
{
  const gchar *tail;
  gsize k;

  if (iface == NULL || method == NULL
      || !g_str_has_prefix (iface, FORWARD_IFACE_ROOT))
    return NULL;
  tail = iface + strlen (FORWARD_IFACE_ROOT);
  if (*tail == '.')
    tail++;
  else if (*tail != '\0')
    return NULL;

  for (k = 0; k < G_N_ELEMENTS (forward_rows); k++)
    if (strcmp (forward_rows[k].method, method) == 0
        && strcmp (forward_rows[k].iface, tail) == 0)
      return &forward_rows[k];
  return NULL;
}

/* ── Arguments: GVariant -> JSON ─────────────────────────────────── */

static void
forward_append_json_string (GString *out, const gchar *s)
{
  g_autofree gchar *q = cmacs_dispatch_json_escape (s != NULL ? s : "");

  g_string_append_c (out, '"');
  g_string_append (out, q);
  g_string_append_c (out, '"');
}

/* Append VALUE as JSON to OUT and say through *EMPTY whether it is the
   "not given" spelling of its type: an empty string, array or dict, or
   a number <= 0.  FALSE, with ERROR set, for a type a row cannot
   carry.  */
static gboolean
forward_append_value (GString *out, GVariant *value, gboolean *empty,
                      GError **error)
{
  const GVariantType *type = g_variant_get_type (value);

  *empty = FALSE;

  if (g_variant_type_equal (type, G_VARIANT_TYPE_STRING))
    {
      const gchar *s = g_variant_get_string (value, NULL);

      *empty = (*s == '\0');
      forward_append_json_string (out, s);
    }
  else if (g_variant_type_equal (type, G_VARIANT_TYPE_BOOLEAN))
    g_string_append (out, g_variant_get_boolean (value) ? "true" : "false");
  else if (g_variant_type_equal (type, G_VARIANT_TYPE_DOUBLE))
    {
      gdouble d = g_variant_get_double (value);
      gchar buf[G_ASCII_DTOSTR_BUF_SIZE];

      /* JSON has no spelling for these, and no method wants one.  */
      if (isnan (d) || isinf (d))
        {
          g_set_error_literal (error, G_DBUS_ERROR, G_DBUS_ERROR_INVALID_ARGS,
                               "a number argument is not finite");
          return FALSE;
        }
      *empty = (d <= 0.0);
      g_string_append (out, g_ascii_dtostr (buf, sizeof buf, d));
    }
  else if (g_variant_type_equal (type, G_VARIANT_TYPE_BYTE)
           || g_variant_type_equal (type, G_VARIANT_TYPE_INT16)
           || g_variant_type_equal (type, G_VARIANT_TYPE_INT32)
           || g_variant_type_equal (type, G_VARIANT_TYPE_INT64))
    {
      gint64 n =
        g_variant_type_equal (type, G_VARIANT_TYPE_BYTE)
          ? (gint64) g_variant_get_byte (value)
        : g_variant_type_equal (type, G_VARIANT_TYPE_INT16)
          ? (gint64) g_variant_get_int16 (value)
        : g_variant_type_equal (type, G_VARIANT_TYPE_INT32)
          ? (gint64) g_variant_get_int32 (value)
        : g_variant_get_int64 (value);

      *empty = (n <= 0);
      g_string_append_printf (out, "%" G_GINT64_FORMAT, n);
    }
  else if (g_variant_type_equal (type, G_VARIANT_TYPE_UINT16)
           || g_variant_type_equal (type, G_VARIANT_TYPE_UINT32)
           || g_variant_type_equal (type, G_VARIANT_TYPE_UINT64))
    {
      guint64 n =
        g_variant_type_equal (type, G_VARIANT_TYPE_UINT16)
          ? (guint64) g_variant_get_uint16 (value)
        : g_variant_type_equal (type, G_VARIANT_TYPE_UINT32)
          ? (guint64) g_variant_get_uint32 (value)
        : g_variant_get_uint64 (value);

      *empty = (n == 0);
      g_string_append_printf (out, "%" G_GUINT64_FORMAT, n);
    }
  else if (g_variant_type_equal (type, G_VARIANT_TYPE_STRING_ARRAY))
    {
      GVariantIter iter;
      const gchar *s;
      gboolean first = TRUE;

      g_variant_iter_init (&iter, value);
      g_string_append_c (out, '[');
      while (g_variant_iter_next (&iter, "&s", &s))
        {
          if (!first)
            g_string_append_c (out, ',');
          first = FALSE;
          forward_append_json_string (out, s);
        }
      g_string_append_c (out, ']');
      *empty = first;
    }
  else if (g_variant_type_equal (type, G_VARIANT_TYPE ("a{ss}")))
    {
      GVariantIter iter;
      const gchar *k, *v;
      gboolean first = TRUE;

      g_variant_iter_init (&iter, value);
      g_string_append_c (out, '{');
      while (g_variant_iter_next (&iter, "{&s&s}", &k, &v))
        {
          if (!first)
            g_string_append_c (out, ',');
          first = FALSE;
          forward_append_json_string (out, k);
          g_string_append_c (out, ':');
          forward_append_json_string (out, v);
        }
      g_string_append_c (out, '}');
      *empty = first;
    }
  else
    {
      g_set_error (error, G_DBUS_ERROR, G_DBUS_ERROR_FAILED,
                   "the forwarding table cannot carry an argument of "
                   "type %s", g_variant_get_type_string (value));
      return FALSE;
    }
  return TRUE;
}

/* Build the JSON object ROW's argument map describes from PARAMS, the
   method's input tuple.  Returns it (caller frees), or NULL with ERROR
   set -- when a value cannot be carried, or when the map does not fit
   the method, which is a mistake in the table and is reported as one
   rather than guessed around.  */
static gchar *
forward_build_args (const CmacsDbusForwardRow *row, GVariant *params,
                    GError **error)
{
  g_auto (GStrv) items = g_strsplit (row->args, ",", -1);
  g_autoptr (GString) json = g_string_new ("{");
  gsize n_params = params != NULL ? g_variant_n_children (params) : 0;
  gsize next = 0;
  gboolean first = TRUE;
  gsize k;

  for (k = 0; items[k] != NULL; k++)
    {
      const gchar *item = items[k];
      const gchar *eq, *opt;
      g_autofree gchar *name = NULL;
      g_autoptr (GVariant) value = NULL;
      g_autoptr (GString) text = NULL;
      const gchar *fallback = NULL;
      gboolean empty = FALSE;

      /* "" is the map of a method with no arguments.  */
      if (*item == '\0')
        continue;

      /* name=VALUE: a constant, sent as a JSON string.  The argument
         validation converts it ("3" is an integer, "true" a boolean),
         so the table needs no syntax for types.  */
      eq = strchr (item, '=');
      if (eq != NULL)
        {
          name = g_strndup (item, (gsize) (eq - item));
          if (!first)
            g_string_append_c (json, ',');
          first = FALSE;
          forward_append_json_string (json, name);
          g_string_append_c (json, ':');
          forward_append_json_string (json, eq + 1);
          continue;
        }

      if (next >= n_params)
        goto misfit;
      value = g_variant_get_child_value (params, next++);

      if (strcmp (item, "-") == 0)
        continue;

      opt = strchr (item, '?');
      if (opt != NULL)
        {
          name = g_strndup (item, (gsize) (opt - item));
          if (opt[1] == ':')
            fallback = opt + 2;
          else if (opt[1] != '\0')
            goto misfit;
        }
      else
        name = g_strdup (item);

      text = g_string_new (NULL);
      if (!forward_append_value (text, value, &empty, error))
        return NULL;

      if (opt != NULL && empty)
        {
          if (fallback == NULL)
            continue;
          /* The method's own default: text for a string argument,
             and otherwise a literal the table's author wrote as a
             number.  */
          g_string_truncate (text, 0);
          if (g_variant_is_of_type (value, G_VARIANT_TYPE_STRING))
            forward_append_json_string (text, fallback);
          else
            g_string_append (text, fallback);
        }

      if (!first)
        g_string_append_c (json, ',');
      first = FALSE;
      forward_append_json_string (json, name);
      g_string_append_c (json, ':');
      g_string_append (json, text->str);
    }

  if (next != n_params)
    goto misfit;

  g_string_append_c (json, '}');
  return g_string_free (g_steal_pointer (&json), FALSE);

misfit:
  g_set_error (error, G_DBUS_ERROR, G_DBUS_ERROR_FAILED,
               "forwarding table: the argument map of %s.%s does not "
               "fit the method's arguments", row->iface, row->method);
  return NULL;
}

/* The out signature of the method IV invokes, as a tuple type string
   ("(s)", "(as)", "()").  Caller frees.  */
static gchar *
forward_out_signature (GDBusMethodInvocation *iv)
{
  const GDBusMethodInfo *info = g_dbus_method_invocation_get_method_info (iv);
  GString *sig = g_string_new ("(");
  guint k;

  if (info != NULL && info->out_args != NULL)
    for (k = 0; info->out_args[k] != NULL; k++)
      g_string_append (sig, info->out_args[k]->signature);
  g_string_append_c (sig, ')');
  return g_string_free (sig, FALSE);
}

/* ── Entry point ─────────────────────────────────────────────────── */

gboolean
cmacs_dbus_forward (const gchar *iface, const gchar *method,
                    GVariant *params, GDBusMethodInvocation *iv)
{
  const CmacsDbusForwardRow *row = forward_find (iface, method);
  g_autofree gchar *json = NULL;
  g_autofree gchar *json_q = NULL;
  g_autofree gchar *target_q = NULL;
  g_autofree gchar *reply_q = NULL;
  g_autofree gchar *sig_q = NULL;
  g_autofree gchar *expr = NULL;
  g_autofree gchar *res = NULL;
  g_autoptr (GError) err = NULL;
  gchar *signature;
  guint token;

  if (row == NULL)
    return FALSE;

  /* From here the method is ours: every path below answers it.  */
  json = forward_build_args (row, params, &err);
  if (json == NULL)
    {
      g_dbus_method_invocation_return_dbus_error (
        iv, FORWARD_ERROR_PREFIX "BadArguments",
        err != NULL ? err->message : "the arguments could not be read");
      return TRUE;
    }

  signature = forward_out_signature (iv);
  if (!g_variant_type_string_is_valid (signature))
    {
      g_free (signature);
      g_dbus_method_invocation_return_dbus_error (
        iv, FORWARD_ERROR_PREFIX "ToolFailed",
        "the method's reply signature could not be read");
      return TRUE;
    }

  /* The table owns the invocation and the signature now.  */
  token = forward_park (iv, signature);

  json_q = cmacs_dispatch_lisp_escape (json);
  target_q = cmacs_dispatch_lisp_escape (row->target);
  reply_q = cmacs_dispatch_lisp_escape (row->reply);
  sig_q = cmacs_dispatch_lisp_escape (signature);
  expr = g_strdup_printf (
    "(progn (require 'cmacs-dbus-forward)"
    " (cmacs-dbus-forward-call %u \"%s\" \"%s\" \"%s\" \"%s\" %u))",
    token, target_q, json_q, reply_q, sig_q, row->flags);

  res = cmacs_dispatch_eval_string (expr, &err);

  /* The Lisp side answers through `cmacs-dbus-forward--reply', and
     reports its own failures the same way.  An error HERE means it
     never got that far: the file would not load, or something
     signalled outside its handlers.  Answer for it; if it did answer
     first, this finds nothing to do.  */
  if (res == NULL)
    forward_reply (token, "ToolFailed",
                   err != NULL ? err->message : "the call could not be made");
  return TRUE;
}

void
cmacs_dbus_forward_stop (void)
{
  guint n = 0;
  guint k;
  gpointer *keys;

  if (forward_pending == NULL)
    return;

  /* The service is going away with calls still parked.  Their tools
     may yet finish, and will then find their token gone; the callers
     are told now rather than left to time out.  Collect first: a reply
     removes its entry, and the table must not change under its own
     iterator.  */
  keys = g_hash_table_get_keys_as_array (forward_pending, &n);
  for (k = 0; k < n; k++)
    forward_reply (GPOINTER_TO_UINT (keys[k]), "ServiceStopped",
                   "the cmacs D-Bus service stopped before the call "
                   "finished");
  g_free (keys);
}

/* ── DEFUNs ──────────────────────────────────────────────────────── */

DEFUN ("cmacs-dbus-forward--reply", Fcmacs_dbus_forward__reply,
       Scmacs_dbus_forward__reply, 3, 3, 0,
       doc: /* Answer the legacy D-Bus method invocation parked under TOKEN.

KIND nil sends TEXT as the method's result: verbatim when the method
replies with one string, and otherwise parsed as GVariant text for the
method's declared reply tuple (so "(true,)" for a boolean reply).  KIND
a string sends the D-Bus error org.cmacs.Editor1.Error.KIND with TEXT
as its message; a KIND that cannot be part of an error name is sent as
ToolFailed.

Returns t when this call answered the invocation and nil when TOKEN was
already answered or never issued.  An invocation is answered at most
once.

Internal: `cmacs-dbus-forward-call' is the caller.  */)
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

  /* Valid UTF-8, or the reply is rejected on its way out and the
     caller waits for nothing: a result can hold raw bytes.  */
  if (!NILP (kind))
    ckind = cmacs_dispatch_string_to_utf8 (kind);
  ctext = cmacs_dispatch_string_to_utf8 (text);

  return forward_reply ((guint) XFIXNAT (token), ckind, ctext) ? Qt : Qnil;
}

DEFUN ("cmacs-dbus-forward--pending", Fcmacs_dbus_forward__pending,
       Scmacs_dbus_forward__pending, 0, 0, 0,
       doc: /* Return how many forwarded D-Bus invocations await an answer.
Non-zero while an :async tool reached through a legacy method is still
running.  */)
  (void)
{
  return make_fixnum (forward_pending != NULL
                      ? g_hash_table_size (forward_pending) : 0);
}

DEFUN ("cmacs-dbus-forward--rows", Fcmacs_dbus_forward__rows,
       Scmacs_dbus_forward__rows, 0, 0, 0,
       doc: /* Return the D-Bus forwarding table this binary was built with.
A list of (INTERFACE METHOD TARGET ARGUMENT-MAP REPLY FLAGS), one per
legacy method served from the capability table, in the table's order.
INTERFACE is the part after "org.cmacs.Editor1."; FLAGS is an integer
\(1 legacy reach, 2 approve).  For tests and for `describe'-style
tooling: nothing dispatches on it.  */)
  (void)
{
  Lisp_Object rows = Qnil;
  gsize k;

  for (k = G_N_ELEMENTS (forward_rows); k-- > 0; )
    rows = Fcons (list (build_string (forward_rows[k].iface),
                        build_string (forward_rows[k].method),
                        build_string (forward_rows[k].target),
                        build_string (forward_rows[k].args),
                        build_string (forward_rows[k].reply),
                        make_fixnum (forward_rows[k].flags)),
                  rows);
  return rows;
}

void
syms_of_cmacs_dbus_forward (void)
{
  defsubr (&Scmacs_dbus_forward__reply);
  defsubr (&Scmacs_dbus_forward__pending);
  defsubr (&Scmacs_dbus_forward__rows);
}

#endif /* HAVE_CMACS_GLIB */
