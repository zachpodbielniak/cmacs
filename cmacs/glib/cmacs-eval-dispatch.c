/*
 * Copyright (C) 2026 Zach Podbielniak
 * SPDX-License-Identifier: AGPL-3.0-or-later
 */

/* cmacs-eval-dispatch.c — shared dispatch for CMacs eval operations
 *
 * Transport-agnostic dispatch: the D-Bus service and socketpair IPC
 * handler both call these functions.  They run on the Emacs main
 * thread via the CMacs GMainContext.
 */

#include <config.h>

#ifdef HAVE_CMACS_GLIB

#include "lisp.h"
#include "keyboard.h"
#include "cmacs-eval-dispatch.h"

#include <glib.h>
#include <stdatomic.h>
#include <stdint.h>
#include <string.h>

/* ── waiting_for_input guard + safe_calln wrappers ─────────────────────
 *
 * See the long comment in dispatch_safe_eval below for the why.  These
 * helpers are the public API for any GLib callback that needs to
 * invoke Lisp.  They mirror safe_calln but clear waiting_for_input
 * around the call so signals stay inside the condition-case. */

void
cmacs_dispatch_safe_callN (Lisp_Object fn, ptrdiff_t nargs,
                           Lisp_Object *args)
{
  if (NILP (fn))
    return;
  /* Build a single-argument-vector layout for safe_funcall: [fn, a0, ...].
   * Stack-allocate for the common small-N case; spill to malloc for
   * pathologically large N.  Most call sites are <= 4 args. */
  enum { STK_MAX = 8 };
  Lisp_Object stkbuf[STK_MAX + 1];
  Lisp_Object *full =
    nargs + 1 <= STK_MAX + 1 ? stkbuf : xmalloc ((nargs + 1) * sizeof (Lisp_Object));
  full[0] = fn;
  if (nargs > 0)
    memcpy (full + 1, args, nargs * sizeof (Lisp_Object));
  bool was_waiting = waiting_for_input;
  if (was_waiting)
    clear_waiting_for_input ();
  safe_funcall (nargs + 1, full);
  if (was_waiting)
    set_waiting_for_input (input_available_clear_time);
  if (full != stkbuf)
    xfree (full);
}

void
cmacs_dispatch_safe_call1 (Lisp_Object fn, Lisp_Object a1)
{
  Lisp_Object args[1] = { a1 };
  cmacs_dispatch_safe_callN (fn, 1, args);
}

void
cmacs_dispatch_safe_call2 (Lisp_Object fn, Lisp_Object a1, Lisp_Object a2)
{
  Lisp_Object args[2] = { a1, a2 };
  cmacs_dispatch_safe_callN (fn, 2, args);
}

void
cmacs_dispatch_safe_call3 (Lisp_Object fn, Lisp_Object a1,
                           Lisp_Object a2, Lisp_Object a3)
{
  Lisp_Object args[3] = { a1, a2, a3 };
  cmacs_dispatch_safe_callN (fn, 3, args);
}

/* ── One-shot callback registry ──────────────────────────────────────── */

static Lisp_Object cmacs_dispatch__cb_table;
static gboolean    cmacs_dispatch__cb_table_init;
static _Atomic uint64_t cmacs_dispatch__next_cookie = 1;

static void
cb_table_ensure (void)
{
  if (cmacs_dispatch__cb_table_init)
    return;
  cmacs_dispatch__cb_table_init = TRUE;
  cmacs_dispatch__cb_table = CALLN (Fmake_hash_table, QCtest, Qeql);
  staticpro (&cmacs_dispatch__cb_table);
}

uint64_t
cmacs_dispatch_callback_register (Lisp_Object fn)
{
  if (NILP (fn))
    return 0;
  cb_table_ensure ();
  uint64_t cookie = atomic_fetch_add (&cmacs_dispatch__next_cookie, 1);
  Fputhash (make_uint (cookie), fn, cmacs_dispatch__cb_table);
  return cookie;
}

static Lisp_Object
cb_pop (uint64_t cookie)
{
  if (!cmacs_dispatch__cb_table_init || cookie == 0)
    return Qnil;
  Lisp_Object key = make_uint (cookie);
  Lisp_Object fn  = Fgethash (key, cmacs_dispatch__cb_table, Qnil);
  Fremhash (key, cmacs_dispatch__cb_table);
  return fn;
}

void
cmacs_dispatch_callback_invoke1 (uint64_t cookie, Lisp_Object a1)
{
  Lisp_Object fn = cb_pop (cookie);
  if (NILP (fn))
    return;
  cmacs_dispatch_safe_call1 (fn, a1);
}

void
cmacs_dispatch_callback_invokeN (uint64_t cookie, ptrdiff_t nargs,
                                 Lisp_Object *args)
{
  Lisp_Object fn = cb_pop (cookie);
  if (NILP (fn))
    return;
  cmacs_dispatch_safe_callN (fn, nargs, args);
}

void
cmacs_dispatch_callback_drop (uint64_t cookie)
{
  (void) cb_pop (cookie);
}

/* ── Safe evaluation helpers ───────────────────────────────────────── */

static Lisp_Object
dispatch_eval_body (Lisp_Object form)
{
  return Feval (form, Qnil);
}

static Lisp_Object
dispatch_eval_error (Lisp_Object err)
{
  return Fcons (Qerror, Ferror_message_string (err));
}

/* Guarded wrapper around internal_condition_case_1.
 *
 * GLib callbacks that come through cmacs_dispatch_* may run while the
 * main thread is inside read_char / sit_for with `waiting_for_input'
 * set to true (e.g. the MCP server's GIO sources are attached to the
 * default GMainContext dispatched from `xg_select`, which does *not*
 * go through `cmacs_glib_dispatch` and therefore does not clear the
 * flag).  If a Lisp error is signaled from that state, signal_or_quit
 * hits its "impossible" branch and calls emacs_abort before
 * internal_condition_case_1 ever sees the signal -- aborting the
 * whole emacs process on what should be a recoverable error.
 *
 * Temporarily clearing waiting_for_input mirrors the guard in
 * cmacs_glib_dispatch (cmacs-glib-loop.c) and keeps signals inside
 * the condition-case where they belong. */
