# cmacs — task runner.
# Run `just`        to list grouped recipes.
# Run `just c`      to fuzzy-select one interactively.
# Run `just <name>` to invoke directly.

set shell      := ["bash", "-euo", "pipefail", "-c"]
set positional-arguments
set dotenv-load := false

# ──────────────────────────────────────────────────────────────────────
# Variables (override with: just emacs="..." <recipe>)
# ──────────────────────────────────────────────────────────────────────

emacs       := "./src/emacs"
emacs_args  := ""
jobs        := `nproc`

# Note: the WebKit/JSC GC-signal redirect off SIGUSR1 (so podomation's
# on_sigusr1, libreclaw's thread dump and Emacs's [sigusr1] keep working)
# is now done in C, at the top of main() via JSConfigureSignalForGC() --
# see src/emacs.c and doc_org/cmacs/cmacs-gsurf.org.  No launch-env var is
# needed (and the JSC_SIGNAL_FOR_GC env var is avoided on purpose: JSC's
# option parser rejects it with "ERROR: invalid option").
gowl_dir    := "deps/gowl"

# Android build settings.  Override per-invocation:
#   just android_image_tag=foo:dev android-build
android_image_tag  := "cmacs-android:latest"
android_doom_core  := env_var_or_default('CMACS_DOOM_CORE',    env_var('HOME') + "/.config/emacs")
android_doom_priv  := env_var_or_default('CMACS_DOOM_PRIVATE', env_var('HOME') + "/.config/doom")
android_out_dir    := justfile_directory() + "/build/android-out"
android_abi        := env_var_or_default('CMACS_ANDROID_ABI', "aarch64")
# `podman` by default; set to `docker` if you don't have podman.
container_runtime  := env_var_or_default('CMACS_CONTAINER_RUNTIME', "podman")

# Full configure-flag set lifted from CLAUDE.md so we never forget one.
# Mirrors the recommended dev build: pgtk + native comp + every cmacs
# subsystem.  Override an individual flag by editing here, or pass
# extras via `just configure-extra <flags>`.
configure_flags := """
    --with-pgtk
    --with-cairo
    --with-dbus
    --with-harfbuzz
    --with-modules
    --with-native-compilation=aot
    --with-tree-sitter
    --with-sqlite3
    --with-json
    --with-rsvg
    --with-jpeg
    --with-png
    --with-gif
    --with-tiff
    --with-webp
    --with-xpm
    --with-gpm=no
    --with-xwidgets
    --with-cmacs-glib
    --with-cmacs-gi
    --with-cmacs-crispy
    --with-cmacs-bacon
    --with-cmacs-gowl
    --with-cmacs-podomation
    --with-cmacs-libreclaw
    --with-cmacs-ai
    --with-cmacs-org-ex
    --with-cmacs-mcp
    --with-cmacs-print
    --with-cmacs-video
    --with-cmacs-audio
    --with-cmacs-whisper
    --with-cmacs-piper
    --with-cmacs-cintrospect
    --with-cmacs-libregnum
    --with-cmacs-gnuseye
    --with-cmacs-gsurf
    --enable-cmacs-cpatch
"""

# ──────────────────────────────────────────────────────────────────────
# Default + helpers
# ──────────────────────────────────────────────────────────────────────

# List grouped recipes.
[group('meta')]
default:
    @just --list --unsorted --list-heading $'cmacs task runner\n\n'

# Alias: list (kept for muscle memory).
[group('meta')]
list:
    @just --list --unsorted

# Fuzzy-select a recipe (requires fzf).
[group('meta')]
c:
    @just --choose

# Print the resolved configure-flag set (useful when copy-pasting).
[group('meta')]
show-configure-flags:
    @echo "{{ configure_flags }}" | tr -s ' \n' ' ' | sed 's/^ //; s/ $/\n/'

# ──────────────────────────────────────────────────────────────────────
# Bootstrap & build
# ──────────────────────────────────────────────────────────────────────

# Run autogen.sh.  Required after editing configure.ac.
[group('build')]
autogen:
    ./autogen.sh

