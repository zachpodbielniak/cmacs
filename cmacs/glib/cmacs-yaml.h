/* cmacs-yaml.h — YAML file -> JSON text primitive
 *
 * Copyright (C) 2026 Zach Podbielniak
 * SPDX-License-Identifier: AGPL-3.0-or-later
 *
 * Emacs has no YAML reader.  cmacs already links yaml-glib, so one
 * small DEFUN hands a YAML document to Elisp as JSON text, which
 * `json-parse-string' turns into data.  See cmacs-yaml.c.
 */

#ifndef CMACS_YAML_H
#define CMACS_YAML_H

#include "lisp.h"

extern void syms_of_cmacs_yaml (void);

#endif /* CMACS_YAML_H */
