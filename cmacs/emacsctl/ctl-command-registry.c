/*
 * Copyright (C) 2026 Zach Podbielniak
 * SPDX-License-Identifier: AGPL-3.0-or-later
 */

/* ctl-command-registry.c --- see ctl-command-registry.h. */

#include "ctl-command-registry.h"

struct _CtlCommandRegistry
{
  GObject parent_instance;

  GHashTable *by_name;        /* name -> CtlCommand (owned by ordered) */
  GPtrArray  *ordered;        /* of CtlCommand, owns refs */
};

enum
{
  SIGNAL_COMMAND_ADDED,
  N_SIGNALS
};

static guint signals[N_SIGNALS] = { 0 };

G_DEFINE_FINAL_TYPE (CtlCommandRegistry, ctl_command_registry,
                     G_TYPE_OBJECT)

static void
ctl_command_registry_finalize (GObject *object)
{
  CtlCommandRegistry *self = CTL_COMMAND_REGISTRY (object);
  g_hash_table_unref (self->by_name);
  g_ptr_array_unref (self->ordered);
  G_OBJECT_CLASS (ctl_command_registry_parent_class)->finalize (object);
}

static void
ctl_command_registry_class_init (CtlCommandRegistryClass *klass)
{
  G_OBJECT_CLASS (klass)->finalize = ctl_command_registry_finalize;

  /* CtlCommandRegistry::command-added --- completion generation and
   * future plugin systems listen for new verbs. */
  signals[SIGNAL_COMMAND_ADDED] = g_signal_new (
    "command-added", CTL_TYPE_COMMAND_REGISTRY, G_SIGNAL_RUN_LAST,
    0, NULL, NULL, NULL, G_TYPE_NONE, 1, CTL_TYPE_COMMAND);
}

static void
ctl_command_registry_init (CtlCommandRegistry *self)
{
  self->by_name = g_hash_table_new (g_str_hash, g_str_equal);
  self->ordered = g_ptr_array_new_with_free_func (g_object_unref);
}

CtlCommandRegistry *
ctl_command_registry_new (void)
{
  return g_object_new (CTL_TYPE_COMMAND_REGISTRY, NULL);
}

void
ctl_command_registry_add (CtlCommandRegistry *self, CtlCommand *command)
{
  g_ptr_array_add (self->ordered, command);
  g_hash_table_insert (self->by_name,
                       (gpointer) ctl_command_get_name (command),
                       command);
  g_signal_emit (self, signals[SIGNAL_COMMAND_ADDED], 0, command);
}

CtlCommand *
ctl_command_registry_lookup (CtlCommandRegistry *self, gchar **argv,
                             gint argc, gint *consumed)
{
  CtlCommand *cmd;

  if (argc >= 2)
    {
      gchar *two = g_strdup_printf ("%s %s", argv[0], argv[1]);
      cmd = g_hash_table_lookup (self->by_name, two);
      g_free (two);
      if (cmd != NULL)
        {
          if (consumed != NULL)
            *consumed = 2;
          return cmd;
        }
    }
  if (argc >= 1)
    {
      cmd = g_hash_table_lookup (self->by_name, argv[0]);
      if (cmd != NULL)
        {
          if (consumed != NULL)
            *consumed = 1;
          return cmd;
        }
    }
  if (consumed != NULL)
    *consumed = 0;
  return NULL;
}

CtlCommand *
ctl_command_registry_get (CtlCommandRegistry *self, const gchar *name)
{
  return g_hash_table_lookup (self->by_name, name);
}

guint
ctl_command_registry_get_n_commands (CtlCommandRegistry *self)
{
  return self->ordered->len;
}

CtlCommand *
ctl_command_registry_get_nth (CtlCommandRegistry *self, guint idx)
{
  return g_ptr_array_index (self->ordered, idx);
}