# Run ./configure with the canonical cmacs flag set (extra args appended).
[group('build')]
configure *EXTRA:
    #!/usr/bin/env bash
    set -euo pipefail
    flags=$(echo "{{ configure_flags }}" | tr -s ' \n' ' ' | sed 's/^ //; s/ $//')
    echo "==> ./configure $flags $@"
    ./configure $flags "$@"

# Initial setup from a fresh clone: autogen + configure + build.
[group('build')]
bootstrap: autogen configure build

# Build cmacs (auto-detects parallelism).
[group('build')]
build:
    make -j{{ jobs }}

# Build with a single job, useful when chasing a specific compiler error.
[group('build')]
build-serial:
    make

# Build the gowl submodule only (release).
[group('build')]
build-gowl:
    make -C {{ gowl_dir }} -j{{ jobs }}

# Build the gowl submodule with debug symbols + ASan (slow but tracks crashes).
[group('build')]
build-gowl-debug:
    make -C {{ gowl_dir }} -j{{ jobs }} DEBUG=1 ASAN=1

# Force-relink temacs (sometimes Make's deps don't notice an .o changed).
[group('build')]
relink:
    rm -f src/temacs src/emacs
    @just build

# Show the active configure summary (catch silently-dropped flags).
[group('build')]
config-summary:
    @grep -E "^(  with[a-z-]+|  Does Emacs use|  Does Emacs support)" config.log | head -40

# Install the "cmacs" CUPS virtual printer (system-wide, prompts sudo).
# Auto-redirects to install-cmacs-printer-user on OSTree/immutable systems.
[group('build')]
install-cmacs-printer:
    @make install-cmacs-printer

# Remove the "cmacs" CUPS virtual printer (system-wide, prompts sudo).
[group('build')]
uninstall-cmacs-printer:
    @make uninstall-cmacs-printer

# Install a per-user IPP-Everywhere "cmacs" printer.  No sudo, works on
# Silverblue / Atomic / NixOS / any read-only-rootfs system.  Uses
# ippeveprinter + a systemd user service; cups-browsed picks it up via mDNS.
[group('build')]
install-cmacs-printer-user:
    @make install-cmacs-printer-user

# Stop and remove the per-user IPP-Everywhere printer.
[group('build')]
uninstall-cmacs-printer-user:
    @make uninstall-cmacs-printer-user

# Install editor-independent spool drainer (systemd user path+service).
# Companion to install-cmacs-printer — drains /tmp/cmacs-print-<uid>/
# into ~/Documents/notes/.../cmacs-print/ via cmacs --batch on inotify.
# No sudo.  Works whether or not interactive cmacs is running.
[group('build')]
install-cmacs-print-watcher:
    @make install-cmacs-print-watcher

# Stop and remove the systemd spool drainer.
[group('build')]
uninstall-cmacs-print-watcher:
    @make uninstall-cmacs-print-watcher

# Read-only diagnostic for the print subsystem (CUPS state + tools on PATH).
[group('build')]
check-cmacs-printer:
    @make check-cmacs-printer

# ──────────────────────────────────────────────────────────────────────
# Clean
# ──────────────────────────────────────────────────────────────────────

# Standard make clean.
[group('clean')]
clean:
    make clean

# Drop .elc + .eln for cmacs/* (run after editing lisp/cmacs/*.el).
[group('clean')]
clean-elisp:
    @echo "==> Removing lisp/cmacs/*.elc"
    -rm -f lisp/cmacs/*.elc
    @echo "==> Removing native-lisp/*/cmacs-*.eln"
    -find native-lisp -type f -name 'cmacs-*.eln' -delete 2>/dev/null
    @echo "==> Removing user-level eln cache for cmacs-*"
    -rm -f ~/.config/emacs/.local/cache/eln/*/cmacs-*.eln 2>/dev/null
    -rm -f ~/.config/emacs/eln-cache/*/cmacs-*.eln 2>/dev/null

# Nuke ALL native-comp output (~5 min recompile next startup).
[group('clean')]
clean-eln-all:
    -rm -rf native-lisp
    -rm -rf ~/.config/emacs/.local/cache/eln 2>/dev/null
    -rm -rf ~/.config/emacs/eln-cache 2>/dev/null

# Submodule clean.
[group('clean')]
clean-gowl:
    make -C {{ gowl_dir }} clean

