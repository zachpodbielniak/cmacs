/*
 * Copyright (C) 2026 Zach Podbielniak
 * SPDX-License-Identifier: AGPL-3.0-or-later
 */

/* ctl-cmd-editor.c --- editor-surface command groups.
 *
 * Every verb here is ONE CtlMethodSpec table row bound to a typed
 * org.cmacs.Editor1.* D-Bus method.  Adding a server method to the
 * CLI means adding a row. */

#include "ctl-command-registry.h"
#include "ctl-ifaces.h"

#include <stdio.h>
#include <string.h>

void ctl_cmd_editor_register (CtlCommandRegistry *registry);

/* ── text group ─────────────────────────────────────────────────────
 *
 * The text verbs are CtlSimpleCommands rather than table rows: they
 * share a --buffer flag (empty = the editor's current buffer) and
 * `insert' / `append' read the text from stdin when no argument is
 * given, so files and pipelines feed straight into a buffer:
 *
 *   emacsctl text insert --buffer '*scratch*' "some text"
 *   make 2>&1 | emacsctl text append --buffer '*build-log*'
 */

static gchar *text_opt_buffer = NULL;
static gboolean text_opt_escapes = FALSE;

static const GOptionEntry text_entries[] = {
  { "buffer", 'b', 0, G_OPTION_ARG_STRING, &text_opt_buffer,
    "Target buffer (default: the editor's current buffer)", "NAME" },
  { "escapes", 'e', 0, G_OPTION_ARG_NONE, &text_opt_escapes,
    "Interpret backslash escapes in TEXT (\\n, \\t, \\xHH, \\0NNN, "
    "...) like `echo -e'", NULL },
  { NULL, 0, 0, 0, NULL, NULL, NULL }
};

/* Expand backslash escapes the way `echo -e' does: \\a \\b \\e \\f
 * \\n \\r \\t \\v \\\\, \\xHH (1-2 hex digits) and \\0NNN (0-3 octal
 * digits).  Unknown escapes pass through verbatim.  Caller g_frees. */
static gchar *
text_expand_escapes (const gchar *s)
{
  GString *out = g_string_new (NULL);

  while (*s != '\0')
    {
      if (*s != '\\' || s[1] == '\0')
        {
          g_string_append_c (out, *s++);
          continue;
        }
      s++;                      /* past the backslash */
      switch (*s)
        {
        case 'a':  g_string_append_c (out, '\a'); s++; break;
        case 'b':  g_string_append_c (out, '\b'); s++; break;
        case 'e':  g_string_append_c (out, '\033'); s++; break;
        case 'f':  g_string_append_c (out, '\f'); s++; break;
        case 'n':  g_string_append_c (out, '\n'); s++; break;
        case 'r':  g_string_append_c (out, '\r'); s++; break;
        case 't':  g_string_append_c (out, '\t'); s++; break;
        case 'v':  g_string_append_c (out, '\v'); s++; break;
        case '\\': g_string_append_c (out, '\\'); s++; break;
        case 'x':
          {
            guint value = 0;
            gint digits = 0;
            s++;
            while (digits < 2 && g_ascii_isxdigit (*s))
              {
                value = value * 16 + g_ascii_xdigit_value (*s);
                s++;
                digits++;
              }
            if (digits > 0)
              g_string_append_c (out, (gchar) value);
            else
              g_string_append (out, "\\x");
          }
          break;
        case '0':
          {
            guint value = 0;
            gint digits = 0;
            s++;
            while (digits < 3 && *s >= '0' && *s <= '7')
              {
                value = value * 8 + (guint) (*s - '0');
                s++;
                digits++;
              }
            if (value != 0 || digits > 0)
              g_string_append_c (out, (gchar) value);
          }
          break;
        default:
          /* Unknown escape: keep it verbatim, like echo -e. */
          g_string_append_c (out, '\\');
          g_string_append_c (out, *s++);
        }
    }
  return g_string_free (out, FALSE);
}

/* Read all of stdin (for `text insert/append' with no argument).
 * Caller g_frees. */
static gchar *
text_read_stdin (void)
{
  GString *buf = g_string_new (NULL);
  gchar chunk[4096];
  gsize got;

  while ((got = fread (chunk, 1, sizeof chunk, stdin)) > 0)
    g_string_append_len (buf, chunk, got);
  return g_string_free (buf, FALSE);
}

