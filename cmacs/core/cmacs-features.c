/* cmacs-features.c --- compile-time cmacs feature flags.
 *
 * Copyright (C) 2026 Zach Podbielniak
 * SPDX-License-Identifier: AGPL-3.0-or-later
 *
 * Exposes, for every --with-cmacs-<name> / --enable-cmacs-<name>
 * configure option, an always-bound Lisp variable `IS-CMACS-<NAME>'
 * (plus a lower-case `is-cmacs-<name>' alias) that is t when the
 * subsystem was compiled into this build and nil otherwise, so a user
 * config can do (when IS-CMACS-AI ...) without a void-variable risk.
 *
 * This translation unit is ALWAYS linked -- even in an upstream-shaped
 * build with every cmacs feature off -- so the flags are bound in every
 * configuration (they simply all read nil).  It is the single source of
 * truth for the compiled-in feature set: `cmacs_feature_names' is also
 * consumed by the D-Bus instance interface, and the Elisp
 * `cmacs-features' / `cmacs-feature-p' defer to it.
 *
 * NOTE: make-docfile parses DEFVAR calls textually, so every DEFVAR_BOOL
 * below must stay a literal source line (no macro wrapper). */

#include <config.h>

#include "lisp.h"
#include "cmacs-features.h"

/* Lower-case subsystem names, matching the --with-cmacs-<name> flags.
 * Guarded by the same HAVE_CMACS_<NAME> macros as the variables below;
 * keep the two lists in sync. */
const char *const cmacs_feature_names[] = {
#ifdef HAVE_CMACS_GLIB
  "glib",
#endif
#ifdef HAVE_CMACS_GI
  "gi",
#endif
#ifdef HAVE_CMACS_CRISPY
  "crispy",
#endif
#ifdef HAVE_CMACS_BACON
  "bacon",
#endif
#ifdef HAVE_CMACS_GOWL
  "gowl",
#endif
#ifdef HAVE_CMACS_PODOMATION
  "podomation",
#endif
#ifdef HAVE_CMACS_LIBRECLAW
  "libreclaw",
#endif
#ifdef HAVE_CMACS_AI
  "ai",
#endif
#ifdef HAVE_CMACS_LIBREGNUM
  "libregnum",
#endif
#ifdef HAVE_CMACS_LRGTERM
  "lrgterm",
#endif
#ifdef HAVE_CMACS_IMGEDIT
  "imgedit",
#endif
#ifdef HAVE_CMACS_VIDSTUDIO
  "vidstudio",
#endif
#ifdef HAVE_CMACS_TRANSCODE
  "transcode",
#endif
#ifdef HAVE_CMACS_GNUSEYE
  "gnuseye",
#endif
#ifdef HAVE_CMACS_CAD
  "cad",
#endif
#ifdef HAVE_CMACS_SCREENSAVER
  "screensaver",
#endif
#ifdef HAVE_CMACS_ORG_EX
  "org-ex",
#endif
#ifdef HAVE_CMACS_MCP
  "mcp",
#endif
#ifdef HAVE_CMACS_PRINT
  "print",
#endif
#ifdef HAVE_CMACS_VIDEO
  "video",
#endif
#ifdef HAVE_CMACS_AUDIO
  "audio",
#endif
#ifdef HAVE_CMACS_WHISPER
  "whisper",
#endif
#ifdef HAVE_CMACS_PIPER
  "piper",
#endif
#ifdef HAVE_CMACS_GSURF
  "gsurf",
#endif
#ifdef HAVE_CMACS_GSURF_LRG
  "gsurf-lrg",
#endif
#ifdef HAVE_CMACS_EMACSCTL
  "emacsctl",
#endif
#ifdef HAVE_CMACS_CINTROSPECT
  "cintrospect",
#endif
#ifdef HAVE_CMACS_CPATCH
  "cpatch",
#endif
  NULL
};

