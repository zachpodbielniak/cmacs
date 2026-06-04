/*
 * gsurf-cmacs-bridge-module.c - JS -> Emacs message channel
 *
 * Copyright (C) 2026 Zach Podbielniak
 * SPDX-License-Identifier: AGPL-3.0-or-later
 *
 * A cmacs-specific gsurf module that opens a one-way page->Emacs data
 * channel.  It registers a WebKit script-message handler named "cmacs" on
 * each view's WebKitUserContentManager and installs a tiny bootstrap
 * user-script exposing window.cmacs.send(channel, payload).  A page (or an
 * Emacs-injected user-script, e.g. the inspector's console capture) calls
 *
 *     window.cmacs.send("console", {level:"log", args:[...]});
 *
 * and the handler forwards the raw JSON {channel,payload} to the host
 * bridge cmacs_gsurf_js_message (resolved from the emacs executable;
 * temacs is --export-dynamic), which routes it to the originating buffer's
 * Elisp dispatcher.  The payload is DATA only -- Elisp parses the JSON and
 * routes by channel; it is never evaluated as code.
 *
 * gsurf itself stays elisp-free: this module lives in the cmacs tree, not
 * deps/gsurf.  It links no libgsurf/webkit of its own for the gsurf_*
 * symbols (those resolve from the executable); the WebKit/JSC symbols come
 * from the system libwebkit2gtk, which the .so links directly.
 *
 * GsurfScriptInjector::inject fires once per view at construction
 * (uri == NULL), so registration is naturally once-per-view; an
 * idempotency flag on the web view guards against any future re-dispatch.
 */

#include <gsurf/gsurf.h>
#include <gmodule.h>
#include <webkit2/webkit2.h>

/* Host bridge (cmacs/gsurf/cmacs-gsurf-view.c), resolved at load time. */
extern void cmacs_gsurf_js_message (void *gsurf_view, const char *message);

#define GSURF_TYPE_CMACS_BRIDGE_MODULE (gsurf_cmacs_bridge_module_get_type())
G_DECLARE_FINAL_TYPE(GsurfCmacsBridgeModule, gsurf_cmacs_bridge_module,
                     GSURF, CMACS_BRIDGE_MODULE, GsurfModule)

struct _GsurfCmacsBridgeModule
{
	GsurfModule parent_instance;
};

static void gsurf_cmacs_bridge_injector_init(GsurfScriptInjectorInterface *iface);

G_DEFINE_FINAL_TYPE_WITH_CODE(GsurfCmacsBridgeModule, gsurf_cmacs_bridge_module,
	GSURF_TYPE_MODULE,
	G_IMPLEMENT_INTERFACE(GSURF_TYPE_SCRIPT_INJECTOR,
		gsurf_cmacs_bridge_injector_init))

/* Re-runs on every navigation (user-scripts are re-injected by WebKit), so
   window.cmacs.send is always present. */
static const char *BOOTSTRAP_JS =
	"(function(){"
	"if(window.cmacs&&window.cmacs.send)return;"
	"window.cmacs=window.cmacs||{};"
	"window.cmacs.send=function(c,p){try{"
	"window.webkit.messageHandlers.cmacs.postMessage("
	"JSON.stringify({channel:c,payload:p}));}catch(e){}};"
	"})();";

static void
on_cmacs_message(WebKitUserContentManager *ucm,
                 WebKitJavascriptResult *js_result, gpointer user)
{
	GsurfView *view = user;
	JSCValue *val;
	gchar *str;

	(void) ucm;
	val = webkit_javascript_result_get_js_value(js_result);
	if (val == NULL)
		return;
	str = jsc_value_to_string(val);
	if (str != NULL) {
		cmacs_gsurf_js_message(view, str);
		g_free(str);
	}
}

static void
gsurf_cmacs_bridge_inject(GsurfScriptInjector *self, GsurfView *view,
                          const gchar *uri)
{
	gpointer w;
	WebKitWebView *wv;
	WebKitUserContentManager *ucm;

	(void) self; (void) uri;
	w = (view != NULL) ? gsurf_view_get_native_widget(view) : NULL;
	if (w == NULL)
		return;
	wv = WEBKIT_WEB_VIEW(w);

	/* Once per view (inject is per-construction, but guard anyway: a
	   duplicate register_script_message_handler would warn). */
	if (g_object_get_data(G_OBJECT(wv), "cmacs-bridge-installed") != NULL)
		return;
	g_object_set_data(G_OBJECT(wv), "cmacs-bridge-installed",
	                  GINT_TO_POINTER(1));

	ucm = webkit_web_view_get_user_content_manager(wv);
	webkit_user_content_manager_register_script_message_handler(ucm, "cmacs");
	g_signal_connect(ucm, "script-message-received::cmacs",
	                 G_CALLBACK(on_cmacs_message), view);
	gsurf_view_add_user_script(view, BOOTSTRAP_JS, FALSE);
}

static void
gsurf_cmacs_bridge_injector_init(GsurfScriptInjectorInterface *iface)
{
	iface->inject = gsurf_cmacs_bridge_inject;
}

static const gchar *
gsurf_cmacs_bridge_get_name(GsurfModule *module)
{
	(void) module;
	return "js_bridge";
}

static const gchar *
gsurf_cmacs_bridge_get_description(GsurfModule *module)
{
	(void) module;
	return "JS->Emacs message channel: window.cmacs.send (cmacs)";
}

static gboolean
gsurf_cmacs_bridge_activate(GsurfModule *module)
{
	(void) module;
	return TRUE;
}

static void
gsurf_cmacs_bridge_module_class_init(GsurfCmacsBridgeModuleClass *klass)
{
	GsurfModuleClass *module_class = GSURF_MODULE_CLASS(klass);

	module_class->activate = gsurf_cmacs_bridge_activate;
	module_class->get_name = gsurf_cmacs_bridge_get_name;
	module_class->get_description = gsurf_cmacs_bridge_get_description;
}

static void
gsurf_cmacs_bridge_module_init(GsurfCmacsBridgeModule *self)
{
	(void) self;
}

G_MODULE_EXPORT GType
gsurf_module_register(void)
{
	return GSURF_TYPE_CMACS_BRIDGE_MODULE;
}
