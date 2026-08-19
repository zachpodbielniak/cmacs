/* cmacs-dbexplorer-schema.c --- database explorer model layer

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

/* Model half: this file sees orm-glib and glib, and must never include
   lisp.h.  See cmacs/dbexplorer/cmacs-dbexplorer.h for why.  */

#include <config.h>

#ifdef HAVE_CMACS_DBEXPLORER

#define ORM_INSIDE
#include <orm.h>
#undef ORM_INSIDE

#endif /* HAVE_CMACS_DBEXPLORER */
