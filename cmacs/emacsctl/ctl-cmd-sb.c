/*
 * Copyright (C) 2026 Zach Podbielniak
 * SPDX-License-Identifier: AGPL-3.0-or-later
 */

/* ctl-cmd-sb.c --- the `sb' command group: the second brain from a shell.
 *
 *   emacsctl sb ingest [FLAGS] [URL|FILE...]     file things into the notes
 *   emacsctl sb status ID / jobs / cancel ID     follow the queue
 *   emacsctl sb tree / find / doctor             look at the tree
 *   emacsctl sb open / search / stats / ...      drive the visualiser
 *
 * `second-brain' and `secondbrain' are aliases of `sb'.
 *
 * Everything talks to org.cmacs.Editor1.SecondBrain (cmacs/dbus/
 * cmacs-dbus-iface-secondbrain.c), which in turn calls the same Elisp
 * the MCP tools and the keyboard do.  Ingest is asynchronous on the
 * editor's side: the method returns queued jobs, and `--wait' polls
 * IngestStatus here, in the client, until they finish.  Polling from
 * the client rather than blocking in the editor is deliberate -- a
 * `--gowl' editor's main thread is the desktop.  */

#include "ctl-command-registry.h"
#include "ctl-ifaces.h"
#include "ctl-invocation.h"
#include "ctl-result.h"
#include "ctl-transport.h"
#include "ctl.h"

#include <json-glib/json-glib.h>
#include <stdio.h>
#include <string.h>
#include <unistd.h>

void ctl_cmd_sb_register (CtlCommandRegistry *registry);

/* ── Table-driven verbs (one D-Bus call, one reply) ──────────────── */

static const CtlMethodSpec sb_specs[] = {
  { "sb open", "Open the second-brain visualiser (--3d via 'sb open true')",
    CTL_IFACE_SECONDBRAIN, "Open", "b?:three_d", CTL_REPLY_STRING },
  { "sb layout", "Switch the visualiser layout: rings, circle, hex, force",
    CTL_IFACE_SECONDBRAIN, "SetLayout", "s:kind", CTL_REPLY_STRING },
  { "sb search", "Highlight nodes matching QUERY (SEMANTIC true = embeddings)",
    CTL_IFACE_SECONDBRAIN, "Search", "s:query b?:semantic", CTL_REPLY_STRING },
  { "sb expand", "Expand (or COLLAPSE true) a department by id; empty id = all",
    CTL_IFACE_SECONDBRAIN, "Expand", "s?:id b?:collapse", CTL_REPLY_STRING },
  { "sb node", "The full record for a node id",
    CTL_IFACE_SECONDBRAIN, "NodeInfo", "s:id", CTL_REPLY_STRING },
  { "sb stats", "Node, visible and edge counts of the open view",
    CTL_IFACE_SECONDBRAIN, "Stats", NULL, CTL_REPLY_STRING },
  { "sb sources", "The registered ARMS data sources",
    CTL_IFACE_SECONDBRAIN, "Sources", NULL, CTL_REPLY_STRING },
  { "sb refresh", "Re-read every source and rebuild the view",
    CTL_IFACE_SECONDBRAIN, "Refresh", NULL, CTL_REPLY_STRING },
  { "sb jobs", "Every ingest job this session, with its state",
    CTL_IFACE_SECONDBRAIN, "IngestList", NULL, CTL_REPLY_JSON },
  { "sb status", "Status of one ingest job",
    CTL_IFACE_SECONDBRAIN, "IngestStatus", "s:id", CTL_REPLY_JSON },
  { "sb cancel", "Cancel an ingest job",
    CTL_IFACE_SECONDBRAIN, "IngestCancel", "s:id", CTL_REPLY_JSON },
  { "sb doctor", "Which programs and features the ingester can use here",
    CTL_IFACE_SECONDBRAIN, "Doctor", NULL, CTL_REPLY_JSON },
  { "sb watch", "Watch the drop folder in the editor (true) or stop (false)",
    CTL_IFACE_SECONDBRAIN, "Watch", "b:enable", CTL_REPLY_STRING },
  { NULL, NULL, NULL, NULL, NULL, 0 }
};

