/* Camera hand tracking for CMacs -- onnxruntime sessions.

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

SPDX-License-Identifier: AGPL-3.0-or-later

A model is one ORT session on the CPU provider, one image input and any
number of float outputs, read back in the model's own order.  Every
call here runs on the inference thread (cmacs-handtrack-worker.c); ORT
sessions may be run from any thread.  Built only with HAVE_ONNXRUNTIME;
without it the same functions say so, and hand tracking reports itself
unavailable instead of failing to build.  */

#include <config.h>

#ifdef HAVE_CMACS_HANDTRACK

#include <string.h>

#include "cmacs-handtrack.h"

#ifdef HAVE_ONNXRUNTIME

#include <onnxruntime_c_api.h>

#define HT_MAX_IO 8

struct CmacsHtModel
{
  OrtSession *session;
  char *in_name;
  char *out_names[HT_MAX_IO];
  size_t n_out;
  int64_t in_dims[4];
  int size;
  bool nchw;
};

static const OrtApi *ort;
static OrtEnv *ort_env;
static GMutex ort_lock;          /* env creation */

/* A failed status as a message (and release it).  True when STATUS was
   success.  */
static bool
ort_ok (OrtStatus *status, const char *what, char **err)
{
  if (status == NULL)
    return true;
  if (err != NULL && *err == NULL)
    *err = g_strdup_printf ("%s: %s", what, ort->GetErrorMessage (status));
  ort->ReleaseStatus (status);
  return false;
}

/* Release a status nobody needs (ORT marks its results must-use).  */
static void
ort_drop (OrtStatus *status)
{
  if (status != NULL)
    ort->ReleaseStatus (status);
}

static bool
ort_init (char **err)
{
  bool ok = true;

  g_mutex_lock (&ort_lock);
  if (ort == NULL)
    {
      const OrtApiBase *base = OrtGetApiBase ();
      ort = base != NULL ? base->GetApi (ORT_API_VERSION) : NULL;
      if (ort == NULL)
        {
          *err = g_strdup ("onnxruntime is older than the headers cmacs "
                           "was built with");
          ok = false;
        }
    }
  if (ok && ort_env == NULL)
    ok = ort_ok (ort->CreateEnv (ORT_LOGGING_LEVEL_WARNING, "cmacs-handtrack",
                                 &ort_env),
                 "CreateEnv", err);
  g_mutex_unlock (&ort_lock);
  return ok;
}

bool
cmacs_ht_inference_available (void)
{
  return true;
}

void
cmacs_ht_model_free (CmacsHtModel *m)
{
  size_t i;

  if (m == NULL)
    return;
  if (m->session != NULL)
    ort->ReleaseSession (m->session);
  g_free (m->in_name);
  for (i = 0; i < m->n_out; i++)
    g_free (m->out_names[i]);
  g_free (m);
}

CmacsHtModel *
cmacs_ht_model_load (const char *path, int threads, char **err)
{
  CmacsHtModel *m;
  OrtSessionOptions *opts = NULL;
  OrtAllocator *alloc = NULL;
  OrtTypeInfo *ti = NULL;
  const OrtTensorTypeAndShapeInfo *tsi = NULL;
  size_t n_in = 0, n_out = 0, nd = 0, i;
  char *name = NULL;

  if (!ort_init (err))
    return NULL;
  m = g_new0 (CmacsHtModel, 1);
  if (!ort_ok (ort->CreateSessionOptions (&opts), "CreateSessionOptions", err)
      || !ort_ok (ort->SetIntraOpNumThreads (opts, MAX (threads, 1)),
                  "SetIntraOpNumThreads", err)
      || !ort_ok (ort->SetSessionGraphOptimizationLevel (opts, ORT_ENABLE_ALL),
                  "SetSessionGraphOptimizationLevel", err)
      || !ort_ok (ort->CreateSession (ort_env, path, opts, &m->session),
                  "CreateSession", err))
    goto fail;
  ort->ReleaseSessionOptions (opts);
  opts = NULL;

  if (!ort_ok (ort->GetAllocatorWithDefaultOptions (&alloc), "allocator", err)
      || !ort_ok (ort->SessionGetInputCount (m->session, &n_in), "inputs", err)
      || !ort_ok (ort->SessionGetOutputCount (m->session, &n_out), "outputs",
                  err))
    goto fail;
  if (n_in != 1 || n_out == 0 || n_out > HT_MAX_IO)
    {
      *err = g_strdup_printf ("%s: expected one image input and up to %d "
                              "outputs, found %zu and %zu", path, HT_MAX_IO,
                              n_in, n_out);
      goto fail;
    }
  if (!ort_ok (ort->SessionGetInputName (m->session, 0, alloc, &name),
               "input name", err))
    goto fail;
  m->in_name = g_strdup (name);
  ort_drop (ort->AllocatorFree (alloc, name));
  for (i = 0; i < n_out; i++)
    {
      if (!ort_ok (ort->SessionGetOutputName (m->session, i, alloc, &name),
                   "output name", err))
        goto fail;
      m->out_names[i] = g_strdup (name);
      ort_drop (ort->AllocatorFree (alloc, name));
      m->n_out = i + 1;
    }

  /* The input: [1, S, S, 3] (NHWC, as MediaPipe's conversions are) or
     [1, 3, S, S].  A dynamic size (-1) takes the pipeline's own.  */
  if (!ort_ok (ort->SessionGetInputTypeInfo (m->session, 0, &ti), "input type",
               err)
      || !ort_ok (ort->CastTypeInfoToTensorInfo (ti, &tsi), "input tensor", err)
      || !ort_ok (ort->GetDimensionsCount (tsi, &nd), "input rank", err))
    goto fail;
  if (nd != 4)
    {
      *err = g_strdup_printf ("%s: the input is not an image (rank %zu)", path,
                              nd);
      goto fail;
    }
  if (!ort_ok (ort->GetDimensions (tsi, m->in_dims, 4), "input dims", err))
    goto fail;
  ort->ReleaseTypeInfo (ti);
  ti = NULL;
  m->nchw = m->in_dims[1] == 3;
  m->size = (int) (m->nchw ? m->in_dims[2] : m->in_dims[1]);
  m->in_dims[0] = 1;
  return m;

fail:
  if (ti != NULL)
    ort->ReleaseTypeInfo (ti);
  if (opts != NULL)
    ort->ReleaseSessionOptions (opts);
  cmacs_ht_model_free (m);
  return NULL;
}

