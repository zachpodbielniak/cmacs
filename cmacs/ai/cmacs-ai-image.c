/* cmacs-ai-image.c --- image generation DEFUNs.
 *
 * Copyright (C) 2026 Zach Podbielniak
 * SPDX-License-Identifier: AGPL-3.0-or-later
 *
 * Wraps AiImageGenerator (implemented by the OpenAI, Gemini and Grok
 * clients).  The Elisp layer above this writes the bytes to a file and
 * attaches them to an Org node, so the job of this file is to get the
 * full request surface across the C boundary and hand back raw bytes --
 * whatever form the provider happened to return them in.
 *
 * Generation takes tens of seconds, so the async DEFUN is the primary
 * entry point.  A bounded synchronous wrapper exists for callers with no
 * other option (org-babel, which has no async protocol), built on a
 * private GMainContext exactly like `cmacs-ai-list-models'. */

#include <config.h>

#ifdef HAVE_CMACS_AI

#include "lisp.h"
#include "cmacs-ai.h"
#include "cmacs-glib-loop.h"
#include "cmacs-eval-dispatch.h"

#include <ai-glib.h>
#include <glib.h>

/* In-flight jobs, so `cmacs-ai-image-cancel' has something to cancel.
 * Generation is slow enough that being unable to stop it is a real
 * problem, not a theoretical one. */
static GHashTable *cmacs_ai_image_jobs;   /* guint handle -> GCancellable* */
static guint       cmacs_ai_image_next_handle = 1;

typedef struct
{
  uint64_t          cb_cookie;
  guint             handle;
  AiImageResponse  *resp;      /* owned */
  GPtrArray        *bytes;     /* GBytes*, one slot per image, may be NULL */
  guint             pending;   /* URL fetches still outstanding */
} CmacsAiImageJob;

/* ------------------------------------------------------------------ */
/* Option plist -> AiImageRequest                                       */
/* ------------------------------------------------------------------ */

enum cmacs_ai_image_opt_kind
{
  OPT_STRING,
  OPT_INT,
  OPT_INT64,
  OPT_FLOAT,
  OPT_ENUM,        /* string or symbol -> provider enum via a from_string */
  OPT_TRISTATE,
  OPT_REFERENCES,  /* list of file paths, or of (PATH . ROLE) */
  OPT_MASK,
  OPT_EXTRAS       /* plist of KEY VALUE spliced into the request body */
};

struct cmacs_ai_image_opt
{
  const char                   *key;
  enum cmacs_ai_image_opt_kind  kind;
  /* Exactly one of these is used, per `kind'. */
  void (*set_string)  (AiImageRequest *, const gchar *);
  void (*set_int)     (AiImageRequest *, gint);
  void (*set_int64)   (AiImageRequest *, gint64);
  void (*set_float)   (AiImageRequest *, gdouble);
  void (*set_enum)    (AiImageRequest *, gint);
  gint (*from_string) (const gchar *);
  void (*set_tri)     (AiImageRequest *, AiTriState);
};

/* Adapters: the enum setters take their own enum type, which cannot be
 * spelled uniformly in a table of function pointers. */
#define CMACS_AI_IMAGE_ENUM_ADAPTER(name, setter, type)                 \
  static void                                                           \
  name (AiImageRequest *req, gint value)                                \
  {                                                                     \
    setter (req, (type) value);                                         \
  }

CMACS_AI_IMAGE_ENUM_ADAPTER (set_size_adapter,
                             ai_image_request_set_size, AiImageSize)
CMACS_AI_IMAGE_ENUM_ADAPTER (set_quality_adapter,
                             ai_image_request_set_quality, AiImageQuality)
CMACS_AI_IMAGE_ENUM_ADAPTER (set_style_adapter,
                             ai_image_request_set_style, AiImageStyle)
CMACS_AI_IMAGE_ENUM_ADAPTER (set_operation_adapter,
                             ai_image_request_set_operation, AiImageOperation)
CMACS_AI_IMAGE_ENUM_ADAPTER (set_resolution_adapter,
                             ai_image_request_set_resolution, AiImageResolution)
CMACS_AI_IMAGE_ENUM_ADAPTER (set_background_adapter,
                             ai_image_request_set_background, AiImageBackground)
CMACS_AI_IMAGE_ENUM_ADAPTER (set_format_adapter,
                             ai_image_request_set_output_format, AiImageFormat)
CMACS_AI_IMAGE_ENUM_ADAPTER (set_moderation_adapter,
                             ai_image_request_set_moderation, AiImageModeration)
