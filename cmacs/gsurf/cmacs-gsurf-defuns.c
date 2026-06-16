/* cmacs-gsurf-defuns.c --- Elisp entry points for the gsurf browser.
 *
 * Copyright (C) 2026 Zach Podbielniak
 * SPDX-License-Identifier: AGPL-3.0-or-later
 *
 * Thin DEFUN layer over the plain-C view API in cmacs-gsurf.h.  This
 * translation unit never sees gsurf.h / GTK / WebKit types — it speaks
 * only Lisp_Object and C strings, so it stays a clean Emacs-C file. */

#include <config.h>

#ifdef HAVE_CMACS_GSURF

#include "lisp.h"
#include "buffer.h"
#include "frame.h"
#include "coding.h"
#include "cmacs-gsurf.h"

void syms_of_cmacs_gsurf_defuns (void);

/* Resolve BUFFER's view or signal.  */
static CmacsGsurfView *
require_view (Lisp_Object buffer)
{
  CHECK_BUFFER (buffer);
  CmacsGsurfView *v = cmacs_gsurf_view_for_buffer (buffer);
  if (!v)
    xsignal1 (Qcmacs_gsurf_error,
              build_string ("no gsurf view attached to buffer"));
  return v;
}

/* Convert a freshly g_malloc'd C string to a Lisp string (or nil),
   freeing the C string.  */
static Lisp_Object
take_string (char *s)
{
  if (s == NULL)
    return Qnil;
  Lisp_Object r = build_string (s);
  cmacs_gsurf_string_free (s);
  return r;
}

/* UTF-8 bytes of a Lisp string, for passing to the gsurf/WebKit API.  */
static const char *
utf8 (Lisp_Object string)
{
  return SSDATA (code_convert_string_norecord (string, intern ("utf-8"),
                                               true));
}

DEFUN ("cmacs-gsurf-supported-p", Fcmacs_gsurf_supported_p,
       Scmacs_gsurf_supported_p, 0, 0, 0,
       doc: /* Return t when cmacs-gsurf is built into this cmacs.
Note that an attached browser additionally needs a windowing backend
(a display); see `cmacs-gsurf-attach'.  */)
  (void)
{
  return Qt;
}

DEFUN ("cmacs-gsurf-lrg-supported-p", Fcmacs_gsurf_lrg_supported_p,
       Scmacs_gsurf_lrg_supported_p, 0, 0, 0,
       doc: /* Return t when the gsurf libregnum backend is built in.
This is the GTK-free backend used under `emacs --lrg': the page is
rendered to a libregnum texture composited by the lrg display backend.
When nil, gsurf works only on GTK (pgtk) frames.  */)
  (void)
{
#ifdef HAVE_CMACS_GSURF_LRG
  return Qt;
#else
  return Qnil;
#endif
}

DEFUN ("cmacs-gsurf-attach", Fcmacs_gsurf_attach,
       Scmacs_gsurf_attach, 1, 2, 0,
       doc: /* Attach a live gsurf web view to BUFFER.
Brings up the gsurf runtime on first use and creates a WebKitGTK view
parented into BUFFER's frame.  Idempotent.  Signals `cmacs-gsurf-error'
if the windowing backend is unavailable.

With optional OFFSCREEN non-nil, the view is created headless: its
widget is hosted in a GtkOffscreenWindow (so WebKit still realizes and
runs JavaScript) and is never shown on a frame.  This is what gsurf-lite
uses to render a page and extract its post-JS DOM as Emacs text.  */)
  (Lisp_Object buffer, Lisp_Object offscreen)
{
  CHECK_BUFFER (buffer);
  if (cmacs_gsurf_view_for_buffer (buffer))
    return Qt;
  if (!cmacs_gsurf_runtime_ensure ())
    xsignal1 (Qcmacs_gsurf_error,
              build_string ("gsurf backend unavailable (no display?)"));
  CmacsGsurfView *v = cmacs_gsurf_view_new (buffer);
  if (!v)
    xsignal1 (Qcmacs_gsurf_error,
              build_string ("failed to create gsurf view"));
  if (!NILP (offscreen))
    cmacs_gsurf_view_make_offscreen (v);
  return Qt;
}

