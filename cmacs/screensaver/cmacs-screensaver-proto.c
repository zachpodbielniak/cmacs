/* cmacs-screensaver-proto.c --- shared wire/shm protocol implementation.
 *
 * Copyright (C) 2026 Zach Podbielniak
 * SPDX-License-Identifier: AGPL-3.0-or-later
 *
 * See cmacs-screensaver-proto.h for the design.  Pure C (glib + json-glib);
 * compiled into both the Emacs binary and the cmacs-screensaver-render child. */

/* config.h MUST come first: when this file is compiled into Emacs, gnulib's
 * header overrides (in ../lib) error out unless config.h was included first.
 * The standalone consumers (the cmacs-screensaver-render child and the GTest
 * suite) put a minimal shim config.h first on their -I path. */
#include <config.h>

#include "cmacs-screensaver-proto.h"

#include <json-glib/json-glib.h>
#include <string.h>

/* ---- atomics ------------------------------------------------------------- */
/* Plain integer fields accessed with the GCC/Clang __atomic builtins so the
 * header stays a fixed-layout POD shared across the process boundary. */

#define SCR_LOAD_ACQ(p)     __atomic_load_n ((p), __ATOMIC_ACQUIRE)
#define SCR_STORE_REL(p, v) __atomic_store_n ((p), (v), __ATOMIC_RELEASE)
#define SCR_FENCE_REL()     __atomic_thread_fence (__ATOMIC_RELEASE)
#define SCR_FENCE_ACQ()     __atomic_thread_fence (__ATOMIC_ACQUIRE)

/* ---- shared-memory frame ring ------------------------------------------- */

gboolean
scr_shm_dims_valid (uint32_t w, uint32_t h)
{
  return w > 0 && h > 0 && w <= SCR_SHM_MAX_DIM && h <= SCR_SHM_MAX_DIM;
}

gsize
scr_shm_total_size (uint32_t w, uint32_t h)
{
  guint64 stride, slot, total;

  if (!scr_shm_dims_valid (w, h))
    return 0;

  /* w <= 16384 so w*4 cannot overflow 32 bits; promote to 64 for the products
   * anyway and bound the final size well under SIZE_MAX. */
  stride = (guint64) w * 4u;
  slot = stride * (guint64) h;                       /* <= 16384*4*16384 = 1 GiB */
  total = (guint64) sizeof (ScrShmHeader)
          + slot * (guint64) SCR_SHM_N_SLOTS;        /* <= ~3 GiB */
  if (total > (guint64) (4096ull * 1024ull * 1024ull))
    return 0;                                        /* refuse absurd buffers */
  return (gsize) total;
}

void
scr_shm_header_init (void *base, uint32_t w, uint32_t h)
{
  ScrShmHeader *hd = base;
  uint32_t i;

  hd->magic = SCR_SHM_MAGIC;
  hd->version = SCR_SHM_VERSION;
  hd->width = w;
  hd->height = h;
  hd->stride = w * 4u;
  hd->n_slots = SCR_SHM_N_SLOTS;
  hd->slot_bytes = (uint64_t) hd->stride * (uint64_t) h;
  hd->pixels_off = (uint64_t) sizeof (ScrShmHeader);
  hd->generation = 0;
  for (i = 0; i < SCR_SHM_N_SLOTS; i++)
    hd->seq[i] = 0;
  /* Publish `latest' last so a reader that races init sees SENTINEL, not a
   * half-initialised header. */
  SCR_FENCE_REL ();
  SCR_STORE_REL (&hd->latest, SCR_SHM_SENTINEL);
}

gboolean
scr_shm_header_validate (const void *base, uint32_t expect_w, uint32_t expect_h)
{
  const ScrShmHeader *hd = base;

  if (hd->magic != SCR_SHM_MAGIC || hd->version != SCR_SHM_VERSION)
    return FALSE;
  if (hd->n_slots != SCR_SHM_N_SLOTS)
    return FALSE;
  if (!scr_shm_dims_valid (hd->width, hd->height))
    return FALSE;
  if (hd->stride != hd->width * 4u
      || hd->slot_bytes != (uint64_t) hd->stride * (uint64_t) hd->height
      || hd->pixels_off != (uint64_t) sizeof (ScrShmHeader))
    return FALSE;
  if (expect_w != 0 && hd->width != expect_w)
    return FALSE;
  if (expect_h != 0 && hd->height != expect_h)
    return FALSE;
  return TRUE;
}

