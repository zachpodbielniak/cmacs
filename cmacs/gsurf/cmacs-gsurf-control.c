/* cmacs-gsurf-control.c --- toolkit-neutral gsurf control surface.
 *
 * Copyright (C) 2026 Zach Podbielniak
 * SPDX-License-Identifier: AGPL-3.0-or-later
 *
 * Elisp entry points for the libgsurf features that work on a bare
 * GsurfView (no GsurfWindow), which is exactly what cmacs embeds:
 *
 *   - page input:   trusted key / click / text injection (gsurf 0.5.10),
 *                   and "click the element matching a CSS selector";
 *   - network:      add a cookie to the view's session, cookie accept
 *                   policy, proxy;
 *   - containers:   list / define / temporary containers, and creating a
 *                   buffer's view inside a container;
 *   - identity:     the process-unique view id and the opener id, which is
 *                   how a buffer tree is drawn;
 *   - actions:      every GsurfAction by name, dispatched to the modules
 *                   that implement one (dark_mode, form_autofill, ...);
 *   - input mode:   the module manager's NORMAL/INSERT/FOLLOW/... mode,
 *                   the per-view DOM editing state, and the mode-changed
 *                   signal bridged to an Emacs hook;
 *   - keybind help: every core + module keybinding with its description.
 *
 * Window-only gsurf features (wmux panes, the tab tree provider, the
 * gsurfctl control socket, kiosk/PWA windows, the --lrg=3d tab space) are
 * deliberately absent: in cmacs, Emacs windows and buffers are the panes
 * and tabs.
 *
 * This unit sees gsurf.h (GTK-free) through cmacs-gsurf-internal.h but no
 * GTK/WebKit: anything that touches the native widget -- notably the focus
 * borrowing that trusted input needs -- lives in cmacs-gsurf-view.c behind
 * cmacs_gsurf_view_send_input.
 *
 * GC: no Lisp_Object is ever stored in GLib memory.  Async results (cookie
 * store, click-element) reach Lisp through the staticpro'd callback cookie
 * registry in cmacs-eval-dispatch.c, after hopping onto the cmacs main
 * context; the GsurfView is ref-held across the gap and the owning buffer
 * is re-resolved through the reverse map before anything touches it. */

#include <config.h>

#ifdef HAVE_CMACS_GSURF

#include "lisp.h"
#include "buffer.h"
#include "coding.h"
#include "cmacs-gsurf.h"
#include "cmacs-gsurf-internal.h"
#include "cmacs-eval-dispatch.h"
#include "cmacs-glib-loop.h"

#include <gsurf/gsurf.h>
#include <math.h>
#include <string.h>

void syms_of_cmacs_gsurf_control (void);

/* The defun layer builds modifier masks from these mirrors; keep them
   honest against gsurf's own enum. */
G_STATIC_ASSERT (CMACS_GSURF_MOD_SHIFT == GSURF_MOD_SHIFT);
G_STATIC_ASSERT (CMACS_GSURF_MOD_CTRL  == GSURF_MOD_CTRL);
G_STATIC_ASSERT (CMACS_GSURF_MOD_ALT   == GSURF_MOD_ALT);
G_STATIC_ASSERT (CMACS_GSURF_MOD_SUPER == GSURF_MOD_SUPER);

/* ── Small helpers ──────────────────────────────────────────────────── */

/* BUFFER's view, or signal `cmacs-gsurf-error'.  */
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

/* BUFFER's GsurfView, or signal.  */
static GsurfView *
require_gsurf (Lisp_Object buffer)
{
  GsurfView *gv = cmacs_gsurf_view_gsurf (require_view (buffer));
  if (gv == NULL)
    xsignal1 (Qcmacs_gsurf_error, build_string ("gsurf view has no engine"));
  return gv;
}

/* The gsurf runtime (backend + modules) must be up for module-backed
   calls; signal otherwise rather than talk to an empty manager.  */
static void
require_runtime (void)
{
  if (!cmacs_gsurf_available_p ())
    xsignal1 (Qcmacs_gsurf_error,
              build_string ("gsurf runtime not started (open a gsurf buffer first)"));
}

/* UTF-8 bytes of a Lisp string, for the gsurf API.  */
static const char *
utf8 (Lisp_Object string)
{
  return SSDATA (code_convert_string_norecord (string, intern ("utf-8"),
                                               true));
}

/* A string or symbol argument as its name; nil -> NULL; else signal.  */
static Lisp_Object
string_or_symbol_name (Lisp_Object x)
{
  if (NILP (x))
    return Qnil;
  if (SYMBOLP (x))
    return SYMBOL_NAME (x);
  CHECK_STRING (x);
  return x;
}

/* Build a Lisp string from a possibly-NULL C string (NULL -> nil).  */
static Lisp_Object
string_or_nil (const char *s)
{
  return s ? build_string (s) : Qnil;
}

/* Signal `cmacs-gsurf-error' with a message and free ERR (a g_malloc'd
   string from the view layer).  Never returns.  */
static AVOID
signal_c_error (char *err)
{
  Lisp_Object msg = build_string (err ? err : "gsurf error");
  cmacs_gsurf_string_free (err);
  xsignal1 (Qcmacs_gsurf_error, msg);
}

/* Map one modifier name to its GsurfKeyMod flag (0 if unknown).  Accepts
   the Emacs names (control, meta, shift, super), gsurf's (ctrl, alt) and
   the one-letter Emacs prefixes (C, M, S, s).  */
static unsigned int
modifier_flag (const char *name)
{
  if (!strcmp (name, "shift") || !strcmp (name, "S"))
    return CMACS_GSURF_MOD_SHIFT;
  if (!strcmp (name, "control") || !strcmp (name, "ctrl")
      || !strcmp (name, "C"))
    return CMACS_GSURF_MOD_CTRL;
  if (!strcmp (name, "meta") || !strcmp (name, "alt") || !strcmp (name, "M")
      || !strcmp (name, "A"))
    return CMACS_GSURF_MOD_ALT;
  if (!strcmp (name, "super") || !strcmp (name, "s"))
    return CMACS_GSURF_MOD_SUPER;
  return 0;
}

/* Fold a list of modifier symbols/strings into a GsurfKeyMod mask, or
   signal on an unknown one (a typo must not silently become no-mod).  */