bool
cmacs_ht_model_input (CmacsHtModel *m, int *size, bool *nchw)
{
  *size = m->size;
  *nchw = m->nchw;
  return m->size > 0;
}

int
cmacs_ht_model_run (CmacsHtModel *m, const float *input, float **out,
                    gsize *n, int max, char **err)
{
  OrtMemoryInfo *mem = NULL;
  OrtValue *in = NULL, *outs[HT_MAX_IO];
  const char *in_names[1];
  const char *out_names[HT_MAX_IO];
  int64_t dims[4];
  size_t i, count = (size_t) m->size * (size_t) m->size * 3;
  int got = -1;

  memset (outs, 0, sizeof outs);
  memcpy (dims, m->in_dims, sizeof dims);
  if (m->nchw)
    {
      dims[1] = 3;
      dims[2] = dims[3] = m->size;
    }
  else
    {
      dims[1] = dims[2] = m->size;
      dims[3] = 3;
    }
  in_names[0] = m->in_name;
  for (i = 0; i < m->n_out; i++)
    out_names[i] = m->out_names[i];

  if (!ort_ok (ort->CreateCpuMemoryInfo (OrtArenaAllocator, OrtMemTypeDefault,
                                         &mem), "memory info", err)
      || !ort_ok (ort->CreateTensorWithDataAsOrtValue
                    (mem, (void *) input, count * sizeof (float), dims, 4,
                     ONNX_TENSOR_ELEMENT_DATA_TYPE_FLOAT, &in),
                  "input tensor", err)
      || !ort_ok (ort->Run (m->session, NULL, in_names,
                            (const OrtValue *const *) &in, 1, out_names,
                            m->n_out, outs),
                  "run", err))
    goto done;

  for (i = 0; i < m->n_out && (int) i < max; i++)
    {
      OrtTensorTypeAndShapeInfo *info = NULL;
      size_t elems = 0;
      float *data = NULL;

      if (!ort_ok (ort->GetTensorTypeAndShape (outs[i], &info), "output",
                   err))
        goto done;
      if (!ort_ok (ort->GetTensorShapeElementCount (info, &elems), "output",
                   err))
        {
          ort->ReleaseTensorTypeAndShapeInfo (info);
          goto done;
        }
      ort->ReleaseTensorTypeAndShapeInfo (info);
      if (!ort_ok (ort->GetTensorMutableData (outs[i], (void **) &data),
                   "output data", err))
        goto done;
      out[i] = g_memdup2 (data, elems * sizeof (float));
      n[i] = elems;
    }
  got = (int) MIN (m->n_out, (size_t) max);

done:
  for (i = 0; i < HT_MAX_IO; i++)
    if (outs[i] != NULL)
      ort->ReleaseValue (outs[i]);
  if (in != NULL)
    ort->ReleaseValue (in);
  if (mem != NULL)
    ort->ReleaseMemoryInfo (mem);
  return got;
}

#else /* !HAVE_ONNXRUNTIME */

struct CmacsHtModel
{
  int unused;
};

bool
cmacs_ht_inference_available (void)
{
  return false;
}

CmacsHtModel *
cmacs_ht_model_load (const char *path, int threads, char **err)
{
  (void) path;
  (void) threads;
  *err = g_strdup ("cmacs was built without onnxruntime (install "
                   "onnxruntime-devel and reconfigure)");
  return NULL;
}

void
cmacs_ht_model_free (CmacsHtModel *m)
{
  g_free (m);
}

bool
cmacs_ht_model_input (CmacsHtModel *m, int *size, bool *nchw)
{
  (void) m;
  *size = 0;
  *nchw = false;
  return false;
}

int
cmacs_ht_model_run (CmacsHtModel *m, const float *input, float **out,
                    gsize *n, int max, char **err)
{
  (void) m; (void) input; (void) out; (void) n; (void) max;
  *err = g_strdup ("no onnxruntime");
  return -1;
}

#endif /* HAVE_ONNXRUNTIME */

#endif /* HAVE_CMACS_HANDTRACK */
