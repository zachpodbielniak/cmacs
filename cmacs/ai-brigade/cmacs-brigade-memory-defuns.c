/* cmacs-brigade-memory-defuns.c --- Lisp entry points to the index.
 *
 * Copyright (C) 2026 Zach Podbielniak
 * SPDX-License-Identifier: AGPL-3.0-or-later
 *
 * The Elisp side owns policy -- which roots to index, when to rebuild,
 * how to talk to the embedder -- and this file owns the parts that would
 * be unbearable in Lisp: chunking 369 MB of org, and scanning a few
 * hundred megabytes of fp16 per query.  Elisp has no fp16, no SIMD, and
 * three hundred thousand float vectors would be a GC problem rather than
 * a data structure.
 *
 * Handles follow the cmacs/ai convention: monotonic integers in a
 * mutex-guarded table that holds the only reference, and no Lisp_Object
 * ever stored in C-allocated memory. */

#include <config.h>

#ifdef HAVE_CMACS_AI_BRIGADE

#include "lisp.h"
#include "cmacs-brigade.h"

#include <glib.h>
#include <math.h>
#include <string.h>

/* ── Handle registries ────────────────────────────────────────────── */

static GHashTable *cmacs_brigade__indexes;   /* guint -> CmacsBrigadeIndex* */
static GHashTable *cmacs_brigade__writers;   /* guint -> writer* */
static guint       cmacs_brigade__next_handle = 1;
static GMutex      cmacs_brigade__mem_mutex;
static gboolean    cmacs_brigade__mem_init_done;

static void
mem_registry_init (void)
{
  if (cmacs_brigade__mem_init_done) return;
  cmacs_brigade__mem_init_done = TRUE;
  g_mutex_init (&cmacs_brigade__mem_mutex);
  cmacs_brigade__indexes =
    g_hash_table_new_full (g_direct_hash, g_direct_equal, NULL,
                           (GDestroyNotify) cmacs_brigade_index_close);
  cmacs_brigade__writers =
    g_hash_table_new_full (g_direct_hash, g_direct_equal, NULL,
                           (GDestroyNotify) cmacs_brigade_index_writer_free);
}

static guint
mem_put (GHashTable *table, gpointer value)
{
  guint h;

  g_mutex_lock (&cmacs_brigade__mem_mutex);
  h = cmacs_brigade__next_handle++;
  g_hash_table_insert (table, GUINT_TO_POINTER (h), value);
  g_mutex_unlock (&cmacs_brigade__mem_mutex);
  return h;
}

static gpointer
mem_get (GHashTable *table, Lisp_Object handle)
{
  gpointer v;

  CHECK_FIXNAT (handle);
  g_mutex_lock (&cmacs_brigade__mem_mutex);
  v = g_hash_table_lookup (table, GUINT_TO_POINTER (XFIXNUM (handle)));
  g_mutex_unlock (&cmacs_brigade__mem_mutex);
  return v;
}

/* ── Chunking ─────────────────────────────────────────────────────── */

