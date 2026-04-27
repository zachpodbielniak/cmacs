# cmacs/org-ex/lib/Makefile --- build liborgex-1.0
#
# The org-ex library.  Provides GObject types for the org-ex
# widget system.  No dependency on Emacs internals.
#
# Targets:
#   all     — shared library (liborgex-1.0.so)
#   static  — static library (liborgex-1.0.a) for embedding into emacs
#   gir     — GObject Introspection typelib
#
# Dependencies: glib-2.0, gobject-2.0, gio-2.0

SRCS := org-ex-enums.c \
        interfaces/org-ex-renderable.c \
        interfaces/org-ex-exportable.c \
        core/org-ex-widget.c \
        core/org-ex-widget-gtk.c \
        core/org-ex-widget-web.c \
        core/org-ex-widget-buffer.c \
        core/org-ex-widget-code.c \
        core/org-ex-ink-stroke.c \
        core/org-ex-ink-render.c \
        core/org-ex-document.c \
        core/org-ex-binding.c \
        core/org-ex-channel.c \
        boxed/org-ex-widget-state.c

HDRS := org-ex.h org-ex-types.h \
        interfaces/org-ex-renderable.h \
        interfaces/org-ex-exportable.h \
        core/org-ex-widget.h \
        core/org-ex-widget-gtk.h \
        core/org-ex-widget-web.h \
        core/org-ex-widget-buffer.h \
        core/org-ex-widget-code.h \
        core/org-ex-ink-stroke.h \
        core/org-ex-ink-render.h \
        core/org-ex-document.h \
        core/org-ex-binding.h \
        core/org-ex-channel.h \
        boxed/org-ex-widget-state.h

OBJS := $(SRCS:.c=.o)

CC       ?= gcc
AR       ?= ar
PKG_CFLAGS := $(shell pkg-config --cflags glib-2.0 gobject-2.0 gio-2.0 cairo)
PKG_LIBS   := $(shell pkg-config --libs glib-2.0 gobject-2.0 gio-2.0 cairo)

CFLAGS   += -std=gnu89 -Wall -Wextra -Wno-unused-parameter \
            -fPIC \
            -DORG_EX_COMPILATION \
            -I. $(PKG_CFLAGS)
LDFLAGS  += $(PKG_LIBS)

OUTDIR   ?= .

GIR_SCANNER  ?= g-ir-scanner
GIR_COMPILER ?= g-ir-compiler
GIR_NAMESPACE := OrgEx
GIR_VERSION   := 1.0

.PHONY: all static clean gir

all: $(OUTDIR)/liborgex-1.0.so

static: $(OUTDIR)/liborgex-1.0.a

%.o: %.c $(HDRS)
	@mkdir -p $(dir $@)
	$(CC) $(CFLAGS) -c -o $@ $<

$(OUTDIR)/liborgex-1.0.a: $(OBJS)
	$(AR) rcs $@ $(OBJS)

$(OUTDIR)/liborgex-1.0.so: $(SRCS) $(HDRS)
	$(CC) $(CFLAGS) -shared -Wl,-soname,liborgex-1.0.so -o $@ $(SRCS) $(LDFLAGS)

# GObject Introspection (optional: make BUILD_GIR=1 gir)
gir: $(OUTDIR)/$(GIR_NAMESPACE)-$(GIR_VERSION).typelib

$(OUTDIR)/$(GIR_NAMESPACE)-$(GIR_VERSION).gir: $(SRCS) $(HDRS) \
                                                 $(OUTDIR)/liborgex-1.0.so
	$(GIR_SCANNER) \
		--namespace=$(GIR_NAMESPACE) \
		--nsversion=$(GIR_VERSION) \
		--library=orgex-1.0 \
		--library-path=$(OUTDIR) \
		--include=GLib-2.0 \
		--include=GObject-2.0 \
		--include=Gio-2.0 \
		--pkg=glib-2.0 \
		--pkg=gobject-2.0 \
		--pkg=gio-2.0 \
		--output=$@ \
		--warn-all \
		-I. \
		-DORG_EX_COMPILATION \
		$(HDRS) $(SRCS)

$(OUTDIR)/$(GIR_NAMESPACE)-$(GIR_VERSION).typelib: \
		$(OUTDIR)/$(GIR_NAMESPACE)-$(GIR_VERSION).gir
	$(GIR_COMPILER) --output=$@ $<

clean:
	rm -f $(OBJS)
	rm -f $(OUTDIR)/liborgex-1.0.so $(OUTDIR)/liborgex-1.0.a
	rm -f $(OUTDIR)/$(GIR_NAMESPACE)-$(GIR_VERSION).gir
	rm -f $(OUTDIR)/$(GIR_NAMESPACE)-$(GIR_VERSION).typelib
