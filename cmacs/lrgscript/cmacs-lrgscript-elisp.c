/* cmacs-lrgscript-elisp.c --- the LrgScripting Emacs Lisp backend.
 *
 * Copyright (C) 2026 Zach Podbielniak
 * SPDX-License-Identifier: AGPL-3.0-or-later
 *
 * CmacsLrgScriptingElisp is an LrgScripting subclass whose vtable routes into
 * the live Emacs Lisp VM.  It is the *only* translation unit in this subsystem
 * that includes <libregnum.h>, and it never includes lisp.h: all Lisp work is
 * delegated to the bridge (cmacs-lrgscript-bridge.c) through GValue + plain-C
 * calls, and no Lisp_Object is ever named here.  See cmacs-lrgscript.h for the
 * firewall rationale.
 *
 * The backend is registered with libregnum's process-wide LrgScriptingManager
 * at startup (init_cmacs_lrgscript -> cmacs_lrgscript_register_backend), so
 * #LrgScriptComponent / #LrgScriptBinding and the editor "attach a script"
 * flow transparently support language "elisp". */

#include <config.h>

#ifdef HAVE_CMACS_LRGSCRIPT

#include <libregnum.h>
#include <glib.h>
#include <glib-object.h>

#include "cmacs-lrgscript-object.h"
#include "cmacs-lrgscript-bridge.h"

/* ── Host-function registry ───────────────────────────────────────────
 *
 * register_function exposes a C callback to scripts under a name.  Because
 * elisp has a single global obarray, host functions are tracked in one
 * process-global table keyed by name; the elisp trampoline
 * (cmacs-lrgscript--invoke-host) resolves the callback here.  Each backend
 * instance remembers the names it bound so reset()/finalize() can unbind. */

typedef struct
{
  LrgScriptingCFunction  cfunc;
  gpointer               user_data;
  LrgScripting          *self;   /* not reffed; owns the registration */
} HostFn;

static GHashTable *host_fns;   /* gchar* name -> HostFn* */

static void
ensure_host_table (void)
{
  if (host_fns == NULL)
    host_fns = g_hash_table_new_full (g_str_hash, g_str_equal, g_free, g_free);
}

/* ── Type ─────────────────────────────────────────────────────────── */

#define CMACS_TYPE_LRGSCRIPTING_ELISP (cmacs_lrgscripting_elisp_get_type ())
G_DECLARE_FINAL_TYPE (CmacsLrgScriptingElisp, cmacs_lrgscripting_elisp,
                      CMACS, LRGSCRIPTING_ELISP, LrgScripting)

struct _CmacsLrgScriptingElisp
{
  LrgScripting  parent_instance;
  GPtrArray    *host_names;   /* gchar*, names this instance bound */
};

G_DEFINE_FINAL_TYPE (CmacsLrgScriptingElisp, cmacs_lrgscripting_elisp,
                     LRG_TYPE_SCRIPTING)

/* ── Error helper: bridge (char*) -> GError ───────────────────────── */

static gboolean
fail (GError **error, gint code, gchar *msg)
{
  g_set_error (error, LRG_SCRIPTING_ERROR, code, "%s",
               msg ? msg : "elisp scripting error");
  g_free (msg);
  return FALSE;
}

/* ── Vtable implementations ───────────────────────────────────────── */

static gboolean
elisp_load_file (LrgScripting *scripting, const gchar *path, GError **error)
{
  gchar *msg = NULL;
  (void) scripting;
  if (cmacs_lrgscript_bridge_load_file (path, &msg))
    return TRUE;
  return fail (error, LRG_SCRIPTING_ERROR_LOAD, msg);
}

static gboolean
elisp_load_string (LrgScripting *scripting, const gchar *name,
                   const gchar *code, GError **error)
{
  gchar *msg = NULL;
  (void) scripting;
  if (cmacs_lrgscript_bridge_load_string (name, code, &msg))
    return TRUE;
  return fail (error, LRG_SCRIPTING_ERROR_RUNTIME, msg);
}