void *
scr_shm_slot_ptr (void *base, uint32_t idx)
{
  ScrShmHeader *hd = base;
  return (guint8 *) base + hd->pixels_off + (gsize) idx * (gsize) hd->slot_bytes;
}

uint32_t
scr_shm_writer_pick (const void *base, uint32_t last_written)
{
  const ScrShmHeader *hd = base;
  uint32_t latest = SCR_LOAD_ACQ (&hd->latest);
  uint32_t i;

  for (i = 0; i < SCR_SHM_N_SLOTS; i++)
    if (i != latest && i != last_written)
      return i;
  /* Only reachable if last_written == latest (e.g. first frame); any slot but
   * latest is fine. */
  for (i = 0; i < SCR_SHM_N_SLOTS; i++)
    if (i != latest)
      return i;
  return 0;
}

void *
scr_shm_write_begin (void *base, uint32_t idx)
{
  ScrShmHeader *hd = base;
  uint32_t s = hd->seq[idx];

  /* Make the slot's seq odd ("write in progress") before touching pixels. */
  SCR_STORE_REL (&hd->seq[idx], s | 1u);
  SCR_FENCE_REL ();
  return scr_shm_slot_ptr (base, idx);
}

void
scr_shm_write_commit (void *base, uint32_t idx)
{
  ScrShmHeader *hd = base;
  uint32_t s = hd->seq[idx];

  /* Even again: pixels are complete and visible (release). */
  SCR_FENCE_REL ();
  SCR_STORE_REL (&hd->seq[idx], (s + 1u) & ~1u);
  SCR_STORE_REL (&hd->latest, idx);
  SCR_STORE_REL (&hd->generation, hd->generation + 1u);
}

void
scr_shm_write_abort (void *base, uint32_t idx)
{
  ScrShmHeader *hd = base;
  uint32_t s = hd->seq[idx];

  /* s is odd (write in progress); drop the low bit back to the prior even value
   * -- no new frame is published, so latest/generation stay put. */
  SCR_STORE_REL (&hd->seq[idx], s & ~1u);
}

gboolean
scr_shm_read_acquire (const void *base, ScrShmFrame *out)
{
  const ScrShmHeader *hd = base;
  uint32_t idx, s;

  out->pixels = NULL;
  idx = SCR_LOAD_ACQ (&hd->latest);
  if (idx == SCR_SHM_SENTINEL || idx >= SCR_SHM_N_SLOTS)
    return FALSE;
  s = SCR_LOAD_ACQ (&hd->seq[idx]);
  if (s & 1u)
    return FALSE;            /* writer mid-write -- skip, never spin */

  out->idx = idx;
  out->seq = s;
  out->generation = SCR_LOAD_ACQ (&hd->generation);
  out->pixels = (const guint8 *) base + hd->pixels_off
                + (gsize) idx * (gsize) hd->slot_bytes;
  return TRUE;
}

gboolean
scr_shm_read_verify (const void *base, const ScrShmFrame *f)
{
  const ScrShmHeader *hd = base;
  uint32_t s2;

  SCR_FENCE_ACQ ();
  s2 = SCR_LOAD_ACQ (&hd->seq[f->idx]);
  return s2 == f->seq;       /* unchanged & even => the slot did not tear */
}

/* ---- JSON helpers -------------------------------------------------------- */

/* Parse JSON into a root object.  Returns the JsonParser (transfer full) with
 * *OBJ set to the borrowed root object, or NULL on any error. */
static JsonParser *
proto_parse_object (const gchar *json, gssize len, JsonObject **obj)
{
  JsonParser *parser = json_parser_new ();
  JsonNode *root;

  if (json == NULL
      || !json_parser_load_from_data (parser, json, len, NULL))
    {
      g_object_unref (parser);
      return NULL;
    }
  root = json_parser_get_root (parser);
  if (root == NULL || !JSON_NODE_HOLDS_OBJECT (root))
    {
      g_object_unref (parser);
      return NULL;
    }
  *obj = json_node_get_object (root);
  return parser;
}

static const gchar *
proto_get_string (JsonObject *o, const gchar *member)
{
  if (!json_object_has_member (o, member))
    return NULL;
  return json_object_get_string_member (o, member);
}

/* json-glib's typed getters g_assert when a member is absent; these tolerate
 * missing fields (partial / malformed input) and return a default. */
static gint64
proto_get_int (JsonObject *o, const gchar *member)
{
  if (!json_object_has_member (o, member))
    return 0;
  return json_object_get_int_member (o, member);
}

static gboolean
proto_get_bool (JsonObject *o, const gchar *member)
{
  if (!json_object_has_member (o, member))
    return FALSE;
  return json_object_get_boolean_member (o, member);
}

