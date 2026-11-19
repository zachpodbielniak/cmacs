/* cmacs-sherpa-defuns.c --- the Lisp face of cmacs-sherpa
 *
 * Copyright (C) 2026 Zach Podbielniak
 * SPDX-License-Identifier: AGPL-3.0-or-later
 *
 * Every DEFUN of the subsystem.  This file sees lisp.h and never
 * sherpa's c-api.h; it talks to the engine (cmacs-sherpa-engine.h)
 * through strings, GBytes, integer handles and GVariant results, which
 * it converts to Lisp here, on the main thread.
 *
 * Results are alists with keyword keys, the shape cmacs-whisper uses:
 * a{sv} -> ((:key . value) ...); numeric arrays -> vectors; other
 * arrays -> lists; byte strings -> unibyte strings (PCM).
 *
 * Callbacks are kept in a staticpro'd hash table keyed by a cookie, so
 * a closure handed to an async job stays GC-rooted while only the
 * cookie travels through C.  A job's chunk function can run many times;
 * its done function once, after which the entry is dropped.
 */

#include <config.h>

#ifdef HAVE_CMACS_SHERPA

#include "lisp.h"
#include "coding.h"
#include "cmacs-sherpa.h"
#include "cmacs-sherpa-engine.h"
#include "cmacs-eval-dispatch.h"
#include "cmacs-glib-loop.h"

#include <glib.h>
#include <string.h>

/* cookie (fixnum) -> (DONE . CHUNK).  */
static Lisp_Object cmacs_sherpa__callbacks;
static uint64_t cmacs_sherpa__next_cookie = 1;

/* --- GVariant -> Lisp --- */

static Lisp_Object variant_to_lisp (GVariant *v);

static Lisp_Object
keyword (const char *name)
{
  g_autofree char *k = g_strconcat (":", name, NULL);
  return intern (k);
}

static bool
numeric_type (const GVariantType *t)
{
  return g_variant_type_equal (t, G_VARIANT_TYPE_DOUBLE)
    || g_variant_type_equal (t, G_VARIANT_TYPE_INT64)
    || g_variant_type_equal (t, G_VARIANT_TYPE_UINT64)
    || g_variant_type_equal (t, G_VARIANT_TYPE_INT32)
    || g_variant_type_equal (t, G_VARIANT_TYPE_UINT32)
    || g_variant_type_equal (t, G_VARIANT_TYPE_INT16)
    || g_variant_type_equal (t, G_VARIANT_TYPE_UINT16);
}