DEFUN ("cmacs-gsurf-offscreen-p", Fcmacs_gsurf_offscreen_p,
       Scmacs_gsurf_offscreen_p, 1, 1, 0,
       doc: /* Return t if BUFFER's gsurf view is headless (offscreen).
Offscreen views (gsurf-lite) are realized in a GtkOffscreenWindow and
never placed on a frame.  Returns nil if BUFFER has no view.  */)
  (Lisp_Object buffer)
{
  CHECK_BUFFER (buffer);
  CmacsGsurfView *v = cmacs_gsurf_view_for_buffer (buffer);
  return (v && cmacs_gsurf_view_offscreen_p (v)) ? Qt : Qnil;
}

DEFUN ("cmacs-gsurf-detach", Fcmacs_gsurf_detach,
       Scmacs_gsurf_detach, 1, 1, 0,
       doc: /* Detach and destroy the gsurf view bound to BUFFER.  */)
  (Lisp_Object buffer)
{
  CHECK_BUFFER (buffer);
  CmacsGsurfView *v = cmacs_gsurf_view_for_buffer (buffer);
  if (v)
    cmacs_gsurf_view_destroy (v);
  return Qt;
}

DEFUN ("cmacs-gsurf-attached-p", Fcmacs_gsurf_attached_p,
       Scmacs_gsurf_attached_p, 1, 1, 0,
       doc: /* Return t if BUFFER has an attached gsurf view.  */)
  (Lisp_Object buffer)
{
  CHECK_BUFFER (buffer);
  return cmacs_gsurf_view_for_buffer (buffer) ? Qt : Qnil;
}

DEFUN ("cmacs-gsurf-place", Fcmacs_gsurf_place,
       Scmacs_gsurf_place, 6, 6, 0,
       doc: /* Position BUFFER's gsurf widget on FRAME at pixel rect X Y WIDTH HEIGHT.
Coordinates are relative to FRAME.  Called from the Elisp
window-configuration and scroll hooks to keep the live widget aligned
with the window showing the buffer.  */)
  (Lisp_Object buffer, Lisp_Object frame, Lisp_Object x, Lisp_Object y,
   Lisp_Object width, Lisp_Object height)
{
  CmacsGsurfView *v = require_view (buffer);
  CHECK_FRAME (frame);
  CHECK_FIXNUM (x); CHECK_FIXNUM (y);
  CHECK_FIXNAT (width); CHECK_FIXNAT (height);
  cmacs_gsurf_view_place (v, frame, XFIXNUM (x), XFIXNUM (y),
                          XFIXNUM (width), XFIXNUM (height));
  return Qt;
}

DEFUN ("cmacs-gsurf-hide", Fcmacs_gsurf_hide,
       Scmacs_gsurf_hide, 1, 1, 0,
       doc: /* Hide BUFFER's gsurf widget (buffer no longer displayed).  */)
  (Lisp_Object buffer)
{
  CHECK_BUFFER (buffer);
  CmacsGsurfView *v = cmacs_gsurf_view_for_buffer (buffer);
  if (v)
    cmacs_gsurf_view_hide (v);
  return Qt;
}

DEFUN ("cmacs-gsurf-focus-page", Fcmacs_gsurf_focus_page,
       Scmacs_gsurf_focus_page, 0, 1, "",
       doc: /* Give keyboard focus to BUFFER's web view so the page gets keys.
BUFFER defaults to the current buffer.  Use this (or just click the
page) to start typing/scrolling in the page; press \\<cmacs-gsurf-mode-map>\
\\[keyboard-quit] or Escape to hand control back to Emacs.  */)
  (Lisp_Object buffer)
{
  if (NILP (buffer))
    XSETBUFFER (buffer, current_buffer);
  CmacsGsurfView *v = require_view (buffer);
  cmacs_gsurf_view_focus_page (v);
  return Qt;
}

DEFUN ("cmacs-gsurf-release-focus", Fcmacs_gsurf_release_focus,
       Scmacs_gsurf_release_focus, 0, 0, "",
       doc: /* Return keyboard focus from any gsurf page to Emacs.
Grabs focus to the selected frame's edit widget so Emacs and evil
regain keyboard control.  */)
  (void)
{
  cmacs_gsurf_release_focus ();
  return Qt;
}

