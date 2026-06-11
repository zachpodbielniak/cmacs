/*
 * Copyright (C) 2026 Zach Podbielniak
 * SPDX-License-Identifier: AGPL-3.0-or-later
 */

/* ctl-config.c --- see ctl-config.h. */

#include "ctl-config.h"

#include <yaml-glib.h>
#include <string.h>

/* ── CtlContext ────────────────────────────────────────────────────── */

G_DEFINE_BOXED_TYPE (CtlContext, ctl_context,
                     ctl_context_copy, ctl_context_free)

CtlContext *
ctl_context_new (const gchar *name)
{
  CtlContext *self = g_slice_new0 (CtlContext);
  self->name = g_strdup (name);
  return self;
}

CtlContext *
ctl_context_copy (const CtlContext *self)
{
  CtlContext *copy = ctl_context_new (self->name);
  copy->instance = g_strdup (self->instance);
  copy->host = g_strdup (self->host);
  copy->output = g_strdup (self->output);
  copy->timeout = self->timeout;
  return copy;
}

void
ctl_context_free (CtlContext *self)
{
  if (self == NULL)
    return;
  g_free (self->name);
  g_free (self->instance);
  g_free (self->host);
  g_free (self->output);
  g_slice_free (CtlContext, self);
}

/* ── CtlConfig ─────────────────────────────────────────────────────── */

struct _CtlConfig
{
  GObject parent_instance;

  gchar *path;
  gchar *current_context;
  GPtrArray *contexts;        /* of CtlContext, owned */
  GHashTable *aliases;        /* str -> str, owned */
  gint timeout;
};

G_DEFINE_FINAL_TYPE (CtlConfig, ctl_config, G_TYPE_OBJECT)

static void
ctl_config_finalize (GObject *object)
{
  CtlConfig *self = CTL_CONFIG (object);
  g_free (self->path);
  g_free (self->current_context);
  g_ptr_array_unref (self->contexts);
  g_hash_table_unref (self->aliases);
  G_OBJECT_CLASS (ctl_config_parent_class)->finalize (object);
}

static void
ctl_config_class_init (CtlConfigClass *klass)
{
  G_OBJECT_CLASS (klass)->finalize = ctl_config_finalize;
}

static void
ctl_config_init (CtlConfig *self)
{
  self->contexts = g_ptr_array_new_with_free_func (
    (GDestroyNotify) ctl_context_free);
  self->aliases = g_hash_table_new_full (g_str_hash, g_str_equal,
                                         g_free, g_free);
}

gchar *
ctl_config_default_path (void)
{
  const gchar *env = g_getenv ("EMACSCTL_CONFIG");
  if (env != NULL && *env != '\0')
    return g_strdup (env);
  return g_build_filename (g_get_user_config_dir (), "cmacs",
                           "emacsctl.yaml", NULL);
}

