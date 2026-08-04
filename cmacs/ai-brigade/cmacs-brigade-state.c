/* cmacs-brigade-state.c --- authoritative runtime state for plan tasks.
 *
 * Copyright (C) 2026 Zach Podbielniak
 * SPDX-License-Identifier: AGPL-3.0-or-later
 *
 * The ownership rule this file exists to enforce:
 *
 *   C is authoritative for RUNTIME.  Org is authoritative for INTENT.
 *
 * The two sides own disjoint fields.  Org owns the title, the prompt,
 * which agent, which model, the budget, the tool list -- everything the
 * human decides.  C owns the state, the turn and token counters, the
 * timestamps, the error.  Neither writes the other's fields, so there is
 * nothing to merge and no last-write-wins.
 *
 * The one apparent overlap is the TODO keyword, and it is not really an
 * overlap: the keyword is a *projection* of runtime state on the way
 * out, and a *command* on the way in.  A human typing C-c C-t is not
 * assigning a state, they are requesting a transition, and this file
 * decides whether that transition is legal.  A request to mark a running
 * task DONE is refused rather than obeyed, because the machine knows
 * something the keystroke does not.
 *
 * Keeping this in C is not about speed.  It is that the table has to be
 * readable from a worker thread while the Lisp side is mid-redisplay,
 * and it has to survive the plan buffer being killed. */

#include <config.h>

#ifdef HAVE_CMACS_AI_BRIGADE

#include "lisp.h"
#include "cmacs-brigade.h"

#include <glib.h>
#include <string.h>

/* ── State machine ────────────────────────────────────────────────── */

static const gchar *const state_names[] = {
  "draft", "queued", "starting", "running", "waiting-input",
  "blocked", "done", "failed", "cancelled", "over-budget",
  "interrupted", NULL
};

const gchar *
cmacs_brigade_state_name (CmacsBrigadeState s)
{
  return (s >= 0 && s < CMACS_BRIGADE_STATE_COUNT) ? state_names[s] : "?";
}

CmacsBrigadeState
cmacs_brigade_state_from_name (const gchar *name)
{
  gint i;

  if (name == NULL) return CMACS_BRIGADE_STATE_DRAFT;
  for (i = 0; state_names[i] != NULL; i++)
    if (strcmp (name, state_names[i]) == 0) return (CmacsBrigadeState) i;
  return CMACS_BRIGADE_STATE_DRAFT;
}

gboolean
cmacs_brigade_state_terminal (CmacsBrigadeState s)
{
  switch (s)
    {
    case CMACS_BRIGADE_STATE_DONE:
    case CMACS_BRIGADE_STATE_FAILED:
    case CMACS_BRIGADE_STATE_CANCELLED:
    case CMACS_BRIGADE_STATE_OVER_BUDGET:
      return TRUE;
    default:
      return FALSE;
    }
}

gboolean
cmacs_brigade_state_live (CmacsBrigadeState s)
{
  switch (s)
    {
    case CMACS_BRIGADE_STATE_STARTING:
    case CMACS_BRIGADE_STATE_RUNNING:
    case CMACS_BRIGADE_STATE_WAITING_INPUT:
    case CMACS_BRIGADE_STATE_BLOCKED:
      return TRUE;
    default:
      return FALSE;
    }
}

/* Is FROM -> TO a legal transition?
 *
 * The table is permissive about machine-driven moves and strict about
 * human-driven ones, because the human is the one who can be wrong in a
 * way that loses work: marking a running task DONE by hand would orphan
 * a live agent that is still spending money. */
