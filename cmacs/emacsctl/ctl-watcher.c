/*
 * Copyright (C) 2026 Zach Podbielniak
 * SPDX-License-Identifier: AGPL-3.0-or-later
 */

/* ctl-watcher.c --- see ctl-watcher.h. */

#include "ctl-watcher.h"

#include <string.h>

struct _CtlWatcher
{
  GObject parent_instance;

  CtlTransport *transport;    /* owned */
  GMainLoop *loop;
  GArray *subscription_ids;   /* of guint */

  CtlWatcherPollFunc poll;
  gpointer poll_user_data;
  guint poll_interval_ms;
  guint poll_source_id;
  gchar *last_poll_rendering;
};

enum
{
  SIGNAL_EVENT,
  N_SIGNALS
};

static guint signals[N_SIGNALS] = { 0 };

G_DEFINE_FINAL_TYPE (CtlWatcher, ctl_watcher, G_TYPE_OBJECT)

static void
ctl_watcher_finalize (GObject *object)
{
  CtlWatcher *self = CTL_WATCHER (object);
  guint k;

  for (k = 0; k < self->subscription_ids->len; k++)
    ctl_transport_unsubscribe (
      self->transport, g_array_index (self->subscription_ids, guint, k));
  g_array_unref (self->subscription_ids);
  if (self->poll_source_id != 0)
    g_source_remove (self->poll_source_id);
  if (self->loop != NULL)
    g_main_loop_unref (self->loop);
  g_free (self->last_poll_rendering);
  g_clear_object (&self->transport);
  G_OBJECT_CLASS (ctl_watcher_parent_class)->finalize (object);
}

static void
ctl_watcher_class_init (CtlWatcherClass *klass)
{
  G_OBJECT_CLASS (klass)->finalize = ctl_watcher_finalize;

  /* CtlWatcher::event --- one streamed update, as a CtlResult. */
  signals[SIGNAL_EVENT] = g_signal_new (
    "event", CTL_TYPE_WATCHER, G_SIGNAL_RUN_LAST,
    0, NULL, NULL, NULL, G_TYPE_NONE, 1, CTL_TYPE_RESULT);
}

static void
ctl_watcher_init (CtlWatcher *self)
{
  self->subscription_ids = g_array_new (FALSE, TRUE, sizeof (guint));
  self->loop = g_main_loop_new (NULL, FALSE);
}

CtlWatcher *
ctl_watcher_new (CtlTransport *transport)
{
  CtlWatcher *self = g_object_new (CTL_TYPE_WATCHER, NULL);
  self->transport = g_object_ref (transport);
  g_signal_connect_swapped (transport, "closed",
                            G_CALLBACK (g_main_loop_quit), self->loop);
  return self;
}

static void
watcher_on_signal (CtlTransport *transport, const gchar *iface,
                   const gchar *signal_name, GVariant *args,
                   gpointer user_data)
{
  CtlWatcher *self = user_data;
  CtlResult *result;

  (void) transport; (void) iface; (void) signal_name;

  /* Single-string signals (MessageLogged, BufferAdded, ...) stream as
   * their payload; anything else as the printed tuple. */
  if (args != NULL
      && g_variant_is_of_type (args, G_VARIANT_TYPE ("(s)")))
    {
      const gchar *s;
      g_variant_get (args, "(&s)", &s);
      result = ctl_result_new_scalar (s);
    }
  else if (args != NULL)
    {
      gchar *printed = g_variant_print (args, FALSE);
      result = ctl_result_new_scalar (printed);
      g_free (printed);
    }
  else
    result = ctl_result_new_scalar ("");

  g_signal_emit (self, signals[SIGNAL_EVENT], 0, result);
  ctl_result_unref (result);
}

void
ctl_watcher_add_signal (CtlWatcher *self, const gchar *iface,
                        const gchar *signal_name)
{
  guint id = ctl_transport_subscribe (self->transport, iface,
                                      signal_name, watcher_on_signal,
                                      self, NULL);
  g_array_append_val (self->subscription_ids, id);
}

static gboolean
watcher_poll_tick (gpointer user_data)
{
  CtlWatcher *self = user_data;
  GError *error = NULL;
  CtlResult *result =
    self->poll (self->transport, self->poll_user_data, &error);
  JsonNode *node;
  JsonGenerator *gen;
  gchar *rendering;

  if (result == NULL)
    {
      g_clear_error (&error);
      return G_SOURCE_CONTINUE;
    }

  /* Only emit when the canonical rendering changed. */
  node = ctl_result_to_json_node (result);
  gen = json_generator_new ();
  json_generator_set_root (gen, node);
  rendering = json_generator_to_data (gen, NULL);
  g_object_unref (gen);
  json_node_unref (node);

  if (g_strcmp0 (rendering, self->last_poll_rendering) != 0)
    {
      g_free (self->last_poll_rendering);
      self->last_poll_rendering = rendering;
      g_signal_emit (self, signals[SIGNAL_EVENT], 0, result);
    }
  else
    g_free (rendering);

  ctl_result_unref (result);
  return G_SOURCE_CONTINUE;
}

void
ctl_watcher_set_poll (CtlWatcher *self, guint interval_ms,
                      CtlWatcherPollFunc poll, gpointer user_data)
{
  self->poll = poll;
  self->poll_user_data = user_data;
  self->poll_interval_ms = interval_ms;
}

void
ctl_watcher_run (CtlWatcher *self)
{
  if (self->poll != NULL)
    {
      /* Fire once immediately, then on the interval. */
      watcher_poll_tick (self);
      self->poll_source_id = g_timeout_add (self->poll_interval_ms,
                                            watcher_poll_tick, self);
    }
  g_main_loop_run (self->loop);
}
