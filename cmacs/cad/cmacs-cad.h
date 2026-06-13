/* cmacs-cad.h --- Parametric CAD subsystem for cmacs
 *
 * Copyright (C) 2026 Zach Podbielniak
 * SPDX-License-Identifier: AGPL-3.0-or-later
 *
 * Part source (.cad s-expressions / .ccad crispy) evaluates through
 * cad-glib into solids with feature trees and source spans; geometry
 * renders through the libregnum editor's CAD_PART node path.  This
 * header is the subsystem's pure-C surface: lisp.h only -- cad-glib
 * types stay inside cmacs-cad-doc.c (the firewall discipline used by
 * cmacs/libregnum and cmacs/gnuseye).
 */

#ifndef CMACS_CAD_H
#define CMACS_CAD_H

#include <config.h>

#ifdef HAVE_CMACS_CAD

#include "lisp.h"

extern void syms_of_cmacs_cad (void);
extern void init_cmacs_cad (void);
extern void syms_of_cmacs_cad_defuns (void);
extern void syms_of_cmacs_cad_sketch (void);
extern void syms_of_cmacs_cad_assembly (void);

#endif /* HAVE_CMACS_CAD */
#endif /* CMACS_CAD_H */