static Lisp_Object
dispatch_safe_eval (Lisp_Object form)
{
  Lisp_Object result;
  bool was_waiting = waiting_for_input;
  if (was_waiting)
    clear_waiting_for_input ();
  result = internal_condition_case_1 (dispatch_eval_body, form,
                                      Qt, dispatch_eval_error);
  if (was_waiting)
    set_waiting_for_input (input_available_clear_time);
  return result;
}

static gboolean
dispatch_result_is_error (Lisp_Object result)
{
  return CONSP (result) && EQ (XCAR (result), Qerror);
}

#define CMACS_DISPATCH_ERROR_DOMAIN (g_quark_from_static_string ("cmacs-dispatch"))

/* ── Public API ────────────────────────────────────────────────────── */

gchar *
cmacs_dispatch_eval (const gchar *expression, GError **error)
{
  Lisp_Object form, result, printed;

  form = Fcar (Fread_from_string (build_string (expression), Qnil, Qnil));
  result = dispatch_safe_eval (form);

  if (dispatch_result_is_error (result))
    {
      Lisp_Object msg = XCDR (result);
      g_set_error (error, CMACS_DISPATCH_ERROR_DOMAIN, 1,
                   "%s", STRINGP (msg) ? SSDATA (msg) : "unknown error");
      return NULL;
    }

  printed = Fprin1_to_string (result, Qnil, Qnil);
  return g_strdup (SSDATA (printed));
}

gchar *
cmacs_dispatch_eval_string (const gchar *expression, GError **error)
{
  Lisp_Object form, result, printed;

  form = Fcar (Fread_from_string (build_string (expression), Qnil, Qnil));
  result = dispatch_safe_eval (form);

  if (dispatch_result_is_error (result))
    {
      Lisp_Object msg = XCDR (result);
      g_set_error (error, CMACS_DISPATCH_ERROR_DOMAIN, 1,
                   "%s", STRINGP (msg) ? SSDATA (msg) : "unknown error");
      return NULL;
    }

  /* Strings are returned verbatim so callers get raw text; any other
     value type falls back to its printed representation. */
  if (STRINGP (result))
    return g_strdup (SSDATA (result));

  printed = Fprin1_to_string (result, Qnil, Qnil);
  return g_strdup (SSDATA (printed));
}

/* The org walker behind Edit.GetOrgContent and the MCP
   get_org_content tool.  Entirely org "porcelain" (org-map-entries,
   org-entry-get, org-collect-keywords), so it tracks org-mode's own
   notion of headlines, planning, and the agenda match syntax instead
   of reimplementing a parser.  The flat (LEVEL . ALIST) list is
   rebuilt into a nested tree, then json-encoded.  Runs under dynamic
   binding: the `build' lambda recurses via its dynamically bound
   name. */
static const gchar *org_content_template =
  "(with-current-buffer \"%s\""
  " (require 'org)"
  " (require 'json)"
  " (unless (derived-mode-p 'org-mode)"
  "   (error \"%%s is not an org-mode buffer\" (buffer-name)))"
  " (save-excursion"
  "  (save-restriction"
  "   (widen)"
  "   (let ((max-depth %d)"
  "         (include-body %s)"
  "         (include-props %s)"
  "         (entries nil))"
  "    (org-map-entries"
  "     (lambda ()"
  "      (let* ((comps (org-heading-components))"
  "             (level (nth 0 comps))"
  "             (todo (nth 2 comps))"
  "             (prio (nth 3 comps))"
  "             (title (or (nth 4 comps) \"\"))"
  "             (tags (mapcar #'substring-no-properties"
  "                           (org-get-tags nil t)))"
  "             (sched (org-entry-get nil \"SCHEDULED\"))"
  "             (deadl (org-entry-get nil \"DEADLINE\"))"
  "             (closed (org-entry-get nil \"CLOSED\"))"
  "             (props (and include-props"
  "                         (let (out)"
  "                          (dolist (kv (org-entry-properties"
  "                                       nil 'standard)"
  "                                      (nreverse out))"
  "                           (unless (or (equal (car kv) \"ITEM\")"
  "                                       (equal (car kv) \"FILE\")"
  "                                       (equal (car kv) \"BLOCKED\")"
  "                                       (and (equal (car kv)"
  "                                                   \"CATEGORY\")"
  "                                            (equal (cdr kv)"
  "                                                   \"???\")))"
  "                            (push kv out))))))"
  "             (body (and include-body"
  "                        (save-excursion"
  "                         (let ((limit (save-excursion"
  "                                       (outline-next-heading)"
  "                                       (point))))"
  "                          (org-end-of-meta-data t)"
  "                          (if (>= (point) limit) \"\""
  "                           (string-trim"
  "                            (buffer-substring-no-properties"
  "                             (point) limit))))))))"
  "       (when (or (= max-depth 0) (<= level max-depth))"
  "        (push (cons level"
  "                    (nconc"
  "                     (list (cons 'title"
  "                                 (substring-no-properties title))"
  "                           (cons 'level level))"
  "                     (and todo (list (cons 'todo"
  "                                           (substring-no-properties"
  "                                            todo))))"
  "                     (and prio (list (cons 'priority"
  "                                           (char-to-string prio))))"
  "                     (and tags (list (cons 'tags (vconcat tags))))"
  "                     (and sched (list (cons 'scheduled sched)))"
  "                     (and deadl (list (cons 'deadline deadl)))"
  "                     (and closed (list (cons 'closed closed)))"
  "                     (and props (list (cons 'properties props)))"
  "                     (and body (> (length body) 0)"
  "                          (list (cons 'body body)))))"
  "              entries))))"
  "     %s)"
  "    (setq entries (nreverse entries))"
  "    (let ((remaining entries)"
  "          (build nil))"
  "     (setq build"
  "           (lambda (parent-level)"
  "            (let (nodes)"
  "             (while (and remaining"
  "                         (> (car (car remaining)) parent-level))"
  "              (let* ((e (pop remaining))"
  "                     (lvl (car e))"
  "                     (node (cdr e))"
  "                     (kids (funcall build lvl)))"
  "               (when kids"
  "                (setq node (nconc node"
  "                                  (list (cons 'children"
  "                                              (vconcat kids))))))"
  "               (push node nodes)))"
  "             (nreverse nodes))))"
  "     (let ((tree (funcall build 0))"
  "           (kw (org-collect-keywords"
  "                '(\"TITLE\" \"AUTHOR\" \"DATE\" \"FILETAGS\"))))"
  "      (json-encode"
  "       (nconc"
  "        (list (cons 'buffer (buffer-name)))"
  "        (and (buffer-file-name)"
  "             (list (cons 'file (buffer-file-name))))"
  "        (let ((v (cadr (assoc \"TITLE\" kw))))"
  "         (and v (list (cons 'title v))))"
  "        (let ((v (cadr (assoc \"AUTHOR\" kw))))"
  "         (and v (list (cons 'author v))))"
  "        (let ((v (cadr (assoc \"DATE\" kw))))"
  "         (and v (list (cons 'date v))))"
  "        (let ((v (cadr (assoc \"FILETAGS\" kw))))"
  "         (and v (list (cons 'filetags v))))"
  "        (list (cons 'headlines (vconcat tree)))))))))))";

