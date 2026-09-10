/* Clawtilla fleet client for CMacs -- transport.

Copyright (C) 2026 Zach Podbielniak

This file is part of CMacs.

CMacs is free software: you can redistribute it and/or modify it under
the terms of the GNU Affero General Public License as published by the
Free Software Foundation, either version 3 of the License, or (at your
option) any later version.

CMacs is distributed in the hope that it will be useful, but WITHOUT ANY
WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS
FOR A PARTICULAR PURPOSE.  See the GNU Affero General Public License for
more details.

You should have received a copy of the GNU Affero General Public License
along with CMacs.  If not, see <https://www.gnu.org/licenses/>.

SPDX-License-Identifier: AGPL-3.0-or-later  */

#include <config.h>

#ifdef HAVE_CMACS_CLAWTILLA

/* This translation unit must not see lisp.h.  See cmacs-clawtilla.h.  */
#include <clawtilla.h>
#include <glib.h>
#include <json-glib/json-glib.h>

#include "cmacs-clawtilla.h"

/* ------------------------------------------------------------------
   Connections, by handle.

   The table owns a ref on each ClawtClient.  A handle is never reused:
   `next_handle' only increases, so a reply that arrives for a
   connection Lisp already closed finds nothing rather than finding
   whatever took its place.
   ------------------------------------------------------------------ */

typedef struct
{
  uint64_t     handle;
  ClawtClient *client;
} CmacsClawtConn;

static GHashTable *cmacs_clawt_conns;   /* uint64_t -> CmacsClawtConn * */
static uint64_t    cmacs_clawt_next_handle = 1;

/* A request in flight: which Lisp callback is owed the answer.  */
typedef struct
{
  uint64_t handle;
  uint64_t cookie;
} CmacsClawtCall;

static void
cmacs_clawt_conn_free (gpointer data)
{
  CmacsClawtConn *conn = data;

  if (conn->client != NULL)
    {
      /* Handlers first: disconnecting emits `disconnected', and a
         delivery into Lisp from inside teardown would run against a
         handle the table is in the middle of removing.  */
      g_signal_handlers_disconnect_by_data (conn->client, conn);
      clawt_client_set_auto_reconnect (conn->client, FALSE);
      clawt_client_disconnect (conn->client);
      g_clear_object (&conn->client);
    }

  g_free (conn);
}

void
cmacs_clawt_init (void)
{
  if (cmacs_clawt_conns != NULL)
    return;

  cmacs_clawt_conns = g_hash_table_new_full (g_int64_hash, g_int64_equal,
                                             g_free, cmacs_clawt_conn_free);
}

static CmacsClawtConn *
cmacs_clawt_lookup (uint64_t handle)
{
  if (cmacs_clawt_conns == NULL)
    return NULL;

  return g_hash_table_lookup (cmacs_clawt_conns, &handle);
}

static ClawtClient *
cmacs_clawt_client (uint64_t handle)
{
  CmacsClawtConn *conn = cmacs_clawt_lookup (handle);

  return conn != NULL ? conn->client : NULL;
}

/* ------------------------------------------------------------------
   Marshalling.

   Only strings cross into the DEFUN half, so a JsonNode is serialised
   here and parsed by `json-parse-string' there.  That keeps json-glib
   entirely on this side and means a malformed reply is a Lisp error at
   a point Lisp can catch, rather than a CRITICAL in a GLib callback
   where signalling would abort Emacs instead of unwinding.
   ------------------------------------------------------------------ */

static char *
cmacs_clawt_node_to_json (JsonNode *node)
{
  g_autoptr (JsonGenerator) generator = NULL;

  if (node == NULL)
    return g_strdup ("{}");

  generator = json_generator_new ();
  json_generator_set_root (generator, node);

  return json_generator_to_data (generator, NULL);
}

static JsonNode *
cmacs_clawt_json_to_node (const char *json)
{
  g_autoptr (JsonParser) parser = NULL;
  g_autoptr (GError) error = NULL;

  if (json == NULL || *json == '\0')
    return NULL;

  parser = json_parser_new ();

  if (!json_parser_load_from_data (parser, json, -1, &error))
    return NULL;

  return json_node_copy (json_parser_get_root (parser));
}

