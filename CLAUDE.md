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
            --with-cmacs-gsurf --with-cmacs-emacsctl --with-cmacs-lrgterm \
            --enable-cmacs-cpatch  # full flag set: README.org
make -j$(nproc)           # builds deps + emacs
just run                  # run it
```

cmacs features are all `--with-cmacs-*` / `--enable-cmacs-*`, auto-detect system
packages, and fall back to bundled `deps/` submodules. `just run` is preferred over
`src/emacs`: it exports `CMACS_MODULE_DIR` (bacon `cmacsgi`) and `CMACS_GSURF_MODULE_DIR`
(gsurf modules). Bare `src/emacs` is fine for plain editing.

**Rebuild rules**
- After C source in `cmacs/`: `make -j$(nproc)`.
- After `configure.ac`: `autoconf`, then `./configure` again.
- After temacs-linked objects: the pdumper image regenerates automatically.
- **`make` may not relink** after C changes (incomplete deps) — force with
  `rm -f src/temacs && make -j$(nproc)`.
- After Elisp in `lisp/cmacs/`: clean compiled caches — see *Stale Elisp cache* below.

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
