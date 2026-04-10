/* cmacs-podomation.c — Podomation automation engine integration
 *
 * Copyright (C) 2026 Zach Podbielniak
 * SPDX-License-Identifier: AGPL-3.0-or-later
 *
 * Links against libpodomation-1.0.  Provides DEFUNs for engine lifecycle,
 * DSL evaluation, pod management, REPL, and event emission.
 */

#include <config.h>

#ifdef HAVE_CMACS_PODOMATION

#include <podomation.h>
#include "lisp.h"
#include "cmacs-podomation.h"
#include "cmacs-eval-dispatch.h"
#include <gmodule.h>

/* Forward declarations for built-in PodModules. */
extern PodModule *pod_cmacs_module_new (void);
#ifdef HAVE_CMACS_GOWL
extern PodModule *pod_gowl_module_new (void);
#endif

/* ── State ─────────────────────────────────────────────────────────── */

/* The shared PodEngine, created via PodRepl so REPL and engine share
   the same module manager and pod namespace. */
static PodEngine *cmacs_pod_engine = NULL;
static PodRepl   *cmacs_pod_repl   = NULL;

/* The built-in cmacs PodModule singleton (for emit-event). */
static PodModule *cmacs_pod_cmacs_module = NULL;

PodEngine *
cmacs_podomation_get_engine (void)
{
  return cmacs_pod_engine;
}

PodModule *
cmacs_podomation_get_cmacs_module (void)
{
  return cmacs_pod_cmacs_module;
}

/* ── Helpers ───────────────────────────────────────────────────────── */

static Lisp_Object
pod_health_to_symbol (PodPodHealth h)
{
  switch (h)
    {
    case POD_POD_HEALTH_HEALTHY:    return intern ("healthy");
    case POD_POD_HEALTH_DEGRADED:   return intern ("degraded");
    case POD_POD_HEALTH_FAILED:     return intern ("failed");
    case POD_POD_HEALTH_RECOVERING: return intern ("recovering");
    default:                        return intern ("unknown");
    }
}

static Lisp_Object
repl_kind_to_symbol (PodReplResultKind k)
{
  switch (k)
    {
    case POD_REPL_RESULT_EMPTY:    return intern ("empty");
    case POD_REPL_RESULT_VALUE:    return intern ("value");
    case POD_REPL_RESULT_OUTPUT:   return intern ("output");
    case POD_REPL_RESULT_ERROR:    return intern ("error");
    case POD_REPL_RESULT_INFO:     return intern ("info");
    case POD_REPL_RESULT_QUIT:     return intern ("quit");
    case POD_REPL_RESULT_CONTINUE: return intern ("continue");
    default:                       return intern ("unknown");
    }
}

/* Convert Lisp alist ((key . val) ...) to GVariant a{sv}. */
static GVariant *
alist_to_variant (Lisp_Object alist)
{
  GVariantBuilder builder;
  Lisp_Object tail;

  g_variant_builder_init (&builder, G_VARIANT_TYPE ("a{sv}"));

  for (tail = alist; CONSP (tail); tail = XCDR (tail))
    {
      Lisp_Object pair = XCAR (tail);
      if (!CONSP (pair))
	continue;
      Lisp_Object key = XCAR (pair);
      Lisp_Object val = XCDR (pair);

      const char *k = SYMBOLP (key) ? SSDATA (SYMBOL_NAME (key))
		    : STRINGP (key) ? SSDATA (key) : NULL;
      if (k == NULL)
	continue;

      const char *v = STRINGP (val) ? SSDATA (val) : "";
      g_variant_builder_add (&builder, "{sv}", k,
			     g_variant_new_string (v));
    }

  return g_variant_ref_sink (g_variant_builder_end (&builder));
}

/* ── Lifecycle DEFUNs ──────────────────────────────────────────────── */

