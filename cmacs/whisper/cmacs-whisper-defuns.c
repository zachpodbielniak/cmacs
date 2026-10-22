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
#include <math.h>

extern Lisp_Object cmacs_whisper_transcribe_pcm_sync (const char *model_path,
                                                      const char *language,
                                                      const int16_t *pcm,
                                                      size_t n_samples,
                                                      int n_threads);
extern Lisp_Object cmacs_whisper_transcribe_file_sync (const char *model_path,
                                                       const char *language,
                                                       const char *wav_path,
                                                       int n_threads,
                                                       GError **err);
extern void cmacs_whisper_transcribe_pcm_async (const char *model_path,
                                                const char *language,
                                                const int16_t *pcm,
                                                size_t n_samples,
                                                int n_threads,
                                                Lisp_Object callback);
extern void cmacs_whisper_transcribe_file_async (const char *model_path,
                                                 const char *language,
                                                 const char *wav_path,
                                                 int n_threads,
                                                 Lisp_Object callback);

/* Decode an optional THREADS arg to a whisper n_threads value.  nil (or a
   non-positive integer) yields 0, which the job layer maps to all cores --
   preserving the historical default for callers that don't pass THREADS.  */
static int
cmacs_whisper__threads (Lisp_Object threads)
{
  if (NILP (threads))
    return 0;
  CHECK_FIXNUM (threads);
  EMACS_INT n = XFIXNUM (threads);
  return n > 0 ? (int) n : 0;
}

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
       Scmacs_whisper_transcribe_file, 2, 4, 0,
       doc: /* Synchronously transcribe WAV-PATH using MODEL-PATH.
Optional LANGUAGE is a 2-letter ISO code (default "en").  Optional THREADS
is the number of CPU cores whisper.cpp uses (nil or non-positive = all
cores).  Returns an alist:
  ((:text   . "...full text...")
   (:segments . (((:start . MS) (:end . MS) (:text . "...")) ...)))
or
  ((:error  . "error message"))  */)
  (Lisp_Object model_path, Lisp_Object wav_path, Lisp_Object language,
   Lisp_Object threads)
{
  CHECK_STRING (model_path);
  CHECK_STRING (wav_path);
  const char *lang = NILP (language) ? NULL
                   : (CHECK_STRING (language), SSDATA (language));
  int nthreads = cmacs_whisper__threads (threads);
  Lisp_Object mp = ENCODE_FILE (model_path);
  Lisp_Object wp = ENCODE_FILE (wav_path);
  GError *err = NULL;
  Lisp_Object out = cmacs_whisper_transcribe_file_sync (SSDATA (mp), lang,
                                                        SSDATA (wp), nthreads,
                                                        &err);
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
       Scmacs_whisper_transcribe_pcm, 2, 4, 0,
       doc: /* Synchronously transcribe PCM (unibyte S16LE mono 16 kHz) using
MODEL-PATH.  Optional THREADS is the CPU-core count (nil = all cores).
Returns the same alist as `cmacs-whisper-transcribe-file'.  */)
  (Lisp_Object model_path, Lisp_Object pcm, Lisp_Object language,
   Lisp_Object threads)
{
  CHECK_STRING (model_path);
  CHECK_STRING (pcm);
  const char *lang = NILP (language) ? NULL
                   : (CHECK_STRING (language), SSDATA (language));
  int nthreads = cmacs_whisper__threads (threads);
  Lisp_Object mp = ENCODE_FILE (model_path);
  return cmacs_whisper_transcribe_pcm_sync (SSDATA (mp), lang,
                                            (const int16_t *) SDATA (pcm),
                                            SBYTES (pcm) / sizeof (int16_t),
                                            nthreads);
}

DEFUN ("cmacs-whisper-transcribe-async", Fcmacs_whisper_transcribe_async,
       Scmacs_whisper_transcribe_async, 3, 5, 0,
       doc: /* Asynchronously transcribe WAV-PATH using MODEL-PATH and
call CALLBACK with the result alist.  Optional LANGUAGE = "en" etc.
Optional THREADS is the CPU-core count for inference (nil = all cores).  */)
  (Lisp_Object model_path, Lisp_Object wav_path,
   Lisp_Object callback, Lisp_Object language, Lisp_Object threads)
{
  CHECK_STRING (model_path);
  CHECK_STRING (wav_path);
  const char *lang = NILP (language) ? NULL
                   : (CHECK_STRING (language), SSDATA (language));
  int nthreads = cmacs_whisper__threads (threads);
  Lisp_Object mp = ENCODE_FILE (model_path);
  Lisp_Object wp = ENCODE_FILE (wav_path);
  cmacs_whisper_transcribe_file_async (SSDATA (mp), lang, SSDATA (wp),
                                       nthreads, callback);
  return Qt;
}

