# cmacs — GNU Emacs with GLib/GObject/Wayland integration

cmacs embeds GLib/GObject, a Wayland compositor, AI, a web browser, and more into
GNU Emacs as C primitives (DEFUNs). This file is the orientation map plus the
invariants you must not break — detailed per-subsystem notes live in
`doc_org/cmacs/*.org`, `doc/cmacs/cmacs.texi`, and the Claude memory files.

## Upstream merge discipline (IMPORTANT)

cmacs tracks upstream GNU Emacs and merges it in every few weeks. Keep merges painless:

- **Put new features in NEW files** under `cmacs/<subsystem>/` and `lisp/cmacs/` — never
  spread a feature across upstream Emacs sources.
- **Minimize edits to upstream files** (`src/*.c`, `lisp/*.el`, `src/Makefile.in`, …).
  When you must touch one, make the change as small and guarded as possible — ideally a
  single call into a `cmacs_*` function defined in a new file — and comment it clearly so
  it's trivial to re-apply across a merge.
- Every new subsystem must be `--with-cmacs-*` / `--enable-cmacs-*` gated and
  self-contained, so an upstream-style build with cmacs off still works.

Current upstream touch-points (keep minimal): `process.c` pselect hooks (GLib loop),
`src/pgtkterm.c` paint hooks (video / libregnum / ink overlays), `src/emacs.c` early
`main()` hooks (`--bacon` / `--gowl` entry, JSC GC-signal redirect), `src/Makefile.in`
(linking). Each hunk is marked `/* CMACS: ... */`; the full catalogue with rationale is
`doc_org/cmacs/cmacs-upstream-changes.org` (and the *Upstream Changes* chapter in the manual).

## Build

```bash
./install-deps            # system deps (Fedora, Ubuntu, Arch, macOS, FreeBSD)
./autogen.sh              # first time only
./configure --with-pgtk --with-cairo --with-dbus --with-harfbuzz \
            --with-modules --with-native-compilation=aot \
            --with-tree-sitter --with-xwidgets \
            --with-cmacs-glib --with-cmacs-gi ... --with-cmacs-gnuseye \
            --with-cmacs-screensaver --with-cmacs-gsurf --with-cmacs-emacsctl \
            --with-cmacs-lrgterm --with-cmacs-imgedit \
            --with-cmacs-vidstudio --enable-cmacs-cpatch \
            --enable-cmacs-deps-debug  # in-house deps -O0 -g3 DWARF (gdb + cintrospect); full set: README.org
make -j$(nproc)           # builds deps + emacs
just run                  # run it
```

**Talking to a running instance (`emacsctl`).** `src/emacsctl` (alias `cmacsctl`) is a
standalone D-Bus CLI to a live cmacs — use it to introspect/drive a running
`emacs --gowl` session (e.g. the GDM "CMacs (Debug)" seat session) without the MCP
server. `./src/emacsctl eval '(EXPR)'` is the universal gateway (returns the printed
value); also `instances`, `logs`/`events` (firehose), `repl`, and groups like
`get clients`, `var`, `buffer`, `c` (C introspection). For gowl, eval specific
`gowl-*` DEFUNs: `'(gowl-focused-client)'`, `'(gowl-list-monitors)'`,
`'(gowl-list-keybinds)'`.

**DANGER — a `--gowl` instance IS the user's desktop session.** `emacsctl eval`
runs **synchronously in the compositor's main thread**. Any eval that blocks (a full
`mapatoms` symbol-table scan, a long loop, `(gowl-list-modules)`) or errors can hang
or crash the compositor — which kills the entire Wayland session and every app in it
(this has happened). Rules when a `--gowl` session is live: (1) only tiny, O(1),
read-only evals — never `mapatoms`/unbounded loops/anything touching all
buffers/symbols; (2) never eval anything that can signal an error mid-compositor;
(3) prefer **static source analysis** over live probing; (4) if you genuinely need
runtime state, hand the user a one-liner to run themselves and paste back, rather
than firing it at their desktop. When unsure, don't eval — read the code.

cmacs features are all `--with-cmacs-*` / `--enable-cmacs-*`, auto-detect system
packages, and fall back to bundled `deps/` submodules. `just run` (and `just gowl`)
are preferred over `src/emacs`: they export `CMACS_MODULE_DIR` (bacon `cmacsgi`),
`CMACS_GSURF_MODULE_DIR` (gsurf modules) and `CMACS_GOWL_MODULE_DIR`
(`deps/gowl/build/release/modules`) so local testing always loads the freshly-built
modules instead of any system-installed copy. Bare `src/emacs` is fine for plain
editing (it still finds in-tree gowl modules via the relative dev-build path, but
the env var is the explicit override — see `cmacs_gowl_find_module`).

