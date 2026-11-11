/* cmacs-libregnum-lrgeditor.c --- libregnum's lrgeditor shell, hosted.
 * Copyright (C) 2026 Zach Podbielniak
 * SPDX-License-Identifier: AGPL-3.0-or-later
 *
 * The libregnum half of the embedded editor (see the header for the
 * design).  This TU sees <libregnum.h> and never lisp.h or any other
 * Emacs header: libregnum's raylib `Color' and pgtk's `Color' cannot
 * share a translation unit.  Nothing here evaluates Lisp. */

#include <config.h>

#ifdef HAVE_CMACS_LIBREGNUM

/* The editor application lives behind LRG_BUILD_EDITOR_UI in
 * <libregnum.h>; cmacs builds libregnum with its default BUILD_EDITOR_UI=1,
 * so the objects are in liblibregnum.a and only the headers need asking
 * for. */
#ifndef LRG_BUILD_EDITOR
#define LRG_BUILD_EDITOR 1
#endif
#ifndef LRG_BUILD_EDITOR_UI
#define LRG_BUILD_EDITOR_UI 1
#endif

#include "cmacs-libregnum-lrgeditor.h"
#include "../glib/cmacs-glib-loop.h"

#include <libregnum.h>
#include <string.h>

/* Clamp for one frame's delta: a view that was hidden for a minute must
 * not hand the play session a 60-second step. */
#define CMACS_LRGEDITOR_MAX_DT (0.1)

struct CmacsLrgeditorHost
{
  LrgEditor      *editor;   /* owned */
  LrgEditorApp   *app;      /* owned */

  /* The input being gathered for the next frame. */
  LrgCanvasInput  pending;

  /* State that persists across frames: where the pointer is, which
   * buttons and modifiers are held. */
  gfloat          pointer_x;
  gfloat          pointer_y;
  guint           buttons_down;
  guint           prev_buttons;
  guint           modifiers;

  gint64          last_frame_us;
  gint64          last_input_us;

  gulong          changed_id;
  gulong          replaced_id;
  gboolean        level_changed;
};

/* Reset the pending input to an empty frame that still carries the
 * persistent state (pointer, held buttons, modifiers). */
static void
host_reset_pending (CmacsLrgeditorHost *self)
{
  lrg_canvas_input_init (&self->pending);
  self->pending.pointer_x = self->pointer_x;
  self->pending.pointer_y = self->pointer_y;
  self->pending.buttons_down = self->buttons_down;
  self->pending.modifiers = (LrgInputModifiers) self->modifiers;
}

static void
host_on_level_changed (gpointer instance, gpointer user_data)
{
  CmacsLrgeditorHost *self = user_data;

  (void) instance;
  self->level_changed = TRUE;
}

/* "level-replaced" carries the new LrgLevel before the user data. */
static void
host_on_level_replaced (gpointer instance, gpointer level, gpointer user_data)
{
  (void) level;
  host_on_level_changed (instance, user_data);
}

static void
host_touch (CmacsLrgeditorHost *self)
{
  self->last_input_us = g_get_monotonic_time ();
}

CmacsLrgeditorHost *
cmacs_lrgeditor_host_new (const char *settings_path, char **error_msg)
{
  CmacsLrgeditorHost *self;
  GError *error = NULL;

  self = g_new0 (CmacsLrgeditorHost, 1);
  self->editor = lrg_editor_new ();

  /* Everything the app attaches to "the" main context -- file monitors,
   * the log writer's flush, later the IPC server -- must land on cmacs's
   * context: that one is dispatched in every pselect, including the
   * accept-process-output loop libregnum.el's synchronous requests wait
   * in, and always under the waiting_for_input guard. */
  g_main_context_push_thread_default (cmacs_glib_get_context ());
  self->app = lrg_editor_app_new (self->editor);

  /* Same preferences file as the standalone `lrgeditor' unless told
   * otherwise: recent projects, layout and external-editor choice then
   * follow the user between the two. */
  if (!lrg_editor_app_load_settings (self->app, settings_path, &error))
    {
      g_main_context_pop_thread_default (cmacs_glib_get_context ());
      if (error_msg != NULL)
        *error_msg = g_strdup (error != NULL ? error->message
                                             : "could not load settings");
      g_clear_error (&error);
      cmacs_lrgeditor_host_free (self);
      return NULL;
    }

  self->changed_id = g_signal_connect (self->editor, "changed",
                                       G_CALLBACK (host_on_level_changed),
                                       self);
  self->replaced_id = g_signal_connect (self->editor, "level-replaced",
                                        G_CALLBACK (host_on_level_replaced),
                                        self);
  g_main_context_pop_thread_default (cmacs_glib_get_context ());

  self->pointer_x = -1.0f;
  self->pointer_y = -1.0f;
  self->level_changed = TRUE;
  host_reset_pending (self);
  host_touch (self);
  return self;
}

