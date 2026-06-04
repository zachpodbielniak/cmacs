/* cmacs-gsurf-view.c --- per-buffer gsurf view + live GTK embed.
 *
 * Copyright (C) 2026 Zach Podbielniak
 * SPDX-License-Identifier: AGPL-3.0-or-later
 *
 * Owns the buffer <-> GsurfView registry and the xwidget-style live
 * embed: each view's native WebKitGTK widget is parented into the pgtk
 * frame's GtkFixed (FRAME_GTK_WIDGET) and moved/sized to cover the
 * window body showing the buffer.  This is the one translation unit
 * that touches GTK directly; gsurf.h is itself GTK-free, so including
 * it alongside gtk/gtk.h + pgtkterm.h is safe (no type clashes).
 *
 * GsurfView signals are bridged to Emacs abnormal hooks
 * (cmacs-gsurf-{load,uri,title}-changed-functions) through the safe
 * dispatch layer so page events can drive Lisp. */

#include <config.h>

#ifdef HAVE_CMACS_GSURF

#include "lisp.h"
#include "buffer.h"
#include "frame.h"
#include "blockinput.h"
#include "cmacs-gsurf.h"
#include "cmacs-gsurf-internal.h"
#include "cmacs-eval-dispatch.h"
#include "cmacs-glib-loop.h"

#include <gsurf/gsurf.h>
#include <gtk/gtk.h>
#include <gdk/gdkkeysyms.h>

#ifdef HAVE_PGTK
#include "pgtkterm.h"
#endif

/* ── View struct ────────────────────────────────────────────────────── */

struct CmacsGsurfView
{
  Lisp_Object  buffer;       /* GC-rooted via Vcmacs_gsurf__buffers */
  guint        view_id;
  GsurfView   *view;         /* owned ref (gsurf_view_new) */
  GtkWidget   *widget;       /* native WebKitGTK widget (owned by view) */
  GtkWidget   *parent_fixed; /* current FRAME_GTK_WIDGET it sits in, or NULL */
  gboolean     offscreen;    /* headless: parked far off-area in the
                                frame's GtkFixed so WebKit runs JS but the
                                view is never visible (gsurf-lite) */
  gboolean     shown;
  /* Our explicit focus intent.  The web widget is created NON-focusable
   * (gtk_widget_set_can_focus FALSE) so a page that autofocuses an
   * element (DuckDuckGo's search box, etc.) cannot steal the GtkWindow's
   * keyboard focus from the Emacs edit widget -- by default Emacs (and
   * evil's SPC leader, C-w, M-x, ...) keeps every key.  `focused' is set
   * only when WE deliberately hand keys to the page (focus_page/follow),
   * which is the one moment we flip can_focus TRUE + grab.  Tracking our
   * own intent here (rather than querying gtk_widget_has_focus on the
   * outer widget, which lies when a descendant holds focus) makes the
   * Elisp focus logic reliable. */
  gboolean     focused;
};

/* ── Registries ─────────────────────────────────────────────────────── */

static GHashTable  *cmacs_gsurf__views   = NULL;  /* id -> CmacsGsurfView* */
static GHashTable  *cmacs_gsurf__by_view = NULL;  /* GsurfView* -> CmacsGsurfView* */
static guint        cmacs_gsurf__next_id = 1;
static Lisp_Object  Vcmacs_gsurf__buffers;        /* buffer -> make_uint(id) */

Lisp_Object *cmacs_gsurf__buffers_root (void);
Lisp_Object *
cmacs_gsurf__buffers_root (void)
{
  return &Vcmacs_gsurf__buffers;
}

static void
registry_init (void)
{
  if (!cmacs_gsurf__views)
    cmacs_gsurf__views = g_hash_table_new (g_direct_hash, g_direct_equal);
  if (!cmacs_gsurf__by_view)
    cmacs_gsurf__by_view = g_hash_table_new (g_direct_hash, g_direct_equal);
  if (NILP (Vcmacs_gsurf__buffers))
    Vcmacs_gsurf__buffers = CALLN (Fmake_hash_table, QCtest, Qeq);
}

bool
cmacs_gsurf_registry_empty_p (void)
{
  return !cmacs_gsurf__views
    || g_hash_table_size (cmacs_gsurf__views) == 0;
}

/* ── Signal -> Emacs hook bridge ────────────────────────────────────── */

/* Forward decl: defined in the focus section below.  on_load_changed
 * re-asserts the non-focusable subtree because WebKit rebuilds its
 * focusable WebKitWebViewBase on each navigation (and may autofocus a
 * page element), which would otherwise re-steal the keyboard. */
static void set_webview_focusable (CmacsGsurfView *v, gboolean can);

static void
run_hook2 (const char *hook, Lisp_Object buffer, Lisp_Object arg)
{
  cmacs_dispatch_safe_call3 (intern ("run-hook-with-args"),
                             intern (hook), buffer, arg);
}

/* Like run_hook2 but for a buffer-only abnormal hook (no extra arg). */
static void
run_hook1 (const char *hook, Lisp_Object buffer)
{
  cmacs_dispatch_safe_call2 (intern ("run-hook-with-args"),
                             intern (hook), buffer);
}