gchar *
cmacs_dispatch_org_content (const gchar *buffer, const gchar *match,
                            gint max_depth, gboolean include_body,
                            gboolean include_properties,
                            GError **error)
{
  gchar *escaped_buffer;
  gchar *match_form;
  gchar *expr;
  gchar *result;

  escaped_buffer = g_strescape (buffer != NULL ? buffer : "", NULL);
  if (match != NULL && *match != '\0')
    {
      gchar *escaped_match = g_strescape (match, NULL);
      match_form = g_strdup_printf ("\"%s\"", escaped_match);
      g_free (escaped_match);
    }
  else
    match_form = g_strdup ("nil");

  expr = g_strdup_printf (org_content_template,
                          escaped_buffer,
                          max_depth > 0 ? max_depth : 0,
                          include_body ? "t" : "nil",
                          include_properties ? "t" : "nil",
                          match_form);
  g_free (escaped_buffer);
  g_free (match_form);

  result = cmacs_dispatch_eval_string (expr, error);
  g_free (expr);
  return result;
}

/* The org-aware insertion behind Edit.InsertOrg and the MCP
   insert_org tool.  Targeting uses org's own resolvers
   (org-find-exact-headline-in-buffer for a bare title anywhere,
   org-find-olp for slash paths); missing path components are created
   bottom-up when CREATE.  The child-heading star count derives from
   the live target level, which is why this runs in the editor rather
   than in the client.  %s placeholders are filled with g_strescape'd
   values; %% survives printf as a literal % for elisp format. */
static const gchar *org_insert_template =
  "(with-current-buffer (if (string= \"%s\" \"\")"
  "                         (current-buffer) \"%s\")"
  " (require 'org)"
  " (unless (derived-mode-p 'org-mode)"
  "   (error \"%%s is not an org-mode buffer\" (buffer-name)))"
  " (save-excursion"
  "  (let ((heading \"%s\")"
  "        (do-create %s)"
  "        (where \"%s\")"
  "        (wrap \"%s\")"
  "        (lang \"%s\")"
  "        (drawer \"%s\")"
  "        (child \"%s\")"
  "        (todo \"%s\")"
  "        (tags \"%s\")"
  "        (stamp %s)"
  "        (body (string-trim-right \"%s\" \"\\n+\"))"
  "        (target-level 0))"
  "   (if (string= heading \"\")"
  "       (cond ((string= where \"top\") (goto-char (point-min)))"
  "             ((string= where \"point\") nil)"
  "             (t (goto-char (point-max))))"
  "     (let* ((comps (split-string heading \"/\" t))"
  "            (m (or (and (= (length comps) 1)"
  "                        (org-find-exact-headline-in-buffer"
  "                         (car comps) (current-buffer)))"
  "                   (ignore-errors"
  "                    (org-find-olp comps (current-buffer))))))"
  "      (when (and (not m) (not do-create))"
  "        (error \"heading not found: %%s\" heading))"
  "      (unless m"
  "       (let ((k (1- (length comps))) (pm nil))"
  "        (while (and (> k 0)"
  "                    (not (setq pm (ignore-errors"
  "                                   (org-find-olp"
  "                                    (seq-take comps k)"
  "                                    (current-buffer))))))"
  "         (setq k (1- k)))"
  "        (if pm (progn (goto-char pm) (org-end-of-subtree t t))"
  "          (goto-char (point-max)))"
  "        (unless (bolp) (insert \"\\n\"))"
  "        (let ((lvl (1+ k)))"
  "         (dolist (c (seq-drop comps k))"
  "          (insert (make-string lvl ?*) \" \" c \"\\n\")"
  "          (setq lvl (1+ lvl))))"
  "        (setq m (org-find-olp comps (current-buffer)))))"
  "      (goto-char m)"
  "      (setq target-level (org-current-level))"
  "      (cond"
  "       ((string= where \"top\") (org-end-of-meta-data t))"
  "       ((string= where \"subtree-end\") (org-end-of-subtree t t))"
  "       (t"
  "        (let ((end (save-excursion (org-end-of-subtree t t)"
  "                                   (point))))"
  "         (org-end-of-meta-data t)"
  "         (if (re-search-forward org-heading-regexp end t)"
  "             (goto-char (match-beginning 0))"
  "           (goto-char end)))))))"
  "   (when stamp"
  "    (setq body (concat (format-time-string"
  "                        \"[%%Y-%%m-%%d %%a %%H:%%M]\")"
  "                       \"\\n\" body)))"
  "   (cond"
  "    ((string= wrap \"\") nil)"
  "    ((string= wrap \"src\")"
  "     (setq body (concat \"#+begin_src\""
  "                        (if (string= lang \"\") \"\""
  "                          (concat \" \" lang))"
  "                        \"\\n\" body \"\\n#+end_src\")))"
  "    (t"
  "     (setq body (concat \"#+begin_\" wrap \"\\n\" body"
  "                        \"\\n#+end_\" wrap))))"
  "   (unless (string= drawer \"\")"
  "    (setq body (concat \":\" (upcase drawer) \":\\n\" body"
  "                       \"\\n:END:\")))"
  "   (unless (string= child \"\")"
  "    (setq body (concat (make-string (1+ target-level) ?*) \" \""
  "                       (if (string= todo \"\") \"\""
  "                         (concat todo \" \"))"
  "                       child"
  "                       (if (string= tags \"\") \"\""
  "                         (concat \" :\" tags \":\"))"
  "                       \"\\n\" body)))"
  "   (unless (bolp) (insert \"\\n\"))"
  "   (insert body)"
  "   (unless (bolp) (insert \"\\n\"))"
  "   (format \"inserted %%d chars%%s\" (length body)"
  "           (if (string= heading \"\") \"\""
  "             (format \" under %%s\" heading))))))";

