/*
 * Copyright (C) 2026 Zach Podbielniak
 * SPDX-License-Identifier: AGPL-3.0-or-later
 */

/* ctl-cmd-alias.c --- the verbs that are aliases of registry tools.
 *
 * `emacsctl calc eval', `emacsctl gsurf open', `emacsctl db tables'
 * and about a hundred more used to be rows in the ctl-cmd-*.c tables,
 * each naming one hand-written D-Bus method.  The capability behind
 * each is now a tool in the registry, which `emacsctl tool ...'
 * reaches through org.cmacs.Editor1.Tools.Call.  This file keeps the
 * old spellings and sends them down that one path:
 *
 *   emacsctl calc units '60 mph' m/s
 *     -> Tools.Call ("calc_convert_units",
 *                    {"expression": "60 mph", "units": "m/s"})
 *
 * A row is declarative (ctl-alias.h describes the fields) and running
 * one is a single D-Bus call: the tool, its parameter names and how to
 * print its answer are all in the row, so the tool list is not fetched.
 * It is fetched for `--help', whose text is the tool's own description.
 *
 * WHEN THE TOOL CANNOT BE REACHED.  An older cmacs has no
 * org.cmacs.Editor1.Tools, a newer one may have dropped a tool, and a
 * user may have taken one off D-Bus.  In each case the call is refused
 * before the tool runs, and the alias then calls the D-Bus method the
 * verb used to be -- the `legacy' half of its row -- exactly as the old
 * table row did.  ctl_alias_decide is the rule, and it never retries a
 * call that may have started.
 *
 * WHAT IS NOT HERE.  A verb stays a hand-written row when no tool does
 * the same thing, when its tool is not on the `cli' surface, or when
 * the tool's answer cannot be turned back into what the verb printed.
 * `kept_verbs' below records which and why, verb by verb; a verb that
 * is neither an alias nor listed there fails the unit tests.
 *
 * ADDING ONE.  Replace the verb's row in its ctl-cmd-*.c table with
 * CTL_ALIAS_ROW ("the verb"), move the row here behind the tool's name,
 * and delete its line from kept_verbs.  The row layout is parsed as
 * text by test/cmacs/cmacs-emacsctl-alias-tests.el, which checks each
 * tool and parameter against the generated capability reference, and
 * by admin/cmacs-capability-audit.sh, which lists the verbs: keep the
 * first line `{ "tool", PARAMS, DEFAULTS, CTL_ALIAS_X, SECONDS,' and
 * the second `{ "verb", ...'. */

#include "ctl-cmd-alias.h"
#include "ctl-cmd-tool.h"
#include "ctl-ifaces.h"
#include "ctl-tool-args.h"
#include "ctl-transport.h"
#include "ctl.h"

#include <stdio.h>
#include <string.h>

/* ── The table ───────────────────────────────────────────────────── */

/* { tool, positional -> parameter, defaults, output, async seconds,
 *   { the old row: verb, summary, interface, method, argspec, reply } }
 *
 * The verbs are in the order of the tables they came from. */