/* Escape STR into a freshly g_malloc'd Elisp double-quoted string literal
 * (backslash + double-quote escaped).  Used to embed a URI safely into a
 * deferred Elisp form for cmacs_gsurf_emacs_eval_async.  Caller g_free's. */
static char *
el_string (const char *str)
{
  GString *s = g_string_new ("\"");
  for (const char *p = str ? str : ""; *p; p++)
    {
      if (*p == '\\' || *p == '"')
        g_string_append_c (s, '\\');
      g_string_append_c (s, *p);
    }
  g_string_append_c (s, '"');
  return g_string_free (s, FALSE);
}

static void
on_uri_changed (GsurfView *view, const gchar *uri, gpointer user)
{
  CmacsGsurfView *v = user;
  (void) view;
  if (!v || NILP (v->buffer) || !BUFFERP (v->buffer)) return;
  run_hook2 ("cmacs-gsurf-uri-changed-functions", v->buffer,
             build_string (uri ? uri : ""));
}

static void
on_title_changed (GsurfView *view, const gchar *title, gpointer user)
{
  CmacsGsurfView *v = user;
  (void) view;
  if (!v || NILP (v->buffer) || !BUFFERP (v->buffer)) return;
  run_hook2 ("cmacs-gsurf-title-changed-functions", v->buffer,
             build_string (title ? title : ""));
}

static void
on_load_changed (GsurfView *view, gint event, gpointer user)
{
  CmacsGsurfView *v = user;
  (void) view;
  if (!v || NILP (v->buffer) || !BUFFERP (v->buffer)) return;

  /* Unless the user explicitly handed the page the keyboard, re-assert
   * the non-focusable subtree on every load: WebKit rebuilds its
   * WebKitWebViewBase and a page may autofocus an element (DuckDuckGo's
   * search box), which would otherwise grab the toplevel's focus away
   * from Emacs and make keys (SPC leader, C-w, ...) scroll the page. */
  if (!v->focused)
    {
      block_input ();
      set_webview_focusable (v, FALSE);
      if (v->widget
          && (gtk_widget_has_focus (v->widget)
              || gtk_widget_is_focus (v->widget)))
        {
          GtkWidget *fixed = v->parent_fixed
            ? v->parent_fixed : gtk_widget_get_parent (v->widget);
          if (fixed) gtk_widget_grab_focus (fixed);
        }
      unblock_input ();
    }

  /* GsurfLoadEvent: 0 started, 1 redirected, 2 committed, 3 finished. */
  const char *sym;
  switch (event)
    {
    case 0:  sym = "started";   break;
    case 2:  sym = "committed"; break;
    case 3:  sym = "finished";  break;
    default: sym = "changed";   break;
    }
  run_hook2 ("cmacs-gsurf-load-changed-functions", v->buffer, intern (sym));
}

/* The link URI under the pointer (or "" when the pointer leaves a link). */
static void
on_hovered_uri_changed (GsurfView *view, const gchar *uri, gpointer user)
{
  CmacsGsurfView *v = user;
  (void) view;
  if (!v || NILP (v->buffer) || !BUFFERP (v->buffer)) return;
  run_hook2 ("cmacs-gsurf-hovered-uri-changed-functions", v->buffer,
             build_string (uri ? uri : ""));
}

/* Estimated load progress, 0.0 .. 1.0. */
static void
on_progress_changed (GsurfView *view, gdouble progress, gpointer user)
{
  CmacsGsurfView *v = user;
  (void) view;
  if (!v || NILP (v->buffer) || !BUFFERP (v->buffer)) return;
  run_hook2 ("cmacs-gsurf-progress-changed-functions", v->buffer,
             make_float (progress));
}

/* The web content process crashed / was killed. */
static void
on_web_process_terminated (GsurfView *view, gpointer user)
{
  CmacsGsurfView *v = user;
  (void) view;
  if (!v || NILP (v->buffer) || !BUFFERP (v->buffer)) return;
  run_hook1 ("cmacs-gsurf-crashed-functions", v->buffer);
}

/* The page favicon changed. */
static void
on_favicon_changed (GsurfView *view, gpointer user)
{
  CmacsGsurfView *v = user;
  (void) view;
  if (!v || NILP (v->buffer) || !BUFFERP (v->buffer)) return;
  run_hook1 ("cmacs-gsurf-favicon-changed-functions", v->buffer);
}

/* A popup / new-window request (target=_blank, window.open, middle-click).
 * Returning a live popup GsurfView from inside WebKit's `create' emission
 * is unsafe: the returned view must be brand-new + unrealized for WebKit to
 * take over, and we cannot create an Emacs buffer + view synchronously
 * inside a GLib-dispatched signal (it would re-enter the command loop / GC
 * during emission).  So block the WebKit-managed popup (return NULL) and
 * async-open a normal gsurf buffer with the requested URI instead. */
