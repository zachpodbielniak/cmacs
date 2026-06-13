/* cmacs-cad-internal.h --- C surface between cmacs-cad TUs.
 *
 * Copyright (C) 2026 Zach Podbielniak
 * SPDX-License-Identifier: AGPL-3.0-or-later
 *
 * Not installed; both sides include cad-glib (GLib-only, no GL).
 */

#ifndef CMACS_CAD_INTERNAL_H
#define CMACS_CAD_INTERNAL_H

#include <config.h>

#ifdef HAVE_CMACS_CAD

#include <stdint.h>
#include <cad-glib.h>

extern CadDocument *cmacs_cad_doc_open (const char *path, GError **error);
extern gboolean cmacs_cad_doc_close (const char *path);
extern CadDocument *cmacs_cad_doc_peek (const char *path);
extern gboolean cmacs_cad_doc_set_source (const char *path,
                                          const char *source,
                                          GError **error);
extern void cmacs_cad_doc_eval_async (const char *path,
                                      GHashTable *overrides,
                                      uint64_t cookie);
extern guint64 cmacs_cad_doc_generation (const char *path);

/* Error signalling shared with the sketch TU (defined in
 * cmacs-cad-defuns.c).  Both raise the `cmacs-cad-error' condition. */
extern AVOID cmacs_cad_signal (GError *error);
extern AVOID cmacs_cad_error_str (const char *msg);

#endif /* HAVE_CMACS_CAD */
#endif /* CMACS_CAD_INTERNAL_H */