/* ------------------------------------------------------------------
   Events and connection state, pushed at Lisp.
   ------------------------------------------------------------------ */

static void
cmacs_clawt_on_event (ClawtClient *client, JsonNode *event, gpointer data)
{
  CmacsClawtConn *conn = data;
  g_autofree char *json = NULL;
  const char *kind = "";
  JsonObject *object;

  (void) client;

  json = cmacs_clawt_node_to_json (event);

  if (event != NULL && JSON_NODE_HOLDS_OBJECT (event))
    {
      /* json_node_get_object() answers NULL for a node built as an
         object and left empty, so the member is asked for only after
         the object itself is known to be there -- the same trap the
         daemon's empty replies set for every client.  */
      object = json_node_get_object (event);

      if (object != NULL && json_object_has_member (object, "kind"))
        kind = json_object_get_string_member (object, "kind");
    }

  cmacs_clawt_deliver_event (conn->handle, kind, json);
}

static void
cmacs_clawt_on_connected (ClawtClient *client, gpointer data)
{
  CmacsClawtConn *conn = data;

  (void) client;
  cmacs_clawt_deliver_state (conn->handle, "connected");
}

static void
cmacs_clawt_on_disconnected (ClawtClient *client, gpointer data)
{
  CmacsClawtConn *conn = data;

  (void) client;
  cmacs_clawt_deliver_state (conn->handle, "disconnected");
}

static void
cmacs_clawt_on_resync (ClawtClient *client, gpointer data)
{
  CmacsClawtConn *conn = data;

  (void) client;

  /* A resync means the event stream has a gap in it: the cursor could
     not be resumed, so anything cached from before is suspect and the
     client has to refetch rather than append.  */
  cmacs_clawt_deliver_state (conn->handle, "resync");
}

/* ------------------------------------------------------------------
   Connecting.  Always async: the blocking form turns the caller's main
   context, and here that context is the editor's -- and under `--gowl'
   the compositor's.
   ------------------------------------------------------------------ */

static void
cmacs_clawt_on_connect_done (GObject *source, GAsyncResult *result,
                             gpointer data)
{
  CmacsClawtCall *call = data;
  g_autoptr (GError) error = NULL;

  if (clawt_client_connect_finish (CLAWT_CLIENT (source), result, &error))
    cmacs_clawt_deliver_reply (call->cookie, "{}", NULL);
  else
    cmacs_clawt_deliver_reply (call->cookie, NULL,
                               error != NULL ? error->message
                                             : "the connection failed");

  g_free (call);
}

static uint64_t
cmacs_clawt_adopt (ClawtClient *client, uint64_t cookie)
{
  CmacsClawtConn *conn;
  CmacsClawtCall *call;
  uint64_t *key;

  cmacs_clawt_init ();

  conn = g_new0 (CmacsClawtConn, 1);
  conn->handle = cmacs_clawt_next_handle++;
  conn->client = client;

  g_signal_connect (client, "event", G_CALLBACK (cmacs_clawt_on_event), conn);
  g_signal_connect (client, "connected",
                    G_CALLBACK (cmacs_clawt_on_connected), conn);
  g_signal_connect (client, "disconnected",
                    G_CALLBACK (cmacs_clawt_on_disconnected), conn);
  g_signal_connect (client, "resync", G_CALLBACK (cmacs_clawt_on_resync),
                    conn);

  key = g_new (uint64_t, 1);
  *key = conn->handle;
  g_hash_table_insert (cmacs_clawt_conns, key, conn);

  call = g_new0 (CmacsClawtCall, 1);
  call->handle = conn->handle;
  call->cookie = cookie;

  clawt_client_connect_async (client, NULL, cmacs_clawt_on_connect_done,
                              call);

  return conn->handle;
}

uint64_t
cmacs_clawt_connect_local (const char *socket_path, uint64_t cookie)
{
  g_autofree char *resolved = NULL;
  ClawtClient *client;

  if (socket_path == NULL || *socket_path == '\0')
    {
      resolved = clawt_client_default_socket_path ();
      socket_path = resolved;
    }

  client = clawt_client_new (socket_path);

  if (client == NULL)
    return 0;

  return cmacs_clawt_adopt (client, cookie);
}

