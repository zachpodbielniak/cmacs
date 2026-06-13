/* cmacs-cad-doc.c --- CAD document registry + async evaluation.
 *
 * Copyright (C) 2026 Zach Podbielniak
 * SPDX-License-Identifier: AGPL-3.0-or-later
 *
 * The render half of the firewall: this file talks to cad-glib (and
 * exposes a plain-C surface to cmacs-cad-defuns.c), never to pgtk
 * internals.  Documents are keyed by absolute path through the
 * libregnum CAD manager so the editor's CAD_PART nodes and the .cad
 * buffer workflow share one cache.
 *
 * Async evaluation runs cad-glib's GTask worker; completion lands on
 * the cmacs GMainContext and invokes a GC-rooted Lisp callback via
 * the dispatch-cookie machinery (the piper pattern: never stash a
 * bare Lisp_Object in C heap memory).
 */

#include <config.h>

#ifdef HAVE_CMACS_CAD

#include "lisp.h"
#include "cmacs-cad.h"
#include "../glib/cmacs-eval-dispatch.h"

#include <cad-glib.h>
#include <string.h>

/* Per-document bookkeeping beyond what cad-glib stores: a generation
 * counter so stale async completions are discarded. */
typedef struct
{
  CadDocument *document;        /* ref */
  guint64 generation;
} CmacsCadEntry;

static GHashTable *cmacs_cad_docs;   /* abs path -> CmacsCadEntry* */

static void
cmacs_cad_entry_free (gpointer data)
{
  CmacsCadEntry *entry = data;

  g_clear_object (&entry->document);
  g_free (entry);
}

static void
cmacs_cad_ensure_frontends (void)
{
  cad_frontend_sexp_get_default ();
#ifdef CAD_HAVE_CRISPY
  cad_frontend_crispy_get_default ();
#endif
}

static GHashTable *
cmacs_cad_docs_table (void)
{
  if (cmacs_cad_docs == NULL)
    cmacs_cad_docs = g_hash_table_new_full (g_str_hash, g_str_equal,
                                            g_free, cmacs_cad_entry_free);

  return cmacs_cad_docs;
}

/* Returns the entry for PATH, creating (and parsing) on demand. */
static CmacsCadEntry *
cmacs_cad_entry_for (const char *path,
                     GError **error)
{
  GHashTable *table = cmacs_cad_docs_table ();
  char *abs_path;
  CmacsCadEntry *entry;
  CadDocument *document;

  cmacs_cad_ensure_frontends ();

  abs_path = g_canonicalize_filename (path, NULL);
  entry = g_hash_table_lookup (table, abs_path);
  if (entry != NULL)
    {
      g_free (abs_path);
      return entry;
    }

  document = cad_document_new_from_file (abs_path, error);
  if (document == NULL)
    {
      g_free (abs_path);
      return NULL;
    }

  entry = g_new0 (CmacsCadEntry, 1);
  entry->document = document;
  g_hash_table_replace (table, abs_path, entry);

  return entry;
}

/* ---- plain-C surface for the defuns ---- */

CadDocument *cmacs_cad_doc_open (const char *path, GError **error);
gboolean cmacs_cad_doc_close (const char *path);
CadDocument *cmacs_cad_doc_peek (const char *path);
gboolean cmacs_cad_doc_set_source (const char *path, const char *source,
                                   GError **error);
void cmacs_cad_doc_eval_async (const char *path, GHashTable *overrides,
                               uint64_t cookie);
guint64 cmacs_cad_doc_generation (const char *path);

CadDocument *
cmacs_cad_doc_open (const char *path,
                    GError **error)
{
  CmacsCadEntry *entry = cmacs_cad_entry_for (path, error);

  return entry != NULL ? entry->document : NULL;
}

gboolean
cmacs_cad_doc_close (const char *path)
{
  char *abs_path;
  gboolean removed;

  if (cmacs_cad_docs == NULL)
    return false;

  abs_path = g_canonicalize_filename (path, NULL);
  removed = g_hash_table_remove (cmacs_cad_docs, abs_path);
  g_free (abs_path);

  return removed;
}