static unsigned int
modifier_mask (Lisp_Object mods)
{
  unsigned int mask = 0;
  Lisp_Object tail;

  if (NILP (mods))
    return 0;
  if (SYMBOLP (mods) || STRINGP (mods))
    mods = list1 (mods);
  for (tail = mods; CONSP (tail); tail = XCDR (tail))
    {
      Lisp_Object name = string_or_symbol_name (XCAR (tail));
      unsigned int flag;
      if (NILP (name))
        continue;
      flag = modifier_flag (SSDATA (name));
      if (flag == 0)
        xsignal2 (Qcmacs_gsurf_error,
                  build_string ("unknown modifier"), XCAR (tail));
      mask |= flag;
    }
  return mask;
}

/* KEY (a key name string/symbol, or an integer keysym) -> keysym, or
   signal when the name is not a key.  */
static unsigned int
key_to_keyval (Lisp_Object key)
{
  if (FIXNATP (key))
    return (unsigned int) XFIXNAT (key);
  Lisp_Object name = string_or_symbol_name (key);
  if (NILP (name) || SCHARS (name) == 0)
    xsignal1 (Qcmacs_gsurf_error, build_string ("empty key name"));
  unsigned int keyval = cmacs_gsurf_keyval_from_name (utf8 (name));
  if (keyval == 0)
    xsignal2 (Qcmacs_gsurf_error, build_string ("unknown key"), key);
  return keyval;
}

/* ── Page input ─────────────────────────────────────────────────────── */

DEFUN ("cmacs-gsurf-keyval", Fcmacs_gsurf_keyval, Scmacs_gsurf_keyval, 1, 1, 0,
       doc: /* Return the X keysym gsurf uses for key NAME, or nil.
NAME is a string or symbol: a DOM `KeyboardEvent.key' name ("Enter",
"Tab", "Escape", "Backspace", "ArrowLeft", "PageDown", ...), an X keysym
name ("Return", "Left", "space", ...; named keys match
case-insensitively) or a single character.  Nil means NAME is not a
key.  Display-free.  */)
  (Lisp_Object name)
{
  name = string_or_symbol_name (name);
  if (NILP (name))
    return Qnil;
  unsigned int k = cmacs_gsurf_keyval_from_name (utf8 (name));
  return k ? make_fixnum (k) : Qnil;
}

DEFUN ("cmacs-gsurf-modifier-mask", Fcmacs_gsurf_modifier_mask,
       Scmacs_gsurf_modifier_mask, 1, 1, 0,
       doc: /* Return the gsurf modifier mask for MODIFIERS.
MODIFIERS is a list of symbols or strings (or a single one): `shift',
`control' (or `ctrl', "C"), `meta' (or `alt', "M") and `super' ("s").
Signals `cmacs-gsurf-error' on an unknown modifier.  Display-free; the
same parsing `cmacs-gsurf-send-key' and `cmacs-gsurf-click' use.  */)
  (Lisp_Object modifiers)
{
  return make_fixnum (modifier_mask (modifiers));
}

DEFUN ("cmacs-gsurf-send-key", Fcmacs_gsurf_send_key, Scmacs_gsurf_send_key,
       2, 3, 0,
       doc: /* Press and release KEY in BUFFER's gsurf page.
KEY is a key name (see `cmacs-gsurf-keyval') or an integer keysym;
MODIFIERS a list such as (control shift).  The page sees a trusted
keyboard event (GTK3), delivered to whatever has DOM focus.  Keyboard
focus is borrowed for the call and handed straight back to Emacs, so
this works while Emacs holds the keyboard.  The page must have been
shown at least once.  Returns t, or signals `cmacs-gsurf-error'.  */)
  (Lisp_Object buffer, Lisp_Object key, Lisp_Object modifiers)
{
  CmacsGsurfView *v = require_view (buffer);
  unsigned int keyval = key_to_keyval (key);
  unsigned int mask = modifier_mask (modifiers);
  char *err = NULL;
  if (!cmacs_gsurf_view_send_input (v, CMACS_GSURF_INPUT_KEY, 0, 0,
                                    keyval, mask, NULL, &err))
    signal_c_error (err);
  return Qt;
}

DEFUN ("cmacs-gsurf-click", Fcmacs_gsurf_click, Scmacs_gsurf_click, 3, 5, 0,
       doc: /* Click at X, Y (CSS pixels from the view's top-left) in BUFFER.
Optional BUTTON is 1 (left, the default), 2 (middle) or 3 (right);
MODIFIERS is a list as for `cmacs-gsurf-send-key'.  The pointer moves
there, then the button is pressed and released: a trusted click on GTK3.
Coordinates are what `getBoundingClientRect' reports, so zoom is
accounted for.  Returns t, or signals `cmacs-gsurf-error'.  */)
  (Lisp_Object buffer, Lisp_Object x, Lisp_Object y, Lisp_Object button,
   Lisp_Object modifiers)
{
  CmacsGsurfView *v = require_view (buffer);
  CHECK_NUMBER (x);
  CHECK_NUMBER (y);
  unsigned int btn = 1;
  if (!NILP (button))
    {
      CHECK_FIXNAT (button);
      if (XFIXNAT (button) < 1 || XFIXNAT (button) > 3)
        args_out_of_range_3 (button, make_fixnum (1), make_fixnum (3));
      btn = (unsigned int) XFIXNAT (button);
    }
  unsigned int mask = modifier_mask (modifiers);
  char *err = NULL;
  if (!cmacs_gsurf_view_send_input (v, CMACS_GSURF_INPUT_CLICK,
                                    XFLOATINT (x), XFLOATINT (y),
                                    btn, mask, NULL, &err))
    signal_c_error (err);
  return Qt;
}

DEFUN ("cmacs-gsurf-type", Fcmacs_gsurf_type, Scmacs_gsurf_type, 2, 2, 0,
       doc: /* Type TEXT into whatever has DOM focus in BUFFER's page.
One trusted key press per character (GTK3); a newline is Return.  Focus
a field first, e.g. with `cmacs-gsurf-click-element'.  Keyboard focus is
borrowed for the call and returned to Emacs.  Returns t, or signals
`cmacs-gsurf-error'.  */)
  (Lisp_Object buffer, Lisp_Object text)
{
  CmacsGsurfView *v = require_view (buffer);
  CHECK_STRING (text);
  char *err = NULL;
  if (!cmacs_gsurf_view_send_input (v, CMACS_GSURF_INPUT_TEXT, 0, 0, 0, 0,
                                    utf8 (text), &err))
    signal_c_error (err);
  return Qt;
}

