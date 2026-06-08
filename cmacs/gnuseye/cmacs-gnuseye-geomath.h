/* cmacs-gnuseye-geomath.h --- pure-C geodesy shared by both halves.
 *
 * Copyright (C) 2026 Zach Podbielniak
 * SPDX-License-Identifier: AGPL-3.0-or-later
 *
 * Header-only geodetic helpers used by BOTH the Lisp-facing wrappers in
 * cmacs-gnuseye-geo.c AND the libregnum-facing render half in
 * cmacs-gnuseye-globe.c.  Deliberately depends on NOTHING but <math.h>
 * (no lisp.h, no libregnum.h) so it sits cleanly on either side of the
 * raylib `Color' firewall.
 *
 * World convention matches libregnum scenes: right-handed, Y-up.  The
 * globe is a sphere of radius GNUSEYE_GLOBE_RADIUS world units.  We map
 * 1 world unit == 1000 km, so altitudes (in metres) lift markers off the
 * surface at a natural scale and a 400 km LEO satellite sits visibly
 * above the limb.  lat=0,lon=0 is at (+R,0,0); the north pole at (0,+R,0);
 * longitude increases eastward toward -Z (so, viewed from outside with
 * north up, east is to the right -- a standard, un-mirrored globe). */

#ifndef CMACS_GNUSEYE_GEOMATH_H
#define CMACS_GNUSEYE_GEOMATH_H

#include <math.h>

#ifndef M_PI
#define M_PI 3.14159265358979323846
#endif

/* Mean Earth radius (WGS84 authalic ~6371 km), in metres. */
#define GNUSEYE_EARTH_RADIUS_M 6371000.0
/* Globe radius in libregnum world units (1 unit == 1000 km). */
#define GNUSEYE_GLOBE_RADIUS   6.371

#define GNUSEYE_DEG2RAD (M_PI / 180.0)
#define GNUSEYE_RAD2DEG (180.0 / M_PI)

/* Geodetic (lat, lon in degrees, altitude in metres above the sphere)
 * -> world XYZ on/above the globe. */
static inline void
gnuseye_latlon_to_xyz (double lat_deg, double lon_deg, double alt_m,
                       double *x, double *y, double *z)
{
  double lat = lat_deg * GNUSEYE_DEG2RAD;
  double lon = lon_deg * GNUSEYE_DEG2RAD;
  double r = GNUSEYE_GLOBE_RADIUS
             * (1.0 + alt_m / GNUSEYE_EARTH_RADIUS_M);
  double cl = cos (lat);
  *x = r * cl * cos (lon);
  *y = r * sin (lat);
  /* Longitude winds toward -Z so that, viewed from outside with north up,
   * east is to the right (a standard globe) rather than mirrored. */
  *z = -r * cl * sin (lon);
}

/* World XYZ -> geodetic (lat, lon degrees, altitude metres). */
static inline void
gnuseye_xyz_to_latlon (double x, double y, double z,
                       double *lat_deg, double *lon_deg, double *alt_m)
{
  double r = sqrt (x * x + y * y + z * z);
  if (r <= 0.0)
    {
      *lat_deg = *lon_deg = *alt_m = 0.0;
      return;
    }
  *lat_deg = asin (y / r) * GNUSEYE_RAD2DEG;
  *lon_deg = atan2 (-z, x) * GNUSEYE_RAD2DEG;   /* match the -Z winding */
  *alt_m = (r / GNUSEYE_GLOBE_RADIUS - 1.0) * GNUSEYE_EARTH_RADIUS_M;
}

/* Local east-north-up unit basis at (lat, lon) in world space.  `up' is
 * the outward surface normal; `north' points toward the north pole along
 * the meridian; `east' completes the right-handed tangent frame. */
static inline void
gnuseye_enu_basis (double lat_deg, double lon_deg,
                   double up[3], double east[3], double north[3])
{
  double lat = lat_deg * GNUSEYE_DEG2RAD;
  double lon = lon_deg * GNUSEYE_DEG2RAD;
  double sla = sin (lat), cla = cos (lat);
  double slo = sin (lon), clo = cos (lon);
  /* Z components negated to match the -Z longitude winding in
   * gnuseye_latlon_to_xyz (keeps east/north/up a consistent tangent frame). */
  up[0] = cla * clo;  up[1] = sla;  up[2] = -cla * slo;
  east[0] = -slo;     east[1] = 0.0; east[2] = -clo;
  north[0] = -sla * clo; north[1] = cla; north[2] = sla * slo;
}