static gboolean
proto_type_is (JsonObject *o, const gchar *type)
{
  const gchar *t = proto_get_string (o, "t");
  return t != NULL && g_strcmp0 (t, type) == 0;
}

/* Serialise a JsonBuilder's current object to a compact string (g_free). */
static gchar *
proto_builder_to_string (JsonBuilder *b)
{
  JsonGenerator *gen = json_generator_new ();
  JsonNode *root = json_builder_get_root (b);
  gchar *out;

  json_generator_set_root (gen, root);
  out = json_generator_to_data (gen, NULL);
  json_node_unref (root);
  g_object_unref (gen);
  return out;
}

gchar *
scr_proto_message_type (const gchar *json, gssize len)
{
  JsonObject *o;
  JsonParser *p = proto_parse_object (json, len, &o);
  const gchar *t;
  gchar *out;

  if (p == NULL)
    return NULL;
  t = proto_get_string (o, "t");
  out = t ? g_strdup (t) : NULL;
  g_object_unref (p);
  return out;
}

/* ---- set-target ---------------------------------------------------------- */

void
scr_set_target_clear (ScrSetTarget *t)
{
  if (t == NULL)
    return;
  g_clear_pointer (&t->mon, g_free);
  g_clear_pointer (&t->so, g_free);
  g_clear_pointer (&t->args, g_strfreev);
  memset (t, 0, sizeof *t);
}

gchar *
scr_proto_build_set_target (const ScrSetTarget *t)
{
  JsonBuilder *b = json_builder_new ();
  gchar *out;

  json_builder_begin_object (b);
  json_builder_set_member_name (b, "t");
  json_builder_add_string_value (b, SCR_MSG_SET_TARGET);
  json_builder_set_member_name (b, "sink");
  json_builder_add_int_value (b, t->sink);
  json_builder_set_member_name (b, "mon");
  json_builder_add_string_value (b, t->mon ? t->mon : "");
  json_builder_set_member_name (b, "so");
  json_builder_add_string_value (b, t->so ? t->so : "");
  json_builder_set_member_name (b, "w");
  json_builder_add_int_value (b, t->w);
  json_builder_set_member_name (b, "h");
  json_builder_add_int_value (b, t->h);
  json_builder_set_member_name (b, "covered");
  json_builder_add_boolean_value (b, t->covered);
  json_builder_set_member_name (b, "args");
  json_builder_begin_array (b);
  if (t->args != NULL)
    {
      gchar **a;
      for (a = t->args; *a != NULL; a++)
        json_builder_add_string_value (b, *a);
    }
  json_builder_end_array (b);
  json_builder_end_object (b);

  out = proto_builder_to_string (b);
  g_object_unref (b);
  return out;
}

gboolean
scr_proto_parse_set_target (const gchar *json, gssize len, ScrSetTarget *out)
{
  JsonObject *o;
  JsonParser *p = proto_parse_object (json, len, &o);
  const gchar *mon, *so;

  memset (out, 0, sizeof *out);
  if (p == NULL)
    return FALSE;
  if (!proto_type_is (o, SCR_MSG_SET_TARGET))
    goto fail;

  out->sink = (int) proto_get_int (o, "sink");
  mon = proto_get_string (o, "mon");
  so = proto_get_string (o, "so");
  if (mon == NULL || *mon == '\0' || so == NULL || *so == '\0')
    goto fail;
  out->mon = g_strdup (mon);
  out->so = g_strdup (so);
  out->w = (int) proto_get_int (o, "w");
  out->h = (int) proto_get_int (o, "h");
  out->covered = json_object_has_member (o, "covered")
                 && proto_get_bool (o, "covered");

  if (json_object_has_member (o, "args"))
    {
      JsonArray *arr = json_object_get_array_member (o, "args");
      guint n = arr ? json_array_get_length (arr) : 0;
      GPtrArray *v = g_ptr_array_new ();
      guint i;
      for (i = 0; i < n; i++)
        g_ptr_array_add (v, g_strdup (json_array_get_string_element (arr, i)));
      g_ptr_array_add (v, NULL);
      out->args = (gchar **) g_ptr_array_free (v, FALSE);
    }

  g_object_unref (p);
  return TRUE;

fail:
  g_object_unref (p);
  scr_set_target_clear (out);
  return FALSE;
}

/* ---- frame-buffer -------------------------------------------------------- */

void
scr_frame_buffer_clear (ScrFrameBuffer *t)
{
  if (t == NULL)
    return;
  g_clear_pointer (&t->mon, g_free);
  memset (t, 0, sizeof *t);
}