static GsurfView *
on_create_view (GsurfView *view, const gchar *uri, gpointer user)
{
  CmacsGsurfView *v = user;
  (void) view;
  if (!v || NILP (v->buffer) || !BUFFERP (v->buffer))
    return NULL;
  if (uri && *uri)
    {
      char *lit  = el_string (uri);
      char *form = g_strdup_printf ("(cmacs-gsurf--open-popup %s)", lit);
      cmacs_gsurf_emacs_eval_async (form);
      g_free (form);
      g_free (lit);
    }
  return NULL;
}

/* ── Focus handoff ──────────────────────────────────────────────────────
 *
 * The live WebKitGTK child grabs GTK keyboard focus when shown or
 * clicked; once it has focus, Emacs's key handling (and therefore evil,
 * C-w, C-x, M-x, ...) never sees keystrokes.  We make focus explicit:
 *   - On the first placement we hand focus back to the frame's edit
 *     widget, so a freshly-opened gsurf buffer is in Emacs/evil control
 *     (the page is shown but not capturing keys).
 *   - Escape pressed in the page returns focus to Emacs (see the
 *     key-press handler) and asks evil to drop to normal state.
 *   - Elisp window-selection hooks call cmacs_gsurf_release_focus when
 *     the user moves to a non-gsurf window, so leaving the buffer (even
 *     by mouse) always restores Emacs keyboard control.
 * The page is (re)focused only on an explicit click or
 * `cmacs-gsurf-focus-page'. */

/* Set can-focus on a widget AND every descendant.  Crucial for WebKit:
 * a WebKitWebView is a GtkContainer whose actual key-consuming widget is
 * an internal WebKitWebViewBase DESCENDANT, so `can_focus(FALSE)' on the
 * outer widget alone does NOT stop the page from grabbing the toplevel's
 * keyboard focus (the descendant is still focusable).  Toggling the whole
 * subtree is what actually keeps keys with Emacs by default. */
static void
set_focusable_cb (GtkWidget *child, gpointer can)
{
  gtk_widget_set_can_focus (child, GPOINTER_TO_INT (can));
  if (GTK_IS_CONTAINER (child))
    gtk_container_forall (GTK_CONTAINER (child), set_focusable_cb, can);
}

static void
set_webview_focusable (CmacsGsurfView *v, gboolean can)
{
  if (!v || !v->widget) return;
  gtk_widget_set_can_focus (v->widget, can);
  if (GTK_IS_CONTAINER (v->widget))
    gtk_container_forall (GTK_CONTAINER (v->widget), set_focusable_cb,
                          GINT_TO_POINTER (can));
}

/* Make V's web widget subtree non-focusable so it cannot capture the
 * GtkWindow's keyboard focus, then (if it somehow holds it) hand focus
 * back to the frame edit widget (its GtkFixed parent == FRAME_GTK_WIDGET).
 * Safe to call from a GTK signal handler: it touches no Lisp. */
static void
release_to_emacs (CmacsGsurfView *v)
{
  if (!v) return;
  set_webview_focusable (v, FALSE);
  v->focused = FALSE;
  GtkWidget *fixed = v->parent_fixed;
  if (fixed == NULL && v->widget)
    fixed = gtk_widget_get_parent (v->widget);
  if (fixed != NULL)
    gtk_widget_grab_focus (fixed);
}

/* Translate a GDK modifier mask to gsurf's GsurfKeyMod flags. */
static guint
translate_mods (guint state)
{
  guint m = GSURF_MOD_NONE;
  if (state & GDK_SHIFT_MASK)   m |= GSURF_MOD_SHIFT;
  if (state & GDK_CONTROL_MASK) m |= GSURF_MOD_CTRL;
  if (state & GDK_MOD1_MASK)    m |= GSURF_MOD_ALT;
  if (state & GDK_SUPER_MASK)   m |= GSURF_MOD_SUPER;
  return m;
}

