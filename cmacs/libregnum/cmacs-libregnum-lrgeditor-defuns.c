/* cmacs-libregnum-lrgeditor-defuns.c --- Elisp entry points for lrgeditor.
 * Copyright (C) 2026 Zach Podbielniak
 * SPDX-License-Identifier: AGPL-3.0-or-later
 *
 * The Lisp half of the embedded lrgeditor shell.  This TU sees lisp.h and
 * never <libregnum.h>; everything libregnum-shaped goes through the plain
 * C host API in cmacs-libregnum-lrgeditor.h.  cmacs-lrgeditor.el builds
 * the buffer, the keymap and the commands on top of these. */

#include <config.h>

#ifdef HAVE_CMACS_LIBREGNUM

#include "lisp.h"
#include "buffer.h"
#include "coding.h"
#include "cmacs-libregnum.h"
#include "cmacs-libregnum-render.h"
#include "cmacs-libregnum-lrgeditor.h"

/* The view attached to BUFFER, or signal. */
static CmacsLibregnumView *
lrgeditor_view (Lisp_Object buffer)
{
  CmacsLibregnumView *v;

  CHECK_BUFFER (buffer);
  v = cmacs_libregnum_view_for_buffer (buffer);
  if (!v)
    error ("cmacs-lrgeditor: no libregnum view attached to buffer");
  return v;
}

/* The shell hosted in BUFFER's view, or signal. */
static CmacsLrgeditorHost *
lrgeditor_host (Lisp_Object buffer)
{
  CmacsLibregnumView *v = lrgeditor_view (buffer);
  CmacsLrgeditorHost *host =
    cmacs_libregnum_render_ctx_app_host (cmacs_libregnum_view_get_render_ctx (v));

  if (!host)
    error ("cmacs-lrgeditor: buffer does not host the lrgeditor shell");
  return host;
}

/* Input or an action changed what the shell shows: draw it, and keep
   drawing while the canvas animates (cmacs-lrgeditor.el stops the clock
   once the shell is idle). */
static void
lrgeditor_wake (Lisp_Object buffer)
{
  CmacsLibregnumView *v = lrgeditor_view (buffer);

  cmacs_libregnum_view_set_animated (v, TRUE, 0);
  cmacs_libregnum_view_request_redraw (v);
}

/* Signal `cmacs-libregnum-error' with C string MSG (freed here). */
static AVOID
lrgeditor_signal (char *msg, const char *fallback)
{
  Lisp_Object text = build_string (msg ? msg : fallback);

  g_free (msg);
  xsignal1 (Qcmacs_libregnum_error, text);
}

DEFUN ("cmacs-lrgeditor--attach", Fcmacs_lrgeditor__attach,
       Scmacs_lrgeditor__attach, 1, 2, 0,
       doc: /* Host libregnum's lrgeditor shell in BUFFER's libregnum view.
SETTINGS, a file name, is the editor preferences file; nil shares the
standalone editor's $XDG_CONFIG_HOME/libregnum/editor.yaml.  Replaces any
level an older editor session had open in that view.  */)
  (Lisp_Object buffer, Lisp_Object settings)
{
  CmacsLibregnumView *v = lrgeditor_view (buffer);
  CmacsLrgeditorHost *host;
  char *err = NULL;
  const char *path = NULL;

  if (!NILP (settings))
    {
      CHECK_STRING (settings);
      settings = ENCODE_FILE (Fexpand_file_name (settings, Qnil));
      path = SSDATA (settings);
    }
  host = cmacs_lrgeditor_host_new (path, &err);
  if (!host)
    lrgeditor_signal (err, "could not start the editor");
  cmacs_libregnum_render_ctx_app_attach
    (cmacs_libregnum_view_get_render_ctx (v), host);
  lrgeditor_wake (buffer);
  return Qt;
}

