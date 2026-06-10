/* pod-cmacs-module.c — CMacs PodModule for Emacs event/eval integration
 *
 * Copyright (C) 2026 Zach Podbielniak
 * SPDX-License-Identifier: AGPL-3.0-or-later
 *
 * DUAL PodModule implementing PodEventSource and PodEventHandler.
 *
 * As a source, emits Emacs lifecycle events (buffer save, kill, idle,
 * command execution, etc.) driven by hook functions installed from
 * the Elisp layer (cmacs-podomation.el).
 *
 * As a handler, provides 32 operations: buffer management, file I/O,
 * shell commands, clipboard, notifications, and Lisp eval.  Action
 * handlers use g_idle_add (fire-and-forget); query handlers call
 * cmacs_dispatch_eval directly (safe because handlers run inside
 * cmacs_glib_dispatch where waiting_for_input is already FALSE).
 * Pure GLib handlers (file ops, shell, notify) need no Lisp at all.
 */

#include <config.h>

#ifdef HAVE_CMACS_PODOMATION

#include "pod-cmacs-module.h"
#include "lisp.h"
#include "cmacs-eval-dispatch.h"

#include <unistd.h>

/* ── Instance struct ───────────────────────────────────────────────── */

struct _PodCmacsModule
{
  PodModule parent_instance;
  gboolean  started;
};

/* ── Supported names ───────────────────────────────────────────────── */

static const gchar *source_events[] = {
  "on_buffer_save",
  "on_buffer_kill",
  "on_idle",
  "on_command",
  "on_after_init",
  "on_after_load",
  "on_post_command",
  "on_process_exit",
  "on_buffer_create",
  "on_window_focus",
  "on_region_change",
  "on_compile_finish",
  "on_hook",
  /* cmacs-audio + cmacs-whisper voice events.  Fired by the Elisp
   * `cmacs-audio-voice-event-functions' hook in `cmacs-audio.el' when
   * a transcript or matched keyword is available. */
  "on_transcription_ready",
  "on_voice_command",
  /* cmacs-gsurf browser events.  Fired by the Elisp page-event hook
   * handlers in `cmacs-gsurf.el' / `cmacs-gsurf-downloads.el'. */
  "on_gsurf_navigate",
  "on_gsurf_download",
  "on_gsurf_permission",
  "on_gsurf_crash",
  /* GNU's Eye geofence events.  Fired by `cmacs-gnuseye-geofence.el' when a
   * tracked entity enters or leaves a geofence.  Event data: fence, entity_id,
   * kind, label, lat, lon, distance_km, layer. */
  "on_geofence_enter",
  "on_geofence_exit",
  NULL
};

static const gchar *handler_funcs[] = {
  /* Lisp eval */
  "eval",
  "eval_async",
  /* Buffer actions */
  "save_buffer",
  "save_all",
  "kill_buffer",
  "switch_buffer",
  "revert_buffer",
  /* Buffer queries */
  "buffer_name",
  "buffer_file",
  "buffer_list",
  "major_mode",
  "region_text",
  "project_root",
  /* Navigation / editing */
  "message",
  "find_file",
  "set_variable",
  "run_command",
  "insert",
  "goto_line",
  "compile",
  "dired",
  /* Clipboard */
  "kill_new",
  "current_kill",
  /* File operations (pure GLib, no Lisp) */
  "shell_command",
  "write_file",
  "read_file",
  "append_file",
  "delete_file",
  "rename_file",
  "copy_file",
  "file_exists",
  "mkdir",
  /* Notification (pure GLib) */
  "notify",
  /* cmacs-piper voice action. */
  "speak",
  NULL
};

/* ── PodEventSource interface ──────────────────────────────────────── */

static gboolean
cmacs_source_start (PodEventSource *self, GMainContext *context,
		    GError **error)
{
  PodCmacsModule *mod = POD_CMACS_MODULE (self);
  (void) context;
  (void) error;
  mod->started = TRUE;
  return TRUE;
}

static void
cmacs_source_stop (PodEventSource *self)
{
  PodCmacsModule *mod = POD_CMACS_MODULE (self);
  mod->started = FALSE;
}

