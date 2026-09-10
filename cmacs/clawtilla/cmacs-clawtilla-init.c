/* Clawtilla fleet client for CMacs -- subsystem entry points.

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

#ifdef HAVE_CMACS_CLAWTILLA

#include "lisp.h"
#include "cmacs-clawtilla.h"

static bool init_done = false;

void
syms_of_cmacs_clawtilla (void)
{
  syms_of_cmacs_clawtilla_defuns ();
}

void
init_cmacs_clawtilla (void)
{
  /* Guarded because a pdumped Emacs runs this again on restore.  */
  if (init_done)
    return;
  init_done = true;

  /* No daemon is started and nothing is connected here.  The normal
     use is a daemon that is already running -- on this machine or on
     another one -- so connecting is a decision the user makes, not
     something startup does on their behalf.  */
  cmacs_clawt_init ();
}

#endif /* HAVE_CMACS_CLAWTILLA */
