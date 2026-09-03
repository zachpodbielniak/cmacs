/* cmacs-ai-embed.c --- text embeddings over ai-glib's AiEmbedder.
 *
 * Copyright (C) 2026 Zach Podbielniak
 * SPDX-License-Identifier: AGPL-3.0-or-later
 *
 * ai-glib exposes embeddings as an interface (AiEmbedder) rather than a
 * provider method, because only some providers serve them: today ollama
 * and openai implement it, and asking anything else for a vector is a
 * type error rather than a request that fails at runtime.  This file is
 * the Elisp surface for that interface.
 *
 * Two entry points, because the two callers want opposite things:
 *
 *   `cmacs-ai-embed'        blocks.  One query vector is a single round
 *                           trip and the caller has nothing to do until
 *                           it lands.
 *   `cmacs-ai-embed-async'  does not.  Indexing a notes repository is
 *                           hundreds of thousands of chunks; a blocking
 *                           call there freezes Emacs for hours.  Note
 *                           that an Emacs thread would NOT have helped:
 *                           a thread parked in a synchronous call still
 *                           holds the global Lisp lock, so the main
 *                           thread cannot run.  The GLib main loop that
 *                           cmacs already pumps is what actually yields.
 *
 * The async callback is stashed in a staticpro'd Lisp hash table keyed
 * by an integer request id, never in the C-heap request struct: a
 * Lisp_Object living in GLib-allocated memory is invisible to the GC
 * and crashes the next time one runs. */

#include <config.h>

#ifdef HAVE_CMACS_AI

#include "lisp.h"
#include "cmacs-ai.h"
#include "cmacs-eval-dispatch.h"
#include <math.h>

/* ── Async callback registry (GC roots) ─────────────────────────── */

static Lisp_Object Vcmacs_ai__embed_callbacks;   /* hash: int -> callback */
static guint cmacs_ai__next_embed_id = 1;

/* id -> GCancellable, for `cmacs-ai-embed-cancel'.  Plain C memory: a
 * GCancellable is a GObject, not a Lisp_Object, so the GC has no
 * interest in it. */
static GHashTable *cmacs_ai__embed_cancellables;

static void
cmacs_ai_embed__cancellables_init (void)
{
  if (cmacs_ai__embed_cancellables) return;
  cmacs_ai__embed_cancellables =
    g_hash_table_new_full (g_direct_hash, g_direct_equal,
                           NULL, g_object_unref);
}

static void
cmacs_ai_embed__cancellable_drop (guint id)
{
  if (!cmacs_ai__embed_cancellables) return;
  g_hash_table_remove (cmacs_ai__embed_cancellables, GUINT_TO_POINTER (id));
}

static void
cmacs_ai_embed__callbacks_init (void)
{
  if (!NILP (Vcmacs_ai__embed_callbacks)) return;
  Vcmacs_ai__embed_callbacks =
    CALLN (Fmake_hash_table, QCtest, Qeql);
  staticpro (&Vcmacs_ai__embed_callbacks);
}

static Lisp_Object
cmacs_ai_embed__callback_lookup (guint id)
{
  cmacs_ai_embed__callbacks_init ();
  return Fgethash (make_uint (id), Vcmacs_ai__embed_callbacks, Qnil);
}

static void
cmacs_ai_embed__callback_set (guint id, Lisp_Object cb)
{
  cmacs_ai_embed__callbacks_init ();
  Fputhash (make_uint (id), cb, Vcmacs_ai__embed_callbacks);
}

static void
cmacs_ai_embed__callback_drop (guint id)
{
  if (NILP (Vcmacs_ai__embed_callbacks)) return;
  Fremhash (make_uint (id), Vcmacs_ai__embed_callbacks);
}

/* ── Provider construction ──────────────────────────────────────── */

/* Build an embedder for PROVIDER_SYM, or nil for the default.
 *
 * Deliberately a short list rather than a call into the generic client
 * factory: a caller who asks claude-code for a vector has made a
 * category error, and saying which providers embed is more useful than
 * constructing a client and failing an interface check later. */
static AiEmbedder *
cmacs_ai_embed__make (Lisp_Object provider_sym)
{
  /* Built against the *shared* AiConfig, not the private one a bare
   * _new() would create.  ai_ollama_client_embed_async resolves its
   * base URL through ai_client_get_config(), so a client holding its
   * own config silently ignores `cmacs-ai-config-set-base-url' -- and
   * with it `cmacs-brigade-embed-endpoint', which is layered on top.
   * The visible symptom is an endpoint setting that does nothing:
   * requests keep going to the default host and appear to succeed. */
  AiConfig *config = ai_config_get_default ();

  if (NILP (provider_sym) || EQ (provider_sym, intern ("ollama")))
    return AI_EMBEDDER (ai_ollama_client_new_with_config (config));
  if (EQ (provider_sym, intern ("openai")))
    return AI_EMBEDDER (ai_openai_client_new_with_config (config));
  error ("cmacs-ai-embed: provider %s does not serve embeddings "
         "(use ollama or openai)",
         SSDATA (SYMBOL_NAME (provider_sym)));
}