gboolean
cmacs_brigade_state_can_transition (CmacsBrigadeState from,
                                    CmacsBrigadeState to)
{
  if (from == to) return TRUE;

  /* Cancellation is always available while something is live.  A user
   * who wants to stop an agent must never be told they may not. */
  if (to == CMACS_BRIGADE_STATE_CANCELLED)
    return cmacs_brigade_state_live (from)
      || from == CMACS_BRIGADE_STATE_QUEUED
      || from == CMACS_BRIGADE_STATE_DRAFT;

  switch (from)
    {
    case CMACS_BRIGADE_STATE_DRAFT:
      return to == CMACS_BRIGADE_STATE_QUEUED;

    case CMACS_BRIGADE_STATE_QUEUED:
      return to == CMACS_BRIGADE_STATE_DRAFT      /* unqueue */
        || to == CMACS_BRIGADE_STATE_STARTING;

    case CMACS_BRIGADE_STATE_STARTING:
      return to == CMACS_BRIGADE_STATE_RUNNING
        || to == CMACS_BRIGADE_STATE_FAILED;

    case CMACS_BRIGADE_STATE_RUNNING:
      return to == CMACS_BRIGADE_STATE_WAITING_INPUT
        || to == CMACS_BRIGADE_STATE_BLOCKED
        || to == CMACS_BRIGADE_STATE_DONE
        || to == CMACS_BRIGADE_STATE_FAILED
        || to == CMACS_BRIGADE_STATE_OVER_BUDGET
        || to == CMACS_BRIGADE_STATE_INTERRUPTED;

    case CMACS_BRIGADE_STATE_WAITING_INPUT:
      /* An answer resumes it; accepting the partial result finishes it. */
      return to == CMACS_BRIGADE_STATE_RUNNING
        || to == CMACS_BRIGADE_STATE_DONE
        || to == CMACS_BRIGADE_STATE_FAILED;

    case CMACS_BRIGADE_STATE_BLOCKED:
      return to == CMACS_BRIGADE_STATE_RUNNING
        || to == CMACS_BRIGADE_STATE_FAILED;

    case CMACS_BRIGADE_STATE_INTERRUPTED:
      /* Recovered after a restart: retry or abandon, never resume --
       * whatever the agent was doing, nobody watched it stop. */
      return to == CMACS_BRIGADE_STATE_QUEUED
        || to == CMACS_BRIGADE_STATE_DRAFT;

    case CMACS_BRIGADE_STATE_DONE:
    case CMACS_BRIGADE_STATE_FAILED:
    case CMACS_BRIGADE_STATE_CANCELLED:
    case CMACS_BRIGADE_STATE_OVER_BUDGET:
      /* Terminal states can be retried, which means going back to the
       * start rather than resuming. */
      return to == CMACS_BRIGADE_STATE_QUEUED
        || to == CMACS_BRIGADE_STATE_DRAFT;

    default:
      return FALSE;
    }
}

/* ── Task table ───────────────────────────────────────────────────── */

typedef struct
{
  gchar             *id;         /* org :ID: or :BRIGADE-ID: */
  gchar             *plan;       /* plan file this belongs to */
  CmacsBrigadeState  state;
  guint              turns;
  guint64            in_tokens;
  guint64            out_tokens;
  gint64             cost_micros;
  gint64             started_at;
  gint64             ended_at;
  gchar             *error;
  gchar             *agent;
} CmacsBrigadeTask;

static GHashTable *cmacs_brigade__tasks;    /* id -> CmacsBrigadeTask* */
static GMutex      cmacs_brigade__task_mutex;
static gboolean    cmacs_brigade__task_init_done;

static void
task_free (gpointer data)
{
  CmacsBrigadeTask *t = data;

  if (t == NULL) return;
  g_free (t->id);
  g_free (t->plan);
  g_free (t->error);
  g_free (t->agent);
  g_free (t);
}

void
cmacs_brigade_state_init (void)
{
  if (cmacs_brigade__task_init_done) return;
  cmacs_brigade__task_init_done = TRUE;
  g_mutex_init (&cmacs_brigade__task_mutex);
  cmacs_brigade__tasks = g_hash_table_new_full (g_str_hash, g_str_equal,
                                                g_free, task_free);
}

