/* pod-gowl-module.h — Gowl PodModule for compositor automation
 *
 * Copyright (C) 2026 Zach Podbielniak
 * SPDX-License-Identifier: AGPL-3.0-or-later
 *
 * DUAL PodModule: exposes gowl compositor events as PodEventSource
 * and provides compositor commands (spawn, focus, layout, etc.)
 * as PodEventHandler, mirroring the 47 gowl DEFUNs.
 */

#ifndef POD_GOWL_MODULE_H
#define POD_GOWL_MODULE_H

#include <config.h>

#if defined (HAVE_CMACS_PODOMATION) && defined (HAVE_CMACS_GOWL)

#include <podomation.h>

G_BEGIN_DECLS

#define POD_TYPE_GOWL_MODULE (pod_gowl_module_get_type ())

G_DECLARE_FINAL_TYPE (PodGowlModule, pod_gowl_module,
		      POD, GOWL_MODULE, PodModule)

PodModule *pod_gowl_module_new (void);

G_END_DECLS

#endif /* HAVE_CMACS_PODOMATION && HAVE_CMACS_GOWL */
#endif /* POD_GOWL_MODULE_H */