DEFUN ("cmacs-gsurf-page-focused-p", Fcmacs_gsurf_page_focused_p,
       Scmacs_gsurf_page_focused_p, 0, 1, 0,
       doc: /* Return t if BUFFER's web view currently holds keyboard focus.
BUFFER defaults to the current buffer.  */)
  (Lisp_Object buffer)
{
  if (NILP (buffer))
    XSETBUFFER (buffer, current_buffer);
  CHECK_BUFFER (buffer);
  CmacsGsurfView *v = cmacs_gsurf_view_for_buffer (buffer);
  return (v && cmacs_gsurf_view_page_focused_p (v)) ? Qt : Qnil;
}

DEFUN ("cmacs-gsurf-follow", Fcmacs_gsurf_follow,
       Scmacs_gsurf_follow, 0, 1, "",
       doc: /* Pop link hints in BUFFER's page (vimium-style follow mode).
Focuses the web view and asks the gsurf `modal' module to overlay a
short chord label on every clickable element; type the chord to click
it (Escape cancels).  BUFFER defaults to the current buffer.  */)
  (Lisp_Object buffer)
{
  if (NILP (buffer))
    XSETBUFFER (buffer, current_buffer);
  CmacsGsurfView *v = require_view (buffer);
  cmacs_gsurf_view_follow (v);
  return Qt;
}

DEFUN ("cmacs-gsurf-load-uri", Fcmacs_gsurf_load_uri,
       Scmacs_gsurf_load_uri, 2, 2, 0,
       doc: /* Load URI in BUFFER's gsurf view.  */)
  (Lisp_Object buffer, Lisp_Object uri)
{
  CmacsGsurfView *v = require_view (buffer);
  CHECK_STRING (uri);
  cmacs_gsurf_view_load_uri (v, utf8 (uri));
  return Qt;
}

DEFUN ("cmacs-gsurf-reload", Fcmacs_gsurf_reload,
       Scmacs_gsurf_reload, 1, 2, 0,
       doc: /* Reload BUFFER's gsurf view.  With NOCACHE non-nil, bypass cache.  */)
  (Lisp_Object buffer, Lisp_Object nocache)
{
  CmacsGsurfView *v = require_view (buffer);
  cmacs_gsurf_view_reload (v, !NILP (nocache));
  return Qt;
}

DEFUN ("cmacs-gsurf-stop", Fcmacs_gsurf_stop,
       Scmacs_gsurf_stop, 1, 1, 0,
       doc: /* Stop loading in BUFFER's gsurf view.  */)
  (Lisp_Object buffer)
{
  cmacs_gsurf_view_stop (require_view (buffer));
  return Qt;
}

DEFUN ("cmacs-gsurf-back", Fcmacs_gsurf_back,
       Scmacs_gsurf_back, 1, 1, 0,
       doc: /* Navigate BUFFER's gsurf view back in history.  */)
  (Lisp_Object buffer)
{
  cmacs_gsurf_view_go_back (require_view (buffer));
  return Qt;
}

DEFUN ("cmacs-gsurf-forward", Fcmacs_gsurf_forward,
       Scmacs_gsurf_forward, 1, 1, 0,
       doc: /* Navigate BUFFER's gsurf view forward in history.  */)
  (Lisp_Object buffer)
{
  cmacs_gsurf_view_go_forward (require_view (buffer));
  return Qt;
}

DEFUN ("cmacs-gsurf-can-go-back-p", Fcmacs_gsurf_can_go_back_p,
       Scmacs_gsurf_can_go_back_p, 1, 1, 0,
       doc: /* Return t if BUFFER's gsurf view can navigate back.  */)
  (Lisp_Object buffer)
{
  return cmacs_gsurf_view_can_go_back (require_view (buffer)) ? Qt : Qnil;
}

DEFUN ("cmacs-gsurf-can-go-forward-p", Fcmacs_gsurf_can_go_forward_p,
       Scmacs_gsurf_can_go_forward_p, 1, 1, 0,
       doc: /* Return t if BUFFER's gsurf view can navigate forward.  */)
  (Lisp_Object buffer)
{
  return cmacs_gsurf_view_can_go_forward (require_view (buffer)) ? Qt : Qnil;
}

