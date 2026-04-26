/* org-ex.h — org-ex umbrella header
 *
 * Copyright (C) 2026 Zach Podbielniak
 * SPDX-License-Identifier: AGPL-3.0-or-later
 *
 * Include this header to access all org-ex types.
 */

#ifndef ORG_EX_H
#define ORG_EX_H

#define ORG_EX_INSIDE

#include "org-ex-types.h"

/* Interfaces */
#include "interfaces/org-ex-renderable.h"
#include "interfaces/org-ex-exportable.h"

/* Core types */
#include "core/org-ex-widget.h"
#include "core/org-ex-widget-gtk.h"
#include "core/org-ex-widget-web.h"
#include "core/org-ex-widget-buffer.h"
#include "core/org-ex-widget-code.h"
#include "core/org-ex-ink-stroke.h"
#include "core/org-ex-ink-render.h"
#include "core/org-ex-document.h"
#include "core/org-ex-binding.h"
#include "core/org-ex-channel.h"

/* Boxed types */
#include "boxed/org-ex-widget-state.h"

#undef ORG_EX_INSIDE

#endif /* ORG_EX_H */