static PodEventKind
cmacs_source_get_event_kind (PodEventSource *self)
{
  (void) self;
  return POD_EVENT_KIND_CUSTOM;
}

static const gchar *const *
cmacs_source_get_supported_events (PodEventSource *self)
{
  (void) self;
  return source_events;
}

static void
cmacs_source_init (PodEventSourceInterface *iface)
{
  iface->start                = cmacs_source_start;
  iface->stop                 = cmacs_source_stop;
  iface->get_event_kind       = cmacs_source_get_event_kind;
  iface->get_supported_events = cmacs_source_get_supported_events;
}

/* ── Lisp eval via idle dispatch ───────────────────────────────────── */

typedef struct
{
  gchar *expression;
} CmacsIdleEval;

static gboolean
cmacs_idle_eval_cb (gpointer data)
{
  CmacsIdleEval *req = data;
  GError *error = NULL;
  gchar *result;

  result = cmacs_dispatch_eval (req->expression, &error);
  g_free (result);
  if (error)
    g_error_free (error);
  g_free (req->expression);
  g_free (req);
  return G_SOURCE_REMOVE;
}

static gboolean
cmacs_idle_message_cb (gpointer data)
{
  gchar *text = data;
  cmacs_dispatch_message (text);
  g_free (text);
  return G_SOURCE_REMOVE;
}

static gboolean
cmacs_idle_find_file_cb (gpointer data)
{
  gchar *path = data;
  cmacs_dispatch_find_file (path);
  g_free (path);
  return G_SOURCE_REMOVE;
}

/* Helper: extract string at position N from params tuple. */
static const gchar *
get_param_string (GVariant *params, gsize n)
{
  if (params == NULL)
    return NULL;
  if (g_variant_is_of_type (params, G_VARIANT_TYPE_STRING))
    return n == 0 ? g_variant_get_string (params, NULL) : NULL;
  if (g_variant_is_of_type (params, G_VARIANT_TYPE_TUPLE))
    {
      if (n >= g_variant_n_children (params))
	return NULL;
      GVariant *child = g_variant_get_child_value (params, n);
      const gchar *s = g_variant_get_string (child, NULL);
      g_variant_unref (child);
      return s;
    }
  return NULL;
}

/* ── Lisp string escaping ─────────────────────────────────────────── */

/* Escape a C string for safe embedding in a Lisp string literal. */
static gchar *
lisp_escape (const gchar *s)
{
  GString *out;
  const gchar *p;

  if (s == NULL)
    return g_strdup ("");

  out = g_string_sized_new (strlen (s) + 8);
  for (p = s; *p != '\0'; p++)
    {
      if (*p == '"' || *p == '\\')
	g_string_append_c (out, '\\');
      g_string_append_c (out, *p);
    }
  return g_string_free (out, FALSE);
}

/* Evaluate EXPRESSION via cmacs_dispatch_eval, strip prin1 quoting
   from string results, and return the raw value.  Caller must
   g_free the return value.  Returns NULL on error.

   Safe to call from handlers because they run inside
   cmacs_glib_dispatch where waiting_for_input is already FALSE. */
static gchar *
eval_to_raw_string (const gchar *expression)
{
  GError *error = NULL;
  gchar *val, *unquoted;
  gsize len;

  val = cmacs_dispatch_eval (expression, &error);
  if (error != NULL)
    {
      g_error_free (error);
      return NULL;
    }
  if (val == NULL)
    return NULL;

  /* Strip outer quotes from prin1 string representation. */
  len = strlen (val);
  if (len >= 2 && val[0] == '"' && val[len - 1] == '"')
    {
      unquoted = g_strndup (val + 1, len - 2);
      g_free (val);
      return unquoted;
    }

  return val;
}

/* Build an a{sv} result with a single "value" string key. */
static void
set_result_value (GVariant **result, const gchar *value)
{
  GVariantBuilder rb;

  if (result == NULL)
    return;

  g_variant_builder_init (&rb, G_VARIANT_TYPE ("a{sv}"));
  g_variant_builder_add (&rb, "{sv}", "value",
			 g_variant_new_string (value ? value : ""));
  *result = g_variant_builder_end (&rb);
}

