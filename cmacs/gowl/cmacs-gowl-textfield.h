/* cmacs-gowl-textfield.h --- another application's text field, as text
 *
 * Copyright (C) 2026 Zach Podbielniak
 * SPDX-License-Identifier: AGPL-3.0-or-later
 *
 * The primitives under `cmacs-gowl-edit-field'
 * (lisp/cmacs/cmacs-gowl-edit-field.el): read the text of the field
 * that has focus in any Wayland window, and put text back, through the
 * text-input-v3 state gowl already relays.  gowl answers on its
 * dispatch thread, where Lisp must never run, so every answer is
 * copied into C strings and delivered to its Lisp callback on Emacs's
 * thread; the callbacks wait in a staticpro'd table keyed by an
 * integer, never in the memory handed to gowl.  */

#ifndef CMACS_GOWL_TEXTFIELD_H
#define CMACS_GOWL_TEXTFIELD_H

#include <config.h>

#ifdef HAVE_CMACS_GOWL

/* Drop every callback still waiting for an answer.  For
   cmacs_gowl_forget_compositor_state: a compositor that is being
   stopped drops its waiting reads and edits without calling back, so
   their callbacks would otherwise stay rooted for good.  An answer
   already on its way to the main thread finds its callback gone and
   is discarded.  Main thread only; touches no compositor state.  */
extern void cmacs_gowl_textfield_forget (void);

extern void syms_of_cmacs_gowl_textfield (void);

#endif /* HAVE_CMACS_GOWL */
#endif /* CMACS_GOWL_TEXTFIELD_H */
