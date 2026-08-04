/* cmacs-ai-client.c --- AiClient handle registry + lifecycle DEFUNs.
 *
 * Copyright (C) 2026 Zach Podbielniak
 * SPDX-License-Identifier: AGPL-3.0-or-later
 *
 * Provider clients (AiClaudeClient, AiOpenAIClient, ...) are opaque
 * GObjects.  Rather than wrap each in a new Lisp type, we expose them
 * via integer handles keyed into a GHashTable that holds the only ref
 * to each instance.  Elisp code creates a handle with
 * (cmacs-ai-client-new 'claude), passes it to higher-level DEFUNs,
 * and frees it explicitly or via kill-buffer-hook.
 *
 * The handle space is monotonic guint64 to avoid ABA on reuse.  We
 * deliberately do NOT hold Lisp_Objects on the C side: there is no
 * GC root for them, and Emacs may reclaim closures stored in C heap
 * mid-async-call. */

#include <config.h>

#ifdef HAVE_CMACS_AI

#include "lisp.h"
#include "coding.h"   /* ENCODE_FILE for the MCP config path */
#include "cmacs-ai.h"

#include <ai-glib.h>
#include <glib.h>

/* ── Registry ───────────────────────────────────────────────────── */

static GHashTable *cmacs_ai__clients = NULL;   /* guint -> GObject */
static guint       cmacs_ai__next_handle = 1;
static GMutex      cmacs_ai__client_mutex;

void
cmacs_ai_client_registry_init (void)
{
  static gboolean done = FALSE;
  if (done) return;
  done = TRUE;
  g_mutex_init (&cmacs_ai__client_mutex);
  cmacs_ai__clients = g_hash_table_new_full (g_direct_hash, g_direct_equal,
                                             NULL, g_object_unref);
}

guint
cmacs_ai_client_register (gpointer client_gobject)
{
  g_return_val_if_fail (G_IS_OBJECT (client_gobject), 0);
  g_mutex_lock (&cmacs_ai__client_mutex);
  guint h = cmacs_ai__next_handle++;
  /* Take a ref so the registry holds the only strong ref. */
  g_hash_table_insert (cmacs_ai__clients,
                       GUINT_TO_POINTER (h),
                       g_object_ref (client_gobject));
  g_mutex_unlock (&cmacs_ai__client_mutex);
  return h;
}

gpointer
cmacs_ai_client_lookup (guint handle)
{
  g_mutex_lock (&cmacs_ai__client_mutex);
  gpointer p = g_hash_table_lookup (cmacs_ai__clients,
                                    GUINT_TO_POINTER (handle));
  g_mutex_unlock (&cmacs_ai__client_mutex);
  return p;
}

void
cmacs_ai_client_unregister (guint handle)
{
  g_mutex_lock (&cmacs_ai__client_mutex);
  g_hash_table_remove (cmacs_ai__clients, GUINT_TO_POINTER (handle));
  g_mutex_unlock (&cmacs_ai__client_mutex);
}

/* ── Provider construction ──────────────────────────────────────── */

static AiProvider *
cmacs_ai__make_client (Lisp_Object provider_sym)
{
  if (EQ (provider_sym, intern ("claude")))
    return AI_PROVIDER (ai_claude_client_new ());
  if (EQ (provider_sym, intern ("openai")))
    return AI_PROVIDER (ai_openai_client_new ());
  if (EQ (provider_sym, intern ("gemini")))
    return AI_PROVIDER (ai_gemini_client_new ());
  if (EQ (provider_sym, intern ("grok")))
    return AI_PROVIDER (ai_grok_client_new ());
  if (EQ (provider_sym, intern ("ollama")))
    return AI_PROVIDER (ai_ollama_client_new ());
  if (EQ (provider_sym, intern ("claude-code")))
    return AI_PROVIDER (ai_claude_code_client_new ());
  if (EQ (provider_sym, intern ("opencode")))
    return AI_PROVIDER (ai_opencode_client_new ());
  if (EQ (provider_sym, intern ("claude-tmux")))
    return AI_PROVIDER (ai_claude_tmux_client_new ());
  return NULL;
}

/* ── Type-routed setters/getters ────────────────────────────────────
 *
 * The registry holds AiProvider implementors of two unrelated GObject
 * hierarchies: AiClient (HTTP API providers) and AiCliClient
 * (claude-code / opencode / claude-tmux).  Calling ai_client_* on a
 * CLI client is a CRITICAL + silent no-op, so every property access
 * routes on the instance type. */

