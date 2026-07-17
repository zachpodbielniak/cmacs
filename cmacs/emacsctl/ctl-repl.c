/*
 * Copyright (C) 2026 Zach Podbielniak
 * SPDX-License-Identifier: AGPL-3.0-or-later
 */

/* ctl-repl.c --- see ctl-repl.h. */

#include "ctl-repl.h"
#include "ctl-ifaces.h"

#include <stdio.h>
#include <string.h>
#include <unistd.h>

#ifdef HAVE_EMACSCTL_READLINE
#include <readline/readline.h>
#include <readline/history.h>
#endif

/* ── CtlReplRuntime (abstract) ─────────────────────────────────────── */

G_DEFINE_ABSTRACT_TYPE (CtlReplRuntime, ctl_repl_runtime, G_TYPE_OBJECT)

static void
ctl_repl_runtime_class_init (CtlReplRuntimeClass *klass)
{
  (void) klass;
}

static void
ctl_repl_runtime_init (CtlReplRuntime *self)
{
  (void) self;
}

const gchar *
ctl_repl_runtime_get_language (CtlReplRuntime *self)
{
  return CTL_REPL_RUNTIME_GET_CLASS (self)->get_language (self);
}

const gchar *
ctl_repl_runtime_get_prompt (CtlReplRuntime *self)
{
  return CTL_REPL_RUNTIME_GET_CLASS (self)->get_prompt (self);
}

gboolean
ctl_repl_runtime_is_complete (CtlReplRuntime *self, const gchar *input)
{
  return CTL_REPL_RUNTIME_GET_CLASS (self)->is_complete (self, input);
}

gchar *
ctl_repl_runtime_eval (CtlReplRuntime *self, CtlTransport *transport,
                       gint timeout_ms, const gchar *input,
                       GError **error)
{
  return CTL_REPL_RUNTIME_GET_CLASS (self)->eval (self, transport,
                                                  timeout_ms, input,
                                                  error);
}

/* ── Registry ──────────────────────────────────────────────────────── */

static GHashTable *runtime_factories = NULL;   /* lang -> factory */
static GPtrArray *runtime_languages = NULL;    /* registration order */

void
ctl_repl_runtime_register (const gchar *language,
                           CtlReplRuntimeFactory factory)
{
  if (runtime_factories == NULL)
    {
      runtime_factories = g_hash_table_new_full (g_str_hash, g_str_equal,
                                                 g_free, NULL);
      runtime_languages = g_ptr_array_new_with_free_func (g_free);
    }
  if (!g_hash_table_contains (runtime_factories, language))
    g_ptr_array_add (runtime_languages, g_strdup (language));
  g_hash_table_insert (runtime_factories, g_strdup (language),
                       (gpointer) factory);
}

CtlReplRuntime *
ctl_repl_runtime_new_for_lang (const gchar *language, GError **error)
{
  CtlReplRuntimeFactory factory = NULL;

  if (runtime_factories != NULL)
    factory = g_hash_table_lookup (runtime_factories, language);
  if (factory == NULL)
    {
      gchar **langs = ctl_repl_runtime_list_languages ();
      gchar *list = g_strjoinv ("|", langs);
      g_set_error (error, CTL_ERROR, CTL_ERROR_USAGE,
                   "unknown REPL language '%s' (available: %s)",
                   language, list);
      g_free (list);
      g_strfreev (langs);
      return NULL;
    }
  return factory ();
}

gchar **
ctl_repl_runtime_list_languages (void)
{
  GPtrArray *out = g_ptr_array_new ();
  guint k;

  if (runtime_languages != NULL)
    for (k = 0; k < runtime_languages->len; k++)
      g_ptr_array_add (out,
        g_strdup (g_ptr_array_index (runtime_languages, k)));
  g_ptr_array_add (out, NULL);
  return (gchar **) g_ptr_array_free (out, FALSE);
}