**Rebuild rules**
- After C source in `cmacs/`: `make -j$(nproc)`.
- After `configure.ac`: `autoconf`, then `./configure` again.
- After temacs-linked objects: the pdumper image regenerates automatically.
- **`make` may not relink** after C changes (incomplete deps) — force with
  `rm -f src/temacs && make -j$(nproc)`.
- After Elisp in `lisp/cmacs/`: clean compiled caches — see *Stale Elisp cache* below.

## Parallel work: git worktrees + incremental build

To work on a big change while another agent/human keeps the main checkout, use a
**git worktree** and copy the build artifacts in so the first build is **incremental
(seconds–minutes), not a full ~20-minute rebuild**. A full build recompiles all deps
(libregnum/graylib/raylib/…), native-compiles every `.eln`, and re-dumps — copying the
existing objects/archives/`.eln`/pdump avoids all of it.

The build is **in-tree** (`srcdir = .`) and the gcc `-MMD` `.d` files use **relative**
dependency paths (portable across worktrees); only the Makefiles carry `abs_srcdir`/
`abs_builddir`, which a re-`configure` fixes. Recipe (main tree clean + committed first):

```bash
# 1. worktree on a new branch off the current commit (sibling dir)
git worktree add ../cmacs-wt -b my-feature

cd ../cmacs-wt
# 2. submodules must be initialised to commit into deps/* (libregnum, graylib, …)
git submodule update --init --recursive

# 3. overlay the main tree's files+artifacts, preserving mtimes, keeping git metadata.
#    (rsync of tracked sources restores their original — older — mtimes so the copied
#    objects stay newer; --exclude='.git' preserves the worktree's + submodules' git
#    linkage.  On btrfs, the big dep build/ dirs can be `cp --reflink=auto` for speed.)
rsync -aH --exclude='.git' /var/home/zach/source/projects/cmacs/ ./

# 4. regenerate Makefiles/config.status for THIS worktree's abs paths (no object rebuild)
./configure $(cd /var/home/zach/source/projects/cmacs && ./config.status --config | tr '\n' ' ')

# 5. make every build output the newest thing in the tree, so the config.h/Makefile
#    regen in step 4 doesn't trigger a mass rebuild; only files you edit recompile.
find . \( -name '*.o' -o -name '*.a' -o -name '*.eln' -o -name '*.elc' \
         -o -name '*.pdmp' \) -print0 | xargs -0 -r touch
touch src/emacs src/temacs 2>/dev/null

# 6. incremental build + smoke test — a second `make` should be a near no-op
make -j"$(nproc)"
src/emacs --version
```

**Two gotchas** (both handled above): (a) **mtime ordering** — a fresh `worktree add`/
`submodule update` stamps sources at "now," making copied objects look stale → full
rebuild; the source-mtime overlay (step 3) + touch-artifacts-newest (step 5) fix it,
verified by a no-op `make`. (b) **absolute paths** — `config.status`/Makefiles embed the
origin tree's `abs_srcdir`; step 4's re-`configure` re-points them (the relative `.d`
files need no fixing).

Cleanup when done: `git worktree remove ../cmacs-wt` (and delete the branch). The worktree
shares the superproject `.git` object store, so its commits/branches are visible from the
main tree — merge the feature branch there when finished.

## Subsystems

C source `cmacs/<name>/`, Elisp `lisp/cmacs/`, tests `test/cmacs/`, docs
`doc_org/cmacs/*.org` + `doc/cmacs/cmacs.texi`. All Lisp DEFUN names use the `cmacs-` prefix.

