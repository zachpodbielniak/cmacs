/* cmacs-sherpa-kws-tokens.c --- spell a phrase in a model's tokens
 *
 * Copyright (C) 2026 Zach Podbielniak
 * SPDX-License-Identifier: AGPL-3.0-or-later
 *
 * sherpa-onnx's keyword spotter does not take "jarvis"; it takes the
 * phrase already spelled in the model's own token inventory, e.g.
 *
 *     ▁JA R VI S @jarvis
 *
 * sherpa ships a Python tool for that (text2token, a SentencePiece
 * encode).  cmacs cannot depend on Python for a wake word, so this file
 * encodes in C.  It has to be the SAME segmentation the model was
 * trained on, not merely a valid one: the spotter matches a token path,
 * so "▁LI G H T" never fires on audio the model hears as "▁ L IGHT".
 *
 * The model directory's bpe.model (a SentencePiece ModelProto) holds the
 * pieces, their scores and the model type; a ~60-line protobuf reader
 * below pulls those out.  A Unigram model (what icefall exports for its
 * "bpe_500" keyword models) is segmented by Viterbi -- the split whose
 * piece log-probabilities sum highest -- and a BPE model by repeatedly
 * merging the adjacent pair with the best score.  Without a bpe.model
 * the token ids of tokens.txt stand in for BPE merge ranks, which is
 * right for BPE exports and a best effort otherwise.  The model's own
 * test_keywords.txt is the test oracle.  CJK character models
 * ("cjkchar") need no SentencePiece: each character is a token.
 *
 * No sherpa header, no Lisp: tested directly by ERT through the DEFUN.
 */

#include <config.h>

#ifdef HAVE_CMACS_SHERPA

#include "cmacs-sherpa-engine.h"

#include <string.h>

#define WORD_MARKER "\xe2\x96\x81"     /* U+2581 */

/* Load tokens.txt ("piece id" per line) as piece -> id + 1 (so that
   id 0 is not a NULL value).  */
static GHashTable *
load_vocab (const char *path, gboolean *has_lower, gboolean *has_upper,
            GError **error)
{
  g_autofree char *data = NULL;
  g_auto (GStrv) lines = NULL;
  GHashTable *set;

  if (!g_file_get_contents (path, &data, NULL, error))
    return NULL;
  set = g_hash_table_new_full (g_str_hash, g_str_equal, g_free, NULL);
  *has_lower = *has_upper = FALSE;
  lines = g_strsplit (data, "\n", -1);
  for (char **l = lines; *l; l++)
    {
      char *sp = strrchr (*l, ' ');
      char *piece;
      if (!sp || sp == *l)
        continue;
      piece = g_strndup (*l, (gsize) (sp - *l));
      /* Special symbols (<blk>, <unk>, <sos/eos>) say nothing about
         the case of the real pieces.  */
      if (*piece != '<')
        for (const char *c = piece; *c; c++)
          {
            if (g_ascii_islower (*c))
              *has_lower = TRUE;
            else if (g_ascii_isupper (*c))
              *has_upper = TRUE;
          }
      g_hash_table_insert (set, piece,
                           GSIZE_TO_POINTER (g_ascii_strtoull (sp + 1, NULL,
                                                               10) + 1));
    }
  return set;
}

/* SentencePiece-BPE encode WORD (already cased, prefixed with the word
   marker) against VOCAB, appending pieces to OUT separated by spaces.  */