gchar *
cmacs_dispatch_org_insert (const gchar *buffer, const gchar *text,
                           const gchar *heading, const gchar *position,
                           const gchar *wrap, const gchar *lang,
                           const gchar *drawer, const gchar *child,
                           const gchar *todo, const gchar *tags,
                           gboolean create, gboolean timestamp,
                           GError **error)
{
  gchar *e_buffer, *e_heading, *e_position, *e_wrap, *e_lang;
  gchar *e_drawer, *e_child, *e_todo, *e_tags, *e_text;
  gchar *expr;
  gchar *result;

  e_buffer = g_strescape (buffer != NULL ? buffer : "", NULL);
  e_heading = g_strescape (heading != NULL ? heading : "", NULL);
  e_position = g_strescape (position != NULL ? position : "", NULL);
  e_wrap = g_strescape (wrap != NULL ? wrap : "", NULL);
  e_lang = g_strescape (lang != NULL ? lang : "", NULL);
  e_drawer = g_strescape (drawer != NULL ? drawer : "", NULL);
  e_child = g_strescape (child != NULL ? child : "", NULL);
  e_todo = g_strescape (todo != NULL ? todo : "", NULL);
  e_tags = g_strescape (tags != NULL ? tags : "", NULL);
  e_text = g_strescape (text != NULL ? text : "", NULL);

  expr = g_strdup_printf (org_insert_template,
                          e_buffer, e_buffer,
                          e_heading,
                          create ? "t" : "nil",
                          e_position,
                          e_wrap, e_lang, e_drawer,
                          e_child, e_todo, e_tags,
                          timestamp ? "t" : "nil",
                          e_text);
  g_free (e_buffer);
  g_free (e_heading);
  g_free (e_position);
  g_free (e_wrap);
  g_free (e_lang);
  g_free (e_drawer);
  g_free (e_child);
  g_free (e_todo);
  g_free (e_tags);
  g_free (e_text);

  result = cmacs_dispatch_eval_string (expr, error);
  g_free (expr);
  return result;
}

/* Same waiting_for_input guard as dispatch_safe_eval -- see the
   comment there.  safe_calln's internal condition-case is still
   entered too late to catch an error signaled while
   waiting_for_input is set. */
#define DISPATCH_WITH_INPUT_GUARD(body)                         \
  do {                                                          \
    bool _was_waiting = waiting_for_input;                      \
    if (_was_waiting)                                           \
      clear_waiting_for_input ();                               \
    body;                                                       \
    if (_was_waiting)                                           \
      set_waiting_for_input (input_available_clear_time);       \
  } while (0)

void
cmacs_dispatch_find_file (const gchar *path)
{
  DISPATCH_WITH_INPUT_GUARD (
    safe_calln (intern ("find-file"), build_string (path)));
}

void
cmacs_dispatch_message (const gchar *text)
{
  DISPATCH_WITH_INPUT_GUARD (
    safe_calln (intern ("message"), build_string (text)));
}

gboolean
cmacs_dispatch_gi_require (const gchar *ns, const gchar *ver,
                           GError **error)
{
  Lisp_Object form, result;

  form = list3 (intern ("gi-require"),
                build_string (ns), build_string (ver));
  result = dispatch_safe_eval (form);

  if (dispatch_result_is_error (result))
    {
      Lisp_Object msg = XCDR (result);
      g_set_error (error, CMACS_DISPATCH_ERROR_DOMAIN, 1,
                   "%s", STRINGP (msg) ? SSDATA (msg) : "unknown error");
      return FALSE;
    }

  return !NILP (result);
}

gchar *
cmacs_dispatch_gi_call (const gchar *ns, const gchar *func,
                        const gchar *const *args, gint n_args,
                        GError **error)
{
  Lisp_Object args_list, form, result, printed;
  gint i;

  /* Build args list from strings, reading each as a Lisp expression. */
  args_list = Qnil;
  for (i = n_args - 1; i >= 0; i--)
    {
      Lisp_Object parsed =
        Fcar (Fread_from_string (build_string (args[i]), Qnil, Qnil));
      args_list = Fcons (parsed, args_list);
    }

  /* Build: (gi-call "NS" "func" arg1 arg2 ...) */
  form = Fcons (intern ("gi-call"),
                Fcons (build_string (ns),
                       Fcons (build_string (func), args_list)));
  result = dispatch_safe_eval (form);

  if (dispatch_result_is_error (result))
    {
      Lisp_Object msg = XCDR (result);
      g_set_error (error, CMACS_DISPATCH_ERROR_DOMAIN, 1,
                   "%s", STRINGP (msg) ? SSDATA (msg) : "unknown error");
      return NULL;
    }

  printed = Fprin1_to_string (result, Qnil, Qnil);
  return g_strdup (SSDATA (printed));
}

