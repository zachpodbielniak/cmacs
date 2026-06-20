/* ssr-shm.h --- child-side shared-memory frame buffer (a sealed memfd).
 *
 * Copyright (C) 2026 Zach Podbielniak
 * SPDX-License-Identifier: AGPL-3.0-or-later */

#ifndef SSR_SHM_H
#define SSR_SHM_H

#include <glib.h>
#include <stdint.h>

G_BEGIN_DECLS

/* One per render target: an anonymous, size-sealed memfd holding the ScrShmHeader
 * + SCR_SHM_N_SLOTS pixel slots, mapped writable in the child.  The fd is handed
 * to Emacs (via SCM_RIGHTS) which maps it read-only. */
typedef struct
{
  int      fd;     /* memfd (owned; closed on free) */
  void    *base;   /* mmap MAP_SHARED (owned; unmapped on free) */
  gsize    size;
  uint32_t w, h;
} SsrShm;

/* Create a memfd sized for a W*H ARGB8888 triple-buffer, seal its size, map it,
 * and initialise the header.  Returns NULL and sets ERROR on failure. */
SsrShm *ssr_shm_new (uint32_t w, uint32_t h, GError **error);

/* Unmap + close. */
void ssr_shm_free (SsrShm *s);

G_END_DECLS

#endif /* SSR_SHM_H */
