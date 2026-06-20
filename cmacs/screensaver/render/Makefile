# cmacs/screensaver/render/Makefile --- build cmacs-screensaver-render
#
# A standalone GLib/GObject binary that renders libregnum screensaver modules
# off-screen in its own GL context and streams frames to Emacs over shared
# memory.  Links the libregnum archive but NO Emacs objects.
#
# Invoked from src/Makefile.in with OUTDIR=<build src dir> and the libregnum
# flags passed through (fully expanded), mirroring cmacs/emacsctl/Makefile:
#
#   $(MAKE) -C cmacs/screensaver/render OUTDIR=$(abspath .) \
#       CMACS_LIBREGNUM_CFLAGS='...' CMACS_LIBREGNUM_LIBS='...' all

CC       ?= gcc
PKGS     := glib-2.0 gobject-2.0 gio-2.0 gio-unix-2.0 gmodule-2.0 json-glib-1.0
PKG_CFLAGS := $(shell pkg-config --cflags $(PKGS))
PKG_LIBS   := $(shell pkg-config --libs $(PKGS))

# libregnum / graylib / raylib / GL flags + archive, passed in from
# src/Makefile.in (already $(abs_top_srcdir)-expanded).  Empty in a standalone
# `make' here, in which case this target cannot be built directly.
CMACS_LIBREGNUM_CFLAGS ?=
CMACS_LIBREGNUM_LIBS   ?=
# cad-glib archive + OCCT/manifold/solvespace (only set when cmacs was built
# --with-cmacs-cad, which is also exactly when the libregnum archive contains the
# CAD baker objects the whole-archive pulls in).  Empty otherwise.
CMACS_CAD_LIBS         ?=

# `-I.' MUST come first so render.c's `#include <config.h>' resolves to our
# minimal shim (HAVE_CMACS_LIBREGNUM only), not Emacs's src/config.h or
# libregnum's build config.h.
CFLAGS  += -std=gnu11 -O2 -g -Wall -Wextra -Wno-unused-parameter \
           -I. -I.. -I../../libregnum \
           $(PKG_CFLAGS) $(CMACS_LIBREGNUM_CFLAGS)

# -rdynamic: this binary is the host for the loaded screensaver .so modules, so
# its dynamic symbol table must export the whole-archived libregnum symbols the
# module resolves at load time (the same reason Emacs links --export-dynamic).
#
# The whole-archived libregnum.a force-links ALL its objects (so any module can
# resolve any libregnum symbol), including optional ones with extra deps that
# must follow the archive on the link line: crispy's REPL -> libreadline,
# yaml-glib -> libyaml, and a net loader -> libsoup.  Order is archive (in
# CMACS_LIBREGNUM_LIBS) -> CAD -> these after-archive deps.
ARCHIVE_DEPS := $(shell pkg-config --libs libsoup-3.0 yaml-0.1 2>/dev/null)
HAVE_READLINE := $(shell pkg-config --exists readline && echo yes)
ifeq ($(HAVE_READLINE),yes)
ARCHIVE_DEPS += $(shell pkg-config --libs readline)
endif
LDFLAGS += -rdynamic $(PKG_LIBS) $(CMACS_LIBREGNUM_LIBS) $(CMACS_CAD_LIBS) \
           $(ARCHIVE_DEPS) -lm

OUTDIR  ?= .
OBJDIR  := $(OUTDIR)/ssr-obj
BIN     := $(OUTDIR)/cmacs-screensaver-render

LOCAL_HDRS := config.h ssr-renderer.h ssr-ipc.h ssr-shm.h \
              ../cmacs-screensaver-proto.h ../../libregnum/cmacs-libregnum-render.h

OBJS := $(OBJDIR)/ssr-main.o $(OBJDIR)/ssr-renderer.o $(OBJDIR)/ssr-ipc.o \
        $(OBJDIR)/ssr-shm.o $(OBJDIR)/cmacs-screensaver-proto.o \
        $(OBJDIR)/cmacs-libregnum-render.o

.PHONY: all clean check

all: $(BIN)

$(BIN): $(OBJS)
	$(CC) -o $@ $(OBJS) $(LDFLAGS)

$(OBJDIR):
	mkdir -p $@

# Local sources (in this directory).
$(OBJDIR)/%.o: %.c $(LOCAL_HDRS) | $(OBJDIR)
	$(CC) $(CFLAGS) -c $< -o $@

# Shared protocol (one dir up) and the libregnum render core (compiled fresh
# against our shim config.h, independent of the copy linked into Emacs).
$(OBJDIR)/cmacs-screensaver-proto.o: ../cmacs-screensaver-proto.c \
                                     ../cmacs-screensaver-proto.h | $(OBJDIR)
	$(CC) $(CFLAGS) -c $< -o $@

$(OBJDIR)/cmacs-libregnum-render.o: ../../libregnum/cmacs-libregnum-render.c \
                                    ../../libregnum/cmacs-libregnum-render.h \
                                    config.h | $(OBJDIR)
	$(CC) $(CFLAGS) -c $< -o $@

check: all
	$(MAKE) -C tests check OUTDIR=$(abspath $(OUTDIR))

clean:
	rm -rf $(OBJDIR) $(BIN)
	-$(MAKE) -C tests clean 2>/dev/null