gchar **
cmacs_dispatch_gi_list_functions (const gchar *ns)
{
  Lisp_Object form, result, tail;
  GPtrArray *arr;

  form = list2 (intern ("gi-list-functions"), build_string (ns));
  result = dispatch_safe_eval (form);

  arr = g_ptr_array_new ();
  if (!dispatch_result_is_error (result))
    {
      tail = result;
      while (CONSP (tail))
        {
          Lisp_Object s = XCAR (tail);
          if (STRINGP (s))
            g_ptr_array_add (arr, g_strdup (SSDATA (s)));
          tail = XCDR (tail);
        }
    }
  g_ptr_array_add (arr, NULL);
  return (gchar **)g_ptr_array_free (arr, FALSE);
}

/* ── Gowl dispatch (direct C API, no elisp round-trip) ────────────── */

#ifdef HAVE_CMACS_GOWL

/* gowl.h and extern cmacs_gowl_compositor provided by cmacs-eval-dispatch.h */

#define GOWL_DISPATCH_CHECK()                                       \
  do { if (cmacs_gowl_compositor == NULL) {                         \
    g_set_error (error, CMACS_DISPATCH_ERROR_DOMAIN, 1,             \
                 "Gowl compositor not running");                    \
    return NULL;                                                    \
  }} while (0)

/* Resolve a monitor by output name. */
static GowlMonitor *
dispatch_resolve_monitor (const gchar *name, GError **error)
{
  GList *monitors, *l;
  monitors = gowl_compositor_get_monitors (cmacs_gowl_compositor);
  for (l = monitors; l != NULL; l = l->next)
    {
      GowlMonitor *m = GOWL_MONITOR (l->data);
      if (g_strcmp0 (gowl_monitor_get_name (m), name) == 0)
        return m;
    }
  g_set_error (error, CMACS_DISPATCH_ERROR_DOMAIN, 1,
               "No monitor named \"%s\"", name);
  return NULL;
}

gchar *
cmacs_dispatch_gowl_list_clients (GError **error)
{
  GList *clients, *l;
  GString *buf;

  GOWL_DISPATCH_CHECK ();

  buf = g_string_new ("[");
  clients = gowl_compositor_get_clients (cmacs_gowl_compositor);
  for (l = clients; l != NULL; l = l->next)
    {
      GowlClient *c = GOWL_CLIENT (l->data);
      gint x, y, w, h;
      gowl_client_get_geometry (c, &x, &y, &w, &h);

      if (l != clients) g_string_append_c (buf, ',');
      g_string_append_printf (buf,
        "{\"id\":%u,\"title\":\"%s\",\"app-id\":\"%s\","
        "\"tags\":%u,\"floating\":%s,\"fullscreen\":%s,"
        "\"pid\":%d,\"geometry\":[%d,%d,%d,%d]}",
        gowl_client_get_id (c),
        gowl_client_get_title (c) ? : "",
        gowl_client_get_app_id (c) ? : "",
        (guint)gowl_client_get_tags (c),
        gowl_client_get_floating (c) ? "true" : "false",
        gowl_client_get_fullscreen (c) ? "true" : "false",
        (int)gowl_client_get_pid (c),
        x, y, w, h);
    }
  g_string_append_c (buf, ']');
  return g_string_free (buf, FALSE);
}

gchar *
cmacs_dispatch_gowl_focused_client (GError **error)
{
  GowlClient *c;
  gint x, y, w, h;

  GOWL_DISPATCH_CHECK ();

  c = gowl_compositor_get_focused_client (cmacs_gowl_compositor);
  if (c == NULL)
    return g_strdup ("nil");

  gowl_client_get_geometry (c, &x, &y, &w, &h);
  return g_strdup_printf (
    "{\"id\":%u,\"title\":\"%s\",\"app-id\":\"%s\","
    "\"tags\":%u,\"floating\":%s,\"pid\":%d,"
    "\"geometry\":[%d,%d,%d,%d]}",
    gowl_client_get_id (c),
    gowl_client_get_title (c) ? : "",
    gowl_client_get_app_id (c) ? : "",
    (guint)gowl_client_get_tags (c),
    gowl_client_get_floating (c) ? "true" : "false",
    (int)gowl_client_get_pid (c),
    x, y, w, h);
}

gchar *
cmacs_dispatch_gowl_spawn (const gchar *command, GError **error)
{
  const gchar *socket;
  gchar *env_cmd;
  GError *spawn_err = NULL;

  GOWL_DISPATCH_CHECK ();

  socket = gowl_compositor_get_socket_name (cmacs_gowl_compositor);
  env_cmd = g_strdup_printf ("WAYLAND_DISPLAY=%s %s",
                             socket ? socket : "", command);

  if (!g_spawn_command_line_async (env_cmd, &spawn_err))
    {
      g_free (env_cmd);
      g_propagate_error (error, spawn_err);
      return NULL;
    }

  g_free (env_cmd);
  return g_strdup ("t");
}

gchar *
cmacs_dispatch_gowl_list_monitors (GError **error)
{
  GList *monitors, *l;
  GString *buf;

  GOWL_DISPATCH_CHECK ();

  buf = g_string_new ("[");
  monitors = gowl_compositor_get_monitors (cmacs_gowl_compositor);
  for (l = monitors; l != NULL; l = l->next)
    {
      GowlMonitor *m = GOWL_MONITOR (l->data);
      GowlOutputMode *cur;
      gint x, y, w, h;
      gowl_monitor_get_geometry (m, &x, &y, &w, &h);

      if (l != monitors) g_string_append_c (buf, ',');
      g_string_append_printf (buf,
        "{\"name\":\"%s\",\"mfact\":%.2f,\"nmaster\":%d,"
        "\"tags\":%u,\"layout\":\"%s\","
        "\"enabled\":%s,\"scale\":%.2f,\"transform\":%d,",
        gowl_monitor_get_name (m) ? : "",
        gowl_monitor_get_mfact (m),
        gowl_monitor_get_nmaster (m),
        (guint)gowl_monitor_get_tags (m),
        gowl_monitor_get_layout_symbol (m) ? : "",
        gowl_monitor_get_enabled (m) ? "true" : "false",
        gowl_monitor_get_scale (m),
        gowl_monitor_get_transform (m));

      cur = gowl_monitor_get_current_mode (m);
      if (cur != NULL)
        {
          g_string_append_printf (buf,
            "\"current_mode\":{\"width\":%d,\"height\":%d,"
            "\"refresh_mhz\":%d},",
            cur->width, cur->height, cur->refresh_mhz);
          gowl_output_mode_free (cur);
        }
      else
        g_string_append (buf, "\"current_mode\":null,");

      g_string_append_printf (buf,
        "\"geometry\":[%d,%d,%d,%d]}",
        x, y, w, h);
    }
  g_string_append_c (buf, ']');
  return g_string_free (buf, FALSE);
}

