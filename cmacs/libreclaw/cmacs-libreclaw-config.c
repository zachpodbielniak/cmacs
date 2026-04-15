/* cmacs-libreclaw-config.c — YAML config validation & preview DEFUNs
 *
 * Copyright (C) 2026 Zach Podbielniak
 * SPDX-License-Identifier: AGPL-3.0-or-later
 *
 * Thin wrappers around libreclaw's LcConfig for the "preview without
 * starting" flow.  Actual YAML parsing is delegated to libreclaw so
 * we inherit every schema change for free.  These DEFUNs let the
 * hatch wizard and `cmacs-libreclaw-config-validate' preflight a
 * file before handing it to lc_app_new_embedded().
 *
 * The primary config DEFUNs (set-config-file, reload-config) live
 * in cmacs-libreclaw.c alongside the lifecycle code. */

#include <config.h>

#ifdef HAVE_CMACS_LIBRECLAW

#include <libreclaw.h>

#include "lisp.h"
#include "cmacs-libreclaw.h"

DEFUN ("cmacs-libreclaw-config-validate",
       Fcmacs_libreclaw_config_validate,
       Scmacs_libreclaw_config_validate, 1, 1, 0,
       doc: /* Parse FILE and return t if valid.
Signals `cmacs-libreclaw-error' with a descriptive message (and
a `:line' keyword in the error data when available) if invalid.
Does NOT start an LcApp — this is a pure validation pass suitable
for running in the hatch wizard before finalize.  */)
  (Lisp_Object file)
{
  LcConfig *cfg;
  GError   *error = NULL;

  CHECK_STRING (file);

  cfg = lc_config_new ();
  if (cfg == NULL)
    xsignal1 (Qcmacs_libreclaw_error,
              build_string ("lc_config_new returned NULL"));

  if (!lc_config_load_from_path (cfg, SSDATA (file), &error))
    {
      Lisp_Object msg = build_string (error ? error->message
                                             : "config validation failed");
      if (error)
        g_error_free (error);
      g_object_unref (cfg);
      xsignal1 (Qcmacs_libreclaw_error, msg);
    }

  g_object_unref (cfg);
  return Qt;
}

DEFUN ("cmacs-libreclaw-config-preview",
       Fcmacs_libreclaw_config_preview,
       Scmacs_libreclaw_config_preview, 1, 1, 0,
       doc: /* Parse FILE and return a plist summarising its contents.
The plist has keys :agent-name, :workspace, :channels, :providers,
:podomation-enabled.  Useful for showing "what would load if I
called (cmacs-libreclaw-start)" before actually starting.  */)
  (Lisp_Object file)
{
  LcConfig *cfg;
  GError   *error = NULL;
  Lisp_Object plist = Qnil;
  const char *agent_name;
  const char *workspace;
  gboolean pod_enabled;

  CHECK_STRING (file);

  cfg = lc_config_new ();
  if (!lc_config_load_from_path (cfg, SSDATA (file), &error))
    {
      Lisp_Object msg = build_string (error ? error->message : "load failed");
      if (error)
        g_error_free (error);
      g_object_unref (cfg);
      xsignal1 (Qcmacs_libreclaw_error, msg);
    }

  agent_name = lc_config_get_agent_name (cfg);
  workspace  = lc_config_get_agent_workspace (cfg);
  pod_enabled = lc_config_get_podomation_enabled (cfg);

  plist = Fcons (intern (":podomation-enabled"),
                 Fcons (pod_enabled ? Qt : Qnil, plist));
  plist = Fcons (intern (":workspace"),
                 Fcons (workspace ? build_string (workspace) : Qnil, plist));
  plist = Fcons (intern (":agent-name"),
                 Fcons (agent_name ? build_string (agent_name) : Qnil, plist));

  g_object_unref (cfg);
  return plist;
}

void
syms_of_cmacs_libreclaw_config (void)
{
  defsubr (&Scmacs_libreclaw_config_validate);
  defsubr (&Scmacs_libreclaw_config_preview);
}

#endif /* HAVE_CMACS_LIBRECLAW */
