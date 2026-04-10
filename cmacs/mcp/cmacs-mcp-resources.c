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

/* ── buffer://{name} ──────────────────────────────────────────────── */

static GList *
handle_buffer_resource (McpServer   *server,
                        const gchar *uri,
                        gpointer     user_data)
{
  const gchar *name;
  g_autoptr (GError) error = NULL;
  g_autofree gchar *expr = NULL;
  g_autofree gchar *content = NULL;
  McpResourceContents *rc;

  (void) server;
  (void) user_data;

  /* Extract buffer name from URI: "buffer://NAME" */
  if (g_str_has_prefix (uri, "buffer://"))
    name = uri + 9;
  else
    name = uri;

  expr = g_strdup_printf (
    "(with-current-buffer \"%s\""
    "  (buffer-substring-no-properties (point-min) (point-max)))",
    name);

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

  content = cmacs_dispatch_eval (
    "(with-current-buffer \"*Messages*\""
    "  (buffer-substring-no-properties (point-min) (point-max)))",
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
  g_autofree gchar *content = NULL;
  McpResourceContents *rc;

  (void) server;
  (void) user_data;

  if (g_str_has_prefix (uri, "variable://"))
    name = uri + 11;
  else
    name = uri;

  expr = g_strdup_printf (
    "(prin1-to-string (symbol-value '%s))", name);

  content = cmacs_dispatch_eval (expr, &error);
  if (content == NULL)
    return NULL;

  rc = mcp_resource_contents_new_text (uri, content, "text/plain");
  return g_list_append (NULL, rc);
}

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
}

#endif /* HAVE_CMACS_MCP */