CMACS_AI_IMAGE_ENUM_ADAPTER (set_person_adapter,
                             ai_image_request_set_person_generation,
                             AiImagePersonGeneration)
CMACS_AI_IMAGE_ENUM_ADAPTER (set_fidelity_adapter,
                             ai_image_request_set_input_fidelity,
                             AiImageFidelity)
CMACS_AI_IMAGE_ENUM_ADAPTER (set_response_format_adapter,
                             ai_image_request_set_response_format,
                             AiImageResponseFormat)

#define CMACS_AI_IMAGE_FROM_STRING(name, fn)            \
  static gint                                           \
  name (const gchar *s)                                 \
  {                                                     \
    return (gint) fn (s);                               \
  }

CMACS_AI_IMAGE_FROM_STRING (size_from_string, ai_image_size_from_string)
CMACS_AI_IMAGE_FROM_STRING (quality_from_string, ai_image_quality_from_string)
CMACS_AI_IMAGE_FROM_STRING (style_from_string, ai_image_style_from_string)
CMACS_AI_IMAGE_FROM_STRING (operation_from_string,
                            ai_image_operation_from_string)
CMACS_AI_IMAGE_FROM_STRING (resolution_from_string,
                            ai_image_resolution_from_string)
CMACS_AI_IMAGE_FROM_STRING (background_from_string,
                            ai_image_background_from_string)
CMACS_AI_IMAGE_FROM_STRING (format_from_string, ai_image_format_from_string)
CMACS_AI_IMAGE_FROM_STRING (moderation_from_string,
                            ai_image_moderation_from_string)
CMACS_AI_IMAGE_FROM_STRING (person_from_string,
                            ai_image_person_generation_from_string)
CMACS_AI_IMAGE_FROM_STRING (fidelity_from_string,
                            ai_image_fidelity_from_string)
CMACS_AI_IMAGE_FROM_STRING (response_format_from_string,
                            ai_image_response_format_from_string)

/* One row per option.  Adding a parameter is a row, not another branch
 * in a growing if-chain. */
static const struct cmacs_ai_image_opt cmacs_ai_image_opts[] = {
  { ":model", OPT_STRING, ai_image_request_set_model },
  { ":prompt", OPT_STRING, ai_image_request_set_prompt },
  { ":negative", OPT_STRING, ai_image_request_set_negative_prompt },
  { ":system", OPT_STRING, ai_image_request_set_system_instruction },
  { ":aspect", OPT_STRING, ai_image_request_set_aspect_ratio },
  { ":custom-size", OPT_STRING, ai_image_request_set_custom_size },
  { ":style-preset", OPT_STRING, ai_image_request_set_style_preset },
  { ":language", OPT_STRING, ai_image_request_set_language },
  { ":user", OPT_STRING, ai_image_request_set_user },

  { ":count", OPT_INT, NULL, ai_image_request_set_count },
  { ":compression", OPT_INT, NULL, ai_image_request_set_output_compression },
  { ":steps", OPT_INT, NULL, ai_image_request_set_steps },
  { ":top-k", OPT_INT, NULL, ai_image_request_set_top_k },
  { ":partial-images", OPT_INT, NULL, ai_image_request_set_partial_images },

  { ":seed", OPT_INT64, NULL, NULL, ai_image_request_set_seed },

  { ":guidance", OPT_FLOAT, NULL, NULL, NULL,
    ai_image_request_set_guidance_scale },
  { ":strength", OPT_FLOAT, NULL, NULL, NULL, ai_image_request_set_strength },
  { ":temperature", OPT_FLOAT, NULL, NULL, NULL,
    ai_image_request_set_temperature },
  { ":top-p", OPT_FLOAT, NULL, NULL, NULL, ai_image_request_set_top_p },

  { ":size", OPT_ENUM, NULL, NULL, NULL, NULL,
    set_size_adapter, size_from_string },
  { ":quality", OPT_ENUM, NULL, NULL, NULL, NULL,
    set_quality_adapter, quality_from_string },
  { ":style", OPT_ENUM, NULL, NULL, NULL, NULL,
    set_style_adapter, style_from_string },
  { ":operation", OPT_ENUM, NULL, NULL, NULL, NULL,
    set_operation_adapter, operation_from_string },
  { ":resolution", OPT_ENUM, NULL, NULL, NULL, NULL,
    set_resolution_adapter, resolution_from_string },
  { ":background", OPT_ENUM, NULL, NULL, NULL, NULL,
    set_background_adapter, background_from_string },
  { ":format", OPT_ENUM, NULL, NULL, NULL, NULL,
    set_format_adapter, format_from_string },
  { ":moderation", OPT_ENUM, NULL, NULL, NULL, NULL,
    set_moderation_adapter, moderation_from_string },
  { ":person-generation", OPT_ENUM, NULL, NULL, NULL, NULL,
    set_person_adapter, person_from_string },
  { ":fidelity", OPT_ENUM, NULL, NULL, NULL, NULL,
    set_fidelity_adapter, fidelity_from_string },
  { ":response-format", OPT_ENUM, NULL, NULL, NULL, NULL,
    set_response_format_adapter, response_format_from_string },

  { ":watermark", OPT_TRISTATE, NULL, NULL, NULL, NULL, NULL, NULL,
    ai_image_request_set_watermark },
  { ":enhance-prompt", OPT_TRISTATE, NULL, NULL, NULL, NULL, NULL, NULL,
    ai_image_request_set_enhance_prompt },

  { ":references", OPT_REFERENCES },
  { ":mask", OPT_MASK },
  { ":extra", OPT_EXTRAS },
};

