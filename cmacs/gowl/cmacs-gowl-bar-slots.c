/* cmacs-gowl-bar-slots.c --- bar items Lisp creates and fills
 *
 * Copyright (C) 2026 Zach Podbielniak
 * SPDX-License-Identifier: AGPL-3.0-or-later
 *
 * See cmacs-gowl-bar-slots.h.
 *
 * Threads.  These DEFUNs run on Emacs's thread.  The bar runs on the
 * compositor's dispatch thread, which holds the gowl lock across every
 * dispatch, so each command is sent with that lock held -- taken with
 * the scoped form, so that nothing can leave it held.  The bar's
 * handlers neither block nor reach Lisp: a push is a table lookup, a
 * few bounded string copies and a repaint.
 *
 * The other direction needs nothing here.  A click on a slot is
 * announced by the bar as the compositor's `module-event' signal, which
 * cmacs already carries to Emacs's thread and runs as
 * `cmacs-gowl-module-event-functions'; the Lisp half listens there.
 *
 * Why DEFUNs at all, when `gowl-run-command' can send any command
 * line?  Because a slot's text is arbitrary -- it is what a query
 * returned, a mail subject, a task heading -- and a command line is
 * split on spaces and ended by a newline.  Here the request is built
 * as a JSON object in C from Lisp strings, so no text can break out of
 * its field; and it goes to the bar alone rather than being announced
 * to every IPC subscriber as a command that ran, which for a status
 * that changes every few seconds would be most of what they hear.  */

#include <config.h>

#ifdef HAVE_CMACS_GOWL

#include <string.h>

#include "lisp.h"
#include "cmacs-gowl.h"
#include "cmacs-eval-dispatch.h"
#include "cmacs-gowl-bar-slots.h"
#include <gowl.h>
#include <json-glib/json-glib.h>

/* Hold the gowl lock for the rest of this call; the release is on the
   specpdl, so nothing below can leave the dispatch thread wedged (see
   cmacs-gowl.c's own, which this mirrors).  */
static specpdl_ref
cmacs_gowl_lock_scoped (void)
{
  specpdl_ref count = SPECPDL_INDEX ();

  cmacs_gowl_lock ();
  record_unwind_protect_void (cmacs_gowl_unlock);
  return count;
}

/* Send COMMAND with ARGS (which may be NULL) to the gowl modules and
   return the bar's reply as a Lisp string.  nil when no compositor is
   running, or when no module answers the command -- the bar is not
   loaded, or it is a gowl from before slots.

   The one place in this file that calls into gowl, and so the one
   place that takes the lock.  */
static Lisp_Object
bar_slots_command (const char *command, const char *args)
{
  specpdl_ref count = cmacs_gowl_lock_scoped ();
  GowlModuleManager *mgr;
  Lisp_Object result = Qnil;
  gchar *reply;

  if (cmacs_gowl_compositor == NULL)
    return unbind_to (count, Qnil);
  mgr = gowl_compositor_get_module_manager (cmacs_gowl_compositor);
  if (mgr == NULL)
    return unbind_to (count, Qnil);

  reply = gowl_module_manager_dispatch_command (mgr, command, args);
  if (reply != NULL)
    {
      result = build_string (reply);
      g_free (reply);
    }
  return unbind_to (count, result);
}

/* Signal unless NAME, a Lisp string, can travel as one word of a
   command line.  gowl checks ids properly; this is only what keeps
   "a b" from being read as two arguments on the way there.  */
static void
bar_slots_check_word (Lisp_Object name)
{
  CHECK_STRING (name);
  if (SCHARS (name) == 0
      || strpbrk (SSDATA (name), " \t\n\r") != NULL
      || memchr (SSDATA (name), '\0', SBYTES (name)) != NULL)
    xsignal2 (Qerror, build_string ("Not a bar slot name"), name);
}

