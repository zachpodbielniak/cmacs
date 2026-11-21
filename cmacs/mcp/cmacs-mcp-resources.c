/*
 * cmacs-mcp-resources.c — MCP resources for Emacs runtime
 *
 * Copyright (C) 2026 Zach Podbielniak
 * SPDX-License-Identifier: AGPL-3.0-or-later
 */

#include <config.h>

#ifdef HAVE_CMACS_MCP

#include "lisp.h"
#include "cmacs-mcp-tools.h"
#include "cmacs-eval-dispatch.h"

#include <glib/gstdio.h>

/* ── Redaction ────────────────────────────────────────────────────── */

/* CMACS redact: whether the resource KIND://NAME may be read at all.

   The user's privacy rules (lisp/cmacs/cmacs-redact.el, which applies
   the journal's rule set to every model-facing surface) are asked
   before anything is read: an excluded buffer, a file under a hidden
   directory, the buffer of a process that is hidden.  The Lisp side
   signals to refuse, so every way this can fail -- the rules did not
   load, the file is missing from this build, the guard itself broke --
   is a refusal.  A refused resource is reported exactly like one that
   does not exist; nothing says why.

   NAME goes into the form through cmacs_dispatch_lisp_escape, never
   g_strescape (whose octal escapes the reader turns into raw bytes).  */
static gboolean
resource_allowed (const gchar *kind, const gchar *name)
{
  g_autoptr (GError) error = NULL;
  g_autofree gchar *ename = cmacs_dispatch_lisp_escape (name ? name : "");
  g_autofree gchar *expr = g_strdup_printf (
    "(progn (require 'cmacs-redact)"
    "  (cmacs-redact-resource-guard \"%s\" \"%s\") t)",
    kind, ename);
  g_autofree gchar *ok = cmacs_dispatch_eval (expr, &error);

  return ok != NULL;
}

/* ── buffer://{name} ──────────────────────────────────────────────── */

static GList *
handle_buffer_resource (McpServer   *server,
                        const gchar *uri,
                        gpointer     user_data)
{
  const gchar *name;
  g_autoptr (GError) error = NULL;
  g_autofree gchar *expr = NULL;
  g_autofree gchar *ename = NULL;
  g_autofree gchar *content = NULL;
  McpResourceContents *rc;

  (void) server;
  (void) user_data;

  /* Extract buffer name from URI: "buffer://NAME" */
  if (g_str_has_prefix (uri, "buffer://"))
    name = uri + 9;
  else
    name = uri;

  if (!resource_allowed ("buffer", name))
    return NULL;

  ename = cmacs_dispatch_lisp_escape (name);
  expr = g_strdup_printf (
    "(with-current-buffer \"%s\""
    "  (buffer-substring-no-properties (point-min) (point-max)))",
    ename);

  content = cmacs_dispatch_eval (expr, &error);
  if (content == NULL)
    return NULL;

  rc = mcp_resource_contents_new_text (uri, content, "text/plain");
  return g_list_append (NULL, rc);
}

/* ── file://{path} ────────────────────────────────────────────────── */

static GList *
handle_file_resource (McpServer   *server,
                      const gchar *uri,
                      gpointer     user_data)
{
  const gchar *path;
  g_autofree gchar *content = NULL;
  g_autoptr (GError) error = NULL;
  McpResourceContents *rc;

  (void) server;
  (void) user_data;

  if (g_str_has_prefix (uri, "file://"))
    path = uri + 7;
  else
    path = uri;

  if (!resource_allowed ("file", path))
    return NULL;

  if (!g_file_get_contents (path, &content, NULL, &error))
    return NULL;

  rc = mcp_resource_contents_new_text (uri, content, "text/plain");
  return g_list_append (NULL, rc);
}

/* ── messages:// ──────────────────────────────────────────────────── */

static GList *
handle_messages_resource (McpServer   *server,
                          const gchar *uri,
                          gpointer     user_data)
{
  g_autoptr (GError) error = NULL;
  g_autofree gchar *content = NULL;
  McpResourceContents *rc;

  (void) server;
  (void) uri;
  (void) user_data;

  if (!resource_allowed ("messages", NULL))
    return NULL;

  /* The message log is free text from everywhere, so beyond the
     refusal above it goes through the free-text rules.  */
  content = cmacs_dispatch_eval (
    "(cmacs-redact-text"
    " (with-current-buffer \"*Messages*\""
    "   (buffer-substring-no-properties (point-min) (point-max))))",
    &error);

  if (content == NULL)
    return NULL;

  rc = mcp_resource_contents_new_text ("messages://", content, "text/plain");
  return g_list_append (NULL, rc);
}