static gboolean
on_view_key_press (GtkWidget *w, GdkEventKey *ev, gpointer user)
{
  CmacsGsurfView *v = user;
  GsurfModuleManager *mgr = gsurf_module_manager_get_default ();
  guint mods = translate_mods (ev->state);
  gboolean has_mod =
    (mods & (GSURF_MOD_CTRL | GSURF_MOD_ALT | GSURF_MOD_SUPER)) != 0;
  gboolean is_escape = (ev->keyval == GDK_KEY_Escape);
  (void) w;

  /* Escape ALWAYS hands control back to Emacs/evil -- it is the
   * universal "return to the editor" gesture and must never be swallowed
   * by a module.  We still dispatch it to the modules first so the modal
   * module can clean up (clear a link-hint overlay, leave INSERT mode,
   * blur a focused field), but we IGNORE whether it consumed the event
   * and unconditionally pull GTK focus back to the frame (no Lisp --
   * safe here) + schedule an idle that drops evil to normal state.
   *
   * This is the fix for "after Esc, Space still scrolls the page": the
   * modal module consumes Escape in both NORMAL and INSERT modes, so
   * dispatching-then-returning left focus on the WebKit widget and the
   * page kept receiving keys (Space = scroll).  Returning focus here
   * unconditionally guarantees one Escape is enough. */
  if (is_escape)
    {
      gsurf_module_manager_dispatch_key_event (
        mgr, v->view, ev->keyval, ev->hardware_keycode, mods,
        GSURF_MODE_NORMAL);
      release_to_emacs (v);
      cmacs_gsurf_emacs_eval_async ("(cmacs-gsurf--on-escape)");
      return TRUE;
    }

  /* Safety net: a key reached the web widget although we never handed it
   * focus (the page grabbed GTK focus behind our back despite
   * can_focus=FALSE -- shouldn't happen, but WebKit is large).  Bounce
   * focus back to Emacs and swallow this one key rather than let the page
   * act on it; the next key then reaches Emacs normally. */
  if (!v->focused)
    {
      release_to_emacs (v);
      return TRUE;
    }

  /* While the page is "typing" -- a DOM editable element is focused, or
   * the modal module is in INSERT passthrough -- bare keys must reach
   * the page and not be consumed by an input-handler module.  Modified
   * keys still dispatch (shortcuts). */
  gboolean passthrough =
    gsurf_module_manager_get_input_passthrough (mgr)
    || (v->view && gsurf_view_get_editing (v->view));

  if (!(passthrough && !has_mod))
    {
      /* Give the input-handler modules (modal: hjkl scroll, f link
       * hints, i insert; tabs; ...) first crack at the key.  This is the
       * dispatch the standalone gsurf binary runs from its window key
       * handler -- cmacs runs it here because it parents the raw
       * GsurfView with no GsurfWindow, so without this the modal module
       * never sees a keystroke (hjkl/f do nothing). */
      if (gsurf_module_manager_dispatch_key_event (
            mgr, v->view, ev->keyval, ev->hardware_keycode, mods,
            GSURF_MODE_NORMAL))
        return TRUE;
    }

  return FALSE;
}

/* ── Construction / destruction ─────────────────────────────────────── */

CmacsGsurfView *
cmacs_gsurf_view_new (Lisp_Object buffer)
{
  CHECK_BUFFER (buffer);
  registry_init ();

  GsurfView *gv = gsurf_view_new ();
  if (gv == NULL)
    return NULL;

  GsurfConfig *cfg = cmacs_gsurf_config ();
  if (cfg != NULL && cfg->settings != NULL)
    gsurf_view_apply_settings (gv, cfg->settings);

  GtkWidget *w = (GtkWidget *) gsurf_view_get_native_widget (gv);
  if (w == NULL)
    {
      g_object_unref (gv);
      return NULL;
    }

  CmacsGsurfView *v = g_new0 (CmacsGsurfView, 1);
  v->buffer  = buffer;
  v->view    = gv;
  v->widget  = g_object_ref_sink (w);
  v->view_id = cmacs_gsurf__next_id++;

  g_signal_connect (gv, "uri-changed",   G_CALLBACK (on_uri_changed),   v);
  g_signal_connect (gv, "title-changed", G_CALLBACK (on_title_changed), v);
  g_signal_connect (gv, "load-changed",  G_CALLBACK (on_load_changed),  v);
  /* The previously-dropped signals: link hover, load progress, web-process
   * crash, favicon, and popup/new-window requests.  All are on GV
   * (== v->view) with data V, so g_signal_handlers_disconnect_by_data
   * (v->view, v) in cmacs_gsurf_view_destroy tears them down. */
  g_signal_connect (gv, "hovered-uri-changed",
                    G_CALLBACK (on_hovered_uri_changed), v);
  g_signal_connect (gv, "progress-changed",
                    G_CALLBACK (on_progress_changed), v);
  g_signal_connect (gv, "web-process-terminated",
                    G_CALLBACK (on_web_process_terminated), v);
  g_signal_connect (gv, "favicon-changed",
                    G_CALLBACK (on_favicon_changed), v);
  g_signal_connect (gv, "create-view",
                    G_CALLBACK (on_create_view), v);

  /* Intercept Escape on the web widget so the user can always hand
   * control back to Emacs/evil.  Connected non-after so it runs before
   * WebKit's own key handling. */
  gtk_widget_add_events (v->widget, GDK_KEY_PRESS_MASK);
  g_signal_connect (v->widget, "key-press-event",
                    G_CALLBACK (on_view_key_press), v);

  /* Permission requests (geolocation, notifications, camera/mic, ...).
   * Connected on the native WebKitWebView (== v->widget in WK2GTK 4.1)
   * with data V; cmacs_gsurf_view_destroy disconnects by data on v->widget
   * before unreffing it, so no callback fires on a freed view. */
  cmacs_gsurf_permissions_attach (v->widget, v);

  /* Create the web widget NON-focusable: by default keyboard focus stays
   * with the Emacs frame, so SPC (the evil/Doom leader), C-w, M-x, etc.
   * all work in a gsurf buffer.  A page that autofocuses an element
   * cannot grab keys because gtk_widget_grab_focus is a no-op on a
   * non-focusable widget.  We flip this TRUE only on explicit
   * focus_page/follow; pointer events (clicks, scroll wheel, link nav)
   * are delivered regardless of focusability, so mouse browsing still
   * works fully.  Press `i'/RET to type into the page.  Recurse into the
   * subtree: a WebKitWebView's key-consuming widget is a descendant
   * (WebKitWebViewBase), so the outer widget alone is not enough. */
  set_webview_focusable (v, FALSE);

  g_hash_table_insert (cmacs_gsurf__views,
                       GUINT_TO_POINTER (v->view_id), v);
  g_hash_table_insert (cmacs_gsurf__by_view, gv, v);
  Fputhash (buffer, make_uint (v->view_id), Vcmacs_gsurf__buffers);
  return v;
}

