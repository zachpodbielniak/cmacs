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
gowl_dir    := "deps/gowl"

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
    --with-cmacs-glib
    --with-cmacs-gi
    --with-cmacs-crispy
    --with-cmacs-bacon
    --with-cmacs-gowl
    --with-cmacs-podomation
    --with-cmacs-libreclaw
    --with-cmacs-org-ex
    --with-cmacs-mcp
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

# Run cmacs normally.
[group('run')]
run *ARGS:
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
