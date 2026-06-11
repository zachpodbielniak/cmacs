/*
 * Copyright (C) 2026 Zach Podbielniak
 * SPDX-License-Identifier: AGPL-3.0-or-later
 */

/* ctl-repl.h --- the interactive REPL and its language abstraction.
 *
 * CtlReplRuntime is an abstract base class; a registry maps language
 * names to runtimes so future languages plug in with one
 * ctl_repl_runtime_register call.  The four built-ins (elisp, crispy,
 * bacon, eshell) share CtlMethodReplRuntime, a concrete subclass
 * driven by a static spec (prompt, D-Bus iface/method, multi-line
 * completion style). */

#ifndef CTL_REPL_H
#define CTL_REPL_H

#include "ctl-invocation.h"

G_BEGIN_DECLS

/* ── Abstract runtime ──────────────────────────────────────────────── */

#define CTL_TYPE_REPL_RUNTIME (ctl_repl_runtime_get_type ())
G_DECLARE_DERIVABLE_TYPE (CtlReplRuntime, ctl_repl_runtime,
                          CTL, REPL_RUNTIME, GObject)

struct _CtlReplRuntimeClass
{
  GObjectClass parent_class;

  const gchar *(*get_language) (CtlReplRuntime *self);
  const gchar *(*get_prompt)   (CtlReplRuntime *self);

  /* Multi-line input: FALSE keeps reading continuation lines. */
  gboolean     (*is_complete)  (CtlReplRuntime *self,
                                const gchar *input);

  /* Evaluate INPUT in the target editor; printable result or NULL
   * with *ERROR. */
  gchar       *(*eval)         (CtlReplRuntime *self,
                                CtlTransport *transport,
                                gint timeout_ms,
                                const gchar *input,
                                GError **error);
};

const gchar *ctl_repl_runtime_get_language (CtlReplRuntime *self);
const gchar *ctl_repl_runtime_get_prompt   (CtlReplRuntime *self);
gboolean     ctl_repl_runtime_is_complete  (CtlReplRuntime *self,
                                            const gchar *input);
gchar       *ctl_repl_runtime_eval         (CtlReplRuntime *self,
                                            CtlTransport *transport,
                                            gint timeout_ms,
                                            const gchar *input,
                                            GError **error);

/* ── Registry ──────────────────────────────────────────────────────── */

typedef CtlReplRuntime *(*CtlReplRuntimeFactory) (void);

void ctl_repl_runtime_register (const gchar *language,
                                CtlReplRuntimeFactory factory);
CtlReplRuntime *ctl_repl_runtime_new_for_lang (const gchar *language,
                                               GError **error);
/* NULL-terminated registered language names.  Caller g_strfreevs. */
gchar **ctl_repl_runtime_list_languages (void);

/* Register elisp/crispy/bacon/eshell. */
void ctl_repl_register_builtin_runtimes (void);

/* ── The interactive loop (`emacsctl repl') ────────────────────────── */

gint ctl_repl_run (CtlInvocation *inv, const gchar *language,
                   GError **error);

G_END_DECLS

#endif /* CTL_REPL_H */