DEFUN ("cmacs-lrgeditor-attached-p", Fcmacs_lrgeditor_attached_p,
       Scmacs_lrgeditor_attached_p, 1, 1, 0,
       doc: /* Return non-nil if BUFFER's libregnum view hosts the lrgeditor shell.  */)
  (Lisp_Object buffer)
{
  CmacsLibregnumView *v;

  CHECK_BUFFER (buffer);
  v = cmacs_libregnum_view_for_buffer (buffer);
  return (v && cmacs_libregnum_render_ctx_app_host
                 (cmacs_libregnum_view_get_render_ctx (v)))
         ? Qt : Qnil;
}

DEFUN ("cmacs-lrgeditor--open", Fcmacs_lrgeditor__open,
       Scmacs_lrgeditor__open, 2, 2, 0,
       doc: /* Open PATH in the shell hosted in BUFFER.
PATH is a project directory or its project.ryaml, a level or prefab, a
sequence, or any file one of the shell's data editors handles (.rsong,
.rmat, .rbt, .rparticles, ...); see `cmacs-lrgeditor-can-open-p'.  It is
routed the way the shell's assets panel routes a double click, and a
file inside another project opens that project first.  */)
  (Lisp_Object buffer, Lisp_Object path)
{
  CmacsLrgeditorHost *host = lrgeditor_host (buffer);
  char *err = NULL;

  CHECK_STRING (path);
  path = ENCODE_FILE (Fexpand_file_name (path, Qnil));
  if (!cmacs_lrgeditor_host_open (host, SSDATA (path), &err))
    lrgeditor_signal (err, "could not open");
  lrgeditor_wake (buffer);
  return Qt;
}

DEFUN ("cmacs-lrgeditor-can-open-p", Fcmacs_lrgeditor_can_open_p,
       Scmacs_lrgeditor_can_open_p, 1, 1, 0,
       doc: /* Return non-nil if the lrgeditor shell has an editor for FILE.
That is a project.ryaml, a level or prefab, a sequence, or a file whose
format one of the shell's data editors handles.  The format is read from
the file (a data file's `format:' key), so FILE must exist.  No shell
needs to be open to ask.  */)
  (Lisp_Object file)
{
  CHECK_STRING (file);
  file = ENCODE_FILE (Fexpand_file_name (file, Qnil));
  return cmacs_lrgeditor_host_can_open (SSDATA (file)) ? Qt : Qnil;
}

DEFUN ("cmacs-lrgeditor--new-project", Fcmacs_lrgeditor__new_project,
       Scmacs_lrgeditor__new_project, 3, 3, 0,
       doc: /* Create a libregnum project in DIR named NAME and open it in BUFFER.
NAME may be nil to take the directory's name.  */)
  (Lisp_Object buffer, Lisp_Object dir, Lisp_Object name)
{
  CmacsLrgeditorHost *host = lrgeditor_host (buffer);
  char *err = NULL;

  CHECK_STRING (dir);
  if (!NILP (name))
    CHECK_STRING (name);
  dir = ENCODE_FILE (Fexpand_file_name (dir, Qnil));
  if (!cmacs_lrgeditor_host_new_project (host, SSDATA (dir),
                                         NILP (name) ? NULL : SSDATA (name),
                                         &err))
    lrgeditor_signal (err, "could not create the project");
  lrgeditor_wake (buffer);
  return Qt;
}