static const CtlAliasSpec alias_specs[] = {
  { "get_buffer_content", "buffer", NULL, CTL_ALIAS_PRINTED, 0,
    { "get content", "Print a buffer's contents",
      CTL_IFACE_EDIT, "GetContent", "s:buffer", CTL_REPLY_STRING } },
  { "get_buffer_content", "buffer", NULL, CTL_ALIAS_PRINTED, 0,
    { "buffer show", "Print a buffer's contents",
      CTL_IFACE_EDIT, "GetContent", "s:buffer", CTL_REPLY_STRING } },
  { "search_buffer", "buffer regexp", NULL, CTL_ALIAS_PRINTED, 0,
    { "edit search", "Regexp search in a buffer",
      CTL_IFACE_EDIT, "Search", "s:buffer s:regexp", CTL_REPLY_STRING } },
  { "goto_line", "buffer line", NULL, CTL_ALIAS_PRINTED, 0,
    { "edit goto-line", "Move point to a line",
      CTL_IFACE_EDIT, "GotoLine", "s:buffer i:line", CTL_REPLY_STRING } },
  { "backtrace", NULL, NULL, CTL_ALIAS_PRINTED, 0,
    { "debug backtrace", "Lisp backtrace",
      CTL_IFACE_DEBUG, "Backtrace", NULL, CTL_REPLY_STRING } },
  { "memory_info", NULL, NULL, CTL_ALIAS_PRINTED, 0,
    { "debug memory", "GC and memory statistics",
      CTL_IFACE_DEBUG, "MemoryInfo", NULL, CTL_REPLY_STRING } },
  { "list_hooks", NULL, NULL, CTL_ALIAS_PRINTED, 0,
    { "debug hooks", "Non-empty hooks",
      CTL_IFACE_DEBUG, "ListHooks", NULL, CTL_REPLY_STRING } },
  { "describe_mode", NULL, NULL, CTL_ALIAS_PRINTED, 0,
    { "debug mode", "Current major/minor modes",
      CTL_IFACE_DEBUG, "DescribeMode", NULL, CTL_REPLY_STRING } },
  { "describe_function", "symbol", NULL, CTL_ALIAS_PRINTED, 0,
    { "debug function", "Describe a function",
      CTL_IFACE_DEBUG, "DescribeFunction", "s:symbol",
      CTL_REPLY_STRING } },
  { "describe_variable", "symbol", NULL, CTL_ALIAS_PRINTED, 0,
    { "debug variable", "Describe a variable",
      CTL_IFACE_DEBUG, "DescribeVariable", "s:symbol",
      CTL_REPLY_STRING } },
  { "apropos", "pattern", NULL, CTL_ALIAS_PRINTED, 0,
    { "debug apropos", "Apropos symbol search",
      CTL_IFACE_DEBUG, "Apropos", "s:pattern", CTL_REPLY_STRING } },
  { "completions", "prefix", NULL, CTL_ALIAS_PRINTED_LINES, 0,
    { "debug completions", "Symbol completions",
      CTL_IFACE_DEBUG, "Completions", "s:prefix", CTL_REPLY_STRLIST } },
  { "profiler_start", NULL, NULL, CTL_ALIAS_PRINTED, 0,
    { "debug profiler-start", "Start the CPU profiler",
      CTL_IFACE_DEBUG, "ProfilerStart", NULL, CTL_REPLY_STRING } },
  { "profiler_stop", NULL, NULL, CTL_ALIAS_PRINTED, 0,
    { "debug profiler-stop", "Stop the CPU profiler",
      CTL_IFACE_DEBUG, "ProfilerStop", NULL, CTL_REPLY_STRING } },
  { "profiler_report", NULL, NULL, CTL_ALIAS_PRINTED, 0,
    { "debug profiler-report", "CPU profiler report",
      CTL_IFACE_DEBUG, "ProfilerReport", NULL, CTL_REPLY_STRING } },
  { "ai_list_providers", NULL, NULL, CTL_ALIAS_TEXT, 0,
    { "ai providers", "List configured AI providers",
      CTL_IFACE_AI, "ListProviders", NULL, CTL_REPLY_STRING } },
  { "agent_status", "id", NULL, CTL_ALIAS_TEXT, 0,
    { "brigade status", "State, turns, tokens and cost of a task",
      CTL_IFACE_BRIGADE, "Status", "s:id", CTL_REPLY_STRING } },
  { "agent_result", "id", NULL, CTL_ALIAS_TEXT, 0,
    { "brigade result", "What a task produced",
      CTL_IFACE_BRIGADE, "Result", "s:id", CTL_REPLY_STRING } },
  { "agent_list", NULL, NULL, CTL_ALIAS_TEXT, 0,
    { "brigade list", "Every known task with its state",
      CTL_IFACE_BRIGADE, "List", NULL, CTL_REPLY_STRING } },
  { "agent_providers", NULL, NULL, CTL_ALIAS_TEXT, 0,
    { "brigade providers", "AI providers this cmacs can reach",
      CTL_IFACE_BRIGADE, "Providers", NULL, CTL_REPLY_STRING } },
  { "agent_models", "provider", NULL, CTL_ALIAS_TEXT, 0,
    { "brigade models", "Models a provider offers, as provider/model",
      CTL_IFACE_BRIGADE, "Models", "s:provider", CTL_REPLY_STRING } },
  { "agent_inbox", "id", NULL, CTL_ALIAS_TEXT, 0,
    { "brigade inbox", "Messages queued for a task but not yet delivered",
      CTL_IFACE_BRIGADE, "Inbox", "s:id", CTL_REPLY_STRING } },
  { "agent_log", "id from_turn kinds", NULL, CTL_ALIAS_TEXT, 0,
    { "brigade log", "A task's transaction log: messages, replies, tool calls",
      CTL_IFACE_BRIGADE, "Log", "s:id s?:from_turn s?:kinds",
      CTL_REPLY_STRING } },
  { "gsurf_open", "url", NULL, CTL_ALIAS_TEXT, 0,
    { "gsurf open", "Open a URL in a new gsurf buffer",
      CTL_IFACE_GSURF, "Open", "s:url", CTL_REPLY_STRING } },
  { "gsurf_navigate", "url buffer", NULL, CTL_ALIAS_TEXT, 0,
    { "gsurf navigate", "Navigate a gsurf buffer",
      CTL_IFACE_GSURF, "Navigate", "s:url s?:buffer", CTL_REPLY_STRING } },
  { "gsurf_back", "buffer", NULL, CTL_ALIAS_TEXT, 0,
    { "gsurf back", "History back",
      CTL_IFACE_GSURF, "Back", "s?:buffer", CTL_REPLY_STRING } },
  { "gsurf_forward", "buffer", NULL, CTL_ALIAS_TEXT, 0,
    { "gsurf forward", "History forward",
      CTL_IFACE_GSURF, "Forward", "s?:buffer", CTL_REPLY_STRING } },
  { "gsurf_reload", "buffer", NULL, CTL_ALIAS_TEXT, 0,
    { "gsurf reload", "Reload the page",
      CTL_IFACE_GSURF, "Reload", "s?:buffer", CTL_REPLY_STRING } },
  { "gsurf_stop", "buffer", NULL, CTL_ALIAS_TEXT, 0,
    { "gsurf stop", "Stop loading",
      CTL_IFACE_GSURF, "Stop", "s?:buffer", CTL_REPLY_STRING } },
  { "gsurf_get_uri", "buffer", NULL, CTL_ALIAS_TEXT, 0,
    { "gsurf url", "Current page URL",
      CTL_IFACE_GSURF, "GetUri", "s?:buffer", CTL_REPLY_STRING } },
  { "gsurf_get_title", "buffer", NULL, CTL_ALIAS_TEXT, 0,
    { "gsurf title", "Current page title",
      CTL_IFACE_GSURF, "GetTitle", "s?:buffer", CTL_REPLY_STRING } },
  { "gsurf_current", NULL, NULL, CTL_ALIAS_TEXT, 0,
    { "gsurf current", "Most recent gsurf buffer info",
      CTL_IFACE_GSURF, "Current", NULL, CTL_REPLY_STRING } },
  { "gsurf_list", NULL, NULL, CTL_ALIAS_TEXT, 0,
    { "gsurf list", "List gsurf buffers",
      CTL_IFACE_GSURF, "List", NULL, CTL_REPLY_STRING } },
  { "gsurf_modules_list", NULL, NULL, CTL_ALIAS_TEXT, 0,
    { "gsurf modules", "List loaded gsurf modules",
      CTL_IFACE_GSURF, "ModulesList", NULL, CTL_REPLY_STRING } },
  { "gsurf_set_zoom", "level buffer", NULL, CTL_ALIAS_TEXT, 0,
    { "gsurf zoom", "Set the zoom level",
      CTL_IFACE_GSURF, "SetZoom", "d:level s?:buffer",
      CTL_REPLY_STRING } },
  { "gsurf_lite_open", "url", NULL, CTL_ALIAS_TEXT, 0,
    { "gsurf lite", "Render a page into a text buffer (gsurf-lite)",
      CTL_IFACE_GSURF, "LiteOpen", "s:url", CTL_REPLY_STRING } },
  { "gsurf_extract_text", "buffer", NULL, CTL_ALIAS_TEXT, 0,
    { "gsurf text", "Extract the page's text content",
      CTL_IFACE_GSURF, "ExtractText", "s?:buffer", CTL_REPLY_STRING } },
  { "gsurf_download_list", NULL, NULL, CTL_ALIAS_TEXT, 0,
    { "gsurf downloads", "List downloads",
      CTL_IFACE_GSURF, "DownloadList", NULL, CTL_REPLY_STRING } },
  { "gsurf_download_cancel", "id", NULL, CTL_ALIAS_TEXT, 0,
    { "gsurf download-cancel", "Cancel a download by id",
      CTL_IFACE_GSURF, "DownloadCancel", "x:id", CTL_REPLY_STRING } },
  { "gsurf_click", "x y button buffer", NULL, CTL_ALIAS_TEXT, 0,
    { "gsurf click", "Click at X Y (CSS px) in the page "
      "(button 1|2|3, default 1)",
      CTL_IFACE_GSURF, "Click", "d:x d:y i?:button s?:buffer",
      CTL_REPLY_STRING } },
  { "gsurf_click_element", "selector buffer", NULL, CTL_ALIAS_TEXT, 0,
    { "gsurf click-element", "Click the first element matching a CSS "
      "selector (async)",
      CTL_IFACE_GSURF, "ClickElement", "s:selector s?:buffer",
      CTL_REPLY_STRING } },
  { "gsurf_toggle_module", "name enabled", NULL, CTL_ALIAS_TEXT, 0,
    { "gsurf module", "Enable or disable a gsurf module (NAME true|false)",
      CTL_IFACE_GSURF, "ToggleModule", "s:name b:enabled", CTL_REPLY_STRING } },
  { "gsurf_run_action", "action buffer", NULL, CTL_ALIAS_TEXT, 0,
    { "gsurf action", "Run a gsurf action by name "
      "(dark-mode-toggle, form-autofill, reload, ...)",
      CTL_IFACE_GSURF, "RunAction", "s:action s?:buffer", CTL_REPLY_STRING } },
  { "gsurf_list_actions", NULL, NULL, CTL_ALIAS_TEXT, 0,
    { "gsurf actions", "List gsurf actions (JSON)",
      CTL_IFACE_GSURF, "ListActions", NULL, CTL_REPLY_STRING } },
  { "gsurf_list_containers", NULL, NULL, CTL_ALIAS_TEXT, 0,
    { "gsurf containers", "List browsing containers (JSON)",
      CTL_IFACE_GSURF, "ListContainers", NULL, CTL_REPLY_STRING } },
  { "gnuseye_open", NULL, NULL, CTL_ALIAS_TEXT, 0,
    { "gnuseye open", "Open the GNU's Eye globe",
      CTL_IFACE_GNUSEYE, "Open", NULL, CTL_REPLY_STRING } },
  { "gnuseye_brief", NULL, NULL, CTL_ALIAS_TEXT, 0,
    { "gnuseye brief", "Entity index summary",
      CTL_IFACE_GNUSEYE, "Brief", NULL, CTL_REPLY_STRING } },
  { "gnuseye_list_layers", NULL, NULL, CTL_ALIAS_TEXT, 0,
    { "gnuseye layers", "List data layers",
      CTL_IFACE_GNUSEYE, "ListLayers", NULL, CTL_REPLY_STRING } },
  { "gnuseye_toggle_layer", "name", NULL, CTL_ALIAS_TEXT, 0,
    { "gnuseye toggle", "Toggle a data layer",
      CTL_IFACE_GNUSEYE, "ToggleLayer", "s:name", CTL_REPLY_STRING } },
  { "gnuseye_fly_to", "lat lon range", NULL, CTL_ALIAS_TEXT, 0,
    { "gnuseye fly-to", "Fly the camera to lat/lon",
      CTL_IFACE_GNUSEYE, "FlyTo", "d:lat d:lon d?:range",
      CTL_REPLY_STRING } },
  { "gnuseye_refresh", NULL, NULL, CTL_ALIAS_TEXT, 0,
    { "gnuseye refresh", "Refresh all layers",
      CTL_IFACE_GNUSEYE, "Refresh", NULL, CTL_REPLY_STRING } },
  { "gnuseye_query_entities", "kind west east south north limit", NULL, CTL_ALIAS_JSON, 0,
    { "gnuseye query", "Query indexed entities "
      "(kind west east south north limit)",
      CTL_IFACE_GNUSEYE, "QueryEntities",
      "s?:kind d?:west d?:east d?:south d?:north i?:limit",
      CTL_REPLY_JSON } },
  { "gnuseye_add_geofence", "name lat lon radius_km", NULL, CTL_ALIAS_TEXT, 0,
    { "gnuseye geofence", "Add a circular geofence",
      CTL_IFACE_GNUSEYE, "AddGeofence", "s:name d:lat d:lon d:radius_km",
      CTL_REPLY_STRING } },
  { "gnuseye_cii", NULL, NULL, CTL_ALIAS_JSON, 0,
    { "gnuseye cii", "Country instability index (top 15)",
      CTL_IFACE_GNUSEYE, "Cii", NULL, CTL_REPLY_JSON } },
  { "podomation_list_pods", NULL, NULL, CTL_ALIAS_PRINTED, 0,
    { "pod pods", "List active pods",
      CTL_IFACE_PODOMATION, "ListPods", NULL, CTL_REPLY_STRING } },
  { "podomation_list_modules", NULL, NULL, CTL_ALIAS_PRINTED, 0,
    { "pod modules", "List loaded modules",
      CTL_IFACE_PODOMATION, "ListModules", NULL, CTL_REPLY_STRING } },
  { "podomation_stats", NULL, NULL, CTL_ALIAS_PRINTED, 0,
    { "pod stats", "Engine statistics",
      CTL_IFACE_PODOMATION, "Stats", NULL, CTL_REPLY_STRING } },
  { "video_list", NULL, NULL, CTL_ALIAS_PRINTED, 0,
    { "video list", "List live video stream handles",
      CTL_IFACE_VIDEO, "List", NULL, CTL_REPLY_STRING } },
  { "record_audio", "seconds output_path", NULL, CTL_ALIAS_TEXT, 0,
    { "audio record", "Record microphone audio to a WAV file",
      CTL_IFACE_AUDIO, "Record", "d:seconds s?:file",
      CTL_REPLY_STRING } },
  { "transcribe", "audio_path language", NULL, CTL_ALIAS_TEXT, 1200,
    { "speech transcribe", "Transcribe an audio/video file (engine from M-x cmacs-speech)",
      CTL_IFACE_SPEECH, "Transcribe", "s:audio_path s?:language",
      CTL_REPLY_STRING } },
  { "speech_components", NULL, NULL, CTL_ALIAS_TEXT, 0,
    { "speech components", "Engine and model per component, and why",
      CTL_IFACE_SPEECH, "Components", NULL, CTL_REPLY_STRING } },
  { "speech_set", "component backend model", NULL, CTL_ALIAS_TEXT, 0,
    { "speech set", "Choose a component's engine for this session",
      CTL_IFACE_SPEECH, "SetComponent", "s:component s:backend s?:model",
      CTL_REPLY_STRING } },
  { "list_whisper_models", NULL, NULL, CTL_ALIAS_TEXT, 0,
    { "speech whisper-models", "List whisper.cpp model files",
      CTL_IFACE_SPEECH, "ListWhisperModels", NULL, CTL_REPLY_STRING } },
  { "list_voices", NULL, NULL, CTL_ALIAS_TEXT, 0,
    { "speech voices", "List piper voices",
      CTL_IFACE_SPEECH, "ListVoices", NULL, CTL_REPLY_STRING } },
  { "lrgeditor_open", "path", NULL, CTL_ALIAS_TEXT, 0,
    { "lrg open", "Open the libregnum level editor",
      CTL_IFACE_LRG, "Open", "s?:path", CTL_REPLY_STRING } },
  { "lrgeditor_play", NULL, NULL, CTL_ALIAS_TEXT, 0,
    { "lrg play", "Enter play mode",
      CTL_IFACE_LRG, "Play", NULL, CTL_REPLY_STRING } },
  { "lrgeditor_stop", NULL, NULL, CTL_ALIAS_TEXT, 0,
    { "lrg stop", "Stop play mode",
      CTL_IFACE_LRG, "Stop", NULL, CTL_REPLY_STRING } },
  { "lrgeditor_save", "path", "path=level.rlevel", CTL_ALIAS_TEXT, 0,
    { "lrg save", "Save the level",
      CTL_IFACE_LRG, "Save", "s?:path", CTL_REPLY_STRING } },
  { "lrgeditor_object_tree", NULL, NULL, CTL_ALIAS_TEXT, 0,
    { "lrg tree", "Object tree",
      CTL_IFACE_LRG, "ObjectTree", NULL, CTL_REPLY_STRING } },
  { "lrgeditor_select", "id", NULL, CTL_ALIAS_TEXT, 0,
    { "lrg select", "Select a node by id",
      CTL_IFACE_LRG, "Select", "x:id", CTL_REPLY_STRING } },
  { "lrgeditor_move", "id x y z", NULL, CTL_ALIAS_TEXT, 0,
    { "lrg move", "Move a node",
      CTL_IFACE_LRG, "Move", "x:id d:x d:y d:z", CTL_REPLY_STRING } },
  { "lrgeditor_delete", "id", NULL, CTL_ALIAS_TEXT, 0,
    { "lrg delete", "Delete a node",
      CTL_IFACE_LRG, "Delete", "x:id", CTL_REPLY_STRING } },
  { "lrgeditor_add_primitive", "primitive name", NULL, CTL_ALIAS_TEXT, 0,
    { "lrg add-primitive", "Add a primitive node",
      CTL_IFACE_LRG, "AddPrimitive", "x:primitive s?:name",
      CTL_REPLY_STRING } },
  { "lrgeditor_add_visual", "kind asset name", NULL, CTL_ALIAS_TEXT, 0,
    { "lrg add-visual", "Add a visual node",
      CTL_IFACE_LRG, "AddVisual", "x:kind s?:asset s?:name",
      CTL_REPLY_STRING } },
  { "calc_eval", "expression", NULL, CTL_ALIAS_TEXT, 0,
    { "calc eval", "Evaluate an expression numerically",
      CTL_IFACE_CALC, "Eval", "s:expression", CTL_REPLY_STRING } },
  { "calc_eval_symbolic", "expression", NULL, CTL_ALIAS_TEXT, 0,
    { "calc symbolic", "Evaluate symbolically (deriv/integ/solve/taylor)",
      CTL_IFACE_CALC, "EvalSymbolic", "s:expression", CTL_REPLY_STRING } },
  { "calc_convert_units", "expression units", NULL, CTL_ALIAS_TEXT, 0,
    { "calc units", "Convert to UNITS, or reduce to base SI when omitted",
      CTL_IFACE_CALC, "ConvertUnits", "s:expression s?:units",
      CTL_REPLY_STRING } },
  { "calc_list", "category", NULL, CTL_ALIAS_TEXT, 0,
    { "calc list", "List registered calculators (optionally by category)",
      CTL_IFACE_CALC, "ListCalculators", "s?:category", CTL_REPLY_STRING } },
  { "calc_describe", "name", NULL, CTL_ALIAS_TEXT, 0,
    { "calc describe", "Describe one calculator by name",
      CTL_IFACE_CALC, "Describe", "s:name", CTL_REPLY_STRING } },
  { "db_connections", NULL, NULL, CTL_ALIAS_JSON, 0,
    { "db connections", "List saved and live database connections",
      CTL_IFACE_DBEXPLORER, "Connections", NULL, CTL_REPLY_JSON } },
  { "db_connect", "connection", NULL, CTL_ALIAS_TEXT, 60,
    { "db connect", "Connect to a saved database",
      CTL_IFACE_DBEXPLORER, "Connect", "s:connection", CTL_REPLY_STRING } },
  { "db_disconnect", "connection", NULL, CTL_ALIAS_TEXT, 0,
    { "db disconnect", "Close a connection, keeping its saved definition",
      CTL_IFACE_DBEXPLORER, "Disconnect", "s:connection",
      CTL_REPLY_STRING } },
  { "db_query", "connection sql max_rows", NULL, CTL_ALIAS_JSON, 45,
    { "db query", "Run a read-only query (MAX_ROWS caps the rows fetched)",
      CTL_IFACE_DBEXPLORER, "QueryLimited",
      "s:connection s:sql i?:max_rows", CTL_REPLY_JSON } },
  { "db_tables", "connection schema", NULL, CTL_ALIAS_JSON, 45,
    { "db tables", "List tables and views, optionally in one schema",
      CTL_IFACE_DBEXPLORER, "Tables", "s:connection s?:schema",
      CTL_REPLY_JSON } },
  { "db_columns", "connection table schema", NULL, CTL_ALIAS_JSON, 45,
    { "db columns", "Describe one table's columns",
      CTL_IFACE_DBEXPLORER, "Columns", "s:connection s:table s?:schema",
      CTL_REPLY_JSON } },
  { "recent_messages", "lines", "lines=50", CTL_ALIAS_PRINTED, 0,
    { "logs show", "Recent *Messages* lines",
      CTL_IFACE_LOG, "RecentMessages", "i?:lines", CTL_REPLY_STRING } },
  { "gowl_list_clients", NULL, NULL, CTL_ALIAS_JSON, 0,
    { "compositor clients", "List Wayland clients",
      CTL_IFACE_COMPOSITOR, "ListClients", NULL, CTL_REPLY_JSON } },
  { "gowl_focused_client", NULL, NULL, CTL_ALIAS_JSON, 0,
    { "compositor focused", "Focused client info",
      CTL_IFACE_COMPOSITOR, "FocusedClient", NULL, CTL_REPLY_JSON } },
  { "gowl_find_client", "pattern by", NULL, CTL_ALIAS_JSON, 0,
    { "compositor find", "Find a client (by app-id or title)",
      CTL_IFACE_COMPOSITOR, "FindClient", "s:pattern s?:by",
      CTL_REPLY_JSON } },
  { "gowl_workspace_list", NULL, NULL, CTL_ALIAS_PRINTED, 0,
    { "compositor workspaces", "List workspaces",
      CTL_IFACE_COMPOSITOR, "WorkspaceList", NULL, CTL_REPLY_STRING } },
  { "gowl_list_keybinds", NULL, NULL, CTL_ALIAS_JSON, 0,
    { "compositor keybinds", "List keybinds",
      CTL_IFACE_COMPOSITOR, "ListKeybinds", NULL, CTL_REPLY_JSON } },
  { "screensaver_set_wallpaper", "config", NULL, CTL_ALIAS_TEXT, 0,
    { "compositor screensaver", "Set the animated screensaver wallpaper "
      "(config name from cmacs-screensaver-configs; omit for the default)",
      CTL_IFACE_COMPOSITOR, "SetScreensaverWallpaper", "s?:config",
      CTL_REPLY_STRING } },
  { "screensaver_stop_wallpaper", NULL, NULL, CTL_ALIAS_TEXT, 0,
    { "compositor screensaver-stop", "Stop the animated screensaver wallpaper",
      CTL_IFACE_COMPOSITOR, "StopScreensaverWallpaper", NULL,
      CTL_REPLY_STRING } },
  { "screensaver_list_configs", NULL, NULL, CTL_ALIAS_TEXT, 0,
    { "compositor screensaver-configs", "List screensaver config names",
      CTL_IFACE_COMPOSITOR, "ListScreensaverConfigs", NULL,
      CTL_REPLY_STRING } },
  { "screensaver_status", NULL, NULL, CTL_ALIAS_TEXT, 0,
    { "compositor screensaver-status",
      "Show the out-of-process screensaver renderer status (plist)",
      CTL_IFACE_COMPOSITOR, "ScreensaverStatus", NULL,
      CTL_REPLY_STRING } },
  { "screensaver_restart", NULL, NULL, CTL_ALIAS_TEXT, 0,
    { "compositor screensaver-restart",
      "Kill and respawn the screensaver render child",
      CTL_IFACE_COMPOSITOR, "ScreensaverRestart", NULL,
      CTL_REPLY_STRING } },
  { "screensaver_pause", NULL, NULL, CTL_ALIAS_TEXT, 0,
    { "compositor screensaver-pause", "Pause animated wallpaper/lock rendering",
      CTL_IFACE_COMPOSITOR, "ScreensaverPause", NULL,
      CTL_REPLY_STRING } },
  { "screensaver_resume", NULL, NULL, CTL_ALIAS_TEXT, 0,
    { "compositor screensaver-resume", "Resume animated wallpaper/lock rendering",
      CTL_IFACE_COMPOSITOR, "ScreensaverResume", NULL,
      CTL_REPLY_STRING } },
  { "screensaver_set_fps", "fps", NULL, CTL_ALIAS_TEXT, 0,
    { "compositor screensaver-fps", "Set animated wallpaper/lock FPS (1-240)",
      CTL_IFACE_COMPOSITOR, "ScreensaverSetFps", "i:fps",
      CTL_REPLY_STRING } },
  { "gowl_list_monitors", NULL, NULL, CTL_ALIAS_JSON, 0,
    { "monitor list", "List monitors",
      CTL_IFACE_MONITOR, "List", NULL, CTL_REPLY_JSON } },
  { "secondbrain_open", "three_d", NULL, CTL_ALIAS_TEXT, 0,
    { "sb open", "Open the second-brain visualiser (--3d via 'sb open true')",
      CTL_IFACE_SECONDBRAIN, "Open", "b?:three_d", CTL_REPLY_STRING } },
  { "secondbrain_set_layout", "kind", NULL, CTL_ALIAS_TEXT, 0,
    { "sb layout", "Switch the visualiser layout: rings, circle, hex, force",
      CTL_IFACE_SECONDBRAIN, "SetLayout", "s:kind", CTL_REPLY_STRING } },
  { "secondbrain_expand", "id collapse", NULL, CTL_ALIAS_TEXT, 0,
    { "sb expand", "Expand (or COLLAPSE true) a department by id; empty id = all",
      CTL_IFACE_SECONDBRAIN, "Expand", "s?:id b?:collapse", CTL_REPLY_STRING } },
  { "secondbrain_node_info", "id", NULL, CTL_ALIAS_TEXT, 0,
    { "sb node", "The full record for a node id",
      CTL_IFACE_SECONDBRAIN, "NodeInfo", "s:id", CTL_REPLY_STRING } },
  { "secondbrain_stats", NULL, NULL, CTL_ALIAS_TEXT, 0,
    { "sb stats", "Node, visible and edge counts of the open view",
      CTL_IFACE_SECONDBRAIN, "Stats", NULL, CTL_REPLY_STRING } },
  { "secondbrain_sources", NULL, NULL, CTL_ALIAS_TEXT, 0,
    { "sb sources", "The registered ARMS data sources",
      CTL_IFACE_SECONDBRAIN, "Sources", NULL, CTL_REPLY_STRING } },
  { "secondbrain_refresh", NULL, NULL, CTL_ALIAS_TEXT, 0,
    { "sb refresh", "Re-read every source and rebuild the view",
      CTL_IFACE_SECONDBRAIN, "Refresh", NULL, CTL_REPLY_STRING } },
  { "secondbrain_ingest_status", NULL, NULL, CTL_ALIAS_JSON, 0,
    { "sb jobs", "Every ingest job this session, with its state",
      CTL_IFACE_SECONDBRAIN, "IngestList", NULL, CTL_REPLY_JSON } },
  { "secondbrain_ingest_status", "id", NULL, CTL_ALIAS_JSON, 0,
    { "sb status", "Status of one ingest job",
      CTL_IFACE_SECONDBRAIN, "IngestStatus", "s:id", CTL_REPLY_JSON } },
  { "secondbrain_ingest_cancel", "id", NULL, CTL_ALIAS_JSON, 0,
    { "sb cancel", "Cancel an ingest job",
      CTL_IFACE_SECONDBRAIN, "IngestCancel", "s:id", CTL_REPLY_JSON } },
};

