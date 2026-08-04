/* cmacs-brigade-chunk.c --- org-aware chunking for the memory index.
 *
 * Copyright (C) 2026 Zach Podbielniak
 * SPDX-License-Identifier: AGPL-3.0-or-later
 *
 * Splits a document into the units that get embedded.  Three passes:
 *
 *   1. cut at headline boundaries, so a chunk never spans two sections
 *      at the same or a shallower level;
 *   2. pack consecutive sibling sections up to a target size, so a note
 *      full of one-line headings does not become hundreds of useless
 *      one-line chunks;
 *   3. split anything still oversized on a blank line, then a sentence,
 *      then a hard cut, with a backward overlap so a fact spanning the
 *      seam survives in one of the halves.
 *
 * Every chunk carries a synthetic breadcrumb prefix --
 * "path > Heading > Subheading" -- which is embedded along with the
 * text.  Without it a chunk reading "yes, Tuesday works" is
 * unretrievable: it has no content words, and the thing that makes it
 * findable lives three headlines up.
 *
 * This is a line scanner, not an org parser.  Deliberately: it runs over
 * 24k files and org-element on that corpus blocks the main thread for
 * minutes, while a full org parser in C would be a second implementation
 * of a format Emacs already owns and would drift from it.  Everything
 * here is decided from the first characters of a line.
 *
 * Skipped: :LOGBOOK: drawers (clock noise, no prose), long src blocks
 * (code poisons a prose embedding space -- a query about "the parser"
 * should not return the parser's own source), and property drawers. */

#include <config.h>

#ifdef HAVE_CMACS_AI_BRIGADE

#include "lisp.h"
#include "cmacs-brigade.h"

#include <glib.h>
#include <string.h>

/* How much of the previous chunk to repeat at the head of a split one.
 * Enough to carry a sentence across the seam without meaningfully
 * inflating the index. */
#define CHUNK_OVERLAP_DEFAULT 200

/* A src block longer than this is dropped rather than embedded.  Short
 * ones are usually illustrative and belong with their prose. */
#define CHUNK_MAX_SRC_LINES 10

struct chunk_state
{
  GPtrArray   *out;          /* CmacsBrigadeChunk* */
  GString     *buf;          /* accumulating text */
  GPtrArray   *headings;     /* gchar*, current outline path */
  const gchar *path;
  gsize        target;
  gsize        overlap;
  gsize        buf_start;    /* byte offset of buf[0] in the document */
  gsize        cursor;       /* byte offset we have consumed to */
  /* Breadcrumb captured when the buffer started filling.  A chunk must
   * be labelled with where its content came from, not with wherever the
   * scanner happened to be when the buffer finally overflowed -- those
   * differ whenever sibling sections get packed together, which is the
   * common case for an outline of short entries. */
  gchar       *pending_heading;
};

static void
chunk_free (gpointer data)
{
  CmacsBrigadeChunk *c = data;

  if (c == NULL) return;
  g_free (c->text);
  g_free (c->heading);
  g_free (c);
}

void
cmacs_brigade_chunk_free (CmacsBrigadeChunk *chunk)
{
  chunk_free (chunk);
}

/* Render the current outline path as "file > A > B". */
static gchar *
breadcrumb (struct chunk_state *st)
{
  GString *s = g_string_new (st->path ? st->path : "");
  guint i;

  for (i = 0; i < st->headings->len; i++)
    {
      const gchar *h = g_ptr_array_index (st->headings, i);
      if (h == NULL || h[0] == '\0') continue;
      g_string_append (s, " > ");
      g_string_append (s, h);
    }
  return g_string_free (s, FALSE);
}

/* Emit whatever is in buf as a chunk, then reset it. */
/* Remember the outline position the next chunk will be labelled with,
 * unless one is already pending. */
static void
mark_start (struct chunk_state *st)
{
  if (st->pending_heading == NULL)
    st->pending_heading = breadcrumb (st);
}

static void
flush (struct chunk_state *st)
{
  CmacsBrigadeChunk *c;
  gchar *trimmed;

  if (st->buf->len == 0) return;

  trimmed = g_strdup (st->buf->str);
  g_strstrip (trimmed);
  if (trimmed[0] == '\0')
    {
      g_free (trimmed);
      g_string_truncate (st->buf, 0);
      g_clear_pointer (&st->pending_heading, g_free);
      st->buf_start = st->cursor;
      return;
    }

  c = g_new0 (CmacsBrigadeChunk, 1);
  c->text       = trimmed;
  c->heading    = st->pending_heading != NULL
    ? st->pending_heading : breadcrumb (st);
  c->byte_start = st->buf_start;
  c->byte_len   = st->buf->len;
  g_ptr_array_add (st->out, c);

  st->pending_heading = NULL;   /* ownership moved into the chunk */
  g_string_truncate (st->buf, 0);
  st->buf_start = st->cursor;
}

/* Split an oversized buffer, preferring a blank line, then a sentence
 * end, then a hard cut.  Leaves the tail in buf. */
