/* cmacs-libreclaw-hatch.c — DEFUNs wrapping libreclaw's lc_hatch_* API
 *
 * Copyright (C) 2026 Zach Podbielniak
 * SPDX-License-Identifier: AGPL-3.0-or-later
 *
 * Exposes libreclaw 0.18.0's hatch library API to Elisp so the
 * `cmacs-libreclaw-hatch' wizard (defined in
 * lisp/cmacs/cmacs-libreclaw-hatch.el) can drive workspace
 * scaffolding from inside an org buffer.
 *
 * Handle lifetime: each `cmacs-libreclaw-hatch-new' call returns an
 * opaque integer handle keyed into a GHashTable of LcHatchContext*.
 * The context stays alive until `cmacs-libreclaw-hatch-free' is
 * called; a `kill-buffer-hook' in the Elisp layer ensures contexts
 * are released when the wizard buffer is killed.
 *
 * We use integer handles (not Lisp_Object GObject wrappers) to
 * sidestep GC safety concerns — no Lisp_Object is held in C-owned
 * memory for the duration of the wizard session. */

#include <config.h>

#ifdef HAVE_CMACS_LIBRECLAW

#include <libreclaw.h>
#include <glib.h>

#include "lisp.h"
#include "cmacs-libreclaw.h"

static GHashTable *g_hatch_contexts = NULL;   /* guint → LcHatchContext* */
static guint       g_hatch_next_id  = 1;

static LcHatchContext *
handle_lookup (Lisp_Object handle)
{
  EMACS_INT id;
  gpointer v;

  CHECK_FIXNUM (handle);
  id = XFIXNUM (handle);
  if (g_hatch_contexts == NULL)
    return NULL;

  v = g_hash_table_lookup (g_hatch_contexts, GUINT_TO_POINTER ((guint)id));
  return v != NULL ? (LcHatchContext *) v : NULL;
}

static LcHatchContext *
handle_require (Lisp_Object handle)
{
  LcHatchContext *ctx = handle_lookup (handle);
  if (ctx == NULL)
    xsignal1 (Qcmacs_libreclaw_error,
              build_string ("Invalid or freed hatch handle"));
  return ctx;
}

static void
check_ok_or_signal (gboolean ok, GError *error, const char *prefix)
{
  if (!ok)
    {
      Lisp_Object msg;
      g_autofree gchar *combined = NULL;
      if (error != NULL)
        combined = g_strdup_printf ("%s: %s", prefix, error->message);
      else
        combined = g_strdup_printf ("%s: unknown error", prefix);
      msg = build_string (combined);
      if (error != NULL)
        g_error_free (error);
      xsignal1 (Qcmacs_libreclaw_error, msg);
    }
}

/* ── Context lifecycle ─────────────────────────────────────────────── */

DEFUN ("cmacs-libreclaw-hatch-new", Fcmacs_libreclaw_hatch_new,
       Scmacs_libreclaw_hatch_new, 1, 1, 0,
       doc: /* Create a new hatch context in WORKSPACE-DIR.
Returns an integer handle to be passed to the other
`cmacs-libreclaw-hatch-*' functions.  Release via
`cmacs-libreclaw-hatch-free' when the wizard buffer is closed.  */)
  (Lisp_Object workspace_dir)
{
  LcHatchContext *ctx;
  guint id;

  CHECK_STRING (workspace_dir);

  if (g_hatch_contexts == NULL)
    g_hatch_contexts =
      g_hash_table_new_full (g_direct_hash, g_direct_equal,
                             NULL, (GDestroyNotify) g_object_unref);

  ctx = lc_hatch_context_new (SSDATA (workspace_dir));
  if (ctx == NULL)
    xsignal1 (Qcmacs_libreclaw_error,
              build_string ("lc_hatch_context_new returned NULL"));

  id = g_hatch_next_id++;
  g_hash_table_insert (g_hatch_contexts, GUINT_TO_POINTER (id), ctx);
  return make_fixnum ((EMACS_INT) id);
}

DEFUN ("cmacs-libreclaw-hatch-free", Fcmacs_libreclaw_hatch_free,
       Scmacs_libreclaw_hatch_free, 1, 1, 0,
       doc: /* Release the hatch context identified by HANDLE.  */)
  (Lisp_Object handle)
{
  EMACS_INT id;

  CHECK_FIXNUM (handle);
  id = XFIXNUM (handle);
  if (g_hatch_contexts != NULL)
    g_hash_table_remove (g_hatch_contexts, GUINT_TO_POINTER ((guint)id));
  return Qt;
}