DEFUN ("cmacs-podomation-start", Fcmacs_podomation_start,
       Scmacs_podomation_start, 0, 0, 0,
       doc: /* Start the podomation automation engine.
Creates a PodEngine via PodRepl, loads modules from the bundled and
user-configured directories, registers the built-in cmacs and gowl
PodModules, and starts the engine in embedded mode on the CMacs
GMainContext.  */)
  (void)
{
  GError *error = NULL;
  PodModuleManager *mgr;
  const gchar *module_dir;

  if (cmacs_pod_engine != NULL)
    xsignal1 (Qcmacs_podomation_error,
	      build_string ("Podomation engine already running"));

  /* Create REPL (which owns the engine). */
  cmacs_pod_repl = pod_repl_new ();
  cmacs_pod_engine = pod_repl_get_engine (cmacs_pod_repl);

  /* Load .so modules.  Try the in-tree dev path first, then the
     installed system path.  When embedded, the dev path is the build
     tree; the installed path is $libdir/podomation/modules/. */
  module_dir = NULL;
#ifdef CMACS_PODOMATION_MODULE_DIR
  if (g_file_test (CMACS_PODOMATION_MODULE_DIR, G_FILE_TEST_IS_DIR))
    module_dir = CMACS_PODOMATION_MODULE_DIR;
#endif
#ifdef PODOMATION_MODULEDIR
  if (module_dir == NULL
      && g_file_test (PODOMATION_MODULEDIR, G_FILE_TEST_IS_DIR))
    module_dir = PODOMATION_MODULEDIR;
#endif
  if (!pod_repl_load_modules (cmacs_pod_repl, module_dir, &error))
    {
      Lisp_Object msg = build_string (error->message);
      g_error_free (error);
      cmacs_pod_engine = NULL;
      g_clear_object (&cmacs_pod_repl);
      xsignal1 (Qcmacs_podomation_error, msg);
    }

  /* Register built-in modules compiled into temacs. */
  mgr = pod_engine_get_module_manager (cmacs_pod_engine);

  cmacs_pod_cmacs_module = pod_cmacs_module_new ();
  pod_module_manager_register (mgr, cmacs_pod_cmacs_module);

#ifdef HAVE_CMACS_GOWL
  {
    PodModule *gowl_mod = pod_gowl_module_new ();
    pod_module_manager_register (mgr, gowl_mod);
  }
#endif

  /* Start the engine — attaches event sources to the GMainContext. */
  if (!pod_engine_start_embedded (cmacs_pod_engine, &error))
    {
      Lisp_Object msg = build_string (error->message);
      g_error_free (error);
      cmacs_pod_cmacs_module = NULL;
      cmacs_pod_engine = NULL;
      g_clear_object (&cmacs_pod_repl);
      xsignal1 (Qcmacs_podomation_error, msg);
    }

  return Qt;
}

DEFUN ("cmacs-podomation-stop", Fcmacs_podomation_stop,
       Scmacs_podomation_stop, 0, 0, 0,
       doc: /* Stop the podomation automation engine.  */)
  (void)
{
  if (cmacs_pod_engine == NULL)
    return Qnil;

  pod_engine_stop (cmacs_pod_engine);
  cmacs_pod_cmacs_module = NULL;
  cmacs_pod_engine = NULL;
  g_clear_object (&cmacs_pod_repl);
  return Qt;
}

DEFUN ("cmacs-podomation-running-p", Fcmacs_podomation_running_p,
       Scmacs_podomation_running_p, 0, 0, 0,
       doc: /* Return non-nil if the podomation engine is running.  */)
  (void)
{
  if (cmacs_pod_engine == NULL)
    return Qnil;
  return pod_engine_is_running (cmacs_pod_engine) ? Qt : Qnil;
}

DEFUN ("cmacs-podomation-reload", Fcmacs_podomation_reload,
       Scmacs_podomation_reload, 0, 0, 0,
       doc: /* Hot-reload the podomation engine configuration.  */)
  (void)
{
  GError *error = NULL;

  if (cmacs_pod_engine == NULL)
    xsignal1 (Qcmacs_podomation_error,
	      build_string ("Podomation engine not running"));

  if (!pod_engine_reload_config (cmacs_pod_engine, &error))
    {
      Lisp_Object msg = build_string (error->message);
      g_error_free (error);
      xsignal1 (Qcmacs_podomation_error, msg);
    }
  return Qt;
}