DEFUN ("cmacs-gsurf-locate-script", Fcmacs_gsurf_locate_script,
       Scmacs_gsurf_locate_script, 1, 1, 0,
       doc: /* Return gsurf's JavaScript that locates CSS SELECTOR.
Evaluated in a page, the script finds the first match, scrolls it into
view, focuses it, and yields a JSON array [X, Y] (its centre in CSS
pixels, ready for `cmacs-gsurf-click') or null.  This is the one
definition of "the element" every gsurf caller shares.  Display-free.  */)
  (Lisp_Object selector)
{
  CHECK_STRING (selector);
  gchar *js = gsurf_view_locate_script (utf8 (selector));
  Lisp_Object r = build_string (js ? js : "null");
  g_free (js);
  return r;
}

/* Parse "[x, y]" (the locate script's JSON) into X/Y.  Returns false for
   "null", an empty result, or anything that is not two numbers.  Exposed
   to Lisp as `cmacs-gsurf--parse-point' for the tests.  */
static bool
parse_point (const char *json, double *x, double *y)
{
  const char *p = json;
  char *end;

  if (p == NULL)
    return false;
  while (*p == ' ' || *p == '\t' || *p == '\n') p++;
  if (*p++ != '[')
    return false;
  *x = g_ascii_strtod (p, &end);
  if (end == p)
    return false;
  p = end;
  while (*p == ' ') p++;
  if (*p++ != ',')
    return false;
  *y = g_ascii_strtod (p, &end);
  if (end == p)
    return false;
  p = end;
  while (*p == ' ') p++;
  return *p == ']' && isfinite (*x) && isfinite (*y);
}

DEFUN ("cmacs-gsurf--parse-point", Fcmacs_gsurf__parse_point,
       Scmacs_gsurf__parse_point, 1, 1, 0,
       doc: /* Internal: parse the locate script's JSON STRING into (X . Y).
Returns nil for "null" or malformed input.  */)
  (Lisp_Object string)
{
  double x, y;
  CHECK_STRING (string);
  if (!parse_point (SSDATA (string), &x, &y))
    return Qnil;
  return Fcons (make_float (x), make_float (y));
}

/* In-flight click-element: locate (async JS) -> click on the main thread. */
typedef struct
{
  GsurfView   *gv;         /* reffed for the async gap */
  uint64_t     cb_cookie;  /* 0 = no callback */
  unsigned int button;
  char        *json;       /* the script's value, owned */
  char        *js_error;   /* JS evaluation error, owned, or NULL */
} CmacsGsurfClickCall;

static gboolean
click_element_main (gpointer data)
{
  CmacsGsurfClickCall *c = data;
  Lisp_Object result = Qnil;
  double x = 0, y = 0;
  /* Re-validate: the buffer may have been killed while the JS ran. */
  CmacsGsurfView *v = cmacs_gsurf_view_from_gsurf (c->gv);

  if (v == NULL)
    result = build_string ("gsurf buffer was killed");
  else if (c->js_error)
    result = build_string (c->js_error);
  else if (parse_point (c->json, &x, &y))
    {
      char *err = NULL;
      if (cmacs_gsurf_view_send_input (v, CMACS_GSURF_INPUT_CLICK, x, y,
                                       c->button, 0, NULL, &err))
        result = Qt;
      else
        result = build_string (err ? err : "click not delivered");
      cmacs_gsurf_string_free (err);
    }
  /* else: no element matched -> nil */

  if (c->cb_cookie)
    cmacs_dispatch_callback_invoke1 (c->cb_cookie, result);
  g_free (c->json);
  g_free (c->js_error);
  g_object_unref (c->gv);
  g_free (c);
  return G_SOURCE_REMOVE;
}

static void
click_element_js_done (GObject *source, GAsyncResult *res, gpointer user)
{
  CmacsGsurfClickCall *c = user;
  GError *err = NULL;
  (void) source;
  c->json = gsurf_view_run_javascript_finish (c->gv, res, &err);
  if (err != NULL)
    c->js_error = g_strdup (err->message);
  g_clear_error (&err);
  /* Never touch Lisp from the WebKit completion: hop to the main loop. */
  g_main_context_invoke (cmacs_glib_get_context (), click_element_main, c);
}

DEFUN ("cmacs-gsurf-click-element", Fcmacs_gsurf_click_element,
       Scmacs_gsurf_click_element, 2, 4, 0,
       doc: /* Click the first element matching CSS SELECTOR in BUFFER.
The element is located with `cmacs-gsurf-locate-script' (scrolled into
view and focused), then clicked at its centre with a trusted click.
Asynchronous: optional CALLBACK is called with t when clicked, nil when
nothing matched, or an error message string.  Optional BUTTON is as for
`cmacs-gsurf-click'.  Returns t once the lookup is started.  */)
  (Lisp_Object buffer, Lisp_Object selector, Lisp_Object callback,
   Lisp_Object button)
{
  GsurfView *gv = require_gsurf (buffer);
  CHECK_STRING (selector);
  unsigned int btn = 1;
  if (!NILP (button))
    {
      CHECK_FIXNAT (button);
      if (XFIXNAT (button) < 1 || XFIXNAT (button) > 3)
        args_out_of_range_3 (button, make_fixnum (1), make_fixnum (3));
      btn = (unsigned int) XFIXNAT (button);
    }

  gchar *js = gsurf_view_locate_script (utf8 (selector));
  CmacsGsurfClickCall *c = g_new0 (CmacsGsurfClickCall, 1);
  c->gv        = g_object_ref (gv);
  c->button    = btn;
  c->cb_cookie = NILP (callback) ? 0
    : cmacs_dispatch_callback_register (callback);
  gsurf_view_run_javascript_async (gv, js, NULL, click_element_js_done, c);
  g_free (js);
  return Qt;
}

/* ── Cookies + network ──────────────────────────────────────────────── */

typedef struct
{
  GsurfView *gv;         /* reffed: the GTask's source object */
  uint64_t   cb_cookie;  /* 0 = no callback */
  gboolean   ok;
  char      *error;      /* owned, or NULL */
} CmacsGsurfCookieCall;

