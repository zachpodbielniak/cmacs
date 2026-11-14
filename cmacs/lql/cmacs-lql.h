/* cmacs-lql.h --- LQL query language subsystem

Copyright (C) 2026 Zach Podbielniak

This file is part of CMacs.

CMacs is free software: you can redistribute it and/or modify it under
the terms of the GNU Affero General Public License as published by the
Free Software Foundation, either version 3 of the License, or (at your
option) any later version.

CMacs is distributed in the hope that it will be useful, but WITHOUT ANY
WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS
FOR A PARTICULAR PURPOSE.  See the GNU Affero General Public License for
more details.

You should have received a copy of the GNU Affero General Public License
along with CMacs.  If not, see <https://www.gnu.org/licenses/>.

SPDX-License-Identifier: AGPL-3.0-or-later

   The subsystem links libre-query-language (deps/libre-query-language):
   liblql-1.0.a, the language, and liblql-tools.a, the sources the `lql'
   program offers (files of every format, git, exec, the journal,
   coredumps, Kubernetes, SQL).  On top of those it registers the sources
   Elisp defines -- buffers, windows, processes, org headings, anything a
   user adds with `cmacs-lql-define-source'.

   Three translation units, split the dbexplorer way:

   - cmacs-lql-env.c owns the one LqlEnvironment.  It includes <lql.h>
     and never lisp.h, so it compiles and links without a Lisp VM.  Every
     function in it is safe to call from any thread; the environment is
     guarded by one mutex (see below).

   - cmacs-lql-defuns.c is the Lisp half: the DEFUNs, the job registry
     and the single worker thread queries run on.  It never includes
     <lql.h>.  Only C strings cross between the two -- JSON in, JSON out.

   - cmacs-lql-init.c aggregates the syms_of_ hooks.

   Threading.  A query can take seconds (a git log, a journal, a remote
   SQL server), so it never runs on the editor's thread: a one-thread
   pool runs queries one at a time, each with a private thread-default
   GMainContext.  Editor state is never read from that thread.  Lisp
   snapshots the Elisp-defined sources a query names into JSON *before*
   submitting it, and the worker installs those snapshots as memory-source
   tables while it holds the environment lock.

   The editor-side helpers (completion, hover, diagnostics, describe,
   explain, format) must never wait for a running query -- a frozen
   minibuffer is worse than a missing candidate -- so they TRY the lock
   and report "busy" instead of blocking.  Source definitions made while
   the lock is held are queued and applied by whoever takes it next.  */

#ifndef CMACS_LQL_H
#define CMACS_LQL_H

#include <glib.h>
#include <gio/gio.h>

G_BEGIN_DECLS

/* Result of an editor-side helper: OK, BUSY (a query holds the
   environment; try again shortly) or ERROR (*error set).  */
typedef enum
{
  CMACS_LQL_OK = 0,
  CMACS_LQL_BUSY,
  CMACS_LQL_ERROR
} CmacsLqlStatus;

/* One Elisp-defined source snapshot handed to a run: NAME's rows as a
   JSON array of objects.  */
typedef struct
{
  gchar *name;
  gchar *rows_json;
} CmacsLqlSnapshot;

/* The outcome of one query run (cmacs_lql_env_run).  */
typedef struct
{
  gchar  *json;         /* {"columns":[{name,type}],"rows":[[..]],"total":N} */
  gchar  *text;         /* the table as aligned text, when asked for */
  guint   n_rows;       /* rows the query produced (before truncation) */
  gint64  elapsed_us;
} CmacsLqlResult;

/* Environment (cmacs-lql-env.c).  */

extern gboolean cmacs_lql_env_ensure (GError **error);

extern void cmacs_lql_env_define_source (const gchar *name,
                                         const gchar *columns_json,
                                         const gchar *description);

extern gboolean cmacs_lql_env_run (const gchar *text,
                                   GPtrArray *snapshots,
                                   guint max_rows,
                                   guint text_width,
                                   gint64 timeout_ms,
                                   GCancellable *cancellable,
                                   CmacsLqlResult *out,
                                   GError **error);

extern void cmacs_lql_result_clear (CmacsLqlResult *result);

extern void cmacs_lql_snapshot_free (gpointer data);

extern CmacsLqlStatus cmacs_lql_env_describe (gchar **out_json,
                                              GError **error);

extern CmacsLqlStatus cmacs_lql_env_complete (const gchar *text,
                                              guint offset,
                                              gchar **out_json);

extern CmacsLqlStatus cmacs_lql_env_hover (const gchar *text,
                                           guint offset,
                                           gchar **out_json);

extern CmacsLqlStatus cmacs_lql_env_signature (const gchar *text,
                                               guint offset,
                                               gchar **out_json);

extern CmacsLqlStatus cmacs_lql_env_diagnose (const gchar *text,
                                              gchar **out_json);

extern CmacsLqlStatus cmacs_lql_env_explain (const gchar *text,
                                             gchar **out_text,
                                             GError **error);

extern CmacsLqlStatus cmacs_lql_env_format (const gchar *text,
                                            guint width,
                                            gchar **out_text,
                                            GError **error);

extern gchar **cmacs_lql_env_list_sources (void);

extern const gchar *cmacs_lql_version (void);

/* Per-TU registration hooks, called by cmacs-lql-init.c.
   syms_of_cmacs_lql / init_cmacs_lql themselves live in src/lisp.h.  */
extern void syms_of_cmacs_lql_defuns (void);

G_END_DECLS

#endif /* CMACS_LQL_H */
