/* cmacs-lrgfns.c --- output_lrg frame creation + Lisp entry points.

Copyright (C) 2026 Zach Podbielniak

This file is part of cmacs, a fork of GNU Emacs.

SPDX-License-Identifier: AGPL-3.0-or-later

The x-create-frame / x-open-connection analogues for the lrg backend, plus
the frame-parameter handler table and the default-font chooser.  Ported,
trimmed, from src/pgtkfns.c.  */

#include <config.h>

#ifdef HAVE_CMACS_LRGTERM

#include <libregnum.h>

#include "lisp.h"
#include "blockinput.h"
#include "frame.h"
#include "window.h"
#include "buffer.h"
#include "dispextern.h"
#include "font.h"
#include "fontset.h"
#include "termhooks.h"
#include "termchar.h"
#include "cmacs-lrgterm.h"

/* ------------------------------------------------- colour parameters ---- */

static unsigned long
lrg_parse_pixel (struct frame *f, Lisp_Object color, unsigned long dflt)
{
  Emacs_Color col;

  if (STRINGP (color)
      && FRAME_TERMINAL (f)->defined_color_hook (f, SSDATA (color), &col,
                                                 true, false))
    return col.pixel;
  return dflt;
}

static void
lrg_set_foreground_color (struct frame *f, Lisp_Object arg, Lisp_Object oldval)
{
  unsigned long fg = lrg_parse_pixel (f, arg, FRAME_FOREGROUND_PIXEL (f));
  (void) oldval;
  FRAME_FOREGROUND_PIXEL (f) = fg;
  FRAME_LRG_OUTPUT (f)->foreground_color = fg;
  if (FRAME_LRG_SURFACE (f) != NULL)
    {
      update_face_from_frame_parameter (f, Qforeground_color, arg);
      if (FRAME_VISIBLE_P (f))
        SET_FRAME_GARBAGED (f);
    }
}

static void
lrg_set_background_color (struct frame *f, Lisp_Object arg, Lisp_Object oldval)
{
  unsigned long bg = lrg_parse_pixel (f, arg, FRAME_BACKGROUND_PIXEL (f));
  (void) oldval;
  FRAME_BACKGROUND_PIXEL (f) = bg;
  FRAME_LRG_OUTPUT (f)->background_color = bg;
  if (FRAME_LRG_SURFACE (f) != NULL)
    {
      update_face_from_frame_parameter (f, Qbackground_color, arg);
      if (FRAME_VISIBLE_P (f))
        SET_FRAME_GARBAGED (f);
    }
}

static void
lrg_set_cursor_color (struct frame *f, Lisp_Object arg, Lisp_Object oldval)
{
  unsigned long fg = lrg_parse_pixel (f, arg, FRAME_FOREGROUND_PIXEL (f));
  (void) oldval;
  FRAME_LRG_OUTPUT (f)->cursor_color = fg;
  if (FRAME_VISIBLE_P (f))
    {
      gui_update_cursor (f, false);
      gui_update_cursor (f, true);
    }
}

/* Handler table -- order matches the frame-parameter table (see frame.c).
   Generic gui_* handlers are used where they suffice; lrg-specific colour
   setters are wired; the rest are NULL (skipped) for the v1 boot.  */
