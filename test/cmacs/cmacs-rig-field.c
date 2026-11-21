/*
 * cmacs-rig-field.c - a window that is one text-input-v3 text field
 *
 * Copyright (C) 2026  Zach Podbielniak
 * SPDX-License-Identifier: AGPL-3.0-or-later
 *
 * The rig (test/cmacs/cmacs-rig.el) needs an application with a real
 * text-input-v3 text field: something the compositor can read with
 * gowl-text-field-read and edit with gowl-text-field-replace.
 *
 * WHY NOT A TOOLKIT.  A GTK entry was the first attempt and cannot work
 * in the rig.  GTK enables its text input only while its window has
 * keyboard focus, which it learns from wl_keyboard.enter -- and a
 * headless gowl has no keyboard device, so its seat advertises no
 * wl_keyboard at all (capabilities 0; a virtual keyboard does not
 * change that, by design, see deps/gowl/src/core/gowl-text-input.c).
 * This program speaks the protocol itself and needs no keyboard: it
 * enables its text input when the compositor ENTERS it, which is what
 * gowl does for the length of a read or an edit.
 *
 * What it does, in protocol terms, is what a toolkit does:
 *
 *   enter                   -> enable, set_surrounding_text,
 *                              set_content_type, commit
 *   delete_surrounding_text,
 *   commit_string, done     -> apply as ONE edit (delete first, then
 *                              insert, as the protocol orders), then
 *                              report the new surrounding text, commit
 *   leave                   -> disable, commit
 *
 * It also rewrites a file with the field's text whenever it changes.
 * That file is what the APPLICATION holds, which is a different
 * question from what the compositor was told: a test that only asked
 * the compositor would pass with an edit that never arrived.
 *
 * Build (the rig does this at run time, into a temporary directory):
 *   P=$(pkg-config --variable=pkgdatadir wayland-protocols)
 *   for x in stable/xdg-shell/xdg-shell \
 *            unstable/text-input/text-input-unstable-v3; do
 *     wayland-scanner client-header $P/$x.xml $(basename $x).h
 *     wayland-scanner private-code  $P/$x.xml $(basename $x).c
 *   done
 *   gcc -std=gnu89 -I. -o cmacs-rig-field cmacs-rig-field.c \
 *       xdg-shell.c text-input-unstable-v3.c \
 *       $(pkg-config --cflags --libs wayland-client glib-2.0)
 * With -DRIG_FIELD_DRAW and pangocairo's flags the window also shows
 * its text, which is only for people looking at screenshots.
 */

#define _GNU_SOURCE
#include <errno.h>
#include <locale.h>
#include <poll.h>
#include <string.h>
#include <sys/mman.h>
#include <unistd.h>

#include <glib.h>
#include <wayland-client.h>
#ifdef RIG_FIELD_DRAW
#include <pango/pangocairo.h>
#endif

#include "xdg-shell.h"
#include "text-input-unstable-v3.h"

#define RIG_FIELD_DEFAULT_TITLE  ("rig-field")
#define RIG_FIELD_WIDTH          (480)
#define RIG_FIELD_HEIGHT         (160)
#define RIG_FIELD_COLOUR         (0xff2e3440)	/* ARGB, opaque slate */
/* The protocol's limit on one set_surrounding_text. */
#define RIG_FIELD_MAX_SURROUND   (4000)

static gchar    *opt_title    = NULL;
static gchar    *opt_app_id   = NULL;
static gchar    *opt_text     = NULL;
static gchar    *opt_dump     = NULL;
static gboolean  opt_password = FALSE;
static gint      opt_heartbeat = 0;
static gboolean  opt_license  = FALSE;

static GOptionEntry rig_field_entries[] = {
	{ "title", 't', 0, G_OPTION_ARG_STRING, &opt_title,
	  "The window's title", "TITLE" },
	{ "app-id", 'a', 0, G_OPTION_ARG_STRING, &opt_app_id,
	  "The window's Wayland app-id", "ID" },
	{ "text", 'x', 0, G_OPTION_ARG_STRING, &opt_text,
	  "What the field holds at first (cursor after it)", "TEXT" },
	{ "dump", 'd', 0, G_OPTION_ARG_FILENAME, &opt_dump,
	  "Rewrite FILE with the field's text whenever it changes", "FILE" },
	{ "password", 'p', 0, G_OPTION_ARG_NONE, &opt_password,
	  "Declare the field a password (content purpose 8)", NULL },
	{ "heartbeat", 'b', 0, G_OPTION_ARG_INT, &opt_heartbeat,
	  "Send the compositor a wl_display.sync every MS milliseconds", "MS" },
	{ "license", 0, 0, G_OPTION_ARG_NONE, &opt_license,
	  "Print the license and exit", NULL },
	{ NULL, 0, 0, G_OPTION_ARG_NONE, NULL, NULL, NULL }
};

