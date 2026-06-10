/* cmacs-gnuseye-sgp4.c --- TLE parsing + satellite orbit propagation.
 *
 * Copyright (C) 2026 Zach Podbielniak
 * SPDX-License-Identifier: AGPL-3.0-or-later
 *
 * Parses NORAD two-line element sets and propagates satellite positions
 * for the astronomical layer.
 *
 * v1 uses a two-body (Keplerian) propagator: it derives the orbit from
 * the TLE mean elements (inclination, RAAN, eccentricity, argument of
 * perigee, mean anomaly, mean motion), advances the mean anomaly by the
 * mean motion, solves Kepler's equation, builds the ECI position, and
 * rotates to ECEF via GMST to get geodetic lat/lon/alt.  This is exact
 * two-body motion; it omits the SGP4 secular/periodic perturbations
 * (J2 nodal regression, atmospheric drag).  Over the short windows the
 * globe propagates (minutes ahead, with TLEs refreshed every few hours)
 * the visual error is small.  Full SGP4/SDP4 is a future upgrade -- when
 * added, vendor a public-domain reference (Vallado/CelesTrak) and
 * validate against its test vectors before trusting the positions.
 *
 * No raylib/libregnum here -- pure lisp.h + libm. */

#include <config.h>

#ifdef HAVE_CMACS_GNUSEYE

#include "lisp.h"
#include "cmacs-gnuseye.h"
#include <glib.h>
#include <math.h>

#ifndef M_PI
#define M_PI 3.14159265358979323846
#endif

#define MU_EARTH      398600.4418     /* km^3 / s^2 */
#define EARTH_RADIUS  6378.137        /* km (equatorial) */
#define DEG2RAD       (M_PI / 180.0)
#define TWO_PI        (2.0 * M_PI)

/* Orbital element set, as returned to Elisp (a vector of 9 floats):
 *   [0] satnum            [1] epoch_unix (s)
 *   [2] inclination (rad) [3] RAAN (rad)
 *   [4] eccentricity      [5] arg perigee (rad)
 *   [6] mean anomaly0(rad)[7] mean motion (rad/s)
 *   [8] semi-major axis (km) */
enum { ELSET_LEN = 9 };

/* ── TLE column helpers ─────────────────────────────────────────────── */

/* Copy 1-based columns [c0,c1] of LINE into BUF (NUL-terminated). */
static void
tle_field (const char *line, int len, int c0, int c1, char *buf, int bufsz)
{
  int i = 0;
  for (int c = c0; c <= c1 && c <= len && i < bufsz - 1; c++)
    buf[i++] = line[c - 1];
  buf[i] = '\0';
}

static double
tle_double (const char *line, int len, int c0, int c1)
{
  char buf[32];
  tle_field (line, len, c0, c1, buf, sizeof buf);
  return g_ascii_strtod (g_strstrip (buf), NULL);
}

/* TLE epoch (YYDDD.DDDDDDDD at cols 19-32 of line 1) -> Unix seconds. */
static double
tle_epoch_unix (const char *l1, int len)
{
  char buf[16];
  tle_field (l1, len, 19, 20, buf, sizeof buf);
  int yy = (int) g_ascii_strtoll (buf, NULL, 10);
  int year = (yy < 57) ? 2000 + yy : 1900 + yy;
  double doy = tle_double (l1, len, 21, 32);   /* day-of-year + fraction */

  /* Days from 1970-01-01 to YEAR-01-01. */
  long days = 0;
  for (int y = 1970; y < year; y++)
    days += ((y % 4 == 0 && y % 100 != 0) || y % 400 == 0) ? 366 : 365;
  return (double) days * 86400.0 + (doy - 1.0) * 86400.0;
}

/* Greenwich Mean Sidereal Time (radians) at Unix time T. */
static double
gmst_rad (double unix_s)
{
  double jd = unix_s / 86400.0 + 2440587.5;
  double d = jd - 2451545.0;
  double tc = d / 36525.0;
  double gmst = 280.46061837 + 360.98564736629 * d
              + 0.000387933 * tc * tc - tc * tc * tc / 38710000.0;
  gmst = fmod (gmst, 360.0);
  if (gmst < 0) gmst += 360.0;
  return gmst * DEG2RAD;
}