frame_parm_handler lrg_frame_parm_handlers[] =
  {
    gui_set_autoraise,
    gui_set_autolower,
    lrg_set_background_color,
    NULL,                       /* border_color */
    gui_set_border_width,
    lrg_set_cursor_color,
    NULL,                       /* cursor_type */
    gui_set_font,
    lrg_set_foreground_color,
    NULL,                       /* icon_name */
    NULL,                       /* icon_type */
    NULL,                       /* child_frame_border_width */
    NULL,                       /* internal_border_width */
    gui_set_right_divider_width,
    gui_set_bottom_divider_width,
    NULL,                       /* menu_bar_lines */
    NULL,                       /* mouse_color */
    NULL,                       /* name */
    gui_set_scroll_bar_width,
    gui_set_scroll_bar_height,
    NULL,                       /* title */
    gui_set_unsplittable,
    gui_set_vertical_scroll_bars,
    gui_set_horizontal_scroll_bars,
    gui_set_visibility,
    NULL,                       /* tab_bar_lines */
    NULL,                       /* tool_bar_lines */
    NULL,                       /* scroll_bar_foreground */
    NULL,                       /* scroll_bar_background */
    gui_set_screen_gamma,
    gui_set_line_spacing,
    gui_set_left_fringe,
    gui_set_right_fringe,
    0,
    gui_set_fullscreen,
    gui_set_font_backend,
    gui_set_alpha,
    NULL,                       /* sticky */
    NULL,                       /* tool_bar_position */
    0,
    NULL,                       /* undecorated */
    NULL,                       /* parent_frame */
    NULL,                       /* skip_taskbar */
    NULL,                       /* no_focus_on_map */
    NULL,                       /* no_accept_focus */
    NULL,                       /* z_group */
    NULL,                       /* override_redirect */
    gui_set_no_special_glyphs,
    NULL,                       /* alpha_background */
    gui_set_borders_respect_alpha_background,
    NULL,
  };

/* ----------------------------------------------------- default font ----- */

void
lrg_default_font_parameter (struct frame *f, Lisp_Object parms)
{
  Lisp_Object font_param =
    gui_display_get_arg (NULL, parms, Qfont, NULL, NULL, RES_TYPE_STRING);
  Lisp_Object font = Qnil;

  if (! BASE_EQ (font_param, Qunbound))
    font = font_param;

  if (NILP (font))
    font = font_open_by_name (f, build_unibyte_string ("monospace-12"));
  if (NILP (font))
    font = font_open_by_name (f, build_unibyte_string ("Sans Mono-12"));
  if (NILP (font))
    font = font_open_by_name (f, build_unibyte_string ("fixed-12"));

  if (! NILP (font))
    gui_default_parameter (f, parms, Qfont, font, "font", "Font",
                           RES_TYPE_STRING);
}

/* -------------------------------------------------- x-create-frame ------ */

