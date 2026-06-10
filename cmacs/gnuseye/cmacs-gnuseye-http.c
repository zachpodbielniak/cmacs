/* cmacs-gnuseye-http.c --- async HTTP feed client.
 *
 * Copyright (C) 2026 Zach Podbielniak
 * SPDX-License-Identifier: AGPL-3.0-or-later
 *
 * A non-blocking HTTP GET for the gnuseye layers: each request runs on a
 * detached worker thread (its own SoupSession, fully isolated from the
 * Emacs main thread) with retry/backoff and Retry-After etiquette modelled
 * on deps/ai-glib/src/convenience/ai-search-http.c (private to ai-glib, so
 * the logic is reimplemented here, not linked).  The response is delivered
 * back on the cmacs GMainContext, where the Lisp callback is invoked under
 * the input guard via the cookie registry.  The body is returned verbatim
 * (status + string); JSON parsing is left to Elisp (json-parse-string),
 * keeping this layer free of feed-shape knowledge. */

#include <config.h>

#ifdef HAVE_CMACS_GNUSEYE

#include "lisp.h"
#include "coding.h"
#include "cmacs-gnuseye.h"
#include "cmacs-glib-loop.h"
#include "cmacs-eval-dispatch.h"

#include <glib.h>
#include <libsoup/soup.h>
#include <stdint.h>

#define GNUSEYE_HTTP_ATTEMPTS  3
#define GNUSEYE_HTTP_BACKOFF_MS 200
#define GNUSEYE_HTTP_TIMEOUT_S  20

typedef struct
{
  gchar    *url;
  gchar   **headers;   /* NULL-terminated name,value,name,value,... */
  uint64_t  cookie;
} HttpReq;

typedef struct
{
  uint64_t  cookie;
  int       status;    /* HTTP status, or 0 on transport error */
  gchar    *body;      /* owned, or NULL */
  gchar    *error;     /* owned, or NULL */
} HttpResult;

void
cmacs_gnuseye_http_init (void)
{
  /* Sessions are created per-request on the worker thread; nothing to do
   * here beyond confirming the symbol is linked. */
}

void
cmacs_gnuseye_http_shutdown (void)
{
}

/* Deliver one finished request to its Lisp callback on the cmacs context. */
static gboolean
http_deliver_idle (gpointer data)
{
  HttpResult *r = data;
  Lisp_Object args[2];
  if (r->error)
    {
      args[0] = Qnil;
      args[1] = build_string (r->error);
    }
  else
    {
      args[0] = make_fixnum (r->status);
      args[1] = r->body ? build_string (r->body) : empty_unibyte_string;
    }
  cmacs_dispatch_callback_invokeN (r->cookie, 2, args);
  g_free (r->body);
  g_free (r->error);
  g_free (r);
  return G_SOURCE_REMOVE;
}

static gint
parse_retry_after (SoupMessage *msg)
{
  SoupMessageHeaders *h = soup_message_get_response_headers (msg);
  if (!h) return 0;
  const char *ra = soup_message_headers_get_one (h, "Retry-After");
  if (!ra) return 0;
  gint64 secs = g_ascii_strtoll (ra, NULL, 10);
  if (secs > 0 && secs < 120) return (gint) secs;
  return 0;
}

