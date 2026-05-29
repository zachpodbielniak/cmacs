/* cmacs-libregnum-scene-tree.c --- project file tree scene.
 *
 * Copyright (C) 2026 Zach Podbielniak
 * SPDX-License-Identifier: AGPL-3.0-or-later
 *
 * Builds a navigable 3D node-link tree of the project: directories and
 * files are nodes laid out in a tidy hanging tree (depth -> Y, siblings
 * spread on X with width proportional to subtree leaf count), connected
 * to their parent by thin edges.  Directories render as spheres, files
 * as cubes (height = log file size, hue = extension).  Every node is
 * also recorded in the render context's node table so the click/keyboard
 * navigation layer can pick it, label it, and open/drill it.
 *
 * Translation-unit firewall: this file includes libregnum.h (and thus
 * indirectly raylib.h) so it CANNOT include cmacs internals like
 * lisp.h/frame.h/buffer.h.  It talks to cmacs only via the plain-C
 * cmacs-libregnum-render.h API. */

#include <config.h>

#ifdef HAVE_CMACS_LIBREGNUM

#include "cmacs-libregnum-render.h"
#include "cmacs-libregnum-scenes.h"

#include <libregnum.h>
#include <glib.h>
#include <math.h>
#include <string.h>

/* Layout constants. */
#define SLOT      1.5f    /* horizontal width allotted per leaf */
#define LAYER_GAP 3.2f    /* vertical distance between depth levels */
#define MAX_NODES 2000    /* hard cap on total nodes (dirs + files) */
#define MAX_DEPTH 6       /* recursion depth cap */

typedef struct Node Node;
struct Node
{
  gchar     *path;        /* absolute path, owned */
  gchar     *name;        /* basename, owned */
  gboolean   is_dir;
  guint64    size;        /* file size (0 for dirs) */
  guint      depth;
  GPtrArray *children;    /* Node*, owned */
  /* computed */
  guint      leaves;      /* leaf-descendant count (>=1) */
  float      x, y, z;
};

static Node *
node_new (const gchar *path, const gchar *name, gboolean is_dir,
          guint64 size, guint depth)
{
  Node *n = g_new0 (Node, 1);
  n->path = g_strdup (path ? path : "");
  n->name = g_strdup (name ? name : "");
  n->is_dir = is_dir;
  n->size = size;
  n->depth = depth;
  n->children = g_ptr_array_new ();
  return n;
}

static void
node_free (Node *n)
{
  if (!n) return;
  for (guint i = 0; i < n->children->len; i++)
    node_free ((Node *) n->children->pdata[i]);
  g_ptr_array_free (n->children, TRUE);
  g_free (n->path);
  g_free (n->name);
  g_free (n);
}

static gboolean
skip_dir (const gchar *name)
{
  return (g_strcmp0 (name, ".git") == 0
          || g_strcmp0 (name, "build") == 0
          || g_strcmp0 (name, "node_modules") == 0
          || g_strcmp0 (name, "native-lisp") == 0
          || g_strcmp0 (name, "__pycache__") == 0);
}

/* Recursively read DIR's children into PARENT, depth-first.  *COUNT is
 * the running total node count (capped at MAX_NODES). */
static void
build_subtree (Node *parent, GFile *dir, guint depth, guint *count)
{
  if (depth >= MAX_DEPTH || *count >= MAX_NODES) return;
  g_autoptr (GError) err = NULL;
  g_autoptr (GFileEnumerator) en =
    g_file_enumerate_children (dir,
                               G_FILE_ATTRIBUTE_STANDARD_NAME ","
                               G_FILE_ATTRIBUTE_STANDARD_TYPE ","
                               G_FILE_ATTRIBUTE_STANDARD_SIZE,
                               G_FILE_QUERY_INFO_NOFOLLOW_SYMLINKS,
                               NULL, &err);
  if (!en) return;

  while (*count < MAX_NODES)
    {
      g_autoptr (GFileInfo) info =
        g_file_enumerator_next_file (en, NULL, NULL);
      if (!info) break;
      const gchar *name = g_file_info_get_name (info);
      if (!name || name[0] == '.') continue;   /* skip dotfiles */
      GFileType type = g_file_info_get_file_type (info);
      g_autoptr (GFile) child = g_file_get_child (dir, name);
      g_autofree gchar *cpath = g_file_get_path (child);

      if (type == G_FILE_TYPE_DIRECTORY)
        {
          if (skip_dir (name)) continue;
          Node *dn = node_new (cpath ? cpath : name, name, TRUE, 0,
                               depth + 1);
          g_ptr_array_add (parent->children, dn);
          (*count)++;
          build_subtree (dn, child, depth + 1, count);
        }
      else if (type == G_FILE_TYPE_REGULAR)
        {
          Node *fn = node_new (cpath ? cpath : name, name, FALSE,
                               (guint64) g_file_info_get_size (info),
                               depth + 1);
          g_ptr_array_add (parent->children, fn);
          (*count)++;
        }
    }
}

