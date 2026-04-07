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
  --with-cmacs-org-ex
make -j$(nproc)           # builds deps + emacs
src/emacs                 # run it
```

- Dependencies under `deps/` (crispy, bacon, gowl) are git submodules — `configure` falls back to bundled builds when system packages aren't found
- After modifying C source in `cmacs/`, just `make -j$(nproc)` from the top level
- After modifying `configure.ac`, run `autoconf` then `./configure` again
- After touching temacs-linked objects, the pdumper image is regenerated automatically
- Native-compiled .eln files cache by ABI hash — if you see stale-code behavior, `rm -rf native-lisp/`

## Architecture

cmacs integrates six subsystems into Emacs as C primitives (DEFUNs):

| Subsystem | Directory | What it does |
|-----------|-----------|--------------|
| **glib** | `cmacs/glib/` | GMainContext event loop integration, D-Bus service, safe Lisp eval dispatch |
| **gobject** | `cmacs/gobject/` | GObject ↔ Lisp bridge, GClosure wrappers |
| **gi** | `cmacs/gi/` | GObject Introspection — call any GI-registered library from Elisp |
| **api** | `cmacs/api/` | Shared C library: transport, eval helpers, high-level config API (libcmacs-api.so) |
| **crispy** | `cmacs/crispy/` | Embedded scripting language (C-like, GObject-based) |
| **bacon** | `cmacs/bacon/` | Embedded shell (fork-of-self `--bacon` mode, socketpair IPC) |
| **gowl** | `cmacs/gowl/` | Wayland compositor (wlroots-based) — 47 DEFUNs for full WM control |
| **org-ex** | `cmacs/org-ex/` | Interactive widget embedding for Org mode (liborgex-1.0.so) |

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
  org-ex/           Org-Ex interactive widgets (liborgex-1.0.so + DEFUN bridge)
  compat/           Compatibility shims
  cmacs.h           Master header
deps/               Git submodules (crispy, bacon, gowl)
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
- **org-ex**: builds `liborgex-1.0.so` from `cmacs/org-ex/lib/` (requires glib)

## Testing

```bash
make -C test check-cmacs    # run all cmacs ERT tests
```

Test files in `test/cmacs/`: one per subsystem (`cmacs-glib-tests.el`, `cmacs-bacon-tests.el`, `cmacs-gi-tests.el`, `cmacs-gobject-tests.el`, `cmacs-gowl-tests.el`, `cmacs-crispy-tests.el`, `cmacs-config-tests.el`, `cmacs-org-ex-tests.el`).

## Debugging Crashes

cmacs has a GDB debugging agent (`.claude/agents/gdb-debugger.md`) that uses the `gdb-mcp-server` for post-mortem core dump analysis. For crash debugging:

1. Extract core dump: `coredumpctl dump --output=/tmp/emacs-core`
2. Launch the gdb-debugger agent — it knows cmacs internals, Lisp_Object decoding, and common crash patterns

### Common crash patterns

- **SIGABRT in `signal_or_quit`**: `waiting_for_input` was true during GLib callback Lisp evaluation. Check the guard in `cmacs_glib_dispatch`.
- **Non-deterministic crashes with varying backtraces**: Duplicate symbols from vendored static libraries. Check the dedup logic in `src/Makefile.in`.
- **GC crashes**: A `Lisp_Object` stored in GLib-allocated memory without GC protection (`staticpro` or specpdl).

## Known Issues / Gotchas

- The pdumper image must be regenerated after changes to temacs-linked code — `make` handles this, but stale dumps cause confusing runtime errors
- Native compilation .eln cache is keyed by ABI hash — version mismatches cause silent fallback to byte-compiled code
- `g_main_context_iteration` in `cmacs-glib-iteration` does NOT go through the `waiting_for_input` guard — only use it from Lisp code that knows Emacs is not in input-wait state
- bacon `--bacon` mode forks the emacs process itself — `fork()` safety constraints apply (no threads before fork)
