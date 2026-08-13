/* cmacs-roamgraph-scan.c --- native :ID: / [[id:]] org scanner.
 *
 * Copyright (C) 2026 Zach Podbielniak
 * SPDX-License-Identifier: AGPL-3.0-or-later
 *
 * The fallback data source, for a notes tree with no org-roam
 * database: a line scanner that extracts file-level and heading-level
 * :ID: properties, #+title:, #+filetags: and [[id:UUID]] link targets.
 *
 * Deliberately a line scanner rather than an org parser, and
 * deliberately without file:-link resolution: reimplementing org's
 * link semantics in C would drift from the one implementation Emacs
 * already owns.  When an org-roam database exists it is authoritative
 * and this never runs.
 *
 * Includes lisp.h, never <libregnum.h>. */

#include <config.h>

#ifdef HAVE_CMACS_ROAMGRAPH

#include "lisp.h"
#include "coding.h"
#include "cmacs-roamgraph.h"

/* Filled in by a later phase; the DEFUN is registered now so the Lisp
   source-selection layer can probe for it with `fboundp'. */

DEFUN ("cmacs-roamgraph-scan-supported-p",
       Fcmacs_roamgraph_scan_supported_p,
       Scmacs_roamgraph_scan_supported_p, 0, 0, 0,
       doc: /* Return non-nil if the native org scanner is available.  */)
  (void)
{
  return Qnil;
}

void
syms_of_cmacs_roamgraph_scan (void)
{
  defsubr (&Scmacs_roamgraph_scan_supported_p);
}

#endif /* HAVE_CMACS_ROAMGRAPH */
