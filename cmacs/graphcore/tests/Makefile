# cmacs/graphcore/tests/Makefile --- unit tests for the shared graph model
# and layout solver.  Pure: no Emacs, no GL, no display.
#
# `-I.' puts this directory's shim config.h first on the path so the graphcore
# sources' `#include <config.h>' resolves without dragging in Emacs's gnulib
# config.  That the shim is a two-line file is the firewall working: graphcore
# includes neither lisp.h nor libregnum.h, which is exactly what makes the
# solver testable here rather than only behind a live display.
#
# Run: make -C cmacs/graphcore/tests check

CC       ?= gcc
PKGS     := glib-2.0
PKG_CFLAGS := $(shell pkg-config --cflags $(PKGS))
PKG_LIBS   := $(shell pkg-config --libs $(PKGS))

# -I.   : the shim config.h
# -I..  : cmacs-graphcore-{graph,layout}.h
CFLAGS  += -std=gnu11 -O2 -g -Wall -Wextra -Wno-unused-parameter \
           -I. -I.. $(PKG_CFLAGS)
LDFLAGS += $(PKG_LIBS) -lm

OUTDIR  ?= .
BIN     := $(OUTDIR)/test-graphcore
SRCS    := test-graphcore.c ../cmacs-graphcore-graph.c ../cmacs-graphcore-layout.c
HDRS    := ../cmacs-graphcore-graph.h ../cmacs-graphcore-layout.h config.h

.PHONY: all check clean

all: $(BIN)

$(BIN): $(SRCS) $(HDRS)
	$(CC) $(CFLAGS) -o $@ $(SRCS) $(LDFLAGS)

check: $(BIN)
	$(BIN)

clean:
	rm -f $(BIN)
