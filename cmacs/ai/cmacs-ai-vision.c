/* cmacs-ai-vision.c --- image input for cmacs-ai.
 *
 * Copyright (C) 2026 Zach Podbielniak
 * SPDX-License-Identifier: AGPL-3.0-or-later
 *
 * Everything that turns "an image the Lisp side named" into an
 * AiImageContent block on a user message, plus the two questions the
 * Lisp side needs answered before it sends one:
 *
 *   - Image specs.  An image reaches C as a plist, (:file PATH) or
 *     (:data UNIBYTE-STRING :mime "image/png"), or a list of them.
 *     `cmacs_ai_images_from_lisp' validates each one and returns a GList
 *     of AiImageContent the caller owns.  Every message-building DEFUN
 *     in cmacs/ai (chat-stream, session-append-message, cmacs-ai--call,
 *     harness-send-input) goes through it, so the rules below hold on
 *     every path:
 *
 *       * the BYTES decide what an image is, never a name: PNG, JPEG,
 *         GIF and WebP are recognised by their magic numbers, and
 *         anything else is refused -- an agent cannot send an arbitrary
 *         file to a remote model by calling it a picture;
 *       * a file is opened O_NONBLOCK (a FIFO named as an image must not
 *         wedge the main thread at open), must be a regular file, and is
 *         refused when it is larger than `cmacs-ai-image-max-bytes'
 *         BEFORE a byte is read.  The read itself is on the calling
 *         thread: with the cap it is bounded, and a local file of a few
 *         megabytes is cheaper to read than to hand to a worker;
 *       * a list longer than `cmacs-ai-image-max-count' is refused.
 *
 *   - Can the provider take images?  ai-glib has no "accepts image
 *     input" capability (its AiImageCapabilities are about GENERATING
 *     images).  But every HTTP provider is an AiClient whose class has a
 *     public `build_request' vfunc, so the honest test is to ask it:
 *     build a request holding a small marked image and look for the
 *     image's base64 in the JSON.  A provider that drops image blocks
 *     answers no; one that starts serialising them answers yes, with
 *     no change here (every HTTP client in ai-glib 0.13 keeps them --
 *     Claude's through AiImageContent's own to_json).  CLI
 *     providers have no request body to inspect; for those the answer is
 *     `cli' and the Lisp side keeps a table.
 *
 *   - PNG encoding in memory (`cmacs-ai-png-encode'), so a screen
 *     capture goes to a model without ever touching the disk.  The pixel
 *     layout is gowl's screenshot layout: cairo ARGB32 rows, stride the
 *     data's length divided by the height.
 *
 * Lisp_Objects never reach GLib memory: specs are converted to GBytes on
 * the main thread, at the DEFUN boundary, and only GObjects go on. */

#include <config.h>

#ifdef HAVE_CMACS_AI

#include <errno.h>
#include <fcntl.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>

#include "lisp.h"
#include "coding.h"
#include "cmacs-ai.h"

#include <ai-glib.h>
#include <glib.h>
#include <glib/gstdio.h>

#ifdef USE_CAIRO
#include <cairo.h>
#endif

/* Defaults for the two Lisp options, used while cmacs-ai-vision.el has
 * not been loaded (the variables are then void) or holds nonsense. */
#define CMACS_AI_VISION_DEFAULT_MAX_BYTES (20 * 1024 * 1024)
#define CMACS_AI_VISION_DEFAULT_MAX_COUNT 16

/* The base64 of the probe image below, as it appears in any request
 * body that carries the image: alphanumeric only, so no JSON escaping
 * can hide it. */
#define CMACS_AI_VISION_PROBE_B64 "iVBORw0KGgpjbWFjcy12aXNpb24tcHJvYmUtMQ"

/* A PNG signature followed by a marker.  Not a decodable picture: the
 * probe never leaves the process, it only has to be recognisable in the
 * JSON a client builds. */
static const guint8 cmacs_ai_vision__probe_bytes[] = {
  0x89, 'P', 'N', 'G', '\r', '\n', 0x1a, '\n',
  'c', 'm', 'a', 'c', 's', '-', 'v', 'i', 's', 'i', 'o', 'n', '-',
  'p', 'r', 'o', 'b', 'e', '-', '1'
};

/* ── Options read from Lisp ──────────────────────────────────────── */