gchar *
scr_proto_build_frame_buffer (const ScrFrameBuffer *t)
{
  JsonBuilder *b = json_builder_new ();
  gchar *out;

  json_builder_begin_object (b);
  json_builder_set_member_name (b, "t");
  json_builder_add_string_value (b, SCR_MSG_FRAME_BUFFER);
  json_builder_set_member_name (b, "sink");
  json_builder_add_int_value (b, t->sink);
  json_builder_set_member_name (b, "mon");
  json_builder_add_string_value (b, t->mon ? t->mon : "");
  json_builder_set_member_name (b, "w");
  json_builder_add_int_value (b, t->w);
  json_builder_set_member_name (b, "h");
  json_builder_add_int_value (b, t->h);
  json_builder_set_member_name (b, "stride");
  json_builder_add_int_value (b, t->stride);
  json_builder_set_member_name (b, "slots");
  json_builder_add_int_value (b, t->slots);
  json_builder_end_object (b);

  out = proto_builder_to_string (b);
  g_object_unref (b);
  return out;
}

gboolean
scr_proto_parse_frame_buffer (const gchar *json, gssize len, ScrFrameBuffer *out)
{
  JsonObject *o;
  JsonParser *p = proto_parse_object (json, len, &o);
  const gchar *mon;

  memset (out, 0, sizeof *out);
  if (p == NULL)
    return FALSE;
  if (!proto_type_is (o, SCR_MSG_FRAME_BUFFER))
    goto fail;

  out->sink = (int) proto_get_int (o, "sink");
  mon = proto_get_string (o, "mon");
  if (mon == NULL || *mon == '\0')
    goto fail;
  out->mon = g_strdup (mon);
  out->w = (int) proto_get_int (o, "w");
  out->h = (int) proto_get_int (o, "h");
  out->stride = (int) proto_get_int (o, "stride");
  out->slots = (int) proto_get_int (o, "slots");

  g_object_unref (p);
  return TRUE;

fail:
  g_object_unref (p);
  scr_frame_buffer_clear (out);
  return FALSE;
}

/* ---- load-result --------------------------------------------------------- */

void
scr_load_result_clear (ScrLoadResult *t)
{
  if (t == NULL)
    return;
  g_clear_pointer (&t->mon, g_free);
  g_clear_pointer (&t->err, g_free);
  memset (t, 0, sizeof *t);
}

gchar *
scr_proto_build_load_result (const ScrLoadResult *t)
{
  JsonBuilder *b = json_builder_new ();
  gchar *out;

  json_builder_begin_object (b);
  json_builder_set_member_name (b, "t");
  json_builder_add_string_value (b, SCR_MSG_LOAD_RESULT);
  json_builder_set_member_name (b, "sink");
  json_builder_add_int_value (b, t->sink);
  json_builder_set_member_name (b, "mon");
  json_builder_add_string_value (b, t->mon ? t->mon : "");
  json_builder_set_member_name (b, "ok");
  json_builder_add_boolean_value (b, t->ok);
  json_builder_set_member_name (b, "err");
  json_builder_add_string_value (b, t->err ? t->err : "");
  json_builder_end_object (b);

  out = proto_builder_to_string (b);
  g_object_unref (b);
  return out;
}

gboolean
scr_proto_parse_load_result (const gchar *json, gssize len, ScrLoadResult *out)
{
  JsonObject *o;
  JsonParser *p = proto_parse_object (json, len, &o);
  const gchar *mon, *err;

  memset (out, 0, sizeof *out);
  if (p == NULL)
    return FALSE;
  if (!proto_type_is (o, SCR_MSG_LOAD_RESULT))
    goto fail;

  out->sink = (int) proto_get_int (o, "sink");
  mon = proto_get_string (o, "mon");
  out->mon = g_strdup (mon ? mon : "");
  out->ok = json_object_has_member (o, "ok")
            && proto_get_bool (o, "ok");
  err = proto_get_string (o, "err");
  out->err = (err != NULL && *err != '\0') ? g_strdup (err) : NULL;

  g_object_unref (p);
  return TRUE;

fail:
  g_object_unref (p);
  scr_load_result_clear (out);
  return FALSE;
}

/* ---- simple / scalar messages -------------------------------------------- */

gchar *
scr_proto_build_simple (const gchar *type)
{
  JsonBuilder *b = json_builder_new ();
  gchar *out;

  json_builder_begin_object (b);
  json_builder_set_member_name (b, "t");
  json_builder_add_string_value (b, type);
  json_builder_end_object (b);
  out = proto_builder_to_string (b);
  g_object_unref (b);
  return out;
}

