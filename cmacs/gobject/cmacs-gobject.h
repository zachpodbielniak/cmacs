/* cmacs-gobject.h — GObject ↔ elisp type bridge
 *
 * Copyright (C) 2026 Zach Podbielniak
 * SPDX-License-Identifier: AGPL-3.0-or-later
 *
 * Maps GObject's ref-counted type system to elisp via Lisp_User_Ptr.
 * Creating an elisp reference calls g_object_ref().
 * Emacs GC finalizer calls g_object_unref().
 */

#ifndef CMACS_GOBJECT_H
#define CMACS_GOBJECT_H

#include <config.h>

#ifdef HAVE_CMACS_GLIB

#include <glib-object.h>
#include "lisp.h"

/* Wrap a GObject as an elisp user-ptr.
 * Takes a reference (calls g_object_ref). */
extern Lisp_Object cmacs_gobject_wrap (GObject *obj);

/* Extract the GObject from an elisp user-ptr.
 * Returns NULL if the object is not a wrapped GObject. */
extern GObject *cmacs_gobject_unwrap (Lisp_Object obj);

/* Check if an elisp value is a wrapped GObject. */
extern bool cmacs_gobject_p (Lisp_Object obj);

#endif /* HAVE_CMACS_GLIB */
#endif /* CMACS_GOBJECT_H */
