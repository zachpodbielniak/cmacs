/* cmacs-gowl-loop.c — GSource wrapper for the gowl wl_event_loop
 *
 * Copyright (C) 2026 Zach Podbielniak
 * SPDX-License-Identifier: AGPL-3.0-or-later
 */

#include <config.h>

#ifdef HAVE_CMACS_GOWL

#include "cmacs-gowl-loop.h"
#include "cmacs-glib-loop.h"

#include <wayland-server-core.h>

typedef struct {
	GSource               gsource;
	CmacsGowlLoopSource  *owner;  /* back-pointer; not owned */
	gpointer              poll_tag;
	int                   fd;
} CmacsGowlLoopGSource;

typedef struct {
	struct wl_event_loop *loop;
	struct wl_display    *dpy;
	CmacsGowlLoopGSource *gsrc;    /* NULL before attach */
	gboolean              dispatching;
	guint64               tick_count;
} CmacsGowlLoopSourcePrivate;

static void cmacs_gowl_loop_source_default_before_dispatch(
	CmacsGowlLoopSource *self);
static void cmacs_gowl_loop_source_default_after_dispatch(
	CmacsGowlLoopSource *self, guint n_events);

G_DEFINE_TYPE_WITH_PRIVATE(CmacsGowlLoopSource,
                           cmacs_gowl_loop_source,
                           G_TYPE_OBJECT)

#define GET_PRIV(obj)                                             \
	((CmacsGowlLoopSourcePrivate *)                            \
	 cmacs_gowl_loop_source_get_instance_private(obj))

/* ----- Properties ----- */

enum {
	PROP_0,
	PROP_EVENT_LOOP,
	PROP_DISPLAY,
	PROP_DISPATCHING,
	PROP_TICK_COUNT,
	N_PROPS
};

static GParamSpec *props[N_PROPS] = { NULL };

/* ----- Signals ----- */

enum {
	SIGNAL_BEFORE_DISPATCH,
	SIGNAL_AFTER_DISPATCH,
	N_SIGNALS
};

static guint signals[N_SIGNALS] = { 0 };

/* ----- GSourceFuncs bridge to the owning GObject ----- */

static gboolean
source_prepare(GSource *src, gint *timeout_ms)
{
	/* Always poll the fd; no immediate work to do in prepare. */
	*timeout_ms = -1;
	return FALSE;
}

static gboolean
source_check(GSource *src)
{
	CmacsGowlLoopGSource *gsrc = (CmacsGowlLoopGSource *)src;
	GIOCondition revents;

	if (gsrc->poll_tag == NULL)
		return FALSE;

	revents = g_source_query_unix_fd(src, gsrc->poll_tag);
	return (revents & (G_IO_IN | G_IO_HUP | G_IO_ERR)) != 0;
}

static gboolean
source_dispatch(GSource *src, GSourceFunc callback, gpointer user_data)
{
	CmacsGowlLoopGSource        *gsrc;
	CmacsGowlLoopSource         *self;
	CmacsGowlLoopSourcePrivate  *priv;
	guint                        n_events;
	int                          rc;

	(void)callback;
	(void)user_data;

	gsrc = (CmacsGowlLoopGSource *)src;
	self = gsrc->owner;
	if (self == NULL)
		return G_SOURCE_CONTINUE;

	priv = GET_PRIV(self);
	priv->dispatching = TRUE;

	g_signal_emit(self, signals[SIGNAL_BEFORE_DISPATCH], 0);

	/* wl_event_loop_dispatch returns <0 on error, 0 on no events,
	 * >0 otherwise.  We don't distinguish — just pass through. */
	rc = wl_event_loop_dispatch(priv->loop, 0);
	n_events = (rc > 0) ? (guint)rc : 0;

	if (priv->dpy != NULL)
		wl_display_flush_clients(priv->dpy);

	priv->tick_count++;
	priv->dispatching = FALSE;

	g_signal_emit(self, signals[SIGNAL_AFTER_DISPATCH], 0, n_events);

	g_object_notify_by_pspec(G_OBJECT(self), props[PROP_TICK_COUNT]);

	return G_SOURCE_CONTINUE;
}

static void
source_finalize(GSource *src)
{
	CmacsGowlLoopGSource *gsrc = (CmacsGowlLoopGSource *)src;
	/* Back-pointer cleared by the owner on detach; nothing else
	 * to do here because GSource memory belongs to GLib. */
	gsrc->owner = NULL;
}

