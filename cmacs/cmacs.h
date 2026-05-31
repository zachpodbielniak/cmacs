/* cmacs.h — CMacs umbrella header and feature detection
 *
 * Copyright (C) 2026 Zach Podbielniak
 * SPDX-License-Identifier: AGPL-3.0-or-later
 *
 * CMacs is a fork of GNU Emacs that adds GLib/GObject as a first-class
 * runtime, a GObject Introspection bridge for elisp, and native
 * crispy/bacon integration for runtime C evaluation.
 */

#ifndef CMACS_H
#define CMACS_H

#include <config.h>

/* CMACS version */
#define CMACS_VERSION_MAJOR 0
#define CMACS_VERSION_MINOR 1
#define CMACS_VERSION_PATCH 0
#define CMACS_VERSION_STRING "0.1.0"

/* Feature detection — set by configure.ac */

#ifdef HAVE_CMACS_GLIB
# include "glib/cmacs-glib-loop.h"
# include "gobject/cmacs-gobject.h"
# include "gobject/cmacs-gclosure.h"
#endif

#ifdef HAVE_CMACS_GI
# include "gi/cmacs-gi.h"
#endif

#ifdef HAVE_CMACS_CRISPY
# include "crispy/cmacs-crispy.h"
#endif

#ifdef HAVE_CMACS_BACON
# include "bacon/cmacs-bacon.h"
#endif

#ifdef HAVE_CMACS_GOWL
# include "gowl/cmacs-gowl.h"
#endif

#ifdef HAVE_CMACS_LIBRECLAW
# include "libreclaw/cmacs-libreclaw.h"
#endif

#ifdef HAVE_CMACS_ORG_EX
# include "org-ex/cmacs-org-ex.h"
#endif

#ifdef HAVE_CMACS_MCP
# include "mcp/cmacs-mcp.h"
#endif

#ifdef HAVE_CMACS_AI
# include "ai/cmacs-ai.h"
#endif

#ifdef HAVE_CMACS_LIBREGNUM
# include "libregnum/cmacs-libregnum.h"
#endif

#ifdef HAVE_CMACS_GSURF
# include "gsurf/cmacs-gsurf.h"
#endif

#endif /* CMACS_H */