/* Call a Text method and emit its (s) reply. */
static gint
text_call (CtlInvocation *inv, const gchar *method, GVariant *params,
           GError **error)
{
  CtlTransport *transport;
  GVariant *reply;
  const gchar *ack;
  CtlResult *result;
  gboolean ok;

  transport = ctl_invocation_get_transport (inv, error);
  if (transport == NULL)
    {
      if (params != NULL)
        g_variant_unref (g_variant_ref_sink (params));
      return CTL_EXIT_NO_INSTANCE;
    }
  reply = ctl_transport_call (transport, CTL_IFACE_TEXT, method,
                              params,
                              ctl_invocation_get_timeout_ms (inv),
                              error);
  if (reply == NULL)
    return ctl_exit_code_for_error (error != NULL ? *error : NULL);

  g_variant_get (reply, "(&s)", &ack);
  result = ctl_result_new_scalar (ack);
  ok = ctl_invocation_emit (inv, result, error);
  ctl_result_unref (result);
  g_variant_unref (reply);
  return ok ? CTL_EXIT_OK : CTL_EXIT_ERROR;
}

/* Shared body for insert/append: positional text, or stdin. */
static gint
text_insert_or_append (CtlInvocation *inv, const gchar *method,
                       GError **error)
{
  const gchar *buffer =
    text_opt_buffer != NULL ? text_opt_buffer : "";
  const gchar *arg = ctl_invocation_get_arg (inv, 0);
  gchar *from_stdin = NULL;
  gchar *expanded = NULL;
  gint code;

  if (arg == NULL)
    {
      from_stdin = text_read_stdin ();
      if (*from_stdin == '\0')
        {
          g_free (from_stdin);
          g_set_error (error, CTL_ERROR, CTL_ERROR_USAGE,
                       "no text given and stdin was empty "
                       "(see 'text %s --help')",
                       g_ascii_strcasecmp (method, "Insert") == 0
                       ? "insert" : "append");
          return CTL_EXIT_USAGE;
        }
      arg = from_stdin;
    }

  if (text_opt_escapes)
    {
      expanded = text_expand_escapes (arg);
      arg = expanded;
    }

  code = text_call (inv, method,
                    g_variant_new ("(ss)", arg, buffer), error);
  g_free (from_stdin);
  g_free (expanded);
  return code;
}

static gint
cmd_text_insert (CtlCommand *self, CtlInvocation *inv, GError **error)
{
  (void) self;
  return text_insert_or_append (inv, "Insert", error);
}

/* ── text insert-org ────────────────────────────────────────────────
 *
 * Org-aware insertion: target a headline (by exact title or a slash
 * outline path), pick the spot inside the entry, and optionally wrap
 * the text in an org block / drawer or file it as a new child
 * headline.  The org work happens in the editor via
 * Edit.InsertOrg(buffer, text, a{ss} options):
 *
 *   emacsctl text insert-org -b notes.org -H 'Projects/cmacs' \
 *     --src elisp '(message "hi")'
 *   git log -1 | emacsctl text insert-org -b notes.org \
 *     -H 'Log' --create --child "$(date +%F)" --timestamp --quote
 */

static gchar *org_ins_opt_buffer = NULL;
static gchar *org_ins_opt_heading = NULL;
static gchar *org_ins_opt_position = NULL;
static gboolean org_ins_opt_create = FALSE;
static gboolean org_ins_opt_quote = FALSE;
static gboolean org_ins_opt_example = FALSE;
static gboolean org_ins_opt_verse = FALSE;
static gboolean org_ins_opt_center = FALSE;
static gchar *org_ins_opt_src = NULL;
static gchar *org_ins_opt_block = NULL;
static gchar *org_ins_opt_drawer = NULL;
static gchar *org_ins_opt_child = NULL;
static gchar *org_ins_opt_todo = NULL;
static gchar *org_ins_opt_tags = NULL;
static gboolean org_ins_opt_timestamp = FALSE;
static gboolean org_ins_opt_escapes = FALSE;