DEFUN ("lrg-create-frame", Flrg_create_frame, Slrg_create_frame, 1, 1, 0,
       doc: /* Make a new lrg (libregnum/raylib) frame.
The argument is an alist of frame parameters.  */)
  (Lisp_Object parms)
{
  struct frame *f;
  Lisp_Object frame, tem;
  Lisp_Object name;
  bool minibuffer_only = false;
  specpdl_ref count = SPECPDL_INDEX ();
  Lisp_Object display;
  struct lrg_display_info *dpyinfo = NULL;
  struct kboard *kb;
  int width, height;

  parms = Fcopy_alist (parms);

  display = gui_display_get_arg (NULL, parms, Qterminal, 0, 0,
                                 RES_TYPE_NUMBER);
  if (BASE_EQ (display, Qunbound))
    display = Qnil;
  dpyinfo = check_lrg_display_info (display);
  kb = dpyinfo->pgtk.terminal->kboard;

  if (!dpyinfo->pgtk.terminal->name)
    error ("Terminal is not live, can't create new frames on it");

  name = gui_display_get_arg (NULL, parms, Qname, "name", "Name",
                              RES_TYPE_STRING);
  if (!STRINGP (name) && !BASE_EQ (name, Qunbound) && !NILP (name))
    error ("Invalid frame name--not a string or nil");
  if (STRINGP (name))
    Vx_resource_name = name;

  /* Minibuffer handling.  */
  tem = gui_display_get_arg (NULL, parms, Qminibuffer, "minibuffer",
                             "Minibuffer", RES_TYPE_SYMBOL);
  if (EQ (tem, Qnone) || NILP (tem))
    f = make_frame_without_minibuffer (Qnil, kb, display);
  else if (EQ (tem, Qonly))
    {
      f = make_minibuffer_frame ();
      minibuffer_only = true;
    }
  else if (WINDOWP (tem))
    f = make_frame_without_minibuffer (tem, kb, display);
  else
    f = make_frame (true);

  XSETFRAME (frame, f);

  f->terminal = dpyinfo->pgtk.terminal;
  f->output_method = output_lrg;
  f->output_data.lrg = xzalloc (sizeof (struct lrg_output));
  FRAME_LRG_OUTPUT (f)->display_info = dpyinfo;
  FRAME_LRG_OUTPUT (f)->fontset = -1;
  FRAME_LRG_OUTPUT (f)->render_mode =
    lrg_requested_render_mode < 0 ? 0 : lrg_requested_render_mode;
  if (FRAME_LRG_OUTPUT (f)->render_mode != 0)
    {
      fprintf (stderr,
               "cmacs: lrg render mode '%s' not yet implemented; using 2d\n",
               FRAME_LRG_OUTPUT (f)->render_mode == 1 ? "3d" : "3dvr");
      FRAME_LRG_OUTPUT (f)->render_mode = 0;
    }
  FRAME_LRG_OUTPUT (f)->cursor_color = 0x000000;
  FRAME_FOREGROUND_PIXEL (f) = 0x000000;
  FRAME_BACKGROUND_PIXEL (f) = 0xFFFFFF;
  FRAME_LRG_OUTPUT (f)->foreground_color = 0x000000;
  FRAME_LRG_OUTPUT (f)->background_color = 0xFFFFFF;

  fset_icon_name (f, Qnil);
  dpyinfo->pgtk.reference_count++;

  f->terminal->reference_count++;

  /* make_frame does NOT register the frame; the backend must.  Without this
     the frame is invisible to other_frames/frame-list and startup's
     frame-initialize cannot delete the terminal frame.  */
  Vframe_list = Fcons (frame, Vframe_list);

  /* Font drivers + default font.  */
  lrg_register_font_drivers (f);

  /* NB: pass NULL for the X-resource name/class throughout -- lrg has no X
     resource database, and a non-NULL attribute would send
     gui_default_parameter into gui_display_get_resource via the pgtk
     FRAME_DISPLAY_INFO macro, which reads the wrong union member for an lrg
     frame.  The Lisp default (or the alist value) is used instead.  */
  gui_default_parameter (f, parms, Qfont_backend, Qnil, NULL, NULL,
                         RES_TYPE_STRING);
  lrg_default_font_parameter (f, parms);

  gui_default_parameter (f, parms, Qborder_width, make_fixnum (0),
                         NULL, NULL, RES_TYPE_NUMBER);
  gui_default_parameter (f, parms, Qinternal_border_width, make_fixnum (0),
                         NULL, NULL, RES_TYPE_NUMBER);
  gui_default_parameter (f, parms, Qright_divider_width, make_fixnum (0),
                         NULL, NULL, RES_TYPE_NUMBER);
  gui_default_parameter (f, parms, Qbottom_divider_width, make_fixnum (0),
                         NULL, NULL, RES_TYPE_NUMBER);

  gui_default_parameter (f, parms, Qforeground_color, build_string ("black"),
                         NULL, NULL, RES_TYPE_STRING);
  gui_default_parameter (f, parms, Qbackground_color, build_string ("white"),
                         NULL, NULL, RES_TYPE_STRING);
  gui_default_parameter (f, parms, Qcursor_color, build_string ("black"),
                         NULL, NULL, RES_TYPE_STRING);

  /* Set `display-type' before realizing faces: defface specs gate colours on
     (class color), which matches against this frame parameter.  Without it,
     faces like mode-line / region resolve to `unspecified'.  lrg is always a
     truecolor GPU surface.  */
  if (NILP (Fframe_parameter (frame, Qdisplay_type)))
    {
      AUTO_FRAME_ARG (arg, Qdisplay_type, Qcolor);
      Fmodify_frame_parameters (frame, arg);
    }

  /* Init faces before computing the window size (needs the font).  */
  init_frame_faces (f);

  gui_default_parameter (f, parms, Qvertical_scroll_bars, Qnil,
                         NULL, NULL, RES_TYPE_SYMBOL);
  gui_default_parameter (f, parms, Qhorizontal_scroll_bars, Qnil,
                         NULL, NULL, RES_TYPE_SYMBOL);

  /* Enable the standard graphical fringes (8 px each side) so wrapped/
     truncated lines and overlay arrows show the GUI bitmaps drawn by
     lrg_draw_fringe_bitmap, rather than the no-fringe `\'/`$' text glyphs.  */
  gui_default_parameter (f, parms, Qleft_fringe, Qnil,
                         NULL, NULL, RES_TYPE_NUMBER);
  gui_default_parameter (f, parms, Qright_fringe, Qnil,
                         NULL, NULL, RES_TYPE_NUMBER);

  /* Default to an 80x36 character frame unless the caller specified a size,
     so gui_figure_window_size has a sensible basis.  */
  if (NILP (Fassq (Qwidth, parms))
      && NILP (Fassq (Qwidth, Vdefault_frame_alist)))
    parms = Fcons (Fcons (Qwidth, make_fixnum (80)), parms);
  if (NILP (Fassq (Qheight, parms))
      && NILP (Fassq (Qheight, Vdefault_frame_alist)))
    parms = Fcons (Fcons (Qheight, make_fixnum (36)), parms);

  gui_figure_window_size (f, parms, true, true);

  width = FRAME_PIXEL_WIDTH (f);
  height = FRAME_PIXEL_HEIGHT (f);
  if (width < 100)
    width = 80 * FRAME_COLUMN_WIDTH (f);
  if (height < 100)
    height = 36 * FRAME_LINE_HEIGHT (f);

  /* Create the libregnum surface + its OS window.  */
  block_input ();
  lrg_window_create (f, width, height,
                     STRINGP (name) ? SSDATA (name) : "cmacs");
  unblock_input ();

  gui_default_parameter (f, parms, Qno_special_glyphs, Qnil,
                         NULL, NULL, RES_TYPE_BOOLEAN);

  f->can_set_window_size = true;

  adjust_frame_size (f, FRAME_TEXT_WIDTH (f), FRAME_TEXT_HEIGHT (f),
                     0, true, Qx_create_frame_1);

  gui_default_parameter (f, parms, Qauto_raise, Qnil, NULL, NULL,
                         RES_TYPE_BOOLEAN);
  gui_default_parameter (f, parms, Qauto_lower, Qnil, NULL, NULL,
                         RES_TYPE_BOOLEAN);

  SET_FRAME_VISIBLE (f, true);

  /* Make the frame visible + queue the first paint.  */
  store_frame_param (f, Qname, name);

  f->after_make_frame = true;
  SET_FRAME_GARBAGED (f);

  return unbind_to (count, frame);
}