/* Forward direction (unit world vector) for an object at (lat, lon)
 * travelling on HEADING degrees clockwise from true north.  Tangent to
 * the surface.  Used to orient aircraft/vessel/satellite markers along
 * their direction of travel. */
static inline void
gnuseye_heading_forward (double lat_deg, double lon_deg, double heading_deg,
                         double *fx, double *fy, double *fz)
{
  double up[3], east[3], north[3];
  gnuseye_enu_basis (lat_deg, lon_deg, up, east, north);
  double h = heading_deg * GNUSEYE_DEG2RAD;
  double ch = cos (h), sh = sin (h);
  *fx = ch * north[0] + sh * east[0];
  *fy = ch * north[1] + sh * east[1];
  *fz = ch * north[2] + sh * east[2];
}

/* Great-circle interpolation between two surface points, fraction t in
 * [0,1].  Writes the interpolated (lat, lon) in degrees. */
static inline void
gnuseye_great_circle_point (double lat1, double lon1,
                            double lat2, double lon2, double t,
                            double *out_lat, double *out_lon)
{
  double a[3], b[3];
  gnuseye_latlon_to_xyz (lat1, lon1, 0.0, &a[0], &a[1], &a[2]);
  gnuseye_latlon_to_xyz (lat2, lon2, 0.0, &b[0], &b[1], &b[2]);
  /* Normalise to unit vectors. */
  double na = sqrt (a[0]*a[0]+a[1]*a[1]+a[2]*a[2]);
  double nb = sqrt (b[0]*b[0]+b[1]*b[1]+b[2]*b[2]);
  if (na > 0) { a[0]/=na; a[1]/=na; a[2]/=na; }
  if (nb > 0) { b[0]/=nb; b[1]/=nb; b[2]/=nb; }
  double dot = a[0]*b[0]+a[1]*b[1]+a[2]*b[2];
  if (dot > 1.0) dot = 1.0; else if (dot < -1.0) dot = -1.0;
  double omega = acos (dot);
  double s0, s1;
  if (omega < 1e-9)
    { s0 = 1.0 - t; s1 = t; }            /* nearly coincident -> lerp */
  else
    {
      double so = sin (omega);
      s0 = sin ((1.0 - t) * omega) / so;
      s1 = sin (t * omega) / so;
    }
  double px = s0*a[0] + s1*b[0];
  double py = s0*a[1] + s1*b[1];
  double pz = s0*a[2] + s1*b[2];
  double dummy;
  gnuseye_xyz_to_latlon (px, py, pz, out_lat, out_lon, &dummy);
}

/* Great-circle (haversine) distance in metres between two lat/lon points. */
static inline double
gnuseye_haversine_m (double lat1, double lon1, double lat2, double lon2)
{
  double p1 = lat1 * GNUSEYE_DEG2RAD, p2 = lat2 * GNUSEYE_DEG2RAD;
  double dphi = (lat2 - lat1) * GNUSEYE_DEG2RAD;
  double dlam = (lon2 - lon1) * GNUSEYE_DEG2RAD;
  double a = sin (dphi/2) * sin (dphi/2)
           + cos (p1) * cos (p2) * sin (dlam/2) * sin (dlam/2);
  double c = 2.0 * atan2 (sqrt (a), sqrt (1.0 - a));
  return GNUSEYE_EARTH_RADIUS_M * c;
}

/* Initial bearing (degrees clockwise from north) from point 1 to point 2. */
static inline double
gnuseye_bearing_deg (double lat1, double lon1, double lat2, double lon2)
{
  double p1 = lat1 * GNUSEYE_DEG2RAD, p2 = lat2 * GNUSEYE_DEG2RAD;
  double dlam = (lon2 - lon1) * GNUSEYE_DEG2RAD;
  double y = sin (dlam) * cos (p2);
  double x = cos (p1) * sin (p2) - sin (p1) * cos (p2) * cos (dlam);
  double br = atan2 (y, x) * GNUSEYE_RAD2DEG;
  return fmod (br + 360.0, 360.0);
}

