/*
 * Copyright (C) 2026 Zach Podbielniak
 * SPDX-License-Identifier: AGPL-3.0-or-later
 */

/* ctl-tool-args.c --- table lookups, typed flags and generated help
 * for `emacsctl tool'.  See ctl-tool-args.h.
 *
 * emacsctl has no list of tools.  What a tool is called, what it takes
 * and how to describe it all come from the table the running editor
 * sends, so this file is written against that table's shape and
 * nothing else:
 *
 *   { "name": "calc_eval", "cli": "calc eval", "group": "calc",
 *     "description": "...", "returns": "string",
 *     "params": [ { "name": "expression", "type": "string",
 *                   "description": "...", "required": true } ],
 *     "destructive": false, "confirm": null, "async": false,
 *     "timeout": 120, "surfaces": ["mcp", "dbus", ...],
 *     "example": null, "aliases": [] }
 */

#include "ctl-tool-args.h"

#include <stdlib.h>
#include <string.h>

/* ── Small readers ───────────────────────────────────────────────── */

/* The string member KEY of OBJ, or FALLBACK when it is absent, null or
 * not a string.  json-glib's own _with_default accessor warns on a
 * type mismatch, and the table is remote input. */
static const gchar *
member_string (JsonObject *obj, const gchar *key, const gchar *fallback)
{
  JsonNode *node;

  if (obj == NULL || !json_object_has_member (obj, key))
    return fallback;
  node = json_object_get_member (obj, key);
  if (!JSON_NODE_HOLDS_VALUE (node)
      || json_node_get_value_type (node) != G_TYPE_STRING)
    return fallback;
  return json_node_get_string (node);
}

static gboolean
member_bool (JsonObject *obj, const gchar *key)
{
  JsonNode *node;

  if (obj == NULL || !json_object_has_member (obj, key))
    return FALSE;
  node = json_object_get_member (obj, key);
  if (!JSON_NODE_HOLDS_VALUE (node)
      || json_node_get_value_type (node) != G_TYPE_BOOLEAN)
    return FALSE;
  return json_node_get_boolean (node);
}

static JsonArray *
member_array (JsonObject *obj, const gchar *key)
{
  JsonNode *node;

  if (obj == NULL || !json_object_has_member (obj, key))
    return NULL;
  node = json_object_get_member (obj, key);
  return JSON_NODE_HOLDS_ARRAY (node) ? json_node_get_array (node) : NULL;
}

/* Element IDX of ARR as an object, or NULL. */
static JsonObject *
element_object (JsonArray *arr, guint idx)
{
  JsonNode *node = json_array_get_element (arr, idx);

  return JSON_NODE_HOLDS_OBJECT (node) ? json_node_get_object (node) : NULL;
}

/* A == B, treating `-' and `_' as the same character. */
static gboolean
names_equal (const gchar *a, const gchar *b)
{
  if (a == NULL || b == NULL)
    return FALSE;
  for (; *a != '\0' && *b != '\0'; a++, b++)
    {
      gchar ca = (*a == '-') ? '_' : *a;
      gchar cb = (*b == '-') ? '_' : *b;
      if (ca != cb)
        return FALSE;
    }
  return *a == '\0' && *b == '\0';
}

/* ── Lookups ─────────────────────────────────────────────────────── */

JsonObject *
ctl_tool_find_by_name (JsonArray *tools, const gchar *name)
{
  guint n, k;

  if (tools == NULL || name == NULL)
    return NULL;
  n = json_array_get_length (tools);
  for (k = 0; k < n; k++)
    {
      JsonObject *tool = element_object (tools, k);
      JsonArray *aliases;
      guint a, n_aliases;

      if (tool == NULL)
        continue;
      if (names_equal (member_string (tool, "name", NULL), name))
        return tool;
      aliases = member_array (tool, "aliases");
      n_aliases = aliases != NULL ? json_array_get_length (aliases) : 0;
      for (a = 0; a < n_aliases; a++)
        {
          JsonNode *node = json_array_get_element (aliases, a);
          if (JSON_NODE_HOLDS_VALUE (node)
              && json_node_get_value_type (node) == G_TYPE_STRING
              && names_equal (json_node_get_string (node), name))
            return tool;
        }
    }
  return NULL;
}

