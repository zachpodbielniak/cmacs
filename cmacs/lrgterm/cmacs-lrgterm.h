/* cmacs-lrgterm.h --- output_lrg: independent libregnum/raylib display backend.

Copyright (C) 2026 Zach Podbielniak

This file is part of cmacs, a fork of GNU Emacs.

SPDX-License-Identifier: AGPL-3.0-or-later

Shared header for the output_lrg backend.  Defines the per-display and
per-frame state structs and the FRAME_LRG_* accessors used by the lrgterm
backend sources.

This header is ALSO pulled into every Emacs core translation unit via the
TERM_HEADER (gtkutil.h includes it after pgtkterm.h when
HAVE_CMACS_LRGTERM), so that the shared redisplay macros FRAME_FONT,
FRAME_FONTSET, FRAME_BASELINE_OFFSET and MOUSE_HL_INFO -- which upstream
hardwires to a single window-system backend -- can be redefined to DISPATCH
between pgtk and lrg on FRAME_LRG_P.  Those four macros all yield
backend-agnostic types (struct font *, int, Mouse_HLInfo *), so a ternary
dispatch type-checks.

To stay light enough for that wide inclusion, this header does NOT include
the libregnum or graylib umbrella headers; it forward-declares the few Lrg
and Grl types it references as opaque pointers.  The .c sources include
libregnum.h for the real definitions (duplicate identical typedefs are
permitted by GNU C).  */

#ifndef CMACS_LRGTERM_H
#define CMACS_LRGTERM_H

#include "dispextern.h"
#include "frame.h"
#include "character.h"
#include "font.h"
#include "termhooks.h"

#ifdef HAVE_CMACS_LRGTERM

/* lrg coexists with pgtk in a single build.  Emacs's shared redisplay code is
   compiled with FRAME_DISPLAY_INFO typed for the one window-system backend
   (pgtk here), and reads many fields through it (resx/resy via FRAME_RES_X/Y,
   n_planes, n_fonts, bitmaps, name_list_element, rdb, mouse_highlight, ...).
   To make those reads correct for lrg frames WITHOUT a fragile hand-mirrored
   shadow struct, we embed a real `struct pgtk_display_info' as the first
   member of lrg_display_info and point FRAME_DISPLAY_INFO at it (below).  */
#ifdef HAVE_PGTK
#include "pgtkterm.h"
#endif

/* Opaque forward declarations -- real definitions come from <libregnum.h>
   / <graylib.h> in the .c sources.  */
typedef struct _LrgFrameSurface LrgFrameSurface;
typedef struct _Lrg2DSurface    Lrg2DSurface;
typedef struct _LrgGlyphAtlas   LrgGlyphAtlas;
typedef struct _GrlWindow       GrlWindow;

/* Per-display state (one per opened display connection / OS window set).  */
struct lrg_display_info
{
  /* MUST be first: a layout-correct pgtk_display_info for the generic
     FRAME_DISPLAY_INFO path.  lrg uses pgtk.{terminal,name_list_element,resx,
     resy,reference_count,smallest_*,mouse_highlight,x_focus_frame,...}; the
     GTK-specific members stay NULL (only pgtk*.c touches those, and it never
     runs for output_lrg frames).  Its name_list_element is GC-marked by
     mark_lrgterm.  */
  struct pgtk_display_info pgtk;

  /* GPU glyph cache shared by all frames on this display.  */
  LrgGlyphAtlas *glyph_atlas;

  /* Self-pipe read fd registered with add_keyboard_wait_descriptor so pselect
     wakes when the input thread has events (Phase 4).  */
  int connection;

  /* Chain of all lrg_display_info structures.  */
  struct lrg_display_info *next;
};

extern struct lrg_display_info *lrg_display_list;
extern void mark_lrgterm (void);

/* Per-frame state.  */
struct lrg_output
{
  /* Colors (24-bit packed 0xRRGGBB).  */
  unsigned long foreground_color;
  unsigned long background_color;
  unsigned long cursor_color;
  unsigned long cursor_foreground_color;
  unsigned long mouse_color;
  unsigned long border_pixel;

  /* Font / fontset (read by the dispatched FRAME_FONT/FONTSET macros).  */
  struct font *font;
  int baseline_offset;
  int fontset;

  /* Backlink to the display.  */
  struct lrg_display_info *display_info;

  /* The libregnum surface that owns this frame's OS window + GL context.
     Concrete type is Lrg2DSurface (LRG_RENDER_MODE_2D) today; held as the
     abstract base so 3D/VR subclasses drop in unchanged.  */
  LrgFrameSurface *surface;

  /* Render mode selected for this frame (0 = 2d).  */
  int render_mode;

  int has_been_visible;
  int focus_state;

  /* Cursor shapes (placeholders; see note above).  */
  Emacs_Cursor current_cursor;
  Emacs_Cursor text_cursor;
  Emacs_Cursor nontext_cursor;
  Emacs_Cursor modeline_cursor;
  Emacs_Cursor hand_cursor;
  Emacs_Cursor hourglass_cursor;

