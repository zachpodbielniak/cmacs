/*
 * Copyright (C) 2026 Zach Podbielniak
 * SPDX-License-Identifier: AGPL-3.0-or-later
 */

/* ctl-formatter-yaml.c --- -o yaml, via yaml-glib. */

#include "ctl-formatter.h"
#include "ctl-json-yaml.h"

#define CTL_TYPE_YAML_FORMATTER (ctl_yaml_formatter_get_type ())
G_DECLARE_FINAL_TYPE (CtlYamlFormatter, ctl_yaml_formatter,
                      CTL, YAML_FORMATTER, GObject)

struct _CtlYamlFormatter
{
  GObject parent_instance;
};

static void ctl_yaml_formatter_formatter_init (CtlFormatterInterface *iface);

G_DEFINE_TYPE_WITH_CODE (CtlYamlFormatter, ctl_yaml_formatter,
                         G_TYPE_OBJECT,
                         G_IMPLEMENT_INTERFACE (CTL_TYPE_FORMATTER,
                           ctl_yaml_formatter_formatter_init))

static gboolean
yaml_emit (CtlFormatter *self, CtlResult *result, FILE *out,
           GError **error)
{
  JsonNode *json = ctl_result_to_json_node (result);
  YamlNode *yaml = ctl_json_to_yaml (json);
  YamlGenerator *gen = yaml_generator_new ();
  gchar *data;
  gsize len = 0;

  (void) self;

  yaml_generator_set_root (gen, yaml);
  data = yaml_generator_to_data (gen, &len, error);
  if (data == NULL)
    {
      g_object_unref (gen);
      yaml_node_unref (yaml);
      json_node_unref (json);
      return FALSE;
    }
  fwrite (data, 1, len, out);
  if (len == 0 || data[len - 1] != '\n')
    fputc ('\n', out);
  g_free (data);
  g_object_unref (gen);
  yaml_node_unref (yaml);
  json_node_unref (json);
  return TRUE;
}

static void
ctl_yaml_formatter_formatter_init (CtlFormatterInterface *iface)
{
  iface->emit = yaml_emit;
}

static void
ctl_yaml_formatter_class_init (CtlYamlFormatterClass *klass)
{
  (void) klass;
}

static void
ctl_yaml_formatter_init (CtlYamlFormatter *self)
{
  (void) self;
}