JsonObject *
ctl_tool_find_by_cli (JsonArray *tools, const gchar *group,
                      const gchar *verb)
{
  gchar *want;
  JsonObject *found = NULL;
  guint n, k;

  if (tools == NULL || group == NULL || verb == NULL)
    return NULL;
  want = g_strdup_printf ("%s %s", group, verb);
  n = json_array_get_length (tools);
  for (k = 0; k < n && found == NULL; k++)
    {
      JsonObject *tool = element_object (tools, k);
      if (tool != NULL
          && g_strcmp0 (member_string (tool, "cli", NULL), want) == 0)
        found = tool;
    }
  g_free (want);
  return found;
}

gboolean
ctl_tool_on_surface (JsonObject *tool, const gchar *surface)
{
  JsonArray *surfaces = member_array (tool, "surfaces");
  guint n, k;

  if (surfaces == NULL)
    return FALSE;
  n = json_array_get_length (surfaces);
  for (k = 0; k < n; k++)
    {
      JsonNode *node = json_array_get_element (surfaces, k);
      if (JSON_NODE_HOLDS_VALUE (node)
          && json_node_get_value_type (node) == G_TYPE_STRING
          && g_strcmp0 (json_node_get_string (node), surface) == 0)
        return TRUE;
    }
  return FALSE;
}

gint
ctl_tool_timeout_ms (JsonObject *tool, gint base_ms)
{
  gint64 secs;
  gint64 need_ms;

  if (!member_bool (tool, "async")
      || !json_object_has_member (tool, "timeout"))
    return base_ms;
  secs = json_object_get_int_member (tool, "timeout");
  if (secs <= 0)
    return base_ms;
  /* The editor answers at the tool's timeout at the latest; the margin
   * is for that answer to arrive rather than race the client's own
   * deadline and lose. */
  need_ms = (secs + 5) * 1000;
  if (need_ms > G_MAXINT)
    need_ms = G_MAXINT;
  return (base_ms < 0 || base_ms < need_ms) ? (gint) need_ms : base_ms;
}

/* ── Typed flags ─────────────────────────────────────────────────── */

/* The parameter of TOOL that the flag word FLAG (no leading dashes)
 * names, or NULL. */
static JsonObject *
find_param (JsonObject *tool, const gchar *flag)
{
  JsonArray *params = member_array (tool, "params");
  guint n, k;

  if (params == NULL)
    return NULL;
  n = json_array_get_length (params);
  for (k = 0; k < n; k++)
    {
      JsonObject *p = element_object (params, k);
      if (p != NULL && names_equal (member_string (p, "name", NULL), flag))
        return p;
    }
  return NULL;
}

/* "--a, --b" for every parameter of TOOL, or "none".  Caller g_frees. */
static gchar *
flag_list (JsonObject *tool)
{
  JsonArray *params = member_array (tool, "params");
  GString *out = g_string_new (NULL);
  guint n = params != NULL ? json_array_get_length (params) : 0;
  guint k;

  for (k = 0; k < n; k++)
    {
      JsonObject *p = element_object (params, k);
      if (p == NULL)
        continue;
      if (out->len > 0)
        g_string_append (out, ", ");
      g_string_append_printf (out, "--%s", member_string (p, "name", "?"));
    }
  if (out->len == 0)
    g_string_append (out, "none");
  return g_string_free (out, FALSE);
}

static gboolean
parse_bool_word (const gchar *word, gboolean *value)
{
  if (g_strcmp0 (word, "true") == 0)
    { *value = TRUE; return TRUE; }
  if (g_strcmp0 (word, "false") == 0)
    { *value = FALSE; return TRUE; }
  return FALSE;
}

