/*
 * cmacs-mcp-tools-project.c — Workspace file MCP tools
 *
 * Copyright (C) 2026 Zach Podbielniak
 * SPDX-License-Identifier: AGPL-3.0-or-later
 *
 * Generic read/write/list/find file tools scoped to the open project
 * in the workspace.  Designed for a remote "copilot" agent connected
 * over the MCP bridge: every path is resolved against the workspace
 * root and, unless `cmacs-mcp-workspace-confine' is explicitly nil,
 * confined to it so a remote client cannot escape the project tree.
 *
 * The workspace root is, in order of preference:
 *   1. the `cmacs-mcp-workspace-root' variable, if set;
 *   2. the project.el root of the current project;
 *   3. `default-directory'.
 */

#include <config.h>

#ifdef HAVE_CMACS_MCP

#include "lisp.h"
#include "cmacs-mcp-tools.h"
#include "cmacs-eval-dispatch.h"

/* Elisp that evaluates to the workspace root directory string. */
#define WORKSPACE_ROOT_EXPR                                     \
  "(or (bound-and-true-p cmacs-mcp-workspace-root)"             \
  "    (and (fboundp 'project-current)"                        \
  "         (let ((p (ignore-errors (project-current nil))))"  \
  "           (and p (project-root p))))"                      \
  "    default-directory)"

/* Helper: build an error result with MESSAGE. */
static McpToolResult *
project_error (const gchar *message)
{
  McpToolResult *result = mcp_tool_result_new (TRUE);
  mcp_tool_result_add_text (result, message);
  return result;
}

/* Wrap BODY (elisp using the bound symbols `root' and `target') in the
   workspace-root resolution and path-confinement prelude.  ESCAPED_PATH
   is a g_strescape'd relative or absolute path.  Caller frees. */
static gchar *
project_expr (const gchar *escaped_path, const gchar *body)
{
  return g_strdup_printf (
    "(let* ((root (file-name-as-directory"
    "              (expand-file-name " WORKSPACE_ROOT_EXPR ")))"
    "       (target (expand-file-name \"%s\" root)))"
    "  (unless (and (boundp 'cmacs-mcp-workspace-confine)"
    "               (null cmacs-mcp-workspace-confine))"
    "    (let ((rt (file-truename root))"
    "          (tt (file-truename target)))"
    "      (unless (or (string-prefix-p rt tt)"
    "                  (string= (directory-file-name rt)"
    "                           (directory-file-name tt)))"
    "        (error \"path escapes workspace root\"))))"
    "  %s)",
    escaped_path, body);
}

/* ── project_root ─────────────────────────────────────────────────── */

static McpToolResult *
handle_project_root (McpServer *s, const gchar *n,
                     JsonObject *a, gpointer u)
{
  g_autoptr (GError) error = NULL;
  g_autofree gchar *str = NULL;
  McpToolResult *result;

  (void) s; (void) n; (void) a; (void) u;

  str = cmacs_dispatch_eval_string (
    "(file-name-as-directory"
    " (expand-file-name " WORKSPACE_ROOT_EXPR "))",
    &error);
  result = mcp_tool_result_new (str == NULL);
  mcp_tool_result_add_text (result, str ? str : error->message);
  return result;
}

/* ── project_read_file ────────────────────────────────────────────── */

static McpToolResult *
handle_project_read_file (McpServer *s, const gchar *n,
                          JsonObject *a, gpointer u)
{
  const gchar *path;
  g_autofree gchar *ep = NULL, *expr = NULL, *str = NULL;
  g_autoptr (GError) error = NULL;
  McpToolResult *result;

  (void) s; (void) n; (void) u;

  path = json_object_get_string_member (a, "path");
  if (path == NULL)
    return project_error ("Missing required argument: path");

  ep = g_strescape (path, NULL);
  expr = project_expr (ep,
    "(if (file-readable-p target)"
    "    (let ((sz (file-attribute-size (file-attributes target))))"
    "      (when (and sz (> sz 2000000))"
    "        (error \"file too large: %d bytes\" sz))"
    "      (with-temp-buffer"
    "        (insert-file-contents target)"
    "        (buffer-substring-no-properties (point-min) (point-max))))"
    "  (error \"file not readable: %s\" target))");

  str = cmacs_dispatch_eval_string (expr, &error);
  result = mcp_tool_result_new (str == NULL);
  mcp_tool_result_add_text (result, str ? str : error->message);
  return result;
}

