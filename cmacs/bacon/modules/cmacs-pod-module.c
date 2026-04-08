/*
 * Copyright (C) 2026 Zach Podbielniak
 * SPDX-License-Identifier: AGPL-3.0-or-later
 */

/* cmacs-pod-module.c — Bacon module that registers the `pod` builtin
 *
 * On startup, registers the `pod` BaconCommand with the shell.
 * The command uses the CMacs API transport to interact with the
 * podomation automation engine via Elisp DEFUNs.
 */

#ifndef BACON_COMPILATION
#define BACON_COMPILATION
#endif
#include "cmacs-pod-module.h"
#include "cmacs-pod-command.h"
#include <interfaces/bacon-startup-shutdown.h>
#include <core/bacon-shell.h>
#include <bacon-types.h>

#include <gmodule.h>

struct _CmacsPodModule
{
    BaconModule parent_instance;
};

static void cmacs_pod_module_startup_init(BaconStartupShutdownInterface *iface);

G_DEFINE_TYPE_WITH_CODE(CmacsPodModule, cmacs_pod_module, BACON_TYPE_MODULE,
    G_IMPLEMENT_INTERFACE(BACON_TYPE_STARTUP_SHUTDOWN,
                          cmacs_pod_module_startup_init))

/* ── Startup: register the builtin ───────────────────────────────── */

static void
cmacs_pod_module_on_startup(BaconStartupShutdown *self,
                            gpointer              shell)
{
    CmacsPodCommand *cmd;

    (void)self;

    cmd = cmacs_pod_command_new();
    bacon_shell_register_builtin(BACON_SHELL(shell), "pod",
                                 BACON_COMMAND(cmd));
    g_object_unref(cmd);
}

static void
cmacs_pod_module_on_shutdown(BaconStartupShutdown *self,
                             gpointer              shell)
{
    (void)self;
    (void)shell;
}

/* ── Module lifecycle ────────────────────────────────────────────── */

static gboolean
cmacs_pod_module_activate_impl(BaconModule *module)
{
    (void)module;
    return TRUE;
}

static void
cmacs_pod_module_deactivate_impl(BaconModule *module)
{
    (void)module;
}

static const gchar *
cmacs_pod_module_get_name_impl(BaconModule *module)
{
    (void)module;
    return "cmacs_pod";
}

static const gchar *
cmacs_pod_module_get_description_impl(BaconModule *module)
{
    (void)module;
    return "Podomation automation engine — `pod` builtin";
}

/* ── GObject boilerplate ────────────────────────────────────────── */

static void
cmacs_pod_module_startup_init(BaconStartupShutdownInterface *iface)
{
    iface->on_startup  = cmacs_pod_module_on_startup;
    iface->on_shutdown = cmacs_pod_module_on_shutdown;
}

static void
cmacs_pod_module_class_init(CmacsPodModuleClass *klass)
{
    BaconModuleClass *mod_class = BACON_MODULE_CLASS(klass);

    mod_class->activate        = cmacs_pod_module_activate_impl;
    mod_class->deactivate      = cmacs_pod_module_deactivate_impl;
    mod_class->get_name        = cmacs_pod_module_get_name_impl;
    mod_class->get_description = cmacs_pod_module_get_description_impl;
}

static void
cmacs_pod_module_init(CmacsPodModule *self)
{
    (void)self;
}

/* ── Module entry point ──────────────────────────────────────────── */

G_MODULE_EXPORT GType
bacon_module_register(void)
{
    return CMACS_TYPE_POD_MODULE;
}
