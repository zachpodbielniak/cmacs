/* cmacs-gsurf-modules.c --- gsurf module-manager glue.
 *
 * Copyright (C) 2026 Zach Podbielniak
 * SPDX-License-Identifier: AGPL-3.0-or-later
 *
 * Wires the gsurf module manager into cmacs: configures the search
 * paths (cmacs custom modules + the bundled gsurf stock modules + env
 * overrides), loads and activates them, and exposes a small inventory /
 * toggle API to the defun + MCP layers.
 *
 * Search-path order (first match by filename wins, like $PATH):
 *   1. $CMACS_GSURF_MODULE_DIR   (set by `just run' for dev testing)
 *   2. $GSURF_MODULE_PATH        (generic gsurf override)
 *   3. CMACS_GSURF_MODULE_DIR    (compiled-in cmacs custom module dir)
 *   4. CMACS_GSURF_DEV_MODULE_DIR(deps/gsurf/build/release/modules — stock)
 *   5. GSURF_MODULEDIR           (installed $libdir/cmacs/gsurf/modules)
 */

#include <config.h>

#ifdef HAVE_CMACS_GSURF

#include "cmacs-gsurf.h"
#include "cmacs-gsurf-internal.h"

#include <glib.h>
#include <gsurf/gsurf.h>
#include <json-glib/json-glib.h>

static bool cmacs_gsurf__modules_loaded = false;

/* True once cmacs_gsurf_modules_init has loaded + activated modules. */
static bool
modules_loaded_p (void)
{
  return cmacs_gsurf__modules_loaded;
}

static void
add_path_if (GsurfModuleManager *mgr, const char *dir)
{
  if (dir != NULL && *dir != '\0'
      && g_file_test (dir, G_FILE_TEST_IS_DIR))
    gsurf_module_manager_add_search_path (mgr, dir);
}

void
cmacs_gsurf_modules_init (void)
{
  if (cmacs_gsurf__modules_loaded)
    return;
  cmacs_gsurf__modules_loaded = true;

  GsurfModuleManager *mgr = gsurf_module_manager_get_default ();
  gsurf_module_manager_set_application (mgr, cmacs_gsurf_app ());
  gsurf_module_manager_set_config (mgr, cmacs_gsurf_config ());

  add_path_if (mgr, g_getenv ("CMACS_GSURF_MODULE_DIR"));
  add_path_if (mgr, g_getenv ("GSURF_MODULE_PATH"));
#ifdef CMACS_GSURF_MODULE_DIR
  add_path_if (mgr, CMACS_GSURF_MODULE_DIR);
#endif
#ifdef CMACS_GSURF_DEV_MODULE_DIR
  add_path_if (mgr, CMACS_GSURF_DEV_MODULE_DIR);
#endif
#ifdef GSURF_MODULEDIR
  add_path_if (mgr, GSURF_MODULEDIR);
#endif

  gsurf_module_manager_load_modules (mgr);
  gsurf_module_manager_activate_all (mgr);
}

char *
cmacs_gsurf_modules_list_json (void)
{
  GsurfModuleManager *mgr = gsurf_module_manager_get_default ();
  GPtrArray *mods = gsurf_module_manager_get_modules (mgr);

  g_autoptr (JsonBuilder) b = json_builder_new ();
  json_builder_begin_array (b);
  if (mods != NULL)
    {
      for (guint i = 0; i < mods->len; i++)
        {
          GsurfModule *m = g_ptr_array_index (mods, i);
          const char *name = gsurf_module_get_name (m);
          const char *desc = gsurf_module_get_description (m);
          json_builder_begin_object (b);
          json_builder_set_member_name (b, "name");
          json_builder_add_string_value (b, name ? name : "");
          json_builder_set_member_name (b, "description");
          json_builder_add_string_value (b, desc ? desc : "");
          json_builder_set_member_name (b, "enabled");
          json_builder_add_boolean_value (b, gsurf_module_get_enabled (m));
          json_builder_set_member_name (b, "active");
          json_builder_add_boolean_value (b, gsurf_module_is_active (m));
          json_builder_end_object (b);
        }
    }
  json_builder_end_array (b);

  g_autoptr (JsonGenerator) gen = json_generator_new ();
  g_autoptr (JsonNode) root = json_builder_get_root (b);
  json_generator_set_root (gen, root);
  return json_generator_to_data (gen, NULL);   /* caller frees */
}

