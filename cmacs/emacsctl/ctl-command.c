/*
 * Copyright (C) 2026 Zach Podbielniak
 * SPDX-License-Identifier: AGPL-3.0-or-later
 */

/* ctl-command.c --- CtlCommand base class, CtlSimpleCommand, and the
 * table-driven CtlMethodCommand. */

#include "ctl-command.h"

#include <stdlib.h>
#include <string.h>

/* ── CtlCommand (abstract) ─────────────────────────────────────────── */

typedef struct
{
  gchar *name;
  gchar *summary;
  gchar *usage;
} CtlCommandPrivate;

enum
{
  PROP_0,
  PROP_NAME,
  PROP_SUMMARY,
  PROP_USAGE,
  N_PROPS
};

static GParamSpec *props[N_PROPS] = { NULL };

G_DEFINE_TYPE_WITH_PRIVATE (CtlCommand, ctl_command, G_TYPE_OBJECT)

#define GET_PRIV(obj) \
  ((CtlCommandPrivate *) ctl_command_get_instance_private (obj))

static void
ctl_command_set_property (GObject *object, guint prop_id,
                          const GValue *value, GParamSpec *pspec)
{
  CtlCommandPrivate *priv = GET_PRIV (CTL_COMMAND (object));
  switch (prop_id)
    {
    case PROP_NAME:
      g_free (priv->name);
      priv->name = g_value_dup_string (value);
      break;
    case PROP_SUMMARY:
      g_free (priv->summary);
      priv->summary = g_value_dup_string (value);
      break;
    case PROP_USAGE:
      g_free (priv->usage);
      priv->usage = g_value_dup_string (value);
      break;
    default:
      G_OBJECT_WARN_INVALID_PROPERTY_ID (object, prop_id, pspec);
    }
}

static void
ctl_command_get_property (GObject *object, guint prop_id,
                          GValue *value, GParamSpec *pspec)
{
  CtlCommandPrivate *priv = GET_PRIV (CTL_COMMAND (object));
  switch (prop_id)
    {
    case PROP_NAME:    g_value_set_string (value, priv->name);    break;
    case PROP_SUMMARY: g_value_set_string (value, priv->summary); break;
    case PROP_USAGE:   g_value_set_string (value, priv->usage);   break;
    default:
      G_OBJECT_WARN_INVALID_PROPERTY_ID (object, prop_id, pspec);
    }
}

static void
ctl_command_finalize (GObject *object)
{
  CtlCommandPrivate *priv = GET_PRIV (CTL_COMMAND (object));
  g_free (priv->name);
  g_free (priv->summary);
  g_free (priv->usage);
  G_OBJECT_CLASS (ctl_command_parent_class)->finalize (object);
}

static void
ctl_command_class_init (CtlCommandClass *klass)
{
  GObjectClass *object_class = G_OBJECT_CLASS (klass);

  object_class->set_property = ctl_command_set_property;
  object_class->get_property = ctl_command_get_property;
  object_class->finalize = ctl_command_finalize;

  props[PROP_NAME] = g_param_spec_string (
    "name", "Name", "Full command path, e.g. \"crispy eval\"",
    NULL, G_PARAM_READWRITE | G_PARAM_CONSTRUCT_ONLY);
  props[PROP_SUMMARY] = g_param_spec_string (
    "summary", "Summary", "One-line description",
    NULL, G_PARAM_READWRITE | G_PARAM_CONSTRUCT_ONLY);
  props[PROP_USAGE] = g_param_spec_string (
    "usage", "Usage", "Positional argument synopsis",
    NULL, G_PARAM_READWRITE | G_PARAM_CONSTRUCT_ONLY);
  g_object_class_install_properties (object_class, N_PROPS, props);
}

static void
ctl_command_init (CtlCommand *self)
{
  (void) self;
}

const gchar *
ctl_command_get_name (CtlCommand *self)
{
  return GET_PRIV (self)->name;
}

const gchar *
ctl_command_get_summary (CtlCommand *self)
{
  return GET_PRIV (self)->summary;
}