/* ── Configurators ─────────────────────────────────────────────────── */

DEFUN ("cmacs-libreclaw-hatch-set-name", Fcmacs_libreclaw_hatch_set_name,
       Scmacs_libreclaw_hatch_set_name, 2, 2, 0,
       doc: /* Set the workspace NAME for HANDLE.  */)
  (Lisp_Object handle, Lisp_Object name)
{
  LcHatchContext *ctx = handle_require (handle);
  GError *error = NULL;

  CHECK_STRING (name);
  check_ok_or_signal (lc_hatch_set_workspace_name (ctx, SSDATA (name), &error),
                      error, "hatch set-name");
  return Qt;
}

DEFUN ("cmacs-libreclaw-hatch-set-identity",
       Fcmacs_libreclaw_hatch_set_identity,
       Scmacs_libreclaw_hatch_set_identity, 2, 2, 0,
       doc: /* Set the SOUL.md identity file PATH for HANDLE.  */)
  (Lisp_Object handle, Lisp_Object path)
{
  LcHatchContext *ctx = handle_require (handle);
  GError *error = NULL;

  CHECK_STRING (path);
  check_ok_or_signal (lc_hatch_set_identity (ctx, SSDATA (path), &error),
                      error, "hatch set-identity");
  return Qt;
}

DEFUN ("cmacs-libreclaw-hatch-set-ai", Fcmacs_libreclaw_hatch_set_ai,
       Scmacs_libreclaw_hatch_set_ai, 2, 2, 0,
       doc: /* Set the AI provider KIND for HANDLE.
KIND is one of the symbols `claude', `openai', or `both'.  */)
  (Lisp_Object handle, Lisp_Object kind)
{
  LcHatchContext *ctx = handle_require (handle);
  GError *error = NULL;
  LcHatchAiKind c_kind;

  if (EQ (kind, intern ("claude")))
    c_kind = LC_HATCH_AI_CLAUDE;
  else if (EQ (kind, intern ("openai")))
    c_kind = LC_HATCH_AI_OPENAI;
  else if (EQ (kind, intern ("both")))
    c_kind = LC_HATCH_AI_BOTH;
  else
    xsignal1 (Qcmacs_libreclaw_error,
              build_string ("AI kind must be 'claude, 'openai, or 'both"));

  check_ok_or_signal (lc_hatch_set_ai_provider (ctx, c_kind, &error),
                      error, "hatch set-ai");
  return Qt;
}

DEFUN ("cmacs-libreclaw-hatch-add-matrix",
       Fcmacs_libreclaw_hatch_add_matrix,
       Scmacs_libreclaw_hatch_add_matrix, 4, 4, 0,
       doc: /* Add a matrix channel to HANDLE.
HOMESERVER is a URL, USER-ID is @user:server, TOKEN is the matrix
access token (use auth-source indirection rather than plaintext).  */)
  (Lisp_Object handle, Lisp_Object homeserver, Lisp_Object user_id,
   Lisp_Object token)
{
  LcHatchContext *ctx = handle_require (handle);
  GError *error = NULL;

  CHECK_STRING (homeserver);
  CHECK_STRING (user_id);
  CHECK_STRING (token);

  check_ok_or_signal (
      lc_hatch_add_matrix_channel (ctx, SSDATA (homeserver),
                                   SSDATA (user_id), SSDATA (token),
                                   &error),
      error, "hatch add-matrix");
  return Qt;
}

DEFUN ("cmacs-libreclaw-hatch-add-local",
       Fcmacs_libreclaw_hatch_add_local,
       Scmacs_libreclaw_hatch_add_local, 1, 2, 0,
       doc: /* Add a local (stdin/stdout) channel to HANDLE.
Optional PROMPT overrides the default prompt string.

NOTE: the local channel reads from fd 0 and writes to fd 1 — it
is useful for a CLI libreclaw binary but not for the embedded
cmacs integration.  For in-Emacs chat buffers use
`cmacs-libreclaw-hatch-add-cmacs' instead.  */)
  (Lisp_Object handle, Lisp_Object prompt)
{
  LcHatchContext *ctx = handle_require (handle);
  GError *error = NULL;
  const char *p = NULL;

  if (!NILP (prompt))
    {
      CHECK_STRING (prompt);
      p = SSDATA (prompt);
    }
  check_ok_or_signal (lc_hatch_add_local_channel (ctx, p, &error),
                      error, "hatch add-local");
  return Qt;
}

