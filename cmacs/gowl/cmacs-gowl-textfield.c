/* cmacs-gowl-textfield.c --- another application's text field, as text
 *
 * Copyright (C) 2026 Zach Podbielniak
 * SPDX-License-Identifier: AGPL-3.0-or-later
 *
 * See cmacs-gowl-textfield.h.
 *
 * Threads.  The DEFUNs run on Emacs's thread and take the gowl lock.
 * gowl's callbacks (textfield_on_read, textfield_on_commit) run
 * wherever gowl finishes the operation: on the dispatch thread for one
 * that had to wait for the client, on Emacs's thread -- inside the
 * DEFUN, under the lock -- for one that could be answered at once.
 * Neither place may run Lisp (the first is another thread; the second
 * would run a callback while the lock is held), so both do the same
 * thing: copy the answer into a TextfieldAnswer and queue it with
 * cmacs_glib_invoke_on_main.  The Lisp callback therefore ALWAYS runs
 * later, from the main loop, whichever way gowl answered.
 *
 * Roots.  What crosses to gowl as user_data is an integer.  The Lisp
 * callback it stands for is in Vcmacs_gowl_textfield_callbacks, a
 * staticpro'd hash table, from registration until exactly one of:
 * the answer is delivered (textfield_take), gowl refuses the request
 * (taken back in the DEFUN), or the compositor stops
 * (cmacs_gowl_textfield_forget).  Ids only ever go up, so an answer
 * that arrives after its callback was dropped finds nothing, never
 * somebody else's callback.  */

#include <config.h>

#ifdef HAVE_CMACS_GOWL

#include <string.h>

#include "lisp.h"
#include "cmacs-gowl.h"
#include "cmacs-gobject.h"
#include "cmacs-glib-loop.h"
#include "cmacs-eval-dispatch.h"
#include "cmacs-gowl-textfield.h"
#include <gowl.h>
#include <xkbcommon/xkbcommon.h>

/* ---------------------------------------------------- callback table -- */

/* Callback id -> Lisp function.  Main thread only.  */
static Lisp_Object Vcmacs_gowl_textfield_callbacks;

/* The next id.  Never reused, never 0.  Main thread only.  */
static guint textfield_next_id = 1;

static guint
textfield_register (Lisp_Object callback)
{
  guint id = textfield_next_id++;

  if (textfield_next_id == 0)
    textfield_next_id = 1;
  if (NILP (Vcmacs_gowl_textfield_callbacks))
    Vcmacs_gowl_textfield_callbacks
      = CALLN (Fmake_hash_table, QCtest, Qeql);
  Fputhash (make_uint (id), callback, Vcmacs_gowl_textfield_callbacks);
  return id;
}

/* The callback registered as ID, removed from the table; nil when it
   was already delivered or dropped.  This is the one place a callback
   leaves the table for delivery, which is what makes "exactly once"
   true.  */
static Lisp_Object
textfield_take (guint id)
{
  Lisp_Object cb;

  if (NILP (Vcmacs_gowl_textfield_callbacks))
    return Qnil;
  cb = Fgethash (make_uint (id), Vcmacs_gowl_textfield_callbacks, Qnil);
  Fremhash (make_uint (id), Vcmacs_gowl_textfield_callbacks);
  return cb;
}

void
cmacs_gowl_textfield_forget (void)
{
  if (!NILP (Vcmacs_gowl_textfield_callbacks))
    Fclrhash (Vcmacs_gowl_textfield_callbacks);
}

/* ------------------------------------------- dispatch thread -> main -- */

/* One answer on its way to the main thread.  C data only.  */
typedef struct
{
  guint    id;
  gboolean is_read;

  /* A read.  */
  GowlTextFieldStatus status;
  gchar   *text;                /* owned; NULL unless status is OK */
  guint    cursor;
  guint    anchor;
  gboolean complete;
  guint    content_hint;
  guint    content_purpose;

  /* An edit.  */
  gboolean delivered;
} TextfieldAnswer;