/* ── CtlMethodReplRuntime: spec-driven concrete runtime ────────────── */

typedef enum
{
  CTL_REPL_COMPLETE_LINE,      /* every line is complete */
  CTL_REPL_COMPLETE_PARENS,    /* balanced ()/strings (elisp) */
  CTL_REPL_COMPLETE_BRACES     /* balanced {} (crispy C) */
} CtlReplCompleteStyle;

typedef enum
{
  CTL_REPL_REPLY_STRING,       /* (s) */
  CTL_REPL_REPLY_EXIT_OUTPUT   /* (is) */
} CtlReplReplyKind;

typedef struct
{
  const gchar *language;
  const gchar *prompt;
  const gchar *iface;
  const gchar *method;
  CtlReplCompleteStyle complete_style;
  CtlReplReplyKind reply;
} CtlReplSpec;

#define CTL_TYPE_METHOD_REPL_RUNTIME \
  (ctl_method_repl_runtime_get_type ())
G_DECLARE_FINAL_TYPE (CtlMethodReplRuntime, ctl_method_repl_runtime,
                      CTL, METHOD_REPL_RUNTIME, CtlReplRuntime)

struct _CtlMethodReplRuntime
{
  CtlReplRuntime parent_instance;
  const CtlReplSpec *spec;
};

G_DEFINE_FINAL_TYPE (CtlMethodReplRuntime, ctl_method_repl_runtime,
                     CTL_TYPE_REPL_RUNTIME)

static const gchar *
method_repl_get_language (CtlReplRuntime *self)
{
  return CTL_METHOD_REPL_RUNTIME (self)->spec->language;
}

static const gchar *
method_repl_get_prompt (CtlReplRuntime *self)
{
  return CTL_METHOD_REPL_RUNTIME (self)->spec->prompt;
}

/* Balance check shared by parens/braces styles; tracks elisp/C string
 * and char syntax loosely (good enough for a REPL continuation
 * heuristic). */
static gboolean
balanced (const gchar *input, gchar open, gchar close)
{
  gint depth = 0;
  gboolean in_string = FALSE;
  const gchar *p;

  for (p = input; *p != '\0'; p++)
    {
      if (in_string)
        {
          if (*p == '\\' && p[1] != '\0')
            p++;
          else if (*p == '"')
            in_string = FALSE;
          continue;
        }
      if (*p == '"')
        in_string = TRUE;
      else if (*p == '\\' && p[1] != '\0')
        p++;                    /* elisp ?\( char syntax etc. */
      else if (*p == open)
        depth++;
      else if (*p == close)
        depth--;
    }
  return depth <= 0 && !in_string;
}

static gboolean
method_repl_is_complete (CtlReplRuntime *self, const gchar *input)
{
  switch (CTL_METHOD_REPL_RUNTIME (self)->spec->complete_style)
    {
    case CTL_REPL_COMPLETE_PARENS:
      return balanced (input, '(', ')');
    case CTL_REPL_COMPLETE_BRACES:
      return balanced (input, '{', '}');
    case CTL_REPL_COMPLETE_LINE:
    default:
      return TRUE;
    }
}

static gchar *
method_repl_eval (CtlReplRuntime *self, CtlTransport *transport,
                  gint timeout_ms, const gchar *input, GError **error)
{
  const CtlReplSpec *spec = CTL_METHOD_REPL_RUNTIME (self)->spec;
  GVariant *reply;
  gchar *out;

  reply = ctl_transport_call (transport, spec->iface, spec->method,
                              g_variant_new ("(s)", input), timeout_ms,
                              error);
  if (reply == NULL)
    return NULL;

  if (spec->reply == CTL_REPL_REPLY_EXIT_OUTPUT)
    {
      gint code;
      const gchar *output;
      g_variant_get (reply, "(i&s)", &code, &output);
      if (code != 0)
        out = g_strdup_printf ("%s%s[exit %d]", output,
                               (*output != '\0'
                                && output[strlen (output) - 1] != '\n')
                               ? "\n" : "", code);
      else
        out = g_strdup (output);
    }
  else
    {
      const gchar *s;
      g_variant_get (reply, "(&s)", &s);
      out = g_strdup (s);
    }
  g_variant_unref (reply);
  return out;
}