static gboolean
spell_word (GHashTable *vocab, const char *word, GString *out,
            GError **error)
{
  g_autoptr (GPtrArray) sym = g_ptr_array_new_with_free_func (g_free);

  /* One symbol per character.  */
  for (const char *p = word; *p; p = g_utf8_next_char (p))
    g_ptr_array_add (sym, g_strndup (p, (gsize) (g_utf8_next_char (p) - p)));

  /* Merge the best-ranked adjacent pair until none is a piece.  */
  for (;;)
    {
      guint best = G_MAXUINT;
      gsize best_rank = G_MAXSIZE;
      for (guint i = 0; i + 1 < sym->len; i++)
        {
          g_autofree char *cand = g_strconcat (sym->pdata[i],
                                               sym->pdata[i + 1], NULL);
          gsize rank = GPOINTER_TO_SIZE (g_hash_table_lookup (vocab, cand));
          if (rank && rank < best_rank)
            {
              best_rank = rank;
              best = i;
            }
        }
      if (best == G_MAXUINT)
        break;
      {
        char *merged = g_strconcat (sym->pdata[best], sym->pdata[best + 1],
                                    NULL);
        g_free (sym->pdata[best]);
        sym->pdata[best] = merged;
        g_ptr_array_remove_index (sym, best + 1);
      }
    }

  for (guint i = 0; i < sym->len; i++)
    {
      const char *piece = sym->pdata[i];
      if (!g_hash_table_contains (vocab, piece))
        {
          g_set_error (error, CMACS_SHERPA_ERROR, 7,
                       "the keyword model has no token for `%s' in `%s'",
                       piece, word);
          return FALSE;
        }
      if (out->len)
        g_string_append_c (out, ' ');
      g_string_append (out, piece);
    }
  return TRUE;
}

/* --- SentencePiece model (bpe.model) --- */

typedef struct
{
  GHashTable *score;      /* piece -> double* (normal pieces only) */
  gboolean    unigram;    /* else BPE */
  int         max_chars;  /* longest piece, in characters */
} SpModel;

static void
sp_model_free (SpModel *m)
{
  if (m)
    {
      g_hash_table_unref (m->score);
      g_free (m);
    }
}

G_DEFINE_AUTOPTR_CLEANUP_FUNC (SpModel, sp_model_free)

static gboolean
pb_varint (const guint8 **p, const guint8 *end, guint64 *v)
{
  int shift = 0;
  *v = 0;
  while (*p < end && shift < 64)
    {
      guint8 b = *(*p)++;
      *v |= (guint64) (b & 0x7f) << shift;
      if (!(b & 0x80))
        return TRUE;
      shift += 7;
    }
  return FALSE;
}

/* Skip a field of WIRE type; FALSE on a malformed message.  */
static gboolean
pb_skip (const guint8 **p, const guint8 *end, int wire)
{
  guint64 n;
  switch (wire)
    {
    case 0: return pb_varint (p, end, &n);
    case 1: if (end - *p < 8) return FALSE; *p += 8; return TRUE;
    case 5: if (end - *p < 4) return FALSE; *p += 4; return TRUE;
    case 2:
      if (!pb_varint (p, end, &n) || (guint64) (end - *p) < n)
        return FALSE;
      *p += n;
      return TRUE;
    default: return FALSE;
    }
}

/* Parse one SentencePiece message (piece=1, score=2, type=3) into M.  */
static gboolean
pb_piece (SpModel *m, const guint8 *p, const guint8 *end)
{
  g_autofree char *piece = NULL;
  float score = 0.0f;
  guint64 type = 1;             /* NORMAL */
  while (p < end)
    {
      guint64 key, n;
      if (!pb_varint (&p, end, &key))
        return FALSE;
      if (key >> 3 == 1 && (key & 7) == 2)
        {
          if (!pb_varint (&p, end, &n) || (guint64) (end - p) < n)
            return FALSE;
          g_free (piece);
          piece = g_strndup ((const char *) p, n);
          p += n;
        }
      else if (key >> 3 == 2 && (key & 7) == 5 && end - p >= 4)
        {
          guint32 bits = (guint32) p[0] | (guint32) p[1] << 8
                         | (guint32) p[2] << 16 | (guint32) p[3] << 24;
          memcpy (&score, &bits, sizeof score);
          p += 4;
        }
      else if (key >> 3 == 3 && (key & 7) == 0)
        {
          if (!pb_varint (&p, end, &type))
            return FALSE;
        }
      else if (!pb_skip (&p, end, (int) (key & 7)))
        return FALSE;
    }
  /* NORMAL (1) and USER_DEFINED (4) pieces can appear in a segmentation;
     unknown/control/byte/unused cannot.  */
  if (piece && (type == 1 || type == 4))
    {
      double *d = g_new (double, 1);
      int len = (int) g_utf8_strlen (piece, -1);
      *d = type == 4 ? 0.0 : (double) score;
      if (len > m->max_chars)
        m->max_chars = len;
      g_hash_table_insert (m->score, g_steal_pointer (&piece), d);
    }
  return TRUE;
}

