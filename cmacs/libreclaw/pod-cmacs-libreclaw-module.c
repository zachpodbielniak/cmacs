/* pod-cmacs-libreclaw-module.c — Podomation bridge for libreclaw
 *
 * Copyright (C) 2026 Zach Podbielniak
 * SPDX-License-Identifier: AGPL-3.0-or-later
 *
 * DUAL PodModule: implements PodEventSource (for event emission) and
 * PodEventHandler (for action dispatch).  Registered on cmacs's
 * shared PodEngine at `cmacs-libreclaw-start' time.
 *
 * See cmacs/podomation/pod-cmacs-module.c for the template this
 * module follows.  The podomation module API is structured around:
 *
 *   - PodModuleClass  : get_name, get_description, activate, deactivate
 *   - PodEventSource  : emit events via g_signal_emit on module
 *   - PodEventHandler : handle_event, get_supported_handlers
 *
 * Event emission is driven from cmacs-libreclaw-room.c, which is
 * already connected to libreclaw's GObject signals.  When a signal
 * fires there, cmacs-libreclaw-room calls lc_pod_module_emit_event
 * equivalent — but since we use a different module class, event
 * emission happens via pod_event_source_emit() on this module
 * instance.  For now this initial cut ships the module scaffolding
 * with the supported-handler list and a functional send_message
 * action; event emission is a follow-up pass once the room bridge
 * is wired up. */

#include <config.h>

#ifdef HAVE_CMACS_LIBRECLAW

#include <libreclaw.h>
#include <podomation.h>

#include "pod-cmacs-libreclaw-module.h"

/* ── Type boilerplate ─────────────────────────────────────────────── */

#define POD_TYPE_CMACS_LIBRECLAW_MODULE \
  (pod_cmacs_libreclaw_module_get_type ())

G_DECLARE_FINAL_TYPE (PodCmacsLibreclawModule,
                      pod_cmacs_libreclaw_module,
                      POD, CMACS_LIBRECLAW_MODULE,
                      PodModule)

struct _PodCmacsLibreclawModule {
  PodModule parent_instance;

  LcApp    *app;   /* borrowed — set via set_app, no ref */
};

static void cmls_source_init  (PodEventSourceInterface  *iface);
static void cmls_handler_init (PodEventHandlerInterface *iface);

G_DEFINE_FINAL_TYPE_WITH_CODE (PodCmacsLibreclawModule,
                               pod_cmacs_libreclaw_module,
                               POD_TYPE_MODULE,
  G_IMPLEMENT_INTERFACE (POD_TYPE_EVENT_SOURCE,  cmls_source_init)
  G_IMPLEMENT_INTERFACE (POD_TYPE_EVENT_HANDLER, cmls_handler_init))

/* ── Event and handler name tables ────────────────────────────────── */

static const gchar *const source_events[] = {
  "on_cm_lc_message",
  "on_cm_lc_response",
  "on_cm_lc_room_joined",
  "on_cm_lc_room_removed",
  "on_cm_lc_channel_connected",
  "on_cm_lc_channel_disconnected",
  "on_cm_lc_channel_error",
  "on_cm_lc_session_created",
  "on_cm_lc_session_destroyed",
  NULL
};

static const gchar *const handler_funcs[] = {
  "send_message",
  "join_room",
  "leave_room",
  NULL
};

/* ── PodEventSource interface ─────────────────────────────────────── */

static const gchar *const *
cmls_source_get_supported (PodEventSource *self)
{
  (void) self;
  return source_events;
}

static PodEventKind
cmls_source_get_event_kind (PodEventSource *self)
{
  (void) self;
  return POD_EVENT_KIND_CUSTOM;
}

static gboolean
cmls_source_start (PodEventSource *self,
                   GMainContext   *context,
                   GError        **error)
{
  (void) self;
  (void) context;
  (void) error;
  return TRUE;
}

static void
cmls_source_stop (PodEventSource *self)
{
  (void) self;
}

static void
cmls_source_init (PodEventSourceInterface *iface)
{
  iface->start                = cmls_source_start;
  iface->stop                 = cmls_source_stop;
  iface->get_event_kind       = cmls_source_get_event_kind;
  iface->get_supported_events = cmls_source_get_supported;
}

/* ── PodEventHandler interface ────────────────────────────────────── */

