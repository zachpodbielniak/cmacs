/* Clawtilla fleet client for CMacs -- Lisp primitives.

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

SPDX-License-Identifier: AGPL-3.0-or-later  */

#include <config.h>

#ifdef HAVE_CMACS_CLAWTILLA

/* This translation unit must not see <clawtilla.h>.  See
   cmacs-clawtilla.h for why the split is worth keeping.  */
#include "lisp.h"
#include "coding.h"
#include "cmacs-eval-dispatch.h"
#include "cmacs-clawtilla.h"

/* Vcmacs_clawtilla_event_functions and Vcmacs_clawtilla_state_functions
   are DEFVAR_LISP'd below and are deliberately NOT declared here.
   make-docfile emits each one into globals.h as a macro expanding to a
   struct member, so a `static Lisp_Object' of that name expands into a
   syntax error reported in globals.h -- a file that does not mention
   the source that caused it.  */

static Lisp_Object
cmacs_clawt_string (const char *text)
{
  return text != NULL ? build_string (text) : Qnil;
}

/* A handle or a cursor arrives as a Lisp integer and is a uint64 here.
   `check_uinteger_max' takes fixnums and bignums both, and signals for
   a negative or oversized one -- which is the right place for that
   error, because this is still the caller's stack.  */
static uint64_t
cmacs_clawt_uint (Lisp_Object value)
{
  return check_uinteger_max (value, UINT64_MAX);
}

static char *
cmacs_clawt_dup (Lisp_Object string)
{
  Lisp_Object encoded;

  CHECK_STRING (string);
  encoded = ENCODE_UTF_8 (string);

  return xstrdup (SSDATA (encoded));
}

/* ------------------------------------------------------------------
   Delivery out of GLib callbacks.

   Everything below runs from a GLib callback, where Emacs is not
   expecting Lisp: `cmacs_dispatch_safe_call*' is what clears
   `waiting_for_input' around the call, without which an error signalled
   inside the handler aborts Emacs rather than unwinding.
   ------------------------------------------------------------------ */

void
cmacs_clawt_deliver_reply (uint64_t cookie, const char *json,
                           const char *error)
{
  Lisp_Object payload = cmacs_clawt_string (json);
  Lisp_Object message = cmacs_clawt_string (error);

  /* The cookie is spent here whichever way the request went, so a
     reply that somehow arrived twice cannot call Lisp twice.  */
  cmacs_dispatch_callback_invokeN (cookie, 2,
                                   ((Lisp_Object[]) { payload, message }));
  cmacs_dispatch_callback_drop (cookie);
}

/* Run a hook, rather than calling one.

   These two used to hand the hook's VALUE to cmacs_dispatch_safe_callN
   as the function to call.  A hook's value is a LIST of functions, and
   funcalling a list is not running a hook -- it fails inside the
   dispatch guard, where the error is swallowed by design because
   signalling out of a GLib callback would abort Emacs rather than
   unwind.  So every daemon event and every connection-state change was
   delivered to nothing, in silence: no live redraws, no appended
   messages, no alerts, and no error anywhere to say why.

   `run-hook-with-args' takes the hook's SYMBOL, so that is what goes
   through the guard now.  */
static void
cmacs_clawt_run_hook (Lisp_Object hook, ptrdiff_t nargs, Lisp_Object *args)
{
  Lisp_Object call[4];
  ptrdiff_t i;

  eassert (nargs <= 3);

  call[0] = hook;

  for (i = 0; i < nargs; i++)
    call[i + 1] = args[i];

  cmacs_dispatch_safe_callN (Qrun_hook_with_args, nargs + 1, call);
}

void
cmacs_clawt_deliver_event (uint64_t handle, const char *kind,
                           const char *json)
{
  Lisp_Object args[3];

  args[0] = make_uint (handle);
  args[1] = cmacs_clawt_string (kind);
  args[2] = cmacs_clawt_string (json);

  cmacs_clawt_run_hook (Qcmacs_clawtilla_event_functions, 3, args);
}

void
cmacs_clawt_deliver_state (uint64_t handle, const char *state)
{
  Lisp_Object args[2];

  args[0] = make_uint (handle);
  args[1] = cmacs_clawt_string (state);

  cmacs_clawt_run_hook (Qcmacs_clawtilla_state_functions, 2, args);
}