static void
config_parse_root (CtlConfig *self, YamlNode *root)
{
  YamlMapping *map;
  const gchar *s;

  if (root == NULL || yaml_node_get_node_type (root) != YAML_NODE_MAPPING)
    return;
  map = yaml_node_get_mapping (root);

  s = yaml_mapping_get_string_member (map, "current-context");
  if (s != NULL)
    self->current_context = g_strdup (s);

  if (yaml_mapping_has_member (map, "contexts"))
    {
      YamlSequence *seq =
        yaml_mapping_get_sequence_member (map, "contexts");
      guint n = seq != NULL ? yaml_sequence_get_length (seq) : 0;
      guint k;
      for (k = 0; k < n; k++)
        {
          YamlNode *el = yaml_sequence_get_element (seq, k);
          YamlMapping *cm;
          CtlContext *ctx;
          if (el == NULL
              || yaml_node_get_node_type (el) != YAML_NODE_MAPPING)
            continue;
          cm = yaml_node_get_mapping (el);
          s = yaml_mapping_get_string_member (cm, "name");
          if (s == NULL)
            continue;
          ctx = ctl_context_new (s);
          ctx->instance =
            g_strdup (yaml_mapping_get_string_member (cm, "instance"));
          ctx->host =
            g_strdup (yaml_mapping_get_string_member (cm, "host"));
          ctx->output =
            g_strdup (yaml_mapping_get_string_member (cm, "output"));
          if (yaml_mapping_has_member (cm, "timeout"))
            ctx->timeout = (gint) yaml_mapping_get_int_member (cm,
                                                               "timeout");
          g_ptr_array_add (self->contexts, ctx);
        }
    }

  if (yaml_mapping_has_member (map, "aliases"))
    {
      YamlMapping *am = yaml_mapping_get_mapping_member (map, "aliases");
      if (am != NULL)
        {
          guint n = yaml_mapping_get_size (am);
          guint k;
          for (k = 0; k < n; k++)
            {
              const gchar *key = yaml_mapping_get_key (am, k);
              YamlNode *val = yaml_mapping_get_value (am, k);
              const gchar *vs =
                val != NULL ? yaml_node_get_string (val) : NULL;
              if (key != NULL && vs != NULL)
                g_hash_table_insert (self->aliases, g_strdup (key),
                                     g_strdup (vs));
            }
        }
    }

  if (yaml_mapping_has_member (map, "settings"))
    {
      YamlMapping *sm =
        yaml_mapping_get_mapping_member (map, "settings");
      if (sm != NULL && yaml_mapping_has_member (sm, "timeout"))
        self->timeout = (gint) yaml_mapping_get_int_member (sm,
                                                            "timeout");
    }
}

CtlConfig *
ctl_config_load (const gchar *path, GError **error)
{
  CtlConfig *self = g_object_new (CTL_TYPE_CONFIG, NULL);

  self->path = path != NULL ? g_strdup (path)
                            : ctl_config_default_path ();

  if (g_file_test (self->path, G_FILE_TEST_EXISTS))
    {
      YamlParser *parser = yaml_parser_new ();
      GError *local = NULL;
      if (!yaml_parser_load_from_file (parser, self->path, &local))
        {
          g_object_unref (parser);
          g_object_unref (self);
          g_propagate_prefixed_error (error, local, "%s: ", self->path);
          return NULL;
        }
      config_parse_root (self, yaml_parser_get_root (parser));
      g_object_unref (parser);
    }
  return self;
}

const gchar *
ctl_config_get_path (CtlConfig *self)
{
  return self->path;
}

const gchar *
ctl_config_get_current_context (CtlConfig *self)
{
  return self->current_context;
}

CtlContext *
ctl_config_get_context (CtlConfig *self, const gchar *name)
{
  guint k;
  for (k = 0; k < self->contexts->len; k++)
    {
      CtlContext *ctx = g_ptr_array_index (self->contexts, k);
      if (g_strcmp0 (ctx->name, name) == 0)
        return ctl_context_copy (ctx);
    }
  return NULL;
}

CtlContext *
ctl_config_resolve_context (CtlConfig *self, const gchar *name,
                            GError **error)
{
  CtlContext *ctx;
  const gchar *effective = name;

  if (effective == NULL || *effective == '\0')
    effective = self->current_context;

  if (effective != NULL && *effective != '\0')
    {
      ctx = ctl_config_get_context (self, effective);
      if (ctx != NULL)
        return ctx;
      if (name != NULL)
        {
          /* Explicitly requested but unknown: that is an error. */
          g_set_error (error, CTL_ERROR, CTL_ERROR_USAGE,
                       "unknown context '%s' in %s", name, self->path);
          return NULL;
        }
    }

  /* Built-in defaults. */
  ctx = ctl_context_new ("default");
  ctx->instance = g_strdup ("auto");
  return ctx;
}

