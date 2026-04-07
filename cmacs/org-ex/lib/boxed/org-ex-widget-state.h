/* org-ex-widget-state.h — Serializable widget state (boxed type)
 *
 * Copyright (C) 2026 Zach Podbielniak
 * SPDX-License-Identifier: AGPL-3.0-or-later
 */

#ifndef ORG_EX_WIDGET_STATE_H
#define ORG_EX_WIDGET_STATE_H

#if !defined(ORG_EX_INSIDE) && !defined(ORG_EX_COMPILATION)
#error "Only <org-ex.h> can be included directly."
#endif

#include <glib-object.h>
#include "../org-ex-types.h"

G_BEGIN_DECLS

#define ORG_EX_TYPE_WIDGET_STATE (org_ex_widget_state_get_type ())

GType org_ex_widget_state_get_type (void) G_GNUC_CONST;

/**
 * OrgExWidgetState:
 *
 * A key-value store for persisting ephemeral widget state
 * (scroll position, focus state, etc.) to a sidecar file.
 */
struct _OrgExWidgetState
{
  GHashTable *entries;    /* gchar* -> gchar* (owned) */
};

OrgExWidgetState *org_ex_widget_state_new  (void);
OrgExWidgetState *org_ex_widget_state_copy (const OrgExWidgetState *state);
void              org_ex_widget_state_free (OrgExWidgetState       *state);

void         org_ex_widget_state_set (OrgExWidgetState *state,
                                       const gchar      *key,
                                       const gchar      *value);
const gchar *org_ex_widget_state_get (const OrgExWidgetState *state,
                                       const gchar            *key);

/**
 * org_ex_widget_state_to_json:
 * @state: a #OrgExWidgetState
 *
 * Serialize the state to a JSON string.
 *
 * Returns: (transfer full): JSON string
 */
gchar *org_ex_widget_state_to_json (const OrgExWidgetState *state);

/**
 * org_ex_widget_state_from_json:
 * @json: JSON string to parse
 * @error: return location for a #GError, or %NULL
 *
 * Deserialize state from a JSON string.
 *
 * Returns: (transfer full) (nullable): new state, or %NULL on error
 */
OrgExWidgetState *org_ex_widget_state_from_json (const gchar *json,
                                                   GError     **error);

G_END_DECLS

#endif /* ORG_EX_WIDGET_STATE_H */