/* ------------------------------------------------------------------
   Primitives.
   ------------------------------------------------------------------ */

DEFUN ("cmacs-clawtilla-supported-p", Fcmacs_clawtilla_supported_p,
       Scmacs_clawtilla_supported_p, 0, 0, 0,
       doc: /* Return non-nil if this build has the clawtilla client.

The runtime companion to `IS-CMACS-CLAWTILLA': the variable says the
subsystem was compiled in, this says its primitives are reachable.  */)
  (void)
{
  return Qt;
}

DEFUN ("cmacs-clawtilla--default-socket", Fcmacs_clawtilla__default_socket,
       Scmacs_clawtilla__default_socket, 0, 0, 0,
       doc: /* Return the socket path a local daemon listens on by default.

Asked of the library rather than rebuilt here, so a change to where
clawtillad listens does not need a matching edit in cmacs.  */)
  (void)
{
  char *path = cmacs_clawt_default_socket_path ();
  Lisp_Object result = cmacs_clawt_string (path);

  g_free (path);
  return result;
}

DEFUN ("cmacs-clawtilla--connect-local", Fcmacs_clawtilla__connect_local,
       Scmacs_clawtilla__connect_local, 2, 2, 0,
       doc: /* Connect to the daemon on SOCKET-PATH; call CALLBACK when done.

SOCKET-PATH nil means the library's default.  Returns the connection
handle immediately -- the connection is not established yet, and
`cmacs-clawtilla--connected-p' is nil until CALLBACK has run.

CALLBACK receives (PAYLOAD ERROR): a JSON string and nil on success, or
nil and a message on failure.  Failure is not signalled because it is
discovered in a GLib callback, where signalling aborts Emacs rather
than unwinding.  */)
  (Lisp_Object socket_path, Lisp_Object callback)
{
  char *path = NULL;
  uint64_t handle;
  uint64_t cookie;

  if (!NILP (socket_path))
    path = cmacs_clawt_dup (socket_path);

  cookie = cmacs_dispatch_callback_register (callback);
  handle = cmacs_clawt_connect_local (path, cookie);
  xfree (path);

  if (handle == 0)
    {
      cmacs_dispatch_callback_drop (cookie);
      return Qnil;
    }

  return make_uint (handle);
}

DEFUN ("cmacs-clawtilla--connect-tcp", Fcmacs_clawtilla__connect_tcp,
       Scmacs_clawtilla__connect_tcp, 6, 6, 0,
       doc: /* Connect to a daemon at HOST:PORT with TOKEN; call CALLBACK.

TLS non-nil uses TLS.  INSECURE non-nil accepts a certificate that does
not validate, which trusts anything answering on that address and is
never the default.

A remote daemon is the reason this is asynchronous: DNS, a TLS
handshake, or a tailnet that has moved can take seconds, and under
`--gowl' this process is also the compositor.  See
`cmacs-clawtilla--connect-local' for the CALLBACK contract.  */)
  (Lisp_Object host, Lisp_Object port, Lisp_Object token, Lisp_Object tls,
   Lisp_Object insecure, Lisp_Object callback)
{
  char *c_host;
  char *c_token = NULL;
  uint64_t handle;
  uint64_t cookie;

  CHECK_FIXNUM (port);
  c_host = cmacs_clawt_dup (host);

  if (!NILP (token))
    c_token = cmacs_clawt_dup (token);

  cookie = cmacs_dispatch_callback_register (callback);
  handle = cmacs_clawt_connect_tcp (c_host, (int) XFIXNUM (port), c_token,
                                    !NILP (tls), !NILP (insecure), cookie);
  xfree (c_host);
  xfree (c_token);

  if (handle == 0)
    {
      cmacs_dispatch_callback_drop (cookie);
      return Qnil;
    }

  return make_uint (handle);
}