/* Set member NAME of OBJ from the text VALUE, converted to TYPE. */
static gboolean
set_typed (JsonObject *obj, const gchar *name, const gchar *type,
           const gchar *value, GError **error)
{
  if (g_strcmp0 (type, "integer") == 0)
    {
      gchar *end = NULL;
      gint64 v = g_ascii_strtoll (value, &end, 10);

      if (*value == '\0' || end == NULL || *end != '\0')
        {
          g_set_error (error, CTL_ERROR, CTL_ERROR_USAGE,
                       "--%s takes an integer, not '%s'", name, value);
          return FALSE;
        }
      json_object_set_int_member (obj, name, v);
    }
  else if (g_strcmp0 (type, "number") == 0)
    {
      gchar *end = NULL;
      gdouble v = g_ascii_strtod (value, &end);

      if (*value == '\0' || end == NULL || *end != '\0')
        {
          g_set_error (error, CTL_ERROR, CTL_ERROR_USAGE,
                       "--%s takes a number, not '%s'", name, value);
          return FALSE;
        }
      json_object_set_double_member (obj, name, v);
    }
  else
    json_object_set_string_member (obj, name, value);
  return TRUE;
}

/* Merge the members of the JSON object text TEXT into OBJ. */
static gboolean
merge_json (JsonObject *obj, const gchar *text, GError **error)
{
  JsonParser *parser = json_parser_new ();
  GError *err = NULL;
  JsonNode *root;
  GList *members, *l;
  JsonObject *src;

  if (!json_parser_load_from_data (parser, text, -1, &err))
    {
      g_set_error (error, CTL_ERROR, CTL_ERROR_USAGE,
                   "--json is not valid JSON: %s", err->message);
      g_error_free (err);
      g_object_unref (parser);
      return FALSE;
    }
  root = json_parser_get_root (parser);
  if (root == NULL || !JSON_NODE_HOLDS_OBJECT (root))
    {
      g_set_error (error, CTL_ERROR, CTL_ERROR_USAGE,
                   "--json must be a JSON object, e.g. '{\"name\": 1}'");
      g_object_unref (parser);
      return FALSE;
    }
  src = json_node_get_object (root);
  members = json_object_get_members (src);
  for (l = members; l != NULL; l = l->next)
    json_object_set_member (obj, l->data,
                            json_node_copy (
                              json_object_get_member (src, l->data)));
  g_list_free (members);
  g_object_unref (parser);
  return TRUE;
}