/* Solve Kepler's equation E - e sinE = M (radians) by Newton iteration. */
static double
kepler_E (double M, double e)
{
  M = fmod (M, TWO_PI);
  double E = e < 0.8 ? M : M_PI;
  for (int i = 0; i < 30; i++)
    {
      double f = E - e * sin (E) - M;
      double fp = 1.0 - e * cos (E);
      double dE = f / fp;
      E -= dE;
      if (fabs (dE) < 1e-12) break;
    }
  return E;
}

/* Propagate ELSET (9-float array) to UNIX_S, writing geodetic lat/lon
 * (degrees) and altitude (metres). */
static void
propagate (const double *el, double unix_s,
           double *lat_deg, double *lon_deg, double *alt_m)
{
  double epoch = el[1], incl = el[2], raan = el[3], ecc = el[4];
  double argp = el[5], M0 = el[6], n = el[7], a = el[8];

  double M = M0 + n * (unix_s - epoch);
  double E = kepler_E (M, ecc);
  double cosE = cos (E), sinE = sin (E);

  /* Position in the orbital plane (perifocal frame), km. */
  double r = a * (1.0 - ecc * cosE);
  double xp = a * (cosE - ecc);
  double yp = a * sqrt (1.0 - ecc * ecc) * sinE;

  /* Rotate perifocal -> ECI by argp (Rz), incl (Rx), raan (Rz). */
  double cw = cos (argp), sw = sin (argp);
  double co = cos (raan), so = sin (raan);
  double ci = cos (incl), si = sin (incl);

  /* Combined rotation applied to (xp, yp, 0). */
  double x1 = xp * cw - yp * sw;
  double y1 = xp * sw + yp * cw;
  /* incl about X then raan about Z. */
  double x2 = x1;
  double y2 = y1 * ci;
  double z2 = y1 * si;
  double xeci = x2 * co - y2 * so;
  double yeci = x2 * so + y2 * co;
  double zeci = z2;

  /* ECI -> ECEF by GMST rotation about Z. */
  double g = gmst_rad (unix_s);
  double cg = cos (g), sg = sin (g);
  double xe =  xeci * cg + yeci * sg;
  double ye = -xeci * sg + yeci * cg;
  double ze =  zeci;

  double rm = sqrt (xe * xe + ye * ye + ze * ze);
  *lat_deg = asin (ze / rm) * (180.0 / M_PI);
  *lon_deg = atan2 (ye, xe) * (180.0 / M_PI);
  *alt_m = (rm - EARTH_RADIUS) * 1000.0;
  (void) r;
}

/* ── DEFUNs ─────────────────────────────────────────────────────────── */

DEFUN ("cmacs-gnuseye-tle-parse", Fcmacs_gnuseye_tle_parse,
       Scmacs_gnuseye_tle_parse, 2, 2, 0,
       doc: /* Parse a TLE (LINE1, LINE2) into an orbital element vector.
Returns a 9-element float vector
[SATNUM EPOCH-UNIX INCL RAAN ECC ARGP MEAN-ANOMALY MEAN-MOTION SEMI-MAJOR]
(angles in radians, mean-motion in rad/s, semi-major axis in km), or nil
if the lines are malformed.  Pass the vector to
`cmacs-gnuseye-sat-propagate' / `cmacs-gnuseye-sat-track'.  */)
  (Lisp_Object line1, Lisp_Object line2)
{
  CHECK_STRING (line1);
  CHECK_STRING (line2);
  const char *l1 = SSDATA (line1);
  const char *l2 = SSDATA (line2);
  int len1 = (int) SBYTES (line1), len2 = (int) SBYTES (line2);
  if (len1 < 64 || len2 < 64) return Qnil;

  double satnum = tle_double (l2, len2, 3, 7);
  double epoch  = tle_epoch_unix (l1, len1);
  double incl   = tle_double (l2, len2, 9, 16) * DEG2RAD;
  double raan   = tle_double (l2, len2, 18, 25) * DEG2RAD;

  char ebuf[16];
  tle_field (l2, len2, 27, 33, ebuf, sizeof ebuf);
  char edec[24];
  snprintf (edec, sizeof edec, "0.%s", g_strstrip (ebuf));
  double ecc = g_ascii_strtod (edec, NULL);

  double argp = tle_double (l2, len2, 35, 42) * DEG2RAD;
  double ma   = tle_double (l2, len2, 44, 51) * DEG2RAD;
  double mm_rev_day = tle_double (l2, len2, 53, 63);   /* rev/day */
  if (mm_rev_day <= 0.0) return Qnil;
  double n = mm_rev_day * TWO_PI / 86400.0;            /* rad/s */
  double a = cbrt (MU_EARTH / (n * n));                 /* km */

  Lisp_Object v = make_vector (ELSET_LEN, Qnil);
  ASET (v, 0, make_float (satnum));
  ASET (v, 1, make_float (epoch));
  ASET (v, 2, make_float (incl));
  ASET (v, 3, make_float (raan));
  ASET (v, 4, make_float (ecc));
  ASET (v, 5, make_float (argp));
  ASET (v, 6, make_float (ma));
  ASET (v, 7, make_float (n));
  ASET (v, 8, make_float (a));
  return v;
}