static void
cmacs_ai__provider_set_model (gpointer p, const gchar *model)
{
  if (AI_IS_CLIENT (p))
    ai_client_set_model (AI_CLIENT (p), model);
  else if (AI_IS_CLI_CLIENT (p))
    ai_cli_client_set_model (AI_CLI_CLIENT (p), model);
}

static const gchar *
cmacs_ai__provider_get_model (gpointer p)
{
  if (AI_IS_CLIENT (p))
    return ai_client_get_model (AI_CLIENT (p));
  if (AI_IS_CLI_CLIENT (p))
    return ai_cli_client_get_model (AI_CLI_CLIENT (p));
  return NULL;
}

static void
cmacs_ai__provider_set_system_prompt (gpointer p, const gchar *prompt)
{
  if (AI_IS_CLIENT (p))
    ai_client_set_system_prompt (AI_CLIENT (p), prompt);
  else if (AI_IS_CLI_CLIENT (p))
    ai_cli_client_set_system_prompt (AI_CLI_CLIENT (p), prompt);
}

static void
cmacs_ai__provider_set_max_tokens (gpointer p, gint max)
{
  if (AI_IS_CLIENT (p))
    ai_client_set_max_tokens (AI_CLIENT (p), max);
  else if (AI_IS_CLI_CLIENT (p))
    ai_cli_client_set_max_tokens (AI_CLI_CLIENT (p), max);
}

/* ── DEFUNs ─────────────────────────────────────────────────────── */

DEFUN ("cmacs-ai-client-new", Fcmacs_ai_client_new,
       Scmacs_ai_client_new, 1, 2, 0,
       doc: /* Create an ai-glib client for PROVIDER.
PROVIDER is one of the symbols: claude, openai, gemini, grok, ollama,
claude-code, opencode, claude-tmux.  Optional MODEL is a string (passed
to `ai-client-set-model').  Returns an integer handle.  Free with
`cmacs-ai-client-free'.  */)
  (Lisp_Object provider, Lisp_Object model)
{
  CHECK_SYMBOL (provider);
  AiProvider *p = cmacs_ai__make_client (provider);
  if (p == NULL)
    error ("cmacs-ai: unknown provider %s", SSDATA (SYMBOL_NAME (provider)));
  if (!NILP (model))
    {
      CHECK_STRING (model);
      cmacs_ai__provider_set_model (p, SSDATA (model));
    }
  guint h = cmacs_ai_client_register (p);
  g_object_unref (p);   /* registry holds the only ref now */
  return make_uint (h);
}

DEFUN ("cmacs-ai-client-free", Fcmacs_ai_client_free,
       Scmacs_ai_client_free, 1, 1, 0,
       doc: /* Free client HANDLE.  No-op if HANDLE is unknown.  */)
  (Lisp_Object handle)
{
  CHECK_FIXNAT (handle);
  cmacs_ai_client_unregister (XFIXNUM (handle));
  return Qt;
}

DEFUN ("cmacs-ai-client-set-model", Fcmacs_ai_client_set_model,
       Scmacs_ai_client_set_model, 2, 2, 0,
       doc: /* Set MODEL on client HANDLE.  */)
  (Lisp_Object handle, Lisp_Object model)
{
  CHECK_FIXNAT (handle);
  CHECK_STRING (model);
  gpointer c = cmacs_ai_client_lookup (XFIXNUM (handle));
  if (c == NULL) error ("cmacs-ai: bad client handle");
  cmacs_ai__provider_set_model (c, SSDATA (model));
  return Qt;
}

DEFUN ("cmacs-ai-client-get-model", Fcmacs_ai_client_get_model,
       Scmacs_ai_client_get_model, 1, 1, 0,
       doc: /* Return MODEL string for client HANDLE, or nil if unset.  */)
  (Lisp_Object handle)
{
  CHECK_FIXNAT (handle);
  gpointer c = cmacs_ai_client_lookup (XFIXNUM (handle));
  if (c == NULL) error ("cmacs-ai: bad client handle");
  const gchar *m = cmacs_ai__provider_get_model (c);
  return m ? build_string (m) : Qnil;
}

DEFUN ("cmacs-ai-client-effective-model",
       Fcmacs_ai_client_effective_model,
       Scmacs_ai_client_effective_model, 1, 1, 0,
       doc: /* Return the model the client will actually use.
If a model was explicitly set via `cmacs-ai-client-set-model', returns
that.  Otherwise returns the provider's compiled-in default (from
`ai_provider_get_default_model').  Returns nil only if neither is
available.  */)
  (Lisp_Object handle)
{
  CHECK_FIXNAT (handle);
  gpointer c = cmacs_ai_client_lookup (XFIXNUM (handle));
  if (c == NULL) error ("cmacs-ai: bad client handle");
  const gchar *m = cmacs_ai__provider_get_model (c);
  if (m == NULL || *m == '\0')
    m = ai_provider_get_default_model (AI_PROVIDER (c));
  return (m && *m) ? build_string (m) : Qnil;
}

