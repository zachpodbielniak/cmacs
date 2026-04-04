/* cmacs-compat.h — Platform compatibility shims
 *
 * Copyright (C) 2026 Zach Podbielniak
 * SPDX-License-Identifier: AGPL-3.0-or-later
 */

#ifndef CMACS_COMPAT_H
#define CMACS_COMPAT_H

#include <config.h>

/* Platform detection */
#if defined(__APPLE__) && defined(__MACH__)
# define CMACS_PLATFORM_MACOS 1
#elif defined(__FreeBSD__)
# define CMACS_PLATFORM_FREEBSD 1
#else
# define CMACS_PLATFORM_LINUX 1
#endif

/* Wayland availability — gowl only works on Linux/FreeBSD */
#if defined(CMACS_PLATFORM_LINUX) || defined(CMACS_PLATFORM_FREEBSD)
# define CMACS_HAVE_WAYLAND 1
#endif

#endif /* CMACS_COMPAT_H */