DEFUN ("cmacs-lrgeditor--start-server", Fcmacs_lrgeditor__start_server,
       Scmacs_lrgeditor__start_server, 1, 2, 0,
       doc: /* Serve the editor protocol for the shell in BUFFER; return the socket.
SOCKET is the Unix socket file name; nil lets the editor choose (its
settings, else $XDG_RUNTIME_DIR/libregnum/editor-PID.sock).  `lrgeditorctl',
its MCP verbs and libregnum.el connect there.  Starting twice is a no-op
that returns the running socket.  */)
  (Lisp_Object buffer, Lisp_Object socket)
{
  CmacsLrgeditorHost *host = lrgeditor_host (buffer);
  char *err = NULL;
  const char *path;

  if (!NILP (socket))
    {
      CHECK_STRING (socket);
      socket = ENCODE_FILE (Fexpand_file_name (socket, Qnil));
    }
  if (!cmacs_lrgeditor_host_start_server (host,
                                          NILP (socket) ? NULL
                                                        : SSDATA (socket),
                                          &err))
    lrgeditor_signal (err, "could not start the editor server");
  path = cmacs_lrgeditor_host_socket_path (host);
  return path ? DECODE_FILE (build_unibyte_string (path)) : Qnil;
}

DEFUN ("cmacs-lrgeditor-socket", Fcmacs_lrgeditor_socket,
       Scmacs_lrgeditor_socket, 1, 1, 0,
       doc: /* Return the socket the shell in BUFFER serves on, or nil.  */)
  (Lisp_Object buffer)
{
  const char *path = cmacs_lrgeditor_host_socket_path (lrgeditor_host (buffer));

  return path ? DECODE_FILE (build_unibyte_string (path)) : Qnil;
}

DEFUN ("cmacs-lrgeditor--key", Fcmacs_lrgeditor__key,
       Scmacs_lrgeditor__key, 4, 4, 0,
       doc: /* Send key GRL-KEY to the shell in BUFFER.
GRL-KEY is a graylib key code (raylib KEY_*).  PHASE is 0 for a press,
1 for an auto-repeat, 2 for a release.  MODS is a bit mask: 1 shift,
2 control, 4 alt, 8 super.  */)
  (Lisp_Object buffer, Lisp_Object grl_key, Lisp_Object phase,
   Lisp_Object mods)
{
  CmacsLrgeditorHost *host = lrgeditor_host (buffer);

  CHECK_FIXNUM (grl_key);
  CHECK_FIXNUM (phase);
  CHECK_FIXNUM (mods);
  cmacs_lrgeditor_host_key (host, (int) XFIXNUM (grl_key),
                            (int) XFIXNUM (phase), (guint) XFIXNUM (mods));
  lrgeditor_wake (buffer);
  return Qnil;
}

DEFUN ("cmacs-lrgeditor--text", Fcmacs_lrgeditor__text,
       Scmacs_lrgeditor__text, 2, 2, 0,
       doc: /* Send typed TEXT (a string) to the shell in BUFFER.
This is what a focused text field inserts; shortcuts come from
`cmacs-lrgeditor--key'.  */)
  (Lisp_Object buffer, Lisp_Object text)
{
  CmacsLrgeditorHost *host = lrgeditor_host (buffer);

  CHECK_STRING (text);
  text = ENCODE_UTF_8 (text);
  cmacs_lrgeditor_host_text (host, SSDATA (text));
  lrgeditor_wake (buffer);
  return Qnil;
}

DEFUN ("cmacs-lrgeditor--release-all", Fcmacs_lrgeditor__release_all,
       Scmacs_lrgeditor__release_all, 1, 1, 0,
       doc: /* Release every button and modifier the shell in BUFFER thinks is held.
Called when the shell's window loses focus.  */)
  (Lisp_Object buffer)
{
  cmacs_lrgeditor_host_release_all (lrgeditor_host (buffer));
  lrgeditor_wake (buffer);
  return Qnil;
}

DEFUN ("cmacs-lrgeditor--idle-seconds", Fcmacs_lrgeditor__idle_seconds,
       Scmacs_lrgeditor__idle_seconds, 1, 1, 0,
       doc: /* Return seconds since the shell in BUFFER last received input.  */)
  (Lisp_Object buffer)
{
  gint64 last = cmacs_lrgeditor_host_last_input_us (lrgeditor_host (buffer));

  return make_float ((double) (g_get_monotonic_time () - last)
                     / G_USEC_PER_SEC);
}