static void
textfield_answer_free (gpointer data)
{
  TextfieldAnswer *a = data;

  g_free (a->text);
  g_free (a);
}

/* Main thread: hand the answer to its Lisp callback, if it still has
   one.  The call is guarded -- a callback that signals must not unwind
   through the GLib dispatch it is running in.  */
static gboolean
textfield_deliver (gpointer data)
{
  TextfieldAnswer *a = data;
  Lisp_Object cb = textfield_take (a->id);
  Lisp_Object payload;

  if (NILP (cb))
    return G_SOURCE_REMOVE;

  if (!a->is_read)
    payload = a->delivered ? Qt : Qnil;
  else
    {
      const char *status
        = (a->status == GOWL_TEXT_FIELD_OK ? "ok"
           : a->status == GOWL_TEXT_FIELD_NO_FIELD ? "no-field"
           : "no-surrounding");

      /* Keywords are interned here rather than DEFSYM'd: `:text' and
         `:status' belong to other subsystems' DEFSYMs, and a second
         DEFSYM of a name splits the symbol.  */
      payload = CALLN (Flist,
                       intern_c_string (":status"), intern_c_string (status),
                       intern_c_string (":text"),
                       a->text != NULL ? build_string (a->text) : Qnil,
                       intern_c_string (":cursor"), make_uint (a->cursor),
                       intern_c_string (":anchor"), make_uint (a->anchor),
                       intern_c_string (":complete"),
                       a->complete ? Qt : Qnil,
                       intern_c_string (":hint"),
                       make_uint (a->content_hint),
                       intern_c_string (":purpose"),
                       make_uint (a->content_purpose));
    }
  cmacs_dispatch_safe_call1 (cb, payload);
  return G_SOURCE_REMOVE;
}

/* gowl's answer to a read.  Any thread; no Lisp.  INFO and its text
   are only valid during the call, hence the copy.  */
static void
textfield_on_read (const GowlTextFieldInfo *info, gpointer user_data)
{
  TextfieldAnswer *a = g_new0 (TextfieldAnswer, 1);

  a->id = GPOINTER_TO_UINT (user_data);
  a->is_read = TRUE;
  a->status = info->status;
  if (info->status == GOWL_TEXT_FIELD_OK)
    {
      a->text = g_strdup (info->text != NULL ? info->text : "");
      a->cursor = info->cursor;
      a->anchor = info->anchor;
      a->complete = info->complete;
    }
  a->content_hint = info->content_hint;
  a->content_purpose = info->content_purpose;
  cmacs_glib_invoke_on_main (textfield_deliver, a, textfield_answer_free);
}

/* gowl's answer to an edit that had to wait.  Any thread; no Lisp.  */
static void
textfield_on_commit (gboolean delivered, gpointer user_data)
{
  TextfieldAnswer *a = g_new0 (TextfieldAnswer, 1);

  a->id = GPOINTER_TO_UINT (user_data);
  a->is_read = FALSE;
  a->delivered = delivered;
  cmacs_glib_invoke_on_main (textfield_deliver, a, textfield_answer_free);
}

/* ----------------------------------------------------------- Lisp half -- */

/* Hold the gowl lock for the rest of this call; the release is on the
   specpdl, so an `error' below cannot leave the dispatch thread
   wedged (see cmacs-gowl.c's own, which this mirrors).  */
static specpdl_ref
cmacs_gowl_lock_scoped (void)
{
  specpdl_ref count = SPECPDL_INDEX ();

  cmacs_gowl_lock ();
  record_unwind_protect_void (cmacs_gowl_unlock);
  return count;
}

/* CLIENT as a GowlClient, or signal.  Caller holds the scoped lock.  */
static GowlClient *
textfield_client (Lisp_Object client)
{
  GObject *obj = cmacs_gobject_unwrap (client);

  if (obj == NULL || !GOWL_IS_CLIENT (obj))
    error ("Not a GowlClient");
  return GOWL_CLIENT (obj);
}