/* ── Verbs that stay hand-written, and why ───────────────────────── */

#define KEPT_LOCAL \
  "runs in the client; there is no editor capability behind it"
#define KEPT_INSTANCE \
  "instance discovery and identity (org.cmacs.Editor1.Instance), which " \
  "has to work before any tool can be called"
#define KEPT_STREAM \
  "a stream of D-Bus signals, not a call with one answer"
#define KEPT_EVAL \
  "evaluates code the caller supplies; privileged, and kept off the " \
  "registry on purpose"
#define KEPT_INPUT \
  "types input or runs a command the caller supplies; privileged, and " \
  "kept off the registry on purpose"
#define KEPT_NATIVE \
  "C introspection and hot-patching of the running binary; the " \
  "cmacs.c.* tools stay in C and are not on the cli surface"
#define KEPT_NO_TOOL \
  "no registry tool provides it"
#define KEPT_SURFACE \
  "its tool is destructive and not published on the cli surface, so " \
  "Tools.Call would refuse it"
#define KEPT_FLAGS \
  "flag-driven C: it composes the request in the client (option " \
  "flags, stdin, files) and reshapes the reply per output format"
#define KEPT_IMAGE \
  "writes an image file; its tool returns image content and stays in C"
#define KEPT_MUX \
  "one D-Bus method that multiplexes sub-verbs through a free-text " \
  "argument; the tools are one per sub-verb"
