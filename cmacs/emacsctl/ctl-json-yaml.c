/*
 * Copyright (C) 2026 Zach Podbielniak
 * SPDX-License-Identifier: AGPL-3.0-or-later
 */

/* ctl-json-yaml.c --- JsonNode <-> YamlNode conversion.
 *
 * Both libraries model the same tree shapes (mapping/object,
 * sequence/array, scalar, null), so the conversion is a mechanical
 * recursion. */

#include "ctl-json-yaml.h"

YamlNode *
ctl_json_to_yaml (JsonNode *json)
{
  YamlNode *node;

  if (json == NULL || json_node_is_null (json))
    {
      node = yaml_node_alloc ();
      yaml_node_init_null (node);
      return node;
    }

  if (JSON_NODE_HOLDS_OBJECT (json))
    {
      JsonObject *obj = json_node_get_object (json);
      JsonObjectIter iter;
      const gchar *name;
      JsonNode *member;
      YamlMapping *map;

      node = yaml_node_new (YAML_NODE_MAPPING);
      map = yaml_node_get_mapping (node);
      /* Ordered: keep the member order the producer chose (title
       * before children, etc.) instead of hash order. */
      json_object_iter_init_ordered (&iter, obj);
      while (json_object_iter_next_ordered (&iter, &name, &member))
        {
          YamlNode *child = ctl_json_to_yaml (member);
          yaml_mapping_set_member (map, name, child);
          yaml_node_unref (child);
        }
      return node;
    }

  if (JSON_NODE_HOLDS_ARRAY (json))
    {
      JsonArray *arr = json_node_get_array (json);
      guint n = json_array_get_length (arr);
      guint k;
      YamlSequence *seq;

      node = yaml_node_new (YAML_NODE_SEQUENCE);
      seq = yaml_node_get_sequence (node);
      for (k = 0; k < n; k++)
        {
          YamlNode *child =
            ctl_json_to_yaml (json_array_get_element (arr, k));
          yaml_sequence_add_element (seq, child);
          yaml_node_unref (child);
        }
      return node;
    }

  /* Scalar. */
  node = yaml_node_new (YAML_NODE_SCALAR);
  {
    GType vt = json_node_get_value_type (json);
    if (vt == G_TYPE_STRING)
      yaml_node_set_string (node, json_node_get_string (json));
    else if (vt == G_TYPE_BOOLEAN)
      yaml_node_set_boolean (node, json_node_get_boolean (json));
    else if (vt == G_TYPE_INT64)
      yaml_node_set_int (node, json_node_get_int (json));
    else
      yaml_node_set_double (node, json_node_get_double (json));
  }
  return node;
}

JsonNode *
ctl_yaml_to_json (YamlNode *yaml)
{
  JsonNode *node;

  if (yaml == NULL)
    return json_node_new (JSON_NODE_NULL);

  switch (yaml_node_get_node_type (yaml))
    {
    case YAML_NODE_MAPPING:
      {
        YamlMapping *map = yaml_node_get_mapping (yaml);
        JsonObject *obj = json_object_new ();
        guint n = yaml_mapping_get_size (map);
        guint k;
        for (k = 0; k < n; k++)
          {
            const gchar *key = yaml_mapping_get_key (map, k);
            YamlNode *child = yaml_mapping_get_value (map, k);
            json_object_set_member (obj, key, ctl_yaml_to_json (child));
          }
        node = json_node_new (JSON_NODE_OBJECT);
        json_node_take_object (node, obj);
        return node;
      }
    case YAML_NODE_SEQUENCE:
      {
        YamlSequence *seq = yaml_node_get_sequence (yaml);
        JsonArray *arr = json_array_new ();
        guint n = yaml_sequence_get_length (seq);
        guint k;
        for (k = 0; k < n; k++)
          json_array_add_element (
            arr, ctl_yaml_to_json (yaml_sequence_get_element (seq, k)));
        node = json_node_new (JSON_NODE_ARRAY);
        json_node_take_array (node, arr);
        return node;
      }
    case YAML_NODE_SCALAR:
      {
        const gchar *s = yaml_node_get_string (yaml);
        node = json_node_new (JSON_NODE_VALUE);
        json_node_set_string (node, s != NULL ? s : "");
        return node;
      }
    case YAML_NODE_NULL:
    default:
      return json_node_new (JSON_NODE_NULL);
    }
}
