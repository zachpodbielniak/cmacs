/* org-ex-widget-state.c — Serializable widget state implementation
 *
 * Copyright (C) 2026 Zach Podbielniak
 * SPDX-License-Identifier: AGPL-3.0-or-later
 */

#ifndef ORG_EX_COMPILATION
#define ORG_EX_COMPILATION
#endif
#include "org-ex-widget-state.h"
#include "../org-ex-types.h"

/**
 * SECTION:org-ex-widget-state
 * @title: OrgExWidgetState
 * @short_description: Serializable key-value state for widget persistence
 *
 * #OrgExWidgetState is a boxed type that stores ephemeral widget
 * state as string key-value pairs.  It serializes to/from JSON for
 * sidecar file persistence.
 */

G_DEFINE_BOXED_TYPE (OrgExWidgetState, org_ex_widget_state,
                     org_ex_widget_state_copy, org_ex_widget_state_free)

OrgExWidgetState *
org_ex_widget_state_new (void)
{
  OrgExWidgetState *state;

  state = g_slice_new0 (OrgExWidgetState);
  state->entries = g_hash_table_new_full (g_str_hash, g_str_equal,
                                          g_free, g_free);
  return state;
}

OrgExWidgetState *
org_ex_widget_state_copy (const OrgExWidgetState *state)
{
  OrgExWidgetState *copy;
  GHashTableIter iter;
  gpointer key, value;

  g_return_val_if_fail (state != NULL, NULL);

  copy = org_ex_widget_state_new ();

  g_hash_table_iter_init (&iter, state->entries);
  while (g_hash_table_iter_next (&iter, &key, &value))
    g_hash_table_insert (copy->entries,
                          g_strdup (key), g_strdup (value));

  return copy;
}

void
org_ex_widget_state_free (OrgExWidgetState *state)
{
  if (state == NULL)
    return;

  g_hash_table_unref (state->entries);
  g_slice_free (OrgExWidgetState, state);
}

void
org_ex_widget_state_set (OrgExWidgetState *state,
                          const gchar      *key,
                          const gchar      *value)
{
  g_return_if_fail (state != NULL);
  g_return_if_fail (key != NULL);

  g_hash_table_insert (state->entries,
                        g_strdup (key), g_strdup (value));
}

const gchar *
org_ex_widget_state_get (const OrgExWidgetState *state,
                          const gchar            *key)
{
  g_return_val_if_fail (state != NULL, NULL);
  g_return_val_if_fail (key != NULL, NULL);

  return g_hash_table_lookup (state->entries, key);
}

gchar *
org_ex_widget_state_to_json (const OrgExWidgetState *state)
{
  GString *json;
  GHashTableIter iter;
  gpointer key, value;
  gboolean first = TRUE;

  g_return_val_if_fail (state != NULL, NULL);

  json = g_string_new ("{");

  g_hash_table_iter_init (&iter, state->entries);
  while (g_hash_table_iter_next (&iter, &key, &value))
    {
      gchar *escaped_key, *escaped_val;

      if (!first)
        g_string_append_c (json, ',');
      first = FALSE;

      /* Simple JSON string escaping */
      escaped_key = g_strescape ((const gchar *) key, NULL);
      escaped_val = g_strescape ((const gchar *) value, NULL);
      g_string_append_printf (json, "\"%s\":\"%s\"",
                              escaped_key, escaped_val);
      g_free (escaped_key);
      g_free (escaped_val);
    }

  g_string_append_c (json, '}');

  return g_string_free (json, FALSE);
}

OrgExWidgetState *
org_ex_widget_state_from_json (const gchar *json,
                                GError     **error)
{
  OrgExWidgetState *state;
  const gchar *p;
  gchar *key, *val;

  g_return_val_if_fail (json != NULL, NULL);

  state = org_ex_widget_state_new ();

  /* Minimal JSON object parser for {"key":"val",...} */
  p = json;
  while (*p != '\0' && *p != '{')
    p++;
  if (*p != '{')
    {
      g_set_error_literal (error, ORG_EX_ERROR, ORG_EX_ERROR_STATE,
                           "Expected '{' in JSON state");
      org_ex_widget_state_free (state);
      return NULL;
    }
  p++;

  while (*p != '\0' && *p != '}')
    {
      GString *buf;

      /* Skip whitespace and commas */
      while (*p == ' ' || *p == '\t' || *p == '\n' || *p == ',')
        p++;
      if (*p == '}' || *p == '\0')
        break;

      /* Parse key */
      if (*p != '"')
        goto parse_error;
      p++;
      buf = g_string_new (NULL);
      while (*p != '\0' && *p != '"')
        {
          if (*p == '\\' && *(p + 1) != '\0')
            {
              p++;
              g_string_append_c (buf, *p);
            }
          else
            g_string_append_c (buf, *p);
          p++;
        }
      if (*p != '"')
        {
          g_string_free (buf, TRUE);
          goto parse_error;
        }
      p++;
      key = g_string_free (buf, FALSE);

      /* Skip colon */
      while (*p == ' ' || *p == '\t')
        p++;
      if (*p != ':')
        {
          g_free (key);
          goto parse_error;
        }
      p++;
      while (*p == ' ' || *p == '\t')
        p++;

      /* Parse value */
      if (*p != '"')
        {
          g_free (key);
          goto parse_error;
        }
      p++;
      buf = g_string_new (NULL);
      while (*p != '\0' && *p != '"')
        {
          if (*p == '\\' && *(p + 1) != '\0')
            {
              p++;
              g_string_append_c (buf, *p);
            }
          else
            g_string_append_c (buf, *p);
          p++;
        }
      if (*p != '"')
        {
          g_free (key);
          g_string_free (buf, TRUE);
          goto parse_error;
        }
      p++;
      val = g_string_free (buf, FALSE);

      g_hash_table_insert (state->entries, key, val);
    }

  return state;

parse_error:
  g_set_error_literal (error, ORG_EX_ERROR, ORG_EX_ERROR_STATE,
                       "Malformed JSON in state file");
  org_ex_widget_state_free (state);
  return NULL;
}