static const GOptionEntry org_ins_entries[] = {
  { "buffer", 'b', 0, G_OPTION_ARG_STRING, &org_ins_opt_buffer,
    "Target org buffer (default: the editor's current buffer)",
    "NAME" },
  { "heading", 'H', 0, G_OPTION_ARG_STRING, &org_ins_opt_heading,
    "Target headline: exact title, or a slash outline path like "
    "'Projects/cmacs/Log'", "PATH" },
  { "create", 'C', 0, G_OPTION_ARG_NONE, &org_ins_opt_create,
    "Create missing heading path components", NULL },
  { "position", 'p', 0, G_OPTION_ARG_STRING, &org_ins_opt_position,
    "Where in the entry: top, bottom (default), subtree-end, "
    "or point", "POS" },
  { "quote", 'q', 0, G_OPTION_ARG_NONE, &org_ins_opt_quote,
    "Wrap in #+begin_quote", NULL },
  { "src", 's', 0, G_OPTION_ARG_STRING, &org_ins_opt_src,
    "Wrap in #+begin_src LANG", "LANG" },
  { "example", 0, 0, G_OPTION_ARG_NONE, &org_ins_opt_example,
    "Wrap in #+begin_example", NULL },
  { "verse", 0, 0, G_OPTION_ARG_NONE, &org_ins_opt_verse,
    "Wrap in #+begin_verse", NULL },
  { "center", 0, 0, G_OPTION_ARG_NONE, &org_ins_opt_center,
    "Wrap in #+begin_center", NULL },
  { "block", 0, 0, G_OPTION_ARG_STRING, &org_ins_opt_block,
    "Wrap in a custom #+begin_NAME block", "NAME" },
  { "drawer", 0, 0, G_OPTION_ARG_STRING, &org_ins_opt_drawer,
    "Wrap in a :NAME: drawer (e.g. LOGBOOK)", "NAME" },
  { "child", 'c', 0, G_OPTION_ARG_STRING, &org_ins_opt_child,
    "File as a new child headline with this title; the text "
    "becomes its body", "TITLE" },
  { "todo", 0, 0, G_OPTION_ARG_STRING, &org_ins_opt_todo,
    "TODO keyword for --child (e.g. TODO, DONE)", "KEYWORD" },
  { "tags", 0, 0, G_OPTION_ARG_STRING, &org_ins_opt_tags,
    "Colon-separated tags for --child (e.g. work:cli)", "TAGS" },
  { "timestamp", 't', 0, G_OPTION_ARG_NONE, &org_ins_opt_timestamp,
    "Prepend an inactive org timestamp", NULL },
  { "escapes", 'e', 0, G_OPTION_ARG_NONE, &org_ins_opt_escapes,
    "Interpret backslash escapes in TEXT like `echo -e'", NULL },
  { NULL, 0, 0, 0, NULL, NULL, NULL }
};