/* ── Offscreen (headless) views ────────────────────────────────────── *
 *
 * gsurf-lite renders a page with no on-screen widget: the post-JS DOM is
 * extracted and re-rendered as Emacs text via shr.
 *
 * WebKit only spawns its web process / lays out / runs JavaScript once
 * its widget is realized inside a real on-screen GtkWindow.  A pure
 * GtkOffscreenWindow does NOT start it (verified empirically: the
 * run-javascript callback never fires), so instead we park the widget in
 * the selected frame's GtkFixed at a normal viewport size but far below
 * the visible area, where GTK clips it away.  It is realized (so it runs
 * JS with a real 1280x1024 viewport -- important for real sites' layout)
 * yet never visible, and it is never resized to a window rect
 * (cmacs_gsurf_view_place / _hide are no-ops for offscreen views), so it
 * can never cover the rendered text. */

#define CMACS_GSURF_OFFSCREEN_X 0
#define CMACS_GSURF_OFFSCREEN_Y 100000   /* below any plausible frame */
#define CMACS_GSURF_OFFSCREEN_W 1280
#define CMACS_GSURF_OFFSCREEN_H 1024

void
cmacs_gsurf_view_make_offscreen (CmacsGsurfView *v)
{
  if (v == NULL || v->widget == NULL || v->offscreen)
    return;
#ifdef HAVE_PGTK
  struct frame *f = SELECTED_FRAME ();
  if (f == NULL || !FRAME_LIVE_P (f) || !FRAME_PGTK_P (f))
    return;
  GtkWidget *fixed = FRAME_GTK_WIDGET (f);
  if (fixed == NULL || !GTK_IS_FIXED (fixed))
    return;
  block_input ();
  v->offscreen = TRUE;
  GtkWidget *cur = gtk_widget_get_parent (v->widget);
  if (cur != fixed)
    {
      if (cur != NULL)
        gtk_container_remove (GTK_CONTAINER (cur), v->widget);
      gtk_fixed_put (GTK_FIXED (fixed), v->widget,
                     CMACS_GSURF_OFFSCREEN_X, CMACS_GSURF_OFFSCREEN_Y);
      v->parent_fixed = fixed;
    }
  else
    gtk_fixed_move (GTK_FIXED (fixed), v->widget,
                    CMACS_GSURF_OFFSCREEN_X, CMACS_GSURF_OFFSCREEN_Y);
  gtk_widget_set_size_request (v->widget,
                               CMACS_GSURF_OFFSCREEN_W, CMACS_GSURF_OFFSCREEN_H);
  /* Showing it inside the already-realized frame realizes the widget ->
     WebKit spawns its web process and starts running JS / laying out. */
  gtk_widget_show (v->widget);
  v->shown = TRUE;
  set_webview_focusable (v, FALSE);
  unblock_input ();
#else
  (void) v;
#endif
}

bool
cmacs_gsurf_view_offscreen_p (CmacsGsurfView *v)
{
  return v != NULL && v->offscreen;
}

void
cmacs_gsurf_view_destroy (CmacsGsurfView *v)
{
  if (!v) return;

  block_input ();
  if (v->widget != NULL)
    {
      g_signal_handlers_disconnect_by_data (v->view, v);
      /* Also disconnect handlers placed on the native web widget itself
       * (key-press, permission-request, and the Phase-3 JS message handler)
       * before it is unreffed, so a late callback can't deref a freed V. */
      g_signal_handlers_disconnect_by_data (v->widget, v);
      GtkWidget *parent = gtk_widget_get_parent (v->widget);
      if (parent != NULL)
        gtk_container_remove (GTK_CONTAINER (parent), v->widget);
      g_object_unref (v->widget);
      v->widget = NULL;
    }
  unblock_input ();

  if (cmacs_gsurf__views)
    g_hash_table_remove (cmacs_gsurf__views,
                         GUINT_TO_POINTER (v->view_id));
  /* Drop the GsurfView* -> view reverse entry BEFORE freeing V so a late
   * JS-bridge message (cmacs_gsurf_js_message) resolves to nothing and
   * no-ops instead of dereferencing a freed view. */
  if (cmacs_gsurf__by_view && v->view)
    g_hash_table_remove (cmacs_gsurf__by_view, v->view);
  if (!NILP (Vcmacs_gsurf__buffers))
    Fremhash (v->buffer, Vcmacs_gsurf__buffers);

  if (v->view != NULL)
    g_object_unref (v->view);
  g_free (v);
}