/* Coerce a Lisp value to a string: strings pass through, symbols use
 * their name, so both :size "1024x1024" and :size '1024x1024 work. */
static const gchar *
cmacs_ai_image__as_string (Lisp_Object val)
{
  if (STRINGP (val))
    return SSDATA (val);
  if (SYMBOLP (val) && !NILP (val))
    return SSDATA (SYMBOL_NAME (val));
  return NULL;
}

/* Add one reference: either "PATH" or (PATH . "role") / (PATH "role"). */
static void
cmacs_ai_image__add_reference (AiImageRequest *req, Lisp_Object entry)
{
  Lisp_Object path = entry;
  const gchar *role = NULL;
  g_autoptr (GError) err = NULL;

  if (CONSP (entry))
    {
      Lisp_Object tail = XCDR (entry);

      path = XCAR (entry);
      if (CONSP (tail))
        tail = XCAR (tail);
      role = cmacs_ai_image__as_string (tail);
    }

  CHECK_STRING (path);

  if (!ai_image_request_add_reference_file (req, SSDATA (path), role, &err))
    error ("cmacs-ai: %s", err ? err->message : "could not read reference");
}

static void
cmacs_ai_image__apply_options (AiImageRequest *req, Lisp_Object options)
{
  Lisp_Object tail = options;

  while (CONSP (tail) && CONSP (XCDR (tail)))
    {
      Lisp_Object key = XCAR (tail);
      Lisp_Object val = XCAR (XCDR (tail));
      size_t i;

      tail = XCDR (XCDR (tail));

      if (NILP (val))
        continue;

      for (i = 0; i < G_N_ELEMENTS (cmacs_ai_image_opts); i++)
        {
          const struct cmacs_ai_image_opt *opt = &cmacs_ai_image_opts[i];

          if (!EQ (key, intern (opt->key)))
            continue;

          switch (opt->kind)
            {
            case OPT_STRING:
              {
                const gchar *s = cmacs_ai_image__as_string (val);
                if (s != NULL)
                  opt->set_string (req, s);
              }
              break;

            case OPT_INT:
              CHECK_FIXNUM (val);
              opt->set_int (req, (gint) XFIXNUM (val));
              break;

            case OPT_INT64:
              CHECK_FIXNUM (val);
              opt->set_int64 (req, XFIXNUM (val));
              break;

            case OPT_FLOAT:
              CHECK_NUMBER (val);
              opt->set_float (req, extract_float (Ffloat (val)));
              break;

            case OPT_ENUM:
              {
                const gchar *s = cmacs_ai_image__as_string (val);
                if (s != NULL)
                  opt->set_enum (req, opt->from_string (s));
              }
              break;

            case OPT_TRISTATE:
              /* Only ever reached for a non-nil value, so this is the
               * caller explicitly asking for the parameter to be set;
               * `t' means true and anything else means false.  Leaving
               * the key out entirely is how you get "unset". */
              opt->set_tri (req, EQ (val, Qt) ? AI_TRI_TRUE : AI_TRI_FALSE);
              break;

            case OPT_REFERENCES:
              {
                Lisp_Object refs = val;

                /* A bare string is a one-element list. */
                if (STRINGP (refs))
                  cmacs_ai_image__add_reference (req, refs);
                else
                  for (; CONSP (refs); refs = XCDR (refs))
                    cmacs_ai_image__add_reference (req, XCAR (refs));
              }
              break;

            case OPT_MASK:
              {
                g_autoptr (GError) err = NULL;
                AiImage *mask;

                CHECK_STRING (val);
                mask = ai_image_new_from_file (SSDATA (val), &err);
                if (mask == NULL)
                  error ("cmacs-ai: %s",
                         err ? err->message : "could not read mask");
                ai_image_request_set_mask (req, mask);
                ai_image_free (mask);
              }
              break;

            case OPT_EXTRAS:
              {
                Lisp_Object x = val;

                while (CONSP (x) && CONSP (XCDR (x)))
                  {
                    Lisp_Object ekey = XCAR (x);
                    Lisp_Object eval = XCAR (XCDR (x));
                    const gchar *ks = cmacs_ai_image__as_string (ekey);

                    x = XCDR (XCDR (x));

                    if (ks == NULL)
                      continue;

                    /* Skip a leading colon so (:extra (:foo "bar"))
                     * sends "foo", which is what the API expects. */
                    if (ks[0] == ':')
                      ks++;

                    if (STRINGP (eval))
                      ai_image_request_set_extra_string (req, ks,
                                                         SSDATA (eval));
                    else if (FIXNUMP (eval))
                      ai_image_request_set_extra
                        (req, ks, g_variant_new_int64 (XFIXNUM (eval)));
                    else if (FLOATP (eval))
                      ai_image_request_set_extra
                        (req, ks, g_variant_new_double (XFLOAT_DATA (eval)));
                    else if (EQ (eval, Qt))
                      ai_image_request_set_extra
                        (req, ks, g_variant_new_boolean (TRUE));
                    else
                      {
                        const gchar *s = cmacs_ai_image__as_string (eval);
                        if (s != NULL)
                          ai_image_request_set_extra_string (req, ks, s);
                      }
                  }
              }
              break;
            }

          break;
        }
    }
}

