# cmacs/screensaver/render/tests/Makefile --- unit tests for the screensaver
# protocol + shared-memory seqlock.  Pure: no Emacs, no GL.
#
# `-I..' puts the render directory's minimal shim config.h first on the path so
# cmacs-screensaver-proto.c's `#include <config.h>' resolves without dragging in
# Emacs's gnulib config.

CC       ?= gcc
PKGS     := glib-2.0 gobject-2.0 gio-2.0 gio-unix-2.0 json-glib-1.0
PKG_CFLAGS := $(shell pkg-config --cflags $(PKGS))
PKG_LIBS   := $(shell pkg-config --libs $(PKGS))

# -I..  : render/config.h shim (resolves proto.c's <config.h>)
# -I../.. : cmacs-screensaver-proto.h
CFLAGS  += -std=gnu11 -O2 -g -Wall -Wextra -Wno-unused-parameter \
           -I.. -I../.. $(PKG_CFLAGS)
LDFLAGS += $(PKG_LIBS) -lpthread

OUTDIR  ?= .
BIN     := $(OUTDIR)/test-proto
SRCS    := test-proto.c ../../cmacs-screensaver-proto.c

.PHONY: all check clean

all: $(BIN)

$(BIN): $(SRCS) ../../cmacs-screensaver-proto.h
	$(CC) $(CFLAGS) -o $@ $(SRCS) $(LDFLAGS)

check: $(BIN)
	$(BIN)
	sh guard-symbols.sh

clean:
	rm -f $(BIN)