static bool
read_elset (Lisp_Object elset, double *out)
{
  if (!VECTORP (elset) || ASIZE (elset) < ELSET_LEN) return false;
  for (int i = 0; i < ELSET_LEN; i++)
    out[i] = XFLOATINT (AREF (elset, i));
  return true;
}

DEFUN ("cmacs-gnuseye-sat-propagate", Fcmacs_gnuseye_sat_propagate,
       Scmacs_gnuseye_sat_propagate, 2, 2, 0,
       doc: /* Propagate ELSET to EPOCH (Unix seconds, float).
ELSET is from `cmacs-gnuseye-tle-parse'.  Returns (LAT LON ALT-M).  */)
  (Lisp_Object elset, Lisp_Object epoch)
{
  double el[ELSET_LEN];
  if (!read_elset (elset, el)) return Qnil;
  double lat, lon, alt;
  propagate (el, XFLOATINT (epoch), &lat, &lon, &alt);
  return list3 (make_float (lat), make_float (lon), make_float (alt));
}

DEFUN ("cmacs-gnuseye-sat-track", Fcmacs_gnuseye_sat_track,
       Scmacs_gnuseye_sat_track, 4, 4, 0,
       doc: /* Sample ELSET's ground track for an orbit trail.
Starting at START (Unix seconds), take N samples STEP seconds apart.
Returns a vector of N [LAT LON ALT-M] vectors.  */)
  (Lisp_Object elset, Lisp_Object start, Lisp_Object step, Lisp_Object n)
{
  double el[ELSET_LEN];
  if (!read_elset (elset, el)) return Qnil;
  CHECK_FIXNAT (n);
  EMACS_INT count = XFIXNUM (n);
  if (count < 1) count = 1;
  double t0 = XFLOATINT (start), dt = XFLOATINT (step);
  Lisp_Object out = make_vector (count, Qnil);
  for (EMACS_INT i = 0; i < count; i++)
    {
      double lat, lon, alt;
      propagate (el, t0 + (double) i * dt, &lat, &lon, &alt);
      Lisp_Object p = make_vector (3, Qnil);
      ASET (p, 0, make_float (lat));
      ASET (p, 1, make_float (lon));
      ASET (p, 2, make_float (alt));
      ASET (out, i, p);
    }
  return out;
}

DEFUN ("cmacs-gnuseye-sat-available-p", Fcmacs_gnuseye_sat_available_p,
       Scmacs_gnuseye_sat_available_p, 0, 0, 0,
       doc: /* Return t: satellite TLE propagation is available.  */)
  (void)
{
  return Qt;
}

void
syms_of_cmacs_gnuseye_sgp4 (void)
{
  defsubr (&Scmacs_gnuseye_tle_parse);
  defsubr (&Scmacs_gnuseye_sat_propagate);
  defsubr (&Scmacs_gnuseye_sat_track);
  defsubr (&Scmacs_gnuseye_sat_available_p);
}

#endif /* HAVE_CMACS_GNUSEYE */