/* ── variable://{name} ────────────────────────────────────────────── */

static GList *
handle_variable_resource (McpServer   *server,
                          const gchar *uri,
                          gpointer     user_data)
{
  const gchar *name;
  g_autoptr (GError) error = NULL;
  g_autofree gchar *expr = NULL;
  g_autofree gchar *ename = NULL;
  g_autofree gchar *content = NULL;
  McpResourceContents *rc;

  (void) server;
  (void) user_data;

  if (g_str_has_prefix (uri, "variable://"))
    name = uri + 11;
  else
    name = uri;

  /* `intern' of a quoted string, not a bare symbol spliced into the
     source: a name is data, and "nil) (delete-directory ...) (car '(x"
     used to read as three forms. */
  if (!resource_allowed ("variable", name))
    return NULL;

  /* A variable has no buffer or file for a rule to name, so its value
     is redacted as free text instead.  */
  ename = cmacs_dispatch_lisp_escape (name);
  expr = g_strdup_printf (
    "(cmacs-redact-text"
    " (prin1-to-string (symbol-value (intern \"%s\"))))", ename);

  content = cmacs_dispatch_eval (expr, &error);
  if (content == NULL)
    return NULL;

  rc = mcp_resource_contents_new_text (uri, content, "text/plain");
  return g_list_append (NULL, rc);
}

/* ── process://{name} ─────────────────────────────────────────────── */

static GList *
handle_process_resource (McpServer   *server,
                         const gchar *uri,
                         gpointer     user_data)
{
  const gchar *name;
  g_autoptr (GError) error = NULL;
  g_autofree gchar *expr = NULL;
  g_autofree gchar *escaped = NULL;
  g_autofree gchar *content = NULL;
  McpResourceContents *rc;

  (void) server;
  (void) user_data;

  if (g_str_has_prefix (uri, "process://"))
    name = uri + 10;
  else
    name = uri;

  if (!resource_allowed ("process", name))
    return NULL;

  escaped = cmacs_dispatch_lisp_escape (name);
  expr = g_strdup_printf (
    "(let ((p (get-process \"%s\")))"
    "  (if (and p (process-buffer p)"
    "           (buffer-live-p (process-buffer p)))"
    "      (with-current-buffer (process-buffer p)"
    "        (buffer-substring-no-properties (point-min) (point-max)))"
    "    (error \"no such process or its buffer is dead\")))",
    escaped);

  content = cmacs_dispatch_eval (expr, &error);
  if (content == NULL)
    return NULL;

  rc = mcp_resource_contents_new_text (uri, content, "text/plain");
  return g_list_append (NULL, rc);
}

#ifdef HAVE_CMACS_GOWL
/* ── keybinds:// ──────────────────────────────────────────────────── */

static GList *
handle_keybinds_resource (McpServer   *server,
                          const gchar *uri,
                          gpointer     user_data)
{
  g_autoptr (GError) error = NULL;
  g_autofree gchar *json = NULL;
  McpResourceContents *rc;

  (void) server;
  (void) uri;
  (void) user_data;

  json = cmacs_dispatch_gowl_list_keybinds (&error);
  if (json == NULL)
    return NULL;

  rc = mcp_resource_contents_new_text ("keybinds://", json,
                                       "application/json");
  return g_list_append (NULL, rc);
}

/* ── screenshot://frame ───────────────────────────────────────────── */