static Lisp_Object
task_to_plist (const CmacsBrigadeTask *t)
{
  return list (intern (":id"), build_string (t->id),
               intern (":plan"), t->plan ? build_string (t->plan) : Qnil,
               intern (":state"), intern (cmacs_brigade_state_name (t->state)),
               intern (":turns"), make_fixnum (t->turns),
               intern (":in-tokens"), make_fixnum (t->in_tokens),
               intern (":out-tokens"), make_fixnum (t->out_tokens),
               intern (":cost-micros"), make_fixnum (t->cost_micros),
               intern (":started-at"), make_fixnum (t->started_at),
               intern (":ended-at"), make_fixnum (t->ended_at),
               intern (":agent"), t->agent ? build_string (t->agent) : Qnil,
               intern (":error"), t->error ? build_string (t->error) : Qnil);
}

/* ── DEFUNs ───────────────────────────────────────────────────────── */

DEFUN ("cmacs-brigade-task-adopt", Fcmacs_brigade_task_adopt,
       Scmacs_brigade_task_adopt, 2, 3, 0,
       doc: /* Ensure a task record exists for ID in PLAN, and return it.

AGENT names the agent the task will run under.  An existing record is
returned unchanged: adopting is how the org side announces "this task
exists", not how it sets runtime state, which it may not touch.  */)
  (Lisp_Object id, Lisp_Object plan, Lisp_Object agent)
{
  CmacsBrigadeTask *t;

  CHECK_STRING (id);
  CHECK_STRING (plan);
  cmacs_brigade_state_init ();

  g_mutex_lock (&cmacs_brigade__task_mutex);
  t = g_hash_table_lookup (cmacs_brigade__tasks, SSDATA (id));
  if (t == NULL)
    {
      t = g_new0 (CmacsBrigadeTask, 1);
      t->id    = g_strdup (SSDATA (id));
      t->plan  = g_strdup (SSDATA (plan));
      t->state = CMACS_BRIGADE_STATE_DRAFT;
      g_hash_table_insert (cmacs_brigade__tasks, g_strdup (t->id), t);
    }
  if (STRINGP (agent))
    {
      g_free (t->agent);
      t->agent = g_strdup (SSDATA (agent));
    }
  {
    Lisp_Object out = task_to_plist (t);
    g_mutex_unlock (&cmacs_brigade__task_mutex);
    return out;
  }
}

DEFUN ("cmacs-brigade-task-get", Fcmacs_brigade_task_get,
       Scmacs_brigade_task_get, 1, 1, 0,
       doc: /* Return the runtime record for task ID, or nil.  */)
  (Lisp_Object id)
{
  CmacsBrigadeTask *t;
  Lisp_Object out = Qnil;

  CHECK_STRING (id);
  cmacs_brigade_state_init ();
  g_mutex_lock (&cmacs_brigade__task_mutex);
  t = g_hash_table_lookup (cmacs_brigade__tasks, SSDATA (id));
  if (t != NULL) out = task_to_plist (t);
  g_mutex_unlock (&cmacs_brigade__task_mutex);
  return out;
}

DEFUN ("cmacs-brigade-task-forget", Fcmacs_brigade_task_forget,
       Scmacs_brigade_task_forget, 1, 1, 0,
       doc: /* Drop the record for task ID.

Called when the human deletes a headline: the record has no owner any
more and keeping it would leave a task on the dashboard that exists
nowhere in any plan.  */)
  (Lisp_Object id)
{
  gboolean removed;

  CHECK_STRING (id);
  cmacs_brigade_state_init ();
  g_mutex_lock (&cmacs_brigade__task_mutex);
  removed = g_hash_table_remove (cmacs_brigade__tasks, SSDATA (id));
  g_mutex_unlock (&cmacs_brigade__task_mutex);
  return removed ? Qt : Qnil;
}