/* ── Flag-driven verbs ───────────────────────────────────────────── */

/* Call a SecondBrain method and return its (s) reply.  Caller g_frees. */
static gchar *
sb_call (CtlInvocation *inv, const gchar *method, GVariant *params,
         GError **error)
{
  CtlTransport *transport;
  GVariant *reply;
  gchar *out;

  transport = ctl_invocation_get_transport (inv, error);
  if (transport == NULL)
    {
      if (params != NULL)
        g_variant_unref (g_variant_ref_sink (params));
      return NULL;
    }
  reply = ctl_transport_call (transport, CTL_IFACE_SECONDBRAIN, method,
                              params, ctl_invocation_get_timeout_ms (inv),
                              error);
  if (reply == NULL)
    return NULL;
  g_variant_get (reply, "(s)", &out);
  g_variant_unref (reply);
  return out;
}

/* Emit JSON text as a document result when it parses, else as a scalar. */
static gint
sb_emit_json (CtlInvocation *inv, const gchar *json, GError **error)
{
  JsonParser *parser = json_parser_new ();
  CtlResult *result;
  gboolean ok;

  if (json_parser_load_from_data (parser, json, -1, NULL))
    result = ctl_result_new_document (
      json_node_copy (json_parser_get_root (parser)));
  else
    result = ctl_result_new_scalar (json);
  g_object_unref (parser);

  ok = ctl_invocation_emit (inv, result, error);
  ctl_result_unref (result);
  return ok ? CTL_EXIT_OK : CTL_EXIT_ERROR;
}

/* -- sb ingest ---------------------------------------------------- */

static gchar *sb_opt_para = NULL;
static gchar *sb_opt_category = NULL;
static gchar *sb_opt_directory = NULL;
static gchar *sb_opt_tags = NULL;
static gchar *sb_opt_type = NULL;
static gchar *sb_opt_prompt = NULL;
static gboolean sb_opt_principle = FALSE;
static gboolean sb_opt_no_summary = FALSE;
static gboolean sb_opt_no_ai = FALSE;
static gboolean sb_opt_sanitize = FALSE;
static gchar *sb_opt_sanitize_rules = NULL;
static gchar *sb_opt_provider = NULL;
static gchar *sb_opt_model = NULL;
static gchar *sb_opt_name = NULL;
static gchar *sb_opt_title = NULL;
static gchar *sb_opt_format = NULL;
static gboolean sb_opt_stdin = FALSE;
static gboolean sb_opt_crawl = FALSE;
static gint sb_opt_depth = -1;
static gint sb_opt_max_pages = -1;
static gchar *sb_opt_include = NULL;
static gchar *sb_opt_exclude = NULL;
static gboolean sb_opt_recursive = FALSE;
static gboolean sb_opt_append = FALSE;
static gboolean sb_opt_dry_run = FALSE;
static gboolean sb_opt_no_link = FALSE;
static gboolean sb_opt_keep_source = FALSE;
static gchar *sb_opt_root = NULL;
static gchar *sb_opt_branch = NULL;
static gchar *sb_opt_web = NULL;
static gboolean sb_opt_wait = FALSE;
static gint sb_opt_wait_timeout = 900;

