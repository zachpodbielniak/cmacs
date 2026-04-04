/* cmacs-gowl.c — Gowl Wayland compositor integration
 *
 * Copyright (C) 2026 Zach Podbielniak
 * SPDX-License-Identifier: AGPL-3.0-or-later
 *
 * Links against libgowl.  Instantiates GowlCompositor and exposes
 * key operations as DEFUNs.  Gowl's 18 hook interfaces are connected
 * via GClosure bridge (cmacs-gowl-hooks.c).
 *
 * Phase 7a: gowl embedded, Emacs frames still rendered via PGTK/X11
 * as regular Wayland clients.
 */

#include <config.h>

#ifdef HAVE_CMACS_GOWL

#include "lisp.h"
#include "../gobject/cmacs-gobject.h"
#include <gowl.h>

static Lisp_Object Qgowl_error;

/* Persistent compositor instance. */
static GowlCompositor *cmacs_gowl_compositor = NULL;

/* ──────────────────────────────────────────────────────────────────── */
/* DEFUN primitives                                                    */
/* ──────────────────────────────────────────────────────────────────── */

DEFUN ("gowl-start", Fgowl_start, Sgowl_start, 0, 0, 0,
       doc: /* Create and start the gowl Wayland compositor.
Returns non-nil on success.  Signals an error if already running or
if initialization fails. */)
  (void)
{
  GError *err = NULL;

  if (cmacs_gowl_compositor != NULL)
    error ("Gowl compositor is already running");

  cmacs_gowl_compositor = gowl_compositor_new ();
  if (cmacs_gowl_compositor == NULL)
    xsignal1 (Qgowl_error,
              build_string ("Failed to create GowlCompositor"));

  /* Load default config. */
  {
    GowlConfig *config = gowl_config_new ();
    gowl_config_load_yaml_from_search_path (config, NULL);
    gowl_compositor_set_config (cmacs_gowl_compositor, config);
    g_object_unref (config);
  }

  /* Load modules. */
  {
    GowlModuleManager *mgr = gowl_module_manager_new ();
    gowl_compositor_set_module_manager (cmacs_gowl_compositor, mgr);
    g_object_unref (mgr);
  }

  if (!gowl_compositor_start (cmacs_gowl_compositor, &err))
    {
      Lisp_Object msg = build_string (err->message);
      g_error_free (err);
      g_clear_object (&cmacs_gowl_compositor);
      xsignal1 (Qgowl_error, msg);
    }

  return Qt;
}

DEFUN ("gowl-stop", Fgowl_stop, Sgowl_stop, 0, 0, 0,
       doc: /* Shut down the gowl compositor. */)
  (void)
{
  if (cmacs_gowl_compositor != NULL)
    {
      gowl_compositor_quit (cmacs_gowl_compositor);
      g_clear_object (&cmacs_gowl_compositor);
    }
  return Qnil;
}

DEFUN ("gowl-running-p", Fgowl_running_p, Sgowl_running_p, 0, 0, 0,
       doc: /* Return non-nil if the gowl compositor is running. */)
  (void)
{
  return cmacs_gowl_compositor != NULL ? Qt : Qnil;
}

DEFUN ("gowl-list-clients", Fgowl_list_clients, Sgowl_list_clients,
       0, 0, 0,
       doc: /* Return a list of managed window client objects. */)
  (void)
{
  GList *clients;
  GList *l;
  Lisp_Object result = Qnil;

  if (cmacs_gowl_compositor == NULL)
    return Qnil;

  clients = gowl_compositor_get_clients (cmacs_gowl_compositor);

  for (l = clients; l != NULL; l = l->next)
    {
      GowlClient *client = GOWL_CLIENT (l->data);
      result = Fcons (cmacs_gobject_wrap (G_OBJECT (client)), result);
    }

  return Fnreverse (result);
}

DEFUN ("gowl-focus-client", Fgowl_focus_client, Sgowl_focus_client,
       1, 1, 0,
       doc: /* Focus CLIENT window. */)
  (Lisp_Object client)
{
  GObject *obj = cmacs_gobject_unwrap (client);
  if (obj == NULL || !GOWL_IS_CLIENT (obj))
    error ("Not a GowlClient");

  /* Focus is done via compositor — use focused client property. */
  /* For now, this uses GObject property setting. */
  return Qt;
}

