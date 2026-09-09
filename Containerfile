# cmacs container image.
#
# One recipe, three distro families.  build-container picks the base
# image and passes CMACS_DISTRO; everything after the package install
# is identical, because it is all `make'.
#
#   ./build-container 44        Fedora 44   (the default)
#   ./build-container 24.04     Ubuntu 24.04
#   ./build-container 26.04     Ubuntu 26.04
#   ./build-container arch      Arch Linux
#
# The image is a scratch stage holding only /usr and /etc, so a
# consumer installs it by copying:
#
#   cp -a /mnt-cmacs/usr/. /usr/   (immutablue does exactly this)
#   ./install-container            (does it for a running system)
#
# Which is the point of building for several distros centrally: a
# two-core Arch box takes hours to build cmacs and seconds to unpack
# it.
#
# CMACS_DISTRO selects the package manager and the wlroots strategy.
# CMACS_RELEASE is the distro version, used only for the image's
# release marker.
#
# gowl builds against wlroots 0.19 or 0.20 (newest present wins; 0.20
# adds per-window screencast capture).  Fedora 44+, Arch and Ubuntu
# 26.04 all carry one of those.  Ubuntu 24.04 ships 0.17, so the
# builder compiles the Wayland stack from source -- see the
# wlroots-from-source stage below.
ARG BASE_IMAGE=registry.fedoraproject.org/fedora:44
FROM ${BASE_IMAGE} AS builder
ARG CMACS_DISTRO=fedora
ARG CMACS_RELEASE=44

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
# Build parallelism.  Defaults to every core, which is right for a big
# machine and wrong for two other cases:
#
#   * Several images built at once.  Emacs's ahead-of-time native
#     compilation runs one gcc per Lisp file, so -j24 across five
#     concurrent builds is 120 compilers -- which OOMs a 121 GB host and
#     takes every build down with it, reported only as
#     "container exited on killed".
#   * A small machine.  native-comp is memory-hungry per job, so a
#     4-core box with 8 GB wants -j2, not -j4.
#
# build-container exposes this as --jobs N.
ARG CMACS_JOBS=

ARG WHISPER_MODEL_NAME=ggml-base.en.bin
ARG WHISPER_MODEL_URL=https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-base.en.bin
ARG PIPER_VOICE_NAME=en_US-amy-low.onnx
ARG PIPER_VOICE_DIR=en/en_US/amy/low
ARG PIPER_VOICE_BASE_URL=https://huggingface.co/rhasspy/piper-voices/resolve/main