/* ── DSL DEFUNs ────────────────────────────────────────────────────── */

DEFUN ("cmacs-podomation-load-file", Fcmacs_podomation_load_file,
       Scmacs_podomation_load_file, 1, 1, 0,
       doc: /* Load and parse a .pod DSL file.
FILE is the path to the file.  */)
  (Lisp_Object file)
{
  GError *error = NULL;
  gchar *contents;
  gsize len;

  CHECK_STRING (file);
  if (cmacs_pod_engine == NULL)
    xsignal1 (Qcmacs_podomation_error,
	      build_string ("Podomation engine not running"));

  if (!g_file_get_contents (SSDATA (file), &contents, &len, &error))
    {
      Lisp_Object msg = build_string (error->message);
      g_error_free (error);
      xsignal1 (Qcmacs_podomation_error, msg);
    }

  if (!pod_engine_parse_dsl (cmacs_pod_engine, contents, &error))
    {
      Lisp_Object msg = build_string (error->message);
      g_error_free (error);
      g_free (contents);
      xsignal1 (Qcmacs_podomation_error, msg);
    }

  g_free (contents);
  return Qt;
}

DEFUN ("cmacs-podomation-eval-dsl", Fcmacs_podomation_eval_dsl,
       Scmacs_podomation_eval_dsl, 1, 1, 0,
       doc: /* Parse and execute a podomation DSL string.
DSL is the DSL source text.  */)
  (Lisp_Object dsl)
{
  GError *error = NULL;

  CHECK_STRING (dsl);
  if (cmacs_pod_engine == NULL)
    xsignal1 (Qcmacs_podomation_error,
	      build_string ("Podomation engine not running"));

  if (!pod_engine_parse_dsl (cmacs_pod_engine, SSDATA (dsl), &error))
    {
      Lisp_Object msg = build_string (error->message);
      g_error_free (error);
      xsignal1 (Qcmacs_podomation_error, msg);
    }
  return Qt;
}

/* ── Pod management DEFUNs ─────────────────────────────────────────── */

DEFUN ("cmacs-podomation-list-pods", Fcmacs_podomation_list_pods,
       Scmacs_podomation_list_pods, 0, 0, 0,
       doc: /* Return an alist of active pod names and health.
Each element is (NAME . HEALTH) where HEALTH is a symbol:
healthy, degraded, failed, or recovering.  */)
  (void)
{
  GPtrArray *pods;
  Lisp_Object result = Qnil;
  guint i;

  if (cmacs_pod_engine == NULL)
    return Qnil;

  pods = pod_engine_get_pods (cmacs_pod_engine);
  for (i = 0; i < pods->len; i++)
    {
      PodPod *pod = g_ptr_array_index (pods, i);
      const gchar *name = pod_pod_get_name (pod);
      PodPodHealth health = pod_pod_get_health (pod);

      result = Fcons (Fcons (build_string (name),
			     pod_health_to_symbol (health)),
		      result);
    }
  return Fnreverse (result);
}

DEFUN ("cmacs-podomation-list-modules", Fcmacs_podomation_list_modules,
       Scmacs_podomation_list_modules, 0, 0, 0,
       doc: /* Return a list of loaded podomation module names.  */)
  (void)
{
  PodModuleManager *mgr;
  GList *modules, *l;
  Lisp_Object result = Qnil;

  if (cmacs_pod_engine == NULL)
    return Qnil;

  mgr = pod_engine_get_module_manager (cmacs_pod_engine);
  modules = pod_module_manager_list_modules (mgr);

  for (l = modules; l != NULL; l = l->next)
    {
      PodModule *mod = POD_MODULE (l->data);
      const gchar *name = pod_module_get_name (mod);
      result = Fcons (build_string (name), result);
    }

  g_list_free (modules);
  return Fnreverse (result);
}

