/* cmacs-piper-defuns.c --- All cmacs-piper DEFUNs.
 *
 * Copyright (C) 2026 Zach Podbielniak
 * SPDX-License-Identifier: AGPL-3.0-or-later
 */

#include <config.h>

#ifdef HAVE_CMACS_PIPER

#include "lisp.h"
#include "coding.h"
#include "cmacs-piper.h"

#include <glib.h>

extern gboolean cmacs_piper_supported_p (void);
extern gchar   *cmacs_piper_synth_sync   (const char *binary, const char *model,
                                          const char *text, gsize *out_bytes,
                                          GError **err);
extern void     cmacs_piper_synth_async  (const char *binary, const char *model,
                                          const char *text, Lisp_Object callback);

DEFUN ("cmacs-piper-supported-p", Fcmacs_piper_supported_p,
       Scmacs_piper_supported_p, 0, 0, 0,
       doc: /* Return t if a piper executable can be located on PATH.  */)
  (void)
{
  return cmacs_piper_supported_p () ? Qt : Qnil;
}

DEFUN ("cmacs-piper--synth-sync-1", Fcmacs_piper__synth_sync_1,
       Scmacs_piper__synth_sync_1, 2, 3, 0,
       doc: /* Synthesise TEXT using MODEL-PATH; return PCM (unibyte
S16LE bytes) or signal `cmacs-piper-error'.  Optional BINARY overrides
the configured piper executable path.  */)
  (Lisp_Object model_path, Lisp_Object text, Lisp_Object binary)
{
  CHECK_STRING (model_path);
  CHECK_STRING (text);
  const char *bin = NILP (binary) ? NULL
                  : (CHECK_STRING (binary), SSDATA (binary));
  Lisp_Object mp = ENCODE_FILE (model_path);
  Lisp_Object tx = ENCODE_UTF_8 (text);
  GError *err = NULL;
  gsize sz = 0;
  gchar *pcm = cmacs_piper_synth_sync (bin, SSDATA (mp), SSDATA (tx), &sz, &err);
  if (!pcm)
    {
      Lisp_Object msg = err ? build_string (err->message)
                            : build_string ("cmacs-piper: synth failed");
      if (err) g_error_free (err);
      xsignal1 (Qcmacs_piper_error, msg);
    }
  Lisp_Object out = make_unibyte_string ((const char *) pcm, sz);
  g_free (pcm);
  return out;
}

DEFUN ("cmacs-piper--synth-async-1", Fcmacs_piper__synth_async_1,
       Scmacs_piper__synth_async_1, 3, 4, 0,
       doc: /* Asynchronously synthesise TEXT using MODEL-PATH and call
CALLBACK with the PCM unibyte string (or an alist `((:error . MSG))').  */)
  (Lisp_Object model_path, Lisp_Object text, Lisp_Object callback,
   Lisp_Object binary)
{
  CHECK_STRING (model_path);
  CHECK_STRING (text);
  const char *bin = NILP (binary) ? NULL
                  : (CHECK_STRING (binary), SSDATA (binary));
  Lisp_Object mp = ENCODE_FILE (model_path);
  Lisp_Object tx = ENCODE_UTF_8 (text);
  cmacs_piper_synth_async (bin, SSDATA (mp), SSDATA (tx), callback);
  return Qt;
}

void syms_of_cmacs_piper_defuns (void);
void
syms_of_cmacs_piper_defuns (void)
{
  DEFSYM (Qcmacs_piper_error, "cmacs-piper-error");
  Fput (Qcmacs_piper_error, Qerror_conditions,
        list2 (Qcmacs_piper_error, Qerror));
  Fput (Qcmacs_piper_error, Qerror_message,
        build_string ("CMacs piper error"));

  defsubr (&Scmacs_piper_supported_p);
  defsubr (&Scmacs_piper__synth_sync_1);
  defsubr (&Scmacs_piper__synth_async_1);
}

#endif /* HAVE_CMACS_PIPER */