DEFUN ("cmacs-clawtilla--request", Fcmacs_clawtilla__request,
       Scmacs_clawtilla__request, 4, 4, 0,
       doc: /* Send KIND with PAYLOAD on HANDLE; call CALLBACK with the reply.

PAYLOAD is a JSON string or nil.  CALLBACK receives (PAYLOAD ERROR) as
`cmacs-clawtilla--connect-local' describes.

There is deliberately no synchronous form.  The library's blocking
request turns the caller's main context while it waits, and here that
context is the editor's -- turning it from inside a primitive re-enters
Lisp where Emacs does not expect it.  */)
  (Lisp_Object handle, Lisp_Object kind, Lisp_Object payload,
   Lisp_Object callback)
{
  char *c_kind;
  char *c_payload = NULL;
  uint64_t cookie;
  bool sent;

  CHECK_INTEGER (handle);
  c_kind = cmacs_clawt_dup (kind);

  if (!NILP (payload))
    c_payload = cmacs_clawt_dup (payload);

  cookie = cmacs_dispatch_callback_register (callback);
  sent = cmacs_clawt_request (cmacs_clawt_uint (handle), c_kind, c_payload,
                              cookie);
  xfree (c_kind);
  xfree (c_payload);

  if (!sent)
    {
      cmacs_dispatch_callback_drop (cookie);
      return Qnil;
    }

  return Qt;
}

DEFUN ("cmacs-clawtilla--subscribe", Fcmacs_clawtilla__subscribe,
       Scmacs_clawtilla__subscribe, 3, 3, 0,
       doc: /* Subscribe HANDLE to the event stream from CURSOR.

CALLBACK receives (PAYLOAD ERROR); PAYLOAD carries `resumed', which is
false when the daemon could not resume from CURSOR.  That is a gap in
the stream, not a failure: anything cached from before it has to be
refetched rather than appended to.  */)
  (Lisp_Object handle, Lisp_Object cursor, Lisp_Object callback)
{
  uint64_t cookie;
  bool sent;

  CHECK_INTEGER (handle);
  CHECK_INTEGER (cursor);

  cookie = cmacs_dispatch_callback_register (callback);
  sent = cmacs_clawt_subscribe (cmacs_clawt_uint (handle),
                                cmacs_clawt_uint (cursor), cookie);

  if (!sent)
    {
      cmacs_dispatch_callback_drop (cookie);
      return Qnil;
    }

  return Qt;
}

DEFUN ("cmacs-clawtilla--disconnect", Fcmacs_clawtilla__disconnect,
       Scmacs_clawtilla__disconnect, 1, 1, 0,
       doc: /* Drop HANDLE's connection, keeping the handle.  */)
  (Lisp_Object handle)
{
  CHECK_INTEGER (handle);
  return cmacs_clawt_disconnect (cmacs_clawt_uint (handle)) ? Qt : Qnil;
}

DEFUN ("cmacs-clawtilla--close", Fcmacs_clawtilla__close,
       Scmacs_clawtilla__close, 1, 1, 0,
       doc: /* Forget HANDLE entirely, disconnecting it first.

A handle is never reused, so a reply still in flight for a closed
connection finds nothing rather than finding whatever took its place.  */)
  (Lisp_Object handle)
{
  CHECK_INTEGER (handle);
  return cmacs_clawt_close (cmacs_clawt_uint (handle)) ? Qt : Qnil;
}

DEFUN ("cmacs-clawtilla--connected-p", Fcmacs_clawtilla__connected_p,
       Scmacs_clawtilla__connected_p, 1, 1, 0,
       doc: /* Return non-nil if HANDLE has a live link to a daemon.  */)
  (Lisp_Object handle)
{
  CHECK_INTEGER (handle);
  return cmacs_clawt_is_connected (cmacs_clawt_uint (handle)) ? Qt : Qnil;
}

DEFUN ("cmacs-clawtilla--reconnecting-p", Fcmacs_clawtilla__reconnecting_p,
       Scmacs_clawtilla__reconnecting_p, 1, 1, 0,
       doc: /* Return non-nil if HANDLE is retrying a lost connection.

Distinct from not being connected: a handle nobody has connected yet is
also not connected, and that is not a state worth drawing.  */)
  (Lisp_Object handle)
{
  CHECK_INTEGER (handle);
  return cmacs_clawt_is_reconnecting (cmacs_clawt_uint (handle)) ? Qt : Qnil;
}

