/* cmacs-brigade-registry.c --- C mirror of the brigade tool registry.
 *
 * Copyright (C) 2026 Zach Podbielniak
 * SPDX-License-Identifier: AGPL-3.0-or-later
 *
 * The authoritative tool registry lives in Elisp
 * (lisp/cmacs/cmacs-brigade-registry.el) because a tool is fundamentally
 * a Lisp function plus metadata.  This file keeps a C-side mirror of the
 * metadata, which exists for two reasons Elisp cannot serve:
 *
 *   1. MCP publication.  cmacs's MCP server is C and registers its tool
 *      set when a session opens, so it has to be able to enumerate
 *      brigade tools without calling into Lisp mid-handshake.
 *
 *   2. The allowlist gate.  Deciding whether an agent may call a tool
 *      must not itself be Lisp, or any agent that reaches `eval' can
 *      rewrite the decision.  See cmacs-brigade-allowlist.c.
 *
 * The mirror holds no Lisp_Object: handlers are invoked by name through
 * the eval dispatcher, so nothing here needs GC protection and the
 * registry can be read from a worker thread under its own mutex. */

#include <config.h>

#ifdef HAVE_CMACS_AI_BRIGADE

#include "lisp.h"
#include "cmacs-brigade.h"

#include <glib.h>
#include <string.h>

/* ── Registry ─────────────────────────────────────────────────────── */

static GHashTable *cmacs_brigade__tools;   /* gchar* -> CmacsBrigadeTool* */
static GMutex      cmacs_brigade__tool_mutex;
static gboolean    cmacs_brigade__tools_init_done;

static void
cmacs_brigade_tool_free (gpointer data)
{
  CmacsBrigadeTool *t = data;

  if (t == NULL) return;
  g_free (t->name);
  g_free (t->description);
  g_free (t->params_json);
  g_free (t->group);
  g_free (t);
}

void
cmacs_brigade_registry_init (void)
{
  if (cmacs_brigade__tools_init_done) return;
  cmacs_brigade__tools_init_done = TRUE;
  g_mutex_init (&cmacs_brigade__tool_mutex);
  cmacs_brigade__tools = g_hash_table_new_full (g_str_hash, g_str_equal,
                                                g_free,
                                                cmacs_brigade_tool_free);
}

/* Walk every registered tool under the registry lock.
 *
 * The callback runs with the mutex held, so it must not call back into
 * the registry or into Lisp.  Both callers (MCP publication and the
 * allowlist) only read fields, which is why this is a callback walk
 * rather than a "return the list" API that would need a snapshot. */
void
cmacs_brigade_registry_foreach (CmacsBrigadeToolFunc fn, gpointer user_data)
{
  GHashTableIter iter;
  gpointer key, value;

  cmacs_brigade_registry_init ();
  g_mutex_lock (&cmacs_brigade__tool_mutex);
  g_hash_table_iter_init (&iter, cmacs_brigade__tools);
  while (g_hash_table_iter_next (&iter, &key, &value))
    fn ((const CmacsBrigadeTool *) value, user_data);
  g_mutex_unlock (&cmacs_brigade__tool_mutex);
}

/* Look up one tool.  Returns a newly allocated copy so the caller can
 * use it after the lock is dropped; the registry can be mutated from
 * Lisp at any time, so handing out an interior pointer would be a
 * use-after-free waiting for a `cmacs-brigade-unregister-tool'. */
CmacsBrigadeTool *
cmacs_brigade_registry_lookup (const gchar *name)
{
  CmacsBrigadeTool *found, *copy = NULL;

  if (name == NULL) return NULL;
  cmacs_brigade_registry_init ();
  g_mutex_lock (&cmacs_brigade__tool_mutex);
  found = g_hash_table_lookup (cmacs_brigade__tools, name);
  if (found != NULL)
    {
      copy = g_new0 (CmacsBrigadeTool, 1);
      copy->name        = g_strdup (found->name);
      copy->description = g_strdup (found->description);
      copy->params_json = g_strdup (found->params_json);
      copy->group       = g_strdup (found->group);
      copy->destructive = found->destructive;
      copy->confirm     = found->confirm;
      copy->async       = found->async;
      copy->timeout_ms  = found->timeout_ms;
    }
  g_mutex_unlock (&cmacs_brigade__tool_mutex);
  return copy;
}

void
cmacs_brigade_tool_destroy (CmacsBrigadeTool *tool)
{
  cmacs_brigade_tool_free (tool);
}

guint
cmacs_brigade_registry_size (void)
{
  guint n;

  cmacs_brigade_registry_init ();
  g_mutex_lock (&cmacs_brigade__tool_mutex);
  n = g_hash_table_size (cmacs_brigade__tools);
  g_mutex_unlock (&cmacs_brigade__tool_mutex);
  return n;
}

