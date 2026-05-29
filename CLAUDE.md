# cmacs — GNU Emacs with GLib/GObject/Wayland integration

## Build

```bash
./install-deps            # system dependencies (Fedora, Ubuntu, Arch, macOS, FreeBSD)
./autogen.sh              # first time only
./configure \             # see README.org for full recommended flags
  --with-pgtk --with-cairo --with-dbus --with-harfbuzz \
  --with-modules --with-native-compilation=aot \
  --with-tree-sitter --with-sqlite3 --with-json \
  --with-rsvg --with-jpeg --with-png --with-gif \
  --with-tiff --with-webp --with-xpm --with-gpm=no \
  --with-cmacs-glib --with-cmacs-gi --with-cmacs-crispy \
  --with-cmacs-bacon --with-cmacs-gowl \
  --with-cmacs-podomation --with-cmacs-libreclaw \
  --with-cmacs-ai \
  --with-cmacs-org-ex --with-cmacs-mcp \
  --with-cmacs-print \
  --with-cmacs-video \
  --with-cmacs-cintrospect --with-cmacs-libregnum --enable-cmacs-cpatch
make -j$(nproc)           # builds deps + emacs
just run                  # run it (sets CMACS_MODULE_DIR for cmacsgi)
```

`just run` is preferred over `src/emacs` directly: it exports
`CMACS_MODULE_DIR=$PWD/cmacs/bacon/modules` so the `cmacsgi` bacon
builtin loads when you do `M-x bacon`. Without that env var, the
bacon child loads no modules and `cmacsgi` is unknown. Bare
`src/emacs` is still fine for plain editing.

- Dependencies under `deps/` (crispy, bacon, gowl, podomation) are git submodules — `configure` falls back to bundled builds when system packages aren't found
- After modifying C source in `cmacs/`, just `make -j$(nproc)` from the top level
- After modifying `configure.ac`, run `autoconf` then `./configure` again
- After touching temacs-linked objects, the pdumper image is regenerated automatically
- Native-compiled .eln files cache by ABI hash — if you see stale-code behavior, `rm -rf native-lisp/`
- **After modifying Elisp in `lisp/cmacs/`**, you MUST clean all compiled caches (see below)

## Architecture

cmacs integrates nine subsystems into Emacs as C primitives (DEFUNs):

