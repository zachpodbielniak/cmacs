/*
 * Copyright (C) 2026 Zach Podbielniak
 * SPDX-License-Identifier: AGPL-3.0-or-later
 */

/* cmacs-dbus-forward-table.h --- which legacy D-Bus methods are served
 * from the capability table, and how.
 *
 * Included exactly once, by cmacs-dbus-forward.c, inside the
 * initializer of its row array.  It is also read as TEXT by
 * test/cmacs/cmacs-dbus-forward-tests.el and by
 * admin/cmacs-capability-audit.sh, so the format is part of the
 * contract:
 *
 *   one row per line, nothing else on the line, and every field a
 *   plain string literal:
 *
 *   FWD ("Interface", "Method", "target", "argument map", "reply", FLAGS)
 *
 * Interface   the part after "org.cmacs.Editor1." ("" is the root
 *             interface itself).
 * Method      the D-Bus method.  Its name, its signature and the
 *             interface it is on are NOT here: they stay in the
 *             introspection XML of the cmacs-dbus-iface-*.c that
 *             registers it, unchanged.
 * target      a registry tool's wire name, or "@NAME" for the Lisp
 *             function cmacs-dbus-method-NAME (methods with no tool,
 *             in lisp/cmacs/cmacs-dbus-forward.el).
 * argument map
 *             comma-separated, one item per D-Bus input argument, in
 *             the method's order:
 *
 *               name          pass the argument as member NAME
 *               name?         ...but leave it out when it is "not
 *                             given": an empty string, array or dict,
 *                             or a number <= 0.  D-Bus has no optional
 *                             arguments, and these methods have always
 *                             spelt "use the default" that way.
 *               name?:VALUE   ...and send VALUE instead of leaving it
 *                             out (the method's own historical
 *                             default, where the tool has none).
 *               -             ignore the argument
 *               name=VALUE    a constant member; consumes no argument
 *
 *             Types carried: s, b, the integers, d, as (a JSON array
 *             of strings) and a{ss} (a JSON object of strings).  A
 *             method with any other input type cannot be a row.
 * reply       how the result becomes the method's declared reply; see
 *             `cmacs-dbus-forward--adapt':  text, raw, prin1, lines, ok.
 * FLAGS       0, LEGACY, APPROVE or LEGACY | APPROVE.
 *
 *   LEGACY    the legacy-reach grant.  The tool is :destructive and so
 *             is not on the `dbus' surface; this one named method has
 *             always performed the action and keeps doing so.  The
 *             grant is to the method, not to Tools.Call.  A row may
 *             carry it only if its tool really is off `dbus' -- the
 *             test suite checks -- so `grep LEGACY' on this file is
 *             the complete list of what a D-Bus caller can do beyond
 *             the registry's defaults.
 *   APPROVE   org.cmacs.Editor1.Brigade's historical behaviour: the
 *             confirmation policy is answered "yes" for the call.
 *
 * A method that is not here keeps its hand-written body in its
 * cmacs-dbus-iface-*.c.  doc_org/cmacs/cmacs-capability.org ("D-Bus:
 * the legacy interfaces") says which those are and why.  */

/* ── org.cmacs.Editor1.Compositor ─────────────────────────────────── */
FWD ("Compositor", "ListClients", "gowl_list_clients", "", "text", 0)
FWD ("Compositor", "FocusedClient", "gowl_focused_client", "", "text", 0)
FWD ("Compositor", "FindClient", "gowl_find_client", "pattern,by?", "text", 0)
FWD ("Compositor", "ListKeybinds", "gowl_list_keybinds", "", "text", 0)
FWD ("Compositor", "WorkspaceList", "gowl_workspace_list", "", "raw", 0)
FWD ("Compositor", "Spawn", "gowl_spawn", "command", "text", LEGACY)
FWD ("Compositor", "FocusClient", "gowl_focus_client", "pattern,by?", "raw", LEGACY)
FWD ("Compositor", "CloseClient", "gowl_close_client", "pattern,by?", "raw", LEGACY)
FWD ("Compositor", "SetClientGeometry", "gowl_set_client_geometry", "pattern,by?,x,y,width,height", "raw", LEGACY)
FWD ("Compositor", "SetLayout", "gowl_set_layout", "layout", "raw", LEGACY)
FWD ("Compositor", "WorkspaceSwitch", "gowl_workspace_switch", "id", "raw", LEGACY)
FWD ("Compositor", "SetScreensaverWallpaper", "screensaver_set_wallpaper", "config?", "text", 0)
FWD ("Compositor", "StopScreensaverWallpaper", "screensaver_stop_wallpaper", "", "text", 0)
FWD ("Compositor", "ListScreensaverConfigs", "screensaver_list_configs", "", "text", 0)
FWD ("Compositor", "ScreensaverStatus", "screensaver_status", "", "text", 0)
FWD ("Compositor", "ScreensaverRestart", "screensaver_restart", "", "text", 0)
FWD ("Compositor", "ScreensaverPause", "screensaver_pause", "", "text", 0)
FWD ("Compositor", "ScreensaverResume", "screensaver_resume", "", "text", 0)
FWD ("Compositor", "ScreensaverSetFps", "screensaver_set_fps", "fps", "text", 0)
FWD ("Compositor", "Screenshot", "@compositor-screenshot", "mode,client,by,file", "text", 0)

