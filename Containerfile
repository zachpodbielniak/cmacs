ARG FEDORA_VERSION=43
FROM registry.fedoraproject.org/fedora:${FEDORA_VERSION} AS builder
ARG FEDORA_VERSION

# System build dependencies
# Fedora 44+ ships wlroots-0.20 as wlroots-devel; gowl needs
# wlroots-0.19, available as the wlroots0.19-devel compat package.
RUN if [ "${FEDORA_VERSION}" -ge 44 ] 2>/dev/null; then \
        WLROOTS_PKG=wlroots0.19-devel; \
    else \
        WLROOTS_PKG=wlroots-devel; \
    fi \
    && dnf install -y \
        autoconf automake gcc make pkgconf-pkg-config texinfo \
        gnutls-devel ncurses-devel zlib-devel \
        gtk3-devel \
        libgccjit-devel \
        libXpm-devel libjpeg-turbo-devel giflib-devel libtiff-devel \
        librsvg2-devel libwebp-devel \
        libotf-devel m17n-lib-devel \
        jansson-devel \
        libtree-sitter-devel \
        glib2-devel gobject-introspection-devel \
        "${WLROOTS_PKG}" wayland-devel wayland-protocols-devel \
        libinput-devel libxkbcommon-devel pango-devel cairo-devel \
        libdecor-devel libdrm-devel pixman-devel \
        libxcb-devel xcb-util-wm-devel \
        libyaml-devel json-glib-devel libdex-devel \
        gdk-pixbuf2-devel \
        libsoup3-devel readline-devel \
        libetpan-devel sqlite-devel libpq-devel \
        cmark-devel \
        libssh2-devel libvirt-devel pam-devel \
        elfutils-devel elfutils-debuginfod-client-devel binutils-devel \
    && dnf clean all
# elfutils-devel + libdebuginfod: cintrospect's libdw DWARF reader.
# binutils-devel: provides dis-asm.h / libopcodes for cpatch's
# (currently optional) prologue probe.  cmacs builds without it via
# a built-in fallback.

COPY . /build/cmacs
WORKDIR /build/cmacs

# Remove .git pointer (submodule COPY artifact) and build bundled deps
RUN rm -f .git \
    && for dep in mcp-glib crispy bacon gowl podomation libreclaw; do \
           if [ -d "deps/${dep}" ]; then \
               make -C "deps/${dep}" clean all PREFIX=/usr; \
               make -C "deps/${dep}" install PREFIX=/usr; \
           fi; \
       done \
    && ldconfig

# Build cmacs
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
        --with-cmacs-glib \
        --with-cmacs-gi \
        --with-cmacs-crispy \
        --with-cmacs-bacon \
        --with-cmacs-gowl \
        --with-cmacs-podomation \
        --with-cmacs-libreclaw \
        --with-cmacs-org-ex \
        --with-cmacs-mcp \
        --with-cmacs-print \
        --with-cmacs-video \
        --with-cmacs-cintrospect \
        --enable-cmacs-cpatch \
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

# Install interactive Org manual
RUN emacs_version="" \
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