| Subsystem | Directory | What it does |
|-----------|-----------|--------------|
| **glib** | `cmacs/glib/` | GMainContext event loop integration, D-Bus service, safe Lisp eval dispatch |
| **gobject** | `cmacs/gobject/` | GObject ↔ Lisp bridge, GClosure wrappers |
| **gi** | `cmacs/gi/` | GObject Introspection — call any GI-registered library from Elisp |
| **api** | `cmacs/api/` | Shared C library: transport, eval helpers, high-level config API (libcmacs-api.so) |
| **crispy** | `cmacs/crispy/` | Embedded scripting language (C-like, GObject-based) |
| **bacon** | `cmacs/bacon/` | Embedded shell (fork-of-self `--bacon` mode, socketpair IPC) |
| **gowl** | `cmacs/gowl/` | Wayland compositor (wlroots-based) — 47 DEFUNs for full WM control |
| **podomation** | `cmacs/podomation/` | Event-driven automation engine — 17 DEFUNs, DSL, REPL |
| **libreclaw** | `cmacs/libreclaw/` | LibreClaw chat gateway — two modes: **embedded** (in-process LcApp, shared PodEngine, hatch wizard) and **remote** (dial-out to a separate libreclaw server's `/api/v1/bridge` WebSocket, tunnels cmacs's own MCP server back so the remote agent can drive the editor). Bridge subsystem (`deps/libreclaw/src/bridge/`) provides the generic substrate — any tool host that speaks the wire protocol can connect, not just cmacs. |
| **ai** | `cmacs/ai/` + `lisp/cmacs/cmacs-ai*.el` | First-class coding-agent surface wrapping `ai-glib`. Eight providers (claude/openai/gemini/grok/ollama/claude-code/opencode/claude-tmux) via one `cmacs-ai-client-new` DEFUN. Streaming via `AiStreamable` signals into `cmacs-ai-chat-mode` org buffers (libreclaw-style `* Compose` sentinel, history read-only). Region commands (rewrite/explain/doc/test), idle-timer FIM ghost completion, project-aware agent (`cmacs-ai-agent-open` auto-attaches `CLAUDE.md` / `AGENTS.md`), whisper→ai→piper voice loop, `#+BEGIN_SRC ai` org babel, `cmacs-ai-suggest-commit-message`. `AiToolExecutor` tool use enabled by default (full trust); custom Elisp tools via `cmacs-ai-tools-register`. Each chat buffer's executor is also auto-augmented with cmacs's MCP tool surface (buffer/file/project/eval/apropos/describe by default; PCRE allowlist via `cmacs-ai-mcp-bridge-allowlist`), routed through `mcp_server_invoke_tool` (a new public API I added upstream to mcp-glib); `^ai_` is hard-denied at the C layer to prevent recursion. Image gen via `cmacs-ai-image-generate-async`. MCP tools `ai_prompt` / `ai_list_providers` / `ai_open_chat` for outer agents. Canonical `libai-glib-1.0.a` built once at `deps/ai-glib/build/release/` and shared with libreclaw (libreclaw's sub-make is redirected via `AI_GLIB_DIR=` so no duplicate copy is linked); `libai-glib-1.0.a` carries only `ai_*` objects so no dedup rule is needed against bacon's canonical yaml_* set. GIR: `AiGlib-1.0.typelib` auto-prepended to `GIRepository` search path at `init_cmacs_ai`, so `(gi-require "AiGlib" "1.0")` and the bacon `cmacsgi` builtin work without any `GI_TYPELIB_PATH` setup. |
| **org-ex** | `cmacs/org-ex/` | Interactive widget embedding for Org mode (liborgex-1.0.a, statically linked) |
| **mcp** | `cmacs/mcp/` | MCP server — full AI-native runtime introspection and control via Unix socket |
| **print** | `cmacs/print/` + `lisp/cmacs/cmacs-print.el` | "Print to cmacs" CUPS virtual printer — PDF intake, per-page rasterisation, annotatable org docs |
| **video** | `cmacs/video/` + `lisp/cmacs/cmacs-video.el` | GStreamer video overlay — `playbin3` → BGRA `appsink` → Cairo blit in `pgtk_handle_draw`. Compositor-agnostic (runs under any Wayland/X11 compositor; no gowl dependency). `#+BEGIN_VIDEO` + `cmacs-video-mode`. Powers external `unifi-cam.el`. |
| **audio** | `cmacs/audio/` + `lisp/cmacs/cmacs-audio*.el` | GStreamer audio capture (pipewiresrc/pulsesrc → S16LE/16k/mono `appsink`) and playback (`appsrc` or `playbin3` → `autoaudiosink`). Inline `#+BEGIN_AUDIO` org blocks render an SVG cairo waveform overlay (inline image, not a per-frame paint). Shares cmacs-video's `gst_init` (idempotent). The 16 kHz mono capture default makes drained PCM whisper-ready with no resample. |
| **whisper** | `cmacs/whisper/` + `lisp/cmacs/cmacs-whisper*.el` | Offline STT via vendored `deps/whisper.cpp/libwhisper.a` (or system `whisper.pc`). Model cache lives in a thread-safe path→ctx GHashTable. Inference runs on a GThread worker; result delivered back to the main thread via `g_main_context_invoke (cmacs_glib_get_context())`. Exposes sync + async DEFUNs, an MCP `transcribe` tool, and live dictation (`cmacs-whisper-dictate`) bound to `C-c v d`. Models in `~/.local/share/cmacs/whisper-models/`. |
| **piper** | `cmacs/piper/` + `lisp/cmacs/cmacs-piper*.el` | Offline TTS via Piper subprocess (`piper --model V --output_raw` reading stdin, emitting raw S16LE on stdout). PCM streamed back through `cmacs-audio--playback-open-pcm-1`. `M-x cmacs-piper-speak-region` (`C-c v s`) + `cmacs-piper-stop` (`C-c v S`); PGTK right-click context menu shows "Speak selection" / "Speak sentence" / "Stop speaking" via `context-menu-functions`. Voices in `~/.local/share/cmacs/piper-voices/`. Requires `--with-cmacs-audio`. |
| **cintrospect** | `cmacs/cintrospect/` | Runtime C self-introspection via libdw (DWARF) + libgccjit (Phase 2 JIT). Symbol/type/source/stack/object lookup, plus compile-and-call new C from Lisp. Default-on. |
| **cpatch** | `cmacs/cpatch/` | Runtime C hot-patching: atomic `Lisp_Subr.function` swap (Phase 1) and trampoline detours for arbitrary C (Phase 3). Off by default — `--enable-cmacs-cpatch`. |
| **libregnum** | `cmacs/libregnum/` + `lisp/cmacs/cmacs-libregnum.el` | libregnum (GObject/raylib game engine) as embedded 3D scene buffers. Per-buffer view renders to a hidden raylib FBO (`FLAG_WINDOW_HIDDEN`), reads back BGRA, blits via `pgtk_handle_draw` (same shape as cmacs-video). **Translation-unit firewall**: only `cmacs-libregnum-render.c` includes raylib — avoids the `Color` struct vs `void*` typedef clash with `pgtkgui.h`. Three scenes: `M-x cmacs-libregnum-project-tree` (file cubes on a grid), `cmacs-libregnum-gobject-graph` (live `g_type_children` walk), `cmacs-libregnum-mind-map` (radial layout of org-heading tree). Buffer text is a YAML-ish scene description; camera state is snapshotted on save and restored on open (`before-save-hook` + mode-init scan). Off by default — `--with-cmacs-libregnum`; requires `--with-cmacs-glib` + `--with-pgtk`. **Must link against `liblibregnum.so`, NOT the static archive** — raylib's headers compile raymath inline without `static`, so `.a` has multi-defs (`QuaternionToMatrix`, `MatrixDecompose`, etc.). **Real-time rendering pipeline** (details in `doc_org/cmacs/cmacs-libregnum.org` › Rendering pipeline): the FBO render deliberately does NOT call `lrg_window_begin/end_frame` — those wrap raylib `BeginDrawing/EndDrawing`, which present + pace the *hidden* window (`glfwSwapBuffers` vsync block, a `WaitTime` 60-FPS `SetTargetFPS` cap, `glfwPollEvents`); for an offscreen FBO that is pure latency and was throttling every scene update. Readback is one `glReadPixels(GL_BGRA)` straight into a double-buffered cairo `ARGB32` surface (front read by the paint hook, back written by the renderer; the bottom-up GL origin is flipped for free by the paint matrix — no CPU channel-swap/flip loop, no per-frame malloc). **Frames reach the screen via `gtk_widget_queue_draw` on the widgets of frames showing the buffer** (`notify_frame_ready` in `cmacs-libregnum-view.c`), re-running only `pgtk_handle_draw` (the blit) at the GTK frame-clock rate — NOT `force-window-update`. A full `redisplay_internal` per frame was the measured ceiling (~35 ms/frame → ~20 FPS); the targeted invalidate restores 40–60 FPS real-time orbit (safe because the buffer text is static behind the blit, so Emacs's backing surface is already correct). Opt-in continuous animation: `cmacs-libregnum-set-animated` / `M-x cmacs-libregnum-toggle-animation` (`cmacs-libregnum-target-fps`, default 60), visibility-gated by a paint-stamp generation counter so hidden buffers cost nothing. **Rendering stays on the main thread**: an off-thread GL worker (GLFW context handoff + PBO async readback) was implemented and reverted — the worker→main frame handoff plus GL-driver cross-thread contention *regressed* FPS, because after the cap removal the render (~10–15 ms for ~1500 cubes) was never the main-thread blocker. That work is parked on branch `libregnum-offthread-wip`; do not re-land it without profiling that shows the render blocking the main thread. |