/* ------------------------------------------------------------------ */
/* Result marshalling                                                   */
/* ------------------------------------------------------------------ */

static void
cmacs_ai_image__job_free (CmacsAiImageJob *j)
{
  if (j->handle != 0 && cmacs_ai_image_jobs != NULL)
    g_hash_table_remove (cmacs_ai_image_jobs, GUINT_TO_POINTER (j->handle));

  g_clear_pointer (&j->resp, ai_image_response_free);
  g_clear_pointer (&j->bytes, g_ptr_array_unref);
  g_free (j);
}

/* Build (:images ((:data BYTES :mime M :url U :base64 B :revised R) ...)).
 *
 * `:data' is the payload as a unibyte string, so the Elisp layer can
 * write it straight out without a base64 round trip. */
static Lisp_Object
cmacs_ai_image__to_lisp (CmacsAiImageJob *j)
{
  Lisp_Object out = Qnil;
  guint n = ai_image_response_get_image_count (j->resp);
  guint i;

  for (i = 0; i < n; i++)
    {
      AiGeneratedImage *img = ai_image_response_get_image (j->resp, i);
      GBytes *bytes;
      Lisp_Object plist = Qnil;
      const gchar *s;

      if (img == NULL)
        continue;

      s = ai_generated_image_get_revised_prompt (img);
      if (s)
        plist = Fcons (build_string (s),
                       Fcons (intern (":revised"), plist));

      s = ai_generated_image_get_base64 (img);
      if (s)
        plist = Fcons (build_string (s), Fcons (intern (":base64"), plist));

      s = ai_generated_image_get_url (img);
      if (s)
        plist = Fcons (build_string (s), Fcons (intern (":url"), plist));

      s = ai_generated_image_get_mime_type (img);
      plist = Fcons (build_string (s ? s : "image/png"),
                     Fcons (intern (":mime"), plist));

      bytes = i < j->bytes->len ? g_ptr_array_index (j->bytes, i) : NULL;
      if (bytes != NULL)
        {
          gsize len = 0;
          gconstpointer data = g_bytes_get_data (bytes, &len);

          plist = Fcons (make_unibyte_string ((const char *) data, len),
                         Fcons (intern (":data"), plist));
        }

      out = Fcons (Fnreverse (plist), out);
    }

  return Fnreverse (out);
}