/* Everything the program holds.  One window, one field. */
typedef struct
{
	struct wl_display                 *display;
	struct wl_compositor              *compositor;
	struct wl_shm                     *shm;
	struct wl_seat                    *seat;
	struct xdg_wm_base                *wm_base;
	struct zwp_text_input_manager_v3  *ti_manager;
	struct zwp_text_input_v3          *text_input;
	struct wl_surface                 *surface;
	struct xdg_surface                *xdg_surface;
	struct xdg_toplevel               *toplevel;
	struct wl_buffer                  *buffer;
	guint32                           *pixels;	/* the buffer, mapped */
	gboolean                           configured;

	GString   *text;		/* the field, UTF-8 */
	gsize      cursor;		/* a byte offset into it */

	/* One edit, collected between the events and their `done'. */
	guint32    pending_before;
	guint32    pending_after;
	gchar     *pending_commit;
	gboolean   have_pending;

	gboolean   entered;
	gboolean   running;
} RigField;

/**
 * rig_field_dump:
 * @field: the field
 *
 * Replace the dump file with the field's text.  g_file_set_contents()
 * writes a temporary file and renames it, so a reader never sees half
 * a write.
 */
static void
rig_field_dump(
	RigField *field
){
	g_autoptr(GError) error = NULL;

	if (opt_dump == NULL)
		return;
	if (!g_file_set_contents(opt_dump, field->text->str,
	                         (gssize)field->text->len, &error))
		g_printerr("cmacs-rig-field: %s: %s\n", opt_dump,
		           error->message);
}

/**
 * rig_field_report:
 * @field: the field
 *
 * Tell the compositor what the field holds and what kind it is, as a
 * toolkit does after every change.  Text past the protocol's limit is
 * not sent whole: a window around the cursor goes instead, cut between
 * characters, which is what the limit obliges a real client to do.
 */
static void
rig_field_report(
	RigField *field
){
	const gchar *text;
	gsize len;
	gsize start;
	gsize end;
	g_autofree gchar *window = NULL;

	text = field->text->str;
	len = field->text->len;
	start = 0;
	end = len;
	if (len > RIG_FIELD_MAX_SURROUND) {
		gsize half;

		half = RIG_FIELD_MAX_SURROUND / 2;
		start = (field->cursor > half) ? field->cursor - half : 0;
		end = MIN(len, start + RIG_FIELD_MAX_SURROUND);
		/* Never cut inside a character. */
		while (start < len && (((guchar)text[start]) & 0xC0) == 0x80)
			start++;
		while (end > start && end < len
		       && (((guchar)text[end]) & 0xC0) == 0x80)
			end--;
	}
	window = g_strndup(text + start, end - start);

	zwp_text_input_v3_set_surrounding_text(field->text_input, window,
		(gint32)(field->cursor - start),
		(gint32)(field->cursor - start));
	zwp_text_input_v3_set_content_type(field->text_input,
		opt_password
			? (ZWP_TEXT_INPUT_V3_CONTENT_HINT_HIDDEN_TEXT
			   | ZWP_TEXT_INPUT_V3_CONTENT_HINT_SENSITIVE_DATA)
			: ZWP_TEXT_INPUT_V3_CONTENT_HINT_NONE,
		opt_password
			? ZWP_TEXT_INPUT_V3_CONTENT_PURPOSE_PASSWORD
			: ZWP_TEXT_INPUT_V3_CONTENT_PURPOSE_NORMAL);
	zwp_text_input_v3_commit(field->text_input);
}

static void rig_field_draw(RigField *field);

/* ── text-input-v3 ─────────────────────────────────────────────── */

static void
ti_enter(
	void                     *data,
	struct zwp_text_input_v3 *ti,
	struct wl_surface        *surface
){
	RigField *field = (RigField *)data;

	(void)surface;
	field->entered = TRUE;
	/* The field always has the program's focus: there is nothing
	   else in the window.  So an entered text input is an enabled
	   one, which is what makes this a text field to gowl. */
	zwp_text_input_v3_enable(ti);
	rig_field_report(field);
}

