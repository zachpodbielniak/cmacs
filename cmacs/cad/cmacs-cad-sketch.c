/* cmacs-cad-sketch.c --- Interactive 2D constraint-sketch DEFUNs.
 *
 * Copyright (C) 2026 Zach Podbielniak
 * SPDX-License-Identifier: AGPL-3.0-or-later
 *
 * A thin Lisp bridge to cad-glib's CadSketch (SolveSpace solver): create
 * a sketch, add entities, apply constraints, solve, read back geometry +
 * degrees of freedom.  Sketches live in a process-wide handle table so a
 * Lisp integer handle survives across calls; the interactive sketcher
 * (lisp/cmacs/cmacs-cad-sketch.el) drives it and serialises the result
 * back into a `defsketch' source form.
 */

#include <config.h>

#ifdef HAVE_CMACS_CAD

#include "lisp.h"
#include "cmacs-cad.h"
#include "cmacs-cad-internal.h"

#include <string.h>

static GHashTable *cmacs_cad_sketches; /* guint handle -> CadSketch* */
static guint cmacs_cad_sketch_next = 1;

static CadSketch *
cmacs_cad_sketch_require (Lisp_Object handle)
{
  CadSketch *sk;
  CHECK_FIXNUM (handle);
  if (cmacs_cad_sketches == NULL)
    cmacs_cad_error_str ("no such sketch");
  sk = g_hash_table_lookup (cmacs_cad_sketches,
                            GUINT_TO_POINTER ((guint) XFIXNUM (handle)));
  if (sk == NULL)
    cmacs_cad_error_str ("no such sketch");
  return sk;
}

/* Map a Lisp constraint symbol to a CadConstraintKind, or signal. */
static CadConstraintKind
cmacs_cad_constraint_kind (Lisp_Object sym)
{
  struct { const char *name; CadConstraintKind kind; } table[] = {
    { "coincident",    CAD_CONSTRAINT_COINCIDENT },
    { "distance",      CAD_CONSTRAINT_DISTANCE },
    { "angle",         CAD_CONSTRAINT_ANGLE },
    { "parallel",      CAD_CONSTRAINT_PARALLEL },
    { "perpendicular", CAD_CONSTRAINT_PERPENDICULAR },
    { "tangent",       CAD_CONSTRAINT_TANGENT },
    { "equal",         CAD_CONSTRAINT_EQUAL },
    { "symmetric",     CAD_CONSTRAINT_SYMMETRIC },
    { "horizontal",    CAD_CONSTRAINT_HORIZONTAL },
    { "vertical",      CAD_CONSTRAINT_VERTICAL },
    { "diameter",      CAD_CONSTRAINT_DIAMETER },
    { "midpoint",      CAD_CONSTRAINT_MIDPOINT },
    { "fixed",         CAD_CONSTRAINT_FIXED },
  };
  Lisp_Object name = SYMBOLP (sym) ? SYMBOL_NAME (sym) : sym;
  gsize i;
  CHECK_STRING (name);
  for (i = 0; i < sizeof (table) / sizeof (table[0]); i++)
    if (strcmp (table[i].name, SSDATA (name)) == 0)
      return table[i].kind;
  cmacs_cad_error_str ("unknown constraint kind");
}

DEFUN ("cmacs-cad-sketch-new", Fcmacs_cad_sketch_new,
       Scmacs_cad_sketch_new, 0, 0, 0,
       doc: /* Create a new empty constraint sketch; return its handle.  */)
  (void)
{
  CadSketch *sk = cad_sketch_new ();
  guint handle = cmacs_cad_sketch_next++;
  if (cmacs_cad_sketches == NULL)
    cmacs_cad_sketches =
      g_hash_table_new_full (g_direct_hash, g_direct_equal, NULL,
                             g_object_unref);
  g_hash_table_insert (cmacs_cad_sketches, GUINT_TO_POINTER (handle), sk);
  return make_fixnum (handle);
}

DEFUN ("cmacs-cad-sketch-free", Fcmacs_cad_sketch_free,
       Scmacs_cad_sketch_free, 1, 1, 0,
       doc: /* Free the sketch HANDLE.  */)
  (Lisp_Object handle)
{
  CHECK_FIXNUM (handle);
  if (cmacs_cad_sketches != NULL)
    g_hash_table_remove (cmacs_cad_sketches,
                         GUINT_TO_POINTER ((guint) XFIXNUM (handle)));
  return Qnil;
}