gchar **
ctl_config_list_contexts (CtlConfig *self)
{
  GPtrArray *names = g_ptr_array_new ();
  guint k;
  for (k = 0; k < self->contexts->len; k++)
    {
      CtlContext *ctx = g_ptr_array_index (self->contexts, k);
      g_ptr_array_add (names, g_strdup (ctx->name));
    }
  g_ptr_array_add (names, NULL);
  return (gchar **) g_ptr_array_free (names, FALSE);
}

gchar *
ctl_config_expand_alias (CtlConfig *self, const gchar *word)
{
  const gchar *value = g_hash_table_lookup (self->aliases, word);
  return value != NULL ? g_strdup (value) : NULL;
}

gint
ctl_config_get_timeout (CtlConfig *self)
{
  return self->timeout;
}

/* yaml-glib generators cannot emit comments, so `config init' writes
 * a static commented template. */
static const gchar *config_template =
  "apiVersion: cmacs.org/v1\n"
  "kind: EmacsctlConfig\n"
  "current-context: local\n"
  "contexts:\n"
  "  - name: local\n"
  "    instance: primary      # primary | auto (newest) | <pid>\n"
  "    output: table          # table | json | yaml | raw\n"
  "  # - name: laptop\n"
  "  #   host: user@laptop    # tunneled via `emacsctl proxy` over ssh\n"
  "  #   instance: auto\n"
  "aliases:\n"
  "  # b: get buffers\n"
  "settings:\n"
  "  timeout: 30\n";

gboolean
ctl_config_init_boilerplate (const gchar *path, GError **error)
{
  gchar *effective = path != NULL ? g_strdup (path)
                                  : ctl_config_default_path ();
  gchar *dir;
  gboolean ok;

  if (g_file_test (effective, G_FILE_TEST_EXISTS))
    {
      g_set_error (error, CTL_ERROR, CTL_ERROR_FAILED,
                   "%s already exists (remove it first)", effective);
      g_free (effective);
      return FALSE;
    }
  dir = g_path_get_dirname (effective);
  g_mkdir_with_parents (dir, 0755);
  g_free (dir);

  ok = g_file_set_contents (effective, config_template, -1, error);
  if (ok)
    g_print ("wrote %s\n", effective);
  g_free (effective);
  return ok;
}

gboolean
ctl_config_use_context (CtlConfig *self, const gchar *name,
                        GError **error)
{
  gchar *contents = NULL;
  gchar **lines;
  GString *out;
  gboolean replaced = FALSE;
  gint k;
  CtlContext *ctx;

  ctx = ctl_config_get_context (self, name);
  if (ctx == NULL)
    {
      g_set_error (error, CTL_ERROR, CTL_ERROR_USAGE,
                   "unknown context '%s' (define it in %s first)",
                   name, self->path);
      return FALSE;
    }
  ctl_context_free (ctx);

  if (!g_file_get_contents (self->path, &contents, NULL, error))
    return FALSE;

  /* Textual line rewrite preserves the user's comments. */
  out = g_string_new (NULL);
  lines = g_strsplit (contents, "\n", -1);
  g_free (contents);
  for (k = 0; lines[k] != NULL; k++)
    {
      if (!replaced && g_str_has_prefix (lines[k], "current-context:"))
        {
          g_string_append_printf (out, "current-context: %s", name);
          replaced = TRUE;
        }
      else
        g_string_append (out, lines[k]);
      if (lines[k + 1] != NULL)
        g_string_append_c (out, '\n');
    }
  g_strfreev (lines);

  if (!replaced)
    {
      GString *fresh = g_string_new (NULL);
      g_string_append_printf (fresh, "current-context: %s\n", name);
      g_string_append (fresh, out->str);
      g_string_free (out, TRUE);
      out = fresh;
    }

  {
    gboolean ok = g_file_set_contents (self->path, out->str, -1, error);
    g_string_free (out, TRUE);
    if (ok)
      {
        g_free (self->current_context);
        self->current_context = g_strdup (name);
      }
    return ok;
  }
}