static gint
cmd_text_insert_org (CtlCommand *self, CtlInvocation *inv,
                     GError **error)
{
  const gchar *arg = ctl_invocation_get_arg (inv, 0);
  gchar *from_stdin = NULL;
  gchar *expanded = NULL;
  const gchar *wrap = NULL;
  GVariantBuilder opts;
  CtlTransport *transport;
  GVariant *reply;
  const gchar *status;
  CtlResult *result;
  gboolean ok;
  gint n_wraps = 0;

  (void) self;

  /* Exactly one block wrapping may be chosen. */
  if (org_ins_opt_quote)   { wrap = "quote";   n_wraps++; }
  if (org_ins_opt_example) { wrap = "example"; n_wraps++; }
  if (org_ins_opt_verse)   { wrap = "verse";   n_wraps++; }
  if (org_ins_opt_center)  { wrap = "center";  n_wraps++; }
  if (org_ins_opt_src != NULL)   { wrap = "src"; n_wraps++; }
  if (org_ins_opt_block != NULL) { wrap = org_ins_opt_block; n_wraps++; }
  if (n_wraps > 1)
    {
      g_set_error (error, CTL_ERROR, CTL_ERROR_USAGE,
                   "choose at most one of --quote, --src, --example, "
                   "--verse, --center, --block");
      return CTL_EXIT_USAGE;
    }
  if ((org_ins_opt_todo != NULL || org_ins_opt_tags != NULL)
      && org_ins_opt_child == NULL)
    {
      g_set_error (error, CTL_ERROR, CTL_ERROR_USAGE,
                   "--todo/--tags only apply with --child TITLE");
      return CTL_EXIT_USAGE;
    }

  if (arg == NULL)
    {
      from_stdin = text_read_stdin ();
      if (*from_stdin == '\0')
        {
          g_free (from_stdin);
          g_set_error (error, CTL_ERROR, CTL_ERROR_USAGE,
                       "no text given and stdin was empty "
                       "(see 'text insert-org --help')");
          return CTL_EXIT_USAGE;
        }
      arg = from_stdin;
    }
  if (org_ins_opt_escapes)
    {
      expanded = text_expand_escapes (arg);
      arg = expanded;
    }

  g_variant_builder_init (&opts, G_VARIANT_TYPE ("a{ss}"));
  if (org_ins_opt_heading != NULL)
    g_variant_builder_add (&opts, "{ss}", "heading",
                           org_ins_opt_heading);
  if (org_ins_opt_position != NULL)
    g_variant_builder_add (&opts, "{ss}", "position",
                           org_ins_opt_position);
  if (wrap != NULL)
    g_variant_builder_add (&opts, "{ss}", "wrap", wrap);
  if (org_ins_opt_src != NULL)
    g_variant_builder_add (&opts, "{ss}", "lang", org_ins_opt_src);
  if (org_ins_opt_drawer != NULL)
    g_variant_builder_add (&opts, "{ss}", "drawer",
                           org_ins_opt_drawer);
  if (org_ins_opt_child != NULL)
    g_variant_builder_add (&opts, "{ss}", "child", org_ins_opt_child);
  if (org_ins_opt_todo != NULL)
    g_variant_builder_add (&opts, "{ss}", "todo", org_ins_opt_todo);
  if (org_ins_opt_tags != NULL)
    g_variant_builder_add (&opts, "{ss}", "tags", org_ins_opt_tags);
  if (org_ins_opt_create)
    g_variant_builder_add (&opts, "{ss}", "create", "t");
  if (org_ins_opt_timestamp)
    g_variant_builder_add (&opts, "{ss}", "timestamp", "t");

  transport = ctl_invocation_get_transport (inv, error);
  if (transport == NULL)
    {
      g_variant_builder_clear (&opts);
      g_free (from_stdin);
      g_free (expanded);
      return CTL_EXIT_NO_INSTANCE;
    }

  reply = ctl_transport_call (
    transport, CTL_IFACE_EDIT, "InsertOrg",
    g_variant_new ("(ssa{ss})",
                   org_ins_opt_buffer != NULL ? org_ins_opt_buffer
                                              : "",
                   arg,
                   &opts),
    ctl_invocation_get_timeout_ms (inv), error);
  g_free (from_stdin);
  g_free (expanded);
  if (reply == NULL)
    return ctl_exit_code_for_error (error != NULL ? *error : NULL);

  g_variant_get (reply, "(&s)", &status);
  result = ctl_result_new_scalar (status);
  ok = ctl_invocation_emit (inv, result, error);
  ctl_result_unref (result);
  g_variant_unref (reply);
  return ok ? CTL_EXIT_OK : CTL_EXIT_ERROR;
}

static gint
cmd_text_append (CtlCommand *self, CtlInvocation *inv, GError **error)
{
  (void) self;
  return text_insert_or_append (inv, "Append", error);
}

static gint
cmd_text_line (CtlCommand *self, CtlInvocation *inv, GError **error)
{
  const gchar *buffer =
    text_opt_buffer != NULL ? text_opt_buffer : "";
  const gchar *n = ctl_invocation_get_arg (inv, 0);

  (void) self;

  if (n == NULL)
    {
      g_set_error (error, CTL_ERROR, CTL_ERROR_USAGE,
                   "missing required argument <line> "
                   "(see 'text line --help')");
      return CTL_EXIT_USAGE;
    }
  return text_call (inv, "Line",
                    g_variant_new ("(xs)",
                                   g_ascii_strtoll (n, NULL, 10),
                                   buffer),
                    error);
}

static gint
cmd_text_delete (CtlCommand *self, CtlInvocation *inv, GError **error)
{
  const gchar *buffer =
    text_opt_buffer != NULL ? text_opt_buffer : "";
  const gchar *start = ctl_invocation_get_arg (inv, 0);
  const gchar *end = ctl_invocation_get_arg (inv, 1);

  (void) self;

  if (start == NULL || end == NULL)
    {
      g_set_error (error, CTL_ERROR, CTL_ERROR_USAGE,
                   "missing required arguments <start> <end> "
                   "(see 'text delete --help')");
      return CTL_EXIT_USAGE;
    }
  return text_call (inv, "Delete",
                    g_variant_new ("(xxs)",
                                   g_ascii_strtoll (start, NULL, 10),
                                   g_ascii_strtoll (end, NULL, 10),
                                   buffer),
                    error);
}

