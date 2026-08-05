/*
 * cmacs-mcp-tools-cad.c — parametric CAD "vibe CAD" MCP tools
 *
 * Copyright (C) 2026 Zach Podbielniak
 * SPDX-License-Identifier: AGPL-3.0-or-later
 *
 * Thin MCP tools that drive the CAD subsystem by dispatching Elisp
 * (`cmacs-cad-mcp-*' in lisp/cmacs/cmacs-cad-mcp.el).  The fused
 * cad_set_source / cad_patch_source tools are the agent's edit-eval inner
 * loop; cad_snapshot returns an inline PNG.  Print starting is gated:
 * cad_print only begins a print when BOTH start and confirm are true.
 */

#include <config.h>

#if defined(HAVE_CMACS_MCP) && defined(HAVE_CMACS_CAD)

#include "lisp.h"
#include "cmacs-mcp-tools.h"
#include "cmacs-eval-dispatch.h"

/* Render STR as an Elisp string literal, or `nil' when STR is NULL. */
static gchar *
cad_lisp_str (const gchar *str)
{
  GString *s;
  const gchar *p;
  if (str == NULL)
    return g_strdup ("nil");
  s = g_string_new ("\"");
  for (p = str; *p; p++)
    {
      if (*p == '"' || *p == '\\')
        g_string_append_c (s, '\\');
      g_string_append_c (s, *p);
    }
  g_string_append_c (s, '"');
  return g_string_free (s, FALSE);
}

/* Wrap BODY so the cmacs-cad-mcp helper library is loaded first.  Takes
 * ownership of BODY. */
static gchar *
cad_wrap (gchar *body)
{
  gchar *out =
    g_strdup_printf ("(progn (require 'cmacs-cad-mcp) %s)", body);
  g_free (body);
  return out;
}

/* Run ELISP (after loading the helper library) and return its value (or
 * error) as the tool's text result.  Takes ownership of ELISP. */
static McpToolResult *
cad_eval_result (gchar *elisp)
{
  g_autoptr (GError) error = NULL;
  g_autofree gchar *src = cad_wrap (elisp);
  g_autofree gchar *out = cmacs_dispatch_eval (src, &error);
  McpToolResult *result = mcp_tool_result_new (out == NULL);
  mcp_tool_result_add_text (result,
    out ? out : (error ? error->message : "error"));
  return result;
}

/* The "path" argument, as an Elisp string literal (caller frees). */
static gchar *
cad_path_arg (JsonObject *a)
{
  return cad_lisp_str (json_object_has_member (a, "path")
    ? json_object_get_string_member_with_default (a, "path", NULL) : NULL);
}

static McpToolResult *
handle_open (McpServer *s, const gchar *n, JsonObject *a, gpointer u)
{
  g_autofree gchar *p = cad_path_arg (a);
  (void) s; (void) n; (void) u;
  return cad_eval_result (g_strdup_printf ("(cmacs-cad-mcp-open %s)", p));
}

static McpToolResult *
handle_get_source (McpServer *s, const gchar *n, JsonObject *a, gpointer u)
{
  g_autofree gchar *p = cad_path_arg (a);
  (void) s; (void) n; (void) u;
  return cad_eval_result
    (g_strdup_printf ("(cmacs-cad-mcp-get-source %s)", p));
}

static McpToolResult *
handle_set_source (McpServer *s, const gchar *n, JsonObject *a, gpointer u)
{
  g_autofree gchar *p = cad_path_arg (a);
  g_autofree gchar *src = cad_lisp_str (json_object_has_member (a, "source")
    ? json_object_get_string_member_with_default (a, "source", NULL) : NULL);
  (void) s; (void) n; (void) u;
  return cad_eval_result
    (g_strdup_printf ("(cmacs-cad-mcp-set-source %s %s)", p, src));
}

static McpToolResult *
handle_patch_source (McpServer *s, const gchar *n, JsonObject *a, gpointer u)
{
  g_autofree gchar *p = cad_path_arg (a);
  g_autofree gchar *old = cad_lisp_str (json_object_has_member (a, "old")
    ? json_object_get_string_member_with_default (a, "old", NULL) : NULL);
  g_autofree gchar *nw = cad_lisp_str (json_object_has_member (a, "new")
    ? json_object_get_string_member_with_default (a, "new", NULL) : NULL);
  (void) s; (void) n; (void) u;
  return cad_eval_result
    (g_strdup_printf ("(cmacs-cad-mcp-patch-source %s %s %s)", p, old, nw));
}

static McpToolResult *
handle_eval (McpServer *s, const gchar *n, JsonObject *a, gpointer u)
{
  g_autofree gchar *p = cad_path_arg (a);
  (void) s; (void) n; (void) u;
  return cad_eval_result (g_strdup_printf ("(cmacs-cad-mcp-eval %s)", p));
}

