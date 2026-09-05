/* cmacs-brigade-index.c --- the flat fp16 vector index.
 *
 * Copyright (C) 2026 Zach Podbielniak
 * SPDX-License-Identifier: AGPL-3.0-or-later
 *
 * A brute-force index, on purpose.  At the scale this serves -- a few
 * hundred thousand chunks -- the scan is memory-bandwidth-bound, not
 * compute-bound: 300k x 768 fp16 is 460 MB to read and roughly 10 ms
 * warm.  An ANN structure would add a build step, a tuning knob, a
 * recall cliff and a second thing to invalidate, to save single-digit
 * milliseconds.  Revisit somewhere north of a few million chunks.
 *
 * Layout, one file per concern rather than a single blob:
 *
 *   vectors.f16   64 B header, then count x dim fp16, L2-NORMALISED at
 *                 write time so a query is a pure dot product with no
 *                 per-vector sqrt in the inner loop
 *   meta.bin      64 B header, then one fixed-size record per chunk
 *   strings.bin   NUL-separated paths and breadcrumbs
 *   manifest.eld  human-readable: schema version, embedding model and
 *                 its digest, dim, chunk params, epoch, counts
 *
 * Keeping vectors.f16 a bare contiguous array is the whole reason for
 * the split: the scan is one aligned loop over one mapping with no
 * pointer chasing and no per-record branching.  Metadata is touched only
 * for the handful of survivors after the scan.
 *
 * fp16 -> f32 conversion dispatches at RUNTIME on
 * __builtin_cpu_supports("f16c"), with a table-driven scalar fallback.
 * The translation unit is never compiled with -mf16c: this binary is
 * built in a container and runs on aarch64 as well as Zen, and a
 * compile-time commitment would produce something that SIGILLs on the
 * host it was built for. */

#include <config.h>

#ifdef HAVE_CMACS_AI_BRIGADE

#include "lisp.h"
#include "cmacs-brigade.h"

#include <glib.h>
#include <glib/gstdio.h>
#include <string.h>
#include <math.h>
#include <fcntl.h>
#include <unistd.h>
#include <sys/mman.h>
#include <sys/stat.h>
#include <sys/file.h>

#if defined __x86_64__ || defined __i386__
# if !defined __has_include || __has_include(<immintrin.h>)
#  include <immintrin.h>
#  define BRIGADE_MAY_HAVE_F16C 1
# endif
#endif

#define VEC_MAGIC   "CMBRGVEC"
#define INDEX_FORMAT_VERSION 1

typedef struct
{
  gchar    magic[8];
  guint32  version;
  guint32  dim;
  guint64  count;
  guint64  flags;
  guint8   pad[32];
} IndexHeader;

/* ── fp16 -> f32 ──────────────────────────────────────────────────── */

/* Scalar reference conversion.  Used to build the lookup table and as
 * the fallback path; correctness here is what the F16C path is checked
 * against in the tests. */
static float
half_to_float_scalar (guint16 h)
{
  guint32 sign = (h & 0x8000u) << 16;
  guint32 exp  = (h >> 10) & 0x1Fu;
  guint32 mant = h & 0x3FFu;
  guint32 bits;

  if (exp == 0)
    {
      if (mant == 0) { bits = sign; }
      else
        {
          /* Subnormal: renormalise. */
          exp = 127 - 15 + 1;
          while ((mant & 0x400u) == 0) { mant <<= 1; exp--; }
          mant &= 0x3FFu;
          bits = sign | (exp << 23) | (mant << 13);
        }
    }
  else if (exp == 0x1Fu)
    bits = sign | 0x7F800000u | (mant << 13);
  else
    bits = sign | ((exp - 15 + 127) << 23) | (mant << 13);

  {
    float f;
    memcpy (&f, &bits, sizeof f);
    return f;
  }
}

static float *half_lut;           /* 65536 entries, built once */
static gboolean have_f16c;
static gboolean dispatch_ready;