static GSourceFuncs cmacs_gowl_loop_source_funcs = {
	source_prepare,
	source_check,
	source_dispatch,
	source_finalize,
	NULL,
	NULL
};

/* ----- GObject lifecycle ----- */

static void
cmacs_gowl_loop_source_get_property(GObject    *object,
                                     guint       prop_id,
                                     GValue     *value,
                                     GParamSpec *pspec)
{
	CmacsGowlLoopSource        *self = CMACS_GOWL_LOOP_SOURCE(object);
	CmacsGowlLoopSourcePrivate *priv = GET_PRIV(self);

	switch (prop_id) {
	case PROP_EVENT_LOOP:
		g_value_set_pointer(value, priv->loop);
		break;
	case PROP_DISPLAY:
		g_value_set_pointer(value, priv->dpy);
		break;
	case PROP_DISPATCHING:
		g_value_set_boolean(value, priv->dispatching);
		break;
	case PROP_TICK_COUNT:
		g_value_set_uint64(value, priv->tick_count);
		break;
	default:
		G_OBJECT_WARN_INVALID_PROPERTY_ID(object, prop_id, pspec);
		break;
	}
}

static void
cmacs_gowl_loop_source_set_property(GObject      *object,
                                     guint         prop_id,
                                     const GValue *value,
                                     GParamSpec   *pspec)
{
	CmacsGowlLoopSource        *self = CMACS_GOWL_LOOP_SOURCE(object);
	CmacsGowlLoopSourcePrivate *priv = GET_PRIV(self);

	switch (prop_id) {
	case PROP_EVENT_LOOP:
		/* CONSTRUCT_ONLY: only settable during construction. */
		priv->loop = g_value_get_pointer(value);
		break;
	case PROP_DISPLAY:
		priv->dpy = g_value_get_pointer(value);
		break;
	default:
		G_OBJECT_WARN_INVALID_PROPERTY_ID(object, prop_id, pspec);
		break;
	}
}

static void
cmacs_gowl_loop_source_dispose(GObject *object)
{
	CmacsGowlLoopSource *self = CMACS_GOWL_LOOP_SOURCE(object);

	cmacs_gowl_loop_source_detach(self);

	G_OBJECT_CLASS(cmacs_gowl_loop_source_parent_class)->dispose(object);
}

static void
cmacs_gowl_loop_source_class_init(CmacsGowlLoopSourceClass *klass)
{
	GObjectClass *object_class = G_OBJECT_CLASS(klass);

	object_class->get_property = cmacs_gowl_loop_source_get_property;
	object_class->set_property = cmacs_gowl_loop_source_set_property;
	object_class->dispose      = cmacs_gowl_loop_source_dispose;

	klass->before_dispatch =
		cmacs_gowl_loop_source_default_before_dispatch;
	klass->after_dispatch =
		cmacs_gowl_loop_source_default_after_dispatch;

	props[PROP_EVENT_LOOP] = g_param_spec_pointer(
		"event-loop", "Event Loop",
		"The wl_event_loop this source pumps",
		G_PARAM_READWRITE | G_PARAM_CONSTRUCT_ONLY
		| G_PARAM_STATIC_STRINGS);

	props[PROP_DISPLAY] = g_param_spec_pointer(
		"display", "Display",
		"The wl_display whose clients are flushed after dispatch",
		G_PARAM_READWRITE | G_PARAM_CONSTRUCT_ONLY
		| G_PARAM_STATIC_STRINGS);

	props[PROP_DISPATCHING] = g_param_spec_boolean(
		"dispatching", "Dispatching",
		"TRUE while a dispatch tick is running",
		FALSE,
		G_PARAM_READABLE | G_PARAM_STATIC_STRINGS);

	props[PROP_TICK_COUNT] = g_param_spec_uint64(
		"tick-count", "Tick Count",
		"Number of dispatch ticks since source creation",
		0, G_MAXUINT64, 0,
		G_PARAM_READABLE | G_PARAM_EXPLICIT_NOTIFY
		| G_PARAM_STATIC_STRINGS);

	g_object_class_install_properties(object_class, N_PROPS, props);

	/**
	 * CmacsGowlLoopSource::before-dispatch:
	 *
	 * Emitted at the top of every dispatch tick, before
	 * wl_event_loop_dispatch runs.  Use for profiling or to
	 * clear per-tick state from Elisp.
	 */
	signals[SIGNAL_BEFORE_DISPATCH] =
		g_signal_new("before-dispatch",
		             G_TYPE_FROM_CLASS(klass),
		             G_SIGNAL_RUN_LAST,
		             G_STRUCT_OFFSET(CmacsGowlLoopSourceClass,
		                             before_dispatch),
		             NULL, NULL, NULL,
		             G_TYPE_NONE, 0);

	/**
	 * CmacsGowlLoopSource::after-dispatch:
	 * @n_events: number of events processed (may be 0 on a wake
	 *   with no events, e.g. hangup).
	 *
	 * Emitted after wl_display_flush_clients runs.
	 */
	signals[SIGNAL_AFTER_DISPATCH] =
		g_signal_new("after-dispatch",
		             G_TYPE_FROM_CLASS(klass),
		             G_SIGNAL_RUN_LAST,
		             G_STRUCT_OFFSET(CmacsGowlLoopSourceClass,
		                             after_dispatch),
		             NULL, NULL, NULL,
		             G_TYPE_NONE, 1,
		             G_TYPE_UINT);
}