/* Post a Lisp expression for async idle evaluation (fire-and-forget). */
static void
idle_eval (const gchar *expression)
{
  CmacsIdleEval *req = g_new0 (CmacsIdleEval, 1);
  req->expression = g_strdup (expression);
  g_idle_add (cmacs_idle_eval_cb, req);
}

/* Build and post a formatted Lisp expression for idle evaluation. */
G_GNUC_PRINTF (1, 2) static void
idle_eval_fmt (const gchar *format, ...)
{
  va_list ap;
  gchar *expr;

  va_start (ap, format);
  expr = g_strdup_vprintf (format, ap);
  va_end (ap);

  CmacsIdleEval *req = g_new0 (CmacsIdleEval, 1);
  req->expression = expr;
  g_idle_add (cmacs_idle_eval_cb, req);
}

/* ── Pure GLib handlers (no Lisp needed) ──────────────────────────── */

static gboolean
handle_shell_command (GVariant *params, GVariant **result)
{
  const gchar *cmd;
  gchar *out_text = NULL, *err_text = NULL;
  gchar exit_buf[16];
  gint exit_status = 0;
  GError *error = NULL;

  cmd = get_param_string (params, 0);
  if (cmd == NULL)
    return FALSE;

  g_spawn_command_line_sync (cmd, &out_text, &err_text,
			     &exit_status, &error);
  if (error != NULL)
    {
      g_error_free (error);
      g_free (out_text);
      g_free (err_text);
      return FALSE;
    }

  if (result != NULL)
    {
      GVariantBuilder rb;
      g_snprintf (exit_buf, sizeof exit_buf, "%d",
		  WIFEXITED (exit_status) ? WEXITSTATUS (exit_status)
					  : -1);
      g_variant_builder_init (&rb, G_VARIANT_TYPE ("a{sv}"));
      g_variant_builder_add (&rb, "{sv}", "stdout",
			     g_variant_new_string (out_text ? out_text : ""));
      g_variant_builder_add (&rb, "{sv}", "stderr",
			     g_variant_new_string (err_text ? err_text : ""));
      g_variant_builder_add (&rb, "{sv}", "exit_code",
			     g_variant_new_string (exit_buf));
      /* Alias "value" to stdout for simple pipe usage. */
      g_variant_builder_add (&rb, "{sv}", "value",
			     g_variant_new_string (out_text ? out_text : ""));
      *result = g_variant_builder_end (&rb);
    }

  g_free (out_text);
  g_free (err_text);
  return TRUE;
}

static gboolean
handle_write_file (GVariant *params, gboolean append)
{
  const gchar *path, *content;
  GError *error = NULL;
  gboolean ok;

  path = get_param_string (params, 0);
  content = get_param_string (params, 1);
  if (path == NULL || content == NULL)
    return FALSE;

  if (append)
    {
      gchar *existing = NULL;
      GString *buf;

      g_file_get_contents (path, &existing, NULL, NULL);
      buf = g_string_new (existing ? existing : "");
      g_free (existing);
      g_string_append (buf, content);
      ok = g_file_set_contents (path, buf->str, buf->len, &error);
      g_string_free (buf, TRUE);
    }
  else
    ok = g_file_set_contents (path, content, -1, &error);

  if (error != NULL)
    g_error_free (error);
  return ok;
}

static gboolean
handle_read_file (GVariant *params, GVariant **result)
{
  const gchar *path;
  gchar *content = NULL;
  GError *error = NULL;

  path = get_param_string (params, 0);
  if (path == NULL)
    return FALSE;

  g_file_get_contents (path, &content, NULL, &error);
  if (error != NULL)
    {
      g_error_free (error);
      return FALSE;
    }

  set_result_value (result, content);
  g_free (content);
  return TRUE;
}

static gboolean
handle_file_exists (GVariant *params, GVariant **result)
{
  const gchar *path = get_param_string (params, 0);
  if (path == NULL)
    return FALSE;

  set_result_value (result, g_file_test (path, G_FILE_TEST_EXISTS)
			      ? "true" : "false");
  return TRUE;
}

