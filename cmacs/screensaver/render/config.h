/* config.h --- minimal build config for the cmacs-screensaver-render child.
 *
 * Copyright (C) 2026 Zach Podbielniak
 * SPDX-License-Identifier: AGPL-3.0-or-later
 *
 * cmacs-libregnum-render.c (compiled into this standalone binary) does
 * `#include <config.h>' and is gated by HAVE_CMACS_LIBREGNUM.  Rather than drag
 * in Emacs's full gnulib-laden src/config.h, the child resolves <config.h> to
 * this tiny shim (its directory is the first -I on the compile line): it enables
 * exactly the libregnum render path and leaves the optional CAD / lrgterm
 * features compiled out, which the screensaver host does not need. */

#ifndef CMACS_SCREENSAVER_RENDER_CONFIG_H
#define CMACS_SCREENSAVER_RENDER_CONFIG_H

#define HAVE_CMACS_LIBREGNUM 1

#endif /* CMACS_SCREENSAVER_RENDER_CONFIG_H */
