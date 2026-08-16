/* cmacs-office-zip.c --- the OPC / ODF package container.
 *
 * Copyright (C) 2026 Zach Podbielniak
 * SPDX-License-Identifier: AGPL-3.0-or-later
 *
 * See cmacs-office-zip.h for the deferred-write rationale and the
 * shadow-package invariant this file exists to protect.  Nothing here
 * includes lisp.h or any Emacs header. */

#include <config.h>

#ifdef HAVE_CMACS_OFFICE

#include "cmacs-office-zip.h"

#include <gio/gio.h>            /* g_file_copy, for the save-as path */
#include <glib/gstdio.h>
#include <string.h>
#include <zip.h>

/* The one part an ODF package may not have rewritten underneath it. */
#define CMACS_OFFICE_ODF_MIMETYPE "mimetype"

/* A part name longer than this is not a real part name. */
#define CMACS_OFFICE_ZIP_MAX_NAME 4096

struct _CmacsOfficeZip
{
  gchar      *path;          /* the file we were opened on */
  zip_t      *za;            /* read-only handle; NULL while saving */

  GHashTable *pending;       /* gchar* -> GBytes*, queued writes */
  GPtrArray  *pending_order; /* gchar*, insertion order of new parts */
  GHashTable *deleted;       /* gchar* set, queued deletions */

  guint64     max_part;
  guint64     max_total;
};

G_DEFINE_QUARK (cmacs-office-zip-error-quark, cmacs_office_zip_error)

/* ------------------------------------------------------------------ */
/* Error plumbing                                                      */
/* ------------------------------------------------------------------ */

/* libzip reports through its own zip_error_t.  Funnel both the
   open-time integer code and the per-archive error object into a
   GError so callers only deal with one error domain. */
static void
set_error_from_code (GError **error, gint code, CmacsOfficeZipError ours,
                     const gchar *what, const gchar *name)
{
  zip_error_t ze;

  if (error == NULL)
    return;

  zip_error_init_with_code (&ze, code);
  g_set_error (error, CMACS_OFFICE_ZIP_ERROR, ours, "%s %s: %s",
               what, name, zip_error_strerror (&ze));
  zip_error_fini (&ze);
}

static void
set_error_from_archive (GError **error, zip_t *za, CmacsOfficeZipError ours,
                        const gchar *what, const gchar *name)
{
  if (error == NULL)
    return;

  g_set_error (error, CMACS_OFFICE_ZIP_ERROR, ours, "%s %s: %s",
               what, name,
               za ? zip_error_strerror (zip_get_error (za)) : "unknown error");
}

/* ------------------------------------------------------------------ */
/* Part-name validation                                                */
/* ------------------------------------------------------------------ */

/* These archives arrive as mail attachments, so a part name is
   untrusted input.  It is checked BEFORE any lookup, not after, so a
   traversal attempt can never reach the filesystem layer -- and
   because we only ever address parts by name (we never extract to
   disk), rejecting here is sufficient rather than merely prudent. */
gboolean
cmacs_office_zip_name_valid (const gchar *name)
{
  const gchar *p;
  gsize len;

  if (name == NULL || *name == '\0')
    return FALSE;

  len = strlen (name);
  if (len > CMACS_OFFICE_ZIP_MAX_NAME)
    return FALSE;

  if (!g_utf8_validate (name, (gssize) len, NULL))
    return FALSE;

  /* Absolute paths escape the package. */
  if (name[0] == '/')
    return FALSE;

  /* OPC part names are '/'-separated; a backslash or a colon means
     someone is trying to smuggle a Windows path through. */
  if (strchr (name, '\\') != NULL || strchr (name, ':') != NULL)
    return FALSE;

  /* No `..' component anywhere. */
  p = name;
  while (*p != '\0')
    {
      const gchar *slash = strchr (p, '/');
      gsize seg = slash ? (gsize) (slash - p) : strlen (p);

      if (seg == 2 && p[0] == '.' && p[1] == '.')
        return FALSE;
      if (slash == NULL)
        break;
      p = slash + 1;
    }

  return TRUE;
}

static gboolean
check_name (const gchar *name, GError **error)
{
  if (cmacs_office_zip_name_valid (name))
    return TRUE;

  g_set_error (error, CMACS_OFFICE_ZIP_ERROR, CMACS_OFFICE_ZIP_ERROR_BAD_NAME,
               "unsafe or malformed package part name: %s",
               name ? name : "(null)");
  return FALSE;
}