static Lisp_Object
textfield_result_symbol (GowlTextCommitResult res)
{
  if (res == GOWL_TEXT_COMMIT_SENT)
    return intern_c_string ("sent");
  if (res == GOWL_TEXT_COMMIT_PENDING)
    return intern_c_string ("pending");
  return Qnil;
}

DEFUN ("gowl-client-has-text-input-p", Fgowl_client_has_text_input_p,
       Sgowl_client_has_text_input_p, 1, 1, 0,
       doc: /* Return non-nil if CLIENT can be reached through text-input-v3.
That is: it has a text input enabled on its surface right now, or --
with no input method running, and CLIENT holding the keyboard focus --
one the compositor can enter for the length of a read or an edit.  The
second is a promise of an attempt, not of a text field: a window with
nothing focused that takes text never answers, and `gowl-text-field-read'
then reports `no-field'.  nil when no compositor is running.  */)
  (Lisp_Object client)
{
  specpdl_ref lock_count = cmacs_gowl_lock_scoped ();
  GowlClient *c;
  gboolean has;

  if (cmacs_gowl_compositor == NULL)
    return unbind_to (lock_count, Qnil);
  c = textfield_client (client);
  has = gowl_compositor_client_has_text_input (cmacs_gowl_compositor, c);
  return unbind_to (lock_count, has ? Qt : Qnil);
}

DEFUN ("gowl-text-field-read", Fgowl_text_field_read,
       Sgowl_text_field_read, 2, 2, 0,
       doc: /* Read the text field that has focus in CLIENT, then call CALLBACK.
CLIENT must hold the keyboard focus.  The text is what the application
reports as text-input-v3 surrounding text.

Return nil when no text input reaches CLIENT (or one is busy with
another read or edit); CALLBACK is then never called.  Otherwise return
`sent' or `pending' and call CALLBACK exactly once, later, from the main
loop -- never before this returns -- with one argument, a plist:

  :status    `ok', `no-field' (nothing that takes text has CLIENT's
             focus) or `no-surrounding' (a field is there, but the
             application did not say what is in it)
  :text      the text, a string; nil unless :status is `ok'
  :cursor    the cursor, in BYTES of UTF-8 from the start of :text
  :anchor    the other end of the selection, likewise; equal to :cursor
             when nothing is selected
  :complete  nil when :text is long enough to be a window cut at the
             protocol's 4000-byte limit; non-nil means only "not known
             to be cut" -- some widgets report less than the whole field
  :hint      the field's content-hint bits (0 when not given)
  :purpose   its content purpose (0 normal; 8 password, 9 PIN)

An application that does not answer is reported `no-field' after a
quarter of a second.  If the compositor is stopped first, CALLBACK is
dropped without being called.  */)
  (Lisp_Object client, Lisp_Object callback)
{
  specpdl_ref lock_count = cmacs_gowl_lock_scoped ();
  GowlClient *c;
  GowlTextCommitResult res;
  guint id;

  if (cmacs_gowl_compositor == NULL)
    error ("Gowl compositor not running");
  c = textfield_client (client);
  if (!FUNCTIONP (callback))
    wrong_type_argument (Qfunctionp, callback);

  /* Nothing between the registration and gowl's verdict can signal,
     so the callback cannot be left in the table by an `error'.  */
  id = textfield_register (callback);
  res = gowl_compositor_read_text_field (cmacs_gowl_compositor, c,
                                         textfield_on_read,
                                         GUINT_TO_POINTER (id));
  if (res == GOWL_TEXT_COMMIT_UNAVAILABLE)
    textfield_take (id);
  return unbind_to (lock_count, textfield_result_symbol (res));
}