static const GOptionEntry sb_ingest_entries[] = {
  { "para", 'p', 0, G_OPTION_ARG_STRING, &sb_opt_para,
    "PARA category: inbox, projects, areas, resources, or detect "
    "(default: the editor's configured placement)", "CATEGORY" },
  { "category", 'c', 0, G_OPTION_ARG_STRING, &sb_opt_category,
    "Sub path under the PARA category, e.g. technical/linux", "PATH" },
  { "directory", 'd', 0, G_OPTION_ARG_STRING, &sb_opt_directory,
    "Exact directory under the root, overriding -p/-c", "PATH" },
  { "tags", 't', 0, G_OPTION_ARG_STRING, &sb_opt_tags,
    "Comma-separated tags to add", "TAGS" },
  { "type", 'T', 0, G_OPTION_ARG_STRING, &sb_opt_type,
    "Summary type: general, meeting, book, youtube, ... or auto", "TYPE" },
  { "prompt", 0, 0, G_OPTION_ARG_STRING, &sb_opt_prompt,
    "Extra instructions for the summary", "TEXT" },
  { "principle", 0, 0, G_OPTION_ARG_NONE, &sb_opt_principle,
    "Add a principles section to the summary", NULL },
  { "no-summary", 'n', 0, G_OPTION_ARG_NONE, &sb_opt_no_summary,
    "Skip the AI summary (the model may still place and tag)", NULL },
  { "no-ai", 'N', 0, G_OPTION_ARG_NONE, &sb_opt_no_ai,
    "No model at all: source title, no tags, inbox or the given place", NULL },
  { "sanitize", 's', 0, G_OPTION_ARG_NONE, &sb_opt_sanitize,
    "Redact secrets before the model sees them and before storing "
    "(the default-on rules)", NULL },
  { "sanitize-rules", 0, 0, G_OPTION_ARG_STRING, &sb_opt_sanitize_rules,
    "Redact with exactly these rules, e.g. email,phone,bank-account "
    "(implies -s)", "RULES" },
  { "provider", 'P', 0, G_OPTION_ARG_STRING, &sb_opt_provider,
    "AI provider (default: claude-code)", "NAME" },
  { "model", 'm', 0, G_OPTION_ARG_STRING, &sb_opt_model,
    "Model (default: sonnet)", "MODEL" },
  { "name", 0, 0, G_OPTION_ARG_STRING, &sb_opt_name,
    "Seed for the file name instead of the title", "NAME" },
  { "title", 0, 0, G_OPTION_ARG_STRING, &sb_opt_title,
    "Title to use instead of the material's own", "TITLE" },
  { "format", 'f', 0, G_OPTION_ARG_STRING, &sb_opt_format,
    "Format of stdin text: org, markdown, text, json, csv, html", "FORMAT" },
  { "stdin", 'i', 0, G_OPTION_ARG_NONE, &sb_opt_stdin,
    "Read the material from stdin (also implied by '-' as the input)", NULL },
  { "crawl", 0, 0, G_OPTION_ARG_NONE, &sb_opt_crawl,
    "Crawl the URL's site: one note per page under a site index", NULL },
  { "depth", 0, 0, G_OPTION_ARG_INT, &sb_opt_depth,
    "Crawl link depth (default from the editor's config)", "N" },
  { "max-pages", 0, 0, G_OPTION_ARG_INT, &sb_opt_max_pages,
    "Crawl page cap", "N" },
  { "include", 0, 0, G_OPTION_ARG_STRING, &sb_opt_include,
    "Crawl only URLs matching this Emacs regexp", "REGEXP" },
  { "exclude", 0, 0, G_OPTION_ARG_STRING, &sb_opt_exclude,
    "Skip URLs matching this Emacs regexp while crawling", "REGEXP" },
  { "recursive", 'r', 0, G_OPTION_ARG_NONE, &sb_opt_recursive,
    "Descend into directories given as inputs", NULL },
  { "append", 'a', 0, G_OPTION_ARG_NONE, &sb_opt_append,
    "Append to an existing note of the same name instead of uniquifying", NULL },
  { "dry-run", 0, 0, G_OPTION_ARG_NONE, &sb_opt_dry_run,
    "Report what would happen (kind, strategies, target) and stop", NULL },
  { "no-link", 0, 0, G_OPTION_ARG_NONE, &sb_opt_no_link,
    "Do not add related notes", NULL },
  { "keep-source", 0, 0, G_OPTION_ARG_NONE, &sb_opt_keep_source,
    "Copy the original file into .attachments beside the note", NULL },
  { "root", 0, 0, G_OPTION_ARG_STRING, &sb_opt_root,
    "Notes root to use instead of the configured one", "DIR" },
  { "branch", 'b', 0, G_OPTION_ARG_STRING, &sb_opt_branch,
    "Use the worktree ROOT/trees/NAME", "NAME" },
  { "web", 0, 0, G_OPTION_ARG_STRING, &sb_opt_web,
    "Page fetcher: url, or gsurf (JavaScript runs, logins apply)", "BACKEND" },
  { "wait", 'w', 0, G_OPTION_ARG_NONE, &sb_opt_wait,
    "Poll until every job finishes and print the final statuses", NULL },
  { "wait-timeout", 0, 0, G_OPTION_ARG_INT, &sb_opt_wait_timeout,
    "Give up waiting after this many seconds (default 900)", "SECONDS" },
  { NULL, 0, 0, 0, NULL, NULL, NULL }
};