/* ── Lisp <-> C conversions ─────────────────────────────────────── */

/* TEXTS is a string or a list of strings; return a NULL-terminated
 * argv-style array.  The strings point into Lisp string data, which is
 * stable for the duration of a call that does not itself run Lisp. */
static gchar **
cmacs_ai_embed__texts_to_argv (Lisp_Object texts, gsize *n_out)
{
  gchar **argv;
  gsize n, i;
  Lisp_Object tail;

  if (STRINGP (texts))
    {
      argv = g_new0 (gchar *, 2);
      argv[0] = SSDATA (texts);
      *n_out = 1;
      return argv;
    }

  CHECK_LIST (texts);
  n = list_length (texts);
  argv = g_new0 (gchar *, n + 1);

  for (i = 0, tail = texts; i < n; i++, tail = XCDR (tail))
    {
      Lisp_Object s = XCAR (tail);
      CHECK_STRING (s);
      argv[i] = SSDATA (s);
    }

  *n_out = n;
  return argv;
}

/* One vector as a Lisp vector of floats. */
static Lisp_Object
cmacs_ai_embed__vector_to_lisp (const gfloat *v, gsize dim)
{
  Lisp_Object out = make_nil_vector (dim);
  gsize i;

  for (i = 0; i < dim; i++)
    ASET (out, i, make_float ((double) v[i]));

  return out;
}

/* The whole reply.  SINGLE means the caller passed one string and wants
 * one vector back rather than a one-element list. */
static Lisp_Object
cmacs_ai_embed__embedding_to_lisp (AiEmbedding *emb, bool single)
{
  gsize n = ai_embedding_get_n_vectors (emb);
  gsize dim = ai_embedding_get_dimensions (emb);
  Lisp_Object out = Qnil;
  gsize i;

  if (single)
    {
      const gfloat *v = ai_embedding_get_vector (emb, 0);
      return v ? cmacs_ai_embed__vector_to_lisp (v, dim) : Qnil;
    }

  /* Built back-to-front so the list comes out in request order. */
  for (i = n; i > 0; i--)
    {
      const gfloat *v = ai_embedding_get_vector (emb, i - 1);
      if (v)
        out = Fcons (cmacs_ai_embed__vector_to_lisp (v, dim), out);
    }

  return out;
}

/* A Lisp vector (or list) of numbers as a float array. */
static gfloat *
cmacs_ai_embed__lisp_to_vector (Lisp_Object v, gsize *dim_out)
{
  gfloat *out;
  gsize n, i;

  if (VECTORP (v))
    {
      n = ASIZE (v);
      out = g_new0 (gfloat, n ? n : 1);
      for (i = 0; i < n; i++)
        {
          Lisp_Object e = AREF (v, i);
          CHECK_NUMBER (e);
          out[i] = (gfloat) XFLOATINT (e);
        }
    }
  else
    {
      Lisp_Object tail;
      CHECK_LIST (v);
      n = list_length (v);
      out = g_new0 (gfloat, n ? n : 1);
      for (i = 0, tail = v; i < n; i++, tail = XCDR (tail))
        {
          Lisp_Object e = XCAR (tail);
          CHECK_NUMBER (e);
          out[i] = (gfloat) XFLOATINT (e);
        }
    }

  *dim_out = n;
  return out;
}

static Lisp_Object
cmacs_ai_embed__model_info_to_lisp (const AiEmbeddingModelInfo *info)
{
  return list (intern (":id"),
               info->id ? build_string (info->id) : Qnil,
               intern (":dimensions"),
               make_fixnum ((EMACS_INT) info->dimensions),
               intern (":max-input-chars"),
               make_fixnum ((EMACS_INT) info->max_input_chars),
               intern (":supports-batch"),
               info->supports_batch ? Qt : Qnil,
               intern (":notes"),
               info->notes ? build_string (info->notes) : Qnil);
}

/* ── Synchronous embed ──────────────────────────────────────────── */

