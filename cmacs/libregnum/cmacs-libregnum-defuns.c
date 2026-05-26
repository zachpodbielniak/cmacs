/* cmacs-libregnum-defuns.c --- Elisp entry points.
 *
 * Copyright (C) 2026 Zach Podbielniak
 * SPDX-License-Identifier: AGPL-3.0-or-later */

#include <config.h>

#ifdef HAVE_CMACS_LIBREGNUM

#include "lisp.h"
#include "buffer.h"
#include "cmacs-libregnum.h"

DEFUN ("cmacs-libregnum-supported-p", Fcmacs_libregnum_supported_p,
       Scmacs_libregnum_supported_p, 0, 0, 0,
       doc: /* Return t when cmacs-libregnum is built into this cmacs.  */)
  (void)
{
  return Qt;
}

DEFUN ("cmacs-libregnum-attach", Fcmacs_libregnum_attach,
       Scmacs_libregnum_attach, 1, 3, 0,
       doc: /* Attach a libregnum view to BUFFER.
WIDTH and HEIGHT default to 800x500.  Returns t on success or signals
`cmacs-libregnum-error' on failure (e.g. GL context unavailable).
Idempotent: re-attaching the same buffer is a no-op.  */)
  (Lisp_Object buffer, Lisp_Object width, Lisp_Object height)
{
  CHECK_BUFFER (buffer);
  int w = NILP (width)  ? 800 : (CHECK_FIXNAT (width),  XFIXNUM (width));
  int h = NILP (height) ? 500 : (CHECK_FIXNAT (height), XFIXNUM (height));
  if (cmacs_libregnum_view_for_buffer (buffer))
    return Qt;
  cmacs_libregnum_view_new (buffer, w, h);
  return Qt;
}

DEFUN ("cmacs-libregnum-detach", Fcmacs_libregnum_detach,
       Scmacs_libregnum_detach, 1, 1, 0,
       doc: /* Detach and destroy the libregnum view bound to BUFFER.  */)
  (Lisp_Object buffer)
{
  CHECK_BUFFER (buffer);
  CmacsLibregnumView *v = cmacs_libregnum_view_for_buffer (buffer);
  if (v) cmacs_libregnum_view_destroy (v);
  return Qt;
}

DEFUN ("cmacs-libregnum-attached-p", Fcmacs_libregnum_attached_p,
       Scmacs_libregnum_attached_p, 1, 1, 0,
       doc: /* Return t if BUFFER has an attached libregnum view.  */)
  (Lisp_Object buffer)
{
  CHECK_BUFFER (buffer);
  return cmacs_libregnum_view_for_buffer (buffer) ? Qt : Qnil;
}

DEFUN ("cmacs-libregnum-resize", Fcmacs_libregnum_resize,
       Scmacs_libregnum_resize, 3, 3, 0,
       doc: /* Resize BUFFER's libregnum view to WIDTH x HEIGHT.  */)
  (Lisp_Object buffer, Lisp_Object width, Lisp_Object height)
{
  CHECK_BUFFER (buffer);
  CHECK_FIXNAT (width);
  CHECK_FIXNAT (height);
  CmacsLibregnumView *v = cmacs_libregnum_view_for_buffer (buffer);
  if (!v) error ("cmacs-libregnum: no view attached to buffer");
  cmacs_libregnum_view_resize (v, XFIXNUM (width), XFIXNUM (height));
  return Qt;
}

DEFUN ("cmacs-libregnum-redraw", Fcmacs_libregnum_redraw,
       Scmacs_libregnum_redraw, 1, 1, 0,
       doc: /* Request a redraw of BUFFER's libregnum view.  */)
  (Lisp_Object buffer)
{
  CHECK_BUFFER (buffer);
  CmacsLibregnumView *v = cmacs_libregnum_view_for_buffer (buffer);
  if (v) cmacs_libregnum_view_request_redraw (v);
  return Qt;
}

extern Lisp_Object *cmacs_libregnum__buffers_root  (void);
extern Lisp_Object *cmacs_libregnum__payloads_root (void);

void syms_of_cmacs_libregnum_defuns (void);
void
syms_of_cmacs_libregnum_defuns (void)
{
  DEFSYM (Qcmacs_libregnum_error, "cmacs-libregnum-error");
  Fput (Qcmacs_libregnum_error, Qerror_conditions,
        list2 (Qcmacs_libregnum_error, Qerror));
  Fput (Qcmacs_libregnum_error, Qerror_message,
        build_string ("CMacs libregnum error"));

  /* The view registry's Lisp hash tables (lazy-instantiated on
   * first use) need their static slots GC-rooted. */
  *cmacs_libregnum__buffers_root  () = Qnil;
  *cmacs_libregnum__payloads_root () = Qnil;
  staticpro (cmacs_libregnum__buffers_root  ());
  staticpro (cmacs_libregnum__payloads_root ());

  defsubr (&Scmacs_libregnum_supported_p);
  defsubr (&Scmacs_libregnum_attach);
  defsubr (&Scmacs_libregnum_detach);
  defsubr (&Scmacs_libregnum_attached_p);
  defsubr (&Scmacs_libregnum_resize);
  defsubr (&Scmacs_libregnum_redraw);
}

#endif /* HAVE_CMACS_LIBREGNUM */
