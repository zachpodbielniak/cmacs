/*
 * Copyright (C) 2026 Zach Podbielniak
 * SPDX-License-Identifier: AGPL-3.0-or-later
 */

/* cmacs-api-transport.c --- transport abstraction for the CMacs API
 *
 * Three backends:
 *   1. DIRECT -- in-process function calls via a registered dispatch
 *      table.  Used by crispy scripts loaded into the Emacs process.
 *   2. FD -- length-prefixed JSON over a Unix socketpair ($CMACS_IPC_FD).
 *      Used by the bacon child process.
 *   3. D-Bus -- GDBusProxy to org.cmacs.Editor1 ($CMACS_DBUS_NAME).
 *      Used by external tools.
 *
 * All backends provide the same synchronous call/response semantics.
 */

#include "cmacs-api.h"

#include <gio/gio.h>
#include <json-glib/json-glib.h>
#include <unistd.h>
#include <errno.h>
#include <string.h>
#include <poll.h>

typedef enum {
    TRANSPORT_DIRECT,
    TRANSPORT_FD,
    TRANSPORT_DBUS
} CmacsApiTransportKind;

struct _CmacsApiTransport
{
    CmacsApiTransportKind kind;
    union {
        int          fd;
        GDBusProxy  *proxy;
    } u;
    gint64 next_id;
};

/* Global direct dispatch table, set by cmacs_api_set_direct_dispatch(). */
static const CmacsApiDirectDispatch *direct_dispatch = NULL;

#define CMACS_TRANSPORT_ERROR (g_quark_from_static_string ("cmacs-transport"))

void
cmacs_api_set_direct_dispatch (const CmacsApiDirectDispatch *dispatch)
{
    direct_dispatch = dispatch;
}

/* ── FD transport: wire protocol helpers ───────────────────────────── */

static gboolean
fd_read_exact (int fd, guint8 *buf, gsize n)
{
    gsize off = 0;
    while (off < n)
    {
        gssize r = read (fd, buf + off, n - off);
        if (r <= 0)
        {
            if (r < 0 && errno == EINTR)
                continue;
            return FALSE;
        }
        off += (gsize)r;
    }
    return TRUE;
}

static gboolean
fd_write_exact (int fd, const guint8 *buf, gsize n)
{
    gsize off = 0;
    while (off < n)
    {
        gssize w = write (fd, buf + off, n - off);
        if (w < 0)
        {
            if (errno == EINTR)
                continue;
            return FALSE;
        }
        off += (gsize)w;
    }
    return TRUE;
}

/* Send a length-prefixed JSON message on fd. */
static gboolean
fd_send_json (int fd, JsonNode *root)
{
    JsonGenerator *gen;
    gchar *json;
    gsize len;
    guint32 net_len;
    gboolean ok;

    gen = json_generator_new ();
    json_generator_set_root (gen, root);
    json = json_generator_to_data (gen, &len);
    g_object_unref (gen);

    net_len = GUINT32_TO_BE ((guint32)len);
    ok = fd_write_exact (fd, (const guint8 *)&net_len, 4)
         && fd_write_exact (fd, (const guint8 *)json, len);
    g_free (json);
    return ok;
}

/* Like fd_read_exact, but gives up once DEADLINE_US (monotonic) passes.
 * poll() only says the first byte is there; a peer that stalls after a
 * partial frame must not park the caller in read() forever. */
static gboolean
fd_read_exact_deadline (int fd, guint8 *buf, gsize n, gint64 deadline_us)
{
    gsize off = 0;
    while (off < n)
    {
        struct pollfd pfd;
        gint64 now = g_get_monotonic_time ();
        int timeout_ms;
        gssize r;

        if (now >= deadline_us)
            return FALSE;
        timeout_ms = (int) ((deadline_us - now + 999) / 1000);
        pfd.fd = fd;
        pfd.events = POLLIN;
        if (poll (&pfd, 1, timeout_ms) <= 0)
        {
            if (errno == EINTR)
                continue;
            return FALSE;
        }
        r = read (fd, buf + off, n - off);
        if (r <= 0)
        {
            if (r < 0 && (errno == EINTR || errno == EAGAIN))
                continue;
            return FALSE;
        }
        off += (gsize)r;
    }
    return TRUE;
}