/* -------------------------------------------------- connection ---------- */

DEFUN ("lrg-open-connection", Flrg_open_connection, Slrg_open_connection, 1, 3, 0,
       doc: /* Open a connection to an lrg display.  */)
  (Lisp_Object display, Lisp_Object xrm_string, Lisp_Object must_succeed)
{
  char *xrm_option = NULL;
  struct lrg_display_info *dpyinfo;

  (void) must_succeed;
  CHECK_STRING (display);
  if (!NILP (xrm_string))
    CHECK_STRING (xrm_string);

  if (lrg_display_list != NULL)
    return Qnil;

  dpyinfo = lrg_term_init (display, xrm_option);
  if (dpyinfo == NULL)
    error ("Cannot open lrg display");

  return Qnil;
}

DEFUN ("lrg-display-list", Flrg_display_list, Slrg_display_list, 0, 0, 0,
       doc: /* Return a list of available lrg displays.  */)
  (void)
{
  return lrg_display_list ? list1 (build_string ("lrg")) : Qnil;
}

void
syms_of_cmacs_lrgfns (void)
{
  defsubr (&Slrg_create_frame);
  defsubr (&Slrg_open_connection);
  defsubr (&Slrg_display_list);
}

#endif /* HAVE_CMACS_LRGTERM */