uint64_t
cmacs_clawt_connect_tcp (const char *host, int port, const char *token,
                         bool tls, bool accept_unknown_certificate,
                         uint64_t cookie)
{
  ClawtClient *client;

  if (host == NULL || *host == '\0' || port <= 0 || port > 65535)
    return 0;

  client = clawt_client_new_tcp (host, (guint16) port, token);

  if (client == NULL)
    return 0;

  if (tls)
    clawt_client_set_tls (client, TRUE, accept_unknown_certificate);

  return cmacs_clawt_adopt (client, cookie);
}

/* ------------------------------------------------------------------
   Requests.
   ------------------------------------------------------------------ */

static void
cmacs_clawt_on_request_done (GObject *source, GAsyncResult *result,
                             gpointer data)
{
  CmacsClawtCall *call = data;
  g_autoptr (JsonNode) reply = NULL;
  g_autoptr (GError) error = NULL;
  g_autofree char *json = NULL;

  reply = clawt_client_request_finish (CLAWT_CLIENT (source), result, &error);

  if (reply == NULL)
    cmacs_clawt_deliver_reply (call->cookie, NULL,
                               error != NULL ? error->message
                                             : "the request failed");
  else
    {
      json = cmacs_clawt_node_to_json (reply);
      cmacs_clawt_deliver_reply (call->cookie, json, NULL);
    }

  g_free (call);
}

bool
cmacs_clawt_request (uint64_t handle, const char *kind,
                     const char *payload_json, uint64_t cookie)
{
  ClawtClient *client = cmacs_clawt_client (handle);
  CmacsClawtCall *call;
  JsonNode *payload;

  if (client == NULL || kind == NULL || *kind == '\0')
    return false;

  payload = cmacs_clawt_json_to_node (payload_json);

  call = g_new0 (CmacsClawtCall, 1);
  call->handle = handle;
  call->cookie = cookie;

  /* request_async takes the payload; there is nothing to free here.  */
  clawt_client_request_async (client, kind, payload, NULL,
                              cmacs_clawt_on_request_done, call);

  return true;
}

static void
cmacs_clawt_on_subscribe_done (GObject *source, GAsyncResult *result,
                               gpointer data)
{
  CmacsClawtCall *call = data;
  g_autoptr (GError) error = NULL;
  gboolean resumed = FALSE;

  if (clawt_client_subscribe_finish (CLAWT_CLIENT (source), result, &resumed,
                                     &error))
    {
      g_autofree char *json =
        g_strdup_printf ("{\"resumed\":%s}", resumed ? "true" : "false");

      cmacs_clawt_deliver_reply (call->cookie, json, NULL);
    }
  else
    cmacs_clawt_deliver_reply (call->cookie, NULL,
                               error != NULL ? error->message
                                             : "the subscribe failed");

  g_free (call);
}

bool
cmacs_clawt_subscribe (uint64_t handle, uint64_t cursor, uint64_t cookie)
{
  ClawtClient *client = cmacs_clawt_client (handle);
  CmacsClawtCall *call;

  if (client == NULL)
    return false;

  call = g_new0 (CmacsClawtCall, 1);
  call->handle = handle;
  call->cookie = cookie;

  clawt_client_subscribe_async (client, cursor, NULL,
                                cmacs_clawt_on_subscribe_done, call);

  return true;
}

/* ------------------------------------------------------------------
   Connection state.
   ------------------------------------------------------------------ */

bool
cmacs_clawt_disconnect (uint64_t handle)
{
  ClawtClient *client = cmacs_clawt_client (handle);

  if (client == NULL)
    return false;

  clawt_client_disconnect (client);
  return true;
}

bool
cmacs_clawt_close (uint64_t handle)
{
  if (cmacs_clawt_conns == NULL)
    return false;

  return g_hash_table_remove (cmacs_clawt_conns, &handle) ? true : false;
}

bool
cmacs_clawt_is_connected (uint64_t handle)
{
  ClawtClient *client = cmacs_clawt_client (handle);

  return client != NULL && clawt_client_is_connected (client);
}

bool
cmacs_clawt_is_reconnecting (uint64_t handle)
{
  ClawtClient *client = cmacs_clawt_client (handle);

  return client != NULL && clawt_client_is_reconnecting (client);
}

