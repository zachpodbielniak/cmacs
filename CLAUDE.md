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
  --with-cmacs-org-ex --with-cmacs-mcp
make -j$(nproc)           # builds deps + emacs
src/emacs                 # run it
```

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
| **libreclaw** | `cmacs/libreclaw/` | LibreClaw chat gateway — Matrix/Local/Email/Webhook rooms as org-mode buffers, shared PodEngine, hatch wizard |
| **org-ex** | `cmacs/org-ex/` | Interactive widget embedding for Org mode (liborgex-1.0.a, statically linked) |
| **mcp** | `cmacs/mcp/` | MCP server — full AI-native runtime introspection and control via Unix socket |

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
