/* SpaceMouse / 6DOF input for CMacs -- subsystem entry points.

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

#ifdef HAVE_CMACS_SPACEMOUSE

#include "lisp.h"
#include "cmacs-spacemouse.h"

void
syms_of_cmacs_spacemouse (void)
{
  syms_of_cmacs_spacemouse_defuns ();
}

void
init_cmacs_spacemouse (void)
{
  /* Nothing connects at startup: `cmacs-spacemouse-mode' (or
     `cmacs-spacemouse-start') does, so a session without a device -- or
     a batch run -- never opens a socket.  */
}

#endif /* HAVE_CMACS_SPACEMOUSE */