gchar *
ctl_tool_build_args (JsonObject *tool, gchar **argv, gint argc,
                     GError **error)
{
  JsonObject *obj = json_object_new ();
  JsonArray *params = member_array (tool, "params");
  const gchar *tool_name = member_string (tool, "name", "tool");
  JsonNode *root;
  gchar *out;
  guint n_params, p;
  gint k;

  /* --json first, wherever it appears, so the flags beside it override
   * its members rather than the other way round. */
  for (k = 0; k < argc; k++)
    {
      const gchar *text = NULL;

      if (g_strcmp0 (argv[k], "--") == 0)
        break;
      if (g_strcmp0 (argv[k], "--json") == 0)
        {
          if (k + 1 >= argc)
            {
              g_set_error (error, CTL_ERROR, CTL_ERROR_USAGE,
                           "--json needs a JSON object");
              goto fail;
            }
          text = argv[k + 1];
        }
      else if (g_str_has_prefix (argv[k], "--json="))
        text = argv[k] + strlen ("--json=");
      if (text != NULL && !merge_json (obj, text, error))
        goto fail;
    }

  for (k = 0; k < argc; k++)
    {
      const gchar *word = argv[k];
      const gchar *eq;
      gchar *flag;
      const gchar *inline_value = NULL;
      JsonObject *param;
      const gchar *pname, *ptype;

      if (g_strcmp0 (word, "--json") == 0)
        { k++; continue; }
      if (g_str_has_prefix (word, "--json="))
        continue;

      if (!g_str_has_prefix (word, "--") || word[2] == '\0')
        {
          g_set_error (error, CTL_ERROR, CTL_ERROR_USAGE,
                       "unexpected argument '%s' (%s takes its arguments "
                       "as --NAME VALUE)", word, tool_name);
          goto fail;
        }

      eq = strchr (word + 2, '=');
      if (eq != NULL)
        {
          flag = g_strndup (word + 2, eq - (word + 2));
          inline_value = eq + 1;
        }
      else
        flag = g_strdup (word + 2);

      param = find_param (tool, flag);

      /* --no-NAME, for a boolean NAME (and only when no parameter is
       * itself called no_NAME). */
      if (param == NULL && inline_value == NULL
          && (g_str_has_prefix (flag, "no-")
              || g_str_has_prefix (flag, "no_")))
        {
          JsonObject *negated = find_param (tool, flag + 3);
          if (negated != NULL
              && g_strcmp0 (member_string (negated, "type", ""),
                            "boolean") == 0)
            {
              json_object_set_boolean_member (
                obj, member_string (negated, "name", flag + 3), FALSE);
              g_free (flag);
              continue;
            }
        }

      if (param == NULL)
        {
          gchar *flags = flag_list (tool);
          g_set_error (error, CTL_ERROR, CTL_ERROR_USAGE,
                       "%s has no argument --%s (it takes: %s)",
                       tool_name, flag, flags);
          g_free (flags);
          g_free (flag);
          goto fail;
        }
      pname = member_string (param, "name", flag);
      ptype = member_string (param, "type", "string");

      if (g_strcmp0 (ptype, "boolean") == 0)
        {
          gboolean value = TRUE;

          if (inline_value != NULL)
            {
              if (!parse_bool_word (inline_value, &value))
                {
                  g_set_error (error, CTL_ERROR, CTL_ERROR_USAGE,
                               "--%s takes true or false, not '%s'",
                               pname, inline_value);
                  g_free (flag);
                  goto fail;
                }
            }
          else if (k + 1 < argc && parse_bool_word (argv[k + 1], &value))
            k++;
          json_object_set_boolean_member (obj, pname, value);
        }
      else
        {
          const gchar *value = inline_value;

          if (value == NULL)
            {
              if (k + 1 >= argc)
                {
                  g_set_error (error, CTL_ERROR, CTL_ERROR_USAGE,
                               "--%s needs a value", pname);
                  g_free (flag);
                  goto fail;
                }
              value = argv[++k];
            }
          if (!set_typed (obj, pname, ptype, value, error))
            {
              g_free (flag);
              goto fail;
            }
        }
      g_free (flag);
    }

  /* The editor checks this too.  Checking here as well turns a round
   * trip and a remote error into a usage message naming the flag. */
  n_params = params != NULL ? json_array_get_length (params) : 0;
  for (p = 0; p < n_params; p++)
    {
      JsonObject *param = element_object (params, p);
      const gchar *pname;

      if (param == NULL || !member_bool (param, "required")
          || json_object_has_member (param, "default"))
        continue;
      pname = member_string (param, "name", NULL);
      if (pname != NULL
          && (!json_object_has_member (obj, pname)
              || json_object_get_null_member (obj, pname)))
        {
          g_set_error (error, CTL_ERROR, CTL_ERROR_USAGE,
                       "%s: missing required argument --%s",
                       tool_name, pname);
          goto fail;
        }
    }

  root = json_node_new (JSON_NODE_OBJECT);
  json_node_take_object (root, obj);
  out = json_to_string (root, FALSE);
  json_node_unref (root);
  return out;

fail:
  json_object_unref (obj);
  return NULL;
}

/* ── Generated help ──────────────────────────────────────────────── */

/* The value placeholder shown after a flag of TYPE. */
static const gchar *
type_placeholder (const gchar *type)
{
  if (g_strcmp0 (type, "integer") == 0) return "INT";
  if (g_strcmp0 (type, "number") == 0)  return "NUM";
  if (g_strcmp0 (type, "boolean") == 0) return "[true|false]";
  return "STRING";
}

/* Comma-joined string elements of ARR.  Caller g_frees. */
static gchar *
join_strings (JsonArray *arr)
{
  GString *out = g_string_new (NULL);
  guint n = arr != NULL ? json_array_get_length (arr) : 0;
  guint k;

  for (k = 0; k < n; k++)
    {
      JsonNode *node = json_array_get_element (arr, k);
      if (!JSON_NODE_HOLDS_VALUE (node)
          || json_node_get_value_type (node) != G_TYPE_STRING)
        continue;
      if (out->len > 0)
        g_string_append (out, ", ");
      g_string_append (out, json_node_get_string (node));
    }
  return g_string_free (out, FALSE);
}

