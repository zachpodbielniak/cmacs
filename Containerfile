# FEDORA_VERSION controls which wlroots gowl builds against: Fedora 44+
# ships wlroots 0.20 (per-window screencast capture), 42/43 ship 0.19
# (monitor-only).  Bump to 44+ (`--build-arg FEDORA_VERSION=44`) for an
# image whose gowl can window-capture.
ARG FEDORA_VERSION=43
FROM registry.fedoraproject.org/fedora:${FEDORA_VERSION} AS builder
ARG FEDORA_VERSION

# ---------------------------------------------------------------------
# Default voice + STT model bundled into the image.  Override at build
# time with --build-arg to swap languages/sizes, e.g.
#
#   build-container --build-arg WHISPER_MODEL_NAME=ggml-small.en.bin \
#                   --build-arg PIPER_VOICE_NAME=en_GB-alba-medium.onnx \
#                   --build-arg PIPER_VOICE_DIR=en/en_GB/alba/medium
#
# Models land in /usr/share/cmacs/{whisper-models,piper-voices}/ in
# the staged image; cmacs-whisper.el and cmacs-piper.el's search
# paths pick them up automatically (user dir under ~/.local/share/
# wins if both exist).  Total cost in the image: ~210 MB for the
# defaults below.
# ---------------------------------------------------------------------
ARG WHISPER_MODEL_NAME=ggml-base.en.bin
ARG WHISPER_MODEL_URL=https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-base.en.bin
ARG PIPER_VOICE_NAME=en_US-amy-low.onnx
ARG PIPER_VOICE_DIR=en/en_US/amy/low
ARG PIPER_VOICE_BASE_URL=https://huggingface.co/rhasspy/piper-voices/resolve/main

# System build dependencies
# wlroots: gowl builds against 0.19 or 0.20 (newest present wins; 0.20
# adds per-window screencast capture).  wlroots-devel is the right
# package on every Fedora release -- it is 0.20 on 44+ and 0.19 on
# 42/43 -- so no version branch is needed.
RUN dnf install -y \
        autoconf automake gcc gcc-c++ make pkgconf-pkg-config texinfo \
        which git \
        gnutls-devel ncurses-devel zlib-devel \
        gtk3-devel \
        webkit2gtk4.1-devel \
        libgccjit-devel \
        libXpm-devel libjpeg-turbo-devel giflib-devel libtiff-devel \
        librsvg2-devel libwebp-devel \
        libotf-devel m17n-lib-devel \
        jansson-devel \
        libtree-sitter-devel \
        glib2-devel gobject-introspection-devel \
        wlroots-devel wayland-devel wayland-protocols-devel \
        libinput-devel libxkbcommon-devel pango-devel cairo-devel \
        libdecor-devel libdrm-devel pixman-devel \
        libeis-devel \
        libxcb-devel xcb-util-wm-devel \
        libyaml-devel json-glib-devel libdex-devel \
        gdk-pixbuf2-devel \
        libsoup3-devel readline-devel \
        libetpan-devel sqlite-devel libpq-devel \
        cmark-devel \
        opencascade-devel \
        libssh2-devel libvirt-devel pam-devel \
        elfutils-devel elfutils-debuginfod-client-devel binutils-devel \
        gstreamer1-devel gstreamer1-plugins-base-devel \
        gstreamer1-plugins-good gstreamer1-plugins-bad-free-devel \
        gstreamer1-plugins-bad-free-extras gstreamer1-plugins-ugly-free \
        gstreamer1-libav \
        pipewire-devel pipewire-libs pulseaudio-libs-devel \
        cmake espeak-ng python3-pip \
        mesa-libGL-devel libX11-devel libXrandr-devel libXcursor-devel \
        libXinerama-devel libXi-devel \
        curl \
    && dnf clean all
