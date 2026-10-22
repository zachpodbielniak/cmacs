/* Camera hand tracking for CMacs -- subsystem entry points.

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

#ifdef HAVE_CMACS_HANDTRACK

#include "lisp.h"
#include "cmacs-handtrack.h"

void
syms_of_cmacs_handtrack (void)
{
  syms_of_cmacs_handtrack_defuns ();
}

void
init_cmacs_handtrack (void)
{
  /* Nothing loads at startup: models are opened by
     `cmacs-handtrack-mode', on a camera the user opened.  */
}

#endif /* HAVE_CMACS_HANDTRACK */