DEFUN ("cmacs-ai-client-provider-name",
       Fcmacs_ai_client_provider_name,
       Scmacs_ai_client_provider_name, 1, 1, 0,
       doc: /* Return the provider display name for client HANDLE
(e.g. \"Claude\", \"OpenAI\", \"Ollama\") -- the string ai-glib
itself uses, not the Elisp symbol.  */)
  (Lisp_Object handle)
{
  CHECK_FIXNAT (handle);
  gpointer c = cmacs_ai_client_lookup (XFIXNUM (handle));
  if (c == NULL) error ("cmacs-ai: bad client handle");
  const gchar *n = ai_provider_get_name (AI_PROVIDER (c));
  return n ? build_string (n) : Qnil;
}

DEFUN ("cmacs-ai-client-set-system-prompt", Fcmacs_ai_client_set_system_prompt,
       Scmacs_ai_client_set_system_prompt, 2, 2, 0,
       doc: /* Set SYSTEM-PROMPT on client HANDLE.
A nil PROMPT clears any previously-set prompt.  */)
  (Lisp_Object handle, Lisp_Object prompt)
{
  CHECK_FIXNAT (handle);
  gpointer c = cmacs_ai_client_lookup (XFIXNUM (handle));
  if (c == NULL) error ("cmacs-ai: bad client handle");
  if (NILP (prompt))
    cmacs_ai__provider_set_system_prompt (c, NULL);
  else
    {
      CHECK_STRING (prompt);
      cmacs_ai__provider_set_system_prompt (c, SSDATA (prompt));
    }
  return Qt;
}

DEFUN ("cmacs-ai-client-set-max-tokens", Fcmacs_ai_client_set_max_tokens,
       Scmacs_ai_client_set_max_tokens, 2, 2, 0,
       doc: /* Set max output tokens on client HANDLE.  */)
  (Lisp_Object handle, Lisp_Object max)
{
  CHECK_FIXNAT (handle);
  CHECK_FIXNAT (max);
  gpointer c = cmacs_ai_client_lookup (XFIXNUM (handle));
  if (c == NULL) error ("cmacs-ai: bad client handle");
  cmacs_ai__provider_set_max_tokens (c, XFIXNUM (max));
  return Qt;
}

DEFUN ("cmacs-ai-client-set-temperature", Fcmacs_ai_client_set_temperature,
       Scmacs_ai_client_set_temperature, 2, 2, 0,
       doc: /* Set sampling TEMPERATURE on client HANDLE (float).  */)
  (Lisp_Object handle, Lisp_Object temp)
{
  CHECK_FIXNAT (handle);
  CHECK_NUMBER (temp);
  gpointer c = cmacs_ai_client_lookup (XFIXNUM (handle));
  if (c == NULL) error ("cmacs-ai: bad client handle");
  /* CLI providers have no sampling temperature; quietly skip. */
  if (AI_IS_CLIENT (c))
    ai_client_set_temperature (AI_CLIENT (c), XFLOATINT (temp));
  return Qt;
}

DEFUN ("cmacs-ai-client-list", Fcmacs_ai_client_list,
       Scmacs_ai_client_list, 0, 0, 0,
       doc: /* Return alist ((HANDLE . PROVIDER-NAME) ...) of live clients.  */)
  (void)
{
  Lisp_Object out = Qnil;
  g_mutex_lock (&cmacs_ai__client_mutex);
  GHashTableIter it;
  gpointer key, value;
  g_hash_table_iter_init (&it, cmacs_ai__clients);
  while (g_hash_table_iter_next (&it, &key, &value))
    {
      guint h = GPOINTER_TO_UINT (key);
      const gchar *name = ai_provider_get_name (AI_PROVIDER (value));
      out = Fcons (Fcons (make_uint (h),
                          build_string (name ? name : "?")), out);
    }
  g_mutex_unlock (&cmacs_ai__client_mutex);
  return out;
}

