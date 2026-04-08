/*
 * Copyright (C) 2026 Zach Podbielniak
 * SPDX-License-Identifier: AGPL-3.0-or-later
 */

/* cmacs-pod-module.h — CMacs podomation bacon module */

#ifndef CMACS_POD_MODULE_H
#define CMACS_POD_MODULE_H

#ifndef BACON_COMPILATION
#define BACON_COMPILATION
#endif
#include <glib-object.h>
#include <module/bacon-module.h>

G_BEGIN_DECLS

#define CMACS_TYPE_POD_MODULE (cmacs_pod_module_get_type())

G_DECLARE_FINAL_TYPE(CmacsPodModule, cmacs_pod_module, CMACS, POD_MODULE, BaconModule)

G_END_DECLS

#endif /* CMACS_POD_MODULE_H */