DEFUN ("cmacs-lrgeditor-playing-p", Fcmacs_lrgeditor_playing_p,
       Scmacs_lrgeditor_playing_p, 1, 1, 0,
       doc: /* Return non-nil while the shell in BUFFER is playing the level.  */)
  (Lisp_Object buffer)
{
  return cmacs_lrgeditor_host_is_playing (lrgeditor_host (buffer)) ? Qt : Qnil;
}

DEFUN ("cmacs-lrgeditor-quit-requested-p", Fcmacs_lrgeditor_quit_requested_p,
       Scmacs_lrgeditor_quit_requested_p, 1, 1, 0,
       doc: /* Return non-nil if the shell in BUFFER asked to quit (File > Quit).  */)
  (Lisp_Object buffer)
{
  return cmacs_lrgeditor_host_should_quit (lrgeditor_host (buffer))
         ? Qt : Qnil;
}

DEFUN ("cmacs-lrgeditor-status", Fcmacs_lrgeditor_status,
       Scmacs_lrgeditor_status, 1, 1, 0,
       doc: /* Return the shell's last status message in BUFFER, or nil.  */)
  (Lisp_Object buffer)
{
  const char *status = cmacs_lrgeditor_host_status (lrgeditor_host (buffer));

  return (status && *status) ? build_string (status) : Qnil;
}

DEFUN ("cmacs-lrgeditor-activate-action", Fcmacs_lrgeditor_activate_action,
       Scmacs_lrgeditor_activate_action, 2, 2, 0,
       doc: /* Run editor action ID (a string such as "file.save") in BUFFER's shell.
Return non-nil if the action exists and was enabled.
See `cmacs-lrgeditor-actions' for the ids.  */)
  (Lisp_Object buffer, Lisp_Object id)
{
  CmacsLrgeditorHost *host = lrgeditor_host (buffer);
  gboolean ok;

  CHECK_STRING (id);
  ok = cmacs_lrgeditor_host_activate_action (host, SSDATA (id));
  lrgeditor_wake (buffer);
  return ok ? Qt : Qnil;
}

DEFUN ("cmacs-lrgeditor-actions", Fcmacs_lrgeditor_actions,
       Scmacs_lrgeditor_actions, 1, 1, 0,
       doc: /* Return the ids of every action the shell in BUFFER registers.  */)
  (Lisp_Object buffer)
{
  char **ids = cmacs_lrgeditor_host_list_actions (lrgeditor_host (buffer));
  Lisp_Object result = Qnil;
  ptrdiff_t i, n = 0;

  if (!ids)
    return Qnil;
  while (ids[n])
    n++;
  for (i = n - 1; i >= 0; i--)
    result = Fcons (build_string (ids[i]), result);
  g_strfreev (ids);
  return result;
}

void
syms_of_cmacs_libregnum_lrgeditor (void)
{
  defsubr (&Scmacs_lrgeditor__attach);
  defsubr (&Scmacs_lrgeditor_attached_p);
  defsubr (&Scmacs_lrgeditor__open);
  defsubr (&Scmacs_lrgeditor_can_open_p);
  defsubr (&Scmacs_lrgeditor__new_project);
  defsubr (&Scmacs_lrgeditor__start_server);
  defsubr (&Scmacs_lrgeditor_socket);
  defsubr (&Scmacs_lrgeditor__key);
  defsubr (&Scmacs_lrgeditor__text);
  defsubr (&Scmacs_lrgeditor__release_all);
  defsubr (&Scmacs_lrgeditor__idle_seconds);
  defsubr (&Scmacs_lrgeditor_playing_p);
  defsubr (&Scmacs_lrgeditor_quit_requested_p);
  defsubr (&Scmacs_lrgeditor_status);
  defsubr (&Scmacs_lrgeditor_activate_action);
  defsubr (&Scmacs_lrgeditor_actions);
}

#endif /* HAVE_CMACS_LIBREGNUM */
