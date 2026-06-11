/*
 * Copyright (C) 2026 Zach Podbielniak
 * SPDX-License-Identifier: AGPL-3.0-or-later
 */

/* ctl-formatter-raw.c --- -o raw, the script-stable formatter.
 *
 * SCALAR    byte-exact, nothing added
 * LIST      first column (or whole element) per line
 * DOCUMENT  compact JSON, one line */

#include "ctl-formatter.h"

#define CTL_TYPE_RAW_FORMATTER (ctl_raw_formatter_get_type ())
G_DECLARE_FINAL_TYPE (CtlRawFormatter, ctl_raw_formatter,
                      CTL, RAW_FORMATTER, GObject)

struct _CtlRawFormatter
{
  GObject parent_instance;
};

static void ctl_raw_formatter_formatter_init (CtlFormatterInterface *iface);

G_DEFINE_TYPE_WITH_CODE (CtlRawFormatter, ctl_raw_formatter,
                         G_TYPE_OBJECT,
                         G_IMPLEMENT_INTERFACE (CTL_TYPE_FORMATTER,
                           ctl_raw_formatter_formatter_init))

static gboolean
raw_emit (CtlFormatter *self, CtlResult *result, FILE *out,
          GError **error)
{
  (void) self; (void) error;

  switch (ctl_result_get_kind (result))
    {
    case CTL_RESULT_SCALAR:
      fputs (ctl_result_get_scalar (result), out);
      return TRUE;
    case CTL_RESULT_LIST:
      {
        JsonArray *rows = ctl_result_get_rows (result);
        guint n = rows != NULL ? json_array_get_length (rows) : 0;
        guint r;
        const gchar *key = ctl_result_get_n_columns (result) > 0
          ? ctl_result_get_column_key (result, 0) : NULL;
        for (r = 0; r < n; r++)
          {
            JsonNode *row = json_array_get_element (rows, r);
            if (key != NULL && JSON_NODE_HOLDS_OBJECT (row))
              {
                JsonObject *obj = json_node_get_object (row);
                if (json_object_has_member (obj, key))
                  {
                    fprintf (out, "%s\n",
                             json_object_get_string_member (obj, key));
                    continue;
                  }
              }
            if (JSON_NODE_HOLDS_VALUE (row))
              fprintf (out, "%s\n", json_node_get_string (row));
          }
        return TRUE;
      }
    case CTL_RESULT_DOCUMENT:
    default:
      {
        JsonGenerator *gen = json_generator_new ();
        gchar *data;
        json_generator_set_root (gen, ctl_result_get_root (result));
        data = json_generator_to_data (gen, NULL);
        fprintf (out, "%s\n", data);
        g_free (data);
        g_object_unref (gen);
        return TRUE;
      }
    }
}

static void
ctl_raw_formatter_formatter_init (CtlFormatterInterface *iface)
{
  iface->emit = raw_emit;
}

static void
ctl_raw_formatter_class_init (CtlRawFormatterClass *klass)
{
  (void) klass;
}

static void
ctl_raw_formatter_init (CtlRawFormatter *self)
{
  (void) self;
}