# ---------------------------------------------------------------------
# System build dependencies.
#
# Spelled out per distro rather than deferred to ./install-deps: a
# container needs things a developer's machine already has (curl, git,
# ca-certificates) and does not want things a developer does (the
# ImageMagick/GJS/LuaJIT extras).  install-deps stays the source of
# truth for a *host* install -- `make deps-list' prints exactly what it
# would put there.
#
# wlroots: gowl builds against 0.19 or 0.20, newest present wins.
# Fedora's wlroots-devel is the right name on every release (0.20 on
# 44+, 0.19 on 42/43).  Arch versions the package (wlroots0.20).
# Ubuntu versions it too (libwlroots-0.19-dev on 26.04) but 24.04 has
# only 0.17, handled further down.
#
# Every Debian-side install after the main one is OPPORTUNISTIC: the
# package may not exist on this release, and failure is swallowed with a
# NOTE.  That is what makes `--no-remove' (the apt_try wrapper) load
# bearing rather than tidy.  Without it apt is free to satisfy one of
# them by DELETING packages the main install already put there, and the
# `|| echo NOTE' hides that anything happened.
#
# 26.04 did exactly that: libmariadb-dev conflicts with the
# libmysqlclient-dev that libocct-data-exchange-dev pulls in through
# libvtk9-dev and libgdal-dev, so apt quietly removed six packages
# including the OCCT data-exchange headers.  cad-glib then failed on
# IGESControl_Reader.hxx six thousand log lines later, with nothing to
# say that a package we had installed was gone.
#
# MySQL is probed before it is asked for, too: on 26.04 the OCCT chain
# has already supplied default-libmysqlclient-dev (and mysqlclient.pc),
# so orm-glib is satisfied and requesting MariaDB only starts the fight.
#
# NOTE: no `#' comments inside the RUN below.  Continued lines are
# joined, so a comment would swallow the rest of the command.
# ---------------------------------------------------------------------
RUN set -eux; \
    case "${CMACS_DISTRO}" in \
    fedora) \
        dnf install -y \
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
            libzip-devel libxml2-devel \
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
            ffmpeg-free wl-clipboard \
            poppler-utils \
            libacl-devel libattr-devel \
            curl \
        ; \
        dnf clean all; \
        ;; \
    ubuntu|debian) \
        export DEBIAN_FRONTEND=noninteractive; \
        apt-get update; \
        apt-get install -y --no-install-recommends \
            autoconf automake gcc g++ make pkg-config texinfo \
            ca-certificates curl git \
            libgnutls28-dev libncurses-dev zlib1g-dev \
            libgtk-3-dev libwebkit2gtk-4.1-dev \
            libxpm-dev libjpeg-dev libgif-dev libtiff-dev \
            librsvg2-dev libwebp-dev \
            libotf-dev libm17n-dev \
            libjansson-dev \
            libtree-sitter-dev \
            libglib2.0-dev libgirepository1.0-dev \
            libwayland-dev libwayland-bin wayland-protocols \
            libinput-dev libxkbcommon-dev libpango1.0-dev libcairo2-dev \
            libdecor-0-dev libdrm-dev libpixman-1-dev \
            libei-dev \
            libxcb1-dev libxcb-icccm4-dev \
            libyaml-dev libjson-glib-dev \
            libzip-dev libxml2-dev \
            libgdk-pixbuf-2.0-dev \
            libsoup-3.0-dev libreadline-dev \
            libetpan-dev libsqlite3-dev libpq-dev \
            libcmark-dev \
            libocct-foundation-dev libocct-modeling-data-dev \
            libocct-modeling-algorithms-dev libocct-data-exchange-dev \
            libeigen3-dev \
            libssh2-1-dev libvirt-dev libpam0g-dev \
            libdw-dev libelf-dev libdebuginfod-dev binutils-dev \
            libgstreamer1.0-dev libgstreamer-plugins-base1.0-dev \
            gstreamer1.0-plugins-good gstreamer1.0-plugins-bad \
            gstreamer1.0-plugins-ugly gstreamer1.0-libav \
            libpipewire-0.3-dev libpulse-dev \
            cmake espeak-ng python3-pip python3-venv \
            libgl1-mesa-dev libegl1-mesa-dev libpng-dev \
            libx11-dev libxrandr-dev libxcursor-dev \
            libxinerama-dev libxi-dev \
            ffmpeg wl-clipboard \
            poppler-utils libglib2.0-bin \
            libacl1-dev libattr1-dev \
            meson ninja-build \
        ; \
        apt_try() { \
            apt-get install -y --no-install-recommends --no-remove "$@"; \
        }; \
        gcc_major="$(gcc -dumpversion | cut -d. -f1)"; \
        apt_try "libgccjit-${gcc_major}-dev" || apt_try libgccjit-dev; \
        apt_try libgirepository-2.0-dev \
            || echo "NOTE: no libgirepository-2.0-dev on this release"; \
        apt_try libdex-dev \
            || echo "NOTE: no libdex-dev on this release"; \
        if pkg-config --exists mysqlclient || pkg-config --exists libmariadb; \
        then \
            echo "NOTE: MySQL/MariaDB headers already present"; \
        else \
            apt_try default-libmysqlclient-dev || apt_try libmariadb-dev \
                || echo "NOTE: no MySQL/MariaDB dev package on this release"; \
        fi; \
        for v in 0.20 0.19; do \
            apt_try "libwlroots-${v}-dev" && break; \
        done \
            || echo "NOTE: no wlroots >= 0.19 packaged; building from source"; \
        ;; \
    arch) \
        pacman -Syu --noconfirm --needed \
            autoconf automake gcc make pkgconf texinfo \
            which git curl \
            gnutls ncurses zlib \
            gtk3 webkit2gtk-4.1 \
            libgccjit \
            libxpm libjpeg-turbo giflib libtiff librsvg libwebp \
            libotf m17n-lib \
            jansson \
            tree-sitter \
            glib2 gobject-introspection libgirepository \
            wayland wayland-protocols \
            libinput libxkbcommon pango cairo \
            libdecor pixman libei \
            libxcb xcb-util-wm \
            libyaml json-glib libdex \
            libzip libxml2 \
            gdk-pixbuf2 \
            libsoup3 readline \
            libetpan sqlite postgresql-libs \
            cmark \
            opencascade eigen \
            libssh2 libvirt pam \
            elfutils debuginfod binutils \
            gstreamer gst-plugins-base gst-plugins-good gst-plugins-bad \
            gst-plugins-ugly gst-libav \
            pipewire libpulse \
            cmake espeak-ng python-pip \
            mesa libglvnd libpng \
            libx11 libxrandr libxcursor libxinerama libxi \
            ffmpeg wl-clipboard \
            poppler \
            acl attr \
            mariadb-libs \
        ; \
        pacman -S --noconfirm --needed wlroots0.20 \
            || pacman -S --noconfirm --needed wlroots0.19; \
        pacman -Scc --noconfirm; \
        ;; \
    *) \
        echo "Unsupported CMACS_DISTRO: ${CMACS_DISTRO}" >&2; exit 1; \
        ;; \
    esac
