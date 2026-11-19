/* cmacs-sherpa-phonemize.c --- espeak-ng phonemes for Piper/VITS voices
 *
 * Copyright (C) 2026 Zach Podbielniak
 * SPDX-License-Identifier: AGPL-3.0-or-later
 *
 * sherpa-onnx 2.0 no longer bundles espeak-ng: a Piper-style VITS voice
 * (or Kokoro / Matcha with espeak data) now needs its text already
 * turned into IPA phoneme codepoints, sentence by sentence.  This file
 * does that the way Piper itself does -- espeak_TextToPhonemesWith-
 * Terminator, clause by clause, putting the clause's punctuation back
 * and starting a new sentence at every sentence terminator -- so a
 * voice sounds the same here as under the piper binary.
 *
 * libespeak-ng is opened with dlopen at first use rather than linked:
 * it is a runtime nicety of one TTS family, not a build dependency
 * (Fedora ships the library with espeak-ng, the headers only with
 * -devel), and a missing library must cost Piper voices, not the build.
 * The few prototypes needed are declared here.
 *
 * espeak-ng keeps global state, so every call holds one mutex, and the
 * library is re-initialised only when the data directory changes.
 */

#include <config.h>

#ifdef HAVE_CMACS_SHERPA

#include "cmacs-sherpa-private.h"

#include <dlfcn.h>   /* RTLD_DEEPBIND: _GNU_SOURCE, set by config.h */
#include <string.h>

/* From espeak-ng's speak_lib.h.  */
#define ESPEAK_AUDIO_OUTPUT_SYNCHRONOUS 2
#define ESPEAK_CHARS_AUTO               0
#define ESPEAK_PHONEMES_IPA             0x02

#define CLAUSE_INTONATION_FULL_STOP     0x00000000
#define CLAUSE_INTONATION_COMMA         0x00001000
#define CLAUSE_INTONATION_QUESTION      0x00002000
#define CLAUSE_INTONATION_EXCLAMATION   0x00003000
#define CLAUSE_TYPE_CLAUSE              0x00040000
#define CLAUSE_TYPE_SENTENCE            0x00080000
#define CLAUSE_PERIOD      (40 | CLAUSE_INTONATION_FULL_STOP | CLAUSE_TYPE_SENTENCE)
#define CLAUSE_COMMA       (20 | CLAUSE_INTONATION_COMMA | CLAUSE_TYPE_CLAUSE)
#define CLAUSE_QUESTION    (40 | CLAUSE_INTONATION_QUESTION | CLAUSE_TYPE_SENTENCE)
#define CLAUSE_EXCLAMATION (45 | CLAUSE_INTONATION_EXCLAMATION | CLAUSE_TYPE_SENTENCE)
#define CLAUSE_COLON       (30 | CLAUSE_INTONATION_FULL_STOP | CLAUSE_TYPE_CLAUSE)
#define CLAUSE_SEMICOLON   (30 | CLAUSE_INTONATION_COMMA | CLAUSE_TYPE_CLAUSE)

typedef int (*InitializeFn) (int output, int buflength, const char *path,
                             int options);
typedef int (*SetVoiceFn) (const char *name);
typedef const char *(*ToPhonemesFn) (const void **textptr, int textmode,
                                     int phonememode, int *terminator);

static GMutex       espeak_lock;
static gboolean     espeak_tried;
static void        *espeak_lib;
static InitializeFn espeak_initialize;
static SetVoiceFn   espeak_set_voice;
static ToPhonemesFn espeak_to_phonemes;
static char        *espeak_path;     /* data path last initialised with */
static char        *espeak_voice;    /* voice last selected */

/* Open libespeak-ng once.  Call with espeak_lock held.  */
static gboolean
espeak_load (GError **error)
{
  if (!espeak_tried)
    {
      espeak_tried = TRUE;
      /* RTLD_DEEPBIND: libespeak-ng exports helpers with generic names
         (GetFileLength, ...) and calls them through the PLT, so without
         it they resolve to the first definition in the process -- and
         cmacs links raylib, whose GetFileLength returns a byte count
         where espeak expects -EISDIR for a directory.  espeak then
         rejects every data directory and every voice is "not found".
         Deep binding makes the library prefer its own symbols.  */
      espeak_lib = dlopen ("libespeak-ng.so.1",
                           RTLD_NOW | RTLD_LOCAL | RTLD_DEEPBIND);
      if (!espeak_lib)
        espeak_lib = dlopen ("libespeak-ng.so",
                             RTLD_NOW | RTLD_LOCAL | RTLD_DEEPBIND);
      if (espeak_lib)
        {
          espeak_initialize = (InitializeFn) dlsym (espeak_lib,
                                                    "espeak_Initialize");
          espeak_set_voice = (SetVoiceFn) dlsym (espeak_lib,
                                                 "espeak_SetVoiceByName");
          espeak_to_phonemes = (ToPhonemesFn) dlsym
            (espeak_lib, "espeak_TextToPhonemesWithTerminator");
        }
    }
  if (!espeak_initialize || !espeak_set_voice || !espeak_to_phonemes)
    {
      g_set_error (error, CMACS_SHERPA_ERROR, 9,
                   "Piper voices need espeak-ng 1.52 or newer "
                   "(libespeak-ng.so.1 with "
                   "espeak_TextToPhonemesWithTerminator); install espeak-ng");
      return FALSE;
    }
  return TRUE;
}