/* The integer value of the Lisp variable NAME when it is a positive
 * fixnum, else FALLBACK.  `find_symbol_value' answers Qunbound for a
 * void variable, so this is safe before the Lisp file loads. */
static EMACS_INT
cmacs_ai_vision__option (const char *name, EMACS_INT fallback)
{
  Lisp_Object v = find_symbol_value (intern (name));
  if (FIXNUMP (v) && XFIXNUM (v) > 0)
    return XFIXNUM (v);
  return fallback;
}

/* ── Recognising an image ────────────────────────────────────────── */

/* The MIME type of DATA by its magic number, or NULL when it is none of
 * the four formats every vision provider accepts. */
static const char *
cmacs_ai_vision__sniff (const guint8 *data, gsize n)
{
  if (n >= 8 && memcmp (data, "\x89PNG\r\n\x1a\n", 8) == 0)
    return "image/png";
  if (n >= 3 && data[0] == 0xFF && data[1] == 0xD8 && data[2] == 0xFF)
    return "image/jpeg";
  if (n >= 6 && (memcmp (data, "GIF87a", 6) == 0
                 || memcmp (data, "GIF89a", 6) == 0))
    return "image/gif";
  if (n >= 12 && memcmp (data, "RIFF", 4) == 0
      && memcmp (data + 8, "WEBP", 4) == 0)
    return "image/webp";
  return NULL;
}

/* A declared type reduced to what it is compared as: parameters
 * ("; q=1") and surrounding blanks dropped, and "image/jpg" -- a common
 * misspelling -- read as image/jpeg.  Returns a newly allocated string.
 *
 * The declaration is only ever COMPARED with what the bytes are; the
 * type that goes on the AiImageContent is always the sniffed one, one of
 * exactly image/png, image/jpeg, image/gif, image/webp.  That matters:
 * Claude accepts those four and nothing else (ai-glib 0.13.1 refuses
 * any other spelling at once), and ai-glib's generic image serialiser
 * defaults a missing type to image/png. */
static char *
cmacs_ai_vision__normalise_mime (const char *mime)
{
  const char *semi = strchr (mime, ';');
  char *out = g_strstrip (semi != NULL ? g_strndup (mime, (gsize) (semi - mime))
                                       : g_strdup (mime));
  if (g_ascii_strcasecmp (out, "image/jpg") == 0)
    {
      g_free (out);
      out = g_strdup ("image/jpeg");
    }
  return out;
}

/* ── Reading a file, bounded ─────────────────────────────────────── */

/* Read PATH (an encoded file name) into a GBytes, or return NULL with
 * *WHY set to a newly allocated sentence.  CAP is the most bytes
 * accepted; a larger file is refused from its size, without reading
 * it, and a file that grows past CAP while being read is refused too. */
static GBytes *
cmacs_ai_vision__read_file (const char *path, gsize cap, char **why)
{
  struct stat st;
  int fd;
  guint8 *buf;
  gsize have = 0;

  /* O_NONBLOCK: opening a FIFO for reading blocks until a writer comes,
   * and this runs on the main thread -- under `emacs --gowl', the
   * compositor's.  The S_ISREG check below then refuses it. */
  fd = g_open (path, O_RDONLY | O_CLOEXEC | O_NOCTTY | O_NONBLOCK, 0);
  if (fd < 0)
    {
      *why = g_strdup_printf ("cannot open %s: %s", path,
                              g_strerror (errno));
      return NULL;
    }
  if (fstat (fd, &st) != 0)
    {
      *why = g_strdup_printf ("cannot stat %s: %s", path,
                              g_strerror (errno));
      close (fd);
      return NULL;
    }
  if (!S_ISREG (st.st_mode))
    {
      *why = g_strdup_printf ("%s is not a regular file", path);
      close (fd);
      return NULL;
    }
  if (st.st_size < 0 || (gsize) st.st_size > cap)
    {
      *why = g_strdup_printf ("%s is %" G_GOFFSET_FORMAT " bytes; the "
                              "limit (`cmacs-ai-image-max-bytes') is %"
                              G_GSIZE_FORMAT,
                              path, st.st_size, cap);
      close (fd);
      return NULL;
    }

  /* One more byte than the cap, so a file that grew since the fstat is
   * noticed rather than silently truncated. */
  buf = g_malloc (cap + 1);
  for (;;)
    {
      gssize got = read (fd, buf + have, cap + 1 - have);
      if (got < 0)
        {
          if (errno == EINTR)
            continue;
          *why = g_strdup_printf ("cannot read %s: %s", path,
                                  g_strerror (errno));
          g_free (buf);
          close (fd);
          return NULL;
        }
      if (got == 0)
        break;
      have += (gsize) got;
      if (have > cap)
        {
          *why = g_strdup_printf ("%s grew past the limit "
                                  "(`cmacs-ai-image-max-bytes') "
                                  "while it was read", path);
          g_free (buf);
          close (fd);
          return NULL;
        }
    }
  close (fd);
  return g_bytes_new_take (buf, have);
}

