/* cmacs-features.h --- compile-time cmacs feature registry.
 *
 * Copyright (C) 2026 Zach Podbielniak
 * SPDX-License-Identifier: AGPL-3.0-or-later
 *
 * Single source of truth for "which --with-cmacs-<name> subsystems were
 * compiled into this build".  cmacs-features.c is ALWAYS linked (even in
 * an upstream-shaped build with every cmacs feature off), so this array
 * and the `IS-CMACS-<NAME>' Lisp variables are always available.  Other
 * cmacs translation units (e.g. the D-Bus instance interface) include
 * this header instead of maintaining their own #ifdef list. */

#ifndef CMACS_FEATURES_H
#define CMACS_FEATURES_H

/* NULL-terminated list of the compiled-in cmacs subsystem names,
 * lower-case to match the --with-cmacs-<name> configure flag names
 * (e.g. "ai", "gowl", "org-ex").  Reflects compile-time configuration
 * only. */
extern const char *const cmacs_feature_names[];

#endif /* CMACS_FEATURES_H */
