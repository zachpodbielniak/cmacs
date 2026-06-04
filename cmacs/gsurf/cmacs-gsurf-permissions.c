/* cmacs-gsurf-permissions.c --- permission requests for the gsurf browser.
 *
 * Copyright (C) 2026 Zach Podbielniak
 * SPDX-License-Identifier: AGPL-3.0-or-later
 *
 * WebKit asks for a permission decision (geolocation, notifications,
 * camera/mic, ...) synchronously, so we must answer without blocking: a
 * modal y-or-n-p from inside the signal would re-enter the command loop
 * from a GLib dispatch and corrupt waiting_for_input.  Instead cmacs keeps
 * a pure-C per-origin policy table (populated from Emacs via
 * `cmacs-gsurf-set-permission-policy') and answers from it; an unknown
 * origin is DENIED and an async notification fires
 * `cmacs-gsurf-permission-request-functions' so the user can set a
 * persistent policy and retry.
 *
 * The handler is connected per view on the native WebKitWebView from
 * cmacs_gsurf_view_new; it runs AFTER gsurf's own permission handler,
 * which returns FALSE (does not consume) whenever no gsurf permission
 * module is enabled (the cmacs default), so ours wins via first-TRUE.
 * Teardown: cmacs_gsurf_view_destroy disconnects handlers on v->widget by
 * data before the widget is unreffed (no late callback on a freed view). */

#include <config.h>

#ifdef HAVE_CMACS_GSURF

#include "lisp.h"
#include "buffer.h"
#include "cmacs-gsurf.h"
#include "cmacs-eval-dispatch.h"

#include <glib.h>
#include <webkit2/webkit2.h>

/* origin"\t"type -> GINT (1 = deny, 2 = allow); absent = unknown. */
static GHashTable *policies = NULL;

static void
ensure_table (void)
{
  if (!policies)
    policies = g_hash_table_new_full (g_str_hash, g_str_equal, g_free, NULL);
}

static const char *
perm_type_name (WebKitPermissionRequest *req)
{
  if (WEBKIT_IS_GEOLOCATION_PERMISSION_REQUEST (req))  return "geolocation";
  if (WEBKIT_IS_NOTIFICATION_PERMISSION_REQUEST (req)) return "notification";
  if (WEBKIT_IS_USER_MEDIA_PERMISSION_REQUEST (req))   return "media";
  if (WEBKIT_IS_CLIPBOARD_PERMISSION_REQUEST (req))    return "clipboard";
  if (WEBKIT_IS_DEVICE_INFO_PERMISSION_REQUEST (req))  return "device-info";
  if (WEBKIT_IS_POINTER_LOCK_PERMISSION_REQUEST (req)) return "pointer-lock";
  return "other";
}

/* "scheme://host:port" for the page in WV (freshly g_malloc'd). */
static char *
origin_of (WebKitWebView *wv)
{
  const char *uri = webkit_web_view_get_uri (wv);
  if (!uri || !*uri)
    return g_strdup ("");
  WebKitSecurityOrigin *o = webkit_security_origin_new_for_uri (uri);
  char *s = o ? webkit_security_origin_to_string (o) : NULL;
  if (o)
    webkit_security_origin_unref (o);
  return s ? s : g_strdup ("");
}

/* -1 unknown, 0 deny, 1 allow. */
static int
policy_lookup (const char *origin, const char *type)
{
  if (!policies)
    return -1;
  g_autofree char *key =
    g_strdup_printf ("%s\t%s", origin ? origin : "", type ? type : "");
  gpointer val = g_hash_table_lookup (policies, key);
  if (!val)
    return -1;
  return GPOINTER_TO_INT (val) == 2 ? 1 : 0;
}

static gboolean
on_permission_request (WebKitWebView *wv, WebKitPermissionRequest *req,
                       gpointer user)
{
  CmacsGsurfView *v = user;
  const char *type = perm_type_name (req);
  g_autofree char *origin = origin_of (wv);
  int verdict = policy_lookup (origin, type);

  if (verdict == 1)
    {
      webkit_permission_request_allow (req);
      return TRUE;
    }
  if (verdict == 0)
    {
      webkit_permission_request_deny (req);
      return TRUE;
    }

  /* Unknown origin: deny (safe, synchronous) and notify Emacs so the user
     can persist a policy for next time. */
  webkit_permission_request_deny (req);
  if (v)
    {
      Lisp_Object buffer = cmacs_gsurf_view_buffer (v);
      if (BUFFERP (buffer))
        {
          Lisp_Object args[4];
          args[0] = intern ("cmacs-gsurf-permission-request-functions");
          args[1] = buffer;
          args[2] = build_string (origin);
          args[3] = intern (type);
          cmacs_dispatch_safe_callN (intern ("run-hook-with-args"), 4, args);
        }
    }
  return TRUE;
}

/* ── Public API (cmacs-gsurf.h) ─────────────────────────────────────── */

void
cmacs_gsurf_permissions_attach (void *webview, CmacsGsurfView *v)
{
  if (!webview)
    return;
  g_signal_connect (WEBKIT_WEB_VIEW (webview), "permission-request",
                    G_CALLBACK (on_permission_request), v);
}

void
cmacs_gsurf_permission_set_policy (const char *origin, const char *type,
                                   int allow)
{
  ensure_table ();
  char *key =
    g_strdup_printf ("%s\t%s", origin ? origin : "", type ? type : "");
  g_hash_table_replace (policies, key, GINT_TO_POINTER (allow ? 2 : 1));
}

void
cmacs_gsurf_permission_clear_policies (void)
{
  if (policies)
    g_hash_table_remove_all (policies);
}

#endif /* HAVE_CMACS_GSURF */