bool
cmacs_clawt_set_auto_reconnect (uint64_t handle, bool enabled)
{
  ClawtClient *client = cmacs_clawt_client (handle);

  if (client == NULL)
    return false;

  clawt_client_set_auto_reconnect (client, enabled ? TRUE : FALSE);
  return true;
}

uint64_t
cmacs_clawt_cursor (uint64_t handle)
{
  ClawtClient *client = cmacs_clawt_client (handle);

  return client != NULL ? clawt_client_get_cursor (client) : 0;
}

void
cmacs_clawt_free (char *text)
{
  g_free (text);
}

char *
cmacs_clawt_default_socket_path (void)
{
  return clawt_client_default_socket_path ();
}

char *
cmacs_clawt_handle_list_json (void)
{
  g_autoptr (JsonBuilder) builder = json_builder_new ();
  g_autoptr (JsonNode) root = NULL;
  GHashTableIter iter;
  gpointer value;

  json_builder_begin_array (builder);

  if (cmacs_clawt_conns != NULL)
    {
      g_hash_table_iter_init (&iter, cmacs_clawt_conns);

      while (g_hash_table_iter_next (&iter, NULL, &value))
        {
          CmacsClawtConn *conn = value;

          json_builder_begin_object (builder);
          json_builder_set_member_name (builder, "handle");
          json_builder_add_int_value (builder, (gint64) conn->handle);
          json_builder_set_member_name (builder, "connected");
          json_builder_add_boolean_value (
            builder, clawt_client_is_connected (conn->client));
          json_builder_set_member_name (builder, "reconnecting");
          json_builder_add_boolean_value (
            builder, clawt_client_is_reconnecting (conn->client));
          json_builder_set_member_name (builder, "cursor");
          json_builder_add_int_value (
            builder, (gint64) clawt_client_get_cursor (conn->client));
          json_builder_end_object (builder);
        }
    }

  json_builder_end_array (builder);
  root = json_builder_get_root (builder);

  return cmacs_clawt_node_to_json (root);
}


/* ------------------------------------------------------------------
   The library's own enumerations, walked.

   Every one of these exists so a client can offer a set of values
   without naming them, and clawtilla's `make parity' fails a client
   that spells any of the values out: having the list is what makes a
   client able to disagree with it.  So cmacs asks for them here and
   the elisp side renders whatever comes back -- a palette added to
   libclawt appears in the picker with no change on this side.

   There is deliberately no flat "page" family.  clawtilla ships
   clawt_page_count() without a clawt_page_nth() beside it precisely
   because a flat list of eleven pages is not something anyone chooses
   between: a page is reached through its section, so "section" carries
   its pages and that is the only way to walk them.

   Each family answers an array of objects with at least `nick' and
   `label'.  The extra members are the questions a client has to ask
   to draw the thing at all: whether a computer type has a screen
   decides whether the Screen view is offered, and a client that
   guessed would be a copy of the table by another name.
   ------------------------------------------------------------------ */

typedef guint (*CmacsClawtCountFn) (void);
typedef const gchar *(*CmacsClawtNthFn) (guint n);

static void
cmacs_clawt_enum_simple (JsonBuilder *builder, CmacsClawtCountFn count,
                         CmacsClawtNthFn nick, CmacsClawtNthFn label)
{
  guint n;
  guint total = count ();

  for (n = 0; n < total; n++)
    {
      const gchar *nick_text = nick (n);
      const gchar *label_text = label != NULL ? label (n) : NULL;

      json_builder_begin_object (builder);
      json_builder_set_member_name (builder, "nick");
      json_builder_add_string_value (builder, nick_text);
      json_builder_set_member_name (builder, "label");
      json_builder_add_string_value (builder,
                                     label_text != NULL ? label_text
                                                        : nick_text);
      json_builder_end_object (builder);
    }
}