DEFUN ("cmacs-clawtilla--set-auto-reconnect",
       Fcmacs_clawtilla__set_auto_reconnect,
       Scmacs_clawtilla__set_auto_reconnect, 2, 2, 0,
       doc: /* Make HANDLE retry a lost connection when ENABLED is non-nil.  */)
  (Lisp_Object handle, Lisp_Object enabled)
{
  CHECK_INTEGER (handle);
  return cmacs_clawt_set_auto_reconnect (cmacs_clawt_uint (handle),
                                         !NILP (enabled)) ? Qt : Qnil;
}

DEFUN ("cmacs-clawtilla--cursor", Fcmacs_clawtilla__cursor,
       Scmacs_clawtilla__cursor, 1, 1, 0,
       doc: /* Return the event cursor HANDLE has reached.  */)
  (Lisp_Object handle)
{
  CHECK_INTEGER (handle);
  return make_uint (cmacs_clawt_cursor (cmacs_clawt_uint (handle)));
}

DEFUN ("cmacs-clawtilla--connections", Fcmacs_clawtilla__connections,
       Scmacs_clawtilla__connections, 0, 0, 0,
       doc: /* Return every open connection as a JSON string.  */)
  (void)
{
  char *json = cmacs_clawt_handle_list_json ();
  Lisp_Object result = cmacs_clawt_string (json);

  cmacs_clawt_free (json);
  return result;
}

DEFUN ("cmacs-clawtilla--enum", Fcmacs_clawtilla__enum,
       Scmacs_clawtilla__enum, 1, 1, 0,
       doc: /* Return the values libclawt enumerates for FAMILY, as JSON.

FAMILY is one of "section", "computer-type", "computer-view",
"import-mode", "measure-unit", "memory-scope", "appearance-scheme",
"appearance-theme" or "relabel"; nil for anything else.  A section
carries its own pages -- there is no flat page family, because
clawtilla ships no clawt_page_nth() and says why: a page is reached
through its section, never chosen from a list of eleven.

These are asked for rather than written down.  clawtilla's `make parity'
fails a client that spells any of the values out, because having a copy
of the list is what makes a client able to disagree with it -- so a
palette added to libclawt appears in the picker here with no edit.  */)
  (Lisp_Object family)
{
  char *c_family = cmacs_clawt_dup (family);
  char *json = cmacs_clawt_enum_json (c_family);
  Lisp_Object result = cmacs_clawt_string (json);

  xfree (c_family);
  cmacs_clawt_free (json);
  return result;
}

DEFUN ("cmacs-clawtilla--connections-path",
       Fcmacs_clawtilla__connections_path,
       Scmacs_clawtilla__connections_path, 0, 0, 0,
       doc: /* Return the file clawtilla keeps saved connections in.  */)
  (void)
{
  char *path = cmacs_clawt_connections_path ();
  Lisp_Object result = cmacs_clawt_string (path);

  cmacs_clawt_free (path);
  return result;
}

DEFUN ("cmacs-clawtilla--saved-connections",
       Fcmacs_clawtilla__connections_saved,
       Scmacs_clawtilla__connections_saved, 0, 1, 0,
       doc: /* Return the saved connection profiles in PATH as JSON.

PATH nil means clawtilla's own connections file, which every one of its
clients reads -- so a profile added in the GTK client is simply here.
Returns nil when the file cannot be read; a file that does not exist
yet is an empty array, because nobody having saved a profile is the
ordinary first run and not a failure.

Each profile carries a `describe' string built by the library.  That is
the one that hides the token, and rebuilding it here would be a second
chance to print one.  */)
  (Lisp_Object path)
{
  char *c_path = NULL;
  char *error = NULL;
  char *json;
  Lisp_Object result;

  if (!NILP (path))
    c_path = cmacs_clawt_dup (path);

  json = cmacs_clawt_connections_json (c_path, &error);
  result = cmacs_clawt_string (json);

  xfree (c_path);
  cmacs_clawt_free (json);
  cmacs_clawt_free (error);
  return result;
}