static McpToolResult *
handle_params (McpServer *s, const gchar *n, JsonObject *a, gpointer u)
{
  g_autofree gchar *p = cad_path_arg (a);
  (void) s; (void) n; (void) u;
  return cad_eval_result (g_strdup_printf ("(cmacs-cad-mcp-params %s)", p));
}

static McpToolResult *
handle_inspect (McpServer *s, const gchar *n, JsonObject *a, gpointer u)
{
  g_autofree gchar *p = cad_path_arg (a);
  (void) s; (void) n; (void) u;
  return cad_eval_result (g_strdup_printf ("(cmacs-cad-mcp-inspect %s)", p));
}

static McpToolResult *
handle_feature_tree (McpServer *s, const gchar *n, JsonObject *a, gpointer u)
{
  g_autofree gchar *p = cad_path_arg (a);
  (void) s; (void) n; (void) u;
  return cad_eval_result
    (g_strdup_printf ("(cmacs-cad-mcp-feature-tree %s)", p));
}

static McpToolResult *
handle_section (McpServer *s, const gchar *n, JsonObject *a, gpointer u)
{
  g_autofree gchar *p = cad_path_arg (a);
  g_autofree gchar *axis = cad_lisp_str (json_object_has_member (a, "axis")
    ? json_object_get_string_member_with_default (a, "axis", NULL) : "z");
  double offset = json_object_has_member (a, "offset")
    ? json_object_get_double_member (a, "offset") : 0.0;
  (void) s; (void) n; (void) u;
  return cad_eval_result
    (g_strdup_printf ("(cmacs-cad-mcp-section %s %s %g)", p, axis, offset));
}

static McpToolResult *
handle_export (McpServer *s, const gchar *n, JsonObject *a, gpointer u)
{
  g_autofree gchar *p = cad_path_arg (a);
  g_autofree gchar *out = cad_lisp_str (json_object_has_member (a, "out")
    ? json_object_get_string_member_with_default (a, "out", NULL) : NULL);
  g_autofree gchar *fmt = cad_lisp_str (json_object_has_member (a, "format")
    ? json_object_get_string_member_with_default (a, "format", NULL) : "stl");
  (void) s; (void) n; (void) u;
  return cad_eval_result
    (g_strdup_printf ("(cmacs-cad-mcp-export %s %s %s)", p, out, fmt));
}

static McpToolResult *
handle_snapshot (McpServer *s, const gchar *n, JsonObject *a, gpointer u)
{
  g_autofree gchar *p = cad_path_arg (a);
  g_autoptr (GError) error = NULL;
  g_autofree gchar *elisp =
    cad_wrap (g_strdup_printf ("(cmacs-cad-mcp-snapshot %s)", p));
  g_autofree gchar *out = cmacs_dispatch_eval (elisp, &error);
  McpToolResult *result;
  (void) s; (void) n; (void) u;

  if (out == NULL)
    {
      result = mcp_tool_result_new (TRUE);
      mcp_tool_result_add_text (result, error ? error->message : "error");
      return result;
    }
  /* The helper returns the PNG path, or a string starting "error:". */
  if (g_str_has_prefix (out, "error:"))
    {
      result = mcp_tool_result_new (TRUE);
      mcp_tool_result_add_text (result, out);
      return result;
    }
  result = mcp_tool_result_new (FALSE);
  if (!cmacs_mcp_result_add_png_file (result, out))
    mcp_tool_result_add_text (result, out);
  return result;
}

static McpToolResult *
handle_slice (McpServer *s, const gchar *n, JsonObject *a, gpointer u)
{
  g_autofree gchar *p = cad_path_arg (a);
  double timeout = json_object_has_member (a, "timeout")
    ? json_object_get_double_member (a, "timeout") : 300.0;
  (void) s; (void) n; (void) u;
  return cad_eval_result
    (g_strdup_printf ("(cmacs-cad-mcp-slice %s %g)", p, timeout));
}

static McpToolResult *
handle_printers (McpServer *s, const gchar *n, JsonObject *a, gpointer u)
{
  (void) s; (void) n; (void) a; (void) u;
  return cad_eval_result (g_strdup ("(cmacs-cad-mcp-printers)"));
}

