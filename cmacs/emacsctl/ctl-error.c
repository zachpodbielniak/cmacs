/*
 * Copyright (C) 2026 Zach Podbielniak
 * SPDX-License-Identifier: AGPL-3.0-or-later
 */

/* ctl-error.c --- the emacsctl error domain and exit-code mapping.
 * Kept in its own translation unit so transport-free units (frame
 * codec, config) stay independently linkable in the test harness. */

#include "ctl.h"

GQuark
ctl_error_quark (void)
{
  return g_quark_from_static_string ("emacsctl-error");
}

gint
ctl_exit_code_for_error (const GError *error)
{
  if (error == NULL)
    return CTL_EXIT_ERROR;
  if (error->domain == CTL_ERROR)
    {
      switch (error->code)
        {
        case CTL_ERROR_USAGE:       return CTL_EXIT_USAGE;
        case CTL_ERROR_UNSUPPORTED: return CTL_EXIT_UNSUPPORTED;
        case CTL_ERROR_NO_INSTANCE: return CTL_EXIT_NO_INSTANCE;
        default:                    return CTL_EXIT_ERROR;
        }
    }
  if (error->domain == G_DBUS_ERROR)
    {
      if (error->code == G_DBUS_ERROR_UNKNOWN_INTERFACE
          || error->code == G_DBUS_ERROR_UNKNOWN_METHOD)
        return CTL_EXIT_UNSUPPORTED;
      if (error->code == G_DBUS_ERROR_SERVICE_UNKNOWN
          || error->code == G_DBUS_ERROR_NAME_HAS_NO_OWNER)
        return CTL_EXIT_NO_INSTANCE;
    }
  return CTL_EXIT_ERROR;
}