gchar *
ctl_tool_help_string (JsonObject *tool, const gchar *prog)
{
  GString *out = g_string_new (NULL);
  JsonArray *params = member_array (tool, "params");
  guint n = params != NULL ? json_array_get_length (params) : 0;
  const gchar *cli = member_string (tool, "cli", NULL);
  const gchar *name = member_string (tool, "name", "?");
  const gchar *confirm = member_string (tool, "confirm", NULL);
  const gchar *example = member_string (tool, "example", NULL);
  gchar *surfaces, *aliases;
  guint k;

  g_string_append (out, "Usage:\n");
  if (cli != NULL)
    g_string_append_printf (out, "  %s [OPTION…] tool %s", prog, cli);
  else
    g_string_append_printf (out, "  %s [OPTION…] tool call %s", prog, name);
  for (k = 0; k < n; k++)
    {
      JsonObject *p = element_object (params, k);
      const gchar *ptype;
      gboolean required;

      if (p == NULL)
        continue;
      ptype = member_string (p, "type", "string");
      required = member_bool (p, "required")
        && !json_object_has_member (p, "default");
      if (g_strcmp0 (ptype, "boolean") == 0)
        g_string_append_printf (out, required ? " --%s" : " [--%s]",
                                member_string (p, "name", "?"));
      else
        g_string_append_printf (out, required ? " --%s %s" : " [--%s %s]",
                                member_string (p, "name", "?"),
                                type_placeholder (ptype));
    }
  g_string_append_printf (out, "\n  %s [OPTION…] tool call %s --json '{…}'\n\n",
                          prog, name);

  g_string_append_printf (out, "%s\n\n",
                          member_string (tool, "description", ""));

  g_string_append (out, "Arguments:\n");
  if (n == 0)
    g_string_append (out, "  (none)\n");
  for (k = 0; k < n; k++)
    {
      JsonObject *p = element_object (params, k);
      JsonArray *pen;
      gchar *label;
      const gchar *ptype;

      if (p == NULL)
        continue;
      ptype = member_string (p, "type", "string");
      label = g_strdup_printf ("--%s %s", member_string (p, "name", "?"),
                               type_placeholder (ptype));
      g_string_append_printf (out, "  %-28s %s%s\n", label,
                              member_bool (p, "required") ? "(required) " : "",
                              member_string (p, "description", ""));
      g_free (label);
      pen = member_array (p, "enum");
      if (pen != NULL && json_array_get_length (pen) > 0)
        {
          gchar *choices = join_strings (pen);
          g_string_append_printf (out, "  %-28s One of: %s\n", "", choices);
          g_free (choices);
        }
      if (json_object_has_member (p, "default"))
        {
          gchar *text = json_to_string (
            json_object_get_member (p, "default"), FALSE);
          g_string_append_printf (out, "  %-28s Default: %s\n", "", text);
          g_free (text);
        }
    }
  g_string_append_printf (out, "  %-28s %s\n", "--json '{…}'",
                          "Every argument as one JSON object; flags given "
                          "beside it override its members");

  surfaces = join_strings (member_array (tool, "surfaces"));
  aliases = join_strings (member_array (tool, "aliases"));
  g_string_append_printf (out, "\nTool:      %s\n", name);
  if (*aliases != '\0')
    g_string_append_printf (out, "Aliases:   %s\n", aliases);
  g_string_append_printf (out, "Surfaces:  %s\n", surfaces);
  g_string_append_printf (out, "Returns:   %s\n",
                          member_string (tool, "returns", "string"));
  if (member_bool (tool, "destructive"))
    g_string_append (out, "Flags:     destructive\n");
  if (confirm != NULL)
    g_string_append_printf (out, "Confirm:   %s (refused when the editor "
                            "has nobody to ask and the tool is not "
                            "auto-approved)\n", confirm);
  if (member_bool (tool, "async"))
    g_string_append_printf (
      out, "Async:     answers when it finishes, within %" G_GINT64_FORMAT
      "s\n", json_object_has_member (tool, "timeout")
               ? json_object_get_int_member (tool, "timeout") : (gint64) 0);
  if (example != NULL)
    g_string_append_printf (out, "Example:   %s\n", example);
  g_string_append_printf (
    out, "\nGlobal options (--instance, --host, -o, --timeout, …) are "
    "listed by '%s --help'.\nA tool argument with one of those names has "
    "to go in --json.\n", prog);

  g_free (surfaces);
  g_free (aliases);
  return g_string_free (out, FALSE);
}