gchar *
cmacs_dispatch_gowl_add_keybind (const gchar *key, gint action,
                                  const gchar *arg, GError **error)
{
  GowlConfig *config;
  guint modifiers, keysym;

  GOWL_DISPATCH_CHECK ();

  config = gowl_compositor_get_config (cmacs_gowl_compositor);
  if (config == NULL)
    {
      g_set_error (error, CMACS_DISPATCH_ERROR_DOMAIN, 1,
                   "No gowl config loaded");
      return NULL;
    }

  if (!gowl_keybind_parse (key, &modifiers, &keysym))
    {
      g_set_error (error, CMACS_DISPATCH_ERROR_DOMAIN, 1,
                   "Invalid key string: %s", key);
      return NULL;
    }

  gowl_config_add_keybind (config, modifiers, keysym, action, arg);
  return g_strdup ("t");
}

gchar *
cmacs_dispatch_gowl_list_keybinds (GError **error)
{
  GowlConfig *config;
  GArray *keybinds;
  GString *buf;
  guint i;

  GOWL_DISPATCH_CHECK ();

  config = gowl_compositor_get_config (cmacs_gowl_compositor);
  if (config == NULL)
    return g_strdup ("[]");

  keybinds = gowl_config_get_keybinds (config);
  buf = g_string_new ("[");
  for (i = 0; i < keybinds->len; i++)
    {
      GowlKeybindEntry *kb = &g_array_index (keybinds, GowlKeybindEntry, i);
      gchar *key_str = gowl_keybind_to_string (kb->modifiers, kb->keysym);

      if (i > 0) g_string_append_c (buf, ',');
      g_string_append_printf (buf,
        "{\"key\":\"%s\",\"action\":%d,\"arg\":\"%s\"}",
        key_str ? key_str : "",
        kb->action,
        kb->arg ? kb->arg : "");
      g_free (key_str);
    }
  g_string_append_c (buf, ']');
  return g_string_free (buf, FALSE);
}

gchar *
cmacs_dispatch_gowl_add_rule (const gchar *app_id, const gchar *title,
                               guint32 tags, gboolean floating,
                               gint monitor, GError **error)
{
  GowlConfig *config;

  GOWL_DISPATCH_CHECK ();

  config = gowl_compositor_get_config (cmacs_gowl_compositor);
  if (config == NULL)
    {
      g_set_error (error, CMACS_DISPATCH_ERROR_DOMAIN, 1,
                   "No gowl config loaded");
      return NULL;
    }

  gowl_config_add_rule (config, app_id, title, tags, floating, monitor);
  return g_strdup ("t");
}

gchar *
cmacs_dispatch_gowl_set_mfact (gdouble mfact, GError **error)
{
  GList *monitors;
  GowlMonitor *mon;

  GOWL_DISPATCH_CHECK ();

  monitors = gowl_compositor_get_monitors (cmacs_gowl_compositor);
  if (monitors == NULL)
    return g_strdup ("nil");

  /* Set on the first (focused) monitor. */
  mon = GOWL_MONITOR (monitors->data);
  gowl_monitor_set_mfact (mon, mfact);
  return g_strdup ("t");
}

gchar *
cmacs_dispatch_gowl_set_nmaster (gint n, GError **error)
{
  GList *monitors;
  GowlMonitor *mon;

  GOWL_DISPATCH_CHECK ();

  monitors = gowl_compositor_get_monitors (cmacs_gowl_compositor);
  if (monitors == NULL)
    return g_strdup ("nil");

  mon = GOWL_MONITOR (monitors->data);
  gowl_monitor_set_nmaster (mon, n);
  return g_strdup ("t");
}

gchar *
cmacs_dispatch_gowl_view_tags (guint32 tagmask, GError **error)
{
  GList *monitors;
  GowlMonitor *mon;

  GOWL_DISPATCH_CHECK ();

  monitors = gowl_compositor_get_monitors (cmacs_gowl_compositor);
  if (monitors == NULL)
    return g_strdup ("nil");

  mon = GOWL_MONITOR (monitors->data);
  gowl_monitor_set_tags (mon, tagmask);
  return g_strdup ("t");
}

gchar *
cmacs_dispatch_gowl_lock (GError **error)
{
  GOWL_DISPATCH_CHECK ();
  gowl_compositor_set_locked (cmacs_gowl_compositor, TRUE);
  return g_strdup ("t");
}

gchar *
cmacs_dispatch_gowl_unlock (GError **error)
{
  GOWL_DISPATCH_CHECK ();
  gowl_compositor_set_locked (cmacs_gowl_compositor, FALSE);
  return g_strdup ("t");
}

gchar *
cmacs_dispatch_gowl_reload_config (GError **error)
{
  GowlConfig *config;

  GOWL_DISPATCH_CHECK ();

  config = gowl_compositor_get_config (cmacs_gowl_compositor);
  if (config != NULL)
    {
      gowl_config_load_yaml_from_search_path (config, NULL);
      /* Apply per-output YAML overrides (transform/scale/mode/...)
       * to live monitors so the reload's effect is visible without
       * a compositor restart. */
      gowl_compositor_apply_monitor_configs (cmacs_gowl_compositor);
    }

  return g_strdup ("t");
}