CadDocument *
cmacs_cad_doc_peek (const char *path)
{
  CmacsCadEntry *entry;
  char *abs_path;

  if (cmacs_cad_docs == NULL)
    return NULL;

  abs_path = g_canonicalize_filename (path, NULL);
  entry = g_hash_table_lookup (cmacs_cad_docs, abs_path);
  g_free (abs_path);

  return entry != NULL ? entry->document : NULL;
}

gboolean
cmacs_cad_doc_set_source (const char *path,
                          const char *source,
                          GError **error)
{
  CmacsCadEntry *entry = cmacs_cad_entry_for (path, error);

  if (entry == NULL)
    return false;

  cad_document_set_source (entry->document, source);
  entry->generation++;

  return true;
}

guint64
cmacs_cad_doc_generation (const char *path)
{
  CmacsCadEntry *entry;
  char *abs_path;
  guint64 generation = 0;

  if (cmacs_cad_docs == NULL)
    return 0;

  abs_path = g_canonicalize_filename (path, NULL);
  entry = g_hash_table_lookup (cmacs_cad_docs, abs_path);
  g_free (abs_path);
  if (entry != NULL)
    generation = entry->generation;

  return generation;
}

/* ---- async evaluation ---- */

typedef struct
{
  uint64_t cookie;              /* GC-rooted Lisp callback */
  guint64 generation;           /* doc generation at submit time */
  char *abs_path;
  GHashTable *overrides;        /* nullable, owned */
} CmacsCadEvalJob;

static void
cmacs_cad_eval_job_free (CmacsCadEvalJob *job)
{
  g_free (job->abs_path);
  if (job->overrides != NULL)
    g_hash_table_unref (job->overrides);
  g_free (job);
}

/* Runs on the cmacs GMainContext (GTask completion). */
static void
cmacs_cad_eval_done (GObject *source,
                     GAsyncResult *result,
                     gpointer user_data)
{
  CmacsCadEvalJob *job = user_data;
  CadDocument *document = CAD_DOCUMENT (source);
  GError *error = NULL;
  gboolean ok;
  Lisp_Object payload;

  ok = cad_document_eval_finish (document, result, &error);

  /* Discard stale completions: the document changed under us. */
  if (cmacs_cad_doc_generation (job->abs_path) != job->generation)
    {
      g_clear_error (&error);
      cmacs_cad_eval_job_free (job);
      return;
    }

  if (ok)
    payload = list2 (QCok, Qt);
  else
    {
      payload = list2 (QCerror,
                       build_string (error != NULL ? error->message
                                                   : "unknown error"));
      g_clear_error (&error);
    }

  cmacs_dispatch_callback_invoke1 (job->cookie, payload);
  cmacs_cad_eval_job_free (job);
}

void
cmacs_cad_doc_eval_async (const char *path,
                          GHashTable *overrides,
                          uint64_t cookie)
{
  GError *error = NULL;
  CmacsCadEntry *entry = cmacs_cad_entry_for (path, &error);
  CmacsCadEvalJob *job;

  if (entry == NULL)
    {
      Lisp_Object payload =
        list2 (QCerror,
               build_string (error != NULL ? error->message
                                           : "unknown error"));

      g_clear_error (&error);
      cmacs_dispatch_callback_invoke1 (cookie, payload);
      return;
    }

  job = g_new0 (CmacsCadEvalJob, 1);
  job->cookie = cookie;
  job->generation = entry->generation;
  job->abs_path = g_canonicalize_filename (path, NULL);
  job->overrides = overrides != NULL ? g_hash_table_ref (overrides) : NULL;

  cad_document_eval_async (entry->document, overrides, NULL,
                           cmacs_cad_eval_done, job);
}

#endif /* HAVE_CMACS_CAD */
