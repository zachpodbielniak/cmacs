/*
 * Copyright (C) 2026 Zach Podbielniak
 * SPDX-License-Identifier: AGPL-3.0-or-later
 */

/* cmacs-eval-dispatch.c — shared dispatch for CMacs eval operations
 *
 * Transport-agnostic dispatch: the D-Bus service and socketpair IPC
 * handler both call these functions.  They run on the Emacs main
 * thread via the CMacs GMainContext.
 */

#include <config.h>

#ifdef HAVE_CMACS_GLIB

#include "lisp.h"
#include "cmacs-eval-dispatch.h"

#include <glib.h>

/* ── Safe evaluation helpers ───────────────────────────────────────── */

static Lisp_Object
dispatch_eval_body (Lisp_Object form)
{
  return Feval (form, Qnil);
}

static Lisp_Object
dispatch_eval_error (Lisp_Object err)
{
  return Fcons (Qerror, Ferror_message_string (err));
}

static Lisp_Object
dispatch_safe_eval (Lisp_Object form)
{
  return internal_condition_case_1 (dispatch_eval_body, form,
                                    Qt, dispatch_eval_error);
}

static gboolean
dispatch_result_is_error (Lisp_Object result)
{
  return CONSP (result) && EQ (XCAR (result), Qerror);
}

#define CMACS_DISPATCH_ERROR_DOMAIN (g_quark_from_static_string ("cmacs-dispatch"))

/* ── Public API ────────────────────────────────────────────────────── */

gchar *
cmacs_dispatch_eval (const gchar *expression, GError **error)
{
  Lisp_Object form, result, printed;

  form = Fcar (Fread_from_string (build_string (expression), Qnil, Qnil));
  result = dispatch_safe_eval (form);

  if (dispatch_result_is_error (result))
    {
      Lisp_Object msg = XCDR (result);
      g_set_error (error, CMACS_DISPATCH_ERROR_DOMAIN, 1,
                   "%s", STRINGP (msg) ? SSDATA (msg) : "unknown error");
      return NULL;
    }

  printed = Fprin1_to_string (result, Qnil, Qnil);
  return g_strdup (SSDATA (printed));
}

void
cmacs_dispatch_find_file (const gchar *path)
{
  safe_calln (intern ("find-file"), build_string (path));
}

void
cmacs_dispatch_message (const gchar *text)
{
  safe_calln (intern ("message"), build_string (text));
}

gboolean
cmacs_dispatch_gi_require (const gchar *ns, const gchar *ver,
                           GError **error)
{
  Lisp_Object form, result;

  form = list3 (intern ("gi-require"),
                build_string (ns), build_string (ver));
  result = dispatch_safe_eval (form);

  if (dispatch_result_is_error (result))
    {
      Lisp_Object msg = XCDR (result);
      g_set_error (error, CMACS_DISPATCH_ERROR_DOMAIN, 1,
                   "%s", STRINGP (msg) ? SSDATA (msg) : "unknown error");
      return FALSE;
    }

  return !NILP (result);
}

gchar *
cmacs_dispatch_gi_call (const gchar *ns, const gchar *func,
                        const gchar *const *args, gint n_args,
                        GError **error)
{
  Lisp_Object args_list, form, result, printed;
  gint i;

  /* Build args list from strings, reading each as a Lisp expression. */
  args_list = Qnil;
  for (i = n_args - 1; i >= 0; i--)
    {
      Lisp_Object parsed =
        Fcar (Fread_from_string (build_string (args[i]), Qnil, Qnil));
      args_list = Fcons (parsed, args_list);
    }

  /* Build: (gi-call "NS" "func" arg1 arg2 ...) */
  form = Fcons (intern ("gi-call"),
                Fcons (build_string (ns),
                       Fcons (build_string (func), args_list)));
  result = dispatch_safe_eval (form);

  if (dispatch_result_is_error (result))
    {
      Lisp_Object msg = XCDR (result);
      g_set_error (error, CMACS_DISPATCH_ERROR_DOMAIN, 1,
                   "%s", STRINGP (msg) ? SSDATA (msg) : "unknown error");
      return NULL;
    }

  printed = Fprin1_to_string (result, Qnil, Qnil);
  return g_strdup (SSDATA (printed));
}