const gchar *
ctl_command_get_usage (CtlCommand *self)
{
  return GET_PRIV (self)->usage;
}

gint
ctl_command_run (CtlCommand *self, CtlInvocation *inv, GError **error)
{
  g_return_val_if_fail (CTL_IS_COMMAND (self), CTL_EXIT_ERROR);
  return CTL_COMMAND_GET_CLASS (self)->run (self, inv, error);
}

gchar **
ctl_command_complete (CtlCommand *self, CtlInvocation *inv, gint argi,
                      const gchar *prefix)
{
  CtlCommandClass *klass = CTL_COMMAND_GET_CLASS (self);
  if (klass->complete == NULL)
    return NULL;
  return klass->complete (self, inv, argi, prefix);
}

/* ── CtlSimpleCommand ──────────────────────────────────────────────── */

struct _CtlSimpleCommand
{
  CtlCommand parent_instance;
  CtlCommandFunc func;
};

G_DEFINE_FINAL_TYPE (CtlSimpleCommand, ctl_simple_command,
                     CTL_TYPE_COMMAND)

static gint
simple_run (CtlCommand *self, CtlInvocation *inv, GError **error)
{
  CtlSimpleCommand *simple = CTL_SIMPLE_COMMAND (self);
  return simple->func (self, inv, error);
}

static void
ctl_simple_command_class_init (CtlSimpleCommandClass *klass)
{
  CTL_COMMAND_CLASS (klass)->run = simple_run;
}

static void
ctl_simple_command_init (CtlSimpleCommand *self)
{
  (void) self;
}

CtlCommand *
ctl_simple_command_new (const gchar *name, const gchar *summary,
                        const gchar *usage, CtlCommandFunc func)
{
  CtlSimpleCommand *self = g_object_new (CTL_TYPE_SIMPLE_COMMAND,
                                         "name", name,
                                         "summary", summary,
                                         "usage", usage,
                                         NULL);
  self->func = func;
  return CTL_COMMAND (self);
}

/* ── CtlMethodCommand ──────────────────────────────────────────────── */

struct _CtlMethodCommand
{
  CtlCommand parent_instance;
  const CtlMethodSpec *spec;
};

G_DEFINE_FINAL_TYPE (CtlMethodCommand, ctl_method_command,
                     CTL_TYPE_COMMAND)