static gboolean
handle_notify (GVariant *params)
{
  const gchar *title, *body;
  gchar *argv[4];
  GError *error = NULL;

  title = get_param_string (params, 0);
  body = get_param_string (params, 1);
  if (title == NULL)
    return FALSE;

  argv[0] = (gchar *) "notify-send";
  argv[1] = (gchar *) title;
  argv[2] = (gchar *) (body ? body : "");
  argv[3] = NULL;

  g_spawn_async (NULL, argv, NULL, G_SPAWN_SEARCH_PATH,
		 NULL, NULL, NULL, &error);
  if (error != NULL)
    {
      g_error_free (error);
      return FALSE;
    }
  return TRUE;
}

/* ── PodEventHandler interface ─────────────────────────────────────── */

static gboolean
cmacs_handle_event (PodEventHandler *handler,
		    const gchar     *event_name,
		    GVariant        *event_data,
		    GVariant        *params,
		    GVariant       **result)
{
  (void) handler;
  (void) event_data;

  if (result != NULL)
    *result = NULL;

  /* ── Lisp eval ─────────────────────────────────────────────── */

  if (g_strcmp0 (event_name, "eval") == 0)
    {
      const gchar *expr = get_param_string (params, 0);
      if (expr == NULL)
	return FALSE;
      gchar *val = eval_to_raw_string (expr);
      set_result_value (result, val ? val : "");
      g_free (val);
      return TRUE;
    }

  if (g_strcmp0 (event_name, "eval_async") == 0)
    {
      const gchar *expr = get_param_string (params, 0);
      if (expr == NULL)
	return FALSE;
      idle_eval (expr);
      return TRUE;
    }

  /* ── Buffer actions ────────────────────────────────────────── */

  if (g_strcmp0 (event_name, "save_buffer") == 0)
    {
      idle_eval ("(save-buffer)");
      return TRUE;
    }

  if (g_strcmp0 (event_name, "save_all") == 0)
    {
      idle_eval ("(save-some-buffers t)");
      return TRUE;
    }

  if (g_strcmp0 (event_name, "kill_buffer") == 0)
    {
      const gchar *name = get_param_string (params, 0);
      if (name != NULL)
	{
	  gchar *esc = lisp_escape (name);
	  idle_eval_fmt ("(kill-buffer \"%s\")", esc);
	  g_free (esc);
	}
      else
	idle_eval ("(kill-buffer)");
      return TRUE;
    }

  if (g_strcmp0 (event_name, "switch_buffer") == 0)
    {
      const gchar *name = get_param_string (params, 0);
      if (name == NULL)
	return FALSE;
      gchar *esc = lisp_escape (name);
      idle_eval_fmt ("(switch-to-buffer \"%s\")", esc);
      g_free (esc);
      return TRUE;
    }

  if (g_strcmp0 (event_name, "revert_buffer") == 0)
    {
      idle_eval ("(revert-buffer t t)");
      return TRUE;
    }

  /* ── Buffer queries (synchronous, safe in dispatch context) ── */

  if (g_strcmp0 (event_name, "buffer_name") == 0)
    {
      gchar *val = eval_to_raw_string ("(buffer-name)");
      set_result_value (result, val);
      g_free (val);
      return TRUE;
    }

  if (g_strcmp0 (event_name, "buffer_file") == 0)
    {
      gchar *val = eval_to_raw_string
	("(or (buffer-file-name) \"\")");
      set_result_value (result, val);
      g_free (val);
      return TRUE;
    }

  if (g_strcmp0 (event_name, "buffer_list") == 0)
    {
      gchar *val = eval_to_raw_string
	("(mapconcat #'buffer-name (buffer-list) \"\\n\")");
      set_result_value (result, val);
      g_free (val);
      return TRUE;
    }

  if (g_strcmp0 (event_name, "major_mode") == 0)
    {
      gchar *val = eval_to_raw_string
	("(symbol-name major-mode)");
      set_result_value (result, val);
      g_free (val);
      return TRUE;
    }

  if (g_strcmp0 (event_name, "region_text") == 0)
    {
      gchar *val = eval_to_raw_string
	("(if (use-region-p)"
	 "  (buffer-substring-no-properties"
	 "    (region-beginning) (region-end))"
	 "  \"\")");
      set_result_value (result, val);
      g_free (val);
      return TRUE;
    }

  if (g_strcmp0 (event_name, "project_root") == 0)
    {
      gchar *val = eval_to_raw_string
	("(or (and (fboundp 'project-root)"
	 "         (project-current)"
	 "         (project-root (project-current)))"
	 "    \"\")");
      set_result_value (result, val);
      g_free (val);
      return TRUE;
    }

  /* ── Navigation / editing ──────────────────────────────────── */

  if (g_strcmp0 (event_name, "message") == 0)
    {
      const gchar *text = get_param_string (params, 0);
      if (text == NULL)
	return FALSE;
      g_idle_add (cmacs_idle_message_cb, g_strdup (text));
      return TRUE;
    }

  if (g_strcmp0 (event_name, "find_file") == 0)
    {
      const gchar *path = get_param_string (params, 0);
      if (path == NULL)
	return FALSE;
      g_idle_add (cmacs_idle_find_file_cb, g_strdup (path));
      return TRUE;
    }

  if (g_strcmp0 (event_name, "set_variable") == 0)
    {
      const gchar *var = get_param_string (params, 0);
      const gchar *val = get_param_string (params, 1);
      if (var == NULL || val == NULL)
	return FALSE;
      gchar *esc = lisp_escape (val);
      idle_eval_fmt ("(setq %s \"%s\")", var, esc);
      g_free (esc);
      return TRUE;
    }

  if (g_strcmp0 (event_name, "run_command") == 0)
    {
      const gchar *cmd = get_param_string (params, 0);
      if (cmd == NULL)
	return FALSE;
      idle_eval_fmt ("(call-interactively '%s)", cmd);
      return TRUE;
    }

  if (g_strcmp0 (event_name, "insert") == 0)
    {
      const gchar *text = get_param_string (params, 0);
      if (text == NULL)
	return FALSE;
      gchar *esc = lisp_escape (text);
      idle_eval_fmt ("(insert \"%s\")", esc);
      g_free (esc);
      return TRUE;
    }

  if (g_strcmp0 (event_name, "goto_line") == 0)
    {
      const gchar *line = get_param_string (params, 0);
      if (line == NULL)
	return FALSE;
      idle_eval_fmt ("(goto-line %s)", line);
      return TRUE;
    }

  if (g_strcmp0 (event_name, "compile") == 0)
    {
      const gchar *cmd = get_param_string (params, 0);
      if (cmd == NULL)
	return FALSE;
      gchar *esc = lisp_escape (cmd);
      idle_eval_fmt ("(compile \"%s\")", esc);
      g_free (esc);
      return TRUE;
    }

  if (g_strcmp0 (event_name, "dired") == 0)
    {
      const gchar *path = get_param_string (params, 0);
      if (path == NULL)
	return FALSE;
      gchar *esc = lisp_escape (path);
      idle_eval_fmt ("(dired \"%s\")", esc);
      g_free (esc);
      return TRUE;
    }

  /* ── Clipboard ─────────────────────────────────────────────── */

  if (g_strcmp0 (event_name, "kill_new") == 0)
    {
      const gchar *text = get_param_string (params, 0);
      if (text == NULL)
	return FALSE;
      gchar *esc = lisp_escape (text);
      idle_eval_fmt ("(kill-new \"%s\")", esc);
      g_free (esc);
      return TRUE;
    }

  if (g_strcmp0 (event_name, "current_kill") == 0)
    {
      gchar *val = eval_to_raw_string
	("(or (current-kill 0 t) \"\")");
      set_result_value (result, val);
      g_free (val);
      return TRUE;
    }

  /* ── File operations (pure GLib, no Lisp) ──────────────────── */

  if (g_strcmp0 (event_name, "shell_command") == 0)
    return handle_shell_command (params, result);

  if (g_strcmp0 (event_name, "write_file") == 0)
    return handle_write_file (params, FALSE);

  if (g_strcmp0 (event_name, "append_file") == 0)
    return handle_write_file (params, TRUE);

  if (g_strcmp0 (event_name, "read_file") == 0)
    return handle_read_file (params, result);

  if (g_strcmp0 (event_name, "file_exists") == 0)
    return handle_file_exists (params, result);

  if (g_strcmp0 (event_name, "delete_file") == 0)
    {
      const gchar *path = get_param_string (params, 0);
      if (path == NULL)
	return FALSE;
      return unlink (path) == 0;
    }

  if (g_strcmp0 (event_name, "rename_file") == 0)
    {
      const gchar *old_path = get_param_string (params, 0);
      const gchar *new_path = get_param_string (params, 1);
      if (old_path == NULL || new_path == NULL)
	return FALSE;
      return rename (old_path, new_path) == 0;
    }

  if (g_strcmp0 (event_name, "copy_file") == 0)
    {
      const gchar *src = get_param_string (params, 0);
      const gchar *dst = get_param_string (params, 1);
      GFile *sf, *df;
      GError *error = NULL;
      gboolean ok;

      if (src == NULL || dst == NULL)
	return FALSE;

      sf = g_file_new_for_path (src);
      df = g_file_new_for_path (dst);
      ok = g_file_copy (sf, df, G_FILE_COPY_OVERWRITE,
			NULL, NULL, NULL, &error);
      g_object_unref (sf);
      g_object_unref (df);
      if (error != NULL)
	g_error_free (error);
      return ok;
    }

  if (g_strcmp0 (event_name, "mkdir") == 0)
    {
      const gchar *path = get_param_string (params, 0);
      if (path == NULL)
	return FALSE;
      return g_mkdir_with_parents (path, 0755) == 0;
    }

  /* ── Notification (pure GLib) ──────────────────────────────── */

  if (g_strcmp0 (event_name, "notify") == 0)
    return handle_notify (params);

  /* ── cmacs-piper speak (routes through Elisp via eval) ─────── */

  if (g_strcmp0 (event_name, "speak") == 0)
    {
      const gchar *text = get_param_string (params, 0);
      if (!text) return FALSE;
      g_autofree gchar *quoted = g_strdup_printf ("\"%s\"", text);
      g_autofree gchar *expr =
        g_strdup_printf ("(progn (require 'cmacs-piper) "
                         "(cmacs-piper-speak-async %s))",
                         quoted);
      g_autoptr (GError) err = NULL;
      g_autofree gchar *r = cmacs_dispatch_eval (expr, &err);
      return r != NULL;
    }

  return FALSE;
}

