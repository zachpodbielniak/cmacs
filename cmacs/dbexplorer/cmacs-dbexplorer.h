/* cmacs-dbexplorer.h --- database explorer subsystem

Copyright (C) 2026 Zach Podbielniak

This file is part of CMacs.

CMacs is free software: you can redistribute it and/or modify it under
the terms of the GNU Affero General Public License as published by the
Free Software Foundation, either version 3 of the License, or (at your
option) any later version.

CMacs is distributed in the hope that it will be useful, but WITHOUT ANY
WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS
FOR A PARTICULAR PURPOSE.  See the GNU Affero General Public License for
more details.

You should have received a copy of the GNU Affero General Public License
along with CMacs.  If not, see <https://www.gnu.org/licenses/>.

SPDX-License-Identifier: AGPL-3.0-or-later  */

/* Three translation-unit classes, the office/roamgraph split:

   - cmacs-dbexplorer-conn.c, -query.c and -schema.c are the model half.
     They include <orm.h> and glib and NEITHER lisp.h NOR any Emacs
     header.  That is what keeps the connection handling, the read-only
     SQL classifier and the schema readers testable with no Lisp VM.

   - cmacs-dbexplorer-defuns.c is the Lisp half.  It includes lisp.h and
     reaches the model only through this plain-C bridge header, so it
     never sees an OrmConnection or an OrmValue.

   - cmacs-dbexplorer-init.c aggregates the per-TU syms_of_ hooks.

   Handles are integers rather than pointers, and never Lisp_Object,
   because a Lisp_Object living in GLib-allocated memory has no GC root.  */

#ifndef CMACS_DBEXPLORER_H
#define CMACS_DBEXPLORER_H

#include <config.h>

#ifdef HAVE_CMACS_DBEXPLORER

#include "lisp.h"

/* Each translation unit that registers DEFUNs exposes its own hook;
   cmacs-dbexplorer-init.c calls them.  syms_of_cmacs_dbexplorer and
   init_cmacs_dbexplorer themselves are declared in src/lisp.h.  */
extern void syms_of_cmacs_dbexplorer_defuns (void);
extern void syms_of_cmacs_dbexplorer_events (void);

#endif /* HAVE_CMACS_DBEXPLORER */

#endif /* CMACS_DBEXPLORER_H */