static gboolean
cookie_main (gpointer data)
{
  CmacsGsurfCookieCall *c = data;
  if (c->cb_cookie)
    cmacs_dispatch_callback_invoke1 (
      c->cb_cookie,
      c->ok ? Qt : build_string (c->error ? c->error : "cookie not stored"));
  g_free (c->error);
  g_object_unref (c->gv);
  g_free (c);
  return G_SOURCE_REMOVE;
}

static void
cookie_done (GObject *source, GAsyncResult *res, gpointer user)
{
  CmacsGsurfCookieCall *c = user;
  GError *err = NULL;
  (void) source;
  c->ok = gsurf_view_add_cookie_finish (c->gv, res, &err);
  if (err != NULL)
    c->error = g_strdup (err->message);
  g_clear_error (&err);
  g_main_context_invoke (cmacs_glib_get_context (), cookie_main, c);
}

/* A required string member of the cookie plist, or signal.  */
static Lisp_Object
cookie_string (Lisp_Object plist, const char *key, bool required)
{
  Lisp_Object v = plist_get (plist, intern (key));
  if (NILP (v))
    {
      if (required)
        xsignal2 (Qcmacs_gsurf_error,
                  build_string ("cookie is missing"), intern (key));
      return Qnil;
    }
  CHECK_STRING (v);
  return v;
}

/* :same-site -> gsurf's 0 none / 1 lax / 2 strict.  */
static int
cookie_same_site (Lisp_Object v)
{
  if (NILP (v))
    return 0;
  if (FIXNATP (v) && XFIXNAT (v) <= 2)
    return (int) XFIXNAT (v);
  Lisp_Object name = string_or_symbol_name (v);
  if (!strcmp (SSDATA (name), "none")) return 0;
  if (!strcmp (SSDATA (name), "lax"))  return 1;
  if (!strcmp (SSDATA (name), "strict")) return 2;
  xsignal2 (Qcmacs_gsurf_error, build_string ("bad :same-site"), v);
}

DEFUN ("cmacs-gsurf-add-cookie", Fcmacs_gsurf_add_cookie,
       Scmacs_gsurf_add_cookie, 2, 3, 0,
       doc: /* Add a cookie to the session of BUFFER's gsurf view.
COOKIE is a plist:
  :name STRING      required
  :value STRING     required
  :domain STRING    required; "example.com", or ".example.com" for the
                    host and its subdomains
  :path STRING      default "/"
  :expires NUMBER   Unix seconds; omitted, nil or <= 0 = session cookie
  :secure BOOL      https only
  :http-only BOOL   hidden from document.cookie
  :same-site SYM    `none' (default), `lax' or `strict'
The cookie goes into the view's own session -- its container's cookie
jar for a view in a container -- replacing one with the same name,
domain and path.  Asynchronous: optional CALLBACK is called with t when
stored or an error message string.  */)
  (Lisp_Object buffer, Lisp_Object cookie, Lisp_Object callback)
{
  GsurfView *gv = require_gsurf (buffer);
  CHECK_LIST (cookie);

  Lisp_Object name   = cookie_string (cookie, ":name", true);
  Lisp_Object value  = cookie_string (cookie, ":value", true);
  Lisp_Object domain = cookie_string (cookie, ":domain", true);
  Lisp_Object path   = cookie_string (cookie, ":path", false);
  Lisp_Object expires = plist_get (cookie, intern (":expires"));
  if (!NILP (expires))
    CHECK_NUMBER (expires);
  if (SCHARS (name) == 0)
    xsignal1 (Qcmacs_gsurf_error, build_string ("cookie :name is empty"));
  if (SCHARS (domain) == 0)
    xsignal1 (Qcmacs_gsurf_error, build_string ("cookie :domain is empty"));

  int same_site = cookie_same_site (plist_get (cookie, intern (":same-site")));

  /* Each encoded string is copied out at once: the next encoding call
     allocates, and Lisp string data must not be held across that.  gsurf
     copies the (borrowed) cookie strings before add_cookie_async
     returns, so the copies are freed right after the call.  */
  char *c_name   = g_strdup (utf8 (name));
  char *c_value  = g_strdup (utf8 (value));
  char *c_domain = g_strdup (utf8 (domain));
  char *c_path   = NILP (path) ? NULL : g_strdup (utf8 (path));

  GsurfCookie gc;
  memset (&gc, 0, sizeof gc);
  gc.name      = c_name;
  gc.value     = c_value;
  gc.domain    = c_domain;
  gc.path      = c_path;
  gc.expires   = NILP (expires) ? 0 : (gint64) XFLOATINT (expires);
  gc.secure    = !NILP (plist_get (cookie, intern (":secure")));
  gc.http_only = !NILP (plist_get (cookie, intern (":http-only")));
  gc.same_site = same_site;

  CmacsGsurfCookieCall *c = g_new0 (CmacsGsurfCookieCall, 1);
  c->gv        = g_object_ref (gv);
  c->cb_cookie = NILP (callback) ? 0
    : cmacs_dispatch_callback_register (callback);
  gsurf_view_add_cookie_async (gv, &gc, NULL, cookie_done, c);
  g_free (c_name);
  g_free (c_value);
  g_free (c_domain);
  g_free (c_path);
  return Qt;
}

DEFUN ("cmacs-gsurf-set-cookie-policy", Fcmacs_gsurf_set_cookie_policy,
       Scmacs_gsurf_set_cookie_policy, 2, 2, 0,
       doc: /* Set the cookie accept POLICY of BUFFER's view's session.
POLICY is `always', `never' or `no-third-party'.  The policy belongs to
the network session, so it applies to every view sharing it (all views
in the default container, or all views in one container).  */)
  (Lisp_Object buffer, Lisp_Object policy)
{
  GsurfView *gv = require_gsurf (buffer);
  Lisp_Object name = string_or_symbol_name (policy);
  int p;
  if (NILP (name))
    wrong_type_argument (Qsymbolp, policy);
  if (!strcmp (SSDATA (name), "always"))               p = 0;
  else if (!strcmp (SSDATA (name), "never"))           p = 1;
  else if (!strcmp (SSDATA (name), "no-third-party"))  p = 2;
  else
    xsignal2 (Qcmacs_gsurf_error, build_string ("unknown cookie policy"),
              policy);
  gsurf_view_set_cookie_accept_policy (gv, p);
  return Qt;
}