static void
cmacs_ai_image__finish (CmacsAiImageJob *j)
{
  Lisp_Object payload = list2 (intern (":images"),
                               cmacs_ai_image__to_lisp (j));

  cmacs_dispatch_callback_invoke1 (j->cb_cookie, payload);
  cmacs_ai_image__job_free (j);
}

static void
cmacs_ai_image__fail (CmacsAiImageJob *j, const gchar *message)
{
  cmacs_dispatch_callback_invoke1 (
    j->cb_cookie,
    list2 (intern (":error"), build_string (message)));
  cmacs_ai_image__job_free (j);
}

struct cmacs_ai_image_fetch
{
  CmacsAiImageJob *job;
  guint            index;
};

static void
cmacs_ai_image__on_bytes (GObject *src, GAsyncResult *res, gpointer user)
{
  struct cmacs_ai_image_fetch *f = user;
  CmacsAiImageJob *j = f->job;
  GError *err = NULL;
  GBytes *bytes;

  bytes = ai_generated_image_load_bytes_finish (NULL, res, &err);

  if (bytes != NULL && f->index < j->bytes->len)
    {
      g_ptr_array_index (j->bytes, f->index) = bytes;
    }
  else
    {
      /* A single unreachable URL should not lose the whole batch; the
       * entry simply arrives without :data and the Elisp layer skips
       * it. */
      if (err != NULL)
        g_warning ("cmacs-ai: image %u could not be retrieved: %s",
                   f->index + 1, err->message);
      g_clear_pointer (&bytes, g_bytes_unref);
    }

  g_clear_error (&err);
  g_free (f);

  if (--j->pending == 0)
    cmacs_ai_image__finish (j);
}

static void
cmacs_ai_image__on_done (GObject *src, GAsyncResult *res, gpointer user)
{
  CmacsAiImageJob *j = user;
  GError *err = NULL;
  AiImageResponse *resp;
  guint n;
  guint i;

  resp = ai_image_generator_generate_image_finish (AI_IMAGE_GENERATOR (src),
                                                   res, &err);
  if (resp == NULL)
    {
      char *msg = g_strdup (err ? err->message : "image generation failed");

      g_clear_error (&err);
      cmacs_ai_image__fail (j, msg);
      g_free (msg);
      return;
    }

  j->resp = resp;
  n = ai_image_response_get_image_count (resp);

  j->bytes = g_ptr_array_new_full (n, (GDestroyNotify) g_bytes_unref);
  for (i = 0; i < n; i++)
    g_ptr_array_add (j->bytes, NULL);

  /* Materialise every image to bytes before returning to Lisp, so the
   * Elisp layer never has to care whether this provider answered with
   * inline base64 or a URL.  Inline payloads resolve without a round
   * trip; URLs need one, and their links expire quickly, so fetching
   * now rather than later is also the safer moment. */
  j->pending = 0;
  for (i = 0; i < n; i++)
    {
      AiGeneratedImage *img = ai_image_response_get_image (resp, i);
      struct cmacs_ai_image_fetch *f;

      if (img == NULL)
        continue;

      f = g_new0 (struct cmacs_ai_image_fetch, 1);
      f->job = j;
      f->index = i;
      j->pending++;

      ai_generated_image_load_bytes_async (img, NULL,
                                           cmacs_ai_image__on_bytes, f);
    }

  if (j->pending == 0)
    cmacs_ai_image__finish (j);
}

/* ------------------------------------------------------------------ */
/* Shared request construction                                          */
/* ------------------------------------------------------------------ */

/* Resolve CLIENT to an AiImageGenerator, signalling if it is not one. */
static AiImageGenerator *
cmacs_ai_image__generator (Lisp_Object client)
{
  gpointer raw;

  CHECK_FIXNAT (client);
  raw = cmacs_ai_client_lookup (XFIXNUM (client));
  if (raw == NULL)
    error ("cmacs-ai: bad client handle");
  if (!AI_IS_IMAGE_GENERATOR (raw))
    error ("cmacs-ai: provider does not support image generation");

  return AI_IMAGE_GENERATOR (raw);
}

/* Build the request.  Defaults to base64 rather than the library's URL
 * default: this layer always wants bytes, and a URL costs an extra
 * round trip against a link that expires. */
static AiImageRequest *
cmacs_ai_image__build (Lisp_Object prompt, Lisp_Object options)
{
  AiImageRequest *req;

  CHECK_STRING (prompt);

  req = ai_image_request_new (SSDATA (prompt));
  ai_image_request_set_response_format (req, AI_IMAGE_RESPONSE_BASE64);

  /* apply_options can signal; the caller must own `req' by then. */
  cmacs_ai_image__apply_options (req, options);

  return req;
}