  /* Relief GCs/colors for 3D box faces.  */
  struct
  {
    Emacs_GC xgcv;
    unsigned long pixel;
  } black_relief, white_relief;
  unsigned long relief_background;
  bool_bf relief_background_valid_p : 1;

  int internal_border_width;
};

/* lrg-specific frame accessors (distinct names so they never collide with
   pgtk's FRAME_X_OUTPUT / FRAME_DISPLAY_INFO from pgtkterm.h).  */
#define FRAME_LRG_OUTPUT(f)        ((f)->output_data.lrg)
#define FRAME_LRG_DISPLAY_INFO(f)  (FRAME_LRG_OUTPUT (f)->display_info)
#define FRAME_LRG_SURFACE(f)       (FRAME_LRG_OUTPUT (f)->surface)
#define FRAME_LRG_FOREGROUND_COLOR(f) (FRAME_LRG_OUTPUT (f)->foreground_color)
#define FRAME_LRG_BACKGROUND_COLOR(f) (FRAME_LRG_OUTPUT (f)->background_color)
#define FRAME_LRG_CURSOR_COLOR(f)  (FRAME_LRG_OUTPUT (f)->cursor_color)

/* --- Shared-macro dispatch (pgtk vs lrg) ---------------------------------
   These four are defined by pgtkterm.h / frame.h for the single upstream
   backend.  Redefine them to pick the right union member at runtime.  Every
   branch yields the same type, so the ternary type-checks.  Valid because
   struct lrg_output / lrg_display_info are fully defined above and this
   header is included (via gtkutil.h) wherever the macros are evaluated.  */

/* The `*(cond ? &a : &b)' form keeps these usable as lvalues (pgtk code
   assigns to FRAME_FONT/FONTSET/BASELINE_OFFSET); a bare ?: is not an
   lvalue in C.  */
#undef FRAME_FONT
#define FRAME_FONT(f) \
  (*(FRAME_LRG_P (f) ? &(f)->output_data.lrg->font \
                     : &(f)->output_data.pgtk->font))

#undef FRAME_FONTSET
#define FRAME_FONTSET(f) \
  (*(FRAME_LRG_P (f) ? &(f)->output_data.lrg->fontset \
                     : &(f)->output_data.pgtk->fontset))

#undef FRAME_BASELINE_OFFSET
#define FRAME_BASELINE_OFFSET(f) \
  (*(FRAME_LRG_P (f) ? &(f)->output_data.lrg->baseline_offset \
                     : &(f)->output_data.pgtk->baseline_offset))

/* FRAME_DISPLAY_INFO: for an lrg frame yield the embedded pgtk_display_info
   (layout-correct); otherwise the pgtk display_info.  Both branches are
   struct pgtk_display_info *, so it type-checks, and all generic
   FRAME_DISPLAY_INFO->field reads (incl. FRAME_RES_X/Y and MOUSE_HL_INFO,
   which build on it) work for lrg frames too.  Kept an lvalue because pgtk
   code assigns FRAME_DISPLAY_INFO(f) = dpyinfo; the lrg branch reinterprets
   the lrg_display_info* as pgtk_display_info* -- valid because pgtk is its
   first member, so the addresses coincide.  */
#undef FRAME_DISPLAY_INFO
#define FRAME_DISPLAY_INFO(f) \
  (*(FRAME_LRG_P (f) \
     ? (struct pgtk_display_info **) &(f)->output_data.lrg->display_info \
     : &(f)->output_data.pgtk->display_info))

/* --- entry points (cmacs-lrgterm.c / lrgfns.c / lrgfont.c) -------------- */
extern struct terminal *lrg_create_terminal (struct lrg_display_info *);
extern struct lrg_display_info *lrg_term_init (Lisp_Object display_name,
                                               char *resource_name);
extern void lrg_delete_terminal (struct terminal *);
extern void lrg_default_font_parameter (struct frame *, Lisp_Object);
extern void lrg_free_frame_resources (struct frame *);
extern struct lrg_display_info *check_lrg_display_info (Lisp_Object);
extern double lrg_frame_scale_factor (struct frame *);

/* Surface/window lifecycle (cmacs-lrgwindow.c).  */
extern GrlWindow *lrg_window_create (struct frame *, int, int, const char *);
extern GrlWindow *lrg_window_of_frame (struct frame *);
extern void lrg_window_begin (struct frame *);
extern void lrg_window_end (struct frame *);
extern void lrg_window_destroy (struct frame *);

/* Font driver registration + glyph blit (lrgfont.c).  */
extern void lrg_register_font_drivers (struct frame *);
extern LrgGlyphAtlas *lrg_frame_glyph_atlas (struct frame *);
extern int lrg_font_draw_glyph_string (struct glyph_string *s, int from,
                                       int to, int x, int y,
                                       bool with_background);

/* lrg_requested_render_mode is declared in lisp.h (reachable from core).  */

#endif /* HAVE_CMACS_LRGTERM */
#endif /* CMACS_LRGTERM_H */