DEFUN ("cmacs-cad-sketch-add-point", Fcmacs_cad_sketch_add_point,
       Scmacs_cad_sketch_add_point, 3, 3, 0,
       doc: /* Add a point at (X Y) to sketch HANDLE; return its entity id.  */)
  (Lisp_Object handle, Lisp_Object x, Lisp_Object y)
{
  CadSketch *sk = cmacs_cad_sketch_require (handle);
  return make_fixnum (cad_sketch_add_point (sk, XFLOATINT (x),
                                            XFLOATINT (y)));
}

DEFUN ("cmacs-cad-sketch-add-line", Fcmacs_cad_sketch_add_line,
       Scmacs_cad_sketch_add_line, 3, 3, 0,
       doc: /* Add a line between point ids A and B in sketch HANDLE.  */)
  (Lisp_Object handle, Lisp_Object a, Lisp_Object b)
{
  CadSketch *sk = cmacs_cad_sketch_require (handle);
  CHECK_FIXNUM (a); CHECK_FIXNUM (b);
  return make_fixnum (cad_sketch_add_line (sk, (guint) XFIXNUM (a),
                                           (guint) XFIXNUM (b)));
}

DEFUN ("cmacs-cad-sketch-add-circle", Fcmacs_cad_sketch_add_circle,
       Scmacs_cad_sketch_add_circle, 3, 3, 0,
       doc: /* Add a circle (CENTER point id, RADIUS) to sketch HANDLE.  */)
  (Lisp_Object handle, Lisp_Object center, Lisp_Object radius)
{
  CadSketch *sk = cmacs_cad_sketch_require (handle);
  CHECK_FIXNUM (center);
  return make_fixnum (cad_sketch_add_circle (sk, (guint) XFIXNUM (center),
                                             XFLOATINT (radius)));
}

DEFUN ("cmacs-cad-sketch-add-arc", Fcmacs_cad_sketch_add_arc,
       Scmacs_cad_sketch_add_arc, 4, 4, 0,
       doc: /* Add an arc (CENTER START END point ids) to sketch HANDLE.  */)
  (Lisp_Object handle, Lisp_Object center, Lisp_Object start, Lisp_Object end)
{
  CadSketch *sk = cmacs_cad_sketch_require (handle);
  CHECK_FIXNUM (center); CHECK_FIXNUM (start); CHECK_FIXNUM (end);
  return make_fixnum (cad_sketch_add_arc (sk, (guint) XFIXNUM (center),
                                          (guint) XFIXNUM (start),
                                          (guint) XFIXNUM (end)));
}

DEFUN ("cmacs-cad-sketch-constrain", Fcmacs_cad_sketch_constrain,
       Scmacs_cad_sketch_constrain, 2, 5, 0,
       doc: /* Add a KIND constraint to sketch HANDLE; return its id.
KIND is a symbol (coincident distance angle parallel perpendicular tangent
equal symmetric horizontal vertical diameter midpoint fixed).  A and B are
entity ids (B may be 0/omitted); VALUE is a dimension where the kind needs
one.  */)
  (Lisp_Object handle, Lisp_Object kind, Lisp_Object a, Lisp_Object b,
   Lisp_Object value)
{
  CadSketch *sk = cmacs_cad_sketch_require (handle);
  CadConstraintKind k = cmacs_cad_constraint_kind (kind);
  GError *error = NULL;
  guint id;
  guint ea = NILP (a) ? 0 : (guint) XFIXNUM (a);
  guint eb = NILP (b) ? 0 : (guint) XFIXNUM (b);
  gdouble v = NILP (value) ? 0.0 : XFLOATINT (value);
  id = cad_sketch_constrain (sk, k, ea, eb, v, &error);
  if (id == 0 && error != NULL)
    cmacs_cad_signal (error);
  return make_fixnum (id);
}

DEFUN ("cmacs-cad-sketch-solve", Fcmacs_cad_sketch_solve,
       Scmacs_cad_sketch_solve, 1, 1, 0,
       doc: /* Solve sketch HANDLE.  Returns t, or signals on failure.  */)
  (Lisp_Object handle)
{
  CadSketch *sk = cmacs_cad_sketch_require (handle);
  GError *error = NULL;
  if (!cad_sketch_solve (sk, &error))
    cmacs_cad_signal (error);
  return Qt;
}

DEFUN ("cmacs-cad-sketch-dof", Fcmacs_cad_sketch_dof,
       Scmacs_cad_sketch_dof, 1, 1, 0,
       doc: /* Return sketch HANDLE's remaining degrees of freedom.  */)
  (Lisp_Object handle)
{
  CadSketch *sk = cmacs_cad_sketch_require (handle);
  return make_fixnum (cad_sketch_get_dof (sk));
}