DEFUN ("cmacs-brigade-task-transition", Fcmacs_brigade_task_transition,
       Scmacs_brigade_task_transition, 2, 3, 0,
       doc: /* Move task ID to STATE if the machine allows it.

Returns the updated record on success, or a plist with :rejected and a
:reason on refusal.  DETAIL is an optional error or explanation string.

Refusal is the point.  A human marking a running task DONE by hand would
orphan a live agent that is still spending money, so the request is
declined and the reason reported rather than obeyed.  */)
  (Lisp_Object id, Lisp_Object state, Lisp_Object detail)
{
  CmacsBrigadeTask *t;
  CmacsBrigadeState to;
  Lisp_Object out;

  CHECK_STRING (id);
  CHECK_SYMBOL (state);
  cmacs_brigade_state_init ();

  to = cmacs_brigade_state_from_name (SSDATA (Fsymbol_name (state)));

  g_mutex_lock (&cmacs_brigade__task_mutex);
  t = g_hash_table_lookup (cmacs_brigade__tasks, SSDATA (id));
  if (t == NULL)
    {
      g_mutex_unlock (&cmacs_brigade__task_mutex);
      return list (intern (":rejected"), Qt,
                   intern (":reason"), build_string ("no such task"));
    }

  if (!cmacs_brigade_state_can_transition (t->state, to))
    {
      g_autofree gchar *why =
        g_strdup_printf ("cannot go from %s to %s",
                         cmacs_brigade_state_name (t->state),
                         cmacs_brigade_state_name (to));
      Lisp_Object r = list (intern (":rejected"), Qt,
                            intern (":reason"), build_string (why),
                            intern (":state"),
                            intern (cmacs_brigade_state_name (t->state)));
      g_mutex_unlock (&cmacs_brigade__task_mutex);
      return r;
    }

  /* Timestamps are set here rather than by the caller so they cannot
   * disagree with the state they describe. */
  if (t->state != CMACS_BRIGADE_STATE_RUNNING
      && to == CMACS_BRIGADE_STATE_RUNNING && t->started_at == 0)
    t->started_at = g_get_real_time () / G_USEC_PER_SEC;
  if (cmacs_brigade_state_terminal (to))
    t->ended_at = g_get_real_time () / G_USEC_PER_SEC;
  /* Retrying clears the previous run's outcome; leaving the old error in
   * place would make a fresh failure indistinguishable from a stale
   * one. */
  if (to == CMACS_BRIGADE_STATE_QUEUED || to == CMACS_BRIGADE_STATE_DRAFT)
    {
      g_clear_pointer (&t->error, g_free);
      t->ended_at = 0;
    }

  if (STRINGP (detail))
    {
      g_free (t->error);
      t->error = g_strdup (SSDATA (detail));
    }

  t->state = to;
  out = task_to_plist (t);
  g_mutex_unlock (&cmacs_brigade__task_mutex);
  return out;
}

DEFUN ("cmacs-brigade-task-progress", Fcmacs_brigade_task_progress,
       Scmacs_brigade_task_progress, 4, 5, 0,
       doc: /* Record progress for task ID.

TURNS, IN-TOKENS and OUT-TOKENS are cumulative counts; COST-MICROS is
spend in millionths of a dollar.

Cost is an integer because it is summed across thousands of turns and
floating point would drift -- and a spend figure that drifts is worse
than no spend figure, since it is the one number a budget acts on.  */)
  (Lisp_Object id, Lisp_Object turns, Lisp_Object in_tokens,
   Lisp_Object out_tokens, Lisp_Object cost_micros)
{
  CmacsBrigadeTask *t;
  Lisp_Object out = Qnil;

  CHECK_STRING (id);
  cmacs_brigade_state_init ();
  g_mutex_lock (&cmacs_brigade__task_mutex);
  t = g_hash_table_lookup (cmacs_brigade__tasks, SSDATA (id));
  if (t != NULL)
    {
      if (FIXNUMP (turns))       t->turns       = (guint) XFIXNUM (turns);
      if (FIXNUMP (in_tokens))   t->in_tokens   = (guint64) XFIXNUM (in_tokens);
      if (FIXNUMP (out_tokens))  t->out_tokens  = (guint64) XFIXNUM (out_tokens);
      if (FIXNUMP (cost_micros)) t->cost_micros = XFIXNUM (cost_micros);
      out = task_to_plist (t);
    }
  g_mutex_unlock (&cmacs_brigade__task_mutex);
  return out;
}

