/* cmacs-ai-defuns.c --- Top-level cmacs-ai DEFUNs.
 *
 * Copyright (C) 2026 Zach Podbielniak
 * SPDX-License-Identifier: AGPL-3.0-or-later
 *
 * Subsystem-wide entry points: supported-p, version, provider
 * enumeration.  Per-resource lifecycle (clients, sessions, tools,
 * image gen) lives in dedicated files. */

#include <config.h>

#ifdef HAVE_CMACS_AI

#include "lisp.h"
#include "cmacs-ai.h"

#include <ai-glib.h>
#include <glib.h>

DEFUN ("cmacs-ai-supported-p", Fcmacs_ai_supported_p,
       Scmacs_ai_supported_p, 0, 0, 0,
       doc: /* Return t when cmacs-ai is built into this cmacs.  */)
  (void)
{
  return Qt;
}

DEFUN ("cmacs-ai-version", Fcmacs_ai_version,
       Scmacs_ai_version, 0, 0, 0,
       doc: /* Return the ai-glib library version string.  */)
  (void)
{
  /* ai-glib's installed ai-version.h template (deps/ai-glib/src/
   * ai-version.h.in) uses @AI_GLIB_MAJOR_VERSION@ placeholders but
   * its Makefile substitutes @VERSION_*@, so the macros are never
   * populated in the installed header.  Surface the pin via the
   * symbol cmacs-ai-glib-pin instead, set from configure.  */
  return build_string ("ai-glib (pinned commit)");
}

DEFUN ("cmacs-ai-providers", Fcmacs_ai_providers,
       Scmacs_ai_providers, 0, 0, 0,
       doc: /* Return list of supported provider symbols.

The built-ins, followed by every name in
`cmacs-ai-openai-compatible-endpoints' -- a user's own OpenAI-compatible
servers are providers here in every sense, so they complete in
`cmacs-ai-chat-with-provider', in the brigade's composer, and anywhere
else this list is offered.  */)
  (void)
{
  Lisp_Object builtin = list (intern ("claude"),
                              intern ("openai"),
                              intern ("gemini"),
                              intern ("grok"),
                              intern ("ollama"),
                              intern ("openai-compatible"),
                              intern ("claude-code"),
                              intern ("opencode"),
                              intern ("claude-tmux"),
                              intern ("grok-build"),
                              intern ("antigravity"),
                              intern ("cursor"),
                              intern ("codex-cli"));
  Lisp_Object extra = Qnil, tail;
  Lisp_Object alist =
    find_symbol_value (intern ("cmacs-ai-openai-compatible-endpoints"));

  for (tail = alist; CONSP (tail); tail = XCDR (tail))
    {
      Lisp_Object entry = XCAR (tail);
      if (CONSP (entry) && SYMBOLP (XCAR (entry)) && !NILP (XCAR (entry)))
        extra = Fcons (XCAR (entry), extra);
    }
  return CALLN (Fnconc, builtin, Fnreverse (extra));
}

DEFUN ("cmacs-ai-config-default-provider",
       Fcmacs_ai_config_default_provider,
       Scmacs_ai_config_default_provider, 0, 0, 0,
       doc: /* Return the symbol of the provider configured as default
in ai-glib's AiConfig singleton (from environment + YAML).  This
reflects what `ai_simple_new' would pick, independent of the Elisp
defcustom `cmacs-ai-default-provider'.  */)
  (void)
{
  AiProviderType pt = ai_config_get_default_provider (
    ai_config_get_default ());
  const gchar *name = ai_provider_type_to_string (pt);
  return intern (name ? name : "ollama");
}

void syms_of_cmacs_ai_defuns (void);
void
syms_of_cmacs_ai_defuns (void)
{
  defsubr (&Scmacs_ai_supported_p);
  defsubr (&Scmacs_ai_version);
  defsubr (&Scmacs_ai_providers);
  defsubr (&Scmacs_ai_config_default_provider);
}

#endif /* HAVE_CMACS_AI */
