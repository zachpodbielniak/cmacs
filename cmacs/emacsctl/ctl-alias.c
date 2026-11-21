/*
 * Copyright (C) 2026 Zach Podbielniak
 * SPDX-License-Identifier: AGPL-3.0-or-later
 */

/* ctl-alias.c --- argument mapping, the fallback decision, output
 * shaping and help text for the verb aliases.  See ctl-alias.h.
 *
 * Nothing here talks to an editor.  The functions take an alias row
 * and plain values, which is what lets the unit tests cover every row
 * of the table without one. */

#include "ctl-alias.h"

#include <stdlib.h>
#include <string.h>

/* ── The row, taken apart ────────────────────────────────────────── */

/* One positional of a row: the argspec token it comes from and the
 * tool parameter it is sent as. */
typedef struct
{
  gchar type;               /* argspec letter: s i u x t d b */
  gboolean optional;
  const gchar *argname;     /* the old method's name for it (borrowed) */
  const gchar *param;       /* the tool's name for it (borrowed) */
} AliasArg;

/* SPEC's positionals.  *N_OUT is their number; the two strv's own the
 * strings the entries borrow and are freed by the caller with
 * alias_args_free.  Returns NULL (and sets *PROBLEM, when given) for a
 * row whose argspec and params do not pair up. */
static AliasArg *
alias_args (const CtlAliasSpec *spec, guint *n_out, gchar ***specs_out,
            gchar ***params_out, gchar **problem)
{
  const gchar *argspec = spec->legacy.argspec;
  gchar **specs = g_strsplit (argspec != NULL ? argspec : "", " ", -1);
  gchar **params = g_strsplit (spec->params != NULL ? spec->params : "",
                               " ", -1);
  guint n_specs = 0, n_params = 0, k;
  AliasArg *args;

  /* g_strsplit ("") is one empty string, not none. */
  if (specs[0] != NULL && *specs[0] == '\0')
    {
      g_strfreev (specs);
      specs = g_new0 (gchar *, 1);
    }
  if (params[0] != NULL && *params[0] == '\0')
    {
      g_strfreev (params);
      params = g_new0 (gchar *, 1);
    }
  n_specs = g_strv_length (specs);
  n_params = g_strv_length (params);

  if (n_specs != n_params)
    {
      if (problem != NULL)
        *problem = g_strdup_printf (
          "%u positional(s) in the argspec but %u parameter name(s)",
          n_specs, n_params);
      g_strfreev (specs);
      g_strfreev (params);
      return NULL;
    }

  args = g_new0 (AliasArg, n_specs + 1);
  for (k = 0; k < n_specs; k++)
    {
      const gchar *colon = strchr (specs[k], ':');

      args[k].type = specs[k][0];
      args[k].optional = specs[k][0] != '\0' && specs[k][1] == '?';
      args[k].argname = colon != NULL ? colon + 1 : specs[k];
      args[k].param = params[k];
    }

  *n_out = n_specs;
  *specs_out = specs;
  *params_out = params;
  return args;
}

static void
alias_args_free (AliasArg *args, gchar **specs, gchar **params)
{
  g_free (args);
  g_strfreev (specs);
  g_strfreev (params);
}

/* The value SPEC's defaults give for PARAM, or NULL.  Caller g_frees. */
static gchar *
alias_default (const CtlAliasSpec *spec, const gchar *param)
{
  gchar **pairs;
  gchar *found = NULL;
  gsize len = strlen (param);
  gint k;

  if (spec->defaults == NULL)
    return NULL;
  pairs = g_strsplit (spec->defaults, " ", -1);
  for (k = 0; pairs[k] != NULL && found == NULL; k++)
    if (strncmp (pairs[k], param, len) == 0 && pairs[k][len] == '=')
      found = g_strdup (pairs[k] + len + 1);
  g_strfreev (pairs);
  return found;
}

/* ── Checking a row ──────────────────────────────────────────────── */

/* A wire name: lower-case letters, digits and underscores, starting
 * with a letter.  (The registry's own names; `cmacs.c.list' and its
 * kind are deliberately not aliasable -- they stay in C.) */