CmacsGsurfView *
cmacs_gsurf_view_for_buffer (Lisp_Object buffer)
{
  if (NILP (Vcmacs_gsurf__buffers) || !cmacs_gsurf__views)
    return NULL;
  Lisp_Object id = Fgethash (buffer, Vcmacs_gsurf__buffers, Qnil);
  if (NILP (id))
    return NULL;
  return g_hash_table_lookup (cmacs_gsurf__views,
                              GUINT_TO_POINTER ((guint) XFIXNUM (id)));
}

Lisp_Object
cmacs_gsurf_view_buffer (CmacsGsurfView *v)
{
  return v ? v->buffer : Qnil;
}

/* The native web widget (WebKitWebView in WK2GTK 4.1) as a void* so the
 * webkit-only translation units (snapshot/print) can reach the WebKit API
 * without the rest of cmacs seeing a WebKit type. */
void *
cmacs_gsurf_view_native_widget (CmacsGsurfView *v)
{
  return v ? (void *) v->widget : NULL;
}

/* ── Placement (the live embed) ─────────────────────────────────────── */

void
cmacs_gsurf_view_place (CmacsGsurfView *v, Lisp_Object frame,
                        int x, int y, int w, int h)
{
  if (!v || !v->widget) return;
  /* Headless (gsurf-lite) views are never shown on a frame -- placing one
     would yank the live page on top of the text buffer. */
  if (v->offscreen) return;
#ifdef HAVE_PGTK
  struct frame *f = XFRAME (frame);
  if (!FRAME_LIVE_P (f) || !FRAME_PGTK_P (f))
    return;
  GtkWidget *fixed = FRAME_GTK_WIDGET (f);
  if (fixed == NULL || !GTK_IS_FIXED (fixed))
    return;

  block_input ();
  GtkWidget *cur = gtk_widget_get_parent (v->widget);
  if (cur != fixed)
    {
      if (cur != NULL)
        gtk_container_remove (GTK_CONTAINER (cur), v->widget);
      gtk_fixed_put (GTK_FIXED (fixed), v->widget, x, y);
      v->parent_fixed = fixed;
    }
  else
    gtk_fixed_move (GTK_FIXED (fixed), v->widget, x, y);

  gtk_widget_set_size_request (v->widget, MAX (1, w), MAX (1, h));
  gtk_widget_show (v->widget);
  v->shown = TRUE;

  /* Re-assert the non-focusable subtree now that the widget is shown and
   * its WebKitWebViewBase descendant is realised (it did not exist when
   * the view was created).  Unless the user explicitly focused the page,
   * this guarantees keyboard focus stays with the Emacs frame so SPC/C-w/
   * M-x work; without recursing into the descendant, a page that
   * autofocuses an element would re-steal the keyboard. */
  if (!v->focused)
    {
      set_webview_focusable (v, FALSE);
      if (gtk_widget_has_focus (v->widget) || gtk_widget_is_focus (v->widget))
        gtk_widget_grab_focus (fixed);
    }
  unblock_input ();
#else
  (void) frame; (void) x; (void) y; (void) w; (void) h;
#endif
}

/* ── Focus control (called from the defun layer) ────────────────────── */

void
cmacs_gsurf_view_focus_page (CmacsGsurfView *v)
{
  if (!v || !v->widget) return;
#ifdef HAVE_PGTK
  block_input ();
  /* Flip the whole subtree focusable, then grab -- this is the one place
   * the page is allowed to take the keyboard.  WebKit then routes keys to
   * the focused DOM element and the modal module's hjkl/f/i apply. */
  set_webview_focusable (v, TRUE);
  gtk_widget_grab_focus (v->widget);
  v->focused = TRUE;
  unblock_input ();
#endif
}

/* Focus the page and trigger the modal module's link-hint (follow) mode
 * by dispatching `f' to it, so the hint labels appear immediately.  The
 * chord the user then types arrives through on_view_key_press (the page
 * now has GTK focus) and is dispatched to the modal module in FOLLOW
 * mode, which matches it and clicks the target. */
void
cmacs_gsurf_view_follow (CmacsGsurfView *v)
{
  if (!v || !v->view || !v->widget) return;
#ifdef HAVE_PGTK
  block_input ();
  set_webview_focusable (v, TRUE);
  gtk_widget_grab_focus (v->widget);
  v->focused = TRUE;
  unblock_input ();
#endif
  gsurf_module_manager_dispatch_key_event (
    gsurf_module_manager_get_default (), v->view,
    GDK_KEY_f, 0, GSURF_MOD_NONE, GSURF_MODE_NORMAL);
}

bool
cmacs_gsurf_view_page_focused_p (CmacsGsurfView *v)
{
  /* Report OUR intent, not gtk_widget_has_focus on the outer widget --
   * WebKit's focusable content is a descendant, so the outer widget can
   * report no focus while the page actually holds the keyboard.  `focused'
   * is true exactly between an explicit focus_page/follow and the next
   * release (Escape / window switch / release_focus). */
  return v ? (bool) v->focused : false;
}