DEFUN ("cmacs-gsurf-get-uri", Fcmacs_gsurf_get_uri,
       Scmacs_gsurf_get_uri, 1, 1, 0,
       doc: /* Return the current URI of BUFFER's gsurf view, or nil.  */)
  (Lisp_Object buffer)
{
  return take_string (cmacs_gsurf_view_get_uri (require_view (buffer)));
}

DEFUN ("cmacs-gsurf-get-title", Fcmacs_gsurf_get_title,
       Scmacs_gsurf_get_title, 1, 1, 0,
       doc: /* Return the current title of BUFFER's gsurf view, or nil.  */)
  (Lisp_Object buffer)
{
  return take_string (cmacs_gsurf_view_get_title (require_view (buffer)));
}

DEFUN ("cmacs-gsurf-get-progress", Fcmacs_gsurf_get_progress,
       Scmacs_gsurf_get_progress, 1, 1, 0,
       doc: /* Return the estimated load progress (0.0-1.0) of BUFFER's view.  */)
  (Lisp_Object buffer)
{
  return make_float (cmacs_gsurf_view_get_progress (require_view (buffer)));
}

DEFUN ("cmacs-gsurf-set-zoom", Fcmacs_gsurf_set_zoom,
       Scmacs_gsurf_set_zoom, 2, 2, 0,
       doc: /* Set the zoom level (1.0 = 100%) of BUFFER's gsurf view.  */)
  (Lisp_Object buffer, Lisp_Object level)
{
  CmacsGsurfView *v = require_view (buffer);
  CHECK_NUMBER (level);
  cmacs_gsurf_view_set_zoom (v, XFLOATINT (level));
  return level;
}

DEFUN ("cmacs-gsurf-get-zoom", Fcmacs_gsurf_get_zoom,
       Scmacs_gsurf_get_zoom, 1, 1, 0,
       doc: /* Return the zoom level of BUFFER's gsurf view.  */)
  (Lisp_Object buffer)
{
  return make_float (cmacs_gsurf_view_get_zoom (require_view (buffer)));
}

DEFUN ("cmacs-gsurf-run-javascript", Fcmacs_gsurf_run_javascript,
       Scmacs_gsurf_run_javascript, 2, 2, 0,
       doc: /* Asynchronously run JavaScript SCRIPT in BUFFER's gsurf view.
The result is discarded (fire-and-forget); use page side effects.  */)
  (Lisp_Object buffer, Lisp_Object script)
{
  CmacsGsurfView *v = require_view (buffer);
  CHECK_STRING (script);
  cmacs_gsurf_view_run_js (v, utf8 (script));
  return Qt;
}

DEFUN ("cmacs-gsurf-run-javascript-async", Fcmacs_gsurf_run_javascript_async,
       Scmacs_gsurf_run_javascript_async, 3, 3, 0,
       doc: /* Run JavaScript SCRIPT in BUFFER's gsurf view; deliver its value.
CALLBACK is called with one argument: the script's result as a string
(JSON for non-string values, the empty string on error).  The call is
asynchronous; CALLBACK runs later on the main thread.  Works while the
page is unfocused (JS evaluation does not need GTK keyboard focus).  */)
  (Lisp_Object buffer, Lisp_Object script, Lisp_Object callback)
{
  CmacsGsurfView *v = require_view (buffer);
  CHECK_STRING (script);
  cmacs_gsurf_view_run_js_cb (v, utf8 (script), callback);
  return Qt;
}

DEFUN ("cmacs-gsurf-add-user-script", Fcmacs_gsurf_add_user_script,
       Scmacs_gsurf_add_user_script, 2, 3, 0,
       doc: /* Inject user SCRIPT into all frames of BUFFER's gsurf view.
SCRIPT is JavaScript source, injected on every page load (it persists
across navigation).  With optional AT-END non-nil it runs at document
end instead of document start.  Use an idempotent guard in SCRIPT so
re-injection on reload is harmless.  */)
  (Lisp_Object buffer, Lisp_Object script, Lisp_Object at_end)
{
  CmacsGsurfView *v = require_view (buffer);
  CHECK_STRING (script);
  cmacs_gsurf_view_add_user_script (v, utf8 (script), !NILP (at_end));
  return Qt;
}

