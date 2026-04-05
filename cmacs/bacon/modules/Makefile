MODULE_NAME := cmacs_gi
SRCS        := cmacs-gi-module.c cmacs-gi-command.c \
               cmacs-gi-transport.c \
               cmacs-gi-cmd-buf.c cmacs-gi-cmd-file.c \
               cmacs-gi-cmd-text.c cmacs-gi-cmd-nav.c \
               cmacs-gi-cmd-search.c cmacs-gi-cmd-win.c \
               cmacs-gi-cmd-config.c cmacs-gi-cmd-project.c \
               cmacs-gi-cmd-mark.c cmacs-gi-cmd-clip.c \
               cmacs-gi-cmd-vc.c cmacs-gi-cmd-pkg.c

BACON_DIR   ?= ../../../deps/bacon
CC          ?= gcc
PKG_CFLAGS  := $(shell pkg-config --cflags glib-2.0 gobject-2.0 gmodule-2.0 gio-2.0 json-glib-1.0)
PKG_LIBS    := $(shell pkg-config --libs glib-2.0 gobject-2.0 gmodule-2.0 gio-2.0 json-glib-1.0)

CFLAGS      += -std=gnu89 -Wall -Wextra -Wno-unused-parameter \
               -fPIC -shared \
               -DBACON_COMPILATION \
               -I$(BACON_DIR) -I$(BACON_DIR)/src \
               $(PKG_CFLAGS)
LDFLAGS     += $(PKG_LIBS)

OUTDIR      ?= .

.PHONY: all clean

all: $(OUTDIR)/$(MODULE_NAME).so

$(OUTDIR)/$(MODULE_NAME).so: $(SRCS)
	$(CC) $(CFLAGS) -o $@ $^ $(LDFLAGS)

clean:
	rm -f $(OUTDIR)/$(MODULE_NAME).so
