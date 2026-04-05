/*
 * Copyright (C) 2026 Zach Podbielniak
 * SPDX-License-Identifier: AGPL-3.0-or-later
 */

/* cmacs-gi-module.c — Bacon module that registers the `cmacsgi` builtin
 *
 * On startup, registers the `cmacsgi` BaconCommand with the shell.
 * The command uses GDBus to call into CMacs for GObject Introspection,
 * elisp evaluation, and file operations.
 */

#ifndef BACON_COMPILATION
#define BACON_COMPILATION
#endif
#include "cmacs-gi-module.h"
#include "cmacs-gi-command.h"
#include <interfaces/bacon-startup-shutdown.h>
#include <core/bacon-shell.h>
#include <bacon-types.h>

#include <gmodule.h>

struct _CmacsGiModule
{
    BaconModule parent_instance;
};

static void cmacs_gi_module_startup_init(BaconStartupShutdownInterface *iface);

G_DEFINE_TYPE_WITH_CODE(CmacsGiModule, cmacs_gi_module, BACON_TYPE_MODULE,
    G_IMPLEMENT_INTERFACE(BACON_TYPE_STARTUP_SHUTDOWN,
                          cmacs_gi_module_startup_init))

/* ── Startup: register the builtin ───────────────────────────────── */

static void
cmacs_gi_module_on_startup(BaconStartupShutdown *self,
                           gpointer              shell)
{
    CmacsGiCommand *cmd;

    (void)self;

    cmd = cmacs_gi_command_new();
    bacon_shell_register_builtin(BACON_SHELL(shell), "cmacsgi",
                                 BACON_COMMAND(cmd));
    g_object_unref(cmd);
}

static void
cmacs_gi_module_on_shutdown(BaconStartupShutdown *self,
                            gpointer              shell)
{
    (void)self;
    (void)shell;
}

/* ── Module lifecycle ─────────────────────────────────────────────── */

static gboolean
cmacs_gi_module_activate_impl(BaconModule *module)
{
    (void)module;
    return TRUE;
}

static void
cmacs_gi_module_deactivate_impl(BaconModule *module)
{
    (void)module;
}

static const gchar *
cmacs_gi_module_get_name_impl(BaconModule *module)
{
    (void)module;
    return "cmacsgi";
}

static const gchar *
cmacs_gi_module_get_description_impl(BaconModule *module)
{
    (void)module;
    return "CMacs GObject Introspection — `cmacsgi` builtin for D-Bus IPC";
}

/* ── GObject boilerplate ─────────────────────────────────────────── */

static void
cmacs_gi_module_startup_init(BaconStartupShutdownInterface *iface)
{
    iface->on_startup  = cmacs_gi_module_on_startup;
    iface->on_shutdown = cmacs_gi_module_on_shutdown;
}

static void
cmacs_gi_module_class_init(CmacsGiModuleClass *klass)
{
    BaconModuleClass *mod_class = BACON_MODULE_CLASS(klass);

    mod_class->activate        = cmacs_gi_module_activate_impl;
    mod_class->deactivate      = cmacs_gi_module_deactivate_impl;
    mod_class->get_name        = cmacs_gi_module_get_name_impl;
    mod_class->get_description = cmacs_gi_module_get_description_impl;
}

static void
cmacs_gi_module_init(CmacsGiModule *self)
{
    (void)self;
}

/* ── Module entry point ───────────────────────────────────────────── */

G_MODULE_EXPORT GType
bacon_module_register(void)
{
    return CMACS_TYPE_GI_MODULE;
}