gchar **
cmacs_dispatch_gi_list_functions (const gchar *ns)
{
  Lisp_Object form, result, tail;
  GPtrArray *arr;

  form = list2 (intern ("gi-list-functions"), build_string (ns));
  result = dispatch_safe_eval (form);

  arr = g_ptr_array_new ();
  if (!dispatch_result_is_error (result))
    {
      tail = result;
      while (CONSP (tail))
        {
          Lisp_Object s = XCAR (tail);
          if (STRINGP (s))
            g_ptr_array_add (arr, g_strdup (SSDATA (s)));
          tail = XCDR (tail);
        }
    }
  g_ptr_array_add (arr, NULL);
  return (gchar **)g_ptr_array_free (arr, FALSE);
}

/* ── Gowl dispatch (direct C API, no elisp round-trip) ────────────── */

#ifdef HAVE_CMACS_GOWL

/* gowl.h and extern cmacs_gowl_compositor provided by cmacs-eval-dispatch.h */

#define GOWL_DISPATCH_CHECK()                                       \
  do { if (cmacs_gowl_compositor == NULL) {                         \
    g_set_error (error, CMACS_DISPATCH_ERROR_DOMAIN, 1,             \
                 "Gowl compositor not running");                    \
    return NULL;                                                    \
  }} while (0)

gchar *
cmacs_dispatch_gowl_list_clients (GError **error)
{
  GList *clients, *l;
  GString *buf;

  GOWL_DISPATCH_CHECK ();

  buf = g_string_new ("[");
  clients = gowl_compositor_get_clients (cmacs_gowl_compositor);
  for (l = clients; l != NULL; l = l->next)
    {
      GowlClient *c = GOWL_CLIENT (l->data);
      gint x, y, w, h;
      gowl_client_get_geometry (c, &x, &y, &w, &h);

      if (l != clients) g_string_append_c (buf, ',');
      g_string_append_printf (buf,
        "{\"id\":%u,\"title\":\"%s\",\"app-id\":\"%s\","
        "\"tags\":%u,\"floating\":%s,\"fullscreen\":%s,"
        "\"pid\":%d,\"geometry\":[%d,%d,%d,%d]}",
        gowl_client_get_id (c),
        gowl_client_get_title (c) ? : "",
        gowl_client_get_app_id (c) ? : "",
        (guint)gowl_client_get_tags (c),
        gowl_client_get_floating (c) ? "true" : "false",
        gowl_client_get_fullscreen (c) ? "true" : "false",
        (int)gowl_client_get_pid (c),
        x, y, w, h);
    }
  g_string_append_c (buf, ']');
  return g_string_free (buf, FALSE);
}

gchar *
cmacs_dispatch_gowl_focused_client (GError **error)
{
  GowlClient *c;
  gint x, y, w, h;

  GOWL_DISPATCH_CHECK ();

  c = gowl_compositor_get_focused_client (cmacs_gowl_compositor);
  if (c == NULL)
    return g_strdup ("nil");

  gowl_client_get_geometry (c, &x, &y, &w, &h);
  return g_strdup_printf (
    "{\"id\":%u,\"title\":\"%s\",\"app-id\":\"%s\","
    "\"tags\":%u,\"floating\":%s,\"pid\":%d,"
    "\"geometry\":[%d,%d,%d,%d]}",
    gowl_client_get_id (c),
    gowl_client_get_title (c) ? : "",
    gowl_client_get_app_id (c) ? : "",
    (guint)gowl_client_get_tags (c),
    gowl_client_get_floating (c) ? "true" : "false",
    (int)gowl_client_get_pid (c),
    x, y, w, h);
}

gchar *
cmacs_dispatch_gowl_spawn (const gchar *command, GError **error)
{
  const gchar *socket;
  gchar *env_cmd;
  GError *spawn_err = NULL;

  GOWL_DISPATCH_CHECK ();

  socket = gowl_compositor_get_socket_name (cmacs_gowl_compositor);
  env_cmd = g_strdup_printf ("WAYLAND_DISPLAY=%s %s",
                             socket ? socket : "", command);

  if (!g_spawn_command_line_async (env_cmd, &spawn_err))
    {
      g_free (env_cmd);
      g_propagate_error (error, spawn_err);
      return NULL;
    }

  g_free (env_cmd);
  return g_strdup ("t");
}