# Nuke everything (cmacs + gowl + .eln/.elc); requires re-bootstrap.
[group('clean')]
clean-all: clean clean-eln-all clean-gowl
    @echo "==> Cleared all build artifacts; run \`just bootstrap\` to rebuild."

# ──────────────────────────────────────────────────────────────────────
# Run
# ──────────────────────────────────────────────────────────────────────

# Run cmacs normally.  Exports CMACS_MODULE_DIR so the `cmacsgi`
# bacon builtin is available when the user does `M-x bacon`.
# GI_TYPELIB_PATH adds libregnum's + graylib's typelibs (built by the cmacs
# build when g-ir-scanner is present) so cmacs's gi subsystem and the libregnum
# gjs/PyGObject scripting backends can `import Libregnum` / `import Graylib`.
# We deliberately do NOT add the matching .so dirs to LD_LIBRARY_PATH: the
# libregnum/graylib symbols are whole-archived into temacs and exported
# (-rdynamic), so GIRepository resolves them from the running image rather than
# dlopening a second copy (which would re-register the GTypes and crash).
[group('run')]
run *ARGS:
    CMACS_MODULE_DIR={{ justfile_directory() }}/cmacs/bacon/modules \
    CMACS_GSURF_MODULE_DIR={{ justfile_directory() }}/cmacs/gsurf/modules \
    GI_TYPELIB_PATH="{{ justfile_directory() }}/deps/libregnum/build/release/gir:{{ justfile_directory() }}/deps/libregnum/deps/graylib/build/gir${GI_TYPELIB_PATH:+:$GI_TYPELIB_PATH}" \
        {{ emacs }} {{ ARGS }}

# Run cmacs as a Wayland compositor (`--gowl`).
[group('run')]
gowl *ARGS:
    {{ emacs }} --gowl {{ ARGS }}

# Run cmacs --gowl under valgrind (slow, but catches use-after-free).
[group('run')]
gowl-valgrind *ARGS:
    valgrind --suppressions=etc/emacs.supp --leak-check=no \
        {{ emacs }} --gowl {{ ARGS }}

# Run cmacs --gowl under gdb (drops to (gdb) prompt; type `r` to start).
[group('run')]
gowl-gdb *ARGS:
    gdb --args {{ emacs }} --gowl {{ ARGS }}

# Quick batch eval, e.g. `just batch '(princ (emacs-version))'`.
[group('run')]
batch EXPR:
    {{ emacs }} -Q --batch --eval "{{ EXPR }}"

# Verify a list of cmacs DEFUNs is available in the binary.
[group('run')]
check-defuns:
    @{{ emacs }} -Q --batch --eval '(dolist (f (list \
        (quote gowl-running-p) \
        (quote gowl-grant-focus-to-emacs) \
        (quote gowl-return-focus-to-embed) \
        (quote gowl-focus-redirect-active-p) \
        (quote gowl-focus-redirect-sticky-p) \
        (quote gowl-set-prefix-key-policy) \
        (quote gowl-session-save) \
        (quote gowl-session-restore) \
        (quote gowl-workspace-create) \
        (quote gowl-workspace-switch) \
        (quote gowl-client-add-mirror) \
        (quote gowl-client-set-geometry))) \
      (princ (format "%-40s %s\n" f (fboundp f))))'

# ──────────────────────────────────────────────────────────────────────
# Test
# ──────────────────────────────────────────────────────────────────────

# Run the cmacs ERT suite.
[group('test')]
test:
    make -C test check-cmacs

# Run gowl's GTest suite.
[group('test')]
test-gowl:
    make -C {{ gowl_dir }} test

# Run everything testable.
[group('test')]
test-all: test-gowl test

# ──────────────────────────────────────────────────────────────────────
# Diagnostics
# ──────────────────────────────────────────────────────────────────────

# Find a running --gowl emacs PID, or 0 if none.
[group('diag')]
gowl-pid:
    #!/usr/bin/env bash
    set -uo pipefail
    pid=$(ps -eo pid,args | awk '/[e]macs --gowl/ {print $1; exit}')
    echo "${pid:-0}"

