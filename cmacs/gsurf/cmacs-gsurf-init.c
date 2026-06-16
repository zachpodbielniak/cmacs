/* cmacs-gsurf-init.c --- gsurf subsystem lifecycle.
 *
 * Copyright (C) 2026 Zach Podbielniak
 * SPDX-License-Identifier: AGPL-3.0-or-later
 *
 * Brings up the gsurf runtime (library + windowing backend + the
 * process GsurfApplication/GsurfConfig + module manager) on first use,
 * and prepends the bundled Gsurf-0.1 typelib directory to the
 * GObject-Introspection search path so (gi-require "Gsurf" "0.1") and
 * the bacon `cmacsgi' builtin work with no GI_TYPELIB_PATH setup.
 *
 * Config policy: cmacs-gsurf does NOT read gsurf's own user config
 * (~/.config/gsurf/config.yaml or config.c) by default.  The config
 * object is created with built-in defaults only; configuration is driven
 * from Emacs (see lisp/cmacs/cmacs-gsurf.el `cmacs-gsurf-modules' /
 * `cmacs-gsurf-config-file' / `cmacs-gsurf-config-c-file', applied via
 * the cmacs-gsurf-load-config-* DEFUNs).  Bring-up is therefore split:
 * `cmacs_gsurf_config_ensure' creates the (display-free) config so Emacs
 * can load into it BEFORE modules are loaded, and `cmacs_gsurf_runtime_
 * ensure' (first attach) then inits the backend and loads the modules,
 * which read the now-settled config. */

#include <config.h>

#ifdef HAVE_CMACS_GSURF

#include "lisp.h"
#include "frame.h"
#include "cmacs-gsurf.h"
#include "cmacs-gsurf-internal.h"

#include <stdbool.h>
#include <gsurf/gsurf.h>

#ifdef HAVE_CMACS_GSURF_LRG
#include <gsurf/backend/lrg/gsurf-lrg-view.h>  /* for the backend factory enum */
#include <gsurf/core/gsurf-backend.h>
#endif

#ifdef HAVE_CMACS_GI
#include <girepository.h>
#endif

extern void syms_of_cmacs_gsurf_defuns (void);

/* ── Process-wide gsurf objects ─────────────────────────────────────── */

static GsurfApplication *cmacs_gsurf__app    = NULL;
static GsurfConfig      *cmacs_gsurf__config = NULL;
static bool              cmacs_gsurf__config_ready  = false;
static bool              cmacs_gsurf__runtime_tried = false;
static bool              cmacs_gsurf__backend_ok    = false;
static bool              cmacs_gsurf__gir_added     = false;

GsurfApplication *
cmacs_gsurf_app (void)
{
  return cmacs_gsurf__app;
}

GsurfConfig *
cmacs_gsurf_config (void)
{
  return cmacs_gsurf__config;
}

/* Prepend the bundled typelib dir to the GI search path.  Cheap and
   display-independent, so it runs at init even before any browser
   buffer exists. */
static void
cmacs_gsurf_add_gir_path (void)
{
  if (cmacs_gsurf__gir_added)
    return;
  cmacs_gsurf__gir_added = true;
#ifdef HAVE_CMACS_GI
# ifdef CMACS_GSURF_GIR_DIR
  g_irepository_prepend_search_path (CMACS_GSURF_GIR_DIR);
# endif
#endif
}

/* Create the process GsurfConfig (built-in defaults only -- NO user
   config files) + application, so Emacs can load configuration into it
   before the modules are loaded.  Display-free: does not init the GTK
   backend, so it is safe in --batch and before the first browser
   buffer.  Idempotent. */
bool
cmacs_gsurf_config_ensure (void)
{
  if (cmacs_gsurf__config_ready)
    return true;

  /* gsurf_init is the library init (type registration etc.); it does
     not require a display. */
  gsurf_init (NULL, NULL);

  cmacs_gsurf__config = gsurf_config_new ();
  gsurf_config_set_default (cmacs_gsurf__config);
  cmacs_gsurf__app = gsurf_application_new (cmacs_gsurf__config);

  cmacs_gsurf_add_gir_path ();

  cmacs_gsurf__config_ready = true;
  return true;
}

bool
cmacs_gsurf_runtime_ensure (void)
{
  if (cmacs_gsurf__runtime_tried)
    return cmacs_gsurf__backend_ok;
  cmacs_gsurf__runtime_tried = true;

  cmacs_gsurf_config_ensure ();

#ifdef HAVE_CMACS_GSURF_LRG
  /* Pick the backend by the Emacs display: under `emacs --lrg' there is no
     GTK widget tree to embed into, so use the gsurf libregnum backend (the
     page is rendered to a GrlTexture that lrgterm composites).  pgtk frames
     keep the GTK backend.  Done before backend_init so the right backend is
     initialised. */
  {
    struct frame *sf = SELECTED_FRAME ();
    if (sf != NULL && FRAME_LIVE_P (sf) && FRAME_LRG_P (sf)
        && gsurf_backend_is_available (GSURF_BACKEND_LRG))
      gsurf_backend_set_default_type (GSURF_BACKEND_LRG);
  }
#endif

  /* backend_init initialises the selected backend (gtk_init for GTK, the
     EGL/offscreen bootstrap for LRG; idempotent).  Needs a display. */
  GError *err = NULL;
  if (!gsurf_backend_init (NULL, NULL, &err))
    {
      fprintf (stderr, "cmacs-gsurf: backend init failed: %s\n",
               err ? err->message : "unknown");
      g_clear_error (&err);
      cmacs_gsurf__backend_ok = false;
      return false;
    }

  /* Load + activate the modules now that the config Emacs supplied (if
     any) is settled; module `enabled' flags are read from that config. */
  cmacs_gsurf_modules_init ();

  /* Track downloads on the shared default WebKitWebContext (idempotent). */
  cmacs_gsurf_downloads_init ();

  cmacs_gsurf__backend_ok = true;
  return true;
}

bool
cmacs_gsurf_available_p (void)
{
  return cmacs_gsurf__backend_ok;
}

/* ── Emacs subsystem hooks ──────────────────────────────────────────── */

void
syms_of_cmacs_gsurf (void)
{
  syms_of_cmacs_gsurf_defuns ();
}

void
init_cmacs_gsurf (void)
{
  /* Make the typelib resolvable immediately; defer the heavy
     display-dependent runtime to the first browser buffer. */
  cmacs_gsurf_add_gir_path ();
}

#endif /* HAVE_CMACS_GSURF */
