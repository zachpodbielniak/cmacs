/* pod-cmacs-module.h — CMacs PodModule for Emacs event/eval integration
 *
 * Copyright (C) 2026 Zach Podbielniak
 * SPDX-License-Identifier: AGPL-3.0-or-later
 *
 * DUAL PodModule: exposes Emacs lifecycle events as PodEventSource
 * and provides eval/message/find-file as PodEventHandler.
 */

#ifndef POD_CMACS_MODULE_H
#define POD_CMACS_MODULE_H

#include <config.h>

#ifdef HAVE_CMACS_PODOMATION

#include <podomation.h>

G_BEGIN_DECLS

#define POD_TYPE_CMACS_MODULE (pod_cmacs_module_get_type ())

G_DECLARE_FINAL_TYPE (PodCmacsModule, pod_cmacs_module,
		      POD, CMACS_MODULE, PodModule)

PodModule *pod_cmacs_module_new (void);

G_END_DECLS

#endif /* HAVE_CMACS_PODOMATION */
#endif /* POD_CMACS_MODULE_H */