/* Read all of stdin.  Caller g_frees. */
static gchar *
sb_read_stdin (void)
{
  GString *buf = g_string_new (NULL);
  gchar chunk[4096];
  gsize got;

  while ((got = fread (chunk, 1, sizeof chunk, stdin)) > 0)
    g_string_append_len (buf, chunk, got);
  return g_string_free (buf, FALSE);
}

static void
sb_add_str (JsonBuilder *b, const gchar *key, const gchar *value)
{
  if (value == NULL || *value == '\0')
    return;
  json_builder_set_member_name (b, key);
  json_builder_add_string_value (b, value);
}

static void
sb_add_bool (JsonBuilder *b, const gchar *key, gboolean value)
{
  if (!value)
    return;
  json_builder_set_member_name (b, key);
  json_builder_add_boolean_value (b, TRUE);
}

static void
sb_add_int (JsonBuilder *b, const gchar *key, gint value)
{
  if (value < 0)
    return;
  json_builder_set_member_name (b, key);
  json_builder_add_int_value (b, value);
}

/* Serialise a builder's root.  Caller g_frees. */
static gchar *
sb_builder_to_string (JsonBuilder *b)
{
  JsonGenerator *gen = json_generator_new ();
  JsonNode *root = json_builder_get_root (b);
  gchar *out;

  json_generator_set_root (gen, root);
  out = json_generator_to_data (gen, NULL);
  json_node_free (root);
  g_object_unref (gen);
  return out;
}

/* Build the options object from the parsed flags (and TEXT when the
 * material came from stdin).  Caller g_frees. */
static gchar *
sb_options_json (const gchar *text)
{
  JsonBuilder *b = json_builder_new ();
  gchar *out;

  json_builder_begin_object (b);
  sb_add_str (b, "para", sb_opt_para);
  sb_add_str (b, "category", sb_opt_category);
  sb_add_str (b, "directory", sb_opt_directory);
  sb_add_str (b, "tags", sb_opt_tags);
  sb_add_str (b, "type", sb_opt_type);
  sb_add_str (b, "prompt", sb_opt_prompt);
  sb_add_bool (b, "principle", sb_opt_principle);
  sb_add_bool (b, "no_summary", sb_opt_no_summary);
  sb_add_bool (b, "no_ai", sb_opt_no_ai);
  /* `-s' alone is the default rule set; `--sanitize-rules a,b' names rules. */
  if (sb_opt_sanitize_rules != NULL && *sb_opt_sanitize_rules != '\0')
    sb_add_str (b, "sanitize", sb_opt_sanitize_rules);
  else if (sb_opt_sanitize)
    sb_add_str (b, "sanitize", "t");
  sb_add_str (b, "provider", sb_opt_provider);
  sb_add_str (b, "model", sb_opt_model);
  sb_add_str (b, "name", sb_opt_name);
  sb_add_str (b, "title", sb_opt_title);
  sb_add_str (b, "format", sb_opt_format);
  sb_add_str (b, "text", text);
  sb_add_bool (b, "crawl", sb_opt_crawl);
  sb_add_int (b, "depth", sb_opt_depth);
  sb_add_int (b, "max_pages", sb_opt_max_pages);
  sb_add_str (b, "include", sb_opt_include);
  sb_add_str (b, "exclude", sb_opt_exclude);
  sb_add_bool (b, "recursive", sb_opt_recursive);
  sb_add_bool (b, "append", sb_opt_append);
  sb_add_bool (b, "dry_run", sb_opt_dry_run);
  if (sb_opt_no_link)
    {
      json_builder_set_member_name (b, "link");
      json_builder_add_boolean_value (b, FALSE);
    }
  if (sb_opt_keep_source)
    sb_add_str (b, "keep_source", "copy");
  sb_add_str (b, "root", sb_opt_root);
  sb_add_str (b, "branch", sb_opt_branch);
  sb_add_str (b, "web_backend", sb_opt_web);
  json_builder_end_object (b);

  out = sb_builder_to_string (b);
  g_object_unref (b);
  return out;
}