static gint
compare_cli (gconstpointer a, gconstpointer b)
{
  JsonObject *ta = *(JsonObject * const *) a;
  JsonObject *tb = *(JsonObject * const *) b;

  return g_strcmp0 (member_string (ta, "cli", ""),
                    member_string (tb, "cli", ""));
}

/* The first sentence of TEXT, or its first 72 bytes' worth of whole
 * characters.  Caller g_frees. */
static gchar *
summary_of (const gchar *text)
{
  const gchar *stop = strstr (text, ".  ");
  const gchar *nl = strchr (text, '\n');
  gsize len;
  gchar *out;

  if (stop != NULL)
    stop++;                     /* keep the full stop */
  if (nl != NULL && (stop == NULL || nl < stop))
    stop = nl;
  len = stop != NULL ? (gsize) (stop - text) : strlen (text);
  if (len > 72)
    {
      const gchar *cut = g_utf8_find_prev_char (text, text + 70);
      gchar *head = g_strndup (text, cut != NULL ? (gsize) (cut - text) : 69);
      out = g_strconcat (head, "…", NULL);
      g_free (head);
      return out;
    }
  return g_strndup (text, len);
}

gchar *
ctl_tool_group_help_string (JsonArray *tools, const gchar *prog,
                            const gchar *group)
{
  GString *out = g_string_new (NULL);
  GPtrArray *rows = g_ptr_array_new ();
  guint n = tools != NULL ? json_array_get_length (tools) : 0;
  gsize group_len = group != NULL ? strlen (group) : 0;
  const gchar *last_group = NULL;
  gsize last_len = 0;
  guint k;

  for (k = 0; k < n; k++)
    {
      JsonObject *tool = element_object (tools, k);
      const gchar *cli;

      if (tool == NULL || !ctl_tool_on_surface (tool, "cli"))
        continue;
      cli = member_string (tool, "cli", NULL);
      if (cli == NULL)
        continue;
      if (group != NULL
          && !(strncmp (cli, group, group_len) == 0
               && cli[group_len] == ' '))
        continue;
      g_ptr_array_add (rows, tool);
    }
  if (group != NULL && rows->len == 0)
    {
      g_ptr_array_free (rows, TRUE);
      g_string_free (out, TRUE);
      return NULL;
    }
  g_ptr_array_sort (rows, compare_cli);

  g_string_append (out, "Usage:\n");
  if (group != NULL)
    g_string_append_printf (out, "  %s [OPTION…] tool %s VERB [--ARG VALUE…]\n",
                            prog, group);
  else
    g_string_append_printf (
      out,
      "  %s [OPTION…] tool GROUP VERB [--ARG VALUE…]\n"
      "  %s [OPTION…] tool call NAME [--ARG VALUE…] [--json '{…}']\n"
      "  %s [OPTION…] tool list [--group GROUP] [--json]\n"
      "  %s [OPTION…] tool describe NAME [--json]\n",
      prog, prog, prog, prog);
  g_string_append (
    out,
    "\nThe capabilities this cmacs registered, read from the running "
    "editor.\nNothing below is built into emacsctl.\n");

  for (k = 0; k < rows->len; k++)
    {
      JsonObject *tool = g_ptr_array_index (rows, k);
      const gchar *cli = member_string (tool, "cli", "");
      const gchar *space = strchr (cli, ' ');
      gsize glen = space != NULL ? (gsize) (space - cli) : strlen (cli);
      gchar *summary = summary_of (member_string (tool, "description", ""));

      if (last_group == NULL || glen != last_len
          || strncmp (cli, last_group, glen) != 0)
        {
          g_string_append_printf (out, "\n%.*s:\n", (gint) glen, cli);
          last_group = cli;
          last_len = glen;
        }
      g_string_append_printf (out, "  %-26s %s%s\n",
                              space != NULL ? space + 1 : cli, summary,
                              member_bool (tool, "destructive")
                                ? "  [destructive]" : "");
      g_free (summary);
    }
  if (rows->len == 0)
    g_string_append (out, "\n(no tools are published on the cli surface)\n");

  g_string_append_printf (
    out, "\nRun '%s tool GROUP VERB --help' for one tool's arguments.\n",
    prog);
  g_ptr_array_free (rows, TRUE);
  return g_string_free (out, FALSE);
}
