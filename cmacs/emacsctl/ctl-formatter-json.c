/*
 * Copyright (C) 2026 Zach Podbielniak
 * SPDX-License-Identifier: AGPL-3.0-or-later
 */

/* ctl-formatter-json.c --- -o json.  Pretty-printed (indent 2). */

#include "ctl-formatter.h"

#define CTL_TYPE_JSON_FORMATTER (ctl_json_formatter_get_type ())
G_DECLARE_FINAL_TYPE (CtlJsonFormatter, ctl_json_formatter,
                      CTL, JSON_FORMATTER, GObject)

struct _CtlJsonFormatter
{
  GObject parent_instance;
};

static void ctl_json_formatter_formatter_init (CtlFormatterInterface *iface);

G_DEFINE_TYPE_WITH_CODE (CtlJsonFormatter, ctl_json_formatter,
                         G_TYPE_OBJECT,
                         G_IMPLEMENT_INTERFACE (CTL_TYPE_FORMATTER,
                           ctl_json_formatter_formatter_init))

static gboolean
json_emit (CtlFormatter *self, CtlResult *result, FILE *out,
           GError **error)
{
  JsonNode *node = ctl_result_to_json_node (result);
  JsonGenerator *gen = json_generator_new ();
  gchar *data;

  (void) self; (void) error;

  json_generator_set_root (gen, node);
  json_generator_set_pretty (gen, TRUE);
  json_generator_set_indent (gen, 2);
  data = json_generator_to_data (gen, NULL);
  fprintf (out, "%s\n", data);
  g_free (data);
  g_object_unref (gen);
  json_node_unref (node);
  return TRUE;
}

static void
ctl_json_formatter_formatter_init (CtlFormatterInterface *iface)
{
  iface->emit = json_emit;
}

static void
ctl_json_formatter_class_init (CtlJsonFormatterClass *klass)
{
  (void) klass;
}

static void
ctl_json_formatter_init (CtlJsonFormatter *self)
{
  (void) self;
}