static Lisp_Object
variant_to_lisp (GVariant *v)
{
  const GVariantType *t = g_variant_get_type (v);

  if (g_variant_type_equal (t, G_VARIANT_TYPE_VARIANT))
    {
      g_autoptr (GVariant) inner = g_variant_get_variant (v);
      return variant_to_lisp (inner);
    }
  if (g_variant_type_equal (t, G_VARIANT_TYPE_STRING))
    return build_string (g_variant_get_string (v, NULL));
  if (g_variant_type_equal (t, G_VARIANT_TYPE_BOOLEAN))
    return g_variant_get_boolean (v) ? Qt : Qnil;
  if (g_variant_type_equal (t, G_VARIANT_TYPE_DOUBLE))
    return make_float (g_variant_get_double (v));
  if (g_variant_type_equal (t, G_VARIANT_TYPE_INT64))
    return make_int (g_variant_get_int64 (v));
  if (g_variant_type_equal (t, G_VARIANT_TYPE_UINT64))
    return make_uint (g_variant_get_uint64 (v));
  if (g_variant_type_equal (t, G_VARIANT_TYPE_INT32))
    return make_int (g_variant_get_int32 (v));
  if (g_variant_type_equal (t, G_VARIANT_TYPE_UINT32))
    return make_int (g_variant_get_uint32 (v));
  if (g_variant_type_equal (t, G_VARIANT_TYPE_INT16))
    return make_int (g_variant_get_int16 (v));
  if (g_variant_type_equal (t, G_VARIANT_TYPE_UINT16))
    return make_int (g_variant_get_uint16 (v));
  if (g_variant_type_equal (t, G_VARIANT_TYPE_BYTE))
    return make_int (g_variant_get_byte (v));

  /* PCM and other raw bytes.  */
  if (g_variant_type_equal (t, G_VARIANT_TYPE_BYTESTRING))
    {
      gsize n = 0;
      const char *p = g_variant_get_fixed_array (v, &n, 1);
      return make_unibyte_string (p ? p : "", (ptrdiff_t) n);
    }

  /* Dictionary -> alist, in insertion order.  */
  if (g_variant_type_equal (t, G_VARIANT_TYPE_VARDICT))
    {
      Lisp_Object out = Qnil;
      GVariantIter it;
      const char *key;
      GVariant *val;
      g_variant_iter_init (&it, v);
      while (g_variant_iter_next (&it, "{&sv}", &key, &val))
        {
          out = Fcons (Fcons (keyword (key), variant_to_lisp (val)), out);
          g_variant_unref (val);
        }
      return Fnreverse (out);
    }

  /* Arrays of numbers -> vector (cheap to index from Lisp; the shape
     cmacs-whisper's VAD probabilities have).  */
  if (g_variant_type_is_array (t)
      && numeric_type (g_variant_type_element (t)))
    {
      gsize n = g_variant_n_children (v);
      Lisp_Object vec = make_nil_vector ((ptrdiff_t) n);
      for (gsize i = 0; i < n; i++)
        {
          g_autoptr (GVariant) c = g_variant_get_child_value (v, i);
          ASET (vec, (ptrdiff_t) i, variant_to_lisp (c));
        }
      return vec;
    }

  /* Pair tuple -> cons; longer tuple or any other array -> list.  */
  if (g_variant_type_is_tuple (t) && g_variant_n_children (v) == 2)
    {
      g_autoptr (GVariant) a = g_variant_get_child_value (v, 0);
      g_autoptr (GVariant) b = g_variant_get_child_value (v, 1);
      return Fcons (variant_to_lisp (a), variant_to_lisp (b));
    }
  if (g_variant_type_is_container (t))
    {
      Lisp_Object out = Qnil;
      gsize n = g_variant_n_children (v);
      for (gsize i = n; i > 0; i--)
        {
          g_autoptr (GVariant) c = g_variant_get_child_value (v, i - 1);
          out = Fcons (variant_to_lisp (c), out);
        }
      return out;
    }
  return Qnil;
}

/* --- Lisp -> engine arguments --- */

/* Name of a symbol or string, without a leading `:'.  Caller frees.  */
static char *
key_name (Lisp_Object k)
{
  const char *s;
  if (SYMBOLP (k))
    k = SYMBOL_NAME (k);
  CHECK_STRING (k);
  s = SSDATA (k);
  return g_strdup (*s == ':' ? s + 1 : s);
}

/* A config value as the engine wants it: a string.  */
static char *
value_string (Lisp_Object v)
{
  if (NILP (v))
    return g_strdup ("0");
  if (EQ (v, Qt))
    return g_strdup ("1");
  if (FIXNUMP (v))
    return g_strdup_printf ("%" pI "d", XFIXNUM (v));
  if (FLOATP (v))
    {
      char buf[G_ASCII_DTOSTR_BUF_SIZE];
      return g_strdup (g_ascii_dtostr (buf, sizeof buf, XFLOAT_DATA (v)));
    }
  if (SYMBOLP (v))
    return g_strdup (SSDATA (SYMBOL_NAME (v)));
  CHECK_STRING (v);
  return g_strdup (SSDATA (ENCODE_UTF_8 (v)));
}

/* Plist (:k v ...) or alist ((k . v) ...) -> string map; nil -> NULL.  */
static GHashTable *
map_from_lisp (Lisp_Object obj)
{
  GHashTable *m;

  if (NILP (obj))
    return NULL;
  CHECK_LIST (obj);
  m = g_hash_table_new_full (g_str_hash, g_str_equal, g_free, g_free);
  if (CONSP (XCAR (obj)))
    {
      for (Lisp_Object t = obj; CONSP (t); t = XCDR (t))
        {
          Lisp_Object e = XCAR (t);
          CHECK_CONS (e);
          g_hash_table_insert (m, key_name (XCAR (e)),
                               value_string (XCDR (e)));
        }
    }
  else
    {
      for (Lisp_Object t = obj; CONSP (t) && CONSP (XCDR (t));
           t = XCDR (XCDR (t)))
        g_hash_table_insert (m, key_name (XCAR (t)),
                             value_string (XCAR (XCDR (t))));
    }
  return m;
}