/* Read a length-prefixed JSON message from fd.  DEADLINE_US bounds the
 * whole frame (0 = block). */
static JsonNode *
fd_recv_json_deadline (int fd, gint64 deadline_us)
{
    guint32 net_len, msg_len;
    guint8 *buf;
    JsonParser *parser;
    JsonNode *root = NULL;
    gboolean ok = deadline_us > 0
        ? fd_read_exact_deadline (fd, (guint8 *)&net_len, 4, deadline_us)
        : fd_read_exact (fd, (guint8 *)&net_len, 4);

    if (!ok)
        return NULL;

    msg_len = GUINT32_FROM_BE (net_len);
    if (msg_len == 0 || msg_len > 16 * 1024 * 1024)
        return NULL;

    buf = g_malloc (msg_len + 1);
    ok = deadline_us > 0
        ? fd_read_exact_deadline (fd, buf, msg_len, deadline_us)
        : fd_read_exact (fd, buf, msg_len);
    if (!ok)
    {
        g_free (buf);
        return NULL;
    }
    buf[msg_len] = '\0';

    parser = json_parser_new ();
    if (json_parser_load_from_data (parser, (const gchar *)buf,
                                    (gssize)msg_len, NULL))
    {
        root = json_parser_get_root (parser);
        if (root != NULL)
            root = json_node_copy (root);
    }
    g_object_unref (parser);
    g_free (buf);
    return root;
}

/* Read frames until the reply whose "id" is ID arrives (30 s overall).
 * A stray or stale frame is dropped rather than misattributed. */
static JsonObject *
fd_wait_reply (int fd, gint64 id, JsonNode **root_out)
{
    gint64 deadline = g_get_monotonic_time () + (gint64) 30 * G_USEC_PER_SEC;

    for (;;)
    {
        JsonNode *resp_root = fd_recv_json_deadline (fd, deadline);
        JsonObject *resp_obj;

        if (resp_root == NULL)
            return NULL;
        if (!JSON_NODE_HOLDS_OBJECT (resp_root))
        {
            json_node_unref (resp_root);
            continue;
        }
        resp_obj = json_node_get_object (resp_root);
        if (json_object_get_int_member_with_default (resp_obj, "id", -1) != id)
        {
            json_node_unref (resp_root);
            continue;
        }
        *root_out = resp_root;
        return resp_obj;
    }
}

/* ── FD transport call implementation ──────────────────────────────── */