/* ── DEFUNs ───────────────────────────────────────────────────────── */

static enum cmacs_brigade_confirm
confirm_from_symbol (Lisp_Object sym)
{
  if (EQ (sym, intern ("always"))) return CMACS_BRIGADE_CONFIRM_ALWAYS;
  if (EQ (sym, intern ("ask")))    return CMACS_BRIGADE_CONFIRM_ASK;
  return CMACS_BRIGADE_CONFIRM_NONE;
}

DEFUN ("cmacs-brigade--mirror-put", Fcmacs_brigade__mirror_put,
       Scmacs_brigade__mirror_put, 4, 4, 0,
       doc: /* Mirror one tool's metadata into the C registry.

NAME is the wire name (a string such as "call_for_me").  DESCRIPTION is
the summary shown to a model.  PARAMS-JSON is a JSON array of parameter
objects, each with name/type/description/required members.  PROPS is a
plist accepting :group, :destructive, :confirm and :timeout.

Internal.  Elisp code calls `cmacs-brigade-register-tool', which owns the
authoritative registry and mirrors here for MCP publication and the
allowlist gate.  */)
  (Lisp_Object name, Lisp_Object description, Lisp_Object params_json,
   Lisp_Object props)
{
  CmacsBrigadeTool *tool;
  Lisp_Object group, timeout;

  CHECK_STRING (name);
  CHECK_STRING (description);
  CHECK_STRING (params_json);

  cmacs_brigade_registry_init ();

  tool = g_new0 (CmacsBrigadeTool, 1);
  tool->name        = g_strdup (SSDATA (name));
  tool->description = g_strdup (SSDATA (description));
  tool->params_json = g_strdup (SSDATA (params_json));

  group = Fplist_get (props, intern (":group"), Qnil);
  tool->group = SYMBOLP (group) && !NILP (group)
    ? g_strdup (SSDATA (Fsymbol_name (group)))
    : (STRINGP (group) ? g_strdup (SSDATA (group)) : NULL);

  tool->destructive = !NILP (Fplist_get (props, intern (":destructive"), Qnil));
  tool->confirm     = confirm_from_symbol (Fplist_get (props, intern (":confirm"),
                                                       Qnil));
  tool->async       = !NILP (Fplist_get (props, intern (":async"), Qnil));

  timeout = Fplist_get (props, intern (":timeout"), Qnil);
  tool->timeout_ms = FIXNUMP (timeout) ? (gint) (XFIXNUM (timeout) * 1000) : 0;

  g_mutex_lock (&cmacs_brigade__tool_mutex);
  /* replace: re-registering a name is how a user reloads their config */
  g_hash_table_replace (cmacs_brigade__tools, g_strdup (tool->name), tool);
  g_mutex_unlock (&cmacs_brigade__tool_mutex);

  return Qt;
}

DEFUN ("cmacs-brigade--mirror-remove", Fcmacs_brigade__mirror_remove,
       Scmacs_brigade__mirror_remove, 1, 1, 0,
       doc: /* Drop NAME from the C tool registry.  Internal.  */)
  (Lisp_Object name)
{
  gboolean removed;

  CHECK_STRING (name);
  cmacs_brigade_registry_init ();
  g_mutex_lock (&cmacs_brigade__tool_mutex);
  removed = g_hash_table_remove (cmacs_brigade__tools, SSDATA (name));
  g_mutex_unlock (&cmacs_brigade__tool_mutex);
  return removed ? Qt : Qnil;
}

DEFUN ("cmacs-brigade--mirror-names", Fcmacs_brigade__mirror_names,
       Scmacs_brigade__mirror_names, 0, 0, 0,
       doc: /* Return the wire names currently mirrored into C.

Used by tests to prove the Elisp registry and the C mirror agree; a
disagreement means MCP clients and in-process agents would see different
tool sets.  */)
  (void)
{
  GHashTableIter iter;
  gpointer key, value;
  Lisp_Object out = Qnil;

  cmacs_brigade_registry_init ();
  g_mutex_lock (&cmacs_brigade__tool_mutex);
  g_hash_table_iter_init (&iter, cmacs_brigade__tools);
  while (g_hash_table_iter_next (&iter, &key, &value))
    out = Fcons (build_string ((const gchar *) key), out);
  g_mutex_unlock (&cmacs_brigade__tool_mutex);
  return out;
}

void syms_of_cmacs_ai_brigade_registry (void);
void
syms_of_cmacs_ai_brigade_registry (void)
{
  defsubr (&Scmacs_brigade__mirror_put);
  defsubr (&Scmacs_brigade__mirror_remove);
  defsubr (&Scmacs_brigade__mirror_names);
}

#endif /* HAVE_CMACS_AI_BRIGADE */