/* Post-order: leaf-descendant count (a leaf counts as 1). */
static guint
compute_leaves (Node *n)
{
  if (n->children->len == 0) { n->leaves = 1; return 1; }
  guint sum = 0;
  for (guint i = 0; i < n->children->len; i++)
    sum += compute_leaves ((Node *) n->children->pdata[i]);
  n->leaves = sum;
  return sum;
}

/* Tidy layered layout: a node's horizontal span is leaves*SLOT; each
 * child is placed left-to-right within it; the node sits centered over
 * its children.  X0 is the left edge of this node's span. */
static void
layout (Node *n, float x0)
{
  float span = n->leaves * SLOT;
  n->y = -(float) n->depth * LAYER_GAP;
  n->z = 0.0f;
  if (n->children->len == 0)
    {
      n->x = x0 + span * 0.5f;
      return;
    }
  float cx = x0;
  for (guint i = 0; i < n->children->len; i++)
    {
      Node *c = (Node *) n->children->pdata[i];
      layout (c, cx);
      cx += c->leaves * SLOT;
    }
  n->x = x0 + span * 0.5f;
}

/* Stable hue from a file's extension; falls back to the whole name. */
static void
extension_color (const gchar *path, guint8 *r, guint8 *g, guint8 *b)
{
  const gchar *dot = strrchr (path, '.');
  guint hash = 0;
  if (dot && dot != path)
    for (const gchar *p = dot + 1; *p; p++)
      hash = (hash * 131u) + (guint) *p;
  else
    hash = (guint) g_str_hash (path);

  double h = (hash % 360) / 60.0;
  double s = 0.6, v = 0.9;
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

/* Pre-order emit: each node gets a drawable + a node-table entry, and an
 * edge to its parent.  PARENT_ID is the node-table id of the parent (-1
 * for the root); parents are emitted before children so it is known. */
static void
emit (CmacsLibregnumRenderCtx *ctx, Node *n, int parent_id,
      float parent_x, float parent_y, float parent_z)
{
  guint id;
  float hw, hh, hd;

  if (n->is_dir)
    {
      /* Directory: sphere, radius grows slightly with child count. */
      float radius = 0.45f + 0.04f * (float) n->children->len;
      if (radius > 1.1f) radius = 1.1f;
      g_autoptr (GrlColor) col = grl_color_new (250, 200, 90, 255);
      LrgSphere3D *s = lrg_sphere3d_new_at (n->x, n->y, n->z, radius);
      lrg_shape_set_color (LRG_SHAPE (s), col);
      cmacs_libregnum_render_ctx_add_drawable (ctx, s);
      hw = hh = hd = radius;
    }
  else
    {
      /* File: cube, height = log size, hue = extension. */
      double hgt = (n->size == 0) ? 0.25 : log10 ((double) n->size) * 0.55;
      if (hgt < 0.2) hgt = 0.2;
      if (hgt > 6.0) hgt = 6.0;
      guint8 cr, cg, cb;
      extension_color (n->path, &cr, &cg, &cb);
      g_autoptr (GrlColor) col = grl_color_new (cr, cg, cb, 255);
      LrgCube3D *cube = lrg_cube3d_new_at (n->x, n->y, n->z,
                                           0.7f, (float) hgt, 0.7f);
      lrg_shape_set_color (LRG_SHAPE (cube), col);
      cmacs_libregnum_render_ctx_add_drawable (ctx, cube);
      hw = 0.35f; hh = (float) hgt * 0.5f; hd = 0.35f;
    }

  id = cmacs_libregnum_render_ctx_add_node (ctx, n->path, n->name,
                                            n->is_dir, (int) n->depth,
                                            parent_id, n->x, n->y, n->z,
                                            hw, hh, hd);

  /* Edge to parent (skip for the root). */
  if (parent_id >= 0)
    {
      g_autoptr (GrlColor) ecol = grl_color_new (130, 130, 150, 200);
      LrgLine3D *line = lrg_line3d_new_from_to (parent_x, parent_y, parent_z,
                                                n->x, n->y, n->z);
      lrg_shape_set_color (LRG_SHAPE (line), ecol);
      cmacs_libregnum_render_ctx_add_drawable (ctx, line);
    }

  for (guint i = 0; i < n->children->len; i++)
    emit (ctx, (Node *) n->children->pdata[i], (int) id,
          n->x, n->y, n->z);
}

gboolean
cmacs_libregnum_scene_tree_build (CmacsLibregnumRenderCtx *r,
                                  const gchar *root_path)
{
  if (!r || !root_path) return FALSE;
  cmacs_libregnum_render_ctx_clear_drawables (r);

  g_autoptr (GFile) root_file = g_file_new_for_path (root_path);
  g_autofree gchar *base = g_path_get_basename (root_path);
  Node *root = node_new (root_path, base, TRUE, 0, 0);

  guint count = 1;   /* root counts */
  build_subtree (root, root_file, 0, &count);

  compute_leaves (root);
  /* Centre the whole tree on X about the origin. */
  layout (root, -(root->leaves * SLOT) * 0.5f);

  emit (r, root, -1, 0, 0, 0);

  node_free (root);
  return TRUE;
}

#endif /* HAVE_CMACS_LIBREGNUM */