static void
ti_leave(
	void                     *data,
	struct zwp_text_input_v3 *ti,
	struct wl_surface        *surface
){
	RigField *field = (RigField *)data;

	(void)surface;
	field->entered = FALSE;
	zwp_text_input_v3_disable(ti);
	zwp_text_input_v3_commit(ti);
}

static void
ti_preedit_string(
	void                     *data,
	struct zwp_text_input_v3 *ti,
	const char               *text,
	int32_t                   cursor_begin,
	int32_t                   cursor_end
){
	/* Nothing is composed here: the rig commits whole strings. */
	(void)data; (void)ti; (void)text;
	(void)cursor_begin; (void)cursor_end;
}

static void
ti_commit_string(
	void                     *data,
	struct zwp_text_input_v3 *ti,
	const char               *text
){
	RigField *field = (RigField *)data;

	(void)ti;
	g_free(field->pending_commit);
	field->pending_commit = g_strdup(text);
	field->have_pending = TRUE;
}

static void
ti_delete_surrounding_text(
	void                     *data,
	struct zwp_text_input_v3 *ti,
	uint32_t                  before_length,
	uint32_t                  after_length
){
	RigField *field = (RigField *)data;

	(void)ti;
	field->pending_before = before_length;
	field->pending_after = after_length;
	field->have_pending = TRUE;
}

/**
 * ti_done:
 *
 * Apply what arrived since the last `done' as one edit.  The protocol
 * fixes the order whatever order the events came in: the surrounding
 * text is deleted first, then the string is inserted at the cursor.
 */
static void
ti_done(
	void                     *data,
	struct zwp_text_input_v3 *ti,
	uint32_t                  serial
){
	RigField *field = (RigField *)data;
	gsize before;
	gsize after;

	(void)ti; (void)serial;
	if (!field->have_pending)
		return;

	/* A count past either end is the whole of that side. */
	before = MIN((gsize)field->pending_before, field->cursor);
	after = MIN((gsize)field->pending_after,
	            field->text->len - field->cursor);
	g_string_erase(field->text, (gssize)(field->cursor - before),
	               (gssize)(before + after));
	field->cursor -= before;
	if (field->pending_commit != NULL) {
		g_string_insert(field->text, (gssize)field->cursor,
		                field->pending_commit);
		field->cursor += strlen(field->pending_commit);
	}

	g_clear_pointer(&field->pending_commit, g_free);
	field->pending_before = 0;
	field->pending_after = 0;
	field->have_pending = FALSE;

	rig_field_dump(field);
	if (field->entered)
		rig_field_report(field);
	rig_field_draw(field);
}

/* Designated, and only the events of version 1: the generated struct
   grows a member with each protocol revision (`action' in newer
   wayland-protocols), and a positional initializer would then warn on
   one machine and not on another. */
static const struct zwp_text_input_v3_listener ti_listener = {
	.enter                   = ti_enter,
	.leave                   = ti_leave,
	.preedit_string          = ti_preedit_string,
	.commit_string           = ti_commit_string,
	.delete_surrounding_text = ti_delete_surrounding_text,
	.done                    = ti_done
};

/* ── The window ────────────────────────────────────────────────── */

/**
 * rig_field_make_buffer:
 * @field: the field
 *
 * One wl_shm buffer of the window's size, left mapped so the field can
 * be drawn into it (rig_field_draw()).
 *
 * Returns: %TRUE when the buffer exists
 */