static void
cmacs_clawt_enum_sections (JsonBuilder *builder)
{
  guint n;
  guint total = clawt_section_count ();

  for (n = 0; n < total; n++)
    {
      ClawtSection section = clawt_section_nth (n);
      guint pages = clawt_section_page_count (section);
      guint p;

      json_builder_begin_object (builder);
      json_builder_set_member_name (builder, "nick");
      json_builder_add_string_value (builder, clawt_section_nick (section));
      json_builder_set_member_name (builder, "label");
      json_builder_add_string_value (builder, clawt_section_label (section));

      /* The default page matters: a section with more than one page is
         opened on a particular one, and which is the library's call.  */
      json_builder_set_member_name (builder, "default-page");
      json_builder_add_string_value (
        builder, clawt_page_nick (clawt_section_default_page (section)));

      json_builder_set_member_name (builder, "pages");
      json_builder_begin_array (builder);

      for (p = 0; p < pages; p++)
        {
          ClawtPage page = clawt_section_page_nth (section, p);

          json_builder_begin_object (builder);
          json_builder_set_member_name (builder, "nick");
          json_builder_add_string_value (builder, clawt_page_nick (page));
          json_builder_set_member_name (builder, "label");
          json_builder_add_string_value (builder, clawt_page_label (page));
          json_builder_end_object (builder);
        }

      json_builder_end_array (builder);
      json_builder_end_object (builder);
    }
}

static void
cmacs_clawt_enum_computer_types (JsonBuilder *builder)
{
  guint n;
  guint total = clawt_computer_type_count ();

  for (n = 0; n < total; n++)
    {
      ClawtComputerType type = clawt_computer_type_nth (n);

      json_builder_begin_object (builder);
      json_builder_set_member_name (builder, "nick");
      json_builder_add_string_value (builder,
                                     clawt_computer_type_nth_nick (n));
      json_builder_set_member_name (builder, "label");
      json_builder_add_string_value (builder,
                                     clawt_computer_type_nth_label (n));
      json_builder_set_member_name (builder, "machine");
      json_builder_add_boolean_value (builder,
                                      clawt_computer_type_has_machine (type));
      json_builder_set_member_name (builder, "screen");
      json_builder_add_boolean_value (builder,
                                      clawt_computer_type_has_screen (type));
      json_builder_set_member_name (builder, "image");
      json_builder_add_boolean_value (builder,
                                      clawt_computer_type_takes_image (type));
      json_builder_set_member_name (builder, "mounts");
      json_builder_add_boolean_value (
        builder, clawt_computer_type_takes_mounts (type));
      json_builder_set_member_name (builder, "shares-host-paths");
      json_builder_add_boolean_value (
        builder, clawt_computer_type_shares_host_paths (type));
      json_builder_end_object (builder);
    }
}

static void
cmacs_clawt_enum_measure_units (JsonBuilder *builder)
{
  guint n;
  guint total = clawt_measure_unit_count ();

  for (n = 0; n < total; n++)
    {
      ClawtMeasureUnit unit = clawt_measure_unit_nth (n);

      json_builder_begin_object (builder);
      json_builder_set_member_name (builder, "nick");
      json_builder_add_string_value (builder,
                                     clawt_measure_unit_nick (unit));
      json_builder_set_member_name (builder, "label");
      json_builder_add_string_value (builder,
                                     clawt_measure_unit_label (unit));
      json_builder_set_member_name (builder, "min");
      json_builder_add_int_value (builder, clawt_measure_unit_min (unit));
      json_builder_set_member_name (builder, "max");
      json_builder_add_int_value (builder, clawt_measure_unit_max (unit));
      json_builder_set_member_name (builder, "step");
      json_builder_add_int_value (builder, clawt_measure_unit_step (unit));
      json_builder_set_member_name (builder, "preset");
      json_builder_add_int_value (builder, clawt_measure_unit_preset (unit));
      json_builder_end_object (builder);
    }
}

static void
cmacs_clawt_enum_themes (JsonBuilder *builder)
{
  guint n;
  guint total = clawt_appearance_theme_count ();

  for (n = 0; n < total; n++)
    {
      ClawtTheme theme = clawt_appearance_theme_nth (n);

      json_builder_begin_object (builder);
      json_builder_set_member_name (builder, "nick");
      json_builder_add_string_value (builder,
                                     clawt_appearance_theme_nick (theme));
      json_builder_set_member_name (builder, "label");
      json_builder_add_string_value (builder,
                                     clawt_appearance_theme_label (theme));
      json_builder_set_member_name (builder, "dark");
      json_builder_add_boolean_value (builder,
                                      clawt_appearance_theme_is_dark (theme));
      json_builder_set_member_name (builder, "palette");
      json_builder_add_boolean_value (
        builder, clawt_appearance_theme_has_palette (theme));
      json_builder_end_object (builder);
    }
}

