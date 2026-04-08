/* cmacs-podomation.h — Podomation automation engine integration
 *
 * Copyright (C) 2026 Zach Podbielniak
 * SPDX-License-Identifier: AGPL-3.0-or-later
 *
 * Embeds podomation (GObject-native event-driven automation) into CMacs
 * so that Emacs becomes a programmable automation platform.
 */

#ifndef CMACS_PODOMATION_H
#define CMACS_PODOMATION_H

#include <config.h>

#ifdef HAVE_CMACS_PODOMATION

extern void syms_of_cmacs_podomation (void);
extern void init_cmacs_podomation (void);

/* Accessor for the shared PodEngine — used by pod-cmacs-module and
   pod-gowl-module which are compiled into temacs. */
struct _PodEngine;
extern struct _PodEngine *cmacs_podomation_get_engine (void);

/* Accessor for the cmacs PodModule singleton — used by the
   cmacs-podomation-emit-event DEFUN. */
struct _PodModule;
extern struct _PodModule *cmacs_podomation_get_cmacs_module (void);

#endif /* HAVE_CMACS_PODOMATION */
#endif /* CMACS_PODOMATION_H */
