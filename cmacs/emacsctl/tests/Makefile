# cmacs/emacsctl/tests/Makefile --- GTest unit tests for emacsctl.
#
# `make -C cmacs/emacsctl check' builds and runs them; no running
# editor required (transport-free internals only).

CC       ?= gcc
PKGS     := glib-2.0 gobject-2.0 gio-2.0 gio-unix-2.0 \
            json-glib-1.0 yaml-0.1
PKG_CFLAGS := $(shell pkg-config --cflags $(PKGS))
PKG_LIBS   := $(shell pkg-config --libs $(PKGS))

# Statically vendored yaml-glib, mirroring ../Makefile --- wildcarded
# there and here so a submodule bump that adds a source file cannot go
# stale into an undefined-reference link failure.
YAMLGLIB_DIR ?= ../../../deps/bacon/deps/yaml-glib
YAMLGLIB_SRCS := $(sort $(wildcard $(YAMLGLIB_DIR)/src/*.c))

HAVE_READLINE := $(shell pkg-config --exists readline && echo yes)
ifeq ($(HAVE_READLINE),yes)
PKG_CFLAGS += $(shell pkg-config --cflags readline) \
              -DHAVE_EMACSCTL_READLINE
PKG_LIBS   += $(shell pkg-config --libs readline)
endif

# The units under test (no main.o, no application/dbus layers needed
# beyond what the tested units pull in).
UNITS := ../ctl-error.c ../ctl-result.c ../ctl-json-yaml.c ../ctl-frame.c \
         ../ctl-config.c ../ctl-repl.c \
         ../ctl-transport.c ../ctl-invocation.c \
         ../ctl-transport-dbus.c ../ctl-transport-ssh.c \
         ../ctl-formatter.c ../ctl-formatter-table.c \
         ../ctl-formatter-json.c ../ctl-formatter-yaml.c \
         ../ctl-formatter-raw.c

CFLAGS += -std=gnu89 -Wall -Wextra -Wno-unused-parameter \
          -I.. -I$(YAMLGLIB_DIR)/src $(PKG_CFLAGS)

.PHONY: check clean

check: test-ctl
	./test-ctl

test-ctl: test-ctl.c $(UNITS) $(YAMLGLIB_SRCS)
	$(CC) $(CFLAGS) -o $@ test-ctl.c $(UNITS) $(YAMLGLIB_SRCS) $(PKG_LIBS)

clean:
	rm -f test-ctl