# Print all threads of the running --gowl emacs.
[group('diag')]
thread-dump-gowl:
    #!/usr/bin/env bash
    set -euo pipefail
    pid=$(ps -eo pid,args | awk '/[e]macs --gowl/ {print $1; exit}')
    if [[ -z "${pid:-}" ]]; then
        echo "no running 'emacs --gowl' process found" >&2
        exit 1
    fi
    if command -v thread_dump >/dev/null; then
        thread_dump -s -p "$pid" -f -a
    else
        # Fallback: use gdb for a one-shot all-threads backtrace.
        gdb -batch -p "$pid" \
            -ex 'set pagination off' \
            -ex 'thread apply all bt' 2>&1
    fi

# Pick a running emacs via fzf and dump every thread's backtrace.
[group('diag')]
thread-dump:
    #!/usr/bin/env bash
    set -euo pipefail
    if ! command -v fzf >/dev/null; then
        echo "fzf not installed; use 'just thread-dump-gowl' or pass a PID" >&2
        exit 1
    fi
    # Collect (pid, etime, command) for every emacs* process.  -f
    # matches against the full command line so users can preview
    # arguments (--gowl, --daemon, etc.) in fzf.
    candidates=$(ps -eo pid=,etime=,args= \
        | awk '$3 ~ /(^|\/)emacs($|[[:space:]])/ \
               || $4 ~ /(^|\/)emacs($|[[:space:]])/' \
        | sed 's/^[[:space:]]*//')
    if [[ -z "${candidates:-}" ]]; then
        echo "no running emacs process found" >&2
        exit 1
    fi
    n=$(printf '%s\n' "$candidates" | wc -l)
    if (( n == 1 )); then
        choice="$candidates"
    else
        choice=$(printf '%s\n' "$candidates" | fzf \
            --prompt='thread-dump emacs > ' \
            --header='PID    ETIME    COMMAND' \
            --layout=reverse \
            --no-multi)
    fi
    [[ -n "${choice:-}" ]] || { echo "nothing selected" >&2; exit 1; }
    pid=$(awk '{print $1}' <<<"$choice")
    echo "==> dumping pid=$pid"
    if command -v thread_dump >/dev/null; then
        thread_dump -s -p "$pid" -f -a
    else
        gdb -batch -p "$pid" \
            -ex 'set pagination off' \
            -ex 'thread apply all bt' 2>&1
    fi

# Quick snapshot: only the main thread's backtrace (cheap).
[group('diag')]
gowl-bt-main:
    #!/usr/bin/env bash
    set -euo pipefail
    pid=$(ps -eo pid,args | awk '/[e]macs --gowl/ {print $1; exit}')
    [[ -n "${pid:-}" ]] || { echo "no --gowl process" >&2; exit 1; }
    gdb -batch -p "$pid" -ex 'set pagination off' -ex 'bt' 2>&1

# Ask coredumpctl for the most recent core dump of cmacs.
[group('diag')]
last-coredump:
    coredumpctl list /var/home/zach/source/projects/cmacs/src/emacs \
        2>/dev/null | tail -n 5

# Show the most recent crash backtrace (no debug-info loading; quick).
[group('diag')]
last-crash:
    coredumpctl info \
        $(coredumpctl list /var/home/zach/source/projects/cmacs/src/emacs \
            -o short 2>/dev/null | awk 'END {print $5}') \
        2>&1 | sed -n '/Stack trace of thread/,/^$/p' | head -60

# Drop into gdb on the most recent core dump (full debug-info load).
[group('diag')]
debug-last-crash:
    coredumpctl debug \
        $(coredumpctl list /var/home/zach/source/projects/cmacs/src/emacs \
            -o short 2>/dev/null | awk 'END {print $5}')

# Kill any running --gowl emacs (frees a stuck Wayland socket).
[group('diag')]
kill-gowl:
    #!/usr/bin/env bash
    set -euo pipefail
    pids=$(ps -eo pid,args | awk '/[e]macs --gowl/ {print $1}')
    if [[ -z "${pids:-}" ]]; then
        echo "no running --gowl process"
        exit 0
    fi
    echo "killing: $pids"
    kill $pids
    sleep 1
    if pgrep -f 'emacs --gowl' >/dev/null; then
        echo "process still alive — sending SIGKILL"
        kill -9 $pids 2>/dev/null || true
    fi