DEFUN ("gowl-text-field-replace", Fgowl_text_field_replace,
       Sgowl_text_field_replace, 4, 5, 0,
       doc: /* Replace text around the cursor of CLIENT's focused text field.
Delete DELETE-BEFORE bytes before the cursor and DELETE-AFTER bytes
after it, then insert TEXT (a string, or nil for none) at the cursor,
as one edit the application can undo as one.  The counts are BYTES of
UTF-8, as `gowl-text-field-read' reports offsets; with DELETE-BEFORE
the :cursor it reported and DELETE-AFTER the rest of its :text, this
replaces exactly what was read.  CLIENT must hold the keyboard focus.

Return nil when no text input reaches CLIENT: nothing was sent and
CALLBACK is not called.  Otherwise return `sent' (the edit went at
once) or `pending' (it waits for the application to enable its text
input, or TEXT is long and goes in several pieces), and call CALLBACK,
if non-nil, exactly once, later, from the main loop, with t when the
edit was delivered and nil when the application did not take it (it
had no text field, or stopped answering part way through a long
TEXT).  If the compositor is stopped first, CALLBACK is dropped.  */)
  (Lisp_Object client, Lisp_Object delete_before, Lisp_Object delete_after,
   Lisp_Object text, Lisp_Object callback)
{
  specpdl_ref lock_count = cmacs_gowl_lock_scoped ();
  GowlClient *c;
  GowlTextCommitResult res;
  gchar *utf8 = NULL;
  guint id = 0;

  if (cmacs_gowl_compositor == NULL)
    error ("Gowl compositor not running");
  c = textfield_client (client);
  CHECK_FIXNAT (delete_before);
  CHECK_FIXNAT (delete_after);
  if (XFIXNAT (delete_before) > G_MAXUINT32
      || XFIXNAT (delete_after) > G_MAXUINT32)
    args_out_of_range (delete_before, delete_after);
  if (!NILP (text))
    CHECK_STRING (text);
  if (!NILP (callback) && !FUNCTIONP (callback))
    wrong_type_argument (Qfunctionp, callback);

  /* From here to gowl's verdict nothing signals: the string and the
     registration cannot be leaked by an `error'.  */
  if (!NILP (text))
    utf8 = cmacs_dispatch_string_to_utf8 (text);
  if (!NILP (callback))
    id = textfield_register (callback);
  res = gowl_compositor_replace_text (cmacs_gowl_compositor, c,
                                      (guint) XFIXNAT (delete_before),
                                      (guint) XFIXNAT (delete_after),
                                      utf8,
                                      id != 0 ? textfield_on_commit : NULL,
                                      GUINT_TO_POINTER (id));
  g_free (utf8);

  if (id != 0)
    {
      if (res == GOWL_TEXT_COMMIT_UNAVAILABLE)
        textfield_take (id);
      else if (res == GOWL_TEXT_COMMIT_SENT)
        /* gowl reports an edit that went at once by its return value
           alone.  The Lisp caller is promised its callback either
           way, and promised it from the main loop, so queue it.  */
        textfield_on_commit (TRUE, GUINT_TO_POINTER (id));
    }
  return unbind_to (lock_count, textfield_result_symbol (res));
}

/* MODIFIERS, a list of symbols, as GowlKeyMod bits.  */
static gint
textfield_modifiers (Lisp_Object modifiers)
{
  gint mods = GOWL_KEY_MOD_NONE;
  Lisp_Object tail;

  for (tail = modifiers; CONSP (tail); tail = XCDR (tail))
    {
      Lisp_Object m = XCAR (tail);

      if (EQ (m, intern_c_string ("control")))
        mods |= GOWL_KEY_MOD_CTRL;
      else if (EQ (m, intern_c_string ("shift")))
        mods |= GOWL_KEY_MOD_SHIFT;
      else if (EQ (m, intern_c_string ("alt"))
               || EQ (m, intern_c_string ("meta")))
        mods |= GOWL_KEY_MOD_ALT;
      else if (EQ (m, intern_c_string ("super")))
        mods |= GOWL_KEY_MOD_LOGO;
      else
        xsignal2 (Qwrong_type_argument,
                  intern_c_string ("gowl-key-modifier-p"), m);
    }
  return mods;
}