DEFUN ("cmacs-brigade-task-list", Fcmacs_brigade_task_list,
       Scmacs_brigade_task_list, 0, 1, 0,
       doc: /* Return every task record, or those belonging to PLAN.  */)
  (Lisp_Object plan)
{
  GHashTableIter iter;
  gpointer key, value;
  Lisp_Object out = Qnil;

  cmacs_brigade_state_init ();
  g_mutex_lock (&cmacs_brigade__task_mutex);
  g_hash_table_iter_init (&iter, cmacs_brigade__tasks);
  while (g_hash_table_iter_next (&iter, &key, &value))
    {
      const CmacsBrigadeTask *t = value;
      if (STRINGP (plan) && g_strcmp0 (t->plan, SSDATA (plan)) != 0)
        continue;
      out = Fcons (task_to_plist (t), out);
    }
  g_mutex_unlock (&cmacs_brigade__task_mutex);
  return out;
}

DEFUN ("cmacs-brigade-state-can-transition-p",
       Fcmacs_brigade_state_can_transition_p,
       Scmacs_brigade_state_can_transition_p, 2, 2, 0,
       doc: /* Return t if a task may move from state FROM to state TO.

Exposed so the org layer can decide whether a keyword change is a
command worth sending, and so the rules are testable without a task.  */)
  (Lisp_Object from, Lisp_Object to)
{
  CHECK_SYMBOL (from);
  CHECK_SYMBOL (to);
  return cmacs_brigade_state_can_transition (
    cmacs_brigade_state_from_name (SSDATA (Fsymbol_name (from))),
    cmacs_brigade_state_from_name (SSDATA (Fsymbol_name (to))))
    ? Qt : Qnil;
}

DEFUN ("cmacs-brigade-state-interrupt-live",
       Fcmacs_brigade_state_interrupt_live,
       Scmacs_brigade_state_interrupt_live, 0, 0, 0,
       doc: /* Mark every live task as interrupted.  Returns the count.

Called at startup after restoring checkpoints.  A task that was running
when cmacs stopped did not finish and did not fail; it was simply
abandoned, and saying so is the honest thing.  Nothing is resumed
automatically -- whatever the agent was doing, nobody watched it stop. */)
  (void)
{
  GHashTableIter iter;
  gpointer key, value;
  EMACS_INT n = 0;

  cmacs_brigade_state_init ();
  g_mutex_lock (&cmacs_brigade__task_mutex);
  g_hash_table_iter_init (&iter, cmacs_brigade__tasks);
  while (g_hash_table_iter_next (&iter, &key, &value))
    {
      CmacsBrigadeTask *t = value;
      if (cmacs_brigade_state_live (t->state))
        {
          t->state = CMACS_BRIGADE_STATE_INTERRUPTED;
          t->ended_at = g_get_real_time () / G_USEC_PER_SEC;
          n++;
        }
    }
  g_mutex_unlock (&cmacs_brigade__task_mutex);
  return make_fixnum (n);
}

void syms_of_cmacs_ai_brigade_state (void);
void
syms_of_cmacs_ai_brigade_state (void)
{
  defsubr (&Scmacs_brigade_task_adopt);
  defsubr (&Scmacs_brigade_task_get);
  defsubr (&Scmacs_brigade_task_forget);
  defsubr (&Scmacs_brigade_task_transition);
  defsubr (&Scmacs_brigade_task_progress);
  defsubr (&Scmacs_brigade_task_list);
  defsubr (&Scmacs_brigade_state_can_transition_p);
  defsubr (&Scmacs_brigade_state_interrupt_live);
}

#endif /* HAVE_CMACS_AI_BRIGADE */