static gboolean
wire_name_p (const gchar *name)
{
  const gchar *c;

  if (name == NULL || !g_ascii_islower (name[0]))
    return FALSE;
  for (c = name; *c != '\0'; c++)
    if (!g_ascii_islower (*c) && !g_ascii_isdigit (*c) && *c != '_')
      return FALSE;
  return TRUE;
}

gchar *
ctl_alias_spec_problem (const CtlAliasSpec *spec)
{
  AliasArg *args;
  gchar **specs = NULL, **params = NULL, **pairs;
  gchar *problem = NULL;
  guint n = 0, k, j;
  gboolean seen_optional = FALSE;

  if (spec->legacy.name == NULL || *spec->legacy.name == '\0')
    return g_strdup ("no verb");
  if (!wire_name_p (spec->tool))
    return g_strdup_printf ("'%s' is not a tool wire name",
                            spec->tool != NULL ? spec->tool : "(null)");
  if (spec->legacy.iface == NULL || spec->legacy.method == NULL)
    return g_strdup ("no D-Bus method to fall back to");
  if (spec->timeout_s < 0)
    return g_strdup ("negative timeout");

  args = alias_args (spec, &n, &specs, &params, &problem);
  if (args == NULL)
    return problem;

  for (k = 0; k < n && problem == NULL; k++)
    {
      /* The letters the alias path types.  o (object path), D (a{ss})
       * and A (as) have no scalar tool parameter to become. */
      if (strchr ("siuxtdb", args[k].type) == NULL || args[k].type == '\0')
        problem = g_strdup_printf ("argspec letter '%c' cannot be an "
                                   "alias positional", args[k].type);
      else if (!wire_name_p (args[k].param))
        problem = g_strdup_printf ("'%s' is not a parameter name",
                                   args[k].param);
      /* A required positional after an optional one could never be
       * given. */
      else if (seen_optional && !args[k].optional)
        problem = g_strdup_printf ("required <%s> follows an optional "
                                   "positional", args[k].argname);
      for (j = 0; j < k && problem == NULL; j++)
        if (strcmp (args[j].param, args[k].param) == 0)
          problem = g_strdup_printf ("two positionals map to '%s'",
                                     args[k].param);
      seen_optional = seen_optional || args[k].optional;
    }

  /* A default has to name an optional positional: that is where its
   * type comes from, and a required one is never absent. */
  pairs = g_strsplit (spec->defaults != NULL ? spec->defaults : "", " ", -1);
  for (j = 0; pairs[j] != NULL && problem == NULL; j++)
    {
      const gchar *eq = strchr (pairs[j], '=');
      gboolean found = FALSE;

      if (*pairs[j] == '\0')
        continue;
      if (eq == NULL || eq == pairs[j] || eq[1] == '\0')
        {
          problem = g_strdup_printf ("default '%s' is not NAME=VALUE",
                                     pairs[j]);
          break;
        }
      for (k = 0; k < n; k++)
        if (strlen (args[k].param) == (gsize) (eq - pairs[j])
            && strncmp (args[k].param, pairs[j], eq - pairs[j]) == 0
            && args[k].optional)
          found = TRUE;
      if (!found)
        problem = g_strdup_printf ("default '%s' names no optional "
                                   "positional", pairs[j]);
    }
  g_strfreev (pairs);

  alias_args_free (args, specs, params);
  return problem;
}

/* ── Arguments ───────────────────────────────────────────────────── */

/* Add VALUE to BUILDER as the member PARAM, converted by the argspec
 * letter TYPE exactly as build_params in ctl-command.c converts it for
 * the D-Bus call -- lenient strtol and all -- so the tool is handed
 * the number the old method was. */