DEFUN ("cmacs-whisper-transcribe-pcm-async",
       Fcmacs_whisper_transcribe_pcm_async,
       Scmacs_whisper_transcribe_pcm_async, 3, 5, 0,
       doc: /* Asynchronously transcribe PCM (S16LE mono 16 kHz) using
MODEL-PATH; call CALLBACK with the result alist.  Optional LANGUAGE = "en"
etc.  Optional THREADS is the CPU-core count for inference (nil = all
cores).  */)
  (Lisp_Object model_path, Lisp_Object pcm,
   Lisp_Object callback, Lisp_Object language, Lisp_Object threads)
{
  CHECK_STRING (model_path);
  CHECK_STRING (pcm);
  const char *lang = NILP (language) ? NULL
                   : (CHECK_STRING (language), SSDATA (language));
  int nthreads = cmacs_whisper__threads (threads);
  Lisp_Object mp = ENCODE_FILE (model_path);
  cmacs_whisper_transcribe_pcm_async (SSDATA (mp), lang,
                                      (const int16_t *) SDATA (pcm),
                                      SBYTES (pcm) / sizeof (int16_t),
                                      nthreads,
                                      callback);
  return Qt;
}

/* --- Streaming VAD + PCM helpers (the duplex voice loop) --- */

/* Decode a VAD HANDLE argument.  */
static uint64_t
cmacs_whisper__vad_handle (Lisp_Object handle)
{
  CHECK_FIXNUM (handle);
  if (XFIXNUM (handle) <= 0)
    xsignal2 (Qargs_out_of_range, handle, make_fixnum (1));
  return (uint64_t) XFIXNUM (handle);
}

DEFUN ("cmacs-whisper-vad-open", Fcmacs_whisper_vad_open,
       Scmacs_whisper_vad_open, 1, 2, 0,
       doc: /* Open a streaming voice-activity detector on MODEL-PATH.
MODEL-PATH is a Silero VAD model in ggml form (for example
`ggml-silero-v6.2.0.bin').  Optional THREADS is the inference thread
count (nil = 1, which is plenty for Silero).

Returns an integer handle for `cmacs-whisper-vad-feed'.  The model is
loaded off the main thread on the first feed; a model that fails to
load is reported to that feed's callback.  Signals an error when
MODEL-PATH does not exist.  */)
  (Lisp_Object model_path, Lisp_Object threads)
{
  CHECK_STRING (model_path);
  Lisp_Object mp = ENCODE_FILE (Fexpand_file_name (model_path, Qnil));
  if (!g_file_test (SSDATA (mp), G_FILE_TEST_IS_REGULAR))
    error ("cmacs-whisper: no VAD model at %s", SSDATA (mp));
  uint64_t h = cmacs_whisper_vad_open (SSDATA (mp),
                                       cmacs_whisper__threads (threads));
  if (h == 0)
    error ("cmacs-whisper: could not start the VAD worker");
  return make_int ((EMACS_INT) h);
}

DEFUN ("cmacs-whisper-vad-feed", Fcmacs_whisper_vad_feed,
       Scmacs_whisper_vad_feed, 3, 3, 0,
       doc: /* Queue PCM on the VAD HANDLE; CALLBACK receives the result.
PCM is a unibyte string of S16LE mono 16 kHz samples.  Feed whole
multiples of 512 samples (1024 bytes) to keep the analysis windows
aligned across calls; the model's recurrent state carries over from
the previous feed (see `cmacs-whisper-vad-reset').

Inference runs on a worker thread; feeds on all handles are processed
strictly in the order they were queued.  CALLBACK is called later on
the main thread with
  ((:probs . [P0 P1 ...]) (:window . 512))
-- one speech probability in [0, 1] per 512-sample (32 ms) window --
or ((:error . MESSAGE)).  Returns t.  */)
  (Lisp_Object handle, Lisp_Object pcm, Lisp_Object callback)
{
  uint64_t h = cmacs_whisper__vad_handle (handle);
  CHECK_STRING (pcm);
  if (STRING_MULTIBYTE (pcm))
    error ("cmacs-whisper: PCM must be a unibyte string");
  if (!cmacs_whisper_vad_feed (h, (const int16_t *) SDATA (pcm),
                               SBYTES (pcm) / sizeof (int16_t), callback))
    error ("cmacs-whisper: no VAD with handle %"pI"d", XFIXNUM (handle));
  return Qt;
}

DEFUN ("cmacs-whisper-vad-reset", Fcmacs_whisper_vad_reset,
       Scmacs_whisper_vad_reset, 1, 1, 0,
       doc: /* Reset the recurrent state of the VAD HANDLE.
The reset is queued behind any feeds already queued.  Returns t, or
nil when HANDLE is not open.  */)
  (Lisp_Object handle)
{
  return cmacs_whisper_vad_reset (cmacs_whisper__vad_handle (handle))
         ? Qt : Qnil;
}

DEFUN ("cmacs-whisper-vad-close", Fcmacs_whisper_vad_close,
       Scmacs_whisper_vad_close, 1, 1, 0,
       doc: /* Close the VAD HANDLE and release its model.
Feeds already queued still call their callbacks.  Returns t, or nil
when HANDLE is not open.  */)
  (Lisp_Object handle)
{
  return cmacs_whisper_vad_close (cmacs_whisper__vad_handle (handle))
         ? Qt : Qnil;
}