gchar *
cmacs_dispatch_gowl_list_monitors (GError **error)
{
  GList *monitors, *l;
  GString *buf;

  GOWL_DISPATCH_CHECK ();

  buf = g_string_new ("[");
  monitors = gowl_compositor_get_monitors (cmacs_gowl_compositor);
  for (l = monitors; l != NULL; l = l->next)
    {
      GowlMonitor *m = GOWL_MONITOR (l->data);
      gint x, y, w, h;
      gowl_monitor_get_geometry (m, &x, &y, &w, &h);

      if (l != monitors) g_string_append_c (buf, ',');
      g_string_append_printf (buf,
        "{\"name\":\"%s\",\"mfact\":%.2f,\"nmaster\":%d,"
        "\"tags\":%u,\"layout\":\"%s\","
        "\"geometry\":[%d,%d,%d,%d]}",
        gowl_monitor_get_name (m) ? : "",
        gowl_monitor_get_mfact (m),
        gowl_monitor_get_nmaster (m),
        (guint)gowl_monitor_get_tags (m),
        gowl_monitor_get_layout_symbol (m) ? : "",
        x, y, w, h);
    }
  g_string_append_c (buf, ']');
  return g_string_free (buf, FALSE);
}

gchar *
cmacs_dispatch_gowl_add_keybind (const gchar *key, gint action,
                                  const gchar *arg, GError **error)
{
  GowlConfig *config;
  guint modifiers, keysym;

  GOWL_DISPATCH_CHECK ();

  config = gowl_compositor_get_config (cmacs_gowl_compositor);
  if (config == NULL)
    {
      g_set_error (error, CMACS_DISPATCH_ERROR_DOMAIN, 1,
                   "No gowl config loaded");
      return NULL;
    }

  if (!gowl_keybind_parse (key, &modifiers, &keysym))
    {
      g_set_error (error, CMACS_DISPATCH_ERROR_DOMAIN, 1,
                   "Invalid key string: %s", key);
      return NULL;
    }

  gowl_config_add_keybind (config, modifiers, keysym, action, arg);
  return g_strdup ("t");
}

gchar *
cmacs_dispatch_gowl_list_keybinds (GError **error)
{
  GowlConfig *config;
  GArray *keybinds;
  GString *buf;
  guint i;

  GOWL_DISPATCH_CHECK ();

  config = gowl_compositor_get_config (cmacs_gowl_compositor);
  if (config == NULL)
    return g_strdup ("[]");

  keybinds = gowl_config_get_keybinds (config);
  buf = g_string_new ("[");
  for (i = 0; i < keybinds->len; i++)
    {
      GowlKeybindEntry *kb = &g_array_index (keybinds, GowlKeybindEntry, i);
      gchar *key_str = gowl_keybind_to_string (kb->modifiers, kb->keysym);

      if (i > 0) g_string_append_c (buf, ',');
      g_string_append_printf (buf,
        "{\"key\":\"%s\",\"action\":%d,\"arg\":\"%s\"}",
        key_str ? key_str : "",
        kb->action,
        kb->arg ? kb->arg : "");
      g_free (key_str);
    }
  g_string_append_c (buf, ']');
  return g_string_free (buf, FALSE);
}

gchar *
cmacs_dispatch_gowl_add_rule (const gchar *app_id, const gchar *title,
                               guint32 tags, gboolean floating,
                               gint monitor, GError **error)
{
  GowlConfig *config;

  GOWL_DISPATCH_CHECK ();

  config = gowl_compositor_get_config (cmacs_gowl_compositor);
  if (config == NULL)
    {
      g_set_error (error, CMACS_DISPATCH_ERROR_DOMAIN, 1,
                   "No gowl config loaded");
      return NULL;
    }

  gowl_config_add_rule (config, app_id, title, tags, floating, monitor);
  return g_strdup ("t");
}

gchar *
cmacs_dispatch_gowl_set_mfact (gdouble mfact, GError **error)
{
  GList *monitors;
  GowlMonitor *mon;

  GOWL_DISPATCH_CHECK ();

  monitors = gowl_compositor_get_monitors (cmacs_gowl_compositor);
  if (monitors == NULL)
    return g_strdup ("nil");

  /* Set on the first (focused) monitor. */
  mon = GOWL_MONITOR (monitors->data);
  gowl_monitor_set_mfact (mon, mfact);
  return g_strdup ("t");
}

