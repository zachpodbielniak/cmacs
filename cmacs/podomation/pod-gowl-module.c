/* pod-gowl-module.c — Gowl PodModule for compositor automation
 *
 * Copyright (C) 2026 Zach Podbielniak
 * SPDX-License-Identifier: AGPL-3.0-or-later
 *
 * DUAL PodModule: compositor events as PodEventSource, compositor
 * commands as PodEventHandler (mirroring the gowl DEFUNs).
 *
 * Handler calls go directly to the cmacs_dispatch_gowl_* functions
 * in cmacs-eval-dispatch.c — no Lisp eval, no idle dispatch needed.
 */

#include <config.h>

#if defined (HAVE_CMACS_PODOMATION) && defined (HAVE_CMACS_GOWL)

#include "pod-gowl-module.h"
#include "lisp.h"
#include "cmacs-eval-dispatch.h"
#include <gowl.h>

/* ── Instance struct ───────────────────────────────────────────────── */

struct _PodGowlModule
{
  PodModule parent_instance;
  gboolean  started;
  gulong    sig_client_added;
  gulong    sig_client_removed;
  gulong    sig_focus_changed;
};

/* ── Supported names ───────────────────────────────────────────────── */

static const gchar *source_events[] = {
  "on_client_map",
  "on_client_unmap",
  "on_focus_change",
  "on_tag_change",
  NULL
};

static const gchar *handler_funcs[] = {
  "list_clients",
  "focused_client",
  "find_client",
  "spawn",
  "list_monitors",
  "monitor_info",
  "monitor_modes",
  "set_monitor_mode",
  "set_monitor_position",
  "set_monitor_enabled",
  "set_monitor_scale",
  "set_monitor_transform",
  "view_tags",
  "set_mfact",
  "set_nmaster",
  "set_layout",
  "add_keybind",
  "list_keybinds",
  "add_rule",
  "list_rules",
  "lock",
  "unlock",
  "reload_config",
  "config_get",
  NULL
};

/* ── Signal callbacks ──────────────────────────────────────────────── */

/* Build an a{sv} GVariant with client metadata. */
static GVariant *
make_client_data (GowlClient *client)
{
  GVariantBuilder b;
  gchar id_buf[32];

  g_variant_builder_init (&b, G_VARIANT_TYPE ("a{sv}"));
  g_variant_builder_add (&b, "{sv}", "app_id",
			 g_variant_new_string (
			   gowl_client_get_app_id (client)
			     ? gowl_client_get_app_id (client) : ""));
  g_variant_builder_add (&b, "{sv}", "title",
			 g_variant_new_string (
			   gowl_client_get_title (client)
			     ? gowl_client_get_title (client) : ""));
  g_snprintf (id_buf, sizeof id_buf, "%u",
	      gowl_client_get_id (client));
  g_variant_builder_add (&b, "{sv}", "client_id",
			 g_variant_new_string (id_buf));
  return g_variant_builder_end (&b);
}

static void
on_client_added (GowlCompositor *compositor, GowlClient *client,
		 gpointer user_data)
{
  PodGowlModule *mod = POD_GOWL_MODULE (user_data);
  GVariant *data;

  (void) compositor;
  if (!mod->started)
    return;

  data = make_client_data (client);
  g_signal_emit_by_name (mod, "event-fired", "on_client_map", data);
  g_variant_unref (data);
}

static void
on_client_removed (GowlCompositor *compositor, GowlClient *client,
		   gpointer user_data)
{
  PodGowlModule *mod = POD_GOWL_MODULE (user_data);
  GVariant *data;

  (void) compositor;
  if (!mod->started)
    return;

  data = make_client_data (client);
  g_signal_emit_by_name (mod, "event-fired", "on_client_unmap", data);
  g_variant_unref (data);
}

static void
on_focus_changed (GowlCompositor *compositor, GowlClient *client,
		  gpointer user_data)
{
  PodGowlModule *mod = POD_GOWL_MODULE (user_data);
  GVariant *data;

  (void) compositor;
  if (!mod->started)
    return;

  if (client != NULL)
    data = make_client_data (client);
  else
    {
      GVariantBuilder b;
      g_variant_builder_init (&b, G_VARIANT_TYPE ("a{sv}"));
      g_variant_builder_add (&b, "{sv}", "app_id",
			     g_variant_new_string (""));
      g_variant_builder_add (&b, "{sv}", "title",
			     g_variant_new_string (""));
      g_variant_builder_add (&b, "{sv}", "client_id",
			     g_variant_new_string (""));
      data = g_variant_builder_end (&b);
    }

  g_signal_emit_by_name (mod, "event-fired", "on_focus_change", data);
  g_variant_unref (data);
}

/* ── PodEventSource interface ──────────────────────────────────────── */

