/* cmacs-libregnum-scene-mindmap.c --- org outline mind map scene.
 *
 * Copyright (C) 2026 Zach Podbielniak
 * SPDX-License-Identifier: AGPL-3.0-or-later
 *
 * Parses an org file into a heading tree (depth from the leading
 * asterisks) and lays the result out as a 3D radial tree.  Each
 * heading becomes a cube; parent/child relationships are drawn as
 * thin LrgLine3D edges.
 *
 * The layout: root at the origin, depth-1 children spread on a
 * circle in the XZ-plane, depth-2 children fan out further on
 * smaller arcs around each parent, etc.  Radius shrinks per depth
 * (cone-on-cone) so the whole structure fits in a bounded volume
 * regardless of tree shape.  No physics simulation -- the layout is
 * deterministic so reloading the same file produces the same map.
 *
 * Translation-unit firewall: same as scene-tree.c -- this file pulls
 * in libregnum.h and may NOT include cmacs internals. */

#include <config.h>

#ifdef HAVE_CMACS_LIBREGNUM

#include "cmacs-libregnum-render.h"
#include "cmacs-libregnum-scenes.h"

#include <libregnum.h>
#include <glib.h>
#include <math.h>
#include <string.h>

#ifndef G_PI
#define G_PI 3.14159265358979323846
#endif

typedef struct Node Node;
struct Node
{
  gchar  *title;
  guint   depth;        /* 0 = synthetic root, 1 = "* heading", ... */
  Node   *parent;
  GPtrArray *children;  /* element-type: Node*, owned */
  /* Layout output: filled in by layout_pass. */
  float   x, y, z;
};

static Node *
node_new (const gchar *title, guint depth, Node *parent)
{
  Node *n  = g_new0 (Node, 1);
  n->title = g_strdup (title ? title : "");
  n->depth = depth;
  n->parent   = parent;
  n->children = g_ptr_array_new ();
  if (parent)
    g_ptr_array_add (parent->children, n);
  return n;
}

static void
node_free (Node *n)
{
  if (!n) return;
  for (guint i = 0; i < n->children->len; i++)
    node_free ((Node *) n->children->pdata[i]);
  g_ptr_array_free (n->children, TRUE);
  g_free (n->title);
  g_free (n);
}

/* Parse a single org line.  Returns the depth (number of leading
 * asterisks immediately followed by space) and copies the heading
 * text into *title_out (caller frees).  Returns 0 for non-heading
 * lines. */
static guint
parse_heading_line (const gchar *line, gchar **title_out)
{
  guint depth = 0;
  const gchar *p = line;
  while (*p == '*') { depth++; p++; }
  if (depth == 0) return 0;
  if (*p != ' ' && *p != '\t') return 0;
  while (*p == ' ' || *p == '\t') p++;
  /* Strip trailing newline / CR. */
  const gchar *end = p + strlen (p);
  while (end > p && (*(end - 1) == '\n' || *(end - 1) == '\r')) end--;
  *title_out = g_strndup (p, end - p);
  return depth;
}

static Node *
parse_org_file (const gchar *path)
{
  g_autoptr (GError) err = NULL;
  gchar *content = NULL;
  gsize  length  = 0;
  if (!g_file_get_contents (path, &content, &length, &err))
    return NULL;

  Node *root = node_new (path, 0, NULL);

  /* Stack of ancestors keyed by depth; stack[d] = the most recent
   * node at depth d.  When emitting a node at depth D, its parent is
   * stack[D-1] (falling back to root if not present). */
  Node *stack[64] = { 0 };
  stack[0] = root;

  gchar **lines = g_strsplit (content, "\n", -1);
  for (guint i = 0; lines[i]; i++)
    {
      g_autofree gchar *title = NULL;
      guint depth = parse_heading_line (lines[i], &title);
      if (depth == 0 || depth >= 64) continue;

      Node *parent = NULL;
      for (gint d = (gint) depth - 1; d >= 0; d--)
        if (stack[d]) { parent = stack[d]; break; }
      if (!parent) parent = root;

      Node *n = node_new (title, depth, parent);
      stack[depth] = n;
      /* Invalidate deeper-stack entries -- they belong to a previous
       * subtree that's now closed. */
      for (guint d = depth + 1; d < 64; d++) stack[d] = NULL;
    }
  g_strfreev (lines);
  g_free (content);
  return root;
}

