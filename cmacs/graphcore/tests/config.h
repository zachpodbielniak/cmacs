/* config.h --- minimal build config for the graphcore unit tests.
 *
 * Copyright (C) 2026 Zach Podbielniak
 * SPDX-License-Identifier: AGPL-3.0-or-later
 *
 * cmacs-graphcore-{graph,layout}.c do `#include <config.h>' and are gated
 * on HAVE_CMACS_GRAPHCORE.  Rather than drag in Emacs's full gnulib-laden
 * src/config.h, the tests resolve <config.h> to this shim (its directory is
 * the first -I on the compile line).
 *
 * That this shim is *sufficient* is the point: graphcore includes neither
 * "lisp.h" nor <libregnum.h>, so the entire graph model and layout solver
 * link against nothing but glib and can be exercised with no Lisp VM, no GL
 * context and no display.  If this file ever needs to grow, something has
 * breached that firewall. */

#ifndef CMACS_GRAPHCORE_TESTS_CONFIG_H
#define CMACS_GRAPHCORE_TESTS_CONFIG_H

#define HAVE_CMACS_GRAPHCORE 1

#endif /* CMACS_GRAPHCORE_TESTS_CONFIG_H */