# pipewire-devel + pulseaudio-libs-devel: cmacs-audio capture source
# (pipewiresrc preferred, pulsesrc fallback).  cmake: bundled
# whisper.cpp build.  git: cad-glib's Manifold kernel CMake clones its
# pinned Clipper2 via FetchContent (git clone); without it the configure
# dies with "could not find git for clone of clipper2-populate".
# espeak-ng: phonemiser used by piper-tts.
# python3-pip: installs the piper-tts CLI in the later RUN step.
# opencascade: the OpenCASCADE B-rep kernel for --with-cmacs-cad.
# Fedora ships no opencascade.pc, so cad-glib probes it by header+library
# (deps/cad-glib/config.mk); without this package the image builds CAD
# mesh-only (Manifold CSG, no B-rep) and a stale host .pc leaking -lTKernel
# breaks the libregnum link.
# elfutils-devel + libdebuginfod: cintrospect's libdw DWARF reader.
# binutils-devel: provides dis-asm.h / libopcodes for cpatch's
# (currently optional) prologue probe.  cmacs builds without it via
# a built-in fallback.
# ffmpeg: the ffmpeg/ffprobe binaries the vidstudio Reel video
# source/exporter shell out to (video clips + mp4/gif export); Fedora's
# free build decodes/encodes the open codecs, swap in RPM Fusion ffmpeg
# for H.264 Main/High.  wl-clipboard: imgedit's clipboard fallback for
# GTK-less sessions (emacs --lrg / tty).
# mesa GL + the X11 input libs:
# raylib (via deps/libregnum/deps/graylib) needs these even when we
# run with FLAG_WINDOW_HIDDEN because raylib's InitWindow still
# initialises X11 to construct the offscreen GL context.
#
# Ubuntu's apt lines end in `|| echo NOTE' for the handful of packages
# that exist on some releases and not others (libdex-dev arrived in
# 24.10, libgirepository-2.0-dev later still).  A hard failure there
# would make the whole image unbuildable on the older LTS for want of
# an optional subsystem.

