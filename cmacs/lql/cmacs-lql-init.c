/* cmacs-lql-init.c --- LQL subsystem entry points

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

#ifdef HAVE_CMACS_LQL

#include "lisp.h"
#include "cmacs-lql.h"

void
syms_of_cmacs_lql (void)
{
  syms_of_cmacs_lql_defuns ();
}

void
init_cmacs_lql (void)
{
  /* Nothing to do at startup: the environment is built on first use, so
     an Emacs that never runs a query never reads ~/.config/lql or probes
     for kubectl and journalctl.  Building it here would also run before
     a pdumped image's restore, against state the dump cannot carry.  */
}

#endif /* HAVE_CMACS_LQL */
