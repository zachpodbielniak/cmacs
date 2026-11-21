/*
 * Copyright (C) 2026 Zach Podbielniak
 * SPDX-License-Identifier: AGPL-3.0-or-later
 */

/* cmacs-tool-registry.h -- the C mirror of the tool registry.
 *
 * The capability table (`cmacs-brigade-deftool', lisp/cmacs/
 * cmacs-brigade-registry.el) is authoritative in Lisp.  This mirror of
 * its metadata is what C reads: the MCP publisher
 * (cmacs/mcp/cmacs-mcp-tools-brigade.c) to list the tools on a session,
 * and the brigade's allowlist gate (cmacs/ai-brigade/
 * cmacs-brigade-allowlist.c) to resolve group names.
 *
 * It lives in cmacs/core because neither of those owns it: the table
 * is published by every build that has an MCP server, with or without
 * the AI subsystems, and the gate needs it in a brigade build with or
 * without MCP.  So it is compiled when EITHER is configured, and
 * nothing else in the tree may assume more than that.
 *
 * The names keep their `cmacs_brigade_' prefix.  They are what the
 * allowlist, the publisher and the Lisp side (`cmacs-brigade--mirror-put')
 * already call, and the registry they mirror is still spelled
 * `cmacs-brigade-' in Lisp; renaming one side would only make the two
 * harder to match up.  */

#ifndef CMACS_TOOL_REGISTRY_H
#define CMACS_TOOL_REGISTRY_H

#include <config.h>

#if defined HAVE_CMACS_MCP || defined HAVE_CMACS_AI_BRIGADE

#include <glib.h>

enum cmacs_brigade_confirm
{
  CMACS_BRIGADE_CONFIRM_NONE = 0,
  CMACS_BRIGADE_CONFIRM_ASK,
  CMACS_BRIGADE_CONFIRM_ALWAYS
};

typedef struct
{
  gchar    *name;         /* wire name, e.g. "call_for_me" */
  gchar    *description;
  gchar    *params_json;  /* JSON array of parameter objects: name,
                             type, description, required, and for an
                             array or object parameter "schema", its
                             complete JSON Schema */
  gchar    *group;        /* nullable; allowlist vocabulary */
  gboolean  destructive;
  enum cmacs_brigade_confirm confirm;
  gboolean  async;
  gint      timeout_ms;   /* 0 = use the default */
  gboolean  no_mcp;       /* :surfaces excludes `mcp': mirrored for the
                             allowlist gate, never published to MCP */
} CmacsBrigadeTool;

typedef void (*CmacsBrigadeToolFunc) (const CmacsBrigadeTool *tool,
                                      gpointer user_data);

extern void  cmacs_brigade_registry_init    (void);
extern void  cmacs_brigade_registry_foreach (CmacsBrigadeToolFunc fn,
                                             gpointer user_data);
/* Returns a copy; free with cmacs_brigade_tool_destroy. */
extern CmacsBrigadeTool *cmacs_brigade_registry_lookup (const gchar *name);
extern void  cmacs_brigade_tool_destroy     (CmacsBrigadeTool *tool);
extern guint cmacs_brigade_registry_size    (void);
/* A counter that changes whenever a tool is mirrored or removed: lets a
 * reader that published the registry somewhere tell whether it has to
 * do so again.  */
extern guint cmacs_brigade_registry_generation (void);

/* Defines `cmacs-brigade--mirror-put', `-remove' and `-names'.
 *
 * Declared here, and only here (a second declaration anywhere is
 * -Wredundant-decls in every unit that sees both).  Safe to call more
 * than once: the MCP server and the brigade each call it from their own
 * syms_of_, because either may be the only one configured, and the
 * second call does nothing.  */
extern void syms_of_cmacs_tool_registry (void);

#endif /* HAVE_CMACS_MCP || HAVE_CMACS_AI_BRIGADE */
#endif /* CMACS_TOOL_REGISTRY_H */