/* ------------------------------------------------------------------ */
/* Open / close                                                        */
/* ------------------------------------------------------------------ */

/* Sum the central directory's declared uncompressed sizes.  This is
   the cheap half of the zip-bomb guard: it costs no inflation and
   rejects the obvious case at open time.  The expensive half -- a
   member that lies about its size and then streams gigabytes -- is
   caught in read_part, which refuses to read past the declaration. */
static gboolean
check_total_size (zip_t *za, guint64 max_total, GError **error)
{
  zip_int64_t n = zip_get_num_entries (za, 0);
  guint64 total = 0;
  zip_int64_t i;

  for (i = 0; i < n; i++)
    {
      zip_stat_t st;

      if (zip_stat_index (za, i, 0, &st) != 0)
        continue;
      if ((st.valid & ZIP_STAT_SIZE) == 0)
        continue;

      total += st.size;
      if (total > max_total)
        {
          g_set_error (error, CMACS_OFFICE_ZIP_ERROR,
                       CMACS_OFFICE_ZIP_ERROR_TOO_LARGE,
                       "package inflates to more than %" G_GUINT64_FORMAT
                       " bytes; refusing to open", max_total);
          return FALSE;
        }
    }

  return TRUE;
}

CmacsOfficeZip *
cmacs_office_zip_open (const gchar *path, GError **error)
{
  CmacsOfficeZip *zip;
  zip_t *za;
  gint zep = 0;

  g_return_val_if_fail (path != NULL, NULL);

  /* Deliberately no ZIP_CHECKCONS: it rejects archives that real
     producers emit (notably ones with slack between the last member
     and the central directory), and our own size checks cover the
     failure mode that actually matters here. */
  za = zip_open (path, ZIP_RDONLY, &zep);
  if (za == NULL)
    {
      set_error_from_code (error, zep, CMACS_OFFICE_ZIP_ERROR_OPEN,
                           "cannot open package", path);
      return NULL;
    }

  if (!check_total_size (za, CMACS_OFFICE_ZIP_DEFAULT_MAX_TOTAL, error))
    {
      zip_discard (za);
      return NULL;
    }

  zip = g_new0 (CmacsOfficeZip, 1);
  zip->path = g_strdup (path);
  zip->za = za;
  zip->pending = g_hash_table_new_full (g_str_hash, g_str_equal,
                                        g_free, (GDestroyNotify) g_bytes_unref);
  zip->pending_order = g_ptr_array_new_with_free_func (g_free);
  zip->deleted = g_hash_table_new_full (g_str_hash, g_str_equal, g_free, NULL);
  zip->max_part = CMACS_OFFICE_ZIP_DEFAULT_MAX_PART;
  zip->max_total = CMACS_OFFICE_ZIP_DEFAULT_MAX_TOTAL;

  return zip;
}

void
cmacs_office_zip_free (CmacsOfficeZip *zip)
{
  if (zip == NULL)
    return;

  if (zip->za != NULL)
    zip_discard (zip->za);          /* read-only: never write on close */
  g_clear_pointer (&zip->pending, g_hash_table_unref);
  g_clear_pointer (&zip->pending_order, g_ptr_array_unref);
  g_clear_pointer (&zip->deleted, g_hash_table_unref);
  g_free (zip->path);
  g_free (zip);
}

void
cmacs_office_zip_set_limits (CmacsOfficeZip *zip, guint64 max_part,
                             guint64 max_total)
{
  g_return_if_fail (zip != NULL);

  if (max_part > 0)
    zip->max_part = max_part;
  if (max_total > 0)
    zip->max_total = max_total;
}

/* ------------------------------------------------------------------ */
/* Introspection                                                       */
/* ------------------------------------------------------------------ */

const gchar *
cmacs_office_zip_path (CmacsOfficeZip *zip)
{
  g_return_val_if_fail (zip != NULL, NULL);
  return zip->path;
}

gboolean
cmacs_office_zip_dirty (CmacsOfficeZip *zip)
{
  g_return_val_if_fail (zip != NULL, FALSE);
  return g_hash_table_size (zip->pending) > 0
         || g_hash_table_size (zip->deleted) > 0;
}

