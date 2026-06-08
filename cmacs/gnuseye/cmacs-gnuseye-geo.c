/* cmacs-gnuseye-geo.c --- geodesy DEFUNs for GNU's Eye.
 *
 * Copyright (C) 2026 Zach Podbielniak
 * SPDX-License-Identifier: AGPL-3.0-or-later
 *
 * Thin Lisp wrappers over the header-only geodesy in
 * cmacs-gnuseye-geomath.h.  These let Elisp layers and tests compute
 * positions/bearings without re-deriving the projection, and use the
 * same maths the render half uses to place markers. */

#include <config.h>

#ifdef HAVE_CMACS_GNUSEYE

#include "lisp.h"
#include "cmacs-gnuseye.h"
#include "cmacs-gnuseye-geomath.h"

static Lisp_Object
vec3 (double a, double b, double c)
{
  Lisp_Object v = make_vector (3, Qnil);
  ASET (v, 0, make_float (a));
  ASET (v, 1, make_float (b));
  ASET (v, 2, make_float (c));
  return v;
}

DEFUN ("cmacs-gnuseye-latlon-to-xyz", Fcmacs_gnuseye_latlon_to_xyz,
       Scmacs_gnuseye_latlon_to_xyz, 2, 3, 0,
       doc: /* Return the globe world position [X Y Z] for LAT, LON.
LAT and LON are degrees; optional ALT-M is altitude above the sphere in
metres.  Right-handed, Y-up, 1 world unit == 1000 km.  */)
  (Lisp_Object lat, Lisp_Object lon, Lisp_Object alt_m)
{
  double x, y, z;
  gnuseye_latlon_to_xyz (XFLOATINT (lat), XFLOATINT (lon),
                         NILP (alt_m) ? 0.0 : XFLOATINT (alt_m), &x, &y, &z);
  return vec3 (x, y, z);
}

DEFUN ("cmacs-gnuseye-xyz-to-latlon", Fcmacs_gnuseye_xyz_to_latlon,
       Scmacs_gnuseye_xyz_to_latlon, 3, 3, 0,
       doc: /* Return (LAT LON ALT-M) for globe world position X, Y, Z.  */)
  (Lisp_Object x, Lisp_Object y, Lisp_Object z)
{
  double lat, lon, alt;
  gnuseye_xyz_to_latlon (XFLOATINT (x), XFLOATINT (y), XFLOATINT (z),
                         &lat, &lon, &alt);
  return list3 (make_float (lat), make_float (lon), make_float (alt));
}

DEFUN ("cmacs-gnuseye-heading-vector", Fcmacs_gnuseye_heading_vector,
       Scmacs_gnuseye_heading_vector, 3, 3, 0,
       doc: /* Return the unit travel direction [FX FY FZ] in world space.
For an object at LAT, LON travelling on HEADING degrees clockwise from
true north.  Tangent to the globe surface.  */)
  (Lisp_Object lat, Lisp_Object lon, Lisp_Object heading)
{
  double fx, fy, fz;
  gnuseye_heading_forward (XFLOATINT (lat), XFLOATINT (lon),
                           XFLOATINT (heading), &fx, &fy, &fz);
  return vec3 (fx, fy, fz);
}

DEFUN ("cmacs-gnuseye-great-circle", Fcmacs_gnuseye_great_circle,
       Scmacs_gnuseye_great_circle, 5, 5, 0,
       doc: /* Sample the great circle from (LAT1 LON1) to (LAT2 LON2).
Returns a vector of N [LAT LON] pairs (degrees) including both ends.  */)
  (Lisp_Object lat1, Lisp_Object lon1, Lisp_Object lat2, Lisp_Object lon2,
   Lisp_Object n)
{
  CHECK_FIXNAT (n);
  EMACS_INT count = XFIXNUM (n);
  if (count < 2) count = 2;
  double a1 = XFLOATINT (lat1), o1 = XFLOATINT (lon1);
  double a2 = XFLOATINT (lat2), o2 = XFLOATINT (lon2);
  Lisp_Object out = make_vector (count, Qnil);
  for (EMACS_INT i = 0; i < count; i++)
    {
      double t = (double) i / (double) (count - 1);
      double la, lo;
      gnuseye_great_circle_point (a1, o1, a2, o2, t, &la, &lo);
      Lisp_Object pair = make_vector (2, Qnil);
      ASET (pair, 0, make_float (la));
      ASET (pair, 1, make_float (lo));
      ASET (out, i, pair);
    }
  return out;
}

DEFUN ("cmacs-gnuseye-haversine", Fcmacs_gnuseye_haversine,
       Scmacs_gnuseye_haversine, 4, 4, 0,
       doc: /* Great-circle distance in metres between two lat/lon points.  */)
  (Lisp_Object lat1, Lisp_Object lon1, Lisp_Object lat2, Lisp_Object lon2)
{
  return make_float (gnuseye_haversine_m (XFLOATINT (lat1), XFLOATINT (lon1),
                                          XFLOATINT (lat2), XFLOATINT (lon2)));
}

DEFUN ("cmacs-gnuseye-bearing", Fcmacs_gnuseye_bearing,
       Scmacs_gnuseye_bearing, 4, 4, 0,
       doc: /* Initial bearing in degrees (cw from north) from p1 to p2.  */)
  (Lisp_Object lat1, Lisp_Object lon1, Lisp_Object lat2, Lisp_Object lon2)
{
  return make_float (gnuseye_bearing_deg (XFLOATINT (lat1), XFLOATINT (lon1),
                                          XFLOATINT (lat2), XFLOATINT (lon2)));
}

void
syms_of_cmacs_gnuseye_geo (void)
{
  defsubr (&Scmacs_gnuseye_latlon_to_xyz);
  defsubr (&Scmacs_gnuseye_xyz_to_latlon);
  defsubr (&Scmacs_gnuseye_heading_vector);
  defsubr (&Scmacs_gnuseye_great_circle);
  defsubr (&Scmacs_gnuseye_haversine);
  defsubr (&Scmacs_gnuseye_bearing);
}

#endif /* HAVE_CMACS_GNUSEYE */
