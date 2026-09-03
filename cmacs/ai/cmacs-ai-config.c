/* cmacs-ai-config.c --- AiConfig wrappers exposed to Elisp.
 *
 * Copyright (C) 2026 Zach Podbielniak
 * SPDX-License-Identifier: AGPL-3.0-or-later
 *
 * Lets Elisp set per-provider API keys, base URLs, and timeouts
 * without round-tripping through ai-glib's YAML config file (though
 * the YAML file is still honored: precedence is env vars > YAML >
 * built-in defaults, and these DEFUNs override at the top of the
 * chain by mutating the global AiConfig singleton). */

#include <config.h>

#ifdef HAVE_CMACS_AI

#include "lisp.h"
#include "cmacs-ai.h"

#include <ai-glib.h>
#include <glib.h>

static AiProviderType
cmacs_ai__provider_from_symbol (Lisp_Object sym)
{
  if (EQ (sym, intern ("claude")))       return AI_PROVIDER_CLAUDE;
  if (EQ (sym, intern ("openai")))       return AI_PROVIDER_OPENAI;
  if (EQ (sym, intern ("gemini")))       return AI_PROVIDER_GEMINI;
  if (EQ (sym, intern ("grok")))         return AI_PROVIDER_GROK;
  if (EQ (sym, intern ("ollama")))       return AI_PROVIDER_OLLAMA;
  if (EQ (sym, intern ("claude-code"))) return AI_PROVIDER_CLAUDE_CODE;
  if (EQ (sym, intern ("opencode")))    return AI_PROVIDER_OPENCODE;
  if (EQ (sym, intern ("claude-tmux")))  return AI_PROVIDER_CLAUDE_TMUX;
  /* grok-build is the agentic `grok' CLI; `grok' above is the xAI
   * HTTP API.  Two different backends, deliberately two symbols --
   * ai-glib keeps them as separate AiProviderType values for the
   * same reason (its model ids are not interchangeable).  */
  if (EQ (sym, intern ("grok-build")))   return AI_PROVIDER_GROK_BUILD;
  if (EQ (sym, intern ("antigravity")))  return AI_PROVIDER_ANTIGRAVITY;
  if (EQ (sym, intern ("cursor")))       return AI_PROVIDER_CURSOR;
  error ("cmacs-ai: unknown provider %s", SSDATA (SYMBOL_NAME (sym)));
}

DEFUN ("cmacs-ai-config-set-api-key",
       Fcmacs_ai_config_set_api_key,
       Scmacs_ai_config_set_api_key, 2, 2, 0,
       doc: /* Set API KEY for PROVIDER on the default AiConfig.  */)
  (Lisp_Object provider, Lisp_Object key)
{
  CHECK_SYMBOL (provider);
  CHECK_STRING (key);
  AiConfig *cfg = ai_config_get_default ();
  ai_config_set_api_key (cfg,
                         cmacs_ai__provider_from_symbol (provider),
                         SSDATA (key));
  return Qt;
}

DEFUN ("cmacs-ai-config-set-base-url",
       Fcmacs_ai_config_set_base_url,
       Scmacs_ai_config_set_base_url, 2, 2, 0,
       doc: /* Set BASE-URL for PROVIDER on the default AiConfig.  */)
  (Lisp_Object provider, Lisp_Object url)
{
  CHECK_SYMBOL (provider);
  CHECK_STRING (url);
  AiConfig *cfg = ai_config_get_default ();
  ai_config_set_base_url (cfg,
                          cmacs_ai__provider_from_symbol (provider),
                          SSDATA (url));
  return Qt;
}

DEFUN ("cmacs-ai-config-set-timeout",
       Fcmacs_ai_config_set_timeout,
       Scmacs_ai_config_set_timeout, 1, 1, 0,
       doc: /* Set SECONDS network timeout on the default AiConfig.  */)
  (Lisp_Object seconds)
{
  CHECK_FIXNAT (seconds);
  ai_config_set_timeout (ai_config_get_default (), XFIXNUM (seconds));
  return Qt;
}

DEFUN ("cmacs-ai-config-set-default-provider",
       Fcmacs_ai_config_set_default_provider,
       Scmacs_ai_config_set_default_provider, 1, 1, 0,
       doc: /* Set default PROVIDER (symbol) for `cmacs-ai-prompt-sync'
and `ai_simple_new'.  */)
  (Lisp_Object provider)
{
  CHECK_SYMBOL (provider);
  ai_config_set_default_provider (ai_config_get_default (),
                                  cmacs_ai__provider_from_symbol (provider));
  return Qt;
}

DEFUN ("cmacs-ai-config-set-default-model",
       Fcmacs_ai_config_set_default_model,
       Scmacs_ai_config_set_default_model, 1, 1, 0,
       doc: /* Set default MODEL (string) for `ai_simple_new'.  */)
  (Lisp_Object model)
{
  CHECK_STRING (model);
  ai_config_set_default_model (ai_config_get_default (), SSDATA (model));
  return Qt;
}

void syms_of_cmacs_ai_config_defuns (void);
void
syms_of_cmacs_ai_config_defuns (void)
{
  defsubr (&Scmacs_ai_config_set_api_key);
  defsubr (&Scmacs_ai_config_set_base_url);
  defsubr (&Scmacs_ai_config_set_timeout);
  defsubr (&Scmacs_ai_config_set_default_provider);
  defsubr (&Scmacs_ai_config_set_default_model);
}

#endif /* HAVE_CMACS_AI */