# Live-strace the running --gowl emacs (use sparingly — slow).
[group('diag')]
strace-gowl:
    #!/usr/bin/env bash
    set -euo pipefail
    pid=$(ps -eo pid,args | awk '/[e]macs --gowl/ {print $1; exit}')
    [[ -n "${pid:-}" ]] || { echo "no --gowl process" >&2; exit 1; }
    strace -fp "$pid" -e trace=!futex,clock_nanosleep,nanosleep \
        -o /tmp/cmacs-strace.log
    echo "log at /tmp/cmacs-strace.log"

# ──────────────────────────────────────────────────────────────────────
# Source / inventory
# ──────────────────────────────────────────────────────────────────────

# Count gowl-* DEFUNs exposed to Lisp.
[group('inv')]
defun-count:
    @grep -c '^DEFUN' cmacs/gowl/cmacs-gowl.c

# List all gowl-* DEFUN names.
[group('inv')]
defun-list:
    @grep '^DEFUN ("' cmacs/gowl/cmacs-gowl.c \
        | sed -E 's/^DEFUN \("([^"]+)".*/\1/' \
        | sort

# Count cmacs_gowl_mutex lock/unlock sites (post-refactor sanity check).
[group('inv')]
mutex-sites:
    @echo -n "lock sites:   "; grep -c 'pthread_mutex_lock (&cmacs_gowl_mutex)' \
        cmacs/gowl/cmacs-gowl.c
    @echo -n "unlock sites: "; grep -c 'pthread_mutex_unlock (&cmacs_gowl_mutex)' \
        cmacs/gowl/cmacs-gowl.c
    @echo "(asymmetry expected: error returns can unlock without a matching lock site)"

# Cmacs-managed sources and their line counts (top 20).
[group('inv')]
sloc:
    @find cmacs lisp/cmacs -type f \( -name '*.c' -o -name '*.h' -o -name '*.el' \) \
        | xargs wc -l 2>/dev/null | sort -rn | head -20

# ──────────────────────────────────────────────────────────────────────
# VCS
# ──────────────────────────────────────────────────────────────────────

# git status for both cmacs and the gowl submodule, side by side.
[group('vcs')]
status:
    @echo "==> cmacs"
    @git status --short
    @echo
    @echo "==> deps/gowl"
    @cd {{ gowl_dir }} && git status --short

# Show what's changed in cmacs and gowl since last push.
[group('vcs')]
log-unpushed:
    @echo "==> cmacs (origin/master..HEAD)"
    @git log --oneline origin/master..HEAD || true
    @echo
    @echo "==> deps/gowl (origin/master..HEAD)"
    @cd {{ gowl_dir }} && git log --oneline origin/master..HEAD || true

# Pull latest on cmacs + gowl + bring submodules in line.
[group('vcs')]
sync:
    git pull --rebase origin master
    git submodule update --init --recursive

# Compare current submodule pointer to its HEAD branch tip.
[group('vcs')]
gowl-pointer:
    @echo -n "submodule pointer: "
    @git ls-tree HEAD {{ gowl_dir }} | awk '{print $3}'
    @echo -n "submodule HEAD:    "
    @cd {{ gowl_dir }} && git rev-parse HEAD


# ──────────────────────────────────────────────────────────────────────
# Android APK build (containerized — no host JDK / SDK / NDK needed)
# ──────────────────────────────────────────────────────────────────────
#
# Pipeline: `just android-image` once, then `just android-build` whenever
# you want a fresh APK.  See plan in
# .claude/plans/i-want-you-to-shimmying-finch.md for the full design.
#
# Doom is bundled from $CMACS_DOOM_CORE (default ~/.config/emacs) and
# $CMACS_DOOM_PRIVATE (default ~/.config/doom) at build time.  On
# first launch on the phone, lisp/site-start.el seeds them into the
# app's HOME so the user lands in their Doom config.

# Build the Fedora+JDK21+SDK36+NDK image (~3-4 GB; ~10 min first run).
[group('android')]
android-image:
    {{ container_runtime }} build \
        -f Containerfile.android \
        -t {{ android_image_tag }} .