static void
index_dispatch_init (void)
{
  if (dispatch_ready) return;
  dispatch_ready = TRUE;

#ifdef BRIGADE_MAY_HAVE_F16C
  have_f16c = __builtin_cpu_supports ("f16c") && __builtin_cpu_supports ("avx2");
#else
  have_f16c = FALSE;
#endif

  if (!have_f16c)
    {
      /* 256 KiB, built once per process.  Cheaper than 300k x 768
       * scalar conversions on every query, and it makes the fallback
       * fast enough that a machine without F16C is merely slower rather
       * than unusable. */
      guint32 i;
      half_lut = g_new (float, 65536);
      for (i = 0; i < 65536; i++)
        half_lut[i] = half_to_float_scalar ((guint16) i);
    }
}

gboolean
cmacs_brigade_index_using_f16c (void)
{
  index_dispatch_init ();
  return have_f16c;
}

/* Dot product of a normalised f32 query against a normalised fp16 row.
 * Both sides are unit vectors, so this is the cosine similarity.
 *
 * Two implementations, chosen at runtime.  The F16C one carries a
 * function-level target attribute rather than the translation unit being
 * built with -mf16c: GCC will not inline the intrinsics without the ISA
 * enabled somewhere, but enabling it for the whole file would let the
 * compiler emit AVX in the dispatch code and the scalar fallback too,
 * which is precisely how a binary ends up SIGILLing on the machine it
 * was meant to fall back on. */

static float
dot_row_scalar (const float *q, const guint16 *row, guint32 dim)
{
  float acc = 0.0f;
  guint32 i;

  for (i = 0; i < dim; i++)
    acc += q[i] * (half_lut ? half_lut[row[i]] : half_to_float_scalar (row[i]));
  return acc;
}

#ifdef BRIGADE_MAY_HAVE_F16C
__attribute__ ((target ("avx2,f16c")))
static float
dot_row_f16c (const float *q, const guint16 *row, guint32 dim)
{
  __m256 sum = _mm256_setzero_ps ();
  float tmp[8];
  float acc;
  guint32 i = 0;

  for (; i + 8 <= dim; i += 8)
    {
      __m128i h  = _mm_loadu_si128 ((const __m128i *) (row + i));
      __m256  v  = _mm256_cvtph_ps (h);
      __m256  qv = _mm256_loadu_ps (q + i);
      sum = _mm256_add_ps (sum, _mm256_mul_ps (qv, v));
    }

  _mm256_storeu_ps (tmp, sum);
  acc = tmp[0] + tmp[1] + tmp[2] + tmp[3] + tmp[4] + tmp[5] + tmp[6] + tmp[7];

  /* Tail: dimensions are typically a multiple of 8 (768 for
   * nomic-embed-text), but nothing enforces that, so finish scalar. */
  for (; i < dim; i++)
    acc += q[i] * half_to_float_scalar (row[i]);

  return acc;
}
#endif

static float
dot_row (const float *q, const guint16 *row, guint32 dim)
{
#ifdef BRIGADE_MAY_HAVE_F16C
  if (have_f16c) return dot_row_f16c (q, row, dim);
#endif
  return dot_row_scalar (q, row, dim);
}

/* ── float -> fp16 (write side) ───────────────────────────────────── */

static guint16
float_to_half (float f)
{
  guint32 bits;
  guint32 sign, exp;
  gint32 e;

  memcpy (&bits, &f, sizeof bits);
  sign = (bits >> 16) & 0x8000u;
  e = (gint32) ((bits >> 23) & 0xFFu) - 127 + 15;

  if (e <= 0)
    {
      /* Underflow to zero.  Values this small carry no signal in a
       * normalised embedding. */
      return (guint16) sign;
    }
  if (e >= 0x1F) return (guint16) (sign | 0x7C00u);

  exp = (guint32) e;
  return (guint16) (sign | (exp << 10) | ((bits >> 13) & 0x3FFu));
}

/* ── Mapping ──────────────────────────────────────────────────────── */

struct _CmacsBrigadeIndex
{
  gchar     *dir;
  int        vec_fd;
  void      *vec_map;
  gsize      vec_len;
  guint32    dim;
  guint64    count;
};