/* ── org.cmacs.Editor1.Monitor ────────────────────────────────────── */
FWD ("Monitor", "List", "gowl_list_monitors", "", "text", 0)
FWD ("Monitor", "SetTransform", "gowl_set_monitor_transform", "name,transform", "text", LEGACY)

/* ── org.cmacs.Editor1.BufferManager ──────────────────────────────── */
FWD ("BufferManager", "List", "@buffer-list", "", "text", 0)
FWD ("BufferManager", "Find", "@buffer-find", "name", "text", 0)
FWD ("BufferManager", "Current", "@buffer-current", "", "text", 0)
FWD ("BufferManager", "FilenameFor", "@buffer-filename", "name", "text", 0)
FWD ("BufferManager", "PointFor", "@buffer-point", "name", "text", 0)
FWD ("BufferManager", "ModifiedP", "@buffer-modified-p", "name", "text", 0)
FWD ("BufferManager", "SaveCurrent", "@buffer-save-current", "", "text", 0)
FWD ("BufferManager", "Switch", "@buffer-switch", "name", "text", 0)
FWD ("BufferManager", "Kill", "kill_buffer", "buffer", "ok", LEGACY)
FWD ("BufferManager", "Create", "create_buffer", "name", "ok", LEGACY)
FWD ("BufferManager", "Save", "save_buffer", "buffer", "ok", LEGACY)

/* ── org.cmacs.Editor1.FrameManager ───────────────────────────────── */
FWD ("FrameManager", "List", "@frame-list", "", "text", 0)
FWD ("FrameManager", "Selected", "@frame-selected", "", "text", 0)
FWD ("FrameManager", "Count", "@frame-count", "", "text", 0)
FWD ("FrameManager", "RaiseAll", "@frame-raise-all", "", "text", 0)

/* ── org.cmacs.Editor1.WindowManager ──────────────────────────────── */
FWD ("WindowManager", "List", "@window-list", "", "text", 0)
FWD ("WindowManager", "Selected", "@window-selected", "", "text", 0)
FWD ("WindowManager", "Count", "@window-count", "", "text", 0)
FWD ("WindowManager", "SelectByBuffer", "@window-select-by-buffer", "buffer", "text", 0)
FWD ("WindowManager", "Other", "select_window", "", "raw", 0)
FWD ("WindowManager", "SplitBelow", "split_window", "direction=vertical", "ok", LEGACY)
FWD ("WindowManager", "SplitRight", "split_window", "direction=horizontal", "ok", LEGACY)
FWD ("WindowManager", "Delete", "delete_window", "", "ok", LEGACY)

/* ── org.cmacs.Editor1.Edit ───────────────────────────────────────── */
FWD ("Edit", "GetContent", "get_buffer_content", "buffer", "raw", 0)
FWD ("Edit", "Search", "search_buffer", "buffer,regexp", "raw", 0)
FWD ("Edit", "GotoLine", "goto_line", "buffer,line", "raw", 0)
FWD ("Edit", "GetOrgContent", "get_org_content", "buffer,match?,max_depth?,include_body,include_properties", "text", 0)
FWD ("Edit", "EditExact", "edit_buffer", "buffer,old_string,new_string,replace_all", "raw", LEGACY)
FWD ("Edit", "Replace", "replace_in_buffer", "buffer,regexp,replacement", "raw", LEGACY)

