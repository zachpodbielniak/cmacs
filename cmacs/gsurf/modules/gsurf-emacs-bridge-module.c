/*
 * gsurf-emacs-bridge-module.c - emit gsurf navigation events into Emacs
 *
 * Copyright (C) 2026 Zach Podbielniak
 * SPDX-License-Identifier: AGPL-3.0-or-later
 *
 * A cmacs-specific gsurf module: implements GsurfNavigationHook and
 * forwards every committed navigation and load-state change to Emacs as
 * the abnormal hook `cmacs-gsurf-module-event-functions' (EVENT URI).
 * This is the canonical "Emacs always knows what the browser is doing"
 * surface --- it fires for module-initiated navigations too, so
 * podomation / Elisp automation can react.
 *
 * Loaded only inside cmacs: it resolves the host-exported bridge symbol
 * `cmacs_gsurf_emacs_eval_async' from the emacs executable (temacs is
 * linked --export-dynamic).  It links no libgsurf of its own --- the
 * gsurf_ and yaml_ symbols also resolve from the executable.
 */

#include <gsurf/gsurf.h>
#include <gmodule.h>

/* Host bridge: schedule ELISP (source string) on the Emacs main thread.
   Defined in cmacs/gsurf/cmacs-gsurf-view.c, resolved at load time. */
extern void cmacs_gsurf_emacs_eval_async (const char *elisp);

#define GSURF_TYPE_EMACS_BRIDGE_MODULE (gsurf_emacs_bridge_module_get_type())
G_DECLARE_FINAL_TYPE(GsurfEmacsBridgeModule, gsurf_emacs_bridge_module,
                     GSURF, EMACS_BRIDGE_MODULE, GsurfModule)

struct _GsurfEmacsBridgeModule
{
	GsurfModule parent_instance;
};

static void gsurf_emacs_bridge_nav_hook_init(GsurfNavigationHookInterface *iface);

G_DEFINE_FINAL_TYPE_WITH_CODE(GsurfEmacsBridgeModule, gsurf_emacs_bridge_module,
	GSURF_TYPE_MODULE,
	G_IMPLEMENT_INTERFACE(GSURF_TYPE_NAVIGATION_HOOK,
		gsurf_emacs_bridge_nav_hook_init))

/* Quote S as an Elisp string literal (escaping backslash and quote). */
static gchar *
elq(const gchar *s)
{
	GString *o;
	const gchar *p;

	if (s == NULL)
		return g_strdup("\"\"");
	o = g_string_new("\"");
	for (p = s; *p != '\0'; p++) {
		if (*p == '\\' || *p == '"')
			g_string_append_c(o, '\\');
		g_string_append_c(o, *p);
	}
	g_string_append_c(o, '"');
	return g_string_free(o, FALSE);
}

static void
emit_event(const gchar *event, const gchar *uri)
{
	g_autofree gchar *q = elq(uri);
	g_autofree gchar *form = g_strdup_printf(
		"(run-hook-with-args 'cmacs-gsurf-module-event-functions '%s %s)",
		event, q);
	cmacs_gsurf_emacs_eval_async(form);
}

static void
gsurf_emacs_bridge_after_navigate(GsurfNavigationHook *hook,
                                  GsurfView *view, const gchar *uri)
{
	(void) hook; (void) view;
	if (uri != NULL && *uri != '\0')
		emit_event("navigated", uri);
}

static void
gsurf_emacs_bridge_load_changed(GsurfNavigationHook *hook,
                                GsurfView *view, GsurfLoadEvent event)
{
	const gchar *sym;
	const gchar *uri;

	(void) hook;
	switch (event) {
	case GSURF_LOAD_STARTED:   sym = "load-started";   break;
	case GSURF_LOAD_COMMITTED: sym = "load-committed"; break;
	case GSURF_LOAD_FINISHED:  sym = "load-finished";  break;
	default:                   sym = "load-changed";   break;
	}
	uri = (view != NULL) ? gsurf_view_get_uri(view) : NULL;
	emit_event(sym, uri);
}

static void
gsurf_emacs_bridge_nav_hook_init(GsurfNavigationHookInterface *iface)
{
	iface->after_navigate = gsurf_emacs_bridge_after_navigate;
	iface->load_changed = gsurf_emacs_bridge_load_changed;
}

static const gchar *
gsurf_emacs_bridge_get_name(GsurfModule *module)
{
	(void) module;
	return "emacs_bridge";
}

static const gchar *
gsurf_emacs_bridge_get_description(GsurfModule *module)
{
	(void) module;
	return "Emit gsurf navigation events into Emacs hooks (cmacs)";
}

static gboolean
gsurf_emacs_bridge_activate(GsurfModule *module)
{
	(void) module;
	return TRUE;
}

static void
gsurf_emacs_bridge_module_class_init(GsurfEmacsBridgeModuleClass *klass)
{
	GsurfModuleClass *module_class = GSURF_MODULE_CLASS(klass);

	module_class->activate = gsurf_emacs_bridge_activate;
	module_class->get_name = gsurf_emacs_bridge_get_name;
	module_class->get_description = gsurf_emacs_bridge_get_description;
}

static void
gsurf_emacs_bridge_module_init(GsurfEmacsBridgeModule *self)
{
	(void) self;
}

G_MODULE_EXPORT GType
gsurf_module_register(void)
{
	return GSURF_TYPE_EMACS_BRIDGE_MODULE;
}
