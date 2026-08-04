/*
 * Copyright (C) 2026 Zach Podbielniak
 * SPDX-License-Identifier: AGPL-3.0-or-later
 */

/* cmacs-brigade.h -- CMacs AI brigade fabric.
 *
 * The brigade is the layer every other cmacs subsystem -- and every
 * user's own config -- lays on top of to get AI capability, agent
 * orchestration, and memory.  Its primary deliverable is the extension
 * surface: registering a capability must be one form in init.el (or
 * init.c via crispy), and that one form must light it up on all three
 * delivery paths at once:
 *
 *   1. in-process HTTP agents  -- as an AiTool on the agent's executor
 *   2. CLI agents (claude-code / opencode) -- as an MCP tool reached
 *      through the `emacs --mcp-relay' bridge, scoped by the agent's
 *      capability token
 *   3. external MCP clients    -- on cmacs's existing MCP server
 *
 * Everything the shipped features use goes through the same public
 * registration API a user gets.  There are deliberately no private back
 * doors: if a built-in needs a hook, that hook is public.
 *
 * Layering: brigade sits directly on cmacs-ai (and therefore ai-glib);
 * --with-cmacs-ai-brigade hard-requires --with-cmacs-ai.  libreclaw is
 * optional and only adds extra surfaces when present.  */

#ifndef CMACS_BRIGADE_H
#define CMACS_BRIGADE_H

#include <config.h>

#ifdef HAVE_CMACS_AI_BRIGADE

#include "lisp.h"
#include <glib.h>

/* Per-file DEFUN registration entry points (syms_of_cmacs_ai_brigade_*)
 * are deliberately NOT declared here.  Each unit declares its own just
 * above the definition and cmacs-brigade-init.c declares the ones it
 * calls -- the same arrangement cmacs/ai uses.  Declaring them here as
 * well would put two declarations in every translation unit and trip
 * -Wredundant-decls, which this tree treats as an error.  */

/* The GThread that owns the Lisp VM, captured in init_cmacs_ai_brigade.
 *
 * Worker threads must never touch Lisp directly.  Code that may run off
 * the main thread compares against this and, when it differs, marshals
 * back with g_main_context_invoke (cmacs_glib_get_context (), ...) --
 * the same gate cmacs/ai/cmacs-ai-tools.c uses.  */
extern GThread *cmacs_brigade__main_gthread;

#endif /* HAVE_CMACS_AI_BRIGADE */
#endif /* CMACS_BRIGADE_H */