/* Build the params tuple from ARGSPEC + positional argv. */
static GVariant *
build_params (const gchar *argspec, CtlInvocation *inv, GError **error)
{
  GVariantBuilder builder;
  gchar **specs;
  gint si, argi = 0, argc = 0;
  gchar **argv = ctl_invocation_get_args (inv, &argc);

  if (argspec == NULL || *argspec == '\0')
    return NULL;

  g_variant_builder_init (&builder, G_VARIANT_TYPE_TUPLE);
  specs = g_strsplit (argspec, " ", -1);

  for (si = 0; specs[si] != NULL; si++)
    {
      const gchar *spec = specs[si];
      gchar type = spec[0];
      gboolean optional = spec[1] == '?';
      const gchar *argname = strchr (spec, ':');
      const gchar *value = argi < argc ? argv[argi] : NULL;

      argname = argname != NULL ? argname + 1 : spec;

      if (type == 'D')
        {
          /* Remaining args are KEY=VALUE pairs. */
          GVariantBuilder dict;
          g_variant_builder_init (&dict, G_VARIANT_TYPE ("a{ss}"));
          for (; argi < argc; argi++)
            {
              gchar *eq = strchr (argv[argi], '=');
              if (eq == NULL)
                {
                  g_set_error (error, CTL_ERROR, CTL_ERROR_USAGE,
                               "expected KEY=VALUE, got '%s'", argv[argi]);
                  g_variant_builder_clear (&dict);
                  g_variant_builder_clear (&builder);
                  g_strfreev (specs);
                  return NULL;
                }
              *eq = '\0';
              g_variant_builder_add (&dict, "{ss}", argv[argi], eq + 1);
              *eq = '=';
            }
          g_variant_builder_add_value (&builder,
                                       g_variant_builder_end (&dict));
          continue;
        }

      if (value == NULL && !optional)
        {
          g_set_error (error, CTL_ERROR, CTL_ERROR_USAGE,
                       "missing required argument <%s>", argname);
          g_variant_builder_clear (&builder);
          g_strfreev (specs);
          return NULL;
        }
      if (value != NULL)
        argi++;

      switch (type)
        {
        case 's':
          g_variant_builder_add (&builder, "s",
                                 value != NULL ? value : "");
          break;
        case 'o':
          g_variant_builder_add (&builder, "o",
                                 value != NULL ? value : "/");
          break;
        case 'i':
          g_variant_builder_add (&builder, "i",
            value != NULL ? (gint) strtol (value, NULL, 10) : 0);
          break;
        case 'u':
          g_variant_builder_add (&builder, "u",
            value != NULL ? (guint32) g_ascii_strtoull (value, NULL, 10)
                          : (guint32) 0);
          break;
        case 'x':
          g_variant_builder_add (&builder, "x",
            value != NULL ? (gint64) g_ascii_strtoll (value, NULL, 10)
                          : (gint64) 0);
          break;
        case 't':
          g_variant_builder_add (&builder, "t",
            value != NULL ? (guint64) g_ascii_strtoull (value, NULL, 10)
                          : (guint64) 0);
          break;
        case 'd':
          g_variant_builder_add (&builder, "d",
            value != NULL ? g_ascii_strtod (value, NULL) : 0.0);
          break;
        case 'b':
          g_variant_builder_add (&builder, "b",
            value != NULL
            && (g_strcmp0 (value, "true") == 0
                || g_strcmp0 (value, "t") == 0
                || g_strcmp0 (value, "1") == 0));
          break;
        default:
          g_set_error (error, CTL_ERROR, CTL_ERROR_FAILED,
                       "bad argspec token '%s'", spec);
          g_variant_builder_clear (&builder);
          g_strfreev (specs);
          return NULL;
        }
    }

  g_strfreev (specs);
  return g_variant_builder_end (&builder);
}

/* Map a reply variant to a CtlResult per KIND.  EXIT_OUTPUT is
 * special-cased by the caller. */
static CtlResult *
result_for_reply (GVariant *reply, CtlReplyKind kind)
{
  switch (kind)
    {
    case CTL_REPLY_STRING:
      {
        /* Tolerant: (s) and (o) extract the string; any other reply
         * shape falls back to the printed tuple. */
        if (g_variant_is_of_type (reply, G_VARIANT_TYPE ("(s)")))
          {
            const gchar *s;
            g_variant_get (reply, "(&s)", &s);
            return ctl_result_new_scalar (s);
          }
        if (g_variant_is_of_type (reply, G_VARIANT_TYPE ("(o)")))
          {
            const gchar *s;
            g_variant_get (reply, "(&o)", &s);
            return ctl_result_new_scalar (s);
          }
        {
          gchar *printed = g_variant_print (reply, FALSE);
          CtlResult *result = ctl_result_new_scalar (printed);
          g_free (printed);
          return result;
        }
      }
    case CTL_REPLY_JSON:
      {
        const gchar *s;
        JsonParser *parser;
        CtlResult *result;
        g_variant_get (reply, "(&s)", &s);
        parser = json_parser_new ();
        if (json_parser_load_from_data (parser, s, -1, NULL))
          result = ctl_result_new_document (
            json_node_copy (json_parser_get_root (parser)));
        else
          result = ctl_result_new_scalar (s);
        g_object_unref (parser);
        return result;
      }
    case CTL_REPLY_BOOL:
      {
        gboolean b;
        g_variant_get (reply, "(b)", &b);
        return ctl_result_new_scalar (b ? "true" : "false");
      }
    case CTL_REPLY_INT:
      {
        gint i;
        gchar buf[32];
        g_variant_get (reply, "(i)", &i);
        g_snprintf (buf, sizeof buf, "%d", i);
        return ctl_result_new_scalar (buf);
      }
    case CTL_REPLY_STRLIST:
      {
        GVariantIter *iter;
        const gchar *s;
        JsonArray *rows = json_array_new ();
        g_variant_get (reply, "(as)", &iter);
        while (g_variant_iter_loop (iter, "&s", &s))
          json_array_add_string_element (rows, s);
        g_variant_iter_free (iter);
        return ctl_result_new_list (rows);
      }
    default:
      return ctl_result_new_scalar ("");
    }
}