# pipewire-devel + pulseaudio-libs-devel: cmacs-audio capture source
# (pipewiresrc preferred, pulsesrc fallback).  cmake: bundled
# whisper.cpp build.  git: cad-glib's Manifold kernel CMake clones its
# pinned Clipper2 via FetchContent (git clone); without it the configure
# dies with "could not find git for clone of clipper2-populate".
# espeak-ng: phonemiser used by piper-tts.
# python3-pip: installs the piper-tts CLI in the later RUN step.
# opencascade-devel: the OpenCASCADE B-rep kernel for --with-cmacs-cad.
# Fedora ships no opencascade.pc, so cad-glib probes it by header+library
# (deps/cad-glib/config.mk); without this package the image builds CAD
# mesh-only (Manifold CSG, no B-rep) and a stale host .pc leaking -lTKernel
# breaks the libregnum link.
# elfutils-devel + libdebuginfod: cintrospect's libdw DWARF reader.
# binutils-devel: provides dis-asm.h / libopcodes for cpatch's
# (currently optional) prologue probe.  cmacs builds without it via
# a built-in fallback.
# mesa-libGL-devel + libX11-devel + the four X11 input libs:
# raylib (via deps/libregnum/deps/graylib) needs these even when we
# run with FLAG_WINDOW_HIDDEN because raylib's InitWindow still
# initialises X11 to construct the offscreen GL context.

COPY . /build/cmacs
WORKDIR /build/cmacs