static const gchar *const *
cmacs_handler_get_supported (PodEventHandler *self)
{
  (void) self;
  return handler_funcs;
}

static void
cmacs_handler_init (PodEventHandlerInterface *iface)
{
  iface->handle_event           = cmacs_handle_event;
  iface->get_supported_handlers = cmacs_handler_get_supported;
}

/* ── GObject boilerplate ───────────────────────────────────────────── */

G_DEFINE_FINAL_TYPE_WITH_CODE (PodCmacsModule, pod_cmacs_module,
			       POD_TYPE_MODULE,
  G_IMPLEMENT_INTERFACE (POD_TYPE_EVENT_SOURCE, cmacs_source_init)
  G_IMPLEMENT_INTERFACE (POD_TYPE_EVENT_HANDLER, cmacs_handler_init))

static const gchar *
cmacs_get_name (PodModule *self)
{
  (void) self;
  return "cmacs";
}

static const gchar *
cmacs_get_description (PodModule *self)
{
  (void) self;
  return "CMacs Emacs integration — events and eval";
}

static gboolean
cmacs_activate (PodModule *self)
{
  (void) self;
  return TRUE;
}

static void
cmacs_deactivate (PodModule *self)
{
  cmacs_source_stop (POD_EVENT_SOURCE (self));
}

static void
pod_cmacs_module_class_init (PodCmacsModuleClass *klass)
{
  PodModuleClass *mc = POD_MODULE_CLASS (klass);
  mc->get_name        = cmacs_get_name;
  mc->get_description = cmacs_get_description;
  mc->activate        = cmacs_activate;
  mc->deactivate      = cmacs_deactivate;
}

static void
pod_cmacs_module_init (PodCmacsModule *self)
{
  self->started = FALSE;
}

PodModule *
pod_cmacs_module_new (void)
{
  return g_object_new (POD_TYPE_CMACS_MODULE, NULL);
}

#endif /* HAVE_CMACS_PODOMATION */
