ARG FEDORA_VERSION=43
FROM registry.fedoraproject.org/fedora:${FEDORA_VERSION} AS builder

# System build dependencies
RUN dnf install -y \
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
        wlroots-devel wayland-devel wayland-protocols-devel \
        libinput-devel libxkbcommon-devel pango-devel cairo-devel \
        libdecor-devel libdrm-devel pixman-devel \
        libxcb-devel xcb-util-wm-devel \
        libyaml-devel json-glib-devel \
        libsoup3-devel readline-devel \
        libetpan-devel sqlite-devel libpq-devel \
        libssh2-devel libvirt-devel pam-devel \
    && dnf clean all

COPY . /build/cmacs
WORKDIR /build/cmacs

# Remove .git pointer (submodule COPY artifact) and build bundled deps
RUN rm -f .git \
    && for dep in crispy bacon gowl; do \
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
        --with-cmacs-org-ex \
    && make -j"$(nproc)" \
    && make install DESTDIR=/build/stage

# Install Wayland session file
RUN ./install-wm PREFIX=/usr \
    && mkdir -p /build/stage/usr/share/wayland-sessions \
    && mv /usr/share/wayland-sessions/cmacs.desktop /build/stage/usr/share/wayland-sessions/

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