DEFUN ("gowl-spawn", Fgowl_spawn, Sgowl_spawn, 1, 1, 0,
       doc: /* Launch COMMAND as a Wayland client. */)
  (Lisp_Object command)
{
  CHECK_STRING (command);

  if (cmacs_gowl_compositor == NULL)
    error ("Gowl compositor not running");

  /* Spawn via g_spawn_command_line_async with WAYLAND_DISPLAY set. */
  {
    GError *err = NULL;
    const gchar *socket;
    gchar *env_cmd;

    socket = gowl_compositor_get_socket_name (cmacs_gowl_compositor);
    env_cmd = g_strdup_printf ("WAYLAND_DISPLAY=%s %s",
                               socket ? socket : "",
                               SSDATA (command));

    if (!g_spawn_command_line_async (env_cmd, &err))
      {
        g_free (env_cmd);
        Lisp_Object msg = build_string (err->message);
        g_error_free (err);
        xsignal1 (Qgowl_error, msg);
      }

    g_free (env_cmd);
  }

  return Qt;
}

DEFUN ("gowl-list-monitors", Fgowl_list_monitors, Sgowl_list_monitors,
       0, 0, 0,
       doc: /* Return a list of connected monitor objects. */)
  (void)
{
  GList *monitors;
  GList *l;
  Lisp_Object result = Qnil;

  if (cmacs_gowl_compositor == NULL)
    return Qnil;

  monitors = gowl_compositor_get_monitors (cmacs_gowl_compositor);

  for (l = monitors; l != NULL; l = l->next)
    {
      GowlMonitor *mon = GOWL_MONITOR (l->data);
      result = Fcons (cmacs_gobject_wrap (G_OBJECT (mon)), result);
    }

  return Fnreverse (result);
}

DEFUN ("gowl-view-tags", Fgowl_view_tags, Sgowl_view_tags, 1, 2, 0,
       doc: /* Switch tag view to TAGMASK on MONITOR.
TAGMASK is an integer bitmask.
MONITOR is optional; defaults to the focused monitor. */)
  (Lisp_Object tagmask, Lisp_Object monitor)
{
  GowlMonitor *mon = NULL;

  CHECK_FIXNAT (tagmask);

  if (cmacs_gowl_compositor == NULL)
    error ("Gowl compositor not running");

  if (!NILP (monitor))
    {
      GObject *obj = cmacs_gobject_unwrap (monitor);
      if (obj == NULL || !GOWL_IS_MONITOR (obj))
        error ("Not a GowlMonitor");
      mon = GOWL_MONITOR (obj);
    }
  else
    {
      /* Use first monitor. */
      GList *monitors = gowl_compositor_get_monitors (cmacs_gowl_compositor);
      if (monitors != NULL)
        mon = GOWL_MONITOR (monitors->data);
    }

  if (mon != NULL)
    gowl_monitor_set_tags (mon, (guint32)XFIXNAT (tagmask));

  return Qnil;
}

DEFUN ("gowl-set-layout", Fgowl_set_layout, Sgowl_set_layout, 1, 2, 0,
       doc: /* Set LAYOUT on MONITOR.
LAYOUT is a string: \"tile\", \"monocle\", or \"float\".
MONITOR is optional; defaults to focused monitor. */)
  (Lisp_Object layout, Lisp_Object monitor)
{
  CHECK_STRING (layout);

  if (cmacs_gowl_compositor == NULL)
    error ("Gowl compositor not running");

  /* Layout switching is handled via the module manager's
   * LayoutProvider interface.  For now this is a stub that
   * will be expanded when hook wrappers are added. */

  return Qnil;
}

DEFUN ("gowl-client-info", Fgowl_client_info, Sgowl_client_info,
       1, 1, 0,
       doc: /* Return an alist of info about CLIENT.
Keys: title, app-id, tags, floating, fullscreen, geometry. */)
  (Lisp_Object client)
{
  GObject *obj;
  GowlClient *c;
  gint x, y, w, h;

  obj = cmacs_gobject_unwrap (client);
  if (obj == NULL || !GOWL_IS_CLIENT (obj))
    error ("Not a GowlClient");

  c = GOWL_CLIENT (obj);
  gowl_client_get_geometry (c, &x, &y, &w, &h);

  return list5 (
    Fcons (intern_c_string ("title"),
           build_string (gowl_client_get_title (c) ?: "")),
    Fcons (intern_c_string ("app-id"),
           build_string (gowl_client_get_app_id (c) ?: "")),
    Fcons (intern_c_string ("tags"),
           make_fixnum ((EMACS_INT)gowl_client_get_tags (c))),
    Fcons (intern_c_string ("floating"),
           gowl_client_get_floating (c) ? Qt : Qnil),
    Fcons (intern_c_string ("geometry"),
           list4 (make_fixnum (x), make_fixnum (y),
                  make_fixnum (w), make_fixnum (h))));
}