gchar *
cmacs_dispatch_gowl_config_get (const gchar *property, GError **error)
{
  GowlConfig *config;

  GOWL_DISPATCH_CHECK ();

  config = gowl_compositor_get_config (cmacs_gowl_compositor);
  if (config == NULL)
    return g_strdup ("nil");

  if (g_strcmp0 (property, "border-width") == 0)
    return g_strdup_printf ("%d", gowl_config_get_border_width (config));
  if (g_strcmp0 (property, "terminal") == 0)
    return g_strdup (gowl_config_get_terminal (config) ? : "");
  if (g_strcmp0 (property, "mfact") == 0)
    return g_strdup_printf ("%.2f", gowl_config_get_mfact (config));
  if (g_strcmp0 (property, "nmaster") == 0)
    return g_strdup_printf ("%d", gowl_config_get_nmaster (config));
  if (g_strcmp0 (property, "tag-count") == 0)
    return g_strdup_printf ("%d", gowl_config_get_tag_count (config));

  g_set_error (error, CMACS_DISPATCH_ERROR_DOMAIN, 1,
               "Unknown config property: %s", property);
  return NULL;
}

gchar *
cmacs_dispatch_gowl_find_client (const gchar *pattern, const gchar *by,
                                  GError **error)
{
  GowlClient *c;
  gint x, y, w, h;

  GOWL_DISPATCH_CHECK ();

  if (g_strcmp0 (by, "title") == 0)
    c = gowl_compositor_find_client_by_title (cmacs_gowl_compositor,
                                               pattern);
  else
    c = gowl_compositor_find_client_by_app_id (cmacs_gowl_compositor,
                                                pattern);

  if (c == NULL)
    return g_strdup ("nil");

  gowl_client_get_geometry (c, &x, &y, &w, &h);
  return g_strdup_printf (
    "{\"id\":%u,\"title\":\"%s\",\"app-id\":\"%s\","
    "\"tags\":%u,\"geometry\":[%d,%d,%d,%d]}",
    gowl_client_get_id (c),
    gowl_client_get_title (c) ? : "",
    gowl_client_get_app_id (c) ? : "",
    (guint)gowl_client_get_tags (c),
    x, y, w, h);
}

/* ── Monitor management dispatch ─────────────────────────────────── */

static const char *transform_names[] = {
  "normal", "90", "180", "270",
  "flipped", "flipped-90", "flipped-180", "flipped-270"
};

gchar *
cmacs_dispatch_gowl_monitor_info (const gchar *name, GError **error)
{
  GowlMonitor *m;
  GowlOutputMode *cur;
  GList *modes, *ml;
  GString *buf;
  gint x, y, w, h;

  GOWL_DISPATCH_CHECK ();

  m = dispatch_resolve_monitor (name, error);
  if (m == NULL)
    return NULL;

  gowl_monitor_get_geometry (m, &x, &y, &w, &h);

  buf = g_string_new ("{");
  g_string_append_printf (buf,
    "\"name\":\"%s\",\"mfact\":%.2f,\"nmaster\":%d,"
    "\"tags\":%u,\"layout\":\"%s\","
    "\"enabled\":%s,\"scale\":%.2f,\"transform\":\"%s\","
    "\"geometry\":[%d,%d,%d,%d],",
    gowl_monitor_get_name (m) ? : "",
    gowl_monitor_get_mfact (m),
    gowl_monitor_get_nmaster (m),
    (guint)gowl_monitor_get_tags (m),
    gowl_monitor_get_layout_symbol (m) ? : "",
    gowl_monitor_get_enabled (m) ? "true" : "false",
    gowl_monitor_get_scale (m),
    transform_names[gowl_monitor_get_transform (m) & 7],
    x, y, w, h);

  /* current_mode */
  cur = gowl_monitor_get_current_mode (m);
  if (cur != NULL)
    {
      g_string_append_printf (buf,
        "\"current_mode\":{\"width\":%d,\"height\":%d,"
        "\"refresh_mhz\":%d},",
        cur->width, cur->height, cur->refresh_mhz);
      gowl_output_mode_free (cur);
    }
  else
    g_string_append (buf, "\"current_mode\":null,");

  /* modes array */
  g_string_append (buf, "\"modes\":[");
  modes = gowl_monitor_get_modes (m);
  for (ml = modes; ml != NULL; ml = ml->next)
    {
      GowlOutputMode *om = (GowlOutputMode *)ml->data;
      if (ml != modes) g_string_append_c (buf, ',');
      g_string_append_printf (buf,
        "{\"width\":%d,\"height\":%d,\"refresh_mhz\":%d}",
        om->width, om->height, om->refresh_mhz);
      gowl_output_mode_free (om);
    }
  g_list_free (modes);
  g_string_append (buf, "]}");

  return g_string_free (buf, FALSE);
}

gchar *
cmacs_dispatch_gowl_monitor_modes (const gchar *name, GError **error)
{
  GowlMonitor *m;
  GList *modes, *l;
  GString *buf;

  GOWL_DISPATCH_CHECK ();

  m = dispatch_resolve_monitor (name, error);
  if (m == NULL)
    return NULL;

  buf = g_string_new ("[");
  modes = gowl_monitor_get_modes (m);
  for (l = modes; l != NULL; l = l->next)
    {
      GowlOutputMode *om = (GowlOutputMode *)l->data;
      if (l != modes) g_string_append_c (buf, ',');
      g_string_append_printf (buf,
        "{\"width\":%d,\"height\":%d,\"refresh_mhz\":%d}",
        om->width, om->height, om->refresh_mhz);
      gowl_output_mode_free (om);
    }
  g_list_free (modes);
  g_string_append_c (buf, ']');
  return g_string_free (buf, FALSE);
}