DEFUN ("cmacs-libreclaw-hatch-add-cmacs",
       Fcmacs_libreclaw_hatch_add_cmacs,
       Scmacs_libreclaw_hatch_add_cmacs, 1, 1, 0,
       doc: /* Add a cmacs (in-process Emacs-native) channel to HANDLE.
No credentials or parameters required.  The resulting YAML
contains only `channels.cmacs.enabled: true' — all room state is
driven dynamically by the Emacs host at runtime.  This is the
recommended channel for workspaces running inside cmacs.  */)
  (Lisp_Object handle)
{
  LcHatchContext *ctx = handle_require (handle);
  GError *error = NULL;

  check_ok_or_signal (lc_hatch_add_cmacs_channel (ctx, &error),
                      error, "hatch add-cmacs");
  return Qt;
}

DEFUN ("cmacs-libreclaw-hatch-add-email",
       Fcmacs_libreclaw_hatch_add_email,
       Scmacs_libreclaw_hatch_add_email, 5, 5, 0,
       doc: /* Add an email channel to HANDLE.
IMAP-HOST, SMTP-HOST, USERNAME, PASSWORD are strings.  */)
  (Lisp_Object handle, Lisp_Object imap_host, Lisp_Object smtp_host,
   Lisp_Object username, Lisp_Object password)
{
  LcHatchContext *ctx = handle_require (handle);
  GError *error = NULL;

  CHECK_STRING (imap_host);
  CHECK_STRING (smtp_host);
  CHECK_STRING (username);
  CHECK_STRING (password);

  check_ok_or_signal (
      lc_hatch_add_email_channel (ctx, SSDATA (imap_host),
                                  SSDATA (smtp_host),
                                  SSDATA (username),
                                  SSDATA (password), &error),
      error, "hatch add-email");
  return Qt;
}

DEFUN ("cmacs-libreclaw-hatch-add-webhook",
       Fcmacs_libreclaw_hatch_add_webhook,
       Scmacs_libreclaw_hatch_add_webhook, 3, 3, 0,
       doc: /* Add a webhook channel to HANDLE listening on PORT at PATH-PREFIX.  */)
  (Lisp_Object handle, Lisp_Object port, Lisp_Object path_prefix)
{
  LcHatchContext *ctx = handle_require (handle);
  GError *error = NULL;

  CHECK_FIXNUM (port);
  CHECK_STRING (path_prefix);

  check_ok_or_signal (
      lc_hatch_add_webhook_channel (ctx, (guint) XFIXNUM (port),
                                    SSDATA (path_prefix), &error),
      error, "hatch add-webhook");
  return Qt;
}

DEFUN ("cmacs-libreclaw-hatch-enable-podomation",
       Fcmacs_libreclaw_hatch_enable_podomation,
       Scmacs_libreclaw_hatch_enable_podomation, 1, 2, 0,
       doc: /* Enable podomation for HANDLE, optionally with inline DSL.  */)
  (Lisp_Object handle, Lisp_Object dsl)
{
  LcHatchContext *ctx = handle_require (handle);
  GError *error = NULL;
  const char *d = NULL;

  if (!NILP (dsl))
    {
      CHECK_STRING (dsl);
      d = SSDATA (dsl);
    }
  check_ok_or_signal (lc_hatch_enable_podomation (ctx, d, &error),
                      error, "hatch enable-podomation");
  return Qt;
}

DEFUN ("cmacs-libreclaw-hatch-enable-audit",
       Fcmacs_libreclaw_hatch_enable_audit,
       Scmacs_libreclaw_hatch_enable_audit, 1, 2, 0,
       doc: /* Enable audit logging for HANDLE, optionally at DB-PATH.  */)
  (Lisp_Object handle, Lisp_Object db_path)
{
  LcHatchContext *ctx = handle_require (handle);
  GError *error = NULL;
  const char *p = NULL;

  if (!NILP (db_path))
    {
      CHECK_STRING (db_path);
      p = SSDATA (db_path);
    }
  check_ok_or_signal (lc_hatch_enable_audit_log (ctx, p, &error),
                      error, "hatch enable-audit");
  return Qt;
}

