/* cmacs-office.h --- native OOXML + OpenDocument support.
 *
 * Copyright (C) 2026 Zach Podbielniak
 * SPDX-License-Identifier: AGPL-3.0-or-later
 *
 * cmacs-office treats the six office formats -- .docx/.odt,
 * .xlsx/.ods, .pptx/.odp -- as structured, editable, agent-addressable
 * documents rather than as opaque blobs handed to doc-view.
 *
 * The shadow package.  Full OOXML fidelity is a decade of work and is
 * explicitly NOT a goal here.  Instead the package keeps EVERY part of
 * the original zip; loading parses only the parts we understand, and
 * saving rewrites only the parts actually mutated.  A feature we do not
 * model -- SmartArt, a macro, an embedded OLE object, a custom XML part
 * -- survives an edit because it is never regenerated.  That is what
 * makes partial schema coverage safe, and it is the invariant to
 * protect above all others in this subsystem.
 *
 * Architecture.  Three translation-unit classes, the roamgraph split:
 *
 *   - cmacs-office-zip.c (and later -package.c / -model.c / the codecs)
 *     include NEITHER lisp.h NOR any Emacs header, only glib + libzip +
 *     libxml2.  That is what makes the container and the parsers
 *     testable with no Lisp VM and no display.
 *   - cmacs-office-defuns.c includes lisp.h and talks to the model half
 *     only through the plain-C bridge headers.
 *   - cmacs-office-init.c aggregates the per-TU syms_of_ hooks.
 *
 * Division of labour.  C owns the container, the XML, the document
 * model and the cell store.  Elisp owns the org projection, the modes,
 * every keybinding, and the LibreOffice fallback.  Documents cross into
 * Lisp as integer handles (see cmacs-office-defuns.c), never as a
 * Lisp_Object stored in GLib-allocated memory. */

#ifndef CMACS_OFFICE_H
#define CMACS_OFFICE_H

#include <config.h>

#ifdef HAVE_CMACS_OFFICE

#include "lisp.h"

/* syms_of_cmacs_office / init_cmacs_office are declared in src/lisp.h
 * alongside the other cmacs subsystem entry points.  Each office
 * translation unit that registers DEFUNs exposes its own syms_of_ hook,
 * aggregated in cmacs-office-init.c. */
extern void syms_of_cmacs_office_defuns (void);

#endif /* HAVE_CMACS_OFFICE */
#endif /* CMACS_OFFICE_H */