/* ── project_write_file ───────────────────────────────────────────── */

static McpToolResult *
handle_project_write_file (McpServer *s, const gchar *n,
                           JsonObject *a, gpointer u)
{
  const gchar *path, *content;
  g_autofree gchar *ep = NULL, *ecnt = NULL, *body = NULL;
  g_autofree gchar *expr = NULL, *str = NULL;
  g_autoptr (GError) error = NULL;
  McpToolResult *result;

  (void) s; (void) n; (void) u;

  path = json_object_get_string_member (a, "path");
  content = json_object_get_string_member (a, "content");
  if (path == NULL || content == NULL)
    return project_error (
      "Missing required arguments: path, content");

  ep = g_strescape (path, NULL);
  ecnt = g_strescape (content, NULL);
  body = g_strdup_printf (
    "(progn"
    "  (make-directory (file-name-directory target) t)"
    "  (with-temp-buffer"
    "    (insert \"%s\")"
    "    (let ((bytes (string-bytes (buffer-string))))"
    "      (write-region (point-min) (point-max) target nil 'quiet)"
    "      (format \"wrote %%d bytes to %%s\""
    "              bytes (file-relative-name target root)))))",
    ecnt);
  expr = project_expr (ep, body);

  str = cmacs_dispatch_eval (expr, &error);
  result = mcp_tool_result_new (str == NULL);
  mcp_tool_result_add_text (result, str ? str : error->message);
  return result;
}

/* ── project_list_files ───────────────────────────────────────────── */

static McpToolResult *
handle_project_list_files (McpServer *s, const gchar *n,
                           JsonObject *a, gpointer u)
{
  const gchar *directory;
  g_autofree gchar *ed = NULL, *expr = NULL, *str = NULL;
  g_autoptr (GError) error = NULL;
  McpToolResult *result;

  (void) s; (void) n; (void) u;

  directory = json_object_get_string_member (a, "directory");
  ed = g_strescape (directory ? directory : ".", NULL);
  expr = project_expr (ed,
    "(if (file-directory-p target)"
    "    (let ((entries (seq-remove"
    "                    (lambda (f) (member f '(\".\" \"..\")))"
    "                    (directory-files target))))"
    "      (if entries"
    "          (mapconcat"
    "           (lambda (f)"
    "             (let ((full (expand-file-name f target)))"
    "               (if (file-directory-p full) (concat f \"/\")"
    "                 (format \"%s\\t%d\" f"
    "                   (or (file-attribute-size"
    "                        (file-attributes full)) 0)))))"
    "           (sort entries #'string<) \"\\n\")"
    "        \"(empty directory)\"))"
    "  (error \"not a directory: %s\" target))");

  str = cmacs_dispatch_eval_string (expr, &error);
  result = mcp_tool_result_new (str == NULL);
  mcp_tool_result_add_text (result, str ? str : error->message);
  return result;
}

/* ── project_find_files ───────────────────────────────────────────── */

static McpToolResult *
handle_project_find_files (McpServer *s, const gchar *n,
                           JsonObject *a, gpointer u)
{
  const gchar *pattern;
  g_autofree gchar *epat = NULL, *body = NULL, *expr = NULL, *str = NULL;
  g_autoptr (GError) error = NULL;
  McpToolResult *result;

  (void) s; (void) n; (void) u;

  pattern = json_object_get_string_member (a, "pattern");
  if (pattern == NULL)
    return project_error ("Missing required argument: pattern");

  epat = g_strescape (pattern, NULL);
  body = g_strdup_printf (
    "(let ((hits (directory-files-recursively"
    "             root \"%s\" nil"
    "             (lambda (d)"
    "               (not (string-match-p \"\\\\.git\\\\'\" d))))))"
    "  (if hits"
    "      (mapconcat (lambda (f) (file-relative-name f root))"
    "                 (seq-take hits 500) \"\\n\")"
    "    \"(no matches)\"))",
    epat);
  /* The path argument is unused by the body; "." keeps target == root. */
  expr = project_expr (".", body);

  str = cmacs_dispatch_eval_string (expr, &error);
  result = mcp_tool_result_new (str == NULL);
  mcp_tool_result_add_text (result, str ? str : error->message);
  return result;
}