/* The inputs array from the positionals.  Caller g_frees. */
static gchar *
sb_inputs_json (gchar **argv, gint argc)
{
  JsonBuilder *b = json_builder_new ();
  gchar *out;
  gint k;

  json_builder_begin_array (b);
  for (k = 0; k < argc; k++)
    {
      /* Relative paths are resolved HERE, in the shell's cwd: the editor
       * has its own idea of a working directory and it is never the
       * caller's. */
      if (g_str_has_prefix (argv[k], "http://")
          || g_str_has_prefix (argv[k], "https://")
          || g_path_is_absolute (argv[k]))
        json_builder_add_string_value (b, argv[k]);
      else
        {
          gchar *cwd = g_get_current_dir ();
          gchar *abs = g_build_filename (cwd, argv[k], NULL);
          json_builder_add_string_value (b, abs);
          g_free (abs);
          g_free (cwd);
        }
    }
  json_builder_end_array (b);
  out = sb_builder_to_string (b);
  g_object_unref (b);
  return out;
}

/* Collect the job ids out of an Ingest reply.  Caller g_strfreevs. */
static gchar **
sb_job_ids (const gchar *jobs_json)
{
  JsonParser *parser = json_parser_new ();
  GPtrArray *ids = g_ptr_array_new ();

  if (json_parser_load_from_data (parser, jobs_json, -1, NULL))
    {
      JsonNode *root = json_parser_get_root (parser);
      if (JSON_NODE_HOLDS_ARRAY (root))
        {
          JsonArray *arr = json_node_get_array (root);
          guint n = json_array_get_length (arr);
          guint k;

          for (k = 0; k < n; k++)
            {
              JsonObject *o = json_array_get_object_element (arr, k);
              if (o != NULL && json_object_has_member (o, "id"))
                g_ptr_array_add (ids, g_strdup (
                  json_object_get_string_member (o, "id")));
            }
        }
    }
  g_object_unref (parser);
  g_ptr_array_add (ids, NULL);
  return (gchar **) g_ptr_array_free (ids, FALSE);
}

/* Poll IngestStatus for every id until all report done, or the deadline.
 * Returns a JSON array of the final statuses.  Caller g_frees; NULL on
 * a transport error. */
static gchar *
sb_wait_for (CtlInvocation *inv, gchar **ids, gint timeout_s,
             GError **error)
{
  gint64 deadline = g_get_monotonic_time () + (gint64) timeout_s * G_USEC_PER_SEC;
  guint n = g_strv_length (ids);
  gchar **last = g_new0 (gchar *, n + 1);
  gboolean all_done = FALSE;
  GString *out;
  guint k;

  while (!all_done)
    {
      all_done = TRUE;
      for (k = 0; k < n; k++)
        {
          gchar *status;
          JsonParser *parser;

          status = sb_call (inv, "IngestStatus",
                            g_variant_new ("(s)", ids[k]), error);
          if (status == NULL)
            {
              g_strfreev (last);
              return NULL;
            }
          g_free (last[k]);
          last[k] = status;

          parser = json_parser_new ();
          if (json_parser_load_from_data (parser, status, -1, NULL))
            {
              JsonObject *o = json_node_get_object (json_parser_get_root (parser));
              if (o != NULL
                  && (!json_object_has_member (o, "done")
                      || !json_object_get_boolean_member (o, "done")))
                all_done = FALSE;
            }
          g_object_unref (parser);
        }
      if (!all_done)
        {
          if (g_get_monotonic_time () > deadline)
            {
              fprintf (stderr, "sb ingest: still running after %ds; "
                       "follow with 'emacsctl sb jobs'\n", timeout_s);
              break;
            }
          g_usleep (750 * 1000);
        }
    }

  out = g_string_new ("[");
  for (k = 0; k < n; k++)
    {
      if (k > 0)
        g_string_append_c (out, ',');
      g_string_append (out, last[k]);
    }
  g_string_append_c (out, ']');
  g_strfreev (last);
  return g_string_free (out, FALSE);
}