static gchar *
index_path (const gchar *dir, const gchar *name)
{
  return g_build_filename (dir, name, NULL);
}

CmacsBrigadeIndex *
cmacs_brigade_index_open (const gchar *dir, GError **error)
{
  CmacsBrigadeIndex *ix;
  g_autofree gchar *vpath = index_path (dir, "vectors.f16");
  IndexHeader hdr;
  struct stat sb;
  int fd;

  index_dispatch_init ();

  fd = g_open (vpath, O_RDONLY, 0);
  if (fd < 0)
    {
      g_set_error (error, G_FILE_ERROR, G_FILE_ERROR_NOENT,
                   "no memory index at %s (run M-x cmacs-brigade-memory-build)",
                   dir);
      return NULL;
    }
  if (fstat (fd, &sb) != 0 || (gsize) sb.st_size < sizeof hdr)
    {
      close (fd);
      g_set_error (error, G_FILE_ERROR, G_FILE_ERROR_INVAL,
                   "memory index at %s is truncated", dir);
      return NULL;
    }
  if (read (fd, &hdr, sizeof hdr) != (gssize) sizeof hdr
      || memcmp (hdr.magic, VEC_MAGIC, 8) != 0
      || hdr.version != INDEX_FORMAT_VERSION)
    {
      close (fd);
      /* Refuse rather than reinterpret.  A header we do not recognise
       * read as vectors is not an error, it is silently wrong answers. */
      g_set_error (error, G_FILE_ERROR, G_FILE_ERROR_INVAL,
                   "memory index at %s has an unrecognised format "
                   "(rebuild it)", dir);
      return NULL;
    }

  /* The declared count must match the file, or a scan walks off the
   * mapping.  This is the check that turns a half-written index from a
   * SIGSEGV into a message.  The product is checked for overflow first:
   * a header claiming 2^40 rows of dim 2^30 wraps to a small `need',
   * passes the size test, and the scan then reads past the mapping
   * anyway -- the exact failure the test exists to prevent. */
  {
    guint64 row_bytes;
    gsize need;

    if (hdr.dim == 0 || hdr.dim > G_MAXUINT32 / sizeof (guint16)
        || hdr.count > (G_MAXSIZE - sizeof hdr)
                       / ((guint64) hdr.dim * sizeof (guint16)))
      {
        close (fd);
        g_set_error (error, G_FILE_ERROR, G_FILE_ERROR_INVAL,
                     "memory index at %s has an impossible shape "
                     "(dim %u, %" G_GUINT64_FORMAT " vectors); rebuild it",
                     dir, hdr.dim, hdr.count);
        return NULL;
      }
    row_bytes = (guint64) hdr.dim * sizeof (guint16);
    need = sizeof hdr + hdr.count * row_bytes;
    if ((gsize) sb.st_size < need)
      {
        close (fd);
        g_set_error (error, G_FILE_ERROR, G_FILE_ERROR_INVAL,
                     "memory index at %s claims %" G_GUINT64_FORMAT
                     " vectors but the file holds fewer (rebuild it)",
                     dir, hdr.count);
        return NULL;
      }
  }

  ix = g_new0 (CmacsBrigadeIndex, 1);
  ix->dir     = g_strdup (dir);
  ix->vec_fd  = fd;
  ix->dim     = hdr.dim;
  ix->count   = hdr.count;
  ix->vec_len = sizeof hdr + hdr.count * hdr.dim * sizeof (guint16);
  ix->vec_map = mmap (NULL, ix->vec_len, PROT_READ, MAP_SHARED, fd, 0);

  if (ix->vec_map == MAP_FAILED)
    {
      close (fd);
      g_free (ix->dir);
      g_free (ix);
      g_set_error (error, G_FILE_ERROR, G_FILE_ERROR_NOMEM,
                   "cannot map the memory index at %s", dir);
      return NULL;
    }

  /* MADV_RANDOM, never mlock: this machine also runs multi-gigabyte
   * models, and pinning half a gigabyte of index would take memory from
   * the thing the index exists to serve. */
  madvise (ix->vec_map, ix->vec_len, MADV_RANDOM);
  return ix;
}