DEFUN ("cmacs-gsurf-find", Fcmacs_gsurf_find,
       Scmacs_gsurf_find, 2, 3, 0,
       doc: /* Search for TEXT in BUFFER's gsurf view.
With BACKWARD non-nil, search backwards.  */)
  (Lisp_Object buffer, Lisp_Object text, Lisp_Object backward)
{
  CmacsGsurfView *v = require_view (buffer);
  CHECK_STRING (text);
  cmacs_gsurf_view_find (v, utf8 (text), NILP (backward));
  return Qt;
}

DEFUN ("cmacs-gsurf-find-next", Fcmacs_gsurf_find_next,
       Scmacs_gsurf_find_next, 1, 2, 0,
       doc: /* Move to the next find match in BUFFER's gsurf view.
With BACKWARD non-nil, move to the previous match.  */)
  (Lisp_Object buffer, Lisp_Object backward)
{
  cmacs_gsurf_view_find_next (require_view (buffer), NILP (backward));
  return Qt;
}

DEFUN ("cmacs-gsurf-snapshot", Fcmacs_gsurf_snapshot,
       Scmacs_gsurf_snapshot, 2, 4, 0,
       doc: /* Save a PNG snapshot of BUFFER's gsurf view to FILE.
With FULL-PAGE non-nil, capture the whole document; otherwise just the
visible region.  Asynchronous: optional CALLBACK is called with FILE (the
path) on success, or nil on failure.  */)
  (Lisp_Object buffer, Lisp_Object file, Lisp_Object callback,
   Lisp_Object full_page)
{
  CmacsGsurfView *v = require_view (buffer);
  CHECK_STRING (file);
  Lisp_Object enc = ENCODE_FILE (file);
  cmacs_gsurf_snapshot (v, SSDATA (enc), callback, !NILP (full_page));
  return Qt;
}

DEFUN ("cmacs-gsurf-print-to-pdf", Fcmacs_gsurf_print_to_pdf,
       Scmacs_gsurf_print_to_pdf, 2, 3, 0,
       doc: /* Print BUFFER's gsurf view to a PDF at FILE (no dialog).
Asynchronous: optional CALLBACK is called with FILE (the path) on success,
or nil on failure.  */)
  (Lisp_Object buffer, Lisp_Object file, Lisp_Object callback)
{
  CmacsGsurfView *v = require_view (buffer);
  CHECK_STRING (file);
  Lisp_Object enc = ENCODE_FILE (file);
  cmacs_gsurf_print_pdf (v, SSDATA (enc), callback);
  return Qt;
}

DEFUN ("cmacs-gsurf-download-cancel", Fcmacs_gsurf_download_cancel,
       Scmacs_gsurf_download_cancel, 1, 1, 0,
       doc: /* Cancel the in-flight gsurf download with integer ID.
ID is the identifier reported by `cmacs-gsurf-download-changed-functions'.
Does nothing if no such download is active.  */)
  (Lisp_Object id)
{
  CHECK_FIXNAT (id);
  cmacs_gsurf_download_cancel ((unsigned int) XFIXNUM (id));
  return Qt;
}

DEFUN ("cmacs-gsurf-set-permission-policy", Fcmacs_gsurf_set_permission_policy,
       Scmacs_gsurf_set_permission_policy, 3, 3, 0,
       doc: /* Set the permission policy for ORIGIN and TYPE to VERDICT.
ORIGIN is a string like "https://example.com" (scheme://host:port), TYPE a
string or symbol such as `geolocation', `notification', `media',
`clipboard', `device-info' or `pointer-lock', and VERDICT either `allow'
or `deny'.  Consulted synchronously when a page requests the permission;
unknown origins are denied (and reported via
`cmacs-gsurf-permission-request-functions').  */)
  (Lisp_Object origin, Lisp_Object type, Lisp_Object verdict)
{
  CHECK_STRING (origin);
  if (SYMBOLP (type)) type = SYMBOL_NAME (type);
  CHECK_STRING (type);
  int allow = (EQ (verdict, intern ("allow"))
               || (STRINGP (verdict) && !strcmp (SSDATA (verdict), "allow")));
  cmacs_gsurf_permission_set_policy (utf8 (origin), SSDATA (type), allow);
  return Qt;
}