# ---------------------------------------------------------------------
# The Wayland stack, from source, when the distro's is too old.
#
# gowl needs wlroots >= 0.19; Ubuntu 24.04 (noble) ships 0.17, along
# with wayland 1.22 (wlroots wants >= 1.23.1) and pixman 0.42 (wants
# >= 0.43).  Everything else -- Fedora 44, Arch, Ubuntu 26.04 -- has a
# usable wlroots in its repositories and skips this entirely.
#
# The probe is on pkg-config rather than on the distro version, so a
# release that starts shipping a new enough wlroots stops building it
# from source without anyone editing this file.
#
# Two details that are easy to get wrong, both silent:
#
#   * libdir.  Installing to /usr/lib on Debian/Ubuntu does NOT shadow
#     the distro's libraries: /usr/lib/<triplet>/pkgconfig is searched
#     first, so meson happily reports "found 1.22.0 but need >=1.23.1"
#     with a freshly built 1.23.1 sitting in /usr/lib.  The libdir is
#     therefore taken from the multiarch triplet.
#
#   * staging.  The final image is only /build/stage, so a library
#     built here and installed to the builder's /usr is NOT in the
#     image -- the result links against wayland 1.23 symbols and lands
#     on a host that has 1.22.  The install is done twice: once into
#     the builder so cmacs can build, and once into a scratch DESTDIR
#     whose libdir alone is copied into the stage.  Headers are
#     deliberately left behind; the image must not shadow the distro's
#     wayland headers for anything else the user compiles.
#
# libwayland and pixman have only ever added to their ABI, so the newer
# copies satisfy every existing consumer.  wlroots 0.19 carries its
# version in its soname and coexists with the distro's 0.17.  The one
# standing caveat is that a later `apt upgrade' of libwayland-server0
# repoints the soname symlink back at the distro's build; re-running
# install-container puts it right.  install-container says so.
# ---------------------------------------------------------------------
ARG WAYLAND_VERSION=1.23.1
ARG WAYLAND_PROTOCOLS_VERSION=1.41
ARG PIXMAN_VERSION=pixman-0.44.2
ARG WLROOTS_VERSION=0.19

