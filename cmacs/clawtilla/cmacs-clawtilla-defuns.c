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

void
cmacs_clawt_deliver_event (uint64_t handle, const char *kind,
                           const char *json)
{
  Lisp_Object args[3];

  args[0] = make_uint (handle);
  args[1] = cmacs_clawt_string (kind);
  args[2] = cmacs_clawt_string (json);

  cmacs_dispatch_safe_callN (Vcmacs_clawtilla_event_functions, 3, args);
}

void
cmacs_clawt_deliver_state (uint64_t handle, const char *state)
{
  Lisp_Object args[2];

  args[0] = make_uint (handle);
  args[1] = cmacs_clawt_string (state);

  cmacs_dispatch_safe_callN (Vcmacs_clawtilla_state_functions, 2, args);
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

void
syms_of_cmacs_clawtilla_defuns (void)
{
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
}

#endif /* HAVE_CMACS_CLAWTILLA */
