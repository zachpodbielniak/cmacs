/*
 * Copyright (C) 2026 Zach Podbielniak
 * SPDX-License-Identifier: AGPL-3.0-or-later
 */

/* ctl-config.h --- kubeconfig-style contexts file.
 *
 * ~/.config/cmacs/emacsctl.yaml (override with --config or
 * $EMACSCTL_CONFIG).  Schema (extensible: unknown keys are ignored,
 * never errors):
 *
 *   apiVersion: cmacs.org/v1
 *   kind: EmacsctlConfig
 *   current-context: local
 *   contexts:
 *     - name: local
 *       instance: primary      # primary | auto | <pid>
 *       output: table          # table | json | yaml | raw
 *       host: user@machine     # optional: ssh-tunnelled remote
 *       timeout: 30            # optional, seconds
 *   aliases:
 *     b: get buffers
 *   settings:
 *     timeout: 30
 */

#ifndef CTL_CONFIG_H
#define CTL_CONFIG_H

#include "ctl.h"

G_BEGIN_DECLS

/* ── CtlContext (boxed) ────────────────────────────────────────────── */

typedef struct _CtlContext CtlContext;

struct _CtlContext
{
  gchar *name;
  gchar *instance;            /* "primary" | "auto" | "<pid>" */
  gchar *host;                /* NULL for local */
  gchar *output;              /* NULL = unset */
  gint timeout;               /* 0 = unset */
};

#define CTL_TYPE_CONTEXT (ctl_context_get_type ())
GType       ctl_context_get_type (void) G_GNUC_CONST;
CtlContext *ctl_context_new      (const gchar *name);
CtlContext *ctl_context_copy     (const CtlContext *self);
void        ctl_context_free     (CtlContext *self);

/* ── CtlConfig ─────────────────────────────────────────────────────── */

#define CTL_TYPE_CONFIG (ctl_config_get_type ())
G_DECLARE_FINAL_TYPE (CtlConfig, ctl_config, CTL, CONFIG, GObject)

/* Default config path (caller g_frees). */
gchar *ctl_config_default_path (void);

/* Load PATH (NULL: default path).  A missing file yields an empty
 * config, not an error. */
CtlConfig *ctl_config_load (const gchar *path, GError **error);

const gchar *ctl_config_get_path            (CtlConfig *self);
const gchar *ctl_config_get_current_context (CtlConfig *self);

/* NULL when NAME is unknown.  Caller frees. */
CtlContext *ctl_config_get_context (CtlConfig *self, const gchar *name);
/* NAME or current-context or built-in defaults.  Never NULL. */
CtlContext *ctl_config_resolve_context (CtlConfig *self,
                                        const gchar *name,
                                        GError **error);
/* NULL-terminated context names.  Caller g_strfreevs. */
gchar **ctl_config_list_contexts (CtlConfig *self);

/* Alias for WORD, or NULL.  Caller g_frees. */
gchar *ctl_config_expand_alias (CtlConfig *self, const gchar *word);

/* Default settings.timeout, or 0. */
gint ctl_config_get_timeout (CtlConfig *self);

/* `config init': write the commented boilerplate to PATH (NULL:
 * default path), creating parent dirs.  Refuses to overwrite. */
gboolean ctl_config_init_boilerplate (const gchar *path, GError **error);

/* `config use-context': textual rewrite of the current-context line,
 * preserving comments. */
gboolean ctl_config_use_context (CtlConfig *self, const gchar *name,
                                 GError **error);

G_END_DECLS

#endif /* CTL_CONFIG_H */