DEFUN ("cmacs-gsurf-clear-permission-policies",
       Fcmacs_gsurf_clear_permission_policies,
       Scmacs_gsurf_clear_permission_policies, 0, 0, 0,
       doc: /* Forget all gsurf per-origin permission policies.  */)
  (void)
{
  cmacs_gsurf_permission_clear_policies ();
  return Qt;
}

DEFUN ("cmacs-gsurf-modules-list", Fcmacs_gsurf_modules_list,
       Scmacs_gsurf_modules_list, 0, 0, 0,
       doc: /* Return a JSON string describing the loaded gsurf modules.
Each element has name, description, enabled and active fields.  Returns
nil if the gsurf runtime is not up yet.  */)
  (void)
{
  if (!cmacs_gsurf_available_p ())
    return Qnil;
  return take_string (cmacs_gsurf_modules_list_json ());
}

DEFUN ("cmacs-gsurf-module-set-enabled", Fcmacs_gsurf_module_set_enabled,
       Scmacs_gsurf_module_set_enabled, 2, 2, 0,
       doc: /* Enable (ENABLED non-nil) or disable a gsurf module by NAME.
Returns t if the module exists, nil otherwise.  */)
  (Lisp_Object name, Lisp_Object enabled)
{
  CHECK_STRING (name);
  if (!cmacs_gsurf_available_p ())
    return Qnil;
  return cmacs_gsurf_module_set_enabled (SSDATA (name), !NILP (enabled))
    ? Qt : Qnil;
}

DEFUN ("cmacs-gsurf-load-config-data", Fcmacs_gsurf_load_config_data,
       Scmacs_gsurf_load_config_data, 1, 1, 0,
       doc: /* Load gsurf YAML configuration from the string DATA.
Merges over the built-in defaults; module `enabled:' flags and options
take effect when modules load (or immediately, for option changes, if
they are already loaded).  This is the primitive the Emacs-side config
in `cmacs-gsurf-modules' is built on; cmacs does not read gsurf's own
~/.config/gsurf/config.yaml unless you ask it to.  Signals
`cmacs-gsurf-error' on a parse failure.  */)
  (Lisp_Object data)
{
  CHECK_STRING (data);
  char *err = NULL;
  if (!cmacs_gsurf_load_config_data (utf8 (data), &err))
    {
      Lisp_Object m = build_string (err ? err : "gsurf config parse error");
      cmacs_gsurf_string_free (err);
      xsignal1 (Qcmacs_gsurf_error, m);
    }
  return Qt;
}

DEFUN ("cmacs-gsurf-load-config-file", Fcmacs_gsurf_load_config_file,
       Scmacs_gsurf_load_config_file, 1, 1, 0,
       doc: /* Load a gsurf YAML config FILE (a path).
Merges over the built-in defaults.  Signals `cmacs-gsurf-error' on
failure.  */)
  (Lisp_Object file)
{
  CHECK_STRING (file);
  Lisp_Object enc = ENCODE_FILE (file);
  char *err = NULL;
  if (!cmacs_gsurf_load_config_file (SSDATA (enc), &err))
    {
      Lisp_Object m = build_string (err ? err : "gsurf config load error");
      cmacs_gsurf_string_free (err);
      xsignal1 (Qcmacs_gsurf_error, m);
    }
  return Qt;
}

DEFUN ("cmacs-gsurf-load-config-c-file", Fcmacs_gsurf_load_config_c_file,
       Scmacs_gsurf_load_config_c_file, 1, 1, 0,
       doc: /* Compile and load a gsurf C config FILE via crispy.
FILE is a path (for example "~/.config/cmacs/init.c"); it is compiled to
a cached shared object and its gsurf_config_init() runs against the
gsurf config, so it can configure anything programmatically.  Signals
`cmacs-gsurf-error' on failure.  */)
  (Lisp_Object file)
{
  CHECK_STRING (file);
  Lisp_Object enc = ENCODE_FILE (file);
  char *err = NULL;
  if (!cmacs_gsurf_load_config_c_file (SSDATA (enc), &err))
    {
      Lisp_Object m = build_string (err ? err : "gsurf C config error");
      cmacs_gsurf_string_free (err);
      xsignal1 (Qcmacs_gsurf_error, m);
    }
  return Qt;
}