DEFUN ("cmacs-ai-client-cli-p", Fcmacs_ai_client_cli_p,
       Scmacs_ai_client_cli_p, 1, 1, 0,
       doc: /* Return t when HANDLE drives a command-line agent.

The CLI providers (claude-code, opencode, claude-tmux) are a different
GObject hierarchy from the HTTP ones, and they ignore the tools argument
entirely -- ai-glib discards it.  A caller that wants the model to have
tools must therefore hand a CLI provider an MCP config instead of
registering them on an executor, and this is how it finds out which case
it is in.  */)
  (Lisp_Object handle)
{
  CHECK_FIXNAT (handle);
  gpointer p = cmacs_ai_client_lookup (XFIXNUM (handle));
  if (p == NULL) error ("cmacs-ai: bad client handle");
  return AI_IS_CLI_CLIENT (p) ? Qt : Qnil;
}

DEFUN ("cmacs-ai-client-set-mcp-config", Fcmacs_ai_client_set_mcp_config,
       Scmacs_ai_client_set_mcp_config, 2, 2, 0,
       doc: /* Point HANDLE's CLI agent at the MCP config file PATH.

Returns t when the provider accepts one, nil when it has no such
property -- opencode, for instance.  Setting it is how a CLI provider
gets tools at all: it is passed as --mcp-config and the agent connects to
the server described there.  */)
  (Lisp_Object handle, Lisp_Object path)
{
  CHECK_FIXNAT (handle);
  CHECK_STRING (path);
  gpointer p = cmacs_ai_client_lookup (XFIXNUM (handle));
  if (p == NULL) error ("cmacs-ai: bad client handle");
  /* Probed rather than assumed: the three CLI clients do not all carry
   * the property, and g_object_set on a missing one is a CRITICAL. */
  if (g_object_class_find_property (G_OBJECT_GET_CLASS (p),
                                    "mcp-config-path") == NULL)
    return Qnil;
  Lisp_Object enc = ENCODE_FILE (path);
  g_object_set (G_OBJECT (p), "mcp-config-path", SSDATA (enc), NULL);
  return Qt;
}

DEFUN ("cmacs-ai-client-set-working-directory",
       Fcmacs_ai_client_set_working_directory,
       Scmacs_ai_client_set_working_directory, 2, 2, 0,
       doc: /* Run HANDLE's CLI agent with DIRECTORY as its working directory.

Returns t for a CLI provider, nil for an HTTP one, which has no
subprocess to place anywhere.

This is how a command-line agent finds its project: CLAUDE.md, the
.claude directory, a project MCP config and the repository itself are all
resolved relative to where the process starts, so an agent launched in
the wrong directory is a different agent.  */)
  (Lisp_Object handle, Lisp_Object directory)
{
  CHECK_FIXNAT (handle);
  CHECK_STRING (directory);
  gpointer p = cmacs_ai_client_lookup (XFIXNUM (handle));
  if (p == NULL) error ("cmacs-ai: bad client handle");
  if (!AI_IS_CLI_CLIENT (p)) return Qnil;
  Lisp_Object enc = ENCODE_FILE (Fexpand_file_name (directory, Qnil));
  ai_cli_client_set_working_directory (AI_CLI_CLIENT (p), SSDATA (enc));
  return Qt;
}

DEFUN ("cmacs-ai-client-working-directory",
       Fcmacs_ai_client_working_directory,
       Scmacs_ai_client_working_directory, 1, 1, 0,
       doc: /* Return where HANDLE's CLI agent runs, or nil.  */)
  (Lisp_Object handle)
{
  CHECK_FIXNAT (handle);
  gpointer p = cmacs_ai_client_lookup (XFIXNUM (handle));
  if (p == NULL) error ("cmacs-ai: bad client handle");
  if (!AI_IS_CLI_CLIENT (p)) return Qnil;
  const gchar *wd = ai_cli_client_get_working_directory (AI_CLI_CLIENT (p));
  return wd ? DECODE_FILE (build_unibyte_string (wd)) : Qnil;
}

void syms_of_cmacs_ai_client_defuns (void);
void
syms_of_cmacs_ai_client_defuns (void)
{
  defsubr (&Scmacs_ai_client_new);
  defsubr (&Scmacs_ai_client_free);
  defsubr (&Scmacs_ai_client_set_model);
  defsubr (&Scmacs_ai_client_get_model);
  defsubr (&Scmacs_ai_client_effective_model);
  defsubr (&Scmacs_ai_client_provider_name);
  defsubr (&Scmacs_ai_client_set_system_prompt);
  defsubr (&Scmacs_ai_client_set_max_tokens);
  defsubr (&Scmacs_ai_client_set_temperature);
  defsubr (&Scmacs_ai_client_list);
  defsubr (&Scmacs_ai_client_cli_p);
  defsubr (&Scmacs_ai_client_set_mcp_config);
  defsubr (&Scmacs_ai_client_set_working_directory);
  defsubr (&Scmacs_ai_client_working_directory);
}

#endif /* HAVE_CMACS_AI */
