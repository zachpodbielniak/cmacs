# Makefile - cmacs-specific gsurf modules
#
# Invoked by src/Makefile.in's `cmacs-gsurf-modules' target with
# GSURF_DIR pointing at the bundled gsurf submodule.  Each *.c here is an
# independent GsurfModule subclass exporting gsurf_module_register(),
# built into a sibling <basename>.so loaded at runtime by the embedded
# module manager (CMACS_GSURF_MODULE_DIR = this directory).
#
# These modules deliberately link NOTHING for gsurf_*/yaml_* or
# cmacs_gsurf_emacs_eval_async: temacs is linked --export-dynamic and
# whole-archives libgsurf, so the loaded .so resolves every gsurf symbol
# (and the cmacs eval bridge) against the emacs executable at load time
# -- one library instance, no duplicate GType registration.  The link is
# therefore left with undefined symbols on purpose.

GSURF_DIR   ?= ../../../deps/gsurf
CC          ?= gcc

# <gsurf/gsurf.h> resolves through the dev-include symlink gsurf's build
# creates at $(GSURF_DIR)/build/include/gsurf -> src.  gsurf.h pulls in
# the vendored crispy/yaml-glib headers transitively, so add their src
# dirs and the generated-header dir ($(GSURF_DIR)/build/release) too.
GSURF_INC   := -I$(GSURF_DIR)/build/include \
               -I$(GSURF_DIR)/src \
               -I$(GSURF_DIR)/deps/yaml-glib/src \
               -I$(GSURF_DIR)/deps/crispy/src \
               -I$(GSURF_DIR)/build/release

PKG_DEPS    := glib-2.0 gobject-2.0 gio-2.0 gmodule-2.0 yaml-0.1 json-glib-1.0
PKG_CFLAGS  := $(shell pkg-config --cflags $(PKG_DEPS))
PKG_LIBS    := $(shell pkg-config --libs $(PKG_DEPS))

CFLAGS      += -std=gnu11 -Wall -Wextra -Wno-unused-parameter \
               -fPIC \
               $(GSURF_INC) \
               $(PKG_CFLAGS)
# Undefined gsurf_*/cmacs_gsurf_* symbols are resolved from temacs at
# runtime; allow them to stay unresolved in the .so.
LDFLAGS     += -shared $(PKG_LIBS)

OUTDIR      ?= .

SRCS        := $(wildcard *.c)
MODULES     := $(patsubst %.c,$(OUTDIR)/%.so,$(SRCS))

.PHONY: all clean

all: $(MODULES)

$(OUTDIR)/%.so: %.c
	@mkdir -p $(OUTDIR)
	$(CC) $(CFLAGS) -o $@ $< $(LDFLAGS)

clean:
	rm -f $(MODULES)