DEFUN ("cmacs-gsurf-set-proxy", Fcmacs_gsurf_set_proxy,
       Scmacs_gsurf_set_proxy, 2, 2, 0,
       doc: /* Route the network of BUFFER's view through proxy URI.
URI is e.g. "socks5://127.0.0.1:9050" or "http://proxy:3128"; nil or ""
returns to the system default.  The proxy belongs to the view's web
context, so it applies to every view sharing that session.  For a
per-container proxy use `cmacs-gsurf-container-set-network'.  */)
  (Lisp_Object buffer, Lisp_Object uri)
{
  GsurfView *gv = require_gsurf (buffer);
  if (!NILP (uri))
    CHECK_STRING (uri);
  gsurf_view_set_proxy (gv, NILP (uri) ? NULL : utf8 (uri));
  return Qt;
}

/* ── Containers ─────────────────────────────────────────────────────── */

/* The registry exists once the library is initialised; containers are
   defined by the `containers' module or by Emacs.  config_ensure is
   display-free, so these work before the first browser buffer.  */
static GsurfContainerRegistry *
registry (void)
{
  cmacs_gsurf_config_ensure ();
  return gsurf_container_registry_get_default ();
}

/* A container as a plist.  */
static Lisp_Object
container_plist (GsurfContainer *c)
{
  return listn (16,
                intern (":id"),        string_or_nil (gsurf_container_get_id (c)),
                intern (":name"),      string_or_nil (gsurf_container_get_name (c)),
                intern (":color"),     string_or_nil (gsurf_container_get_color (c)),
                intern (":temporary"), gsurf_container_get_temporary (c) ? Qt : Qnil,
                intern (":views"),     make_fixnum (gsurf_container_get_n_views (c)),
                intern (":data-dir"),  string_or_nil (gsurf_container_get_data_dir (c)),
                intern (":proxy"),     string_or_nil (gsurf_container_get_proxy (c)),
                intern (":user-agent"),
                string_or_nil (gsurf_container_get_user_agent (c)));
}

DEFUN ("cmacs-gsurf-containers", Fcmacs_gsurf_containers,
       Scmacs_gsurf_containers, 0, 0, 0,
       doc: /* Return the gsurf browsing containers as a list of plists.
Each has :id, :name, :color, :temporary, :views (live view count),
:data-dir, :proxy and :user-agent.  Persistent containers come first in
definition order, then temporary ones.  The default container (the
engine's own session) is not listed.  */)
  (void)
{
  GPtrArray *all = gsurf_container_registry_list (registry ());
  Lisp_Object out = Qnil;
  if (all != NULL)
    {
      for (guint i = all->len; i > 0; i--)
        out = Fcons (container_plist (g_ptr_array_index (all, i - 1)), out);
      g_ptr_array_unref (all);
    }
  return out;
}

DEFUN ("cmacs-gsurf-containers-enabled-p", Fcmacs_gsurf_containers_enabled_p,
       Scmacs_gsurf_containers_enabled_p, 0, 0, 0,
       doc: /* Return t when a container placement policy is installed.
That is the `containers' gsurf module being active: it decides which
container each new view opens in (host rules, the opener's container,
the new-tab policy).  Without it a view goes in the container it asks
for, or the default one.  */)
  (void)
{
  return gsurf_container_registry_has_resolver (registry ()) ? Qt : Qnil;
}

DEFUN ("cmacs-gsurf-container-define", Fcmacs_gsurf_container_define,
       Scmacs_gsurf_container_define, 1, 3, 0,
       doc: /* Define (or rename/recolour) persistent container ID.
ID is 1-64 characters of [A-Za-z0-9_-] (not "temporary", "default" or a
"tmp-" name); optional NAME is its display name (default ID), COLOR a
CSS colour.  Its cookies and storage live under
$XDG_DATA_HOME/gsurf/containers/ID.  Returns the container's plist.  */)
  (Lisp_Object id, Lisp_Object name, Lisp_Object color)
{
  GError *err = NULL;
  CHECK_STRING (id);
  if (!NILP (name))  CHECK_STRING (name);
  if (!NILP (color)) CHECK_STRING (color);
  char *c_id    = g_strdup (utf8 (id));
  char *c_name  = NILP (name) ? NULL : g_strdup (utf8 (name));
  char *c_color = NILP (color) ? NULL : g_strdup (utf8 (color));
  GsurfContainer *c = gsurf_container_registry_define (
    registry (), c_id, c_name, c_color, &err);
  g_free (c_id);
  g_free (c_name);
  g_free (c_color);
  if (c == NULL)
    {
      Lisp_Object msg = build_string (err ? err->message : "define failed");
      g_clear_error (&err);
      xsignal2 (Qcmacs_gsurf_error, msg, id);
    }
  return container_plist (c);
}

DEFUN ("cmacs-gsurf-container-new-temporary",
       Fcmacs_gsurf_container_new_temporary,
       Scmacs_gsurf_container_new_temporary, 0, 1, 0,
       doc: /* Create a temporary container and return its id ("tmp-N").
Optional COLOR is a CSS colour.  The container and all its data are
destroyed shortly after its last view closes (or if no view ever uses
it).  Pass the id to `cmacs-gsurf-attach-in-container'; the string
"temporary" there creates one implicitly.  */)
  (Lisp_Object color)
{
  if (!NILP (color)) CHECK_STRING (color);
  GsurfContainer *c = gsurf_container_registry_new_temporary (
    registry (), NILP (color) ? NULL : utf8 (color));
  return c ? string_or_nil (gsurf_container_get_id (c)) : Qnil;
}