DEFUN ("gowl-bar-slot-set", Fgowl_bar_slot_set, Sgowl_bar_slot_set, 2, 2, 0,
       doc: /* Create the gowl bar slot ID, or change it, from FIELDS.
A slot is a bar item whose content is pushed from outside.  ID is a
string of letters, digits, `_', `.' and `-'.  FIELDS is an alist of
(KEY . VALUE); only the keys present change.  KEY is a string or a
symbol (a keyword's colon is dropped), one of:

  text     what the slot says (a string; long text is cut)
  icon     a glyph drawn before it
  role     a bar theme role for the colour: "text", "accent", "red" ...
  tooltip  hover text
  urgency  "low", "normal" or "critical"
  click    t to have clicks reported, nil not to
  bar      "top" or "bottom"
  region   "left", "center" or "right"
  order    an integer: where among the region's slots
  output   the one output to show on
  owner    who the slot belongs to; an update must name the same owner
  ttl      an integer: seconds after the last push at which the slot
           removes itself, 0 for never

VALUE is a string, an integer, or t or nil for true and false.  An
empty string clears a field.

Return the bar's reply, a string: "created ID", "updated ID", or
"error: REASON" when the bar refused -- a bad value, another owner's
slot, too many slots.  Return nil when no compositor is running or its
bar has no slots.  Never waits and never runs Lisp.

A click on a slot made with click is reported through
`cmacs-gowl-module-event-functions' as the module "bar" saying
"slot-click ID BUTTON MODIFIERS OUTPUT OWNER".  Use
`cmacs-gowl-bar-slot-set' rather than this: it remembers the slot,
dispatches its clicks, and puts it back when the compositor restarts.  */)
  (Lisp_Object id, Lisp_Object fields)
{
  Lisp_Object tail, result;
  JsonObject *obj;
  JsonNode *node;
  gchar *utf8;
  gchar *args;

  bar_slots_check_word (id);

  /* Check everything first.  Nothing in the second pass can signal,
     so no C memory is ever held across a non-local exit.  */
  tail = fields;
  FOR_EACH_TAIL (tail)
    {
      Lisp_Object cell = XCAR (tail);
      Lisp_Object key, val;

      CHECK_CONS (cell);
      key = XCAR (cell);
      val = XCDR (cell);
      if (NILP (key) || !SYMBOLP (key))
        CHECK_STRING (key);
      if (!(STRINGP (val) || FIXNUMP (val) || NILP (val) || EQ (val, Qt)))
        wrong_type_argument (Qstringp, val);
    }
  CHECK_LIST_END (tail, fields);

  obj = json_object_new ();
  utf8 = cmacs_dispatch_string_to_utf8 (id);
  json_object_set_string_member (obj, "id", utf8);
  g_free (utf8);

  for (tail = fields; CONSP (tail); tail = XCDR (tail))
    {
      Lisp_Object key = XCAR (XCAR (tail));
      Lisp_Object val = XCDR (XCAR (tail));
      gchar *name;
      const gchar *member;

      name = cmacs_dispatch_string_to_utf8 (SYMBOLP (key)
                                            ? SYMBOL_NAME (key) : key);
      /* `:text' and `text' are the same key.  */
      member = (name[0] == ':') ? name + 1 : name;

      /* The id is the first argument and nothing else: an "id" in
         FIELDS would silently retarget the push.  */
      if (strcmp (member, "id") != 0)
        {
          if (STRINGP (val))
            {
              utf8 = cmacs_dispatch_string_to_utf8 (val);
              json_object_set_string_member (obj, member, utf8);
              g_free (utf8);
            }
          else if (FIXNUMP (val))
            json_object_set_int_member (obj, member, XFIXNUM (val));
          else
            json_object_set_boolean_member (obj, member, !NILP (val));
        }
      g_free (name);
    }

  /* One line whatever the text held: the generator escapes newlines.  */
  node = json_node_new (JSON_NODE_OBJECT);
  json_node_take_object (node, obj);
  args = json_to_string (node, FALSE);
  json_node_unref (node);

  result = bar_slots_command ("bar-slot-set", args);
  g_free (args);
  return result;
}

DEFUN ("gowl-bar-slot-remove", Fgowl_bar_slot_remove, Sgowl_bar_slot_remove,
       1, 2, 0,
       doc: /* Remove the gowl bar slot ID.
With OWNER, a string, remove it only if it is that owner's.

Return the bar's reply, a string: "removed ID", or "error: REASON"
when there is no such slot or it is somebody else's.  Return nil when
no compositor is running or its bar has no slots.  */)
  (Lisp_Object id, Lisp_Object owner)
{
  Lisp_Object result;
  gchar *args;

  bar_slots_check_word (id);
  if (!NILP (owner))
    bar_slots_check_word (owner);

  /* Both are single words of ASCII by the check above and by gowl's
     own rule for ids, so they go as written.  */
  args = NILP (owner)
    ? g_strdup (SSDATA (id))
    : g_strdup_printf ("%s %s", SSDATA (id), SSDATA (owner));
  result = bar_slots_command ("bar-slot-remove", args);
  g_free (args);
  return result;
}

DEFUN ("gowl-bar-slot-clear", Fgowl_bar_slot_clear, Sgowl_bar_slot_clear,
       1, 1, 0,
       doc: /* Remove every gowl bar slot that belongs to OWNER, a string.
With OWNER t, remove every slot there is, whoever made it.

Return the bar's reply, a string: "removed N".  Return nil when no
compositor is running or its bar has no slots.  */)
  (Lisp_Object owner)
{
  if (EQ (owner, Qt))
    return bar_slots_command ("bar-slot-clear", "--all");

  bar_slots_check_word (owner);
  /* An owner cannot begin with `-' (gowl refuses to make such a slot),
     so a string here can never be read as `--all'.  Refused all the
     same, rather than trusted.  */
  if (SREF (owner, 0) == '-')
    xsignal2 (Qerror, build_string ("Not a bar slot owner"), owner);
  return bar_slots_command ("bar-slot-clear", SSDATA (owner));
}

DEFUN ("gowl-bar-slot-list", Fgowl_bar_slot_list, Sgowl_bar_slot_list,
       0, 1, 0,
       doc: /* Return gowl's bar slots as a string of JSON.
An array of objects, in the order the bar shows them, each with id,
owner, bar, region, order, output, text, icon, role, tooltip, urgency,
click, ttl and placed.  With OWNER, a string, only that owner's.

Return nil when no compositor is running or its bar has no slots.
`cmacs-gowl-bar-slot-list' returns the same thing parsed.  */)
  (Lisp_Object owner)
{
  if (NILP (owner))
    return bar_slots_command ("bar-slot-list", NULL);

  bar_slots_check_word (owner);
  return bar_slots_command ("bar-slot-list", SSDATA (owner));
}

void
syms_of_cmacs_gowl_bar_slots (void)
{
  defsubr (&Sgowl_bar_slot_set);
  defsubr (&Sgowl_bar_slot_remove);
  defsubr (&Sgowl_bar_slot_clear);
  defsubr (&Sgowl_bar_slot_list);
}

#endif /* HAVE_CMACS_GOWL */