/* ── org.cmacs.Editor1.Debug, .Log ────────────────────────────────── */
FWD ("Debug", "Backtrace", "backtrace", "", "raw", 0)
FWD ("Debug", "MemoryInfo", "memory_info", "", "raw", 0)
FWD ("Debug", "ListHooks", "list_hooks", "", "raw", 0)
FWD ("Debug", "DescribeMode", "describe_mode", "", "raw", 0)
FWD ("Debug", "DescribeFunction", "describe_function", "symbol", "raw", 0)
FWD ("Debug", "DescribeVariable", "describe_variable", "symbol", "raw", 0)
FWD ("Debug", "Apropos", "apropos", "pattern", "raw", 0)
FWD ("Debug", "Completions", "completions", "prefix", "lines", 0)
FWD ("Debug", "ProfilerStart", "profiler_start", "", "raw", 0)
FWD ("Debug", "ProfilerStop", "profiler_stop", "", "raw", 0)
FWD ("Debug", "ProfilerReport", "profiler_report", "", "raw", 0)
FWD ("Log", "RecentMessages", "recent_messages", "lines?", "raw", 0)

/* ── org.cmacs.Editor1.Project, .Search, .Text, .File ─────────────── */
FWD ("Project", "Grep", "project_grep", "regexp,directory?", "text", 0)
FWD ("Project", "Root", "project_root", "", "prin1", 0)
FWD ("Project", "ListFiles", "@project-list-files", "", "text", 0)
FWD ("Project", "ReadFile", "@project-read-file", "path", "text", 0)
FWD ("Project", "Find", "@project-find", "filename,dir", "prin1", 0)
FWD ("Search", "Occur", "@search-occur", "pattern", "prin1", 0)
FWD ("Text", "Line", "@text-line", "n,buffer", "text", 0)
FWD ("Text", "Delete", "@text-delete", "start,end,buffer", "text", 0)
FWD ("File", "Recent", "@file-recent", "n", "prin1", 0)

/* ── org.cmacs.Editor1.Clipboard, .Bookmark, .Config, .Package ────── */
FWD ("Clipboard", "List", "@clipboard-list", "", "prin1", 0)
FWD ("Clipboard", "Get", "@clipboard-get", "", "prin1", 0)
FWD ("Clipboard", "GetSelection", "@clipboard-get-selection", "selection", "prin1", 0)
FWD ("Bookmark", "List", "@bookmark-list", "", "prin1", 0)
FWD ("Config", "Get", "@config-get", "var", "prin1", 0)
FWD ("Package", "List", "@package-list", "", "prin1", 0)

/* ── org.cmacs.Editor1.Calc ───────────────────────────────────────── */
FWD ("Calc", "Eval", "calc_eval", "expression", "text", 0)
FWD ("Calc", "EvalSymbolic", "calc_eval_symbolic", "expression", "text", 0)
FWD ("Calc", "ConvertUnits", "calc_convert_units", "expression,units?", "text", 0)
FWD ("Calc", "ListCalculators", "calc_list", "category?", "text", 0)
FWD ("Calc", "Describe", "calc_describe", "name", "text", 0)

/* ── org.cmacs.Editor1.Gsurf ──────────────────────────────────────── */
FWD ("Gsurf", "Open", "gsurf_open", "url", "text", 0)
FWD ("Gsurf", "Navigate", "gsurf_navigate", "url,buffer?", "text", 0)
FWD ("Gsurf", "Back", "gsurf_back", "buffer?", "text", 0)
FWD ("Gsurf", "Forward", "gsurf_forward", "buffer?", "text", 0)
FWD ("Gsurf", "Reload", "gsurf_reload", "buffer?", "text", 0)
FWD ("Gsurf", "Stop", "gsurf_stop", "buffer?", "text", 0)
FWD ("Gsurf", "GetUri", "gsurf_get_uri", "buffer?", "text", 0)
FWD ("Gsurf", "GetTitle", "gsurf_get_title", "buffer?", "text", 0)
FWD ("Gsurf", "Current", "gsurf_current", "", "text", 0)
FWD ("Gsurf", "List", "gsurf_list", "", "text", 0)
FWD ("Gsurf", "ModulesList", "gsurf_modules_list", "", "text", 0)
FWD ("Gsurf", "SetZoom", "gsurf_set_zoom", "level,buffer?", "text", 0)
FWD ("Gsurf", "LiteOpen", "gsurf_lite_open", "url", "text", 0)
FWD ("Gsurf", "ExtractText", "gsurf_extract_text", "buffer?", "text", 0)
FWD ("Gsurf", "DownloadList", "gsurf_download_list", "", "text", 0)
FWD ("Gsurf", "DownloadCancel", "gsurf_download_cancel", "id", "text", 0)
FWD ("Gsurf", "Click", "gsurf_click", "x,y,button,buffer?", "text", 0)
FWD ("Gsurf", "ClickElement", "gsurf_click_element", "selector,buffer?", "text", 0)
FWD ("Gsurf", "ToggleModule", "gsurf_toggle_module", "name,enabled", "text", 0)
FWD ("Gsurf", "RunAction", "gsurf_run_action", "action,buffer?", "text", 0)
FWD ("Gsurf", "ListActions", "gsurf_list_actions", "", "text", 0)
FWD ("Gsurf", "ListContainers", "gsurf_list_containers", "", "text", 0)
FWD ("Gsurf", "EvalJs", "gsurf_eval_js", "script,buffer?", "text", LEGACY)
FWD ("Gsurf", "Snapshot", "gsurf_snapshot", "file,full_page,buffer?", "text", LEGACY)
FWD ("Gsurf", "PrintPdf", "gsurf_print_pdf", "file,buffer?", "text", LEGACY)
FWD ("Gsurf", "PermissionPolicy", "gsurf_permission_policy", "origin,type,verdict", "text", LEGACY)
FWD ("Gsurf", "TypeText", "gsurf_type_text", "text,buffer?", "text", LEGACY)
FWD ("Gsurf", "PressKey", "gsurf_press_key", "key,modifiers?,buffer?", "text", LEGACY)
FWD ("Gsurf", "SetCookie", "gsurf_set_cookie", "name,value,domain,path?,secure,http_only,expires,buffer?", "text", LEGACY)