DEFUN ("cmacs-clawtilla--connect-profile", Fcmacs_clawtilla__connect_profile,
       Scmacs_clawtilla__connect_profile, 2, 3, 0,
       doc: /* Connect to the saved profile NAME; call CALLBACK when done.

PATH nil means clawtilla's own connections file.  The profile decides
whether this is a unix socket or TCP, and carries the token and the TLS
decision -- the library turns it into the right client, so cmacs does
not have a second opinion about what a profile means.

Returns the handle, or nil if there is no such profile.  See
`cmacs-clawtilla--connect-local' for the CALLBACK contract.  */)
  (Lisp_Object name, Lisp_Object callback, Lisp_Object path)
{
  char *c_name = cmacs_clawt_dup (name);
  char *c_path = NULL;
  char *error = NULL;
  uint64_t cookie;
  uint64_t handle;

  if (!NILP (path))
    c_path = cmacs_clawt_dup (path);

  cookie = cmacs_dispatch_callback_register (callback);
  handle = cmacs_clawt_connect_profile (c_path, c_name, cookie, &error);

  xfree (c_name);
  xfree (c_path);

  if (handle == 0)
    {
      Lisp_Object message = cmacs_clawt_string (error);

      cmacs_dispatch_callback_drop (cookie);
      cmacs_clawt_free (error);

      /* Signalled, not delivered: this failure is found on the caller's
         own stack, so there is no GLib callback to unwind out of.  */
      if (!NILP (message))
        xsignal1 (Qerror, message);

      return Qnil;
    }

  cmacs_clawt_free (error);
  return make_uint (handle);
}

DEFUN ("cmacs-clawtilla--link-notice", Fcmacs_clawtilla__link_notice,
       Scmacs_clawtilla__link_notice, 1, 3, 0,
       doc: /* Return what to tell someone about HANDLE's link, as a string.

NAME names a saved profile, so the advice can say where that daemon is.
EVER-CONNECTED distinguishes "never reached" from "was there and went
away", which is the caller's to remember: once disconnected the client
cannot tell those apart, and they have different remedies -- only one
of which is on this machine.  */)
  (Lisp_Object handle, Lisp_Object name, Lisp_Object ever_connected)
{
  char *c_name = NULL;
  char *text;
  Lisp_Object result;

  CHECK_INTEGER (handle);

  if (!NILP (name))
    c_name = cmacs_clawt_dup (name);

  text = cmacs_clawt_link_notice (cmacs_clawt_uint (handle), c_name,
                                  !NILP (ever_connected));
  result = cmacs_clawt_string (text);

  xfree (c_name);
  cmacs_clawt_free (text);
  return result;
}

/* ------------------------------------------------------------------
   Presentation, answered by the library.

   Every one of these exists because clawtilla already decided it and
   requires its clients to ask rather than answer.  The failures are on
   record there: the CLI read `busy' and `peer' for as long as they
   existed and rendered neither, and the web client drew a bare "busy"
   badge that dropped `peer'.  A sentence assembled in three places is
   three sentences, and `make parity' compares which shared symbols each
   client reaches for so a third one cannot drift quietly.
   ------------------------------------------------------------------ */

DEFUN ("cmacs-clawtilla--activity-label", Fcmacs_clawtilla__activity_label,
       Scmacs_clawtilla__activity_label, 1, 2, 0,
       doc: /* Return what an agent is doing, as the library words it.

BUSY is whether a turn is running and PEER the agent it is with, if
any.  Not assembled here: two other clients already say this sentence,
and a third version of it is a third sentence.  */)
  (Lisp_Object busy, Lisp_Object peer)
{
  char *c_peer = NILP (peer) ? NULL : cmacs_clawt_dup (peer);
  char *text = cmacs_clawt_activity_label (!NILP (busy), c_peer);
  Lisp_Object result = cmacs_clawt_string (text);

  xfree (c_peer);
  cmacs_clawt_free (text);
  return result;
}

DEFUN ("cmacs-clawtilla--team-tally", Fcmacs_clawtilla__team_tally,
       Scmacs_clawtilla__team_tally, 1, 2, 0,
       doc: /* Count AGENTS-JSON for TEAM-ID, as JSON.

TEAM-ID nil counts the agents in no team.  Counted by the library
because three clients counting the same thing is three chances to
disagree about what "active" means.  */)
  (Lisp_Object agents_json, Lisp_Object team_id)
{
  char *c_agents = cmacs_clawt_dup (agents_json);
  char *c_team = NILP (team_id) ? NULL : cmacs_clawt_dup (team_id);
  char *json = cmacs_clawt_team_tally_json (c_agents, c_team);
  Lisp_Object result = cmacs_clawt_string (json);

  xfree (c_agents);
  xfree (c_team);
  cmacs_clawt_free (json);
  return result;
}