DEFUN ("cmacs-brigade-chunk-string", Fcmacs_brigade_chunk_string,
       Scmacs_brigade_chunk_string, 2, 4, 0,
       doc: /* Split TEXT into indexable chunks and return them as a list.

PATH names the document and seeds each chunk's breadcrumb.  TARGET is the
soft chunk size in bytes (nil selects the default) and OVERLAP is how
much of a split chunk is repeated at the head of the next one.

Each element is a plist with :text, :heading, :start and :length.  The
:heading is a synthetic breadcrumb ("path > Section > Subsection")
prepended to the text before embedding -- without it a chunk reading
"yes, Tuesday works" would have no content words and would never be
retrieved.

The splitter is a line scanner rather than an org parser: it runs over
tens of thousands of files, and `org-element-parse-buffer' on that
corpus blocks the main thread for minutes.  It skips :LOGBOOK: and
:PROPERTIES: drawers and drops long source blocks, since code embedded
into a prose space makes every query about "the parser" return the
parser.  */)
  (Lisp_Object text, Lisp_Object path, Lisp_Object target,
   Lisp_Object overlap)
{
  g_autoptr (GPtrArray) chunks = NULL;
  Lisp_Object out = Qnil;
  guint i;

  CHECK_STRING (text);
  CHECK_STRING (path);

  chunks = cmacs_brigade_chunk_text (
    SSDATA (text), SSDATA (path),
    FIXNUMP (target) ? (gsize) XFIXNUM (target) : 0,
    FIXNUMP (overlap) ? (gsize) XFIXNUM (overlap) : 0);

  /* Built back to front so the returned list is in document order. */
  for (i = chunks->len; i > 0; i--)
    {
      const CmacsBrigadeChunk *c = g_ptr_array_index (chunks, i - 1);
      out = Fcons (list (intern (":text"), build_string (c->text),
                         intern (":heading"), build_string (c->heading),
                         intern (":start"), make_fixnum ((EMACS_INT) c->byte_start),
                         intern (":length"), make_fixnum ((EMACS_INT) c->byte_len)),
                   out);
    }
  return out;
}

/* ── Index reading ────────────────────────────────────────────────── */

DEFUN ("cmacs-brigade-index-open", Fcmacs_brigade_index_open,
       Scmacs_brigade_index_open, 1, 1, 0,
       doc: /* Open the memory index in DIR and return a handle.

Signals if the index is absent, truncated, or written by a different
format version.  Refusing is deliberate: a header read as vectors is not
an error, it is silently wrong answers.  */)
  (Lisp_Object dir)
{
  g_autoptr (GError) err = NULL;
  CmacsBrigadeIndex *ix;

  CHECK_STRING (dir);
  mem_registry_init ();

  ix = cmacs_brigade_index_open (SSDATA (dir), &err);
  if (ix == NULL)
    error ("cmacs-brigade: %s", err ? err->message : "cannot open index");

  return make_uint (mem_put (cmacs_brigade__indexes, ix));
}

DEFUN ("cmacs-brigade-index-close", Fcmacs_brigade_index_close,
       Scmacs_brigade_index_close, 1, 1, 0,
       doc: /* Close the index HANDLE and release its mapping.  */)
  (Lisp_Object handle)
{
  gboolean removed;

  CHECK_FIXNAT (handle);
  mem_registry_init ();
  g_mutex_lock (&cmacs_brigade__mem_mutex);
  removed = g_hash_table_remove (cmacs_brigade__indexes,
                                 GUINT_TO_POINTER (XFIXNUM (handle)));
  g_mutex_unlock (&cmacs_brigade__mem_mutex);
  return removed ? Qt : Qnil;
}

DEFUN ("cmacs-brigade-index-info", Fcmacs_brigade_index_info,
       Scmacs_brigade_index_info, 1, 1, 0,
       doc: /* Return a plist describing the index HANDLE.

Keys are :count, :dim and :f16c.  The last reports whether the scan is
using the F16C instructions or the scalar table; both produce the same
ranking, so it is a performance fact rather than a correctness one.  */)
  (Lisp_Object handle)
{
  CmacsBrigadeIndex *ix = mem_get (cmacs_brigade__indexes, handle);

  if (ix == NULL) error ("cmacs-brigade: bad index handle");

  return list (intern (":count"),
               make_fixnum ((EMACS_INT) cmacs_brigade_index_count (ix)),
               intern (":dim"),
               make_fixnum ((EMACS_INT) cmacs_brigade_index_dim (ix)),
               intern (":f16c"),
               cmacs_brigade_index_using_f16c () ? Qt : Qnil);
}