### GLib event loop integration (critical)

cmacs does NOT replace the Emacs event loop. Instead, `cmacs-glib-loop.c` hooks into Emacs's `pselect()` call in `process.c`:

1. `cmacs_glib_prepare()` — before pselect: queries GMainContext for fds/timeouts, merges into Emacs fd_sets
2. `cmacs_glib_dispatch()` — after pselect: maps results back to GPollFD, calls `g_main_context_dispatch()`

**Key invariant**: GLib callbacks (IPC, D-Bus, timers) may evaluate Lisp. Emacs's `signal_or_quit` unconditionally aborts if `waiting_for_input` is true during a Lisp error. `cmacs_glib_dispatch` must clear `waiting_for_input` before dispatch and restore it after. Failing to do this causes non-deterministic `Fatal error 6: Aborted` crashes.

### Bacon IPC

bacon runs as a forked child process communicating via socketpair. IPC uses length-prefixed JSON messages dispatched through GLib idle callbacks (`ipc_idle_dispatch` in `cmacs-bacon-ipc.c`).

### Static library deduplication

crispy and yaml-glib objects are vendored in multiple archives (libcrispy.a, libbacon-1.0.a, libgowl.a) potentially compiled from different git commits. The build system in `src/Makefile.in` strips duplicate objects from downstream archives before linking. Do NOT use `-Wl,-z,muldefs` — it silently picks one implementation, causing ABI mismatches and non-deterministic crashes.

## Source Layout

```
cmacs/              C source for all cmacs subsystems
  glib/             GLib loop, D-Bus, eval dispatch
  gobject/          GObject bridge, GClosure
  gi/               GObject Introspection bridge
  crispy/           crispy language integration
  bacon/            bacon shell integration + IPC
    modules/        bacon native modules (starship, fzf, etc.)
  gowl/             Wayland compositor
  podomation/       Automation engine (DEFUN bridge + cmacs/gowl modules)
  libreclaw/        LibreClaw chat/Matrix integration (rooms as org buffers)
  org-ex/           Org-Ex interactive widgets (liborgex-1.0.a + DEFUN bridge)
  mcp/              MCP server (Unix socket, tools, resources, prompts)
  compat/           Compatibility shims
  cmacs.h           Master header
deps/               Git submodules (crispy, bacon, gowl, podomation, libreclaw, mcp-glib)
tools/cmacs-mcp/    MCP stdio-to-socket shim binary
lisp/cmacs/         Elisp layer for each subsystem
test/cmacs/         ERT tests for each subsystem
doc/cmacs/          Texinfo manual (built into Emacs Info)
doc_org/cmacs/      Org manual (interactive, browsable in Emacs)
```

## Documentation

CMacs documentation is maintained in **two formats** that must be kept in sync:

- `doc/cmacs/cmacs.texi` — Texinfo manual, built into Emacs's Info system
- `doc_org/cmacs/*.org` — Org files, browsable interactively in Emacs

When adding or updating documentation, **update both**. The Org docs are the primary interactive reference; the Texinfo docs are the formal manual built into the editor.

## Code Style

- Follow GNU Emacs C conventions (see `CONTRIBUTE`)
- `/* */` comments only, no `//`
- All cmacs DEFUNs use `cmacs-` prefix in Lisp names
- C functions: `cmacs_` prefix for public, `static` for internal
- Commit messages: Conventional Commits with scope — `feat(gowl):`, `fix(bacon):`, `docs:`, etc.
- Commit message lines must be under 78 characters (enforced by hooks)
- License: AGPL-3.0-or-later on cmacs files

## Configure Options

All cmacs features are auto-detected. The configure script checks for system packages first, then falls back to bundled deps:

- **glib** (always enabled): glib-2.0, gobject-2.0, gio-2.0, gmodule-2.0
- **gi**: gobject-introspection-1.0
- **crispy**: system `crispy` package or bundled `deps/crispy`
- **bacon**: system `bacon-1.0` package or bundled `deps/bacon`
- **gowl**: system `gowl` package or bundled `deps/gowl` + wlroots-0.19 + wayland-server
- **podomation**: system `podomation-1.0` package or bundled `deps/podomation`
- **libreclaw**: system `libreclaw >= 0.18.0` package or bundled `deps/libreclaw` + libsoup-3.0, json-glib-1.0, libcmark, sqlite3, libetpan, libpq, yaml-0.1. Shares cmacs's PodEngine via `lc_podomation_new_with_engine()`; `init_cmacs_libreclaw()` is intentionally empty — `(cmacs-libreclaw-start)` from Elisp creates the LcApp at runtime.
- **org-ex**: builds `liborgex-1.0.a` statically from `cmacs/org-ex/lib/` (requires glib + cairo). The cmacs-ink sub-feature (`#+BEGIN_INK` canvas + marginalia) **requires `--with-rsvg`**: rendered canvases are inline `(image :type svg)` overlays. Install `librsvg2-devel` (Fedora/RHEL), `librsvg2-dev` (Debian/Ubuntu), `librsvg` (Arch/macOS), or `librsvg2` (FreeBSD) — `install-deps` handles all of them. Without rsvg the data path still works (parse/serialise/edit) but the SVG overlay falls back to Emacs's broken-image placeholder.
- **cmacs-ink-region** (region overlay ink, on the `drawing-tab-support` branch): adds a post-glyph Cairo paint pass via guarded extensions to **two** sites in `src/pgtkterm.c`:
  - `pgtk_frame_up_to_date(f)` — out-of-redisplay flushes (echo-area, cursor-blink via `gui_update_cursor`, post `force-window-update`). Its body is gated on `!buffer_flipping_blocked_p()` so it's a no-op during `redisplay_internal`.
  - `pgtk_buffer_flipping_unblocked_hook(f)` — the canonical "redisplay just finished" callback. `redisplay_internal` wraps its work in `block_buffer_flips/unblock_buffer_flips` (xdisp.c:17351, 18163), so the *unblocked* hook is what actually performs the `flip_cr_context` during a normal cursor move or scroll. Painting only at the first site causes strokes to disappear per-line as the cursor moves (partial-row repaints clear pixels and nothing reapplies them until a full-frame update). Both sites must call `cmacs_ink_overlay_paint(f)`.
  - Implementation: `cmacs_ink_overlay_paint(f)` lives in `cmacs/glib/cmacs-ink-overlay.c`; calls `org_ex_ink_paint_strokes_cairo` (in `cmacs/org-ex/lib/core/org-ex-ink-render.c`). Frame screenshots for the capture-window background flow through `cmacs/glib/cmacs-glib-screenshot.c` (DEFUN `cmacs-frame-screenshot-rect`). All paths rely on `f->output_data.pgtk->cr_context` being live during the redisplay-finish hooks; safe because pgtk has already called `block_input` at that point.
  - Hot-path safety: the paint hook runs every redisplay, including before `cmacs-ink-region.el` is autoloaded. Use `find_symbol_value` (returns `Qunbound` for unbound) instead of `Fsymbol_value` (signals `void-variable`); wrap `buffer_local_value` with a `Fboundp`-first helper (`cmacs_ink_safe_blv`) since that path calls `Fdefault_value` which also signals on unbound vars.
  - **Palette** (capture window toolbar row 2): Pen/Hilite/Eraser tool toggles, per-tool `GtkColorButton`, per-tool `GtkSpinButton` width (0.5–20.0 px), and (canvas-mode only) a background `GtkColorButton`. Highlighter renders as uniform-width alpha 0.5 (both SVG `stroke-opacity` and live Cairo); pen still pressure-modulates. Palette state persists in buffer-local defvars within the Emacs session. `#+BEGIN_INK` blocks without `:bg` track the current theme's `default` face background at render time; an explicit `:bg "#hex"` pins the canvas to a literal colour. Tablet eraser-end always wins over the toolbar.
  - **Storage policy** (`lisp/cmacs/cmacs-ink-storage.el`): annotations (per-line marginalia + region overlays) are persisted via a single dispatcher governed by `cmacs-ink-storage` (`'auto` / `'inline` / `'sidecar`; default `'auto`). Org buffers store inline as a folded `* cmacs-ink :noexport:` heading containing `#+BEGIN_INK_MARGINALIA` and `#+BEGIN_INK_REGION` blocks (one stroke per line — git-diff-friendly and self-contained with the file). Non-org buffers store in `<source>.cmacs-ink` sidecars (now also pretty-printed: one anchor per indented form, one stroke per line). Loader tries inline first, falls back to sidecar — old single-line sidecars (`cmacs-ink/marginalia/1` and `/2`) load cleanly; the next save upgrades to pretty-printed (or to inline). Migration command: `M-x cmacs-ink-migrate-to-inline` (org buffers only).