static CmacsSherpaKind
kind_arg (Lisp_Object kind)
{
  g_autofree char *name = key_name (kind);
  CmacsSherpaKind k;
  if (!cmacs_sherpa_kind_from_name (name, &k))
    xsignal2 (Qerror, build_string ("Unknown sherpa kind"), kind);
  return k;
}

static CmacsSherpaOp
op_arg (Lisp_Object op)
{
  static const struct { const char *name; CmacsSherpaOp op; } ops[] = {
    { "run", CMACS_SHERPA_OP_RUN },
    { "feed", CMACS_SHERPA_OP_FEED },
    { "finish", CMACS_SHERPA_OP_FINISH },
    { "reset", CMACS_SHERPA_OP_RESET },
    { "enroll", CMACS_SHERPA_OP_ENROLL },
    { "add-embedding", CMACS_SHERPA_OP_ADD_EMBEDDING },
    { "identify", CMACS_SHERPA_OP_IDENTIFY },
    { "verify", CMACS_SHERPA_OP_VERIFY },
    { "remove", CMACS_SHERPA_OP_REMOVE },
    { "list", CMACS_SHERPA_OP_LIST },
  };
  g_autofree char *name = key_name (op);
  for (size_t i = 0; i < G_N_ELEMENTS (ops); i++)
    if (strcmp (ops[i].name, name) == 0)
      return ops[i].op;
  xsignal2 (Qerror, build_string ("Unknown sherpa operation"), op);
}

static guint64
handle_arg (Lisp_Object h)
{
  if (NILP (h))
    return 0;
  CHECK_FIXNAT (h);
  return (guint64) XFIXNAT (h);
}

/* --- callbacks --- */

static uint64_t
callbacks_put (Lisp_Object done, Lisp_Object chunk)
{
  uint64_t c = cmacs_sherpa__next_cookie++;
  Fputhash (make_uint (c), Fcons (done, chunk), cmacs_sherpa__callbacks);
  return c;
}

static void
callbacks_drop (gpointer cookie)
{
  Fremhash (make_uint (GPOINTER_TO_SIZE (cookie)),
            cmacs_sherpa__callbacks);
}

static void
on_done (GVariant *result, gpointer cookie)
{
  Lisp_Object key = make_uint (GPOINTER_TO_SIZE (cookie));
  Lisp_Object cell = Fgethash (key, cmacs_sherpa__callbacks, Qnil);
  Lisp_Object arg;
  if (!CONSP (cell) || NILP (XCAR (cell)))
    return;
  arg = variant_to_lisp (result);
  cmacs_dispatch_safe_callN_value (XCAR (cell), 1, &arg);
}

static void
on_chunk (GVariant *chunk, gpointer cookie)
{
  Lisp_Object key = make_uint (GPOINTER_TO_SIZE (cookie));
  Lisp_Object cell = Fgethash (key, cmacs_sherpa__callbacks, Qnil);
  Lisp_Object arg;
  if (!CONSP (cell) || NILP (XCDR (cell)))
    return;
  arg = variant_to_lisp (chunk);
  cmacs_dispatch_safe_callN_value (XCDR (cell), 1, &arg);
}

/* --- DEFUNs --- */

DEFUN ("cmacs-sherpa-supported-p", Fcmacs_sherpa_supported_p,
       Scmacs_sherpa_supported_p, 0, 0, 0,
       doc: /* Return non-nil: sherpa-onnx is built into this cmacs.  */)
  (void)
{
  return Qt;
}

DEFUN ("cmacs-sherpa-version", Fcmacs_sherpa_version,
       Scmacs_sherpa_version, 0, 0, 0,
       doc: /* Return the linked sherpa-onnx version string.  */)
  (void)
{
  return build_string (cmacs_sherpa_version ());
}

DEFUN ("cmacs-sherpa-onnxruntime-version", Fcmacs_sherpa_onnxruntime_version,
       Scmacs_sherpa_onnxruntime_version, 0, 0, 0,
       doc: /* Return the version of the onnxruntime sherpa-onnx runs on.  */)
  (void)
{
  return build_string (cmacs_sherpa_onnxruntime_version ());
}