/* ── Registration ─────────────────────────────────────────────────── */

void
cmacs_mcp_tools_project_register (McpServer *server)
{
  McpTool *tool;
  JsonNode *schema;

  /* project_root */
  tool = mcp_tool_new ("project_root",
    "Return the absolute path of the workspace root (the open "
    "project directory) that the other project_* tools resolve "
    "paths against.");
  mcp_tool_set_read_only_hint (tool, TRUE);
  mcp_server_add_tool (server, tool, handle_project_root, NULL, NULL);
  g_object_unref (tool);

  /* project_read_file */
  tool = mcp_tool_new ("project_read_file",
    "Read a file from the workspace. The path is relative to the "
    "workspace root (absolute paths must still resolve inside it). "
    "Returns the raw file contents.");
  schema = cmacs_mcp_schema_from_string (
    "{\"type\":\"object\",\"properties\":{"
    "\"path\":{\"type\":\"string\","
      "\"description\":\"File path relative to the workspace root\"}"
    "},\"required\":[\"path\"]}");
  mcp_tool_set_input_schema (tool, schema);
  mcp_tool_set_read_only_hint (tool, TRUE);
  mcp_server_add_tool (server, tool, handle_project_read_file,
                       NULL, NULL);
  g_object_unref (tool);

  /* project_write_file */
  tool = mcp_tool_new ("project_write_file",
    "Write a file in the workspace, creating parent directories as "
    "needed. The path is resolved against the workspace root and "
    "cannot escape it. Overwrites any existing file.");
  schema = cmacs_mcp_schema_from_string (
    "{\"type\":\"object\",\"properties\":{"
    "\"path\":{\"type\":\"string\","
      "\"description\":\"File path relative to the workspace root\"},"
    "\"content\":{\"type\":\"string\","
      "\"description\":\"Full new file contents\"}"
    "},\"required\":[\"path\",\"content\"]}");
  mcp_tool_set_input_schema (tool, schema);
  mcp_tool_set_destructive_hint (tool, TRUE);
  mcp_server_add_tool (server, tool, handle_project_write_file,
                       NULL, NULL);
  g_object_unref (tool);

  /* project_list_files */
  tool = mcp_tool_new ("project_list_files",
    "List the immediate entries of a workspace directory (defaults "
    "to the workspace root). Directories are suffixed with '/'; "
    "files are followed by a tab and their size in bytes.");
  schema = cmacs_mcp_schema_from_string (
    "{\"type\":\"object\",\"properties\":{"
    "\"directory\":{\"type\":\"string\","
      "\"description\":\"Directory relative to the workspace root "
      "(optional)\"}"
    "}}");
  mcp_tool_set_input_schema (tool, schema);
  mcp_tool_set_read_only_hint (tool, TRUE);
  mcp_server_add_tool (server, tool, handle_project_list_files,
                       NULL, NULL);
  g_object_unref (tool);

  /* project_find_files */
  tool = mcp_tool_new ("project_find_files",
    "Recursively find files in the workspace whose name matches an "
    "Emacs regexp (e.g. \"\\\\.c\\\\'\" for C files). The .git "
    "directory is skipped; up to 500 paths are returned relative "
    "to the workspace root.");
  schema = cmacs_mcp_schema_from_string (
    "{\"type\":\"object\",\"properties\":{"
    "\"pattern\":{\"type\":\"string\","
      "\"description\":\"Emacs regexp matched against file names\"}"
    "},\"required\":[\"pattern\"]}");
  mcp_tool_set_input_schema (tool, schema);
  mcp_tool_set_read_only_hint (tool, TRUE);
  mcp_server_add_tool (server, tool, handle_project_find_files,
                       NULL, NULL);
  g_object_unref (tool);
}

#endif /* HAVE_CMACS_MCP */