DEFUN ("cmacs-brigade-index-search", Fcmacs_brigade_index_search,
       Scmacs_brigade_index_search, 3, 3, 0,
       doc: /* Search index HANDLE for the K rows closest to QUERY.

QUERY is a vector or list of numbers with the index's dimensionality.
Returns a list of (ID . SCORE) pairs, best first, where ID is the row
number the caller resolves against its own metadata.

The scan is exhaustive.  At this corpus size it is bounded by memory
bandwidth rather than arithmetic, so an approximate structure would
trade recall for single-digit milliseconds.  */)
  (Lisp_Object handle, Lisp_Object query, Lisp_Object k)
{
  CmacsBrigadeIndex *ix = mem_get (cmacs_brigade__indexes, handle);
  g_autofree float *q = NULL;
  g_autofree guint32 *ids = NULL;
  g_autofree float *scores = NULL;
  guint32 dim, i;
  guint want, got;
  Lisp_Object out = Qnil;

  if (ix == NULL) error ("cmacs-brigade: bad index handle");
  CHECK_FIXNAT (k);

  dim = cmacs_brigade_index_dim (ix);
  want = (guint) XFIXNUM (k);
  if (want == 0) return Qnil;

  /* Accept either a vector or a list; callers building a query by hand
     naturally produce a list, while the embedder returns a vector. */
  if (VECTORP (query))
    {
      if (ASIZE (query) != (ptrdiff_t) dim)
        error ("cmacs-brigade: query has %"pD"d dims, index has %u",
               ASIZE (query), dim);
      q = g_new (float, dim);
      for (i = 0; i < dim; i++)
        q[i] = (float) XFLOATINT (AREF (query, i));
    }
  else
    {
      Lisp_Object tail = query;
      if (list_length (query) != (ptrdiff_t) dim)
        error ("cmacs-brigade: query has %"pD"d dims, index has %u",
               list_length (query), dim);
      q = g_new (float, dim);
      for (i = 0; i < dim; i++, tail = XCDR (tail))
        q[i] = (float) XFLOATINT (XCAR (tail));
    }

  /* Normalise the query so the stored rows (already unit vectors) turn
     the dot product straight into a cosine. */
  {
    double norm = 0.0;
    for (i = 0; i < dim; i++) norm += (double) q[i] * (double) q[i];
    norm = norm > 1e-12 ? sqrt (norm) : 1.0;
    for (i = 0; i < dim; i++) q[i] = (float) ((double) q[i] / norm);
  }

  ids    = g_new0 (guint32, want);
  scores = g_new0 (float, want);
  got = cmacs_brigade_index_search (ix, q, want, ids, scores);

  for (i = got; i > 0; i--)
    out = Fcons (Fcons (make_fixnum (ids[i - 1]),
                        make_float (scores[i - 1])),
                 out);
  return out;
}

/* ── Index writing ────────────────────────────────────────────────── */

DEFUN ("cmacs-brigade-index-writer-new", Fcmacs_brigade_index_writer_new,
       Scmacs_brigade_index_writer_new, 2, 2, 0,
       doc: /* Begin writing a memory index of DIM dimensions into DIR.

Returns a writer handle.  The index is written to a temporary and only
renamed into place at commit, so a reader never observes a half-built
index and an interrupted build leaves the previous one intact.

Signals if another cmacs already holds the build lock on DIR.  */)
  (Lisp_Object dir, Lisp_Object dim)
{
  g_autoptr (GError) err = NULL;
  CmacsBrigadeIndexWriter *w;

  CHECK_STRING (dir);
  CHECK_FIXNAT (dim);
  mem_registry_init ();

  w = cmacs_brigade_index_writer_new (SSDATA (dir), (guint32) XFIXNUM (dim),
                                      &err);
  if (w == NULL)
    error ("cmacs-brigade: %s", err ? err->message : "cannot open writer");

  return make_uint (mem_put (cmacs_brigade__writers, w));
}

