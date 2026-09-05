# cmacs/emacsctl/Makefile --- build emacsctl (and the cmacsctl symlink)
#
# A standalone kubectl-style CLI for a running cmacs instance.
# Links NO Emacs objects and NO vendored archives: pure GLib/GObject,
# GIO, json-glib, yaml-glib (+ optional readline for the REPL).
#
# Invoked from src/Makefile.in with OUTDIR=<build src dir>, mirroring
# cmacs/api/Makefile.

SRCS := ctl-main.c ctl-application.c ctl-error.c \
        ctl-command.c ctl-command-registry.c \
        ctl-invocation.c ctl-result.c \
        ctl-formatter.c ctl-formatter-table.c ctl-formatter-json.c \
        ctl-formatter-yaml.c ctl-formatter-raw.c ctl-json-yaml.c \
        ctl-transport.c ctl-transport-dbus.c ctl-transport-ssh.c \
        ctl-frame.c ctl-proxy.c \
        ctl-config.c ctl-repl.c ctl-watcher.c ctl-completion.c \
        ctl-cmd-core.c ctl-cmd-editor.c ctl-cmd-subsys.c ctl-cmd-sb.c \
        ctl-cmd-gowl.c

HDRS := ctl.h ctl-ifaces.h ctl-application.h ctl-command.h \
        ctl-command-registry.h ctl-invocation.h ctl-result.h \
        ctl-formatter.h ctl-json-yaml.h ctl-transport.h \
        ctl-transport-dbus.h ctl-transport-ssh.h ctl-frame.h \
        ctl-proxy.h ctl-config.h ctl-repl.h ctl-watcher.h \
        ctl-completion.h

CC       ?= gcc
PKGS     := glib-2.0 gobject-2.0 gio-2.0 gio-unix-2.0 \
            json-glib-1.0 yaml-0.1
PKG_CFLAGS := $(shell pkg-config --cflags $(PKGS))
PKG_LIBS   := $(shell pkg-config --libs $(PKGS))

# yaml-glib is statically vendored (same sources the bacon/podomation
# archives compile into src/emacs), so emacsctl needs no system
# yaml-glib package --- only libyaml (yaml-0.1 above).  Exactly one
# copy links into this binary, so the static-library dedup concern
# from src/Makefile.in does not apply here.
YAMLGLIB_DIR ?= ../../deps/bacon/deps/yaml-glib
YAMLGLIB_SRCS := \
        $(YAMLGLIB_DIR)/src/yaml-builder.c \
        $(YAMLGLIB_DIR)/src/yaml-document.c \
        $(YAMLGLIB_DIR)/src/yaml-generator.c \
        $(YAMLGLIB_DIR)/src/yaml-gobject.c \
        $(YAMLGLIB_DIR)/src/yaml-mapping.c \
        $(YAMLGLIB_DIR)/src/yaml-node.c \
        $(YAMLGLIB_DIR)/src/yaml-parser.c \
        $(YAMLGLIB_DIR)/src/yaml-schema.c \
        $(YAMLGLIB_DIR)/src/yaml-sequence.c \
        $(YAMLGLIB_DIR)/src/yaml-serializable.c

# Optional GNU readline for REPL line editing (fgets fallback).
HAVE_READLINE := $(shell pkg-config --exists readline && echo yes)
ifeq ($(HAVE_READLINE),yes)
PKG_CFLAGS += $(shell pkg-config --cflags readline) \
              -DHAVE_EMACSCTL_READLINE
PKG_LIBS   += $(shell pkg-config --libs readline)
endif

CFLAGS   += -std=gnu89 -Wall -Wextra -Wno-unused-parameter \
            -I. -I$(YAMLGLIB_DIR)/src $(PKG_CFLAGS)
LDFLAGS  += $(PKG_LIBS)

OUTDIR   ?= .

.PHONY: all clean check

all: $(OUTDIR)/emacsctl $(OUTDIR)/cmacsctl

$(OUTDIR)/emacsctl: $(SRCS) $(HDRS)
	$(CC) $(CFLAGS) -o $@ $(SRCS) $(YAMLGLIB_SRCS) $(LDFLAGS)

# cmacsctl is the same binary by another name (argv[0]-insensitive).
$(OUTDIR)/cmacsctl: $(OUTDIR)/emacsctl
	ln -sf emacsctl $@

check: $(OUTDIR)/emacsctl
	$(MAKE) -C tests check OUTDIR=$(abspath $(OUTDIR))

clean:
	rm -f $(OUTDIR)/emacsctl $(OUTDIR)/cmacsctl
	-$(MAKE) -C tests clean 2>/dev/null
