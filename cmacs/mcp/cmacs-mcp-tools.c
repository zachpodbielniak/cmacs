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
cmacs_mcp_register_all_tools (McpServer *server)
{
  cmacs_mcp_tools_eval_register (server);
  cmacs_mcp_tools_buffer_register (server);
  cmacs_mcp_tools_window_register (server);
  cmacs_mcp_tools_input_register (server);
  cmacs_mcp_tools_process_register (server);
  cmacs_mcp_tools_debug_register (server);
  cmacs_mcp_tools_edit_register (server);
  cmacs_mcp_tools_shell_register (server);
  cmacs_mcp_tools_project_register (server);

#ifdef HAVE_CMACS_AI_BRIGADE
  /* Registered after the built-ins so it can see them: a brigade tool
     whose name collides with one is skipped with a warning rather than
     replacing it (mcp_server_add_tool replaces on collision, so a user
     tool called "eval" would otherwise silently take over the real
     one). */
  cmacs_mcp_tools_brigade_register (server);
#endif

#ifdef HAVE_CMACS_GI
  cmacs_mcp_tools_gi_register (server);
#endif

#ifdef HAVE_CMACS_GOWL
  cmacs_mcp_tools_gowl_register (server);
#endif

#ifdef HAVE_CMACS_CINTROSPECT
  cmacs_mcp_tools_cintrospect_register (server);
#endif

#ifdef HAVE_CMACS_AUDIO
  cmacs_mcp_tools_audio_register (server);
#endif

#ifdef HAVE_CMACS_AI
  cmacs_mcp_tools_ai_register (server);
#endif

#ifdef HAVE_CMACS_GSURF
  cmacs_mcp_tools_gsurf_register (server);
#endif

#ifdef HAVE_CMACS_LIBREGNUM
  cmacs_mcp_tools_libregnum_register (server);
#endif

#ifdef HAVE_CMACS_GNUSEYE
  cmacs_mcp_tools_gnuseye_register (server);
#endif

#ifdef HAVE_CMACS_SECONDBRAIN
  cmacs_mcp_tools_secondbrain_register (server);
#endif

#ifdef HAVE_CMACS_CAD
  cmacs_mcp_tools_cad_register (server);
#endif

#ifdef HAVE_CMACS_LRGTERM
  cmacs_mcp_tools_lrgterm_register (server);
#endif

#ifdef HAVE_CMACS_IMGEDIT
  cmacs_mcp_tools_imgedit_register (server);
#endif

#ifdef HAVE_CMACS_CALCULATOR
  cmacs_mcp_tools_calculator_register (server);
#endif

#ifdef HAVE_CMACS_VIDSTUDIO
  cmacs_mcp_tools_vidstudio_register (server);
#endif

#ifdef HAVE_CMACS_DBEXPLORER
  cmacs_mcp_tools_dbexplorer_register (server);
#endif
}

#endif /* HAVE_CMACS_MCP */