static void
flush_oversized (struct chunk_state *st)
{
  while (st->buf->len > st->target * 2)
    {
      gsize cut = st->target;
      const gchar *s = st->buf->str;
      gsize i;

      /* Prefer a paragraph break in the back half of the window. */
      for (i = st->target; i > st->target / 2; i--)
        if (s[i] == '\n' && i > 0 && s[i - 1] == '\n') { cut = i; break; }

      if (cut == st->target)
        for (i = st->target; i > st->target / 2; i--)
          if ((s[i] == '.' || s[i] == '?' || s[i] == '!')
              && i + 1 < st->buf->len && s[i + 1] == ' ')
            { cut = i + 1; break; }

      /* Never cut mid-UTF-8: an invalid sequence would be embedded as
       * replacement characters and poison the vector. */
      while (cut < st->buf->len && (s[cut] & 0xC0) == 0x80) cut++;

      {
        g_autofree gchar *head = g_strndup (s, cut);
        g_autofree gchar *tail = g_strdup (s + cut);
        gsize back = MIN (st->overlap, cut);
        g_autofree gchar *carry = NULL;

        /* Carry the tail of the head forward so a sentence spanning the
         * seam is retrievable from the following chunk too. */
        {
          gsize off = cut - back;
          while (off < cut && (s[off] & 0xC0) == 0x80) off++;
          carry = g_strndup (s + off, cut - off);
        }

        g_string_assign (st->buf, head);
        flush (st);
        g_string_assign (st->buf, carry);
        g_string_append (st->buf, tail);
      }
    }
}

/* Headline level, or 0 if LINE is not one. */
static gint
headline_level (const gchar *line)
{
  gint n = 0;

  while (line[n] == '*') n++;
  return (n > 0 && line[n] == ' ') ? n : 0;
}

/* Chunk TEXT (a whole document) into an array of CmacsBrigadeChunk*.
 * PATH is used for the breadcrumb prefix.  TARGET is the soft size in
 * bytes; 0 selects the default. */
GPtrArray *
cmacs_brigade_chunk_text (const gchar *text, const gchar *path,
                          gsize target, gsize overlap)
{
  struct chunk_state st;
  g_auto (GStrv) lines = NULL;
  gsize i;
  gboolean in_drawer = FALSE, in_src = FALSE;
  gint src_lines = 0;
  GString *src_buf = NULL;

  st.out      = g_ptr_array_new_with_free_func (chunk_free);
  st.buf      = g_string_new (NULL);
  st.headings = g_ptr_array_new_with_free_func (g_free);
  st.path     = path;
  st.target   = target > 0 ? target : 1400;
  st.overlap  = overlap > 0 ? overlap : CHUNK_OVERLAP_DEFAULT;
  st.buf_start = 0;
  st.cursor    = 0;
  st.pending_heading = NULL;

  if (text == NULL) goto done;

  lines = g_strsplit (text, "\n", -1);
  src_buf = g_string_new (NULL);

  for (i = 0; lines[i] != NULL; i++)
    {
      const gchar *line = lines[i];
      gsize linelen = strlen (line) + 1;   /* + the newline we split on */
      gint level;

      st.cursor += linelen;

      /* Drawers: skipped wholesale.  :LOGBOOK: is clock noise and
       * :PROPERTIES: is metadata; neither is prose anyone searches for
       * in words, and both would dilute the surrounding section. */
      if (in_drawer)
        {
          if (g_ascii_strncasecmp (g_strchug ((gchar *) line), ":END:", 5) == 0)
            in_drawer = FALSE;
          continue;
        }
      if (g_str_has_prefix (g_strchug ((gchar *) line), ":LOGBOOK:")
          || g_str_has_prefix (g_strchug ((gchar *) line), ":PROPERTIES:"))
        {
          in_drawer = TRUE;
          continue;
        }

      /* Source and example blocks: kept if short (they are usually
       * illustrative and belong with their prose), dropped if long. */
      if (in_src)
        {
          if (g_ascii_strncasecmp (line, "#+end_", 6) == 0)
            {
              in_src = FALSE;
              if (src_lines <= CHUNK_MAX_SRC_LINES)
                {
                  mark_start (&st);
                  g_string_append (st.buf, src_buf->str);
                }
              g_string_truncate (src_buf, 0);
              src_lines = 0;
            }
          else
            {
              g_string_append (src_buf, line);
              g_string_append_c (src_buf, '\n');
              src_lines++;
            }
          continue;
        }
      if (g_ascii_strncasecmp (line, "#+begin_src", 11) == 0
          || g_ascii_strncasecmp (line, "#+begin_example", 15) == 0)
        {
          in_src = TRUE;
          src_lines = 0;
          continue;
        }

      level = headline_level (line);
      if (level > 0)
        {
          /* A headline ends the previous chunk unless what we have so
           * far is too small to stand alone -- packing siblings is what
           * keeps an outline of one-liners from becoming noise. */
          if (st.buf->len >= st.target) flush (&st);

          /* Pop to the parent level, then push this heading. */
          while ((gint) st.headings->len >= level)
            g_ptr_array_remove_index (st.headings,
                                      st.headings->len - 1);
          {
            const gchar *title = line + level;
            while (*title == ' ') title++;
            g_ptr_array_add (st.headings, g_strdup (title));
          }
          mark_start (&st);
          g_string_append (st.buf, line);
          g_string_append_c (st.buf, '\n');
          continue;
        }

      mark_start (&st);
      g_string_append (st.buf, line);
      g_string_append_c (st.buf, '\n');

      if (st.buf->len > st.target * 2) flush_oversized (&st);
    }

  flush (&st);

done:
  g_clear_pointer (&st.pending_heading, g_free);
  if (src_buf != NULL) g_string_free (src_buf, TRUE);
  g_string_free (st.buf, TRUE);
  g_ptr_array_free (st.headings, TRUE);
  return st.out;
}

#endif /* HAVE_CMACS_AI_BRIGADE */
