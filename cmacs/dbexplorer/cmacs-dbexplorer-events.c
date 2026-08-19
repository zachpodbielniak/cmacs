/* cmacs-dbexplorer-events.c --- delivering async results into Lisp

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

/* Two callback lifetimes, because queries have two shapes.

   A one-shot -- connect, execute, apply-edits -- registers its Lisp
   callback with cmacs-eval-dispatch's cookie registry, which is a
   staticpro'd hash table, and the invoke-and-pop drops the GC root
   atomically when the reply lands.

   A stream -- a query, an export -- calls back many times before it is
   done, so a single-shot cookie is the wrong shape.  Those live in the
   table below, keyed by an integer stream id, until the terminating
   (:end) or (:error) event removes them.

   Both deliver through cmacs_dispatch_safe_call*, never safe_calln
   directly: a GLib callback can arrive while Emacs believes it is
   waiting for input, and a Lisp error raised in that state aborts the
   process rather than being caught.  */

#include <config.h>

#ifdef HAVE_CMACS_DBEXPLORER

#include "cmacs-dbexplorer.h"

void
syms_of_cmacs_dbexplorer_events (void)
{
}

#endif /* HAVE_CMACS_DBEXPLORER */