DEFUN ("cmacs-cad-sketch-failed", Fcmacs_cad_sketch_failed,
       Scmacs_cad_sketch_failed, 1, 1, 0,
       doc: /* Return the list of failing constraint ids for sketch HANDLE.  */)
  (Lisp_Object handle)
{
  CadSketch *sk = cmacs_cad_sketch_require (handle);
  GArray *failed = cad_sketch_get_failed (sk);
  Lisp_Object out = Qnil;
  if (failed != NULL)
    {
      guint i;
      for (i = failed->len; i > 0; i--)
        out = Fcons (make_fixnum (g_array_index (failed, guint, i - 1)),
                     out);
      g_array_unref (failed);
    }
  return out;
}

DEFUN ("cmacs-cad-sketch-point", Fcmacs_cad_sketch_point,
       Scmacs_cad_sketch_point, 2, 2, 0,
       doc: /* Return (X Y) of point ENTITY in sketch HANDLE, or nil.  */)
  (Lisp_Object handle, Lisp_Object entity)
{
  CadSketch *sk = cmacs_cad_sketch_require (handle);
  gdouble x, y;
  CHECK_FIXNUM (entity);
  if (!cad_sketch_get_point (sk, (guint) XFIXNUM (entity), &x, &y))
    return Qnil;
  return list2 (make_float (x), make_float (y));
}

DEFUN ("cmacs-cad-sketch-drag", Fcmacs_cad_sketch_drag,
       Scmacs_cad_sketch_drag, 4, 4, 0,
       doc: /* Drag POINT of sketch HANDLE to (X Y) and re-solve.  */)
  (Lisp_Object handle, Lisp_Object point, Lisp_Object x, Lisp_Object y)
{
  CadSketch *sk = cmacs_cad_sketch_require (handle);
  GError *error = NULL;
  CHECK_FIXNUM (point);
  if (!cad_sketch_drag_point (sk, (guint) XFIXNUM (point),
                              XFLOATINT (x), XFLOATINT (y), &error))
    {
      if (error != NULL) cmacs_cad_signal (error);
      return Qnil;
    }
  return Qt;
}

DEFUN ("cmacs-cad-sketch-closed-p", Fcmacs_cad_sketch_closed_p,
       Scmacs_cad_sketch_closed_p, 1, 1, 0,
       doc: /* Return t if sketch HANDLE forms a closed profile.  */)
  (Lisp_Object handle)
{
  CadSketch *sk = cmacs_cad_sketch_require (handle);
  GError *error = NULL;
  gboolean closed = cad_sketch_is_closed_profile (sk, &error);
  g_clear_error (&error);
  return closed ? Qt : Qnil;
}

DEFUN ("cmacs-cad-sketch-profile", Fcmacs_cad_sketch_profile,
       Scmacs_cad_sketch_profile, 1, 2, 0,
       doc: /* Return sketch HANDLE's closed profile as a list of (X Y).
ARC-SEGMENTS (default 16) sets the arc/circle tessellation.  */)
  (Lisp_Object handle, Lisp_Object arc_segments)
{
  CadSketch *sk = cmacs_cad_sketch_require (handle);
  GError *error = NULL;
  guint n = 0;
  guint segs = NILP (arc_segments) ? 16 : (guint) XFIXNUM (arc_segments);
  gdouble *pts = cad_sketch_get_profile_polyline (sk, segs, &n, &error);
  Lisp_Object out = Qnil;
  guint i;
  if (pts == NULL)
    {
      if (error != NULL) cmacs_cad_signal (error);
      return Qnil;
    }
  for (i = n; i > 0; i--)
    out = Fcons (list2 (make_float (pts[(i - 1) * 2]),
                        make_float (pts[(i - 1) * 2 + 1])),
                 out);
  g_free (pts);
  return out;
}

void
syms_of_cmacs_cad_sketch (void)
{
  defsubr (&Scmacs_cad_sketch_new);
  defsubr (&Scmacs_cad_sketch_free);
  defsubr (&Scmacs_cad_sketch_add_point);
  defsubr (&Scmacs_cad_sketch_add_line);
  defsubr (&Scmacs_cad_sketch_add_circle);
  defsubr (&Scmacs_cad_sketch_add_arc);
  defsubr (&Scmacs_cad_sketch_constrain);
  defsubr (&Scmacs_cad_sketch_solve);
  defsubr (&Scmacs_cad_sketch_dof);
  defsubr (&Scmacs_cad_sketch_failed);
  defsubr (&Scmacs_cad_sketch_point);
  defsubr (&Scmacs_cad_sketch_drag);
  defsubr (&Scmacs_cad_sketch_closed_p);
  defsubr (&Scmacs_cad_sketch_profile);
}

#endif /* HAVE_CMACS_CAD */