static gint
method_run (CtlCommand *self, CtlInvocation *inv, GError **error)
{
  CtlMethodCommand *cmd = CTL_METHOD_COMMAND (self);
  const CtlMethodSpec *spec = cmd->spec;
  CtlTransport *transport;
  GVariant *params, *reply;
  GError *local = NULL;

  transport = ctl_invocation_get_transport (inv, error);
  if (transport == NULL)
    return CTL_EXIT_NO_INSTANCE;

  params = build_params (spec->argspec, inv, &local);
  if (local != NULL)
    {
      g_propagate_error (error, local);
      return CTL_EXIT_USAGE;
    }

  reply = ctl_transport_call (transport, spec->iface, spec->method,
                              params,
                              ctl_invocation_get_timeout_ms (inv),
                              error);
  if (reply == NULL)
    return ctl_exit_code_for_error (error != NULL ? *error : NULL);

  if (spec->reply == CTL_REPLY_EXIT_OUTPUT)
    {
      gint code;
      const gchar *output;
      g_variant_get (reply, "(i&s)", &code, &output);
      fputs (output, stdout);
      if (*output != '\0' && output[strlen (output) - 1] != '\n')
        fputc ('\n', stdout);
      g_variant_unref (reply);
      return code == 0 ? CTL_EXIT_OK : CTL_EXIT_ERROR;
    }

  if (spec->reply == CTL_REPLY_NONE)
    {
      g_variant_unref (reply);
      return CTL_EXIT_OK;
    }

  {
    CtlResult *result = result_for_reply (reply, spec->reply);
    gboolean ok = ctl_invocation_emit (inv, result, error);
    ctl_result_unref (result);
    g_variant_unref (reply);
    return ok ? CTL_EXIT_OK : CTL_EXIT_ERROR;
  }
}

static void
ctl_method_command_class_init (CtlMethodCommandClass *klass)
{
  CTL_COMMAND_CLASS (klass)->run = method_run;
}

static void
ctl_method_command_init (CtlMethodCommand *self)
{
  (void) self;
}

/* Derive a usage string from an argspec: "<code>" / "[buffer]"... */
static gchar *
usage_for_argspec (const gchar *argspec)
{
  GString *out;
  gchar **specs;
  gint si;

  if (argspec == NULL || *argspec == '\0')
    return g_strdup ("");

  out = g_string_new (NULL);
  specs = g_strsplit (argspec, " ", -1);
  for (si = 0; specs[si] != NULL; si++)
    {
      const gchar *colon = strchr (specs[si], ':');
      const gchar *argname = colon != NULL ? colon + 1 : specs[si];
      gboolean optional = specs[si][1] == '?';
      if (si > 0)
        g_string_append_c (out, ' ');
      if (specs[si][0] == 'D')
        g_string_append (out, "[KEY=VALUE...]");
      else
        g_string_append_printf (out, optional ? "[%s]" : "<%s>",
                                argname);
    }
  g_strfreev (specs);
  return g_string_free (out, FALSE);
}

CtlCommand *
ctl_method_command_new (const CtlMethodSpec *spec)
{
  gchar *usage = usage_for_argspec (spec->argspec);
  CtlMethodCommand *self = g_object_new (CTL_TYPE_METHOD_COMMAND,
                                         "name", spec->name,
                                         "summary", spec->summary,
                                         "usage", usage,
                                         NULL);
  g_free (usage);
  self->spec = spec;
  return CTL_COMMAND (self);
}
