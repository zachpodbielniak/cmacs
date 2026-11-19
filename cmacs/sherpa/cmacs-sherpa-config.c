/* cmacs-sherpa-config.c --- string config -> sherpa config structs
 *
 * Copyright (C) 2026 Zach Podbielniak
 * SPDX-License-Identifier: AGPL-3.0-or-later
 *
 * Fills sherpa-onnx's nested config structs from a flat string map,
 * using the field tables admin/cmacs-sherpa-gen-config.sh generates
 * from c-api.h.  Nothing here knows any model family by name: a field
 * sherpa adds in a release is settable from Lisp as soon as the tables
 * are regenerated, which the build does whenever c-api.h changes.
 */

#include <config.h>

#ifdef HAVE_CMACS_SHERPA

#include "cmacs-sherpa-private.h"

#include <errno.h>
#include <stdlib.h>
#include <string.h>

#include "cmacs-sherpa-config-tables.h"

/* Map a table id to its generated array.  */
const CmacsSherpaField *
cmacs_sherpa_table (CmacsSherpaTable t)
{
  switch (t)
    {
    case CMACS_SHERPA_T_OFFLINE_RECOGNIZER:
      return cmacs_sherpa_fields_OfflineRecognizerConfig;
    case CMACS_SHERPA_T_ONLINE_RECOGNIZER:
      return cmacs_sherpa_fields_OnlineRecognizerConfig;
    case CMACS_SHERPA_T_KEYWORD_SPOTTER:
      return cmacs_sherpa_fields_KeywordSpotterConfig;
    case CMACS_SHERPA_T_VAD:
      return cmacs_sherpa_fields_VadModelConfig;
    case CMACS_SHERPA_T_TTS:
      return cmacs_sherpa_fields_OfflineTtsConfig;
    case CMACS_SHERPA_T_GENERATION:
      return cmacs_sherpa_fields_GenerationConfig;
    case CMACS_SHERPA_T_DIARIZATION:
      return cmacs_sherpa_fields_OfflineSpeakerDiarizationConfig;
    case CMACS_SHERPA_T_SPEAKER_EMBEDDING:
      return cmacs_sherpa_fields_SpeakerEmbeddingExtractorConfig;
    case CMACS_SHERPA_T_OFFLINE_PUNCT:
      return cmacs_sherpa_fields_OfflinePunctuationConfig;
    case CMACS_SHERPA_T_ONLINE_PUNCT:
      return cmacs_sherpa_fields_OnlinePunctuationConfig;
    case CMACS_SHERPA_T_LID:
      return cmacs_sherpa_fields_SpokenLanguageIdentificationConfig;
    case CMACS_SHERPA_T_AUDIO_TAGGING:
      return cmacs_sherpa_fields_AudioTaggingConfig;
    case CMACS_SHERPA_T_OFFLINE_DENOISER:
      return cmacs_sherpa_fields_OfflineSpeechDenoiserConfig;
    case CMACS_SHERPA_T_ONLINE_DENOISER:
      return cmacs_sherpa_fields_OnlineSpeechDenoiserConfig;
    case CMACS_SHERPA_T_SOURCE_SEPARATION:
      return cmacs_sherpa_fields_OfflineSourceSeparationConfig;
    case CMACS_SHERPA_T_NONE:
    default:
      return NULL;
    }
}

/* Find KEY in TABLE.  A key may omit the root's own wrapper -- so
   "whisper.encoder" finds "model-config.whisper.encoder" and
   "vits.model" finds "model.vits.model" -- because Lisp callers think
   in model families, not in sherpa's struct nesting.  */
static const CmacsSherpaField *
lookup_field (const CmacsSherpaField *table, const char *key)
{
  static const char *const prefixes[] = { "", "model-config.", "model.",
                                          NULL };
  for (int p = 0; prefixes[p]; p++)
    {
      for (const CmacsSherpaField *f = table; f->key; f++)
        {
          size_t plen = strlen (prefixes[p]);
          if (strncmp (f->key, prefixes[p], plen) == 0
              && strcmp (f->key + plen, key) == 0)
            return f;
        }
    }
  return NULL;
}