bool
cmacs_gsurf_module_set_enabled (const char *name, bool enabled)
{
  if (name == NULL)
    return false;
  GsurfModuleManager *mgr = gsurf_module_manager_get_default ();
  GsurfModule *m = gsurf_module_manager_get_module (mgr, name);
  if (m == NULL)
    return false;

  gsurf_module_set_enabled (m, enabled);
  if (enabled && !gsurf_module_is_active (m))
    gsurf_module_activate (m);
  else if (!enabled && gsurf_module_is_active (m))
    gsurf_module_deactivate (m);
  return true;
}

/* ── Config loading (Emacs-driven; no gsurf user files by default) ──── */

/* Re-run each loaded module's configure() so option changes in the
   config (e.g. modal scroll_step) take effect.  Enabled-state changes
   are applied separately via cmacs_gsurf_module_set_enabled (the Elisp
   layer pushes those, since reading the YAML `enabled' flag here would
   pull in yaml-glib, which is not on the cmacs-side include path). */
void
cmacs_gsurf_modules_reconfigure (void)
{
  if (!modules_loaded_p ())
    return;
  GsurfModuleManager *mgr = gsurf_module_manager_get_default ();
  GsurfConfig *cfg = cmacs_gsurf_config ();
  GPtrArray *mods = gsurf_module_manager_get_modules (mgr);
  if (cfg == NULL || mods == NULL)
    return;
  for (guint i = 0; i < mods->len; i++)
    gsurf_module_configure (g_ptr_array_index (mods, i), cfg);
}

bool
cmacs_gsurf_load_config_data (const char *yaml, char **err_out)
{
  if (err_out) *err_out = NULL;
  if (yaml == NULL)
    return false;
  cmacs_gsurf_config_ensure ();
  GError *err = NULL;
  gboolean ok = gsurf_config_load_from_data (cmacs_gsurf_config (),
                                             yaml, -1, &err);
  if (!ok)
    {
      if (err_out) *err_out = g_strdup (err ? err->message : "parse error");
      g_clear_error (&err);
      return false;
    }
  cmacs_gsurf_modules_reconfigure ();
  return true;
}

bool
cmacs_gsurf_load_config_file (const char *path, char **err_out)
{
  if (err_out) *err_out = NULL;
  if (path == NULL)
    return false;
  cmacs_gsurf_config_ensure ();
  GError *err = NULL;
  gboolean ok = gsurf_config_load_from_file (cmacs_gsurf_config (),
                                             path, &err);
  if (!ok)
    {
      if (err_out) *err_out = g_strdup (err ? err->message : "load error");
      g_clear_error (&err);
      return false;
    }
  cmacs_gsurf_modules_reconfigure ();
  return true;
}

bool
cmacs_gsurf_load_config_c_file (const char *path, char **err_out)
{
  if (err_out) *err_out = NULL;
  if (path == NULL)
    return false;
  cmacs_gsurf_config_ensure ();

  GError *err = NULL;
  GsurfConfigCompiler *cc = gsurf_config_compiler_new (&err);
  if (cc == NULL)
    {
      if (err_out) *err_out = g_strdup (err ? err->message
                                            : "compiler init failed");
      g_clear_error (&err);
      return false;
    }
  /* The compiled config's gsurf_config_init() mutates the default
     config (gsurf_config_get_default()), which is our config. */
  gboolean ok = gsurf_config_compiler_compile_and_load (cc, path, &err);
  g_object_unref (cc);
  if (!ok)
    {
      if (err_out) *err_out = g_strdup (err ? err->message : "compile error");
      g_clear_error (&err);
      return false;
    }
  cmacs_gsurf_modules_reconfigure ();
  return true;
}

#endif /* HAVE_CMACS_GSURF */