/* Read DIR/bpe.model; NULL (no error) when it is absent or unreadable.  */
static SpModel *
sp_model_load (const char *dir)
{
  g_autofree char *path = g_build_filename (dir, "bpe.model", NULL);
  g_autofree guint8 *data = NULL;
  gsize len = 0;
  const guint8 *p, *end;
  g_autoptr (SpModel) m = NULL;

  if (!g_file_get_contents (path, (char **) &data, &len, NULL))
    return NULL;
  m = g_new0 (SpModel, 1);
  m->score = g_hash_table_new_full (g_str_hash, g_str_equal, g_free, g_free);
  m->unigram = TRUE;            /* TrainerSpec's default model_type */
  p = data;
  end = data + len;
  while (p < end)
    {
      guint64 key, n;
      if (!pb_varint (&p, end, &key))
        return NULL;
      if ((key & 7) == 2 && (key >> 3 == 1 || key >> 3 == 2))
        {
          const guint8 *sub;
          if (!pb_varint (&p, end, &n) || (guint64) (end - p) < n)
            return NULL;
          sub = p;
          p += n;
          if (key >> 3 == 1)
            {
              if (!pb_piece (m, sub, sub + n))
                return NULL;
            }
          else
            {
              /* TrainerSpec: model_type is field 3 (1 UNIGRAM, 2 BPE).  */
              const guint8 *q = sub;
              while (q < sub + n)
                {
                  guint64 k2, v;
                  if (!pb_varint (&q, sub + n, &k2))
                    return NULL;
                  if (k2 >> 3 == 3 && (k2 & 7) == 0)
                    {
                      if (!pb_varint (&q, sub + n, &v))
                        return NULL;
                      m->unigram = v != 2;
                    }
                  else if (!pb_skip (&q, sub + n, (int) (k2 & 7)))
                    return NULL;
                }
            }
        }
      else if (!pb_skip (&p, end, (int) (key & 7)))
        return NULL;
    }
  return g_hash_table_size (m->score) ? g_steal_pointer (&m) : NULL;
}

/* Byte offsets of each UTF-8 character of S, plus the end.  */
static GArray *
char_offsets (const char *s)
{
  GArray *off = g_array_new (FALSE, FALSE, sizeof (gsize));
  for (const char *p = s; ; p = g_utf8_next_char (p))
    {
      gsize o = (gsize) (p - s);
      g_array_append_val (off, o);
      if (!*p)
        break;
    }
  return off;
}

/* Unigram: the segmentation of S maximising the summed piece scores.  */
static gboolean
sp_unigram (SpModel *m, const char *s, GPtrArray *pieces, GError **error)
{
  g_autoptr (GArray) off = char_offsets (s);
  guint n = off->len - 1;
  g_autofree double *best = g_new (double, n + 1);
  g_autofree guint *from = g_new (guint, n + 1);

  best[0] = 0.0;
  for (guint i = 1; i <= n; i++)
    {
      best[i] = -G_MAXDOUBLE;
      from[i] = G_MAXUINT;
      for (guint j = i > (guint) m->max_chars ? i - (guint) m->max_chars : 0;
           j < i; j++)
        {
          gsize a = g_array_index (off, gsize, j);
          gsize b = g_array_index (off, gsize, i);
          g_autofree char *cand = g_strndup (s + a, b - a);
          double *sc;
          if (best[j] == -G_MAXDOUBLE)
            continue;
          sc = g_hash_table_lookup (m->score, cand);
          if (sc && best[j] + *sc > best[i])
            {
              best[i] = best[j] + *sc;
              from[i] = j;
            }
        }
      if (from[i] == G_MAXUINT && i == n)
        break;
    }
  if (n == 0 || from[n] == G_MAXUINT)
    {
      g_set_error (error, CMACS_SHERPA_ERROR, 7,
                   "the keyword model cannot spell `%s'", s);
      return FALSE;
    }
  for (guint i = n; i > 0; i = from[i])
    {
      gsize a = g_array_index (off, gsize, from[i]);
      gsize b = g_array_index (off, gsize, i);
      g_ptr_array_insert (pieces, 0, g_strndup (s + a, b - a));
    }
  return TRUE;
}