static gboolean
rig_field_make_buffer(
	RigField *field
){
	struct wl_shm_pool *pool;
	guint32 *pixels;
	gsize size;
	gsize i;
	gint stride;
	gint fd;

	stride = RIG_FIELD_WIDTH * 4;
	size = (gsize)stride * RIG_FIELD_HEIGHT;
	fd = memfd_create("cmacs-rig-field", MFD_CLOEXEC);
	if (fd < 0 || ftruncate(fd, (off_t)size) < 0) {
		g_printerr("cmacs-rig-field: shm: %s\n", g_strerror(errno));
		return FALSE;
	}
	pixels = (guint32 *)mmap(NULL, size, PROT_READ | PROT_WRITE,
	                         MAP_SHARED, fd, 0);
	if (pixels == MAP_FAILED) {
		g_printerr("cmacs-rig-field: mmap: %s\n", g_strerror(errno));
		close(fd);
		return FALSE;
	}
	for (i = 0; i < size / 4; i++)
		pixels[i] = RIG_FIELD_COLOUR;
	field->pixels = pixels;

	pool = wl_shm_create_pool(field->shm, fd, (gint32)size);
	field->buffer = wl_shm_pool_create_buffer(pool, 0, RIG_FIELD_WIDTH,
		RIG_FIELD_HEIGHT, stride, WL_SHM_FORMAT_ARGB8888);
	wl_shm_pool_destroy(pool);
	close(fd);
	return field->buffer != NULL;
}

/**
 * rig_field_draw:
 * @field: the field
 *
 * Paint the window and show it: the title, and the field's text in a
 * box.  No test reads these pixels -- the dump file is the evidence --
 * but a person looking at a screenshot of the rig should see what the
 * field holds.  Built without pangocairo the window is one colour.
 * A password field shows dots, as one would.
 */
static void
rig_field_draw(
	RigField *field
){
	gsize i;

	if (!field->configured || field->pixels == NULL)
		return;
	for (i = 0; i < (gsize)RIG_FIELD_WIDTH * RIG_FIELD_HEIGHT; i++)
		field->pixels[i] = RIG_FIELD_COLOUR;
#ifdef RIG_FIELD_DRAW
	{
		cairo_surface_t *surface;
		cairo_t *cr;
		PangoLayout *layout;
		PangoFontDescription *font;
		g_autofree gchar *shown = NULL;

		surface = cairo_image_surface_create_for_data(
			(guchar *)field->pixels, CAIRO_FORMAT_ARGB32,
			RIG_FIELD_WIDTH, RIG_FIELD_HEIGHT, RIG_FIELD_WIDTH * 4);
		cr = cairo_create(surface);
		layout = pango_cairo_create_layout(cr);
		font = pango_font_description_from_string("Sans 11");
		pango_layout_set_font_description(layout, font);
		pango_layout_set_width(layout,
			(RIG_FIELD_WIDTH - 40) * PANGO_SCALE);
		pango_layout_set_wrap(layout, PANGO_WRAP_WORD_CHAR);

		/* The title, so a picture says which window this is. */
		cairo_set_source_rgb(cr, 0.60, 0.66, 0.75);
		cairo_move_to(cr, 12, 8);
		pango_layout_set_text(layout,
			opt_title != NULL ? opt_title : RIG_FIELD_DEFAULT_TITLE,
			-1);
		pango_cairo_show_layout(cr, layout);

		/* The field: a box, and what is in it. */
		cairo_set_source_rgb(cr, 0.93, 0.94, 0.96);
		cairo_rectangle(cr, 12, 36, RIG_FIELD_WIDTH - 24,
		                RIG_FIELD_HEIGHT - 48);
		cairo_fill(cr);
		cairo_set_source_rgb(cr, 0.10, 0.11, 0.13);
		cairo_move_to(cr, 20, 44);
		shown = opt_password
			? g_strnfill(g_utf8_strlen(field->text->str, -1), '*')
			: g_strdup(field->text->str);
		pango_layout_set_text(layout, shown, -1);
		pango_cairo_show_layout(cr, layout);

		pango_font_description_free(font);
		g_object_unref(layout);
		cairo_destroy(cr);
		cairo_surface_flush(surface);
		cairo_surface_destroy(surface);
	}
#endif
	wl_surface_attach(field->surface, field->buffer, 0, 0);
	wl_surface_damage_buffer(field->surface, 0, 0, RIG_FIELD_WIDTH,
	                         RIG_FIELD_HEIGHT);
	wl_surface_commit(field->surface);
}

static void
xdg_surface_configure(
	void               *data,
	struct xdg_surface *xdg_surface,
	uint32_t            serial
){
	RigField *field = (RigField *)data;

	/* Whatever size was asked for, the same buffer goes back: a
	   window smaller than its tile is a legal window. */
	xdg_surface_ack_configure(xdg_surface, serial);
	field->configured = TRUE;
	rig_field_draw(field);
}

static const struct xdg_surface_listener xdg_surface_listener = {
	xdg_surface_configure
};

