/*
 * Copyright (C) 2026 Zach Podbielniak
 * SPDX-License-Identifier: AGPL-3.0-or-later
 */

/* cmacs-gi-module.h — CMacs GI bacon module */

#ifndef CMACS_GI_MODULE_H
#define CMACS_GI_MODULE_H

#ifndef BACON_COMPILATION
#define BACON_COMPILATION
#endif
#include <glib-object.h>
#include <module/bacon-module.h>

G_BEGIN_DECLS

#define CMACS_TYPE_GI_MODULE (cmacs_gi_module_get_type())

G_DECLARE_FINAL_TYPE(CmacsGiModule, cmacs_gi_module, CMACS, GI_MODULE, BaconModule)

G_END_DECLS

#endif /* CMACS_GI_MODULE_H */