void
cmacs_lrgeditor_host_free (CmacsLrgeditorHost *self)
{
  if (self == NULL)
    return;
  if (self->editor != NULL)
    {
      if (self->changed_id != 0)
        g_signal_handler_disconnect (self->editor, self->changed_id);
      if (self->replaced_id != 0)
        g_signal_handler_disconnect (self->editor, self->replaced_id);
    }
  /* The app before the editor it wraps: its panels and server hold
   * references into the editor's documents. */
  g_clear_object (&self->app);
  g_clear_object (&self->editor);
  g_free (self);
}

gpointer
cmacs_lrgeditor_host_get_editor (CmacsLrgeditorHost *self)
{
  return self != NULL ? self->editor : NULL;
}

static gboolean
host_fail (GError *error, const char *fallback, char **error_msg)
{
  if (error_msg != NULL)
    *error_msg = g_strdup (error != NULL ? error->message : fallback);
  g_clear_error (&error);
  return FALSE;
}

gboolean
cmacs_lrgeditor_host_open (CmacsLrgeditorHost *self, const char *path,
                           char **error_msg)
{
  GError *error = NULL;
  gboolean ok;

  if (self == NULL || path == NULL)
    return host_fail (NULL, "no path", error_msg);
  /* Opening a project starts file monitors: same context rule as _new. */
  g_main_context_push_thread_default (cmacs_glib_get_context ());

  /* A directory is a project (project.ryaml inside); anything else is
   * taken to be a level file. */
  if (g_file_test (path, G_FILE_TEST_IS_DIR))
    ok = lrg_editor_app_open_project (self->app, path, &error);
  else
    ok = lrg_editor_app_open_level (self->app, path, &error);
  g_main_context_pop_thread_default (cmacs_glib_get_context ());

  if (!ok)
    return host_fail (error, "could not open", error_msg);
  self->level_changed = TRUE;
  return TRUE;
}

gboolean
cmacs_lrgeditor_host_new_project (CmacsLrgeditorHost *self, const char *dir,
                                  const char *name, char **error_msg)
{
  GError *error = NULL;

  if (self == NULL || dir == NULL)
    return host_fail (NULL, "no directory", error_msg);
  g_main_context_push_thread_default (cmacs_glib_get_context ());
  if (!lrg_editor_app_new_project (self->app, dir, name, &error))
    {
      g_main_context_pop_thread_default (cmacs_glib_get_context ());
      return host_fail (error, "could not create the project", error_msg);
    }
  g_main_context_pop_thread_default (cmacs_glib_get_context ());
  self->level_changed = TRUE;
  return TRUE;
}

gboolean
cmacs_lrgeditor_host_start_server (CmacsLrgeditorHost *self,
                                   const char *socket_path, char **error_msg)
{
  GError *error = NULL;

  if (self == NULL)
    return host_fail (NULL, "no editor", error_msg);
  /* Already serving: report success rather than binding twice. */
  if (cmacs_lrgeditor_host_socket_path (self) != NULL)
    return TRUE;
  /* The listening socket's source goes on cmacs's context (see _new). */
  g_main_context_push_thread_default (cmacs_glib_get_context ());
  if (!lrg_editor_app_start_server (self->app, socket_path, &error))
    {
      g_main_context_pop_thread_default (cmacs_glib_get_context ());
      return host_fail (error, "could not start the editor server", error_msg);
    }
  g_main_context_pop_thread_default (cmacs_glib_get_context ());
  return TRUE;
}

const char *
cmacs_lrgeditor_host_socket_path (CmacsLrgeditorHost *self)
{
  LrgEditorServer *server;

  if (self == NULL)
    return NULL;
  /* The server exists from construction; it has a socket path only
   * while it is listening. */
  server = lrg_editor_app_get_server (self->app);
  if (server == NULL)
    return NULL;
  return lrg_editor_server_get_socket_path (server);
}

/* ── Input ─────────────────────────────────────────────────────────── */

void
cmacs_lrgeditor_host_pointer (CmacsLrgeditorHost *self, double x, double y)
{
  if (self == NULL)
    return;
  self->pointer_x = (gfloat) x;
  self->pointer_y = (gfloat) y;
  self->pending.pointer_x = self->pointer_x;
  self->pending.pointer_y = self->pointer_y;
  host_touch (self);
}

void
cmacs_lrgeditor_host_button (CmacsLrgeditorHost *self, int button,
                             gboolean press, double x, double y)
{
  guint mask;

  if (self == NULL || button < 0 || button > 31)
    return;
  cmacs_lrgeditor_host_pointer (self, x, y);
  mask = LRG_CANVAS_BUTTON_MASK (button);
  /* Edges are recorded on the pending frame, so a click shorter than a
   * frame (a touchpad tap) still arrives as a press AND a release. */
  if (press)
    {
      self->buttons_down |= mask;
      self->pending.buttons_pressed |= mask;
    }
  else
    {
      self->buttons_down &= ~mask;
      self->pending.buttons_released |= mask;
    }
  self->pending.buttons_down = self->buttons_down | self->pending.buttons_pressed;
}

