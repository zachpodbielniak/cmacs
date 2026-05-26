/* cmacs-libregnum-scene-gobject.c --- GObject class hierarchy scene.
 *
 * Copyright (C) 2026 Zach Podbielniak
 * SPDX-License-Identifier: AGPL-3.0-or-later
 *
 * Walks `g_type_children` recursively from G_TYPE_OBJECT (or from a
 * named root), laying the resulting tree out in 3D.  Each class
 * becomes a cube; depth from the root maps to Y (height), siblings
 * fan out on the XZ plane, and the hue is derived from the toplevel
 * namespace so e.g. Gtk types are visually grouped vs. Lrg types.
 *
 * Filtering: a NULL or empty namespace argument means "all
 * descendants of G_TYPE_OBJECT", which is a *lot* of types in a
 * full cmacs session; the scene caps emission at 1500 nodes so the
 * grid doesn't explode.  Pass a namespace prefix (e.g. "Lrg",
 * "Gtk", "Mcp") to limit to a single library.
 *
 * Translation-unit firewall: same as scene-tree.c -- this file
 * pulls in libregnum.h and may NOT include cmacs internals. */

#include <config.h>

#ifdef HAVE_CMACS_LIBREGNUM

#include "cmacs-libregnum-render.h"
#include "cmacs-libregnum-scenes.h"

#include <libregnum.h>
#include <glib.h>
#include <glib-object.h>
#include <math.h>
#include <string.h>

typedef struct
{
  CmacsLibregnumRenderCtx *ctx;
  const gchar *namespace_prefix;     /* may be NULL or "" */
  guint        emitted;
  guint        cap;
  /* Per-depth column counters so siblings get unique x slots. */
  GArray      *cols_at_depth;        /* element-type: guint */
} GObjCtx;

static void
ensure_depth (GObjCtx *g, guint depth)
{
  while (g->cols_at_depth->len <= depth)
    {
      guint zero = 0;
      g_array_append_val (g->cols_at_depth, zero);
    }
}

static void
hue_to_rgb (double h, double s, double v,
            guint8 *R, guint8 *G, guint8 *B)
{
  while (h < 0.0)    h += 360.0;
  while (h >= 360.0) h -= 360.0;
  double hh = h / 60.0;
  int    i  = (int) floor (hh);
  double f  = hh - i;
  double p  = v * (1 - s);
  double q  = v * (1 - s * f);
  double t  = v * (1 - s * (1 - f));
  double r = 0, g = 0, b = 0;
  switch (i % 6)
    {
    case 0: r=v; g=t; b=p; break;
    case 1: r=q; g=v; b=p; break;
    case 2: r=p; g=v; b=t; break;
    case 3: r=p; g=q; b=v; break;
    case 4: r=t; g=p; b=v; break;
    case 5: r=v; g=p; b=q; break;
    }
  *R = (guint8) (r * 255);
  *G = (guint8) (g * 255);
  *B = (guint8) (b * 255);
}

/* Map the leading uppercase run of a type name (its GIR namespace
 * prefix in practice -- Gtk, Lrg, Mcp, G, Pango, ...) onto a stable
 * hue 0..360. */
static double
namespace_hue (const gchar *type_name)
{
  if (!type_name) return 0.0;
  gchar prefix[32] = {0};
  gsize n = 0;
  for (const gchar *p = type_name; *p && n < sizeof (prefix) - 1; p++)
    {
      if (g_ascii_isupper (*p) && (n == 0 || g_ascii_islower (*(p - 1))))
        {
          if (n > 0) break;        /* stop at the second uppercase run */
        }
      prefix[n++] = *p;
    }
  guint h = g_str_hash (prefix);
  return (double) (h % 360);
}

static gboolean
matches_namespace (GObjCtx *g, const gchar *type_name)
{
  if (!g->namespace_prefix || !*g->namespace_prefix) return TRUE;
  return g_str_has_prefix (type_name, g->namespace_prefix);
}

static void
emit_node (GObjCtx *g, GType type, guint depth)
{
  if (g->emitted >= g->cap) return;
  const gchar *name = g_type_name (type);
  if (!name) return;

  ensure_depth (g, depth);
  guint col = g_array_index (g->cols_at_depth, guint, depth);
  g_array_index (g->cols_at_depth, guint, depth) = col + 1;

  /* Lay out: y = -depth * row_spacing (root on top), x distributed
   * left-to-right by sibling index, z = depth modulated so deeper
   * trees curl back instead of fading into the distance. */
  float row_spacing = 1.8f;
  float col_spacing = 1.2f;
  float x = (col - 12.0f) * col_spacing;
  float y = -((float) depth) * row_spacing;
  float z = -((float) depth) * 0.6f;

  guint8 R, G, B;
  hue_to_rgb (namespace_hue (name), 0.55, 0.9, &R, &G, &B);
  g_autoptr (GrlColor) col_col = grl_color_new (R, G, B, 255);

  LrgCube3D *cube = lrg_cube3d_new_at (x, y, z, 0.9f, 0.6f, 0.9f);
  lrg_shape_set_color (LRG_SHAPE (cube), col_col);
  cmacs_libregnum_render_ctx_add_drawable (g->ctx, cube);
  g->emitted++;
}

static void
walk_children (GObjCtx *g, GType parent, guint depth)
{
  if (g->emitted >= g->cap) return;
  guint n_children = 0;
  GType *children = g_type_children (parent, &n_children);
  for (guint i = 0; i < n_children; i++)
    {
      const gchar *name = g_type_name (children[i]);
      if (name && matches_namespace (g, name))
        emit_node (g, children[i], depth);
      walk_children (g, children[i], depth + 1);
      if (g->emitted >= g->cap) break;
    }
  g_free (children);
}

gboolean
cmacs_libregnum_scene_gobject_build (CmacsLibregnumRenderCtx *r,
                                     const gchar *namespace_name)
{
  if (!r) return FALSE;

  /* Ensure GObject's type system is initialised; in a cmacs run-time
   * it always is, but the contract is the contract. */
  g_type_ensure (G_TYPE_OBJECT);

  cmacs_libregnum_render_ctx_clear_drawables (r);

  GObjCtx g = { 0 };
  g.ctx              = r;
  g.namespace_prefix = (namespace_name && *namespace_name)
                         ? namespace_name : NULL;
  g.cap              = 1500;
  g.cols_at_depth    = g_array_new (FALSE, TRUE, sizeof (guint));

  /* Always emit the root so the user has something to anchor on. */
  emit_node (&g, G_TYPE_OBJECT, 0);
  walk_children (&g, G_TYPE_OBJECT, 1);

  g_array_free (g.cols_at_depth, TRUE);
  return TRUE;
}

#endif /* HAVE_CMACS_LIBREGNUM */