#define KEPT_NAMES \
  "typed (as) reply of bare names; the list_* tool prints a " \
  "multi-column listing the names cannot be cut out of reliably"
#define KEPT_PROJECT \
  "the project_* tool is a different command: it resolves against the " \
  "workspace root, hides redacted files and prints other output"
#define KEPT_GENERIC \
  "the generic path itself"

/* Exact verbs first, then "GROUP *" for whole groups with one reason.
 * ctl_cmd_alias_kept_reason looks for an exact entry before a group
 * one, so an exception inside a group is just another line. */
static const CtlKeptVerb kept_verbs[] = {
  /* ctl-cmd-core.c */
  { "version", KEPT_INSTANCE },
  { "instances", KEPT_INSTANCE },
  { "get instances", KEPT_INSTANCE },
  { "describe instance", KEPT_INSTANCE },
  { "get content-org", KEPT_FLAGS },
  { "eval", KEPT_EVAL },
  { "repl", KEPT_EVAL },
  { "logs", KEPT_STREAM },
  { "watch stream", KEPT_STREAM },
  { "events", KEPT_STREAM },
  { "events watch", KEPT_STREAM },
  { "events recent", KEPT_NO_TOOL },
  { "events types", KEPT_NO_TOOL },
  { "config *", KEPT_LOCAL },
  { "get contexts", KEPT_LOCAL },
  { "completion", KEPT_LOCAL },
  { "__complete", KEPT_LOCAL },
  { "_proxy", "the far end of the ssh tunnel; it relays calls, it is "
    "not one" },
  { "proxy", "the far end of the ssh tunnel; it relays calls, it is "
    "not one" },

  /* ctl-cmd-editor.c */
  { "get buffers", KEPT_NAMES },
  { "get frames", KEPT_NAMES },
  { "get windows", KEPT_NAMES },
  { "get processes", KEPT_NAMES },
  { "get bookmarks", KEPT_NO_TOOL },
  { "get packages", KEPT_NO_TOOL },
  { "get watches", KEPT_NO_TOOL },
  { "buffer list", KEPT_NAMES },
  { "buffer current", KEPT_NO_TOOL },
  { "buffer exists", KEPT_NO_TOOL },
  { "buffer file", KEPT_NO_TOOL },
  { "buffer modified", KEPT_NO_TOOL },
  { "buffer create", KEPT_SURFACE },
  { "buffer save", KEPT_SURFACE },
  { "buffer kill", KEPT_SURFACE },
  { "buffer set", KEPT_SURFACE },
  { "buffer switch", "prints true or false; switch_to_buffer answers "
    "with the buffer's name and signals where the verb printed false" },
  { "edit exact", KEPT_SURFACE },
  { "edit replace", KEPT_SURFACE },
  { "file *", KEPT_NO_TOOL },
  { "nav *", KEPT_NO_TOOL },
  { "search *", KEPT_NO_TOOL },
  { "vc *", KEPT_NO_TOOL },
  { "project root", KEPT_PROJECT },
  { "project grep", KEPT_PROJECT },
  { "project find", KEPT_PROJECT },
  { "project files", KEPT_PROJECT },
  { "project read", KEPT_PROJECT },
  { "project write", KEPT_SURFACE },
  { "project compile", KEPT_NO_TOOL },
  { "clip *", KEPT_NO_TOOL },
  { "bookmark *", KEPT_NO_TOOL },
  { "pkg *", KEPT_NO_TOOL },
  { "var *", KEPT_NO_TOOL },
  { "input *", KEPT_INPUT },
  { "window *", "no tool means the same on the cli surface: "
    "split_window and delete_window are destructive, select_window "
    "takes a direction where the verb takes a buffer" },
  { "process *", "no registry tool provides it (process_status "
    "describes the Emacs process, not a subprocess)" },
  { "c *", KEPT_NATIVE },
  { "watch add", KEPT_NO_TOOL },
  { "watch rm", KEPT_NO_TOOL },
  { "watch list", KEPT_NO_TOOL },
  { "message", KEPT_NO_TOOL },
  { "find-file", KEPT_SURFACE },
  { "text *", KEPT_FLAGS },

  /* ctl-cmd-subsys.c */
  { "crispy *", KEPT_EVAL },
  { "bacon *", KEPT_EVAL },
  { "eshell *", KEPT_EVAL },
  { "ai prompt", KEPT_FLAGS },
  { "ai call", KEPT_FLAGS },
  { "ai models", KEPT_FLAGS },
  { "ai chat", KEPT_FLAGS },
  { "ai generate-image", KEPT_FLAGS },
  { "brigade spawn", KEPT_SURFACE },
  { "brigade cancel", KEPT_SURFACE },
  { "brigade send", KEPT_SURFACE },
  { "brigade drop", KEPT_SURFACE },
  { "brigade close", KEPT_SURFACE },
  { "brigade agents", "no registry tool provides it (agent_list "
    "prints the tasks as well as the definitions)" },
  { "gsurf js", KEPT_SURFACE },
  { "gsurf snapshot", KEPT_SURFACE },
  { "gsurf pdf", KEPT_SURFACE },
  { "gsurf permission", KEPT_SURFACE },
  { "gsurf type", KEPT_SURFACE },
  { "gsurf key", KEPT_SURFACE },
  { "gsurf cookie", KEPT_SURFACE },
  { "pod status", KEPT_SURFACE },
  { "pod emit", KEPT_SURFACE },
  { "pod load", KEPT_SURFACE },
  { "pod reload", KEPT_SURFACE },
  { "pod set-context", KEPT_SURFACE },
  { "pod eval", KEPT_EVAL },
  { "pod repl-eval", KEPT_EVAL },
  { "video snapshot", KEPT_IMAGE },
  { "speech who", "speech_who_spoke and speech_diarize are "
    "asynchronous brigade tools that report failure as text the verb "
    "never printed; not shown to be the same output" },
  { "speech say", "one verb, two tools: speech_say speaks, "
    "synthesize_speech writes FILE, and the verb picks by argument "
    "count" },
  { "speech models", "speech_models prints a fifth column "
    "(description) the verb does not" },
  { "db execute", KEPT_SURFACE },
  { "db export", KEPT_SURFACE },
  { "lql query", "lql_query renders at 160 columns and defaults to "
    "100 rows; the verb renders at 200 with the method's own clamp" },
  { "lql json", KEPT_NO_TOOL },
  { "lql explain", KEPT_NO_TOOL },
  { "lql sources", "lql_sources prints two comma-joined lines; the "
    "verb prints one source per line" },

  /* ctl-cmd-sb.c */
  { "sb search", "the verb highlights the matches in the view and "
    "prints ok; secondbrain_search returns the matches" },
  { "sb doctor", "the JSON differs: the method prints null where "
    "secondbrain_doctor prints false or an empty string" },
  { "sb watch", KEPT_NO_TOOL },
  { "sb ingest", KEPT_FLAGS },
  { "sb tree", KEPT_FLAGS },
  { "sb find", KEPT_FLAGS },
  { "sb migrate", KEPT_FLAGS },

  /* ctl-cmd-gowl.c */
  { "compositor spawn", KEPT_SURFACE },
  { "compositor focus", KEPT_SURFACE },
  { "compositor close", KEPT_SURFACE },
  { "compositor geometry", KEPT_SURFACE },
  { "compositor layout", KEPT_SURFACE },
  { "compositor workspace", KEPT_SURFACE },
  { "compositor reload", KEPT_SURFACE },
  { "compositor macro", KEPT_SURFACE },
  { "compositor screenshot", KEPT_IMAGE },
  { "compositor broadcast", KEPT_MUX },
  { "compositor floatdesk", KEPT_MUX },
  { "compositor hotkey", KEPT_MUX },
  { "compositor *", KEPT_NO_TOOL },
  { "monitor transform", KEPT_SURFACE },
  { "monitor *", KEPT_NO_TOOL },

  /* ctl-cmd-tool.c */
  { "tool", KEPT_GENERIC },
  { "tool *", KEPT_GENERIC }
};