DEFUN ("cmacs-ai-embed", Fcmacs_ai_embed, Scmacs_ai_embed, 1, 3, 0,
       doc: /* Embed TEXTS and return their vectors.

TEXTS is a string or a list of strings.  A string returns one vector; a
list returns a list of vectors, in request order.  Each vector is a Lisp
vector of floats.

Optional PROVIDER is `ollama' (the default) or `openai' -- the only two
ai-glib serves embeddings from.  Optional MODEL overrides the provider's
default embedding model; see `cmacs-ai-embed-models'.

This BLOCKS until the vectors arrive, so it is meant for a single query.
Use `cmacs-ai-embed-async' to embed a corpus.  Signals `cmacs-ai-error'
on failure.  */)
  (Lisp_Object texts, Lisp_Object provider, Lisp_Object model)
{
  g_autoptr (GError) error = NULL;
  g_autoptr (AiEmbedding) emb = NULL;
  g_autofree gchar **argv = NULL;
  AiEmbedder *embedder;
  gsize n = 0;
  bool single = STRINGP (texts);

  if (!NILP (model)) CHECK_STRING (model);

  argv = cmacs_ai_embed__texts_to_argv (texts, &n);
  if (n == 0)
    return Qnil;

  embedder = cmacs_ai_embed__make (provider);

  emb = ai_embedder_embed (embedder, (const gchar *const *) argv,
                           NILP (model) ? NULL : SSDATA (model),
                           NULL, &error);

  g_object_unref (embedder);

  if (!emb)
    xsignal1 (intern ("cmacs-ai-error"),
              build_string (error ? error->message : "embedding failed"));

  return cmacs_ai_embed__embedding_to_lisp (emb, single);
}

/* ── Asynchronous embed ─────────────────────────────────────────── */

/* C-heap only: no Lisp_Object may live here, the GC cannot see it. */
typedef struct
{
  guint  request_id;
  bool   single;
} CmacsAiEmbedRequest;

static void
cmacs_ai_embed__on_done (GObject *source, GAsyncResult *result, gpointer user)
{
  CmacsAiEmbedRequest *req = user;
  g_autoptr (GError) error = NULL;
  g_autoptr (AiEmbedding) emb = NULL;
  Lisp_Object cb, payload;

  emb = ai_embedder_embed_finish (AI_EMBEDDER (source), result, &error);

  cb = cmacs_ai_embed__callback_lookup (req->request_id);
  cmacs_ai_embed__callback_drop (req->request_id);
  cmacs_ai_embed__cancellable_drop (req->request_id);

  if (!NILP (cb))
    {
      if (emb)
        payload = list2 (intern (":ok"),
                         cmacs_ai_embed__embedding_to_lisp (emb, req->single));
      else if (error && g_error_matches (error, G_IO_ERROR,
                                         G_IO_ERROR_CANCELLED))
        payload = list1 (intern (":cancelled"));
      else
        payload = list2 (intern (":error"),
                         build_string (error ? error->message
                                             : "embedding failed"));
      cmacs_dispatch_safe_call1 (cb, payload);
    }

  g_object_unref (source);
  g_free (req);
}

DEFUN ("cmacs-ai-embed-async", Fcmacs_ai_embed_async,
       Scmacs_ai_embed_async, 2, 4, 0,
       doc: /* Embed TEXTS without blocking, then call CALLBACK.

TEXTS is a string or a list of strings.  CALLBACK is called once with a
single argument: either (:ok VECTORS) or (:error MESSAGE).  VECTORS is
one vector when TEXTS was a string, a list of vectors otherwise -- the
same shape `cmacs-ai-embed' returns.

Optional PROVIDER and MODEL are as in `cmacs-ai-embed'.  Returns an
integer request id.

This is the entry point for indexing a corpus.  Emacs stays responsive
because the reply is delivered from the GLib main loop cmacs already
pumps; running the blocking call in an Emacs thread would not work,
since such a thread keeps the global Lisp lock.  */)
  (Lisp_Object texts, Lisp_Object callback, Lisp_Object provider,
   Lisp_Object model)
{
  g_autofree gchar **argv = NULL;
  CmacsAiEmbedRequest *req;
  AiEmbedder *embedder;
  GCancellable *cancellable;
  gsize n = 0;
  guint id;

  if (!NILP (model)) CHECK_STRING (model);

  argv = cmacs_ai_embed__texts_to_argv (texts, &n);
  if (n == 0)
    error ("cmacs-ai-embed-async: nothing to embed");

  embedder = cmacs_ai_embed__make (provider);

  id = cmacs_ai__next_embed_id++;
  cmacs_ai_embed__callback_set (id, callback);

  req = g_new0 (CmacsAiEmbedRequest, 1);
  req->request_id = id;
  req->single = STRINGP (texts);

  cancellable = g_cancellable_new ();
  cmacs_ai_embed__cancellables_init ();
  g_hash_table_insert (cmacs_ai__embed_cancellables,
                       GUINT_TO_POINTER (id), cancellable);

  ai_embedder_embed_async (embedder, (const gchar *const *) argv,
                           NILP (model) ? NULL : SSDATA (model),
                           cancellable, cmacs_ai_embed__on_done, req);

  return make_uint (id);
}