DEFUN ("cmacs-ai-image-generate-async",
       Fcmacs_ai_image_generate_async,
       Scmacs_ai_image_generate_async, 3, 4, 0,
       doc: /* Generate an image asynchronously.
CLIENT is a client handle whose provider implements image generation
\(openai / gemini / grok).  PROMPT is the textual description.
CALLBACK is funcalled once with a plist:

  (:images ((:data BYTES :mime M :url U :base64 B :revised R) ...))

or (:error MSG).  BYTES is a unibyte string holding the image, already
materialised whether the provider returned inline data or a URL, so the
caller can write it straight to a file.

Optional OPTIONS is a plist.  Any key may be omitted, and an omitted key
leaves the provider on its own default rather than on ours:

  :model :prompt :negative :system :operation
  :size :custom-size :aspect :resolution :count
  :quality :style :style-preset :background :format :compression
  :seed :guidance :steps :strength :temperature :top-p :top-k
  :moderation :person-generation :watermark :enhance-prompt :language
  :fidelity :partial-images :response-format :user
  :references :mask :extra

:references is a file path, a list of paths, or a list of (PATH . ROLE)
so each reference can say what it is for -- "style", "subject" and so on.
Roles matter for multi-image conditioning, where the provider has no
other way to tell the images apart.

:extra is a plist spliced verbatim into the request body, for parameters
newer than this binding.

Options the chosen model cannot honour are dropped rather than sent and
rejected; see `cmacs-ai-image-models' to check in advance.

Returns a job handle usable with `cmacs-ai-image-cancel'.  */)
  (Lisp_Object client, Lisp_Object prompt, Lisp_Object callback,
   Lisp_Object options)
{
  AiImageGenerator *gen = cmacs_ai_image__generator (client);
  g_autoptr (AiImageRequest) req = cmacs_ai_image__build (prompt, options);
  CmacsAiImageJob *j;
  GCancellable *cancellable;
  guint handle;

  if (cmacs_ai_image_jobs == NULL)
    cmacs_ai_image_jobs
      = g_hash_table_new_full (g_direct_hash, g_direct_equal, NULL,
                               g_object_unref);

  handle = cmacs_ai_image_next_handle++;
  cancellable = g_cancellable_new ();
  g_hash_table_insert (cmacs_ai_image_jobs, GUINT_TO_POINTER (handle),
                       cancellable);

  j = g_new0 (CmacsAiImageJob, 1);
  j->cb_cookie = cmacs_dispatch_callback_register (callback);
  j->handle = handle;

  ai_image_generator_generate_image_async (gen, req, cancellable,
                                           cmacs_ai_image__on_done, j);

  return make_fixnum (handle);
}

DEFUN ("cmacs-ai-image-cancel", Fcmacs_ai_image_cancel,
       Scmacs_ai_image_cancel, 1, 1, 0,
       doc: /* Cancel the in-flight image job HANDLE.
HANDLE comes from `cmacs-ai-image-generate-async'.  Returns t if a job
was still running, nil otherwise.  The job's callback still fires, with
an (:error ...) payload.  */)
  (Lisp_Object handle)
{
  GCancellable *cancellable;

  CHECK_FIXNAT (handle);

  if (cmacs_ai_image_jobs == NULL)
    return Qnil;

  cancellable = g_hash_table_lookup (cmacs_ai_image_jobs,
                                     GUINT_TO_POINTER (XFIXNUM (handle)));
  if (cancellable == NULL)
    return Qnil;

  g_cancellable_cancel (cancellable);
  return Qt;
}

/* ------------------------------------------------------------------ */
/* Synchronous variant                                                  */
/* ------------------------------------------------------------------ */

struct cmacs_ai_image_sync_state
{
  gboolean          done;
  AiImageResponse  *resp;
  GError           *error;
};

static void
cmacs_ai_image__sync_cb (GObject *src, GAsyncResult *res, gpointer user)
{
  struct cmacs_ai_image_sync_state *st = user;

  st->resp = ai_image_generator_generate_image_finish (
    AI_IMAGE_GENERATOR (src), res, &st->error);
  st->done = TRUE;
}

static gboolean
cmacs_ai_image__sync_timeout (gpointer user_data)
{
  g_cancellable_cancel ((GCancellable *) user_data);
  return G_SOURCE_REMOVE;
}