const CtlAliasSpec *
ctl_cmd_alias_specs (guint *n_out)
{
  if (n_out != NULL)
    *n_out = G_N_ELEMENTS (alias_specs);
  return alias_specs;
}

const CtlAliasSpec *
ctl_cmd_alias_find (const gchar *verb)
{
  guint k;

  for (k = 0; k < G_N_ELEMENTS (alias_specs); k++)
    if (g_strcmp0 (alias_specs[k].legacy.name, verb) == 0)
      return &alias_specs[k];
  return NULL;
}

const CtlKeptVerb *
ctl_cmd_alias_kept (guint *n_out)
{
  if (n_out != NULL)
    *n_out = G_N_ELEMENTS (kept_verbs);
  return kept_verbs;
}

const gchar *
ctl_cmd_alias_kept_reason (const gchar *verb)
{
  const gchar *space;
  guint k;

  if (verb == NULL)
    return NULL;
  for (k = 0; k < G_N_ELEMENTS (kept_verbs); k++)
    if (strcmp (kept_verbs[k].pattern, verb) == 0)
      return kept_verbs[k].reason;

  /* "GROUP *" covers every verb of GROUP that has no line of its own.
   * A bare command ("eval") has no group and needs its own line. */
  space = strchr (verb, ' ');
  if (space == NULL)
    return NULL;
  for (k = 0; k < G_N_ELEMENTS (kept_verbs); k++)
    {
      const gchar *pattern = kept_verbs[k].pattern;
      gsize len = strlen (pattern);

      if (len >= 2 && pattern[len - 1] == '*' && pattern[len - 2] == ' '
          && len - 2 == (gsize) (space - verb)
          && strncmp (pattern, verb, len - 2) == 0)
        return kept_verbs[k].reason;
    }
  return NULL;
}