static gboolean
elisp_call_function (LrgScripting *scripting, const gchar *func_name,
                     GValue *return_value, guint n_args, const GValue *args,
                     GError **error)
{
  gchar *msg = NULL;
  const gchar *use;
  gchar *hyphen = NULL;
  gboolean ok;

  (void) scripting;

  /* Hook-name translation: LrgScriptComponent calls the underscore names
   * (lrg_script_start/_update/_detach).  If no such elisp function is bound
   * but the idiomatic hyphenated form is, use that instead. */
  use = func_name;
  if (func_name != NULL && !cmacs_lrgscript_bridge_fboundp (func_name))
    {
      hyphen = g_strdup (func_name);
      g_strdelimit (hyphen, "_", '-');
      if (cmacs_lrgscript_bridge_fboundp (hyphen))
        use = hyphen;
    }

  ok = cmacs_lrgscript_bridge_call (use, n_args, args, return_value, &msg);
  g_free (hyphen);
  if (ok)
    return TRUE;
  return fail (error, LRG_SCRIPTING_ERROR_RUNTIME, msg);
}

static gboolean
elisp_register_function (LrgScripting *scripting, const gchar *name,
                         LrgScriptingCFunction func, gpointer user_data,
                         GError **error)
{
  CmacsLrgScriptingElisp *self = CMACS_LRGSCRIPTING_ELISP (scripting);
  HostFn *hf;
  gchar *msg = NULL;

  if (name == NULL || func == NULL)
    return fail (error, LRG_SCRIPTING_ERROR_FAILED,
                 g_strdup ("register_function: null name or callback"));

  ensure_host_table ();

  hf = g_new0 (HostFn, 1);
  hf->cfunc = func;
  hf->user_data = user_data;
  hf->self = scripting;
  g_hash_table_replace (host_fns, g_strdup (name), hf);
  g_ptr_array_add (self->host_names, g_strdup (name));

  if (!cmacs_lrgscript_bridge_bind_host_fn (name, &msg))
    return fail (error, LRG_SCRIPTING_ERROR_FAILED, msg);
  return TRUE;
}

static gboolean
elisp_get_global (LrgScripting *scripting, const gchar *name,
                  GValue *value, GError **error)
{
  gchar *msg = NULL;
  (void) scripting;
  if (cmacs_lrgscript_bridge_get_global (name, value, &msg))
    return TRUE;
  return fail (error, LRG_SCRIPTING_ERROR_NOT_FOUND, msg);
}

static gboolean
elisp_set_global (LrgScripting *scripting, const gchar *name,
                  const GValue *value, GError **error)
{
  gchar *msg = NULL;
  (void) scripting;
  if (cmacs_lrgscript_bridge_set_global (name, value, &msg))
    return TRUE;
  return fail (error, LRG_SCRIPTING_ERROR_FAILED, msg);
}

static void
elisp_reset (LrgScripting *scripting)
{
  CmacsLrgScriptingElisp *self = CMACS_LRGSCRIPTING_ELISP (scripting);
  guint i;

  for (i = 0; i < self->host_names->len; i++)
    {
      const gchar *nm = g_ptr_array_index (self->host_names, i);
      cmacs_lrgscript_bridge_unbind_host_fn (nm);
      if (host_fns != NULL)
        g_hash_table_remove (host_fns, nm);
    }
  g_ptr_array_set_size (self->host_names, 0);
}

/* ── GObject ──────────────────────────────────────────────────────── */

static void
cmacs_lrgscripting_elisp_finalize (GObject *object)
{
  CmacsLrgScriptingElisp *self = CMACS_LRGSCRIPTING_ELISP (object);

  elisp_reset (LRG_SCRIPTING (object));
  g_clear_pointer (&self->host_names, g_ptr_array_unref);

  G_OBJECT_CLASS (cmacs_lrgscripting_elisp_parent_class)->finalize (object);
}

static void
cmacs_lrgscripting_elisp_class_init (CmacsLrgScriptingElispClass *klass)
{
  GObjectClass      *object_class = G_OBJECT_CLASS (klass);
  LrgScriptingClass *sc = LRG_SCRIPTING_CLASS (klass);

  object_class->finalize = cmacs_lrgscripting_elisp_finalize;

  sc->load_file = elisp_load_file;
  sc->load_string = elisp_load_string;
  sc->call_function = elisp_call_function;
  sc->register_function = elisp_register_function;
  sc->get_global = elisp_get_global;
  sc->set_global = elisp_set_global;
  sc->reset = elisp_reset;
}

static void
cmacs_lrgscripting_elisp_init (CmacsLrgScriptingElisp *self)
{
  self->host_names = g_ptr_array_new_with_free_func (g_free);
}

/* ── Factory + registration (public, libregnum side) ──────────────── */