static gint
cmd_sb_ingest (CtlCommand *self, CtlInvocation *inv, GError **error)
{
  gint argc = 0;
  gchar **argv = ctl_invocation_get_args (inv, &argc);
  gchar *text = NULL;
  gchar *inputs, *options, *reply;
  gint code;
  gint k;

  (void) self;

  /* `-' as an input means stdin, like every other Unix tool. */
  for (k = 0; k < argc; k++)
    if (g_strcmp0 (argv[k], "-") == 0)
      sb_opt_stdin = TRUE;

  if (sb_opt_stdin || (argc == 0 && !isatty (STDIN_FILENO)))
    {
      text = sb_read_stdin ();
      if (*text == '\0')
        {
          g_free (text);
          text = NULL;
        }
    }

  {
    /* Positionals minus any `-'. */
    GPtrArray *real = g_ptr_array_new ();
    for (k = 0; k < argc; k++)
      if (g_strcmp0 (argv[k], "-") != 0)
        g_ptr_array_add (real, argv[k]);
    if (real->len == 0 && text == NULL)
      {
        g_ptr_array_free (real, TRUE);
        g_set_error (error, CTL_ERROR, CTL_ERROR_USAGE,
                     "nothing to ingest: give a URL or file, or pipe text "
                     "(see 'sb ingest --help')");
        return CTL_EXIT_USAGE;
      }
    inputs = sb_inputs_json ((gchar **) real->pdata, (gint) real->len);
    g_ptr_array_free (real, TRUE);
  }

  options = sb_options_json (text);
  g_free (text);

  reply = sb_call (inv, "Ingest", g_variant_new ("(ss)", inputs, options),
                   error);
  g_free (inputs);
  g_free (options);
  if (reply == NULL)
    return ctl_exit_code_for_error (error != NULL ? *error : NULL);

  if (sb_opt_wait && !sb_opt_dry_run)
    {
      gchar **ids = sb_job_ids (reply);
      gchar *final;

      if (ids[0] == NULL)
        {
          g_strfreev (ids);
          code = sb_emit_json (inv, reply, error);
          g_free (reply);
          return code;
        }
      final = sb_wait_for (inv, ids, sb_opt_wait_timeout, error);
      g_strfreev (ids);
      g_free (reply);
      if (final == NULL)
        return ctl_exit_code_for_error (error != NULL ? *error : NULL);
      code = sb_emit_json (inv, final, error);
      g_free (final);
      return code;
    }

  code = sb_emit_json (inv, reply, error);
  g_free (reply);
  return code;
}

/* -- sb tree ------------------------------------------------------ */

static gchar *sb_tree_para = NULL;
static gchar *sb_tree_category = NULL;
static gboolean sb_tree_files = FALSE;

static const GOptionEntry sb_tree_entries[] = {
  { "para", 'p', 0, G_OPTION_ARG_STRING, &sb_tree_para,
    "Only this category: inbox, projects, areas, resources, archives",
    "CATEGORY" },
  { "category", 'c', 0, G_OPTION_ARG_STRING, &sb_tree_category,
    "Only this sub path under the category", "PATH" },
  { "files", 'f', 0, G_OPTION_ARG_NONE, &sb_tree_files,
    "List .org files as well as directories", NULL },
  { NULL, 0, 0, 0, NULL, NULL, NULL }
};

