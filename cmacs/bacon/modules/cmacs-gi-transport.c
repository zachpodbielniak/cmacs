/*
 * Copyright (C) 2026 Zach Podbielniak
 * SPDX-License-Identifier: AGPL-3.0-or-later
 */

/* cmacs-gi-transport.c — transport abstraction for cmacsgi
 *
 * Two backends:
 *   1. FD — length-prefixed JSON over a Unix socketpair ($CMACS_IPC_FD)
 *   2. D-Bus — GDBusProxy to org.cmacs.Editor1 ($CMACS_DBUS_NAME)
 *
 * Both provide the same RPC semantics: synchronous call/response.
 */

#ifndef BACON_COMPILATION
#define BACON_COMPILATION
#endif
#include "cmacs-gi-transport.h"

#include <json-glib/json-glib.h>
#include <unistd.h>
#include <errno.h>
#include <string.h>

typedef enum {
    TRANSPORT_FD,
    TRANSPORT_DBUS
} CmacsGiTransportKind;

struct _CmacsGiTransport
{
    CmacsGiTransportKind kind;
    union {
        int          fd;
        GDBusProxy  *proxy;
    } u;
    gint64 next_id;
};

#define CMACS_TRANSPORT_ERROR (g_quark_from_static_string ("cmacs-transport"))

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

/* Read a length-prefixed JSON message from fd.
   Returns a JsonNode (caller unrefs), or NULL on error. */
static JsonNode *
fd_recv_json (int fd)
{
    guint32 net_len, msg_len;
    guint8 *buf;
    JsonParser *parser;
    JsonNode *root = NULL;

    if (!fd_read_exact (fd, (guint8 *)&net_len, 4))
        return NULL;

    msg_len = GUINT32_FROM_BE (net_len);
    if (msg_len == 0 || msg_len > 16 * 1024 * 1024)
        return NULL;

    buf = g_malloc (msg_len + 1);
    if (!fd_read_exact (fd, buf, msg_len))
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

/* ── FD transport call implementation ──────────────────────────────── */

/* Build a JSON request for the given D-Bus-style method + GVariant params.
   We translate GVariant params to JSON so the parent side can parse them.

   Methods and their GVariant param types:
     Eval:            (s)  → {"expression": "..."}
     FindFile:        (s)  → {"path": "..."}
     Message:         (s)  → {"text": "..."}
     GiRequire:       (ss) → {"namespace": "...", "version": "..."}
     GiCall:          (ssas) → {"namespace": "...", "function": "...", "args": [...]}
     GiListFunctions: (s)  → {"namespace": "..."}
*/
static GVariant *
fd_transport_call (CmacsGiTransport *t, const gchar *method,
                   GVariant *params, GError **error)
{
    JsonNode *req_root, *resp_root;
    JsonObject *req_obj, *params_obj, *resp_obj;
    gint64 id;

    id = t->next_id++;

    /* Build request JSON. */
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

    /* Send request. */
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

    /* Read response. */
    resp_root = fd_recv_json (t->u.fd);
    if (resp_root == NULL)
    {
        g_set_error (error, CMACS_TRANSPORT_ERROR, 1,
                     "failed to read IPC response");
        return NULL;
    }

    resp_obj = json_node_get_object (resp_root);

    if (json_object_has_member (resp_obj, "error"))
    {
        const gchar *msg = json_object_get_string_member (resp_obj, "error");
        g_set_error (error, CMACS_TRANSPORT_ERROR, 1, "%s", msg);
        json_node_unref (resp_root);
        return NULL;
    }

    /* Convert response to GVariant to match the D-Bus interface. */
    {
        const gchar *result_str;
        GVariant *result;

        result_str = json_object_get_string_member (resp_obj, "result");

        /* Match GVariant return types based on method:
           Eval → (s), GiRequire → (b), GiCall → (s),
           GiListFunctions → (as), FindFile/Message → NULL */
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
            /* FindFile, Message — no return value */
            result = NULL;
        }

        json_node_unref (resp_root);
        return result;
    }
}

/* ── Public API ────────────────────────────────────────────────────── */

CmacsGiTransport *
cmacs_gi_transport_new (GError **error)
{
    CmacsGiTransport *t;
    const gchar *fd_str, *bus_name;

    t = g_new0 (CmacsGiTransport, 1);
    t->next_id = 1;

    /* Prefer fd transport if available. */
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
                     "Neither CMACS_IPC_FD nor CMACS_DBUS_NAME is set "
                     "— not running inside CMacs?");
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
cmacs_gi_transport_free (CmacsGiTransport *t)
{
    if (t == NULL)
        return;

    if (t->kind == TRANSPORT_DBUS && t->u.proxy != NULL)
        g_object_unref (t->u.proxy);
    /* Note: we do NOT close the fd — it belongs to the environment. */

    g_free (t);
}

GVariant *
cmacs_gi_transport_call (CmacsGiTransport *t, const gchar *method,
                         GVariant *params, GError **error)
{
    if (t->kind == TRANSPORT_FD)
        return fd_transport_call (t, method, params, error);

    /* D-Bus path */
    return g_dbus_proxy_call_sync (t->u.proxy, method, params,
                                   G_DBUS_CALL_FLAGS_NONE, -1,
                                   NULL, error);
}