/* ── REPL DEFUNs ───────────────────────────────────────────────────── */

DEFUN ("cmacs-podomation-repl-eval", Fcmacs_podomation_repl_eval,
       Scmacs_podomation_repl_eval, 1, 1, 0,
       doc: /* Evaluate a line of input in the podomation REPL.
LINE is a string of DSL input.
Returns a cons (KIND . TEXT) where KIND is a symbol:
empty, value, output, error, info, quit, or continue.
TEXT is the result string, or nil.  */)
  (Lisp_Object line)
{
  GError *error = NULL;
  PodReplResult *result;
  Lisp_Object kind, text;

  CHECK_STRING (line);
  if (cmacs_pod_repl == NULL)
    xsignal1 (Qcmacs_podomation_error,
	      build_string ("Podomation engine not running"));

  result = pod_repl_eval (cmacs_pod_repl, SSDATA (line), &error);
  if (result == NULL)
    {
      Lisp_Object msg = build_string (error ? error->message
					    : "Unknown REPL error");
      if (error)
	g_error_free (error);
      xsignal1 (Qcmacs_podomation_error, msg);
    }

  kind = repl_kind_to_symbol (result->kind);
  text = result->text ? build_string (result->text) : Qnil;
  pod_repl_result_free (result);

  return Fcons (kind, text);
}

DEFUN ("cmacs-podomation-repl-complete", Fcmacs_podomation_repl_complete,
       Scmacs_podomation_repl_complete, 1, 1, 0,
       doc: /* Return completions for LINE at the end of the string.
Returns a list of completion strings.  */)
  (Lisp_Object line)
{
  GPtrArray *completions;
  Lisp_Object result = Qnil;
  guint i;

  CHECK_STRING (line);
  if (cmacs_pod_repl == NULL)
    return Qnil;

  completions = pod_repl_complete (cmacs_pod_repl, SSDATA (line),
				   (guint) SBYTES (line));
  if (completions == NULL)
    return Qnil;

  for (i = 0; i < completions->len; i++)
    result = Fcons (build_string (g_ptr_array_index (completions, i)),
		    result);

  g_ptr_array_unref (completions);
  return Fnreverse (result);
}

DEFUN ("cmacs-podomation-repl-prompt", Fcmacs_podomation_repl_prompt,
       Scmacs_podomation_repl_prompt, 0, 0, 0,
       doc: /* Return the current REPL prompt string.  */)
  (void)
{
  if (cmacs_pod_repl == NULL)
    return build_string ("podomation> ");
  return build_string (pod_repl_get_prompt (cmacs_pod_repl));
}

DEFUN ("cmacs-podomation-repl-reset", Fcmacs_podomation_repl_reset,
       Scmacs_podomation_repl_reset, 0, 0, 0,
       doc: /* Reset the REPL state (pods, variables, multi-line buffer).
Modules remain loaded.  */)
  (void)
{
  if (cmacs_pod_repl == NULL)
    xsignal1 (Qcmacs_podomation_error,
	      build_string ("Podomation engine not running"));
  pod_repl_reset (cmacs_pod_repl);
  return Qt;
}

/* ── Context and stats DEFUNs ──────────────────────────────────────── */

DEFUN ("cmacs-podomation-set-context", Fcmacs_podomation_set_context,
       Scmacs_podomation_set_context, 1, 1, 0,
       doc: /* Set the engine application context.
CONTEXT is an alist of (KEY . VALUE) pairs.  Keys should be strings
or symbols; values should be strings.  These become available in DSL
bindings as {context->key}.  */)
  (Lisp_Object context)
{
  GVariant *gv;

  if (cmacs_pod_engine == NULL)
    xsignal1 (Qcmacs_podomation_error,
	      build_string ("Podomation engine not running"));

  gv = alist_to_variant (context);
  pod_engine_set_context (cmacs_pod_engine, gv);
  g_variant_unref (gv);
  return Qt;
}

