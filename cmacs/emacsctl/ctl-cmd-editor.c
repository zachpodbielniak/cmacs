/*
 * Copyright (C) 2026 Zach Podbielniak
 * SPDX-License-Identifier: AGPL-3.0-or-later
 */

/* ctl-cmd-editor.c --- editor-surface command groups.
 *
 * Every verb here is ONE CtlMethodSpec table row bound to a typed
 * org.cmacs.Editor1.* D-Bus method.  Adding a server method to the
 * CLI means adding a row. */

#include "ctl-command-registry.h"
#include "ctl-ifaces.h"

void ctl_cmd_editor_register (CtlCommandRegistry *registry);

static const CtlMethodSpec editor_specs[] = {
  /* get <resource> --- kubectl-style nouns. */
  { "get buffers", "List buffer names",
    CTL_IFACE_BUFMGR, "List", NULL, CTL_REPLY_STRLIST },
  { "get frames", "List frames",
    CTL_IFACE_FRAMEMGR, "List", NULL, CTL_REPLY_STRLIST },
  { "get windows", "List windows",
    CTL_IFACE_WINMGR, "List", NULL, CTL_REPLY_STRLIST },
  { "get processes", "List editor subprocesses",
    CTL_IFACE_PROCMGR, "List", NULL, CTL_REPLY_STRLIST },
  { "get bookmarks", "List bookmarks",
    CTL_IFACE_BOOKMARK, "List", NULL, CTL_REPLY_STRING },
  { "get packages", "List installed packages",
    CTL_IFACE_PACKAGE, "List", NULL, CTL_REPLY_STRING },
  { "get watches", "List live expression watchers",
    CTL_IFACE_WATCH, "List", NULL, CTL_REPLY_STRING },
  { "get content", "Print a buffer's contents",
    CTL_IFACE_EDIT, "GetContent", "s:buffer", CTL_REPLY_STRING },
  /* "get content-org" is a CtlSimpleCommand in ctl-cmd-core.c: it
     takes filter flags and reshapes the reply per output format. */

  /* buffer */
  { "buffer list", "List buffer names",
    CTL_IFACE_BUFMGR, "List", NULL, CTL_REPLY_STRLIST },
  { "buffer current", "Current buffer name",
    CTL_IFACE_BUFMGR, "Current", NULL, CTL_REPLY_STRING },
  { "buffer exists", "Does a buffer exist?",
    CTL_IFACE_BUFMGR, "Find", "s:name", CTL_REPLY_BOOL },
  { "buffer file", "File backing a buffer",
    CTL_IFACE_BUFMGR, "FilenameFor", "s:name", CTL_REPLY_STRING },
  { "buffer modified", "Is a buffer modified?",
    CTL_IFACE_BUFMGR, "ModifiedP", "s:name", CTL_REPLY_BOOL },
  { "buffer create", "Create a buffer",
    CTL_IFACE_BUFMGR, "Create", "s:name", CTL_REPLY_BOOL },
  { "buffer switch", "Switch to a buffer",
    CTL_IFACE_BUFMGR, "Switch", "s:name", CTL_REPLY_BOOL },
  { "buffer save", "Save a buffer",
    CTL_IFACE_BUFMGR, "Save", "s:name", CTL_REPLY_BOOL },
  { "buffer kill", "Kill a buffer",
    CTL_IFACE_BUFMGR, "Kill", "s:name", CTL_REPLY_BOOL },
  { "buffer show", "Print a buffer's contents",
    CTL_IFACE_EDIT, "GetContent", "s:buffer", CTL_REPLY_STRING },
  { "buffer set", "Replace a buffer's contents",
    CTL_IFACE_EDIT, "SetContent", "s:buffer s:content",
    CTL_REPLY_STRING },

  /* edit */
  { "edit exact", "Exact string replacement in a buffer",
    CTL_IFACE_EDIT, "EditExact",
    "s:buffer s:old_string s:new_string b?:replace_all",
    CTL_REPLY_STRING },
  { "edit replace", "Regexp replacement in a buffer",
    CTL_IFACE_EDIT, "Replace", "s:buffer s:regexp s:replacement",
    CTL_REPLY_STRING },
  { "edit search", "Regexp search in a buffer",
    CTL_IFACE_EDIT, "Search", "s:buffer s:regexp", CTL_REPLY_STRING },
  { "edit goto-line", "Move point to a line",
    CTL_IFACE_EDIT, "GotoLine", "s:buffer i:line", CTL_REPLY_STRING },

  /* file */
  { "file open", "Open a file (find-file)",
    CTL_IFACE_FILE, "Open", "s:path", CTL_REPLY_STRING },
  { "file save", "Save a file's buffer",
    CTL_IFACE_FILE, "Save", "s:path", CTL_REPLY_STRING },
  { "file close", "Close a file's buffer",
    CTL_IFACE_FILE, "Close", "s:name", CTL_REPLY_STRING },
  { "file recent", "Recently opened files",
    CTL_IFACE_FILE, "Recent", "i?:count", CTL_REPLY_STRING },

  /* text */
  { "text insert", "Insert text at point",
    CTL_IFACE_TEXT, "Insert", "s:text", CTL_REPLY_STRING },
  { "text append", "Append text to the current buffer",
    CTL_IFACE_TEXT, "Append", "s:text", CTL_REPLY_STRING },
  { "text line", "Print line N",
    CTL_IFACE_TEXT, "Line", "x:line", CTL_REPLY_STRING },
  { "text delete", "Delete a region",
    CTL_IFACE_TEXT, "Delete", "x:start x:end", CTL_REPLY_STRING },

  /* nav */
  { "nav point", "Current line and column",
    CTL_IFACE_NAV, "Point", NULL, CTL_REPLY_STRING },
  { "nav goto", "Go to line/column",
    CTL_IFACE_NAV, "Goto", "x:line x?:col", CTL_REPLY_STRING },

  /* search (current buffer) */
  { "search find", "Count regexp matches in the current buffer",
    CTL_IFACE_SEARCH, "Search", "s:pattern", CTL_REPLY_STRING },
  { "search replace", "Regexp replace in the current buffer",
    CTL_IFACE_SEARCH, "Replace", "s:pattern s:replacement",
    CTL_REPLY_STRING },
  { "search occur", "Occur-style match listing",
    CTL_IFACE_SEARCH, "Occur", "s:pattern", CTL_REPLY_STRING },

  /* vc */
  { "vc status", "Version-control status",
    CTL_IFACE_VC, "Status", NULL, CTL_REPLY_STRING },
  { "vc diff", "Diff a file",
    CTL_IFACE_VC, "Diff", "s?:file", CTL_REPLY_STRING },
  { "vc log", "Commit log",
    CTL_IFACE_VC, "Log", "i?:count s?:file", CTL_REPLY_STRING },
  { "vc blame", "Annotate a file",
    CTL_IFACE_VC, "Blame", "s:file", CTL_REPLY_STRING },

  /* project */
  { "project root", "Project root directory",
    CTL_IFACE_PROJECT, "Root", NULL, CTL_REPLY_STRING },
  { "project grep", "Grep the project tree",
    CTL_IFACE_PROJECT, "Grep", "s:pattern s?:dir", CTL_REPLY_STRING },
  { "project find", "Find files by name",
    CTL_IFACE_PROJECT, "Find", "s:filename s?:dir", CTL_REPLY_STRING },
  { "project files", "List project files",
    CTL_IFACE_PROJECT, "ListFiles", NULL, CTL_REPLY_STRING },
  { "project read", "Read a project file",
    CTL_IFACE_PROJECT, "ReadFile", "s:path", CTL_REPLY_STRING },
  { "project write", "Write a project file",
    CTL_IFACE_PROJECT, "WriteFile", "s:path s:content",
    CTL_REPLY_BOOL },
  { "project compile", "Start a compilation",
    CTL_IFACE_PROJECT, "Compile", "s:command", CTL_REPLY_STRING },

  /* clip */
  { "clip get", "Kill-ring head",
    CTL_IFACE_CLIPBOARD, "Get", NULL, CTL_REPLY_STRING },
  { "clip put", "Push text onto the kill ring",
    CTL_IFACE_CLIPBOARD, "Put", "s:text", CTL_REPLY_STRING },
  { "clip list", "Kill-ring entries",
    CTL_IFACE_CLIPBOARD, "List", NULL, CTL_REPLY_STRING },
  { "clip paste", "Yank at point",
    CTL_IFACE_CLIPBOARD, "Paste", NULL, CTL_REPLY_STRING },

  /* bookmark */
  { "bookmark list", "List bookmarks",
    CTL_IFACE_BOOKMARK, "List", NULL, CTL_REPLY_STRING },
  { "bookmark set", "Set a bookmark at point",
    CTL_IFACE_BOOKMARK, "Set", "s:name", CTL_REPLY_STRING },
  { "bookmark jump", "Jump to a bookmark",
    CTL_IFACE_BOOKMARK, "Jump", "s:name", CTL_REPLY_STRING },
  { "bookmark delete", "Delete a bookmark",
    CTL_IFACE_BOOKMARK, "Delete", "s:name", CTL_REPLY_STRING },

  /* pkg */
  { "pkg list", "List installed packages",
    CTL_IFACE_PACKAGE, "List", NULL, CTL_REPLY_STRING },
  { "pkg install", "Install a package",
    CTL_IFACE_PACKAGE, "Install", "s:name", CTL_REPLY_STRING },
  { "pkg remove", "Remove a package",
    CTL_IFACE_PACKAGE, "Remove", "s:name", CTL_REPLY_STRING },
  { "pkg refresh", "Refresh package archives",
    CTL_IFACE_PACKAGE, "Refresh", NULL, CTL_REPLY_STRING },

  /* var (editor variables, themes, modes) */
  { "var get", "Read an editor variable",
    CTL_IFACE_CONFIG, "Get", "s:name", CTL_REPLY_STRING },
  { "var set", "Set an editor variable",
    CTL_IFACE_CONFIG, "Set", "s:name s:value", CTL_REPLY_STRING },
  { "var theme", "Load a theme",
    CTL_IFACE_CONFIG, "Theme", "s:name", CTL_REPLY_STRING },
  { "var font", "Set the default font",
    CTL_IFACE_CONFIG, "Font", "s:family i:size", CTL_REPLY_STRING },
  { "var mode", "Toggle a mode in the current buffer",
    CTL_IFACE_CONFIG, "Mode", "s:mode", CTL_REPLY_STRING },

  /* input */
  { "input keys", "Send a key sequence (kbd syntax)",
    CTL_IFACE_INPUT, "SendKeys", "s:keys", CTL_REPLY_BOOL },
  { "input command", "Run an interactive command (M-x)",
    CTL_IFACE_INPUT, "ExecuteCommand", "s:command", CTL_REPLY_STRING },

  /* window */
  { "window split", "Split the selected window below",
    CTL_IFACE_WINMGR, "SplitBelow", NULL, CTL_REPLY_BOOL },
  { "window vsplit", "Split the selected window right",
    CTL_IFACE_WINMGR, "SplitRight", NULL, CTL_REPLY_BOOL },
  { "window other", "Select the other window",
    CTL_IFACE_WINMGR, "Other", NULL, CTL_REPLY_STRING },
  { "window delete", "Delete the selected window",
    CTL_IFACE_WINMGR, "Delete", NULL, CTL_REPLY_BOOL },
  { "window select", "Select the window showing a buffer",
    CTL_IFACE_WINMGR, "SelectByBuffer", "s:buffer", CTL_REPLY_BOOL },

  /* process */
  { "process status", "Subprocess status",
    CTL_IFACE_PROCMGR, "Status", "s:name", CTL_REPLY_STRING },
  { "process pid", "Subprocess PID",
    CTL_IFACE_PROCMGR, "Pid", "s:name", CTL_REPLY_INT },
  { "process kill", "Kill a subprocess",
    CTL_IFACE_PROCMGR, "Kill", "s:name", CTL_REPLY_BOOL },
  { "process send", "Send input to a subprocess",
    CTL_IFACE_PROCMGR, "SendTo", "s:name s:input", CTL_REPLY_BOOL },

  /* debug */
  { "debug backtrace", "Lisp backtrace",
    CTL_IFACE_DEBUG, "Backtrace", NULL, CTL_REPLY_STRING },
  { "debug memory", "GC and memory statistics",
    CTL_IFACE_DEBUG, "MemoryInfo", NULL, CTL_REPLY_STRING },
  { "debug hooks", "Non-empty hooks",
    CTL_IFACE_DEBUG, "ListHooks", NULL, CTL_REPLY_STRING },
  { "debug mode", "Current major/minor modes",
    CTL_IFACE_DEBUG, "DescribeMode", NULL, CTL_REPLY_STRING },
  { "debug function", "Describe a function",
    CTL_IFACE_DEBUG, "DescribeFunction", "s:symbol",
    CTL_REPLY_STRING },
  { "debug variable", "Describe a variable",
    CTL_IFACE_DEBUG, "DescribeVariable", "s:symbol",
    CTL_REPLY_STRING },
  { "debug apropos", "Apropos symbol search",
    CTL_IFACE_DEBUG, "Apropos", "s:pattern", CTL_REPLY_STRING },
  { "debug completions", "Symbol completions",
    CTL_IFACE_DEBUG, "Completions", "s:prefix", CTL_REPLY_STRLIST },
  { "debug profiler-start", "Start the CPU profiler",
    CTL_IFACE_DEBUG, "ProfilerStart", NULL, CTL_REPLY_STRING },
  { "debug profiler-stop", "Stop the CPU profiler",
    CTL_IFACE_DEBUG, "ProfilerStop", NULL, CTL_REPLY_STRING },
  { "debug profiler-report", "CPU profiler report",
    CTL_IFACE_DEBUG, "ProfilerReport", NULL, CTL_REPLY_STRING },

  /* c (cintrospect + cpatch) */
  { "c list", "List C symbols (kind: functions|variables|types)",
    CTL_IFACE_CINTROSPECT, "List", "s:kind s?:glob i?:limit",
    CTL_REPLY_STRING },
  { "c symbol", "C symbol info",
    CTL_IFACE_CINTROSPECT, "SymbolInfo", "s:name", CTL_REPLY_STRING },
  { "c type", "C type info",
    CTL_IFACE_CINTROSPECT, "TypeInfo", "s:name", CTL_REPLY_STRING },
  { "c source", "C function source location",
    CTL_IFACE_CINTROSPECT, "FunctionSource", "s:name",
    CTL_REPLY_STRING },
  { "c defuns", "List Lisp primitives (DEFUNs)",
    CTL_IFACE_CINTROSPECT, "ListDefuns", "s?:glob i?:limit",
    CTL_REPLY_STRING },
  { "c defun-info", "DEFUN details",
    CTL_IFACE_CINTROSPECT, "DefunInfo", "s:symbol", CTL_REPLY_STRING },
  { "c stack", "Native C stack trace",
    CTL_IFACE_CINTROSPECT, "StackTrace", "i?:depth",
    CTL_REPLY_STRING },
  { "c patch", "Hot-patch a DEFUN",
    CTL_IFACE_CPATCH, "PatchDefun", "s:symbol s:fn_name",
    CTL_REPLY_STRING },
  { "c unpatch", "Remove a DEFUN patch",
    CTL_IFACE_CPATCH, "UnpatchDefun", "s:symbol", CTL_REPLY_STRING },
  { "c patch-log", "List active patches",
    CTL_IFACE_CPATCH, "PatchList", NULL, CTL_REPLY_STRING },

  /* watch (live expression watchers) */
  { "watch add", "Add a live expression watcher",
    CTL_IFACE_WATCH, "Add", "s:expression", CTL_REPLY_STRING },
  { "watch rm", "Remove a watcher by handle",
    CTL_IFACE_WATCH, "Remove", "o:handle", CTL_REPLY_BOOL },
  { "watch list", "List watcher handles",
    CTL_IFACE_WATCH, "List", NULL, CTL_REPLY_STRING },

  /* root iface odds and ends */
  { "message", "Show a message in the echo area",
    CTL_IFACE_ROOT, "Message", "s:text", CTL_REPLY_NONE },
  { "find-file", "Open a file via find-file",
    CTL_IFACE_ROOT, "FindFile", "s:path", CTL_REPLY_NONE },

  { NULL, NULL, NULL, NULL, NULL, 0 }
};

void
ctl_cmd_editor_register (CtlCommandRegistry *registry)
{
  gint k;
  for (k = 0; editor_specs[k].name != NULL; k++)
    ctl_command_registry_add (registry,
                              ctl_method_command_new (&editor_specs[k]));
}
