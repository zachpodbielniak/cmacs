/*
 * cmacs-mcp-tools-lrgterm.c — the one output_lrg MCP tool that is still C
 *
 * Copyright (C) 2026 Zach Podbielniak
 * SPDX-License-Identifier: AGPL-3.0-or-later
 *
 * lrgterm_dump_screen drives the `lrg-capture-screen' DEFUN and attaches
 * a live PNG of the lrg frame, so an agent can SEE what the backend is
 * rendering.  A registry tool (`cmacs-brigade-deftool') returns text, so
 * this one stays a hand-written handler.
 *
 * The other ten lrgterm_* tools that used to be registered here are
 * registry tools now (lisp/cmacs/cmacs-lrgterm-tools.el), published by
 * cmacs-mcp-tools-brigade.c in every build with an MCP server; their C
 * handlers were deleted.  What they promised a client is frozen in
 * test/cmacs/data/mcp-wire-schema.json.
 */

#include <config.h>

#if defined(HAVE_CMACS_MCP) && defined(HAVE_CMACS_LRGTERM)

#include <glib.h>
#include "lisp.h"
#include "cmacs-mcp-tools.h"
#include "cmacs-eval-dispatch.h"

/* Elisp that binds `f' to the first live output_lrg frame, then runs BODY,
   or yields ERRMSG when no lrg frame exists.  Takes ownership of BODY.  */
static gchar *
lt_with_frame (gchar *body)
{
  gchar *out = g_strdup_printf
    ("(let ((f (catch 'lrgf (dolist (fr (frame-list))"
     " (when (eq (framep fr) 'lrg) (throw 'lrgf fr))))))"
     " (if f (progn %s) \"No lrg frame (start Emacs with --lrg)\"))",
     body);
  g_free (body);
  return out;
}

static McpToolResult *
handle_dump_screen (McpServer *s, const gchar *n, JsonObject *a, gpointer u)
{
  g_autofree gchar *path = cmacs_mcp_temp_path ("cmacs-lrgterm-dump-XXXXXX.png");
  g_autofree gchar *epath = cmacs_dispatch_lisp_escape (path);
  g_autoptr (GError) error = NULL;
  g_autofree gchar *elisp = NULL;
  g_autofree gchar *out = NULL;
  McpToolResult *result;

  (void) s; (void) n; (void) a; (void) u;
  if (path == NULL)
    {
      result = mcp_tool_result_new (TRUE);
      mcp_tool_result_add_text (result,
                                "cannot create a scratch file for the dump");
      return result;
    }
  /* CMACS redact: the frame is every visible buffer at once, so one
     buffer the user's privacy rules exclude refuses the dump.  The
     guard signals, which comes back as the tool's error.  */
  elisp = lt_with_frame (g_strdup_printf
    ("(progn (require 'cmacs-redact)"
     " (cmacs-redact-capture-guard 'frame f)"
     " (redisplay t) (lrg-capture-screen \"%s\" f) \"ok\")", epath));
  out = cmacs_dispatch_eval (elisp, &error);
  if (out == NULL || g_strcmp0 (out, "ok") != 0
      || !g_file_test (path, G_FILE_TEST_EXISTS))
    {
      result = mcp_tool_result_new (TRUE);
      mcp_tool_result_add_text (result,
        out ? out : (error ? error->message : "capture failed"));
      return result;
    }
  result = mcp_tool_result_new (FALSE);
  mcp_tool_result_add_text (result, "lrg frame snapshot:");
  cmacs_mcp_result_add_png_file (result, path);
  return result;
}

void
cmacs_mcp_tools_lrgterm_register (McpServer *server)
{
  McpTool *tool;

  /* lrgterm_dump_screen.  Name, description and hint are what the tool
     has always published; see the frozen wire schema before changing
     any of them.  */
  tool = mcp_tool_new ("lrgterm_dump_screen",
    "Capture the lrg frame to a PNG and return it as an image, so you can see "
    "exactly what the libregnum/raylib backend is rendering.");
  mcp_tool_set_read_only_hint (tool, TRUE);
  mcp_server_add_tool (server, tool, handle_dump_screen, NULL, NULL);
  g_object_unref (tool);
}

#endif /* HAVE_CMACS_MCP && HAVE_CMACS_LRGTERM */
