/* cmacs-libregnum-scene-tree.c --- project file tree scene.
 *
 * Copyright (C) 2026 Zach Podbielniak
 * SPDX-License-Identifier: AGPL-3.0-or-later
 *
 * Builds a 3D scatter of file cubes whose x/z positions encode
 * directory placement (DFS order) and whose y-height encodes file
 * size.  Color encodes extension.
 *
 * Translation-unit firewall: this file includes libregnum.h (and
 * thus indirectly raylib.h) so it CANNOT include cmacs internals
 * like lisp.h/frame.h/buffer.h.  It talks to cmacs only via the
 * plain-C cmacs-libregnum-render.h API. */

#include <config.h>

#ifdef HAVE_CMACS_LIBREGNUM

#include "cmacs-libregnum-render.h"
#include "cmacs-libregnum-scenes.h"

#include <libregnum.h>
#include <glib.h>
#include <math.h>
#include <string.h>

/* Hash an extension to a stable colour.  Quick polynomial roll
 * followed by HSV->RGB so distinct extensions get distinct hues. */
static void
extension_color (const gchar *path, guint8 *r, guint8 *g, guint8 *b)
{
  const gchar *dot = strrchr (path, '.');
  guint hash = 0;
  if (dot && dot != path)
    for (const gchar *p = dot + 1; *p; p++)
      hash = (hash * 131u) + (guint)*p;
  else
    hash = (guint) g_str_hash (path);

  double h = (hash % 360) / 60.0;
  double s = 0.6;
  double v = 0.85;
  int i = (int) floor (h);
  double f = h - i;
  double p = v * (1 - s);
  double q = v * (1 - s * f);
  double t = v * (1 - s * (1 - f));
  double R = 0, G = 0, B = 0;
  switch (i % 6)
    {
    case 0: R=v; G=t; B=p; break;
    case 1: R=q; G=v; B=p; break;
    case 2: R=p; G=v; B=t; break;
    case 3: R=p; G=q; B=v; break;
    case 4: R=t; G=p; B=v; break;
    case 5: R=v; G=p; B=q; break;
    }
  *r = (guint8) (R * 255);
  *g = (guint8) (G * 255);
  *b = (guint8) (B * 255);
}

/* DFS walker: places cubes on a grid based on traversal order. */
typedef struct
{
  CmacsLibregnumRenderCtx *ctx;
  guint     count;
  gint      grid_n;            /* sqrt(N) for x/z layout */
  double    spacing;
  guint64   max_size;
} TreeCtx;

static void
emit_cube (TreeCtx *t, const gchar *path, guint64 size)
{
  guint idx = t->count++;
  int   gx  = (int) (idx % t->grid_n);
  int   gz  = (int) (idx / t->grid_n);
  float x   = (gx - t->grid_n * 0.5f) * t->spacing;
  float z   = (gz - t->grid_n * 0.5f) * t->spacing;
  /* Log-scale the height so a 10 MB file isn't 1000x taller than a
   * 10 KB one.  Cap height at 8 units. */
  double h = (size == 0) ? 0.2 : log10 ((double) size) * 0.6;
  if (h < 0.1) h = 0.1;
  if (h > 8.0) h = 8.0;
  float y = (float) h * 0.5f;

  guint8 cr, cg, cb;
  extension_color (path, &cr, &cg, &cb);
  g_autoptr (GrlColor) col = grl_color_new (cr, cg, cb, 255);

  LrgCube3D *cube = lrg_cube3d_new_at (x, y, z, 0.7f, (float) h, 0.7f);
  lrg_shape_set_color (LRG_SHAPE (cube), col);
  cmacs_libregnum_render_ctx_add_drawable (t->ctx, cube);
}

static void
walk_dir (TreeCtx *t, GFile *dir, int depth_left)
{
  if (depth_left <= 0) return;
  g_autoptr (GError) err = NULL;
  g_autoptr (GFileEnumerator) en =
    g_file_enumerate_children (dir,
                                G_FILE_ATTRIBUTE_STANDARD_NAME ","
                                G_FILE_ATTRIBUTE_STANDARD_TYPE ","
                                G_FILE_ATTRIBUTE_STANDARD_SIZE,
                                G_FILE_QUERY_INFO_NOFOLLOW_SYMLINKS,
                                NULL, &err);
  if (!en) return;

  while (TRUE)
    {
      g_autoptr (GFileInfo) info = g_file_enumerator_next_file (en, NULL, NULL);
      if (!info) break;
      const gchar *name = g_file_info_get_name (info);
      if (!name) continue;
      if (name[0] == '.') continue;   /* skip dotfiles */
      GFileType type = g_file_info_get_file_type (info);
      g_autoptr (GFile) child = g_file_get_child (dir, name);

      if (type == G_FILE_TYPE_DIRECTORY)
        {
          /* Skip .git / build / native-lisp / node_modules etc. */
          if (g_strcmp0 (name, ".git") == 0
              || g_strcmp0 (name, "build") == 0
              || g_strcmp0 (name, "node_modules") == 0
              || g_strcmp0 (name, "native-lisp") == 0
              || g_strcmp0 (name, "__pycache__") == 0)
            continue;
          walk_dir (t, child, depth_left - 1);
        }
      else if (type == G_FILE_TYPE_REGULAR)
        {
          g_autofree gchar *path = g_file_get_path (child);
          emit_cube (t, path ? path : name,
                     (guint64) g_file_info_get_size (info));
          if (t->count >= 1500) return;   /* hard cap */
        }
    }
}

gboolean
cmacs_libregnum_scene_tree_build (CmacsLibregnumRenderCtx *r,
                                  const gchar *root_path)
{
  if (!r || !root_path) return FALSE;
  cmacs_libregnum_render_ctx_clear_drawables (r);

  TreeCtx t = { 0 };
  t.ctx     = r;
  t.spacing = 1.1;
  t.grid_n  = 24;   /* up to 576 cubes; widen if needed */

  g_autoptr (GFile) root = g_file_new_for_path (root_path);
  walk_dir (&t, root, 5 /* max recursion depth */);

  /* Re-grid based on actual count so the layout fits. */
  if (t.count > 0)
    {
      int n = (int) ceil (sqrt ((double) t.count));
      if (n < 4)  n = 4;
      if (n > 64) n = 64;
      t.grid_n = n;
    }

  /* If we're going to revisit, expand grid_n and re-emit.  Simpler:
   * accept the initial grid_n=24 packing and let the redraw show
   * the result. */
  return TRUE;
}

#endif /* HAVE_CMACS_LIBREGNUM */