static gint
cmd_sb_tree (CtlCommand *self, CtlInvocation *inv, GError **error)
{
  gchar *reply;
  gint code;

  (void) self;

  reply = sb_call (inv, "Tree",
                   g_variant_new ("(ssb)",
                                  sb_tree_para != NULL ? sb_tree_para : "",
                                  sb_tree_category != NULL ? sb_tree_category : "",
                                  sb_tree_files),
                   error);
  if (reply == NULL)
    return ctl_exit_code_for_error (error != NULL ? *error : NULL);

  /* A table of paths reads as one path per line; json/yaml get the array. */
  if (g_strcmp0 (ctl_invocation_get_output (inv), "json") == 0
      || g_strcmp0 (ctl_invocation_get_output (inv), "yaml") == 0)
    code = sb_emit_json (inv, reply, error);
  else
    {
      JsonParser *parser = json_parser_new ();
      CtlResult *result;
      gboolean ok;

      if (json_parser_load_from_data (parser, reply, -1, NULL)
          && JSON_NODE_HOLDS_ARRAY (json_parser_get_root (parser)))
        {
          JsonArray *arr = json_node_get_array (json_parser_get_root (parser));
          JsonArray *rows = json_array_new ();
          guint n = json_array_get_length (arr);
          guint k;

          for (k = 0; k < n; k++)
            json_array_add_string_element (
              rows, json_array_get_string_element (arr, k));
          result = ctl_result_new_list (rows);
        }
      else
        result = ctl_result_new_scalar (reply);
      g_object_unref (parser);
      ok = ctl_invocation_emit (inv, result, error);
      ctl_result_unref (result);
      code = ok ? CTL_EXIT_OK : CTL_EXIT_ERROR;
    }
  g_free (reply);
  return code;
}

/* -- sb find ------------------------------------------------------ */

static gint sb_find_limit = 10;

static const GOptionEntry sb_find_entries[] = {
  { "limit", 'k', 0, G_OPTION_ARG_INT, &sb_find_limit,
    "Most results to return (default 10)", "N" },
  { NULL, 0, 0, 0, NULL, NULL, NULL }
};

static gint
cmd_sb_find (CtlCommand *self, CtlInvocation *inv, GError **error)
{
  gint argc = 0;
  gchar **argv = ctl_invocation_get_args (inv, &argc);
  gchar *query, *reply;
  gint code;

  (void) self;

  if (argc == 0)
    {
      g_set_error (error, CTL_ERROR, CTL_ERROR_USAGE,
                   "sb find needs a query");
      return CTL_EXIT_USAGE;
    }
  query = g_strjoinv (" ", argv);
  reply = sb_call (inv, "Find", g_variant_new ("(si)", query, sb_find_limit),
                   error);
  g_free (query);
  if (reply == NULL)
    return ctl_exit_code_for_error (error != NULL ? *error : NULL);

  if (g_strcmp0 (ctl_invocation_get_output (inv), "json") == 0
      || g_strcmp0 (ctl_invocation_get_output (inv), "yaml") == 0)
    code = sb_emit_json (inv, reply, error);
  else
    {
      JsonParser *parser = json_parser_new ();
      CtlResult *result;
      gboolean ok;

      if (json_parser_load_from_data (parser, reply, -1, NULL)
          && JSON_NODE_HOLDS_ARRAY (json_parser_get_root (parser)))
        {
          result = ctl_result_new_list (
            json_array_ref (json_node_get_array (json_parser_get_root (parser))));
          ctl_result_add_column (result, "Title", "title");
          ctl_result_add_column (result, "Path", "path");
          ctl_result_add_column (result, "Score", "score");
        }
      else
        result = ctl_result_new_scalar (reply);
      g_object_unref (parser);
      ok = ctl_invocation_emit (inv, result, error);
      ctl_result_unref (result);
      code = ok ? CTL_EXIT_OK : CTL_EXIT_ERROR;
    }
  g_free (reply);
  return code;
}