# Remove .git pointer (submodule COPY artifact) and build bundled deps.
# Order matters: ai-glib MUST come before libreclaw because libreclaw's
# Makefile references the new build/release layout (libreclaw's bundled
# ai-glib copy is built separately and ignored at cmacs link time -- the
# cmacs build redirects libreclaw's sub-make at the top-level canonical
# artifact via AI_GLIB_DIR=).  ai-glib itself is built with GIR=1 so
# AiGlib-1.0.typelib lands in the system GI search path for downstream
# consumers (python-gi, gjs, the bacon `cmacsgi' builtin, etc.).
#
# The find/rm below is a hermetic-build safety net: even though
# .containerignore excludes build artifacts, any *.elc/*.eln/native-lisp
# that leaks in from the COPYed working tree would otherwise be reused by
# the incremental `make' below (mtime trap) and shipped STALE — notably a
# tramp-compat.elc byte-compiled under an older Emacs version.  Deleting
# them forces a fresh compile under this image's Emacs.
RUN rm -f .git \
    && find . \( -name '*.elc' -o -name '*.eln' \) -delete \
    && rm -rf native-lisp src/*.pdmp deps/whisper.cpp/build \
    && for dep in mcp-glib crispy bacon gowl podomation ai-glib libreclaw; do \
           if [ -d "deps/${dep}" ]; then \
               case "${dep}" in \
                   ai-glib) make -C "deps/${dep}" clean all PREFIX=/usr GIR=1;; \
                   *)       make -C "deps/${dep}" clean all PREFIX=/usr;; \
               esac; \
               case "${dep}" in \
                   ai-glib) make -C "deps/${dep}" install PREFIX=/usr GIR=1;; \
                   *)       make -C "deps/${dep}" install PREFIX=/usr;; \
               esac; \
           fi; \
       done \
    && if ! command -v piper >/dev/null 2>&1; then \
           dnf install -y python3-pip espeak-ng \
              && pip install --no-cache-dir piper-tts; \
       fi \
    && ldconfig
# Piper (OHF-Voice piper1-GPL fork) ships as a Python package; the
# `piper` console-script is installed by pip.  deps/piper is kept as
# a submodule for reference / test fixtures but is not built from source.
#
# deps/whisper.cpp is NOT built here: the `make -j$(nproc)' below
# triggers its CMake build automatically as a prerequisite of the
# whisper .o files (via the $(CMACS_WHISPER_STATIC_LIB) rule in
# src/Makefile.in), with the right -DCMAKE_C_STANDARD=11 etc. flags
# for the CMake 4.x + GCC 16 feature-detection workaround.  Doing it
# manually here with `make -C deps/whisper.cpp libwhisper.a' is both
# redundant AND broken (recent whisper.cpp is CMake-only and no
# longer ships a libwhisper.a Make target).

# Pre-build cad-glib's vendored geometry kernels (Manifold + its
# FetchContent'd Clipper2, SolveSpace's libslvs + mimalloc) serially,
# BEFORE the big parallel `make' below.  Two reasons:
#   * Manifold's CMake clones Clipper2 with git (FetchContent); building
#     it here keeps that one-shot clone out of the parallel build.
#   * Running these nested CMake configures one at a time avoids the
#     compiler ABI-probe failures ("CMAKE_CXX_COMPILER not set, after
#     EnableLanguage") they hit when racing the oversubscribed
#     `make -j$(nproc)'.
# The archives are then already present when cad-glib's sub-make runs as
# a prerequisite of the cmacs link, so it just links them.
RUN make -C deps/cad-glib deps

# Build cmacs.  --enable-cmacs-deps-debug builds the in-house deps at
# -O0 -g3 (DWARF) so gdb and runtime C self-introspection (cintrospect) can
# read their structs; this is our default.  Drop that one flag for a faster
# release-deps image.
RUN ./autogen.sh \
    && ./configure \
        --prefix=/usr \
        --with-pgtk \
        --with-cairo \
        --with-dbus \
        --with-harfbuzz \
        --with-modules \
        --with-native-compilation=aot \
        --with-tree-sitter \
        --with-sqlite3 \
        --with-json \
        --with-rsvg \
        --with-jpeg \
        --with-png \
        --with-gif \
        --with-tiff \
        --with-webp \
        --with-xpm \
        --with-gpm=no \
        --with-xwidgets \
        --with-cmacs-glib \
        --with-cmacs-gi \
        --with-cmacs-crispy \
        --with-cmacs-bacon \
        --with-cmacs-gowl \
        --with-cmacs-podomation \
        --with-cmacs-libreclaw \
        --with-cmacs-ai \
        --with-cmacs-org-ex \
        --with-cmacs-mcp \
        --with-cmacs-print \
        --with-cmacs-video \
        --with-cmacs-audio \
        --with-cmacs-whisper \
        --with-cmacs-piper \
        --with-cmacs-cintrospect \
        --with-cmacs-libregnum \
        --with-cmacs-gnuseye \
        --with-cmacs-cad \
        --with-cmacs-screensaver \
        --with-cmacs-gsurf \
        --with-cmacs-gsurf-lrg \
        --with-cmacs-emacsctl \
        --with-cmacs-lrgterm \
        --enable-cmacs-cpatch \
        --enable-cmacs-deps-debug \
    && make -j"$(nproc)" \
    && make install DESTDIR=/build/stage

# Register cmacs API library path so bacon modules can find libcmacs-api.so
RUN mkdir -p /build/stage/etc/ld.so.conf.d \
    && echo "/usr/lib64/cmacs" > /build/stage/etc/ld.so.conf.d/cmacs.conf

# Build and install cmacs-mcp stdio relay (MCP client support)
RUN make -C tools/cmacs-mcp clean all PREFIX=/usr \
    && make -C tools/cmacs-mcp install PREFIX=/usr DESTDIR=/build/stage

# Install Wayland session file
RUN ./install-wm PREFIX=/usr \
    && mkdir -p /build/stage/usr/share/wayland-sessions \
    && mv /usr/share/wayland-sessions/cmacs.desktop /build/stage/usr/share/wayland-sessions/

# ---------------------------------------------------------------------
# cmacs-print — "Print to cmacs" virtual printer.  Stages everything
# image consumers (immutablue, traditional installs) need to get the
# printer working out of the box.  All paths align with the helper
# scripts in cmacs/print/ so a non-container install via
# `make install-cmacs-printer` produces the same on-disk layout.
#
# Files staged:
#   /usr/lib/cups/backend/cmacs-print              — CUPS backend (0700)
#   /usr/share/cmacs-print/cmacs-print.ppd         — PPD (passthrough)
#   /usr/libexec/cmacs/cmacs-print-register        — first-boot helper
#   /usr/lib/systemd/system/cmacs-print-register.service
#   /usr/lib/systemd/user/cmacs-print-drain.path
#   /usr/lib/systemd/user/cmacs-print-drain.service
#   /usr/lib/systemd/system-preset/50-cmacs-print.preset
#   /usr/lib/systemd/user-preset/50-cmacs-print.preset
# ---------------------------------------------------------------------
RUN set -eux \
    # Discover the emacs version so we can hardcode the lisp dir into
    # the systemd user units (specifier expansion in path units is
    # limited to %U/%h/%t — there is no specifier for the emacs
    # version).
    && emacs_version="" \
    && for d in /build/stage/usr/share/emacs/*/; do \
           v="$(basename "$d")"; \
           if [ "$v" != "site-lisp" ]; then emacs_version="$v"; break; fi; \
       done \
    && [ -n "$emacs_version" ] \
    && lisp_dir="/usr/share/emacs/${emacs_version}/lisp" \
    # CUPS backend + PPD.
    && install -d -m 0755 /build/stage/usr/lib/cups/backend \
    && install -m 0700 cmacs/print/cmacs-print \
       /build/stage/usr/lib/cups/backend/cmacs-print \
    && install -d -m 0755 /build/stage/usr/share/cmacs-print \
    && install -m 0644 cmacs/print/cmacs-print.ppd \
       /build/stage/usr/share/cmacs-print/cmacs-print.ppd \
    # Registration helper.
    && install -d -m 0755 /build/stage/usr/libexec/cmacs \
    && install -m 0755 cmacs/print/cmacs-print-register \
       /build/stage/usr/libexec/cmacs/cmacs-print-register \
    # System unit: register printer at boot.
    && install -d -m 0755 /build/stage/usr/lib/systemd/system \
    && install -m 0644 cmacs/print/cmacs-print-register.service \
       /build/stage/usr/lib/systemd/system/cmacs-print-register.service \
    # User units: spool drainer.  Render the .in templates with absolute
    # paths and the systemd %U specifier (expanded per-user at runtime).
    && install -d -m 0755 /build/stage/usr/lib/systemd/user \
    && sed \
         -e 's|@SPOOL@|/tmp/cmacs-print-%U|g' \
         cmacs/print/cmacs-print-drain.path.in \
       > /build/stage/usr/lib/systemd/user/cmacs-print-drain.path \
    && sed \
         -e 's|@SPOOL@|/tmp/cmacs-print-%U|g' \
         -e 's|@CMACS@|/usr/bin/emacs|g' \
         -e "s|@LISP@|${lisp_dir}|g" \
         cmacs/print/cmacs-print-drain.service.in \
       > /build/stage/usr/lib/systemd/user/cmacs-print-drain.service \
    && chmod 0644 \
         /build/stage/usr/lib/systemd/user/cmacs-print-drain.path \
         /build/stage/usr/lib/systemd/user/cmacs-print-drain.service \
    # Presets: enable the registration service system-wide and the
    # drainer for every user on first login.
    && install -d -m 0755 /build/stage/usr/lib/systemd/system-preset \
    && install -m 0644 cmacs/print/50-cmacs-print.preset \
       /build/stage/usr/lib/systemd/system-preset/50-cmacs-print.preset \
    && install -d -m 0755 /build/stage/usr/lib/systemd/user-preset \
    && install -m 0644 cmacs/print/50-cmacs-print.preset \
       /build/stage/usr/lib/systemd/user-preset/50-cmacs-print.preset