DEFUN ("cmacs-clawtilla--unread-should-count",
       Fcmacs_clawtilla__unread_should_count,
       Scmacs_clawtilla__unread_should_count, 5, 6, 0,
       doc: /* Return non-nil if an event should raise an unread count.

ROOM-ID is where it happened, VIEWING the room on screen, FROM who sent
it, EVENT-TS when, CONNECTED-AT when this link came up, and ROOMS a
JSON array of the rooms this client has a row for.

The rule is the library's, and every clause of it earns its place: not
your own message, not the room you are looking at, not older than the
connection, and not a room with no row -- there is nothing there to
show a count on.

ROOMS is not optional in the way it looks.  The library answers nil
when it is empty, so omitting it makes an unread count impossible; the
first cut of this primitive passed nothing and no count could ever
rise.  */)
  (Lisp_Object room_id, Lisp_Object viewing, Lisp_Object from,
   Lisp_Object event_ts, Lisp_Object connected_at, Lisp_Object rooms)
{
  char *c_room = NILP (room_id) ? NULL : cmacs_clawt_dup (room_id);
  char *c_viewing = NILP (viewing) ? NULL : cmacs_clawt_dup (viewing);
  char *c_from = NILP (from) ? NULL : cmacs_clawt_dup (from);
  char *c_rooms = NILP (rooms) ? NULL : cmacs_clawt_dup (rooms);
  bool counts;

  CHECK_INTEGER (event_ts);
  CHECK_INTEGER (connected_at);

  counts = cmacs_clawt_unread_should_count (c_room, c_viewing, c_from,
                                            XFIXNUM (event_ts),
                                            XFIXNUM (connected_at), c_rooms);
  xfree (c_room);
  xfree (c_viewing);
  xfree (c_from);
  xfree (c_rooms);
  return counts ? Qt : Qnil;
}

DEFUN ("cmacs-clawtilla--run-is-start", Fcmacs_clawtilla__run_is_start,
       Scmacs_clawtilla__run_is_start, 4, 4, 0,
       doc: /* Return whether a message starts a run, as JSON.

Answers two questions, because they are different ones: a new day
always starts a run, but a run can start without the day changing.  A
client that collapsed them would either lose the day divider or draw
one on every message.  */)
  (Lisp_Object previous_sender, Lisp_Object previous_day, Lisp_Object sender,
   Lisp_Object day)
{
  char *c_ps = NILP (previous_sender) ? NULL
                                      : cmacs_clawt_dup (previous_sender);
  char *c_pd = NILP (previous_day) ? NULL : cmacs_clawt_dup (previous_day);
  char *c_s = NILP (sender) ? NULL : cmacs_clawt_dup (sender);
  char *c_d = NILP (day) ? NULL : cmacs_clawt_dup (day);
  char *json = cmacs_clawt_run_is_start (c_ps, c_pd, c_s, c_d);
  Lisp_Object result = cmacs_clawt_string (json);

  xfree (c_ps);
  xfree (c_pd);
  xfree (c_s);
  xfree (c_d);
  cmacs_clawt_free (json);
  return result;
}

DEFUN ("cmacs-clawtilla--time-label", Fcmacs_clawtilla__time_label,
       Scmacs_clawtilla__time_label, 1, 2, 0,
       doc: /* Return the transcript stamp for SECONDS.

DAY non-nil asks for the day divider's wording instead.  One stamp and
one format across every client, rather than each inventing when a time
needs its date.  */)
  (Lisp_Object seconds, Lisp_Object day)
{
  char *text;
  Lisp_Object result;

  CHECK_INTEGER (seconds);
  text = NILP (day) ? cmacs_clawt_chat_time_label (XFIXNUM (seconds))
                    : cmacs_clawt_chat_day_label (XFIXNUM (seconds));
  result = cmacs_clawt_string (text);
  cmacs_clawt_free (text);
  return result;
}