/* BPE: merge the adjacent pair with the best score until none is a
   piece.  */
static gboolean
sp_bpe (SpModel *m, const char *s, GPtrArray *pieces, GError **error)
{
  for (const char *p = s; *p; p = g_utf8_next_char (p))
    g_ptr_array_add (pieces, g_strndup (p, (gsize) (g_utf8_next_char (p) - p)));
  for (;;)
    {
      guint best = G_MAXUINT;
      double best_score = -G_MAXDOUBLE;
      for (guint i = 0; i + 1 < pieces->len; i++)
        {
          g_autofree char *cand = g_strconcat (pieces->pdata[i],
                                               pieces->pdata[i + 1], NULL);
          double *sc = g_hash_table_lookup (m->score, cand);
          if (sc && *sc > best_score)
            {
              best_score = *sc;
              best = i;
            }
        }
      if (best == G_MAXUINT)
        break;
      {
        char *merged = g_strconcat (pieces->pdata[best],
                                    pieces->pdata[best + 1], NULL);
        g_free (pieces->pdata[best]);
        pieces->pdata[best] = merged;
        g_ptr_array_remove_index (pieces, best + 1);
      }
    }
  for (guint i = 0; i < pieces->len; i++)
    if (!g_hash_table_contains (m->score, pieces->pdata[i]))
      {
        g_set_error (error, CMACS_SHERPA_ERROR, 7,
                     "the keyword model has no token for `%s'",
                     (const char *) pieces->pdata[i]);
        return FALSE;
      }
  return TRUE;
}

/**
 * cmacs_sherpa_kws_tokenize:
 * @tokens_path: the keyword model's tokens.txt
 * @phrase: what to listen for, e.g. "hey cmacs"
 * @cjk: %TRUE for a character-level (cjkchar) model
 * @error: return location for a #GError
 *
 * Spell @phrase as one keyword line ("▁HE Y ▁C MA C S @hey_cmacs").
 *
 * Returns: (transfer full) (nullable): the line, or %NULL with @error.
 */