gchar *
cmacs_dispatch_gowl_set_monitor_mode (const gchar *name, gint w, gint h,
                                       gint refresh_mhz, GError **error)
{
  GowlMonitor *m;

  GOWL_DISPATCH_CHECK ();

  m = dispatch_resolve_monitor (name, error);
  if (m == NULL)
    return NULL;

  if (!gowl_monitor_set_mode (m, w, h, refresh_mhz))
    {
      g_set_error (error, CMACS_DISPATCH_ERROR_DOMAIN, 1,
                   "Failed to set mode %dx%d@%d on \"%s\"",
                   w, h, refresh_mhz, name);
      return NULL;
    }

  return g_strdup ("t");
}

gchar *
cmacs_dispatch_gowl_monitor_position (const gchar *name, GError **error)
{
  GowlMonitor *m;
  gint x, y;

  GOWL_DISPATCH_CHECK ();

  m = dispatch_resolve_monitor (name, error);
  if (m == NULL)
    return NULL;

  gowl_monitor_get_position (m, &x, &y);
  return g_strdup_printf ("{\"x\":%d,\"y\":%d}", x, y);
}

gchar *
cmacs_dispatch_gowl_set_monitor_pos (const gchar *name, gint x, gint y,
                                      GError **error)
{
  GowlMonitor *m;

  GOWL_DISPATCH_CHECK ();

  m = dispatch_resolve_monitor (name, error);
  if (m == NULL)
    return NULL;

  if (!gowl_monitor_set_position (m, x, y))
    {
      g_set_error (error, CMACS_DISPATCH_ERROR_DOMAIN, 1,
                   "Failed to set position (%d,%d) on \"%s\"",
                   x, y, name);
      return NULL;
    }

  return g_strdup ("t");
}

gchar *
cmacs_dispatch_gowl_set_monitor_enabled (const gchar *name, gboolean en,
                                          GError **error)
{
  GowlMonitor *m;

  GOWL_DISPATCH_CHECK ();

  m = dispatch_resolve_monitor (name, error);
  if (m == NULL)
    return NULL;

  if (!gowl_monitor_set_enabled (m, en))
    {
      g_set_error (error, CMACS_DISPATCH_ERROR_DOMAIN, 1,
                   "Failed to %s monitor \"%s\"",
                   en ? "enable" : "disable", name);
      return NULL;
    }

  return g_strdup ("t");
}

gchar *
cmacs_dispatch_gowl_set_monitor_scale (const gchar *name, gdouble scale,
                                        GError **error)
{
  GowlMonitor *m;

  GOWL_DISPATCH_CHECK ();

  m = dispatch_resolve_monitor (name, error);
  if (m == NULL)
    return NULL;

  if (!gowl_monitor_set_scale (m, scale))
    {
      g_set_error (error, CMACS_DISPATCH_ERROR_DOMAIN, 1,
                   "Failed to set scale %.2f on \"%s\"",
                   scale, name);
      return NULL;
    }

  return g_strdup ("t");
}

gchar *
cmacs_dispatch_gowl_set_monitor_transform (const gchar *name, gint xform,
                                            GError **error)
{
  GowlMonitor *m;

  GOWL_DISPATCH_CHECK ();

  m = dispatch_resolve_monitor (name, error);
  if (m == NULL)
    return NULL;

  if (xform < 0 || xform > 7)
    {
      g_set_error (error, CMACS_DISPATCH_ERROR_DOMAIN, 1,
                   "Invalid transform %d (must be 0-7)", xform);
      return NULL;
    }

  if (!gowl_monitor_set_transform (m, xform))
    {
      g_set_error (error, CMACS_DISPATCH_ERROR_DOMAIN, 1,
                   "Failed to set transform %d on \"%s\"",
                   xform, name);
      return NULL;
    }

  return g_strdup ("t");
}

/* ---- screensaver (animated libregnum wallpaper) ----------------------- */

/* TRUE iff NAME is a safe screensaver config symbol (kebab-case), so it can be
 * interpolated into an elisp form without injection risk. */
static gboolean
screensaver_config_name_ok (const gchar *name)
{
  gsize i;

  if (name == NULL || name[0] == '\0')
    return FALSE;
  for (i = 0; name[i] != '\0'; i++)
    if (!g_ascii_isalnum (name[i]) && name[i] != '-' && name[i] != '_')
      return FALSE;
  return TRUE;
}

gchar *
cmacs_dispatch_screensaver_set_wallpaper (const gchar *config, GError **error)
{
  g_autofree gchar *expr = NULL;

  GOWL_DISPATCH_CHECK ();

  if (config != NULL && config[0] != '\0')
    {
      if (!screensaver_config_name_ok (config))
        {
          g_set_error (error, CMACS_DISPATCH_ERROR_DOMAIN, 1,
                       "invalid screensaver config name: %s", config);
          return NULL;
        }
      expr = g_strdup_printf (
        "(progn (require 'cmacs-screensaver) "
        "(cmacs-screensaver-set-wallpaper '%s) \"t\")", config);
    }
  else
    expr = g_strdup (
      "(progn (require 'cmacs-screensaver) "
      "(cmacs-screensaver-set-wallpaper "
      "(or cmacs-screensaver-wallpaper-config "
      "cmacs-screensaver-default-config)) \"t\")");
  return cmacs_dispatch_eval_string (expr, error);
}

gchar *
cmacs_dispatch_screensaver_stop_wallpaper (GError **error)
{
  GOWL_DISPATCH_CHECK ();
  return cmacs_dispatch_eval_string (
    "(progn (require 'cmacs-screensaver) "
    "(cmacs-screensaver-stop-wallpaper) \"t\")", error);
}

gchar *
cmacs_dispatch_screensaver_list_configs (GError **error)
{
  return cmacs_dispatch_eval_string (
    "(progn (require 'cmacs-screensaver) "
    "(mapconcat (lambda (e) (symbol-name (car e))) "
    "cmacs-screensaver-configs \"\\n\"))", error);
}

#endif /* HAVE_CMACS_GOWL */

#endif /* HAVE_CMACS_GLIB */
