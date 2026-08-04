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

/* ── Tool registry mirror ─────────────────────────────────────────
 *
 * The authoritative registry is Elisp; this is the C mirror used for
 * MCP publication and the allowlist gate.  See cmacs-brigade-registry.c
 * for why it exists at all.  */

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
  gchar    *params_json;  /* JSON array of parameter objects */
  gchar    *group;        /* nullable; allowlist vocabulary */
  gboolean  destructive;
  enum cmacs_brigade_confirm confirm;
  gboolean  async;
  gint      timeout_ms;   /* 0 = use the default */
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

/* ── Allowlist gate ───────────────────────────────────────────────
 *
 * Decides whether an agent holding ALLOWLIST may call TOOL_NAME.
 * ALLOWLIST is a comma-separated list of tool names and/or group names,
 * or NULL/"" meaning "nothing".  The literal "*" means every
 * non-privileged tool; it never unlocks the privileged set.
 *
 * Deliberately not Lisp: an agent that reaches `eval' could otherwise
 * rewrite the function that decides what it is allowed to do.  */
extern gboolean cmacs_brigade_tool_allowed (const gchar *allowlist,
                                            const gchar *tool_name);

/* True when TOOL_NAME is in the privileged set that is denied unless an
 * allowlist names it explicitly (never via "*" or a group).  */
extern gboolean cmacs_brigade_tool_privileged (const gchar *tool_name);

/* Resolve group names in ALLOWLIST to concrete tool names, for handing
 * to a relay process that has no registry of its own.  Caller frees. */
extern gchar *cmacs_brigade_allowlist_expand (const gchar *allowlist);

/* ── Plan task state ──────────────────────────────────────────────
 *
 * C owns runtime, org owns intent.  The TODO keyword is a projection of
 * the state on the way out and a transition request on the way in; it
 * is never a stored value.  See cmacs-brigade-state.c. */

typedef enum
{
  CMACS_BRIGADE_STATE_DRAFT = 0,
  CMACS_BRIGADE_STATE_QUEUED,
  CMACS_BRIGADE_STATE_STARTING,
  CMACS_BRIGADE_STATE_RUNNING,
  CMACS_BRIGADE_STATE_WAITING_INPUT,
  CMACS_BRIGADE_STATE_BLOCKED,
  CMACS_BRIGADE_STATE_DONE,
  CMACS_BRIGADE_STATE_FAILED,
  CMACS_BRIGADE_STATE_CANCELLED,
  CMACS_BRIGADE_STATE_OVER_BUDGET,
  CMACS_BRIGADE_STATE_INTERRUPTED,
  CMACS_BRIGADE_STATE_COUNT
} CmacsBrigadeState;

extern void         cmacs_brigade_state_init      (void);
extern const gchar *cmacs_brigade_state_name      (CmacsBrigadeState s);
extern CmacsBrigadeState cmacs_brigade_state_from_name (const gchar *name);
extern gboolean     cmacs_brigade_state_terminal  (CmacsBrigadeState s);
extern gboolean     cmacs_brigade_state_live      (CmacsBrigadeState s);
extern gboolean     cmacs_brigade_state_can_transition (CmacsBrigadeState from,
                                                        CmacsBrigadeState to);

/* ── Memory: chunking ─────────────────────────────────────────────
 *
 * A chunk is what gets embedded.  HEADING is the synthetic breadcrumb
 * ("file > Section > Subsection") prepended before embedding: without it
 * a chunk reading "yes, Tuesday works" has no content words and is
 * unretrievable.  BYTE_START/BYTE_LEN locate it in the source document
 * so a hit can be widened to its neighbours on demand. */
typedef struct
{
  gchar *text;
  gchar *heading;
  gsize  byte_start;
  gsize  byte_len;
} CmacsBrigadeChunk;

/* Returns a GPtrArray of CmacsBrigadeChunk* with a free func set.
 * TARGET and OVERLAP of 0 select the defaults. */
extern GPtrArray *cmacs_brigade_chunk_text (const gchar *text,
                                            const gchar *path,
                                            gsize target, gsize overlap);
extern void cmacs_brigade_chunk_free (CmacsBrigadeChunk *chunk);

/* ── Memory: the flat fp16 index ──────────────────────────────────
 *
 * Brute-force cosine over an mmap'd array of L2-normalised fp16 rows.
 * See cmacs-brigade-index.c for why there is no ANN structure. */
typedef struct _CmacsBrigadeIndex       CmacsBrigadeIndex;
typedef struct _CmacsBrigadeIndexWriter CmacsBrigadeIndexWriter;

extern CmacsBrigadeIndex *cmacs_brigade_index_open  (const gchar *dir,
                                                     GError **error);
extern void               cmacs_brigade_index_close (CmacsBrigadeIndex *ix);
extern guint64            cmacs_brigade_index_count (CmacsBrigadeIndex *ix);
extern guint32            cmacs_brigade_index_dim   (CmacsBrigadeIndex *ix);

/* Fills OUT_IDS/OUT_SCORES (each at least K long) with the best K rows,
 * best first.  Returns how many were written. */
extern guint cmacs_brigade_index_search (CmacsBrigadeIndex *ix,
                                         const float *query, guint k,
                                         guint32 *out_ids,
                                         float *out_scores);

/* True when the fp16 scan is using F16C rather than the scalar table.
 * Exposed so a test can assert both paths agree. */
extern gboolean cmacs_brigade_index_using_f16c (void);

extern CmacsBrigadeIndexWriter *
cmacs_brigade_index_writer_new (const gchar *dir, guint32 dim, GError **error);
extern gboolean cmacs_brigade_index_writer_add (CmacsBrigadeIndexWriter *w,
                                                const float *vec, guint32 dim);
extern gboolean cmacs_brigade_index_writer_commit (CmacsBrigadeIndexWriter *w,
                                                   GError **error);
extern void     cmacs_brigade_index_writer_free (CmacsBrigadeIndexWriter *w);
extern guint64  cmacs_brigade_index_writer_count (CmacsBrigadeIndexWriter *w);

/* ── `emacs --mcp-relay' ──────────────────────────────────────────
 *
 * Scans ARGV for --mcp-relay and, if present, takes over the process
 * entirely and exits -- it never returns to the caller.  Called from
 * main() before any Emacs initialisation, the same never-return model
 * as --bacon and --cmacs-lsp.
 *
 * Declared here (rather than in a private header) because src/emacs.c
 * is the only caller and cmacs-brigade.h is what it already includes. */
extern void cmacs_brigade_relay_maybe_main (int argc, char **argv);
extern int  cmacs_brigade_relay_main       (int argc, char **argv);

/* The GThread that owns the Lisp VM, captured in init_cmacs_ai_brigade.
 *
 * Worker threads must never touch Lisp directly.  Code that may run off
 * the main thread compares against this and, when it differs, marshals
 * back with g_main_context_invoke (cmacs_glib_get_context (), ...) --
 * the same gate cmacs/ai/cmacs-ai-tools.c uses.  */
extern GThread *cmacs_brigade__main_gthread;

#endif /* HAVE_CMACS_AI_BRIGADE */
#endif /* CMACS_BRIGADE_H */