# Repack upstream's prebuilt APK with our Doom bundle injected (recommended path).
[group('android')]
android-repack:
    #!/usr/bin/env bash
    set -euo pipefail
    if [ ! -d "{{ android_doom_core }}" ]; then
        echo "Doom core not found at {{ android_doom_core }}" >&2
        exit 2
    fi
    if [ ! -d "{{ android_doom_priv }}" ]; then
        echo "Doom private not found at {{ android_doom_priv }}" >&2
        exit 2
    fi
    doom_core_real=$(realpath -e "{{ android_doom_core }}")
    doom_priv_real=$(realpath -e "{{ android_doom_priv }}")
    cache_dir="{{ justfile_directory() }}/build/upstream-apk-cache"
    mkdir -p "{{ android_out_dir }}" "$cache_dir"
    echo "==> Repacking upstream APK in {{ container_runtime }}: {{ android_image_tag }}"
    echo "    doom core:     $doom_core_real"
    echo "    doom private:  $doom_priv_real"
    echo "    cache:         $cache_dir"
    echo "    output:        {{ android_out_dir }}"
    {{ container_runtime }} run --rm -t \
        -v "{{ justfile_directory() }}:/work/cmacs:Z" \
        -v "$doom_core_real:/work/doom-core:ro,Z" \
        -v "$doom_priv_real:/work/doom-private:ro,Z" \
        -v "{{ android_out_dir }}:/work/out:Z" \
        -v "$cache_dir:/work/upstream-cache:Z" \
        {{ android_image_tag }} \
        bash /work/cmacs/build-aux/android-repack.sh

# Build a Doom-bundled APK in the container; output: build/android-out/.
[group('android')]
android-build:
    #!/usr/bin/env bash
    set -euo pipefail
    if [ ! -d "{{ android_doom_core }}" ]; then
        echo "Doom core not found at {{ android_doom_core }}" >&2
        echo "  set CMACS_DOOM_CORE=/path/to/.config/emacs to override" >&2
        exit 2
    fi
    if [ ! -d "{{ android_doom_priv }}" ]; then
        echo "Doom private not found at {{ android_doom_priv }}" >&2
        echo "  set CMACS_DOOM_PRIVATE=/path/to/.config/doom to override" >&2
        exit 2
    fi
    # Canonicalise via `realpath` — `~/.config/{emacs,doom}` are
    # commonly symlinks into a dotfiles checkout (e.g.
    # ~/.dotfiles/.config/...), and podman's :Z relabel does not
    # traverse symlinks.  Without canonicalisation the SELinux
    # context on the symlink target stays as `config_home_t' and
    # the container hits `Permission denied' on read.
    doom_core_real=$(realpath -e "{{ android_doom_core }}")
    doom_priv_real=$(realpath -e "{{ android_doom_priv }}")
    mkdir -p "{{ android_out_dir }}"
    echo "==> Building APK in {{ container_runtime }}: {{ android_image_tag }}"
    echo "    abi:          {{ android_abi }}"
    echo "    doom core:    $doom_core_real"
    echo "    doom private: $doom_priv_real"
    echo "    output:       {{ android_out_dir }}"
    {{ container_runtime }} run --rm -t \
        -e ANDROID_ABI={{ android_abi }} \
        -e CMACS_ANDROID_VANILLA="${CMACS_ANDROID_VANILLA:-0}" \
        -v "{{ justfile_directory() }}:/work/cmacs:Z" \
        -v "$doom_core_real:/work/doom-core:ro,Z" \
        -v "$doom_priv_real:/work/doom-private:ro,Z" \
        -v "{{ android_out_dir }}:/work/out:Z" \
        {{ android_image_tag }} \
        bash /work/cmacs/build-aux/android-build.sh

# Drop into bash inside the Android build container (same mounts as android-build).
[group('android')]
android-shell:
    #!/usr/bin/env bash
    set -euo pipefail
    doom_core_real=$(realpath -e "{{ android_doom_core }}")
    doom_priv_real=$(realpath -e "{{ android_doom_priv }}")
    {{ container_runtime }} run --rm -it \
        -e ANDROID_ABI={{ android_abi }} \
        -v "{{ justfile_directory() }}:/work/cmacs:Z" \
        -v "$doom_core_real:/work/doom-core:ro,Z" \
        -v "$doom_priv_real:/work/doom-private:ro,Z" \
        -v "{{ android_out_dir }}:/work/out:Z" \
        --workdir /work/cmacs \
        {{ android_image_tag }} \
        bash