RUN set -eux; \
    if pkg-config --exists wlroots-0.20 || pkg-config --exists wlroots-0.19; then \
        echo "==> Distro wlroots is usable:"; \
        pkg-config --modversion wlroots-0.20 2>/dev/null \
            || pkg-config --modversion wlroots-0.19; \
        exit 0; \
    fi; \
    echo "==> No usable wlroots; building the Wayland stack from source"; \
    libdir="lib64"; \
    case "${CMACS_DISTRO}" in \
    ubuntu|debian) \
        export DEBIAN_FRONTEND=noninteractive; \
        apt-get install -y --no-install-recommends \
            meson ninja-build git ca-certificates \
            libffi-dev libexpat1-dev libxml2-dev docbook-xsl xsltproc \
            libudev-dev libseat-dev libdisplay-info-dev libliftoff-dev \
            hwdata libgbm-dev libvulkan-dev glslang-tools \
            libxcb-composite0-dev libxcb-ewmh-dev \
            libxcb-render-util0-dev libxcb-res0-dev libxcb-xinput-dev \
            libxcb-dri3-dev libxcb-present-dev libxcb-shm0-dev \
            libxcb-xfixes0-dev libxcb-randr0-dev \
            python3-setuptools \
        ; \
        apt-get install -y --no-install-recommends libxcb-errors-dev \
            || echo "NOTE: no libxcb-errors-dev; X11 errors print as codes"; \
        libdir="lib/$(dpkg-architecture -qDEB_HOST_MULTIARCH)"; \
        ;; \
    esac; \
    echo "==> Wayland stack libdir: /usr/${libdir}"; \
    stage="/build/wayland-stage"; \
    mkdir -p "${stage}" /build/wayland-src; \
    cd /build/wayland-src; \
    \
    for spec in \
        "wayland|https://gitlab.freedesktop.org/wayland/wayland.git|${WAYLAND_VERSION}|-Ddocumentation=false -Dtests=false" \
        "wayland-protocols|https://gitlab.freedesktop.org/wayland/wayland-protocols.git|${WAYLAND_PROTOCOLS_VERSION}|-Dtests=false" \
        "pixman|https://gitlab.freedesktop.org/pixman/pixman.git|${PIXMAN_VERSION}|-Dtests=disabled -Ddemos=disabled" \
        "wlroots|https://gitlab.freedesktop.org/wlroots/wlroots.git|${WLROOTS_VERSION}|-Dexamples=false -Dbackends=drm,libinput,x11 -Drenderers=gles2,vulkan" \
    ; do \
        name="${spec%%|*}"; rest="${spec#*|}"; \
        url="${rest%%|*}"; rest="${rest#*|}"; \
        ref="${rest%%|*}"; opts="${rest#*|}"; \
        echo "==> ${name} ${ref}"; \
        git clone --depth 1 -b "${ref}" "${url}" "${name}"; \
        meson setup "${name}/build" "${name}" \
            --prefix=/usr --libdir="${libdir}" ${opts}; \
        ninja -C "${name}/build"; \
        ninja -C "${name}/build" install; \
        DESTDIR="${stage}" ninja -C "${name}/build" install; \
        ldconfig; \
    done; \
    \
    mkdir -p "/build/stage/usr/${libdir}"; \
    cp -a "${stage}/usr/${libdir}/." "/build/stage/usr/${libdir}/"; \
    rm -rf "/build/stage/usr/${libdir}/pkgconfig"; \
    rm -rf /build/wayland-src "${stage}"; \
    touch /build/stage/.bundled-wayland; \
    pkg-config --modversion wlroots-0.19

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
# Paths, not bare names: libreclaw is clawtilla's submodule now
# (deps/clawtilla/deps/libreclaw), and the old `[ -d ]' guard would have
# skipped it in silence -- an image quietly missing libreclaw.  A missing
# dep is a hard failure here instead.
#
# CANON_DIRS is the same one-copy rule src/Makefile.in applies: every dep
# that bundles crispy / yaml-glib / mcp-glib is pointed at the canonical
# checkout.  Without it these sub-makes reach for bundled copies that
# admin/cmacs-submodules.sh deliberately does not clone, and the build
# fails on a directory that is empty on purpose.  Both spellings are
# passed because the deps disagree (YAMLGLIB_DIR in gowl and bacon,
# YAML_GLIB_DIR in podomation, libreclaw and ai-glib); a make variable
# a given dep does not use is simply ignored.
#
# The find/rm below is a hermetic-build safety net: even though
# .containerignore excludes build artifacts, any *.elc/*.eln/native-lisp
# that leaks in from the COPYed working tree would otherwise be reused by
# the incremental `make' below (mtime trap) and shipped STALE — notably a
# tramp-compat.elc byte-compiled under an older Emacs version.  Deleting
# them forces a fresh compile under this image's Emacs.
RUN CANON_DIRS="CRISPY_DIR=/build/cmacs/deps/crispy \
      YAMLGLIB_DIR=/build/cmacs/deps/yaml-glib \
      YAML_GLIB_DIR=/build/cmacs/deps/yaml-glib \
      MCP_GLIB_DIR=/build/cmacs/deps/mcp-glib \
      BACON_DIR=/build/cmacs/deps/bacon \
      AI_GLIB_DIR=/build/cmacs/deps/ai-glib" \
    && rm -f .git \
    && find . \( -name '*.elc' -o -name '*.eln' \) -delete \
    && rm -rf native-lisp src/*.pdmp deps/whisper.cpp/build \
    && for dep in deps/mcp-glib deps/crispy deps/bacon deps/gowl \
                  deps/podomation deps/ai-glib \
                  deps/clawtilla/deps/libreclaw; do \
           if [ -d "${dep}" ]; then \
               gir=""; \
               case "${dep}" in */ai-glib) gir="GIR=1";; esac; \
               make -C "${dep}" clean all PREFIX=/usr ${gir} ${CANON_DIRS} \
                   || { echo "FAILED: build ${dep}" >&2; exit 1; }; \
               make -C "${dep}" install PREFIX=/usr ${gir} ${CANON_DIRS} \
                   || { echo "FAILED: install ${dep}" >&2; exit 1; }; \
           else \
               echo "FAILED: ${dep} is not checked out" >&2; exit 1; \
           fi; \
       done \
    && if ! command -v piper >/dev/null 2>&1; then \
           pip3 install --no-cache-dir piper-tts \
             || pip3 install --no-cache-dir --break-system-packages piper-tts \
             || echo "NOTE: piper-tts not installed; cmacs-piper needs it at runtime"; \
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