/* Completion for a URL fetch driven by the synchronous path. */
struct cmacs_ai_image_sync_bytes
{
  gboolean  done;
  GBytes   *bytes;
};

static void
cmacs_ai_image__sync_bytes_cb (GObject *src, GAsyncResult *res, gpointer user)
{
  struct cmacs_ai_image_sync_bytes *fs = user;
  GError *err = NULL;

  fs->bytes = ai_generated_image_load_bytes_finish (NULL, res, &err);

  if (err != NULL)
    {
      g_warning ("cmacs-ai: image could not be retrieved: %s", err->message);
      g_error_free (err);
    }

  fs->done = TRUE;
}

DEFUN ("cmacs-ai-image-generate-sync", Fcmacs_ai_image_generate_sync,
       Scmacs_ai_image_generate_sync, 2, 4, 0,
       doc: /* Generate an image synchronously and return the result plist.
CLIENT, PROMPT and OPTIONS are as for `cmacs-ai-image-generate-async'.
Returns (:images (...)) as that function's callback would receive, or
signals `cmacs-ai-error'.

Optional TIMEOUT is in seconds (default 180).

This blocks Emacs for as long as the provider takes, which is tens of
seconds; it exists for callers with no async protocol available, such as
org-babel.  Everything else should use the asynchronous form.  */)
  (Lisp_Object client, Lisp_Object prompt, Lisp_Object options,
   Lisp_Object timeout)
{
  AiImageGenerator *gen;
  g_autoptr (AiImageRequest) req = NULL;
  g_autoptr (GCancellable) cancellable = NULL;
  struct cmacs_ai_image_sync_state st = { FALSE, NULL, NULL };
  GMainContext *ctx;
  GSource *timer;
  CmacsAiImageJob job = { 0, 0, NULL, NULL, 0 };
  Lisp_Object out;
  guint seconds = 180;
  guint n;
  guint i;

  /* Resolve everything that can signal *before* pushing the private
   * context: a longjmp past the pop would leave the thread-default
   * stack unbalanced for the rest of the session. */
  gen = cmacs_ai_image__generator (client);
  req = cmacs_ai_image__build (prompt, options);

  if (!NILP (timeout))
    {
      CHECK_FIXNAT (timeout);
      seconds = (guint) XFIXNUM (timeout);
    }

  ctx = g_main_context_new ();
  g_main_context_push_thread_default (ctx);

  cancellable = g_cancellable_new ();
  timer = g_timeout_source_new_seconds (seconds);
  g_source_set_callback (timer, cmacs_ai_image__sync_timeout, cancellable,
                         NULL);
  g_source_attach (timer, ctx);

  ai_image_generator_generate_image_async (gen, req, cancellable,
                                           cmacs_ai_image__sync_cb, &st);
  while (!st.done)
    g_main_context_iteration (ctx, TRUE);

  /* Resolve URL-backed images while the private context is still
   * current, for the same reason the async path does it: the caller
   * wants bytes, not a link that expires. */
  if (st.resp != NULL)
    {
      n = ai_image_response_get_image_count (st.resp);
      job.resp = st.resp;
      job.bytes = g_ptr_array_new_full (n, (GDestroyNotify) g_bytes_unref);

      for (i = 0; i < n; i++)
        {
          AiGeneratedImage *img = ai_image_response_get_image (st.resp, i);
          GError *err = NULL;
          GBytes *bytes = NULL;

          if (img != NULL)
            {
              bytes = ai_generated_image_get_bytes (img, &err);

              /* get_bytes refuses URLs rather than blocking; fall back
               * to the async loader, driven on this same private
               * context so it cannot re-enter Emacs's dispatch. */
              if (bytes == NULL && ai_generated_image_is_url (img))
                {
                  struct cmacs_ai_image_sync_bytes fs = { FALSE, NULL };

                  g_clear_error (&err);
                  ai_generated_image_load_bytes_async (
                    img, cancellable, cmacs_ai_image__sync_bytes_cb, &fs);
                  while (!fs.done)
                    g_main_context_iteration (ctx, TRUE);
                  bytes = fs.bytes;
                }

              g_clear_error (&err);
            }

          g_ptr_array_add (job.bytes, bytes);
        }
    }

  g_source_destroy (timer);
  g_source_unref (timer);
  g_main_context_pop_thread_default (ctx);
  g_main_context_unref (ctx);

  if (st.resp == NULL)
    {
      /* xsignal longjmps past the g_autoptr cleanups, so free first. */
      Lisp_Object msg = build_string (st.error ? st.error->message
                                      : "image generation failed");
      g_clear_error (&st.error);
      g_clear_pointer (&job.bytes, g_ptr_array_unref);
      xsignal1 (intern ("cmacs-ai-error"), msg);
    }

  out = list2 (intern (":images"), cmacs_ai_image__to_lisp (&job));

  g_clear_pointer (&job.bytes, g_ptr_array_unref);
  g_clear_pointer (&st.resp, ai_image_response_free);
  g_clear_error (&st.error);

  return out;
}