DEFUN ("cmacs-whisper-vad-list", Fcmacs_whisper_vad_list,
       Scmacs_whisper_vad_list, 0, 0, 0,
       doc: /* Return the list of open VAD handles.  */)
  (void)
{
  return cmacs_whisper_vad_list ();
}

DEFUN ("cmacs-whisper-pcm-levels", Fcmacs_whisper_pcm_levels,
       Scmacs_whisper_pcm_levels, 1, 2, 0,
       doc: /* Return the RMS level of each WINDOW-sample window of PCM, in dBFS.
PCM is a unibyte string of S16LE mono samples.  WINDOW defaults to
512, the VAD window.  The result is a vector of floats, one per
complete window (a trailing partial window is ignored), each between
-120.0 (digital silence) and 0.0 (full scale).

This is the energy fallback the voice loop uses when no VAD model is
installed.  It is a single pass over the samples, cheap enough for the
main thread.  */)
  (Lisp_Object pcm, Lisp_Object window)
{
  CHECK_STRING (pcm);
  EMACS_INT w = 512;
  if (!NILP (window))
    {
      CHECK_FIXNUM (window);
      w = XFIXNUM (window);
      if (w <= 0)
        xsignal2 (Qargs_out_of_range, window, make_fixnum (1));
    }
  const int16_t *x = (const int16_t *) SDATA (pcm);
  ptrdiff_t n = SBYTES (pcm) / (ptrdiff_t) sizeof (int16_t);
  ptrdiff_t n_win = n / w;
  Lisp_Object out = make_nil_vector (n_win);

  for (ptrdiff_t i = 0; i < n_win; i++)
    {
      double acc = 0.0;
      const int16_t *p = x + i * w;
      for (EMACS_INT k = 0; k < w; k++)
        {
          double v = (double) p[k] / 32768.0;
          acc += v * v;
        }
      double rms = sqrt (acc / (double) w);
      double db = rms > 1e-6 ? 20.0 * log10 (rms) : -120.0;
      ASET (out, i, make_float (db < -120.0 ? -120.0 : db));
    }
  return out;
}

DEFUN ("cmacs-whisper-pcm-resample", Fcmacs_whisper_pcm_resample,
       Scmacs_whisper_pcm_resample, 3, 3, 0,
       doc: /* Resample mono S16LE PCM from FROM-RATE to TO-RATE Hz.
PCM is a unibyte string.  Linear interpolation: good enough to bring
22.05 kHz speech (Piper's usual rate) to whisper's 16 kHz, not meant
for music.  Returns a new unibyte string.  */)
  (Lisp_Object pcm, Lisp_Object from_rate, Lisp_Object to_rate)
{
  CHECK_STRING (pcm);
  CHECK_FIXNUM (from_rate);
  CHECK_FIXNUM (to_rate);
  EMACS_INT fr = XFIXNUM (from_rate);
  EMACS_INT tr = XFIXNUM (to_rate);
  if (fr <= 0)
    xsignal2 (Qargs_out_of_range, from_rate, make_fixnum (1));
  if (tr <= 0)
    xsignal2 (Qargs_out_of_range, to_rate, make_fixnum (1));

  const int16_t *x = (const int16_t *) SDATA (pcm);
  ptrdiff_t n_in = SBYTES (pcm) / (ptrdiff_t) sizeof (int16_t);
  if (fr == tr || n_in == 0)
    return make_unibyte_string ((const char *) x,
                                n_in * (ptrdiff_t) sizeof (int16_t));

  ptrdiff_t n_out = (ptrdiff_t) (((double) n_in * (double) tr) / (double) fr);
  int16_t *y = g_new (int16_t, n_out > 0 ? n_out : 1);
  double step = (double) fr / (double) tr;
  for (ptrdiff_t i = 0; i < n_out; i++)
    {
      double pos = (double) i * step;
      ptrdiff_t k = (ptrdiff_t) pos;
      double frac = pos - (double) k;
      double a = x[k < n_in ? k : n_in - 1];
      double b = x[k + 1 < n_in ? k + 1 : n_in - 1];
      double v = a + (b - a) * frac;
      y[i] = (int16_t) lrint (v);
    }
  Lisp_Object out = make_unibyte_string ((const char *) y,
                                         n_out * (ptrdiff_t) sizeof (int16_t));
  g_free (y);
  return out;
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
  defsubr (&Scmacs_whisper_vad_open);
  defsubr (&Scmacs_whisper_vad_feed);
  defsubr (&Scmacs_whisper_vad_reset);
  defsubr (&Scmacs_whisper_vad_close);
  defsubr (&Scmacs_whisper_vad_list);
  defsubr (&Scmacs_whisper_pcm_levels);
  defsubr (&Scmacs_whisper_pcm_resample);
}

#endif /* HAVE_CMACS_WHISPER */