static const CtlMethodSpec editor_specs[] = {
  /* get <resource> --- kubectl-style nouns. */
  { "get buffers", "List buffer names",
    CTL_IFACE_BUFMGR, "List", NULL, CTL_REPLY_STRLIST },
  { "get frames", "List frames",
    CTL_IFACE_FRAMEMGR, "List", NULL, CTL_REPLY_STRLIST },
  { "get windows", "List windows",
    CTL_IFACE_WINMGR, "List", NULL, CTL_REPLY_STRLIST },
  { "get processes", "List editor subprocesses",
    CTL_IFACE_PROCMGR, "List", NULL, CTL_REPLY_STRLIST },
  { "get bookmarks", "List bookmarks",
    CTL_IFACE_BOOKMARK, "List", NULL, CTL_REPLY_STRING },
  { "get packages", "List installed packages",
    CTL_IFACE_PACKAGE, "List", NULL, CTL_REPLY_STRING },
  { "get watches", "List live expression watchers",
    CTL_IFACE_WATCH, "List", NULL, CTL_REPLY_STRING },
  { "get content", "Print a buffer's contents",
    CTL_IFACE_EDIT, "GetContent", "s:buffer", CTL_REPLY_STRING },
  /* "get content-org" is a CtlSimpleCommand in ctl-cmd-core.c: it
     takes filter flags and reshapes the reply per output format. */

  /* buffer */
  { "buffer list", "List buffer names",
    CTL_IFACE_BUFMGR, "List", NULL, CTL_REPLY_STRLIST },
  { "buffer current", "Current buffer name",
    CTL_IFACE_BUFMGR, "Current", NULL, CTL_REPLY_STRING },
  { "buffer exists", "Does a buffer exist?",
    CTL_IFACE_BUFMGR, "Find", "s:name", CTL_REPLY_BOOL },
  { "buffer file", "File backing a buffer",
    CTL_IFACE_BUFMGR, "FilenameFor", "s:name", CTL_REPLY_STRING },
  { "buffer modified", "Is a buffer modified?",
    CTL_IFACE_BUFMGR, "ModifiedP", "s:name", CTL_REPLY_BOOL },
  { "buffer create", "Create a buffer",
    CTL_IFACE_BUFMGR, "Create", "s:name", CTL_REPLY_BOOL },
  { "buffer switch", "Switch to a buffer",
    CTL_IFACE_BUFMGR, "Switch", "s:name", CTL_REPLY_BOOL },
  { "buffer save", "Save a buffer",
    CTL_IFACE_BUFMGR, "Save", "s:name", CTL_REPLY_BOOL },
  { "buffer kill", "Kill a buffer",
    CTL_IFACE_BUFMGR, "Kill", "s:name", CTL_REPLY_BOOL },
  { "buffer show", "Print a buffer's contents",
    CTL_IFACE_EDIT, "GetContent", "s:buffer", CTL_REPLY_STRING },
  { "buffer set", "Replace a buffer's contents",
    CTL_IFACE_EDIT, "SetContent", "s:buffer s:content",
    CTL_REPLY_STRING },

  /* edit */
  { "edit exact", "Exact string replacement in a buffer",
    CTL_IFACE_EDIT, "EditExact",
    "s:buffer s:old_string s:new_string b?:replace_all",
    CTL_REPLY_STRING },
  { "edit replace", "Regexp replacement in a buffer",
    CTL_IFACE_EDIT, "Replace", "s:buffer s:regexp s:replacement",
    CTL_REPLY_STRING },
  { "edit search", "Regexp search in a buffer",
    CTL_IFACE_EDIT, "Search", "s:buffer s:regexp", CTL_REPLY_STRING },
  { "edit goto-line", "Move point to a line",
    CTL_IFACE_EDIT, "GotoLine", "s:buffer i:line", CTL_REPLY_STRING },

  /* file */
  { "file open", "Open a file (find-file)",
    CTL_IFACE_FILE, "Open", "s:path", CTL_REPLY_STRING },
  { "file save", "Save a file's buffer",
    CTL_IFACE_FILE, "Save", "s:path", CTL_REPLY_STRING },
  { "file close", "Close a file's buffer",
    CTL_IFACE_FILE, "Close", "s:name", CTL_REPLY_STRING },
  { "file recent", "Recently opened files",
    CTL_IFACE_FILE, "Recent", "i?:count", CTL_REPLY_STRING },

  /* text: registered separately below --- the verbs take a --buffer
     flag and insert/append fall back to stdin for the text. */

  /* nav */
  { "nav point", "Current line and column",
    CTL_IFACE_NAV, "Point", NULL, CTL_REPLY_STRING },
  { "nav goto", "Go to line/column",
    CTL_IFACE_NAV, "Goto", "x:line x?:col", CTL_REPLY_STRING },

  /* search (current buffer) */
  { "search find", "Count regexp matches in the current buffer",
    CTL_IFACE_SEARCH, "Search", "s:pattern", CTL_REPLY_STRING },
  { "search replace", "Regexp replace in the current buffer",
    CTL_IFACE_SEARCH, "Replace", "s:pattern s:replacement",
    CTL_REPLY_STRING },
  { "search occur", "Occur-style match listing",
    CTL_IFACE_SEARCH, "Occur", "s:pattern", CTL_REPLY_STRING },

  /* vc */
  { "vc status", "Version-control status",
    CTL_IFACE_VC, "Status", NULL, CTL_REPLY_STRING },
  { "vc diff", "Diff a file",
    CTL_IFACE_VC, "Diff", "s?:file", CTL_REPLY_STRING },
  { "vc log", "Commit log",
    CTL_IFACE_VC, "Log", "i?:count s?:file", CTL_REPLY_STRING },
  { "vc blame", "Annotate a file",
    CTL_IFACE_VC, "Blame", "s:file", CTL_REPLY_STRING },

  /* project */
  { "project root", "Project root directory",
    CTL_IFACE_PROJECT, "Root", NULL, CTL_REPLY_STRING },
  { "project grep", "Grep the project tree",
    CTL_IFACE_PROJECT, "Grep", "s:pattern s?:dir", CTL_REPLY_STRING },
  { "project find", "Find files by name",
    CTL_IFACE_PROJECT, "Find", "s:filename s?:dir", CTL_REPLY_STRING },
  { "project files", "List project files",
    CTL_IFACE_PROJECT, "ListFiles", NULL, CTL_REPLY_STRING },
  { "project read", "Read a project file",
    CTL_IFACE_PROJECT, "ReadFile", "s:path", CTL_REPLY_STRING },
  { "project write", "Write a project file",
    CTL_IFACE_PROJECT, "WriteFile", "s:path s:content",
    CTL_REPLY_BOOL },
  { "project compile", "Start a compilation",
    CTL_IFACE_PROJECT, "Compile", "s:command", CTL_REPLY_STRING },

  /* clip */
  { "clip get", "Kill-ring head",
    CTL_IFACE_CLIPBOARD, "Get", NULL, CTL_REPLY_STRING },
  { "clip put", "Push text onto the kill ring",
    CTL_IFACE_CLIPBOARD, "Put", "s:text", CTL_REPLY_STRING },
  { "clip list", "Kill-ring entries",
    CTL_IFACE_CLIPBOARD, "List", NULL, CTL_REPLY_STRING },
  { "clip paste", "Yank at point",
    CTL_IFACE_CLIPBOARD, "Paste", NULL, CTL_REPLY_STRING },

  /* bookmark */
  { "bookmark list", "List bookmarks",
    CTL_IFACE_BOOKMARK, "List", NULL, CTL_REPLY_STRING },
  { "bookmark set", "Set a bookmark at point",
    CTL_IFACE_BOOKMARK, "Set", "s:name", CTL_REPLY_STRING },
  { "bookmark jump", "Jump to a bookmark",
    CTL_IFACE_BOOKMARK, "Jump", "s:name", CTL_REPLY_STRING },
  { "bookmark delete", "Delete a bookmark",
    CTL_IFACE_BOOKMARK, "Delete", "s:name", CTL_REPLY_STRING },

  /* pkg */
  { "pkg list", "List installed packages",
    CTL_IFACE_PACKAGE, "List", NULL, CTL_REPLY_STRING },
  { "pkg install", "Install a package",
    CTL_IFACE_PACKAGE, "Install", "s:name", CTL_REPLY_STRING },
  { "pkg remove", "Remove a package",
    CTL_IFACE_PACKAGE, "Remove", "s:name", CTL_REPLY_STRING },
  { "pkg refresh", "Refresh package archives",
    CTL_IFACE_PACKAGE, "Refresh", NULL, CTL_REPLY_STRING },

  /* var (editor variables, themes, modes) */
  { "var get", "Read an editor variable",
    CTL_IFACE_CONFIG, "Get", "s:name", CTL_REPLY_STRING },
  { "var set", "Set an editor variable",
    CTL_IFACE_CONFIG, "Set", "s:name s:value", CTL_REPLY_STRING },
  { "var theme", "Load a theme",
    CTL_IFACE_CONFIG, "Theme", "s:name", CTL_REPLY_STRING },
  { "var font", "Set the default font",
    CTL_IFACE_CONFIG, "Font", "s:family i:size", CTL_REPLY_STRING },
  { "var mode", "Toggle a mode in the current buffer",
    CTL_IFACE_CONFIG, "Mode", "s:mode", CTL_REPLY_STRING },

  /* input */
  { "input keys", "Send a key sequence (kbd syntax)",
    CTL_IFACE_INPUT, "SendKeys", "s:keys", CTL_REPLY_BOOL },
  { "input command", "Run an interactive command (M-x)",
    CTL_IFACE_INPUT, "ExecuteCommand", "s:command", CTL_REPLY_STRING },

  /* window */
  { "window split", "Split the selected window below",
    CTL_IFACE_WINMGR, "SplitBelow", NULL, CTL_REPLY_BOOL },
  { "window vsplit", "Split the selected window right",
    CTL_IFACE_WINMGR, "SplitRight", NULL, CTL_REPLY_BOOL },
  { "window other", "Select the other window",
    CTL_IFACE_WINMGR, "Other", NULL, CTL_REPLY_STRING },
  { "window delete", "Delete the selected window",
    CTL_IFACE_WINMGR, "Delete", NULL, CTL_REPLY_BOOL },
  { "window select", "Select the window showing a buffer",
    CTL_IFACE_WINMGR, "SelectByBuffer", "s:buffer", CTL_REPLY_BOOL },

  /* process */
  { "process status", "Subprocess status",
    CTL_IFACE_PROCMGR, "Status", "s:name", CTL_REPLY_STRING },
  { "process pid", "Subprocess PID",
    CTL_IFACE_PROCMGR, "Pid", "s:name", CTL_REPLY_INT },
  { "process kill", "Kill a subprocess",
    CTL_IFACE_PROCMGR, "Kill", "s:name", CTL_REPLY_BOOL },
  { "process send", "Send input to a subprocess",
    CTL_IFACE_PROCMGR, "SendTo", "s:name s:input", CTL_REPLY_BOOL },

  /* debug */
  { "debug backtrace", "Lisp backtrace",
    CTL_IFACE_DEBUG, "Backtrace", NULL, CTL_REPLY_STRING },
  { "debug memory", "GC and memory statistics",
    CTL_IFACE_DEBUG, "MemoryInfo", NULL, CTL_REPLY_STRING },
  { "debug hooks", "Non-empty hooks",
    CTL_IFACE_DEBUG, "ListHooks", NULL, CTL_REPLY_STRING },
  { "debug mode", "Current major/minor modes",
    CTL_IFACE_DEBUG, "DescribeMode", NULL, CTL_REPLY_STRING },
  { "debug function", "Describe a function",
    CTL_IFACE_DEBUG, "DescribeFunction", "s:symbol",
    CTL_REPLY_STRING },
  { "debug variable", "Describe a variable",
    CTL_IFACE_DEBUG, "DescribeVariable", "s:symbol",
    CTL_REPLY_STRING },
  { "debug apropos", "Apropos symbol search",
    CTL_IFACE_DEBUG, "Apropos", "s:pattern", CTL_REPLY_STRING },
  { "debug completions", "Symbol completions",
    CTL_IFACE_DEBUG, "Completions", "s:prefix", CTL_REPLY_STRLIST },
  { "debug profiler-start", "Start the CPU profiler",
    CTL_IFACE_DEBUG, "ProfilerStart", NULL, CTL_REPLY_STRING },
  { "debug profiler-stop", "Stop the CPU profiler",
    CTL_IFACE_DEBUG, "ProfilerStop", NULL, CTL_REPLY_STRING },
  { "debug profiler-report", "CPU profiler report",
    CTL_IFACE_DEBUG, "ProfilerReport", NULL, CTL_REPLY_STRING },

  /* c (cintrospect + cpatch) */
  { "c list", "List C symbols (kind: functions|variables|types)",
    CTL_IFACE_CINTROSPECT, "List", "s:kind s?:glob i?:limit",
    CTL_REPLY_STRING },
  { "c symbol", "C symbol info",
    CTL_IFACE_CINTROSPECT, "SymbolInfo", "s:name", CTL_REPLY_STRING },
  { "c type", "C type info",
    CTL_IFACE_CINTROSPECT, "TypeInfo", "s:name", CTL_REPLY_STRING },
  { "c source", "C function source location",
    CTL_IFACE_CINTROSPECT, "FunctionSource", "s:name",
    CTL_REPLY_STRING },
  { "c defuns", "List Lisp primitives (DEFUNs)",
    CTL_IFACE_CINTROSPECT, "ListDefuns", "s?:glob i?:limit",
    CTL_REPLY_STRING },
  { "c defun-info", "DEFUN details",
    CTL_IFACE_CINTROSPECT, "DefunInfo", "s:symbol", CTL_REPLY_STRING },
  { "c stack", "Native C stack trace",
    CTL_IFACE_CINTROSPECT, "StackTrace", "i?:depth",
    CTL_REPLY_STRING },
  { "c patch", "Hot-patch a DEFUN",
    CTL_IFACE_CPATCH, "PatchDefun", "s:symbol s:fn_name",
    CTL_REPLY_STRING },
  { "c unpatch", "Remove a DEFUN patch",
    CTL_IFACE_CPATCH, "UnpatchDefun", "s:symbol", CTL_REPLY_STRING },
  { "c patch-log", "List active patches",
    CTL_IFACE_CPATCH, "PatchList", NULL, CTL_REPLY_STRING },

  /* watch (live expression watchers) */
  { "watch add", "Add a live expression watcher",
    CTL_IFACE_WATCH, "Add", "s:expression", CTL_REPLY_STRING },
  { "watch rm", "Remove a watcher by handle",
    CTL_IFACE_WATCH, "Remove", "o:handle", CTL_REPLY_BOOL },
  { "watch list", "List watcher handles",
    CTL_IFACE_WATCH, "List", NULL, CTL_REPLY_STRING },

  /* root iface odds and ends */
  { "message", "Show a message in the echo area",
    CTL_IFACE_ROOT, "Message", "s:text", CTL_REPLY_NONE },
  { "find-file", "Open a file via find-file",
    CTL_IFACE_ROOT, "FindFile", "s:path", CTL_REPLY_NONE },

  { NULL, NULL, NULL, NULL, NULL, 0 }
};

