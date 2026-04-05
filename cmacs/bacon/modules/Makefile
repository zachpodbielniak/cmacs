MODULE_NAME := cmacs_gi

# Only the bacon-specific files remain here; the command implementations
# and transport layer now live in cmacs/api/ as libcmacs-api.so.
SRCS        := cmacs-gi-module.c cmacs-gi-command.c

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

.PHONY: all clean api

all: api $(OUTDIR)/$(MODULE_NAME).so

# Build the shared API library first.
api:
	$(MAKE) -C $(API_DIR)

$(OUTDIR)/$(MODULE_NAME).so: $(SRCS) $(API_DIR)/libcmacs-api.so
	$(CC) $(CFLAGS) -o $@ $(SRCS) $(LDFLAGS)

clean:
	rm -f $(OUTDIR)/$(MODULE_NAME).so
	$(MAKE) -C $(API_DIR) clean