/* ── Specs to content blocks ─────────────────────────────────────── */

void
cmacs_ai_images_free (GList *images)
{
  g_list_free_full (images, g_object_unref);
}

void
cmacs_ai_images_unwind (void *images)
{
  cmacs_ai_images_free ((GList *) images);
}

/* Build one AiImageContent from SPEC, or return NULL with *WHY set.
 * ENCODED is SPEC's :file already expanded and encoded (Qnil for a
 * :data spec): that step runs Lisp, which may signal, so the caller
 * does it for every spec before any GObject exists.  Main thread only
 * (reads Lisp data).  Never signals. */
static AiImageContent *
cmacs_ai_vision__one (Lisp_Object spec, Lisp_Object encoded, gsize cap,
                      char **why)
{
  Lisp_Object file = plist_get (spec, intern (":file"));
  Lisp_Object data = plist_get (spec, intern (":data"));
  Lisp_Object mime = plist_get (spec, intern (":mime"));
  g_autofree char *declared = NULL;
  const char *sniffed;
  const guint8 *raw;
  gsize len;
  GBytes *bytes = NULL;
  AiImageContent *content;

  if (!NILP (mime))
    {
      if (!STRINGP (mime))
        {
          *why = g_strdup (":mime must be a string such as \"image/png\"");
          return NULL;
        }
      declared = cmacs_ai_vision__normalise_mime (SSDATA (mime));
    }

  if (STRINGP (file) && NILP (data))
    {
      bytes = cmacs_ai_vision__read_file (SSDATA (encoded), cap, why);
      if (bytes == NULL)
        return NULL;
    }
  else if (STRINGP (data) && NILP (file))
    {
      /* A multibyte string holding raw bytes would be read here as its
       * internal UTF-8, which is not the picture: refuse it rather than
       * send something that only looks like one. */
      if (STRING_MULTIBYTE (data))
        {
          *why = g_strdup (":data must be a unibyte string (raw image "
                           "bytes); see `string-to-unibyte'");
          return NULL;
        }
      if ((gsize) SBYTES (data) > cap)
        {
          *why = g_strdup_printf ("an image of %" G_GSIZE_FORMAT " bytes "
                                  "is over the limit "
                                  "(`cmacs-ai-image-max-bytes') of %"
                                  G_GSIZE_FORMAT,
                                  (gsize) SBYTES (data), cap);
          return NULL;
        }
      bytes = g_bytes_new (SDATA (data), SBYTES (data));
    }
  else
    {
      *why = g_strdup ("an image is (:file PATH) or (:data BYTES :mime "
                       "TYPE), exactly one of :file and :data");
      return NULL;
    }

  raw = g_bytes_get_data (bytes, &len);
  sniffed = cmacs_ai_vision__sniff (raw, len);
  if (sniffed == NULL)
    {
      *why = g_strdup_printf ("%s is not a PNG, JPEG, GIF or WebP image",
                              STRINGP (file) ? SSDATA (file) : "the data");
      g_bytes_unref (bytes);
      return NULL;
    }
  if (declared != NULL && g_ascii_strcasecmp (declared, sniffed) != 0)
    {
      *why = g_strdup_printf ("the image was declared %s but its bytes "
                              "are %s", declared, sniffed);
      g_bytes_unref (bytes);
      return NULL;
    }

  content = ai_image_content_new_from_bytes (bytes, sniffed);
  g_bytes_unref (bytes);
  if (content == NULL)
    *why = g_strdup ("ai-glib refused the image");
  return content;
}