static gboolean
key_in (const char *const *list, const char *key)
{
  if (!list)
    return FALSE;
  for (; *list; list++)
    if (strcmp (*list, key) == 0)
      return TRUE;
  return FALSE;
}

gboolean
cmacs_sherpa_config_fill (CmacsSherpaTable t, void *struct_ptr,
                          GHashTable *config, const char *const *extra,
                          GError **error)
{
  const CmacsSherpaField *table = cmacs_sherpa_table (t);
  GHashTableIter it;
  gpointer k, v;

  if (!config)
    return TRUE;
  if (!table)
    {
      /* A kind with no config struct (a stream) accepts only extras.  */
      g_hash_table_iter_init (&it, config);
      while (g_hash_table_iter_next (&it, &k, &v))
        if (!key_in (extra, k))
          {
            g_set_error (error, CMACS_SHERPA_ERROR, 1,
                         "unknown config key `%s'", (const char *) k);
            return FALSE;
          }
      return TRUE;
    }

  g_hash_table_iter_init (&it, config);
  while (g_hash_table_iter_next (&it, &k, &v))
    {
      const char *key = k;
      const char *val = v;
      const CmacsSherpaField *f;
      char *slot;
      char *end = NULL;

      if (key_in (extra, key))
        continue;
      f = lookup_field (table, key);
      if (!f)
        {
          g_set_error (error, CMACS_SHERPA_ERROR, 1,
                       "unknown config key `%s' (see "
                       "`cmacs-sherpa-config-keys')", key);
          return FALSE;
        }

      slot = (char *) struct_ptr + f->offset;
      switch (f->type)
        {
        case CMACS_SHERPA_F_STR:
          /* Points into CONFIG; the handle keeps CONFIG alive.  */
          *(const char **) (void *) slot = val;
          break;

        case CMACS_SHERPA_F_INT:
          {
            long n;
            errno = 0;
            n = strtol (val, &end, 10);
            if (errno || !end || *end || end == val
                || n < INT32_MIN || n > INT32_MAX)
              {
                g_set_error (error, CMACS_SHERPA_ERROR, 2,
                             "config key `%s' wants an integer, got `%s'",
                             key, val);
                return FALSE;
              }
            *(int32_t *) (void *) slot = (int32_t) n;
          }
          break;

        case CMACS_SHERPA_F_FLOAT:
          {
            double d;
            errno = 0;
            d = g_ascii_strtod (val, &end);
            if (errno || !end || *end || end == val)
              {
                g_set_error (error, CMACS_SHERPA_ERROR, 2,
                             "config key `%s' wants a number, got `%s'",
                             key, val);
                return FALSE;
              }
            *(float *) (void *) slot = (float) d;
          }
          break;

        default:
          break;
        }
    }
  return TRUE;
}

/* --- typed parameter lookups --- */

const char *
cmacs_sherpa_param (GHashTable *params, const char *key)
{
  return params ? g_hash_table_lookup (params, key) : NULL;
}

int
cmacs_sherpa_param_int (GHashTable *params, const char *key, int fallback)
{
  const char *s = cmacs_sherpa_param (params, key);
  char *end = NULL;
  long n;

  if (!s || !*s)
    return fallback;
  errno = 0;
  n = strtol (s, &end, 10);
  if (errno || !end || *end || n < INT32_MIN || n > INT32_MAX)
    return fallback;
  return (int) n;
}

double
cmacs_sherpa_param_double (GHashTable *params, const char *key,
                           double fallback)
{
  const char *s = cmacs_sherpa_param (params, key);
  char *end = NULL;
  double d;

  if (!s || !*s)
    return fallback;
  errno = 0;
  d = g_ascii_strtod (s, &end);
  if (errno || !end || *end)
    return fallback;
  return d;
}

gboolean
cmacs_sherpa_param_bool (GHashTable *params, const char *key,
                         gboolean fallback)
{
  const char *s = cmacs_sherpa_param (params, key);

  if (!s || !*s)
    return fallback;
  return !(strcmp (s, "0") == 0 || g_ascii_strcasecmp (s, "nil") == 0
           || g_ascii_strcasecmp (s, "false") == 0);
}

#endif /* HAVE_CMACS_SHERPA */