DEFUN ("cmacs-compiled-features", Fcmacs_compiled_features,
       Scmacs_compiled_features, 0, 0, 0,
       doc: /* Return the list of cmacs subsystems compiled into this build.
Each element is a symbol matching a --with-cmacs-NAME configure option
(e.g. `ai', `gowl', `org-ex').  This reflects compile-time configuration
only; the individual `IS-CMACS-NAME' variables carry the same
information as booleans.  See also `cmacs-features'.  */)
  (void)
{
  Lisp_Object out = Qnil;
  const char *const *p;
  for (p = cmacs_feature_names; *p != NULL; p++)
    out = Fcons (intern (*p), out);
  return Fnreverse (out);
}

/* Give an IS-CMACS-<NAME> flag a conventional lower-case alias
 * (is-cmacs-<name>) so a config can spell it either way.  Both always
 * refer to the same compile-time boolean. */
static void
cmacs_features__alias (const char *lc, const char *uc)
{
  Fdefvaralias (intern (lc), intern (uc), Qnil);
}

void
syms_of_cmacs_features (void)
{
  DEFVAR_BOOL ("IS-CMACS-GLIB", is_cmacs_glib,
    doc: /* Non-nil if this build was configured --with-cmacs-glib.  */);
#ifdef HAVE_CMACS_GLIB
  is_cmacs_glib = true;
#endif

  DEFVAR_BOOL ("IS-CMACS-GI", is_cmacs_gi,
    doc: /* Non-nil if this build was configured --with-cmacs-gi.  */);
#ifdef HAVE_CMACS_GI
  is_cmacs_gi = true;
#endif

  DEFVAR_BOOL ("IS-CMACS-CRISPY", is_cmacs_crispy,
    doc: /* Non-nil if this build was configured --with-cmacs-crispy.  */);
#ifdef HAVE_CMACS_CRISPY
  is_cmacs_crispy = true;
#endif

  DEFVAR_BOOL ("IS-CMACS-BACON", is_cmacs_bacon,
    doc: /* Non-nil if this build was configured --with-cmacs-bacon.  */);
#ifdef HAVE_CMACS_BACON
  is_cmacs_bacon = true;
#endif

  DEFVAR_BOOL ("IS-CMACS-GOWL", is_cmacs_gowl,
    doc: /* Non-nil if this build was configured --with-cmacs-gowl.  */);
#ifdef HAVE_CMACS_GOWL
  is_cmacs_gowl = true;
#endif

  DEFVAR_BOOL ("IS-CMACS-PODOMATION", is_cmacs_podomation,
    doc: /* Non-nil if this build was configured --with-cmacs-podomation.  */);
#ifdef HAVE_CMACS_PODOMATION
  is_cmacs_podomation = true;
#endif

  DEFVAR_BOOL ("IS-CMACS-LIBRECLAW", is_cmacs_libreclaw,
    doc: /* Non-nil if this build was configured --with-cmacs-libreclaw.  */);
#ifdef HAVE_CMACS_LIBRECLAW
  is_cmacs_libreclaw = true;
#endif

  DEFVAR_BOOL ("IS-CMACS-AI", is_cmacs_ai,
    doc: /* Non-nil if this build was configured --with-cmacs-ai.  */);
#ifdef HAVE_CMACS_AI
  is_cmacs_ai = true;
#endif

  DEFVAR_BOOL ("IS-CMACS-LIBREGNUM", is_cmacs_libregnum,
    doc: /* Non-nil if this build was configured --with-cmacs-libregnum.  */);
#ifdef HAVE_CMACS_LIBREGNUM
  is_cmacs_libregnum = true;
#endif

  DEFVAR_BOOL ("IS-CMACS-LRGTERM", is_cmacs_lrgterm,
    doc: /* Non-nil if this build was configured --with-cmacs-lrgterm.  */);
#ifdef HAVE_CMACS_LRGTERM
  is_cmacs_lrgterm = true;
#endif

  DEFVAR_BOOL ("IS-CMACS-IMGEDIT", is_cmacs_imgedit,
    doc: /* Non-nil if this build was configured --with-cmacs-imgedit.  */);
#ifdef HAVE_CMACS_IMGEDIT
  is_cmacs_imgedit = true;
#endif

  DEFVAR_BOOL ("IS-CMACS-VIDSTUDIO", is_cmacs_vidstudio,
    doc: /* Non-nil if this build was configured --with-cmacs-vidstudio.  */);
#ifdef HAVE_CMACS_VIDSTUDIO
  is_cmacs_vidstudio = true;
#endif

  DEFVAR_BOOL ("IS-CMACS-TRANSCODE", is_cmacs_transcode,
    doc: /* Non-nil if this build was configured --with-cmacs-transcode.  */);
#ifdef HAVE_CMACS_TRANSCODE
  is_cmacs_transcode = true;
#endif

  DEFVAR_BOOL ("IS-CMACS-GNUSEYE", is_cmacs_gnuseye,
    doc: /* Non-nil if this build was configured --with-cmacs-gnuseye.  */);
#ifdef HAVE_CMACS_GNUSEYE
  is_cmacs_gnuseye = true;
#endif

  DEFVAR_BOOL ("IS-CMACS-CAD", is_cmacs_cad,
    doc: /* Non-nil if this build was configured --with-cmacs-cad.  */);
#ifdef HAVE_CMACS_CAD
  is_cmacs_cad = true;
#endif

  DEFVAR_BOOL ("IS-CMACS-SCREENSAVER", is_cmacs_screensaver,
    doc: /* Non-nil if this build was configured --with-cmacs-screensaver.  */);
#ifdef HAVE_CMACS_SCREENSAVER
  is_cmacs_screensaver = true;
#endif

  DEFVAR_BOOL ("IS-CMACS-ORG-EX", is_cmacs_org_ex,
    doc: /* Non-nil if this build was configured --with-cmacs-org-ex.  */);
#ifdef HAVE_CMACS_ORG_EX
  is_cmacs_org_ex = true;
#endif

  DEFVAR_BOOL ("IS-CMACS-MCP", is_cmacs_mcp,
    doc: /* Non-nil if this build was configured --with-cmacs-mcp.  */);
#ifdef HAVE_CMACS_MCP
  is_cmacs_mcp = true;
#endif

  DEFVAR_BOOL ("IS-CMACS-PRINT", is_cmacs_print,
    doc: /* Non-nil if this build was configured --with-cmacs-print.  */);
#ifdef HAVE_CMACS_PRINT
  is_cmacs_print = true;
#endif

  DEFVAR_BOOL ("IS-CMACS-VIDEO", is_cmacs_video,
    doc: /* Non-nil if this build was configured --with-cmacs-video.  */);
#ifdef HAVE_CMACS_VIDEO
  is_cmacs_video = true;
#endif

  DEFVAR_BOOL ("IS-CMACS-AUDIO", is_cmacs_audio,
    doc: /* Non-nil if this build was configured --with-cmacs-audio.  */);
#ifdef HAVE_CMACS_AUDIO
  is_cmacs_audio = true;
#endif

  DEFVAR_BOOL ("IS-CMACS-WHISPER", is_cmacs_whisper,
    doc: /* Non-nil if this build was configured --with-cmacs-whisper.  */);
#ifdef HAVE_CMACS_WHISPER
  is_cmacs_whisper = true;
#endif

  DEFVAR_BOOL ("IS-CMACS-PIPER", is_cmacs_piper,
    doc: /* Non-nil if this build was configured --with-cmacs-piper.  */);
#ifdef HAVE_CMACS_PIPER
  is_cmacs_piper = true;
#endif

  DEFVAR_BOOL ("IS-CMACS-GSURF", is_cmacs_gsurf,
    doc: /* Non-nil if this build was configured --with-cmacs-gsurf.  */);
#ifdef HAVE_CMACS_GSURF
  is_cmacs_gsurf = true;
#endif

  DEFVAR_BOOL ("IS-CMACS-GSURF-LRG", is_cmacs_gsurf_lrg,
    doc: /* Non-nil if this build was configured --with-cmacs-gsurf-lrg
(the GTK-free gsurf backend for `emacs --lrg').  */);
#ifdef HAVE_CMACS_GSURF_LRG
  is_cmacs_gsurf_lrg = true;
#endif

  DEFVAR_BOOL ("IS-CMACS-EMACSCTL", is_cmacs_emacsctl,
    doc: /* Non-nil if this build was configured --with-cmacs-emacsctl
(the standalone emacsctl/cmacsctl control client was built).  */);
#ifdef HAVE_CMACS_EMACSCTL
  is_cmacs_emacsctl = true;
#endif

  DEFVAR_BOOL ("IS-CMACS-CINTROSPECT", is_cmacs_cintrospect,
    doc: /* Non-nil if this build was configured --with-cmacs-cintrospect.  */);
#ifdef HAVE_CMACS_CINTROSPECT
  is_cmacs_cintrospect = true;
#endif

  DEFVAR_BOOL ("IS-CMACS-CPATCH", is_cmacs_cpatch,
    doc: /* Non-nil if this build was configured --enable-cmacs-cpatch.  */);
#ifdef HAVE_CMACS_CPATCH
  is_cmacs_cpatch = true;
#endif

  defsubr (&Scmacs_compiled_features);

  /* Conventional lower-case aliases (is-cmacs-<name>).  Kept in the same
   * order as the flags above. */
  cmacs_features__alias ("is-cmacs-glib",        "IS-CMACS-GLIB");
  cmacs_features__alias ("is-cmacs-gi",          "IS-CMACS-GI");
  cmacs_features__alias ("is-cmacs-crispy",      "IS-CMACS-CRISPY");
  cmacs_features__alias ("is-cmacs-bacon",       "IS-CMACS-BACON");
  cmacs_features__alias ("is-cmacs-gowl",        "IS-CMACS-GOWL");
  cmacs_features__alias ("is-cmacs-podomation",  "IS-CMACS-PODOMATION");
  cmacs_features__alias ("is-cmacs-libreclaw",   "IS-CMACS-LIBRECLAW");
  cmacs_features__alias ("is-cmacs-ai",          "IS-CMACS-AI");
  cmacs_features__alias ("is-cmacs-libregnum",   "IS-CMACS-LIBREGNUM");
  cmacs_features__alias ("is-cmacs-lrgterm",     "IS-CMACS-LRGTERM");
  cmacs_features__alias ("is-cmacs-imgedit",     "IS-CMACS-IMGEDIT");
  cmacs_features__alias ("is-cmacs-vidstudio",   "IS-CMACS-VIDSTUDIO");
  cmacs_features__alias ("is-cmacs-transcode",   "IS-CMACS-TRANSCODE");
  cmacs_features__alias ("is-cmacs-gnuseye",     "IS-CMACS-GNUSEYE");
  cmacs_features__alias ("is-cmacs-cad",         "IS-CMACS-CAD");
  cmacs_features__alias ("is-cmacs-screensaver", "IS-CMACS-SCREENSAVER");
  cmacs_features__alias ("is-cmacs-org-ex",      "IS-CMACS-ORG-EX");
  cmacs_features__alias ("is-cmacs-mcp",         "IS-CMACS-MCP");
  cmacs_features__alias ("is-cmacs-print",       "IS-CMACS-PRINT");
  cmacs_features__alias ("is-cmacs-video",       "IS-CMACS-VIDEO");
  cmacs_features__alias ("is-cmacs-audio",       "IS-CMACS-AUDIO");
  cmacs_features__alias ("is-cmacs-whisper",     "IS-CMACS-WHISPER");
  cmacs_features__alias ("is-cmacs-piper",       "IS-CMACS-PIPER");
  cmacs_features__alias ("is-cmacs-gsurf",       "IS-CMACS-GSURF");
  cmacs_features__alias ("is-cmacs-gsurf-lrg",   "IS-CMACS-GSURF-LRG");
  cmacs_features__alias ("is-cmacs-emacsctl",    "IS-CMACS-EMACSCTL");
  cmacs_features__alias ("is-cmacs-cintrospect", "IS-CMACS-CINTROSPECT");
  cmacs_features__alias ("is-cmacs-cpatch",      "IS-CMACS-CPATCH");
}