static void
ctl_method_repl_runtime_class_init (CtlMethodReplRuntimeClass *klass)
{
  CtlReplRuntimeClass *runtime_class = CTL_REPL_RUNTIME_CLASS (klass);
  runtime_class->get_language = method_repl_get_language;
  runtime_class->get_prompt = method_repl_get_prompt;
  runtime_class->is_complete = method_repl_is_complete;
  runtime_class->eval = method_repl_eval;
}

static void
ctl_method_repl_runtime_init (CtlMethodReplRuntime *self)
{
  (void) self;
}

/* ── Built-in language specs ───────────────────────────────────────── */

static const CtlReplSpec elisp_spec = {
  "elisp", "elisp> ", CTL_IFACE_ROOT, "Eval",
  CTL_REPL_COMPLETE_PARENS, CTL_REPL_REPLY_STRING
};
static const CtlReplSpec crispy_spec = {
  "crispy", "crispy> ", CTL_IFACE_CRISPY, "EvalString",
  CTL_REPL_COMPLETE_BRACES, CTL_REPL_REPLY_STRING
};
static const CtlReplSpec bacon_spec = {
  "bacon", "bacon> ", CTL_IFACE_BACON, "Eval",
  CTL_REPL_COMPLETE_LINE, CTL_REPL_REPLY_EXIT_OUTPUT
};
static const CtlReplSpec eshell_spec = {
  "eshell", "eshell> ", CTL_IFACE_ESHELL, "Eval",
  CTL_REPL_COMPLETE_LINE, CTL_REPL_REPLY_STRING
};
/* COMPLETE_LINE, not COMPLETE_PARENS: calculator input is infix, not
 * s-expressions, so one line is always one complete expression --- there
 * is no multi-line form to continue.  Parens here are grouping/call
 * syntax, and an unbalanced one ("sqrt(5") is an error the engine should
 * report, not a request for a continuation line; COMPLETE_PARENS would
 * silently swallow the line and leave the REPL hanging on more input. */
static const CtlReplSpec calc_spec = {
  "calc", "calc> ", CTL_IFACE_CALC, "Eval",
  CTL_REPL_COMPLETE_LINE, CTL_REPL_REPLY_STRING
};

static CtlReplRuntime *
make_runtime (const CtlReplSpec *spec)
{
  CtlMethodReplRuntime *self =
    g_object_new (CTL_TYPE_METHOD_REPL_RUNTIME, NULL);
  self->spec = spec;
  return CTL_REPL_RUNTIME (self);
}

static CtlReplRuntime *make_elisp  (void) { return make_runtime (&elisp_spec); }
static CtlReplRuntime *make_crispy (void) { return make_runtime (&crispy_spec); }
static CtlReplRuntime *make_bacon  (void) { return make_runtime (&bacon_spec); }
static CtlReplRuntime *make_eshell (void) { return make_runtime (&eshell_spec); }
static CtlReplRuntime *make_calc   (void) { return make_runtime (&calc_spec); }

void
ctl_repl_register_builtin_runtimes (void)
{
  ctl_repl_runtime_register ("elisp", make_elisp);
  ctl_repl_runtime_register ("crispy", make_crispy);
  ctl_repl_runtime_register ("bacon", make_bacon);
  ctl_repl_runtime_register ("eshell", make_eshell);
  ctl_repl_runtime_register ("calc", make_calc);
}

/* ── Line reading (readline when available + tty, fgets fallback) ──── */