/* ── The command ─────────────────────────────────────────────────── */

struct _CtlAliasCommand
{
  CtlCommand parent_instance;
  const CtlAliasSpec *spec;
};

G_DEFINE_FINAL_TYPE (CtlAliasCommand, ctl_alias_command, CTL_TYPE_COMMAND)

const CtlAliasSpec *
ctl_alias_command_get_spec (CtlAliasCommand *self)
{
  return self->spec;
}

/* Run the alias: one Tools.Call, or the old method when the tool
 * cannot be reached.
 *
 * Exit codes are the old verb's where the outcome is the same -- 0, 2
 * for a missing argument, 4 for no instance -- and 1 when the tool
 * fails.  That last one is the registry's rule (a failure is a
 * failure), and differs from the handful of old methods that printed
 * "error: ..." and exited 0. */
static gint
alias_run (CtlCommand *self, CtlInvocation *inv, GError **error)
{
  const CtlAliasSpec *spec = CTL_ALIAS_COMMAND (self)->spec;
  gint argc = 0;
  gchar **argv = ctl_invocation_get_args (inv, &argc);
  CtlTransport *transport;
  GVariant *reply;
  GError *local = NULL;
  CtlResult *result;
  const gchar *text;
  gchar *args;
  gboolean ok;

  args = ctl_alias_build_args (spec, argv, argc, error);
  if (args == NULL)
    return ctl_exit_code_for_error (error != NULL ? *error : NULL);

  transport = ctl_invocation_get_transport (inv, error);
  if (transport == NULL)
    {
      g_free (args);
      return CTL_EXIT_NO_INSTANCE;
    }

  /* (The interface constant and the method name are on two lines
   * because admin/cmacs-capability-audit.sh reads the two side by side
   * as a row of a verb table.) */
  reply = ctl_transport_call (
    transport, CTL_IFACE_TOOLS,
    "Call", g_variant_new ("(ss)", spec->tool, args),
    ctl_alias_timeout_ms (spec, ctl_invocation_get_timeout_ms (inv)),
    &local);
  g_free (args);

  if (reply == NULL)
    {
      if (ctl_alias_decide (local) == CTL_ALIAS_FALLBACK)
        {
          /* Refused before the tool ran.  The verb is still a D-Bus
           * method on this cmacs, or it is not and the method call
           * says so the way it always did (exit 3). */
          g_clear_error (&local);
          return ctl_method_spec_run (&spec->legacy, inv, error);
        }
      g_propagate_error (error, local);
      return ctl_exit_code_for_error (error != NULL ? *error : NULL);
    }

  if (!g_variant_is_of_type (reply, G_VARIANT_TYPE ("(s)")))
    {
      g_variant_unref (reply);
      g_set_error (error, CTL_ERROR, CTL_ERROR_FAILED,
                   "the editor answered %s with something that is not "
                   "text", spec->tool);
      return CTL_EXIT_ERROR;
    }
  g_variant_get (reply, "(&s)", &text);
  result = ctl_alias_format_result (spec->format, text);
  ok = ctl_invocation_emit (inv, result, error);
  ctl_result_unref (result);
  g_variant_unref (reply);
  return ok ? CTL_EXIT_OK : CTL_EXIT_ERROR;
}

