/* cmacs-dbexplorer-defuns.c --- Lisp interface to the database explorer

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

#include <config.h>

#ifdef HAVE_CMACS_DBEXPLORER

#include "cmacs-dbexplorer.h"

/* Every failure in this subsystem is signalled as one condition, so Lisp
   can catch the whole surface with a single handler.  The symbol itself
   needs no declaration here: DEFSYM below is what make-docfile scans,
   and globals.h defines the name.  */

DEFUN ("cmacs-dbexplorer-supported-p", Fcmacs_dbexplorer_supported_p,
       Scmacs_dbexplorer_supported_p, 0, 0, 0,
       doc: /* Return non-nil if this build has the database explorer.

This is the runtime companion to `IS-CMACS-DBEXPLORER': the variable says
the subsystem was compiled in, and this says its primitives are actually
reachable.  */)
  (void)
{
  return Qt;
}

void
syms_of_cmacs_dbexplorer_defuns (void)
{
  DEFSYM (Qcmacs_dbexplorer_error, "cmacs-dbexplorer-error");
  Fput (Qcmacs_dbexplorer_error, Qerror_conditions,
	list2 (Qcmacs_dbexplorer_error, Qerror));
  Fput (Qcmacs_dbexplorer_error, Qerror_message,
	build_string ("CMacs database explorer error"));

  defsubr (&Scmacs_dbexplorer_supported_p);
}

#endif /* HAVE_CMACS_DBEXPLORER */