static gpointer
http_worker (gpointer data)
{
  HttpReq *req = data;
  HttpResult *res = g_new0 (HttpResult, 1);
  res->cookie = req->cookie;

  SoupSession *session = soup_session_new ();
  soup_session_set_timeout (session, GNUSEYE_HTTP_TIMEOUT_S);
  soup_session_set_user_agent (session, "cmacs-gnuseye/1.0 ");

  guint backoff = GNUSEYE_HTTP_BACKOFF_MS;
  for (int attempt = 0; attempt < GNUSEYE_HTTP_ATTEMPTS; attempt++)
    {
      SoupMessage *msg = soup_message_new (SOUP_METHOD_GET, req->url);
      if (!msg)
        {
          g_clear_pointer (&res->error, g_free);
          res->error = g_strdup ("invalid URL");
          break;
        }
      if (req->headers)
        {
          SoupMessageHeaders *rh = soup_message_get_request_headers (msg);
          for (int i = 0; req->headers[i] && req->headers[i + 1]; i += 2)
            soup_message_headers_append (rh, req->headers[i],
                                         req->headers[i + 1]);
        }

      GError *err = NULL;
      GBytes *bytes = soup_session_send_and_read (session, msg, NULL, &err);
      guint status = soup_message_get_status (msg);

      if (bytes && status >= 200 && status < 300)
        {
          gsize sz = 0;
          const char *d = g_bytes_get_data (bytes, &sz);
          g_clear_pointer (&res->error, g_free);
          res->status = (int) status;
          res->body = g_strndup (d ? d : "", sz);
          g_bytes_unref (bytes);
          g_object_unref (msg);
          break;
        }

      /* Failure: decide whether to retry. */
      gint retry_after = (status == 429) ? parse_retry_after (msg) : 0;
      g_clear_pointer (&res->error, g_free);
      res->status = (int) status;
      res->error = err ? g_strdup (err->message)
                       : g_strdup_printf ("HTTP %u", status);
      if (bytes) g_bytes_unref (bytes);
      g_clear_error (&err);
      g_object_unref (msg);

      gboolean transient = (status == 0 || status == 429
                            || (status >= 500 && status < 600));
      if (!transient || attempt == GNUSEYE_HTTP_ATTEMPTS - 1)
        break;
      guint sleep_ms = retry_after > 0 ? (guint) retry_after * 1000 : backoff;
      g_usleep ((gulong) sleep_ms * 1000);
      backoff *= 2;
    }

  /* A 2xx clears res->error; if it is still set we report failure. */
  if (res->body) { g_clear_pointer (&res->error, g_free); }

  g_object_unref (session);
  g_main_context_invoke (cmacs_glib_get_context (), http_deliver_idle, res);

  g_free (req->url);
  g_strfreev (req->headers);
  g_free (req);
  return NULL;
}

/* Convert a Lisp header alist ((NAME . VALUE) ...) into a NULL-terminated
 * name,value,name,value,... C array (all g_strdup'd for thread hand-off). */
static gchar **
headers_to_cstrv (Lisp_Object headers)
{
  GPtrArray *a = g_ptr_array_new ();
  for (Lisp_Object tail = headers; CONSP (tail); tail = XCDR (tail))
    {
      Lisp_Object pair = XCAR (tail);
      if (CONSP (pair) && STRINGP (XCAR (pair)) && STRINGP (XCDR (pair)))
        {
          g_ptr_array_add (a, g_strdup (SSDATA (ENCODE_UTF_8 (XCAR (pair)))));
          g_ptr_array_add (a, g_strdup (SSDATA (ENCODE_UTF_8 (XCDR (pair)))));
        }
    }
  g_ptr_array_add (a, NULL);
  return (gchar **) g_ptr_array_free (a, FALSE);
}

DEFUN ("cmacs-gnuseye-http-get-async", Fcmacs_gnuseye_http_get_async,
       Scmacs_gnuseye_http_get_async, 2, 3, 0,
       doc: /* GET URL asynchronously and call CALLBACK with the result.
HEADERS is an alist of (NAME . VALUE) string pairs (or nil).  CALLBACK is
called on the cmacs main loop as (STATUS BODY) on success, or (nil ERROR)
on failure, where STATUS is the integer HTTP status and BODY the raw
response string (parse JSON yourself with `json-parse-string').  The
request runs on a worker thread with retry/backoff and Retry-After
handling; this returns immediately.  */)
  (Lisp_Object url, Lisp_Object callback, Lisp_Object headers)
{
  CHECK_STRING (url);

  HttpReq *req = g_new0 (HttpReq, 1);
  req->url = g_strdup (SSDATA (ENCODE_UTF_8 (url)));
  req->headers = NILP (headers) ? NULL : headers_to_cstrv (headers);
  req->cookie = cmacs_dispatch_callback_register (callback);

  GThread *t = g_thread_new ("gnuseye-http", http_worker, req);
  if (t) g_thread_unref (t);   /* detached */
  return Qt;
}

DEFUN ("cmacs-gnuseye-http-available-p", Fcmacs_gnuseye_http_available_p,
       Scmacs_gnuseye_http_available_p, 0, 0, 0,
       doc: /* Return t: the native async HTTP client is available.  */)
  (void)
{
  return Qt;
}

void
syms_of_cmacs_gnuseye_http (void)
{
  defsubr (&Scmacs_gnuseye_http_get_async);
  defsubr (&Scmacs_gnuseye_http_available_p);
}

#endif /* HAVE_CMACS_GNUSEYE */