/* ── org.cmacs.Editor1.GnusEye ────────────────────────────────────── */
FWD ("GnusEye", "Open", "gnuseye_open", "", "text", 0)
FWD ("GnusEye", "ListLayers", "gnuseye_list_layers", "", "text", 0)
FWD ("GnusEye", "ToggleLayer", "gnuseye_toggle_layer", "name", "text", 0)
FWD ("GnusEye", "FlyTo", "gnuseye_fly_to", "lat,lon,range?", "text", 0)
FWD ("GnusEye", "Refresh", "gnuseye_refresh", "", "text", 0)
FWD ("GnusEye", "QueryEntities", "gnuseye_query_entities", "kind?,west,east,south,north,limit?", "text", 0)
FWD ("GnusEye", "Brief", "gnuseye_brief", "", "text", 0)
FWD ("GnusEye", "AddGeofence", "gnuseye_add_geofence", "name?:fence,lat,lon,radius_km?:100", "text", 0)
FWD ("GnusEye", "Cii", "gnuseye_cii", "", "text", 0)

/* ── org.cmacs.Editor1.Lrg ────────────────────────────────────────── */
FWD ("Lrg", "Open", "lrgeditor_open", "path?", "text", 0)
FWD ("Lrg", "Play", "lrgeditor_play", "", "text", 0)
FWD ("Lrg", "Stop", "lrgeditor_stop", "", "text", 0)
FWD ("Lrg", "Save", "lrgeditor_save", "path?:level.rlevel", "text", 0)
FWD ("Lrg", "Select", "lrgeditor_select", "id", "text", 0)
FWD ("Lrg", "Move", "lrgeditor_move", "id,x,y,z", "text", 0)
FWD ("Lrg", "Delete", "lrgeditor_delete", "id", "text", 0)
FWD ("Lrg", "AddPrimitive", "lrgeditor_add_primitive", "primitive,name?", "text", 0)
FWD ("Lrg", "AddVisual", "lrgeditor_add_visual", "kind,asset?,name?", "text", 0)
FWD ("Lrg", "ObjectTree", "lrgeditor_object_tree", "", "text", 0)
FWD ("Lrg", "Action", "lrgeditor_action", "id", "text", 0)
FWD ("Lrg", "Actions", "lrgeditor_actions", "", "text", 0)
FWD ("Lrg", "Socket", "lrgeditor_socket", "", "text", 0)

/* ── org.cmacs.Editor1.Podomation ─────────────────────────────────── */
FWD ("Podomation", "ListPods", "podomation_list_pods", "", "raw", 0)
FWD ("Podomation", "ListModules", "podomation_list_modules", "", "raw", 0)
FWD ("Podomation", "Stats", "podomation_stats", "", "raw", 0)
FWD ("Podomation", "Control", "podomation_control", "action", "raw", LEGACY)
FWD ("Podomation", "RunPod", "podomation_control", "action=run,pod,event?", "raw", LEGACY)
FWD ("Podomation", "EmitEvent", "podomation_emit_event", "event,data?", "raw", LEGACY)
FWD ("Podomation", "LoadFile", "podomation_load_file", "file", "raw", LEGACY)
FWD ("Podomation", "Reload", "podomation_reload", "", "raw", LEGACY)
FWD ("Podomation", "SetContext", "podomation_set_context", "context", "raw", LEGACY)

