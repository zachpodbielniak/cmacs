# cmacs-mcp Makefile — MCP stdio-to-socket relay
#
# Copyright (C) 2026 Zach Podbielniak
# SPDX-License-Identifier: AGPL-3.0-or-later

PREFIX  ?= /usr/local
BINDIR  ?= $(PREFIX)/bin
CC      ?= gcc
CSTD    ?= -std=gnu11
INSTALL ?= install

PKG_DEPS   = glib-2.0 gio-2.0 gio-unix-2.0
PKG_CFLAGS = $(shell pkg-config --cflags $(PKG_DEPS))
PKG_LIBS   = $(shell pkg-config --libs $(PKG_DEPS))

CFLAGS  ?= -O2 -g
WFLAGS   = -Wall -Wextra -Wno-unused-parameter

.PHONY: all clean install uninstall

all: cmacs-mcp

cmacs-mcp: cmacs-mcp.c
	$(CC) $(CSTD) $(WFLAGS) $(CFLAGS) $(PKG_CFLAGS) -o $@ $< $(PKG_LIBS)

clean:
	rm -f cmacs-mcp

install: cmacs-mcp
	$(INSTALL) -d $(DESTDIR)$(BINDIR)
	$(INSTALL) -m 755 cmacs-mcp $(DESTDIR)$(BINDIR)/cmacs-mcp

uninstall:
	rm -f $(DESTDIR)$(BINDIR)/cmacs-mcp