DEFUN ("cmacs-sherpa-kinds", Fcmacs_sherpa_kinds, Scmacs_sherpa_kinds,
       0, 0, 0,
       doc: /* Return the list of handle kinds, as symbols.
`asr' (offline recognizer), `stream-asr' and its `stream's, `kws' and
its `kws-stream's, `vad', `tts', `diarize', `speaker', `punct',
`punct-online', `lid', `tag', `denoise', `denoise-stream', `separate'.  */)
  (void)
{
  Lisp_Object out = Qnil;
  for (int k = CMACS_SHERPA_N_KINDS - 1; k >= 0; k--)
    out = Fcons (intern (cmacs_sherpa_kind_name ((CmacsSherpaKind) k)), out);
  return out;
}

DEFUN ("cmacs-sherpa-config-keys", Fcmacs_sherpa_config_keys,
       Scmacs_sherpa_config_keys, 1, 1, 0,
       doc: /* Return the config keys KIND accepts, as (KEY . TYPE) conses.
KEY is the sherpa-onnx struct path with `_' spelled `-', e.g.
"model-config.whisper.encoder"; TYPE is "string", "int" or "float".  A
key may omit a leading "model-config." or "model.".  */)
  (Lisp_Object kind)
{
  g_autoptr (GVariant) v = cmacs_sherpa_config_keys (kind_arg (kind));
  return variant_to_lisp (v);
}

DEFUN ("cmacs-sherpa-open", Fcmacs_sherpa_open, Scmacs_sherpa_open, 2, 3, 0,
       doc: /* Load a sherpa-onnx engine of KIND from CONFIG; return its handle.
CONFIG is a plist or alist of config keys (see `cmacs-sherpa-config-keys')
to values; numbers and t/nil are converted.  PARENT is the parent handle
for a `stream' or `kws-stream'.  Blocks while the model loads; prefer
`cmacs-sherpa-open-async' for anything large.  */)
  (Lisp_Object kind, Lisp_Object config, Lisp_Object parent)
{
  g_autoptr (GHashTable) m = map_from_lisp (config);
  g_autoptr (GError) err = NULL;
  guint64 h = cmacs_sherpa_open (kind_arg (kind), m, handle_arg (parent),
                                 &err);
  if (!h)
    xsignal1 (Qerror, build_string (err ? err->message : "open failed"));
  return make_uint (h);
}

DEFUN ("cmacs-sherpa-open-async", Fcmacs_sherpa_open_async,
       Scmacs_sherpa_open_async, 3, 4, 0,
       doc: /* Load an engine of KIND from CONFIG on a loader thread.
CALLBACK is called on the main thread with ((:handle . H)) or
((:error . MESSAGE)).  PARENT is as for `cmacs-sherpa-open'.  */)
  (Lisp_Object kind, Lisp_Object config, Lisp_Object callback,
   Lisp_Object parent)
{
  g_autoptr (GHashTable) m = map_from_lisp (config);
  CmacsSherpaKind k = kind_arg (kind);
  uint64_t cookie = callbacks_put (callback, Qnil);
  cmacs_sherpa_open_async (k, m, handle_arg (parent), on_done,
                           GSIZE_TO_POINTER (cookie),
                           callbacks_drop);
  return Qt;
}

DEFUN ("cmacs-sherpa-close", Fcmacs_sherpa_close, Scmacs_sherpa_close,
       1, 1, 0,
       doc: /* Close sherpa HANDLE.  Queued jobs on it complete as cancelled.
Return non-nil if HANDLE was open.  */)
  (Lisp_Object handle)
{
  return cmacs_sherpa_close (handle_arg (handle)) ? Qt : Qnil;
}