gboolean
cmacs_office_zip_has_part (CmacsOfficeZip *zip, const gchar *name)
{
  g_return_val_if_fail (zip != NULL, FALSE);

  if (!cmacs_office_zip_name_valid (name))
    return FALSE;
  if (g_hash_table_contains (zip->deleted, name))
    return FALSE;
  if (g_hash_table_contains (zip->pending, name))
    return TRUE;

  return zip_name_locate (zip->za, name, 0) >= 0;
}

guint
cmacs_office_zip_n_parts (CmacsOfficeZip *zip)
{
  guint n;
  gchar **names;

  g_return_val_if_fail (zip != NULL, 0);

  names = cmacs_office_zip_part_names (zip, &n);
  g_strfreev (names);
  return n;
}

gchar **
cmacs_office_zip_part_names (CmacsOfficeZip *zip, guint *n_out)
{
  GPtrArray *out;
  zip_int64_t n, i;
  guint k;

  g_return_val_if_fail (zip != NULL, NULL);

  out = g_ptr_array_new ();

  /* Archive order first: ODF requires `mimetype' to come first, and a
     stable order makes round-trip diffs readable. */
  n = zip_get_num_entries (zip->za, 0);
  for (i = 0; i < n; i++)
    {
      const gchar *nm = zip_get_name (zip->za, i, 0);

      if (nm == NULL || g_hash_table_contains (zip->deleted, nm))
        continue;
      g_ptr_array_add (out, g_strdup (nm));
    }

  /* Then parts queued that the archive does not have yet, in the order
     they were added. */
  for (k = 0; k < zip->pending_order->len; k++)
    {
      const gchar *nm = g_ptr_array_index (zip->pending_order, k);

      if (g_hash_table_contains (zip->deleted, nm))
        continue;
      if (zip_name_locate (zip->za, nm, 0) >= 0)
        continue;                    /* already listed above */
      g_ptr_array_add (out, g_strdup (nm));
    }

  if (n_out != NULL)
    *n_out = out->len;

  g_ptr_array_add (out, NULL);
  return (gchar **) g_ptr_array_free (out, FALSE);
}

gboolean
cmacs_office_zip_part_size (CmacsOfficeZip *zip, const gchar *name,
                            guint64 *size_out, GError **error)
{
  GBytes *queued;
  zip_int64_t idx;
  zip_stat_t st;

  g_return_val_if_fail (zip != NULL, FALSE);

  if (!check_name (name, error))
    return FALSE;

  if (g_hash_table_contains (zip->deleted, name))
    {
      g_set_error (error, CMACS_OFFICE_ZIP_ERROR, CMACS_OFFICE_ZIP_ERROR_NO_PART,
                   "no such part: %s", name);
      return FALSE;
    }

  queued = g_hash_table_lookup (zip->pending, name);
  if (queued != NULL)
    {
      if (size_out != NULL)
        *size_out = g_bytes_get_size (queued);
      return TRUE;
    }

  idx = zip_name_locate (zip->za, name, 0);
  if (idx < 0)
    {
      g_set_error (error, CMACS_OFFICE_ZIP_ERROR, CMACS_OFFICE_ZIP_ERROR_NO_PART,
                   "no such part: %s", name);
      return FALSE;
    }

  if (zip_stat_index (zip->za, idx, 0, &st) != 0
      || (st.valid & ZIP_STAT_SIZE) == 0)
    {
      set_error_from_archive (error, zip->za, CMACS_OFFICE_ZIP_ERROR_READ,
                              "cannot stat part", name);
      return FALSE;
    }

  if (size_out != NULL)
    *size_out = st.size;
  return TRUE;
}

/* ------------------------------------------------------------------ */
/* Reading                                                             */
/* ------------------------------------------------------------------ */