static GVariant *
fd_transport_call (CmacsApiTransport *t, const gchar *method,
                   GVariant *params, GError **error)
{
    JsonNode *req_root, *resp_root;
    JsonObject *req_obj, *params_obj, *resp_obj;
    gint64 id;

    id = t->next_id++;

    req_obj = json_object_new ();
    json_object_set_int_member (req_obj, "id", id);
    json_object_set_string_member (req_obj, "method", method);

    params_obj = json_object_new ();

    if (g_strcmp0 (method, "Eval") == 0)
    {
        const gchar *expr;
        g_variant_get (params, "(&s)", &expr);
        json_object_set_string_member (params_obj, "expression", expr);
    }
    else if (g_strcmp0 (method, "FindFile") == 0)
    {
        const gchar *path;
        g_variant_get (params, "(&s)", &path);
        json_object_set_string_member (params_obj, "path", path);
    }
    else if (g_strcmp0 (method, "Message") == 0)
    {
        const gchar *text;
        g_variant_get (params, "(&s)", &text);
        json_object_set_string_member (params_obj, "text", text);
    }
    else if (g_strcmp0 (method, "GiRequire") == 0)
    {
        const gchar *ns, *ver;
        g_variant_get (params, "(&s&s)", &ns, &ver);
        json_object_set_string_member (params_obj, "namespace", ns);
        json_object_set_string_member (params_obj, "version", ver);
    }
    else if (g_strcmp0 (method, "GiCall") == 0)
    {
        const gchar *ns, *func, *arg;
        GVariantIter *iter;
        JsonArray *arr;

        g_variant_get (params, "(&s&sas)", &ns, &func, &iter);
        json_object_set_string_member (params_obj, "namespace", ns);
        json_object_set_string_member (params_obj, "function", func);

        arr = json_array_new ();
        while (g_variant_iter_next (iter, "&s", &arg))
            json_array_add_string_element (arr, arg);
        g_variant_iter_free (iter);
        json_object_set_array_member (params_obj, "args", arr);
    }
    else if (g_strcmp0 (method, "GiListFunctions") == 0)
    {
        const gchar *ns;
        g_variant_get (params, "(&s)", &ns);
        json_object_set_string_member (params_obj, "namespace", ns);
    }

    json_object_set_object_member (req_obj, "params", params_obj);

    req_root = json_node_new (JSON_NODE_OBJECT);
    json_node_set_object (req_root, req_obj);

    if (!fd_send_json (t->u.fd, req_root))
    {
        json_node_unref (req_root);
        json_object_unref (req_obj);
        g_set_error (error, CMACS_TRANSPORT_ERROR, 1,
                     "failed to send IPC request");
        return NULL;
    }
    json_node_unref (req_root);
    json_object_unref (req_obj);

    /* 30s timeout to avoid deadlock; the reply is matched by id. */
    resp_obj = fd_wait_reply (t->u.fd, id, &resp_root);
    if (resp_obj == NULL)
    {
        g_set_error (error, CMACS_TRANSPORT_ERROR, 1,
                     "failed to read IPC response");
        return NULL;
    }

    if (json_object_has_member (resp_obj, "error"))
    {
        const gchar *msg = json_object_get_string_member_with_default (
            resp_obj, "error", "unknown IPC error");
        g_set_error (error, CMACS_TRANSPORT_ERROR, 1, "%s", msg);
        json_node_unref (resp_root);
        return NULL;
    }

    {
        const gchar *result_str;
        GVariant *result;

        result_str = json_object_get_string_member_with_default (
            resp_obj, "result", NULL);

        if (g_strcmp0 (method, "Eval") == 0
            || g_strcmp0 (method, "GiCall") == 0)
        {
            result = g_variant_new ("(s)", result_str ? result_str : "nil");
        }
        else if (g_strcmp0 (method, "GiRequire") == 0)
        {
            result = g_variant_new ("(b)",
                g_strcmp0 (result_str, "t") == 0);
        }
        else if (g_strcmp0 (method, "GiListFunctions") == 0)
        {
            GVariantBuilder builder;
            gchar **lines;
            gint i;

            g_variant_builder_init (&builder, G_VARIANT_TYPE ("as"));
            if (result_str != NULL && *result_str != '\0')
            {
                lines = g_strsplit (result_str, "\n", -1);
                for (i = 0; lines[i] != NULL; i++)
                    g_variant_builder_add (&builder, "s", lines[i]);
                g_strfreev (lines);
            }
            result = g_variant_new ("(as)", &builder);
        }
        else
        {
            result = NULL;
        }

        json_node_unref (resp_root);
        return result;
    }
}

/* ── DIRECT transport call implementation ─────────────────────────── */

/* The DIRECT backend calls Emacs dispatch functions in-process via
 * the registered function pointer table.  This is used by crispy
 * scripts which are compiled to .so and loaded into the Emacs
 * process with g_module_open().  No IPC overhead. */