void
cmacs_brigade_index_close (CmacsBrigadeIndex *ix)
{
  if (ix == NULL) return;
  if (ix->vec_map != NULL && ix->vec_map != MAP_FAILED)
    munmap (ix->vec_map, ix->vec_len);
  if (ix->vec_fd >= 0) close (ix->vec_fd);
  g_free (ix->dir);
  g_free (ix);
}

guint64
cmacs_brigade_index_count (CmacsBrigadeIndex *ix)
{
  return ix ? ix->count : 0;
}

guint32
cmacs_brigade_index_dim (CmacsBrigadeIndex *ix)
{
  return ix ? ix->dim : 0;
}

/* ── Search ───────────────────────────────────────────────────────── */

/* Scan every vector and keep the best K.  A bounded insertion into a
 * small array beats a heap here: K is single digits, so the array stays
 * in registers and cache while a heap would chase pointers. */
guint
cmacs_brigade_index_search (CmacsBrigadeIndex *ix, const float *query,
                            guint k, guint32 *out_ids, float *out_scores)
{
  const guint8 *base;
  guint64 i;
  guint found = 0;

  if (ix == NULL || query == NULL || k == 0) return 0;
  index_dispatch_init ();

  base = (const guint8 *) ix->vec_map + sizeof (IndexHeader);

  for (i = 0; i < ix->count; i++)
    {
      const guint16 *row = (const guint16 *) (base + i * ix->dim
                                              * sizeof (guint16));
      float score = dot_row (query, row, ix->dim);
      gint pos;

      if (found == k && score <= out_scores[k - 1]) continue;

      pos = (gint) (found < k ? found : k - 1);
      while (pos > 0 && out_scores[pos - 1] < score)
        {
          out_scores[pos] = out_scores[pos - 1];
          out_ids[pos]    = out_ids[pos - 1];
          pos--;
        }
      out_scores[pos] = score;
      out_ids[pos]    = (guint32) i;
      if (found < k) found++;
    }

  return found;
}

/* ── Writing ──────────────────────────────────────────────────────── */

struct _CmacsBrigadeIndexWriter
{
  gchar   *dir;
  gchar   *vec_tmp;
  FILE    *vec_fp;
  guint32  dim;
  guint64  count;
  int      lock_fd;
};

CmacsBrigadeIndexWriter *
cmacs_brigade_index_writer_new (const gchar *dir, guint32 dim, GError **error)
{
  CmacsBrigadeIndexWriter *w;
  g_autofree gchar *lockpath = NULL;
  IndexHeader hdr;
  int lock_fd;

  if (g_mkdir_with_parents (dir, 0700) != 0)
    {
      g_set_error (error, G_FILE_ERROR, G_FILE_ERROR_ACCES,
                   "cannot create the index directory %s", dir);
      return NULL;
    }

  /* One writer at a time.  Two cmacs instances indexing the same
   * directory would interleave appends and produce a file whose header
   * count is right and whose contents are not. */
  lockpath = index_path (dir, "lock");
  lock_fd = g_open (lockpath, O_CREAT | O_RDWR, 0600);
  if (lock_fd < 0 || flock (lock_fd, LOCK_EX | LOCK_NB) != 0)
    {
      if (lock_fd >= 0) close (lock_fd);
      g_set_error (error, G_FILE_ERROR, G_FILE_ERROR_AGAIN,
                   "another cmacs is building the index at %s", dir);
      return NULL;
    }

  w = g_new0 (CmacsBrigadeIndexWriter, 1);
  w->dir     = g_strdup (dir);
  w->dim     = dim;
  w->lock_fd = lock_fd;
  /* Written to a temporary and renamed at commit, so a reader never
   * sees a partially written index and a crash leaves the old one
   * intact. */
  w->vec_tmp = index_path (dir, "vectors.f16.new");
  w->vec_fp  = g_fopen (w->vec_tmp, "wb");

  if (w->vec_fp == NULL)
    {
      close (lock_fd);
      g_free (w->dir); g_free (w->vec_tmp); g_free (w);
      g_set_error (error, G_FILE_ERROR, G_FILE_ERROR_ACCES,
                   "cannot write to %s", dir);
      return NULL;
    }

  memset (&hdr, 0, sizeof hdr);
  memcpy (hdr.magic, VEC_MAGIC, 8);
  hdr.version = INDEX_FORMAT_VERSION;
  hdr.dim     = dim;
  hdr.count   = 0;                 /* rewritten at commit */
  fwrite (&hdr, sizeof hdr, 1, w->vec_fp);
  return w;
}