guint8 *
cmacs_office_zip_read_part (CmacsOfficeZip *zip, const gchar *name,
                            gsize *len_out, GError **error)
{
  GBytes *queued;
  zip_int64_t idx;
  zip_stat_t st;
  zip_file_t *zf;
  guint8 *buf;
  guint64 want;
  guint64 got = 0;
  gchar probe;

  g_return_val_if_fail (zip != NULL, NULL);

  if (!check_name (name, error))
    return NULL;

  if (g_hash_table_contains (zip->deleted, name))
    {
      g_set_error (error, CMACS_OFFICE_ZIP_ERROR, CMACS_OFFICE_ZIP_ERROR_NO_PART,
                   "no such part: %s", name);
      return NULL;
    }

  /* Pending writes win, so a caller that sets then reads sees its own
     write rather than the stale on-disk part. */
  queued = g_hash_table_lookup (zip->pending, name);
  if (queued != NULL)
    {
      gsize qlen = 0;
      const guint8 *qdata = g_bytes_get_data (queued, &qlen);

      buf = g_malloc (qlen + 1);
      if (qlen > 0)
        memcpy (buf, qdata, qlen);
      buf[qlen] = '\0';
      if (len_out != NULL)
        *len_out = qlen;
      return buf;
    }

  idx = zip_name_locate (zip->za, name, 0);
  if (idx < 0)
    {
      g_set_error (error, CMACS_OFFICE_ZIP_ERROR, CMACS_OFFICE_ZIP_ERROR_NO_PART,
                   "no such part: %s", name);
      return NULL;
    }

  if (zip_stat_index (zip->za, idx, 0, &st) != 0
      || (st.valid & ZIP_STAT_SIZE) == 0)
    {
      set_error_from_archive (error, zip->za, CMACS_OFFICE_ZIP_ERROR_READ,
                              "cannot stat part", name);
      return NULL;
    }

  want = st.size;
  if (want > zip->max_part)
    {
      g_set_error (error, CMACS_OFFICE_ZIP_ERROR, CMACS_OFFICE_ZIP_ERROR_TOO_LARGE,
                   "part %s inflates to %" G_GUINT64_FORMAT
                   " bytes, over the %" G_GUINT64_FORMAT " byte cap",
                   name, want, zip->max_part);
      return NULL;
    }

  zf = zip_fopen_index (zip->za, idx, 0);
  if (zf == NULL)
    {
      set_error_from_archive (error, zip->za, CMACS_OFFICE_ZIP_ERROR_READ,
                              "cannot open part", name);
      return NULL;
    }

  /* One byte of slack so the buffer is always NUL-terminated and can
     go straight into an XML parser as a C string. */
  buf = g_malloc (want + 1);

  while (got < want)
    {
      zip_int64_t r = zip_fread (zf, buf + got, want - got);

      if (r < 0)
        {
          g_free (buf);
          zip_fclose (zf);
          g_set_error (error, CMACS_OFFICE_ZIP_ERROR, CMACS_OFFICE_ZIP_ERROR_READ,
                       "short read on part %s", name);
          return NULL;
        }
      if (r == 0)
        break;                       /* truncated member */
      got += (guint64) r;
    }

  /* The central directory is attacker-controlled, so a member that
     declares a small size and then keeps delivering is the interesting
     case.  We only ever asked for `want' bytes; if anything remains,
     the declaration lied and the archive is not trustworthy. */
  if (got == want && zip_fread (zf, &probe, 1) > 0)
    {
      g_free (buf);
      zip_fclose (zf);
      g_set_error (error, CMACS_OFFICE_ZIP_ERROR, CMACS_OFFICE_ZIP_ERROR_TOO_LARGE,
                   "part %s is larger than the size it declares", name);
      return NULL;
    }

  zip_fclose (zf);

  if (got != want)
    {
      g_free (buf);
      g_set_error (error, CMACS_OFFICE_ZIP_ERROR, CMACS_OFFICE_ZIP_ERROR_READ,
                   "part %s is truncated (%" G_GUINT64_FORMAT " of %"
                   G_GUINT64_FORMAT " bytes)", name, got, want);
      return NULL;
    }

  buf[want] = '\0';
  if (len_out != NULL)
    *len_out = want;
  return buf;
}

/* ------------------------------------------------------------------ */
/* Queued mutation                                                     */
/* ------------------------------------------------------------------ */

static void
remember_order (CmacsOfficeZip *zip, const gchar *name)
{
  guint i;

  for (i = 0; i < zip->pending_order->len; i++)
    if (g_strcmp0 (g_ptr_array_index (zip->pending_order, i), name) == 0)
      return;

  g_ptr_array_add (zip->pending_order, g_strdup (name));
}