void
cmacs_lrgeditor_host_wheel (CmacsLrgeditorHost *self, double dx, double dy)
{
  if (self == NULL)
    return;
  self->pending.wheel_x += (gfloat) dx;
  self->pending.wheel_y += (gfloat) dy;
  host_touch (self);
}

void
cmacs_lrgeditor_host_set_modifiers (CmacsLrgeditorHost *self, guint mods)
{
  if (self == NULL)
    return;
  self->modifiers = mods & (CMACS_LRGEDITOR_MOD_SHIFT | CMACS_LRGEDITOR_MOD_CTRL
                            | CMACS_LRGEDITOR_MOD_ALT
                            | CMACS_LRGEDITOR_MOD_SUPER);
  self->pending.modifiers = (LrgInputModifiers) self->modifiers;
}

void
cmacs_lrgeditor_host_key (CmacsLrgeditorHost *self, int grl_key, int phase,
                          guint mods)
{
  if (self == NULL || grl_key <= 0)
    return;
  cmacs_lrgeditor_host_set_modifiers (self, mods);
  switch (phase)
    {
    case CMACS_LRGEDITOR_KEY_RELEASE:
      lrg_canvas_input_add_key_release (&self->pending, (GrlKey) grl_key);
      break;
    case CMACS_LRGEDITOR_KEY_REPEAT:
      lrg_canvas_input_add_key_repeat (&self->pending, (GrlKey) grl_key);
      break;
    default:
      lrg_canvas_input_add_key (&self->pending, (GrlKey) grl_key);
      break;
    }
  host_touch (self);
}

void
cmacs_lrgeditor_host_text (CmacsLrgeditorHost *self, const char *utf8)
{
  if (self == NULL || utf8 == NULL || *utf8 == '\0')
    return;
  lrg_canvas_input_add_text (&self->pending, utf8);
  host_touch (self);
}

void
cmacs_lrgeditor_host_release_all (CmacsLrgeditorHost *self)
{
  if (self == NULL)
    return;
  /* Focus left the editor: whatever was held is released, the same rule
   * the standalone window applies when GLFW stops reporting releases. */
  self->pending.buttons_released |= self->buttons_down;
  self->buttons_down = 0;
  self->pending.buttons_down = 0;
  self->modifiers = 0;
  self->pending.modifiers = 0;
}

/* ── Frames ────────────────────────────────────────────────────────── */

void
cmacs_lrgeditor_host_frame (CmacsLrgeditorHost *self, int width, int height)
{
  gint64 now;
  gdouble dt;

  if (self == NULL || width <= 0 || height <= 0)
    return;

  now = g_get_monotonic_time ();
  dt = self->last_frame_us > 0
         ? (gdouble) (now - self->last_frame_us) / G_USEC_PER_SEC
         : 1.0 / 60.0;
  if (dt > CMACS_LRGEDITOR_MAX_DT)
    dt = CMACS_LRGEDITOR_MAX_DT;
  self->last_frame_us = now;

  self->pending.delta_time = (gfloat) dt;
  self->pending.buttons_down |= self->buttons_down;
  lrg_editor_app_process_frame (self->app, &self->pending, width, height);

  self->prev_buttons = self->buttons_down;
  host_reset_pending (self);
}

void
cmacs_lrgeditor_host_draw (CmacsLrgeditorHost *self)
{
  if (self == NULL)
    return;
  lrg_canvas_render (lrg_editor_app_get_canvas (self->app));
}

gboolean
cmacs_lrgeditor_host_take_level_changed (CmacsLrgeditorHost *self)
{
  gboolean changed;

  if (self == NULL)
    return FALSE;
  changed = self->level_changed;
  self->level_changed = FALSE;
  return changed;
}

/* ── State and actions ─────────────────────────────────────────────── */

gboolean
cmacs_lrgeditor_host_is_playing (CmacsLrgeditorHost *self)
{
  return self != NULL && lrg_editor_app_is_playing (self->app);
}

gboolean
cmacs_lrgeditor_host_should_quit (CmacsLrgeditorHost *self)
{
  return self != NULL && lrg_editor_app_should_quit (self->app);
}

gint64
cmacs_lrgeditor_host_last_input_us (CmacsLrgeditorHost *self)
{
  return self != NULL ? self->last_input_us : 0;
}

const char *
cmacs_lrgeditor_host_status (CmacsLrgeditorHost *self)
{
  return self != NULL ? lrg_editor_app_get_status (self->app) : NULL;
}

gboolean
cmacs_lrgeditor_host_activate_action (CmacsLrgeditorHost *self, const char *id)
{
  gboolean ok;

  if (self == NULL || id == NULL)
    return FALSE;
  ok = lrg_editor_app_activate_action (self->app, id);
  host_touch (self);
  return ok;
}

char **
cmacs_lrgeditor_host_list_actions (CmacsLrgeditorHost *self)
{
  if (self == NULL)
    return NULL;
  return g_action_group_list_actions
           (G_ACTION_GROUP (lrg_editor_app_get_actions (self->app)));
}

#endif /* HAVE_CMACS_LIBREGNUM */