static void
alias_add_member (JsonBuilder *builder, const gchar *param, gchar type,
                  const gchar *value)
{
  json_builder_set_member_name (builder, param);
  switch (type)
    {
    case 'i':
      json_builder_add_int_value (builder, (gint) strtol (value, NULL, 10));
      break;
    case 'u':
      json_builder_add_int_value (
        builder, (guint32) g_ascii_strtoull (value, NULL, 10));
      break;
    case 'x':
      json_builder_add_int_value (builder,
                                  g_ascii_strtoll (value, NULL, 10));
      break;
    case 't':
      json_builder_add_int_value (
        builder, (gint64) g_ascii_strtoull (value, NULL, 10));
      break;
    case 'd':
      json_builder_add_double_value (builder, g_ascii_strtod (value, NULL));
      break;
    case 'b':
      json_builder_add_boolean_value (builder,
                                      g_strcmp0 (value, "true") == 0
                                      || g_strcmp0 (value, "t") == 0
                                      || g_strcmp0 (value, "1") == 0);
      break;
    default:
      json_builder_add_string_value (builder, value);
    }
}

/* Whether VALUE, converted by the argspec letter TYPE, is what the
 * old method command sent for a positional that was not given. */
static gboolean
alias_wire_zero_p (gchar type, const gchar *value)
{
  switch (type)
    {
    case 'i':
      return strtol (value, NULL, 10) == 0;
    case 'u':
    case 't':
      return g_ascii_strtoull (value, NULL, 10) == 0;
    case 'x':
      return g_ascii_strtoll (value, NULL, 10) == 0;
    case 'd':
      return g_ascii_strtod (value, NULL) == 0.0;
    case 'b':
      return !(g_strcmp0 (value, "true") == 0
               || g_strcmp0 (value, "t") == 0
               || g_strcmp0 (value, "1") == 0);
    default:
      return *value == '\0';
    }
}

gchar *
ctl_alias_build_args (const CtlAliasSpec *spec, gchar **argv, gint argc,
                      GError **error)
{
  AliasArg *args;
  gchar **specs = NULL, **params = NULL;
  gchar *problem = NULL, *out;
  JsonBuilder *builder;
  JsonGenerator *generator;
  JsonNode *root;
  guint n = 0, k;

  args = alias_args (spec, &n, &specs, &params, &problem);
  if (args == NULL)
    {
      /* A malformed row is a bug in this client, not in what was
       * typed; the unit tests keep it from shipping. */
      g_set_error (error, CTL_ERROR, CTL_ERROR_FAILED,
                   "alias '%s' is malformed: %s", spec->legacy.name,
                   problem);
      g_free (problem);
      return NULL;
    }

  builder = json_builder_new ();
  json_builder_begin_object (builder);
  for (k = 0; k < n; k++)
    {
      const gchar *value = (gint) k < argc ? argv[k] : NULL;
      gchar *fallback = NULL;

      if (value == NULL && !args[k].optional)
        {
          g_set_error (error, CTL_ERROR, CTL_ERROR_USAGE,
                       "missing required argument <%s>", args[k].argname);
          g_object_unref (builder);
          alias_args_free (args, specs, params);
          return NULL;
        }

      /* The old method had no way to say "left out": an optional
       * positional that was absent went over the wire as "", 0 or
       * false, and the method read exactly those as "not given".  A
       * tool reads a missing member that way.  So an optional value
       * that is the wire's zero is no member -- `emacsctl db query c
       * SQL 0' goes on meaning "the default row limit". */
      if (args[k].optional && value != NULL
          && alias_wire_zero_p (args[k].type, value))
        value = NULL;

      if (value == NULL)
        {
          fallback = alias_default (spec, args[k].param);
          value = fallback;
        }
      if (value != NULL)
        alias_add_member (builder, args[k].param, args[k].type, value);
      g_free (fallback);
    }
  json_builder_end_object (builder);

  root = json_builder_get_root (builder);
  generator = json_generator_new ();
  json_generator_set_root (generator, root);
  out = json_generator_to_data (generator, NULL);
  g_object_unref (generator);
  json_node_unref (root);
  g_object_unref (builder);
  alias_args_free (args, specs, params);
  return out;
}

/* ── The fallback decision ───────────────────────────────────────── */

/* The D-Bus error name ERROR carries, or NULL.  Caller g_frees.
 *
 * Locally that is the GDBus remote error.  Through the ssh proxy the
 * error is rebuilt on this side as "NAME: message" in our own domain
 * (ctl-transport-ssh.c), so the name is read back off the front. */