DEFUN ("cmacs-brigade-index-writer-add", Fcmacs_brigade_index_writer_add,
       Scmacs_brigade_index_writer_add, 2, 2, 0,
       doc: /* Append VECTOR to the index being written by HANDLE.

VECTOR is a vector or list of numbers.  It is L2-normalised and stored as
fp16, which is why a query later needs only a dot product.  */)
  (Lisp_Object handle, Lisp_Object vector)
{
  CmacsBrigadeIndexWriter *w = mem_get (cmacs_brigade__writers, handle);
  g_autofree float *v = NULL;
  ptrdiff_t n, i;

  if (w == NULL) error ("cmacs-brigade: bad writer handle");

  if (VECTORP (vector))
    {
      n = ASIZE (vector);
      v = g_new (float, n);
      for (i = 0; i < n; i++) v[i] = (float) XFLOATINT (AREF (vector, i));
    }
  else
    {
      Lisp_Object tail = vector;
      n = list_length (vector);
      v = g_new (float, n);
      for (i = 0; i < n; i++, tail = XCDR (tail))
        v[i] = (float) XFLOATINT (XCAR (tail));
    }

  if (!cmacs_brigade_index_writer_add (w, v, (guint32) n))
    error ("cmacs-brigade: vector has %"pD"d dims, index expects another", n);

  return make_fixnum ((EMACS_INT) cmacs_brigade_index_writer_count (w));
}

DEFUN ("cmacs-brigade-index-writer-commit",
       Fcmacs_brigade_index_writer_commit,
       Scmacs_brigade_index_writer_commit, 1, 1, 0,
       doc: /* Finish the index being written by HANDLE and publish it.

Patches the final count into the header, fsyncs, then renames over the
live index.  The writer handle is released.  */)
  (Lisp_Object handle)
{
  CmacsBrigadeIndexWriter *w = mem_get (cmacs_brigade__writers, handle);
  g_autoptr (GError) err = NULL;
  EMACS_INT n;
  gboolean ok;

  if (w == NULL) error ("cmacs-brigade: bad writer handle");

  n = (EMACS_INT) cmacs_brigade_index_writer_count (w);
  ok = cmacs_brigade_index_writer_commit (w, &err);

  g_mutex_lock (&cmacs_brigade__mem_mutex);
  g_hash_table_remove (cmacs_brigade__writers,
                       GUINT_TO_POINTER (XFIXNUM (handle)));
  g_mutex_unlock (&cmacs_brigade__mem_mutex);

  if (!ok) error ("cmacs-brigade: %s", err ? err->message : "commit failed");
  return make_fixnum (n);
}

DEFUN ("cmacs-brigade-index-writer-abort",
       Fcmacs_brigade_index_writer_abort,
       Scmacs_brigade_index_writer_abort, 1, 1, 0,
       doc: /* Discard the partial index being written by HANDLE.

The live index is untouched, which is what makes an interrupted build
safe to abandon.  */)
  (Lisp_Object handle)
{
  gboolean removed;

  CHECK_FIXNAT (handle);
  mem_registry_init ();
  g_mutex_lock (&cmacs_brigade__mem_mutex);
  removed = g_hash_table_remove (cmacs_brigade__writers,
                                 GUINT_TO_POINTER (XFIXNUM (handle)));
  g_mutex_unlock (&cmacs_brigade__mem_mutex);
  return removed ? Qt : Qnil;
}

void syms_of_cmacs_ai_brigade_memory (void);
void
syms_of_cmacs_ai_brigade_memory (void)
{
  defsubr (&Scmacs_brigade_chunk_string);
  defsubr (&Scmacs_brigade_index_open);
  defsubr (&Scmacs_brigade_index_close);
  defsubr (&Scmacs_brigade_index_info);
  defsubr (&Scmacs_brigade_index_search);
  defsubr (&Scmacs_brigade_index_writer_new);
  defsubr (&Scmacs_brigade_index_writer_add);
  defsubr (&Scmacs_brigade_index_writer_commit);
  defsubr (&Scmacs_brigade_index_writer_abort);
}

#endif /* HAVE_CMACS_AI_BRIGADE */
