/*
 * gsurf-open-in-emacs-module.c - route pseudo-scheme bar input to Emacs
 *
 * Copyright (C) 2026 Zach Podbielniak
 * SPDX-License-Identifier: AGPL-3.0-or-later
 *
 * A cmacs-specific gsurf module: implements GsurfUriHandler and
 * recognises a few pseudo-schemes typed into the address bar, routing
 * them into Emacs instead of loading a web page:
 *
 *   emacs:PATH        -> (find-file "PATH")
 *   eww:URL           -> (eww "URL")
 *   org-capture:TEXT  -> capture TEXT via cmacs-gsurf--module-org-capture
 *
 * Recognised input is dispatched to Emacs and rewritten to "about:blank"
 * so the web view stays idle.  Anything else returns NULL (pass-through,
 * letting search_engines / the engine handle it).  This is how a gsurf
 * buffer hands work back to the editor that hosts it.
 */

#include <gsurf/gsurf.h>
#include <gmodule.h>
#include <string.h>

extern void cmacs_gsurf_emacs_eval_async (const char *elisp);

#define GSURF_TYPE_OPEN_IN_EMACS_MODULE (gsurf_open_in_emacs_module_get_type())
G_DECLARE_FINAL_TYPE(GsurfOpenInEmacsModule, gsurf_open_in_emacs_module,
                     GSURF, OPEN_IN_EMACS_MODULE, GsurfModule)

struct _GsurfOpenInEmacsModule
{
	GsurfModule parent_instance;
};

static void gsurf_open_in_emacs_uri_handler_init(GsurfUriHandlerInterface *iface);

G_DEFINE_FINAL_TYPE_WITH_CODE(GsurfOpenInEmacsModule, gsurf_open_in_emacs_module,
	GSURF_TYPE_MODULE,
	G_IMPLEMENT_INTERFACE(GSURF_TYPE_URI_HANDLER,
		gsurf_open_in_emacs_uri_handler_init))

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

static gchar *
gsurf_open_in_emacs_rewrite_uri(GsurfUriHandler *handler, const gchar *input)
{
	const gchar *arg;

	(void) handler;
	if (input == NULL)
		return NULL;

	if (g_str_has_prefix(input, "emacs:")) {
		arg = input + strlen("emacs:");
		g_autofree gchar *q = elq(arg);
		g_autofree gchar *form =
			g_strdup_printf("(cmacs-gsurf--module-find-file %s)", q);
		cmacs_gsurf_emacs_eval_async(form);
		return g_strdup("about:blank");
	}
	if (g_str_has_prefix(input, "eww:")) {
		arg = input + strlen("eww:");
		g_autofree gchar *q = elq(arg);
		g_autofree gchar *form =
			g_strdup_printf("(cmacs-gsurf--module-eww %s)", q);
		cmacs_gsurf_emacs_eval_async(form);
		return g_strdup("about:blank");
	}
	if (g_str_has_prefix(input, "org-capture:")) {
		arg = input + strlen("org-capture:");
		g_autofree gchar *q = elq(arg);
		g_autofree gchar *form =
			g_strdup_printf("(cmacs-gsurf--module-org-capture %s)", q);
		cmacs_gsurf_emacs_eval_async(form);
		return g_strdup("about:blank");
	}
	return NULL;
}

static void
gsurf_open_in_emacs_uri_handler_init(GsurfUriHandlerInterface *iface)
{
	iface->rewrite_uri = gsurf_open_in_emacs_rewrite_uri;
}

static const gchar *
gsurf_open_in_emacs_get_name(GsurfModule *module)
{
	(void) module;
	return "open_in_emacs";
}

static const gchar *
gsurf_open_in_emacs_get_description(GsurfModule *module)
{
	(void) module;
	return "Route emacs:/eww:/org-capture: bar input into Emacs (cmacs)";
}

static gboolean
gsurf_open_in_emacs_activate(GsurfModule *module)
{
	(void) module;
	return TRUE;
}

static void
gsurf_open_in_emacs_module_class_init(GsurfOpenInEmacsModuleClass *klass)
{
	GsurfModuleClass *module_class = GSURF_MODULE_CLASS(klass);

	module_class->activate = gsurf_open_in_emacs_activate;
	module_class->get_name = gsurf_open_in_emacs_get_name;
	module_class->get_description = gsurf_open_in_emacs_get_description;
}

static void
gsurf_open_in_emacs_module_init(GsurfOpenInEmacsModule *self)
{
	(void) self;
}

G_MODULE_EXPORT GType
gsurf_module_register(void)
{
	return GSURF_TYPE_OPEN_IN_EMACS_MODULE;
}