DEFUN ("cmacs-ai-embed-cancel", Fcmacs_ai_embed_cancel,
       Scmacs_ai_embed_cancel, 1, 1, 0,
       doc: /* Cancel the in-flight `cmacs-ai-embed-async' request ID.

Returns t when a live request was cancelled, nil when ID is unknown --
which is the normal answer for one that already completed.  The
callback still runs, once, with (:cancelled).

This is what stops a corpus build in progress; without it the only way
to abandon one would be to let every queued batch finish.  */)
  (Lisp_Object id)
{
  GCancellable *cancellable;

  CHECK_FIXNAT (id);

  if (!cmacs_ai__embed_cancellables)
    return Qnil;

  cancellable = g_hash_table_lookup (cmacs_ai__embed_cancellables,
                                     GUINT_TO_POINTER ((guint) XFIXNAT (id)));
  if (!cancellable)
    return Qnil;

  g_cancellable_cancel (cancellable);
  return Qt;
}

/* ── Model discovery ────────────────────────────────────────────── */

DEFUN ("cmacs-ai-embed-default-model", Fcmacs_ai_embed_default_model,
       Scmacs_ai_embed_default_model, 0, 1, 0,
       doc: /* Return PROVIDER's default embedding model, as a string.
PROVIDER is `ollama' (the default) or `openai'.  */)
  (Lisp_Object provider)
{
  AiEmbedder *embedder = cmacs_ai_embed__make (provider);
  const gchar *name = ai_embedder_get_default_embedding_model (embedder);
  Lisp_Object out = name ? build_string (name) : Qnil;

  g_object_unref (embedder);
  return out;
}

DEFUN ("cmacs-ai-embed-models", Fcmacs_ai_embed_models,
       Scmacs_ai_embed_models, 0, 1, 0,
       doc: /* Return the embedding models PROVIDER publishes.

PROVIDER is `ollama' (the default) or `openai'.  The value is a list of
plists with keys :id, :dimensions, :max-input-chars, :supports-batch and
:notes.  :dimensions is what an index must be built for -- changing the
model almost always changes it, which invalidates existing vectors.

Returns nil when the provider publishes no table.  */)
  (Lisp_Object provider)
{
  AiEmbedder *embedder = cmacs_ai_embed__make (provider);
  GList *models = ai_embedder_list_embedding_models (embedder);
  Lisp_Object out = Qnil;
  GList *l;

  /* Built back-to-front so the result keeps the provider's order. */
  for (l = g_list_last (models); l; l = l->prev)
    {
      const AiEmbeddingModelInfo *info = l->data;
      if (info)
        out = Fcons (cmacs_ai_embed__model_info_to_lisp (info), out);
    }

  g_list_free (models);
  g_object_unref (embedder);
  return out;
}

/* ── Vector maths ───────────────────────────────────────────────── */

DEFUN ("cmacs-ai-embed-cosine", Fcmacs_ai_embed_cosine,
       Scmacs_ai_embed_cosine, 2, 2, 0,
       doc: /* Return the cosine similarity of vectors A and B, in [-1, 1].

A and B are Lisp vectors (or lists) of numbers and must share a length.
Handles unnormalised input; identical direction is 1.0, orthogonal 0.0,
opposite -1.0.  */)
  (Lisp_Object a, Lisp_Object b)
{
  g_autofree gfloat *va = NULL;
  g_autofree gfloat *vb = NULL;
  gsize da = 0, db = 0;

  va = cmacs_ai_embed__lisp_to_vector (a, &da);
  vb = cmacs_ai_embed__lisp_to_vector (b, &db);

  if (da != db)
    error ("cmacs-ai-embed-cosine: length mismatch (%u vs %u)",
           (unsigned) da, (unsigned) db);
  if (da == 0)
    error ("cmacs-ai-embed-cosine: empty vectors");

  return make_float (ai_embedding_cosine (va, vb, da));
}

/* ── Registration ───────────────────────────────────────────────── */

void syms_of_cmacs_ai_embed_defuns (void);

void
syms_of_cmacs_ai_embed_defuns (void)
{
  defsubr (&Scmacs_ai_embed);
  defsubr (&Scmacs_ai_embed_async);
  defsubr (&Scmacs_ai_embed_cancel);
  defsubr (&Scmacs_ai_embed_default_model);
  defsubr (&Scmacs_ai_embed_models);
  defsubr (&Scmacs_ai_embed_cosine);
}

#endif /* HAVE_CMACS_AI */