DEFUN ("cmacs-clawtilla--alert-tier", Fcmacs_clawtilla__alert_tier,
       Scmacs_clawtilla__alert_tier, 1, 3, 0,
       doc: /* Return the alert tier for an event of KIND about SUBJECT.

One of "skip", "routine", "notice" or "error".  Which events are worth
interrupting somebody for is a judgement the library makes once.  */)
  (Lisp_Object kind, Lisp_Object subject, Lisp_Object timestamp)
{
  char *c_kind = cmacs_clawt_dup (kind);
  char *c_subject = NILP (subject) ? NULL : cmacs_clawt_dup (subject);
  char *tier = cmacs_clawt_alert_tier (c_kind, c_subject,
                                       NILP (timestamp)
                                       ? 0 : XFIXNUM (timestamp));
  Lisp_Object result = cmacs_clawt_string (tier);

  xfree (c_kind);
  xfree (c_subject);
  cmacs_clawt_free (tier);
  return result;
}

DEFUN ("cmacs-clawtilla--alert-arrives-read",
       Fcmacs_clawtilla__alert_arrives_read,
       Scmacs_clawtilla__alert_arrives_read, 2, 2, 0,
       doc: /* Return non-nil if an alert of TIER arrives already read.

SHOWING is whether the alerts surface is in front of the person.  An
alert they are looking at when it lands has been seen, and marking it
unread would leave a count nobody can clear by reading.  */)
  (Lisp_Object showing, Lisp_Object tier)
{
  char *c_tier = NILP (tier) ? NULL : cmacs_clawt_dup (tier);
  bool read = cmacs_clawt_alert_arrives_read (!NILP (showing), c_tier);

  xfree (c_tier);
  return read ? Qt : Qnil;
}

DEFUN ("cmacs-clawtilla--markdown", Fcmacs_clawtilla__markdown,
       Scmacs_clawtilla__markdown, 1, 1, 0,
       doc: /* Render MARKDOWN through the library, returning Pango markup.

Emacs wants text properties rather than markup, so the Lisp side turns
the tags into faces -- but the parse is the library's cmark, which is
the one both graphical clients use.  One markdown implementation for
three clients, rather than two and a hand-rolled third.  */)
  (Lisp_Object markdown)
{
  char *c_markdown = cmacs_clawt_dup (markdown);
  char *pango = cmacs_clawt_markdown (c_markdown);
  Lisp_Object result = cmacs_clawt_string (pango);

  xfree (c_markdown);
  cmacs_clawt_free (pango);
  return result;
}

DEFUN ("cmacs-clawtilla--step-summary", Fcmacs_clawtilla__step_summary,
       Scmacs_clawtilla__step_summary, 2, 4, 0,
       doc: /* Summarise STEPS-JSON between FROM and TO.

Reads "Read 3 files, Changed 2 files, Ran 1 command" rather than
labelling every operation a command.  Counts are tool invocations, not
distinct files.  */)
  (Lisp_Object steps_json, Lisp_Object agent, Lisp_Object from,
   Lisp_Object to)
{
  char *c_steps = cmacs_clawt_dup (steps_json);
  char *c_agent = NILP (agent) ? NULL : cmacs_clawt_dup (agent);
  char *text = cmacs_clawt_step_summary (c_steps, c_agent,
                                         NILP (from) ? 0 : XFIXNUM (from),
                                         NILP (to) ? -1 : XFIXNUM (to));
  Lisp_Object result = cmacs_clawt_string (text);

  xfree (c_steps);
  xfree (c_agent);
  cmacs_clawt_free (text);
  return result;
}

DEFUN ("cmacs-clawtilla--steps", Fcmacs_clawtilla__steps,
       Scmacs_clawtilla__steps, 1, 2, 0,
       doc: /* Return STEPS-JSON normalised through the library, as JSON.

Each step gains its tone -- how it should read -- from
`clawt_turn_step_tone', so a client is not deciding for itself whether
a step is progress or a failure.  */)
  (Lisp_Object steps_json, Lisp_Object agent)
{
  char *c_steps = cmacs_clawt_dup (steps_json);
  char *c_agent = NILP (agent) ? NULL : cmacs_clawt_dup (agent);
  char *json = cmacs_clawt_steps_to_json (c_steps, c_agent);
  Lisp_Object result = cmacs_clawt_string (json);

  xfree (c_steps);
  xfree (c_agent);
  cmacs_clawt_free (json);
  return result;
}