GList *
cmacs_ai_images_from_lisp (Lisp_Object images)
{
  GList *out = NULL;
  char *why = NULL;
  gsize cap;
  EMACS_INT max_count, n = 0;
  Lisp_Object tail, resolved = Qnil;

  if (NILP (images))
    return NULL;

  cap = (gsize) cmacs_ai_vision__option ("cmacs-ai-image-max-bytes",
                                         CMACS_AI_VISION_DEFAULT_MAX_BYTES);
  max_count = cmacs_ai_vision__option ("cmacs-ai-image-max-count",
                                       CMACS_AI_VISION_DEFAULT_MAX_COUNT);

  /* One spec on its own is accepted as a list of one: (:file "a.png")
   * is the obvious thing to write for a single image. */
  if (CONSP (images) && SYMBOLP (XCAR (images))
      && SREF (SYMBOL_NAME (XCAR (images)), 0) == ':')
    images = list1 (images);

  if (!CONSP (images))
    xsignal1 (intern ("cmacs-ai-error"),
              build_string ("images must be a list of image specs"));

  /* Pass one, in Lisp terms only: shape, count, and each file name
   * expanded against `default-directory' and encoded the way every
   * Emacs file primitive encodes one.  Expanding can run a file-name
   * handler and so signal; nothing has been allocated yet. */
  for (tail = images; CONSP (tail); tail = XCDR (tail))
    {
      Lisp_Object spec = XCAR (tail), file;

      if (++n > max_count)
        xsignal1 (intern ("cmacs-ai-error"),
                  make_formatted_string ("more than %" pI "d images in one "
                                         "message "
                                         "(`cmacs-ai-image-max-count')",
                                         max_count));
      if (!CONSP (spec))
        xsignal1 (intern ("cmacs-ai-error"),
                  build_string ("each image is a plist: (:file PATH) or "
                                "(:data BYTES :mime TYPE)"));
      file = plist_get (spec, intern (":file"));
      resolved = Fcons (STRINGP (file)
                        ? ENCODE_FILE (Fexpand_file_name (file, Qnil))
                        : Qnil,
                        resolved);
    }
  resolved = Fnreverse (resolved);

  /* Pass two builds the blocks and calls nothing that signals, so the
   * list cannot leak on the way out. */
  for (tail = images; CONSP (tail) && CONSP (resolved);
       tail = XCDR (tail), resolved = XCDR (resolved))
    {
      AiImageContent *one = cmacs_ai_vision__one (XCAR (tail),
                                                  XCAR (resolved), cap,
                                                  &why);
      if (one == NULL)
        break;
      out = g_list_append (out, one);
    }

  if (why != NULL)
    {
      /* Release everything first: xsignal does not come back. */
      Lisp_Object msg = build_string (why);
      g_free (why);
      cmacs_ai_images_free (out);
      xsignal1 (intern ("cmacs-ai-error"), msg);
    }
  return out;
}

AiMessage *
cmacs_ai_user_message_new (const char *text, GList *images)
{
  AiMessage *m;
  GList *l;

  if (images == NULL)
    return ai_message_new_user (text != NULL ? text : "");

  /* Text first, then the pictures: the order every provider's own
   * examples use, and the one a CLI's text projection reads best in. */
  m = ai_message_new (AI_ROLE_USER);
  if (text != NULL && text[0] != '\0')
    ai_message_add_text (m, text);
  for (l = images; l != NULL; l = l->next)
    ai_message_add_content_block (m, g_object_ref (AI_CONTENT_BLOCK (l->data)));
  return m;
}

/* ── Asking a provider whether it serialises images ──────────────── */

/* GType -> 1 (serialises images) / 2 (drops them) / 3 (cannot tell).
 * Main thread only.  Keyed by type rather than provider symbol: two
 * named OpenAI-compatible endpoints are one client class. */
static GHashTable *cmacs_ai_vision__probe_cache = NULL;