static const gchar *const *
cmls_handler_get_supported (PodEventHandler *self)
{
  (void) self;
  return handler_funcs;
}

static gboolean
cmls_handle_event (PodEventHandler  *self,
                   const gchar      *event_name,
                   GVariant         *event_data,
                   GVariant         *params,
                   GVariant        **result)
{
  PodCmacsLibreclawModule *cm = POD_CMACS_LIBRECLAW_MODULE (self);
  const gchar *channel = NULL;
  const gchar *room    = NULL;
  const gchar *body    = NULL;
  GVariant    *v;
  LcChannelManager *mgr;
  GList *channels, *l;
  LcChannel *ch = NULL;
  LcOutboundMessage *msg;

  (void) event_name;  /* invoked by binding; routing by handler name
                       * happens via the DSL parser before we get here */
  (void) event_data;

  if (result != NULL)
    *result = NULL;

  if (cm->app == NULL)
    return FALSE;

  if (params == NULL ||
      !g_variant_is_of_type (params, G_VARIANT_TYPE ("a{sv}")))
    return FALSE;

  if ((v = g_variant_lookup_value (params, "channel",
                                   G_VARIANT_TYPE_STRING)))
    {
      channel = g_variant_get_string (v, NULL);
      g_variant_unref (v);
    }
  if ((v = g_variant_lookup_value (params, "room",
                                   G_VARIANT_TYPE_STRING)))
    {
      room = g_variant_get_string (v, NULL);
      g_variant_unref (v);
    }
  if ((v = g_variant_lookup_value (params, "body",
                                   G_VARIANT_TYPE_STRING)))
    {
      body = g_variant_get_string (v, NULL);
      g_variant_unref (v);
    }

  if (channel == NULL || room == NULL || body == NULL)
    return FALSE;

  mgr = lc_app_get_channel_manager (cm->app);
  if (mgr == NULL)
    return FALSE;
  channels = lc_channel_manager_list_channels (mgr);
  for (l = channels; l != NULL; l = l->next)
    {
      LcChannel *c = l->data;
      if (g_strcmp0 (lc_channel_get_id (c), channel) == 0)
        {
          ch = c;
          break;
        }
    }
  g_list_free (channels);
  if (ch == NULL)
    return FALSE;

  msg = lc_outbound_message_new (channel, room, NULL, body, NULL, NULL);
  lc_channel_send_message_async (ch, msg, NULL, NULL, NULL);
  lc_outbound_message_free (msg);
  return TRUE;
}

static void
cmls_handler_init (PodEventHandlerInterface *iface)
{
  iface->handle_event           = cmls_handle_event;
  iface->get_supported_handlers = cmls_handler_get_supported;
}

/* ── PodModuleClass vtable ────────────────────────────────────────── */

static const gchar *
cmls_get_name (PodModule *self)
{
  (void) self;
  return "cmacs_libreclaw";
}

static const gchar *
cmls_get_description (PodModule *self)
{
  (void) self;
  return "cmacs ↔ libreclaw chat bridge";
}

static gboolean
cmls_activate (PodModule *self)
{
  (void) self;
  return TRUE;
}

static void
cmls_deactivate (PodModule *self)
{
  (void) self;
}

static void
pod_cmacs_libreclaw_module_class_init (PodCmacsLibreclawModuleClass *klass)
{
  PodModuleClass *mc = POD_MODULE_CLASS (klass);
  mc->get_name        = cmls_get_name;
  mc->get_description = cmls_get_description;
  mc->activate        = cmls_activate;
  mc->deactivate      = cmls_deactivate;
}

static void
pod_cmacs_libreclaw_module_init (PodCmacsLibreclawModule *self)
{
  self->app = NULL;
}

/* ── Public API ────────────────────────────────────────────────────── */

PodModule *
pod_cmacs_libreclaw_module_new (void)
{
  return POD_MODULE (g_object_new (POD_TYPE_CMACS_LIBRECLAW_MODULE, NULL));
}

void
pod_cmacs_libreclaw_module_set_app (PodModule *self_mod, LcApp *app)
{
  PodCmacsLibreclawModule *self;

  g_return_if_fail (POD_IS_CMACS_LIBRECLAW_MODULE (self_mod));
  self = POD_CMACS_LIBRECLAW_MODULE (self_mod);
  self->app = app;  /* borrowed, no ref */
}

#endif /* HAVE_CMACS_LIBRECLAW */