DEFUN ("cmacs-libreclaw-hatch-include-emacs-preamble",
       Fcmacs_libreclaw_hatch_include_emacs_preamble,
       Scmacs_libreclaw_hatch_include_emacs_preamble, 1, 1, 0,
       doc: /* Tell HANDLE to include the cmacs/Emacs channel preamble.

On finalize, writes `CMACS_EMACS_CHANNEL.md' into the workspace
and adds it to `agent.identity_files' in the generated YAML.
Libreclaw loads that file as part of the agent context so the AI
session sees the preamble as part of its system prompt from turn
one — the preamble tells the AI its responses are rendered in an
Emacs org-mode buffer and instructs it to start headings at `***'
so they don't collide with the buffer's own `*' / `**' layout.

Additive with `cmacs-libreclaw-hatch-set-identity'; if both are
called, both files appear in `agent.identity_files'.  */)
  (Lisp_Object handle)
{
  LcHatchContext *ctx = handle_require (handle);
  GError *error = NULL;

  check_ok_or_signal (lc_hatch_include_emacs_preamble (ctx, &error),
                      error, "hatch include-emacs-preamble");
  return Qt;
}

/* ── Preview / finalize ────────────────────────────────────────────── */

DEFUN ("cmacs-libreclaw-hatch-preview", Fcmacs_libreclaw_hatch_preview,
       Scmacs_libreclaw_hatch_preview, 1, 1, 0,
       doc: /* Return the YAML that finalize would write, as a string.  */)
  (Lisp_Object handle)
{
  LcHatchContext *ctx = handle_require (handle);
  GError *error = NULL;
  g_autofree gchar *yaml = NULL;
  Lisp_Object result;

  yaml = lc_hatch_preview (ctx, &error);
  if (yaml == NULL)
    check_ok_or_signal (FALSE, error, "hatch preview");

  result = build_string (yaml);
  return result;
}

DEFUN ("cmacs-libreclaw-hatch-finalize",
       Fcmacs_libreclaw_hatch_finalize,
       Scmacs_libreclaw_hatch_finalize, 1, 2, 0,
       doc: /* Write the workspace to disk.
With non-nil OVERWRITE, replace an existing config.yaml.
Returns the path of the written config.yaml.  */)
  (Lisp_Object handle, Lisp_Object overwrite)
{
  LcHatchContext *ctx = handle_require (handle);
  GError *error = NULL;
  g_autofree gchar *path = NULL;

  check_ok_or_signal (
      lc_hatch_finalize (ctx, NILP (overwrite) ? FALSE : TRUE, &error),
      error, "hatch finalize");

  path = lc_hatch_context_get_config_path (ctx);
  if (path == NULL)
    return Qnil;
  return build_string (path);
}

/* ── Init ──────────────────────────────────────────────────────────── */

void
syms_of_cmacs_libreclaw_hatch (void)
{
  defsubr (&Scmacs_libreclaw_hatch_new);
  defsubr (&Scmacs_libreclaw_hatch_free);
  defsubr (&Scmacs_libreclaw_hatch_set_name);
  defsubr (&Scmacs_libreclaw_hatch_set_identity);
  defsubr (&Scmacs_libreclaw_hatch_set_ai);
  defsubr (&Scmacs_libreclaw_hatch_add_matrix);
  defsubr (&Scmacs_libreclaw_hatch_add_local);
  defsubr (&Scmacs_libreclaw_hatch_add_cmacs);
  defsubr (&Scmacs_libreclaw_hatch_add_email);
  defsubr (&Scmacs_libreclaw_hatch_add_webhook);
  defsubr (&Scmacs_libreclaw_hatch_enable_podomation);
  defsubr (&Scmacs_libreclaw_hatch_enable_audit);
  defsubr (&Scmacs_libreclaw_hatch_include_emacs_preamble);
  defsubr (&Scmacs_libreclaw_hatch_preview);
  defsubr (&Scmacs_libreclaw_hatch_finalize);
}

#endif /* HAVE_CMACS_LIBRECLAW */