DEFUN ("gowl-text-field-send-key", Fgowl_text_field_send_key,
       Sgowl_text_field_send_key, 2, 3, 0,
       doc: /* Press and release KEY in CLIENT with MODIFIERS held.
KEY is an XKB keysym name ("a", "v", "Return"); the key that produces
it in the current keyboard layout is the one sent, so "a" with
`(control)' is Ctrl+A whatever the layout.  MODIFIERS is a list of
`control', `shift', `alt' and `super'.

The event is synthetic: no compositor keybind sees it and it is not
recorded.  It goes by the seat, which reaches CLIENT when it holds the
keyboard focus (an X11 window included, since it then holds X focus
too); this never waits on the application.  Return t when both events
were delivered, nil when the layout has no such key or the compositor
refused -- the session is locked, or a launcher holds the keyboard.  */)
  (Lisp_Object client, Lisp_Object key, Lisp_Object modifiers)
{
  specpdl_ref lock_count = cmacs_gowl_lock_scoped ();
  GowlClient *c;
  xkb_keysym_t sym;
  guint32 keycode;
  gboolean shift = FALSE;
  gboolean ok;
  gint mods;

  if (cmacs_gowl_compositor == NULL)
    error ("Gowl compositor not running");
  c = textfield_client (client);
  CHECK_STRING (key);
  mods = textfield_modifiers (modifiers);

  sym = xkb_keysym_from_name (SSDATA (key), XKB_KEYSYM_NO_FLAGS);
  if (sym == XKB_KEY_NoSymbol)
    error ("Unknown key name: %s", SSDATA (key));
  keycode = gowl_compositor_keysym_to_keycode (cmacs_gowl_compositor,
                                               sym, &shift);
  if (keycode == 0)
    return unbind_to (lock_count, Qnil);
  if (shift)
    mods |= GOWL_KEY_MOD_SHIFT;

  ok = gowl_compositor_deliver_key (cmacs_gowl_compositor, c, keycode, TRUE,
                                    mods, GOWL_KEY_DELIVERY_SEAT);
  /* The release goes even if the press was refused half way: a key
     left down in the application is worse than a spare release.  */
  ok = gowl_compositor_deliver_key (cmacs_gowl_compositor, c, keycode, FALSE,
                                    mods, GOWL_KEY_DELIVERY_SEAT) && ok;
  return unbind_to (lock_count, ok ? Qt : Qnil);
}

DEFUN ("gowl-clipboard-set-transient", Fgowl_clipboard_set_transient,
       Sgowl_clipboard_set_transient, 1, 1, 0,
       doc: /* Set the Wayland clipboard to TEXT, marked "paste me, do not keep me".
Like `gowl-clipboard-set', but the clipboard also offers the
password-manager hint (x-kde-passwordManagerHint), which gowl's
clipboard history and `gowl-clipboard-watch's kill-ring sync both
leave out.  For text that is on the clipboard only to be pasted once,
and for putting the user's own clipboard back afterwards.  */)
  (Lisp_Object text)
{
  specpdl_ref lock_count = cmacs_gowl_lock_scoped ();
  GowlSeat *seat;
  gchar *utf8;

  if (cmacs_gowl_compositor == NULL)
    error ("Gowl compositor not running");
  CHECK_STRING (text);
  seat = gowl_compositor_get_seat (cmacs_gowl_compositor);
  if (seat != NULL)
    {
      utf8 = cmacs_dispatch_string_to_utf8 (text);
      gowl_seat_set_clipboard_transient (seat, utf8);
      g_free (utf8);
    }
  return unbind_to (lock_count, Qnil);
}

void
syms_of_cmacs_gowl_textfield (void)
{
  Vcmacs_gowl_textfield_callbacks = Qnil;
  staticpro (&Vcmacs_gowl_textfield_callbacks);

  defsubr (&Sgowl_client_has_text_input_p);
  defsubr (&Sgowl_text_field_read);
  defsubr (&Sgowl_text_field_replace);
  defsubr (&Sgowl_text_field_send_key);
  defsubr (&Sgowl_clipboard_set_transient);
}

#endif /* HAVE_CMACS_GOWL */