DEFUN ("cmacs-gsurf-container-set-network",
       Fcmacs_gsurf_container_set_network,
       Scmacs_gsurf_container_set_network, 2, 4, 0,
       doc: /* Give container ID its own PROXY and USER-AGENT.
PROXY is a URL (http, https, socks4, socks4a, socks5), "none" for a
direct connection, or nil for the global proxy.  PROXY-IGNORE is a list
of hosts that bypass it.  USER-AGENT (or nil) replaces the global user
agent for the container's views from their next navigation.  A live
session switches proxy at once.  Signals on an invalid proxy.  */)
  (Lisp_Object id, Lisp_Object proxy, Lisp_Object proxy_ignore,
   Lisp_Object user_agent)
{
  GError *err = NULL;
  CHECK_STRING (id);
  if (!NILP (proxy))      CHECK_STRING (proxy);
  if (!NILP (user_agent)) CHECK_STRING (user_agent);
  CHECK_LIST (proxy_ignore);

  /* Copy the ignore list into a NULL-terminated C vector; the strings are
     g_strdup'd because utf8 () may allocate (and GC) between elements.  */
  GPtrArray *ign = g_ptr_array_new_with_free_func (g_free);
  for (Lisp_Object t = proxy_ignore; CONSP (t); t = XCDR (t))
    {
      CHECK_STRING (XCAR (t));
      g_ptr_array_add (ign, g_strdup (utf8 (XCAR (t))));
    }
  g_ptr_array_add (ign, NULL);

  char *c_id    = g_strdup (utf8 (id));
  char *c_proxy = NILP (proxy) ? NULL : g_strdup (utf8 (proxy));
  char *c_ua    = NILP (user_agent) ? NULL : g_strdup (utf8 (user_agent));
  gboolean ok = gsurf_container_registry_set_network (
    registry (), c_id, c_proxy,
    ign->len > 1 ? (const gchar * const *) ign->pdata : NULL,
    c_ua, &err);
  g_free (c_id);
  g_free (c_proxy);
  g_free (c_ua);
  g_ptr_array_unref (ign);
  if (!ok)
    {
      Lisp_Object msg = build_string (err ? err->message : "set-network failed");
      g_clear_error (&err);
      xsignal2 (Qcmacs_gsurf_error, msg, id);
    }
  return Qt;
}

DEFUN ("cmacs-gsurf-attach-in-container", Fcmacs_gsurf_attach_in_container,
       Scmacs_gsurf_attach_in_container, 2, 4, 0,
       doc: /* Attach a gsurf view to BUFFER in browsing CONTAINER.
CONTAINER is a container id, "temporary" (a new temporary container),
"default" (the engine's own session), or nil (let the `containers'
module decide, else default).  Optional OPENER is the gsurf buffer this
one was opened from: it is recorded as the view's opener (see
`cmacs-gsurf-opener-id') and, with the module's inherit_opener, keeps
the link in the opener's container.  Optional URI is a placement hint
for host rules; it is not loaded.  WebKit fixes a view's session when
it is created, so a view's container never changes.  Like
`cmacs-gsurf-attach' this is a no-op on a buffer that already has a
view.  Returns t.  */)
  (Lisp_Object buffer, Lisp_Object container, Lisp_Object opener,
   Lisp_Object uri)
{
  CHECK_BUFFER (buffer);
  if (cmacs_gsurf_view_for_buffer (buffer))
    return Qt;
  container = string_or_symbol_name (container);
  if (!NILP (uri)) CHECK_STRING (uri);
  CmacsGsurfView *ov = NULL;
  if (!NILP (opener))
    {
      CHECK_BUFFER (opener);
      ov = cmacs_gsurf_view_for_buffer (opener);  /* gone -> no opener */
    }
  if (!cmacs_gsurf_runtime_ensure ())
    xsignal1 (Qcmacs_gsurf_error,
              build_string ("gsurf backend unavailable (no display?)"));

  /* Copy out of Lisp before creating the view: view construction runs
     module hooks that may call back into Lisp (and GC).  */
  char *c_container = NILP (container) ? NULL : g_strdup (utf8 (container));
  char *c_uri       = NILP (uri) ? NULL : g_strdup (utf8 (uri));
  CmacsGsurfView *v = cmacs_gsurf_view_new_full (buffer, ov, c_container,
                                                 c_uri);
  g_free (c_container);
  g_free (c_uri);
  if (!v)
    xsignal1 (Qcmacs_gsurf_error, build_string ("failed to create gsurf view"));
  return Qt;
}

DEFUN ("cmacs-gsurf-container-id", Fcmacs_gsurf_container_id,
       Scmacs_gsurf_container_id, 1, 1, 0,
       doc: /* Return the id of the container BUFFER's view browses in.
Nil means the default container.  Fixed for the life of the view.  */)
  (Lisp_Object buffer)
{
  return string_or_nil (gsurf_view_get_container_id (require_gsurf (buffer)));
}

/* ── Identity (buffer tree) ─────────────────────────────────────────── */

DEFUN ("cmacs-gsurf-view-id", Fcmacs_gsurf_view_id, Scmacs_gsurf_view_id,
       1, 1, 0,
       doc: /* Return the process-unique gsurf id of BUFFER's view.
Ids start at 1 and are never reused, so they stay meaningful after a
view closes (an opener id can name a buffer that is gone).  */)
  (Lisp_Object buffer)
{
  return make_uint (gsurf_view_get_id (require_gsurf (buffer)));
}

DEFUN ("cmacs-gsurf-opener-id", Fcmacs_gsurf_opener_id,
       Scmacs_gsurf_opener_id, 1, 1, 0,
       doc: /* Return the view id BUFFER's view was opened from, or nil.
Nil means the user opened it directly.  The id is kept after the opener
closes; resolve it with `cmacs-gsurf-buffer-for-view-id'.  */)
  (Lisp_Object buffer)
{
  guint64 id = gsurf_view_get_opener_id (require_gsurf (buffer));
  return id ? make_uint (id) : Qnil;
}

DEFUN ("cmacs-gsurf-buffer-for-view-id", Fcmacs_gsurf_buffer_for_view_id,
       Scmacs_gsurf_buffer_for_view_id, 1, 1, 0,
       doc: /* Return the live gsurf buffer whose view has id ID, or nil.  */)
  (Lisp_Object id)
{
  if (!FIXNATP (id))
    return Qnil;
  GsurfView *gv = gsurf_view_lookup ((guint64) XFIXNAT (id));
  CmacsGsurfView *v = cmacs_gsurf_view_from_gsurf (gv);
  return v ? cmacs_gsurf_view_buffer (v) : Qnil;
}

/* ── Actions ────────────────────────────────────────────────────────── */