/* Hand keyboard focus to the selected frame's edit widget, so Emacs
 * (and evil) regain control.  Used by the window-selection hook and the
 * `cmacs-gsurf-release-focus' command.  Also makes EVERY gsurf view
 * non-focusable again, so no page can re-grab the keyboard behind our
 * back once the user is back in Emacs. */
void
cmacs_gsurf_release_focus (void)
{
#ifdef HAVE_PGTK
  block_input ();
  if (cmacs_gsurf__views)
    {
      GHashTableIter it;
      gpointer val;
      g_hash_table_iter_init (&it, cmacs_gsurf__views);
      while (g_hash_table_iter_next (&it, NULL, &val))
        {
          CmacsGsurfView *v = val;
          if (v && v->widget)
            set_webview_focusable (v, FALSE);
          if (v)
            v->focused = FALSE;
        }
    }
  struct frame *f = SELECTED_FRAME ();
  if (f != NULL && FRAME_LIVE_P (f) && FRAME_PGTK_P (f))
    {
      GtkWidget *wdg = FRAME_GTK_WIDGET (f);
      if (wdg != NULL)
        gtk_widget_grab_focus (wdg);
    }
  unblock_input ();
#endif
}

void
cmacs_gsurf_view_hide (CmacsGsurfView *v)
{
  if (!v || !v->widget) return;
  /* Headless (gsurf-lite) views stay realized in their GtkOffscreenWindow
     so WebKit keeps running; never hide them. */
  if (v->offscreen) return;
  block_input ();
  gtk_widget_hide (v->widget);
  v->shown = FALSE;
  unblock_input ();
}

/* ── Navigation / state wrappers ────────────────────────────────────── */

void
cmacs_gsurf_view_load_uri (CmacsGsurfView *v, const char *uri)
{ if (v && v->view) gsurf_view_load_uri (v->view, uri); }

void
cmacs_gsurf_view_reload (CmacsGsurfView *v, bool nocache)
{ if (v && v->view) gsurf_view_reload (v->view, nocache); }

void
cmacs_gsurf_view_stop (CmacsGsurfView *v)
{ if (v && v->view) gsurf_view_stop_loading (v->view); }

void
cmacs_gsurf_view_go_back (CmacsGsurfView *v)
{ if (v && v->view) gsurf_view_go_back (v->view); }

void
cmacs_gsurf_view_go_forward (CmacsGsurfView *v)
{ if (v && v->view) gsurf_view_go_forward (v->view); }

bool
cmacs_gsurf_view_can_go_back (CmacsGsurfView *v)
{ return v && v->view && gsurf_view_can_go_back (v->view); }

bool
cmacs_gsurf_view_can_go_forward (CmacsGsurfView *v)
{ return v && v->view && gsurf_view_can_go_forward (v->view); }

char *
cmacs_gsurf_view_get_uri (CmacsGsurfView *v)
{
  if (!v || !v->view) return NULL;
  const gchar *u = gsurf_view_get_uri (v->view);
  return (u && *u) ? g_strdup (u) : NULL;
}

char *
cmacs_gsurf_view_get_title (CmacsGsurfView *v)
{
  if (!v || !v->view) return NULL;
  const gchar *t = gsurf_view_get_title (v->view);
  return (t && *t) ? g_strdup (t) : NULL;
}

double
cmacs_gsurf_view_get_progress (CmacsGsurfView *v)
{
  return (v && v->view)
    ? gsurf_view_get_estimated_load_progress (v->view) : 0.0;
}

void
cmacs_gsurf_view_set_zoom (CmacsGsurfView *v, double z)
{ if (v && v->view) gsurf_view_set_zoom_level (v->view, z); }

double
cmacs_gsurf_view_get_zoom (CmacsGsurfView *v)
{ return (v && v->view) ? gsurf_view_get_zoom_level (v->view) : 1.0; }

void
cmacs_gsurf_view_run_js (CmacsGsurfView *v, const char *js)
{ if (v && v->view) gsurf_view_run_javascript_async (v->view, js, NULL, NULL, NULL); }

/* ---- run-javascript with a Lisp callback (result return channel) --- *
 *
 * The fire-and-forget path above discards the script value.  This
 * variant delivers it back to a one-shot Lisp CALLBACK.  GC safety: the
 * callback lives in the staticpro'd cookie registry in
 * cmacs-eval-dispatch.c (never a raw Lisp_Object across the async gap).
 *
 * Threading: gsurf's run_javascript_async passes the underlying
 * WebKitWebView (not the GsurfView) as the GAsyncResult source object,
 * so we stash a ref to the GsurfView -- ref-held so it outlives a buffer
 * kill mid-flight -- and hop through the cmacs GMainContext before
 * touching Lisp (build_string + the callback must run on the main
 * thread; webkit's callback already fires there, but the invoke keeps
 * us robust to backend threading and matches the whisper pattern). */

typedef struct
{
  GsurfView *view;      /* reffed; _finish needs it (source is the webview) */
  uint64_t   cb_cookie;
  char      *result;    /* owned; set in finish, consumed in main */
} CmacsGsurfJsCall;