static gchar *
alias_error_name (const GError *error)
{
  gchar *name;
  const gchar *colon;

  if (error == NULL)
    return NULL;
  name = g_dbus_error_get_remote_error (error);
  if (name != NULL)
    return name;

  if (error->domain != CTL_ERROR || error->message == NULL)
    return NULL;
  colon = strstr (error->message, ": ");
  if (colon == NULL || colon == error->message)
    return NULL;
  name = g_strndup (error->message, colon - error->message);
  /* An error name is dotted and has no spaces; anything else is the
   * start of an ordinary sentence. */
  if (strchr (name, '.') == NULL || strchr (name, ' ') != NULL
      || !g_dbus_is_interface_name (name))
    {
      g_free (name);
      return NULL;
    }
  return name;
}

CtlAliasVerdict
ctl_alias_decide (const GError *error)
{
  gchar *name;
  CtlAliasVerdict verdict = CTL_ALIAS_FAIL;

  if (error == NULL)
    return CTL_ALIAS_FAIL;

  /* No Tools interface at all, however the transport spelt it. */
  if (g_error_matches (error, G_DBUS_ERROR, G_DBUS_ERROR_UNKNOWN_INTERFACE)
      || g_error_matches (error, G_DBUS_ERROR, G_DBUS_ERROR_UNKNOWN_METHOD)
      || g_error_matches (error, CTL_ERROR, CTL_ERROR_UNSUPPORTED))
    return CTL_ALIAS_FALLBACK;

  name = alias_error_name (error);
  if (name != NULL
      && (strstr (name, "UnknownInterface") != NULL
          || strstr (name, "UnknownMethod") != NULL
          /* The three refusals org.cmacs.Editor1.Tools makes before a
           * tool starts (cmacs-capability.el, "Gate order"). */
          || g_str_has_suffix (name, ".Error.NoSuchTool")
          || g_str_has_suffix (name, ".Error.NotOnSurface")
          || g_str_has_suffix (name, ".Error.BadArguments")))
    verdict = CTL_ALIAS_FALLBACK;
  g_free (name);
  return verdict;
}

gint
ctl_alias_timeout_ms (const CtlAliasSpec *spec, gint base_ms)
{
  gint64 need;

  /* -1 is "the GDBus default" and 0 or less from the row is "the tool
   * is synchronous": neither is raised. */
  if (base_ms < 0 || spec->timeout_s <= 0)
    return base_ms;
  /* A margin past the tool's own timeout, so the answer that reports
   * the timeout arrives instead of being abandoned at the same
   * instant (the same margin `emacsctl tool' adds). */
  need = (gint64) spec->timeout_s * 1000 + 5000;
  if (need > G_MAXINT)
    need = G_MAXINT;
  return need > base_ms ? (gint) need : base_ms;
}

/* ── Output ──────────────────────────────────────────────────────── */

gchar *
ctl_alias_unprint (const gchar *text)
{
  gsize len;
  GString *out;
  const gchar *c, *end;

  if (text == NULL)
    return g_strdup ("");
  len = strlen (text);
  if (len < 2 || text[0] != '"' || text[len - 1] != '"')
    return g_strdup (text);

  out = g_string_sized_new (len);
  end = text + len - 1;
  for (c = text + 1; c < end; c++)
    {
      if (*c == '"')
        {
          /* An unescaped quote inside: this was never one printed
           * string (two JSON strings side by side, say).  Leave it. */
          g_string_free (out, TRUE);
          return g_strdup (text);
        }
      if (*c == '\\')
        {
          if (c + 1 >= end)
            {
              /* The closing quote was itself escaped. */
              g_string_free (out, TRUE);
              return g_strdup (text);
            }
          /* `prin1' escapes only `"' and `\'.  Any other backslash
           * pair (an octal byte in a unibyte string) is kept whole
           * rather than guessed at. */
          if (c[1] != '"' && c[1] != '\\')
            g_string_append_c (out, '\\');
          c++;
        }
      g_string_append_c (out, *c);
    }
  return g_string_free (out, FALSE);
}