static GVariant *
direct_transport_call (const gchar *method, GVariant *params,
                       GError **error)
{
    if (direct_dispatch == NULL)
    {
        g_set_error (error, CMACS_TRANSPORT_ERROR, 1,
                     "DIRECT transport: no dispatch table registered");
        return NULL;
    }

    if (g_strcmp0 (method, "Eval") == 0)
    {
        const gchar *expr;
        gchar *result_str;

        g_variant_get (params, "(&s)", &expr);
        result_str = direct_dispatch->eval (expr, error);
        if (result_str == NULL)
            return NULL;

        {
            GVariant *result = g_variant_new ("(s)", result_str);
            g_free (result_str);
            return result;
        }
    }
    else if (g_strcmp0 (method, "FindFile") == 0)
    {
        const gchar *path;
        g_variant_get (params, "(&s)", &path);
        direct_dispatch->find_file (path);
        return NULL;
    }
    else if (g_strcmp0 (method, "Message") == 0)
    {
        const gchar *text;
        g_variant_get (params, "(&s)", &text);
        direct_dispatch->message (text);
        return NULL;
    }
    else if (g_strcmp0 (method, "GiRequire") == 0)
    {
        const gchar *ns, *ver;
        gboolean ok;

        g_variant_get (params, "(&s&s)", &ns, &ver);
        ok = direct_dispatch->gi_require (ns, ver, error);
        return g_variant_new ("(b)", ok);
    }
    else if (g_strcmp0 (method, "GiCall") == 0)
    {
        const gchar *ns, *func, *arg;
        GVariantIter *iter;
        GPtrArray *args_arr;
        gchar *result_str;

        g_variant_get (params, "(&s&sas)", &ns, &func, &iter);
        args_arr = g_ptr_array_new ();
        while (g_variant_iter_next (iter, "&s", &arg))
            g_ptr_array_add (args_arr, (gpointer)arg);
        g_variant_iter_free (iter);

        result_str = direct_dispatch->gi_call (
            ns, func,
            (const gchar *const *)args_arr->pdata,
            (gint)args_arr->len, error);
        g_ptr_array_free (args_arr, TRUE);

        if (result_str == NULL)
            return NULL;

        {
            GVariant *result = g_variant_new ("(s)", result_str);
            g_free (result_str);
            return result;
        }
    }
    else if (g_strcmp0 (method, "GiListFunctions") == 0)
    {
        const gchar *ns;
        gchar **funcs;
        GVariantBuilder builder;
        gint i;

        g_variant_get (params, "(&s)", &ns);
        funcs = direct_dispatch->gi_list_functions (ns);

        g_variant_builder_init (&builder, G_VARIANT_TYPE ("as"));
        if (funcs != NULL)
        {
            for (i = 0; funcs[i] != NULL; i++)
                g_variant_builder_add (&builder, "s", funcs[i]);
            g_strfreev (funcs);
        }
        return g_variant_new ("(as)", &builder);
    }

    g_set_error (error, CMACS_TRANSPORT_ERROR, 1,
                 "DIRECT transport: unknown method '%s'", method);
    return NULL;
}

/* ── Public API ────────────────────────────────────────────────────── */

CmacsApiTransport *
cmacs_api_transport_new (GError **error)
{
    CmacsApiTransport *t;
    const gchar *fd_str, *bus_name;

    t = g_new0 (CmacsApiTransport, 1);
    t->next_id = 1;

    /* Prefer DIRECT transport if dispatch table is registered. */
    if (direct_dispatch != NULL)
    {
        t->kind = TRANSPORT_DIRECT;
        return t;
    }

    /* Then try FD transport. */
    fd_str = g_getenv ("CMACS_IPC_FD");
    if (fd_str != NULL && *fd_str != '\0')
    {
        t->kind = TRANSPORT_FD;
        t->u.fd = atoi (fd_str);
        return t;
    }

    /* Fall back to D-Bus. */
    bus_name = g_getenv ("CMACS_DBUS_NAME");
    if (bus_name == NULL || *bus_name == '\0')
    {
        g_set_error (error, CMACS_TRANSPORT_ERROR, 1,
                     "No transport available: no direct dispatch, "
                     "CMACS_IPC_FD, or CMACS_DBUS_NAME set");
        g_free (t);
        return NULL;
    }

    t->kind = TRANSPORT_DBUS;
    t->u.proxy = g_dbus_proxy_new_for_bus_sync (
        G_BUS_TYPE_SESSION,
        G_DBUS_PROXY_FLAGS_NONE,
        NULL,
        bus_name,
        "/org/cmacs/Editor",
        "org.cmacs.Editor1",
        NULL, error);

    if (t->u.proxy == NULL)
    {
        g_free (t);
        return NULL;
    }

    return t;
}

void
cmacs_api_transport_free (CmacsApiTransport *t)
{
    if (t == NULL)
        return;

    if (t->kind == TRANSPORT_DBUS && t->u.proxy != NULL)
        g_object_unref (t->u.proxy);

    g_free (t);
}

GVariant *
cmacs_api_transport_call (CmacsApiTransport *t, const gchar *method,
                          GVariant *params, GError **error)
{
    if (t->kind == TRANSPORT_DIRECT)
        return direct_transport_call (method, params, error);

    if (t->kind == TRANSPORT_FD)
        return fd_transport_call (t, method, params, error);

    /* D-Bus path */
    return g_dbus_proxy_call_sync (t->u.proxy, method, params,
                                   G_DBUS_CALL_FLAGS_NONE, -1,
                                   NULL, error);
}