# ---------------------------------------------------------------------
# cmacs-whisper + cmacs-piper: bundle the default English STT model
# and TTS voice into the image so the subsystems work out of the box
# on downstream images that copy /build/stage/usr/. into /usr/.
#
# Staged layout (FHS-compliant; models are data, not executables):
#   /usr/share/cmacs/whisper-models/${WHISPER_MODEL_NAME}
#   /usr/share/cmacs/piper-voices/${PIPER_VOICE_NAME}
#   /usr/share/cmacs/piper-voices/${PIPER_VOICE_NAME}.json
#
# User-installed models under ~/.local/share/cmacs/* take precedence
# over these (cmacs-whisper-models-search-path / -voices-search-path
# put the user dir first); these are the system-wide fallbacks.
#
# Override at build time with the ARGs at the top of the file.
# ---------------------------------------------------------------------
RUN install -d -m 0755 \
        /build/stage/usr/share/cmacs/whisper-models \
        /build/stage/usr/share/cmacs/piper-voices \
 && echo "==> Downloading whisper model: ${WHISPER_MODEL_NAME}" \
 && curl -fsSL -o "/build/stage/usr/share/cmacs/whisper-models/${WHISPER_MODEL_NAME}" \
        "${WHISPER_MODEL_URL}" \
 && echo "==> Downloading piper voice:   ${PIPER_VOICE_NAME}" \
 && curl -fsSL -o "/build/stage/usr/share/cmacs/piper-voices/${PIPER_VOICE_NAME}" \
        "${PIPER_VOICE_BASE_URL}/${PIPER_VOICE_DIR}/${PIPER_VOICE_NAME}" \
 && curl -fsSL -o "/build/stage/usr/share/cmacs/piper-voices/${PIPER_VOICE_NAME}.json" \
        "${PIPER_VOICE_BASE_URL}/${PIPER_VOICE_DIR}/${PIPER_VOICE_NAME}.json" \
 && chmod 0644 \
        "/build/stage/usr/share/cmacs/whisper-models/${WHISPER_MODEL_NAME}" \
        "/build/stage/usr/share/cmacs/piper-voices/${PIPER_VOICE_NAME}" \
        "/build/stage/usr/share/cmacs/piper-voices/${PIPER_VOICE_NAME}.json"