static gchar *
proto_build_one_int (const gchar *type, const gchar *member, gint64 value)
{
  JsonBuilder *b = json_builder_new ();
  gchar *out;

  json_builder_begin_object (b);
  json_builder_set_member_name (b, "t");
  json_builder_add_string_value (b, type);
  json_builder_set_member_name (b, member);
  json_builder_add_int_value (b, value);
  json_builder_end_object (b);
  out = proto_builder_to_string (b);
  g_object_unref (b);
  return out;
}

gchar *
scr_proto_build_hello (int version)
{
  return proto_build_one_int (SCR_MSG_HELLO, "version", version);
}

gchar *
scr_proto_build_set_fps (int fps)
{
  return proto_build_one_int (SCR_MSG_SET_FPS, "fps", fps);
}

gchar *
scr_proto_build_heartbeat (gint64 seq)
{
  return proto_build_one_int (SCR_MSG_HEARTBEAT, "seq", seq);
}

gchar *
scr_proto_build_pause (gboolean paused)
{
  JsonBuilder *b = json_builder_new ();
  gchar *out;

  json_builder_begin_object (b);
  json_builder_set_member_name (b, "t");
  json_builder_add_string_value (b, SCR_MSG_PAUSE);
  json_builder_set_member_name (b, "paused");
  json_builder_add_boolean_value (b, paused);
  json_builder_end_object (b);
  out = proto_builder_to_string (b);
  g_object_unref (b);
  return out;
}

gchar *
scr_proto_build_remove_target (int sink, const gchar *mon)
{
  JsonBuilder *b = json_builder_new ();
  gchar *out;

  json_builder_begin_object (b);
  json_builder_set_member_name (b, "t");
  json_builder_add_string_value (b, SCR_MSG_REMOVE_TARGET);
  json_builder_set_member_name (b, "sink");
  json_builder_add_int_value (b, sink);
  json_builder_set_member_name (b, "mon");
  json_builder_add_string_value (b, mon ? mon : "");
  json_builder_end_object (b);
  out = proto_builder_to_string (b);
  g_object_unref (b);
  return out;
}

gboolean
scr_proto_parse_hello (const gchar *json, gssize len, int *version_out)
{
  JsonObject *o;
  JsonParser *p = proto_parse_object (json, len, &o);
  gboolean ok = FALSE;

  if (p == NULL)
    return FALSE;
  if (proto_type_is (o, SCR_MSG_HELLO))
    {
      if (version_out != NULL)
        *version_out = (int) proto_get_int (o, "version");
      ok = TRUE;
    }
  g_object_unref (p);
  return ok;
}

gboolean
scr_proto_parse_set_fps (const gchar *json, gssize len, int *fps_out)
{
  JsonObject *o;
  JsonParser *p = proto_parse_object (json, len, &o);
  gboolean ok = FALSE;

  if (p == NULL)
    return FALSE;
  if (proto_type_is (o, SCR_MSG_SET_FPS))
    {
      if (fps_out != NULL)
        *fps_out = (int) proto_get_int (o, "fps");
      ok = TRUE;
    }
  g_object_unref (p);
  return ok;
}

gboolean
scr_proto_parse_pause (const gchar *json, gssize len, gboolean *paused_out)
{
  JsonObject *o;
  JsonParser *p = proto_parse_object (json, len, &o);
  gboolean ok = FALSE;

  if (p == NULL)
    return FALSE;
  if (proto_type_is (o, SCR_MSG_PAUSE))
    {
      if (paused_out != NULL)
        *paused_out = json_object_has_member (o, "paused")
                      && proto_get_bool (o, "paused");
      ok = TRUE;
    }
  g_object_unref (p);
  return ok;
}

gboolean
scr_proto_parse_remove_target (const gchar *json, gssize len,
                               int *sink_out, gchar **mon_out)
{
  JsonObject *o;
  JsonParser *p = proto_parse_object (json, len, &o);
  const gchar *mon;
  gboolean ok = FALSE;

  if (p == NULL)
    return FALSE;
  if (proto_type_is (o, SCR_MSG_REMOVE_TARGET))
    {
      mon = proto_get_string (o, "mon");
      if (mon != NULL && *mon != '\0')
        {
          if (sink_out != NULL)
            *sink_out = (int) proto_get_int (o, "sink");
          if (mon_out != NULL)
            *mon_out = g_strdup (mon);
          ok = TRUE;
        }
    }
  g_object_unref (p);
  return ok;
}