void
ctl_cmd_editor_register (CtlCommandRegistry *registry)
{
  gint k;
  for (k = 0; editor_specs[k].name != NULL; k++)
    ctl_command_registry_add (registry,
                              ctl_method_command_new (&editor_specs[k]));

  ctl_command_registry_add (registry,
    ctl_simple_command_new_with_options (
      "text insert", "Insert text at point (stdin when no TEXT)",
      "[TEXT]", text_entries, cmd_text_insert));
  ctl_command_registry_add (registry,
    ctl_simple_command_new_with_options (
      "text insert-org",
      "Org-aware insert: target a headline, wrap in blocks/drawers, "
      "or file as a child entry (stdin when no TEXT)",
      "[TEXT]", org_ins_entries, cmd_text_insert_org));
  ctl_command_registry_add (registry,
    ctl_simple_command_new_with_options (
      "text append", "Append text to a buffer (stdin when no TEXT)",
      "[TEXT]", text_entries, cmd_text_append));
  ctl_command_registry_add (registry,
    ctl_simple_command_new_with_options (
      "text line", "Print line N of a buffer",
      "LINE", text_entries, cmd_text_line));
  ctl_command_registry_add (registry,
    ctl_simple_command_new_with_options (
      "text delete", "Delete a region of a buffer",
      "START END", text_entries, cmd_text_delete));
}