/* 1, 2 or 3 as above, for the AiClient CLIENT. */
static int
cmacs_ai_vision__probe_client (AiClient *client)
{
  AiClientClass *klass = AI_CLIENT_GET_CLASS (client);
  GBytes *bytes;
  AiMessage *m;
  AiImageContent *img;
  GList *messages;
  JsonNode *node;
  int answer = 3;

  if (klass->build_request == NULL)
    return 3;

  bytes = g_bytes_new_static (cmacs_ai_vision__probe_bytes,
                              sizeof cmacs_ai_vision__probe_bytes);
  img = ai_image_content_new_from_bytes (bytes, "image/png");
  g_bytes_unref (bytes);
  if (img == NULL)
    return 3;
  m = ai_message_new (AI_ROLE_USER);
  ai_message_add_text (m, "probe");
  ai_message_add_content_block (m, AI_CONTENT_BLOCK (img));
  messages = g_list_append (NULL, m);

  /* Building a request is pure: no socket, no key needed.  A client
   * that cannot build one without more configuration returns NULL, and
   * that is "cannot tell", not "no". */
  node = klass->build_request (client, messages, NULL, 64, NULL);
  if (node != NULL)
    {
      gchar *json = json_to_string (node, FALSE);
      answer = (json != NULL
                && strstr (json, CMACS_AI_VISION_PROBE_B64) != NULL) ? 1 : 2;
      g_free (json);
      json_node_unref (node);
    }
  g_list_free (messages);
  g_object_unref (m);
  return answer;
}

DEFUN ("cmacs-ai-provider-image-input", Fcmacs_ai_provider_image_input,
       Scmacs_ai_provider_image_input, 0, 1, 0,
       doc: /* Say whether PROVIDER's client sends image input to the model.
PROVIDER is a provider symbol, or nil for the provider ai-glib's own
configuration names as its default.  Returns a plist:

  :images      t      an HTTP client that puts image blocks in its
                      request body;
               nil    an HTTP client that drops them;
               `cli'  a CLI client: there is no request body to look
                      at, so the answer is the Lisp table's
                      (`cmacs-ai-vision-cli-providers');
               `unknown'  the client could not build a request.
  :configured  for an HTTP client, t when ai-glib has the credentials
               it needs (an API key, or none needed); nil otherwise.
               Always nil for a CLI client.
  :type        the client's GType name, for messages.

The answer for an HTTP client is found by building a request that holds
a small marked image and looking for that image in the JSON -- so it is
what the linked ai-glib actually does, not what a table remembers.  It
is computed once per client class and cached.  This says nothing about
the MODEL: a text-only model behind an image-capable client is the
model's to refuse (see `cmacs-ai-vision-model-overrides').  */)
  (Lisp_Object provider)
{
  AiProviderType type;
  AiSimple *ai;
  AiProvider *prov;
  GType gtype;
  int answer;
  Lisp_Object images, configured = Qnil, type_name;

  if (NILP (provider))
    type = ai_config_get_default_provider (ai_config_get_default ());
  else
    {
      CHECK_SYMBOL (provider);
      type = cmacs_ai_provider_type_from_symbol (provider);
    }

  ai = ai_simple_new_with_provider (type, NULL);
  if (ai == NULL)
    xsignal1 (intern ("cmacs-ai-error"),
              build_string ("could not build a client for that provider"));
  prov = ai_simple_get_provider (ai);
  gtype = G_OBJECT_TYPE (prov);
  type_name = build_string (g_type_name (gtype));

  if (!AI_IS_CLIENT (prov))
    {
      g_object_unref (ai);
      return listn (6, intern (":images"), intern ("cli"),
                    intern (":configured"), Qnil,
                    intern (":type"), type_name);
    }

  if (cmacs_ai_vision__probe_cache == NULL)
    cmacs_ai_vision__probe_cache = g_hash_table_new (g_direct_hash,
                                                     g_direct_equal);
  answer = GPOINTER_TO_INT (g_hash_table_lookup (cmacs_ai_vision__probe_cache,
                                                 GSIZE_TO_POINTER (gtype)));
  if (answer == 0)
    {
      answer = cmacs_ai_vision__probe_client (AI_CLIENT (prov));
      g_hash_table_insert (cmacs_ai_vision__probe_cache,
                           GSIZE_TO_POINTER (gtype),
                           GINT_TO_POINTER (answer));
    }
  if (ai_config_validate (ai_config_get_default (), type, NULL))
    configured = Qt;
  g_object_unref (ai);

  images = answer == 1 ? Qt : answer == 2 ? Qnil : intern ("unknown");
  return listn (6, intern (":images"), images,
                intern (":configured"), configured,
                intern (":type"), type_name);
}

/* ── Seams for tests and preflight ───────────────────────────────── */

/* (:mime MIME :bytes N) for the AiImageContent CONTENT, read back out
 * of the AiImage it holds -- what a provider will serialise. */