static void
cmacs_clawt_enum_import_modes (JsonBuilder *builder)
{
  guint n;
  guint total = clawt_import_mode_count ();

  for (n = 0; n < total; n++)
    {
      ClawtImportMode mode = clawt_import_mode_nth (n);

      json_builder_begin_object (builder);
      json_builder_set_member_name (builder, "nick");
      json_builder_add_string_value (builder,
                                     clawt_import_mode_nth_nick (n));
      json_builder_set_member_name (builder, "label");
      json_builder_add_string_value (builder,
                                     clawt_import_mode_nth_label (n));
      json_builder_set_member_name (builder, "url");
      json_builder_add_boolean_value (builder,
                                      clawt_import_mode_takes_url (mode));
      json_builder_end_object (builder);
    }
}

char *
cmacs_clawt_enum_json (const char *family)
{
  g_autoptr (JsonBuilder) builder = json_builder_new ();
  g_autoptr (JsonNode) root = NULL;

  if (family == NULL)
    return NULL;

  json_builder_begin_array (builder);

  if (g_str_equal (family, "section"))
    cmacs_clawt_enum_sections (builder);
  else if (g_str_equal (family, "computer-type"))
    cmacs_clawt_enum_computer_types (builder);
  else if (g_str_equal (family, "computer-view"))
    cmacs_clawt_enum_simple (builder, clawt_computer_view_count,
                             clawt_computer_view_nth_nick,
                             clawt_computer_view_nth_label);
  else if (g_str_equal (family, "import-mode"))
    cmacs_clawt_enum_import_modes (builder);
  else if (g_str_equal (family, "measure-unit"))
    cmacs_clawt_enum_measure_units (builder);
  else if (g_str_equal (family, "memory-scope"))
    cmacs_clawt_enum_simple (builder, clawt_memory_scope_count,
                             clawt_memory_scope_nth_nick,
                             clawt_memory_scope_nth_label);
  else if (g_str_equal (family, "appearance-scheme"))
    cmacs_clawt_enum_simple (builder, clawt_appearance_scheme_count,
                             clawt_appearance_scheme_nth_nick,
                             clawt_appearance_scheme_nth_label);
  else if (g_str_equal (family, "appearance-theme"))
    cmacs_clawt_enum_themes (builder);
  else if (g_str_equal (family, "relabel"))
    cmacs_clawt_enum_simple (builder, clawt_relabel_count,
                             clawt_relabel_nth_nick, clawt_relabel_nth_label);
  else
    return NULL;

  json_builder_end_array (builder);
  root = json_builder_get_root (builder);

  return cmacs_clawt_node_to_json (root);
}


/* ------------------------------------------------------------------
   Saved connections.

   clawtilla keeps these in ~/.config/clawtilla/connections.yaml and
   every one of its clients reads that file.  cmacs reads the same one
   through the same functions rather than parsing the YAML itself: a
   profile added in the GTK client is then simply there, and the advice
   shown when a daemon cannot be reached is the identical sentence in
   all three clients rather than three that drifted.
   ------------------------------------------------------------------ */

static void
cmacs_clawt_connection_to_json (JsonBuilder *builder, ClawtConnection *conn)
{
  gboolean local = clawt_connection_is_local (conn);
  g_autofree gchar *described = clawt_connection_describe (conn);

  json_builder_begin_object (builder);
  json_builder_set_member_name (builder, "name");
  json_builder_add_string_value (builder, clawt_connection_get_name (conn));
  json_builder_set_member_name (builder, "local");
  json_builder_add_boolean_value (builder, local);

  /* The description is asked for, not assembled here: it is what hides
     the token, and a second version of that logic is a second chance to
     print one.  */
  json_builder_set_member_name (builder, "describe");
  json_builder_add_string_value (builder, described);

  if (local)
    {
      json_builder_set_member_name (builder, "socket");
      json_builder_add_string_value (builder,
                                     clawt_connection_get_socket_path (conn));
    }
  else
    {
      json_builder_set_member_name (builder, "host");
      json_builder_add_string_value (builder,
                                     clawt_connection_get_host (conn));
      json_builder_set_member_name (builder, "port");
      json_builder_add_int_value (builder, clawt_connection_get_port (conn));
      json_builder_set_member_name (builder, "tls");
      json_builder_add_boolean_value (builder,
                                      clawt_connection_get_tls (conn));
      json_builder_set_member_name (builder, "insecure");
      json_builder_add_boolean_value (
        builder, clawt_connection_get_accept_unknown_certificate (conn));
    }

  json_builder_end_object (builder);
}

