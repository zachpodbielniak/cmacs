/*
 * Copyright (C) 2026 Zach Podbielniak
 * SPDX-License-Identifier: AGPL-3.0-or-later
 */

/* ctl-main.c --- entry point for emacsctl / cmacsctl.
 *
 * All built-in registration happens here, explicitly (no
 * __attribute__((constructor)) magic --- gnu89-clean and easy to
 * audit).  Adding a future command group means one register call. */

#include "ctl-application.h"
#include "ctl-repl.h"

#include <locale.h>

void ctl_cmd_core_register   (CtlCommandRegistry *registry);
void ctl_cmd_editor_register (CtlCommandRegistry *registry);
void ctl_cmd_subsys_register (CtlCommandRegistry *registry);
void ctl_cmd_gowl_register   (CtlCommandRegistry *registry);

static void
ctl_builtin_register_all (CtlApplication *app)
{
  CtlCommandRegistry *registry = ctl_application_get_registry (app);

  ctl_repl_register_builtin_runtimes ();

  ctl_cmd_core_register (registry);
  ctl_cmd_editor_register (registry);
  ctl_cmd_subsys_register (registry);
  ctl_cmd_gowl_register (registry);
}

int
main (int argc, char **argv)
{
  CtlApplication *app;
  gint code;

  setlocale (LC_ALL, "");

  app = ctl_application_new ();
  ctl_builtin_register_all (app);
  code = ctl_application_run (app, argc, argv);
  g_object_unref (app);
  return code;
}
