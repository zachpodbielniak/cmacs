# cmacs/api/Makefile --- build libcmacs-api.so
#
# The CMacs API shared library.  Consumed by both the bacon cmacsgi
# module and crispy scripts (via init.c).
#
# Dependencies: glib-2.0, gobject-2.0, gio-2.0, json-glib-1.0
# No dependency on Emacs internals or bacon.

SRCS := cmacs-api-transport.c cmacs-api-helpers.c \
        cmacs-api-high-level.c \
        cmacs-api-cmd-buf.c cmacs-api-cmd-file.c \
        cmacs-api-cmd-text.c cmacs-api-cmd-nav.c \
        cmacs-api-cmd-search.c cmacs-api-cmd-win.c \
        cmacs-api-cmd-config.c cmacs-api-cmd-project.c \
        cmacs-api-cmd-mark.c cmacs-api-cmd-clip.c \
        cmacs-api-cmd-vc.c cmacs-api-cmd-pkg.c \
        cmacs-api-cmd-monitor.c \
        cmacs-api-cmd-rg.c cmacs-api-cmd-bar.c \
        cmacs-api-cmd-cintrospect.c

CC       ?= gcc
PKG_CFLAGS := $(shell pkg-config --cflags glib-2.0 gobject-2.0 \
                       gio-2.0 json-glib-1.0)
PKG_LIBS   := $(shell pkg-config --libs glib-2.0 gobject-2.0 \
                       gio-2.0 json-glib-1.0)

CFLAGS   += -std=gnu89 -Wall -Wextra -Wno-unused-parameter \
            -fPIC -shared \
            -I. $(PKG_CFLAGS)
LDFLAGS  += $(PKG_LIBS)

OUTDIR   ?= .

.PHONY: all clean

all: $(OUTDIR)/libcmacs-api.so

$(OUTDIR)/libcmacs-api.so: $(SRCS) cmacs-api.h
	$(CC) $(CFLAGS) -o $@ $(SRCS) $(LDFLAGS)

clean:
	rm -f $(OUTDIR)/libcmacs-api.so