static gboolean
gowl_source_start (PodEventSource *self, GMainContext *context,
		   GError **error)
{
  PodGowlModule *mod = POD_GOWL_MODULE (self);
  (void) context;
  (void) error;

  if (cmacs_gowl_compositor != NULL)
    {
      mod->sig_client_added =
	g_signal_connect (cmacs_gowl_compositor, "client-added",
			  G_CALLBACK (on_client_added), mod);
      mod->sig_client_removed =
	g_signal_connect (cmacs_gowl_compositor, "client-removed",
			  G_CALLBACK (on_client_removed), mod);
      mod->sig_focus_changed =
	g_signal_connect (cmacs_gowl_compositor, "focus-changed",
			  G_CALLBACK (on_focus_changed), mod);
    }

  mod->started = TRUE;
  return TRUE;
}

static void
gowl_source_stop (PodEventSource *self)
{
  PodGowlModule *mod = POD_GOWL_MODULE (self);

  if (cmacs_gowl_compositor != NULL)
    {
      if (mod->sig_client_added > 0)
	g_signal_handler_disconnect (cmacs_gowl_compositor,
				     mod->sig_client_added);
      if (mod->sig_client_removed > 0)
	g_signal_handler_disconnect (cmacs_gowl_compositor,
				     mod->sig_client_removed);
      if (mod->sig_focus_changed > 0)
	g_signal_handler_disconnect (cmacs_gowl_compositor,
				     mod->sig_focus_changed);
    }

  mod->sig_client_added = 0;
  mod->sig_client_removed = 0;
  mod->sig_focus_changed = 0;
  mod->started = FALSE;
}

static PodEventKind
gowl_source_get_event_kind (PodEventSource *self)
{
  (void) self;
  return POD_EVENT_KIND_CUSTOM;
}

static const gchar *const *
gowl_source_get_supported_events (PodEventSource *self)
{
  (void) self;
  return source_events;
}

static void
gowl_source_init (PodEventSourceInterface *iface)
{
  iface->start                = gowl_source_start;
  iface->stop                 = gowl_source_stop;
  iface->get_event_kind       = gowl_source_get_event_kind;
  iface->get_supported_events = gowl_source_get_supported_events;
}

/* ── Handler helpers ───────────────────────────────────────────────── */

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

/* Build an a{sv} result with a single "value" key. */
static GVariant *
make_string_result (const gchar *value)
{
  GVariantBuilder rb;
  g_variant_builder_init (&rb, G_VARIANT_TYPE ("a{sv}"));
  g_variant_builder_add (&rb, "{sv}", "value",
			 g_variant_new_string (value ? value : ""));
  return g_variant_builder_end (&rb);
}

/* ── PodEventHandler interface ─────────────────────────────────────── */