static void
ctl_alias_command_class_init (CtlAliasCommandClass *klass)
{
  /* No option entries, as a method command has none: the words after
   * the verb are positionals, dashes and all. */
  CTL_COMMAND_CLASS (klass)->run = alias_run;
}

static void
ctl_alias_command_init (CtlAliasCommand *self)
{
  (void) self;
}

CtlCommand *
ctl_cmd_alias_new (const gchar *verb)
{
  const CtlAliasSpec *spec = ctl_cmd_alias_find (verb);
  CtlAliasCommand *self;
  gchar *usage;

  if (spec == NULL)
    g_error ("emacsctl: '%s' is marked CTL_ALIAS_ROW but has no row in "
             "ctl-cmd-alias.c", verb);

  usage = ctl_method_spec_usage (spec->legacy.argspec);
  self = g_object_new (CTL_TYPE_ALIAS_COMMAND,
                       "name", spec->legacy.name,
                       "summary", spec->legacy.summary,
                       "usage", usage,
                       NULL);
  g_free (usage);
  self->spec = spec;
  return CTL_COMMAND (self);
}

CtlCommand *
ctl_cmd_alias_command_for_row (const CtlMethodSpec *spec)
{
  return spec->iface != NULL
    ? ctl_method_command_new (spec)
    : ctl_cmd_alias_new (spec->name);
}

