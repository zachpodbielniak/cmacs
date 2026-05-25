/* cmacs-whisper-defuns.c --- All cmacs-whisper DEFUNs.
 *
 * Copyright (C) 2026 Zach Podbielniak
 * SPDX-License-Identifier: AGPL-3.0-or-later
 */

#include <config.h>

#ifdef HAVE_CMACS_WHISPER

#include "lisp.h"
#include "coding.h"
#include "cmacs-whisper.h"

#include <glib.h>
#include <whisper.h>
#include <stdint.h>

extern Lisp_Object cmacs_whisper_transcribe_pcm_sync (const char *model_path,
                                                      const char *language,
                                                      const int16_t *pcm,
                                                      size_t n_samples);
extern Lisp_Object cmacs_whisper_transcribe_file_sync (const char *model_path,
                                                       const char *language,
                                                       const char *wav_path,
                                                       GError **err);
extern void cmacs_whisper_transcribe_pcm_async (const char *model_path,
                                                const char *language,
                                                const int16_t *pcm,
                                                size_t n_samples,
                                                Lisp_Object callback);
extern void cmacs_whisper_transcribe_file_async (const char *model_path,
                                                 const char *language,
                                                 const char *wav_path,
                                                 Lisp_Object callback);

DEFUN ("cmacs-whisper-supported-p", Fcmacs_whisper_supported_p,
       Scmacs_whisper_supported_p, 0, 0, 0,
       doc: /* Return non-nil if cmacs-whisper is built into this cmacs.  */)
  (void)
{
  return Qt;
}

DEFUN ("cmacs-whisper-print-system-info",
       Fcmacs_whisper_print_system_info,
       Scmacs_whisper_print_system_info, 0, 0, 0,
       doc: /* Print whisper.cpp build/runtime capability info to *Messages*.  */)
  (void)
{
  const char *info = whisper_print_system_info ();
  if (info && *info)
    message ("%s", info);
  return Qt;
}

DEFUN ("cmacs-whisper-transcribe-file", Fcmacs_whisper_transcribe_file,
       Scmacs_whisper_transcribe_file, 2, 3, 0,
       doc: /* Synchronously transcribe WAV-PATH using MODEL-PATH.
Optional LANGUAGE is a 2-letter ISO code (default "en").  Returns an
alist:
  ((:text   . "...full text...")
   (:segments . (((:start . MS) (:end . MS) (:text . "...")) ...)))
or
  ((:error  . "error message"))  */)
  (Lisp_Object model_path, Lisp_Object wav_path, Lisp_Object language)
{
  CHECK_STRING (model_path);
  CHECK_STRING (wav_path);
  const char *lang = NILP (language) ? NULL
                   : (CHECK_STRING (language), SSDATA (language));
  Lisp_Object mp = ENCODE_FILE (model_path);
  Lisp_Object wp = ENCODE_FILE (wav_path);
  GError *err = NULL;
  Lisp_Object out = cmacs_whisper_transcribe_file_sync (SSDATA (mp), lang,
                                                        SSDATA (wp), &err);
  if (NILP (out))
    {
      out = Fcons (Fcons (intern (":error"),
                          build_string (err ? err->message
                                            : "transcription failed")),
                   Qnil);
      if (err) g_error_free (err);
    }
  return out;
}

DEFUN ("cmacs-whisper-transcribe-pcm", Fcmacs_whisper_transcribe_pcm,
       Scmacs_whisper_transcribe_pcm, 2, 3, 0,
       doc: /* Synchronously transcribe PCM (unibyte S16LE mono 16 kHz) using
MODEL-PATH.  Returns the same alist as `cmacs-whisper-transcribe-file'.  */)
  (Lisp_Object model_path, Lisp_Object pcm, Lisp_Object language)
{
  CHECK_STRING (model_path);
  CHECK_STRING (pcm);
  const char *lang = NILP (language) ? NULL
                   : (CHECK_STRING (language), SSDATA (language));
  Lisp_Object mp = ENCODE_FILE (model_path);
  return cmacs_whisper_transcribe_pcm_sync (SSDATA (mp), lang,
                                            (const int16_t *) SDATA (pcm),
                                            SBYTES (pcm) / sizeof (int16_t));
}

DEFUN ("cmacs-whisper-transcribe-async", Fcmacs_whisper_transcribe_async,
       Scmacs_whisper_transcribe_async, 3, 4, 0,
       doc: /* Asynchronously transcribe WAV-PATH using MODEL-PATH and
call CALLBACK with the result alist.  Optional LANGUAGE = "en" etc.  */)
  (Lisp_Object model_path, Lisp_Object wav_path,
   Lisp_Object callback, Lisp_Object language)
{
  CHECK_STRING (model_path);
  CHECK_STRING (wav_path);
  const char *lang = NILP (language) ? NULL
                   : (CHECK_STRING (language), SSDATA (language));
  Lisp_Object mp = ENCODE_FILE (model_path);
  Lisp_Object wp = ENCODE_FILE (wav_path);
  cmacs_whisper_transcribe_file_async (SSDATA (mp), lang, SSDATA (wp), callback);
  return Qt;
}

DEFUN ("cmacs-whisper-transcribe-pcm-async",
       Fcmacs_whisper_transcribe_pcm_async,
       Scmacs_whisper_transcribe_pcm_async, 3, 4, 0,
       doc: /* Asynchronously transcribe PCM (S16LE mono 16 kHz) using
MODEL-PATH; call CALLBACK with the result alist.  */)
  (Lisp_Object model_path, Lisp_Object pcm,
   Lisp_Object callback, Lisp_Object language)
{
  CHECK_STRING (model_path);
  CHECK_STRING (pcm);
  const char *lang = NILP (language) ? NULL
                   : (CHECK_STRING (language), SSDATA (language));
  Lisp_Object mp = ENCODE_FILE (model_path);
  cmacs_whisper_transcribe_pcm_async (SSDATA (mp), lang,
                                      (const int16_t *) SDATA (pcm),
                                      SBYTES (pcm) / sizeof (int16_t),
                                      callback);
  return Qt;
}

void syms_of_cmacs_whisper_defuns (void);
void
syms_of_cmacs_whisper_defuns (void)
{
  defsubr (&Scmacs_whisper_supported_p);
  defsubr (&Scmacs_whisper_print_system_info);
  defsubr (&Scmacs_whisper_transcribe_file);
  defsubr (&Scmacs_whisper_transcribe_pcm);
  defsubr (&Scmacs_whisper_transcribe_async);
  defsubr (&Scmacs_whisper_transcribe_pcm_async);
}

#endif /* HAVE_CMACS_WHISPER */