/* ── org.cmacs.Editor1.Ai ─────────────────────────────────────────── */
FWD ("Ai", "ListProviders", "ai_list_providers", "", "text", 0)
FWD ("Ai", "ListModels", "ai_list_models", "provider?", "text", 0)
FWD ("Ai", "Prompt", "ai_prompt", "prompt,provider?,system?,model?", "text", 0)
FWD ("Ai", "Call", "ai_call", "prompt,provider?,system?,model?,tools", "text", 0)
FWD ("Ai", "GenerateImage", "generate_image", "prompt,provider?,model?,aspect?,references?,buffer?", "text", 0)
FWD ("Ai", "OpenChat", "ai_open_chat", "provider?,prompt?,model?", "text", 0)
FWD ("Ai", "Research", "ai_research", "question,deep,pages?", "text", 0)
FWD ("Ai", "WebFetch", "ai_web_fetch", "url,archive?,max_chars?", "text", 0)
FWD ("Ai", "Lql", "ai_lql", "query,explain", "text", 0)

/* ── org.cmacs.Editor1.Brigade ────────────────────────────────────── */
FWD ("Brigade", "List", "agent_list", "", "text", 0)
FWD ("Brigade", "Providers", "agent_providers", "", "text", 0)
FWD ("Brigade", "Models", "agent_models", "provider", "text", 0)
FWD ("Brigade", "Status", "agent_status", "id", "text", 0)
FWD ("Brigade", "Result", "agent_result", "id", "text", 0)
FWD ("Brigade", "Inbox", "agent_inbox", "id", "text", 0)
FWD ("Brigade", "Log", "agent_log", "id,from_turn?,kinds?", "text", 0)
FWD ("Brigade", "Spawn", "agent_spawn", "task,agent?,title?,model?", "text", LEGACY | APPROVE)
FWD ("Brigade", "Send", "agent_send", "id,message", "text", LEGACY | APPROVE)
FWD ("Brigade", "Cancel", "agent_cancel", "id", "text", LEGACY)
FWD ("Brigade", "Close", "agent_close", "id", "text", LEGACY)
FWD ("Brigade", "Drop", "agent_drop", "id,index?", "text", LEGACY)

/* ── org.cmacs.Editor1.DbExplorer ─────────────────────────────────── */
FWD ("DbExplorer", "Connections", "db_connections", "", "text", 0)
FWD ("DbExplorer", "Connect", "db_connect", "connection", "text", 0)
FWD ("DbExplorer", "Disconnect", "db_disconnect", "connection", "text", 0)
FWD ("DbExplorer", "Query", "db_query", "connection,sql", "text", 0)
FWD ("DbExplorer", "QueryLimited", "db_query", "connection,sql,max_rows?", "text", 0)
FWD ("DbExplorer", "Tables", "db_tables", "connection,schema?", "text", 0)
FWD ("DbExplorer", "Columns", "db_columns", "connection,table,schema?", "text", 0)
FWD ("DbExplorer", "Execute", "db_execute", "connection,sql", "text", LEGACY)
FWD ("DbExplorer", "Export", "db_export", "connection,sql,format,path", "text", LEGACY)

/* ── org.cmacs.Editor1.SecondBrain ────────────────────────────────── */
FWD ("SecondBrain", "Open", "secondbrain_open", "three_d", "text", 0)
FWD ("SecondBrain", "SetLayout", "secondbrain_set_layout", "kind", "text", 0)
FWD ("SecondBrain", "Search", "secondbrain_search", "query,semantic", "text", 0)
FWD ("SecondBrain", "Expand", "secondbrain_expand", "id?,collapse", "text", 0)
FWD ("SecondBrain", "NodeInfo", "secondbrain_node_info", "id", "text", 0)
FWD ("SecondBrain", "Stats", "secondbrain_stats", "", "text", 0)
FWD ("SecondBrain", "Sources", "secondbrain_sources", "", "text", 0)
FWD ("SecondBrain", "Refresh", "secondbrain_refresh", "", "text", 0)
FWD ("SecondBrain", "IngestStatus", "secondbrain_ingest_status", "id?", "text", 0)
FWD ("SecondBrain", "IngestList", "secondbrain_ingest_status", "", "text", 0)
FWD ("SecondBrain", "IngestCancel", "secondbrain_ingest_cancel", "id", "text", 0)
FWD ("SecondBrain", "Tree", "secondbrain_tree", "para?,category?,files", "text", 0)
FWD ("SecondBrain", "Find", "secondbrain_find", "query,limit?", "text", 0)
FWD ("SecondBrain", "Doctor", "secondbrain_doctor", "", "text", 0)

/* ── org.cmacs.Editor1.Video ──────────────────────────────────────── */
FWD ("Video", "List", "video_list", "", "raw", 0)
