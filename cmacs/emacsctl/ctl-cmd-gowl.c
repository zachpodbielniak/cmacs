/*
 * Copyright (C) 2026 Zach Podbielniak
 * SPDX-License-Identifier: AGPL-3.0-or-later
 */

/* ctl-cmd-gowl.c --- Wayland compositor + display configuration
 * command groups (org.cmacs.Editor1.Compositor / .Monitor, present
 * when the target cmacs is built with --with-cmacs-gowl). */

#include "ctl-command-registry.h"
#include "ctl-ifaces.h"

void ctl_cmd_gowl_register (CtlCommandRegistry *registry);

static const CtlMethodSpec gowl_specs[] = {
  /* compositor */
  { "compositor clients", "List Wayland clients",
    CTL_IFACE_COMPOSITOR, "ListClients", NULL, CTL_REPLY_JSON },
  { "compositor focused", "Focused client info",
    CTL_IFACE_COMPOSITOR, "FocusedClient", NULL, CTL_REPLY_JSON },
  { "compositor spawn", "Spawn a command in the compositor",
    CTL_IFACE_COMPOSITOR, "Spawn", "s:command", CTL_REPLY_STRING },
  { "compositor find", "Find a client (by app-id or title)",
    CTL_IFACE_COMPOSITOR, "FindClient", "s:pattern s?:by",
    CTL_REPLY_JSON },
  { "compositor focus", "Focus a client by pattern",
    CTL_IFACE_COMPOSITOR, "FocusClient", "s:pattern s?:by",
    CTL_REPLY_STRING },
  { "compositor close", "Close a client by pattern",
    CTL_IFACE_COMPOSITOR, "CloseClient", "s:pattern s?:by",
    CTL_REPLY_STRING },
  { "compositor geometry", "Set client geometry "
    "(pattern by x y width height)",
    CTL_IFACE_COMPOSITOR, "SetClientGeometry",
    "s:pattern s:by i:x i:y i:width i:height", CTL_REPLY_STRING },
  { "compositor layout", "Set the layout",
    CTL_IFACE_COMPOSITOR, "SetLayout", "s:layout", CTL_REPLY_STRING },
  { "compositor workspaces", "List workspaces",
    CTL_IFACE_COMPOSITOR, "WorkspaceList", NULL, CTL_REPLY_STRING },
  { "compositor workspace", "Switch workspace by id",
    CTL_IFACE_COMPOSITOR, "WorkspaceSwitch", "i:id",
    CTL_REPLY_STRING },
  { "compositor screenshot", "Screenshot to a PNG file "
    "(mode: desktop|window|all; client pattern optional)",
    CTL_IFACE_COMPOSITOR, "Screenshot",
    "s?:mode s?:client s?:by s:file", CTL_REPLY_STRING },
  { "compositor keybinds", "List keybinds",
    CTL_IFACE_COMPOSITOR, "ListKeybinds", NULL, CTL_REPLY_JSON },
  { "compositor mfact", "Set the master area factor",
    CTL_IFACE_COMPOSITOR, "SetMfact", "d:mfact", CTL_REPLY_STRING },
  { "compositor nmaster", "Set the number of master windows",
    CTL_IFACE_COMPOSITOR, "SetNmaster", "i:n", CTL_REPLY_STRING },
  { "compositor tags", "View a tag mask",
    CTL_IFACE_COMPOSITOR, "ViewTags", "u:tagmask", CTL_REPLY_STRING },
  { "compositor lock", "Lock the session",
    CTL_IFACE_COMPOSITOR, "Lock", NULL, CTL_REPLY_STRING },
  { "compositor unlock", "Unlock the session",
    CTL_IFACE_COMPOSITOR, "Unlock", NULL, CTL_REPLY_STRING },
  { "compositor screensaver", "Set the animated screensaver wallpaper "
    "(config name from cmacs-screensaver-configs; omit for the default)",
    CTL_IFACE_COMPOSITOR, "SetScreensaverWallpaper", "s?:config",
    CTL_REPLY_STRING },
  { "compositor screensaver-stop", "Stop the animated screensaver wallpaper",
    CTL_IFACE_COMPOSITOR, "StopScreensaverWallpaper", NULL,
    CTL_REPLY_STRING },
  { "compositor screensaver-configs", "List screensaver config names",
    CTL_IFACE_COMPOSITOR, "ListScreensaverConfigs", NULL,
    CTL_REPLY_STRING },
  { "compositor screensaver-status",
    "Show the out-of-process screensaver renderer status (plist)",
    CTL_IFACE_COMPOSITOR, "ScreensaverStatus", NULL,
    CTL_REPLY_STRING },
  { "compositor screensaver-restart",
    "Kill and respawn the screensaver render child",
    CTL_IFACE_COMPOSITOR, "ScreensaverRestart", NULL,
    CTL_REPLY_STRING },
  { "compositor screensaver-pause", "Pause animated wallpaper/lock rendering",
    CTL_IFACE_COMPOSITOR, "ScreensaverPause", NULL,
    CTL_REPLY_STRING },
  { "compositor screensaver-resume", "Resume animated wallpaper/lock rendering",
    CTL_IFACE_COMPOSITOR, "ScreensaverResume", NULL,
    CTL_REPLY_STRING },
  { "compositor screensaver-fps", "Set animated wallpaper/lock FPS (1-240)",
    CTL_IFACE_COMPOSITOR, "ScreensaverSetFps", "i:fps",
    CTL_REPLY_STRING },
  { "compositor reload", "Reload the compositor config",
    CTL_IFACE_COMPOSITOR, "ReloadConfig", NULL, CTL_REPLY_STRING },
  { "compositor config", "Read a compositor config property",
    CTL_IFACE_COMPOSITOR, "ConfigGet", "s:property",
    CTL_REPLY_STRING },

  /* monitor (display configuration) */
  { "monitor list", "List monitors",
    CTL_IFACE_MONITOR, "List", NULL, CTL_REPLY_JSON },
  { "monitor info", "Monitor details",
    CTL_IFACE_MONITOR, "Info", "s:name", CTL_REPLY_JSON },
  { "monitor modes", "Available modes",
    CTL_IFACE_MONITOR, "Modes", "s:name", CTL_REPLY_JSON },
  { "monitor set-mode", "Set a mode (name w h refresh_mhz)",
    CTL_IFACE_MONITOR, "SetMode", "s:name i:width i:height i:refresh",
    CTL_REPLY_STRING },
  { "monitor position", "Monitor position",
    CTL_IFACE_MONITOR, "Position", "s:name", CTL_REPLY_STRING },
  { "monitor set-position", "Move a monitor",
    CTL_IFACE_MONITOR, "SetPosition", "s:name i:x i:y",
    CTL_REPLY_STRING },
  { "monitor enable", "Enable/disable a monitor",
    CTL_IFACE_MONITOR, "SetEnabled", "s:name b:enabled",
    CTL_REPLY_STRING },
  { "monitor scale", "Set a monitor's scale",
    CTL_IFACE_MONITOR, "SetScale", "s:name d:scale",
    CTL_REPLY_STRING },
  { "monitor transform", "Set a monitor's transform (0-7)",
    CTL_IFACE_MONITOR, "SetTransform", "s:name i:transform",
    CTL_REPLY_STRING },

  { NULL, NULL, NULL, NULL, NULL, 0 }
};

void
ctl_cmd_gowl_register (CtlCommandRegistry *registry)
{
  gint k;
  for (k = 0; gowl_specs[k].name != NULL; k++)
    ctl_command_registry_add (registry,
                              ctl_method_command_new (&gowl_specs[k]));
}