static void
cmacs_gowl_loop_source_init(CmacsGowlLoopSource *self)
{
	CmacsGowlLoopSourcePrivate *priv = GET_PRIV(self);

	priv->loop        = NULL;
	priv->dpy         = NULL;
	priv->gsrc        = NULL;
	priv->dispatching = FALSE;
	priv->tick_count  = 0;
}

static void
cmacs_gowl_loop_source_default_before_dispatch(CmacsGowlLoopSource *self)
{
	(void)self;
}

static void
cmacs_gowl_loop_source_default_after_dispatch(CmacsGowlLoopSource *self,
                                               guint                n_events)
{
	(void)self;
	(void)n_events;
}

/* ----- Public API ----- */

CmacsGowlLoopSource *
cmacs_gowl_loop_source_new(struct wl_event_loop *loop,
                            struct wl_display    *display)
{
	return g_object_new(CMACS_TYPE_GOWL_LOOP_SOURCE,
	                    "event-loop", loop,
	                    "display",    display,
	                    NULL);
}

gboolean
cmacs_gowl_loop_source_attach(CmacsGowlLoopSource *self,
                               GMainContext        *context)
{
	CmacsGowlLoopSourcePrivate *priv;
	CmacsGowlLoopGSource        *gsrc;

	g_return_val_if_fail(CMACS_IS_GOWL_LOOP_SOURCE(self), FALSE);
	priv = GET_PRIV(self);

	if (priv->gsrc != NULL)
		return FALSE;  /* already attached */
	if (priv->loop == NULL)
		return FALSE;  /* no loop to pump */

	gsrc = (CmacsGowlLoopGSource *)g_source_new(
		&cmacs_gowl_loop_source_funcs,
		sizeof(CmacsGowlLoopGSource));
	gsrc->owner    = self;
	gsrc->fd       = wl_event_loop_get_fd(priv->loop);
	gsrc->poll_tag = g_source_add_unix_fd(
		(GSource *)gsrc, gsrc->fd,
		G_IO_IN | G_IO_HUP | G_IO_ERR);

	g_source_set_name((GSource *)gsrc, "cmacs-gowl-loop");

	if (context == NULL)
		context = cmacs_glib_get_context();

	g_source_attach((GSource *)gsrc, context);

	priv->gsrc = gsrc;
	return TRUE;
}

void
cmacs_gowl_loop_source_detach(CmacsGowlLoopSource *self)
{
	CmacsGowlLoopSourcePrivate *priv;

	g_return_if_fail(CMACS_IS_GOWL_LOOP_SOURCE(self));
	priv = GET_PRIV(self);

	if (priv->gsrc == NULL)
		return;

	g_source_destroy((GSource *)priv->gsrc);
	g_source_unref((GSource *)priv->gsrc);
	priv->gsrc = NULL;
}

gboolean
cmacs_gowl_loop_source_is_attached(CmacsGowlLoopSource *self)
{
	CmacsGowlLoopSourcePrivate *priv;

	g_return_val_if_fail(CMACS_IS_GOWL_LOOP_SOURCE(self), FALSE);
	priv = GET_PRIV(self);
	return priv->gsrc != NULL;
}

guint64
cmacs_gowl_loop_source_get_tick_count(CmacsGowlLoopSource *self)
{
	CmacsGowlLoopSourcePrivate *priv;

	g_return_val_if_fail(CMACS_IS_GOWL_LOOP_SOURCE(self), 0);
	priv = GET_PRIV(self);
	return priv->tick_count;
}

#endif /* HAVE_CMACS_GOWL */