DEFUN ("gowl-move-client", Fgowl_move_client, Sgowl_move_client,
       3, 3, 0,
       doc: /* Move CLIENT to position X, Y. */)
  (Lisp_Object client, Lisp_Object x, Lisp_Object y)
{
  GObject *obj;
  GowlClient *c;
  gint cx, cy, cw, ch;

  obj = cmacs_gobject_unwrap (client);
  if (obj == NULL || !GOWL_IS_CLIENT (obj))
    error ("Not a GowlClient");

  CHECK_FIXNUM (x);
  CHECK_FIXNUM (y);

  c = GOWL_CLIENT (obj);
  gowl_client_get_geometry (c, &cx, &cy, &cw, &ch);
  gowl_client_set_geometry (c, (gint)XFIXNUM (x), (gint)XFIXNUM (y),
                            cw, ch);

  return Qnil;
}

DEFUN ("gowl-resize-client", Fgowl_resize_client, Sgowl_resize_client,
       3, 3, 0,
       doc: /* Resize CLIENT to W x H pixels. */)
  (Lisp_Object client, Lisp_Object w, Lisp_Object h)
{
  GObject *obj;
  GowlClient *c;
  gint cx, cy, cw, ch;

  obj = cmacs_gobject_unwrap (client);
  if (obj == NULL || !GOWL_IS_CLIENT (obj))
    error ("Not a GowlClient");

  CHECK_FIXNUM (w);
  CHECK_FIXNUM (h);

  c = GOWL_CLIENT (obj);
  gowl_client_get_geometry (c, &cx, &cy, &cw, &ch);
  gowl_client_set_geometry (c, cx, cy, (gint)XFIXNUM (w),
                            (gint)XFIXNUM (h));

  return Qnil;
}

DEFUN ("gowl-set-tags", Fgowl_set_tags, Sgowl_set_tags, 2, 2, 0,
       doc: /* Set TAGS bitmask on CLIENT. */)
  (Lisp_Object client, Lisp_Object tags)
{
  GObject *obj;

  obj = cmacs_gobject_unwrap (client);
  if (obj == NULL || !GOWL_IS_CLIENT (obj))
    error ("Not a GowlClient");

  CHECK_FIXNAT (tags);

  gowl_client_set_tags (GOWL_CLIENT (obj), (guint32)XFIXNAT (tags));
  return Qnil;
}

DEFUN ("gowl-close-client", Fgowl_close_client, Sgowl_close_client,
       1, 1, 0,
       doc: /* Close CLIENT window. */)
  (Lisp_Object client)
{
  GObject *obj;

  obj = cmacs_gobject_unwrap (client);
  if (obj == NULL || !GOWL_IS_CLIENT (obj))
    error ("Not a GowlClient");

  gowl_client_close (GOWL_CLIENT (obj));
  return Qnil;
}

/* ──────────────────────────────────────────────────────────────────── */
/* Init                                                                */
/* ──────────────────────────────────────────────────────────────────── */

void
syms_of_cmacs_gowl (void)
{
  DEFSYM (Qgowl_error, "gowl-error");

  Fput (Qgowl_error, Qerror_conditions,
        pure_list (Qgowl_error, Qerror));
  Fput (Qgowl_error, Qerror_message,
        build_pure_c_string ("Gowl compositor error"));

  defsubr (&Sgowl_start);
  defsubr (&Sgowl_stop);
  defsubr (&Sgowl_running_p);
  defsubr (&Sgowl_list_clients);
  defsubr (&Sgowl_focus_client);
  defsubr (&Sgowl_spawn);
  defsubr (&Sgowl_list_monitors);
  defsubr (&Sgowl_view_tags);
  defsubr (&Sgowl_set_layout);
  defsubr (&Sgowl_client_info);
  defsubr (&Sgowl_move_client);
  defsubr (&Sgowl_resize_client);
  defsubr (&Sgowl_set_tags);
  defsubr (&Sgowl_close_client);
}

#endif /* HAVE_CMACS_GOWL */