/* ------------------------------------------------------------------ */
/* Capability introspection                                             */
/* ------------------------------------------------------------------ */

DEFUN ("cmacs-ai-image-models", Fcmacs_ai_image_models,
       Scmacs_ai_image_models, 1, 1, 0,
       doc: /* Return the image models CLIENT's provider offers.
CLIENT is a client handle.  The result is a list of plists:

  (:id ID :name NAME :max-references N :max-count N
   :capabilities (SYMBOL ...) :sizes (S ...) :aspect-ratios (R ...)
   :qualities (Q ...) :notes TEXT)

Capabilities say which request options the model will actually honour,
so a command can offer only the ones that apply instead of sending
something the model rejects.  */)
  (Lisp_Object client)
{
  AiImageGenerator *gen = cmacs_ai_image__generator (client);
  GList *models;
  GList *l;
  Lisp_Object out = Qnil;

  models = ai_image_generator_list_image_models (gen);

  for (l = models; l != NULL; l = l->next)
    {
      AiImageModelInfo *info = l->data;
      Lisp_Object plist = Qnil;
      const gchar *s;
      const gchar * const *vec;

      s = ai_image_model_info_get_notes (info);
      if (s)
        plist = Fcons (build_string (s), Fcons (intern (":notes"), plist));

      /* String vectors: qualities, aspect ratios, sizes. */
      {
        static const char *vec_keys[] = { ":qualities", ":aspect-ratios",
                                          ":sizes" };
        const gchar * const *vecs[3];
        int k;

        vecs[0] = ai_image_model_info_get_qualities (info);
        vecs[1] = ai_image_model_info_get_aspect_ratios (info);
        vecs[2] = ai_image_model_info_get_sizes (info);

        for (k = 0; k < 3; k++)
          {
            Lisp_Object items = Qnil;
            int n;

            vec = vecs[k];
            if (vec == NULL)
              continue;

            for (n = 0; vec[n] != NULL; n++)
              items = Fcons (build_string (vec[n]), items);

            plist = Fcons (Fnreverse (items),
                           Fcons (intern (vec_keys[k]), plist));
          }
      }

      /* Capabilities as a list of symbols, from the flags nicknames so
       * the two never drift apart. */
      {
        g_autofree gchar *caps
          = ai_image_capabilities_to_string
              (ai_image_model_info_get_capabilities (info));
        Lisp_Object syms = Qnil;

        if (caps != NULL && caps[0] != '\0')
          {
            g_auto (GStrv) parts = g_strsplit (caps, ",", -1);
            int n;

            for (n = 0; parts[n] != NULL; n++)
              syms = Fcons (intern (parts[n]), syms);
          }

        plist = Fcons (Fnreverse (syms),
                       Fcons (intern (":capabilities"), plist));
      }

      plist = Fcons (make_fixnum (ai_image_model_info_get_max_count (info)),
                     Fcons (intern (":max-count"), plist));
      plist = Fcons (make_fixnum (
                       ai_image_model_info_get_max_reference_images (info)),
                     Fcons (intern (":max-references"), plist));

      s = ai_image_model_info_get_display_name (info);
      plist = Fcons (build_string (s ? s : ""),
                     Fcons (intern (":name"), plist));

      s = ai_image_model_info_get_id (info);
      plist = Fcons (build_string (s ? s : ""),
                     Fcons (intern (":id"), plist));

      out = Fcons (Fnreverse (plist), out);
    }

  g_list_free_full (models, (GDestroyNotify) ai_image_model_info_free);

  return Fnreverse (out);
}

void syms_of_cmacs_ai_image_defuns (void);
void
syms_of_cmacs_ai_image_defuns (void)
{
  defsubr (&Scmacs_ai_image_generate_async);
  defsubr (&Scmacs_ai_image_generate_sync);
  defsubr (&Scmacs_ai_image_cancel);
  defsubr (&Scmacs_ai_image_models);
}

#endif /* HAVE_CMACS_AI */