gchar *
cmacs_dispatch_gowl_set_nmaster (gint n, GError **error)
{
  GList *monitors;
  GowlMonitor *mon;

  GOWL_DISPATCH_CHECK ();

  monitors = gowl_compositor_get_monitors (cmacs_gowl_compositor);
  if (monitors == NULL)
    return g_strdup ("nil");

  mon = GOWL_MONITOR (monitors->data);
  gowl_monitor_set_nmaster (mon, n);
  return g_strdup ("t");
}

gchar *
cmacs_dispatch_gowl_view_tags (guint32 tagmask, GError **error)
{
  GList *monitors;
  GowlMonitor *mon;

  GOWL_DISPATCH_CHECK ();

  monitors = gowl_compositor_get_monitors (cmacs_gowl_compositor);
  if (monitors == NULL)
    return g_strdup ("nil");

  mon = GOWL_MONITOR (monitors->data);
  gowl_monitor_set_tags (mon, tagmask);
  return g_strdup ("t");
}

gchar *
cmacs_dispatch_gowl_lock (GError **error)
{
  GOWL_DISPATCH_CHECK ();
  gowl_compositor_set_locked (cmacs_gowl_compositor, TRUE);
  return g_strdup ("t");
}

gchar *
cmacs_dispatch_gowl_unlock (GError **error)
{
  GOWL_DISPATCH_CHECK ();
  gowl_compositor_set_locked (cmacs_gowl_compositor, FALSE);
  return g_strdup ("t");
}

gchar *
cmacs_dispatch_gowl_reload_config (GError **error)
{
  GowlConfig *config;

  GOWL_DISPATCH_CHECK ();

  config = gowl_compositor_get_config (cmacs_gowl_compositor);
  if (config != NULL)
    gowl_config_load_yaml_from_search_path (config, NULL);

  return g_strdup ("t");
}

gchar *
cmacs_dispatch_gowl_config_get (const gchar *property, GError **error)
{
  GowlConfig *config;

  GOWL_DISPATCH_CHECK ();

  config = gowl_compositor_get_config (cmacs_gowl_compositor);
  if (config == NULL)
    return g_strdup ("nil");

  if (g_strcmp0 (property, "border-width") == 0)
    return g_strdup_printf ("%d", gowl_config_get_border_width (config));
  if (g_strcmp0 (property, "terminal") == 0)
    return g_strdup (gowl_config_get_terminal (config) ? : "");
  if (g_strcmp0 (property, "mfact") == 0)
    return g_strdup_printf ("%.2f", gowl_config_get_mfact (config));
  if (g_strcmp0 (property, "nmaster") == 0)
    return g_strdup_printf ("%d", gowl_config_get_nmaster (config));
  if (g_strcmp0 (property, "tag-count") == 0)
    return g_strdup_printf ("%d", gowl_config_get_tag_count (config));

  g_set_error (error, CMACS_DISPATCH_ERROR_DOMAIN, 1,
               "Unknown config property: %s", property);
  return NULL;
}

gchar *
cmacs_dispatch_gowl_find_client (const gchar *pattern, const gchar *by,
                                  GError **error)
{
  GowlClient *c;
  gint x, y, w, h;

  GOWL_DISPATCH_CHECK ();

  if (g_strcmp0 (by, "title") == 0)
    c = gowl_compositor_find_client_by_title (cmacs_gowl_compositor,
                                               pattern);
  else
    c = gowl_compositor_find_client_by_app_id (cmacs_gowl_compositor,
                                                pattern);

  if (c == NULL)
    return g_strdup ("nil");

  gowl_client_get_geometry (c, &x, &y, &w, &h);
  return g_strdup_printf (
    "{\"id\":%u,\"title\":\"%s\",\"app-id\":\"%s\","
    "\"tags\":%u,\"geometry\":[%d,%d,%d,%d]}",
    gowl_client_get_id (c),
    gowl_client_get_title (c) ? : "",
    gowl_client_get_app_id (c) ? : "",
    (guint)gowl_client_get_tags (c),
    x, y, w, h);
}

#endif /* HAVE_CMACS_GOWL */

#endif /* HAVE_CMACS_GLIB */