char *
cmacs_clawt_connections_path (void)
{
  return clawt_connection_list_default_path ();
}

char *
cmacs_clawt_connections_json (const char *path, char **error)
{
  g_autofree gchar *resolved = NULL;
  g_autoptr (GPtrArray) list = NULL;
  g_autoptr (JsonBuilder) builder = json_builder_new ();
  g_autoptr (JsonNode) root = NULL;
  g_autoptr (GError) local_error = NULL;
  guint i;

  if (path == NULL || *path == '\0')
    {
      resolved = clawt_connection_list_default_path ();
      path = resolved;
    }

  list = clawt_connection_list_load (path, &local_error);

  if (list == NULL)
    {
      /* A missing file is an empty list, not a failure: nobody has
         saved a profile yet, which is the ordinary first run.  */
      if (local_error != NULL && error != NULL)
        *error = g_strdup (local_error->message);

      return NULL;
    }

  json_builder_begin_array (builder);

  for (i = 0; i < list->len; i++)
    cmacs_clawt_connection_to_json (builder,
                                    g_ptr_array_index (list, i));

  json_builder_end_array (builder);
  root = json_builder_get_root (builder);

  return cmacs_clawt_node_to_json (root);
}

uint64_t
cmacs_clawt_connect_profile (const char *path, const char *name,
                             uint64_t cookie, char **error)
{
  g_autofree gchar *resolved = NULL;
  g_autoptr (GPtrArray) list = NULL;
  g_autoptr (GError) local_error = NULL;
  ClawtConnection *found;
  ClawtClient *client;

  if (path == NULL || *path == '\0')
    {
      resolved = clawt_connection_list_default_path ();
      path = resolved;
    }

  list = clawt_connection_list_load (path, &local_error);

  if (list == NULL)
    {
      if (error != NULL)
        *error = g_strdup (local_error != NULL ? local_error->message
                                               : "no saved connections");
      return 0;
    }

  found = clawt_connection_list_find (list, name);

  if (found == NULL)
    {
      if (error != NULL)
        *error = g_strdup_printf ("there is no saved connection called '%s'",
                                  name);
      return 0;
    }

  /* create_client() is what turns a profile into the right kind of
     client -- unix or TCP, with the token and the TLS decision already
     applied.  Rebuilding that here would be a second place for the two
     to disagree about what a profile means.  */
  client = clawt_connection_create_client (found);

  if (client == NULL)
    {
      if (error != NULL)
        *error = g_strdup ("that connection could not be opened");
      return 0;
    }

  return cmacs_clawt_adopt (client, cookie);
}

char *
cmacs_clawt_link_notice (uint64_t handle, const char *name,
                         bool ever_connected)
{
  g_autofree gchar *path = clawt_connection_list_default_path ();
  g_autoptr (GPtrArray) list = NULL;
  ClawtConnection *found = NULL;
  ClawtClient *client = cmacs_clawt_client (handle);
  ClawtDaemonLink link;

  list = clawt_connection_list_load (path, NULL);

  if (list != NULL && name != NULL)
    found = clawt_connection_list_find (list, name);

  /* `ever_connected' is the whole discriminator between NEVER and LOST,
     and it is the caller's to remember: the client object cannot tell
     them apart after it has been disconnected.  */
  link = clawt_daemon_link_state (client, ever_connected ? TRUE : FALSE);

  return clawt_connection_notice_text (link, found, NULL, NULL);
}

#endif /* HAVE_CMACS_CLAWTILLA */