char *
cmacs_sherpa_kws_tokenize (const char *tokens_path, const char *phrase,
                           gboolean cjk, GError **error)
{
  g_autoptr (GHashTable) vocab = NULL;
  g_autoptr (GString) out = g_string_new (NULL);
  g_auto (GStrv) words = NULL;
  g_autofree char *clean = NULL;
  gboolean lower = FALSE, upper = FALSE;

  if (!phrase || !*phrase)
    {
      g_set_error (error, CMACS_SHERPA_ERROR, 7, "empty keyword");
      return NULL;
    }
  vocab = load_vocab (tokens_path, &lower, &upper, error);
  if (!vocab)
    return NULL;

  clean = g_utf8_normalize (phrase, -1, G_NORMALIZE_NFC);
  if (!clean)
    {
      g_set_error (error, CMACS_SHERPA_ERROR, 7, "keyword is not UTF-8");
      return NULL;
    }
  g_strstrip (clean);
  if (cjk)
    {
      for (const char *p = clean; *p; p = g_utf8_next_char (p))
        {
          g_autofree char *ch = g_strndup (p, (gsize) (g_utf8_next_char (p) - p));
          if (g_unichar_isspace (g_utf8_get_char (p)))
            continue;
          if (!g_hash_table_contains (vocab, ch))
            {
              g_set_error (error, CMACS_SHERPA_ERROR, 7,
                           "the keyword model has no token for `%s'", ch);
              return NULL;
            }
          if (out->len)
            g_string_append_c (out, ' ');
          g_string_append (out, ch);
        }
    }
  else
    {
      g_autofree char *dir = g_path_get_dirname (tokens_path);
      g_autoptr (SpModel) sp = sp_model_load (dir);
      g_autoptr (GString) marked = g_string_new (NULL);

      /* Match the vocabulary's case: sherpa's English keyword models
         are upper-case (GigaSpeech), some are lower.  SentencePiece
         sees the whole phrase, each word behind the word marker.  */
      words = g_strsplit_set (clean, " \t", -1);
      for (char **w = words; *w; w++)
        {
          g_autofree char *cased = NULL;
          if (!**w)
            continue;
          cased = upper && !lower ? g_utf8_strup (*w, -1)
                  : lower && !upper ? g_utf8_strdown (*w, -1)
                  : g_strdup (*w);
          if (sp)
            {
              g_string_append (marked, WORD_MARKER);
              g_string_append (marked, cased);
            }
          else
            {
              g_autofree char *one = g_strconcat (WORD_MARKER, cased, NULL);
              if (!spell_word (vocab, one, out, error))
                return NULL;
            }
        }
      if (sp && marked->len)
        {
          g_autoptr (GPtrArray) pieces = g_ptr_array_new_with_free_func (g_free);
          if (!(sp->unigram ? sp_unigram (sp, marked->str, pieces, error)
                            : sp_bpe (sp, marked->str, pieces, error)))
            return NULL;
          for (guint i = 0; i < pieces->len; i++)
            {
              if (!g_hash_table_contains (vocab, pieces->pdata[i]))
                {
                  g_set_error (error, CMACS_SHERPA_ERROR, 7,
                               "piece `%s' of bpe.model is not in %s",
                               (const char *) pieces->pdata[i], tokens_path);
                  return NULL;
                }
              if (out->len)
                g_string_append_c (out, ' ');
              g_string_append (out, pieces->pdata[i]);
            }
        }
    }

  if (!out->len)
    {
      g_set_error (error, CMACS_SHERPA_ERROR, 7, "empty keyword");
      return NULL;
    }
  /* The display name ends at whitespace in sherpa's parser ("@light
     up" makes "up" a token it cannot find), so spaces become `_';
     cmacs-speech turns them back on a detection.  */
  g_strdelimit (clean, " \t", '_');
  g_string_append_printf (out, " @%s", clean);
  return g_string_free (g_steal_pointer (&out), FALSE);
}

/**
 * cmacs_sherpa_kws_validate:
 * @tokens_path: the keyword model's tokens.txt
 * @keywords: keyword lines separated by `/' or newlines
 * @error: return location for a #GError
 *
 * Check that every token of every line exists in the model.  sherpa-onnx
 * answers a bad line with a null stream inside a non-null wrapper, which
 * crashes at the first decode -- in cmacs, the editor (and under --gowl
 * the desktop) -- so lines are checked here first.
 *
 * Returns: %TRUE when sherpa can encode @keywords.
 */
gboolean
cmacs_sherpa_kws_validate (const char *tokens_path, const char *keywords,
                           GError **error)
{
  g_autoptr (GHashTable) vocab = NULL;
  g_auto (GStrv) lines = NULL;
  gboolean lower = FALSE, upper = FALSE;
  int n = 0;

  vocab = load_vocab (tokens_path, &lower, &upper, error);
  if (!vocab)
    return FALSE;
  lines = g_strsplit_set (keywords ? keywords : "", "/\n", -1);
  for (char **l = lines; *l; l++)
    {
      g_auto (GStrv) words = g_strsplit_set (*l, " \t", -1);
      int tokens = 0;
      for (char **w = words; *w; w++)
        {
          if (!**w || **w == ':' || **w == '#' || **w == '@')
            continue;
          if (!g_hash_table_contains (vocab, *w))
            {
              g_set_error (error, CMACS_SHERPA_ERROR, 7,
                           "keyword token `%s' is not in %s (line `%s')",
                           *w, tokens_path, *l);
              return FALSE;
            }
          tokens++;
        }
      if (tokens)
        n++;
      else if (g_strstrip (*l)[0])
        {
          g_set_error (error, CMACS_SHERPA_ERROR, 7,
                       "keyword line `%s' has no tokens", *l);
          return FALSE;
        }
    }
  if (n == 0)
    {
      g_set_error (error, CMACS_SHERPA_ERROR, 7, "no keywords");
      return FALSE;
    }
  return TRUE;
}

#endif /* HAVE_CMACS_SHERPA */