static void
toplevel_configure(
	void                *data,
	struct xdg_toplevel *toplevel,
	int32_t              width,
	int32_t              height,
	struct wl_array     *states
){
	(void)data; (void)toplevel; (void)width; (void)height; (void)states;
}

static void
toplevel_close(
	void                *data,
	struct xdg_toplevel *toplevel
){
	RigField *field = (RigField *)data;

	(void)toplevel;
	field->running = FALSE;
}

/* xdg_wm_base is bound at version 1, which sends only these two. */
static const struct xdg_toplevel_listener toplevel_listener = {
	.configure = toplevel_configure,
	.close     = toplevel_close
};

static void
wm_base_ping(
	void               *data,
	struct xdg_wm_base *wm_base,
	uint32_t            serial
){
	(void)data;
	xdg_wm_base_pong(wm_base, serial);
}

static const struct xdg_wm_base_listener wm_base_listener = {
	wm_base_ping
};

/* ── The heartbeat ─────────────────────────────────────────────── */

static void
sync_done(
	void               *data,
	struct wl_callback *callback,
	uint32_t            serial
){
	(void)data; (void)serial;
	wl_callback_destroy(callback);
}

static const struct wl_callback_listener sync_listener = {
	.done = sync_done
};

/**
 * rig_field_run:
 * @field: the field
 *
 * Dispatch events until the window is closed or the display goes.
 *
 * With --heartbeat this also sends a wl_display.sync every that many
 * milliseconds.  It is what a desktop with anything alive on it looks
 * like to the compositor: a request arrives, its event loop turns, and
 * whatever it had queued for its clients is flushed.  WITHOUT it this
 * client is silent between events, and the compositor's loop sleeps --
 * which is how the rig shows that an event queued for a client from
 * outside that loop (the `enter' of gowl-text-field-read) can sit
 * unsent until something else wakes it.
 */
static void
rig_field_run(
	RigField *field
){
	struct pollfd pfd;
	gint n;

	pfd.fd = wl_display_get_fd(field->display);
	pfd.events = POLLIN;

	while (field->running) {
		/* The documented read protocol: nothing may be pending
		   when the read is announced. */
		while (wl_display_prepare_read(field->display) != 0)
			if (wl_display_dispatch_pending(field->display) < 0)
				return;
		if (!field->running) {
			wl_display_cancel_read(field->display);
			return;
		}
		if (wl_display_flush(field->display) < 0 && errno != EAGAIN) {
			wl_display_cancel_read(field->display);
			return;
		}

		pfd.revents = 0;
		n = poll(&pfd, 1, opt_heartbeat > 0 ? opt_heartbeat : -1);
		if (n > 0) {
			if (wl_display_read_events(field->display) < 0
			    || wl_display_dispatch_pending(field->display) < 0)
				return;
		} else {
			wl_display_cancel_read(field->display);
			if (n < 0 && errno != EINTR)
				return;
			if (n == 0)
				wl_callback_add_listener(
					wl_display_sync(field->display),
					&sync_listener, NULL);
		}
	}
}

/* ── The registry ──────────────────────────────────────────────── */

static void
registry_global(
	void               *data,
	struct wl_registry *registry,
	uint32_t            name,
	const char         *interface,
	uint32_t            version
){
	RigField *field = (RigField *)data;

	(void)version;
	if (g_strcmp0(interface, wl_compositor_interface.name) == 0)
		field->compositor = (struct wl_compositor *)
			wl_registry_bind(registry, name,
			                 &wl_compositor_interface, 4);
	else if (g_strcmp0(interface, wl_shm_interface.name) == 0)
		field->shm = (struct wl_shm *)
			wl_registry_bind(registry, name, &wl_shm_interface, 1);
	else if (g_strcmp0(interface, wl_seat_interface.name) == 0)
		field->seat = (struct wl_seat *)
			wl_registry_bind(registry, name, &wl_seat_interface, 1);
	else if (g_strcmp0(interface, xdg_wm_base_interface.name) == 0)
		field->wm_base = (struct xdg_wm_base *)
			wl_registry_bind(registry, name,
			                 &xdg_wm_base_interface, 1);
	else if (g_strcmp0(interface,
	                   zwp_text_input_manager_v3_interface.name) == 0)
		field->ti_manager = (struct zwp_text_input_manager_v3 *)
			wl_registry_bind(registry, name,
				&zwp_text_input_manager_v3_interface, 1);
}

