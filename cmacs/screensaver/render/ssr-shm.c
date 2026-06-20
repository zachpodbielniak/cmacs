/* ssr-shm.c --- child-side shared-memory frame buffer.
 *
 * Copyright (C) 2026 Zach Podbielniak
 * SPDX-License-Identifier: AGPL-3.0-or-later */

#ifndef _GNU_SOURCE
#define _GNU_SOURCE   /* memfd_create, F_ADD_SEALS, F_SEAL_* */
#endif

#include "ssr-shm.h"
#include "cmacs-screensaver-proto.h"

#include <sys/mman.h>
#include <fcntl.h>
#include <unistd.h>
#include <errno.h>
#include <string.h>

SsrShm *
ssr_shm_new (uint32_t w, uint32_t h, GError **error)
{
  gsize size;
  int fd;
  void *base;
  SsrShm *s;

  size = scr_shm_total_size (w, h);
  if (size == 0)
    {
      g_set_error (error, G_FILE_ERROR, G_FILE_ERROR_INVAL,
                   "invalid frame dimensions %ux%u", w, h);
      return NULL;
    }

  fd = memfd_create ("cmacs-screensaver", MFD_CLOEXEC | MFD_ALLOW_SEALING);
  if (fd < 0)
    {
      g_set_error (error, G_FILE_ERROR, g_file_error_from_errno (errno),
                   "memfd_create: %s", g_strerror (errno));
      return NULL;
    }
  if (ftruncate (fd, (off_t) size) != 0)
    {
      g_set_error (error, G_FILE_ERROR, g_file_error_from_errno (errno),
                   "ftruncate(%" G_GSIZE_FORMAT "): %s", size,
                   g_strerror (errno));
      close (fd);
      return NULL;
    }
  /* Seal the size so a buggy/raced child can never shrink the region out from
   * under Emacs's mapping (which would SIGBUS the reader).  The region stays
   * writable for the child (we do NOT add F_SEAL_WRITE). */
  if (fcntl (fd, F_ADD_SEALS, F_SEAL_SHRINK | F_SEAL_GROW) != 0)
    {
      g_set_error (error, G_FILE_ERROR, g_file_error_from_errno (errno),
                   "F_ADD_SEALS: %s", g_strerror (errno));
      close (fd);
      return NULL;
    }

  base = mmap (NULL, size, PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0);
  if (base == MAP_FAILED)
    {
      g_set_error (error, G_FILE_ERROR, g_file_error_from_errno (errno),
                   "mmap: %s", g_strerror (errno));
      close (fd);
      return NULL;
    }

  scr_shm_header_init (base, w, h);

  s = g_new0 (SsrShm, 1);
  s->fd = fd;
  s->base = base;
  s->size = size;
  s->w = w;
  s->h = h;
  return s;
}

void
ssr_shm_free (SsrShm *s)
{
  if (s == NULL)
    return;
  if (s->base != NULL && s->base != MAP_FAILED)
    munmap (s->base, s->size);
  if (s->fd >= 0)
    close (s->fd);
  g_free (s);
}