| Subsystem | Directory | What it does |
|-----------|-----------|--------------|
| **glib** | `cmacs/glib/` | GMainContext event-loop integration, D-Bus service, safe Lisp eval dispatch |
| **gobject** | `cmacs/gobject/` | GObject ↔ Lisp bridge, GClosure wrappers |
| **gi** | `cmacs/gi/` | GObject Introspection — call any GI-registered library from Elisp |
| **api** | `cmacs/api/` | Shared C lib (libcmacs-api.so): transport, eval helpers, config API |
| **crispy** | `cmacs/crispy/` | Embedded C-like GObject scripting language |
| **bacon** | `cmacs/bacon/` | Embedded shell (fork-of-self `--bacon` mode, socketpair IPC) |
| **gowl** | `cmacs/gowl/` | wlroots-based Wayland compositor — full WM control via DEFUNs |
| **podomation** | `cmacs/podomation/` | Event-driven automation engine — DSL + REPL |
| **libreclaw** | `cmacs/libreclaw/` | Chat gateway: **embedded** (in-proc LcApp, shared PodEngine) + **remote** (dial-out bridge that tunnels cmacs's MCP server to a remote agent) |
| **ai** | `cmacs/ai/` | Coding-agent surface over `ai-glib`: 8 providers, streaming chat org buffers, region cmds, FIM completion, voice loop, MCP tool bridge (`deps/ai-glib`, shared with libreclaw) |
| **org-ex** | `cmacs/org-ex/` | Interactive widget embedding for Org (liborgex-1.0.a); includes cmacs-ink |
| **mcp** | `cmacs/mcp/` | MCP server over Unix socket — AI-native runtime introspection & control |
| **gsurf** | `cmacs/gsurf/` | Embedded web browser (gsurf, a GObject `surf` port) as live WebKitGTK buffers; caret mode + gsurf-lite (eww-style). Two render backends, runtime-selected by frame type: GTK3/WebKitGTK widget embed (pgtk), and a GTK-free libregnum backend for `emacs --lrg` (offscreen WebKit → GrlTexture composited by lrgterm; `--with-cmacs-gsurf-lrg`). Off by default |
| **print** | `cmacs/print/` | "Print to cmacs" CUPS virtual printer → annotatable org docs |
| **video** | `cmacs/video/` | GStreamer video overlay (playbin3 → BGRA appsink → Cairo blit). Compositor-agnostic |
| **audio** | `cmacs/audio/` | GStreamer audio capture/playback; `#+BEGIN_AUDIO` waveform |
| **whisper** | `cmacs/whisper/` | Offline STT (whisper.cpp) + live dictation (`C-c v d`) |
| **piper** | `cmacs/piper/` | Offline TTS (Piper subprocess) — `C-c v s` |
| **cintrospect** | `cmacs/cintrospect/` | Runtime C self-introspection (DWARF + libgccjit JIT). Default-on |
| **cpatch** | `cmacs/cpatch/` | Runtime C hot-patching (Lisp_Subr swap + detours). Off by default |
| **libregnum** | `cmacs/libregnum/` | raylib game engine as embedded 3D scene buffers (project tree, gobject graph, mind map). Off by default |
| **emacsctl** | `cmacs/emacsctl/` | kubectl-style CLI (`emacsctl`/`cmacsctl`) over the D-Bus surface — instances, eval (elisp/crispy/bacon/eshell), REPL, watch/logs, contexts, ssh tunnelling. Standalone binary at `src/emacsctl`, links no Emacs objects |
| **gnuseye** | `cmacs/gnuseye/` | "GNU's Eye": live planetary situational-awareness globe (satellites/aircraft/vessels/weather/solar-system) rendered through libregnum; data layers defined in Elisp. In the default flag set (`just bootstrap`/Containerfile) |
| **lrgterm** | `cmacs/lrgterm/` | `output_lrg`: independent libregnum/raylib **Emacs display backend** (peer to tty/pgtk) that renders the whole UI via libregnum. Opt-in `emacs --lrg[=SPEC]`: 2d (flat) and 3d (frame/windows as textured panels in a real-time scene — `--lrg=3d:per-window:workshop`, runtime-switchable arrangements/environments + camera via `C-c 3`); 3dvr reserved. Reuses Emacs FreeType/HarfBuzz for text via a GPU glyph-atlas. Off by default |
| **screensaver** | `cmacs/screensaver/` | Renders `deps/screensavers` libregnum game-modules (blackhole/singularity/helios) as animated **gowl wallpaper**, **lock-screen background** (`gowl-lock` integration), or **in-buffer** playback. Wallpaper/lock render **out-of-process** (`cmacs-screensaver-render`, its own GL context — no main-thread lag, no EGL/GLX conflict; a *process* not a thread because raylib's GL context is shared): control over a SEQPACKET-JSON socketpair, frames over a sealed-memfd seqlock ring (`SCM_RIGHTS`), supervised (crash-restart/backoff/watchdog/PDEATHSIG). Emacs pushes raw ARGB8888 frames into gowl's frame-sink — **gowl never links libregnum** (guard-tested; child links no Emacs objects). Named configs + picker + status/restart/pause/resume/set-fps on all surfaces; off by default |
| **imgedit** | `cmacs/imgedit/` | 2D image / sprite editor on libregnum's `LrgImageDocument`/`LrgImageLayer` (CPU layer compositor: opacity, blend modes, offset, undo). DEFUN model layer (`cmacs-imgedit-*`, handle-based, MCP/headless-driveable) + `cmacs-imgedit-mode` (native-image display + mouse painting; in-engine GL viewport is a planned follow-on). Off by default (`--with-cmacs-imgedit`; needs libregnum) |
| **vidstudio** | `cmacs/vidstudio/` | Video editor on libregnum's Reel system (each track = an `LrgReelTransitionSeries` of clip segments). DEFUN model layer (`cmacs-vidstudio-*`: tracks/clips/transitions/effects/split/trim/move/ripple, CPU render, ffmpeg export) + `cmacs-vidstudio-mode` (native-image preview + playhead/transport; in-engine timeline strip is a planned follow-on). ffmpeg-binary backed; the `LrgVideoPlayer` libav backend (`FFMPEG=1`) gives smooth scrub. Off by default (`--with-cmacs-vidstudio`; needs libregnum) |

The large subsystems have non-obvious internals (gsurf's focus-handoff model, libregnum's
real-time render pipeline, the ai/MCP tool bridge). Read `doc_org/cmacs/*.org` and the
relevant memory file (e.g. `gsurf-embedding.md`) before touching them.

## Critical invariants (breaking these causes non-deterministic crashes)

**GLib event loop.** cmacs does NOT replace Emacs's event loop — `cmacs-glib-loop.c` hooks
Emacs's `pselect()` in `process.c` (`cmacs_glib_prepare` before, `cmacs_glib_dispatch`
after). GLib callbacks may eval Lisp, and Emacs's `signal_or_quit` aborts if
`waiting_for_input` is true during a Lisp error. `cmacs_glib_dispatch` MUST clear
`waiting_for_input` before dispatch and restore it after — else `Fatal error 6: Aborted`.
(`g_main_context_iteration` via `cmacs-glib-iteration` bypasses this guard — only call it
when you know Emacs is not in input-wait.)

**Static library dedup.** crispy/yaml-glib objects are vendored in several archives,
possibly from different commits. `src/Makefile.in` strips duplicate objects from downstream
archives before linking. **NEVER use `-Wl,-z,muldefs`** — it silently picks one impl →
ABI mismatch → non-deterministic crashes.

**GC roots.** A `Lisp_Object` stored in GLib-allocated memory needs GC protection
(`staticpro` or specpdl); otherwise GC crashes.

## Stale Elisp cache pitfall (#1 cause of "my change isn't working")

Emacs prefers `.elc` and native `.eln` over `.el`, and the async native compiler may have
cached a stale intermediate. After editing any `lisp/cmacs/*.el`:

```bash
rm -f lisp/cmacs/CHANGED.elc
rm -f native-lisp/*/CHANGED-*.eln
rm -f ~/.config/emacs/.local/cache/eln/*/CHANGED-*.eln ~/.config/emacs/eln-cache/*/CHANGED-*.eln
```

Verify with `(locate-library "NAME")`. When in doubt: `rm -rf native-lisp/ lisp/cmacs/*.elc`.
If you also changed C DEFUNs, force a relink (see Rebuild rules).

## Documentation

Maintained in two formats that must stay in sync — **update both**:
`doc_org/cmacs/*.org` (interactive, primary) and `doc/cmacs/cmacs.texi` (Info manual).

## Code style

- GNU Emacs C conventions (see `CONTRIBUTE`); `/* */` comments only, no `//`.
- Lisp DEFUN names `cmacs-`; C public `cmacs_`, internal `static`.
- Commits: Conventional Commits with scope (`feat(gowl):`, `fix(bacon):`, `docs:`);
  message lines < 78 chars (hook-enforced).
- License: AGPL-3.0-or-later on cmacs files.

## Testing

`make -C test check-cmacs` — ERT tests, one file per subsystem in `test/cmacs/`.

## Debugging crashes

`coredumpctl dump --output=/tmp/emacs-core`, then launch the gdb-debugger agent
(`.claude/agents/gdb-debugger.md`) — it knows Lisp_Object decoding and cmacs internals.
Common patterns: SIGABRT in `signal_or_quit` → `waiting_for_input` guard; varying
backtraces → static-lib duplicate symbols; GC crash → unprotected Lisp_Object in GLib memory.

## Agent/tooling gotcha

**`pkill`/`grep` exit-1 cancels the whole Bash tool batch** (set -e-like behavior): append
`|| true`, end build/process scripts with `exit 0`, and run build/kill/verify as one Bash
call per message so an exit-1 can't nuke sibling calls. Process-killing steps also need
`dangerouslyDisableSandbox: true`.

## Android APK build

Containerized (`podman`/`docker`), two paths:
- `just android-repack` (recommended) — repackages upstream Po Lu's prebuilt APK with our
  Doom bundle. Works around a libhwui-mutex crash the from-source build hits on
  Samsung Fold 5 / Android 16.
- `just android-build` — cross-compile from source (`Containerfile.android`); crashes on
  Fold 5, kept for hacking Emacs C internals.

Helpers: `just android-image` / `-deviceinstall` / `-logcat-snapshot` / `-addr2lib`.
First on-device run: `M-x doom-sync` once. No native-comp on Android.
Details in `build-aux/android-*.sh` and the manual.
