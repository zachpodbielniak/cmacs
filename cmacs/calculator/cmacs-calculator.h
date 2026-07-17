/* cmacs-calculator.h --- CMacs calculator subsystem

Copyright (C) 2026 Zach Podbielniak

SPDX-License-Identifier: AGPL-3.0-or-later

This file is part of CMacs.  */

#ifndef CMACS_CALCULATOR_H
#define CMACS_CALCULATOR_H

#include <config.h>

#ifdef HAVE_CMACS_CALCULATOR

#include "lisp.h"

/* The calculator subsystem is mostly Elisp: the engine wraps GNU Calc
 * (lisp/cmacs/cmacs-calculator*.el), which already provides arbitrary
 * precision, symbolic algebra, units and CODATA constants.  The C half exists
 * only for the parts that cannot be Lisp:
 *
 *   - GPU charting through libregnum (cmacs-calculator-chart.c, guarded by
 *     HAVE_CMACS_CALCULATOR_CHART -- a build --without-cmacs-libregnum still
 *     gets the whole calculator, just with the SVG chart tier only);
 *   - the `emacs --calc' CLI entry (cmacs-calculator-cli.c).
 *
 * TU firewall: cmacs-calculator-chart.c is the ONLY file here that includes
 * <libregnum.h>, and it never includes lisp.h -- raylib's `Color' struct
 * collides with the `Color' typedef cmacs gets from pgtkgui.h.  Everything
 * else reaches libregnum through the plain-C cmacs-calculator-chart.h.  */

/* Defined in cmacs-calculator-defuns.c.  */
extern void syms_of_cmacs_calculator_defuns (void);

/* syms_of_cmacs_calculator and init_cmacs_calculator are defined in
 * cmacs-calculator-init.c and called from src/emacs.c; they are declared in
 * lisp.h alongside every other subsystem's, so they are deliberately NOT
 * repeated here (-Wredundant-decls is on).  */

#endif /* HAVE_CMACS_CALCULATOR */
#endif /* CMACS_CALCULATOR_H */