/* Destination point: starting at (lat,lon), travel DIST_M metres along the
 * great circle on initial bearing BRG_DEG (degrees clockwise from north).
 * Writes the destination (lat, lon) in degrees.  Used to draw range/coverage
 * rings (sample bearings 0..360 at a fixed distance) and geofence circles. */
static inline void
gnuseye_destination (double lat_deg, double lon_deg, double brg_deg,
                     double dist_m, double *out_lat, double *out_lon)
{
  double dr = dist_m / GNUSEYE_EARTH_RADIUS_M;       /* angular distance */
  double p1 = lat_deg * GNUSEYE_DEG2RAD;
  double l1 = lon_deg * GNUSEYE_DEG2RAD;
  double br = brg_deg * GNUSEYE_DEG2RAD;
  double sp = sin (p1), cp = cos (p1), sd = sin (dr), cd = cos (dr);
  double p2 = asin (sp * cd + cp * sd * cos (br));
  double l2 = l1 + atan2 (sin (br) * sd * cp, cd - sp * sin (p2));
  *out_lat = p2 * GNUSEYE_RAD2DEG;
  /* Normalise longitude to [-180,180]. */
  double lon = l2 * GNUSEYE_RAD2DEG;
  lon = fmod (lon + 540.0, 360.0) - 180.0;
  *out_lon = lon;
}

/* Subsolar point (lat, lon in degrees) at Unix time UNIX_S: the geographic
 * point where the Sun is directly overhead.  Low-precision NOAA almanac
 * (~0.01 deg) -- ample for a day/night terminator.  The terminator is the
 * great circle 90 deg from this point; the night hemisphere is the far side
 * of the sun-unit vector. */
static inline void
gnuseye_subsolar_point (double unix_s, double *out_lat, double *out_lon)
{
  double jd = unix_s / 86400.0 + 2440587.5;
  double n  = jd - 2451545.0;                         /* days since J2000 */
  double L  = fmod (280.460 + 0.9856474 * n, 360.0);  /* mean longitude */
  double g  = fmod (357.528 + 0.9856003 * n, 360.0) * GNUSEYE_DEG2RAD;
  if (L < 0) L += 360.0;
  /* Apparent ecliptic longitude + obliquity. */
  double lam = (L + 1.915 * sin (g) + 0.020 * sin (2.0 * g)) * GNUSEYE_DEG2RAD;
  double eps = (23.439 - 0.0000004 * n) * GNUSEYE_DEG2RAD;
  double dec = asin (sin (eps) * sin (lam));           /* declination */
  double ra  = atan2 (cos (eps) * sin (lam), cos (lam)); /* right ascension */
  /* GMST in degrees (same series as cmacs-gnuseye-sgp4.c gmst_rad). */
  double gmst = fmod (280.46061837 + 360.98564736629 * n, 360.0);
  if (gmst < 0) gmst += 360.0;
  *out_lat = dec * GNUSEYE_RAD2DEG;
  double lon = ra * GNUSEYE_RAD2DEG - gmst;            /* east-positive */
  lon = fmod (lon + 540.0, 360.0) - 180.0;
  *out_lon = lon;
}

/* Unit world vector from the globe centre toward the Sun at Unix time
 * UNIX_S, in the SAME -Z-winding frame as gnuseye_latlon_to_xyz, so it can
 * drive the globe shader's `sunDir' uniform consistently with the markers. */
static inline void
gnuseye_sun_unit (double unix_s, double *x, double *y, double *z)
{
  double slat, slon;
  gnuseye_subsolar_point (unix_s, &slat, &slon);
  gnuseye_latlon_to_xyz (slat, slon, 0.0, x, y, z);
  double n = sqrt ((*x) * (*x) + (*y) * (*y) + (*z) * (*z));
  if (n > 1e-12) { *x /= n; *y /= n; *z /= n; }
}

#endif /* CMACS_GNUSEYE_GEOMATH_H */