DEFUN ("cmacs-gsurf-actions", Fcmacs_gsurf_actions, Scmacs_gsurf_actions,
       0, 0, 0,
       doc: /* Return every gsurf action as an alist of (NAME . DESCRIPTION).
NAME is the canonical action string ("reload", "dark-mode-toggle", ...)
accepted by `cmacs-gsurf-dispatch-action' and by gsurf keybinding
configs.  The list is the whole GsurfAction enum; which of them do
something in an Emacs buffer depends on the modules loaded (see
`cmacs-gsurf-run-action', which also maps the core ones onto cmacs
commands).  Display-free.  */)
  (void)
{
  Lisp_Object out = Qnil;
  for (int a = GSURF_ACTION_LAST - 1; a > GSURF_ACTION_NONE; a--)
    {
      const char *nick = gsurf_action_to_string ((GsurfAction) a);
      const char *desc = gsurf_action_get_description ((GsurfAction) a);
      if (nick == NULL)
        continue;
      out = Fcons (Fcons (build_string (nick), build_string (desc ? desc : "")),
                   out);
    }
  return out;
}

DEFUN ("cmacs-gsurf-dispatch-action", Fcmacs_gsurf_dispatch_action,
       Scmacs_gsurf_dispatch_action, 2, 2, 0,
       doc: /* Offer gsurf ACTION to the modules, acting on BUFFER's view.
ACTION is an action name (string or symbol; `-' and `_' both accepted),
e.g. "dark-mode-toggle", "dark-mode-toggle-site" or "form-autofill".
Returns t when a module performed it and nil when nothing did (no
loaded module implements it -- the core navigation actions are not
module actions; `cmacs-gsurf-run-action' maps those to cmacs commands).
Signals `cmacs-gsurf-error' for an unknown action name, or one refused
in kiosk mode.  */)
  (Lisp_Object buffer, Lisp_Object action)
{
  GsurfView *gv = require_gsurf (buffer);
  Lisp_Object name = string_or_symbol_name (action);
  GError *err = NULL;
  if (NILP (name))
    wrong_type_argument (Qstringp, action);
  GsurfAction a = gsurf_action_from_string (utf8 (name));
  if (a == GSURF_ACTION_NONE)
    xsignal2 (Qcmacs_gsurf_error, build_string ("unknown gsurf action"),
              action);
  require_runtime ();
  if (gsurf_module_manager_execute_action (gsurf_module_manager_get_default (),
                                           NULL, gv, a, &err))
    return Qt;
  if (err != NULL && g_error_matches (err, G_IO_ERROR, G_IO_ERROR_NOT_SUPPORTED))
    {
      g_clear_error (&err);
      return Qnil;
    }
  Lisp_Object msg = build_string (err ? err->message : "action failed");
  g_clear_error (&err);
  xsignal2 (Qcmacs_gsurf_error, msg, action);
}

/* ── Input mode ─────────────────────────────────────────────────────── */

/* GsurfModePolicy -> lower-case symbol (`normal', `insert', ...).  */
static Lisp_Object
mode_symbol (GsurfModePolicy mode)
{
  const char *label = gsurf_mode_policy_get_label (mode);
  if (label == NULL)
    return Qnil;
  gchar *lower = g_ascii_strdown (label, -1);
  Lisp_Object sym = intern (lower);
  g_free (lower);
  return sym;
}

DEFUN ("cmacs-gsurf-input-modes", Fcmacs_gsurf_input_modes,
       Scmacs_gsurf_input_modes, 0, 0, 0,
       doc: /* Return the gsurf input modes as a list of symbols.
`normal' (keys are commands), `insert' (keys go to the page), `follow'
(link hints up), `find' and `passthrough' (every key, Escape included,
goes to the page).  Display-free.  */)
  (void)
{
  Lisp_Object out = Qnil;
  for (int m = GSURF_MODE_PASSTHROUGH; m >= GSURF_MODE_NORMAL; m--)
    out = Fcons (mode_symbol ((GsurfModePolicy) m), out);
  return out;
}

DEFUN ("cmacs-gsurf-input-mode", Fcmacs_gsurf_input_mode,
       Scmacs_gsurf_input_mode, 0, 0, 0,
       doc: /* Return the gsurf input mode in effect, as a symbol.
This is the mode the modal module published (see
`cmacs-gsurf-input-modes').  It only governs keys while a page holds the
keyboard (after \\[cmacs-gsurf-focus-page]); while Emacs has it, Emacs
keymaps apply.  Per-page typing is `cmacs-gsurf-editing-p'.  */)
  (void)
{
  if (!cmacs_gsurf_available_p ())
    return intern ("normal");
  return mode_symbol (gsurf_module_manager_get_mode (
                        gsurf_module_manager_get_default ()));
}

DEFUN ("cmacs-gsurf-set-input-mode", Fcmacs_gsurf_set_input_mode,
       Scmacs_gsurf_set_input_mode, 1, 1, 0,
       doc: /* Publish MODE as the gsurf input mode.
MODE is a symbol or string from `cmacs-gsurf-input-modes'.  This is what
the modal module itself does on `i' / Escape; it runs
`cmacs-gsurf-input-mode-changed-functions' when the mode in effect
changes.  It does not move keyboard focus.  */)
  (Lisp_Object mode)
{
  Lisp_Object name = string_or_symbol_name (mode);
  if (NILP (name))
    wrong_type_argument (Qsymbolp, mode);
  require_runtime ();
  for (int m = GSURF_MODE_NORMAL; m <= GSURF_MODE_PASSTHROUGH; m++)
    {
      const char *label = gsurf_mode_policy_get_label ((GsurfModePolicy) m);
      if (label && !g_ascii_strcasecmp (label, SSDATA (name)))
        {
          gsurf_module_manager_set_mode (gsurf_module_manager_get_default (),
                                         (GsurfModePolicy) m);
          return mode_symbol ((GsurfModePolicy) m);
        }
    }
  xsignal2 (Qcmacs_gsurf_error, build_string ("unknown input mode"), mode);
}

DEFUN ("cmacs-gsurf-editing-p", Fcmacs_gsurf_editing_p,
       Scmacs_gsurf_editing_p, 1, 1, 0,
       doc: /* Return t if an editable element has DOM focus in BUFFER's page.
A text input, textarea, contenteditable or select.  Changes are reported
through `cmacs-gsurf-editing-changed-functions'.  */)
  (Lisp_Object buffer)
{
  return gsurf_view_get_editing (require_gsurf (buffer)) ? Qt : Qnil;
}

