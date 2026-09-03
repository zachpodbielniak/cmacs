/* cmacs-secondbrain-model.c --- the ARMS ring vocabulary.
 *
 * Copyright (C) 2026 Zach Podbielniak
 * SPDX-License-Identifier: AGPL-3.0-or-later
 *
 * See cmacs-secondbrain-model.h for the contract.  This translation
 * unit includes neither "lisp.h" nor <libregnum.h>, on purpose: it is
 * the part of the subsystem that can be exercised with no Lisp VM and
 * no GL context. */

#include <config.h>

#ifdef HAVE_CMACS_SECONDBRAIN

#include "cmacs-secondbrain-model.h"

#include <math.h>
#include <string.h>

/* One table, indexed by the enum, rather than a switch per accessor:
   adding a ring should not mean finding five places to edit. */
static const struct
{
  const char *name;
  const char *label;
  guint32     rgba;
  double      gap_scale;
} sb_rings[CMACS_SB_RING_COUNT] = {
  /* name           label            colour        gap scale */
  { "skills",       "SKILLS",        0xE8873DFFu,  1.00 },
  { "memory",       "MEMORY",        0xA98FE0FFu,  1.00 },
  { "routines",     "ROUTINES",      0xE0C24BFFu,  1.00 },
  { "applications", "APPLICATIONS",  0x6FA8DCFFu,  1.00 }
};

static const char *sb_kinds[CMACS_SB_KIND_COUNT] = {
  "hub", "file", "folder", "app", "routine", "skill", "centre"
};

const char *
cmacs_sb_ring_name (CmacsSbRing ring)
{
  if ((int) ring < 0 || ring >= CMACS_SB_RING_COUNT) return NULL;
  return sb_rings[ring].name;
}

const char *
cmacs_sb_ring_label (CmacsSbRing ring)
{
  if ((int) ring < 0 || ring >= CMACS_SB_RING_COUNT) return NULL;
  return sb_rings[ring].label;
}

guint32
cmacs_sb_ring_color (CmacsSbRing ring)
{
  if ((int) ring < 0 || ring >= CMACS_SB_RING_COUNT) return 0xB0B8C8FFu;
  return sb_rings[ring].rgba;
}

const char *
cmacs_sb_kind_name (CmacsSbKind kind)
{
  if ((int) kind < 0 || kind >= CMACS_SB_KIND_COUNT) return NULL;
  return sb_kinds[kind];
}

gboolean
cmacs_sb_ring_from_name (const char *name, CmacsSbRing *out)
{
  int i;

  if (!name) return FALSE;
  for (i = 0; i < CMACS_SB_RING_COUNT; i++)
    if (strcmp (name, sb_rings[i].name) == 0)
      {
        if (out) *out = (CmacsSbRing) i;
        return TRUE;
      }
  return FALSE;
}

gboolean
cmacs_sb_kind_from_name (const char *name, CmacsSbKind *out)
{
  int i;

  if (!name) return FALSE;
  for (i = 0; i < CMACS_SB_KIND_COUNT; i++)
    if (strcmp (name, sb_kinds[i]) == 0)
      {
        if (out) *out = (CmacsSbKind) i;
        return TRUE;
      }
  return FALSE;
}

double
cmacs_sb_ring_radius (CmacsSbRing ring, double gap)
{
  int i;
  double r = 0.0;

  if ((int) ring < 0 || ring >= CMACS_SB_RING_COUNT) return gap;
  if (gap <= 0.0) gap = 6.0;

  /* Accumulate the scaled gaps rather than multiplying by the index, so
     a ring that needs more room pushes everything outside it out too
     instead of overlapping its neighbour. */
  for (i = 0; i <= (int) ring; i++)
    r += gap * sb_rings[i].gap_scale;
  return r;
}

double
cmacs_sb_node_radius (CmacsSbKind kind, guint32 descendants)
{
  double base;

  switch (kind)
    {
    case CMACS_SB_KIND_CENTRE:  base = 0.90; break;
    case CMACS_SB_KIND_HUB:     base = 0.55; break;
    case CMACS_SB_KIND_APP:     base = 0.42; break;
    case CMACS_SB_KIND_ROUTINE: base = 0.38; break;
    case CMACS_SB_KIND_SKILL:   base = 0.34; break;
    case CMACS_SB_KIND_FOLDER:  base = 0.32; break;
    default:                    base = 0.26; break;
    }

  /* Cube root, not linear and not log: a department hiding 12000 files
     must read as bigger than one hiding 300 without swallowing the
     frame.  Linear makes the large one absurd; log flattens the two
     into the same dot. */
  if (descendants > 0)
    base *= 1.0 + 0.55 * cbrt ((double) descendants) / 4.0;

  return base;
}

#endif /* HAVE_CMACS_SECONDBRAIN */