static GList *
handle_screenshot_resource (McpServer   *server,
                            const gchar *uri,
                            gpointer     user_data)
{
  g_autoptr (GError) error = NULL;
  g_autofree gchar *path = NULL;
  g_autofree gchar *expr = NULL;
  g_autofree gchar *str = NULL;
  g_autofree gchar *data = NULL;
  g_autofree gchar *b64 = NULL;
  gsize len = 0;
  McpResourceContents *rc;

  (void) server;
  (void) uri;
  (void) user_data;

  path = cmacs_mcp_temp_path ("cmacs-mcp-frame-XXXXXX.png");
  if (path == NULL)
    return NULL;
  {
    g_autofree gchar *epath = cmacs_dispatch_lisp_escape (path);
    /* CMACS redact: no picture of a screen an excluded window is on.  */
    expr = g_strdup_printf (
      "(progn (require 'cmacs-redact)"
      "  (cmacs-redact-capture-guard 'desktop)"
      "  (gowl-screenshot 'desktop \"%s\" t))", epath);
  }

  str = cmacs_dispatch_eval (expr, &error);
  if (str == NULL
      || !g_file_get_contents (path, &data, &len, NULL)
      || len == 0)
    {
      g_unlink (path);
      return NULL;
    }

  b64 = g_base64_encode ((const guchar *) data, len);
  g_unlink (path);
  rc = mcp_resource_contents_new_blob ("screenshot://frame", b64,
                                       "image/png");
  return g_list_append (NULL, rc);
}
#endif /* HAVE_CMACS_GOWL */

/* ── Registration ─────────────────────────────────────────────────── */

void
cmacs_mcp_register_resources (McpServer *server)
{
  McpResourceTemplate *tmpl;
  McpResource *res;

  /* buffer://{name} */
  tmpl = mcp_resource_template_new ("buffer://{name}", "Buffer Contents");
  mcp_resource_template_set_description (tmpl,
    "Read the text content of an Emacs buffer by name");
  mcp_resource_template_set_mime_type (tmpl, "text/plain");
  mcp_server_add_resource_template (server, tmpl,
    handle_buffer_resource, NULL, NULL);
  g_object_unref (tmpl);

  /* file://{path} */
  tmpl = mcp_resource_template_new ("file://{+path}", "File Contents");
  mcp_resource_template_set_description (tmpl,
    "Read a file from the filesystem");
  mcp_resource_template_set_mime_type (tmpl, "text/plain");
  mcp_server_add_resource_template (server, tmpl,
    handle_file_resource, NULL, NULL);
  g_object_unref (tmpl);

  /* messages:// */
  res = mcp_resource_new ("messages://", "Emacs Messages");
  mcp_resource_set_description (res, "The *Messages* buffer contents");
  mcp_resource_set_mime_type (res, "text/plain");
  mcp_server_add_resource (server, res,
    handle_messages_resource, NULL, NULL);
  g_object_unref (res);

  /* variable://{name} */
  tmpl = mcp_resource_template_new ("variable://{name}", "Variable Value");
  mcp_resource_template_set_description (tmpl,
    "Read the current value of an Emacs Lisp variable");
  mcp_resource_template_set_mime_type (tmpl, "text/plain");
  mcp_server_add_resource_template (server, tmpl,
    handle_variable_resource, NULL, NULL);
  g_object_unref (tmpl);

  /* process://{name} */
  tmpl = mcp_resource_template_new ("process://{name}",
                                    "Process Output");
  mcp_resource_template_set_description (tmpl,
    "Read the output buffer of a named Emacs subprocess");
  mcp_resource_template_set_mime_type (tmpl, "text/plain");
  mcp_server_add_resource_template (server, tmpl,
    handle_process_resource, NULL, NULL);
  g_object_unref (tmpl);

#ifdef HAVE_CMACS_GOWL
  /* keybinds:// */
  res = mcp_resource_new ("keybinds://", "Compositor Keybinds");
  mcp_resource_set_description (res,
    "All gowl compositor keybindings as a JSON array");
  mcp_resource_set_mime_type (res, "application/json");
  mcp_server_add_resource (server, res,
    handle_keybinds_resource, NULL, NULL);
  g_object_unref (res);

  /* screenshot://frame */
  res = mcp_resource_new ("screenshot://frame", "Desktop Screenshot");
  mcp_resource_set_description (res,
    "A fresh PNG screenshot of the whole desktop");
  mcp_resource_set_mime_type (res, "image/png");
  mcp_server_add_resource (server, res,
    handle_screenshot_resource, NULL, NULL);
  g_object_unref (res);
#endif /* HAVE_CMACS_GOWL */
}

#endif /* HAVE_CMACS_MCP */
