/*
 * Copyright (C) 2026 Zach Podbielniak
 * SPDX-License-Identifier: AGPL-3.0-or-later
 */

/* ctl-formatter.c --- CtlFormatter interface + factory. */

#include "ctl-formatter.h"

G_DEFINE_INTERFACE (CtlFormatter, ctl_formatter, G_TYPE_OBJECT)

static void
ctl_formatter_default_init (CtlFormatterInterface *iface)
{
  (void) iface;
}

gboolean
ctl_formatter_emit (CtlFormatter *self, CtlResult *result, FILE *out,
                    GError **error)
{
  g_return_val_if_fail (CTL_IS_FORMATTER (self), FALSE);
  return CTL_FORMATTER_GET_IFACE (self)->emit (self, result, out, error);
}

/* Implementation GTypes, defined in ctl-formatter-*.c. */
GType ctl_table_formatter_get_type (void);
GType ctl_json_formatter_get_type  (void);
GType ctl_yaml_formatter_get_type  (void);
GType ctl_raw_formatter_get_type   (void);

CtlFormatter *
ctl_formatter_for_name (const gchar *name)
{
  if (name == NULL || g_strcmp0 (name, "table") == 0)
    return g_object_new (ctl_table_formatter_get_type (), NULL);
  if (g_strcmp0 (name, "json") == 0)
    return g_object_new (ctl_json_formatter_get_type (), NULL);
  if (g_strcmp0 (name, "yaml") == 0)
    return g_object_new (ctl_yaml_formatter_get_type (), NULL);
  if (g_strcmp0 (name, "raw") == 0)
    return g_object_new (ctl_raw_formatter_get_type (), NULL);
  return NULL;
}
