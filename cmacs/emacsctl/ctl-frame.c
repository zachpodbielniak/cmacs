/*
 * Copyright (C) 2026 Zach Podbielniak
 * SPDX-License-Identifier: AGPL-3.0-or-later
 */

/* ctl-frame.c --- see ctl-frame.h. */

#include "ctl-frame.h"

#include <string.h>

JsonObject *
ctl_frame_read (GInputStream *in, gboolean *eof_seen, GError **error)
{
  guchar header[4];
  gsize got = 0;
  guint32 len;
  gchar *payload;
  JsonParser *parser;
  JsonObject *frame;

  if (eof_seen != NULL)
    *eof_seen = FALSE;

  if (!g_input_stream_read_all (in, header, 4, &got, NULL, error))
    return NULL;
  if (got == 0)
    {
      if (eof_seen != NULL)
        *eof_seen = TRUE;
      return NULL;
    }
  if (got < 4)
    {
      g_set_error (error, CTL_ERROR, CTL_ERROR_FAILED,
                   "truncated frame header (%u bytes)", (guint) got);
      return NULL;
    }

  len = ((guint32) header[0] << 24) | ((guint32) header[1] << 16)
      | ((guint32) header[2] << 8)  |  (guint32) header[3];
  if (len == 0 || len > (64u << 20))
    {
      g_set_error (error, CTL_ERROR, CTL_ERROR_FAILED,
                   "implausible frame length %u", len);
      return NULL;
    }

  payload = g_malloc (len + 1);
  if (!g_input_stream_read_all (in, payload, len, &got, NULL, error)
      || got < len)
    {
      if (error != NULL && *error == NULL)
        g_set_error (error, CTL_ERROR, CTL_ERROR_FAILED,
                     "truncated frame payload (%u of %u bytes)",
                     (guint) got, len);
      g_free (payload);
      return NULL;
    }
  payload[len] = '\0';

  parser = json_parser_new ();
  if (!json_parser_load_from_data (parser, payload, len, error))
    {
      g_free (payload);
      g_object_unref (parser);
      return NULL;
    }
  g_free (payload);

  {
    JsonNode *root = json_parser_get_root (parser);
    if (root == NULL || !JSON_NODE_HOLDS_OBJECT (root))
      {
        g_set_error (error, CTL_ERROR, CTL_ERROR_FAILED,
                     "frame payload is not a JSON object");
        g_object_unref (parser);
        return NULL;
      }
    frame = json_object_ref (json_node_get_object (root));
  }
  g_object_unref (parser);
  return frame;
}

gboolean
ctl_frame_write (GOutputStream *out, JsonObject *frame, GError **error)
{
  JsonGenerator *gen;
  JsonNode *root;
  gchar *data;
  gsize len = 0;
  guchar header[4];
  gboolean ok;

  root = json_node_new (JSON_NODE_OBJECT);
  json_node_set_object (root, frame);
  gen = json_generator_new ();
  json_generator_set_root (gen, root);
  data = json_generator_to_data (gen, &len);
  g_object_unref (gen);
  json_node_unref (root);

  header[0] = (len >> 24) & 0xff;
  header[1] = (len >> 16) & 0xff;
  header[2] = (len >> 8) & 0xff;
  header[3] = len & 0xff;

  ok = g_output_stream_write_all (out, header, 4, NULL, NULL, error)
    && g_output_stream_write_all (out, data, len, NULL, NULL, error)
    && g_output_stream_flush (out, NULL, error);
  g_free (data);
  return ok;
}

JsonObject *
ctl_frame_new (const gchar *type)
{
  JsonObject *frame = json_object_new ();
  json_object_set_string_member (frame, "type", type);
  return frame;
}

JsonObject *
ctl_frame_new_hello (void)
{
  JsonObject *frame = ctl_frame_new ("hello");
  json_object_set_int_member (frame, "proto", CTL_FRAME_PROTO);
  json_object_set_string_member (frame, "version", CTL_VERSION);
  return frame;
}

void
ctl_frame_set_variant (JsonObject *frame, const gchar *key,
                       GVariant *variant)
{
  gchar *sig_key;

  if (variant == NULL)
    return;
  json_object_set_member (frame, key, json_gvariant_serialize (variant));
  sig_key = g_strdup_printf ("%s_sig", key);
  json_object_set_string_member (frame, sig_key,
                                 g_variant_get_type_string (variant));
  g_free (sig_key);
}

GVariant *
ctl_frame_get_variant (JsonObject *frame, const gchar *key,
                       GError **error)
{
  gchar *sig_key;
  const gchar *sig;
  JsonNode *node;
  GVariant *variant;

  if (!json_object_has_member (frame, key))
    return NULL;

  sig_key = g_strdup_printf ("%s_sig", key);
  sig = json_object_get_string_member_with_default (frame, sig_key,
                                                    NULL);
  g_free (sig_key);
  node = json_object_get_member (frame, key);
  variant = json_gvariant_deserialize (node, sig, error);
  if (variant != NULL)
    g_variant_ref_sink (variant);
  return variant;
}
