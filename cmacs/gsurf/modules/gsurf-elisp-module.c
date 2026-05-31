/*
 * gsurf-elisp-module.c - evaluate Elisp typed into the gsurf address bar
 *
 * Copyright (C) 2026 Zach Podbielniak
 * SPDX-License-Identifier: AGPL-3.0-or-later
 *
 * A cmacs-specific gsurf module: implements GsurfUriHandler and treats
 * bar input of the form "elisp:FORM" as Emacs Lisp to evaluate in the
 * host (e.g. "elisp:(cmacs-gsurf-reload (current-buffer))").  The form
 * is dispatched to the Emacs main thread; the bar input is rewritten to
 * "about:blank" so no web load happens.  This is the in-bar Elisp escape
 * hatch that makes a gsurf buffer scriptable like any other Emacs
 * surface.  Anything not prefixed "elisp:" returns NULL (pass-through).
 */

#include <gsurf/gsurf.h>
#include <gmodule.h>
#include <string.h>

extern void cmacs_gsurf_emacs_eval_async (const char *elisp);

#define GSURF_TYPE_ELISP_MODULE (gsurf_elisp_module_get_type())
G_DECLARE_FINAL_TYPE(GsurfElispModule, gsurf_elisp_module,
                     GSURF, ELISP_MODULE, GsurfModule)

struct _GsurfElispModule
{
	GsurfModule parent_instance;
};

static void gsurf_elisp_uri_handler_init(GsurfUriHandlerInterface *iface);

G_DEFINE_FINAL_TYPE_WITH_CODE(GsurfElispModule, gsurf_elisp_module,
	GSURF_TYPE_MODULE,
	G_IMPLEMENT_INTERFACE(GSURF_TYPE_URI_HANDLER,
		gsurf_elisp_uri_handler_init))

static gchar *
gsurf_elisp_rewrite_uri(GsurfUriHandler *handler, const gchar *input)
{
	(void) handler;
	if (input == NULL || !g_str_has_prefix(input, "elisp:"))
		return NULL;
	/* The remainder is already an Elisp form; dispatch it verbatim. */
	cmacs_gsurf_emacs_eval_async(input + strlen("elisp:"));
	return g_strdup("about:blank");
}

static void
gsurf_elisp_uri_handler_init(GsurfUriHandlerInterface *iface)
{
	iface->rewrite_uri = gsurf_elisp_rewrite_uri;
}

static const gchar *
gsurf_elisp_get_name(GsurfModule *module)
{
	(void) module;
	return "elisp";
}

static const gchar *
gsurf_elisp_get_description(GsurfModule *module)
{
	(void) module;
	return "Evaluate elisp:FORM bar input in Emacs (cmacs)";
}

static gboolean
gsurf_elisp_activate(GsurfModule *module)
{
	(void) module;
	return TRUE;
}

static void
gsurf_elisp_module_class_init(GsurfElispModuleClass *klass)
{
	GsurfModuleClass *module_class = GSURF_MODULE_CLASS(klass);

	module_class->activate = gsurf_elisp_activate;
	module_class->get_name = gsurf_elisp_get_name;
	module_class->get_description = gsurf_elisp_get_description;
}

static void
gsurf_elisp_module_init(GsurfElispModule *self)
{
	(void) self;
}

G_MODULE_EXPORT GType
gsurf_module_register(void)
{
	return GSURF_TYPE_ELISP_MODULE;
}