gboolean
cmacs_office_zip_set_part (CmacsOfficeZip *zip, const gchar *name,
                           const guint8 *data, gsize len, GError **error)
{
  g_return_val_if_fail (zip != NULL, FALSE);
  g_return_val_if_fail (data != NULL || len == 0, FALSE);

  if (!check_name (name, error))
    return FALSE;

  /* An ODF package is only valid if it opens with an uncompressed
     `mimetype' entry.  libzip preserves order and compression method
     for entries it copies through untouched, so the invariant holds
     for free -- right up until something rewrites this part, at which
     point it would be re-added at the end and deflated.  Refuse.
     (Adding it to a package that lacks it is fine: that is package
     creation, not mutation.) */
  if (g_strcmp0 (name, CMACS_OFFICE_ODF_MIMETYPE) == 0
      && zip_name_locate (zip->za, name, 0) >= 0)
    {
      g_set_error (error, CMACS_OFFICE_ZIP_ERROR, CMACS_OFFICE_ZIP_ERROR_READONLY,
                   "refusing to rewrite the ODF `mimetype' part: it must stay "
                   "first and uncompressed");
      return FALSE;
    }

  g_hash_table_remove (zip->deleted, name);
  g_hash_table_replace (zip->pending, g_strdup (name),
                        g_bytes_new (data, len));
  remember_order (zip, name);
  return TRUE;
}

gboolean
cmacs_office_zip_delete_part (CmacsOfficeZip *zip, const gchar *name,
                              GError **error)
{
  g_return_val_if_fail (zip != NULL, FALSE);

  if (!check_name (name, error))
    return FALSE;

  if (g_strcmp0 (name, CMACS_OFFICE_ODF_MIMETYPE) == 0)
    {
      g_set_error (error, CMACS_OFFICE_ZIP_ERROR, CMACS_OFFICE_ZIP_ERROR_READONLY,
                   "refusing to delete the ODF `mimetype' part");
      return FALSE;
    }

  if (!cmacs_office_zip_has_part (zip, name))
    {
      g_set_error (error, CMACS_OFFICE_ZIP_ERROR, CMACS_OFFICE_ZIP_ERROR_NO_PART,
                   "no such part: %s", name);
      return FALSE;
    }

  g_hash_table_remove (zip->pending, name);
  g_hash_table_add (zip->deleted, g_strdup (name));
  return TRUE;
}

void
cmacs_office_zip_revert (CmacsOfficeZip *zip)
{
  g_return_if_fail (zip != NULL);

  g_hash_table_remove_all (zip->pending);
  g_hash_table_remove_all (zip->deleted);
  if (zip->pending_order->len > 0)
    g_ptr_array_remove_range (zip->pending_order, 0, zip->pending_order->len);
}

/* ------------------------------------------------------------------ */
/* Saving                                                              */
/* ------------------------------------------------------------------ */

/* Apply every queued write to the archive at `target'.
 *
 * The GBytes in `pending' stay alive for the whole call, which is why
 * zip_source_buffer is handed freep=0: libzip reads straight out of
 * our buffers at zip_close time and must not try to free them.  Every
 * entry we do NOT touch is copied by libzip with its compressed bytes
 * intact -- that is the whole point of deferring writes this far. */
