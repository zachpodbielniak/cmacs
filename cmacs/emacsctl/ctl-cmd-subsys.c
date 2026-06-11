/*
 * Copyright (C) 2026 Zach Podbielniak
 * SPDX-License-Identifier: AGPL-3.0-or-later
 */

/* ctl-cmd-subsys.c --- cmacs subsystem command groups (the Phase 6
 * MCP-parity interfaces): crispy, bacon, eshell, ai, gsurf, gnuseye,
 * podomation, video, audio, speech, libregnum.
 *
 * If the target cmacs was built without a subsystem its interface is
 * absent and the call maps to exit code 3 with a clear message ---
 * the CLI does not need to know the server's configure flags. */

#include "ctl-command-registry.h"
#include "ctl-ifaces.h"

void ctl_cmd_subsys_register (CtlCommandRegistry *registry);

static const CtlMethodSpec subsys_specs[] = {
  /* crispy */
  { "crispy eval", "Run inline crispy C, printing captured stdout",
    CTL_IFACE_CRISPY, "EvalString", "s:code", CTL_REPLY_STRING },
  { "crispy run", "Run inline crispy C, printing the exit code",
    CTL_IFACE_CRISPY, "Eval", "s:code", CTL_REPLY_INT },

  /* bacon */
  { "bacon eval", "Run a bacon shell command line",
    CTL_IFACE_BACON, "Eval", "s:command", CTL_REPLY_EXIT_OUTPUT },
  { "bacon eval-c", "Run a C block through bacon/crispy",
    CTL_IFACE_BACON, "EvalC", "s:code", CTL_REPLY_EXIT_OUTPUT },
  { "bacon complete", "Bacon shell completion candidates",
    CTL_IFACE_BACON, "Complete", "s:prefix", CTL_REPLY_STRLIST },

  /* eshell */
  { "eshell eval", "Run an eshell command line",
    CTL_IFACE_ESHELL, "Eval", "s:command", CTL_REPLY_STRING },

  /* ai */
  { "ai providers", "List configured AI providers",
    CTL_IFACE_AI, "ListProviders", NULL, CTL_REPLY_STRING },
  { "ai prompt", "One-shot AI prompt (blocking)",
    CTL_IFACE_AI, "Prompt", "s:prompt s?:provider s?:system",
    CTL_REPLY_STRING },
  { "ai chat", "Open a chat buffer (optionally sending a prompt)",
    CTL_IFACE_AI, "OpenChat", "s?:provider s?:prompt",
    CTL_REPLY_STRING },

  /* gsurf */
  { "gsurf open", "Open a URL in a new gsurf buffer",
    CTL_IFACE_GSURF, "Open", "s:url", CTL_REPLY_STRING },
  { "gsurf navigate", "Navigate a gsurf buffer",
    CTL_IFACE_GSURF, "Navigate", "s:url s?:buffer", CTL_REPLY_STRING },
  { "gsurf back", "History back",
    CTL_IFACE_GSURF, "Back", "s?:buffer", CTL_REPLY_STRING },
  { "gsurf forward", "History forward",
    CTL_IFACE_GSURF, "Forward", "s?:buffer", CTL_REPLY_STRING },
  { "gsurf reload", "Reload the page",
    CTL_IFACE_GSURF, "Reload", "s?:buffer", CTL_REPLY_STRING },
  { "gsurf stop", "Stop loading",
    CTL_IFACE_GSURF, "Stop", "s?:buffer", CTL_REPLY_STRING },
  { "gsurf url", "Current page URL",
    CTL_IFACE_GSURF, "GetUri", "s?:buffer", CTL_REPLY_STRING },
  { "gsurf title", "Current page title",
    CTL_IFACE_GSURF, "GetTitle", "s?:buffer", CTL_REPLY_STRING },
  { "gsurf current", "Most recent gsurf buffer info",
    CTL_IFACE_GSURF, "Current", NULL, CTL_REPLY_STRING },
  { "gsurf list", "List gsurf buffers",
    CTL_IFACE_GSURF, "List", NULL, CTL_REPLY_STRING },
  { "gsurf modules", "List loaded gsurf modules",
    CTL_IFACE_GSURF, "ModulesList", NULL, CTL_REPLY_STRING },
  { "gsurf js", "Evaluate JavaScript in the page",
    CTL_IFACE_GSURF, "EvalJs", "s:script s?:buffer",
    CTL_REPLY_STRING },
  { "gsurf zoom", "Set the zoom level",
    CTL_IFACE_GSURF, "SetZoom", "d:level s?:buffer",
    CTL_REPLY_STRING },
  { "gsurf lite", "Render a page into a text buffer (gsurf-lite)",
    CTL_IFACE_GSURF, "LiteOpen", "s:url", CTL_REPLY_STRING },
  { "gsurf text", "Extract the page's text content",
    CTL_IFACE_GSURF, "ExtractText", "s?:buffer", CTL_REPLY_STRING },
  { "gsurf downloads", "List downloads",
    CTL_IFACE_GSURF, "DownloadList", NULL, CTL_REPLY_STRING },
  { "gsurf download-cancel", "Cancel a download by id",
    CTL_IFACE_GSURF, "DownloadCancel", "x:id", CTL_REPLY_STRING },
  { "gsurf snapshot", "Screenshot the page to a PNG file",
    CTL_IFACE_GSURF, "Snapshot", "s:file b?:full_page s?:buffer",
    CTL_REPLY_STRING },
  { "gsurf pdf", "Print the page to a PDF file",
    CTL_IFACE_GSURF, "PrintPdf", "s:file s?:buffer",
    CTL_REPLY_STRING },
  { "gsurf permission", "Set a permission policy "
    "(origin type allow|deny|ask)",
    CTL_IFACE_GSURF, "PermissionPolicy", "s:origin s:type s:verdict",
    CTL_REPLY_STRING },

  /* gnuseye */
  { "gnuseye open", "Open the GNU's Eye globe",
    CTL_IFACE_GNUSEYE, "Open", NULL, CTL_REPLY_STRING },
  { "gnuseye brief", "Entity index summary",
    CTL_IFACE_GNUSEYE, "Brief", NULL, CTL_REPLY_STRING },
  { "gnuseye layers", "List data layers",
    CTL_IFACE_GNUSEYE, "ListLayers", NULL, CTL_REPLY_STRING },
  { "gnuseye toggle", "Toggle a data layer",
    CTL_IFACE_GNUSEYE, "ToggleLayer", "s:name", CTL_REPLY_STRING },
  { "gnuseye fly-to", "Fly the camera to lat/lon",
    CTL_IFACE_GNUSEYE, "FlyTo", "d:lat d:lon d?:range",
    CTL_REPLY_STRING },
  { "gnuseye refresh", "Refresh all layers",
    CTL_IFACE_GNUSEYE, "Refresh", NULL, CTL_REPLY_STRING },
  { "gnuseye query", "Query indexed entities "
    "(kind west east south north limit)",
    CTL_IFACE_GNUSEYE, "QueryEntities",
    "s?:kind d?:west d?:east d?:south d?:north i?:limit",
    CTL_REPLY_JSON },
  { "gnuseye geofence", "Add a circular geofence",
    CTL_IFACE_GNUSEYE, "AddGeofence", "s:name d:lat d:lon d:radius_km",
    CTL_REPLY_STRING },
  { "gnuseye cii", "Country instability index (top 15)",
    CTL_IFACE_GNUSEYE, "Cii", NULL, CTL_REPLY_JSON },

  /* podomation */
  { "pod status", "Engine status (start|stop|status)",
    CTL_IFACE_PODOMATION, "Control", "s:action", CTL_REPLY_STRING },
  { "pod pods", "List active pods",
    CTL_IFACE_PODOMATION, "ListPods", NULL, CTL_REPLY_STRING },
  { "pod modules", "List loaded modules",
    CTL_IFACE_PODOMATION, "ListModules", NULL, CTL_REPLY_STRING },
  { "pod stats", "Engine statistics",
    CTL_IFACE_PODOMATION, "Stats", NULL, CTL_REPLY_STRING },
  { "pod emit", "Emit an event (with KEY=VALUE payload)",
    CTL_IFACE_PODOMATION, "EmitEvent", "s:event D:data",
    CTL_REPLY_STRING },
  { "pod eval", "Evaluate podomation DSL source",
    CTL_IFACE_PODOMATION, "EvalDsl", "s:dsl", CTL_REPLY_STRING },
  { "pod repl-eval", "Evaluate one line in the persistent DSL REPL",
    CTL_IFACE_PODOMATION, "ReplEval", "s:line", CTL_REPLY_STRING },
  { "pod load", "Load a .pod DSL file",
    CTL_IFACE_PODOMATION, "LoadFile", "s:file", CTL_REPLY_STRING },
  { "pod reload", "Hot-reload the engine",
    CTL_IFACE_PODOMATION, "Reload", NULL, CTL_REPLY_STRING },
  { "pod set-context", "Set engine context (KEY=VALUE...)",
    CTL_IFACE_PODOMATION, "SetContext", "D:context",
    CTL_REPLY_STRING },

  /* video */
  { "video list", "List live video stream handles",
    CTL_IFACE_VIDEO, "List", NULL, CTL_REPLY_STRING },
  { "video snapshot", "Save a video frame to a PNG file",
    CTL_IFACE_VIDEO, "Snapshot", "x:handle s:file",
    CTL_REPLY_STRING },

  /* audio */
  { "audio record", "Record microphone audio to a WAV file",
    CTL_IFACE_AUDIO, "Record", "d:seconds s?:file",
    CTL_REPLY_STRING },

  /* speech */
  { "speech transcribe", "Transcribe a WAV file (whisper)",
    CTL_IFACE_SPEECH, "Transcribe", "s:audio_path s?:language",
    CTL_REPLY_STRING },
  { "speech models", "List whisper models",
    CTL_IFACE_SPEECH, "ListWhisperModels", NULL, CTL_REPLY_STRING },
  { "speech say", "Speak text (piper); FILE saves PCM instead",
    CTL_IFACE_SPEECH, "Synthesize", "s:text s?:file",
    CTL_REPLY_STRING },
  { "speech voices", "List piper voices",
    CTL_IFACE_SPEECH, "ListVoices", NULL, CTL_REPLY_STRING },

  /* lrg (libregnum editor) */
  { "lrg open", "Open the libregnum level editor",
    CTL_IFACE_LRG, "Open", "s?:path", CTL_REPLY_STRING },
  { "lrg play", "Enter play mode",
    CTL_IFACE_LRG, "Play", NULL, CTL_REPLY_STRING },
  { "lrg stop", "Stop play mode",
    CTL_IFACE_LRG, "Stop", NULL, CTL_REPLY_STRING },
  { "lrg save", "Save the level",
    CTL_IFACE_LRG, "Save", "s?:path", CTL_REPLY_STRING },
  { "lrg tree", "Object tree",
    CTL_IFACE_LRG, "ObjectTree", NULL, CTL_REPLY_STRING },
  { "lrg select", "Select a node by id",
    CTL_IFACE_LRG, "Select", "x:id", CTL_REPLY_STRING },
  { "lrg move", "Move a node",
    CTL_IFACE_LRG, "Move", "x:id d:x d:y d:z", CTL_REPLY_STRING },
  { "lrg delete", "Delete a node",
    CTL_IFACE_LRG, "Delete", "x:id", CTL_REPLY_STRING },
  { "lrg add-primitive", "Add a primitive node",
    CTL_IFACE_LRG, "AddPrimitive", "x:primitive s?:name",
    CTL_REPLY_STRING },
  { "lrg add-visual", "Add a visual node",
    CTL_IFACE_LRG, "AddVisual", "x:kind s?:asset s?:name",
    CTL_REPLY_STRING },

  /* instance/log surface */
  { "logs show", "Recent *Messages* lines",
    CTL_IFACE_LOG, "RecentMessages", "i?:lines", CTL_REPLY_STRING },

  { NULL, NULL, NULL, NULL, NULL, 0 }
};

void
ctl_cmd_subsys_register (CtlCommandRegistry *registry)
{
  gint k;
  for (k = 0; subsys_specs[k].name != NULL; k++)
    ctl_command_registry_add (registry,
                              ctl_method_command_new (&subsys_specs[k]));
}