DEFUN ("cmacs-podomation-stats", Fcmacs_podomation_stats,
       Scmacs_podomation_stats, 0, 0, 0,
       doc: /* Return engine statistics as a plist.
Includes :events-dispatched, :handlers-called, :handlers-failed,
:pipe-chains-executed, and :start-time-us.  */)
  (void)
{
  const PodEngineStats *stats;
  Lisp_Object result = Qnil;

  if (cmacs_pod_engine == NULL)
    return Qnil;

  stats = pod_engine_get_stats (cmacs_pod_engine);

  result = Fcons (intern (":start-time-us"),
		  Fcons (make_fixnum ((EMACS_INT) stats->start_time_us),
			 result));
  result = Fcons (intern (":pipe-chains-executed"),
		  Fcons (make_fixnum ((EMACS_INT) stats->pipe_chains_executed),
			 result));
  result = Fcons (intern (":handlers-failed"),
		  Fcons (make_fixnum ((EMACS_INT) stats->handlers_failed),
			 result));
  result = Fcons (intern (":handlers-called"),
		  Fcons (make_fixnum ((EMACS_INT) stats->handlers_called),
			 result));
  result = Fcons (intern (":events-dispatched"),
		  Fcons (make_fixnum ((EMACS_INT) stats->events_dispatched),
			 result));

  return result;
}

/* ── Event emission ────────────────────────────────────────────────── */

DEFUN ("cmacs-podomation-emit-event", Fcmacs_podomation_emit_event,
       Scmacs_podomation_emit_event, 2, 2, 0,
       doc: /* Emit a podomation event from the cmacs module.
EVENT-NAME is a string (e.g. "on_buffer_save").
DATA is an alist of (KEY . VALUE) pairs for the event data.  */)
  (Lisp_Object event_name, Lisp_Object data)
{
  GVariant *gv;

  CHECK_STRING (event_name);
  if (cmacs_pod_cmacs_module == NULL)
    return Qnil;

  if (NILP (data))
    {
      g_signal_emit_by_name (cmacs_pod_cmacs_module, "event-fired",
			     SSDATA (event_name), NULL);
    }
  else
    {
      gv = alist_to_variant (data);
      g_signal_emit_by_name (cmacs_pod_cmacs_module, "event-fired",
			     SSDATA (event_name), gv);
      g_variant_unref (gv);
    }
  return Qt;
}

/* ── Init ──────────────────────────────────────────────────────────── */

void
syms_of_cmacs_podomation (void)
{
  DEFSYM (Qcmacs_podomation_error, "cmacs-podomation-error");

  Fput (Qcmacs_podomation_error, Qerror_conditions,
	Fcons (Qcmacs_podomation_error, Fcons (Qerror, Qnil)));
  Fput (Qcmacs_podomation_error, Qerror_message,
	build_string ("Podomation engine error"));

  /* Lifecycle. */
  defsubr (&Scmacs_podomation_start);
  defsubr (&Scmacs_podomation_stop);
  defsubr (&Scmacs_podomation_running_p);
  defsubr (&Scmacs_podomation_reload);

  /* DSL. */
  defsubr (&Scmacs_podomation_load_file);
  defsubr (&Scmacs_podomation_eval_dsl);

  /* Pod management. */
  defsubr (&Scmacs_podomation_list_pods);
  defsubr (&Scmacs_podomation_list_modules);

  /* REPL. */
  defsubr (&Scmacs_podomation_repl_eval);
  defsubr (&Scmacs_podomation_repl_complete);
  defsubr (&Scmacs_podomation_repl_prompt);
  defsubr (&Scmacs_podomation_repl_reset);

  /* Context and stats. */
  defsubr (&Scmacs_podomation_set_context);
  defsubr (&Scmacs_podomation_stats);

  /* Event emission. */
  defsubr (&Scmacs_podomation_emit_event);
}

void
init_cmacs_podomation (void)
{
  /* Intentionally empty.  Engine is started from Elisp via
     cmacs-podomation-start, not during C init.  This keeps the
     pdumper image clean — no PodEngine state in the dump. */
}

#endif /* HAVE_CMACS_PODOMATION */
