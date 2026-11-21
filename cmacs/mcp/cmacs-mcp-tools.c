/*
 * cmacs-mcp-tools.c — MCP tool master registration and schema helper
 *
 * Copyright (C) 2026 Zach Podbielniak
 * SPDX-License-Identifier: AGPL-3.0-or-later
 */

#include <config.h>

#ifdef HAVE_CMACS_MCP

#include "cmacs-mcp-tools.h"

#include <json-glib/json-glib.h>
#include <glib/gstdio.h>
#include <fcntl.h>
#include <string.h>
#include <unistd.h>

/* ── Schema helper ────────────────────────────────────────────────── */

JsonNode *
cmacs_mcp_schema_from_string (const gchar *json_str)
{
  g_autoptr (JsonParser) parser = json_parser_new ();
  g_autoptr (GError) error = NULL;

  if (!json_parser_load_from_data (parser, json_str, -1, &error))
    {
      g_warning ("cmacs-mcp: bad JSON schema: %s", error->message);
      return NULL;
    }

  return json_node_copy (json_parser_get_root (parser));
}

/* ── Image content helper ─────────────────────────────────────────── */

gboolean
cmacs_mcp_result_add_png_file (McpToolResult *result, const gchar *path)
{
  g_autofree gchar *data = NULL;
  g_autofree gchar *b64 = NULL;
  gsize len = 0;

  if (path == NULL
      || !g_file_get_contents (path, &data, &len, NULL)
      || len == 0)
    return FALSE;

  b64 = g_base64_encode ((const guchar *) data, len);
  mcp_tool_result_add_image (result, b64, "image/png");
  g_unlink (path);
  return TRUE;
}

/* ── Scratch files ────────────────────────────────────────────────── */

gchar *
cmacs_mcp_temp_path (const gchar *template)
{
  gchar *path;
  gint fd;

  if (template == NULL || strstr (template, "XXXXXX") == NULL)
    return NULL;

  path = g_build_filename (g_get_user_runtime_dir (), template, NULL);
  fd = g_mkstemp_full (path, O_RDWR | O_CREAT | O_EXCL, 0600);
  if (fd < 0)
    {
      g_free (path);
      return NULL;
    }
  close (fd);
  return path;
}

/* ── Master registration ──────────────────────────────────────────── */

void
cmacs_mcp_register_c_tools (McpServer *server)
{
  /* The tools that are still hand-written C, and only those: the
     privileged set (eval, send_keys, gi_call, the *_eval tools, ...),
     the C introspection family, and the four that return an image.
     `admin/cmacs-capability-audit.sh --remainder' lists them with the
     reason each stays.  Their order here is the order they have always
     been registered in.

     Every other MCP tool is a `cmacs-brigade-deftool' form in
     lisp/cmacs/cmacs-*-tools.el, published by the last call below; the
     C handlers those replaced were deleted, and what they promised a
     client is frozen in test/cmacs/data/mcp-wire-schema.json.  */
  cmacs_mcp_tools_eval_register (server);
  cmacs_mcp_tools_input_register (server);
  cmacs_mcp_tools_process_register (server);
  cmacs_mcp_tools_shell_register (server);

#ifdef HAVE_CMACS_GI
  cmacs_mcp_tools_gi_register (server);
#endif

#ifdef HAVE_CMACS_GOWL
  cmacs_mcp_tools_gowl_register (server);
#endif

#ifdef HAVE_CMACS_CINTROSPECT
  cmacs_mcp_tools_cintrospect_register (server);
#endif

#ifdef HAVE_CMACS_CAD
  cmacs_mcp_tools_cad_register (server);
#endif

#ifdef HAVE_CMACS_LRGTERM
  cmacs_mcp_tools_lrgterm_register (server);
#endif
}

void
cmacs_mcp_register_all_tools (McpServer *server)
{
  cmacs_mcp_register_c_tools (server);

  /* The tool registry, in every build (it needs no AI subsystem).
     Last, so it sees every hand-written tool: a registry tool is never
     published under a name one of them already serves, so a tool of
     anyone's called "eval" cannot quietly take over the real one.  See
     publish_one in cmacs-mcp-tools-brigade.c, which also tells the
     session when the registry's Lisp side failed to load.  */
  cmacs_mcp_tools_brigade_register (server);
}

#endif /* HAVE_CMACS_MCP */