DEFUN ("cmacs-sherpa-submit", Fcmacs_sherpa_submit, Scmacs_sherpa_submit,
       3, 8, 0,
       doc: /* Queue operation OP on HANDLE; return a job id.
OP is one of `run', `feed', `finish', `reset' (streams), or for a
`speaker' handle `enroll', `add-embedding', `identify', `verify',
`remove', `list'.
CALLBACK is called once, on the main thread, with the result alist (or
((:error . MESSAGE)), or ((:cancelled . t))).
PCM is a unibyte string of S16LE mono samples (for `add-embedding', a
vector of floats).  TEXT is text to speak or punctuate, or a speaker
name.  PARAMS is a plist of per-job options.  CHUNK-FN, if non-nil, is
called with partial results as they arrive (TTS audio, progress).
SAMPLE-RATE is PCM's rate, default 16000.  */)
  (Lisp_Object handle, Lisp_Object op, Lisp_Object callback,
   Lisp_Object pcm, Lisp_Object text, Lisp_Object params,
   Lisp_Object chunk_fn, Lisp_Object sample_rate)
{
  CmacsSherpaOp o = op_arg (op);
  g_autoptr (GBytes) bytes = NULL;
  g_autoptr (GHashTable) p = map_from_lisp (params);
  g_autoptr (GError) err = NULL;
  g_autofree char *t = NULL;
  int rate = 0;
  uint64_t cookie;
  guint64 job;

  if (!NILP (sample_rate))
    {
      CHECK_FIXNAT (sample_rate);
      rate = (int) XFIXNAT (sample_rate);
    }
  if (VECTORP (pcm))
    {
      /* Raw float embedding (add-embedding).  */
      ptrdiff_t n = ASIZE (pcm);
      float *f = g_new (float, n ? n : 1);
      for (ptrdiff_t i = 0; i < n; i++)
        {
          Lisp_Object x = AREF (pcm, i);
          CHECK_NUMBER (x);
          f[i] = (float) XFLOATINT (x);
        }
      bytes = g_bytes_new_take (f, (gsize) n * sizeof (float));
    }
  else if (!NILP (pcm))
    {
      CHECK_STRING (pcm);
      if (STRING_MULTIBYTE (pcm))
        error ("PCM must be a unibyte string");
      bytes = g_bytes_new (SDATA (pcm), (gsize) SBYTES (pcm));
    }
  if (!NILP (text))
    {
      CHECK_STRING (text);
      t = g_strdup (SSDATA (ENCODE_UTF_8 (text)));
    }

  cookie = callbacks_put (callback, chunk_fn);
  job = cmacs_sherpa_submit (handle_arg (handle), o, bytes, rate, t, p,
                             on_done, NILP (chunk_fn) ? NULL : on_chunk,
                             GSIZE_TO_POINTER (cookie),
                             callbacks_drop, &err);
  if (!job)
    {
      callbacks_drop (GSIZE_TO_POINTER (cookie));
      xsignal1 (Qerror, build_string (err ? err->message : "submit failed"));
    }
  return make_uint (job);
}

DEFUN ("cmacs-sherpa-run", Fcmacs_sherpa_run, Scmacs_sherpa_run, 2, 6, 0,
       doc: /* Run operation OP on HANDLE on this thread; return the result alist.
Arguments are as for `cmacs-sherpa-submit' (PCM, TEXT, PARAMS,
SAMPLE-RATE), without callbacks.  Blocks until done -- for surfaces that
answer synchronously (MCP, D-Bus); interactive code uses the async
`cmacs-sherpa-submit'.  Signals on failure.  */)
  (Lisp_Object handle, Lisp_Object op, Lisp_Object pcm, Lisp_Object text,
   Lisp_Object params, Lisp_Object sample_rate)
{
  CmacsSherpaOp o = op_arg (op);
  g_autoptr (GBytes) bytes = NULL;
  g_autoptr (GHashTable) p = map_from_lisp (params);
  g_autoptr (GError) err = NULL;
  g_autoptr (GVariant) v = NULL;
  g_autofree char *t = NULL;
  int rate = 0;

  if (!NILP (sample_rate))
    {
      CHECK_FIXNAT (sample_rate);
      rate = (int) XFIXNAT (sample_rate);
    }
  if (!NILP (pcm))
    {
      CHECK_STRING (pcm);
      if (STRING_MULTIBYTE (pcm))
        error ("PCM must be a unibyte string");
      bytes = g_bytes_new (SDATA (pcm), (gsize) SBYTES (pcm));
    }
  if (!NILP (text))
    {
      CHECK_STRING (text);
      t = g_strdup (SSDATA (ENCODE_UTF_8 (text)));
    }
  v = cmacs_sherpa_run_sync (handle_arg (handle), o, bytes, rate, t, p, &err);
  if (!v)
    xsignal1 (Qerror, build_string (err ? err->message : "run failed"));
  return variant_to_lisp (v);
}

DEFUN ("cmacs-sherpa-cancel", Fcmacs_sherpa_cancel, Scmacs_sherpa_cancel,
       1, 1, 0,
       doc: /* Cancel sherpa JOB.  Its callback still runs, with ((:cancelled . t)).
Running speech generation stops at its next sentence.  Return non-nil
if JOB was still pending.  */)
  (Lisp_Object job)
{
  return cmacs_sherpa_cancel (handle_arg (job)) ? Qt : Qnil;
}