/* Append the codepoints of UTF-8 S to CPS.  */
static void
append_codepoints (GArray *cps, const char *s)
{
  for (const char *p = s; p && *p; p = g_utf8_next_char (p))
    {
      gint32 c = (gint32) g_utf8_get_char (p);
      g_array_append_val (cps, c);
    }
}

/**
 * cmacs_sherpa_phonemize:
 * @data_dir: the voice's espeak-ng-data directory
 * @voice: espeak voice name, e.g. "en-us"
 * @text: what to say
 * @codepoints: (out caller-allocates): gint32 IPA codepoints, flattened
 * @lens: (out caller-allocates): gint32 codepoints per sentence
 * @error: return location for a #GError
 *
 * Phonemize @text sentence by sentence, as Piper does.
 *
 * Returns: %TRUE on success.
 */
gboolean
cmacs_sherpa_phonemize (const char *data_dir, const char *voice,
                        const char *text, GArray *codepoints, GArray *lens,
                        GError **error)
{
  g_autofree char *parent = NULL;
  const void *ptr;
  guint sentence_start;
  gboolean ok = FALSE;

  g_mutex_lock (&espeak_lock);
  if (!espeak_load (error))
    goto out;

  /* espeak_Initialize wants the directory CONTAINING espeak-ng-data.  */
  parent = g_path_get_dirname (data_dir);
  if (g_strcmp0 (parent, espeak_path) != 0)
    {
      if (espeak_initialize (ESPEAK_AUDIO_OUTPUT_SYNCHRONOUS, 0, parent, 0)
          < 0)
        {
          g_set_error (error, CMACS_SHERPA_ERROR, 9,
                       "espeak-ng could not initialise from %s", data_dir);
          goto out;
        }
      g_free (espeak_path);
      espeak_path = g_strdup (parent);
      g_clear_pointer (&espeak_voice, g_free);
    }
  if (g_strcmp0 (voice, espeak_voice) != 0)
    {
      if (espeak_set_voice (voice) != 0)
        {
          g_set_error (error, CMACS_SHERPA_ERROR, 9,
                       "espeak-ng has no voice `%s'", voice);
          goto out;
        }
      g_free (espeak_voice);
      espeak_voice = g_strdup (voice);
    }

  ptr = text;
  sentence_start = codepoints->len;
  while (ptr)
    {
      int terminator = 0;
      const char *ph = espeak_to_phonemes (&ptr, ESPEAK_CHARS_AUTO,
                                           ESPEAK_PHONEMES_IPA, &terminator);
      int punct = terminator & 0x000FFFFF;
      append_codepoints (codepoints, ph);
      switch (punct)
        {
        case CLAUSE_PERIOD:      append_codepoints (codepoints, ".");  break;
        case CLAUSE_QUESTION:    append_codepoints (codepoints, "?");  break;
        case CLAUSE_EXCLAMATION: append_codepoints (codepoints, "!");  break;
        case CLAUSE_COMMA:       append_codepoints (codepoints, ", "); break;
        case CLAUSE_COLON:       append_codepoints (codepoints, ": "); break;
        case CLAUSE_SEMICOLON:   append_codepoints (codepoints, "; "); break;
        default: break;
        }
      if ((terminator & CLAUSE_TYPE_SENTENCE) == CLAUSE_TYPE_SENTENCE
          || !ptr)
        {
          gint32 n = (gint32) (codepoints->len - sentence_start);
          if (n > 0)
            g_array_append_val (lens, n);
          sentence_start = codepoints->len;
        }
    }
  ok = lens->len > 0;
  if (!ok)
    g_set_error (error, CMACS_SHERPA_ERROR, 9, "nothing to say");

 out:
  g_mutex_unlock (&espeak_lock);
  return ok;
}

#endif /* HAVE_CMACS_SHERPA */