#ifdef HAVE_EMACSCTL_READLINE
static gchar *
history_path_for (const gchar *language)
{
  gchar *dir = g_build_filename (g_get_user_state_dir (), "cmacs", NULL);
  gchar *path;
  g_mkdir_with_parents (dir, 0755);
  path = g_strdup_printf ("%s/emacsctl_history.%s", dir, language);
  g_free (dir);
  return path;
}
#endif

static gchar *
read_input_line (const gchar *prompt, gboolean is_tty)
{
#ifdef HAVE_EMACSCTL_READLINE
  if (is_tty)
    {
      gchar *line = readline (prompt);
      if (line != NULL && *line != '\0')
        add_history (line);
      return line;              /* readline mallocs; g_free-compatible */
    }
#endif
  {
    GString *buf = g_string_new (NULL);
    gint c;
    if (is_tty)
      {
        fputs (prompt, stdout);
        fflush (stdout);
      }
    while ((c = fgetc (stdin)) != EOF && c != '\n')
      g_string_append_c (buf, (gchar) c);
    if (c == EOF && buf->len == 0)
      {
        g_string_free (buf, TRUE);
        return NULL;
      }
    return g_string_free (buf, FALSE);
  }
}

/* ── The loop ──────────────────────────────────────────────────────── */

static void
repl_on_transport_closed (CtlTransport *transport, gpointer user_data)
{
  gboolean *closed = user_data;
  (void) transport;
  *closed = TRUE;
}

gint
ctl_repl_run (CtlInvocation *inv, const gchar *language, GError **error)
{
  CtlReplRuntime *runtime;
  CtlTransport *transport;
  gboolean is_tty = isatty (0);
  gboolean closed = FALSE;
#ifdef HAVE_EMACSCTL_READLINE
  gchar *history = NULL;
#endif

  runtime = ctl_repl_runtime_new_for_lang (language, error);
  if (runtime == NULL)
    return CTL_EXIT_USAGE;

  transport = ctl_invocation_get_transport (inv, error);
  if (transport == NULL)
    {
      g_object_unref (runtime);
      return CTL_EXIT_NO_INSTANCE;
    }
  g_signal_connect (transport, "closed",
                    G_CALLBACK (repl_on_transport_closed), &closed);

#ifdef HAVE_EMACSCTL_READLINE
  if (is_tty)
    {
      history = history_path_for (language);
      read_history (history);
    }
#endif

  if (is_tty)
    printf ("%s REPL on the live editor --- C-d exits.\n",
            ctl_repl_runtime_get_language (runtime));

  for (;;)
    {
      GString *input;
      gchar *line;

      if (closed)
        break;

      line = read_input_line (ctl_repl_runtime_get_prompt (runtime),
                              is_tty);
      if (line == NULL)
        break;                  /* EOF */
      if (*line == '\0')
        {
          g_free (line);
          continue;
        }

      input = g_string_new (line);
      g_free (line);

      while (!ctl_repl_runtime_is_complete (runtime, input->str))
        {
          line = read_input_line ("... ", is_tty);
          if (line == NULL)
            break;
          g_string_append_c (input, '\n');
          g_string_append (input, line);
          g_free (line);
        }

      {
        GError *eval_error = NULL;
        gchar *result = ctl_repl_runtime_eval (
          runtime, transport, ctl_invocation_get_timeout_ms (inv),
          input->str, &eval_error);
        if (result != NULL)
          {
            fputs (result, stdout);
            if (*result == '\0'
                || result[strlen (result) - 1] != '\n')
              fputc ('\n', stdout);
            g_free (result);
          }
        else if (eval_error != NULL)
          {
            g_dbus_error_strip_remote_error (eval_error);
            fprintf (stderr, "error: %s\n", eval_error->message);
            g_error_free (eval_error);
          }
      }
      g_string_free (input, TRUE);
    }

#ifdef HAVE_EMACSCTL_READLINE
  if (history != NULL)
    {
      write_history (history);
      g_free (history);
    }
#endif

  g_object_unref (runtime);
  return CTL_EXIT_OK;
}