static Lisp_Object
cmacs_ai_vision__describe (AiImageContent *content)
{
  AiImage *image = ai_image_content_get_image (content);
  const char *mime = image != NULL ? ai_image_get_mime_type (image) : NULL;
  gsize size = image != NULL ? ai_image_get_size (image) : 0;

  return list4 (intern (":mime"), build_string (mime != NULL ? mime : ""),
                intern (":bytes"), make_uint (size));
}

DEFUN ("cmacs-ai-image-parts", Fcmacs_ai_image_parts,
       Scmacs_ai_image_parts, 1, 1, 0,
       doc: /* Validate IMAGES and describe the content blocks they become.
IMAGES is what every image-taking cmacs-ai function accepts: a list of
plists (:file PATH) or (:data UNIBYTE-STRING :mime TYPE), or one such
plist.  Each is turned into the ai-glib image block a message would
carry -- the file read under `cmacs-ai-image-max-bytes', the type taken
from the bytes -- and described as (:mime TYPE :bytes N).  Nothing is
sent.  Signals `cmacs-ai-error' for an image that would be refused.  */)
  (Lisp_Object images)
{
  GList *list = cmacs_ai_images_from_lisp (images);
  GList *l;
  Lisp_Object out = Qnil;

  for (l = list; l != NULL; l = l->next)
    out = Fcons (cmacs_ai_vision__describe (AI_IMAGE_CONTENT (l->data)), out);
  cmacs_ai_images_free (list);
  return Fnreverse (out);
}

DEFUN ("cmacs-ai-session-message-parts", Fcmacs_ai_session_message_parts,
       Scmacs_ai_session_message_parts, 1, 2, 0,
       doc: /* Return the content blocks of a message in SESSION.
INDEX counts from 0; nil means the last message.  Each block is
\(text STRING), (image :mime TYPE :bytes N), or (other TYPE-NAME).
For seeing that an image really reached the conversation, which the
message text alone cannot show.  */)
  (Lisp_Object session, Lisp_Object index)
{
  CmacsAiSession *s;
  GList *messages, *node, *b;
  Lisp_Object out = Qnil;

  CHECK_FIXNAT (session);
  s = cmacs_ai_session_lookup (XFIXNUM (session));
  if (s == NULL)
    error ("cmacs-ai: bad session handle");
  messages = cmacs_ai_session_get_messages (s);
  if (NILP (index))
    node = g_list_last (messages);
  else
    {
      CHECK_FIXNAT (index);
      node = g_list_nth (messages, (guint) XFIXNUM (index));
    }
  if (node == NULL)
    return Qnil;

  for (b = ai_message_get_content_blocks (AI_MESSAGE (node->data));
       b != NULL; b = b->next)
    {
      if (AI_IS_TEXT_CONTENT (b->data))
        {
          const char *t =
            ai_text_content_get_text (AI_TEXT_CONTENT (b->data));
          out = Fcons (list2 (intern ("text"),
                              build_string (t != NULL ? t : "")), out);
        }
      else if (AI_IS_IMAGE_CONTENT (b->data))
        out = Fcons (Fcons (intern ("image"),
                            cmacs_ai_vision__describe
                              (AI_IMAGE_CONTENT (b->data))),
                     out);
      else
        out = Fcons (list2 (intern ("other"),
                            build_string (G_OBJECT_TYPE_NAME (b->data))),
                     out);
    }
  return Fnreverse (out);
}

/* ── PNG in memory ───────────────────────────────────────────────── */

#ifdef USE_CAIRO

static cairo_status_t
cmacs_ai_vision__png_write (void *closure, const unsigned char *data,
                            unsigned int length)
{
  g_byte_array_append ((GByteArray *) closure, data, length);
  return CAIRO_STATUS_SUCCESS;
}

