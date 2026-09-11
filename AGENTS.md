# cmacs — GNU Emacs with GLib/GObject/Wayland integration

This is a personal fork.  LLM-assisted code, documentation, reviews, and
planning are welcome here.  Implement requested changes and run relevant
checks, respecting any more specific instructions in subdirectories.

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
- **Every new `--with-cmacs-<name>` / `--enable-cmacs-<name>` option MUST also add an
  `IS-CMACS-<NAME>` flag** in `cmacs/core/cmacs-features.c` — a literal `DEFVAR_BOOL`
  (make-docfile parses it textually, so no macro wrapper), the lower-case
  `is-cmacs-<name>` alias, and a `cmacs_feature_names[]` entry, all under the same
  `#ifdef HAVE_CMACS_<NAME>`. That file is the single source of truth for "what's
  compiled in" (see *Feature flags* below). Keep it in sync when adding/removing/renaming
  a configure option — the D-Bus instance list and `cmacs.el` derive from it.
- **Every new `--with-cmacs-<name>` / `--enable-cmacs-<name>` option MUST be added to the
  DEFAULT build**, not merely defined in `configure.ac`. cmacs ships with the full feature
  set on by default, so a new flag has to be inserted everywhere the default flag set is
  enumerated — otherwise the feature silently never builds in CI, containers, or a normal
  `just` build. The canonical locations (add the flag next to the other `--with-cmacs-*`
  entries in each): `Containerfile` (the `./configure` line), `Justfile`
  (`configure_flags :=` — the single source of truth for every `just` recipe incl.
  `just bootstrap`), `README.org` (both `./configure` blocks **and** the per-flag bullet
  list), this `AGENTS.md` (the *Build* `./configure` block **and** the *Subsystems* table),
  `doc/cmacs/cmacs.texi` (the configure `@example`), and `doc_org/cmacs/build.org` (the
  configure example **and** the *Configure Flags* table). Grep for the previous flag you
  added (e.g. `--with-cmacs-vidstudio`) to find every spot.

Current upstream touch-points (keep minimal): `process.c` pselect hooks (GLib loop),
`src/pgtkterm.c` paint hooks (video / libregnum / ink overlays), `src/emacs.c` early
`main()` hooks (`--bacon` / `--gowl` entry, JSC GC-signal redirect) plus the guarded
`syms_of_/init_cmacs_*` block (which now also makes one unconditional
`syms_of_cmacs_features ()` call), `src/lisp.h` (cmacs `syms_of_*` prototypes),
`src/comp.c` (`F_RELOC_MAX_SIZE` raised to 8192; `load_comp_unit` publishes a unit only
*after* the ABI-hash check, so a stale `.eln` is an error every time instead of a
segfault on the second load),
`src/Makefile.in` (linking; `CMACS_CORE_OBJ` always links `cmacs-features.o`). Each hunk
is marked `/* CMACS: ... */`; the full catalogue with rationale is
`doc_org/cmacs/cmacs-upstream-changes.org` (and the *Upstream Changes* chapter in the manual).

## Build

From a fresh clone, `just bootstrap` is the whole thing — it runs `install-deps`
(system packages), `admin/cmacs-submodules.sh`, `autogen`,
`configure` with the flag set below, `clean-stale-lisp`, and `make`. It is
idempotent, so re-running it on a built tree is cheap. Distro detection reads
`ID` then `ID_LIKE` from `/etc/os-release` (so Omarchy/CachyOS/Nobara/Pop!_OS
derivatives work), then falls back to whichever package manager is on `PATH`.
Versioned package names (`wlroots0.20` — Arch has no unversioned `wlroots`;
`libwlroots-0.NN-dev`; `libgccjit-NN-dev`) are probed against the local index,
never hard-coded, and an unknown name is skipped with a warning rather than
aborting the whole transaction. **`just check-deps` (`./install-deps --check`)
reports every unsatisfied build dep at once** — use it instead of rebuilding to
discover them one at a time. The package step is the only part needing sudo;
`CMACS_SKIP_INSTALL_DEPS=1 just bootstrap` skips it for CI/immutable hosts.

The steps by hand:

```bash
./install-deps            # system deps (Fedora, Ubuntu, Arch, macOS, FreeBSD)
./autogen.sh              # first time only
./configure --with-pgtk --with-cairo --with-dbus --with-harfbuzz \
            --with-modules --with-native-compilation=aot \
            --with-tree-sitter --with-xwidgets \
            --with-cmacs-glib --with-cmacs-gi ... --with-cmacs-gnuseye \
            --with-cmacs-roamgraph \
            --with-cmacs-secondbrain \
            --with-cmacs-office \
            --with-cmacs-lrgscript \
            --with-cmacs-screensaver --with-cmacs-gsurf --with-cmacs-emacsctl \
            --with-cmacs-lrgterm --with-cmacs-imgedit \
            --with-cmacs-vidstudio --with-cmacs-transcode \
            --with-cmacs-transcribe \
            --with-cmacs-calculator \
            --with-cmacs-lsp \
            --with-cmacs-dbexplorer \
            --with-cmacs-clawtilla \
            --with-cmacs-ai-brigade \
            --enable-cmacs-cpatch \
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

**`gowl-stop` and what the compositor owns.** gowl's compositor only *borrows* its config and module manager, so cmacs hands its references to the compositor as object data on both launch paths (`cmacs_gowl_hand_over_config_and_modules`, called by `Fgowl_start` and the `--gowl` branch of `main()`); they are released at the end of the compositor's finalization, in gowl's `main()` order. Never free them separately in `gowl-stop`: `gowl-compositor` gives Lisp a strong reference, and an uncollected wrapper keeps the compositor alive past `gowl-stop`, to be finalized later against whatever was freed. `gowl-stop` dispatches every module's shutdown hook while the compositor is alive, then resets cmacs's per-compositor statics in `cmacs_gowl_forget_compositor_state` — add any new ones there, or the next `gowl-start` inherits them (stale clipboard handler ids made `gowl-clipboard-watch` connect nothing). `test/cmacs/cmacs-gowl-tests.el` runs real headless start/stop cycles in a child cmacs.

**Rebuild rules**
- After C source in `cmacs/`: `make -j$(nproc)`.
- After `configure.ac`: **`./autogen.sh`**, then `./configure` again. Bare `autoconf` is
  not enough — it regenerates `configure` against a stale `aclocal.m4`, and the result
  fails in a way that points nowhere near the cause: its compile probes report "no" for
  tests that logged `$? = 0`, it decides gcc is clang, and it dies on the year-2038
  check. `autogen.sh` runs the full `autoreconf -fi`.
- **A new subsystem must `git add src/cmacs-<name>-*.c`.** Those are symlinks created by
  `cmacs-symlinks`, they are tracked, and `gl-stamp` lists them as prerequisites — so
  without them a clean build fails with `No rule to make target 'cmacs-<name>-init.c'`,
  which names the file and not the subsystem.
- **Never `DEFSYM` a name another compiled file already `DEFSYM`s.** `DEFSYM` does not
  look a symbol up, it *creates and interns a new one* — so a duplicate name puts two
  distinct symbols with that name in the obarray and `EQ` against the other one then
  fails everywhere, with no warning and a clean build. `DEFSYM (Qcmacs_bg_image, "image")`
  alongside `xdisp.c`'s `Qimage` stopped every `(image ...)` display spec from matching:
  images silently stopped rendering and their raw data appeared as text. Use the existing
  `Q<name>` (they are all global via `globals.h`). The generated `defsym_name[]` table in
  `src/globals.h` is the authoritative list of what this build actually compiles, and
  `test/cmacs/cmacs-defsym-tests.el` fails on any duplicate in it.
- **Never declare a DEFSYM'd symbol as a `static Lisp_Object`.** make-docfile emits it
  into `globals.h` as a macro, so the declaration expands into a syntax error *reported
  in globals.h* — the file that caused it is not mentioned.
- After temacs-linked objects: the pdumper image regenerates automatically.
- **`make` may not relink** after C changes (incomplete deps) — force with
  `rm -f src/temacs && make -j$(nproc)`.
- After Elisp in `lisp/cmacs/`: clean compiled caches — see *Stale Elisp cache* below.

## Build warnings

**A full rebuild produces a known 188 warnings** (as of 2026-08-23, GCC 16).
The build has `--enable-gcc-warnings`, so the bar is zero *new* ones — anything
past this baseline is yours. Before claiming a clean build, get a real inventory:

```bash
touch src/config.h && make -j$(nproc) 2>&1 | grep -oE '\[-W[a-z=-]+\]' | sort | uniq -c | sort -rn
```

**An incremental `make` recompiles almost nothing, so it proves nothing about
warnings.** That is how ~350 of them accumulated unnoticed: every routine build
was a near no-op and looked clean. `touch src/config.h` forces the full pass.

**What is left, and why it is left:**

| Count | Warning | Why it stays |
|-------|---------|--------------|
| 124 | `-Wuseless-cast` | From gnulib's `manywarnings` set, not a cmacs choice. Many are deliberate portability documentation — `(EMACS_INT)` on a `glong`, `(int)` on a `pid_t` for `%d` — that are only useless on LP64. Deleting them is a house-style decision, not a bug fix. |
| 30 | `-Wdouble-promotion` | Same origin. libregnum is float-throughout and promoting to `double` for `printf`/`math.h` is the normal thing. |
| 24 | tail | `-Wmisleading-indentation`, `-Wmissing-prototypes` and `-Wmissing-variable-declarations` in the `--lrg`, dbus and cintrospect files, some unused locals, plus advisory `-Wsuggest-attribute` on DEFUNs that always `xsignal` (a DEFUN's signature is fixed by the macro, so `noreturn` cannot be added). Individually fixable; nothing here is load-bearing. |
| 10 | not ours | 7 upstream Emacs (two deprecated WebKit calls in `xwidget.c`, `-Wmaybe-uninitialized` in `lisp.h`, a generated Wayland protocol file) and 3 in deps (`GGML_TENSOR_SIZE` in `ggml.h`). Fixing these means patching upstream or a submodule. |

If you take on `-Wuseless-cast`, do it as its own commit and check each site rather
than sed-ing them away — some are load-bearing on non-LP64 targets.

**Three invariants that keep the fixed classes fixed:**

- **Third-party `-I` becomes `-isystem`.** `configure.ac` rewrites absolute `-I`
  paths in every `CMACS_*_CFLAGS` just before `AC_OUTPUT`, because pkg-config's
  `-I` does not make a directory a system directory and cmacs's warning set was
  landing on json-glib (80 warnings under GCC 16). Only *absolute* paths are
  rewritten — cmacs's own include paths are `$(srcdir)`-relative and must keep
  warning. A new `PKG_CHECK_MODULES` needs its `CMACS_*_CFLAGS` added to that list.
- **`syms_of_`/`init_` live in exactly one header.** The subsystem's *top-level*
  pair is declared in `src/lisp.h`; per-file `syms_of_cmacs_<sub>_<part>` entry
  points are declared in `cmacs/<sub>/cmacs-<sub>.h`. Declaring either in both
  places is `-Wredundant-decls` in every TU that sees both — that was 98 of them.
- **Dep archives must track their source.** A rule with no prerequisites only
  checks that the archive *exists*, which is how a submodule bump left a stale
  `libwhisper.a` linked against new headers with the build exiting 0. Bundled deps
  use `FORCE` and let their own build system decide incrementality.

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
./admin/cmacs-submodules.sh   # NOT a bare `git submodule update --recursive':
                              # the skips are per-repo config a fresh clone lacks

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
| **gowl** | `cmacs/gowl/` | wlroots-based Wayland compositor — full WM control via DEFUNs. Its **bar** (`deps/gowl/src/barkit` + `deps/gowl/modules/bar`) is a plugin host: left/centre/right regions with a centre anchor, dropdown **panels** a plugin *describes* (the host renders, hit-tests, scrolls and navigates them, so a third-party panel is indistinguishable from a shipped one), and **toasts** on the OVERLAY layer that can name a panel — a notification one click from the thing that resolves it. Plugins are a `GowlBarPluginVTable` of plain C functions wrapped by a proxy, loaded from `~/.config/gowl/bar-plugins/` as `.so` or as `.c` compiled through crispy and cached; the vtable form is the only one that hot-reloads, because a GType cannot be unregistered. Colours are theme *roles* resolved from the session palette — a shipped plugin hard-coding hex is a source-guard failure. **Containment is the invariant to protect**: plugins run in-process, so every entry point runs under `gowl_bar_guard_call` (SIGSEGV/BUS/FPE/ILL/ABRT → unwind, quarantine, toast), and a load that kills the session anyway is caught by the journal at `$XDG_STATE_HOME/gowl/bar-plugins.journal` — without it the next start loads the same plugin and crashes again. `docs/bar.org` |
| **podomation** | `cmacs/podomation/` | Event-driven automation engine — DSL + REPL |
| **libreclaw** | `cmacs/libreclaw/` | Chat gateway: **embedded** (in-proc LcApp, shared PodEngine) + **remote** (dial-out bridge that tunnels cmacs's MCP server to a remote agent) |
| **ai-brigade** | `cmacs/ai-brigade/` + `lisp/cmacs/` | The AI **fabric**: the layer other subsystems and user config lay on top of for AI capability, agent orchestration, and memory. Primary deliverable is the *extension surface* — one `cmacs-brigade-deftool` form in `init.el` publishes a capability to in-process HTTP agents, CLI agents (claude-code/opencode) over an `emacs --mcp-relay` MCP bridge that talks to a per-agent **scoped socket** (`cmacs-brigade-scope-open`, the allowlist enforced server-side by the C gate; the relay is defence in depth and filters resources/prompts too), **and** external MCP clients. Every string an RPC surface splices into generated Lisp goes through `cmacs_dispatch_lisp_escape` (never `g_strescape`, whose octal escapes the reader turns into raw bytes), and the expression is `read` inside the condition-case. Public registries for tools/agents/workers/isolation/memory-sources/deliverables/panels; shipped features use the same API (no private back doors). Also: flat mmap'd fp16 memory index over the notes repo (runtime F16C dispatch + scalar fallback), org-file-as-plan model (C owns runtime, org owns intent), dashboard, GenMail, deliverable generators. Requires `--with-cmacs-ai`; libreclaw optional. In the default flag set |
| **ai** | `cmacs/ai/` | Coding-agent surface over `ai-glib`: 13 providers (incl. `codex-cli` and `openai-compatible`; user-named servers live in `cmacs-ai-openai-compatible-endpoints` and are providers in every sense — one symbol→type table in `cmacs-ai-config.c`, shared by client/stream/harness, because three copies is how a new provider worked in a chat and not in `prompt-sync`), streaming chat org buffers, region cmds, FIM completion, voice loop, MCP tool bridge, generic tools-capable one-shot calls (`cmacs-ai-call` / C `cmacs-ai--call`, also on D-Bus `Ai.Call` / `emacsctl ai call` / MCP `ai_call`) (`deps/ai-glib`, shared with libreclaw). `lisp/cmacs/cmacs-ai-view.el` is the shared "what is on the user's screen" layer — visible buffers minus the AI surfaces — used by the chat system prompt, both libreclaw send paths, and the `current_view` MCP tool; it is a hint plus an inventory, never the buffer text, because a tool-capable model fetches what it needs. `cmacs-ai-output.el` keeps its session past `finish` so every action routed through `cmacs-ai-textops-stream` gets follow-ups (`C-c C-c`) and promote-to-chat (`C-c C-p`); its answer is sealed with a `read-only` TEXT PROPERTY, not a `before-change-functions` guard — Emacs clears that hook when a function on it signals, so a guard protects a buffer exactly once. The same seal now protects `cmacs-ai-chat` and `cmacs-libreclaw` transcripts (`--seal-history`, applied at turn boundaries, guard re-armed each time), and `cmacs-ai-harness--read-only-props` gained `front-sticky` — `rear-nonsticky` alone permits insertion in the MIDDLE of a read-only run |
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
| **roamgraph** | `cmacs/roamgraph/` + `lisp/cmacs/` | Native org-roam knowledge-graph visualiser, the in-editor `org-roam-ui` replacement. `M-x cmacs-roamgraph` (2D) / `-3d`. Force-directed layout (Fruchterman–Reingold + Barnes–Hut) in a **pure-C** TU class (no `lisp.h`, no `<libregnum.h>`) so the solver is headless-testable; scene half is the only TU seeing libregnum. Data is Elisp-owned: reads `org-roam.db` directly via Emacs's builtin SQLite (**no `org-roam` package dependency**; values are emacsql-prin1'd and must be unwrapped; only `type = '"id"'` links become edges), with a native `:ID:`/`[[id:]]` C scanner fallback and optional ai-brigade similarity edges. Two navigation tiers: `hjkl` spatial (screen-space cone), `[`/`]`/`<`/`>` link-topological over a breadcrumb trail. All Lisp state keys on the org-roam UUID (scene node ids churn on rebuild). Requires `--with-cmacs-libregnum`; in the default flag set |
| **secondbrain** | `cmacs/secondbrain/` + `lisp/cmacs/` | The **ARMS** second-brain visualiser: an agentic workspace as four concentric rings (Applications / Routines / Memory / Skills) around a centre. Sibling of roamgraph, not a mode of it — either builds without the other; both link `cmacs/graphcore/` (the shared store, solver, closed-form layouts, tweening and hierarchical collapse), so an engine improvement lands in both. Data is an Elisp **source registry** (a ring member is a registration, not a patch); ships providers for the Claude workspace *and* cmacs-native equivalents, and a failing source costs one ring member rather than the map. Memory is **PARA**-grouped via `lisp/cmacs/cmacs-para.el` (also shared with roamgraph, and the fix for the `~/org` vs `~/Documents/notes` root disagreement that made PARA colouring silently inert). Departments arrive collapsed and expand animated — 35k files cannot be 35k spheres. Search is three tiers cheapest-first (substring → embeddings → `sim` edges, which finally give roamgraph's long-unused edge kind a caller). `M-x cmacs-secondbrain` / `-3d`. **Ingest** (`lisp/cmacs/cmacs-secondbrain-ingest*.el`, the port of the `sbi` shell script): any file/URL/media/mail/text → one Org roam node (`:ID:`, header keywords, AI summary, content, `* See also` by similarity, `00_index.org` bullet), placed by explicit PARA, or by the model against the REAL tree with filesystem validation and an inbox fallback. Every stage async (sentinels/callbacks/streams) because D-Bus+MCP dispatch on the compositor thread; default model `claude-code`/`sonnet` run in a project-free cwd with `--exclude-dynamic-system-prompt-sections` (a CLI started in the repo answers as a coding agent; `--bare` would help but also skips the login). Surfaces: `emacsctl sb` (aliases `second-brain`/`secondbrain`), `org.cmacs.Editor1.SecondBrain`, `secondbrain_ingest*` MCP tools, brigade tools, `/ingest` + `C-c C-b` in cmacs-ai chat (`cmacs-ai-ingest.el`, via `cmacs-ai-chat-slash-command-functions`), a drop folder (`file-notify` watch mode + a generated podomation `inotify_event` rule), in-place Markdown migration (`-migrate.el`, plans by default), and incremental brigade re-index after each note (`cmacs-brigade-memory-update-files` over `cmacs-brigade-index-writer-copy`). In the default flag set |
| **office** | `cmacs/office/` | Native OOXML + OpenDocument: `.docx`/`.xlsx`/`.pptx` + `.odt`/`.ods`/`.odp` as structured editable packages (all six are zip-of-XML — OPC vs ODF package). Factors into one container + three document models + six thin codecs, so a 7th format is one codec. **The shadow-package invariant is the thing to protect**: every part of the original is kept, only mutated parts are rewritten, so unparsed features (SmartArt, macros, OLE, charts, signatures) survive edits untouched — that is what makes partial schema coverage safe. libzip specifically, because it copies untouched members through *without re-deflating* (same bytes, same CRC, same method — verified by the round-trip ERT gate over all six formats). Deferred writes: a save with nothing queued is a no-op, so byte-identity is structural. ODF `mimetype` is refused for rewrite (would move it last + deflate it). Part names validated against traversal; inflated-size caps bound zip bombs (these arrive as mail attachments). TU split: `-zip.c` sees no `lisp.h`, `-defuns.c` never sees `zip.h`; handles are integers, never `Lisp_Object` in GLib memory. Needs `libzip` + `libxml2`; LibreOffice optional/never authoritative, found via PATH **or flatpak** (`--command=libreoffice`, *not* `soffice`). In the default flag set |
| **lrgscript** | `cmacs/lrgscript/` | Emacs Lisp as a first-class libregnum scripting language — *only* in cmacs. An `LrgScripting` subclass (`CmacsLrgScriptingElisp`) routes load/call/get/set into the live Elisp VM via the `cmacs-eval-dispatch` `waiting_for_input` guard; registered with libregnum's scripting manager (`LRG_SCRIPT_LANGUAGE_ELISP`) through a generic runtime hook, so libregnum ships **no** elisp runtime. Node scripts (`lrg-script-start/update/detach`), plus a full game-authoring layer (`CmacsLrgScriptGame : LrgGameTemplate` + declarative scene DSL) so a complete game can be written from `init.el`. `cmacs-lrgscript-*` DEFUNs; headless-testable. In the default flag set; requires `--with-cmacs-libregnum` + `--with-cmacs-glib` |
| **lrgterm** | `cmacs/lrgterm/` | `output_lrg`: independent libregnum/raylib **Emacs display backend** (peer to tty/pgtk) that renders the whole UI via libregnum. Opt-in `emacs --lrg[=SPEC]`: 2d (flat) and 3d (frame/windows as textured panels in a real-time scene — `--lrg=3d:per-window:workshop`, runtime-switchable arrangements/environments + camera via `C-c 3`); 3dvr reserved. Reuses Emacs FreeType/HarfBuzz for text via a GPU glyph-atlas. Off by default |
| **screensaver** | `cmacs/screensaver/` | Renders `deps/screensavers` libregnum game-modules (17 of them: blackhole/nebula/aurora/galaxy/wormhole/…) as animated **gowl wallpaper**, **lock-screen background**, **libregnum scene background** (the `TEXTURE` sink: frames are *pulled* by an in-process consumer instead of pushed to gowl, so it needs no compositor — libregnum takes a generic `CmacsLibregnumFrameSource` fn-ptr and the coupling lives here, in the optional subsystem) (`gowl-lock` integration), or **in-buffer** playback. Wallpaper/lock render **out-of-process** (`cmacs-screensaver-render`, its own GL context — no main-thread lag, no EGL/GLX conflict; a *process* not a thread because raylib's GL context is shared): control over a SEQPACKET-JSON socketpair, frames over a sealed-memfd seqlock ring (`SCM_RIGHTS`), supervised (crash-restart/backoff/watchdog/PDEATHSIG). Emacs pushes raw ARGB8888 frames into gowl's frame-sink — **gowl never links libregnum** (guard-tested; child links no Emacs objects). Named configs + picker + status/restart/pause/resume/set-fps on all surfaces; off by default |
| **imgedit** | `cmacs/imgedit/` | 2D image / sprite editor on libregnum's `LrgImageDocument`/`LrgImageLayer` (CPU layer compositor: opacity, blend modes, offset, undo). DEFUN model layer (`cmacs-imgedit-*`, handle-based, MCP/headless-driveable) + `cmacs-imgedit-mode` (native-image display + mouse painting; in-engine GL viewport is a planned follow-on). Off by default (`--with-cmacs-imgedit`; needs libregnum) |
| **vidstudio** | `cmacs/vidstudio/` | Video editor on libregnum's Reel system (each track = an `LrgReelTransitionSeries` of clip segments). DEFUN model layer (`cmacs-vidstudio-*`: tracks/clips/transitions/effects/split/trim/move/ripple, CPU render, ffmpeg export) + `cmacs-vidstudio-mode` (native-image preview + playhead/transport; in-engine timeline strip is a planned follow-on). ffmpeg-binary backed; the `LrgVideoPlayer` libav backend (`FFMPEG=1`) gives smooth scrub. Off by default (`--with-cmacs-vidstudio`; needs libregnum) |
| **transcode** | `lisp/cmacs/` | Native batch video/audio transcoder mirroring the `compress_video`/`compress_audio` scripts. Pure-Elisp (no C): spawns ffmpeg in a podman/docker `linuxserver/ffmpeg` container (guaranteed codec set) or a host ffmpeg, managing an Emacs bounded parallel pool itself (no GNU parallel). Interactive queue buffer (`cmacs-transcode-mode`: add files, tune codec/CRF/format/hwaccel/parallel, process-missing/existing) with a live status timer; all knobs are `defcustom`s. Full fidelity incl. VAAPI/Vulkan hwaccel + colour-metadata preservation. Off by default (`--with-cmacs-transcode`) |
| **transcribe** | `lisp/cmacs/` | Native batch speech-to-text sibling of transcode. Pure-Elisp (no C of its own): per file it converts to a transient 16 kHz-mono WAV via `cmacs-transcode`'s ffmpeg backend (the embedded whisper reader only accepts that PCM WAV — it can't decode mp3/ogg/mp4), runs `cmacs-whisper` STT, writes `<input>.txt` (+ optional `.srt`/`.vtt`/timestamped), and optionally summarizes via `cmacs-ai` (async `cmacs-ai-chat-stream`) into a `.org` whose last section is the full transcript. Same bounded parallel pool + queue buffer (`cmacs-transcribe-mode`) as transcode; per-STT CPU-core count is tunable (`cmacs-transcribe-threads`, default 4). Two abnormal hooks (`cmacs-transcribe-after-transcription-functions`/`-after-summary-functions`) fire a rich INFO plist for DB/notes integration. Off by default (`--with-cmacs-transcribe`; needs whisper + a transcode backend) |
| **calculator** | `cmacs/calculator/` + `lisp/cmacs/` | Calculator: desktop, financial (loans/amortization/bonds/Black-Scholes+greeks/tax), physics, relativity, CAS. Engine is **Elisp wrapping GNU Calc** (ships with Emacs) — never edit `lisp/calc/`; the wrapper corrects Calc's defaults, which are wrong for a desktop calculator (`2/3*4`→2/(3·4); degrees; bad input returned *unevaluated* not signalled) via `calc-eval`'s mode-list form + `evalv` + a validation walker. Calculators are `defmath`, so they compose in any expression. C half is small: libregnum GPU charts (a `chart_mode` branch in `cmacs-libregnum-render.c`, guarded `HAVE_CMACS_CALCULATOR_CHART` — **libregnum optional**, SVG tier stands alone) and the `emacs --calc` argv rewrite (it can *not* use the `--bacon` never-return model: the engine is Elisp, so the Lisp VM must be up). Charts work under pgtk **and** `--lrg`. In the default flag set (`--with-cmacs-calculator`) |
| **lsp** | `cmacs/lsp/` + `lisp/cmacs/` | In-binary LSP language servers: `emacs --cmacs-lsp LANG` runs a pure C/GLib JSON-RPC-over-stdio server via the `--bacon` never-return early-main model (no Lisp VM; stdout is protocol-only). Generic core (io/server/document/registry — a `CmacsLspServerOps` vtable per language) + registry that auto-populates `--help` and the bare/unknown `--cmacs-lsp` error listing. First server: **gnucalc** for `.calc` sheets (needs calculator) — completion/hover/signatureHelp/definition/symbols/semanticTokens/lexical diagnostics over `cmacs-lsp-gnucalc-data.h`, **generated** by `admin/cmacs-calc-builtins-catalog.el` (builtins + registry + constants + units; drift-guarded by ERT). Clients call back into the same binary (`cmacs-lsp.el`; eglot auto-start for sheets, native flymake kept authoritative). In the default flag set (`--with-cmacs-lsp`) |
| **dbexplorer** | `cmacs/dbexplorer/` + `lisp/cmacs/` | Database explorer over `deps/orm-glib`: query, browse schema, edit rows, export. Backends resolve by URL scheme through orm-glib's driver registry (SQLite/PostgreSQL/MySQL today; a new one is a driver + a registration, with no change here). TU split enforced: `-conn.c`/`-query.c`/`-schema.c` see `<orm.h>` and never `lisp.h`, `-defuns.c` never sees `<orm.h>`; handles are integers. Read-only is a per-connection flag the C layer enforces, so MCP/brigade/D-Bus inherit it. Row edits stage in Elisp and apply as one C-side transaction with an affected-rows check. Secrets via auth-source, never in the connection alist. Model/view split (`cmacs-dbexplorer-model.el` owns structs, hooks and registries) so extra views — a libregnum 2D/3D one — are additive. In the default flag set (`--with-cmacs-dbexplorer`) |
| **clawtilla** | `cmacs/clawtilla/` + `lisp/cmacs/` | Client for a **clawtilla agent fleet** (`deps/clawtilla`) -- a daemon that runs many libreclaw agents, each with its own persona, model, credentials, integrations and computer. A CLIENT, not an embedded daemon: the normal use is a `clawtillad` already running, on this machine over its unix socket or on another over TCP, so the fleet outlives the editor and the GTK client can watch the same one. Saved profiles are clawtilla's own `connections.yaml`. **There is no synchronous request primitive**: the library's blocking request turns the caller's main context, which here is the editor's and under `--gowl` the compositor's -- `clawt_client_connect_async`/`_subscribe_async` were added upstream for this. Buffers are magit-shaped (collapsible sections, a transient per buffer) with an ement-shaped transcript (read-only, appends, follows the live edge only when already at it). **Nearly every rule is asked of libclawt rather than reimplemented** -- activity sentence, team tally, run/day boundaries, timestamps, alert tiers, the unread rule, tool-run grouping, markdown -- because a sentence assembled in three clients is three sentences; `admin/cmacs-clawtilla-parity.sh` fails the build when this client reaches less of the daemon than the GTK one does. In the default flag set |

The large subsystems have non-obvious internals (gsurf's focus-handoff model, libregnum's
real-time render pipeline, the ai/MCP tool bridge). Read `doc_org/cmacs/*.org` and the
relevant memory file (e.g. `gsurf-embedding.md`) before touching them.

## Feature flags (`IS-CMACS-*`)

`cmacs/core/cmacs-features.c` is **always linked** (even in an upstream-shaped build with
every cmacs feature off) and is the single source of truth for which subsystems were
compiled in. For each `--with-cmacs-<name>` / `--enable-cmacs-<name>` option it defines an
always-bound Lisp variable `IS-CMACS-<NAME>` (= `t` when compiled in, else `nil`) plus a
lower-case `is-cmacs-<name>` alias, so a user config can branch on a feature without a
`void-variable` error, e.g. `(when IS-CMACS-AI (global-set-key (kbd "C-c a a") #'cmacs-ai-call))`.
It also exposes `(cmacs-compiled-features)` (the list of enabled feature symbols); `cmacs.el`'s
`cmacs-feature-p` / `cmacs-features` and the `org.cmacs.Editor1.Instance` D-Bus feature list
both derive from the same `#ifdef HAVE_CMACS_<NAME>` table. **Adding/renaming a configure
option means editing this one file** (see the discipline rule above). make-docfile parses
`DEFVAR_BOOL` textually, so each flag must stay a literal source line — no macro or loop.

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

**`git stash` does NOT revert Elisp behaviour.** `.elc`/`.eln` are gitignored, so
they survive the stash and Emacs still prefers them — a "is this failure
pre-existing?" check done by stashing sources re-runs the exact code it was meant
to rule out, and answers confidently wrong. Bind the feature off
(`(setq cmacs-libreclaw-context-function nil)`), or use a worktree at the older
commit, which has its own build tree.

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

**Test `.elc` files go stale across a rebuild, and lie about it.** The runner
loads `test/cmacs/*.elc` in preference to the `.el` unless `TEST_LOAD_EL=yes`, and
upstream's `%.elc: %.el` rule names only the source — so an object written by an
earlier `src/emacs` stays "up to date" forever. In this tree that is a rebuild
every few minutes. Symptom: a pile of failures in suites you never touched, with
conditions like `void-variable <a macro-defined test symbol>`. `test/Makefile.in`
now lists the byte compiler as a prerequisite (marked `## CMACS:`), so a rebuilt
Emacs recompiles them; **re-run `./config.status test/Makefile` after a merge
drops that hunk**. The manual escape hatch is still `rm -f test/cmacs/*.elc`.

**Known-failing upstream test.** `emacs-tests/seccomp/allows-stdout` dies `SIGSYS`
(exit 159) and is *expected to*: `lib-src/seccomp-filter.bpf` whitelists the
syscalls an upstream-shaped Emacs makes at startup, and cmacs links GLib/wlroots,
whose init reaches outside that set before any Lisp runs. Not a regression, not
worth chasing. To prove any other post-merge failure is likewise pre-existing, run
it against the newest `src/emacs-32.0.50.N` predating the merge — the build keeps
every previous binary there.

## Debugging crashes

`coredumpctl dump --output=/tmp/emacs-core`, then launch the gdb-debugger agent
(`.claude/agents/gdb-debugger.md`) — it knows Lisp_Object decoding and cmacs internals.
Common patterns: SIGABRT in `signal_or_quit` → `waiting_for_input` guard; varying
backtraces → static-lib duplicate symbols; GC crash → unprotected Lisp_Object in GLib memory.

## Agent/tooling gotcha

**NEVER kill by pattern on a developer machine — `pkill -f`, `pkill`, `killall`.** This
host builds immutablue / hyacinth-macaw / kuberblue images concurrently with cmacs, and
their command lines contain `buildah build`, `Containerfile`, `--no-cache` and `:44` —
every pattern specific enough to look safe for a cmacs build matches those too. Record
the PID you started and signal that PID. When hunting a PID, print the candidates for a
human to read before signalling anything. And note that **buildah ignores SIGTERM for a
while**: a `/proc` check immediately after a signal showing `state=S` is NOT proof the
process survived — it can die seconds later, so re-check before reporting.

**`pkill`/`grep` exit-1 cancels the whole Bash tool batch** (set -e-like behavior): append
`|| true`, end build/process scripts with `exit 0`, and run build/kill/verify as one Bash
call per message so an exit-1 can't nuke sibling calls. Process-killing steps also need
`dangerouslyDisableSandbox: true`.

## Container images (build once, install anywhere)

`./build-container [TARGET]` builds a distro image; `./install-from-container` unpacks one
onto a host **and is also the update command**. The point is machines that cannot afford
to build: a 2- or 4-core box takes *hours* from source and about a minute to unpack. The
image is `FROM scratch` holding only `/usr` + `/etc`, which is also how immutablue
consumes it.

- **Updating prunes, and that is the whole reason for the manifest.** The install records
  every path it wrote to `/usr/share/cmacs/container-manifest`; a later run copies the new
  image over the top, then deletes what the previous image had and this one does not.
  Without it a renamed `.so` lingers and `ld.so` keeps loading it — worse than a missing
  file, because everything works until it doesn't. **Copy first, prune second**: a crash
  between them leaves both versions' files (still runs) rather than neither. Only paths
  from our own manifest are deletable, files and symlinks only, never directories.
- **Compatibility is checked against the machine, not the tag.** Comparing the image's
  `distro`/`arch` against its own tag is circular — they always agree — so it can never
  catch an Arch image being unpacked on Fedora. It reads `/etc/os-release`, `uname -m`
  and `VERSION_ID`. `--prefix` skips the check (staging is not installing).
- **Rootless needs `podman unshare`.** `podman mount` fails rootless, which is exactly the
  `--prefix` case; the script re-execs itself once under `podman unshare`. `--local` also
  passes `--pull=never`, since `podman create` otherwise pulls on a missing name.

The target is inferred from its **shape** — `arch`/`archlinux`, `NN.NN` (Ubuntu),
`NN` (Fedora, the default: 44). The Containerfile takes `BASE_IMAGE`, `CMACS_DISTRO`,
`CMACS_RELEASE`; `CMACS_DISTRO` selects the package manager and everything after the
package install is identical, because it is all `make`.

- **An opportunistic `apt-get install` must pass `--no-remove`.** Everything after
  the main install in the Debian branch may be absent on a given release, so failure
  is swallowed with a `NOTE` — which means apt is also free to satisfy one by
  *deleting* packages the main install already put there, invisibly. On 26.04
  `libmariadb-dev` conflicted with the `libmysqlclient-dev` that
  `libocct-data-exchange-dev` pulls in via VTK and GDAL; apt removed six packages
  including the OCCT headers, and cad-glib failed on `IGESControl_Reader.hxx` six
  thousand log lines later. Probe with `pkg-config` before asking for a package that
  something else may already have satisfied. Same rule in `install-deps`, more so —
  that one runs on a workstation.
- **No `#` comments inside a `RUN`.** Continued lines are joined, so a comment
  swallows the rest of the command. Put the explanation above the instruction.
- **Per-distro package lists live in the Containerfile**, deliberately — a container
  needs `curl`/`git`/`ca-certificates` a dev box already has, and not the dev extras.
  `install-deps` stays the source of truth for the *host* question, which is what
  **`./install-deps --packages [PLATFORM]`** answers (`just deps-list [PLATFORM]` wraps
  it): one paste-ready install command on stdout, all commentary on stderr, and it needs
  no configured tree — the machine that needs the list is the one that cannot build yet.
  Deliberately NOT a make target: a target defined before `include Makefile` in
  `GNUmakefile` becomes make's **default goal**, so a bare `make` stopped building Emacs
  and printed a package list, exiting 0 as though the tree were up to date.
- **Ubuntu 24.04 builds wayland/wayland-protocols/pixman/wlroots from source** (noble has
  wlroots 0.17 / wayland 1.22 / pixman 0.42). The probe is on `pkg-config`, not the distro
  version, so a release that catches up takes the fast path with no edit. Two silent traps
  guarded there: (a) `--libdir` must be the **multiarch triplet** — installing to
  `/usr/lib` does not shadow the distro's, `/usr/lib/<triplet>/pkgconfig` is searched
  first and meson reports "found 1.22.0" with 1.23.1 sitting right there; (b) each
  component installs **twice**, once into the builder and once into a scratch `DESTDIR`
  whose *libdir alone* is staged — a library only in the builder is not in the image, and
  the result links 1.23 symbols and lands on a 1.22 host. Headers are deliberately not
  staged.
- **`/usr/share/cmacs/container-release`** records distro/release/libdir/arch/version/
  `bundled_wayland`. `install-from-container` refuses a mismatched distro or arch (`--force`
  overrides), because those binaries are linked against that distro's libraries and the
  failure otherwise surfaces much later as an unresolved symbol.
- **The libdir in `/etc/ld.so.conf.d/cmacs.conf` is read off the staged tree**, never
  hardcoded — Fedora/Arch `/usr/lib64/cmacs`, Debian/Ubuntu `/usr/lib/<triplet>/cmacs`. A
  wrong path is silent: `ldconfig` happily caches a directory that does not exist.
- **A `for dep in ...` loop takes the exit status of its LAST iteration.** A dep whose
  `make install` failed mid-loop left the build green for a long time (that is how gowl's
  broken `install-headers` went unnoticed). Every step in that loop now `|| exit 1`s.
- **A dependency with two coexisting versions only ever exercises the newer one here.**
  gowl picks the newest wlroots present, so a box with 0.19 *and* 0.20 never compiles the
  0.19 path — and 0.19 differs: its `wlr/` headers `#include "<proto>-protocol.h"` by bare
  name (the consumer must run wayland-scanner), while 0.20 uses a shipped
  `<wayland-protocols/…-enum.h>`. Fedora 43 is 0.19-only and could not build gowl at all.
  Same shape with libeis: `EIS_EVENT_SEAT_DEVICE_REQUESTED` is 1.6-only, F43 has 1.5.
  Both are now pkg-config-probed, and `deps/gowl/tests/test-protocol-headers.sh` checks
  **every installed** wlroots version rather than the selected one — checking the selected
  one would reproduce the blind spot. `make WLROOTS=0.19` in `deps/gowl` builds the older
  path locally, which is vastly cheaper than finding out inside a container.

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
