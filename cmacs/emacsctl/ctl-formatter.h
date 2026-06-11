/*
 * Copyright (C) 2026 Zach Podbielniak
 * SPDX-License-Identifier: AGPL-3.0-or-later
 */

/* ctl-formatter.h --- CtlFormatter, the output rendering interface.
 *
 * A GInterface with one method: render a CtlResult to a FILE stream.
 * Implementations: table (human default), json, yaml, raw
 * (script-stable).  ctl_formatter_for_name is the factory the
 * -o/--output flag goes through. */

#ifndef CTL_FORMATTER_H
#define CTL_FORMATTER_H

#include "ctl.h"
#include "ctl-result.h"

#include <stdio.h>

G_BEGIN_DECLS

#define CTL_TYPE_FORMATTER (ctl_formatter_get_type ())
G_DECLARE_INTERFACE (CtlFormatter, ctl_formatter, CTL, FORMATTER, GObject)

struct _CtlFormatterInterface
{
  GTypeInterface parent_iface;

  gboolean (*emit) (CtlFormatter *self,
                    CtlResult    *result,
                    FILE         *out,
                    GError      **error);
};

gboolean ctl_formatter_emit (CtlFormatter *self, CtlResult *result,
                             FILE *out, GError **error);

/* Factory: NAME is one of table|json|yaml|raw.  NULL on unknown. */
CtlFormatter *ctl_formatter_for_name (const gchar *name);

G_END_DECLS

#endif /* CTL_FORMATTER_H */