static gboolean
gowl_handle_event (PodEventHandler *handler,
		   const gchar     *event_name,
		   GVariant        *event_data,
		   GVariant        *params,
		   GVariant       **result)
{
  GError *error = NULL;
  gchar *res = NULL;

  (void) handler;
  (void) event_data;

  if (result != NULL)
    *result = NULL;

  if (g_strcmp0 (event_name, "list_clients") == 0)
    {
      res = cmacs_dispatch_gowl_list_clients (&error);
    }
  else if (g_strcmp0 (event_name, "focused_client") == 0)
    {
      res = cmacs_dispatch_gowl_focused_client (&error);
    }
  else if (g_strcmp0 (event_name, "find_client") == 0)
    {
      const gchar *pattern = get_param_string (params, 0);
      const gchar *by = get_param_string (params, 1);
      if (pattern == NULL)
	return FALSE;
      res = cmacs_dispatch_gowl_find_client (pattern,
					     by ? by : "app-id",
					     &error);
    }
  else if (g_strcmp0 (event_name, "spawn") == 0)
    {
      const gchar *cmd = get_param_string (params, 0);
      if (cmd == NULL)
	return FALSE;
      res = cmacs_dispatch_gowl_spawn (cmd, &error);
    }
  else if (g_strcmp0 (event_name, "list_monitors") == 0)
    {
      res = cmacs_dispatch_gowl_list_monitors (&error);
    }
  else if (g_strcmp0 (event_name, "monitor_info") == 0)
    {
      const gchar *name = get_param_string (params, 0);
      if (name == NULL)
	return FALSE;
      res = cmacs_dispatch_gowl_monitor_info (name, &error);
    }
  else if (g_strcmp0 (event_name, "monitor_modes") == 0)
    {
      const gchar *name = get_param_string (params, 0);
      if (name == NULL)
	return FALSE;
      res = cmacs_dispatch_gowl_monitor_modes (name, &error);
    }
  else if (g_strcmp0 (event_name, "view_tags") == 0)
    {
      const gchar *tags_str = get_param_string (params, 0);
      if (tags_str == NULL)
	return FALSE;
      guint32 tagmask = (guint32) g_ascii_strtoull (tags_str, NULL, 10);
      res = cmacs_dispatch_gowl_view_tags (tagmask, &error);
    }
  else if (g_strcmp0 (event_name, "set_mfact") == 0)
    {
      const gchar *mf = get_param_string (params, 0);
      if (mf == NULL)
	return FALSE;
      res = cmacs_dispatch_gowl_set_mfact (g_ascii_strtod (mf, NULL),
					   &error);
    }
  else if (g_strcmp0 (event_name, "set_nmaster") == 0)
    {
      const gchar *n = get_param_string (params, 0);
      if (n == NULL)
	return FALSE;
      res = cmacs_dispatch_gowl_set_nmaster (
	      (gint) g_ascii_strtoll (n, NULL, 10), &error);
    }
  else if (g_strcmp0 (event_name, "add_keybind") == 0)
    {
      const gchar *key = get_param_string (params, 0);
      const gchar *action_str = get_param_string (params, 1);
      const gchar *arg = get_param_string (params, 2);
      /* Optional fourth positional param: the bind's description.
	 Absent in every rule written before it existed, which
	 get_param_string reports as NULL. */
      const gchar *desc = get_param_string (params, 3);
      if (key == NULL || action_str == NULL)
	return FALSE;
      gint action = (gint) g_ascii_strtoll (action_str, NULL, 10);
      res = cmacs_dispatch_gowl_add_keybind (key, action,
					     arg ? arg : "", desc, &error);
    }
  else if (g_strcmp0 (event_name, "list_keybinds") == 0)
    {
      res = cmacs_dispatch_gowl_list_keybinds (&error);
    }
  else if (g_strcmp0 (event_name, "lock") == 0)
    {
      res = cmacs_dispatch_gowl_lock (&error);
    }
  else if (g_strcmp0 (event_name, "unlock") == 0)
    {
      res = cmacs_dispatch_gowl_unlock (&error);
    }
  else if (g_strcmp0 (event_name, "reload_config") == 0)
    {
      res = cmacs_dispatch_gowl_reload_config (&error);
    }
  else if (g_strcmp0 (event_name, "config_get") == 0)
    {
      const gchar *prop = get_param_string (params, 0);
      if (prop == NULL)
	return FALSE;
      res = cmacs_dispatch_gowl_config_get (prop, &error);
    }
  else
    {
      return FALSE;
    }

  if (error != NULL)
    {
      g_free (res);
      g_error_free (error);
      return FALSE;
    }

  if (result != NULL && res != NULL)
    *result = make_string_result (res);
  g_free (res);
  return TRUE;
}

static const gchar *const *
gowl_handler_get_supported (PodEventHandler *self)
{
  (void) self;
  return handler_funcs;
}

static void
gowl_handler_init (PodEventHandlerInterface *iface)
{
  iface->handle_event           = gowl_handle_event;
  iface->get_supported_handlers = gowl_handler_get_supported;
}

/* ── GObject boilerplate ───────────────────────────────────────────── */

G_DEFINE_FINAL_TYPE_WITH_CODE (PodGowlModule, pod_gowl_module,
			       POD_TYPE_MODULE,
  G_IMPLEMENT_INTERFACE (POD_TYPE_EVENT_SOURCE, gowl_source_init)
  G_IMPLEMENT_INTERFACE (POD_TYPE_EVENT_HANDLER, gowl_handler_init))

static const gchar *
gowl_get_name (PodModule *self)
{
  (void) self;
  return "gowl";
}

static const gchar *
gowl_get_description (PodModule *self)
{
  (void) self;
  return "Gowl Wayland compositor automation";
}

static gboolean
gowl_activate (PodModule *self)
{
  (void) self;
  return TRUE;
}

static void
gowl_deactivate (PodModule *self)
{
  gowl_source_stop (POD_EVENT_SOURCE (self));
}

static void
pod_gowl_module_class_init (PodGowlModuleClass *klass)
{
  PodModuleClass *mc = POD_MODULE_CLASS (klass);
  mc->get_name        = gowl_get_name;
  mc->get_description = gowl_get_description;
  mc->activate        = gowl_activate;
  mc->deactivate      = gowl_deactivate;
}

static void
pod_gowl_module_init (PodGowlModule *self)
{
  self->started = FALSE;
  self->sig_client_added = 0;
  self->sig_client_removed = 0;
  self->sig_focus_changed = 0;
}

PodModule *
pod_gowl_module_new (void)
{
  return g_object_new (POD_TYPE_GOWL_MODULE, NULL);
}

#endif /* HAVE_CMACS_PODOMATION && HAVE_CMACS_GOWL */
