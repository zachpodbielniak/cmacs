/*
 * Copyright (C) 2026 Zach Podbielniak
 * SPDX-License-Identifier: AGPL-3.0-or-later
 */

/* ctl-cmd-gowl.c --- Wayland compositor + display configuration
 * command groups (org.cmacs.Editor1.Compositor / .Monitor, present
 * when the target cmacs is built with --with-cmacs-gowl).
 *
 * A CTL_ALIAS_ROW ("verb") is a verb whose capability is a registry
 * tool; its row is in ctl-cmd-alias.c. */

#include "ctl-cmd-alias.h"
#include "ctl-command-registry.h"
#include "ctl-ifaces.h"

void ctl_cmd_gowl_register (CtlCommandRegistry *registry);

static const CtlMethodSpec gowl_specs[] = {
  /* compositor */
  CTL_ALIAS_ROW ("compositor clients"),
  CTL_ALIAS_ROW ("compositor focused"),
  { "compositor spawn", "Spawn a command in the compositor",
    CTL_IFACE_COMPOSITOR, "Spawn", "s:command", CTL_REPLY_STRING },
  CTL_ALIAS_ROW ("compositor find"),
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
  CTL_ALIAS_ROW ("compositor workspaces"),
  { "compositor workspace", "Switch workspace by id",
    CTL_IFACE_COMPOSITOR, "WorkspaceSwitch", "i:id",
    CTL_REPLY_STRING },
  { "compositor screenshot", "Screenshot to a PNG file "
    "(mode: desktop|window|all; client pattern optional)",
    CTL_IFACE_COMPOSITOR, "Screenshot",
    "s?:mode s?:client s?:by s:file", CTL_REPLY_STRING },
  CTL_ALIAS_ROW ("compositor keybinds"),
  { "compositor run-keybind", "Run what a key is bound to "
    "(e.g. \"Super+Return\"); not the same as injecting the key, "
    "which goes to the focused client",
    CTL_IFACE_COMPOSITOR, "RunKeybind", "s:key", CTL_REPLY_STRING },
  { "compositor macro", "Run a gowl macro by name or path with its "
    "arguments (loads the opt-in macro module on first use)",
    CTL_IFACE_COMPOSITOR, "RunMacro", "s:name A:args", CTL_REPLY_STRING },
  { "compositor broadcast", "Input broadcasting: status, list, on, "
    "off, toggle or panic (loads the opt-in broadcast module)",
    CTL_IFACE_COMPOSITOR, "Broadcast", "s:verb", CTL_REPLY_STRING },
  { "compositor floatdesk", "Floating desktop: toggle/on/off [TAG], "
    "default on|off, status, minimize/restore/maximize [ID], snap "
    "'left|right|max [ID]', dock-position/-autohide/-pin/-unpin/"
    "-launch/-apps (several words of ARGS go in one quoted argument)",
    CTL_IFACE_COMPOSITOR, "Floatdesk", "s:verb s?:args", CTL_REPLY_STRING },
  { "compositor hotkey", "Hotkeys (AutoHotkey): status, list, "
    "problems, add YAML, remove/enable/disable/toggle/fire ID, suspend "
    "[on|off|toggle], mode [NAME], send KEYS, send-text TEXT, call NAME "
    "ARGS, history, keystate KEY, timers, reload (loads the opt-in hotkey "
    "module; several words of ARGS go in one quoted argument)",
    CTL_IFACE_COMPOSITOR, "Hotkey", "s:verb s?:args", CTL_REPLY_STRING },
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
  CTL_ALIAS_ROW ("compositor screensaver"),
  CTL_ALIAS_ROW ("compositor screensaver-stop"),
  CTL_ALIAS_ROW ("compositor screensaver-configs"),
  CTL_ALIAS_ROW ("compositor screensaver-status"),
  CTL_ALIAS_ROW ("compositor screensaver-restart"),
  CTL_ALIAS_ROW ("compositor screensaver-pause"),
  CTL_ALIAS_ROW ("compositor screensaver-resume"),
  CTL_ALIAS_ROW ("compositor screensaver-fps"),
  { "compositor mode", "Enter a key mode (\"default\" leaves it)",
    CTL_IFACE_COMPOSITOR, "SetKeyMode", "s:mode", CTL_REPLY_STRING },
  { "compositor mode-get", "The key mode in force",
    CTL_IFACE_COMPOSITOR, "KeyMode", NULL, CTL_REPLY_STRING },
  { "compositor keyboard-layout", "Switch the keyboard layout "
    "(next|prev|index; default next)",
    CTL_IFACE_COMPOSITOR, "SwitchKeyboardLayout", "s?:which",
    CTL_REPLY_STRING },
  { "compositor keyboard-layout-get", "The active keyboard layout",
    CTL_IFACE_COMPOSITOR, "KeyboardLayout", NULL, CTL_REPLY_STRING },
  { "compositor focus-dir", "Focus the nearest window in a direction "
    "(left|right|up|down)",
    CTL_IFACE_COMPOSITOR, "FocusDirection", "s:direction",
    CTL_REPLY_STRING },
  { "compositor focus-urgent", "Focus the urgent window",
    CTL_IFACE_COMPOSITOR, "FocusUrgent", NULL, CTL_REPLY_STRING },
  { "compositor focus-last", "Focus the previous window",
    CTL_IFACE_COMPOSITOR, "FocusLast", NULL, CTL_REPLY_STRING },
  { "compositor power", "Power every output on|off|toggle",
    CTL_IFACE_COMPOSITOR, "OutputPower", "s:mode", CTL_REPLY_STRING },
  { "compositor confine", "Keep the pointer in the focused window "
    "(on|off|toggle|state; default state)",
    CTL_IFACE_COMPOSITOR, "PointerConfine", "s?:mode", CTL_REPLY_STRING },
  { "compositor reload", "Reload the compositor config",
    CTL_IFACE_COMPOSITOR, "ReloadConfig", NULL, CTL_REPLY_STRING },
  { "compositor config", "Read a compositor config property",
    CTL_IFACE_COMPOSITOR, "ConfigGet", "s:property",
    CTL_REPLY_STRING },

  /* monitor (display configuration) */
  CTL_ALIAS_ROW ("monitor list"),
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
    ctl_command_registry_add (
      registry, ctl_cmd_alias_command_for_row (&gowl_specs[k]));
}