# Clean Android build artifacts (APKs, staged Doom bundle, java/ + cross/ state).
[group('android')]
android-clean:
    -rm -rf "{{ android_out_dir }}"
    -rm -rf build-aux/android-doom-bundle
    -rm -rf java/install_temp java/classes
    -find java -maxdepth 1 -name 'emacs-*.apk' -delete
    -[ -d cross ] && make -C cross distclean 2>/dev/null || true

# adb install the latest APK (host adb if installed, else container w/ USB passthrough).
[group('android')]
android-deviceinstall:
    #!/usr/bin/env bash
    set -euo pipefail
    apk=$(ls -t "{{ android_out_dir }}"/*.apk 2>/dev/null | head -1)
    if [ -z "$apk" ]; then
        echo "No APK in {{ android_out_dir }} — run \`just android-build\` first." >&2
        exit 2
    fi
    if command -v adb >/dev/null; then
        echo "==> [host adb] install -r $apk"
        adb install -r "$apk"
    else
        echo "==> [container adb] install -r $(basename "$apk")"
        {{ container_runtime }} run --rm -t \
            --device /dev/bus/usb \
            -v "{{ android_out_dir }}:/work/out:Z" \
            {{ android_image_tag }} \
            adb install -r "/work/out/$(basename "$apk")"
    fi

# Live-tail device logcat filtered to Emacs tags + Java/native crashes (Ctrl-C to stop).
[group('android')]
android-logcat:
    #!/usr/bin/env bash
    set -euo pipefail
    # Tag filter: app-side (EmacsActivity, EmacsService, EmacsThread,
    # libemacs from ndk-stack), Java runtime exceptions
    # (AndroidRuntime), native crash tombstones (DEBUG / libc), then
    # silence everything else with `*:S'.
    filter='EmacsActivity:V EmacsService:V EmacsThread:V Emacs:V AndroidRuntime:E DEBUG:V libc:E zygote:E *:S'
    echo "==> clearing logcat buffer; relaunch the app on your device now."
    if command -v adb >/dev/null; then
        adb logcat -c
        adb logcat $filter
    else
        {{ container_runtime }} run --rm -it \
            --device /dev/bus/usb \
            {{ android_image_tag }} \
            sh -c "adb logcat -c && adb logcat $filter"
    fi

# Force-stop, relaunch, then dump tagged logcat — one-shot crash capture.
[group('android')]
android-logcat-snapshot:
    #!/usr/bin/env bash
    set -euo pipefail
    # Filter widened: capture libc abort trails (libc:F), the
    # tombstone backtrace (DEBUG / crash_dump64 are the bionic
    # crash-handler tags), Java runtime exceptions, and the Emacs
    # tags.  *:S silences the rest.
    filter='EmacsActivity:V EmacsService:V EmacsThread:V Emacs:V AndroidRuntime:E DEBUG:V libc:V crash_dump64:V crash_dump32:V tombstoned:V *:S'
    pkg=org.gnu.emacs
    # 8s wait — the DEBUG tombstone is written ~1-3s AFTER the
    # SIGABRT in libc, and crash_dump64 takes another second to
    # flush.  4s sometimes misses it.
    cmd="adb logcat -c \
      && adb shell am force-stop $pkg \
      && adb shell monkey -p $pkg -c android.intent.category.LAUNCHER 1 >/dev/null \
      && sleep 8 \
      && adb logcat -d $filter | tail -400"
    if command -v adb >/dev/null; then
        bash -c "$cmd"
    else
        {{ container_runtime }} run --rm -t \
            --device /dev/bus/usb \
            {{ android_image_tag }} \
            sh -c "$cmd"
    fi

# Identify which library a given hex address falls in by snapshotting /proc/PID/maps.
# Usage: just android-addr2lib 0x749f003718
#
# Uses `am set-debug-app -w' so the app waits for a debugger attach
# before crossing into native code — gives us unlimited time to read
# the live process's memory map.  The wait is cleared at end-of-run.
[group('android')]
android-addr2lib ADDR:
    #!/usr/bin/env bash
    # Deliberately NOT using `set -e' or `pipefail' — pidof exits 1
    # when the app process hasn't appeared yet, and we WANT to keep
    # polling.
    set -u
    pkg=org.gnu.emacs
    addr={{ ADDR }}
    cleanup() { adb shell am clear-debug-app >/dev/null 2>&1 || true ; }
    trap cleanup EXIT
    echo "==> arming debug-wait on $pkg"
    adb shell am force-stop "$pkg" >/dev/null 2>&1 || true
    adb shell am set-debug-app -w "$pkg" >/dev/null 2>&1 || \
        echo "  (set-debug-app may have failed; continuing — may still catch pid quickly)" >&2
    adb shell monkey -p "$pkg" -c android.intent.category.LAUNCHER 1 >/dev/null 2>&1 || true
    echo "==> waiting for app to land in pre-debug pause"
    pid=
    for i in $(seq 1 80); do
        pid=$(adb shell pidof "$pkg" 2>/dev/null | tr -d '\r' | awk '{print $1}' || true)
        [ -n "$pid" ] && break
        sleep 0.1
    done
    if [ -z "$pid" ]; then
        echo "couldn't catch the app pid even with debug-wait armed" >&2
        exit 2
    fi
    echo "pid: $pid"
    tmp=$(mktemp)
    adb shell "cat /proc/$pid/maps 2>/dev/null" > "$tmp"
    if [ ! -s "$tmp" ]; then
        echo "/proc/$pid/maps was empty — possibly need run-as $pkg" >&2
        # Try via run-as (works on debuggable APKs)
        adb shell "run-as $pkg cat /proc/$pid/maps 2>/dev/null" > "$tmp" || true
    fi
    if [ ! -s "$tmp" ]; then
        echo "still empty; aborting" >&2
        rm -f "$tmp"
        exit 2
    fi
    awk -v t=$(printf '%d' "$addr") '
        /^[0-9a-f]+-[0-9a-f]+/ {
            line[NR] = $0
            split($1, r, "-")
            lo = strtonum("0x" r[1])
            hi = strtonum("0x" r[2])
            if (t >= lo && t < hi) hit = NR
        }
        END {
            if (!hit) { printf "addr 0x%x not found\n", t; exit }
            printf "addr 0x%x falls in:\n\n", t
            for (n = hit-5; n <= hit+5; n++) {
                if (line[n]) {
                    marker = (n == hit) ? "==> " : "    "
                    printf "%s%s\n", marker, line[n]
                }
            }
        }
    ' "$tmp"
    rm -f "$tmp"
    # Hand control back: also let the app proceed (so the pre-debug
    # hold doesn't strand the process forever).
    adb shell am clear-debug-app >/dev/null 2>&1 || true
    adb shell run-as "$pkg" kill -CONT "$pid" >/dev/null 2>&1 || true

# Pull the latest /data/tombstones/* off the device (needs root).
[group('android')]
android-tombstones:
    #!/usr/bin/env bash
    set -euo pipefail
    out="{{ android_out_dir }}/tombstones"
    mkdir -p "$out"
    cmd="adb shell 'su -c \"ls -t /data/tombstones/ 2>/dev/null\" || ls -t /data/tombstones/ 2>/dev/null' \
      | head -1 \
      | xargs -I{} sh -c 'adb shell \"su -c cat /data/tombstones/{}\" 2>/dev/null \
                          || adb pull /data/tombstones/{} -' > '$out/latest.txt'"
    if command -v adb >/dev/null; then
        bash -c "$cmd"
    else
        echo "Tombstone pull requires host adb (and likely root on the device)." >&2
        echo "Most non-rooted phones won't allow /data/tombstones/ access." >&2
        echo "Use \`just android-logcat-snapshot\` instead." >&2
        exit 2
    fi
    if [ -s "$out/latest.txt" ]; then
        echo "==> wrote $out/latest.txt"
        head -40 "$out/latest.txt"
    else
        echo "Tombstone empty / not readable (device probably not rooted)." >&2
        exit 2
    fi