/* Append one vector, normalising it so search is a plain dot product. */
gboolean
cmacs_brigade_index_writer_add (CmacsBrigadeIndexWriter *w,
                                const float *vec, guint32 dim)
{
  g_autofree guint16 *row = NULL;
  double norm = 0.0;
  guint32 i;

  if (w == NULL || vec == NULL || dim != w->dim) return FALSE;

  for (i = 0; i < dim; i++) norm += (double) vec[i] * (double) vec[i];
  norm = sqrt (norm);
  /* A zero vector would divide by zero; it also carries no signal, so
   * store it as zeros and let it score 0 against every query. */
  if (norm < 1e-12) norm = 1.0;

  row = g_new (guint16, dim);
  for (i = 0; i < dim; i++)
    row[i] = float_to_half ((float) ((double) vec[i] / norm));

  return fwrite (row, sizeof (guint16), dim, w->vec_fp) == dim
    && (w->count++, TRUE);
}

const guint16 *
cmacs_brigade_index_row (CmacsBrigadeIndex *ix, guint64 i)
{
  if (ix == NULL || ix->vec_map == NULL || i >= ix->count) return NULL;
  return (const guint16 *) ((const guint8 *) ix->vec_map
                            + sizeof (IndexHeader)
                            + i * (guint64) ix->dim * sizeof (guint16));
}

gboolean
cmacs_brigade_index_writer_add_f16 (CmacsBrigadeIndexWriter *w,
                                    const guint16 *row, guint32 dim)
{
  if (w == NULL || row == NULL || dim != w->dim) return FALSE;
  return fwrite (row, sizeof (guint16), dim, w->vec_fp) == dim
    && (w->count++, TRUE);
}

gboolean
cmacs_brigade_index_writer_commit (CmacsBrigadeIndexWriter *w, GError **error)
{
  g_autofree gchar *final = NULL;
  IndexHeader hdr;
  gboolean ok;

  if (w == NULL) return FALSE;

  /* Patch the count into the header now that it is known. */
  memset (&hdr, 0, sizeof hdr);
  memcpy (hdr.magic, VEC_MAGIC, 8);
  hdr.version = INDEX_FORMAT_VERSION;
  hdr.dim     = w->dim;
  hdr.count   = w->count;
  fseek (w->vec_fp, 0, SEEK_SET);
  fwrite (&hdr, sizeof hdr, 1, w->vec_fp);
  fflush (w->vec_fp);
  /* fsync before rename: the rename is what makes the index visible, so
   * the data has to be on disk first or a power cut leaves a valid-
   * looking header over garbage. */
  fsync (fileno (w->vec_fp));
  fclose (w->vec_fp);
  w->vec_fp = NULL;

  final = index_path (w->dir, "vectors.f16");
  ok = g_rename (w->vec_tmp, final) == 0;
  if (!ok)
    g_set_error (error, G_FILE_ERROR, G_FILE_ERROR_FAILED,
                 "cannot commit the index at %s", w->dir);

  return ok;
}

void
cmacs_brigade_index_writer_free (CmacsBrigadeIndexWriter *w)
{
  if (w == NULL) return;
  if (w->vec_fp != NULL) fclose (w->vec_fp);
  if (w->lock_fd >= 0)
    {
      flock (w->lock_fd, LOCK_UN);
      close (w->lock_fd);
    }
  g_free (w->dir);
  g_free (w->vec_tmp);
  g_free (w);
}

guint64
cmacs_brigade_index_writer_count (CmacsBrigadeIndexWriter *w)
{
  return w ? w->count : 0;
}

#endif /* HAVE_CMACS_AI_BRIGADE */