static void
registry_global_remove(
	void               *data,
	struct wl_registry *registry,
	uint32_t            name
){
	(void)data; (void)registry; (void)name;
}

static const struct wl_registry_listener registry_listener = {
	registry_global,
	registry_global_remove
};

gint
main(
	gint    argc,
	gchar **argv
){
	g_autoptr(GOptionContext) context = NULL;
	g_autoptr(GError) error = NULL;
	struct wl_registry *registry;
	RigField field;

	/* GOption converts its string arguments from the locale's
	   encoding.  Without this the locale is "C", whose encoding is
	   ASCII, and --text with one accented letter is refused. */
	setlocale(LC_ALL, "");

	/* Options first: --help and --license work with no display. */
	context = g_option_context_new(
		"- one text-input-v3 text field, for the cmacs rig");
	g_option_context_add_main_entries(context, rig_field_entries, NULL);
	g_option_context_set_description(context,
		"Examples:\n"
		"  cmacs-rig-field --title notes --text 'hello world'\n"
		"  cmacs-rig-field --text draft --dump /tmp/field.txt\n"
		"  cmacs-rig-field --password --app-id rig-secret\n"
		"  cmacs-rig-field --text busy --heartbeat 20\n");
	if (!g_option_context_parse(context, &argc, &argv, &error)) {
		g_printerr("cmacs-rig-field: %s\n", error->message);
		return 2;
	}
	if (opt_license) {
		g_print("cmacs-rig-field is free software: "
		        "AGPL-3.0-or-later.\n"
		        "See <https://www.gnu.org/licenses/agpl-3.0.html>.\n");
		return 0;
	}

	memset(&field, 0, sizeof(field));
	field.text = g_string_new(opt_text != NULL ? opt_text : "");
	if (!g_utf8_validate(field.text->str, -1, NULL)) {
		g_printerr("cmacs-rig-field: --text is not UTF-8\n");
		return 2;
	}
	/* The cursor after the text, where typing would continue. */
	field.cursor = field.text->len;
	field.running = TRUE;

	/* Only ever the display it was told: WAYLAND_DISPLAY, which the
	   rig sets to its own compositor. */
	field.display = wl_display_connect(NULL);
	if (field.display == NULL) {
		g_printerr("cmacs-rig-field: no display\n");
		return 1;
	}
	registry = wl_display_get_registry(field.display);
	wl_registry_add_listener(registry, &registry_listener, &field);
	wl_display_roundtrip(field.display);
	if (field.compositor == NULL || field.shm == NULL
	    || field.seat == NULL || field.wm_base == NULL
	    || field.ti_manager == NULL) {
		g_printerr("cmacs-rig-field: the compositor lacks "
		           "wl_compositor, wl_shm, wl_seat, xdg_wm_base or "
		           "text-input-v3\n");
		return 1;
	}
	xdg_wm_base_add_listener(field.wm_base, &wm_base_listener, &field);
	if (!rig_field_make_buffer(&field))
		return 1;

	field.text_input = zwp_text_input_manager_v3_get_text_input(
		field.ti_manager, field.seat);
	zwp_text_input_v3_add_listener(field.text_input, &ti_listener,
	                               &field);

	field.surface = wl_compositor_create_surface(field.compositor);
	field.xdg_surface = xdg_wm_base_get_xdg_surface(field.wm_base,
	                                                field.surface);
	xdg_surface_add_listener(field.xdg_surface, &xdg_surface_listener,
	                         &field);
	field.toplevel = xdg_surface_get_toplevel(field.xdg_surface);
	xdg_toplevel_add_listener(field.toplevel, &toplevel_listener, &field);
	xdg_toplevel_set_title(field.toplevel,
		opt_title != NULL ? opt_title : RIG_FIELD_DEFAULT_TITLE);
	xdg_toplevel_set_app_id(field.toplevel,
		opt_app_id != NULL ? opt_app_id : RIG_FIELD_DEFAULT_TITLE);
	/* The first commit has no buffer: it asks for a configure. */
	wl_surface_commit(field.surface);

	/* The dump exists from the start, so a reader need not tell "no
	   change yet" from "no file". */
	rig_field_dump(&field);

	rig_field_run(&field);

	g_string_free(field.text, TRUE);
	g_free(field.pending_commit);
	wl_display_disconnect(field.display);
	return 0;
}
