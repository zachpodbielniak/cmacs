/* cmacs-secondbrain-model.h --- the ARMS ring vocabulary.
 *
 * Copyright (C) 2026 Zach Podbielniak
 * SPDX-License-Identifier: AGPL-3.0-or-later
 *
 * Pure C: no "lisp.h", no <libregnum.h>, only glib.  Both halves of the
 * subsystem need to agree about what the rings are and what order they
 * sit in, and putting that agreement in the third translation-unit
 * class means it can be tested with no Lisp VM and no GL context --
 * the same reasoning as cmacs/graphcore.
 *
 * The ring order is the whole point of the layout, so it is defined
 * once, here, rather than being re-derived from a string comparison at
 * each use. */

#ifndef CMACS_SECONDBRAIN_MODEL_H
#define CMACS_SECONDBRAIN_MODEL_H

#include <config.h>

#ifdef HAVE_CMACS_SECONDBRAIN

#include <glib.h>

G_BEGIN_DECLS

/* The ARMS layers, innermost first.
 *
 * Skills sit at the centre because they are what the agent actually
 * does; applications sit outside because they are the boundary with
 * everything else.  Memory is between them and is normally the
 * largest, which is why it gets the widest band. */
typedef enum
{
  CMACS_SB_RING_SKILLS       = 0,
  CMACS_SB_RING_MEMORY       = 1,
  CMACS_SB_RING_ROUTINES     = 2,
  CMACS_SB_RING_APPLICATIONS = 3,
  CMACS_SB_RING_COUNT        = 4
} CmacsSbRing;

/* Node roles.  The scene draws a different glyph per role, which is
 * what lets you read the map without the labels: a hex is something
 * external, a ring is something on a clock, a star is a capability. */
typedef enum
{
  CMACS_SB_KIND_HUB     = 0,   /* a collapsed department */
  CMACS_SB_KIND_FILE    = 1,
  CMACS_SB_KIND_FOLDER  = 2,
  CMACS_SB_KIND_APP     = 3,
  CMACS_SB_KIND_ROUTINE = 4,
  CMACS_SB_KIND_SKILL   = 5,
  CMACS_SB_KIND_CENTRE  = 6,   /* the workspace root, e.g. CLAUDE.md */
  CMACS_SB_KIND_COUNT   = 7
} CmacsSbKind;

/* Lower-case stable names, used on the Lisp boundary and in the ring
 * band labels.  NULL for an out-of-range value rather than a crash:
 * these cross the Elisp boundary, where anything can arrive. */
extern const char *cmacs_sb_ring_name (CmacsSbRing ring);
extern const char *cmacs_sb_kind_name (CmacsSbKind kind);

/* Parse back.  Returns FALSE and leaves *OUT untouched when NAME is not
 * a known ring/kind, so a caller can distinguish "absent" from "ring
 * zero" -- which matters, because ring zero is Skills. */
extern gboolean cmacs_sb_ring_from_name (const char *name, CmacsSbRing *out);
extern gboolean cmacs_sb_kind_from_name (const char *name, CmacsSbKind *out);

/* Display label for a ring band ("APPLICATIONS", ...). */
extern const char *cmacs_sb_ring_label (CmacsSbRing ring);

/* Default 0xRRGGBBAA for a ring, used when a node carries no colour of
 * its own.  Fixed, not hashed, so a ring means the same thing in every
 * session. */
extern guint32 cmacs_sb_ring_color (CmacsSbRing ring);

/* Radius of RING's band, in graphcore world units, given the gap
 * between adjacent bands.  Memory is given a wider gap than the others
 * because it normally holds an order of magnitude more nodes and would
 * otherwise read as a solid line. */
extern double cmacs_sb_ring_radius (CmacsSbRing ring, double gap);

/* Render radius for a node of KIND holding DESCENDANTS children.
 *
 * A collapsed hub is sized by how much it is hiding -- that is the
 * whole signal it carries when its contents are not drawn -- but by the
 * CUBE ROOT of it, so a department with 12000 files is legible next to
 * one with 300 rather than swallowing the frame. */
extern double cmacs_sb_node_radius (CmacsSbKind kind, guint32 descendants);

G_END_DECLS

#endif /* HAVE_CMACS_SECONDBRAIN */
#endif /* CMACS_SECONDBRAIN_MODEL_H */