DEFUN ("cmacs-sherpa-info", Fcmacs_sherpa_info, Scmacs_sherpa_info, 1, 1, 0,
       doc: /* Return static facts about HANDLE as an alist, or nil if unknown.
E.g. :sample-rate and :num-speakers for `tts', :dim for `speaker',
:window for `vad', :stems for `separate'.  */)
  (Lisp_Object handle)
{
  g_autoptr (GVariant) v = cmacs_sherpa_info (handle_arg (handle));
  return v ? variant_to_lisp (v) : Qnil;
}

DEFUN ("cmacs-sherpa-loaded", Fcmacs_sherpa_loaded, Scmacs_sherpa_loaded,
       0, 0, 0,
       doc: /* Return one alist per open sherpa handle.
Keys: :id :kind :model :parent :jobs :pending :opened :last-used.  */)
  (void)
{
  g_autoptr (GVariant) v = cmacs_sherpa_list ();
  return variant_to_lisp (v);
}

DEFUN ("cmacs-sherpa-read-wav", Fcmacs_sherpa_read_wav,
       Scmacs_sherpa_read_wav, 1, 1, 0,
       doc: /* Read PCM WAV FILE; return (PCM . SAMPLE-RATE).
PCM is a unibyte string of S16LE mono samples (the first channel).  Any
sample rate is accepted; recognizers resample.  */)
  (Lisp_Object file)
{
  g_autoptr (GError) err = NULL;
  g_autoptr (GBytes) b = NULL;
  int rate = 0;
  gsize n = 0;
  const char *p;

  CHECK_STRING (file);
  file = Fexpand_file_name (file, Qnil);
  b = cmacs_sherpa_read_wave (SSDATA (ENCODE_FILE (file)), &rate, &err);
  if (!b)
    xsignal1 (Qerror, build_string (err ? err->message : "read failed"));
  p = g_bytes_get_data (b, &n);
  return Fcons (make_unibyte_string (p ? p : "", (ptrdiff_t) n),
                make_int (rate));
}

DEFUN ("cmacs-sherpa-kws-tokenize", Fcmacs_sherpa_kws_tokenize,
       Scmacs_sherpa_kws_tokenize, 2, 3, 0,
       doc: /* Spell PHRASE for the keyword model whose tokens file is TOKENS.
Return one keyword line, e.g. "▁JA R VI S @jarvis", suitable for the
:keywords config of a `kws-stream'.  Non-nil CJK means a character-level
model.  Signals if a character has no token in the model.  */)
  (Lisp_Object tokens, Lisp_Object phrase, Lisp_Object cjk)
{
  g_autoptr (GError) err = NULL;
  g_autofree char *line = NULL;

  CHECK_STRING (tokens);
  CHECK_STRING (phrase);
  tokens = Fexpand_file_name (tokens, Qnil);
  line = cmacs_sherpa_kws_tokenize (SSDATA (ENCODE_FILE (tokens)),
                                    SSDATA (ENCODE_UTF_8 (phrase)),
                                    !NILP (cjk), &err);
  if (!line)
    xsignal1 (Qerror, build_string (err ? err->message : "tokenize failed"));
  return build_string (line);
}

void
syms_of_cmacs_sherpa_defuns (void)
{
  cmacs_sherpa__callbacks = CALLN (Fmake_hash_table, QCtest, Qeql);
  staticpro (&cmacs_sherpa__callbacks);

  defsubr (&Scmacs_sherpa_supported_p);
  defsubr (&Scmacs_sherpa_version);
  defsubr (&Scmacs_sherpa_onnxruntime_version);
  defsubr (&Scmacs_sherpa_kinds);
  defsubr (&Scmacs_sherpa_config_keys);
  defsubr (&Scmacs_sherpa_open);
  defsubr (&Scmacs_sherpa_open_async);
  defsubr (&Scmacs_sherpa_close);
  defsubr (&Scmacs_sherpa_submit);
  defsubr (&Scmacs_sherpa_run);
  defsubr (&Scmacs_sherpa_cancel);
  defsubr (&Scmacs_sherpa_info);
  defsubr (&Scmacs_sherpa_loaded);
  defsubr (&Scmacs_sherpa_read_wav);
  defsubr (&Scmacs_sherpa_kws_tokenize);
}

#endif /* HAVE_CMACS_SHERPA */
