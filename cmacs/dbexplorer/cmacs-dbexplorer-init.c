/* cmacs-dbexplorer-init.c --- database explorer subsystem entry points

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

#include "lisp.h"
#include "cmacs-dbexplorer.h"

static bool init_done = false;

void
syms_of_cmacs_dbexplorer (void)
{
  syms_of_cmacs_dbexplorer_defuns ();
  syms_of_cmacs_dbexplorer_events ();
}

void
init_cmacs_dbexplorer (void)
{
  /* Guarded because a pdumped Emacs runs this again on restore.  */
  if (init_done)
    return;
  init_done = true;

  /* The model half publishes through function pointers rather than
     calling into the Lisp half directly, so that the connection
     handling, the SQL classifier and the schema readers stay linkable
     and testable without a Lisp VM.  This is where the two are joined. */
  cmacs_dbx_events_install ();
}

#endif /* HAVE_CMACS_DBEXPLORER */