DEFUN ("cmacs-clawtilla--step-precedes", Fcmacs_clawtilla__step_precedes,
       Scmacs_clawtilla__step_precedes, 2, 3, 0,
       doc: /* Return non-nil if STEP-JSON belongs before MESSAGE-TS.

This is how live steps merge into history rather than piling up after
it once the turn has finished.  */)
  (Lisp_Object step_json, Lisp_Object message_ts, Lisp_Object agent)
{
  char *c_step = cmacs_clawt_dup (step_json);
  char *c_agent = NILP (agent) ? NULL : cmacs_clawt_dup (agent);
  bool precedes;

  CHECK_INTEGER (message_ts);
  precedes = cmacs_clawt_step_precedes (c_step, c_agent,
                                        XFIXNUM (message_ts));
  xfree (c_step);
  xfree (c_agent);
  return precedes ? Qt : Qnil;
}

void
syms_of_cmacs_clawtilla_defuns (void)
{
  /* The hooks are run by symbol, so the symbols are interned here
     rather than reached through the DEFVAR's value.  */
  DEFSYM (Qcmacs_clawtilla_event_functions, "cmacs-clawtilla-event-functions");
  DEFSYM (Qcmacs_clawtilla_state_functions, "cmacs-clawtilla-state-functions");

  DEFVAR_LISP ("cmacs-clawtilla-event-functions",
               Vcmacs_clawtilla_event_functions,
               doc: /* Functions called with (HANDLE KIND JSON) per daemon event.

A hook rather than one callback because more than one buffer wants the
same event: the fleet list redraws an agent's state while that agent's
transcript appends the message, and neither owns the connection.  */);
  Vcmacs_clawtilla_event_functions = Qnil;

  DEFVAR_LISP ("cmacs-clawtilla-state-functions",
               Vcmacs_clawtilla_state_functions,
               doc: /* Functions called with (HANDLE STATE) when a link changes.

STATE is the string "connected", "disconnected" or "resync".  A resync
means the daemon could not resume the event cursor, so the stream has a
gap and anything cached from before it must be refetched.  */);
  Vcmacs_clawtilla_state_functions = Qnil;

  defsubr (&Scmacs_clawtilla_supported_p);
  defsubr (&Scmacs_clawtilla__default_socket);
  defsubr (&Scmacs_clawtilla__connect_local);
  defsubr (&Scmacs_clawtilla__connect_tcp);
  defsubr (&Scmacs_clawtilla__request);
  defsubr (&Scmacs_clawtilla__subscribe);
  defsubr (&Scmacs_clawtilla__disconnect);
  defsubr (&Scmacs_clawtilla__close);
  defsubr (&Scmacs_clawtilla__connected_p);
  defsubr (&Scmacs_clawtilla__reconnecting_p);
  defsubr (&Scmacs_clawtilla__set_auto_reconnect);
  defsubr (&Scmacs_clawtilla__cursor);
  defsubr (&Scmacs_clawtilla__connections);
  defsubr (&Scmacs_clawtilla__enum);
  defsubr (&Scmacs_clawtilla__connections_path);
  defsubr (&Scmacs_clawtilla__connections_saved);
  defsubr (&Scmacs_clawtilla__connect_profile);
  defsubr (&Scmacs_clawtilla__link_notice);
  defsubr (&Scmacs_clawtilla__activity_label);
  defsubr (&Scmacs_clawtilla__team_tally);
  defsubr (&Scmacs_clawtilla__unread_should_count);
  defsubr (&Scmacs_clawtilla__run_is_start);
  defsubr (&Scmacs_clawtilla__time_label);
  defsubr (&Scmacs_clawtilla__alert_tier);
  defsubr (&Scmacs_clawtilla__alert_arrives_read);
  defsubr (&Scmacs_clawtilla__markdown);
  defsubr (&Scmacs_clawtilla__step_summary);
  defsubr (&Scmacs_clawtilla__steps);
  defsubr (&Scmacs_clawtilla__step_precedes);
}

#endif /* HAVE_CMACS_CLAWTILLA */