/* ── Help from the live table ────────────────────────────────────── */

gint
ctl_cmd_alias_help (CtlInvocation *inv, CtlCommandRegistry *registry,
                    const gchar *prog, gchar **words, gint n_words)
{
  JsonParser *parser = NULL;
  JsonArray *tools = NULL;
  CtlCommand *cmd;
  const gchar *group;
  gint consumed = 0;
  guint n, k;
  gsize group_len;
  gboolean any = FALSE;

  if (n_words < 1)
    return -1;

  cmd = ctl_command_registry_lookup (registry, words, n_words, &consumed);
  if (cmd != NULL && CTL_IS_ALIAS_COMMAND (cmd))
    {
      const CtlAliasSpec *spec = CTL_ALIAS_COMMAND (cmd)->spec;
      gchar *help;

      /* One List: help is the place the round trip is worth it, and a
       * table that cannot be had is not an error here -- the page says
       * which text it is showing. */
      tools = ctl_cmd_tool_table (inv, &parser, NULL);
      help = ctl_alias_help_string (
        spec, tools != NULL ? ctl_tool_find_by_name (tools, spec->tool)
                            : NULL,
        prog);
      fputs (help, stdout);
      g_free (help);
      g_clear_object (&parser);
      return CTL_EXIT_OK;
    }
  if (cmd != NULL)
    return -1;

  /* A group.  Only ask the editor when the group has an alias in it:
   * `emacsctl config --help' should not open a bus connection. */
  group = ctl_command_registry_canonical (registry, words[0]);
  group_len = strlen (group);
  n = ctl_command_registry_get_n_commands (registry);
  for (k = 0; k < n && !any; k++)
    {
      CtlCommand *each = ctl_command_registry_get_nth (registry, k);
      const gchar *name = ctl_command_get_name (each);

      any = CTL_IS_ALIAS_COMMAND (each)
        && strncmp (name, group, group_len) == 0
        && name[group_len] == ' ';
    }
  if (!any)
    return -1;

  tools = ctl_cmd_tool_table (inv, &parser, NULL);
  for (k = 0; k < n; k++)
    {
      CtlCommand *each = ctl_command_registry_get_nth (registry, k);
      const gchar *name = ctl_command_get_name (each);
      const CtlAliasSpec *spec;
      gchar *summary;

      if (!CTL_IS_ALIAS_COMMAND (each)
          || strncmp (name, group, group_len) != 0
          || name[group_len] != ' ')
        continue;
      spec = CTL_ALIAS_COMMAND (each)->spec;
      summary = ctl_alias_summary (
        spec, tools != NULL ? ctl_tool_find_by_name (tools, spec->tool)
                            : NULL);
      ctl_command_set_summary (each, summary);
      g_free (summary);
    }
  g_clear_object (&parser);
  return -1;
}