CtlResult *
ctl_alias_format_result (CtlAliasFormat format, const gchar *text)
{
  CtlResult *result = NULL;

  if (text == NULL)
    text = "";

  switch (format)
    {
    case CTL_ALIAS_JSON:
      {
        JsonParser *parser = json_parser_new ();

        if (json_parser_load_from_data (parser, text, -1, NULL)
            && json_parser_get_root (parser) != NULL)
          result = ctl_result_new_document (
            json_node_copy (json_parser_get_root (parser)));
        g_object_unref (parser);
      }
      break;

    case CTL_ALIAS_PRINTED:
      {
        gchar *plain = ctl_alias_unprint (text);

        result = ctl_result_new_scalar (plain);
        g_free (plain);
      }
      break;

    case CTL_ALIAS_PRINTED_LINES:
      {
        gchar *plain = ctl_alias_unprint (text);
        gchar **lines = g_strsplit (plain, "\n", -1);
        JsonArray *rows = json_array_new ();
        gint k;

        /* No row for an empty line: the old (as) reply had none, and
         * "no matches" is an empty list rather than one blank row. */
        for (k = 0; lines[k] != NULL; k++)
          if (*lines[k] != '\0')
            json_array_add_string_element (rows, lines[k]);
        g_strfreev (lines);
        g_free (plain);
        result = ctl_result_new_list (rows);
      }
      break;

    case CTL_ALIAS_TEXT:
    default:
      break;
    }

  if (result == NULL)
    result = ctl_result_new_scalar (text);
  return result;
}

/* ── Help ────────────────────────────────────────────────────────── */

/* The string member KEY of OBJ, or FALLBACK.  The table is remote
 * input, so the type is checked rather than assumed. */
static const gchar *
alias_member_string (JsonObject *obj, const gchar *key,
                     const gchar *fallback)
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

/* TOOL's parameter called NAME, or NULL. */
static JsonObject *
alias_tool_param (JsonObject *tool, const gchar *name)
{
  JsonNode *node;
  JsonArray *params;
  guint n, k;

  if (tool == NULL || !json_object_has_member (tool, "params"))
    return NULL;
  node = json_object_get_member (tool, "params");
  if (!JSON_NODE_HOLDS_ARRAY (node))
    return NULL;
  params = json_node_get_array (node);
  n = json_array_get_length (params);
  for (k = 0; k < n; k++)
    {
      JsonNode *element = json_array_get_element (params, k);
      JsonObject *param;

      if (!JSON_NODE_HOLDS_OBJECT (element))
        continue;
      param = json_node_get_object (element);
      if (g_strcmp0 (alias_member_string (param, "name", NULL), name) == 0)
        return param;
    }
  return NULL;
}

/* "tool calc eval" when the table says where the tool lives on the
 * CLI, "tool call calc_eval" otherwise -- which always works.  Caller
 * g_frees. */
static gchar *
alias_target (const CtlAliasSpec *spec, JsonObject *tool)
{
  const gchar *cli = alias_member_string (tool, "cli", NULL);

  return (cli != NULL && *cli != '\0')
    ? g_strdup_printf ("tool %s", cli)
    : g_strdup_printf ("tool call %s", spec->tool);
}

gchar *
ctl_alias_summary (const CtlAliasSpec *spec, JsonObject *tool)
{
  const gchar *desc = alias_member_string (tool, "description", NULL);
  gchar *target = alias_target (spec, tool);
  gchar *first, *out;

  if (desc != NULL && *desc != '\0')
    {
      /* The first sentence, as `emacsctl tool list' cuts it. */
      const gchar *stop = strstr (desc, ".  ");
      const gchar *newline = strchr (desc, '\n');

      if (stop == NULL)
        stop = strstr (desc, ". ");
      if (stop != NULL && (newline == NULL || stop < newline))
        first = g_strndup (desc, stop - desc + 1);
      else if (newline != NULL)
        first = g_strndup (desc, newline - desc);
      else
        first = g_strdup (desc);
    }
  else
    first = g_strdup (spec->legacy.summary != NULL
                      ? spec->legacy.summary : "");

  out = g_strdup_printf ("%s  [= %s]", first, target);
  g_free (first);
  g_free (target);
  return out;
}