/* -- sb migrate --------------------------------------------------- */

static gboolean sb_mig_apply = FALSE;
static gboolean sb_mig_archives = FALSE;
static gboolean sb_mig_ai = FALSE;
static gchar *sb_mig_remove = NULL;

static const GOptionEntry sb_migrate_entries[] = {
  { "apply", 0, 0, G_OPTION_ARG_NONE, &sb_mig_apply,
    "Perform the migration (default: only print the plan)", NULL },
  { "include-archives", 0, 0, G_OPTION_ARG_NONE, &sb_mig_archives,
    "Also migrate 04_archives", NULL },
  { "ai", 0, 0, G_OPTION_ARG_NONE, &sb_mig_ai,
    "Let the model summarise and tag each migrated note", NULL },
  { "remove", 0, 0, G_OPTION_ARG_STRING, &sb_mig_remove,
    "What to do with the originals after a successful migration: trash",
    "MODE" },
  { NULL, 0, 0, 0, NULL, NULL, NULL }
};

static gint
cmd_sb_migrate (CtlCommand *self, CtlInvocation *inv, GError **error)
{
  gint argc = 0;
  gchar **argv = ctl_invocation_get_args (inv, &argc);
  gchar *dir;
  gchar *options;
  gchar *reply;
  gint code;

  (void) self;

  if (argc > 0 && !g_path_is_absolute (argv[0]))
    {
      gchar *cwd = g_get_current_dir ();
      dir = g_build_filename (cwd, argv[0], NULL);
      g_free (cwd);
    }
  else
    dir = g_strdup (argc > 0 ? argv[0] : "");

  options = g_strdup_printf
    ("{\"apply\":%s,\"include_archives\":%s,\"ai\":%s,\"remove\":\"%s\"}",
     sb_mig_apply ? "true" : "false", sb_mig_archives ? "true" : "false",
     sb_mig_ai ? "true" : "false",
     (sb_mig_remove != NULL && g_strcmp0 (sb_mig_remove, "trash") == 0)
       ? "trash" : "");
  reply = sb_call (inv, "Migrate", g_variant_new ("(ss)", dir, options), error);
  g_free (dir);
  g_free (options);
  if (reply == NULL)
    return ctl_exit_code_for_error (error != NULL ? *error : NULL);
  code = sb_emit_json (inv, reply, error);
  g_free (reply);
  return code;
}

/* ── Registration ────────────────────────────────────────────────── */

void
ctl_cmd_sb_register (CtlCommandRegistry *registry)
{
  gint k;

  for (k = 0; sb_specs[k].name != NULL; k++)
    ctl_command_registry_add (registry,
                              ctl_method_command_new (&sb_specs[k]));

  ctl_command_registry_add (registry,
    ctl_simple_command_new_with_options (
      "sb ingest",
      "Ingest URLs, files or stdin into the second brain as Org notes",
      "[URL|FILE|-...]", sb_ingest_entries, cmd_sb_ingest));
  ctl_command_registry_add (registry,
    ctl_simple_command_new_with_options (
      "sb tree", "List the PARA notes tree",
      NULL, sb_tree_entries, cmd_sb_tree));
  ctl_command_registry_add (registry,
    ctl_simple_command_new_with_options (
      "sb find", "Search the notes (semantic when the memory index exists)",
      "QUERY...", sb_find_entries, cmd_sb_find));
  ctl_command_registry_add (registry,
    ctl_simple_command_new_with_options (
      "sb migrate", "Plan (or --apply) the Markdown-to-Org migration",
      "[DIR]", sb_migrate_entries, cmd_sb_migrate));

  ctl_command_registry_add_alias (registry, "second-brain", "sb");
  ctl_command_registry_add_alias (registry, "secondbrain", "sb");
  ctl_command_registry_add_alias (registry, "second_brain", "sb");
}