static gboolean
js_result_main (gpointer data)
{
  CmacsGsurfJsCall *c = data;
  cmacs_dispatch_callback_invoke1 (c->cb_cookie,
                                   build_string (c->result ? c->result : ""));
  g_free (c->result);
  g_object_unref (c->view);
  g_free (c);
  return G_SOURCE_REMOVE;
}

static void
js_finish_cb (GObject *source, GAsyncResult *res, gpointer user)
{
  CmacsGsurfJsCall *c = user;
  GError *err = NULL;
  (void) source;
  c->result = gsurf_view_run_javascript_finish (c->view, res, &err);
  g_clear_error (&err);
  g_main_context_invoke (cmacs_glib_get_context (), js_result_main, c);
}

void
cmacs_gsurf_view_run_js_cb (CmacsGsurfView *v, const char *js,
                            Lisp_Object callback)
{
  if (!v || !v->view)
    return;
  if (NILP (callback))
    {
      gsurf_view_run_javascript_async (v->view, js, NULL, NULL, NULL);
      return;
    }
  CmacsGsurfJsCall *c = g_new0 (CmacsGsurfJsCall, 1);
  c->view      = g_object_ref (v->view);
  c->cb_cookie = cmacs_dispatch_callback_register (callback);
  gsurf_view_run_javascript_async (v->view, js, NULL, js_finish_cb, c);
}

/* ---- user-script injection (idempotent per-page bootstrap) -------- *
 *
 * Wraps gsurf_view_add_user_script (the WebKitUserContentManager path
 * the stock userscripts module uses).  Caret mode injects its engine
 * once per view here so it survives navigation / SPA route changes;
 * gsurf-lite uses it for its extraction helper. */

void
cmacs_gsurf_view_add_user_script (CmacsGsurfView *v, const char *src,
                                  bool at_end)
{
  if (v && v->view && src)
    gsurf_view_add_user_script (v->view, src, at_end);
}

void
cmacs_gsurf_view_find (CmacsGsurfView *v, const char *text, bool forward)
{ if (v && v->view) gsurf_view_find (v->view, text, FALSE, forward); }

void
cmacs_gsurf_view_find_next (CmacsGsurfView *v, bool forward)
{
  if (!v || !v->view) return;
  if (forward) gsurf_view_find_next (v->view);
  else         gsurf_view_find_previous (v->view);
}

void
cmacs_gsurf_string_free (char *s)
{ g_free (s); }

/* ── Host bridge for gsurf modules ──────────────────────────────────── */

/* Idle payload: an Elisp source string to evaluate.  */
static gboolean
eval_idle (gpointer data)
{
  char *src = data;
  /* Evaluate via the Elisp dispatcher, which wraps eval in a
     condition-case so a bad form can't escape into signal_or_quit.
     cmacs_dispatch_safe_call1 clears waiting_for_input for the call. */
  cmacs_dispatch_safe_call1 (intern ("cmacs-gsurf--module-eval"),
                             build_string (src));
  g_free (src);
  return G_SOURCE_REMOVE;
}

/* Called from the cmacs gsurf modules (resolved from the emacs binary at
   module-load time) to run ELISP on the Emacs main thread.  Deferred via
   an idle on the cmacs GMainContext so evaluation never nests inside the
   WebKit signal emission that triggered it. */
void
cmacs_gsurf_emacs_eval_async (const char *elisp)
{
  if (elisp == NULL || *elisp == '\0')
    return;
  GSource *src = g_idle_source_new ();
  g_source_set_callback (src, eval_idle, g_strdup (elisp), NULL);
  g_source_attach (src, cmacs_glib_get_context ());
  g_source_unref (src);
}

/* ── JS -> Emacs message channel host bridge ────────────────────────── *
 *
 * Called from the cmacs JS-bridge gsurf module
 * (modules/gsurf-cmacs-bridge-module.c) when a page posts via
 * window.cmacs.send (window.webkit.messageHandlers.cmacs).  GSURF_VIEW is
 * the GsurfView* the message came from (passed as void* to keep this
 * header gsurf-free); MESSAGE is the raw JSON string {channel,payload}.
 *
 * We own the buffer<->view registry, so we resolve the originating buffer
 * here and hand the message to the Elisp dispatcher.  The reverse map is
 * validated (a freed/unknown view no-ops) so a late callback after a
 * buffer kill is safe.  MESSAGE is delivered as DATA only: the dispatcher
 * parses JSON and routes by channel -- it is never evaluated as code. */
void
cmacs_gsurf_js_message (void *gsurf_view, const char *message)
{
  if (gsurf_view == NULL || message == NULL || !cmacs_gsurf__by_view)
    return;
  CmacsGsurfView *v = g_hash_table_lookup (cmacs_gsurf__by_view, gsurf_view);
  if (!v || NILP (v->buffer) || !BUFFERP (v->buffer))
    return;
  cmacs_dispatch_safe_call2 (intern ("cmacs-gsurf--js-message"),
                             v->buffer, build_string (message));
}

#endif /* HAVE_CMACS_GSURF */