DEFUN ("cmacs-gsurf-typing-p", Fcmacs_gsurf_typing_p,
       Scmacs_gsurf_typing_p, 1, 1, 0,
       doc: /* Return t if a bare key for BUFFER's page would be typed text.
True when the modal module passes keys through (INSERT) or a page field
has focus in NORMAL mode; FOLLOW keeps the keys even over a field.  This
is the routing rule the page-focused key handler applies.  */)
  (Lisp_Object buffer)
{
  GsurfView *gv = require_gsurf (buffer);
  if (!cmacs_gsurf_available_p ())
    return gsurf_view_get_editing (gv) ? Qt : Qnil;
  return gsurf_module_manager_is_typing (gsurf_module_manager_get_default (),
                                         gv) ? Qt : Qnil;
}

DEFUN ("cmacs-gsurf-blur-editable", Fcmacs_gsurf_blur_editable,
       Scmacs_gsurf_blur_editable, 1, 1, 0,
       doc: /* Leave the focused field in BUFFER's page.
Blurs `document.activeElement' and clears the editing state at once, so
the next page key is a command, not text.  Touches no keyboard focus.  */)
  (Lisp_Object buffer)
{
  gsurf_view_blur_editable (require_gsurf (buffer));
  return Qt;
}

/* mode-changed is emitted from inside GTK key dispatch and from
   `cmacs-gsurf-set-input-mode' itself; deliver it from an idle so the
   hook never runs nested inside either.  */
static gboolean
mode_changed_idle (gpointer data)
{
  GsurfModePolicy mode = (GsurfModePolicy) GPOINTER_TO_INT (data);
  cmacs_dispatch_safe_call2 (intern ("run-hook-with-args"),
                             intern ("cmacs-gsurf-input-mode-changed-functions"),
                             mode_symbol (mode));
  return G_SOURCE_REMOVE;
}

static void
on_mode_changed (GsurfModuleManager *mgr, GsurfModePolicy mode, gpointer user)
{
  (void) mgr; (void) user;
  GSource *src = g_idle_source_new ();
  g_source_set_callback (src, mode_changed_idle,
                         GINT_TO_POINTER ((int) mode), NULL);
  g_source_attach (src, cmacs_glib_get_context ());
  g_source_unref (src);
}

void
cmacs_gsurf_control_init (void)
{
  static gboolean wired = FALSE;
  if (wired)
    return;
  wired = TRUE;
  g_signal_connect (gsurf_module_manager_get_default (), "mode-changed",
                    G_CALLBACK (on_mode_changed), NULL);
}

/* ── Keybinding help ────────────────────────────────────────────────── */

DEFUN ("cmacs-gsurf-keybinds", Fcmacs_gsurf_keybinds,
       Scmacs_gsurf_keybinds, 0, 0, 0,
       doc: /* Return gsurf's keybinding help rows as a list of plists.
Each has :key (config notation), :pretty (display form), :description,
:source ("core" or the module name) and :action.  Rows are every core
`keybinds:' entry plus each active module that publishes keybindings,
core first, then by module and key.  Module rows act while a page holds
the keyboard; core rows are the standalone gsurf window's bindings,
which cmacs maps onto `cmacs-gsurf-mode-map' instead.  Rebuilt on every
call.  */)
  (void)
{
  Lisp_Object out = Qnil;
  cmacs_gsurf_config_ensure ();
  GPtrArray *rows =
    gsurf_module_manager_collect_keybinds (gsurf_module_manager_get_default ());
  if (rows == NULL)
    return Qnil;
  for (guint i = rows->len; i > 0; i--)
    {
      GsurfKeybindHelp *h = g_ptr_array_index (rows, i - 1);
      const char *key = gsurf_keybind_help_get_key (h);
      gchar *pretty = gsurf_keybind_help_pretty_key (key);
      out = Fcons (listn (10,
                          intern (":key"),    string_or_nil (key),
                          intern (":pretty"), string_or_nil (pretty ? pretty : key),
                          intern (":description"),
                          string_or_nil (gsurf_keybind_help_get_description (h)),
                          intern (":source"),
                          string_or_nil (gsurf_keybind_help_get_source (h)),
                          intern (":action"),
                          string_or_nil (gsurf_keybind_help_get_action (h))),
                   out);
      g_free (pretty);
    }
  g_ptr_array_unref (rows);
  return out;
}

/* ── Registration ───────────────────────────────────────────────────── */

void
syms_of_cmacs_gsurf_control (void)
{
  /* Page input */
  defsubr (&Scmacs_gsurf_keyval);
  defsubr (&Scmacs_gsurf_modifier_mask);
  defsubr (&Scmacs_gsurf_send_key);
  defsubr (&Scmacs_gsurf_click);
  defsubr (&Scmacs_gsurf_type);
  defsubr (&Scmacs_gsurf_locate_script);
  defsubr (&Scmacs_gsurf__parse_point);
  defsubr (&Scmacs_gsurf_click_element);
  /* Cookies + network */
  defsubr (&Scmacs_gsurf_add_cookie);
  defsubr (&Scmacs_gsurf_set_cookie_policy);
  defsubr (&Scmacs_gsurf_set_proxy);
  /* Containers */
  defsubr (&Scmacs_gsurf_containers);
  defsubr (&Scmacs_gsurf_containers_enabled_p);
  defsubr (&Scmacs_gsurf_container_define);
  defsubr (&Scmacs_gsurf_container_new_temporary);
  defsubr (&Scmacs_gsurf_container_set_network);
  defsubr (&Scmacs_gsurf_attach_in_container);
  defsubr (&Scmacs_gsurf_container_id);
  /* Identity */
  defsubr (&Scmacs_gsurf_view_id);
  defsubr (&Scmacs_gsurf_opener_id);
  defsubr (&Scmacs_gsurf_buffer_for_view_id);
  /* Actions */
  defsubr (&Scmacs_gsurf_actions);
  defsubr (&Scmacs_gsurf_dispatch_action);
  /* Input mode */
  defsubr (&Scmacs_gsurf_input_modes);
  defsubr (&Scmacs_gsurf_input_mode);
  defsubr (&Scmacs_gsurf_set_input_mode);
  defsubr (&Scmacs_gsurf_editing_p);
  defsubr (&Scmacs_gsurf_typing_p);
  defsubr (&Scmacs_gsurf_blur_editable);
  /* Keybinding help */
  defsubr (&Scmacs_gsurf_keybinds);
}

#endif /* HAVE_CMACS_GSURF */