# ---------------------------------------------------------------------
# D-Bus session-bus activation file.  Stages
# /usr/share/dbus-1/services/org.cmacs.Editor.service so any client
# (file manager "Open With cmacs", gio open, GNOME shell search,
# external script) targeting org.cmacs.Editor when no cmacs is running
# causes dbus-daemon to launch `emacs --fg-daemon` (or the
# cmacs.service systemd user unit when present).
#
# This is what makes the cmacs D-Bus surface "just work" on downstream
# images that copy /build/stage/usr/. into /usr/.  Nothing else needs
# to run at first boot — dbus-daemon picks the file up automatically
# the next time a client sends to org.cmacs.Editor.
# ---------------------------------------------------------------------
RUN make install-cmacs-dbus-service \
        DESTDIR=/build/stage \
        prefix=/usr \
        bindir=/usr/bin \
        datadir=/usr/share \
        dbusservicedir=/usr/share/dbus-1/services

# Install interactive Org manual (core docs + embedded dependency docs).
# `make` already regenerates doc_org/cmacs/deps/ from each deps/<dep>/docs
# via the cmacs-deps-docs target, but run the sync explicitly here so the
# staged tree is guaranteed fresh regardless of make's incremental
# decisions.  doc_org/ is then copied wholesale into the emacs data dir;
# downstream images (immutablue) that copy /build/stage/usr/. into /usr
# pick the whole manual — deps docs included — up automatically.
RUN ./tools/sync-deps-docs.sh --quiet \
    && emacs_version="" \
    && for d in /build/stage/usr/share/emacs/*/; do \
           v="$(basename "$d")"; \
           if [ "$v" != "site-lisp" ]; then emacs_version="$v"; break; fi; \
       done \
    && if [ -n "${emacs_version}" ] && [ -d doc_org ]; then \
           cp -a doc_org "/build/stage/usr/share/emacs/${emacs_version}/doc_org"; \
       fi

# Scratch stage — only the built artifacts
FROM scratch
COPY --from=builder /build/stage /