static McpToolResult *
handle_print (McpServer *s, const gchar *n, JsonObject *a, gpointer u)
{
  g_autofree gchar *printer = cad_lisp_str
    (json_object_has_member (a, "printer")
       ? json_object_get_string_member_with_default (a, "printer", NULL) : NULL);
  g_autofree gchar *gcode = cad_lisp_str
    (json_object_has_member (a, "gcode")
       ? json_object_get_string_member_with_default (a, "gcode", NULL) : NULL);
  gboolean start = json_object_has_member (a, "start")
    && json_object_get_boolean_member (a, "start");
  gboolean confirm = json_object_has_member (a, "confirm")
    && json_object_get_boolean_member (a, "confirm");
  (void) s; (void) n; (void) u;
  return cad_eval_result
    (g_strdup_printf ("(cmacs-cad-mcp-print %s %s %s %s)", printer, gcode,
                      start ? "t" : "nil", confirm ? "t" : "nil"));
}

/* The "name" (assembly) argument, as an Elisp string literal. */
static gchar *
cad_name_arg (JsonObject *a)
{
  return cad_lisp_str (json_object_has_member (a, "name")
    ? json_object_get_string_member_with_default (a, "name", NULL) : NULL);
}

static McpToolResult *
handle_assembly_info (McpServer *s, const gchar *n, JsonObject *a, gpointer u)
{
  g_autofree gchar *p = cad_path_arg (a);
  g_autofree gchar *name = cad_name_arg (a);
  (void) s; (void) n; (void) u;
  return cad_eval_result
    (g_strdup_printf ("(cmacs-cad-mcp-assembly-info %s %s)", p, name));
}

static McpToolResult *
handle_assembly_bom (McpServer *s, const gchar *n, JsonObject *a, gpointer u)
{
  g_autofree gchar *p = cad_path_arg (a);
  g_autofree gchar *name = cad_name_arg (a);
  (void) s; (void) n; (void) u;
  return cad_eval_result
    (g_strdup_printf ("(cmacs-cad-mcp-assembly-bom %s %s)", p, name));
}

static McpToolResult *
handle_assembly_interference (McpServer *s, const gchar *n, JsonObject *a,
                              gpointer u)
{
  g_autofree gchar *p = cad_path_arg (a);
  g_autofree gchar *name = cad_name_arg (a);
  (void) s; (void) n; (void) u;
  return cad_eval_result
    (g_strdup_printf ("(cmacs-cad-mcp-assembly-interference %s %s)", p,
                      name));
}

static McpToolResult *
handle_assembly_set_joint (McpServer *s, const gchar *n, JsonObject *a,
                           gpointer u)
{
  g_autofree gchar *p = cad_path_arg (a);
  g_autofree gchar *name = cad_name_arg (a);
  gint64 jid = json_object_has_member (a, "joint")
    ? json_object_get_int_member (a, "joint") : 0;
  double value = json_object_has_member (a, "value")
    ? json_object_get_double_member (a, "value") : 0.0;
  (void) s; (void) n; (void) u;
  return cad_eval_result
    (g_strdup_printf ("(cmacs-cad-mcp-assembly-set-joint %s %s %" G_GINT64_FORMAT
                      " %g)", p, name, jid, value));
}

static void
cad_add (McpServer *server, const gchar *name, const gchar *desc,
         const gchar *schema_json, gboolean read_only,
         McpToolResult *(*handler) (McpServer *, const gchar *,
                                    JsonObject *, gpointer))
{
  McpTool *tool = mcp_tool_new (name, desc);
  if (schema_json)
    mcp_tool_set_input_schema (tool,
      cmacs_mcp_schema_from_string (schema_json));
  if (read_only)
    mcp_tool_set_read_only_hint (tool, TRUE);
  mcp_server_add_tool (server, tool, handler, NULL, NULL);
  g_object_unref (tool);
}

#define PATH_SCHEMA \
  "{\"type\":\"object\",\"properties\":{\"path\":{\"type\":\"string\"}}," \
  "\"required\":[\"path\"]}"