- **mcp**: system `mcp-glib-1.0` package or bundled `deps/mcp-glib` + json-glib-1.0, libsoup-3.0, libdex-1
- **audio**: `gstreamer-1.0 >= 1.20 gstreamer-app-1.0 gstreamer-audio-1.0` (build) + plugins-good (`pipewiresrc`, `pulsesrc`, `level`) at runtime. System-only; never bundled. Capture-source auto-detection in `cmacs_audio__make_capture_source` tries `pipewiresrc` factory first, falls back to `pulsesrc` on factory-make failure. Composes with `--with-cmacs-video` to share `gst_init` (both call `gst_init_check` idempotently). Composes with `--with-cmacs-whisper` (16 kHz/mono/S16LE capture caps are whisper-ready) and `--with-cmacs-piper` (Piper PCM streamed back through `cmacs-audio--playback-open-pcm-1`). Bus watch attaches via `gst_bus_create_watch` + `g_source_attach(cmacs_glib_get_context())` (NEVER `gst_bus_add_watch`). Per-stream Lisp_Objects live in `cmacs_audio__lisp_state` (single staticpro'd hash). Defcustoms: `cmacs-audio-capture-source` (default `'auto`), `cmacs-audio-default-rate` (16000), `cmacs-audio-default-channels` (1), `cmacs-audio-output-dir`.
- **whisper**: vendored `deps/whisper.cpp/libwhisper.a` + `ggml/src/libggml.a` (default) OR system `whisper.pc` (set `--with-cmacs-whisper=system`). Requires `--with-cmacs-audio` (configure errors otherwise). Inference runs on a `GThread` worker; completion delivered via `g_main_context_invoke (cmacs_glib_get_context(), ..., job)` so the Lisp callback always fires on the main thread. Sync (`cmacs-whisper-transcribe-file/pcm`) + async (`-async` variants) DEFUNs both routed through `cmacs/whisper/cmacs-whisper-job.c`. Model cache in `cmacs/whisper/cmacs-whisper-context.c` is thread-safe (single GMutex) and persists for the cmacs lifetime — no eviction at v1. MCP `transcribe` tool exposed through `cmacs/mcp/cmacs-mcp-tools-audio.c` (guarded on `#ifdef HAVE_CMACS_WHISPER`). **Model search path** (`cmacs-whisper-models-search-path`): user dir `~/.local/share/cmacs/whisper-models/` first, then system dir `/usr/share/cmacs/whisper-models/` (populated by container image builds — see `build-container` ARG `WHISPER_MODEL_NAME` / `WHISPER_MODEL_URL`; defaults to `ggml-base.en.bin`, 142 MB).  `M-x cmacs-whisper-download-model` writes to the user dir. Live dictation via `lisp/cmacs/cmacs-whisper-dictate.el`: opens a capture stream + 3 s sliding-window timer that calls `cmacs-whisper-transcribe-pcm-async` per window, inserts segments at point with `undo-boundary`, intercepts voice commands from `cmacs-whisper-dictate-command-words` (`"new line" → newline`, `"period" → ?.`, etc).
- **ai**: top-level `deps/ai-glib/build/release/libai-glib-1.0.a` (canonical, built with `GIR=1` so `AiGlib-1.0.typelib` is produced alongside). Requires `--with-cmacs-glib`. PKG_CHECK_MODULES for `glib-2.0 gobject-2.0 gio-2.0 libsoup-3.0 json-glib-1.0 >= 1.6`. When `--with-cmacs-libreclaw` is also enabled, `src/Makefile.in` invokes libreclaw's sub-make with `AI_GLIB_DIR=$(abs_top_srcdir)/deps/ai-glib` so libreclaw consumes the canonical artifact instead of building its own copy — no duplicate `libai-glib-1.0.a` on the link line. `libai-glib-1.0.a` contains only `ai_*` objects (its vendored yaml-glib is linked into the `.so` but NOT embedded in the `.a`), so the existing `_dup_yaml` / `_dup_podomation_objs` dedup machinery (`src/Makefile.in:998–1075`) is unchanged. Defcustoms: `cmacs-ai-default-provider` (default `'claude`), `cmacs-ai-default-model` (nil → provider default), `cmacs-ai-system-prompt`, `cmacs-ai-max-tokens` (4096), `cmacs-ai-enabled-tools` (full set), `cmacs-ai-tool-confirm` (nil / 'destructive / function), `cmacs-ai-completion-provider` (`'claude-code`), `cmacs-ai-chat-dir` (`$XDG_DATA_HOME/cmacs-ai/`).
- **piper**: subprocess-driven (no library link). Uses the OHF-Voice `piper1-GPL` fork — a Python package installed via `pip install piper-tts` (provides a `piper` console-script). `deps/piper` is kept as a submodule for reference / tests but is NOT built from source. Configure probes for `piper` on PATH with `AC_PATH_PROG` and bakes the resolved path into `CMACS_PIPER_DEFAULT_BINARY`; if absent at configure time the macro falls back to literal `"piper"` (resolved via `g_find_program_in_path` at runtime, so installing piper post-build works without reconfigure). Runtime dep: `espeak-ng` (used by piper for phonemization). Requires `--with-cmacs-audio` (configure errors otherwise). Invocation: `g_subprocess_new (..., piper, "--model", VOICE.onnx, "--output_raw", NULL)` reading UTF-8 stdin and emitting raw S16LE on stdout, run via `g_subprocess_communicate_async` so polling happens on the cmacs GMainContext (no extra thread). PCM is then handed to `cmacs-audio--playback-open-pcm-1` for live output, or written to a WAV via `with-temp-file`. **Voice search path** (`cmacs-piper-voices-search-path`): user dir `~/.local/share/cmacs/piper-voices/` first, then system dir `/usr/share/cmacs/piper-voices/` (populated by container image builds — see `build-container` ARGs `PIPER_VOICE_NAME` / `PIPER_VOICE_DIR` / `PIPER_VOICE_BASE_URL`; defaults to `en_US-amy-low.onnx`, 64 MB). PGTK right-click context menu integration is in `lisp/cmacs/cmacs-piper-context-menu.el` and uses the standard Emacs 28+ `context-menu-functions` hook (auto-enables `context-menu-mode`).
- **video**: `gstreamer-1.0 >= 1.20 gstreamer-app-1.0 gstreamer-video-1.0` (build) + plugins-{base,good,bad,ugly} + libav (runtime). System-only; never bundled. **Compositor-agnostic** — paint hook runs in `pgtk_handle_draw` under any Wayland/X11 compositor; has NO dependency on `--with-cmacs-gowl`. Bus watch attaches via `gst_bus_create_watch` + `g_source_attach(cmacs_glib_get_context())` (NOT `gst_bus_add_watch`, which goes to the default context). Streaming-thread `new-sample` only mem-copies BGRA into a mutex-guarded double-buffer and `g_main_context_invoke`s; never calls Lisp. Per-stream Lisp_Objects (state callbacks, anchor markers) live in a single staticpro'd hash table keyed by handle (`cmacs_video__lisp_state`), NOT in-struct, so GC roots stay valid across stream destroy. Teardown order: remove from registry → `gst_element_set_state(NULL)` (blocks until streaming threads unwind) → destroy cairo surfaces → free backing pixel data. Live-stream stall watchdog (5s threshold + 3s grace) triggers reconnect for the older `gst-plugins-good` UDP-silent-drop case. **Default audio = off**; `--with-cmacs-video` without `--with-pgtk` builds but never paints (decode-only).
- **print**: pure-Elisp + shell-script subsystem (no C build artefacts). Configure probes for `pdftocairo`, `pdfinfo`, `gdbus` at configure time; if any are missing, `--with-cmacs-print` still succeeds but the install-time CUPS backend is a no-op until you install `poppler-utils` (Fedora/Debian/Arch) and `glib2`. **Two install modes:**
  - `make install-cmacs-printer` — system-wide CUPS backend at `/usr/lib/cups/backend/cmacs-print` (root:root, mode 0700). Prompts sudo. **Auto-redirects to user-mode on immutable systems** (detects `/run/ostree-booted` or non-writable `/usr` and prints a one-line redirect to `install-cmacs-printer-user`; override with `CMACS_PRINT_FORCE_SYSTEM=1`).
  - `make install-cmacs-printer-user` — per-user IPP-Everywhere install for OSTree / Silverblue / Atomic / NixOS / any read-only-rootfs system. No sudo, no `/usr` writes. Drops a handler at `~/.local/libexec/cmacs/cmacs-print-handler` and a systemd user unit at `~/.config/systemd/user/cmacs-print.service` (absolute paths to `ippeveprinter` + handler are substituted at install time). The unit runs `ippeveprinter` advertising via mDNS; `cups-browsed` auto-creates a CUPS queue named `cmacs`. If cups-browsed is inactive, the installer prints the one-time `sudo systemctl enable --now cups-browsed` command — that's the only sudo step on any immutable system, and it lives entirely in `/etc/`.
  - **Editor-independent drainer** — `make install-cmacs-print-watcher` (per-user, no sudo). Drops a `systemd --user` `cmacs-print-drain.path` (kernel-inotify watcher on `/tmp/cmacs-print-$UID/`) and `cmacs-print-drain.service` (oneshot that runs `cmacs --batch ... --eval '(cmacs-print-drain-spool)'`). This is what makes prints land in `~/Documents/notes/03_resources/cmacs-print/` regardless of whether an interactive cmacs is running. Latency is ~1 s from spool drop to drained directory. Pair this with EITHER printer install mode. Without it, prints sit in `/tmp/cmacs-print-$UID/` until a cmacs with `cmacs-print.el` loaded starts up. Removes via `make uninstall-cmacs-print-watcher`. Path units use `DirectoryNotEmpty=` with the systemd `%U` specifier in image-baked installs (per-user installer hardcodes the UID since the unit lives under `~/.config/systemd/user/`). Service uses `Type=oneshot` + `ExecCondition` to skip when the spool is empty (path-unit fires on metadata changes too); each invocation runs cmacs in batch with a 240 s sit-for to allow async rasterise sentinels to complete.
  - **Image-baked path (immutablue / ublue / bluefin / bazzite / any image that pulls the cmacs container)** — the Containerfile stages all of the above (backend, PPD, registration helper + system unit, drainer path + service, system+user presets) into `/build/stage/usr/...`, so downstream images that `cp -a /mnt-cmacs/usr/. /usr/` (which is exactly what immutablue's `build/10-copy.sh` does) inherit a fully-configured "Print to cmacs" with zero install steps. `systemctl preset-all` at build/first-boot enables `cmacs-print-register.service` system-wide and `cmacs-print-drain.path` for every user. The system-wide drainer unit uses `/tmp/cmacs-print-%U` so all UIDs get their own spool dir without per-user file rendering. The systemd specifier `%U` works inside `[Path]=DirectoryNotEmpty=` since systemd v240+ — older systemd would silently fail-open here, but anything shipping cmacs (Fedora 43+ → systemd 254+) is way past that.
  - Removes via `make uninstall-cmacs-printer{,-user}`. Diagnostic: `make check-cmacs-printer` (reports both modes' state and detects whether `/usr` is immutable).
  - The Elisp module `lisp/cmacs/cmacs-print.el` provides `cmacs-print-import-pdf` and `cmacs-print-import-pdf-interactive` (M-x). Output formats are configurable via `cmacs-print-output-formats` (`'(org pdf)` default — produces both an org doc with inline page images and a full PDF copy under `~/Documents/notes/03_resources/cmacs-print/`). Annotation rides on the existing `cmacs-ink-region` overlay system + the user's Doom plugins (pdf-tools, org-noter, org-remark, org-roam).
  - **System backend ↔ cmacs delivery is pull-based, NOT push:** the system-mode CUPS backend writes the PDF atomically to `/tmp/cmacs-print-<uid>/<TS>-job<ID>-<title>.pdf` and exits. Cmacs `file-notify`-watches that directory (`cmacs-print-watch-spool` = t by default) and runs `cmacs-print-import-pdf` in its own `unconfined_t` security context. This sidesteps three SELinux dead ends in stock Fedora policy that are all silenced by `dontaudit` rules (failures don't show in `ausearch`): `cupsd_t` writing to `user_tmp_t` (`/run/user/$UID/`), `cupsd_t` writing to `user_home_t`, and `cupsd_t` running `su`/`runuser`/`gdbus`. `/tmp/` is `tmp_t` which `cupsd_t` can manage freely. A periodic `cmacs-print-poll-interval` drain (default 30 s) catches missed events in daemon-without-frame mode where file-notify can lag. PDFs queued before cmacs starts are picked up by the load-time drain. Per-user (ippeveprinter) mode runs in the user's own context so this whole concern doesn't apply there.

## Android APK build

Containerized — host needs only `podman` (or `docker`).  Two paths:

### Path 1 (recommended): `just android-repack`

Repackages upstream Po Lu's prebuilt APK from SourceForge with our Doom bundle injected.  Works around a libhwui-mutex bug we couldn't isolate against upstream's binary on at least **Samsung Fold 5 / Android 16** — the from-source path crashes there with `FORTIFY: pthread_mutex_lock called on a destroyed mutex (0x749f003718)`, the destroyed-looking mutex turning out to be inside `/system/lib64/libhwui.so`'s BSS, presumably mis-initialized when the framework's `vendor.display.enable_optimal_refresh_rate` property reads come back access-denied.

Flow (see `build-aux/android-repack.sh`):
1. Downloads `emacs-31.0.50-35-arm64-v8a.apk` from `https://sourceforge.net/projects/android-ports-for-gnu-emacs/files/` (cached under `build/upstream-apk-cache/`).
2. Unzips, drops `assets/doom-bundle/{emacs,doom}` (from `$HOME/.config/{emacs,doom}`) and `assets/lisp/site-start.el` into the tree.
3. Strips `META-INF/`, re-zips with `resources.arsc` and `lib/**/*.so` STORED uncompressed (Android 30+ requirement), zipaligns, resigns with `java/emacs.keystore` (`emacs1` storepass — same key upstream uses, so installs over an existing upstream install).

We ship Po Lu's exact `libemacs.so` — no source-level customisation possible — but the Doom asset bundle still rides along and the on-device shim still seeds HOME on first launch.

### Path 2: `just android-build`

Cross-compiles from source.  Currently produces an APK that crashes on Samsung Fold 5 (see Path 1 caveat); kept for environments where the libhwui interaction is benign and for hacking on Emacs C internals.

- `Containerfile.android` — Fedora 43 + JDK 21 (Temurin) + Android SDK 36 + NDK r28.2 (pinned).  Includes `libselinux-devel` on the host for the outer configure's selinux check (otherwise `with_selinux=no` propagates and `libselinux_emacs.so` is dropped).
- `/opt/ndk-ports/` is staged with the full upstream-matching SourceForge port set: gnutls + deps, libxml2, harfbuzz, tree-sitter, libffi, libiconv, image libs (jpeg/png/gif/tiff), pixman + cairo + glib + pango + gdk-pixbuf + libcroco + rsvg + libselinux.  Plus AOSP `pcre` (cloned at `android-7.1.2_r1` for its Android.mk).  Tiff's `libtiff/Android.mk` + `Makefile.{am,in}` are sed-patched at image-build time to drop webp imports (no webp port available on SourceForge).
- `build-aux/android-build.sh` runs the cross-build inside the container; `--with-ndk-path` points at all of `/opt/ndk-ports/*/`, `--with-selinux=yes` is passed explicitly (defaults to "maybe" which skips the cross-build's ndk_SEARCH_MODULE selinux branch).  `selinux/selinux.h` is staged into the NDK sysroot at image build (the gnulib `AC_CHECK_HEADER` for `<selinux/selinux.h>` doesn't pick up `--with-ndk-path`'s include flags otherwise).
- `--without-android-debug` matches upstream's release-mode signing (`debuggable=false`); debug-mode triggers extra HyperOS/OneUI checks that are part of the libhwui crash chain.
- `CMACS_ANDROID_VANILLA=1` env var skips the Doom bundle injection — useful for diagnostic builds that should match upstream byte-for-byte.

### Shared concerns

- `just android-image` — build/refresh the container image (~4 GB, ~10 min first run, cached afterward).
- `just android-deviceinstall` — `adb install` the most recent APK in `build/android-out/`.  Falls back to container `adb` with `/dev/bus/usb` passthrough if host `adb` isn't installed.
- `just android-logcat-snapshot` — force-stop, relaunch, and dump 400 lines of logcat filtered to Emacs + bionic crash tags.  Use to capture startup crashes.
- `just android-addr2lib ADDR` — race-launch via `am set-debug-app -w`, dump `/proc/<pid>/maps`, identify which library covers a given hex address.  Indispensable for FORTIFY tracebacks.
- `lisp/site-start.el` — first-launch shim.  On Android (detected via `system-configuration` containing `"android"`) it copies `/assets/doom-bundle/{emacs,doom}` into `$HOME/.config/{emacs,doom}` if absent, then re-points `user-emacs-directory` and `startup-init-directory` so `early-init.el`/`init.el` load from Doom.  No-op on every other build.
- `java/Makefile.in` — patched `install_temp` rule: when `build-aux/android-doom-bundle/` exists, copy it into `install_temp/assets/doom-bundle/` (only used by `android-build`; `android-repack` injects the bundle into the unzipped upstream APK directly).
- On-device first run: launch Emacs, then `M-x doom-sync` once (network required) to install the Doom packages into the seeded `~/.config/emacs/.local/` — they don't ship in the APK.  No native compilation on Android (no `libgccjit` for NDK; configure passes `--without-native-compilation`).

## Testing

```bash
make -C test check-cmacs    # run all cmacs ERT tests
```

Test files in `test/cmacs/`: one per subsystem (`cmacs-glib-tests.el`, `cmacs-bacon-tests.el`, `cmacs-gi-tests.el`, `cmacs-gobject-tests.el`, `cmacs-gowl-tests.el`, `cmacs-crispy-tests.el`, `cmacs-config-tests.el`, `cmacs-org-ex-tests.el`, `cmacs-libreclaw-tests.el`).

## Debugging Crashes

cmacs has a GDB debugging agent (`.claude/agents/gdb-debugger.md`) that uses the `gdb-mcp-server` for post-mortem core dump analysis. For crash debugging:

1. Extract core dump: `coredumpctl dump --output=/tmp/emacs-core`
2. Launch the gdb-debugger agent — it knows cmacs internals, Lisp_Object decoding, and common crash patterns

### Common crash patterns

- **SIGABRT in `signal_or_quit`**: `waiting_for_input` was true during GLib callback Lisp evaluation. Check the guard in `cmacs_glib_dispatch`.
- **Non-deterministic crashes with varying backtraces**: Duplicate symbols from vendored static libraries. Check the dedup logic in `src/Makefile.in`.
- **GC crashes**: A `Lisp_Object` stored in GLib-allocated memory without GC protection (`staticpro` or specpdl).

## Modifying Elisp in `lisp/cmacs/` — Stale Cache Pitfall

Emacs has **three layers of compiled Elisp** that silently override `.el` source files. After modifying any `.el` file in `lisp/cmacs/`, you MUST clean ALL of them or your changes will not take effect:

```bash
# 1. Delete byte-compiled .elc (Emacs prefers .elc over .el)
rm -f lisp/cmacs/CHANGED-FILE.elc

# 2. Delete native-compiled .eln from ALL ABI hash directories
#    Each rebuild generates a new ABI hash; old .eln files accumulate
rm -f native-lisp/*/CHANGED-FILE-*.eln

# 3. Delete user-level eln cache (Doom Emacs, etc.)
rm -f ~/.config/emacs/.local/cache/eln/*/CHANGED-FILE-*.eln
rm -f ~/.config/emacs/eln-cache/*/CHANGED-FILE-*.eln

# 4. If you also changed C DEFUNs used by the .el file, force relink:
rm -f src/temacs src/emacs && make -j$(nproc)
```

**Why this matters:** Emacs's async native compiler runs in the background during normal use. It can compile a `.el` file WHILE you're editing it, producing an `.eln` from an intermediate version. On the next function call or restart, Emacs loads the stale `.eln` instead of the updated `.el`. This causes changes to silently "stop working" mid-session with no error.

**Best practice for Elisp changes:**
- Always delete the corresponding `.elc` after editing
- Run `rm -f native-lisp/*/FILENAME-*.eln` after editing
- If behavior is wrong despite correct source, check `(locate-library "LIBRARY-NAME")` to see what file Emacs is actually loading
- When in doubt: `rm -rf native-lisp/ lisp/cmacs/*.elc`

## Known Issues / Gotchas

- The pdumper image must be regenerated after changes to temacs-linked code — `make` handles this, but stale dumps cause confusing runtime errors
- Native compilation .eln cache is keyed by ABI hash — version mismatches cause silent fallback to byte-compiled code
- **Stale `.elc`/`.eln` files** are the #1 cause of "my Elisp change isn't working" — see section above
- `g_main_context_iteration` in `cmacs-glib-iteration` does NOT go through the `waiting_for_input` guard — only use it from Lisp code that knows Emacs is not in input-wait state
- bacon `--bacon` mode forks the emacs process itself — `fork()` safety constraints apply (no threads before fork)
- **`make` may not relink** after C source changes — if `src/Makefile.in` dependencies are incomplete, the `.o` recompiles but `temacs` is not re-linked. Force with `rm -f src/temacs && make -j$(nproc)`
- **cmacs-audio capture-source auto-detect** — `'auto` tries `pipewiresrc` factory first; on PulseAudio-only systems the factory probe is wasted (still works, but logs once). Set `cmacs-audio-capture-source` to `'pulse` to skip the failed probe. On macOS set it to `'coreaudio` (osxaudiosrc factory).
- **cmacs-whisper model not found** — the dictate flow signals `user-error` if `(cmacs-whisper-model-path)` doesn't exist; run `M-x cmacs-whisper-download-model` once and the default `ggml-base.en.bin` lands under `~/.local/share/cmacs/whisper-models/`. The async path silently `:error`s if the model load fails mid-job; check `*Messages*`.
- **cmacs-piper subprocess** — Piper is invoked via `g_subprocess_communicate_async`, so failures land in the callback's `((:error . MSG))` shape rather than as a signal. If the executable isn't on PATH at runtime, `cmacs-piper-supported-p` returns nil; the speak commands raise a `user-error`. The bundled `deps/piper` build under the container image is staged into `/usr/local/bin/piper`.
- **`pipx install piper-tts` fails with "cannot find package 'piper-tts' metadata"** — This is a pipx-1.12 + uv-backend bug, not a piper-tts bug. pipx auto-detects `uv` as its installer backend when `uv` is on PATH; uv's pip-install of piper-tts's scikit-build-core wheel races pipx's metadata-readback step. Symptoms: pipx logs `Backend resolved to uv (source: auto-path)` then `installing piper-tts...` then the error, even though the wheel install succeeded. Fix: bypass pipx with plain `/usr/bin/python3 -m pip install --user piper-tts`. Documented in detail in `doc_org/cmacs/cmacs-piper.org` and `doc/cmacs/cmacs.texi` (Piper > Troubleshooting). Also: `install-deps` tries plain pip first by design for this reason — do NOT "fix" it to prefer pipx without re-reading the comment.
- **pipx `No interpreter found at path /home/linuxbrew/.../libexec/bin/python`** — pipx caches the Python interpreter path baked into venv metadata at install time. Homebrew upgrades of `python@3.14` move `libexec/bin/python`, breaking every cached venv. Fix: `PIPX_DEFAULT_PYTHON=/usr/bin/python3 pipx reinstall-all`, or (cleanest) `rm -rf ~/.local/share/pipx ~/.local/pipx && pipx ensurepath`. cmacs's `install-deps` works around this preemptively by using `/usr/bin/python3` explicitly for the piper-tts install.