DEFUN ("cmacs-ai-png-encode", Fcmacs_ai_png_encode,
       Scmacs_ai_png_encode, 3, 4, 0,
       doc: /* Encode a screen capture as PNG bytes, in memory.
WIDTH and HEIGHT are the capture's size in pixels and DATA its pixels,
as `gowl-screenshot-region' and `gowl-screenshot-client' return them:
a unibyte string of 32-bit cairo ARGB32 rows, its length divided by
HEIGHT being the row stride.  Optional MAX-SIDE, a positive integer,
scales the picture down (never up) so its longer side is at most that
many pixels -- the size a vision model actually reads, and a fraction of
the bytes.  Returns a unibyte string holding the PNG.  Nothing is
written to disk.  */)
  (Lisp_Object width, Lisp_Object height, Lisp_Object data,
   Lisp_Object max_side)
{
  EMACS_INT w, h, limit = 0;
  ptrdiff_t stride, dst_stride, row;
  cairo_surface_t *src, *out;
  cairo_status_t status;
  GByteArray *png;
  Lisp_Object result;
  unsigned char *dst;

  CHECK_FIXNAT (width);
  CHECK_FIXNAT (height);
  CHECK_STRING (data);
  w = XFIXNUM (width);
  h = XFIXNUM (height);
  if (!NILP (max_side))
    {
      CHECK_FIXNAT (max_side);
      limit = XFIXNUM (max_side);
    }
  if (w <= 0 || h <= 0 || w > 32767 || h > 32767)
    error ("cmacs-ai-png-encode: bad size %" pI "dx%" pI "d", w, h);
  stride = SBYTES (data) / h;
  if (stride < w * 4)
    error ("cmacs-ai-png-encode: %" pI "dx%" pI "d needs at least %" pI
           "d bytes, DATA has %" pD "d", w, h, w * h * 4, SBYTES (data));

  /* Same copy as gowl_compositor_save_png: the capture is already in
   * cairo's ARGB32 byte order, so each row is a memcpy. */
  src = cairo_image_surface_create (CAIRO_FORMAT_ARGB32, (int) w, (int) h);
  if (cairo_surface_status (src) != CAIRO_STATUS_SUCCESS)
    {
      cairo_surface_destroy (src);
      error ("cmacs-ai-png-encode: cannot allocate a %" pI "dx%" pI
             "d surface", w, h);
    }
  cairo_surface_flush (src);
  dst = cairo_image_surface_get_data (src);
  dst_stride = cairo_image_surface_get_stride (src);
  for (row = 0; row < h; row++)
    memcpy (dst + row * dst_stride, SDATA (data) + row * stride,
            (size_t) w * 4);
  cairo_surface_mark_dirty (src);

  out = src;
  if (limit > 0 && (w > limit || h > limit))
    {
      double scale = (double) limit / (double) (w > h ? w : h);
      int sw = (int) (w * scale), sh = (int) (h * scale);
      cairo_t *cr;

      if (sw < 1) sw = 1;
      if (sh < 1) sh = 1;
      out = cairo_image_surface_create (CAIRO_FORMAT_ARGB32, sw, sh);
      if (cairo_surface_status (out) != CAIRO_STATUS_SUCCESS)
        {
          cairo_surface_destroy (out);
          cairo_surface_destroy (src);
          error ("cmacs-ai-png-encode: cannot allocate the scaled surface");
        }
      cr = cairo_create (out);
      cairo_scale (cr, scale, scale);
      cairo_set_source_surface (cr, src, 0, 0);
      /* GOOD rather than the default BILINEAR: a downscale by more than
       * two with BILINEAR drops whole rows, and text is what a model is
       * usually being shown. */
      cairo_pattern_set_filter (cairo_get_source (cr), CAIRO_FILTER_GOOD);
      cairo_paint (cr);
      cairo_destroy (cr);
      cairo_surface_destroy (src);
    }

  png = g_byte_array_new ();
  status = cairo_surface_write_to_png_stream (out, cmacs_ai_vision__png_write,
                                              png);
  cairo_surface_destroy (out);
  if (status != CAIRO_STATUS_SUCCESS)
    {
      g_byte_array_unref (png);
      error ("cmacs-ai-png-encode: %s", cairo_status_to_string (status));
    }
  result = make_unibyte_string ((const char *) png->data, png->len);
  g_byte_array_unref (png);
  return result;
}

#endif /* USE_CAIRO */

void syms_of_cmacs_ai_vision_defuns (void);
void
syms_of_cmacs_ai_vision_defuns (void)
{
  defsubr (&Scmacs_ai_provider_image_input);
  defsubr (&Scmacs_ai_image_parts);
  defsubr (&Scmacs_ai_session_message_parts);
#ifdef USE_CAIRO
  defsubr (&Scmacs_ai_png_encode);
#endif
}

#endif /* HAVE_CMACS_AI */
