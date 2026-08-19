/*
 * Copyright (C) 2026 Zach Podbielniak
 * SPDX-License-Identifier: AGPL-3.0-or-later
 */

/* ctl-ifaces.h --- every org.cmacs.Editor1[.X] name emacsctl talks to.
 *
 * Centralized so a server-side rename is a one-line client fix.  The
 * authoritative definitions live in cmacs/dbus/cmacs-dbus-iface-*.c. */

#ifndef CTL_IFACES_H
#define CTL_IFACES_H

#define CTL_BUS_WELL_KNOWN   "org.cmacs.Editor"
#define CTL_BUS_PID_PREFIX   "org.cmacs.Editor.Pid"
#define CTL_OBJECT_PATH      "/org/cmacs/Editor"

#define CTL_IFACE_ROOT       "org.cmacs.Editor1"
#define CTL_IFACE_BUFMGR     "org.cmacs.Editor1.BufferManager"
#define CTL_IFACE_FRAMEMGR   "org.cmacs.Editor1.FrameManager"
#define CTL_IFACE_WINMGR     "org.cmacs.Editor1.WindowManager"
#define CTL_IFACE_PROCMGR    "org.cmacs.Editor1.ProcessManager"
#define CTL_IFACE_SEARCH     "org.cmacs.Editor1.Search"
#define CTL_IFACE_VC         "org.cmacs.Editor1.VC"
#define CTL_IFACE_PROJECT    "org.cmacs.Editor1.Project"
#define CTL_IFACE_CINTROSPECT "org.cmacs.Editor1.Cintrospect"
#define CTL_IFACE_CPATCH     "org.cmacs.Editor1.Cpatch"
#define CTL_IFACE_BOOKMARK   "org.cmacs.Editor1.Bookmark"
#define CTL_IFACE_CLIPBOARD  "org.cmacs.Editor1.Clipboard"
#define CTL_IFACE_PACKAGE    "org.cmacs.Editor1.Package"
#define CTL_IFACE_FILE       "org.cmacs.Editor1.File"
#define CTL_IFACE_TEXT       "org.cmacs.Editor1.Text"
#define CTL_IFACE_NAV        "org.cmacs.Editor1.Nav"
#define CTL_IFACE_CONFIG     "org.cmacs.Editor1.Config"
#define CTL_IFACE_WATCH      "org.cmacs.Editor1.Watch"
#define CTL_IFACE_COMPOSITOR "org.cmacs.Editor1.Compositor"
#define CTL_IFACE_MONITOR    "org.cmacs.Editor1.Monitor"

/* Phase 6 MCP-parity ifaces. */
#define CTL_IFACE_CRISPY     "org.cmacs.Editor1.Crispy"
#define CTL_IFACE_BACON      "org.cmacs.Editor1.Bacon"
#define CTL_IFACE_ESHELL     "org.cmacs.Editor1.Eshell"
#define CTL_IFACE_EDIT       "org.cmacs.Editor1.Edit"
#define CTL_IFACE_INPUT      "org.cmacs.Editor1.Input"
#define CTL_IFACE_DEBUG      "org.cmacs.Editor1.Debug"
#define CTL_IFACE_AI         "org.cmacs.Editor1.Ai"
#define CTL_IFACE_GSURF      "org.cmacs.Editor1.Gsurf"
#define CTL_IFACE_GNUSEYE    "org.cmacs.Editor1.GnusEye"
#define CTL_IFACE_PODOMATION "org.cmacs.Editor1.Podomation"
#define CTL_IFACE_VIDEO      "org.cmacs.Editor1.Video"
#define CTL_IFACE_AUDIO      "org.cmacs.Editor1.Audio"
#define CTL_IFACE_SPEECH     "org.cmacs.Editor1.Speech"
#define CTL_IFACE_LRG        "org.cmacs.Editor1.Lrg"
#define CTL_IFACE_CALC       "org.cmacs.Editor1.Calc"
#define CTL_IFACE_DBEXPLORER "org.cmacs.Editor1.DbExplorer"
#define CTL_IFACE_BRIGADE    "org.cmacs.Editor1.Brigade"
#define CTL_IFACE_INSTANCE   "org.cmacs.Editor1.Instance"
#define CTL_IFACE_LOG        "org.cmacs.Editor1.Log"
#define CTL_IFACE_EVENTS     "org.cmacs.Editor1.Events"

#endif /* CTL_IFACES_H */
