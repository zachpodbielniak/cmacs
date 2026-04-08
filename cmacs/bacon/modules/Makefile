BACON_DIR   ?= ../../../deps/bacon
API_DIR     ?= ../../api
CC          ?= gcc
PKG_CFLAGS  := $(shell pkg-config --cflags glib-2.0 gobject-2.0 gmodule-2.0 gio-2.0 json-glib-1.0)
PKG_LIBS    := $(shell pkg-config --libs glib-2.0 gobject-2.0 gmodule-2.0 gio-2.0 json-glib-1.0)

CFLAGS      += -std=gnu89 -Wall -Wextra -Wno-unused-parameter \
               -fPIC -shared \
               -DBACON_COMPILATION \
               -I$(BACON_DIR) -I$(BACON_DIR)/src \
               -I$(API_DIR) \
               $(PKG_CFLAGS)
LDFLAGS     += -L$(API_DIR) -lcmacs-api -Wl,-rpath,'$$ORIGIN/../../api' \
               $(PKG_LIBS)

OUTDIR      ?= .

# ── cmacs_gi module ──────────────────────────────────────────────────

GI_SRCS := cmacs-gi-module.c cmacs-gi-command.c

$(OUTDIR)/cmacs_gi.so: $(GI_SRCS) $(API_DIR)/libcmacs-api.so
	$(CC) $(CFLAGS) -o $@ $(GI_SRCS) $(LDFLAGS)

# ── cmacs_pod module ─────────────────────────────────────────────────

POD_SRCS := cmacs-pod-module.c cmacs-pod-command.c

$(OUTDIR)/cmacs_pod.so: $(POD_SRCS) $(API_DIR)/libcmacs-api.so
	$(CC) $(CFLAGS) -o $@ $(POD_SRCS) $(LDFLAGS) -lreadline

# ── Targets ──────────────────────────────────────────────────────────

.PHONY: all clean api

all: api $(OUTDIR)/cmacs_gi.so $(OUTDIR)/cmacs_pod.so

# Build the shared API library first.
api:
	$(MAKE) -C $(API_DIR)

clean:
	rm -f $(OUTDIR)/cmacs_gi.so $(OUTDIR)/cmacs_pod.so
	$(MAKE) -C $(API_DIR) clean