# Both makes take -j, and the SECOND one is the one that matters.
#
# `all' leaves the Lisp alone; it is `install' that runs `make -C lisp
# all' and native-compiles ~1500 files.  With no -j on the install line
# that entire phase ran one file at a time -- the longest part of every
# image build, single-threaded, while 23 cores sat idle.  It looks like
# the C compile is the expensive half and it is not: 892 CC lines
# against 1496 ELC+ELN.
#
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
        --with-cmacs-ai-brigade \
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
        --with-cmacs-roamgraph \
        --with-cmacs-secondbrain \
        --with-cmacs-office \
        --with-cmacs-lrgscript \
        --with-cmacs-cad \
        --with-cmacs-screensaver \
        --with-cmacs-gsurf \
        --with-cmacs-gsurf-lrg \
        --with-cmacs-emacsctl \
        --with-cmacs-lrgterm \
        --with-cmacs-imgedit \
        --with-cmacs-vidstudio \
        --with-cmacs-transcode \
        --with-cmacs-transcribe \
        --with-cmacs-calculator \
        --with-cmacs-lsp \
        --with-cmacs-dbexplorer \
        --enable-cmacs-cpatch \
        --enable-cmacs-deps-debug \
    && make -j"${CMACS_JOBS:-$(nproc)}" \
    && make -j"${CMACS_JOBS:-$(nproc)}" install DESTDIR=/build/stage

# ---------------------------------------------------------------------
# Register the cmacs API library path so bacon modules can find
# libcmacs-api.so, and stamp the image with what it was built from.
#
# The libdir is READ OFF the staged tree rather than hardcoded: Fedora
# and Arch install to /usr/lib64, Debian/Ubuntu to
# /usr/lib/x86_64-linux-gnu.  A wrong path here is silent -- ldconfig
# is happy to cache a directory that does not exist, and the failure
# only shows up much later as a bacon module that will not load.
#
# container-release is what install-container reads to refuse an image
# built for another distro.  It is also just useful: an unpacked /usr
# otherwise says nothing about where it came from.
# ---------------------------------------------------------------------
RUN set -eux; \
    libdir=""; \
    for d in /build/stage/usr/lib64/cmacs \
             /build/stage/usr/lib/*/cmacs \
             /build/stage/usr/lib/cmacs; do \
        if [ -d "$d" ]; then \
            libdir="${d#/build/stage}"; \
            break; \
        fi; \
    done; \
    if [ -z "$libdir" ]; then \
        echo "no staged cmacs libdir found" >&2; \
        find /build/stage/usr -name 'libcmacs-api.so*' >&2 || true; \
        exit 1; \
    fi; \
    echo "==> cmacs libdir: ${libdir}"; \
    mkdir -p /build/stage/etc/ld.so.conf.d; \
    echo "${libdir}" > /build/stage/etc/ld.so.conf.d/cmacs.conf; \
    mkdir -p /build/stage/usr/share/cmacs; \
    { \
        echo "distro=${CMACS_DISTRO}"; \
        echo "release=${CMACS_RELEASE}"; \
        echo "libdir=${libdir}"; \
        echo "arch=$(uname -m)"; \
        if [ -f /build/stage/.bundled-wayland ]; then \
            echo "bundled_wayland=yes"; \
        else \
            echo "bundled_wayland=no"; \
        fi; \
        echo "built=$(date -u +%Y-%m-%dT%H:%M:%SZ)"; \
        echo "version=$(sed -n 's/^AC_INIT(\[GNU Emacs\], *\[\([^]]*\)\].*/\1/p' configure.ac | head -1)"; \
    } > /build/stage/usr/share/cmacs/container-release; \
    rm -f /build/stage/.bundled-wayland; \
    cat /build/stage/usr/share/cmacs/container-release

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