void
cmacs_mcp_tools_cad_register (McpServer *server)
{
  cad_add (server, "cad_open",
    "Open a .cad/.ccad part; returns its language + capabilities.",
    PATH_SCHEMA, TRUE, handle_open);

  cad_add (server, "cad_get_source", "Return a part's source text.",
    PATH_SCHEMA, TRUE, handle_get_source);

  cad_add (server, "cad_set_source",
    "Replace a part's whole SOURCE, write it, re-evaluate, and report "
    "ok+parts or the error with its source location. The edit-eval loop.",
    "{\"type\":\"object\",\"properties\":{\"path\":{\"type\":\"string\"},"
    "\"source\":{\"type\":\"string\"}},\"required\":[\"path\",\"source\"]}",
    FALSE, handle_set_source);

  cad_add (server, "cad_patch_source",
    "Replace the single occurrence of OLD with NEW in a part, then "
    "re-evaluate. Token-economical edits; errors if OLD is absent/ambiguous.",
    "{\"type\":\"object\",\"properties\":{\"path\":{\"type\":\"string\"},"
    "\"old\":{\"type\":\"string\"},\"new\":{\"type\":\"string\"}},"
    "\"required\":[\"path\",\"old\",\"new\"]}", FALSE, handle_patch_source);

  cad_add (server, "cad_eval", "Re-evaluate a part; report ok+parts/error.",
    PATH_SCHEMA, FALSE, handle_eval);

  cad_add (server, "cad_params", "List a part's parameters and ranges.",
    PATH_SCHEMA, TRUE, handle_params);

  cad_add (server, "cad_inspect",
    "Mass properties: volume, area, triangles, watertight, COM, bbox.",
    PATH_SCHEMA, TRUE, handle_inspect);

  cad_add (server, "cad_feature_tree",
    "The part's feature (CSG) tree as indented text.",
    PATH_SCHEMA, TRUE, handle_feature_tree);

  cad_add (server, "cad_section",
    "Section the part by an X/Y/Z plane at OFFSET; report segments + perimeter.",
    "{\"type\":\"object\",\"properties\":{\"path\":{\"type\":\"string\"},"
    "\"axis\":{\"type\":\"string\"},\"offset\":{\"type\":\"number\"}},"
    "\"required\":[\"path\"]}", TRUE, handle_section);

  cad_add (server, "cad_export",
    "Export the part to OUT in FORMAT (stl/stl-ascii/obj/step/iges).",
    "{\"type\":\"object\",\"properties\":{\"path\":{\"type\":\"string\"},"
    "\"out\":{\"type\":\"string\"},\"format\":{\"type\":\"string\"}},"
    "\"required\":[\"path\",\"out\"]}", FALSE, handle_export);

  cad_add (server, "cad_snapshot",
    "Render the part in a workbench viewport and return an inline PNG.",
    PATH_SCHEMA, TRUE, handle_snapshot);

  cad_add (server, "cad_slice",
    "Export the part to STL and slice it to G-code (waits, default 300s).",
    "{\"type\":\"object\",\"properties\":{\"path\":{\"type\":\"string\"},"
    "\"timeout\":{\"type\":\"number\"}},\"required\":[\"path\"]}",
    FALSE, handle_slice);

  cad_add (server, "cad_printers", "List configured printers.",
    NULL, TRUE, handle_printers);

  cad_add (server, "cad_print",
    "Upload GCODE to PRINTER. A print only STARTS when BOTH start and "
    "confirm are true; otherwise it only uploads (the safe default).",
    "{\"type\":\"object\",\"properties\":{\"printer\":{\"type\":\"string\"},"
    "\"gcode\":{\"type\":\"string\"},\"start\":{\"type\":\"boolean\"},"
    "\"confirm\":{\"type\":\"boolean\"}},"
    "\"required\":[\"printer\",\"gcode\"]}", FALSE, handle_print);

  cad_add (server, "cad_assembly_info",
    "Assembly NAME's solved state, DOF, and per-instance transforms.",
    "{\"type\":\"object\",\"properties\":{\"path\":{\"type\":\"string\"},"
    "\"name\":{\"type\":\"string\"}},\"required\":[\"path\",\"name\"]}",
    TRUE, handle_assembly_info);

  cad_add (server, "cad_assembly_bom",
    "Assembly NAME's bill of materials (part, quantity, volume, mass).",
    "{\"type\":\"object\",\"properties\":{\"path\":{\"type\":\"string\"},"
    "\"name\":{\"type\":\"string\"}},\"required\":[\"path\",\"name\"]}",
    TRUE, handle_assembly_bom);

  cad_add (server, "cad_assembly_interference",
    "Interferences (overlapping instance pairs + volume) in assembly NAME.",
    "{\"type\":\"object\",\"properties\":{\"path\":{\"type\":\"string\"},"
    "\"name\":{\"type\":\"string\"}},\"required\":[\"path\",\"name\"]}",
    TRUE, handle_assembly_interference);

  cad_add (server, "cad_assembly_set_joint",
    "Drive JOINT (id) of assembly NAME to VALUE and re-solve (no source "
    "re-eval); report the new instance transforms.",
    "{\"type\":\"object\",\"properties\":{\"path\":{\"type\":\"string\"},"
    "\"name\":{\"type\":\"string\"},\"joint\":{\"type\":\"integer\"},"
    "\"value\":{\"type\":\"number\"}},"
    "\"required\":[\"path\",\"name\",\"joint\",\"value\"]}",
    FALSE, handle_assembly_set_joint);
}

#endif /* HAVE_CMACS_MCP && HAVE_CMACS_CAD */