/* Radial layout: place a node at given xyz, then evenly distribute
 * its children on a circle in the local XZ plane (with a slight Y
 * lift so the tree fans out vertically too).  Radius shrinks per
 * recursion. */
static void
layout_pass (Node *n, float radius, float y_step, double angle_start,
             double angle_span)
{
  guint nc = n->children->len;
  if (nc == 0) return;
  double step = angle_span / (double) nc;
  for (guint i = 0; i < nc; i++)
    {
      Node *c = (Node *) n->children->pdata[i];
      double a = angle_start + step * (i + 0.5);
      c->x = n->x + (float) (radius * cos (a));
      c->z = n->z + (float) (radius * sin (a));
      c->y = n->y - y_step;     /* deeper headings sink slightly */
      /* For the child's own subtree, narrow the angular span so
       * sub-fans don't collide with sibling fans. */
      double child_span = (nc == 1) ? (2.0 * G_PI)
                                    : step * 0.85;
      double child_start = a - child_span * 0.5;
      layout_pass (c, radius * 0.65f, y_step, child_start, child_span);
    }
}

static void
hsv_to_rgb (double h, double s, double v,
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

static void
emit_node (CmacsLibregnumRenderCtx *ctx, Node *n, guint *count, guint cap)
{
  if (*count >= cap) return;
  guint8 R, G, B;
  hsv_to_rgb (((double) (n->depth * 53)) , 0.65, 0.9, &R, &G, &B);
  g_autoptr (GrlColor) col = grl_color_new (R, G, B, 255);

  float size = 0.8f - 0.1f * (float) n->depth;
  if (size < 0.25f) size = 0.25f;

  LrgCube3D *cube = lrg_cube3d_new_at (n->x, n->y, n->z, size, size, size);
  lrg_shape_set_color (LRG_SHAPE (cube), col);
  cmacs_libregnum_render_ctx_add_drawable (ctx, cube);
  (*count)++;

  if (n->parent && *count < cap)
    {
      g_autoptr (GrlColor) edge_col = grl_color_new (180, 180, 200, 255);
      LrgLine3D *line = lrg_line3d_new_from_to (n->parent->x, n->parent->y,
                                                 n->parent->z,
                                                 n->x, n->y, n->z);
      lrg_shape_set_color (LRG_SHAPE (line), edge_col);
      cmacs_libregnum_render_ctx_add_drawable (ctx, line);
      (*count)++;
    }

  for (guint i = 0; i < n->children->len && *count < cap; i++)
    emit_node (ctx, (Node *) n->children->pdata[i], count, cap);
}

gboolean
cmacs_libregnum_scene_mindmap_build (CmacsLibregnumRenderCtx *r,
                                     const gchar *org_file_path)
{
  if (!r || !org_file_path) return FALSE;

  Node *root = parse_org_file (org_file_path);
  if (!root) return FALSE;

  /* Layout: root at origin, depth-1 nodes on a circle of radius
   * 6, fanning over the full 2π span. */
  root->x = root->y = root->z = 0;
  layout_pass (root, 6.0f, 1.0f, 0.0, 2.0 * G_PI);

  cmacs_libregnum_render_ctx_clear_drawables (r);
  guint count = 0;

  /* Skip the synthetic root cube (it represents the file itself,
   * not a heading) but still walk its children. */
  for (guint i = 0; i < root->children->len && count < 1500; i++)
    emit_node (r, (Node *) root->children->pdata[i], &count, 1500);

  node_free (root);
  return TRUE;
}

#endif /* HAVE_CMACS_LIBREGNUM */