DEFUN ("cmacs-gsurf-reconfigure-modules", Fcmacs_gsurf_reconfigure_modules,
       Scmacs_gsurf_reconfigure_modules, 0, 0, 0,
       doc: /* Re-run configure on all loaded gsurf modules.
Picks up option changes made to the config after modules were loaded.
Enable/disable changes are applied separately via
`cmacs-gsurf-module-set-enabled'.  */)
  (void)
{
  cmacs_gsurf_modules_reconfigure ();
  return Qt;
}

extern Lisp_Object *cmacs_gsurf__buffers_root (void);

void
syms_of_cmacs_gsurf_defuns (void)
{
  DEFSYM (Qcmacs_gsurf_error, "cmacs-gsurf-error");
  Fput (Qcmacs_gsurf_error, Qerror_conditions,
        list2 (Qcmacs_gsurf_error, Qerror));
  Fput (Qcmacs_gsurf_error, Qerror_message,
        build_string ("CMacs gsurf error"));

  /* GC-root the buffer->id registry hash (lazy-instantiated). */
  *cmacs_gsurf__buffers_root () = Qnil;
  staticpro (cmacs_gsurf__buffers_root ());

  defsubr (&Scmacs_gsurf_supported_p);
  defsubr (&Scmacs_gsurf_lrg_supported_p);
  defsubr (&Scmacs_gsurf_attach);
  defsubr (&Scmacs_gsurf_offscreen_p);
  defsubr (&Scmacs_gsurf_detach);
  defsubr (&Scmacs_gsurf_attached_p);
  defsubr (&Scmacs_gsurf_place);
  defsubr (&Scmacs_gsurf_hide);
  defsubr (&Scmacs_gsurf_focus_page);
  defsubr (&Scmacs_gsurf_release_focus);
  defsubr (&Scmacs_gsurf_page_focused_p);
  defsubr (&Scmacs_gsurf_follow);
  defsubr (&Scmacs_gsurf_load_uri);
  defsubr (&Scmacs_gsurf_reload);
  defsubr (&Scmacs_gsurf_stop);
  defsubr (&Scmacs_gsurf_back);
  defsubr (&Scmacs_gsurf_forward);
  defsubr (&Scmacs_gsurf_can_go_back_p);
  defsubr (&Scmacs_gsurf_can_go_forward_p);
  defsubr (&Scmacs_gsurf_get_uri);
  defsubr (&Scmacs_gsurf_get_title);
  defsubr (&Scmacs_gsurf_get_progress);
  defsubr (&Scmacs_gsurf_set_zoom);
  defsubr (&Scmacs_gsurf_get_zoom);
  defsubr (&Scmacs_gsurf_run_javascript);
  defsubr (&Scmacs_gsurf_run_javascript_async);
  defsubr (&Scmacs_gsurf_add_user_script);
  defsubr (&Scmacs_gsurf_find);
  defsubr (&Scmacs_gsurf_find_next);
  defsubr (&Scmacs_gsurf_snapshot);
  defsubr (&Scmacs_gsurf_print_to_pdf);
  defsubr (&Scmacs_gsurf_download_cancel);
  defsubr (&Scmacs_gsurf_set_permission_policy);
  defsubr (&Scmacs_gsurf_clear_permission_policies);
  defsubr (&Scmacs_gsurf_modules_list);
  defsubr (&Scmacs_gsurf_module_set_enabled);
  defsubr (&Scmacs_gsurf_load_config_data);
  defsubr (&Scmacs_gsurf_load_config_file);
  defsubr (&Scmacs_gsurf_load_config_c_file);
  defsubr (&Scmacs_gsurf_reconfigure_modules);
}

#endif /* HAVE_CMACS_GSURF */