/* What an argspec letter is called in help. */
static const gchar *
alias_type_word (gchar type)
{
  switch (type)
    {
    case 'i': case 'u': case 'x': case 't': return "integer";
    case 'd': return "number";
    case 'b': return "true|false";
    default:  return "string";
    }
}

gchar *
ctl_alias_help_string (const CtlAliasSpec *spec, JsonObject *tool,
                       const gchar *prog)
{
  GString *out = g_string_new (NULL);
  AliasArg *args;
  gchar **specs = NULL, **params = NULL;
  gchar *usage = ctl_method_spec_usage (spec->legacy.argspec);
  gchar *target = alias_target (spec, tool);
  const gchar *desc = alias_member_string (tool, "description", NULL);
  guint n = 0, k;

  g_string_append_printf (out, "Usage:\n  %s [OPTION…] %s%s%s\n\n", prog,
                          spec->legacy.name, *usage != '\0' ? " " : "",
                          usage);

  /* The description is the tool's: the text the editor publishes to
   * every surface, so this page cannot say something `emacsctl tool
   * ... --help' does not. */
  g_string_append_printf (out, "%s\n\n",
                          (desc != NULL && *desc != '\0')
                          ? desc
                          : (spec->legacy.summary != NULL
                             ? spec->legacy.summary : ""));

  args = alias_args (spec, &n, &specs, &params, NULL);
  g_string_append (out, "Arguments:\n");
  if (args == NULL || n == 0)
    g_string_append (out, "  (none)\n");
  for (k = 0; args != NULL && k < n; k++)
    {
      JsonObject *param = alias_tool_param (tool, args[k].param);
      gchar *label = g_strdup_printf (args[k].optional ? "[%s]" : "<%s>",
                                      args[k].argname);
      gchar *fallback = alias_default (spec, args[k].param);
      const gchar *text = alias_member_string (param, "description", "");
      const gchar *type = alias_member_string (
        param, "type", alias_type_word (args[k].type));

      /* No padding after the last column that has anything in it. */
      if (*text != '\0' || fallback != NULL)
        g_string_append_printf (out, "  %-18s %-10s %s", label, type, text);
      else
        g_string_append_printf (out, "  %-18s %s", label, type);
      if (fallback != NULL)
        g_string_append_printf (out, "%s(default here: %s)",
                                *text != '\0' ? " " : "", fallback);
      g_string_append_c (out, '\n');
      g_free (label);
      g_free (fallback);
    }
  if (args != NULL)
    alias_args_free (args, specs, params);

  g_string_append_printf (out, "\nSame as: %s %s", prog, target);
  args = alias_args (spec, &n, &specs, &params, NULL);
  for (k = 0; args != NULL && k < n; k++)
    {
      gchar *flag = g_strdelimit (g_strdup (args[k].param), "_", '-');

      if (args[k].type == 'b')
        g_string_append_printf (out, " [--%s]", flag);
      else
        g_string_append_printf (out, args[k].optional ? " [--%s %s]"
                                                      : " --%s %s",
                                flag, args[k].argname);
      g_free (flag);
    }
  if (args != NULL)
    alias_args_free (args, specs, params);
  g_string_append_c (out, '\n');

  if (tool != NULL)
    g_string_append_printf (
      out,
      "This verb is an alias.  The description and arguments above "
      "are the running\ncmacs's own; every flag the tool takes is in\n"
      "  %s %s --help\n", prog, target);
  else
    g_string_append_printf (
      out,
      "This verb is an alias of the tool `%s'.\nNo running cmacs "
      "answered with its tool list, so the text above is the\n"
      "built-in summary.\n", spec->tool);

  g_string_append_printf (
    out, "\nRun '%s --help' for the global options.\n", prog);

  g_free (usage);
  g_free (target);
  return g_string_free (out, FALSE);
}