static gboolean
apply_pending (CmacsOfficeZip *zip, const gchar *target, GError **error)
{
  zip_t *za;
  gint zep = 0;
  GHashTableIter iter;
  gpointer k, v;
  gboolean ok = TRUE;

  za = zip_open (target, 0, &zep);
  if (za == NULL)
    {
      set_error_from_code (error, zep, CMACS_OFFICE_ZIP_ERROR_WRITE,
                           "cannot open package for writing", target);
      return FALSE;
    }

  g_hash_table_iter_init (&iter, zip->pending);
  while (ok && g_hash_table_iter_next (&iter, &k, &v))
    {
      const gchar *name = k;
      GBytes *bytes = v;
      gsize len = 0;
      const guint8 *data = g_bytes_get_data (bytes, &len);
      zip_source_t *src;
      zip_int64_t idx;

      src = zip_source_buffer (za, data, len, 0);
      if (src == NULL)
        {
          set_error_from_archive (error, za, CMACS_OFFICE_ZIP_ERROR_WRITE,
                                  "cannot stage part", name);
          ok = FALSE;
          break;
        }

      idx = zip_name_locate (za, name, 0);
      if (idx >= 0)
        ok = zip_file_replace (za, idx, src, ZIP_FL_ENC_UTF_8) == 0;
      else
        ok = zip_file_add (za, name, src, ZIP_FL_ENC_UTF_8) >= 0;

      if (!ok)
        {
          zip_source_free (src);
          set_error_from_archive (error, za, CMACS_OFFICE_ZIP_ERROR_WRITE,
                                  "cannot write part", name);
          break;
        }
    }

  if (ok)
    {
      g_hash_table_iter_init (&iter, zip->deleted);
      while (ok && g_hash_table_iter_next (&iter, &k, NULL))
        {
          const gchar *name = k;
          zip_int64_t idx = zip_name_locate (za, name, 0);

          if (idx < 0)
            continue;                /* already absent; nothing to do */
          if (zip_delete (za, idx) != 0)
            {
              set_error_from_archive (error, za, CMACS_OFFICE_ZIP_ERROR_WRITE,
                                      "cannot delete part", name);
              ok = FALSE;
            }
        }
    }

  if (!ok)
    {
      zip_discard (za);
      return FALSE;
    }

  if (zip_close (za) != 0)
    {
      set_error_from_archive (error, za, CMACS_OFFICE_ZIP_ERROR_WRITE,
                              "cannot finalise package", target);
      zip_discard (za);
      return FALSE;
    }

  return TRUE;
}

/* Reopen the read-only handle after the file underneath it changed.
   The old handle points at the pre-rename inode, so reads through it
   would silently return stale parts. */
static gboolean
reopen (CmacsOfficeZip *zip, GError **error)
{
  gint zep = 0;

  zip->za = zip_open (zip->path, ZIP_RDONLY, &zep);
  if (zip->za == NULL)
    {
      set_error_from_code (error, zep, CMACS_OFFICE_ZIP_ERROR_OPEN,
                           "cannot reopen package", zip->path);
      return FALSE;
    }
  return TRUE;
}

gboolean
cmacs_office_zip_save (CmacsOfficeZip *zip, GError **error)
{
  gboolean ok;

  g_return_val_if_fail (zip != NULL, FALSE);

  /* Nothing queued means nothing to write.  Not an optimisation: it is
     the guarantee that opening a document and saving it without an
     edit cannot perturb a single byte. */
  if (!cmacs_office_zip_dirty (zip))
    return TRUE;

  /* Drop our read-only handle first: zip_close renames a temp file
     over the original, and holding the old fd across that leaves us
     reading the previous inode. */
  zip_discard (zip->za);
  zip->za = NULL;

  ok = apply_pending (zip, zip->path, error);

  if (!reopen (zip, ok ? error : NULL))
    return FALSE;

  if (ok)
    cmacs_office_zip_revert (zip);

  return ok;
}

gboolean
cmacs_office_zip_save_as (CmacsOfficeZip *zip, const gchar *dest,
                          GError **error)
{
  GFile *src_f, *dst_f;
  gboolean copied;
  GError *local = NULL;

  g_return_val_if_fail (zip != NULL, FALSE);
  g_return_val_if_fail (dest != NULL, FALSE);

  if (g_strcmp0 (dest, zip->path) == 0)
    return cmacs_office_zip_save (zip, error);

  /* Copy first, then edit the copy: the original is never at risk, so
     a failed export leaves the source document exactly as it was.
     With nothing queued this is the whole operation, which makes
     save-as of an untouched package a byte-exact file copy. */
  src_f = g_file_new_for_path (zip->path);
  dst_f = g_file_new_for_path (dest);
  copied = g_file_copy (src_f, dst_f, G_FILE_COPY_OVERWRITE,
                        NULL, NULL, NULL, &local);
  g_object_unref (src_f);
  g_object_unref (dst_f);

  if (!copied)
    {
      g_set_error (error, CMACS_OFFICE_ZIP_ERROR, CMACS_OFFICE_ZIP_ERROR_WRITE,
                   "cannot copy package to %s: %s", dest,
                   local ? local->message : "unknown error");
      g_clear_error (&local);
      return FALSE;
    }

  if (!cmacs_office_zip_dirty (zip))
    return TRUE;

  /* Deliberately does NOT clear the pending set or retarget `path'.
     save-as is an export here: the in-memory document still carries
     its edits relative to the file it was opened from. */
  return apply_pending (zip, dest, error);
}

#endif /* HAVE_CMACS_OFFICE */