static LrgScripting *
cmacs_lrgscript_elisp_factory (gpointer user_data)
{
  (void) user_data;
  return LRG_SCRIPTING (g_object_new (CMACS_TYPE_LRGSCRIPTING_ELISP, NULL));
}

void
cmacs_lrgscript_register_backend (void)
{
  LrgScriptingManager *m = lrg_scripting_manager_get_default ();

  lrg_scripting_manager_register_backend (m, LRG_SCRIPT_LANGUAGE_ELISP,
                                          "Emacs Lisp", "el",
                                          cmacs_lrgscript_elisp_factory,
                                          NULL, NULL);
}

gboolean
cmacs_lrgscript_available_p (void)
{
  LrgScriptingManager *m = lrg_scripting_manager_get_default ();
  return lrg_scripting_manager_is_available (m, LRG_SCRIPT_LANGUAGE_ELISP);
}

gpointer
cmacs_lrgscript_shared_context (void)
{
  static LrgScripting *shared;   /* process-lifetime; never unreffed */

  if (shared == NULL)
    shared = LRG_SCRIPTING (g_object_new (CMACS_TYPE_LRGSCRIPTING_ELISP, NULL));
  return shared;
}

/* ── Context accessors used by the DEFUN layer ────────────────────── */

static gboolean
gerror_to_msg (GError *gerr, gboolean ok, gchar **err)
{
  if (ok)
    {
      g_clear_error (&gerr);
      return TRUE;
    }
  if (err != NULL)
    *err = g_strdup (gerr && gerr->message ? gerr->message
                                           : "elisp scripting error");
  g_clear_error (&gerr);
  return FALSE;
}

gboolean
cmacs_lrgscript_ctx_load_string (gpointer ctx, const gchar *name,
                                 const gchar *code, gchar **err)
{
  GError *gerr = NULL;
  gboolean ok;

  g_return_val_if_fail (LRG_IS_SCRIPTING (ctx), FALSE);
  ok = lrg_scripting_load_string (LRG_SCRIPTING (ctx), name, code, &gerr);
  return gerror_to_msg (gerr, ok, err);
}

gboolean
cmacs_lrgscript_ctx_call (gpointer ctx, const gchar *name, guint n_args,
                          const GValue *args, GValue *ret, gchar **err)
{
  GError *gerr = NULL;
  gboolean ok;

  g_return_val_if_fail (LRG_IS_SCRIPTING (ctx), FALSE);
  ok = lrg_scripting_call_function (LRG_SCRIPTING (ctx), name, ret,
                                    n_args, args, &gerr);
  return gerror_to_msg (gerr, ok, err);
}

gboolean
cmacs_lrgscript_ctx_get_global (gpointer ctx, const gchar *name,
                                GValue *out, gchar **err)
{
  GError *gerr = NULL;
  gboolean ok;

  g_return_val_if_fail (LRG_IS_SCRIPTING (ctx), FALSE);
  ok = lrg_scripting_get_global (LRG_SCRIPTING (ctx), name, out, &gerr);
  return gerror_to_msg (gerr, ok, err);
}

gboolean
cmacs_lrgscript_ctx_set_global (gpointer ctx, const gchar *name,
                                const GValue *val, gchar **err)
{
  GError *gerr = NULL;
  gboolean ok;

  g_return_val_if_fail (LRG_IS_SCRIPTING (ctx), FALSE);
  ok = lrg_scripting_set_global (LRG_SCRIPTING (ctx), name, val, &gerr);
  return gerror_to_msg (gerr, ok, err);
}

gboolean
cmacs_lrgscript_invoke_host_fn (const gchar *name, guint n_args,
                                const GValue *args, GValue *ret, gchar **err)
{
  HostFn *hf;
  GError *gerr = NULL;

  if (host_fns == NULL || name == NULL
      || (hf = g_hash_table_lookup (host_fns, name)) == NULL)
    {
      if (err != NULL)
        *err = g_strdup_printf ("no host function: %s", name ? name : "(null)");
      return FALSE;
    }

  if (!hf->cfunc (hf->self, n_args, args, ret, hf->user_data, &gerr))
    {
      if (err != NULL)
        *err = g_strdup (gerr && gerr->message ? gerr->message
                                               : "host function failed");
      g_clear_error (&gerr);
      return FALSE;
    }
  return TRUE;
}

#endif /* HAVE_CMACS_LRGSCRIPT */
