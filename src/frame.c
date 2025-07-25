/* Generic frame functions.

Copyright (C) 1993-1995, 1997, 1999-2025 Free Software Foundation, Inc.

This file is part of GNU Emacs.

GNU Emacs is free software: you can redistribute it and/or modify
it under the terms of the GNU General Public License as published by
the Free Software Foundation, either version 3 of the License, or (at
your option) any later version.

GNU Emacs is distributed in the hope that it will be useful,
but WITHOUT ANY WARRANTY; without even the implied warranty of
MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
GNU General Public License for more details.

You should have received a copy of the GNU General Public License
along with GNU Emacs.  If not, see <https://www.gnu.org/licenses/>.  */

#include <config.h>

#include <stdio.h>
#include <stdlib.h>
#include <errno.h>
#include <limits.h>

#include <c-ctype.h>

#include "lisp.h"

#ifdef HAVE_WINDOW_SYSTEM
#include TERM_HEADER
#endif /* HAVE_WINDOW_SYSTEM */

#include "buffer.h"
/* These help us bind and responding to switch-frame events.  */
#include "keyboard.h"
#include "frame.h"
#include "blockinput.h"
#include "termchar.h"
#include "termhooks.h"
#include "dispextern.h"
#include "window.h"
#ifdef HAVE_WINDOW_SYSTEM
#include "fontset.h"
#endif
#include "cm.h"
#ifdef MSDOS
#include "msdos.h"
#include "dosfns.h"
#endif
#ifdef USE_X_TOOLKIT
#include "widget.h"
#endif
#include "pdumper.h"

/* The currently selected frame.  */
Lisp_Object selected_frame;

/* The selected frame the last time window change functions were run.  */
Lisp_Object old_selected_frame;

/* A frame which is not just a mini-buffer, or NULL if there are no such
   frames.  This is usually the most recent such frame that was selected.  */

static struct frame *last_nonminibuf_frame;

/* False means there are no visible garbaged frames.  */
bool frame_garbaged;

/* The default tab bar height for future frames.  */
int frame_default_tab_bar_height;

/* The default tool bar height for future frames.  */
#ifdef HAVE_EXT_TOOL_BAR
enum { frame_default_tool_bar_height = 0 };
#else
int frame_default_tool_bar_height;
#endif

#ifdef HAVE_WINDOW_SYSTEM
static void gui_report_frame_params (struct frame *, Lisp_Object *);
#endif

/* These setters are used only in this file, so they can be private.  */
static void
fset_buffer_predicate (struct frame *f, Lisp_Object val)
{
  f->buffer_predicate = val;
}
static void
fset_minibuffer_window (struct frame *f, Lisp_Object val)
{
  f->minibuffer_window = val;
}

struct frame *
decode_live_frame (register Lisp_Object frame)
{
  if (NILP (frame))
    frame = selected_frame;
  CHECK_LIVE_FRAME (frame);
  return XFRAME (frame);
}

struct frame *
decode_any_frame (register Lisp_Object frame)
{
  if (NILP (frame))
    frame = selected_frame;
  CHECK_FRAME (frame);
  return XFRAME (frame);
}

#ifdef HAVE_WINDOW_SYSTEM
bool
display_available (void)
{
  return x_display_list != NULL;
}
#endif

struct frame *
decode_window_system_frame (Lisp_Object frame)
{
  struct frame *f = decode_live_frame (frame);
  check_window_system (f);
#ifdef HAVE_WINDOW_SYSTEM
  return f;
#endif
}

struct frame *
decode_tty_frame (Lisp_Object frame)
{
  struct frame *f = decode_live_frame (frame);
  check_tty (f);
  return f;
}

void
check_window_system (struct frame *f)
{
#ifdef HAVE_WINDOW_SYSTEM
  if (window_system_available (f))
    return;
#endif
  error (f ? "Window system frame should be used"
	 : "Window system is not in use or not initialized");
}

void
check_tty (struct frame *f)
{
  /* FIXME: the noninteractive case is here because some tests running
     in batch mode, like xt-mouse-tests, test with the initial frame
     which is no tty frame.  It would be nicer if the test harness
     would allow testing with real tty frames.  */
  if (f && noninteractive)
    return;

  if (!f || !FRAME_TERMCAP_P (f))
    error ("tty frame should be used");
}

/* Return the value of frame parameter PROP in frame FRAME.  */

Lisp_Object
get_frame_param (struct frame *frame, Lisp_Object prop)
{
  return Fcdr (Fassq (prop, frame->param_alist));
}


/* Return true if 'frame-inhibit-implied-resize' is non-nil or
   fullscreen state of frame F would be affected by a vertical
   (horizontal if HORIZONTAL is true) resize.  PARAMETER is the symbol
   of the frame parameter about to be changed.

   If 'frame-inhibit-implied-resize' equals 'force', unconditionally
   return true (Bug#76275).  Otherwise, return nil if F has not been
   made yet and (on GTK) its tool bar has not been resized at least
   once.  Together these should ensure that F always gets its requested
   initial size.  */
bool
frame_inhibit_resize (struct frame *f, bool horizontal, Lisp_Object parameter)
{
  Lisp_Object fullscreen = get_frame_param (f, Qfullscreen);

  return (EQ (frame_inhibit_implied_resize, Qforce)
	  || (f->after_make_frame
#ifdef USE_GTK
	      && f->tool_bar_resized
#endif
	      && (EQ (frame_inhibit_implied_resize, Qt)
		  || (CONSP (frame_inhibit_implied_resize)
		      && !NILP (Fmemq (parameter, frame_inhibit_implied_resize)))
		  || (horizontal
		      && !NILP (fullscreen) && !EQ (fullscreen, Qfullheight))
		  || (!horizontal
		      && !NILP (fullscreen) && !EQ (fullscreen, Qfullwidth))
		  || FRAME_TERMCAP_P (f) || FRAME_MSDOS_P (f))));
}


/** Set menu bar lines for a TTY frame.  */
static void
set_menu_bar_lines (struct frame *f, Lisp_Object value, Lisp_Object oldval)
{
  int olines = FRAME_MENU_BAR_LINES (f);
  int nlines = TYPE_RANGED_FIXNUMP (int, value) ? XFIXNUM (value) : 0;

  if (is_tty_frame (f))
    {
      /* Menu bars on child frames don't work on all platforms, which is
	 the reason why prepare_menu_bar does not update_menu_bar for
	 child frames (info from Martin Rudalics).  This could be
	 implemented in ttys, but it's probably not worth it.  */
      if (FRAME_PARENT_FRAME (f))
	FRAME_MENU_BAR_LINES (f) = FRAME_MENU_BAR_HEIGHT (f) = 0;
      else
	{
	  /* Make only 0 or 1 menu bar line (Bug#77015).  */
	  FRAME_MENU_BAR_LINES (f) = FRAME_MENU_BAR_HEIGHT (f)
	    = nlines > 0 ? 1 : 0;

	  if (FRAME_MENU_BAR_LINES (f) != olines)
	    {
	      windows_or_buffers_changed = 14;
	      change_frame_size
		(f, FRAME_PIXEL_WIDTH (f), FRAME_PIXEL_HEIGHT (f),
		 false, true, false);
	    }
	}
    }
  /* Right now, menu bars don't work properly in minibuf-only frames;
     most of the commands try to apply themselves to the minibuffer
     frame itself, and get an error because you can't switch buffers
     in or split the minibuffer window.  */
  else if (!FRAME_MINIBUF_ONLY_P (f) && nlines != olines)
    {
      windows_or_buffers_changed = 14;
      FRAME_MENU_BAR_LINES (f) = FRAME_MENU_BAR_HEIGHT (f) = nlines;
      change_frame_size (f, FRAME_PIXEL_WIDTH (f), FRAME_PIXEL_HEIGHT (f),
			 false, true, false);
    }
}


/** Set tab bar lines for a TTY frame.  */
static void
set_tab_bar_lines (struct frame *f, Lisp_Object value, Lisp_Object oldval)
{
  int olines = FRAME_TAB_BAR_LINES (f);
  int nlines = TYPE_RANGED_FIXNUMP (int, value) ? XFIXNUM (value) : 0;

  /* Right now, tab bars don't work properly in minibuf-only frames;
     most of the commands try to apply themselves to the minibuffer
     frame itself, and get an error because you can't switch buffers
     in or split the minibuffer window.  */
  if (!FRAME_MINIBUF_ONLY_P (f) && nlines != olines)
    {
      windows_or_buffers_changed = 14;
      FRAME_TAB_BAR_LINES (f) = FRAME_TAB_BAR_HEIGHT (f) = nlines;
      change_frame_size (f, FRAME_PIXEL_WIDTH (f), FRAME_PIXEL_HEIGHT (f),
			 false, true, false);
    }
}

Lisp_Object Vframe_list;

DEFUN ("framep", Fframep, Sframep, 1, 1, 0,
       doc: /* Return non-nil if OBJECT is a frame.
Value is:
  t for a termcap frame (a character-only terminal),
 `x' for an Emacs frame that is really an X window,
 `w32' for an Emacs frame that is a window on MS-Windows display,
 `ns' for an Emacs frame on a GNUstep or Macintosh Cocoa display,
 `pc' for a direct-write MS-DOS frame,
 `pgtk' for an Emacs frame running on pure GTK.
 `haiku' for an Emacs frame running in Haiku.
 `android' for an Emacs frame running in Android.
See also `frame-live-p'.  */)
  (Lisp_Object object)
{
  if (!FRAMEP (object))
    return Qnil;
  switch (XFRAME (object)->output_method)
    {
    case output_initial: /* The initial frame is like a termcap frame. */
    case output_termcap:
      return Qt;
    case output_x_window:
      return Qx;
    case output_w32:
      return Qw32;
    case output_msdos_raw:
      return Qpc;
    case output_ns:
      return Qns;
    case output_pgtk:
      return Qpgtk;
    case output_haiku:
      return Qhaiku;
    case output_android:
      return Qandroid;
    default:
      emacs_abort ();
    }
}

DEFUN ("frame-live-p", Fframe_live_p, Sframe_live_p, 1, 1, 0,
       doc: /* Return non-nil if OBJECT is a frame which has not been deleted.
Value is nil if OBJECT is not a live frame.  If object is a live
frame, the return value indicates what sort of terminal device it is
displayed on.  See the documentation of `framep' for possible
return values.  */)
  (Lisp_Object object)
{
  return ((FRAMEP (object)
	   && FRAME_LIVE_P (XFRAME (object)))
	  ? Fframep (object)
	  : Qnil);
}

DEFUN ("window-system", Fwindow_system, Swindow_system, 0, 1, 0,
       doc: /* The name of the window system that FRAME is displaying through.
The value is a symbol:
 nil for a termcap frame (a character-only terminal),
 `x' for an Emacs frame that is really an X window,
 `w32' for an Emacs frame that is a window on MS-Windows display,
 `ns' for an Emacs frame on a GNUstep or Macintosh Cocoa display,
 `pc' for a direct-write MS-DOS frame.
 `pgtk' for an Emacs frame using pure GTK facilities.
 `haiku' for an Emacs frame running in Haiku.
 `android' for an Emacs frame running in Android.

FRAME defaults to the currently selected frame.

Use of this function as a predicate is deprecated.  Instead,
use `display-graphic-p' or any of the other `display-*-p'
predicates which report frame's specific UI-related capabilities.  */)
  (Lisp_Object frame)
{
  Lisp_Object type;
  if (NILP (frame))
    frame = selected_frame;

  type = Fframep (frame);

  if (NILP (type))
    wrong_type_argument (Qframep, frame);

  if (EQ (type, Qt))
    return Qnil;
  else
    return type;
}

/** Return true if F can be redisplayed, that is if F is visible and, if
    F is a tty frame, all its ancestors are visible too.  */
bool
frame_redisplay_p (struct frame *f)
{
  if (is_tty_frame (f))
    {
      struct frame *p = f;
      struct frame *q = f;

      while (p)
	{
	  if (!p->visible)
	    /* A tty child frame cannot be redisplayed if one of its
	       ancestors is invisible.  */
	    return false;
	  else
	    {
	      q = p;
	      p = FRAME_PARENT_FRAME (p);
	    }
	}

      struct tty_display_info *tty = FRAME_TTY (f);
      struct frame *r = XFRAME (tty->top_frame);

      /* A tty child frame can be redisplayed iff its root is the top
	 frame of its terminal.  Any other tty frame can be redisplayed
	 iff it is the top frame of its terminal itself which must be
	 always visible.  */
      return q == r;
    }
  else
#ifndef HAVE_X_WINDOWS
    return FRAME_VISIBLE_P (f);
#else
  /* Under X, frames can continue to be displayed to the user by the
     compositing manager even if they are invisible, so this also
     checks whether or not the frame is reported visible by the X
     server.  */
  return (FRAME_VISIBLE_P (f)
	  || (FRAME_X_P (f) && FRAME_X_VISIBLE (f)));
#endif
}

/* Placeholder used by temacs -nw before window.el is loaded.  */
DEFUN ("frame-windows-min-size", Fframe_windows_min_size,
       Sframe_windows_min_size, 4, 4, 0,
       doc: /* SKIP: real doc in window.el.  */
       attributes: const)
     (Lisp_Object frame, Lisp_Object horizontal,
      Lisp_Object ignore, Lisp_Object pixelwise)
{
  return make_fixnum (0);
}

/**
 * frame_windows_min_size:
 *
 * Return the minimum number of lines (columns if HORIZONTAL is non-nil)
 * of FRAME.  If PIXELWISE is non-nil, return the minimum inner height
 * (width) of FRAME in pixels.
 *
 * This value is calculated by the function `frame-windows-min-size' in
 * window.el unless the `min-height' (`min-width' if HORIZONTAL is
 * non-nil) parameter of FRAME is non-nil thus explicitly specifying the
 * value to be returned.  In that latter case IGNORE is ignored.
 *
 * If `frame-windows-min-size' is called, it will make sure that the
 * return value accommodates all windows of FRAME respecting the values
 * of `window-min-height' (`window-min-width' if HORIZONTAL is
 * non-nil) and `window-safe-min-height' (`window-safe-min-width')
 * according to IGNORE (see `window-min-size').
 *
 * In either case, never return a value less than 1.  For TTY frames,
 * additionally limit the minimum frame height to a value large enough
 * to support menu bar, tab bar, mode line and echo area.
 */
static int
frame_windows_min_size (Lisp_Object frame, Lisp_Object horizontal,
			Lisp_Object ignore, Lisp_Object pixelwise)
{
  struct frame *f = XFRAME (frame);
  Lisp_Object par_size;
  int retval;

  if ((!NILP (horizontal)
       && RANGED_FIXNUMP (INT_MIN,
			  par_size = get_frame_param (f, Qmin_width),
			  INT_MAX))
      || (NILP (horizontal)
	  && RANGED_FIXNUMP (INT_MIN,
			     par_size = get_frame_param (f, Qmin_height),
			     INT_MAX)))
    {
      int min_size = XFIXNUM (par_size);

      /* Don't allow phantom frames.  */
      if (min_size < 1)
	min_size = 1;

      retval = (NILP (pixelwise)
		? min_size
		: min_size * (NILP (horizontal)
			      ? FRAME_LINE_HEIGHT (f)
			      : FRAME_COLUMN_WIDTH (f)));
    }
  else
    retval = XFIXNUM (calln (Qframe_windows_min_size, frame, horizontal,
			     ignore, pixelwise));

  /* Don't allow too small height of text-mode frames, or else cm.c
     might abort in cmcheckmagic.  */
  if ((FRAME_TERMCAP_P (f) || FRAME_MSDOS_P (f)) && NILP (horizontal))
    {
      int min_height = (FRAME_MENU_BAR_LINES (f) + FRAME_TAB_BAR_LINES (f)
			+ FRAME_WANTS_MODELINE_P (f)
			+ FRAME_HAS_MINIBUF_P (f));
      if (min_height == 0)
	min_height = 1;
      if (retval < min_height)
	retval = min_height;
    }

  return retval;
}


/**
 * keep_ratio:
 *
 * Preserve ratios of frame F which usually happens after its parent
 * frame P got resized.  OLD_WIDTH, OLD_HEIGHT specifies the old native
 * size of F's parent, NEW_WIDTH and NEW_HEIGHT its new size.
 *
 * Adjust F's width if F's 'keep_ratio' parameter is non-nil and, if
 * it is a cons, its car is not 'height-only'.  Adjust F's height if F's
 * 'keep_ratio' parameter is non-nil and, if it is a cons, its car
 * is not 'width-only'.
 *
 * Adjust F's left position if F's 'keep_ratio' parameter is non-nil
 * and, if its is a cons, its cdr is non-nil and not 'top-only'.  Adjust
 * F's top position if F's 'keep_ratio' parameter is non-nil and, if
 * its is a cons, its cdr is non-nil and not 'left-only'.
 *
 * Note that when positional adjustment is requested but the size of F
 * should remain unaltered in the corresponding direction, this routine
 * tries to constrain F to its parent frame - something which usually
 * happens when the parent frame shrinks.  This means, however, that
 * when the parent frame is re-enlarged later, the child's original
 * position will not get restored to its pre-shrinking value.
 *
 * This routine is currently useful for child frames only.  It might be
 * eventually useful when moving non-child frames between monitors with
 * different resolutions.
 */
static void
keep_ratio (struct frame *f, struct frame *p, int old_width, int old_height,
	    int new_width, int new_height)
{
  Lisp_Object keep_ratio = get_frame_param (f, Qkeep_ratio);


  if (!NILP (keep_ratio))
    {
      double width_factor = (double)new_width / (double)old_width;
      double height_factor = (double)new_height / (double)old_height;
      int pixel_width, pixel_height, pos_x, pos_y;

      if (!CONSP (keep_ratio) || !NILP (Fcdr (keep_ratio)))
	{
	  if (CONSP (keep_ratio) && EQ (Fcdr (keep_ratio), Qtop_only))
	    pos_x = f->left_pos;
	  else
	    {
	      pos_x = (int)(f->left_pos * width_factor + 0.5);

	      if (CONSP (keep_ratio)
		  && (NILP (Fcar (keep_ratio))
		      || EQ (Fcar (keep_ratio), Qheight_only))
		  && FRAME_PIXEL_WIDTH (p) - FRAME_PIXEL_WIDTH (f) < pos_x)
		{
		  int p_f_width
		    = FRAME_PIXEL_WIDTH (p) - FRAME_PIXEL_WIDTH (f);

		  if (p_f_width <= 0)
		    pos_x = 0;
		  else
		    pos_x = (int)(p_f_width * width_factor * 0.5 + 0.5);
		}

	      f->left_pos = pos_x;
	    }

	  if (CONSP (keep_ratio) && EQ (Fcdr (keep_ratio), Qleft_only))
	    pos_y = f->top_pos;
	  else
	    {
	      pos_y = (int)(f->top_pos * height_factor + 0.5);

	      if (CONSP (keep_ratio)
		  && (NILP (Fcar (keep_ratio))
		      || EQ (Fcar (keep_ratio), Qwidth_only))
		  && FRAME_PIXEL_HEIGHT (p) - FRAME_PIXEL_HEIGHT (f) < pos_y)
		/* When positional adjustment was requested and the
		   width of F should remain unaltered, try to constrain
		   F to its parent.  This means that when the parent
		   frame is enlarged later the child's original position
		   won't get restored.  */
		{
		  int p_f_height
		    = FRAME_PIXEL_HEIGHT (p) - FRAME_PIXEL_HEIGHT (f);

		  if (p_f_height <= 0)
		    pos_y = 0;
		  else
		    pos_y = (int)(p_f_height * height_factor * 0.5 + 0.5);
		}

	      f->top_pos = pos_y;
	    }

          if (FRAME_TERMINAL (f)->set_frame_offset_hook)
            FRAME_TERMINAL (f)->set_frame_offset_hook (f, pos_x, pos_y, -1);
	}

      if (!CONSP (keep_ratio) || !NILP (Fcar (keep_ratio)))
	{
	  if (CONSP (keep_ratio) && EQ (Fcar (keep_ratio), Qheight_only))
	    pixel_width = -1;
	  else
	    pixel_width
	      = (int)(FRAME_PIXEL_WIDTH (f) * width_factor + 0.5);

	  if (CONSP (keep_ratio) && EQ (Fcar (keep_ratio), Qwidth_only))
	    pixel_height = -1;
	  else
	    pixel_height
	      = (int)(FRAME_PIXEL_HEIGHT (f) * height_factor + 0.5);

	  adjust_frame_size (f, FRAME_PIXEL_TO_TEXT_WIDTH (f, pixel_width),
			     FRAME_PIXEL_TO_TEXT_HEIGHT (f, pixel_height), 1,
			     false, Qkeep_ratio);
	}
    }
}


static void
frame_size_history_adjust (struct frame *f, int inhibit, Lisp_Object parameter,
			   int old_text_width, int old_text_height,
			   int new_text_width, int new_text_height,
			   int old_text_cols, int old_text_lines,
			   int new_text_cols, int new_text_lines,
			   int old_native_width, int old_native_height,
			   int new_native_width, int new_native_height,
			   int old_inner_width, int old_inner_height,
			   int new_inner_width, int new_inner_height,
			   int min_inner_width, int min_inner_height,
			   bool inhibit_horizontal, bool inhibit_vertical)
{
  Lisp_Object frame;

  XSETFRAME (frame, f);
  if (CONSP (frame_size_history)
      && FIXNUMP (XCAR (frame_size_history))
      && 0 < XFIXNUM (XCAR (frame_size_history)))
    frame_size_history =
      Fcons (make_fixnum (XFIXNUM (XCAR (frame_size_history)) - 1),
	     Fcons (Fcons (list4 (frame, make_fixnum (5),
				  make_fixnum (inhibit), parameter),
			   list5 (list4i (old_text_width, old_text_height,
					  new_text_width, new_text_height),
				  list4i (old_text_cols, old_text_lines,
					  new_text_cols, new_text_lines),
				  list4i (old_native_width, old_native_height,
					  new_native_width, new_native_height),
				  list4i (old_inner_width, old_inner_height,
					  new_inner_width,  new_inner_height),
				  list4 (make_fixnum (min_inner_width),
					 make_fixnum (min_inner_height),
					 inhibit_horizontal ? Qt : Qnil,
					 inhibit_vertical ? Qt : Qnil))),
		    XCDR (frame_size_history)));
}


void
frame_size_history_plain (struct frame *f, Lisp_Object parameter)
{
  Lisp_Object frame;

  XSETFRAME (frame, f);
  if (CONSP (frame_size_history)
      && FIXNUMP (XCAR (frame_size_history))
      && 0 < XFIXNUM (XCAR (frame_size_history)))
    frame_size_history =
      Fcons (make_fixnum (XFIXNUM (XCAR (frame_size_history)) - 1),
	     Fcons (Fcons (list3 (frame, make_fixnum (1), parameter), Qt),
		    XCDR (frame_size_history)));
}


void
frame_size_history_extra (struct frame *f, Lisp_Object parameter,
			  int pixel_width, int pixel_height,
			  int extra_width, int extra_height,
			  int delayed_width, int delayed_height)
{
  Lisp_Object frame;

  XSETFRAME (frame, f);
  if (CONSP (frame_size_history)
      && FIXNUMP (XCAR (frame_size_history))
      && 0 < XFIXNUM (XCAR (frame_size_history)))
    frame_size_history =
      Fcons (make_fixnum (XFIXNUM (XCAR (frame_size_history)) - 1),
	     Fcons (Fcons (list3 (frame, make_fixnum (2), parameter),
			   list2 (list4i (pixel_width, pixel_height,
					  extra_width, extra_height),
				  list2i (delayed_width, delayed_height))),
		    XCDR (frame_size_history)));
}


/**
 * adjust_frame_size:
 *
 * Adjust size of frame F.  NEW_TEXT_WIDTH and NEW_TEXT_HEIGHT specify
 * the new text size of F in pixels.  When INHIBIT equals 2, 3 or 4, a
 * value of -1 means to leave the text size of F unchanged and adjust,
 * if necessary and possible, F's native size accordingly.  When INHIBIT
 * equals 0, 1 or 5, a negative value means that the frame has been (or
 * should be) made pathologically small which usually means that parts
 * of the frame's windows may not be entirely visible.
 *
 * The effect of calling this function can be to either issue a request
 * to resize the frame externally (via set_window_size_hook), to resize
 * the frame internally (via resize_frame_windows) or to do nothing.
 *
 * The argument INHIBIT controls whether set_window_size_hook may be
 * called and can assume the following values:
 *
 * 0 means to unconditionally call set_window_size_hook even if sizes
 *   apparently do not change.  Fx_create_frame uses this to pass the
 *   initial size to the window manager.
 *
 * 1 means to call set_window_size_hook if the native frame size should
 *   change.  Fset_frame_size and friends and width and height parameter
 *   changes use this.
 *
 * 2 means to call set_window_size_hook provided frame_inhibit_resize
 *   allows it.  The code updating external menu and tool bars uses this
 *   to keep the height of the native frame unaltered when one of these
 *   bars is added or removed.  This means that Emacs has to work
 *   against the window manager which usually tries to keep the combined
 *   height (native frame plus bar) unaltered.
 *
 * 3 means to call set_window_size_hook if window minimum sizes must be
 *   preserved or frame_inhibit_resize allows it.  This is the default
 *   for parameters accounted for in a frame's text size like fringes,
 *   scroll bars, internal border, tab bar, internal tool and menu bars.
 *   It's also used when the frame's default font changes.
 *
 * 4 means to call set_window_size_hook only if window minimum sizes
 *   must be preserved.  The code for setting up window dividers and
 *   that responsible for wrapping the (internal) tool bar use this.
 *
 * 5 means to never call set_window_size_hook.  Usually this means to
 *   call resize_frame_windows.  change_frame_size uses this.
 *
 * PRETEND is as for change_frame_size.  PARAMETER, if non-nil, is the
 * symbol of the parameter changed (like `menu-bar-lines', `font', ...).
 * This is passed on to frame_inhibit_resize to let the latter decide on
 * a case-by-case basis whether set_window_size_hook should be called.
 */
void
adjust_frame_size (struct frame *f, int new_text_width, int new_text_height,
		   int inhibit, bool pretend, Lisp_Object parameter)
{
  int unit_width = FRAME_COLUMN_WIDTH (f);
  int unit_height = FRAME_LINE_HEIGHT (f);
  int old_native_width = FRAME_PIXEL_WIDTH (f);
  int old_native_height = FRAME_PIXEL_HEIGHT (f);
  int new_native_width, new_native_height;
  /* The desired minimum inner width and height of the frame calculated
     via 'frame-windows-min-size'.  */
  int min_inner_width, min_inner_height;
  /* Get the "old" inner width, height and position of F via its root
     window and the minibuffer window.  We cannot use FRAME_INNER_WIDTH
     and FRAME_INNER_HEIGHT here since the internal border and the top
     margin may have been already set to new values.  */
  struct window *r = XWINDOW (FRAME_ROOT_WINDOW (f));
  int old_inner_width = WINDOW_PIXEL_WIDTH (r);
  int old_inner_height
    = (WINDOW_PIXEL_HEIGHT (r)
       + ((FRAME_HAS_MINIBUF_P (f) && !FRAME_MINIBUF_ONLY_P (f))
	  ? WINDOW_PIXEL_HEIGHT (XWINDOW (FRAME_MINIBUF_WINDOW (f)))
	  : 0));
  int new_inner_width, new_inner_height;
  int old_text_cols = FRAME_COLS (f);
  int old_text_lines = FRAME_LINES (f);
  int new_text_cols, new_text_lines;
  int old_text_width = FRAME_TEXT_WIDTH (f);
  int old_text_height = FRAME_TEXT_HEIGHT (f);
  bool inhibit_horizontal, inhibit_vertical;
  Lisp_Object frame;

  XSETFRAME (frame, f);

  min_inner_width
    = frame_windows_min_size (frame, Qt, (inhibit == 5) ? Qsafe : Qnil, Qt);
  min_inner_height
    = frame_windows_min_size (frame, Qnil, (inhibit == 5) ? Qsafe : Qnil, Qt);

  if (inhibit >= 2 && inhibit <= 4)
    /* When INHIBIT is in [2..4] inhibit if the "old" window sizes stay
       within the limits and either resizing is inhibited or INHIBIT
       equals 4.  */
    {
      if (new_text_width == -1)
	new_text_width = FRAME_TEXT_WIDTH (f);
      if (new_text_height == -1)
	new_text_height = FRAME_TEXT_HEIGHT (f);

      inhibit_horizontal = (FRAME_INNER_WIDTH (f) >= min_inner_width
                            && (inhibit == 4
                                || frame_inhibit_resize (f, true, parameter)));
      inhibit_vertical = (FRAME_INNER_HEIGHT (f) >= min_inner_height
                          && (inhibit == 4
                              || frame_inhibit_resize (f, false, parameter)));
    }
  else
    /* Otherwise inhibit if INHIBIT equals 5.  If we wanted to overrule
       the WM do that here (could lead to some sort of eternal fight
       with the WM).  */
    inhibit_horizontal = inhibit_vertical = inhibit == 5;

  new_native_width = ((inhibit_horizontal && inhibit < 5)
		      ? old_native_width
		      : max (FRAME_TEXT_TO_PIXEL_WIDTH (f, new_text_width),
			     min_inner_width
			     + 2 * FRAME_INTERNAL_BORDER_WIDTH (f)));
  new_inner_width = new_native_width - 2 * FRAME_INTERNAL_BORDER_WIDTH (f);
  new_text_width = FRAME_PIXEL_TO_TEXT_WIDTH (f, new_native_width);
  new_text_cols = new_text_width / unit_width;

  new_native_height = ((inhibit_vertical && inhibit < 5)
		       ? old_native_height
		       : max (FRAME_TEXT_TO_PIXEL_HEIGHT (f, new_text_height),
			      min_inner_height
			      + FRAME_MARGIN_HEIGHT (f)
			      + 2 * FRAME_INTERNAL_BORDER_WIDTH (f)));
  new_inner_height = (new_native_height
		      - FRAME_MARGIN_HEIGHT (f)
		      - 2 * FRAME_INTERNAL_BORDER_WIDTH (f));
  new_text_height = FRAME_PIXEL_TO_TEXT_HEIGHT (f, new_native_height);
  new_text_lines = new_text_height / unit_height;

  if (FRAME_WINDOW_P (f)
      && f->can_set_window_size
      /* For inhibit == 1 call the window_size_hook only if a native
	 size changes.  For inhibit == 0 or inhibit == 2 always call
	 it.  */
      && ((!inhibit_horizontal
	   && (new_native_width != old_native_width
	       || inhibit == 0 || inhibit == 2))
	  || (!inhibit_vertical
	      && (new_native_height != old_native_height
		  || inhibit == 0 || inhibit == 2))))
    {
      if (inhibit == 2
#ifdef USE_MOTIF
	  && !EQ (parameter, Qmenu_bar_lines)
#endif
	  && (f->new_width >= 0 || f->new_height >= 0))
	/* For implied resizes with inhibit 2 (external menu and tool
	   bar) pick up any new sizes the display engine has not
	   processed yet.  Otherwise, we would request the old sizes
	   which will make this request appear as a request to set new
	   sizes and have the WM react accordingly which is not TRT.

	   We don't that for the external menu bar on Motif.
	   Otherwise, switching off the menu bar will shrink the frame
	   and switching it on will not enlarge it.  */
	{
	  if (f->new_width >= 0)
	    new_native_width = f->new_width;
	  if (f->new_height >= 0)
	    new_native_height = f->new_height;
	}

      if (CONSP (frame_size_history))
	frame_size_history_adjust (f, inhibit, parameter,
				   old_text_width, old_text_height,
				   new_text_width, new_text_height,
				   old_text_cols, old_text_lines,
				   new_text_cols, new_text_lines,
				   old_native_width, old_native_height,
				   new_native_width, new_native_height,
				   old_inner_width, old_inner_height,
				   new_inner_width, new_inner_height,
				   min_inner_width, min_inner_height,
				   inhibit_horizontal, inhibit_vertical);

      if (inhibit == 0 || inhibit == 1)
	{
	  f->new_width = new_native_width;
	  f->new_height = new_native_height;
	  /* Resetting f->new_size_p is controversial: It might cause
	     do_pending_window_change drop a previous request and we are
	     in troubles when the window manager does not honor the
	     request we issue here.  */
	  f->new_size_p = false;
	}

      if (FRAME_TERMINAL (f)->set_window_size_hook)
        FRAME_TERMINAL (f)->set_window_size_hook
	  (f, 0, new_native_width, new_native_height);
      f->resized_p = true;

      return;
    }

  if (CONSP (frame_size_history))
    frame_size_history_adjust (f, inhibit, parameter,
			       old_text_width, old_text_height,
			       new_text_width, new_text_height,
			       old_text_cols, old_text_lines,
			       new_text_cols, new_text_lines,
			       old_native_width, old_native_height,
			       new_native_width, new_native_height,
			       old_inner_width, old_inner_height,
			       new_inner_width, new_inner_height,
			       min_inner_width, min_inner_height,
			       inhibit_horizontal, inhibit_vertical);

  if ((XWINDOW (FRAME_ROOT_WINDOW (f))->pixel_top
       == FRAME_TOP_MARGIN_HEIGHT (f))
      && new_text_width == old_text_width
      && new_text_height == old_text_height
      && new_inner_width == old_inner_width
      && new_inner_height == old_inner_height
      /* We might be able to drop these but some doubts remain.  */
      && new_native_width == old_native_width
      && new_native_height == old_native_height
      && new_text_cols == old_text_cols
      && new_text_lines == old_text_lines)
    /* No change.  */
    return;

  block_input ();

#ifdef MSDOS
  if (!FRAME_PARENT_FRAME (f))
    {
      /* We only can set screen dimensions to certain values supported
	 by our video hardware.  Try to find the smallest size greater
	 or equal to the requested dimensions, while accounting for the
	 fact that the menu-bar lines are not counted in the frame
	 height.  */
      int dos_new_text_lines = new_text_lines + FRAME_TOP_MARGIN (f);

      dos_set_window_size (&dos_new_text_lines, &new_text_cols);
      new_text_lines = dos_new_text_lines - FRAME_TOP_MARGIN (f);
    }
#endif

  if (new_inner_width != old_inner_width)
    {
      resize_frame_windows (f, new_inner_width, true);

      /* MSDOS frames cannot PRETEND, as they change frame size by
	 manipulating video hardware.  */
      if (is_tty_root_frame (f))
	if ((FRAME_TERMCAP_P (f) && !pretend) || FRAME_MSDOS_P (f))
	  FrameCols (FRAME_TTY (f)) = new_text_cols;

#if defined (HAVE_WINDOW_SYSTEM)
      if (WINDOWP (f->tab_bar_window))
	{
	  XWINDOW (f->tab_bar_window)->pixel_width = new_inner_width;
	  XWINDOW (f->tab_bar_window)->total_cols
	    = new_inner_width / unit_width;
	}
#endif

#if defined (HAVE_WINDOW_SYSTEM) && ! defined (HAVE_EXT_TOOL_BAR)
      if (WINDOWP (f->tool_bar_window))
	{
	  XWINDOW (f->tool_bar_window)->pixel_width = new_inner_width;
	  XWINDOW (f->tool_bar_window)->total_cols
	    = new_inner_width / unit_width;
	}
#endif
    }
  else if (new_text_cols != old_text_cols)
    calln (Qwindow__pixel_to_total, frame, Qt);

  if (new_inner_height != old_inner_height
      /* When the top margin has changed we have to recalculate the top
	 edges of all windows.  No such calculation is necessary for the
	 left edges.  */
      || WINDOW_TOP_PIXEL_EDGE (r) != FRAME_TOP_MARGIN_HEIGHT (f))
    {
      resize_frame_windows (f, new_inner_height, false);

      /* MSDOS frames cannot PRETEND, as they change frame size by
	 manipulating video hardware. */
      if (is_tty_root_frame (f))
	if ((FRAME_TERMCAP_P (f) && !pretend) || FRAME_MSDOS_P (f))
	  FrameRows (FRAME_TTY (f)) = new_text_lines + FRAME_TOP_MARGIN (f);
    }
  else if (new_text_lines != old_text_lines)
    calln (Qwindow__pixel_to_total, frame, Qnil);

  /* Assign new sizes.  */
  FRAME_COLS (f) = new_text_cols;
  FRAME_LINES (f) = new_text_lines;
  FRAME_TEXT_WIDTH (f) = new_text_width;
  FRAME_TEXT_HEIGHT (f) = new_text_height;
  FRAME_PIXEL_WIDTH (f) = new_native_width;
  FRAME_PIXEL_HEIGHT (f) = new_native_height;
  FRAME_TOTAL_COLS (f) = FRAME_PIXEL_WIDTH (f) / FRAME_COLUMN_WIDTH (f);
  FRAME_TOTAL_LINES (f) = FRAME_PIXEL_HEIGHT (f) / FRAME_LINE_HEIGHT (f);

  {
    struct window *w = XWINDOW (FRAME_SELECTED_WINDOW (f));
    int text_area_x, text_area_y, text_area_width, text_area_height;

    window_box (w, TEXT_AREA, &text_area_x, &text_area_y, &text_area_width,
		&text_area_height);
    if (w->cursor.x >= text_area_x + text_area_width)
      w->cursor.hpos = w->cursor.x = 0;
    if (w->cursor.y >= text_area_y + text_area_height)
      w->cursor.vpos = w->cursor.y = 0;
  }

  adjust_frame_glyphs (f);
  calculate_costs (f);
  SET_FRAME_GARBAGED (f);
  if (is_tty_child_frame (f))
    SET_FRAME_GARBAGED (root_frame (f));

  /* We now say here that F was resized instead of using the old
     condition below.  Some resizing must have taken place and if it was
     only shifting the root window's position (paranoia?).  */
  f->resized_p = true;

/**   /\* A frame was "resized" if its native size changed, even if its X **/
/**      window wasn't resized at all.  *\/ **/
/**   f->resized_p = (new_native_width != old_native_width **/
/** 		  || new_native_height != old_native_height); **/

  unblock_input ();

  {
    /* Adjust size of F's child frames.  */
    Lisp_Object frames, frame1;

    FOR_EACH_FRAME (frames, frame1)
      if (FRAME_PARENT_FRAME (XFRAME (frame1)) == f)
	keep_ratio (XFRAME (frame1), f, old_native_width, old_native_height,
		    new_native_width, new_native_height);
  }
}

/* Allocate basically initialized frame.  */

static struct frame *
allocate_frame (void)
{
  return ALLOCATE_ZEROED_PSEUDOVECTOR (struct frame, tool_bar_items,
				       PVEC_FRAME);
}

struct frame *
make_frame (bool mini_p)
{
  Lisp_Object frame;
  struct frame *f;
  struct window *rw, *mw UNINIT;
  Lisp_Object root_window;
  Lisp_Object mini_window;

  f = allocate_frame ();
  XSETFRAME (frame, f);

  /* Initialize Lisp data.  Note that allocate_frame initializes all
     Lisp data to nil, so do it only for slots which should not be nil.  */
  fset_tool_bar_position (f, Qtop);

  /* Initialize non-Lisp data.  Note that allocate_frame zeroes out all
     non-Lisp data, so do it only for slots which should not be zero.
     To avoid subtle bugs and for the sake of readability, it's better to
     initialize enum members explicitly even if their values are zero.  */
  f->wants_modeline = true;
  f->redisplay = true;
  f->garbaged = true;
  f->can_set_window_size = false;
  f->after_make_frame = false;
  f->tab_bar_redisplayed = false;
  f->tab_bar_resized = false;
  f->tool_bar_redisplayed = false;
  f->tool_bar_resized = false;
  f->column_width = 1;  /* !FRAME_WINDOW_P value.  */
  f->line_height = 1;  /* !FRAME_WINDOW_P value.  */
  f->new_width = -1;
  f->new_height = -1;
  f->no_special_glyphs = false;
#ifdef HAVE_WINDOW_SYSTEM
  f->vertical_scroll_bar_type = vertical_scroll_bar_none;
  f->horizontal_scroll_bars = false;
  f->want_fullscreen = FULLSCREEN_NONE;
  f->undecorated = false;
#ifndef HAVE_NTGUI
  f->override_redirect = false;
#endif
  f->skip_taskbar = false;
  f->no_focus_on_map = false;
  f->no_accept_focus = false;
  f->z_group = z_group_none;
  f->tooltip = false;
  f->was_invisible = false;
  f->child_frame_border_width = -1;
  f->face_cache = NULL;
  f->image_cache = NULL;
  f->last_tab_bar_item = -1;
#ifndef HAVE_EXT_TOOL_BAR
  f->last_tool_bar_item = -1;
  f->tool_bar_wraps_p = false;
#endif
#ifdef NS_IMPL_COCOA
  f->ns_appearance = ns_appearance_system_default;
  f->ns_transparent_titlebar = false;
#endif
#endif
  f->select_mini_window_flag = false;
  /* This one should never be zero.  */
  f->change_stamp = 1;

#ifdef HAVE_TEXT_CONVERSION
  f->conversion.compose_region_start = Qnil;
  f->conversion.compose_region_end = Qnil;
  f->conversion.compose_region_overlay = Qnil;
  f->conversion.field = Qnil;
  f->conversion.batch_edit_count = 0;
  f->conversion.batch_edit_flags = 0;
  f->conversion.actions = NULL;
#endif

  root_window = make_window ();
  rw = XWINDOW (root_window);
  if (mini_p)
    {
      mini_window = make_window ();
      mw = XWINDOW (mini_window);
      wset_next (rw, mini_window);
      wset_prev (mw, root_window);
      mw->mini = 1;
      wset_frame (mw, frame);
      fset_minibuffer_window (f, mini_window);
      store_frame_param (f, Qminibuffer, Qt);
    }
  else
    {
      mini_window = Qnil;
      wset_next (rw, Qnil);
      fset_minibuffer_window (f, Qnil);
    }

  wset_frame (rw, frame);

  /* 80/25 is arbitrary, just so that there is "something there."
     Correct size will be set up later with adjust_frame_size.  */
  FRAME_COLS (f) = FRAME_TOTAL_COLS (f) = rw->total_cols = 80;
  FRAME_TEXT_WIDTH (f) = FRAME_PIXEL_WIDTH (f) = rw->pixel_width
    = 80 * FRAME_COLUMN_WIDTH (f);
  FRAME_LINES (f) = FRAME_TOTAL_LINES (f) = 25;
  FRAME_TEXT_HEIGHT (f) = FRAME_PIXEL_HEIGHT (f) = 25 * FRAME_LINE_HEIGHT (f);

  rw->total_lines = FRAME_LINES (f) - (mini_p ? 1 : 0);
  rw->pixel_height = rw->total_lines * FRAME_LINE_HEIGHT (f);

  fset_face_hash_table
    (f, make_hash_table (&hashtest_eq, DEFAULT_HASH_SIZE, Weak_None));

  if (mini_p)
    {
      mw->top_line = rw->total_lines;
      mw->pixel_top = rw->pixel_height;
      mw->total_cols = rw->total_cols;
      mw->pixel_width = rw->pixel_width;
      mw->total_lines = 1;
      mw->pixel_height = FRAME_LINE_HEIGHT (f);
    }

  /* Choose a buffer for the frame's root window.  */
  {
    Lisp_Object buf = Fcurrent_buffer ();

    /* If the current buffer is hidden and shall not be exposed, try to find
       another one.  */
    if (BUFFER_HIDDEN_P (XBUFFER (buf)) && NILP (expose_hidden_buffer))
      buf = other_buffer_safely (buf);

    /* Use set_window_buffer, not Fset_window_buffer, and don't let
       hooks be run by it.  The reason is that the whole frame/window
       arrangement is not yet fully initialized at this point.  Windows
       don't have the right size, glyph matrices aren't initialized
       etc.  Running Lisp functions at this point surely ends in a
       SEGV.  */
    set_window_buffer (root_window, buf, 0, 0);
    fset_buffer_list (f, list1 (buf));
  }

  if (mini_p)
    set_window_buffer (mini_window,
		       (NILP (Vminibuffer_list)
			? get_minibuffer (0)
			: Fcar (Vminibuffer_list)),
		       0, 0);

  fset_root_window (f, root_window);
  fset_selected_window (f, root_window);
  /* Make sure this window seems more recently used than
     a newly-created, never-selected window.  */
  XWINDOW (f->selected_window)->use_time = ++window_select_count;

  return f;
}

/* Make a frame using a separate minibuffer window on another frame.
   MINI_WINDOW is the minibuffer window to use.  nil means use the
   default (the global minibuffer).  */

struct frame *
make_frame_without_minibuffer (Lisp_Object mini_window, KBOARD *kb,
			       Lisp_Object display)
{
  struct frame *f;

  if (!NILP (mini_window))
    CHECK_LIVE_WINDOW (mini_window);

  if (!NILP (mini_window)
      && FRAME_KBOARD (XFRAME (XWINDOW (mini_window)->frame)) != kb)
    error ("Frame and minibuffer must be on the same terminal");

  /* Make a frame containing just a root window.  */
  f = make_frame (0);

  if (NILP (mini_window))
    {
      /* Use default-minibuffer-frame if possible.  */
      if (!FRAMEP (KVAR (kb, Vdefault_minibuffer_frame))
	  || ! FRAME_LIVE_P (XFRAME (KVAR (kb, Vdefault_minibuffer_frame))))
	{
	  Lisp_Object initial_frame;

	  /* If there's no minibuffer frame to use, create one.  */
	  initial_frame = calln (Qmake_initial_minibuffer_frame,
				 display);
	  kset_default_minibuffer_frame (kb, initial_frame);
	}

      mini_window
	= XFRAME (KVAR (kb, Vdefault_minibuffer_frame))->minibuffer_window;
    }

  fset_minibuffer_window (f, mini_window);
  store_frame_param (f, Qminibuffer, mini_window);

  /* Make the chosen minibuffer window display the proper minibuffer,
     unless it is already showing a minibuffer.  */
  if (NILP (Fmemq (XWINDOW (mini_window)->contents, Vminibuffer_list)))
    /* Use set_window_buffer instead of Fset_window_buffer (see
       discussion of bug#11984, bug#12025, bug#12026).  */
    set_window_buffer (mini_window,
		       (NILP (Vminibuffer_list)
			? get_minibuffer (0)
			: Fcar (Vminibuffer_list)), 0, 0);
  return f;
}

/* Make a frame containing only a minibuffer window.  */

struct frame *
make_minibuffer_frame (void)
{
  /* First make a frame containing just a root window, no minibuffer.  */

  register struct frame *f = make_frame (0);
  register Lisp_Object mini_window;
  register Lisp_Object frame;

  XSETFRAME (frame, f);

  f->auto_raise = 0;
  f->auto_lower = 0;
  f->no_split = 1;
  f->wants_modeline = 0;

  /* Now label the root window as also being the minibuffer.
     Avoid infinite looping on the window chain by marking next pointer
     as nil. */

  mini_window = f->root_window;
  fset_minibuffer_window (f, mini_window);
  store_frame_param (f, Qminibuffer, Qonly);
  XWINDOW (mini_window)->mini = 1;
  wset_next (XWINDOW (mini_window), Qnil);
  wset_prev (XWINDOW (mini_window), Qnil);
  wset_frame (XWINDOW (mini_window), frame);

  /* Put the proper buffer in that window.  */

  /* Use set_window_buffer instead of Fset_window_buffer (see
     discussion of bug#11984, bug#12025, bug#12026).  */
  set_window_buffer (mini_window,
		     (NILP (Vminibuffer_list)
		      ? get_minibuffer (0)
		      : Fcar (Vminibuffer_list)), 0, 0);
  return f;
}


/* Construct a frame that refers to a terminal.  */

static intmax_t tty_frame_count;

struct frame *
make_initial_frame (void)
{
  struct frame *f;
  struct terminal *terminal;
  Lisp_Object frame;

  eassert (initial_kboard);
  eassert (NILP (Vframe_list) || CONSP (Vframe_list));

  terminal = init_initial_terminal ();

  f = make_frame (true);
  XSETFRAME (frame, f);

  Vframe_list = Fcons (frame, Vframe_list);

  tty_frame_count = 1;
  fset_name (f, build_string ("F1"));

  SET_FRAME_VISIBLE (f, true);

  f->output_method = terminal->type;
  f->terminal = terminal;
  f->terminal->reference_count++;

  FRAME_FOREGROUND_PIXEL (f) = FACE_TTY_DEFAULT_FG_COLOR;
  FRAME_BACKGROUND_PIXEL (f) = FACE_TTY_DEFAULT_BG_COLOR;

#ifdef HAVE_WINDOW_SYSTEM
  f->vertical_scroll_bar_type = vertical_scroll_bar_none;
  f->horizontal_scroll_bars = false;
#endif

  /* The default value of menu-bar-mode is t.  */
  set_menu_bar_lines (f, make_fixnum (1), Qnil);

  /* The default value of tab-bar-mode is nil.  */
  set_tab_bar_lines (f, make_fixnum (0), Qnil);

  /* Allocate glyph matrices.  */
  adjust_frame_glyphs (f);

  if (!noninteractive)
    init_frame_faces (f);

  last_nonminibuf_frame = f;

  f->can_set_window_size = true;
  f->after_make_frame = true;

  return f;
}

#ifndef HAVE_ANDROID

static struct frame *
make_terminal_frame (struct terminal *terminal, Lisp_Object parent,
		     Lisp_Object params)
{
  if (!terminal->name)
    error ("Terminal is not live, can't create new frames on it");

  struct frame *f;

  if (NILP (parent))
    f = make_frame (true);
  else
    {
      CHECK_LIVE_FRAME (parent);

      f = NULL;
      Lisp_Object mini = Fassq (Qminibuffer, params);

      /* Handling the minibuffer parameter on a tty is different from
	 its handling on a GUI.  On a GUI any "client frame" can have,
	 in principle, its minibuffer window on any "minibuffer frame" -
	 a frame that has a minibuffer window.  If necessary, Emacs
	 tells the window manager to make the minibuffer frame visible,
	 raise it and give it input focus.

	 On a tty there's no window manager; so Emacs itself has to make
	 such a minibuffer frame visible, raise and focus it.  Since a
	 tty can show only one root frame (a frame that doesn't have a
	 parent frame) at any time, any client frame shown on a tty must
	 have a minibuffer frame whose root frame is the root frame of
	 that client frame.  If that minibuffer frame is a child frame,
	 Emacs will automatically make it visible, raise it and give it
	 input focus, if necessary.

	 Two trivial consequences of these observations for ttys are:

	 - A root frame cannot be the minibuffer frame of another root
	   frame.

	 - Since a child frame cannot be created before its parent
           frame, each root frame must have its own minibuffer window.

         The situation may change as soon as we can delete and create
         minibuffer windows on the fly.  */
      if (CONSP (mini))
	{
	  mini = Fcdr (mini);

	  if (EQ (mini, Qnone) || NILP (mini))
	    {
	      mini = root_frame (XFRAME (parent))->minibuffer_window;
	      f = make_frame (false);
	      fset_minibuffer_window (f, mini);
	      store_frame_param (f, Qminibuffer, mini);
	    }
	  else if (EQ (mini, Qonly))
	    f = make_minibuffer_frame ();
	  else if (WINDOWP (mini))
	    {
	      if (!WINDOW_LIVE_P (mini)
		  || !MINI_WINDOW_P (XWINDOW (mini))
		  || (root_frame (WINDOW_XFRAME (XWINDOW (mini)))
		      != root_frame (XFRAME (parent))))
		error ("The `minibuffer' parameter does not specify a valid minibuffer window");
	      else
		{
		  f = make_frame (false);
		  fset_minibuffer_window (f, mini);
		  store_frame_param (f, Qminibuffer, mini);
		}
	    }
	}

      if (f == NULL)
	f = make_frame (true);
      f->parent_frame = parent;
      f->z_order = 1 + max_child_z_order (XFRAME (parent));
    }

  Lisp_Object frame;
  XSETFRAME (frame, f);
  Vframe_list = Fcons (frame, Vframe_list);

  fset_name (f, make_formatted_string ("F%"PRIdMAX, ++tty_frame_count));

  SET_FRAME_VISIBLE (f, true);

  f->terminal = terminal;
  f->terminal->reference_count++;
#ifdef MSDOS
  f->output_data.tty = &the_only_tty_output;
  f->output_data.tty->display_info = &the_only_display_info;
  if (!inhibit_window_system
      && (!FRAMEP (selected_frame) || !FRAME_LIVE_P (XFRAME (selected_frame))
	  || XFRAME (selected_frame)->output_method == output_msdos_raw))
    f->output_method = output_msdos_raw;
  else
    f->output_method = output_termcap;
#else /* not MSDOS */
  f->output_method = output_termcap;
  create_tty_output (f);
  FRAME_FOREGROUND_PIXEL (f) = FACE_TTY_DEFAULT_FG_COLOR;
  FRAME_BACKGROUND_PIXEL (f) = FACE_TTY_DEFAULT_BG_COLOR;
#endif /* not MSDOS */

  struct tty_display_info *tty = terminal->display_info.tty;

  if (NILP (tty->top_frame))
    /* If this frame's terminal's top frame has not been set up yet,
       make the new frame its top frame so the top frame has been set up
       before the first do_switch_frame on this terminal happens.  See
       Bug#78966.  */
    tty->top_frame = frame;

#ifdef HAVE_WINDOW_SYSTEM
  f->vertical_scroll_bar_type = vertical_scroll_bar_none;
  f->horizontal_scroll_bars = false;
#endif

  /* Menu bars on child frames don't work on all platforms, which is
     the reason why prepare_menu_bar does not update_menu_bar for
     child frames (info from Martin Rudalics).  This could be
     implemented in ttys, but it's unclear if it is worth it.  */
  if (NILP (parent))
    FRAME_MENU_BAR_LINES (f) = NILP (Vmenu_bar_mode) ? 0 : 1;
  else
    FRAME_MENU_BAR_LINES (f) = 0;

  FRAME_TAB_BAR_LINES (f) = NILP (Vtab_bar_mode) ? 0 : 1;
  FRAME_LINES (f) = FRAME_LINES (f) - FRAME_MENU_BAR_LINES (f)
    - FRAME_TAB_BAR_LINES (f);
  FRAME_MENU_BAR_HEIGHT (f) = FRAME_MENU_BAR_LINES (f) * FRAME_LINE_HEIGHT (f);
  FRAME_TAB_BAR_HEIGHT (f) = FRAME_TAB_BAR_LINES (f) * FRAME_LINE_HEIGHT (f);
  FRAME_TEXT_HEIGHT (f) = FRAME_TEXT_HEIGHT (f) - FRAME_MENU_BAR_HEIGHT (f)
    - FRAME_TAB_BAR_HEIGHT (f);

  return f;
}

/* Get a suitable value for frame parameter PARAMETER for a newly
   created frame, based on (1) the user-supplied frame parameter
   alist SUPPLIED_PARMS, and (2) CURRENT_VALUE.  */

static Lisp_Object
get_future_frame_param (Lisp_Object parameter,
                        Lisp_Object supplied_parms,
                        char *current_value)
{
  Lisp_Object result;

  result = Fassq (parameter, supplied_parms);
  if (NILP (result))
    result = Fassq (parameter, XFRAME (selected_frame)->param_alist);
  if (NILP (result) && current_value != NULL)
    result = build_string (current_value);
  if (!NILP (result) && !STRINGP (result))
    result = XCDR (result);
  if (NILP (result) || !STRINGP (result))
    result = Qnil;

  return result;
}

#endif

int
tty_child_pos_param (struct frame *f, Lisp_Object key,
		     Lisp_Object params, int pos, int size)
{
  struct frame *p = XFRAME (f->parent_frame);
  Lisp_Object val = Fassq (key, params);

  if (CONSP (val))
    {
      val = XCDR (val);

      if (EQ (val, Qminus))
	pos = (EQ (key, Qtop)
	       ? p->pixel_height - size
	       : p->pixel_width - size);
      else if (TYPE_RANGED_FIXNUMP (int, val))
	{
	  pos = XFIXNUM (val);

	  if (pos < 0)
	    /* Handle negative value. */
	    pos = (EQ (key, Qtop)
		   ? p->pixel_height - size + pos
		   : p->pixel_width - size + pos);
	}
      else if (CONSP (val) && EQ (XCAR (val), Qplus)
	       && CONSP (XCDR (val))
	       && TYPE_RANGED_FIXNUMP (int, XCAR (XCDR (val))))
	pos = XFIXNUM (XCAR (XCDR (val)));
      else if (CONSP (val) && EQ (XCAR (val), Qminus)
	       && CONSP (XCDR (val))
	       && RANGED_FIXNUMP (-INT_MAX, XCAR (XCDR (val)), INT_MAX))
	pos = (EQ (key, Qtop)
	       ? p->pixel_height - size - XFIXNUM (XCAR (XCDR (val)))
	       : p->pixel_width - size - XFIXNUM (XCAR (XCDR (val))));
    }

  return pos;
}

int
tty_child_size_param (struct frame *child, Lisp_Object key,
		      Lisp_Object params, int dflt)
{
  Lisp_Object val = Fassq (key, params);
  if (CONSP (val))
    {
      val = XCDR (val);
      if (CONSP (val))
	{
	  /* Width and height may look like (width text-pixels . PIXELS)
	     on window systems.  Mimic that.  */
	  val = XCDR (val);
	  if (EQ (val, Qtext_pixels))
	    val = XCDR (val);
	}
      else if (FLOATP (val))
	{
	  /* Width and height may be a float, in which case
	     it's a multiple of the parent's value.  */
	  struct frame *parent = FRAME_PARENT_FRAME (child);
	  eassert (parent);	/* the caller ensures this, but... */
	  if (parent)
	    {
	      int sz = (EQ (key, Qwidth) ? FRAME_TOTAL_COLS (parent)
			: FRAME_TOTAL_LINES (parent));
	      val = make_fixnum (XFLOAT_DATA (val) * sz);
	    }
	  else
	    val = Qnil;
	}

      if (FIXNATP (val))
	return XFIXNUM (val);
    }
  return dflt;
}

#ifndef HAVE_ANDROID

static void
tty_child_frame_rect (struct frame *f, Lisp_Object params,
		      int *x, int *y, int *w, int *h)
{
  *w = tty_child_size_param (f, Qwidth, params, FRAME_TOTAL_COLS (f));
  *h = tty_child_size_param (f, Qheight, params, FRAME_TOTAL_LINES (f));
  *x = tty_child_pos_param (f, Qleft, params, 0, *w);
  *y = tty_child_pos_param (f, Qtop, params, 0, *h);
}

#endif /* !HAVE_ANDROID */

DEFUN ("make-terminal-frame", Fmake_terminal_frame, Smake_terminal_frame,
       1, 1, 0,
       doc: /* Create an additional terminal frame, possibly on another terminal.
This function takes one argument, an alist specifying frame parameters.

You can create multiple frames on a single text terminal, but only one
of them (the selected terminal frame) is actually displayed.

In practice, generally you don't need to specify any parameters,
except when you want to create a new frame on another terminal.
In that case, the `tty' parameter specifies the device file to open,
and the `tty-type' parameter specifies the terminal type.  Example:

   (make-terminal-frame \\='((tty . "/dev/pts/5") (tty-type . "xterm")))

Note that changing the size of one terminal frame automatically
affects all frames on the same terminal device.  */)
  (Lisp_Object parms)
{
#ifdef HAVE_ANDROID
  error ("Text terminals are not supported on this platform");
  return Qnil;
#else
  struct terminal *t = NULL;
  struct frame *sf = SELECTED_FRAME ();

#ifdef MSDOS
  if (sf->output_method != output_msdos_raw
      && sf->output_method != output_termcap)
    emacs_abort ();
#else /* not MSDOS */

#ifdef WINDOWSNT                           /* This should work now! */
  if (sf->output_method != output_termcap)
    error ("Not using an ASCII terminal now; cannot make a new ASCII frame");
#endif
#endif /* not MSDOS */

  {
    Lisp_Object terminal;

    terminal = Fassq (Qterminal, parms);
    if (CONSP (terminal))
      {
        terminal = XCDR (terminal);
        t = decode_live_terminal (terminal);
      }
#ifdef MSDOS
    if (t && t != the_only_display_info.terminal)
      /* msdos.c assumes a single tty_display_info object.  */
      error ("Multiple terminals are not supported on this platform");
    if (!t)
      t = the_only_display_info.terminal;
# endif
  }

  if (!t)
    {
      char *name = 0, *type = 0;
      Lisp_Object tty, tty_type;
      USE_SAFE_ALLOCA;

      tty = get_future_frame_param
        (Qtty, parms, (FRAME_TERMCAP_P (XFRAME (selected_frame))
                       ? FRAME_TTY (XFRAME (selected_frame))->name
                       : NULL));
      if (!NILP (tty))
	SAFE_ALLOCA_STRING (name, tty);

      tty_type = get_future_frame_param
        (Qtty_type, parms, (FRAME_TERMCAP_P (XFRAME (selected_frame))
                            ? FRAME_TTY (XFRAME (selected_frame))->type
                            : NULL));
      if (!NILP (tty_type))
	SAFE_ALLOCA_STRING (type, tty_type);

      t = init_tty (name, type, 0); /* Errors are not fatal.  */
      SAFE_FREE ();
    }

  /* Make a new frame.  We need to know up front if a parent frame is
     specified because we behave differently in this case, e.g., child
     frames don't obscure other frames.  */
  Lisp_Object parent = Fcdr (Fassq (Qparent_frame, parms));
  struct frame *f = make_terminal_frame (t, parent, parms);

  if (!noninteractive)
    init_frame_faces (f);

  /* Visibility of root frames cannot be set with a frame parameter.
     Their visibility solely depends on whether or not they are the
     top_frame on the terminal.  */
  if (FRAME_PARENT_FRAME (f))
    {
      Lisp_Object visible = Fassq (Qvisibility, parms);
      if (CONSP (visible))
	SET_FRAME_VISIBLE (f, !NILP (visible));

      /* FIXME/tty: The only way, for now, to get borders on a tty is
	 to allow decorations.  */
      Lisp_Object undecorated = Fassq (Qundecorated, parms);
      if (CONSP (undecorated) && !NILP (XCDR (undecorated)))
	f->undecorated = true;

      /* Unused at present.  */
      Lisp_Object no_focus = Fassq (Qno_accept_focus, parms);
      if (CONSP (no_focus) && !NILP (XCDR (no_focus)))
	f->no_accept_focus = true;

      Lisp_Object no_split = Fassq (Qunsplittable, parms);
      if (CONSP (no_split) && !NILP (XCDR (no_split)))
	f->no_split = true;
    }

  /* Determine width and height of the frame.  For root frames use the
     width/height of the terminal.  For child frames, take it from frame
     parameters.  Note that a default (80x25) has been set in
     make_frame.  We handle root frames in this way because otherwise we
     would end up needing glyph matrices for the terminal, which is both
     more work and has its downsides (think of clipping frames to the
     terminal size).  */
  int x = 0, y = 0, width, height;
  if (FRAME_PARENT_FRAME (f))
    tty_child_frame_rect (f, parms, &x, &y, &width, &height);
  else
    get_tty_size (fileno (FRAME_TTY (f)->input), &width, &height);
  adjust_frame_size (f, width, height - FRAME_TOP_MARGIN (f), 5, 0,
		     Qterminal_frame);
  adjust_frame_glyphs (f);

  calculate_costs (f);

  f->left_pos = x;
  f->top_pos = y;

  store_in_alist (&parms, Qtty_type, build_string (t->display_info.tty->type));
  store_in_alist (&parms, Qtty,
		  (t->display_info.tty->name
		   ? build_string (t->display_info.tty->name)
		   : Qnil));

  /* Make the frame face hash be frame-specific, so that each
     frame could change its face definitions independently.  */
  fset_face_hash_table (f, Fcopy_hash_table (sf->face_hash_table));
  /* Simple copy_hash_table isn't enough, because we need the contents of
     the vectors which are the values in face_hash_table to
     be copied as well.  */
  ptrdiff_t idx = 0;
  struct Lisp_Hash_Table *table = XHASH_TABLE (f->face_hash_table);
  for (idx = 0; idx < table->count; ++idx)
    set_hash_value_slot (table, idx, Fcopy_sequence (HASH_VALUE (table, idx)));

  /* On terminal frames the `minibuffer' frame parameter is always
     virtually t.  Avoid that a different value in parms causes
     complaints, see Bug#24758.  */
  if (!FRAME_PARENT_FRAME (f))
    store_in_alist (&parms, Qminibuffer, Qt);

  Lisp_Object frame;
  XSETFRAME (frame, f);
  Fmodify_frame_parameters (frame, parms);

  f->can_set_window_size = true;
  f->after_make_frame = true;

  return frame;
#endif
}


/* Perform the switch to frame FRAME.

   If FRAME is a switch-frame event `(switch-frame FRAME1)', use
   FRAME1 as frame.

   If TRACK is non-zero and the frame that currently has the focus
   redirects its focus to the selected frame, redirect that focused
   frame's focus to FRAME instead.

   FOR_DELETION non-zero means that the selected frame is being
   deleted, which includes the possibility that the frame's terminal
   is dead.

   The value of NORECORD is passed as argument to Fselect_window.  */

Lisp_Object
do_switch_frame (Lisp_Object frame, int track, int for_deletion, Lisp_Object norecord)
{
  /* If FRAME is a switch-frame event, extract the frame we should
     switch to.  */
  if (CONSP (frame)
      && EQ (XCAR (frame), Qswitch_frame)
      && CONSP (XCDR (frame)))
    frame = XCAR (XCDR (frame));

  /* This used to say CHECK_LIVE_FRAME, but apparently it's possible for
     a switch-frame event to arrive after a frame is no longer live,
     especially when deleting the initial frame during startup.  */
  CHECK_FRAME (frame);
  struct frame *f = XFRAME (frame);
  struct frame *sf = SELECTED_FRAME ();

  /* Silently ignore dead and tooltip frames (Bug#47207).  */
  if (!FRAME_LIVE_P (f) || FRAME_TOOLTIP_P (f))
    return Qnil;
  else if (f == sf)
    return frame;

  /* If the frame with GUI focus has had it's Emacs focus redirected
     toward the currently selected frame, we should change the
     redirection to point to the newly selected frame.  This means
     that if the focus is redirected from a minibufferless frame to a
     surrogate minibuffer frame, we can use `other-window' to switch
     between all the frames using that minibuffer frame, and the focus
     redirection will follow us around.  This code is necessary when
     we have a minibufferless frame using the MB in another (normal)
     frame (bug#64152) (ACM, 2023-06-20).  */
#ifdef HAVE_WINDOW_SYSTEM
  if (track && FRAME_WINDOW_P (f) && FRAME_TERMINAL (f)->get_focus_frame)
    {
      Lisp_Object gfocus; /* The frame which still has focus on the
			     current terminal, according to the GUI
			     system. */
      Lisp_Object focus;  /* The frame to which Emacs has redirected
			     the focus from `gfocus'.  This might be a
			     frame with a minibuffer when `gfocus'
			     doesn't have a MB.  */

      gfocus = FRAME_TERMINAL (f)->get_focus_frame (f);
      if (FRAMEP (gfocus))
	{
	  focus = FRAME_FOCUS_FRAME (XFRAME (gfocus));
	  if (FRAMEP (focus) && XFRAME (focus) == SELECTED_FRAME ())
	      /* Redirect frame focus also when FRAME has its minibuffer
		 window on the selected frame (see Bug#24500).

		 Don't do that: It causes redirection problem with a
		 separate minibuffer frame (Bug#24803) and problems
		 when updating the cursor on such frames.
	      || (NILP (focus)
		  && EQ (FRAME_MINIBUF_WINDOW (f), sf->selected_window)))  */
	    Fredirect_frame_focus (gfocus, frame);
	}
    }
#endif /* HAVE_X_WINDOWS */

  if (!for_deletion && FRAME_HAS_MINIBUF_P (sf))
    resize_mini_window (XWINDOW (FRAME_MINIBUF_WINDOW (sf)), 1);

  if (FRAME_TERMCAP_P (f) || FRAME_MSDOS_P (f))
    {
      struct tty_display_info *tty = FRAME_TTY (f);
      Lisp_Object top_frame = tty->top_frame;

      /* When FRAME's root frame is not its terminal's top frame, make
	 that root frame the new top frame of FRAME's terminal.  */
      if (NILP (top_frame) || root_frame (f) != XFRAME (top_frame))
	{
	  struct frame *p = FRAME_PARENT_FRAME (f);

	  XSETFRAME (top_frame, root_frame (f));
	  tty->top_frame = top_frame;

	  while (p)
	    {
	      /* If FRAME is a child frame, make its ancsetors visible
		 and garbage them ...  */
	      SET_FRAME_VISIBLE (p, true);
	      SET_FRAME_GARBAGED (p);
	      p = FRAME_PARENT_FRAME (p);
	    }

	  /* ... and FRAME itself too.  */
	  SET_FRAME_VISIBLE (f, true);
	  SET_FRAME_GARBAGED (f);

	  /* FIXME: Why is it correct to set FrameCols/Rows here?  */
	  if (!FRAME_PARENT_FRAME (f))
	    {
	      /* If the new TTY frame changed dimensions, we need to
		 resync term.c's idea of the frame size with the new
		 frame's data.  */
	      if (FRAME_COLS (f) != FrameCols (tty))
		FrameCols (tty) = FRAME_COLS (f);
	      if (FRAME_TOTAL_LINES (f) != FrameRows (tty))
		FrameRows (tty) = FRAME_TOTAL_LINES (f);
	    }
	}
      else
	/* Should be covered by the condition above.  */
	SET_FRAME_VISIBLE (f, true);
    }

  sf->select_mini_window_flag = MINI_WINDOW_P (XWINDOW (sf->selected_window));

  move_minibuffers_onto_frame (sf, frame, for_deletion);

  /* If the selected window in the target frame is its mini-window, we move
     to a different window, the most recently used one, unless there is a
     valid active minibuffer in the mini-window.  */
  if (EQ (f->selected_window, f->minibuffer_window)
      /* The following test might fail if the mini-window contains a
	 non-active minibuffer.  */
      && NILP (Fminibufferp (XWINDOW (f->minibuffer_window)->contents, Qt)))
    {
      Lisp_Object w = calln (Qget_mru_window, frame);
      if (WINDOW_LIVE_P (w)) /* W can be nil in minibuffer-only frames.  */
        Fset_frame_selected_window (frame, w, Qnil);
    }

  /* After setting `selected_frame`, we're temporarily in an inconsistent
     state where (selected-window) != (frame-selected-window).  Until this
     invariant is restored we should be very careful not to run any Lisp.
     (bug#58343)  */
  selected_frame = frame;

  if (f->select_mini_window_flag
      && !NILP (Fminibufferp (XWINDOW (f->minibuffer_window)->contents, Qt)))
    fset_selected_window (f, f->minibuffer_window);
  f->select_mini_window_flag = false;

  if (! FRAME_MINIBUF_ONLY_P (XFRAME (selected_frame)))
    last_nonminibuf_frame = XFRAME (selected_frame);

  Fselect_window (f->selected_window, norecord);

  /* We want to make sure that the next event generates a frame-switch
     event to the appropriate frame.  This seems kludgy to me, but
     before you take it out, make sure that evaluating something like
     (select-window (frame-root-window (make-frame))) doesn't end up
     with your typing being interpreted in the new frame instead of
     the one you're actually typing in.  */

  /* FIXME/tty: I don't understand this.  (The comment above is from
     Jim BLandy 1993 BTW, and the frame_ancestor_p from 2017.)

     Setting the last event frame to nil leads to switch-frame events
     being generated even if they normally wouldn't be because the frame
     in question equals selected-frame.  See the places in keyboard.c
     where make_lispy_switch_frame is called.

     This leads to problems at least on ttys.

     Imagine that we have functions in post-command-hook that use
     select-frame in some way (e.g., with-selected-window).  Let these
     functions select different frames during the execution of
     post-command-hook in command_loop_1.  Setting
     internal_last_event_frame to nil here makes these select-frame
     calls (potentially and in reality) generate switch-frame events.
     (But only in one direction (frame_ancestor_p), which I also don't
     understand).

     These switch-frame events form an endless loop in
     command_loop_1.  It runs post-command-hook, which generates
     switch-frame events, which command_loop_1 finds (bound to '#ignore)
     and executes, which again runs post-command-hook etc., ad
     infinitum.

     Let's not do that for now on ttys.  */
  if (!is_tty_frame (f))
    if (!frame_ancestor_p (f, sf))
      internal_last_event_frame = Qnil;

  return frame;
}

DEFUN ("select-frame", Fselect_frame, Sselect_frame, 1, 2, "e",
       doc: /* Select FRAME.
Subsequent editing commands apply to its selected window.
Optional argument NORECORD means to neither change the order of
recently selected windows nor the buffer list.

The selection of FRAME lasts until the next time the user does
something to select a different frame, or until the next time
this function is called.  If you are using a window system, the
previously selected frame may be restored as the selected frame
when returning to the command loop, because it still may have
the window system's input focus.  On a text terminal, the next
redisplay will display FRAME.

This function returns FRAME, or nil if FRAME has been deleted.  */)
  (Lisp_Object frame, Lisp_Object norecord)
{
  struct frame *f;

  CHECK_LIVE_FRAME (frame);
  f = XFRAME (frame);

  if (FRAME_TOOLTIP_P (f))
    /* Do not select a tooltip frame (Bug#47207).  */
    error ("Cannot select a tooltip frame");
  else
    return do_switch_frame (frame, 1, 0, norecord);
}

DEFUN ("handle-switch-frame", Fhandle_switch_frame,
       Shandle_switch_frame, 1, 1, "^e",
       doc: /* Handle a switch-frame event EVENT.
Switch-frame events are usually bound to this function.
A switch-frame event is an event Emacs sends itself to
indicate that input is arriving in a new frame. It does not
necessarily represent user-visible input focus.  */)
  (Lisp_Object event)
{
  /* Preserve prefix arg that the command loop just cleared.  */
  kset_prefix_arg (current_kboard, Vcurrent_prefix_arg);
  run_hook (Qmouse_leave_buffer_hook);

  return do_switch_frame (event, 0, 0, Qnil);
}

DEFUN ("selected-frame", Fselected_frame, Sselected_frame, 0, 0, 0,
       doc: /* Return the frame that is now selected.  */)
  (void)
{
  return selected_frame;
}

DEFUN ("old-selected-frame", Fold_selected_frame,
       Sold_selected_frame, 0, 0, 0,
       doc: /* Return the old selected FRAME.
FRAME must be a live frame and defaults to the selected one.

The return value is the frame selected the last time window change
functions were run.  */)
  (void)
{
  return old_selected_frame;
}

DEFUN ("frame-list", Fframe_list, Sframe_list,
       0, 0, 0,
       doc: /* Return a list of all live frames.
The return value does not include any tooltip frame.  */)
  (void)
{
#ifdef HAVE_WINDOW_SYSTEM
  Lisp_Object list = Qnil, tail, frame;

  FOR_EACH_FRAME (tail, frame)
    if (!FRAME_TOOLTIP_P (XFRAME (frame)))
      list = Fcons (frame, list);
  /* Reverse list for consistency with the !HAVE_WINDOW_SYSTEM case.  */
  return Fnreverse (list);
#else /* !HAVE_WINDOW_SYSTEM */
  return Fcopy_sequence (Vframe_list);
#endif /* HAVE_WINDOW_SYSTEM */
}

DEFUN ("frame-parent", Fframe_parent, Sframe_parent,
       0, 1, 0,
       doc: /* Return the parent frame of FRAME.
The parent frame of FRAME is the Emacs frame whose window-system window
is the parent window of FRAME's window-system window.  When such a frame
exists, FRAME is considered a child frame of that frame.

Return nil if FRAME has no parent frame.  This means that FRAME's
window-system window is either a "top-level" window (a window whose
parent window is the window-system's root window) or an embedded window
\(a window whose parent window is owned by some other application).  */)
     (Lisp_Object frame)
{
  struct frame *f = decode_live_frame (frame);
  struct frame *p = FRAME_PARENT_FRAME (f);
  Lisp_Object parent;

  /* Can't return f->parent_frame directly since it might not be defined
     for this platform.  */
  if (p)
    {
      XSETFRAME (parent, p);

      return parent;
    }
  else
    return Qnil;
}

/* Return true if frame AF is an ancestor of frame DF.  */
bool
frame_ancestor_p (struct frame *af, struct frame *df)
{
  struct frame *pf = FRAME_PARENT_FRAME (df);

  while (pf)
    {
      if (pf == af)
	return true;
      else
	pf = FRAME_PARENT_FRAME (pf);
    }

  return false;
}

/* A frame AF subsumes a frame DF if AF and DF are the same or AF is an
   ancestor of DF.  */
static bool
frame_subsumes_p (struct frame *af, struct frame *df)
{
  while (df)
    {
      if (df == af)
	return true;
      else
	df = FRAME_PARENT_FRAME (df);
    }

  return false;
}

DEFUN ("frame-ancestor-p", Fframe_ancestor_p, Sframe_ancestor_p,
       2, 2, 0,
       doc: /* Return non-nil if ANCESTOR is an ancestor of DESCENDANT.
ANCESTOR is an ancestor of DESCENDANT when it is either DESCENDANT's
parent frame or it is an ancestor of DESCENDANT's parent frame.  Both,
ANCESTOR and DESCENDANT must be live frames and default to the selected
frame.  */)
     (Lisp_Object ancestor, Lisp_Object descendant)
{
  struct frame *af = decode_live_frame (ancestor);
  struct frame *df = decode_live_frame (descendant);
  return frame_ancestor_p (af, df) ? Qt : Qnil;
}

/* Return the root frame of frame F.  Follow the parent_frame chain
   until we reach a frame that has no parent.  That is the root frame.
   Note that the root of a root frame is itself. */

struct frame *
root_frame (struct frame *f)
{
  while (FRAME_PARENT_FRAME (f))
    f = FRAME_PARENT_FRAME (f);
  return f;
}


DEFUN ("frame-root-frame", Fframe_root_frame, Sframe_root_frame,
       0, 1, 0,
       doc: /* Return root frame of specified FRAME.
FRAME must be a live frame and defaults to the selected one.  The root
frame of FRAME is the frame obtained by following the chain of parent
frames starting with FRAME until a frame is reached that has no parent.
If FRAME has no parent, its root frame is FRAME.  */)
     (Lisp_Object frame)
{
  struct frame *f = decode_live_frame (frame);
  struct frame *r = root_frame (f);
  Lisp_Object root;

  XSETFRAME (root, r);

  return root;
}


/* Return CANDIDATE if it can be used as 'other-than-FRAME' frame on the
   same tty (for tty frames) or among frames which uses FRAME's keyboard.
   If MINIBUF is nil, do not consider minibuffer-only candidate.
   If MINIBUF is `visible', do not consider an invisible candidate.
   If MINIBUF is a window, consider only its own frame and candidate now
   using that window as the minibuffer.
   If MINIBUF is 0, consider candidate if it is visible or iconified.
   Otherwise consider any candidate and return nil if CANDIDATE is not
   acceptable.  */

static Lisp_Object
candidate_frame (Lisp_Object candidate, Lisp_Object frame, Lisp_Object minibuf)
{
  struct frame *c = XFRAME (candidate), *f = XFRAME (frame);

  if ((!FRAME_TERMCAP_P (c) && !FRAME_TERMCAP_P (f)
       && FRAME_KBOARD (c) == FRAME_KBOARD (f))
      || (FRAME_TERMCAP_P (c) && FRAME_TERMCAP_P (f)
	  && FRAME_TTY (c) == FRAME_TTY (f)))
    {
      if (!NILP (get_frame_param (c, Qno_other_frame)))
	return Qnil;
      else if (NILP (minibuf))
	{
	  if (!FRAME_MINIBUF_ONLY_P (c))
	    return candidate;
	}
      else if (EQ (minibuf, Qvisible))
	{
	  if (FRAME_VISIBLE_P (c))
	    return candidate;
	}
      else if (WINDOWP (minibuf))
	{
	  if (EQ (FRAME_MINIBUF_WINDOW (c), minibuf)
	      || EQ (WINDOW_FRAME (XWINDOW (minibuf)), candidate)
	      || EQ (WINDOW_FRAME (XWINDOW (minibuf)),
		     FRAME_FOCUS_FRAME (c)))
	    return candidate;
	}
      else if (FIXNUMP (minibuf) && XFIXNUM (minibuf) == 0)
	{
	  if (FRAME_VISIBLE_P (c) || FRAME_ICONIFIED_P (c))
	    return candidate;
	}
      else
	return candidate;
    }
  return Qnil;
}

/* Return the next frame in the frame list after FRAME.  */

static Lisp_Object
next_frame (Lisp_Object frame, Lisp_Object minibuf)
{
  Lisp_Object f, tail, next = Qnil;
  bool passed = false;

  eassume (CONSP (Vframe_list));

  FOR_EACH_FRAME (tail, f)
    {
      if (EQ (f, frame))
	/* If we encounter FRAME, set PASSED to true.  */
	passed = true;
      else
	{
	  f = candidate_frame (f, frame, minibuf);

	  if (!NILP (f))
	    {
	      if (passed)
		/* If we passed FRAME already, return first suitable
		   candidate following it.  */
		return f;
	      else if (NILP (next))
		/* If we didn't pass FRAME and have no suitable
		   candidate yet, set NEXT to the first suitable
		   candidate preceding FRAME.  */
		next = f;
	    }
	}
    }

  /* We have scanned all frames.  Return first candidate preceding FRAME
     if we have found one.  Otherwise return FRAME regardless of whether
     it is a suitable candidate or not.  */
  return NILP (next) ? frame : next;
}

/* Return the previous frame in the frame list before FRAME.  */

static Lisp_Object
prev_frame (Lisp_Object frame, Lisp_Object minibuf)
{
  Lisp_Object f, tail, prev = Qnil;

  eassume (CONSP (Vframe_list));

  FOR_EACH_FRAME (tail, f)
    {
      if (EQ (frame, f) && !NILP (prev))
	/* If we encounter FRAME and already have found a suitable
	   candidate preceding it, return that candidate.  */
	return prev;

      f = candidate_frame (f, frame, minibuf);

      if (!NILP (f))
	/* PREV is always the last suitable candidate we found.  */
	prev = f;
    }

  /* We've scanned the entire list.  */
  if (NILP (prev))
    /* We went through the whole frame list without finding a single
       acceptable frame.  Return FRAME.  */
    return frame;
  else
    /* There were no acceptable frames in the list before FRAME;
       otherwise, we would have returned directly from the loop.  Since
       PREV is the last suitable frame in the list, return it.  */
    return prev;
}


DEFUN ("next-frame", Fnext_frame, Snext_frame, 0, 2, 0,
       doc: /* Return the next frame in the frame list after FRAME.
Only frames on the same terminal as FRAME are included in the list
of candidate frames.  FRAME defaults to the selected frame.

If MINIFRAME is nil (the default), include all frames except
minibuffer-only frames.

If MINIFRAME is a window, include only its own frame and any frame now
using that window as the minibuffer.

If MINIFRAME is `visible', include only visible frames.

If MINIFRAME is 0, include only visible and iconified frames.

If MINIFRAME is any other value, include all frames.

Return FRAME if no suitable next frame is found.  */)
  (Lisp_Object frame, Lisp_Object miniframe)
{
  if (NILP (frame))
    frame = selected_frame;
  CHECK_LIVE_FRAME (frame);
  return next_frame (frame, miniframe);
}

DEFUN ("previous-frame", Fprevious_frame, Sprevious_frame, 0, 2, 0,
       doc: /* Return the previous frame in the frame list before FRAME.
Only frames on the same terminal as FRAME are included in the list
of candidate frames.  FRAME defaults to the selected frame.

If MINIFRAME is nil (the default), include all frames except
minibuffer-only frames.

If MINIFRAME is a window, include only its own frame and any frame now
using that window as the minibuffer.

If MINIFRAME is `visible', include only visible frames.

If MINIFRAME is 0, include only visible and iconified frames.

If MINIFRAME is any other value, include all frames.

Return FRAME if no suitable previous frame is found.  */)
  (Lisp_Object frame, Lisp_Object miniframe)
{
  if (NILP (frame))
    frame = selected_frame;
  CHECK_LIVE_FRAME (frame);
  return prev_frame (frame, miniframe);
}

DEFUN ("last-nonminibuffer-frame", Flast_nonminibuf_frame,
       Slast_nonminibuf_frame, 0, 0, 0,
       doc: /* Return last non-minibuffer frame selected. */)
  (void)
{
  Lisp_Object frame = Qnil;

  if (last_nonminibuf_frame)
    XSETFRAME (frame, last_nonminibuf_frame);

  return frame;
}

/**
 * other_frames:
 *
 * Return true if there exists at least one visible or iconified frame
 * but F.  Tooltip and child frames do not qualify as candidates.
 * Return false if no such frame exists.
 *
 * INVISIBLE true means we are called from make_frame_invisible where
 * such a frame must be visible or iconified.  INVISIBLE nil means we
 * are called from delete_frame.  In that case FORCE true means that the
 * visibility status of such a frame can be ignored.
 *
 * If F is the terminal frame and we are using X, return true if at
 * least one X frame exists.
 */
static bool
other_frames (struct frame *f, bool invisible, bool force)
{
  Lisp_Object frames, frame, frame1;
  Lisp_Object minibuffer_window = FRAME_MINIBUF_WINDOW (f);

  XSETFRAME (frame, f);
  if (WINDOWP (minibuffer_window)
      && !EQ (frame, WINDOW_FRAME (XWINDOW (minibuffer_window))))
    minibuffer_window = Qnil;

  FOR_EACH_FRAME (frames, frame1)
    {
      struct frame *f1 = XFRAME (frame1);

      if (f != f1)
	{
	  /* The following code is defined out because it is
	     responsible for a performance drop under X connections
	     over a network, and its purpose is unclear.  XSync does
	     not handle events (or call any callbacks defined by
	     Emacs), and as such it should not note any "recent change
	     in visibility".

	     When writing new code, please try as hard as possible to
	     avoid calls that require a roundtrip to the X server.
	     When such calls are inevitable, use the XCB library to
	     handle multiple consecutive requests with a data reply in
	     a more asynchronous fashion.  The following code
	     demonstrates why:

	       rc = XGetWindowProperty (dpyinfo->display, window, ...
	       status = XGrabKeyboard (dpyinfo->display, ...

	     here, `XGetWindowProperty' will wait for a reply from the
	     X server before returning, and thus allowing Emacs to
	     make the XGrabKeyboard request, which in itself also
	     requires waiting a reply.  When XCB is available, this
	     code could be written:

#ifdef HAVE_XCB
	       xcb_get_property_cookie_t cookie1;
	       xcb_get_property_reply_t *reply1;
	       xcb_grab_keyboard_cookie_t cookie2;
	       xcb_grab_keyboard_reply_t *reply2;

	       cookie1 = xcb_get_property (dpyinfo->xcb_connection, window, ...
	       cookie2 = xcb_grab_keyboard (dpyinfo->xcb_connection, ...
	       reply1 = xcb_get_property_reply (dpyinfo->xcb_connection,
						cookie1);
	       reply2 = xcb_grab_keyboard_reply (dpyinfo->xcb_connection,
						cookie2);
#endif

	     In this code, the GetProperty and GrabKeyboard requests
	     are made simultaneously, and replies are then obtained
	     from the server at once, avoiding the extraneous
	     roundtrip to the X server after the call to
	     `XGetWindowProperty'.

	     However, please keep an alternative implementation
	     available for use when Emacs is built without XCB.  */

#if 0
	  /* Verify that we can still talk to the frame's X window, and
	     note any recent change in visibility.  */
#ifdef HAVE_X_WINDOWS
	  if (FRAME_WINDOW_P (f1))
	    x_sync (f1);
#endif
#endif

	  if (!FRAME_TOOLTIP_P (f1)
	      /* Tooltips and child frames count neither for
		 invisibility nor for deletions.  */
	      && !FRAME_PARENT_FRAME (f1)
	      /* Frames with a non-nil `delete-before' parameter don't
		 count for deletions.  */
	      && (invisible || NILP (get_frame_param (f1, Qdelete_before)))
	      /* For invisibility and normal deletions, at least one
		 visible or iconified frame must remain (Bug#26682).  */
	      && (FRAME_VISIBLE_P (f1)
		  || FRAME_ICONIFIED_P (f1)
		  || (!invisible
		      && (force
			  /* Allow deleting the terminal frame when at
			     least one X frame exists.  */
			  || (FRAME_WINDOW_P (f1) && !FRAME_WINDOW_P (f))))))
	    return true;
	}
    }

  return false;
}

/**
 * delete_frame:
 *
 * Delete FRAME.  When FORCE equals Qnoelisp, delete FRAME
 * unconditionally.  x_connection_closed and delete_terminal use this.
 * Any other value of FORCE implements the semantics described for
 * Fdelete_frame.  */
Lisp_Object
delete_frame (Lisp_Object frame, Lisp_Object force)
{
  struct frame *f = decode_any_frame (frame);
  struct frame *sf;
  struct kboard *kb;
  Lisp_Object frames, frame1;
  int is_tooltip_frame;
  bool nochild = !FRAME_PARENT_FRAME (f);
  Lisp_Object minibuffer_child_frame = Qnil;
#ifdef HAVE_X_WINDOWS
  specpdl_ref ref;
#endif

  if (!FRAME_LIVE_P (f))
    return Qnil;
  else if (!EQ (force, Qnoelisp) && !other_frames (f, false, !NILP (force)))
    {
      if (NILP (force))
	error ("Attempt to delete the sole visible or iconified frame");
      else
	error ("Attempt to delete the only frame");
    }
  else if (IS_DAEMON && FRAME_INITIAL_P (f) && NILP (force))
    error ("Attempt to delete daemon's initial frame");
#ifdef HAVE_X_WINDOWS
  else if ((x_dnd_in_progress && f == x_dnd_frame)
	   || (x_dnd_waiting_for_finish && f == x_dnd_finish_frame))
    error ("Attempt to delete the drop source frame");
#endif
#ifdef HAVE_HAIKU
  else if (f == haiku_dnd_frame)
    error ("Attempt to delete the drop source frame");
#endif

  XSETFRAME (frame, f);

  if (is_tty_frame (f) && NILP (force))
    /* If F is a tty frame, check for surrogate minibuffer frames F
       subsumes used by a frame that is not subsumed by F. */
    FOR_EACH_FRAME (frames, frame1)
      {
	struct frame *f1 = XFRAME (frame1);

	if (frame_subsumes_p (f, WINDOW_XFRAME (XWINDOW (f1->minibuffer_window)))
	    && !frame_subsumes_p (f, f1))
	  error ("Cannot delete surrogate minibuffer frame");
      }

  /* Softly delete all frames with this frame as their parent frame or
     as their `delete-before' frame parameter value.  */
  FOR_EACH_FRAME (frames, frame1)
    {
      struct frame *f1 = XFRAME (frame1);

      if (EQ (frame1, frame) || FRAME_TOOLTIP_P (f1))
	continue;
      else if (FRAME_PARENT_FRAME (f1) == f)
	{
	  if (FRAME_HAS_MINIBUF_P (f1) && !FRAME_HAS_MINIBUF_P (f)
	      && EQ (FRAME_MINIBUF_WINDOW (f), FRAME_MINIBUF_WINDOW (f1)))
	    /* frame1 owns frame's minibuffer window so we must not
	       delete it here to avoid a surrogate minibuffer error.
	       Unparent frame1 and make it a top-level frame.  */
	    {
	      Fmodify_frame_parameters
		(frame1, Fcons (Fcons (Qparent_frame, Qnil), Qnil));
	      minibuffer_child_frame = frame1;
	    }
	  else
	    delete_frame (frame1, Qnil);
	}
      else if (nochild
	       && EQ (get_frame_param (XFRAME (frame1), Qdelete_before), frame))
	/* Process `delete-before' parameter iff FRAME is not a child
	   frame.  This avoids that we enter an infinite chain of mixed
	   dependencies.  */
	delete_frame (frame1, Qnil);
    }

  /* Does this frame have a minibuffer, and is it the surrogate
     minibuffer for any other frame?  */
  if (FRAME_HAS_MINIBUF_P (f))
    {
      FOR_EACH_FRAME (frames, frame1)
	{
	  Lisp_Object fminiw;

	  if (EQ (frame1, frame))
	    continue;

	  fminiw = FRAME_MINIBUF_WINDOW (XFRAME (frame1));

	  if (WINDOWP (fminiw) && EQ (frame, WINDOW_FRAME (XWINDOW (fminiw))))
	    {
	      /* If we MUST delete this frame, delete the other first.
		 But do this only if FORCE equals `noelisp'.  */
	      if (EQ (force, Qnoelisp))
		delete_frame (frame1, Qnoelisp);
	      else
		error ("Attempt to delete a surrogate minibuffer frame");
	    }
	}
    }

  is_tooltip_frame = FRAME_TOOLTIP_P (f);

  /* Run `delete-frame-functions' unless FORCE is `noelisp' or
     frame is a tooltip.  FORCE is set to `noelisp' when handling
     a disconnect from the terminal, so we don't dare call Lisp
     code.  */
  if (NILP (Vrun_hooks) || is_tooltip_frame)
    ;
  else if (EQ (force, Qnoelisp))
    pending_funcalls
      = Fcons (list3 (Qrun_hook_with_args, Qdelete_frame_functions, frame),
	       pending_funcalls);
  else
    {
#ifdef HAVE_X_WINDOWS
      /* Also, save clipboard to the clipboard manager.  */
      x_clipboard_manager_save_frame (frame);
#endif

      safe_calln (Qrun_hook_with_args, Qdelete_frame_functions, frame);
    }

  /* delete_frame_functions may have deleted any frame, including this
     one.  */
  if (!FRAME_LIVE_P (f))
    return Qnil;
  else if (!EQ (force, Qnoelisp) && !other_frames (f, false, !NILP (force)))
    {
      if (NILP (force))
	error ("Attempt to delete the sole visible or iconified frame");
      else
	error ("Attempt to delete the only frame");
    }

  /* At this point, we are committed to deleting the frame.
     There is no more chance for errors to prevent it.  */
  sf = SELECTED_FRAME ();
  /* Don't let the frame remain selected.  */
  if (f == sf)
    {
      if (is_tty_child_frame (f))
	/* If F is a child frame on a tty and is the selected frame, try
	   to re-select the frame that was selected before F.  */
	do_switch_frame (mru_rooted_frame (f), 0, 1, Qnil);
      else
	{
	  Lisp_Object tail;
	  eassume (CONSP (Vframe_list));

	  /* Look for another visible frame on the same terminal.
	     Do not call next_frame here because it may loop forever.
	     See https://debbugs.gnu.org/cgi/bugreport.cgi?bug=15025.  */
	  FOR_EACH_FRAME (tail, frame1)
	    {
	      struct frame *f1 = XFRAME (frame1);

	      if (!EQ (frame, frame1)
		  && !FRAME_TOOLTIP_P (f1)
		  && FRAME_TERMINAL (f) == FRAME_TERMINAL (f1)
		  && FRAME_VISIBLE_P (f1))
		break;
	    }

	  /* If there is none, find *some* other frame.  */
	  if (NILP (frame1) || EQ (frame1, frame))
	    {
	      FOR_EACH_FRAME (tail, frame1)
		{
		  struct frame *f1 = XFRAME (frame1);

		  if (!EQ (frame, frame1)
		      && FRAME_LIVE_P (f1)
		      && !FRAME_TOOLTIP_P (f1))
		    {
		      if (FRAME_TERMCAP_P (f1) || FRAME_MSDOS_P (f1))
			{
			  Lisp_Object top_frame = FRAME_TTY (f1)->top_frame;

			  if (!EQ (top_frame, frame))
			    frame1 = top_frame;
			}
		      break;
		    }
		}
	    }
#ifdef NS_IMPL_COCOA
	  else
	    {
	      /* Under NS, there is no system mechanism for choosing a new
		 window to get focus -- it is left to application code.
		 So the portion of THIS application interfacing with NS
		 needs to make the frame we switch to the key window.  */
	      struct frame *f1 = XFRAME (frame1);
	      if (FRAME_NS_P (f1))
		ns_make_frame_key_window (f1);
	    }
#endif

	  do_switch_frame (frame1, 0, 1, Qnil);
	  sf = SELECTED_FRAME ();
	}
    }
  else
    /* Ensure any minibuffers on FRAME are moved onto the selected
       frame.  */
    move_minibuffers_onto_frame (f, selected_frame, true);

  /* Don't let echo_area_window to remain on a deleted frame.  */
  if (EQ (f->minibuffer_window, echo_area_window))
    echo_area_window = sf->minibuffer_window;

  /* Clear any X selections for this frame.  */
#ifdef HAVE_X_WINDOWS
  if (FRAME_X_P (f))
    {
      /* Don't preserve selections when a display is going away, since
	 that sends stuff down the wire.  */

      ref = SPECPDL_INDEX ();

      if (EQ (force, Qnoelisp))
	specbind (Qx_auto_preserve_selections, Qnil);

      x_clear_frame_selections (f);
      unbind_to (ref, Qnil);
    }
#endif

#ifdef HAVE_PGTK
  if (FRAME_PGTK_P (f))
    {
      /* Do special selection events now, in case the window gets
	 destroyed by this deletion.  Does this run Lisp code?  */
      swallow_events (false);

      pgtk_clear_frame_selections (f);
    }
#endif

  /* Free glyphs.
     This function must be called before the window tree of the
     frame is deleted because windows contain dynamically allocated
     memory. */
  free_glyphs (f);

#ifdef HAVE_WINDOW_SYSTEM
  /* Give chance to each font driver to free a frame specific data.  */
  font_update_drivers (f, Qnil);
#endif

  /* Mark all the windows that used to be on FRAME as deleted, and then
     remove the reference to them.  */
  delete_all_child_windows (f->root_window);
  fset_root_window (f, Qnil);

  block_input ();
  Vframe_list = Fdelq (frame, Vframe_list);
  unblock_input ();
  SET_FRAME_VISIBLE (f, false);

  /* Allow the vector of menu bar contents to be freed in the next
     garbage collection.  The frame object itself may not be garbage
     collected until much later, because recent_keys and other data
     structures can still refer to it.  */
  fset_menu_bar_vector (f, Qnil);

  /* If FRAME's buffer lists contains killed
     buffers, this helps GC to reclaim them.  */
  fset_buffer_list (f, Qnil);
  fset_buried_buffer_list (f, Qnil);

  free_font_driver_list (f);
#if defined (USE_X_TOOLKIT) || defined (HAVE_NTGUI)
  xfree (f->namebuf);
#endif
  xfree (f->decode_mode_spec_buffer);
  xfree (FRAME_INSERT_COST (f));
  xfree (FRAME_DELETEN_COST (f));
  xfree (FRAME_INSERTN_COST (f));
  xfree (FRAME_DELETE_COST (f));

  /* Since some events are handled at the interrupt level, we may get
     an event for f at any time; if we zero out the frame's terminal
     now, then we may trip up the event-handling code.  Instead, we'll
     promise that the terminal of the frame must be valid until we
     have called the window-system-dependent frame destruction
     routine.  */
  {
    struct terminal *terminal;
    block_input ();
    if (FRAME_TERMINAL (f)->delete_frame_hook)
      (*FRAME_TERMINAL (f)->delete_frame_hook) (f);
    terminal = FRAME_TERMINAL (f);
    f->terminal = 0;             /* Now the frame is dead.  */
    unblock_input ();

    /* Clear markers and overlays set by F on behalf of an input
       method.  */
#ifdef HAVE_TEXT_CONVERSION
    if (FRAME_WINDOW_P (f))
      reset_frame_state (f);
#endif

    /* If needed, delete the terminal that this frame was on.
       (This must be done after the frame is killed.)  */
    terminal->reference_count--;
#if defined (USE_X_TOOLKIT) || defined (USE_GTK)
    /* FIXME: Deleting the terminal crashes emacs because of a GTK
       bug.
       https://lists.gnu.org/r/emacs-devel/2011-10/msg00363.html */

    /* Since a similar behavior was observed on the Lucid and Motif
       builds (see Bug#5802, Bug#21509, Bug#23499, Bug#27816), we now
       don't delete the terminal for these builds either.  */
    if (terminal->reference_count == 0
	&& (terminal->type == output_x_window
	    || terminal->type == output_pgtk))
      terminal->reference_count = 1;
#endif /* USE_X_TOOLKIT || USE_GTK */

    if (terminal->reference_count == 0)
      {
	Lisp_Object tmp;
	XSETTERMINAL (tmp, terminal);

        kb = NULL;

	/* If force is noelisp, the terminal is going away inside
	   x_delete_terminal, and a recursive call to Fdelete_terminal
	   is unsafe!  */
	if (!EQ (force, Qnoelisp))
	  Fdelete_terminal (tmp, NILP (force) ? Qt : force);
      }
    else
      kb = terminal->kboard;
  }

  /* If we've deleted the last_nonminibuf_frame, then try to find
     another one.  */
  if (f == last_nonminibuf_frame)
    {
      last_nonminibuf_frame = 0;

      FOR_EACH_FRAME (frames, frame1)
	{
	  struct frame *f1 = XFRAME (frame1);

	  if (!FRAME_MINIBUF_ONLY_P (f1))
	    {
	      last_nonminibuf_frame = f1;
	      break;
	    }
	}
    }

  /* If there's no other frame on the same kboard, get out of
     single-kboard state if we're in it for this kboard.  */
  if (kb != NULL)
    {
      /* Some frame we found on the same kboard, or nil if there are none.  */
      Lisp_Object frame_on_same_kboard = Qnil;

      FOR_EACH_FRAME (frames, frame1)
	if (kb == FRAME_KBOARD (XFRAME (frame1)))
	  frame_on_same_kboard = frame1;

      if (NILP (frame_on_same_kboard))
	not_single_kboard_state (kb);
    }


  /* If we've deleted this keyboard's default_minibuffer_frame, try to
     find another one.  Prefer minibuffer-only frames, but also notice
     frames with other windows.  */
  if (kb != NULL && EQ (frame, KVAR (kb, Vdefault_minibuffer_frame)))
    {
      /* The last frame we saw with a minibuffer, minibuffer-only or not.  */
      Lisp_Object frame_with_minibuf = Qnil;
      /* Some frame we found on the same kboard, or nil if there are none.  */
      Lisp_Object frame_on_same_kboard = Qnil;

      FOR_EACH_FRAME (frames, frame1)
	{
	  struct frame *f1 = XFRAME (frame1);

	  /* Set frame_on_same_kboard to frame1 if it is on the same
	     keyboard and is not a tooltip frame.  Set
	     frame_with_minibuf to frame1 if it also has a minibuffer.
	     Leave the loop immediately if frame1 is also
	     minibuffer-only.

	     Emacs 26 did _not_ set frame_on_same_kboard here when it
	     found a minibuffer-only frame, and subsequently failed to
	     set default_minibuffer_frame below.  Not a great deal and
	     never noticed since make_frame_without_minibuffer created a
	     new minibuffer frame in that case (which can be a minor
	     annoyance though).  */
	  if (!FRAME_TOOLTIP_P (f1)
	      && kb == FRAME_KBOARD (f1))
	    {
	      frame_on_same_kboard = frame1;
	      if (FRAME_HAS_MINIBUF_P (f1))
		{
		  frame_with_minibuf = frame1;
		  if (FRAME_MINIBUF_ONLY_P (f1))
		    break;
		}
	    }
	}

      if (!NILP (frame_on_same_kboard))
	{
	  /* We know that there must be some frame with a minibuffer out
	     there.  If this were not true, all of the frames present
	     would have to be minibufferless, which implies that at some
	     point their minibuffer frames must have been deleted, but
	     that is prohibited at the top; you can't delete surrogate
	     minibuffer frames.  */
	  if (NILP (frame_with_minibuf))
	    emacs_abort ();

	  kset_default_minibuffer_frame (kb, frame_with_minibuf);
	}
      else
	/* No frames left on this kboard--say no minibuffer either.  */
	kset_default_minibuffer_frame (kb, Qnil);
    }

  /* Cause frame titles to update--necessary if we now have just one
     frame.  */
  if (!is_tooltip_frame)
    update_mode_lines = 15;

  /* Now run the post-deletion hooks.  */
  if (NILP (Vrun_hooks) || is_tooltip_frame)
    ;
  else if (EQ (force, Qnoelisp))
    pending_funcalls
      = Fcons (list3 (Qrun_hook_with_args, Qafter_delete_frame_functions, frame),
	       pending_funcalls);
  else
    safe_calln (Qrun_hook_with_args, Qafter_delete_frame_functions, frame);

  if (!NILP (minibuffer_child_frame))
    /* If minibuffer_child_frame is non-nil, it was FRAME's minibuffer
       child frame.  Delete it unless it's also the minibuffer frame
       of another frame in which case we make sure it's visible.  */
    {
      struct frame *f1 = XFRAME (minibuffer_child_frame);

      if (FRAME_LIVE_P (f1))
	{
	  Lisp_Object window1 = FRAME_ROOT_WINDOW (f1);
	  Lisp_Object frame2;

	  FOR_EACH_FRAME (frames, frame2)
	    {
	      struct frame *f2 = XFRAME (frame2);

	      if (EQ (frame2, minibuffer_child_frame) || FRAME_TOOLTIP_P (f2))
		continue;
	      else if (EQ (FRAME_MINIBUF_WINDOW (f2), window1))
		{
		  /* minibuffer_child_frame serves as minibuffer frame
		     for at least one other frame - so make it visible
		     and quit.  */
		  if (!FRAME_VISIBLE_P (f1) && !FRAME_ICONIFIED_P (f1))
		    Fmake_frame_visible (minibuffer_child_frame);

		  return Qnil;
		}
	    }

	  /* No other frame found that uses minibuffer_child_frame as
	     minibuffer frame.  If FORCE is Qnoelisp or there are
	     other visible frames left, delete minibuffer_child_frame
	     since it presumably was used by FRAME only.  */
	  if (EQ (force, Qnoelisp) || other_frames (f1, false, !NILP (force)))
	    delete_frame (minibuffer_child_frame, Qnoelisp);
	}
    }

  return Qnil;
}

DEFUN ("delete-frame", Fdelete_frame, Sdelete_frame, 0, 2, "",
       doc: /* Delete FRAME, eliminating it from use.
FRAME must be a live frame and defaults to the selected one.

When `undelete-frame-mode' is enabled, the 16 most recently deleted
frames can be undeleted with `undelete-frame', which see.

Do not delete a frame whose minibuffer serves as surrogate minibuffer
for another frame.  Do not delete a frame if all other frames are
invisible unless the second optional argument FORCE is non-nil.  Do not
delete the initial terminal frame of an Emacs process running as daemon
unless FORCE is non-nil.

This function runs `delete-frame-functions' before actually
deleting the frame, unless the frame is a tooltip.
The functions are run with one argument, the frame to be deleted.  */)
  (Lisp_Object frame, Lisp_Object force)
{
  return delete_frame (frame, !NILP (force) ? Qt : Qnil);
}


/**
 * frame_internal_border_part:
 *
 * Return part of internal border the coordinates X and Y relative to
 * frame F are on.  Return nil if the coordinates are not on the
 * internal border of F.
 *
 * Return one of INTERNAL_BORDER_LEFT_EDGE, INTERNAL_BORDER_TOP_EDGE,
 * INTERNAL_BORDER_RIGHT_EDGE or INTERNAL_BORDER_BOTTOM_EDGE when the
 * mouse cursor is on the corresponding border with an offset of at
 * least one canonical character height from that border's edges.
 *
 * If no border part could be found this way, return one of
 * INTERNAL_BORDER_TOP_LEFT_CORNER, INTERNAL_BORDER_TOP_RIGHT_CORNER,
 * INTERNAL_BORDER_BOTTOM_LEFT_CORNER or
 * INTERNAL_BORDER_BOTTOM_RIGHT_CORNER to indicate that the mouse is in
 * one of the corresponding corners.  This means that for very small
 * frames an `edge' return value is preferred.
 */
enum internal_border_part
frame_internal_border_part (struct frame *f, int x, int y)
{
  int border = (FRAME_INTERNAL_BORDER_WIDTH (f)
		? FRAME_INTERNAL_BORDER_WIDTH (f)
		: (is_tty_child_frame (f) && !FRAME_UNDECORATED (f))
		? 1
		: 0);
  int offset = FRAME_LINE_HEIGHT (f);
  int width = FRAME_PIXEL_WIDTH (f);
  int height = FRAME_PIXEL_HEIGHT (f);
  enum internal_border_part part = INTERNAL_BORDER_NONE;

  if (offset < border)
    /* For very wide borders make offset at least as large as
       border.  */
    offset = border;

  if (offset < x && x < width - offset)
    /* Top or bottom border.  */
    {
      if (0 <= y && y <= border)
	part = INTERNAL_BORDER_TOP_EDGE;
      else if (height - border <= y && y <= height)
	part = INTERNAL_BORDER_BOTTOM_EDGE;
    }
  else if (offset < y && y < height - offset)
    /* Left or right border.  */
    {
      if (0 <= x && x <= border)
	part = INTERNAL_BORDER_LEFT_EDGE;
      else if (width - border <= x && x <= width)
	part = INTERNAL_BORDER_RIGHT_EDGE;
    }
  else
    {
      /* An edge.  */
      int half_width = width / 2;
      int half_height = height / 2;

      if (0 <= x && x <= border)
	{
	  /* A left edge.  */
	  if (0 <= y && y <= half_height)
	     part = INTERNAL_BORDER_TOP_LEFT_CORNER;
	  else if (half_height < y && y <= height)
	     part = INTERNAL_BORDER_BOTTOM_LEFT_CORNER;
	}
      else if (width - border <= x && x <= width)
	{
	  /* A right edge.  */
	  if (0 <= y && y <= half_height)
	     part = INTERNAL_BORDER_TOP_RIGHT_CORNER;
	  else if (half_height < y && y <= height)
	     part = INTERNAL_BORDER_BOTTOM_RIGHT_CORNER;
	}
      else if (0 <= y && y <= border)
	{
	  /* A top edge.  */
	  if (0 <= x && x <= half_width)
	     part = INTERNAL_BORDER_TOP_LEFT_CORNER;
	  else if (half_width < x && x <= width)
	    part = INTERNAL_BORDER_TOP_RIGHT_CORNER;
	}
      else if (height - border <= y && y <= height)
	{
	  /* A bottom edge.  */
	  if (0 <= x && x <= half_width)
	     part = INTERNAL_BORDER_BOTTOM_LEFT_CORNER;
	  else if (half_width < x && x <= width)
	    part = INTERNAL_BORDER_BOTTOM_RIGHT_CORNER;
	}
    }

  return part;
}


/* Return mouse position in character cell units.  */

DEFUN ("mouse-position", Fmouse_position, Smouse_position, 0, 0, 0,
       doc: /* Return a list (FRAME X . Y) giving the current mouse frame and position.
The position is given in canonical character cells, where (0, 0) is the
upper-left corner of the frame, X is the horizontal offset, and Y is the
vertical offset, measured in units of the frame's default character size.
If Emacs is running on a mouseless terminal or hasn't been programmed
to read the mouse position, it returns the selected frame for FRAME
and nil for X and Y.

FRAME might be nil if `track-mouse' is set to `drag-source'.  This
means there is no frame under the mouse.  If `mouse-position-function'
is non-nil, `mouse-position' calls it, passing the normal return value
to that function as an argument, and returns whatever that function
returns.  */)
  (void)
{
  return mouse_position (true);
}

Lisp_Object
mouse_position (bool call_mouse_position_function)
{
  struct frame *f;
  Lisp_Object lispy_dummy;
  Lisp_Object x, y, retval;

  f = SELECTED_FRAME ();
  x = y = Qnil;

  /* It's okay for the hook to refrain from storing anything.  */
  if (FRAME_TERMINAL (f)->mouse_position_hook)
    {
      enum scroll_bar_part party_dummy;
      Time time_dummy;
      (*FRAME_TERMINAL (f)->mouse_position_hook) (&f, -1,
						  &lispy_dummy, &party_dummy,
						  &x, &y,
						  &time_dummy);
    }

  if (! NILP (x) && f)
    {
      int col = XFIXNUM (x);
      int row = XFIXNUM (y);
      pixel_to_glyph_coords (f, col, row, &col, &row, NULL, 1);
      XSETINT (x, col);
      XSETINT (y, row);
    }
  if (f)
    XSETFRAME (lispy_dummy, f);
  else
    lispy_dummy = Qnil;
  retval = Fcons (lispy_dummy, Fcons (x, y));
  if (call_mouse_position_function && !NILP (Vmouse_position_function))
    retval = calln (Vmouse_position_function, retval);
  return retval;
}

DEFUN ("mouse-pixel-position", Fmouse_pixel_position,
       Smouse_pixel_position, 0, 0, 0,
       doc: /* Return a list (FRAME X . Y) giving the current mouse frame and position.
The position is given in pixel units, where (0, 0) is the
upper-left corner of the frame, X is the horizontal offset, and Y is
the vertical offset.
FRAME might be nil if `track-mouse' is set to `drag-source'.  This
means there is no frame under the mouse.  If Emacs is running on a
mouseless terminal or hasn't been programmed to read the mouse
position, it returns the selected frame for FRAME and nil for X and
Y.  */)
  (void)
{
  struct frame *f;
  Lisp_Object lispy_dummy;
  Lisp_Object x, y, retval;

  f = SELECTED_FRAME ();
  x = y = Qnil;

  /* It's okay for the hook to refrain from storing anything.  */
  if (FRAME_TERMINAL (f)->mouse_position_hook)
    {
      enum scroll_bar_part party_dummy;
      Time time_dummy;
      (*FRAME_TERMINAL (f)->mouse_position_hook) (&f, -1,
						  &lispy_dummy, &party_dummy,
						  &x, &y,
						  &time_dummy);
    }

  if (f)
    XSETFRAME (lispy_dummy, f);
  else
    lispy_dummy = Qnil;

  retval = Fcons (lispy_dummy, Fcons (x, y));
  if (!NILP (Vmouse_position_function))
    retval = calln (Vmouse_position_function, retval);
  return retval;
}

#ifdef HAVE_WINDOW_SYSTEM

/* On frame F, convert character coordinates X and Y to pixel
   coordinates *PIX_X and *PIX_Y.  */

static void
frame_char_to_pixel_position (struct frame *f, int x, int y,
			      int *pix_x, int *pix_y)
{
  *pix_x = FRAME_COL_TO_PIXEL_X (f, x) + FRAME_COLUMN_WIDTH (f) / 2;
  *pix_y = FRAME_LINE_TO_PIXEL_Y (f, y) + FRAME_LINE_HEIGHT (f) / 2;

  if (*pix_x < 0)
    *pix_x = 0;
  if (*pix_x > FRAME_PIXEL_WIDTH (f))
    *pix_x = FRAME_PIXEL_WIDTH (f);

  if (*pix_y < 0)
    *pix_y = 0;
  if (*pix_y > FRAME_PIXEL_HEIGHT (f))
    *pix_y = FRAME_PIXEL_HEIGHT (f);
}

/* On frame F, reposition mouse pointer to character coordinates X and Y.  */

static void
frame_set_mouse_position (struct frame *f, int x, int y)
{
  int pix_x, pix_y;

  frame_char_to_pixel_position (f, x, y, &pix_x, &pix_y);
  frame_set_mouse_pixel_position (f, pix_x, pix_y);
}

#endif /* HAVE_WINDOW_SYSTEM */

DEFUN ("set-mouse-position", Fset_mouse_position, Sset_mouse_position, 3, 3, 0,
       doc: /* Move the mouse pointer to the center of character cell (X,Y) in FRAME.
Coordinates are relative to the frame, not a window,
so the coordinates of the top left character in the frame
may be nonzero due to left-hand scroll bars or the menu bar.

The position is given in canonical character cells, where (0, 0) is
the upper-left corner of the frame, X is the horizontal offset, and
Y is the vertical offset, measured in units of the frame's default
character size.

This function is a no-op for an X frame that is not visible.
If you have just created a frame, you must wait for it to become visible
before calling this function on it, like this.
  (while (not (frame-visible-p frame)) (sleep-for .5))  */)
  (Lisp_Object frame, Lisp_Object x, Lisp_Object y)
{
  CHECK_LIVE_FRAME (frame);
  int xval = check_integer_range (x, INT_MIN, INT_MAX);
  int yval = check_integer_range (y, INT_MIN, INT_MAX);

  /* I think this should be done with a hook.  */
  if (FRAME_WINDOW_P (XFRAME (frame)))
    {
#ifdef HAVE_WINDOW_SYSTEM
      /* Warping the mouse will cause enternotify and focus events.  */
      frame_set_mouse_position (XFRAME (frame), xval, yval);
#endif /* HAVE_WINDOW_SYSTEM */
    }
#ifdef MSDOS
  else if (FRAME_MSDOS_P (XFRAME (frame)))
    {
      Fselect_frame (frame, Qnil);
      mouse_moveto (xval, yval);
    }
#endif /* MSDOS */
  else
    {
      Fselect_frame (frame, Qnil);
#ifdef HAVE_GPM
      term_mouse_moveto (xval, yval);
#else
      (void) xval;
      (void) yval;
#endif /* HAVE_GPM */
    }

  return Qnil;
}

DEFUN ("set-mouse-pixel-position", Fset_mouse_pixel_position,
       Sset_mouse_pixel_position, 3, 3, 0,
       doc: /* Move the mouse pointer to pixel position (X,Y) in FRAME.
The position is given in pixels, where (0, 0) is the upper-left corner
of the frame, X is the horizontal offset, and Y is the vertical offset.

Note, this is a no-op for an X frame that is not visible.
If you have just created a frame, you must wait for it to become visible
before calling this function on it, like this.
  (while (not (frame-visible-p frame)) (sleep-for .5))  */)
  (Lisp_Object frame, Lisp_Object x, Lisp_Object y)
{
  CHECK_LIVE_FRAME (frame);
  int xval = check_integer_range (x, INT_MIN, INT_MAX);
  int yval = check_integer_range (y, INT_MIN, INT_MAX);

  /* I think this should be done with a hook.  */
  if (FRAME_WINDOW_P (XFRAME (frame)))
    {
      /* Warping the mouse will cause enternotify and focus events.  */
#ifdef HAVE_WINDOW_SYSTEM
      frame_set_mouse_pixel_position (XFRAME (frame), xval, yval);
#endif /* HAVE_WINDOW_SYSTEM */
    }
#ifdef MSDOS
  else if (FRAME_MSDOS_P (XFRAME (frame)))
    {
      Fselect_frame (frame, Qnil);
      mouse_moveto (xval, yval);
    }
#endif /* MSDOS */
  else
    {
      Fselect_frame (frame, Qnil);
#ifdef HAVE_GPM
      term_mouse_moveto (xval, yval);
#else
      (void) xval;
      (void) yval;
#endif /* HAVE_GPM */

    }

  return Qnil;
}

static void make_frame_visible_1 (Lisp_Object);

DEFUN ("make-frame-visible", Fmake_frame_visible, Smake_frame_visible,
       0, 1, "",
       doc: /* Make the frame FRAME visible (assuming it is an X window).
If omitted, FRAME defaults to the currently selected frame.  */)
  (Lisp_Object frame)
{
  struct frame *f = decode_live_frame (frame);

  if (FRAME_WINDOW_P (f) && FRAME_TERMINAL (f)->frame_visible_invisible_hook)
    FRAME_TERMINAL (f)->frame_visible_invisible_hook (f, true);

  if (is_tty_frame (f))
    {
      SET_FRAME_VISIBLE (f, true);
      tty_raise_lower_frame (f, true);
    }

  make_frame_visible_1 (f->root_window);

  /* Make menu bar update for the Buffers and Frames menus.  */
  /* windows_or_buffers_changed = 15; FIXME: Why?  */

  XSETFRAME (frame, f);
  return frame;
}

/* Update the display_time slot of the buffers shown in WINDOW
   and all its descendants.  */

static void
make_frame_visible_1 (Lisp_Object window)
{
  struct window *w;

  for (; !NILP (window); window = w->next)
    {
      w = XWINDOW (window);
      if (WINDOWP (w->contents))
	make_frame_visible_1 (w->contents);
      else
	bset_display_time (XBUFFER (w->contents), Fcurrent_time ());
    }
}

DEFUN ("make-frame-invisible", Fmake_frame_invisible, Smake_frame_invisible,
       0, 2, "",
       doc: /* Make the frame FRAME invisible.
If omitted, FRAME defaults to the currently selected frame.
On graphical displays, invisible frames are not updated and are
usually not displayed at all, even in a window system's \"taskbar\".

Normally you may not make FRAME invisible if all other frames are
invisible, but if the second optional argument FORCE is non-nil, you may
do so.

On a text terminal make FRAME invisible if and only FRAME is either a
child frame or another non-child frame can be found.  In the former
case, if FRAME is the selected frame, select the first visible ancestor
of FRAME instead.  In the latter case, if FRAME is the top frame of its
terminal, make another frame that terminal's top frame.  */)
  (Lisp_Object frame, Lisp_Object force)
{
  struct frame *f = decode_live_frame (frame);

  XSETFRAME (frame, f);

  if (NILP (force) && !other_frames (f, true, false))
    error ("Attempt to make invisible the sole visible or iconified frame");

  if (FRAME_WINDOW_P (f) && FRAME_TERMINAL (f)->frame_visible_invisible_hook)
    FRAME_TERMINAL (f)->frame_visible_invisible_hook (f, false);

  SET_FRAME_VISIBLE (f, false);

  if (is_tty_frame (f) && EQ (frame, selected_frame))
  /* On a tty if FRAME is the selected frame, we have to select another
    frame instead.  If FRAME is a child frame, use the first visible
    ancestor as returned by 'mru_rooted_frame'.  If FRAME is a root
    frame, use the frame returned by 'next-frame' which must exist since
    otherwise other_frames above would have lied.  */
    Fselect_frame (FRAME_PARENT_FRAME (f)
		   ? mru_rooted_frame (f)
		   : next_frame (frame, make_fixnum (0)),
		   Qnil);

  /* Make menu bar update for the Buffers and Frames menus.  */
  windows_or_buffers_changed = 16;

  return Qnil;
}

DEFUN ("iconify-frame", Ficonify_frame, Siconify_frame,
       0, 1, "",
       doc: /* Make the frame FRAME into an icon.
If omitted, FRAME defaults to the currently selected frame.

If FRAME is a child frame, consult the variable `iconify-child-frame'
for how to proceed.  */)
  (Lisp_Object frame)
{
  struct frame *f = decode_live_frame (frame);

  if (FRAME_PARENT_FRAME (f))
    {
      if (NILP (iconify_child_frame))
	/* Do nothing.  */
	return Qnil;
      else if (FRAME_WINDOW_P (f)
	       && EQ (iconify_child_frame, Qiconify_top_level))
	{
	  /* Iconify root frame (the default).  */
	  Lisp_Object root;

	  XSETFRAME (root, root_frame (f));
	  Ficonify_frame (root);

	  return Qnil;
	}
      else if (EQ (iconify_child_frame, Qmake_invisible))
	{
	  /* Make frame invisible.  */
	  Fmake_frame_invisible (frame, Qnil);

	  return Qnil;
	}
    }

  if (FRAME_WINDOW_P (f) && FRAME_TERMINAL (f)->iconify_frame_hook)
    FRAME_TERMINAL (f)->iconify_frame_hook (f);

  return Qnil;
}

DEFUN ("frame-visible-p", Fframe_visible_p, Sframe_visible_p,
       1, 1, 0,
       doc: /* Return t if FRAME is \"visible\" (actually in use for display).
Return the symbol `icon' if FRAME is iconified or \"minimized\".
Return nil if FRAME was made invisible, via `make-frame-invisible'.
On graphical displays, invisible frames are not updated and are
usually not displayed at all, even in a window system's \"taskbar\".  */)
  (Lisp_Object frame)
{
  CHECK_LIVE_FRAME (frame);
  struct frame *f = XFRAME (frame);

  if (FRAME_VISIBLE_P (f))
    return Qt;
  if (FRAME_ICONIFIED_P (f))
    return Qicon;
  return Qnil;
}

DEFUN ("visible-frame-list", Fvisible_frame_list, Svisible_frame_list,
       0, 0, 0,
       doc: /* Return a list of all frames now \"visible\" (being updated).  */)
  (void)
{
  Lisp_Object tail, frame, value = Qnil;

  FOR_EACH_FRAME (tail, frame)
    if (FRAME_VISIBLE_P (XFRAME (frame)))
      value = Fcons (frame, value);

  return value;
}


DEFUN ("raise-frame", Fraise_frame, Sraise_frame, 0, 1, "",
       doc: /* Bring FRAME to the front, so it occludes any frames it overlaps.
If FRAME is invisible or iconified, make it visible.
If you don't specify a frame, the selected frame is used.
If Emacs is displaying on an ordinary terminal or some other device which
doesn't support multiple overlapping frames, this function selects FRAME.  */)
  (Lisp_Object frame)
{
  struct frame *f = decode_live_frame (frame);

  XSETFRAME (frame, f);

  Fmake_frame_visible (frame);

  if (FRAME_TERMINAL (f)->frame_raise_lower_hook)
    (*FRAME_TERMINAL (f)->frame_raise_lower_hook) (f, true);

  return Qnil;
}

/* Should we have a corresponding function called Flower_Power?  */
DEFUN ("lower-frame", Flower_frame, Slower_frame, 0, 1, "",
       doc: /* Send FRAME to the back, so it is occluded by any frames that overlap it.
If you don't specify a frame, the selected frame is used.
If Emacs is displaying on an ordinary terminal or some other device which
doesn't support multiple overlapping frames, this function does nothing.  */)
  (Lisp_Object frame)
{
  struct frame *f = decode_live_frame (frame);

  if (FRAME_TERMINAL (f)->frame_raise_lower_hook)
    (*FRAME_TERMINAL (f)->frame_raise_lower_hook) (f, false);

  return Qnil;
}


DEFUN ("redirect-frame-focus", Fredirect_frame_focus, Sredirect_frame_focus,
       1, 2, 0,
       doc: /* Arrange for keystrokes typed at FRAME to be sent to FOCUS-FRAME.
In other words, switch-frame events caused by events in FRAME will
request a switch to FOCUS-FRAME, and `last-event-frame' will be
FOCUS-FRAME after reading an event typed at FRAME.

If FOCUS-FRAME is nil, any existing redirection is canceled, and the
frame again receives its own keystrokes.

Focus redirection is useful for temporarily redirecting keystrokes to
a surrogate minibuffer frame when a frame doesn't have its own
minibuffer window.

A frame's focus redirection can be changed by `select-frame'.  If frame
FOO is selected, and then a different frame BAR is selected, any
frames redirecting their focus to FOO are shifted to redirect their
focus to BAR.  This allows focus redirection to work properly when the
user switches from one frame to another using `select-window'.

This means that a frame whose focus is redirected to itself is treated
differently from a frame whose focus is redirected to nil; the former
is affected by `select-frame', while the latter is not.

The redirection lasts until `redirect-frame-focus' is called to change it.  */)
  (Lisp_Object frame, Lisp_Object focus_frame)
{
  /* Note that we don't check for a live frame here.  It's reasonable
     to redirect the focus of a frame you're about to delete, if you
     know what other frame should receive those keystrokes.  */
  struct frame *f = decode_any_frame (frame);

  if (! NILP (focus_frame))
    CHECK_LIVE_FRAME (focus_frame);

  fset_focus_frame (f, focus_frame);

  if (FRAME_TERMINAL (f)->frame_rehighlight_hook)
    (*FRAME_TERMINAL (f)->frame_rehighlight_hook) (f);

  return Qnil;
}


DEFUN ("frame-focus", Fframe_focus, Sframe_focus, 0, 1, 0,
       doc: /* Return the frame to which FRAME's keystrokes are currently being sent.
If FRAME is omitted or nil, the selected frame is used.
Return nil if FRAME's focus is not redirected.
See `redirect-frame-focus'.  */)
  (Lisp_Object frame)
{
  return FRAME_FOCUS_FRAME (decode_live_frame (frame));
}

DEFUN ("x-focus-frame", Fx_focus_frame, Sx_focus_frame, 1, 2, 0,
       doc: /* Set the input focus to FRAME.
FRAME nil means use the selected frame.  Optional argument NOACTIVATE
means do not activate FRAME.

If there is no window system support, this function does nothing.  */)
     (Lisp_Object frame, Lisp_Object noactivate)
{
#ifdef HAVE_WINDOW_SYSTEM
  struct frame *f = decode_window_system_frame (frame);
  if (f && FRAME_TERMINAL (f)->focus_frame_hook)
    FRAME_TERMINAL (f)->focus_frame_hook (f, !NILP (noactivate));
#endif
  return Qnil;
}

DEFUN ("frame-after-make-frame",
       Fframe_after_make_frame,
       Sframe_after_make_frame, 2, 2, 0,
       doc: /* Mark FRAME as made.
FRAME nil means use the selected frame.  Second argument MADE non-nil
means functions on `window-configuration-change-hook' are called
whenever the window configuration of FRAME changes.  MADE nil means
these functions are not called.

This function is currently called by `make-frame' only and should be
otherwise used with utter care to avoid that running functions on
`window-configuration-change-hook' is impeded forever.  */)
  (Lisp_Object frame, Lisp_Object made)
{
  struct frame *f = decode_live_frame (frame);
  f->after_make_frame = !NILP (made);
  return made;
}


/* Discard BUFFER from the buffer-list and buried-buffer-list of each frame.  */

void
frames_discard_buffer (Lisp_Object buffer)
{
  Lisp_Object frame, tail;

  FOR_EACH_FRAME (tail, frame)
    {
      fset_buffer_list
	(XFRAME (frame), Fdelq (buffer, XFRAME (frame)->buffer_list));
      fset_buried_buffer_list
	(XFRAME (frame), Fdelq (buffer, XFRAME (frame)->buried_buffer_list));
    }
}

/* Modify the alist in *ALISTPTR to associate PROP with VAL.
   If the alist already has an element for PROP, we change it.  */

void
store_in_alist (Lisp_Object *alistptr, Lisp_Object prop, Lisp_Object val)
{
  Lisp_Object tem = Fassq (prop, *alistptr);
  if (NILP (tem))
    *alistptr = Fcons (Fcons (prop, val), *alistptr);
  else
    Fsetcdr (tem, val);
}

static int
frame_name_fnn_p (char *str, ptrdiff_t len)
{
  if (len > 1 && str[0] == 'F' && '0' <= str[1] && str[1] <= '9')
    {
      char *p = str + 2;
      while ('0' <= *p && *p <= '9')
	p++;
      if (p == str + len)
	return 1;
    }
  return 0;
}

/* Set the name of the terminal frame.  Also used by MSDOS frames.
   Modeled after *_set_name which is used for WINDOW frames.  */

static void
set_term_frame_name (struct frame *f, Lisp_Object name)
{
  f->explicit_name = ! NILP (name);

  /* If NAME is nil, set the name to F<num>.  */
  if (NILP (name))
    {
      /* Check for no change needed in this very common case
	 before we do any consing.  */
      if (frame_name_fnn_p (SSDATA (f->name), SBYTES (f->name)))
	return;

      name = make_formatted_string ("F%"PRIdMAX, ++tty_frame_count);
    }
  else
    {
      CHECK_STRING (name);

      /* Don't change the name if it's already NAME.  */
      if (! NILP (Fstring_equal (name, f->name)))
	return;

      /* Don't allow the user to set the frame name to F<num>, so it
	 doesn't clash with the names we generate for terminal frames.  */
      if (frame_name_fnn_p (SSDATA (name), SBYTES (name)))
	error ("Frame names of the form F<num> are usurped by Emacs");
    }

  fset_name (f, name);
  update_mode_lines = 16;
}

void
store_frame_param (struct frame *f, Lisp_Object prop, Lisp_Object val)
{
  register Lisp_Object old_alist_elt;

  if (EQ (prop, Qminibuffer))
    {
      if (WINDOWP (val))
	{
	  if (!WINDOW_LIVE_P (val) || !MINI_WINDOW_P (XWINDOW (val)))
	    error ("The `minibuffer' parameter does not specify a valid minibuffer window");
	  else if (FRAME_MINIBUF_ONLY_P (f))
	    {
	      if (EQ (val, FRAME_MINIBUF_WINDOW (f)))
		val = Qonly;
	      else
		error ("Can't change the minibuffer window of a minibuffer-only frame");
	    }
	  else if (FRAME_HAS_MINIBUF_P (f))
	    {
	      if (EQ (val, FRAME_MINIBUF_WINDOW (f)))
		val = Qt;
	      else
		error ("Can't change the minibuffer window of a frame with its own minibuffer");
	    }
	  else if (is_tty_frame (f)
		   && (root_frame (WINDOW_XFRAME (XWINDOW (val)))
		       != root_frame (f)))
	    error ("A frame and its surrogate minibuffer frame must have the same roots");
	  else
	    /* Store the chosen minibuffer window.  */
	    fset_minibuffer_window (f, val);
	}
      else
	{
	  Lisp_Object old_val = Fcdr (Fassq (Qminibuffer, f->param_alist));

	  if (!NILP (old_val))
	    {
	      if (WINDOWP (old_val) && NILP (val))
		/* Don't change the value for a minibuffer-less frame if
		   only nil was specified as new value.  */
		val = old_val;
	      else if (!EQ (old_val, val))
		error ("Can't change the `minibuffer' parameter of this frame");
	    }
	}
    }

  /* Check each parent-frame and delete-before parameter for a
     circular dependency.  Do not check between parameters, so you can
     still create circular dependencies with different properties, for
     example a chain of frames F1->F2->...Fn such that F1 is an ancestor
     frame of Fn and thus cannot be deleted before Fn and a second chain
     Fn->Fn-1->...F1 such that Fn cannot be deleted before F1.  */
  else if (EQ (prop, Qparent_frame) || EQ (prop, Qdelete_before))
    {
      Lisp_Object oldval = Fcdr (Fassq (prop, f->param_alist));

      if (!EQ (oldval, val) && !NILP (val))
	{
	  Lisp_Object frame;
	  Lisp_Object frame1 = val;

	  if (!FRAMEP (frame1) || !FRAME_LIVE_P (XFRAME (frame1)))
	    error ("Invalid `%s' frame parameter",
		   SSDATA (SYMBOL_NAME (prop)));

	  XSETFRAME (frame, f);

	  while (FRAMEP (frame1) && FRAME_LIVE_P (XFRAME (frame1)))
	    if (EQ (frame1, frame))
	      error ("Circular specification of `%s' frame parameter",
		     SSDATA (SYMBOL_NAME (prop)));
	    else
	      frame1 = get_frame_param (XFRAME (frame1), prop);
	}
    }

  /* The buffer-list parameters are stored in a special place and not
     in the alist.  All buffers must be live.  */
  else if (EQ (prop, Qbuffer_list))
    {
      Lisp_Object list = Qnil;
      for (; CONSP (val); val = XCDR (val))
	if (!NILP (Fbuffer_live_p (XCAR (val))))
	  list = Fcons (XCAR (val), list);
      fset_buffer_list (f, Fnreverse (list));
      return;
    }
  else if (EQ (prop, Qburied_buffer_list))
    {
      Lisp_Object list = Qnil;
      for (; CONSP (val); val = XCDR (val))
	if (!NILP (Fbuffer_live_p (XCAR (val))))
	  list = Fcons (XCAR (val), list);
      fset_buried_buffer_list (f, Fnreverse (list));
      return;
    }
  else if ((EQ (prop, Qscroll_bar_width) || EQ (prop, Qscroll_bar_height))
	   && !NILP (val) && !RANGED_FIXNUMP (1, val, INT_MAX))
    {
      Lisp_Object old_val = Fcdr (Fassq (prop, f->param_alist));

      val = old_val;
    }

  /* The parent frame parameter for ttys must be handled specially.  */
  if (is_tty_frame (f) && EQ (prop, Qparent_frame))
    {
      /* Invariant: When a frame F1 uses a surrogate minibuffer frame M1
	 on a tty, both F1 and M1 must have the same root frame.  */
      Lisp_Object frames, frame1, old_val = f->parent_frame;

      FOR_EACH_FRAME (frames, frame1)
	{
	  struct frame *f1 = XFRAME (frame1);
	  struct frame *m1 = WINDOW_XFRAME (XWINDOW (f1->minibuffer_window));
	  bool mismatch = false;

	  /* Temporarily install VAL and check whether our invariant
	     above gets violated.  */
	  f->parent_frame = val;
	  mismatch = root_frame (f1) != root_frame (m1);
	  f->parent_frame = old_val;

	  if (mismatch)
	    error ("Cannot re-root surrogate minibuffer frame");
	}

      if (f == XFRAME (FRAME_TERMINAL (f)->display_info.tty->top_frame)
	  && !NILP (val))
	error ("Cannot make tty top frame a child frame");
      else if (NILP (val))
	{
	  if (!FRAME_HAS_MINIBUF_P (f)
	      && (!frame_ancestor_p
		  (f, WINDOW_XFRAME (XWINDOW (f->minibuffer_window)))))
	    error ("Cannot make tty root frame without valid minibuffer window");
	  else
	    {
	      /* When making a frame a root frame, expand it to full size,
		 if necessary, and position it at top left corner.  */
	      int width, height;

	      get_tty_size (fileno (FRAME_TTY (f)->input), &width, &height);
	      adjust_frame_size (f, width, height - FRAME_TOP_MARGIN (f), 5, 0,
				 Qterminal_frame);
	      f->left_pos = 0;
	      f->top_pos = 0;
	    }
	}

      SET_FRAME_GARBAGED (root_frame (f));
      f->parent_frame = val;
      SET_FRAME_GARBAGED (root_frame (f));
    }

  /* The tty color needed to be set before the frame's parameter
     alist was updated with the new value.  This is not true any more,
     but we still do this test early on.  */
  if (FRAME_TERMCAP_P (f) && EQ (prop, Qtty_color_mode)
      && f == FRAME_TTY (f)->previous_frame)
    /* Force redisplay of this tty.  */
    FRAME_TTY (f)->previous_frame = NULL;

  /* Update the frame parameter alist.  */
  old_alist_elt = Fassq (prop, f->param_alist);
  if (NILP (old_alist_elt))
    fset_param_alist (f, Fcons (Fcons (prop, val), f->param_alist));
  else
    Fsetcdr (old_alist_elt, val);

  /* Update some other special parameters in their special places
     in addition to the alist.  */

  if (EQ (prop, Qbuffer_predicate))
    fset_buffer_predicate (f, val);

  if (! FRAME_WINDOW_P (f))
    {
      if (EQ (prop, Qmenu_bar_lines))
	set_menu_bar_lines (f, val, make_fixnum (FRAME_MENU_BAR_LINES (f)));
      else if (EQ (prop, Qtab_bar_lines))
	set_tab_bar_lines (f, val, make_fixnum (FRAME_TAB_BAR_LINES (f)));
      else if (EQ (prop, Qname))
	set_term_frame_name (f, val);
    }
}

/* Return color matches UNSPEC on frame F or nil if UNSPEC
   is not an unspecified foreground or background color.  */

static Lisp_Object
frame_unspecified_color (struct frame *f, Lisp_Object unspec)
{
  return (!strncmp (SSDATA (unspec), unspecified_bg, SBYTES (unspec))
	  ? tty_color_name (f, FRAME_BACKGROUND_PIXEL (f))
	  : (!strncmp (SSDATA (unspec), unspecified_fg, SBYTES (unspec))
	     ? tty_color_name (f, FRAME_FOREGROUND_PIXEL (f)) : Qnil));
}

DEFUN ("frame-parameters", Fframe_parameters, Sframe_parameters, 0, 1, 0,
       doc: /* Return the parameters-alist of frame FRAME.
It is a list of elements of the form (PARM . VALUE), where PARM is a symbol.
The meaningful PARMs depend on the kind of frame.
If FRAME is omitted or nil, return information on the currently selected frame.  */)
  (Lisp_Object frame)
{
  Lisp_Object alist;
  struct frame *f = decode_any_frame (frame);
  int height, width;

  if (!FRAME_LIVE_P (f))
    return Qnil;

  alist = Fcopy_alist (f->param_alist);

  if (!FRAME_WINDOW_P (f))
    {
      Lisp_Object elt;

      /* If the frame's parameter alist says the colors are
	 unspecified and reversed, take the frame's background pixel
	 for foreground and vice versa.  */
      elt = Fassq (Qforeground_color, alist);
      if (CONSP (elt) && STRINGP (XCDR (elt)))
	{
	  elt = frame_unspecified_color (f, XCDR (elt));
	  if (!NILP (elt))
	    store_in_alist (&alist, Qforeground_color, elt);
	}
      else
	store_in_alist (&alist, Qforeground_color,
			tty_color_name (f, FRAME_FOREGROUND_PIXEL (f)));
      elt = Fassq (Qbackground_color, alist);
      if (CONSP (elt) && STRINGP (XCDR (elt)))
	{
	  elt = frame_unspecified_color (f, XCDR (elt));
	  if (!NILP (elt))
	    store_in_alist (&alist, Qbackground_color, elt);
	}
      else
	store_in_alist (&alist, Qbackground_color,
			tty_color_name (f, FRAME_BACKGROUND_PIXEL (f)));
      store_in_alist (&alist, Qfont,
		      build_string (FRAME_MSDOS_P (f)
				    ? "ms-dos"
				    : FRAME_W32_P (f) ? "w32term"
				    :"tty"));
    }

  store_in_alist (&alist, Qname, f->name);
  /* It's questionable whether here we should report the value of
     f->new_height (and f->new_width below) but we've done that in the
     past, so let's keep it.  Note that a value of -1 for either of
     these means that no new size was requested.

     But check f->new_size before to make sure that f->new_height and
     f->new_width are not ones requested by adjust_frame_size.  */
  height = ((f->new_size_p && f->new_height >= 0)
	    ? f->new_height / FRAME_LINE_HEIGHT (f)
	    : FRAME_LINES (f));
  store_in_alist (&alist, Qheight, make_fixnum (height));
  width = ((f->new_size_p && f->new_width >= 0)
	   ? f->new_width / FRAME_COLUMN_WIDTH (f)
	   : FRAME_COLS(f));
  store_in_alist (&alist, Qwidth, make_fixnum (width));

  store_in_alist (&alist, Qmodeline, FRAME_WANTS_MODELINE_P (f) ? Qt : Qnil);
  store_in_alist (&alist, Qunsplittable, FRAME_NO_SPLIT_P (f) ? Qt : Qnil);
  store_in_alist (&alist, Qbuffer_list, f->buffer_list);
  store_in_alist (&alist, Qburied_buffer_list, f->buried_buffer_list);

  /* I think this should be done with a hook.  */
#ifdef HAVE_WINDOW_SYSTEM
  if (FRAME_WINDOW_P (f))
    gui_report_frame_params (f, &alist);
  else
#endif
    {
      store_in_alist (&alist, Qmenu_bar_lines, make_fixnum (FRAME_MENU_BAR_LINES (f)));
      store_in_alist (&alist, Qtab_bar_lines, make_fixnum (FRAME_TAB_BAR_LINES (f)));
      store_in_alist (&alist, Qvisibility, FRAME_VISIBLE_P (f) ? Qt : Qnil);
      store_in_alist (&alist, Qno_accept_focus, FRAME_NO_ACCEPT_FOCUS (f) ? Qt : Qnil);
    }

  return alist;
}


DEFUN ("frame-parameter", Fframe_parameter, Sframe_parameter, 2, 2, 0,
       doc: /* Return FRAME's value for parameter PARAMETER.
If FRAME is nil, describe the currently selected frame.  */)
  (Lisp_Object frame, Lisp_Object parameter)
{
  struct frame *f = decode_any_frame (frame);
  Lisp_Object value = Qnil;

  CHECK_SYMBOL (parameter);

  XSETFRAME (frame, f);

  if (FRAME_LIVE_P (f))
    {
      /* Avoid consing in frequent cases.  */
      if (EQ (parameter, Qname))
	value = f->name;
#ifdef HAVE_WINDOW_SYSTEM
      /* These are used by vertical motion commands.  */
      else if (EQ (parameter, Qvertical_scroll_bars))
	value = (f->vertical_scroll_bar_type == vertical_scroll_bar_none
		 ? Qnil
		 : (f->vertical_scroll_bar_type == vertical_scroll_bar_left
		    ? Qleft : Qright));
      else if (EQ (parameter, Qhorizontal_scroll_bars))
	value = f->horizontal_scroll_bars ? Qt : Qnil;
      else if (EQ (parameter, Qline_spacing) && f->extra_line_spacing == 0)
	/* If this is non-zero, we can't determine whether the user specified
	   an integer or float value without looking through 'param_alist'.  */
	value = make_fixnum (0);
      else if (EQ (parameter, Qfont) && FRAME_X_P (f))
	value = FRAME_FONT (f)->props[FONT_NAME_INDEX];
#endif /* HAVE_WINDOW_SYSTEM */
#ifdef HAVE_X_WINDOWS
      else if (EQ (parameter, Qdisplay) && FRAME_X_P (f))
	value = XCAR (FRAME_DISPLAY_INFO (f)->name_list_element);
#endif /* HAVE_X_WINDOWS */
      else if (EQ (parameter, Qbackground_color)
	       || EQ (parameter, Qforeground_color))
	{
	  value = Fassq (parameter, f->param_alist);
	  if (CONSP (value))
	    {
	      value = XCDR (value);
	      /* Fframe_parameters puts the actual fg/bg color names,
		 even if f->param_alist says otherwise.  This is
		 important when param_alist's notion of colors is
		 "unspecified".  We need to do the same here.  */
	      if (STRINGP (value) && !FRAME_WINDOW_P (f))
		{
		  Lisp_Object tem = frame_unspecified_color (f, value);

		  if (!NILP (tem))
		    value = tem;
		}
	    }
	  else
	    value = Fcdr (Fassq (parameter, Fframe_parameters (frame)));
	}
      else if (EQ (parameter, Qdisplay_type)
	       || EQ (parameter, Qbackground_mode))
	value = Fcdr (Fassq (parameter, f->param_alist));
      else
	/* FIXME: Avoid this code path at all (as well as code duplication)
	   by sharing more code with Fframe_parameters.  */
	value = Fcdr (Fassq (parameter, Fframe_parameters (frame)));
    }

  return value;
}

DEFUN ("modify-frame-parameters", Fmodify_frame_parameters,
       Smodify_frame_parameters, 2, 2, 0,
       doc: /* Modify FRAME according to new values of its parameters in ALIST.
If FRAME is nil, it defaults to the selected frame.
ALIST is an alist of parameters to change and their new values.
Each element of ALIST has the form (PARM . VALUE), where PARM is a symbol.
Which PARMs are meaningful depends on the kind of frame.
The meaningful parameters are acted upon, i.e. the frame is changed
according to their new values, and are also stored in the frame's
parameter list so that `frame-parameters' will return them.
PARMs that are not meaningful are still stored in the frame's parameter
list, but are otherwise ignored.  */)
  (Lisp_Object frame, Lisp_Object alist)
{
  struct frame *f = decode_live_frame (frame);
  Lisp_Object prop, val;

  /* I think this should be done with a hook.  */
#ifdef HAVE_WINDOW_SYSTEM
  if (FRAME_WINDOW_P (f))
    gui_set_frame_parameters (f, alist);
  else
#endif
#ifdef MSDOS
  if (FRAME_MSDOS_P (f))
    IT_set_frame_parameters (f, alist);
  else
#endif

    {
      EMACS_INT length = list_length (alist);
      ptrdiff_t i;
      Lisp_Object *parms;
      Lisp_Object *values;
      USE_SAFE_ALLOCA;
      SAFE_ALLOCA_LISP (parms, 2 * length);
      values = parms + length;
      Lisp_Object params = alist;

      /* Extract parm names and values into those vectors.  */

      for (i = 0; CONSP (alist); alist = XCDR (alist))
	{
	  Lisp_Object elt;

	  elt = XCAR (alist);
	  parms[i] = Fcar (elt);
	  values[i] = Fcdr (elt);
	  i++;
	}

      /* Now process them in reverse of specified order.  */
      while (--i >= 0)
	{
	  prop = parms[i];
	  val = values[i];
	  store_frame_param (f, prop, val);

	  if (EQ (prop, Qforeground_color)
	      || EQ (prop, Qbackground_color))
	    update_face_from_frame_parameter (f, prop, val);
	}

      if (is_tty_child_frame (f))
	{
	  int w = tty_child_size_param (f, Qwidth, params, f->total_cols);
	  int h = tty_child_size_param (f, Qheight, params, f->total_lines);
	  int x = tty_child_pos_param (f, Qleft, params, f->left_pos, w);
	  int y = tty_child_pos_param (f, Qtop, params, f->top_pos, h);

	  if (x != f->left_pos || y != f->top_pos)
	    {
	      f->left_pos = x;
	      f->top_pos = y;
	      SET_FRAME_GARBAGED (root_frame (f));
	    }

	  if (w != f->total_cols || h != f->total_lines)
	    change_frame_size (f, w, h, false, false, false);

	  Lisp_Object visible = Fassq (Qvisibility, params);

	  if (CONSP (visible))
	    {
	      if (EQ (Fcdr (visible), Qicon)
		  && EQ (iconify_child_frame, Qmake_invisible))
		SET_FRAME_VISIBLE (f, false);
	      else
		SET_FRAME_VISIBLE (f, !NILP (Fcdr (visible)));
	    }

	  Lisp_Object no_special = Fassq (Qno_special_glyphs, params);

	  if (CONSP (no_special))
	    FRAME_NO_SPECIAL_GLYPHS (f) = !NILP (Fcdr (no_special));
	}

      SAFE_FREE ();
    }
  return Qnil;
}

DEFUN ("frame-char-height", Fframe_char_height, Sframe_char_height,
       0, 1, 0,
       doc: /* Height in pixels of a line in the font in frame FRAME.
If FRAME is omitted or nil, the selected frame is used.
For a terminal frame, the value is always 1.  */)
  (Lisp_Object frame)
{
#ifdef HAVE_WINDOW_SYSTEM
  struct frame *f = decode_any_frame (frame);

  if (FRAME_WINDOW_P (f))
    return make_fixnum (FRAME_LINE_HEIGHT (f));
  else
#endif
    return make_fixnum (1);
}


DEFUN ("frame-char-width", Fframe_char_width, Sframe_char_width,
       0, 1, 0,
       doc: /* Width in pixels of characters in the font in frame FRAME.
If FRAME is omitted or nil, the selected frame is used.
On a graphical screen, the width is the standard width of the default font.
For a terminal screen, the value is always 1.  */)
  (Lisp_Object frame)
{
#ifdef HAVE_WINDOW_SYSTEM
  struct frame *f = decode_any_frame (frame);

  if (FRAME_WINDOW_P (f))
    return make_fixnum (FRAME_COLUMN_WIDTH (f));
  else
#endif
    return make_fixnum (1);
}

DEFUN ("frame-native-width", Fframe_native_width,
       Sframe_native_width, 0, 1, 0,
       doc: /* Return FRAME's native width in pixels.
For a terminal frame, the result really gives the width in characters.
If FRAME is omitted or nil, the selected frame is used.

If you're interested only in the width of the text portion of the
frame, see `frame-text-width' instead.  */)
  (Lisp_Object frame)
{
  struct frame *f = decode_any_frame (frame);

#ifdef HAVE_WINDOW_SYSTEM
  if (FRAME_WINDOW_P (f))
    return make_fixnum (FRAME_PIXEL_WIDTH (f));
  else
#endif
    return make_fixnum (FRAME_TOTAL_COLS (f));
}

DEFUN ("frame-native-height", Fframe_native_height,
       Sframe_native_height, 0, 1, 0,
       doc: /* Return FRAME's native height in pixels.
If FRAME is omitted or nil, the selected frame is used.  The exact value
of the result depends on the window-system and toolkit in use:

In the Gtk+ and NS versions, it includes only any window (including the
minibuffer or echo area), mode line, and header line.  It does not
include the tool bar or menu bar.  With other graphical versions, it may
also include the tool bar and the menu bar.

If you're interested only in the height of the text portion of the
frame, see `frame-text-height' instead.

For a text terminal, it includes the menu bar.  In this case, the
result is really in characters rather than pixels (i.e., is identical
to `frame-height'). */)
  (Lisp_Object frame)
{
  struct frame *f = decode_any_frame (frame);

#ifdef HAVE_WINDOW_SYSTEM
  if (FRAME_WINDOW_P (f))
    return make_fixnum (FRAME_PIXEL_HEIGHT (f));
  else
#endif
    return make_fixnum (FRAME_TOTAL_LINES (f));
}

DEFUN ("tool-bar-pixel-width", Ftool_bar_pixel_width,
       Stool_bar_pixel_width, 0, 1, 0,
       doc: /* Return width in pixels of FRAME's tool bar.
The result is greater than zero only when the tool bar is on the left
or right side of FRAME.  If FRAME is omitted or nil, the selected frame
is used.  */)
  (Lisp_Object frame)
{
#ifdef FRAME_TOOLBAR_WIDTH
  struct frame *f = decode_any_frame (frame);

  if (FRAME_WINDOW_P (f))
    return make_fixnum (FRAME_TOOLBAR_WIDTH (f));
#endif
  return make_fixnum (0);
}

DEFUN ("frame-text-cols", Fframe_text_cols, Sframe_text_cols, 0, 1, 0,
       doc: /* Return width in columns of FRAME's text area.  */)
  (Lisp_Object frame)
{
  return make_fixnum (FRAME_COLS (decode_any_frame (frame)));
}

DEFUN ("frame-text-lines", Fframe_text_lines, Sframe_text_lines, 0, 1, 0,
       doc: /* Return height in lines of FRAME's text area.  */)
  (Lisp_Object frame)
{
  return make_fixnum (FRAME_LINES (decode_any_frame (frame)));
}

DEFUN ("frame-total-cols", Fframe_total_cols, Sframe_total_cols, 0, 1, 0,
       doc: /* Return number of total columns of FRAME.  */)
  (Lisp_Object frame)
{
  return make_fixnum (FRAME_TOTAL_COLS (decode_any_frame (frame)));
}

DEFUN ("frame-total-lines", Fframe_total_lines, Sframe_total_lines, 0, 1, 0,
       doc: /* Return number of total lines of FRAME.  */)
  (Lisp_Object frame)
{
  return make_fixnum (FRAME_TOTAL_LINES (decode_any_frame (frame)));
}

DEFUN ("frame-text-width", Fframe_text_width, Sframe_text_width, 0, 1, 0,
       doc: /* Return text area width of FRAME in pixels.  */)
  (Lisp_Object frame)
{
  return make_fixnum (FRAME_TEXT_WIDTH (decode_any_frame (frame)));
}

DEFUN ("frame-text-height", Fframe_text_height, Sframe_text_height, 0, 1, 0,
       doc: /* Return text area height of FRAME in pixels.  */)
  (Lisp_Object frame)
{
  return make_fixnum (FRAME_TEXT_HEIGHT (decode_any_frame (frame)));
}

DEFUN ("frame-scroll-bar-width", Fscroll_bar_width, Sscroll_bar_width, 0, 1, 0,
       doc: /* Return scroll bar width of FRAME in pixels.  */)
  (Lisp_Object frame)
{
  return make_fixnum (FRAME_SCROLL_BAR_AREA_WIDTH (decode_any_frame (frame)));
}

DEFUN ("frame-scroll-bar-height", Fscroll_bar_height, Sscroll_bar_height, 0, 1, 0,
       doc: /* Return scroll bar height of FRAME in pixels.  */)
  (Lisp_Object frame)
{
  return make_fixnum (FRAME_SCROLL_BAR_AREA_HEIGHT (decode_any_frame (frame)));
}

DEFUN ("frame-fringe-width", Ffringe_width, Sfringe_width, 0, 1, 0,
       doc: /* Return fringe width of FRAME in pixels.  */)
  (Lisp_Object frame)
{
  return make_fixnum (FRAME_TOTAL_FRINGE_WIDTH (decode_any_frame (frame)));
}

DEFUN ("frame-child-frame-border-width", Fframe_child_frame_border_width, Sframe_child_frame_border_width, 0, 1, 0,
       doc: /* Return width of FRAME's child-frame border in pixels.
 If FRAME's `child-frame-border-width' parameter is nil, return FRAME's
 internal border width instead.  */)
  (Lisp_Object frame)
{
  int width = FRAME_CHILD_FRAME_BORDER_WIDTH (decode_any_frame (frame));

  if (width < 0)
    return make_fixnum (FRAME_INTERNAL_BORDER_WIDTH (decode_any_frame (frame)));
  else
    return make_fixnum (FRAME_CHILD_FRAME_BORDER_WIDTH (decode_any_frame (frame)));
}

DEFUN ("frame-internal-border-width", Fframe_internal_border_width, Sframe_internal_border_width, 0, 1, 0,
       doc: /* Return width of FRAME's internal border in pixels.  */)
  (Lisp_Object frame)
{
  return make_fixnum (FRAME_INTERNAL_BORDER_WIDTH (decode_any_frame (frame)));
}

DEFUN ("frame-right-divider-width", Fright_divider_width, Sright_divider_width, 0, 1, 0,
       doc: /* Return width (in pixels) of vertical window dividers on FRAME.  */)
  (Lisp_Object frame)
{
  return make_fixnum (FRAME_RIGHT_DIVIDER_WIDTH (decode_any_frame (frame)));
}

DEFUN ("frame-bottom-divider-width", Fbottom_divider_width, Sbottom_divider_width, 0, 1, 0,
       doc: /* Return width (in pixels) of horizontal window dividers on FRAME.  */)
  (Lisp_Object frame)
{
  return make_fixnum (FRAME_BOTTOM_DIVIDER_WIDTH (decode_any_frame (frame)));
}

static int
check_frame_pixels (Lisp_Object size, Lisp_Object pixelwise, int item_size)
{
  intmax_t sz;
  int pixel_size; /* size * item_size */

  CHECK_INTEGER (size);
  if (!NILP (pixelwise))
    item_size = 1;

  if (!integer_to_intmax (size, &sz)
      || ckd_mul (&pixel_size, sz, item_size))
    args_out_of_range_3 (size, make_int (INT_MIN / item_size),
			 make_int (INT_MAX / item_size));

  return pixel_size;
}

DEFUN ("set-frame-height", Fset_frame_height, Sset_frame_height, 2, 4,
       "(set-frame-property--interactive \"Frame height: \" (frame-height))",
       doc: /* Set text height of frame FRAME to HEIGHT lines.
Optional third arg PRETEND non-nil means that redisplay should use
HEIGHT lines but that the idea of the actual height of the frame should
not be changed.

Optional fourth argument PIXELWISE non-nil means that FRAME should be
HEIGHT pixels high.  Note: When `frame-resize-pixelwise' is nil, some
window managers may refuse to honor a HEIGHT that is not an integer
multiple of the default frame font height.

When called interactively, HEIGHT is the numeric prefix and the
currently selected frame will be set to this height.

If FRAME is nil, it defaults to the selected frame.  */)
  (Lisp_Object frame, Lisp_Object height, Lisp_Object pretend, Lisp_Object pixelwise)
{
  struct frame *f = decode_live_frame (frame);
  int text_height
    = check_frame_pixels (height, pixelwise, FRAME_LINE_HEIGHT (f));

  /* With INHIBIT 1 pass correct text width to adjust_frame_size.  */
  adjust_frame_size
    (f, FRAME_TEXT_WIDTH (f), text_height, 1, !NILP (pretend), Qheight);

  return Qnil;
}

DEFUN ("set-frame-width", Fset_frame_width, Sset_frame_width, 2, 4,
       "(set-frame-property--interactive \"Frame width: \" (frame-width))",
       doc: /* Set text width of frame FRAME to WIDTH columns.
Optional third arg PRETEND non-nil means that redisplay should use WIDTH
columns but that the idea of the actual width of the frame should not
be changed.

Optional fourth argument PIXELWISE non-nil means that FRAME should be
WIDTH pixels wide.  Note: When `frame-resize-pixelwise' is nil, some
window managers may refuse to honor a WIDTH that is not an integer
multiple of the default frame font width.

When called interactively, WIDTH is the numeric prefix and the
currently selected frame will be set to this width.

If FRAME is nil, it defaults to the selected frame.  */)
  (Lisp_Object frame, Lisp_Object width, Lisp_Object pretend, Lisp_Object pixelwise)
{
  struct frame *f = decode_live_frame (frame);
  int text_width
    = check_frame_pixels (width, pixelwise, FRAME_COLUMN_WIDTH (f));

  /* With INHIBIT 1 pass correct text height to adjust_frame_size.  */
  adjust_frame_size
    (f, text_width, FRAME_TEXT_HEIGHT (f), 1, !NILP (pretend), Qwidth);

  return Qnil;
}

DEFUN ("set-frame-size", Fset_frame_size, Sset_frame_size, 3, 4, 0,
       doc: /* Set text size of FRAME to WIDTH by HEIGHT, measured in characters.
Optional argument PIXELWISE non-nil means to measure in pixels.  Note:
When `frame-resize-pixelwise' is nil, some window managers may refuse to
honor a WIDTH that is not an integer multiple of the default frame font
width or a HEIGHT that is not an integer multiple of the default frame
font height.

If FRAME is nil, it defaults to the selected frame.  */)
  (Lisp_Object frame, Lisp_Object width, Lisp_Object height, Lisp_Object pixelwise)
{
  struct frame *f = decode_live_frame (frame);
  int text_width
    = check_frame_pixels (width, pixelwise, FRAME_COLUMN_WIDTH (f));
  int text_height
    = check_frame_pixels (height, pixelwise, FRAME_LINE_HEIGHT (f));

  /* PRETEND is always false here.  */
  adjust_frame_size (f, text_width, text_height, 1, false, Qsize);

  return Qnil;
}

DEFUN ("frame-position", Fframe_position,
       Sframe_position, 0, 1, 0,
       doc: /* Return top left corner of FRAME in pixels.
FRAME must be a live frame and defaults to the selected one.  The return
value is a cons (x, y) of the coordinates of the top left corner of
FRAME's outer frame, in pixels relative to an origin (0, 0) of FRAME's
display.

Note that the values returned are not guaranteed to be accurate: The
values depend on the underlying window system, and some systems add a
constant offset to the values.  */)
     (Lisp_Object frame)
{
  register struct frame *f = decode_live_frame (frame);

  return Fcons (make_fixnum (f->left_pos), make_fixnum (f->top_pos));
}

DEFUN ("set-frame-position", Fset_frame_position,
       Sset_frame_position, 3, 3, 0,
       doc: /* Set position of FRAME to (X, Y).
FRAME must be a live frame and defaults to the selected one.  X and Y,
if positive, specify the coordinate of the left and top edge of FRAME's
outer frame in pixels relative to an origin (0, 0) of FRAME's display.
If any of X or Y is negative, it specifies the coordinates of the right
or bottom edge of the outer frame of FRAME relative to the right or
bottom edge of FRAME's display.  */)
  (Lisp_Object frame, Lisp_Object x, Lisp_Object y)
{
  struct frame *f = decode_live_frame (frame);
  int xval = check_integer_range (x, INT_MIN, INT_MAX);
  int yval = check_integer_range (y, INT_MIN, INT_MAX);

  if (FRAME_WINDOW_P (f))
    {
#ifdef HAVE_WINDOW_SYSTEM
      if (FRAME_TERMINAL (f)->set_frame_offset_hook)
	FRAME_TERMINAL (f)->set_frame_offset_hook (f, xval, yval, 1);
#else
      (void) xval;
      (void) yval;
#endif
    }
  else if (is_tty_child_frame (f))
    {
      f->left_pos = xval;
      f->top_pos = yval;
    }

  return Qt;
}

DEFUN ("frame-window-state-change", Fframe_window_state_change,
       Sframe_window_state_change, 0, 1, 0,
       doc: /* Return t if FRAME's window state change flag is set, nil otherwise.
FRAME must be a live frame and defaults to the selected one.

If FRAME's window state change flag is set, the default values of
`window-state-change-functions' and `window-state-change-hook' will be
run during next redisplay, regardless of whether a window state change
actually occurred on FRAME or not.  After that, the value of this flag
is reset.  */)
     (Lisp_Object frame)
{
  return FRAME_WINDOW_STATE_CHANGE (decode_live_frame (frame)) ? Qt : Qnil;
}

DEFUN ("set-frame-window-state-change", Fset_frame_window_state_change,
       Sset_frame_window_state_change, 0, 2, 0,
       doc: /* Set FRAME's window state change flag according to ARG.
Set FRAME's window state change flag if ARG is non-nil, reset it
otherwise.

If FRAME's window state change flag is set, the default values of
`window-state-change-functions' and `window-state-change-hook' will be
run during next redisplay, regardless of whether a window state change
actually occurred on FRAME or not.  After that, the value of FRAME's
window state change flag is reset.  */)
     (Lisp_Object frame, Lisp_Object arg)
{
  struct frame *f = decode_live_frame (frame);

  return (FRAME_WINDOW_STATE_CHANGE (f) = !NILP (arg)) ? Qt : Qnil;
}

DEFUN ("frame-scale-factor", Fframe_scale_factor, Sframe_scale_factor,
       0, 1, 0,
       doc: /* Return FRAMEs scale factor.
If FRAME is omitted or nil, the selected frame is used.
The scale factor is the amount by which a logical pixel size must be
multiplied to find the real number of pixels.  */)
     (Lisp_Object frame)
{
  struct frame *f = decode_live_frame (frame);

  return (make_float (f ? FRAME_SCALE_FACTOR (f) : 1));
}

/***********************************************************************
				Frame Parameters
 ***********************************************************************/

/* Connect the frame-parameter names for frames to the ways of passing
   the parameter values to the window system.

   The name of a parameter, a Lisp symbol, has an `x-frame-parameter'
   property which is its index in this table.  This is initialized in
   syms_of_frame.  */

struct frame_parm_table {
  const char *name;
  int sym;
};

/* If you're adding a new frame parameter here, consider if it makes sense
   for the user to customize it via `initial-frame-alist' and the like.
   If it does, add it to `frame--special-parameters' in frame.el, in order
   to provide completion in the Customize UI for the new parameter.  */
static const struct frame_parm_table frame_parms[] =
{
  {"auto-raise",		SYMBOL_INDEX (Qauto_raise)},
  {"auto-lower",		SYMBOL_INDEX (Qauto_lower)},
  {"background-color",		SYMBOL_INDEX (Qbackground_color)},
  {"border-color",		SYMBOL_INDEX (Qborder_color)},
  {"border-width",		SYMBOL_INDEX (Qborder_width)},
  {"cursor-color",		SYMBOL_INDEX (Qcursor_color)},
  {"cursor-type",		SYMBOL_INDEX (Qcursor_type)},
  {"font",			SYMBOL_INDEX (Qfont)},
  {"foreground-color",		SYMBOL_INDEX (Qforeground_color)},
  {"icon-name",			SYMBOL_INDEX (Qicon_name)},
  {"icon-type",			SYMBOL_INDEX (Qicon_type)},
  {"child-frame-border-width",	SYMBOL_INDEX (Qchild_frame_border_width)},
  {"internal-border-width",	SYMBOL_INDEX (Qinternal_border_width)},
  {"right-divider-width",	SYMBOL_INDEX (Qright_divider_width)},
  {"bottom-divider-width",	SYMBOL_INDEX (Qbottom_divider_width)},
  {"menu-bar-lines",		SYMBOL_INDEX (Qmenu_bar_lines)},
  {"mouse-color",		SYMBOL_INDEX (Qmouse_color)},
  {"name",			SYMBOL_INDEX (Qname)},
  {"scroll-bar-width",		SYMBOL_INDEX (Qscroll_bar_width)},
  {"scroll-bar-height",		SYMBOL_INDEX (Qscroll_bar_height)},
  {"title",			SYMBOL_INDEX (Qtitle)},
  {"unsplittable",		SYMBOL_INDEX (Qunsplittable)},
  {"vertical-scroll-bars",	SYMBOL_INDEX (Qvertical_scroll_bars)},
  {"horizontal-scroll-bars",	SYMBOL_INDEX (Qhorizontal_scroll_bars)},
  {"visibility",		SYMBOL_INDEX (Qvisibility)},
  {"tab-bar-lines",		SYMBOL_INDEX (Qtab_bar_lines)},
  {"tool-bar-lines",		SYMBOL_INDEX (Qtool_bar_lines)},
  {"scroll-bar-foreground",	SYMBOL_INDEX (Qscroll_bar_foreground)},
  {"scroll-bar-background",	SYMBOL_INDEX (Qscroll_bar_background)},
  {"screen-gamma",		SYMBOL_INDEX (Qscreen_gamma)},
  {"line-spacing",		SYMBOL_INDEX (Qline_spacing)},
  {"left-fringe",		SYMBOL_INDEX (Qleft_fringe)},
  {"right-fringe",		SYMBOL_INDEX (Qright_fringe)},
  {"wait-for-wm",		SYMBOL_INDEX (Qwait_for_wm)},
  {"fullscreen",                SYMBOL_INDEX (Qfullscreen)},
  {"font-backend",		SYMBOL_INDEX (Qfont_backend)},
  {"alpha",			SYMBOL_INDEX (Qalpha)},
  {"sticky",			SYMBOL_INDEX (Qsticky)},
  {"tool-bar-position",		SYMBOL_INDEX (Qtool_bar_position)},
  {"inhibit-double-buffering",  SYMBOL_INDEX (Qinhibit_double_buffering)},
  {"undecorated",		SYMBOL_INDEX (Qundecorated)},
  {"parent-frame",		SYMBOL_INDEX (Qparent_frame)},
  {"skip-taskbar",		SYMBOL_INDEX (Qskip_taskbar)},
  {"no-focus-on-map",		SYMBOL_INDEX (Qno_focus_on_map)},
  {"no-accept-focus",		SYMBOL_INDEX (Qno_accept_focus)},
  {"z-group",			SYMBOL_INDEX (Qz_group)},
  {"override-redirect",		SYMBOL_INDEX (Qoverride_redirect)},
  {"no-special-glyphs",		SYMBOL_INDEX (Qno_special_glyphs)},
  {"alpha-background",		SYMBOL_INDEX (Qalpha_background)},
  {"use-frame-synchronization",	SYMBOL_INDEX (Quse_frame_synchronization)},
#ifdef HAVE_X_WINDOWS
  {"shaded",			SYMBOL_INDEX (Qshaded)},
#endif
#ifdef NS_IMPL_COCOA
  {"ns-appearance",		SYMBOL_INDEX (Qns_appearance)},
  {"ns-transparent-titlebar",	SYMBOL_INDEX (Qns_transparent_titlebar)},
#endif
};

#ifdef HAVE_WINDOW_SYSTEM

/* Enumeration type for switch in frame_float.  */
enum frame_float_type
{
 FRAME_FLOAT_WIDTH,
 FRAME_FLOAT_HEIGHT,
 FRAME_FLOAT_LEFT,
 FRAME_FLOAT_TOP
};

/**
 * frame_float:
 *
 * Process the value VAL of the float type frame parameter 'width',
 * 'height', 'left', or 'top' specified via a frame_float_type
 * enumeration type WHAT for frame F.  Such parameters relate the outer
 * size or position of F to the size of the F's display or parent frame
 * which have to be both available in some way.
 *
 * The return value is a size or position value in pixels.  VAL must be
 * in the range 0.0 to 1.0 where a width/height of 0.0 means to return 0
 * and 1.0 means to return the full width/height of the display/parent.
 * For positions, 0.0 means position in the left/top corner of the
 * display/parent while 1.0 means to position at the right/bottom corner
 * of the display/parent frame.
 *
 * Set PARENT_DONE and OUTER_DONE to avoid recalculation of the outer
 * size or parent or display attributes when more float parameters are
 * calculated in a row: -1 means not processed yet, 0 means processing
 * failed, 1 means processing succeeded.
 *
 * Return DEFAULT_VALUE when processing fails for whatever reason with
 * one exception: When calculating F's outer edges fails (probably
 * because F has not been created yet) return the difference between F's
 * native and text size.
 */
static int
frame_float (struct frame *f, Lisp_Object val, enum frame_float_type what,
	     int *parent_done, int *outer_done, int default_value)
{
  double d_val = XFLOAT_DATA (val);

  if (d_val < 0.0 || d_val > 1.0)
    /* Invalid VAL.  */
    return default_value;
  else
    {
      static unsigned parent_width, parent_height;
      static int parent_left, parent_top;
      static unsigned outer_minus_text_width, outer_minus_text_height;
      struct frame *p = FRAME_PARENT_FRAME (f);

      if (*parent_done == 1)
	;
      else if (p)
	{
	  parent_width = FRAME_PIXEL_WIDTH (p);
	  parent_height = FRAME_PIXEL_HEIGHT (p);
	  *parent_done = 1;
	}
      else
	{
	  if (*parent_done == 0)
	    /* No workarea available.  */
	    return default_value;
	  else if (*parent_done == -1)
	    {
	      Lisp_Object monitor_attributes;
	      Lisp_Object workarea;
	      Lisp_Object frame;

	      XSETFRAME (frame, f);
	      monitor_attributes = calln (Qframe_monitor_attributes, frame);
	      if (NILP (monitor_attributes))
		{
		  /* No monitor attributes available.  */
		  *parent_done = 0;

		  return default_value;
		}

	      workarea = Fcdr (Fassq (Qworkarea, monitor_attributes));
	      if (NILP (workarea))
		{
		  /* No workarea available.  */
		  *parent_done = 0;

		  return default_value;
		}

	      /* Workarea available.  */
	      parent_left = XFIXNUM (Fnth (make_fixnum (0), workarea));
	      parent_top = XFIXNUM (Fnth (make_fixnum (1), workarea));
	      parent_width = XFIXNUM (Fnth (make_fixnum (2), workarea));
	      parent_height = XFIXNUM (Fnth (make_fixnum (3), workarea));
	      *parent_done = 1;
	    }
	}

      if (*outer_done == 1)
	;
      else if (FRAME_UNDECORATED (f))
	{
	  outer_minus_text_width
	    = FRAME_PIXEL_WIDTH (f) - FRAME_TEXT_WIDTH (f);
	  outer_minus_text_height
	    = FRAME_PIXEL_HEIGHT (f) - FRAME_TEXT_HEIGHT (f);
	  *outer_done = 1;
	}
      else if (*outer_done == 0)
	/* No outer size available.  */
	return default_value;
      else if (*outer_done == -1)
	{
	  Lisp_Object frame, outer_edges;

	  XSETFRAME (frame, f);
	  outer_edges = calln (Qframe_edges, frame, Qouter_edges);

	  if (!NILP (outer_edges))
	    {
	      outer_minus_text_width
		= (XFIXNUM (Fnth (make_fixnum (2), outer_edges))
		   - XFIXNUM (Fnth (make_fixnum (0), outer_edges))
		   - FRAME_TEXT_WIDTH (f));
	      outer_minus_text_height
		= (XFIXNUM (Fnth (make_fixnum (3), outer_edges))
		   - XFIXNUM (Fnth (make_fixnum (1), outer_edges))
		   - FRAME_TEXT_HEIGHT (f));
	    }
	  else
	    {
	      /* If we can't get any outer edges, proceed as if the frame
		 were undecorated.  */
	      outer_minus_text_width
		= FRAME_PIXEL_WIDTH (f) - FRAME_TEXT_WIDTH (f);
	      outer_minus_text_height
		= FRAME_PIXEL_HEIGHT (f) - FRAME_TEXT_HEIGHT (f);
	    }

	  *outer_done = 1;
	}

      switch (what)
	{
	case FRAME_FLOAT_WIDTH:
	  return parent_width * d_val - outer_minus_text_width;

	case FRAME_FLOAT_HEIGHT:
	  return parent_height * d_val - outer_minus_text_height;

	case FRAME_FLOAT_LEFT:
	  {
	    int rest_width = (parent_width
			      - FRAME_TEXT_WIDTH (f)
			      - outer_minus_text_width);

	    if (p)
	      return (rest_width <= 0 ? 0 : d_val * rest_width);
	    else
	      return (rest_width <= 0
		      ? parent_left
		      : parent_left + d_val * rest_width);
	  }
	case FRAME_FLOAT_TOP:
	  {
	    int rest_height = (parent_height
			       - FRAME_TEXT_HEIGHT (f)
			       - outer_minus_text_height);

	    if (p)
	      return (rest_height <= 0 ? 0 : d_val * rest_height);
	    else
	      return (rest_height <= 0
		      ? parent_top
		      : parent_top + d_val * rest_height);
	  }
	default:
	  emacs_abort ();
	}
    }
}

/* Handle frame parameter change with frame parameter handler.
   F is the frame whose frame parameter was changed.
   PROP is the name of the frame parameter.
   VAL and OLD_VALUE are the current and the old value of the
   frame parameter.  */

static void
handle_frame_param (struct frame *f, Lisp_Object prop, Lisp_Object val,
		    Lisp_Object old_value)
{
  Lisp_Object param_index = Fget (prop, Qx_frame_parameter);
  if (FIXNATP (param_index) && XFIXNAT (param_index) < ARRAYELTS (frame_parms))
    {
      if (FRAME_RIF (f))
	{
	  frame_parm_handler handler
	    = FRAME_RIF (f)->frame_parm_handlers[XFIXNAT (param_index)];
	  if (handler)
	    handler (f, val, old_value);
	}
    }
}

/* Change the parameters of frame F as specified by ALIST.
   If a parameter is not specially recognized, do nothing special;
   otherwise call the `gui_set_...' function for that parameter.
   Except for certain geometry properties, always call store_frame_param
   to store the new value in the parameter alist.

   DEFAULT_PARAMETER should be set if the alist was not specified by
   the user, or by the face code to set the `font' parameter.  In that
   case, the `font-parameter' frame parameter should not be changed,
   so dynamic-setting.el can restore the user's selected font
   correctly.  */

void
gui_set_frame_parameters_1 (struct frame *f, Lisp_Object alist,
			    bool default_parameter)
{
  Lisp_Object tail, frame;

  /* Neither of these values should be used.  */
  int width = -1, height = -1;
  bool width_change = false, height_change = false;

  /* Same here.  */
  Lisp_Object left, top;

  /* Same with these.  */
  Lisp_Object icon_left, icon_top;

  /* And with this.  */
  Lisp_Object fullscreen UNINIT;
  bool fullscreen_change = false;

  /* Record in these vectors all the parms specified.  */
  Lisp_Object *parms;
  Lisp_Object *values;
  ptrdiff_t i, j, size;
  bool left_no_change = 0, top_no_change = 0;
#ifdef HAVE_X_WINDOWS
  bool icon_left_no_change = 0, icon_top_no_change = 0;
#endif
  int parent_done = -1, outer_done = -1;

  XSETFRAME (frame, f);
  for (size = 0, tail = alist; CONSP (tail); tail = XCDR (tail))
    size++;
  CHECK_LIST_END (tail, alist);

  USE_SAFE_ALLOCA;
  SAFE_ALLOCA_LISP (parms, 2 * size);
  values = parms + size;

  /* Extract parm names and values into those vectors.  */

  i = 0, j = size - 1;
  for (tail = alist; CONSP (tail); tail = XCDR (tail))
    {
      Lisp_Object elt = XCAR (tail), prop = Fcar (elt), val = Fcdr (elt);

      /* Some properties are independent of other properties, but other
	 properties are dependent upon them.  These special properties
	 are foreground_color, background_color (affects cursor_color)
	 and font (affects fringe widths); they're recorded starting
	 from the end of PARMS and VALUES to process them first by using
	 reverse iteration.  */

      if (EQ (prop, Qforeground_color)
	  || EQ (prop, Qbackground_color)
	  || EQ (prop, Qfont))
	{
	  parms[j] = prop;
	  values[j] = val;
	  j--;
	}
      else
	{
	  parms[i] = prop;
	  values[i] = val;
	  i++;
	}
    }

  /* TAIL and ALIST are not used again below here.  */
  alist = tail = Qnil;

  top = left = Qunbound;
  icon_left = icon_top = Qunbound;

  /* Reverse order is used to make sure that special
     properties noticed above are processed first.  */
  for (i = size - 1; i >= 0; i--)
    {
      Lisp_Object prop, val;

      prop = parms[i];
      val = values[i];

      if (EQ (prop, Qwidth))
        {
	  width_change = true;

	  if (RANGED_FIXNUMP (0, val, INT_MAX))
	    width = XFIXNAT (val) * FRAME_COLUMN_WIDTH (f) ;
	  else if (CONSP (val) && EQ (XCAR (val), Qtext_pixels)
		   && RANGED_FIXNUMP (0, XCDR (val), INT_MAX))
	    width = XFIXNAT (XCDR (val));
	  else if (FLOATP (val))
	    width = frame_float (f, val, FRAME_FLOAT_WIDTH, &parent_done,
				 &outer_done, -1);
	  else
	    width_change = false;
        }
      else if (EQ (prop, Qheight))
        {
	  height_change = true;

	  if (RANGED_FIXNUMP (0, val, INT_MAX))
	    height = XFIXNAT (val) * FRAME_LINE_HEIGHT (f);
	  else if (CONSP (val) && EQ (XCAR (val), Qtext_pixels)
		   && RANGED_FIXNUMP (0, XCDR (val), INT_MAX))
	    height = XFIXNAT (XCDR (val));
	  else if (FLOATP (val))
	    height = frame_float (f, val, FRAME_FLOAT_HEIGHT, &parent_done,
				 &outer_done, -1);
	  else
	    height_change = false;
        }
      else if (EQ (prop, Qtop))
	top = val;
      else if (EQ (prop, Qleft))
	left = val;
      else if (EQ (prop, Qicon_top))
	icon_top = val;
      else if (EQ (prop, Qicon_left))
	icon_left = val;
      else if (EQ (prop, Qfullscreen))
	{
	  fullscreen = val;
	  fullscreen_change = true;
	}
      else
	{
	  Lisp_Object old_value = get_frame_param (f, prop);
	  store_frame_param (f, prop, val);
	  handle_frame_param (f, prop, val, old_value);

	  if (!default_parameter && EQ (prop, Qfont))
	    /* The user manually specified the `font' frame parameter.
	       Save that parameter for future use by the
	       dynamic-setting code.  */
	    store_frame_param (f, Qfont_parameter, val);
	}
    }

  /* Don't die if just one of these was set.  */
  if (BASE_EQ (left, Qunbound))
    {
      left_no_change = 1;
      if (f->left_pos < 0)
	left = list2 (Qplus, make_fixnum (f->left_pos));
      else
	XSETINT (left, f->left_pos);
    }
  if (BASE_EQ (top, Qunbound))
    {
      top_no_change = 1;
      if (f->top_pos < 0)
	top = list2 (Qplus, make_fixnum (f->top_pos));
      else
	XSETINT (top, f->top_pos);
    }

  /* If one of the icon positions was not set, preserve or default it.  */
  if (! TYPE_RANGED_FIXNUMP (int, icon_left))
    {
#ifdef HAVE_X_WINDOWS
      icon_left_no_change = 1;
#endif
      icon_left = Fcdr (Fassq (Qicon_left, f->param_alist));
      if (NILP (icon_left))
	XSETINT (icon_left, 0);
    }
  if (! TYPE_RANGED_FIXNUMP (int, icon_top))
    {
#ifdef HAVE_X_WINDOWS
      icon_top_no_change = 1;
#endif
      icon_top = Fcdr (Fassq (Qicon_top, f->param_alist));
      if (NILP (icon_top))
	XSETINT (icon_top, 0);
    }

  if (width_change || height_change)
    {
      Lisp_Object parameter;

      if (width_change)
	{
	  if (height_change)
	    parameter = Qsize;
	  else
	    {
	      height = FRAME_TEXT_HEIGHT (f);
	      parameter = Qwidth;
	    }
	}
      else
	{
	  width = FRAME_TEXT_WIDTH (f);
	  parameter = Qheight;
	}

      adjust_frame_size (f, width, height, 1, 0, parameter);
    }

  if ((!NILP (left) || !NILP (top))
      && ! (left_no_change && top_no_change)
      && ! (FIXNUMP (left) && XFIXNUM (left) == f->left_pos
	    && FIXNUMP (top) && XFIXNUM (top) == f->top_pos))
    {
      int leftpos = 0;
      int toppos = 0;

      /* Record the signs.  */
      f->size_hint_flags &= ~ (XNegative | YNegative);
      if (EQ (left, Qminus))
	f->size_hint_flags |= XNegative;
      else if (TYPE_RANGED_FIXNUMP (int, left))
	{
	  leftpos = XFIXNUM (left);
	  if (leftpos < 0)
	    f->size_hint_flags |= XNegative;
	}
      else if (CONSP (left) && EQ (XCAR (left), Qminus)
	       && CONSP (XCDR (left))
	       && RANGED_FIXNUMP (-INT_MAX, XCAR (XCDR (left)), INT_MAX))
	{
	  leftpos = - XFIXNUM (XCAR (XCDR (left)));
	  f->size_hint_flags |= XNegative;
	}
      else if (CONSP (left) && EQ (XCAR (left), Qplus)
	       && CONSP (XCDR (left))
	       && TYPE_RANGED_FIXNUMP (int, XCAR (XCDR (left))))
	leftpos = XFIXNUM (XCAR (XCDR (left)));
      else if (FLOATP (left))
	leftpos = frame_float (f, left, FRAME_FLOAT_LEFT, &parent_done,
			       &outer_done, 0);

      if (EQ (top, Qminus))
	f->size_hint_flags |= YNegative;
      else if (TYPE_RANGED_FIXNUMP (int, top))
	{
	  toppos = XFIXNUM (top);
	  if (toppos < 0)
	    f->size_hint_flags |= YNegative;
	}
      else if (CONSP (top) && EQ (XCAR (top), Qminus)
	       && CONSP (XCDR (top))
	       && RANGED_FIXNUMP (-INT_MAX, XCAR (XCDR (top)), INT_MAX))
	{
	  toppos = - XFIXNUM (XCAR (XCDR (top)));
	  f->size_hint_flags |= YNegative;
	}
      else if (CONSP (top) && EQ (XCAR (top), Qplus)
	       && CONSP (XCDR (top))
	       && TYPE_RANGED_FIXNUMP (int, XCAR (XCDR (top))))
	toppos = XFIXNUM (XCAR (XCDR (top)));
      else if (FLOATP (top))
	toppos = frame_float (f, top, FRAME_FLOAT_TOP, &parent_done,
			      &outer_done, 0);

      /* Store the numeric value of the position.  */
      f->top_pos = toppos;
      f->left_pos = leftpos;

      f->win_gravity = NorthWestGravity;

      /* Actually set that position, and convert to absolute.  */
      if (FRAME_TERMINAL (f)->set_frame_offset_hook)
        FRAME_TERMINAL (f)->set_frame_offset_hook (f, leftpos, toppos, -1);
    }

  if (fullscreen_change)
    {
      Lisp_Object old_value = get_frame_param (f, Qfullscreen);

      store_frame_param (f, Qfullscreen, fullscreen);
      if (!EQ (fullscreen, old_value))
	gui_set_fullscreen (f, fullscreen, old_value);
    }


#ifdef HAVE_X_WINDOWS
  if ((!NILP (icon_left) || !NILP (icon_top))
      && ! (icon_left_no_change && icon_top_no_change))
    x_wm_set_icon_position (f, XFIXNUM (icon_left), XFIXNUM (icon_top));
#endif /* HAVE_X_WINDOWS */

  SAFE_FREE ();
}

void
gui_set_frame_parameters (struct frame *f, Lisp_Object alist)
{
  gui_set_frame_parameters_1 (f, alist, false);
}

/* Insert a description of internally-recorded parameters of frame F
   into the parameter alist *ALISTPTR that is to be given to the user.
   Only parameters that are specific to the X window system
   and whose values are not correctly recorded in the frame's
   param_alist need to be considered here.  */

void
gui_report_frame_params (struct frame *f, Lisp_Object *alistptr)
{
  Lisp_Object tem;
  uintmax_t w;

  /* Represent negative positions (off the top or left screen edge)
     in a way that Fmodify_frame_parameters will understand correctly.  */
  XSETINT (tem, f->left_pos);
  if (f->left_pos >= 0)
    store_in_alist (alistptr, Qleft, tem);
  else
    store_in_alist (alistptr, Qleft, list2 (Qplus, tem));

  XSETINT (tem, f->top_pos);
  if (f->top_pos >= 0)
    store_in_alist (alistptr, Qtop, tem);
  else
    store_in_alist (alistptr, Qtop, list2 (Qplus, tem));

  store_in_alist (alistptr, Qborder_width,
		  make_fixnum (f->border_width));
  store_in_alist (alistptr, Qchild_frame_border_width,
		  FRAME_CHILD_FRAME_BORDER_WIDTH (f) >= 0
		  ? make_fixnum (FRAME_CHILD_FRAME_BORDER_WIDTH (f))
		  : Qnil);
  store_in_alist (alistptr, Qinternal_border_width,
		  make_fixnum (FRAME_INTERNAL_BORDER_WIDTH (f)));
  store_in_alist (alistptr, Qright_divider_width,
		  make_fixnum (FRAME_RIGHT_DIVIDER_WIDTH (f)));
  store_in_alist (alistptr, Qbottom_divider_width,
		  make_fixnum (FRAME_BOTTOM_DIVIDER_WIDTH (f)));
  store_in_alist (alistptr, Qleft_fringe,
		  make_fixnum (FRAME_LEFT_FRINGE_WIDTH (f)));
  store_in_alist (alistptr, Qright_fringe,
		  make_fixnum (FRAME_RIGHT_FRINGE_WIDTH (f)));
  store_in_alist (alistptr, Qscroll_bar_width,
		  (FRAME_CONFIG_SCROLL_BAR_WIDTH (f) > 0
		   ? make_fixnum (FRAME_CONFIG_SCROLL_BAR_WIDTH (f))
		   /* nil means "use default width"
		      for non-toolkit scroll bar.
		      ruler-mode.el depends on this.  */
		   : Qnil));
  store_in_alist (alistptr, Qscroll_bar_height,
		  (FRAME_CONFIG_SCROLL_BAR_HEIGHT (f) > 0
		   ? make_fixnum (FRAME_CONFIG_SCROLL_BAR_HEIGHT (f))
		   /* nil means "use default height"
		      for non-toolkit scroll bar.  */
		   : Qnil));
  /* FRAME_NATIVE_WINDOW is not guaranteed to return an integer.
     E.g., on MS-Windows it returns a value whose type is HANDLE,
     which is actually a pointer.  Explicit casting avoids compiler
     warnings.  */
  w = (uintptr_t) FRAME_NATIVE_WINDOW (f);
  store_in_alist (alistptr, Qwindow_id,
		  make_formatted_string ("%"PRIuMAX, w));
#ifdef HAVE_X_WINDOWS
#ifdef USE_X_TOOLKIT
  /* Tooltip frame may not have this widget.  */
  if (FRAME_X_OUTPUT (f)->widget)
#endif
    w = (uintptr_t) FRAME_OUTER_WINDOW (f);
  store_in_alist (alistptr, Qouter_window_id,
		  make_formatted_string ("%"PRIuMAX, w));
#endif
  store_in_alist (alistptr, Qicon_name, f->icon_name);
  store_in_alist (alistptr, Qvisibility,
		  (FRAME_VISIBLE_P (f) ? Qt
		   : FRAME_ICONIFIED_P (f) ? Qicon : Qnil));
  store_in_alist (alistptr, Qdisplay,
		  XCAR (FRAME_DISPLAY_INFO (f)->name_list_element));

  if (FRAME_OUTPUT_DATA (f)->parent_desc == FRAME_DISPLAY_INFO (f)->root_window)
    tem = Qnil;
  else
    tem = make_fixed_natnum ((uintptr_t) FRAME_OUTPUT_DATA (f)->parent_desc);
  store_in_alist (alistptr, Qexplicit_name, (f->explicit_name ? Qt : Qnil));
  store_in_alist (alistptr, Qparent_id, tem);
  store_in_alist (alistptr, Qtool_bar_position, FRAME_TOOL_BAR_POSITION (f));
}


/* Change the `fullscreen' frame parameter of frame F.  OLD_VALUE is
   the previous value of that parameter, NEW_VALUE is the new value. */

void
gui_set_fullscreen (struct frame *f, Lisp_Object new_value, Lisp_Object old_value)
{
  if (NILP (new_value))
    f->want_fullscreen = FULLSCREEN_NONE;
  else if (EQ (new_value, Qfullboth) || EQ (new_value, Qfullscreen))
    f->want_fullscreen = FULLSCREEN_BOTH;
  else if (EQ (new_value, Qfullwidth))
    f->want_fullscreen = FULLSCREEN_WIDTH;
  else if (EQ (new_value, Qfullheight))
    f->want_fullscreen = FULLSCREEN_HEIGHT;
  else if (EQ (new_value, Qmaximized))
    f->want_fullscreen = FULLSCREEN_MAXIMIZED;

  if (FRAME_TERMINAL (f)->fullscreen_hook != NULL)
    FRAME_TERMINAL (f)->fullscreen_hook (f);
}


/* Change the `line-spacing' frame parameter of frame F.  OLD_VALUE is
   the previous value of that parameter, NEW_VALUE is the new value.  */

void
gui_set_line_spacing (struct frame *f, Lisp_Object new_value, Lisp_Object old_value)
{
  if (NILP (new_value))
    f->extra_line_spacing = 0;
  else if (RANGED_FIXNUMP (0, new_value, INT_MAX))
    f->extra_line_spacing = XFIXNAT (new_value);
  else if (FLOATP (new_value))
    {
      int new_spacing = XFLOAT_DATA (new_value) * FRAME_LINE_HEIGHT (f) + 0.5;

      if (new_spacing >= 0)
	f->extra_line_spacing = new_spacing;
      else
	signal_error ("Invalid line-spacing", new_value);
    }
  else
    signal_error ("Invalid line-spacing", new_value);
  if (FRAME_VISIBLE_P (f))
    redraw_frame (f);
}


/* Change the `screen-gamma' frame parameter of frame F.  OLD_VALUE is
   the previous value of that parameter, NEW_VALUE is the new value.  */

void
gui_set_screen_gamma (struct frame *f, Lisp_Object new_value, Lisp_Object old_value)
{
  Lisp_Object bgcolor;

  if (NILP (new_value))
    f->gamma = 0;
  else if (NUMBERP (new_value) && XFLOATINT (new_value) > 0)
    /* The value 0.4545 is the normal viewing gamma.  */
    f->gamma = 1.0 / (0.4545 * XFLOATINT (new_value));
  else
    signal_error ("Invalid screen-gamma", new_value);

  /* Apply the new gamma value to the frame background.  */
  bgcolor = Fassq (Qbackground_color, f->param_alist);
  if (CONSP (bgcolor) && (bgcolor = XCDR (bgcolor), STRINGP (bgcolor)))
    handle_frame_param (f, Qbackground_color, bgcolor, Qnil);

  clear_face_cache (true);	/* FIXME: Why of all frames?  */
  fset_redisplay (f);
}


void
gui_set_font (struct frame *f, Lisp_Object arg, Lisp_Object oldval)
{
  Lisp_Object font_object;
  int fontset = -1, iwidth;

  /* Set the frame parameter back to the old value because we may
     fail to use ARG as the new parameter value.  */
  store_frame_param (f, Qfont, oldval);

  /* ARG is a fontset name, a font name, a cons of fontset name and a
     font object, or a font object.  In the last case, this function
     never fail.  */
  if (STRINGP (arg))
    {
      fontset = fs_query_fontset (arg, 0);
      if (fontset < 0)
	{
	  font_object = font_open_by_name (f, arg);
	  if (NILP (font_object))
	    error ("Font `%s' is not defined", SSDATA (arg));
	  arg = AREF (font_object, FONT_NAME_INDEX);
	}
      else if (fontset > 0)
	{
	  font_object = font_open_by_name (f, fontset_ascii (fontset));
	  if (NILP (font_object))
	    error ("Font `%s' is not defined", SDATA (arg));
	  arg = AREF (font_object, FONT_NAME_INDEX);
	}
      else
	error ("The default fontset can't be used for a frame font");
    }
  else if (CONSP (arg) && STRINGP (XCAR (arg)) && FONT_OBJECT_P (XCDR (arg)))
    {
      /* This is the case that the ASCII font of F's fontset XCAR
	 (arg) is changed to the font XCDR (arg) by
	 `set-fontset-font'.  */
      fontset = fs_query_fontset (XCAR (arg), 0);
      if (fontset < 0)
	error ("Unknown fontset: %s", SDATA (XCAR (arg)));
      font_object = XCDR (arg);
      arg = AREF (font_object, FONT_NAME_INDEX);
    }
  else if (FONT_OBJECT_P (arg))
    {
      font_object = arg;
      /* This is to store the XLFD font name in the frame parameter for
	 backward compatibility.  We should store the font-object
	 itself in the future.  */
      arg = AREF (font_object, FONT_NAME_INDEX);
      fontset = FRAME_FONTSET (f);
      /* Check if we can use the current fontset.  If not, set FONTSET
	 to -1 to generate a new fontset from FONT-OBJECT.  */
      if (fontset >= 0)
	{
	  Lisp_Object ascii_font = fontset_ascii (fontset);
	  Lisp_Object spec = font_spec_from_name (ascii_font);

	  /* SPEC might be nil because ASCII_FONT's name doesn't parse
	     according to stupid XLFD rules, which, for example,
	     disallow font names that include a dash followed by a
	     number.  So in those cases we simply call
	     set_new_font_hook below to generate a new fontset.  */
	  if (NILP (spec) || ! font_match_p (spec, font_object))
	    fontset = -1;
	}
    }
  else
    signal_error ("Invalid font", arg);

  if (! NILP (Fequal (font_object, oldval)))
    return;

  if (FRAME_TERMINAL (f)->set_new_font_hook)
    FRAME_TERMINAL (f)->set_new_font_hook (f, font_object, fontset);
  store_frame_param (f, Qfont, arg);

  /* Recalculate tabbar height.  */
  f->n_tab_bar_rows = 0;
  /* Recalculate toolbar height.  */
  f->n_tool_bar_rows = 0;

  /* Re-initialize F's image cache.  Since `set_new_font_hook' might
     have changed the frame's column width, by which images are scaled,
     it might likewise need to be assigned a different image cache, or
     have its existing cache adjusted, if by coincidence it is its sole
     user.  */

  iwidth = max (10, FRAME_COLUMN_WIDTH (f));
  if (FRAME_IMAGE_CACHE (f)
      && (iwidth != FRAME_IMAGE_CACHE (f)->scaling_col_width))
    {
      eassert (FRAME_IMAGE_CACHE (f)->refcount >= 1);
      if (FRAME_IMAGE_CACHE (f)->refcount == 1)
	{
	  /* This frame is the only user of this image cache.  */
	  FRAME_IMAGE_CACHE (f)->scaling_col_width = iwidth;
	  /* Clean F's image cache of images whose values are derived
	     from the font width.  */
	  clear_image_cache (f, Qauto);
	}
      else
	{
	  /* Release the current image cache, and reuse or allocate a
	     new image cache with IWIDTH.  */
	  FRAME_IMAGE_CACHE (f)->refcount--;
	  FRAME_IMAGE_CACHE (f) = share_image_cache (f);
	  FRAME_IMAGE_CACHE (f)->refcount++;
	}
    }

  /* Ensure we redraw it.  */
  clear_current_matrices (f);

  /* Attempt to hunt down bug#16028.  */
  SET_FRAME_GARBAGED (f);

  /* This is important if we are called by some Lisp as part of
     redisplaying the frame, see redisplay_internal.  */
  f->fonts_changed = true;

  recompute_basic_faces (f);

  do_pending_window_change (0);

  /* We used to call face-set-after-frame-default here, but it leads to
     recursive calls (since that function can set the `default' face's
     font which in turns changes the frame's `font' parameter).
     Also I don't know what this call is meant to do, but it seems the
     wrong way to do it anyway (it does a lot more work than what seems
     reasonable in response to a change to `font').  */
}


void
gui_set_font_backend (struct frame *f, Lisp_Object new_value, Lisp_Object old_value)
{
  if (! NILP (new_value)
      && !CONSP (new_value))
    {
      char *p0, *p1;

      CHECK_STRING (new_value);
      p0 = p1 = SSDATA (new_value);
      new_value = Qnil;
      while (*p0)
	{
	  while (*p1 && ! c_isspace (*p1) && *p1 != ',') p1++;
	  if (p0 < p1)
	    new_value = Fcons (Fintern (make_string (p0, p1 - p0), Qnil),
			       new_value);
	  if (*p1)
	    {
	      int c;

	      while ((c = *++p1) && c_isspace (c));
	    }
	  p0 = p1;
	}
      new_value = Fnreverse (new_value);
    }

  if (! NILP (old_value) && ! NILP (Fequal (old_value, new_value)))
    return;

  if (FRAME_FONT (f))
    {
      Lisp_Object frame;
      XSETFRAME (frame, f);
      free_all_realized_faces (frame);
    }

  new_value = font_update_drivers (f, NILP (new_value) ? Qt : new_value);
  if (NILP (new_value))
    {
      if (NILP (old_value))
	error ("No font backend available");
      font_update_drivers (f, old_value);
      error ("None of specified font backends are available");
    }
  store_frame_param (f, Qfont_backend, new_value);

  if (FRAME_FONT (f))
    {
      /* Reconsider default font after backend(s) change (Bug#23386).  */
      FRAME_RIF (f)->default_font_parameter (f, Qnil);
      face_change = true;
      windows_or_buffers_changed = 18;
    }
}

void
gui_set_left_fringe (struct frame *f, Lisp_Object new_value, Lisp_Object old_value)
{
  int unit = FRAME_COLUMN_WIDTH (f);
  int old_width = FRAME_LEFT_FRINGE_WIDTH (f);
  int new_width;

  new_width = (RANGED_FIXNUMP (-INT_MAX, new_value, INT_MAX)
	       ? eabs (XFIXNUM (new_value)) : 8);

  if (new_width != old_width)
    {
      f->left_fringe_width = new_width;
      f->fringe_cols /* Round up.  */
	= (new_width + FRAME_RIGHT_FRINGE_WIDTH (f) + unit - 1) / unit;

      if (FRAME_NATIVE_WINDOW (f) != 0)
	adjust_frame_size (f, -1, -1, 3, 0, Qleft_fringe);

      SET_FRAME_GARBAGED (f);
    }
}


void
gui_set_right_fringe (struct frame *f, Lisp_Object new_value, Lisp_Object old_value)
{
  int unit = FRAME_COLUMN_WIDTH (f);
  int old_width = FRAME_RIGHT_FRINGE_WIDTH (f);
  int new_width;

  new_width = (RANGED_FIXNUMP (-INT_MAX, new_value, INT_MAX)
	       ? eabs (XFIXNUM (new_value)) : 8);

  if (new_width != old_width)
    {
      f->right_fringe_width = new_width;
      f->fringe_cols /* Round up.  */
	= (new_width + FRAME_LEFT_FRINGE_WIDTH (f) + unit - 1) / unit;

      if (FRAME_NATIVE_WINDOW (f) != 0)
	adjust_frame_size (f, -1, -1, 3, 0, Qright_fringe);

      SET_FRAME_GARBAGED (f);
    }
}


void
gui_set_border_width (struct frame *f, Lisp_Object arg, Lisp_Object oldval)
{
  int border_width = check_integer_range (arg, INT_MIN, INT_MAX);

  if (border_width == f->border_width)
    return;

  if (FRAME_NATIVE_WINDOW (f) != 0)
    error ("Cannot change the border width of a frame");

  f->border_width = border_width;
}

void
gui_set_right_divider_width (struct frame *f, Lisp_Object arg, Lisp_Object oldval)
{
  int old = FRAME_RIGHT_DIVIDER_WIDTH (f);
  int new = check_int_nonnegative (arg);
  if (new != old)
    {
      f->right_divider_width = new;
      adjust_frame_size (f, -1, -1, 4, 0, Qright_divider_width);
      adjust_frame_glyphs (f);
      SET_FRAME_GARBAGED (f);
    }
}

void
gui_set_bottom_divider_width (struct frame *f, Lisp_Object arg, Lisp_Object oldval)
{
  int old = FRAME_BOTTOM_DIVIDER_WIDTH (f);
  int new = check_int_nonnegative (arg);
  if (new != old)
    {
      f->bottom_divider_width = new;
      adjust_frame_size (f, -1, -1, 4, 0, Qbottom_divider_width);
      adjust_frame_glyphs (f);
      SET_FRAME_GARBAGED (f);
    }
}

void
gui_set_visibility (struct frame *f, Lisp_Object value, Lisp_Object oldval)
{
  Lisp_Object frame;
  XSETFRAME (frame, f);

  if (NILP (value))
    Fmake_frame_invisible (frame, Qt);
  else if (EQ (value, Qicon))
    Ficonify_frame (frame);
  else
    Fmake_frame_visible (frame);
}

void
gui_set_autoraise (struct frame *f, Lisp_Object arg, Lisp_Object oldval)
{
  f->auto_raise = !NILP (arg);
}

void
gui_set_autolower (struct frame *f, Lisp_Object arg, Lisp_Object oldval)
{
  f->auto_lower = !NILP (arg);
}

void
gui_set_unsplittable (struct frame *f, Lisp_Object arg, Lisp_Object oldval)
{
  f->no_split = !NILP (arg);
}

void
gui_set_vertical_scroll_bars (struct frame *f, Lisp_Object arg, Lisp_Object oldval)
{
  if ((EQ (arg, Qleft) && FRAME_HAS_VERTICAL_SCROLL_BARS_ON_RIGHT (f))
      || (EQ (arg, Qright) && FRAME_HAS_VERTICAL_SCROLL_BARS_ON_LEFT (f))
      || (NILP (arg) && FRAME_HAS_VERTICAL_SCROLL_BARS (f))
      || (!NILP (arg) && !FRAME_HAS_VERTICAL_SCROLL_BARS (f)))
    {
      FRAME_VERTICAL_SCROLL_BAR_TYPE (f)
	= (NILP (arg)
	   ? vertical_scroll_bar_none
	   : EQ (Qleft, arg)
	   ? vertical_scroll_bar_left
	   : EQ (Qright, arg)
	   ? vertical_scroll_bar_right
	   : EQ (Qleft, Vdefault_frame_scroll_bars)
	   ? vertical_scroll_bar_left
	   : EQ (Qright, Vdefault_frame_scroll_bars)
	   ? vertical_scroll_bar_right
	   : vertical_scroll_bar_none);

      /* We set this parameter before creating the native window for
	 the frame, so we can get the geometry right from the start.
	 However, if the window hasn't been created yet, we shouldn't
	 call set_window_size_hook.  */
      if (FRAME_NATIVE_WINDOW (f))
	adjust_frame_size (f, -1, -1, 3, 0, Qvertical_scroll_bars);

      SET_FRAME_GARBAGED (f);
    }
}

void
gui_set_horizontal_scroll_bars (struct frame *f, Lisp_Object arg, Lisp_Object oldval)
{
#if USE_HORIZONTAL_SCROLL_BARS
  if ((NILP (arg) && FRAME_HAS_HORIZONTAL_SCROLL_BARS (f))
      || (!NILP (arg) && !FRAME_HAS_HORIZONTAL_SCROLL_BARS (f)))
    {
      f->horizontal_scroll_bars = NILP (arg) ? false : true;

      /* We set this parameter before creating the native window for
	 the frame, so we can get the geometry right from the start.
	 However, if the window hasn't been created yet, we shouldn't
	 call set_window_size_hook.  */
      if (FRAME_NATIVE_WINDOW (f))
	adjust_frame_size (f, -1, -1, 3, 0, Qhorizontal_scroll_bars);

      SET_FRAME_GARBAGED (f);
    }
#endif
}

void
gui_set_scroll_bar_width (struct frame *f, Lisp_Object arg, Lisp_Object oldval)
{
  int unit = FRAME_COLUMN_WIDTH (f);

  if (RANGED_FIXNUMP (1, arg, INT_MAX))
    {
      if (XFIXNAT (arg) == FRAME_CONFIG_SCROLL_BAR_WIDTH (f))
	return;
      else
	{
	  FRAME_CONFIG_SCROLL_BAR_WIDTH (f) = XFIXNAT (arg);
	  FRAME_CONFIG_SCROLL_BAR_COLS (f) = (XFIXNAT (arg) + unit - 1) / unit;
	  if (FRAME_NATIVE_WINDOW (f))
	    adjust_frame_size (f, -1, -1, 3, 0, Qscroll_bar_width);

	  SET_FRAME_GARBAGED (f);
	}
    }
  else
    {
      if (FRAME_TERMINAL (f)->set_scroll_bar_default_width_hook)
        FRAME_TERMINAL (f)->set_scroll_bar_default_width_hook (f);

      if (FRAME_NATIVE_WINDOW (f))
	adjust_frame_size (f, -1, -1, 3, 0, Qscroll_bar_width);

      SET_FRAME_GARBAGED (f);
    }

  XWINDOW (FRAME_SELECTED_WINDOW (f))->cursor.hpos = 0;
  XWINDOW (FRAME_SELECTED_WINDOW (f))->cursor.x = 0;
}

void
gui_set_scroll_bar_height (struct frame *f, Lisp_Object arg, Lisp_Object oldval)
{
#if USE_HORIZONTAL_SCROLL_BARS
  int unit = FRAME_LINE_HEIGHT (f);

  if (RANGED_FIXNUMP (1, arg, INT_MAX))
    {
      if (XFIXNAT (arg) == FRAME_CONFIG_SCROLL_BAR_HEIGHT (f))
	return;
      else
	{
	  FRAME_CONFIG_SCROLL_BAR_HEIGHT (f) = XFIXNAT (arg);
	  FRAME_CONFIG_SCROLL_BAR_LINES (f) = (XFIXNAT (arg) + unit - 1) / unit;
	  if (FRAME_NATIVE_WINDOW (f))
	    adjust_frame_size (f, -1, -1, 3, 0, Qscroll_bar_height);

	  SET_FRAME_GARBAGED (f);
	}
    }
  else
    {
      if (FRAME_TERMINAL (f)->set_scroll_bar_default_height_hook)
        FRAME_TERMINAL (f)->set_scroll_bar_default_height_hook (f);

      if (FRAME_NATIVE_WINDOW (f))
	adjust_frame_size (f, -1, -1, 3, 0, Qscroll_bar_height);

      SET_FRAME_GARBAGED (f);
    }

  XWINDOW (FRAME_SELECTED_WINDOW (f))->cursor.vpos = 0;
  XWINDOW (FRAME_SELECTED_WINDOW (f))->cursor.y = 0;
#endif
}

void
gui_set_alpha (struct frame *f, Lisp_Object arg, Lisp_Object oldval)
{
  double alpha = 1.0;
  double newval[2];
  int i;
  Lisp_Object item;

  for (i = 0; i < 2; i++)
    {
      newval[i] = 1.0;
      if (CONSP (arg))
        {
          item = CAR (arg);
          arg  = CDR (arg);
        }
      else
        item = arg;

      if (NILP (item))
	alpha = - 1.0;
      else if (FLOATP (item))
	{
	  alpha = XFLOAT_DATA (item);
	  if (! (0 <= alpha && alpha <= 1.0))
	    args_out_of_range (make_float (0.0), make_float (1.0));
	}
      else if (FIXNUMP (item))
	{
	  EMACS_INT ialpha = XFIXNUM (item);
	  if (! (0 <= ialpha && ialpha <= 100))
	    args_out_of_range (make_fixnum (0), make_fixnum (100));
	  alpha = ialpha / 100.0;
	}
      else
	wrong_type_argument (Qnumberp, item);
      newval[i] = alpha;
    }

  for (i = 0; i < 2; i++)
    f->alpha[i] = newval[i];

  if (FRAME_TERMINAL (f)->set_frame_alpha_hook)
    {
      block_input ();
      FRAME_TERMINAL (f)->set_frame_alpha_hook (f);
      unblock_input ();
    }
}

void
gui_set_alpha_background (struct frame *f, Lisp_Object arg, Lisp_Object oldval)
{
  double alpha = 1.0;

  if (NILP (arg))
    alpha = 1.0;
  else if (FLOATP (arg))
    {
      alpha = XFLOAT_DATA (arg);
      if (! (0 <= alpha && alpha <= 1.0))
	args_out_of_range (make_float (0.0), make_float (1.0));
    }
  else if (FIXNUMP (arg))
    {
      EMACS_INT ialpha = XFIXNUM (arg);
      if (! (0 <= ialpha && ialpha <= 100))
	args_out_of_range (make_fixnum (0), make_fixnum (100));
      alpha = ialpha / 100.0;
    }
  else
    wrong_type_argument (Qnumberp, arg);

  f->alpha_background = alpha;

  recompute_basic_faces (f);
  SET_FRAME_GARBAGED (f);
}

/**
 * gui_set_no_special_glyphs:
 *
 * Set frame F's `no-special-glyphs' parameter which, if non-nil,
 * suppresses the display of truncation and continuation glyphs
 * outside fringes.
 */
void
gui_set_no_special_glyphs (struct frame *f, Lisp_Object new_value, Lisp_Object old_value)
{
  if (!EQ (new_value, old_value))
    FRAME_NO_SPECIAL_GLYPHS (f) = !NILP (new_value);
}


/* Non-zero if mouse is grabbed on DPYINFO
   and we know the frame where it is.  */

bool
gui_mouse_grabbed (Display_Info *dpyinfo)
{
  return ((dpyinfo->grabbed
	   || (dpyinfo->terminal->any_grab_hook
	       && dpyinfo->terminal->any_grab_hook (dpyinfo)))
	  && dpyinfo->last_mouse_frame
	  && FRAME_LIVE_P (dpyinfo->last_mouse_frame));
}

/* Re-highlight something with mouse-face properties
   on DPYINFO using saved frame and mouse position.  */

void
gui_redo_mouse_highlight (Display_Info *dpyinfo)
{
  if (dpyinfo->last_mouse_motion_frame
      && FRAME_LIVE_P (dpyinfo->last_mouse_motion_frame))
    note_mouse_highlight (dpyinfo->last_mouse_motion_frame,
			  dpyinfo->last_mouse_motion_x,
			  dpyinfo->last_mouse_motion_y);
}

/* Subroutines of creating an X frame.  */

/* Make sure that Vx_resource_name is set to a reasonable value.
   Fix it up, or set it to `emacs' if it is too hopeless.  */

void
validate_x_resource_name (void)
{
  ptrdiff_t len = 0;
  /* Number of valid characters in the resource name.  */
  ptrdiff_t good_count = 0;
  /* Number of invalid characters in the resource name.  */
  ptrdiff_t bad_count = 0;
  Lisp_Object new;
  ptrdiff_t i;

  if (!STRINGP (Vx_resource_class))
    Vx_resource_class = build_string (EMACS_CLASS);

  if (STRINGP (Vx_resource_name))
    {
      unsigned char *p = SDATA (Vx_resource_name);

      len = SBYTES (Vx_resource_name);

      /* Only letters, digits, - and _ are valid in resource names.
	 Count the valid characters and count the invalid ones.  */
      for (i = 0; i < len; i++)
	{
	  int c = p[i];
	  if (! ((c >= 'a' && c <= 'z')
		 || (c >= 'A' && c <= 'Z')
		 || (c >= '0' && c <= '9')
		 || c == '-' || c == '_'))
	    bad_count++;
	  else
	    good_count++;
	}
    }
  else
    /* Not a string => completely invalid.  */
    bad_count = 5, good_count = 0;

  /* If name is valid already, return.  */
  if (bad_count == 0)
    return;

  /* If name is entirely invalid, or nearly so, or is so implausibly
     large that alloca might not work, use `emacs'.  */
  if (good_count < 2 || MAX_ALLOCA - sizeof ".customization" < len)
    {
      Vx_resource_name = build_string ("emacs");
      return;
    }

  /* Name is partly valid.  Copy it and replace the invalid characters
     with underscores.  */

  Vx_resource_name = new = Fcopy_sequence (Vx_resource_name);

  for (i = 0; i < len; i++)
    {
      int c = SREF (new, i);
      if (! ((c >= 'a' && c <= 'z')
	     || (c >= 'A' && c <= 'Z')
	     || (c >= '0' && c <= '9')
	     || c == '-' || c == '_'))
	SSET (new, i, '_');
    }
}

/* Get a GUI resource, like Fx_get_resource, but for display DPYINFO.
   See Fx_get_resource below for other parameters.  */

Lisp_Object
gui_display_get_resource (Display_Info *dpyinfo, Lisp_Object attribute,
                          Lisp_Object class, Lisp_Object component,
                          Lisp_Object subclass)
{
  CHECK_STRING (attribute);
  CHECK_STRING (class);

  if (!NILP (component))
    CHECK_STRING (component);
  if (!NILP (subclass))
    CHECK_STRING (subclass);
  if (NILP (component) != NILP (subclass))
    error ("x-get-resource: must specify both COMPONENT and SUBCLASS or neither");

  validate_x_resource_name ();

  /* Allocate space for the components, the dots which separate them,
     and the final '\0'.  Make them big enough for the worst case.  */
  ptrdiff_t name_keysize = (SBYTES (Vx_resource_name)
			    + (STRINGP (component)
			       ? SBYTES (component) : 0)
			    + SBYTES (attribute)
			    + 3);

  ptrdiff_t class_keysize = (SBYTES (Vx_resource_class)
			     + SBYTES (class)
			     + (STRINGP (subclass)
				? SBYTES (subclass) : 0)
			     + 3);
  USE_SAFE_ALLOCA;
  char *name_key = SAFE_ALLOCA (name_keysize + class_keysize);
  char *class_key = name_key + name_keysize;

  /* Start with emacs.FRAMENAME for the name (the specific one)
     and with `Emacs' for the class key (the general one).  */
  char *nz = lispstpcpy (name_key, Vx_resource_name);
  char *cz = lispstpcpy (class_key, Vx_resource_class);

  *cz++ = '.';
  cz = lispstpcpy (cz, class);

  if (!NILP (component))
    {
      *cz++ = '.';
      lispstpcpy (cz, subclass);

      *nz++ = '.';
      nz = lispstpcpy (nz, component);
    }

  *nz++ = '.';
  lispstpcpy (nz, attribute);

#ifndef HAVE_ANDROID
  const char *value
    = dpyinfo->terminal->get_string_resource_hook (&dpyinfo->rdb,
						   name_key,
						   class_key);

  SAFE_FREE ();

  if (value && *value)
    return build_string (value);
  else
    return Qnil;
#else

  SAFE_FREE ();
  return Qnil;
#endif
}


DEFUN ("x-get-resource", Fx_get_resource, Sx_get_resource, 2, 4, 0,
       doc: /* Return the value of ATTRIBUTE, of class CLASS, from the X defaults database.
This uses `INSTANCE.ATTRIBUTE' as the key and `Emacs.CLASS' as the
class, where INSTANCE is the name under which Emacs was invoked, or
the name specified by the `-name' or `-rn' command-line arguments.

The optional arguments COMPONENT and SUBCLASS add to the key and the
class, respectively.  You must specify both of them or neither.
If you specify them, the key is `INSTANCE.COMPONENT.ATTRIBUTE'
and the class is `Emacs.CLASS.SUBCLASS'.  */)
  (Lisp_Object attribute, Lisp_Object class, Lisp_Object component,
   Lisp_Object subclass)
{
  check_window_system (NULL);

  return gui_display_get_resource (check_x_display_info (Qnil),
                                   attribute, class, component, subclass);
}

#if defined HAVE_X_WINDOWS && !defined USE_X_TOOLKIT && !defined USE_GTK
/* Used when C code wants a resource value.  */
/* Called from oldXMenu/Create.c.  */
const char *
x_get_resource_string (const char *attribute, const char *class)
{
  const char *result;
  struct frame *sf = SELECTED_FRAME ();
  ptrdiff_t invocation_namelen = SBYTES (Vinvocation_name);
  USE_SAFE_ALLOCA;

  /* Allocate space for the components, the dots which separate them,
     and the final '\0'.  */
  ptrdiff_t name_keysize = invocation_namelen + strlen (attribute) + 2;
  ptrdiff_t class_keysize = sizeof (EMACS_CLASS) - 1 + strlen (class) + 2;
  char *name_key = SAFE_ALLOCA (name_keysize + class_keysize);
  char *class_key = name_key + name_keysize;
  esprintf (name_key, "%s.%s", SSDATA (Vinvocation_name), attribute);
  sprintf (class_key, "%s.%s", EMACS_CLASS, class);

  result = x_get_string_resource (&FRAME_DISPLAY_INFO (sf)->rdb,
				  name_key, class_key);
  SAFE_FREE ();
  return result;
}
#endif

/* Return the value of parameter PARAM.

   First search ALIST, then Vdefault_frame_alist, then the GUI
   resource database, using ATTRIBUTE as the attribute name and CLASS
   as its class.

   Convert the resource to the type specified by desired_type.

   If no default is specified, return Qunbound.  If you call
   gui_display_get_arg, make sure you deal with Qunbound in a
   reasonable way, and don't let it get stored in any Lisp-visible
   variables!  */

Lisp_Object
gui_display_get_arg (Display_Info *dpyinfo, Lisp_Object alist, Lisp_Object param,
                     const char *attribute, const char *class,
                     enum resource_types type)
{
  Lisp_Object tem;

  tem = Fassq (param, alist);

  if (!NILP (tem))
    {
      /* If we find this parm in ALIST, clear it out
	 so that it won't be "left over" at the end.  */
      Lisp_Object tail;
      XSETCAR (tem, Qnil);
      /* In case the parameter appears more than once in the alist,
	 clear it out.  */
      for (tail = alist; CONSP (tail); tail = XCDR (tail))
	if (CONSP (XCAR (tail))
	    && EQ (XCAR (XCAR (tail)), param))
	  XSETCAR (XCAR (tail), Qnil);
    }
  else
    tem = Fassq (param, Vdefault_frame_alist);

  /* If it wasn't specified in ALIST or the Lisp-level defaults,
     look in the X resources.  */
  if (NILP (tem))
    {
      if (attribute && dpyinfo)
	{
	  AUTO_STRING (at, attribute);
	  AUTO_STRING (cl, class);
	  tem = gui_display_get_resource (dpyinfo, at, cl, Qnil, Qnil);

	  if (NILP (tem))
	    return Qunbound;

	  switch (type)
	    {
	    case RES_TYPE_NUMBER:
	      return make_fixnum (atoi (SSDATA (tem)));

	    case RES_TYPE_BOOLEAN_NUMBER:
	      if (!strcmp (SSDATA (tem), "on")
		  || !strcmp (SSDATA (tem), "true"))
		return make_fixnum (1);
	      return make_fixnum (atoi (SSDATA (tem)));
              break;

	    case RES_TYPE_FLOAT:
	      return make_float (atof (SSDATA (tem)));

	    case RES_TYPE_BOOLEAN:
	      tem = Fdowncase (tem);
	      if (!strcmp (SSDATA (tem), "on")
#ifdef HAVE_NS
                  || !strcmp (SSDATA (tem), "yes")
#endif
		  || !strcmp (SSDATA (tem), "true"))
		return Qt;
	      else
		return Qnil;

	    case RES_TYPE_STRING:
	      return tem;

	    case RES_TYPE_SYMBOL:
	      /* As a special case, we map the values `true' and `on'
		 to Qt, and `false' and `off' to Qnil.  */
	      {
		Lisp_Object lower;
		lower = Fdowncase (tem);
		if (!strcmp (SSDATA (lower), "on")
#ifdef HAVE_NS
                    || !strcmp (SSDATA (lower), "yes")
#endif
		    || !strcmp (SSDATA (lower), "true"))
		  return Qt;
		else if (!strcmp (SSDATA (lower), "off")
#ifdef HAVE_NS
                      || !strcmp (SSDATA (lower), "no")
#endif
		      || !strcmp (SSDATA (lower), "false"))
		  return Qnil;
		else
		  return Fintern (tem, Qnil);
	      }

	    default:
	      emacs_abort ();
	    }
	}
      else
	return Qunbound;
    }
  return Fcdr (tem);
}

static Lisp_Object
gui_frame_get_arg (struct frame *f, Lisp_Object alist, Lisp_Object param,
                   const char *attribute, const char *class,
                   enum resource_types type)
{
  return gui_display_get_arg (FRAME_DISPLAY_INFO (f),
                              alist, param, attribute, class, type);
}

/* Like gui_frame_get_arg, but also record the value in f->param_alist.  */

Lisp_Object
gui_frame_get_and_record_arg (struct frame *f, Lisp_Object alist,
                              Lisp_Object param,
                              const char *attribute, const char *class,
                              enum resource_types type)
{
  Lisp_Object value;

  value = gui_display_get_arg (FRAME_DISPLAY_INFO (f), alist, param,
                               attribute, class, type);
  if (! NILP (value) && ! BASE_EQ (value, Qunbound))
    store_frame_param (f, param, value);

  return value;
}


/* Record in frame F the specified or default value according to ALIST
   of the parameter named PROP (a Lisp symbol).
   If no value is specified for PROP, look for an X default for XPROP
   on the frame named NAME.
   If that is not found either, use the value DEFLT.  */

Lisp_Object
gui_default_parameter (struct frame *f, Lisp_Object alist, Lisp_Object prop,
                       Lisp_Object deflt, const char *xprop, const char *xclass,
                       enum resource_types type)
{
  Lisp_Object tem;
  bool was_unbound;

  tem = gui_frame_get_arg (f, alist, prop, xprop, xclass, type);

  if (BASE_EQ (tem, Qunbound))
    {
      tem = deflt;
      was_unbound = true;
    }
  else
    was_unbound = false;

  AUTO_FRAME_ARG (arg, prop, tem);
  gui_set_frame_parameters_1 (f, arg, was_unbound);
  return tem;
}


#if !defined (HAVE_X_WINDOWS) && defined (NoValue)

/*
 *    XParseGeometry parses strings of the form
 *   "=<width>x<height>{+-}<xoffset>{+-}<yoffset>", where
 *   width, height, xoffset, and yoffset are unsigned integers.
 *   Example:  "=80x24+300-49"
 *   The equal sign is optional.
 *   It returns a bitmask that indicates which of the four values
 *   were actually found in the string.  For each value found,
 *   the corresponding argument is updated;  for each value
 *   not found, the corresponding argument is left unchanged.
 */

static int
XParseGeometry (char *string,
		int *x, int *y,
		unsigned int *width, unsigned int *height)
{
  int mask = NoValue;
  char *strind;
  unsigned long tempWidth UNINIT, tempHeight UNINIT;
  long int tempX UNINIT, tempY UNINIT;
  char *nextCharacter;

  if (string == NULL || *string == '\0')
    return mask;
  if (*string == '=')
    string++;  /* ignore possible '=' at beg of geometry spec */

  strind = string;
  if (*strind != '+' && *strind != '-' && *strind != 'x')
    {
      tempWidth = strtoul (strind, &nextCharacter, 10);
      if (strind == nextCharacter)
	return 0;
      strind = nextCharacter;
      mask |= WidthValue;
    }

  if (*strind == 'x' || *strind == 'X')
    {
      strind++;
      tempHeight = strtoul (strind, &nextCharacter, 10);
      if (strind == nextCharacter)
	return 0;
      strind = nextCharacter;
      mask |= HeightValue;
    }

  if (*strind == '+' || *strind == '-')
    {
      if (*strind == '-')
	mask |= XNegative;
      tempX = strtol (strind, &nextCharacter, 10);
      if (strind == nextCharacter)
	return 0;
      strind = nextCharacter;
      mask |= XValue;
      if (*strind == '+' || *strind == '-')
	{
	  if (*strind == '-')
	    mask |= YNegative;
	  tempY = strtol (strind, &nextCharacter, 10);
	  if (strind == nextCharacter)
	    return 0;
	  strind = nextCharacter;
	  mask |= YValue;
	}
    }

  /* If strind isn't at the end of the string then it's an invalid
     geometry specification. */

  if (*strind != '\0')
    return 0;

  if (mask & XValue)
    *x = clip_to_bounds (INT_MIN, tempX, INT_MAX);
  if (mask & YValue)
    *y = clip_to_bounds (INT_MIN, tempY, INT_MAX);
  if (mask & WidthValue)
    *width = min (tempWidth, UINT_MAX);
  if (mask & HeightValue)
    *height = min (tempHeight, UINT_MAX);
  return mask;
}

#endif /* !defined (HAVE_X_WINDOWS) && defined (NoValue) */


/* NS used to define x-parse-geometry in ns-win.el, but that confused
   make-docfile: the documentation string in ns-win.el was used for
   x-parse-geometry even in non-NS builds.

   With two definitions of x-parse-geometry in this file, various
   things still get confused (eg M-x apropos documentation), so that
   it is best if the two definitions just share the same doc-string.
*/
DEFUN ("x-parse-geometry", Fx_parse_geometry, Sx_parse_geometry, 1, 1, 0,
       doc: /* Parse a display geometry string STRING.
Returns an alist of the form ((top . TOP), (left . LEFT) ... ).
The properties returned may include `top', `left', `height', and `width'.
For X, the value of `left' or `top' may be an integer,
or a list (+ N) meaning N pixels relative to top/left corner,
or a list (- N) meaning -N pixels relative to bottom/right corner.
On Nextstep, this just calls `ns-parse-geometry'.  */)
  (Lisp_Object string)
{
  /* x and y don't need initialization, as they are not accessed
     unless XParseGeometry sets them, in which case it always returns
     a non-zero value.  */
  int x UNINIT, y UNINIT;
  unsigned int width, height;

  width = height = 0;

  CHECK_STRING (string);

#ifdef HAVE_NS
  if (strchr (SSDATA (string), ' ') != NULL)
    return calln (Qns_parse_geometry, string);
#endif
  int geometry = XParseGeometry (SSDATA (string),
				 &x, &y, &width, &height);
  Lisp_Object result = Qnil;
  if (geometry & XValue)
    {
      Lisp_Object element;

      if (x >= 0 && (geometry & XNegative))
	element = list3 (Qleft, Qminus, make_fixnum (-x));
      else if (x < 0 && ! (geometry & XNegative))
	element = list3 (Qleft, Qplus, make_fixnum (x));
      else
	element = Fcons (Qleft, make_fixnum (x));
      result = Fcons (element, result);
    }

  if (geometry & YValue)
    {
      Lisp_Object element;

      if (y >= 0 && (geometry & YNegative))
	element = list3 (Qtop, Qminus, make_fixnum (-y));
      else if (y < 0 && ! (geometry & YNegative))
	element = list3 (Qtop, Qplus, make_fixnum (y));
      else
	element = Fcons (Qtop, make_fixnum (y));
      result = Fcons (element, result);
    }

  if (geometry & WidthValue)
    result = Fcons (Fcons (Qwidth, make_fixnum (width)), result);
  if (geometry & HeightValue)
    result = Fcons (Fcons (Qheight, make_fixnum (height)), result);

  return result;
}


/* Calculate the desired size and position of frame F.
   Return the flags saying which aspects were specified.

   Also set the win_gravity and size_hint_flags of F.

   Adjust height for toolbar if TOOLBAR_P is 1.

   This function does not make the coordinates positive.  */

long
gui_figure_window_size (struct frame *f, Lisp_Object parms, bool tabbar_p,
                        bool toolbar_p)
{
  Lisp_Object height, width, user_size, top, left, user_position;
  long window_prompting = 0;
  Display_Info *dpyinfo = FRAME_DISPLAY_INFO (f);
  int parent_done = -1, outer_done = -1;
  int text_width = 80 * FRAME_COLUMN_WIDTH (f);
  int text_height = 36 * FRAME_LINE_HEIGHT (f);

  /* Window managers expect that if program-specified
     positions are not (0,0), they're intentional, not defaults.  */
  f->top_pos = 0;
  f->left_pos = 0;

  /* Calculate a tab bar height so that the user gets a text display
     area of the size he specified with -g or via .Xdefaults.  Later
     changes of the tab bar height don't change the frame size.  This
     is done so that users can create tall Emacs frames without having
     to guess how tall the tab bar will get.  */
  if (tabbar_p && FRAME_TAB_BAR_LINES (f))
    {
      if (frame_default_tab_bar_height)
	/* A default tab bar height was already set by the display code
	   for some other frame, use that.  */
	FRAME_TAB_BAR_HEIGHT (f) = frame_default_tab_bar_height;
      else
	/* Calculate the height from various other settings.  For some
	   reason, these are usually off by 2 hence of no use.  */
	{
	  int margin, relief;

	  relief = (tab_bar_button_relief < 0
		    ? DEFAULT_TAB_BAR_BUTTON_RELIEF
		    : min (tab_bar_button_relief, 1000000));

	  if (RANGED_FIXNUMP (1, Vtab_bar_button_margin, INT_MAX))
	    margin = XFIXNAT (Vtab_bar_button_margin);
	  else if (CONSP (Vtab_bar_button_margin)
		   && RANGED_FIXNUMP (1, XCDR (Vtab_bar_button_margin), INT_MAX))
	    margin = XFIXNAT (XCDR (Vtab_bar_button_margin));
	  else
	    margin = 0;

	  FRAME_TAB_BAR_HEIGHT (f)
	    = DEFAULT_TAB_BAR_IMAGE_HEIGHT + 2 * margin + 2 * relief;
	}
    }

  /* Calculate a tool bar height so that the user gets a text display
     area of the size he specified with -g or via .Xdefaults.  Later
     changes of the tool bar height don't change the frame size.  This
     is done so that users can create tall Emacs frames without having
     to guess how tall the tool bar will get.  */
  if (toolbar_p && FRAME_TOOL_BAR_LINES (f))
    {
      if (frame_default_tool_bar_height)
	FRAME_TOOL_BAR_HEIGHT (f) = frame_default_tool_bar_height;
      else
	{
	  int margin, relief;

	  relief = (tool_bar_button_relief < 0
		    ? DEFAULT_TOOL_BAR_BUTTON_RELIEF
		    : min (tool_bar_button_relief, 1000000));

	  if (RANGED_FIXNUMP (1, Vtool_bar_button_margin, INT_MAX))
	    margin = XFIXNAT (Vtool_bar_button_margin);
	  else if (CONSP (Vtool_bar_button_margin)
		   && RANGED_FIXNUMP (1, XCDR (Vtool_bar_button_margin), INT_MAX))
	    margin = XFIXNAT (XCDR (Vtool_bar_button_margin));
	  else
	    margin = 0;

	  FRAME_TOOL_BAR_HEIGHT (f)
	    = DEFAULT_TOOL_BAR_IMAGE_HEIGHT + 2 * margin + 2 * relief;
	}
    }

  /* Ensure that earlier new_width and new_height settings won't
     override what we specify below.  */
  f->new_width = f->new_height = -1;

  height = gui_display_get_arg (dpyinfo, parms, Qheight, 0, 0, RES_TYPE_NUMBER);
  width = gui_display_get_arg (dpyinfo, parms, Qwidth, 0, 0, RES_TYPE_NUMBER);
  if (!BASE_EQ (width, Qunbound) || !BASE_EQ (height, Qunbound))
    {
      if (!BASE_EQ (width, Qunbound))
	{
	  if (CONSP (width) && EQ (XCAR (width), Qtext_pixels))
	    {
	      CHECK_FIXNUM (XCDR (width));
	      if ((XFIXNUM (XCDR (width)) < 0 || XFIXNUM (XCDR (width)) > INT_MAX))
		xsignal1 (Qargs_out_of_range, XCDR (width));

	      text_width = XFIXNUM (XCDR (width));
	    }
	  else if (FLOATP (width))
	    {
	      double d_width = XFLOAT_DATA (width);

	      if (d_width < 0.0 || d_width > 1.0)
		xsignal1 (Qargs_out_of_range, width);
	      else
		{
		  int new_width = frame_float (f, width, FRAME_FLOAT_WIDTH,
					       &parent_done, &outer_done, -1);

		  if (new_width > -1)
		    text_width = new_width;
		}
	    }
	  else
	    {
	      CHECK_FIXNUM (width);
	      if ((XFIXNUM (width) < 0 || XFIXNUM (width) > INT_MAX))
		xsignal1 (Qargs_out_of_range, width);

	      text_width = XFIXNUM (width) * FRAME_COLUMN_WIDTH (f);
	    }
	}

      if (!BASE_EQ (height, Qunbound))
	{
	  if (CONSP (height) && EQ (XCAR (height), Qtext_pixels))
	    {
	      CHECK_FIXNUM (XCDR (height));
	      if ((XFIXNUM (XCDR (height)) < 0 || XFIXNUM (XCDR (height)) > INT_MAX))
		xsignal1 (Qargs_out_of_range, XCDR (height));

	      text_height = XFIXNUM (XCDR (height));
	    }
	  else if (FLOATP (height))
	    {
	      double d_height = XFLOAT_DATA (height);

	      if (d_height < 0.0 || d_height > 1.0)
		xsignal1 (Qargs_out_of_range, height);
	      else
		{
		  int new_height = frame_float (f, height, FRAME_FLOAT_HEIGHT,
						&parent_done, &outer_done, -1);

		  if (new_height > -1)
		    text_height = new_height;
		}
	    }
	  else
	    {
	      CHECK_FIXNUM (height);
	      if ((XFIXNUM (height) < 0) || (XFIXNUM (height) > INT_MAX))
		xsignal1 (Qargs_out_of_range, height);

	      text_height = XFIXNUM (height) * FRAME_LINE_HEIGHT (f);
	    }
	}

      user_size = gui_display_get_arg (dpyinfo, parms, Quser_size, 0, 0,
                                       RES_TYPE_NUMBER);
      if (!NILP (user_size) && !BASE_EQ (user_size, Qunbound))
	window_prompting |= USSize;
      else
	window_prompting |= PSize;
    }

  adjust_frame_size (f, text_width, text_height, 5, false,
		     Qgui_figure_window_size);

  top = gui_display_get_arg (dpyinfo, parms, Qtop, 0, 0, RES_TYPE_NUMBER);
  left = gui_display_get_arg (dpyinfo, parms, Qleft, 0, 0, RES_TYPE_NUMBER);
  user_position = gui_display_get_arg (dpyinfo, parms, Quser_position, 0, 0,
                                       RES_TYPE_NUMBER);
  if (! BASE_EQ (top, Qunbound) || ! BASE_EQ (left, Qunbound))
    {
      if (EQ (top, Qminus))
	{
	  f->top_pos = 0;
	  window_prompting |= YNegative;
	}
      else if (CONSP (top) && EQ (XCAR (top), Qminus)
	       && CONSP (XCDR (top))
	       && RANGED_FIXNUMP (-INT_MAX, XCAR (XCDR (top)), INT_MAX))
	{
	  f->top_pos = - XFIXNUM (XCAR (XCDR (top)));
	  window_prompting |= YNegative;
	}
      else if (CONSP (top) && EQ (XCAR (top), Qplus)
	       && CONSP (XCDR (top))
	       && TYPE_RANGED_FIXNUMP (int, XCAR (XCDR (top))))
	{
	  f->top_pos = XFIXNUM (XCAR (XCDR (top)));
	}
      else if (FLOATP (top))
	f->top_pos = frame_float (f, top, FRAME_FLOAT_TOP, &parent_done,
				  &outer_done, 0);
      else if (BASE_EQ (top, Qunbound))
	f->top_pos = 0;
      else
	{
	  f->top_pos = check_integer_range (top, INT_MIN, INT_MAX);
	  if (f->top_pos < 0)
	    window_prompting |= YNegative;
	}

      if (EQ (left, Qminus))
	{
	  f->left_pos = 0;
	  window_prompting |= XNegative;
	}
      else if (CONSP (left) && EQ (XCAR (left), Qminus)
	       && CONSP (XCDR (left))
	       && RANGED_FIXNUMP (-INT_MAX, XCAR (XCDR (left)), INT_MAX))
	{
	  f->left_pos = - XFIXNUM (XCAR (XCDR (left)));
	  window_prompting |= XNegative;
	}
      else if (CONSP (left) && EQ (XCAR (left), Qplus)
	       && CONSP (XCDR (left))
	       && TYPE_RANGED_FIXNUMP (int, XCAR (XCDR (left))))
	{
	  f->left_pos = XFIXNUM (XCAR (XCDR (left)));
	}
      else if (FLOATP (left))
	f->left_pos = frame_float (f, left, FRAME_FLOAT_LEFT, &parent_done,
				   &outer_done, 0);
      else if (BASE_EQ (left, Qunbound))
	f->left_pos = 0;
      else
	{
	  f->left_pos = check_integer_range (left, INT_MIN, INT_MAX);
	  if (f->left_pos < 0)
	    window_prompting |= XNegative;
	}

      if (!NILP (user_position) && ! BASE_EQ (user_position, Qunbound))
	window_prompting |= USPosition;
      else
	window_prompting |= PPosition;
    }

  if (window_prompting & XNegative)
    {
      if (window_prompting & YNegative)
	f->win_gravity = SouthEastGravity;
      else
	f->win_gravity = NorthEastGravity;
    }
  else
    {
      if (window_prompting & YNegative)
	f->win_gravity = SouthWestGravity;
      else
	f->win_gravity = NorthWestGravity;
    }

  f->size_hint_flags = window_prompting;

  return window_prompting;
}



#endif /* HAVE_WINDOW_SYSTEM */

void
frame_make_pointer_invisible (struct frame *f)
{
  if (! NILP (Vmake_pointer_invisible))
    {
      if (f && FRAME_LIVE_P (f) && !f->pointer_invisible
          && FRAME_TERMINAL (f)->toggle_invisible_pointer_hook)
        {
          f->mouse_moved = 0;
          FRAME_TERMINAL (f)->toggle_invisible_pointer_hook (f, 1);
          f->pointer_invisible = 1;
        }
    }
}

void
frame_make_pointer_visible (struct frame *f)
{
  /* We don't check Vmake_pointer_invisible here in case the
     pointer was invisible when Vmake_pointer_invisible was set to nil.  */
  if (f && FRAME_LIVE_P (f) && f->pointer_invisible && f->mouse_moved
      && FRAME_TERMINAL (f)->toggle_invisible_pointer_hook)
    {
      FRAME_TERMINAL (f)->toggle_invisible_pointer_hook (f, 0);
      f->pointer_invisible = 0;
    }
}

DEFUN ("frame-pointer-visible-p", Fframe_pointer_visible_p,
       Sframe_pointer_visible_p, 0, 1, 0,
       doc: /* Return t if the mouse pointer displayed on FRAME is visible.
Otherwise it returns nil.  FRAME omitted or nil means the
selected frame.  This is useful when `make-pointer-invisible' is set.  */)
  (Lisp_Object frame)
{
  return decode_any_frame (frame)->pointer_invisible ? Qnil : Qt;
}

DEFUN ("mouse-position-in-root-frame", Fmouse_position_in_root_frame,
       Smouse_position_in_root_frame, 0, 0, 0,
       doc: /* Return mouse position in selected frame's root frame.
Return the position of `mouse-position' in coordinates of the root frame
of the frame returned by 'mouse-position'.  */)
  (void)
{
  Lisp_Object pos = mouse_position (true);
  Lisp_Object frame = XCAR (pos);

  if (!FRAMEP (frame))
    return Qnil;
  else
    {
      struct frame *f = XFRAME (frame);
      int x = XFIXNUM (XCAR (XCDR (pos))) + f->left_pos;
      int y = XFIXNUM (XCDR (XCDR (pos))) + f->top_pos;

      f = FRAME_PARENT_FRAME (f);

      while (f)
	{
	  x = x + f->left_pos;
	  y = y + f->top_pos;
	  f = FRAME_PARENT_FRAME (f);
	}

      return Fcons (make_fixnum (x), make_fixnum (y));
    }
}

DEFUN ("frame--set-was-invisible", Fframe__set_was_invisible,
       Sframe__set_was_invisible, 2, 2, 0,
       doc: /* Set FRAME's was-invisible flag if WAS-INVISIBLE is non-nil.
This function is for internal use only.  */)
  (Lisp_Object frame, Lisp_Object was_invisible)
{
  struct frame *f = decode_live_frame (frame);

  f->was_invisible = !NILP (was_invisible);

  return f->was_invisible ? Qt : Qnil;
}

#ifdef HAVE_WINDOW_SYSTEM

DEFUN ("reconsider-frame-fonts", Freconsider_frame_fonts,
       Sreconsider_frame_fonts, 1, 1, 0,
       doc: /* Recreate FRAME's default font using updated font parameters.
Signal an error if FRAME is not a window system frame.  This should be
called after a `config-changed' event is received, signaling that the
parameters (such as pixel density) used by the system to open fonts
have changed.  */)
  (Lisp_Object frame)
{
  struct frame *f;
  Lisp_Object params, font_parameter;

  f = decode_window_system_frame (frame);

  /* Kludge: if a `font' parameter was already specified,
     create an alist containing just that parameter.  (bug#59371)

     This sounds so simple, right?  Well, read on below: */
  params = Qnil;

  /* The difference between Qfont and Qfont_parameter is that the
     latter is not set automatically by the likes of x_new_font, and
     implicitly as the default face is realized.  It is only set when
     the user specifically specifies a `font' frame parameter, and is
     cleared the moment the frame's font becomes defined by a face
     attribute, instead of through the `font' frame parameter.  */
  font_parameter = get_frame_param (f, Qfont_parameter);

  if (!NILP (font_parameter))
    params = list1 (Fcons (Qfont, font_parameter));

  /* First, call this to reinitialize any font backend specific
     stuff.  */

  if (FRAME_RIF (f)->default_font_parameter)
    FRAME_RIF (f)->default_font_parameter (f, params);

  /* For a mysterious reason, x_default_font_parameter sets Qfont to
     nil in the alist!  */

  if (!NILP (font_parameter))
    params = list1 (Fcons (Qfont, font_parameter));

  /* Now call this to apply the existing value(s) of the `default'
     face.  */
  calln (Qface_set_after_frame_default, frame, params);

  /* Restore the value of the `font-parameter' parameter, as
     `face-set-after-frame-default' will have changed it through its
     calls to `set-face-attribute'.  */
  if (!NILP (font_parameter))
    store_frame_param (f, Qfont_parameter, font_parameter);

  return Qnil;
}

#endif


/***********************************************************************
			Multimonitor data
 ***********************************************************************/

#ifdef HAVE_WINDOW_SYSTEM

# if (defined USE_GTK || defined HAVE_PGTK || defined HAVE_NS || defined HAVE_XINERAMA \
      || defined HAVE_XRANDR)
void
free_monitors (struct MonitorInfo *monitors, int n_monitors)
{
  int i;
  for (i = 0; i < n_monitors; ++i)
    xfree (monitors[i].name);
  xfree (monitors);
}
# endif

Lisp_Object
make_monitor_attribute_list (struct MonitorInfo *monitors,
                             int n_monitors,
                             int primary_monitor,
                             Lisp_Object monitor_frames,
                             const char *source)
{
  Lisp_Object attributes_list = Qnil;
  Lisp_Object primary_monitor_attributes = Qnil;
  int i;

  for (i = 0; i < n_monitors; ++i)
    {
      Lisp_Object geometry, workarea, attributes = Qnil;
      struct MonitorInfo *mi = &monitors[i];

      if (mi->geom.width == 0) continue;

      workarea = list4i (mi->work.x, mi->work.y,
			 mi->work.width, mi->work.height);
      geometry = list4i (mi->geom.x, mi->geom.y,
			 mi->geom.width, mi->geom.height);

      if (source)
	attributes = Fcons (Fcons (Qsource, build_string (source)),
			    attributes);

      attributes = Fcons (Fcons (Qframes, AREF (monitor_frames, i)),
			  attributes);
#ifdef HAVE_PGTK
      attributes = Fcons (Fcons (Qscale_factor, make_float (mi->scale_factor)),
			  attributes);
#endif
      attributes = Fcons (Fcons (Qmm_size,
                                 list2i (mi->mm_width, mi->mm_height)),
                          attributes);
      attributes = Fcons (Fcons (Qworkarea, workarea), attributes);
      attributes = Fcons (Fcons (Qgeometry, geometry), attributes);
      if (mi->name)
        attributes = Fcons (Fcons (Qname, make_string (mi->name,
                                                       strlen (mi->name))),
                            attributes);

      if (i == primary_monitor)
        primary_monitor_attributes = attributes;
      else
        attributes_list = Fcons (attributes, attributes_list);
    }

  if (!NILP (primary_monitor_attributes))
    attributes_list = Fcons (primary_monitor_attributes, attributes_list);
  return attributes_list;
}

#endif /* HAVE_WINDOW_SYSTEM */


/***********************************************************************
				Initialization
 ***********************************************************************/

static void init_frame_once_for_pdumper (void);

void
init_frame_once (void)
{
  staticpro (&Vframe_list);
  staticpro (&selected_frame);
  PDUMPER_IGNORE (last_nonminibuf_frame);
  Vframe_list = Qnil;
  selected_frame = Qnil;
  pdumper_do_now_and_after_load (init_frame_once_for_pdumper);
}

static void
init_frame_once_for_pdumper (void)
{
  PDUMPER_RESET_LV (Vframe_list, Qnil);
  PDUMPER_RESET_LV (selected_frame, Qnil);
}

void
syms_of_frame (void)
{
  DEFSYM (Qframep, "framep");
  DEFSYM (Qframe_live_p, "frame-live-p");
  DEFSYM (Qframe_windows_min_size, "frame-windows-min-size");
  DEFSYM (Qframe_monitor_attributes, "frame-monitor-attributes");
  DEFSYM (Qwindow__pixel_to_total, "window--pixel-to-total");
  DEFSYM (Qmake_initial_minibuffer_frame, "make-initial-minibuffer-frame");
  DEFSYM (Qexplicit_name, "explicit-name");
  DEFSYM (Qheight, "height");
  DEFSYM (Qicon, "icon");
  DEFSYM (Qminibuffer, "minibuffer");
  DEFSYM (Qundecorated, "undecorated");
  DEFSYM (Qno_special_glyphs, "no-special-glyphs");
  DEFSYM (Qparent_frame, "parent-frame");
  DEFSYM (Qskip_taskbar, "skip-taskbar");
  DEFSYM (Qno_focus_on_map, "no-focus-on-map");
  DEFSYM (Qno_accept_focus, "no-accept-focus");
  DEFSYM (Qz_group, "z-group");
  DEFSYM (Qoverride_redirect, "override-redirect");
  DEFSYM (Qdelete_before, "delete-before");
  DEFSYM (Qmodeline, "modeline");
  DEFSYM (Qonly, "only");
  DEFSYM (Qnone, "none");
  DEFSYM (Qwidth, "width");
  DEFSYM (Qtext_pixels, "text-pixels");
  DEFSYM (Qgeometry, "geometry");
  DEFSYM (Qicon_left, "icon-left");
  DEFSYM (Qicon_top, "icon-top");
  DEFSYM (Qtooltip, "tooltip");
  DEFSYM (Quser_position, "user-position");
  DEFSYM (Quser_size, "user-size");
  DEFSYM (Qwindow_id, "window-id");
#ifdef HAVE_X_WINDOWS
  DEFSYM (Qouter_window_id, "outer-window-id");
#endif
  DEFSYM (Qparent_id, "parent-id");
  DEFSYM (Qx, "x");
  DEFSYM (Qw32, "w32");
  DEFSYM (Qpc, "pc");
  DEFSYM (Qns, "ns");
  DEFSYM (Qpgtk, "pgtk");
  DEFSYM (Qhaiku, "haiku");
  DEFSYM (Qandroid, "android");
  DEFSYM (Qvisible, "visible");
  DEFSYM (Qbuffer_predicate, "buffer-predicate");
  DEFSYM (Qbuffer_list, "buffer-list");
  DEFSYM (Qburied_buffer_list, "buried-buffer-list");
  DEFSYM (Qdisplay_type, "display-type");
  DEFSYM (Qbackground_mode, "background-mode");
  DEFSYM (Qnoelisp, "noelisp");
  DEFSYM (Qtty_color_mode, "tty-color-mode");
  DEFSYM (Qtty, "tty");
  DEFSYM (Qtty_type, "tty-type");

  DEFSYM (Qface_set_after_frame_default, "face-set-after-frame-default");

  DEFSYM (Qfullwidth, "fullwidth");
  DEFSYM (Qfullheight, "fullheight");
  DEFSYM (Qfullboth, "fullboth");
  DEFSYM (Qmaximized, "maximized");
  DEFSYM (Qshaded, "shaded");
  DEFSYM (Qx_resource_name, "x-resource-name");
  DEFSYM (Qx_frame_parameter, "x-frame-parameter");

  DEFSYM (Qworkarea, "workarea");
  DEFSYM (Qmm_size, "mm-size");
#ifdef HAVE_PGTK
  DEFSYM (Qscale_factor, "scale-factor");
#endif
  DEFSYM (Qframes, "frames");
  DEFSYM (Qsource, "source");

  DEFSYM (Qframe_edges, "frame-edges");
  DEFSYM (Qouter_edges, "outer-edges");
  DEFSYM (Qouter_position, "outer-position");
  DEFSYM (Qouter_size, "outer-size");
  DEFSYM (Qnative_edges, "native-edges");
  DEFSYM (Qinner_edges, "inner-edges");
  DEFSYM (Qexternal_border_size, "external-border-size");
  DEFSYM (Qtitle_bar_size, "title-bar-size");
  DEFSYM (Qmenu_bar_external, "menu-bar-external");
  DEFSYM (Qmenu_bar_size, "menu-bar-size");
  DEFSYM (Qtab_bar_size, "tab-bar-size");
  DEFSYM (Qtool_bar_external, "tool-bar-external");
  DEFSYM (Qtool_bar_size, "tool-bar-size");
  /* The following are passed to adjust_frame_size.  */
  DEFSYM (Qx_set_menu_bar_lines, "x_set_menu_bar_lines");
  DEFSYM (Qchange_frame_size, "change_frame_size");
  DEFSYM (Qxg_frame_set_char_size, "xg_frame_set_char_size");
  DEFSYM (Qx_set_window_size_1, "x_set_window_size_1");
  DEFSYM (Qset_window_configuration, "set_window_configuration");
  DEFSYM (Qx_create_frame_1, "x_create_frame_1");
  DEFSYM (Qx_create_frame_2, "x_create_frame_2");
  DEFSYM (Qgui_figure_window_size, "gui_figure_window_size");
  DEFSYM (Qtip_frame, "tip_frame");
  DEFSYM (Qterminal_frame, "terminal_frame");

#ifdef HAVE_NS
  DEFSYM (Qns_parse_geometry, "ns-parse-geometry");
#endif
#ifdef NS_IMPL_COCOA
  DEFSYM (Qns_appearance, "ns-appearance");
  DEFSYM (Qns_transparent_titlebar, "ns-transparent-titlebar");
#endif

  DEFSYM (Qalpha, "alpha");
  DEFSYM (Qalpha_background, "alpha-background");
  DEFSYM (Qauto_lower, "auto-lower");
  DEFSYM (Qauto_raise, "auto-raise");
  DEFSYM (Qborder_color, "border-color");
  DEFSYM (Qborder_width, "border-width");
  DEFSYM (Qouter_border_width, "outer-border-width");
  DEFSYM (Qbottom_divider_width, "bottom-divider-width");
  DEFSYM (Qcursor_color, "cursor-color");
  DEFSYM (Qcursor_type, "cursor-type");
  DEFSYM (Qfont_backend, "font-backend");
  DEFSYM (Qfullscreen, "fullscreen");
  DEFSYM (Qhorizontal_scroll_bars, "horizontal-scroll-bars");
  DEFSYM (Qicon_name, "icon-name");
  DEFSYM (Qicon_type, "icon-type");
  DEFSYM (Qchild_frame_border_width, "child-frame-border-width");
  DEFSYM (Qinternal_border_width, "internal-border-width");
  DEFSYM (Qleft_fringe, "left-fringe");
  DEFSYM (Qleft_fringe_help, "left-fringe-help");
  DEFSYM (Qline_spacing, "line-spacing");
  DEFSYM (Qmenu_bar_lines, "menu-bar-lines");
  DEFSYM (Qtab_bar_lines, "tab-bar-lines");
  DEFSYM (Qmouse_color, "mouse-color");
  DEFSYM (Qname, "name");
  DEFSYM (Qright_divider_width, "right-divider-width");
  DEFSYM (Qright_fringe, "right-fringe");
  DEFSYM (Qright_fringe_help, "right-fringe-help");
  DEFSYM (Qscreen_gamma, "screen-gamma");
  DEFSYM (Qscroll_bar_background, "scroll-bar-background");
  DEFSYM (Qscroll_bar_foreground, "scroll-bar-foreground");
  DEFSYM (Qscroll_bar_height, "scroll-bar-height");
  DEFSYM (Qscroll_bar_width, "scroll-bar-width");
  DEFSYM (Qsticky, "sticky");
  DEFSYM (Qtitle, "title");
  DEFSYM (Qtool_bar_lines, "tool-bar-lines");
  DEFSYM (Qtool_bar_position, "tool-bar-position");
  DEFSYM (Qunsplittable, "unsplittable");
  DEFSYM (Qvertical_scroll_bars, "vertical-scroll-bars");
  DEFSYM (Qvisibility, "visibility");
  DEFSYM (Qwait_for_wm, "wait-for-wm");
  DEFSYM (Qinhibit_double_buffering, "inhibit-double-buffering");
  DEFSYM (Qno_other_frame, "no-other-frame");
  DEFSYM (Qbelow, "below");
  DEFSYM (Qabove_suspended, "above-suspended");
  DEFSYM (Qmin_width, "min-width");
  DEFSYM (Qmin_height, "min-height");
  DEFSYM (Qmouse_wheel_frame, "mouse-wheel-frame");
  DEFSYM (Qkeep_ratio, "keep-ratio");
  DEFSYM (Qwidth_only, "width-only");
  DEFSYM (Qheight_only, "height-only");
  DEFSYM (Qleft_only, "left-only");
  DEFSYM (Qtop_only, "top-only");
  DEFSYM (Qiconify_top_level, "iconify-top-level");
  DEFSYM (Qmake_invisible, "make-invisible");
  DEFSYM (Quse_frame_synchronization, "use-frame-synchronization");
  DEFSYM (Qfont_parameter, "font-parameter");
  DEFSYM (Qforce, "force");

  for (int i = 0; i < ARRAYELTS (frame_parms); i++)
    {
      int sym = frame_parms[i].sym;
      eassert (sym >= 0 && sym < ARRAYELTS (lispsym));
      Lisp_Object v = builtin_lisp_symbol (sym);
      Fput (v, Qx_frame_parameter, make_fixnum (i));
    }

#ifdef HAVE_WINDOW_SYSTEM
  DEFVAR_LISP ("x-resource-name", Vx_resource_name,
    doc: /* The name Emacs uses to look up X resources.
`x-get-resource' uses this as the first component of the instance name
when requesting resource values.
Emacs initially sets `x-resource-name' to the name under which Emacs
was invoked, or to the value specified with the `-name' or `-rn'
switches, if present.

It may be useful to bind this variable locally around a call
to `x-get-resource'.  See also the variable `x-resource-class'.  */);
  Vx_resource_name = Qnil;

  DEFVAR_LISP ("x-resource-class", Vx_resource_class,
    doc: /* The class Emacs uses to look up X resources.
`x-get-resource' uses this as the first component of the instance class
when requesting resource values.

Emacs initially sets `x-resource-class' to "Emacs".

Setting this variable permanently is not a reasonable thing to do,
but binding this variable locally around a call to `x-get-resource'
is a reasonable practice.  See also the variable `x-resource-name'.  */);
  Vx_resource_class = build_string (EMACS_CLASS);

  DEFVAR_LISP ("frame-alpha-lower-limit", Vframe_alpha_lower_limit,
    doc: /* The lower limit of the frame opacity (alpha transparency).
The value should range from 0 (invisible) to 100 (completely opaque).
You can also use a floating number between 0.0 and 1.0.  */);
  Vframe_alpha_lower_limit = make_fixnum (20);
#endif

  DEFVAR_LISP ("default-frame-alist", Vdefault_frame_alist,
    doc: /* Alist of default values of frame parameters for frame creation.
These may be set in your init file, like this:
  (setq default-frame-alist \\='((width . 80) (height . 55) (menu-bar-lines . 1)))

These override values given in window system configuration data,
including X Windows' defaults database.

Note that many display-related modes (like `scroll-bar-mode' or
`menu-bar-mode') alter `default-frame-alist', so if you set this
variable directly, you may be overriding other settings
unintentionally.  Instead it's often better to use
`modify-all-frames-parameters' or push new elements to the front of
this alist.

For values specific to the first Emacs frame, see `initial-frame-alist'.

For window-system specific values, see `window-system-default-frame-alist'.

For values specific to the separate minibuffer frame, see
`minibuffer-frame-alist'.

Setting this variable does not affect existing frames, only new ones.  */);
  Vdefault_frame_alist = Qnil;

  DEFVAR_LISP ("default-frame-scroll-bars", Vdefault_frame_scroll_bars,
	       doc: /* Default position of vertical scroll bars on this window-system.  */);
#if defined HAVE_WINDOW_SYSTEM && !defined HAVE_ANDROID
#if defined (HAVE_NTGUI) || defined (NS_IMPL_COCOA) || (defined (USE_GTK) && defined (USE_TOOLKIT_SCROLL_BARS))
  /* MS-Windows, macOS, and GTK have scroll bars on the right by
     default.  */
  Vdefault_frame_scroll_bars = Qright;
#else
  Vdefault_frame_scroll_bars = Qleft;
#endif
#else /* !HAVE_WINDOW_SYSTEM || HAVE_ANDROID */
  Vdefault_frame_scroll_bars = Qnil;
#endif /* HAVE_WINDOW_SYSTEM && !HAVE_ANDROID */

  DEFVAR_BOOL ("scroll-bar-adjust-thumb-portion",
               scroll_bar_adjust_thumb_portion_p,
               doc: /* Adjust scroll bars for overscrolling for Gtk+, Motif and Haiku.
Non-nil means adjust the thumb in the scroll bar so it can be dragged downwards
even if the end of the buffer is shown (i.e. overscrolling).
Set to nil if you want the thumb to be at the bottom when the end of the buffer
is shown.  Also, the thumb fills the whole scroll bar when the entire buffer
is visible.  In this case you can not overscroll.  */);
  scroll_bar_adjust_thumb_portion_p = 1;

  DEFVAR_LISP ("terminal-frame", Vterminal_frame,
               doc: /* The initial frame-object, which represents Emacs's stdout.  */);

  DEFVAR_LISP ("mouse-position-function", Vmouse_position_function,
	       doc: /* If non-nil, function to transform normal value of `mouse-position'.
`mouse-position' and `mouse-pixel-position' call this function, passing their
usual return value as argument, and return whatever this function returns.
This abnormal hook exists for the benefit of packages like `xt-mouse.el'
which need to do mouse handling at the Lisp level.  */);
  Vmouse_position_function = Qnil;

  DEFVAR_LISP ("mouse-highlight", Vmouse_highlight,
	       doc: /* If non-nil, clickable text is highlighted when mouse is over it.
If the value is an integer, highlighting is shown only after moving the
mouse, while keyboard input turns off the highlight even when the mouse
is over the clickable text.  However, the mouse shape still indicates
when the mouse is over clickable text.  */);
  Vmouse_highlight = Qt;

  DEFVAR_LISP ("make-pointer-invisible", Vmake_pointer_invisible,
               doc: /* If non-nil, make mouse pointer invisible while typing.
The pointer becomes visible again when the mouse is moved.

When using this, you might also want to disable highlighting of
clickable text.  See `mouse-highlight'.  */);
  Vmake_pointer_invisible = Qt;

  DEFVAR_LISP ("move-frame-functions", Vmove_frame_functions,
               doc: /* Functions run after a frame was moved.
The functions are run with one arg, the frame that moved.  */);
  Vmove_frame_functions = Qnil;

  DEFVAR_LISP ("delete-frame-functions", Vdelete_frame_functions,
	       doc: /* Functions run before deleting a frame.
The functions are run with one arg, the frame to be deleted.
See `delete-frame'.

Note that functions in this list may be called just before the frame is
actually deleted, or some time later (or even both when an earlier function
in `delete-frame-functions' (indirectly) calls `delete-frame'
recursively).  */);
  Vdelete_frame_functions = Qnil;
  DEFSYM (Qdelete_frame_functions, "delete-frame-functions");

  DEFVAR_LISP ("after-delete-frame-functions",
               Vafter_delete_frame_functions,
               doc: /* Functions run after deleting a frame.
The functions are run with one arg, the frame that was deleted and
which is now dead.  */);
  Vafter_delete_frame_functions = Qnil;
  DEFSYM (Qafter_delete_frame_functions, "after-delete-frame-functions");

  DEFVAR_LISP ("menu-bar-mode", Vmenu_bar_mode,
               doc: /* Non-nil if Menu-Bar mode is enabled.
See the command `menu-bar-mode' for a description of this minor mode.
Setting this variable directly does not take effect;
either customize it (see the info node `Easy Customization')
or call the function `menu-bar-mode'.  */);
  Vmenu_bar_mode = Qt;

  DEFVAR_LISP ("tab-bar-mode", Vtab_bar_mode,
               doc: /* Non-nil if Tab-Bar mode is enabled.
See the command `tab-bar-mode' for a description of this minor mode.
Setting this variable directly does not take effect;
either customize it (see the info node `Easy Customization')
or call the function `tab-bar-mode'.  */);
  Vtab_bar_mode = Qnil;

  DEFVAR_LISP ("tool-bar-mode", Vtool_bar_mode,
               doc: /* Non-nil if Tool-Bar mode is enabled.
See the command `tool-bar-mode' for a description of this minor mode.
Setting this variable directly does not take effect;
either customize it (see the info node `Easy Customization')
or call the function `tool-bar-mode'.  */);
#ifdef HAVE_WINDOW_SYSTEM
  Vtool_bar_mode = Qt;
#else
  Vtool_bar_mode = Qnil;
#endif

  DEFVAR_KBOARD ("default-minibuffer-frame", Vdefault_minibuffer_frame,
		 doc: /* Minibuffer-less frames by default use this frame's minibuffer.
Emacs consults this variable only when creating a minibuffer-less frame
and no explicit minibuffer window has been specified for that frame via
the `minibuffer' frame parameter.  Once such a frame has been created,
setting this variable does not change that frame's previous association.

This variable is local to the current terminal and cannot be buffer-local.  */);

  DEFVAR_LISP ("resize-mini-frames", resize_mini_frames,
    doc: /* Non-nil means resize minibuffer-only frames automatically.
If this is nil, do not resize minibuffer-only frames automatically.

If this is a function, call that function with the minibuffer-only
frame that shall be resized as sole argument.  The buffer of the root
window of that frame is the buffer whose text will be eventually shown
in the minibuffer window.

Any other non-nil value means to resize minibuffer-only frames by
calling `fit-mini-frame-to-buffer'.  */);
  resize_mini_frames = Qnil;

  DEFVAR_LISP ("focus-follows-mouse", focus_follows_mouse,
	       doc: /* Non-nil if window system changes focus when you move the mouse.
You should set this variable to tell Emacs how your window manager
handles focus, since there is no way in general for Emacs to find out
automatically.

There are three meaningful values:

- The default nil should be used when your window manager follows a
  "click-to-focus" policy where you have to click the mouse inside of a
  frame in order for that frame to get focus.

- The value t should be used when your window manager has the focus
  automatically follow the position of the mouse pointer but a window
  that gains focus is not raised automatically.

- The value `auto-raise' should be used when your window manager has the
  focus automatically follow the position of the mouse pointer and a
  window that gains focus is raised automatically.

If this option is non-nil, Emacs moves the mouse pointer to the frame
selected by `select-frame-set-input-focus'.  This function is used by a
number of commands like, for example, `other-frame' and `pop-to-buffer'.
If this option is nil and your focus follows mouse window manager does
not autonomously move the mouse pointer to the newly selected frame, the
previously selected window manager window might get reselected instead
immediately.

The distinction between the values t and `auto-raise' is not needed for
"normal" frames because the window manager takes care of raising them.
Setting this to `auto-raise' will, however, override the standard
behavior of a window manager that does not automatically raise the frame
that gets focus.  Setting this to `auto-raise' is also necessary to
automatically raise child frames which are usually left alone by the
window manager.

Note that this option does not distinguish "sloppy" focus (where the
frame that previously had focus retains focus as long as the mouse
pointer does not move into another window manager window) from "strict"
focus (where a frame immediately loses focus when it's left by the mouse
pointer).

In order to extend a "focus follows mouse" policy to individual Emacs
windows, customize the variable `mouse-autoselect-window'.  */);
  focus_follows_mouse = Qnil;

  DEFVAR_BOOL ("frame-resize-pixelwise", frame_resize_pixelwise,
	       doc: /* Non-nil means resize frames pixelwise.
If this option is nil, resizing a frame rounds its sizes to the frame's
current values of `frame-char-height' and `frame-char-width'.  If this
is non-nil, no rounding occurs, hence frame sizes can increase/decrease
by one pixel.

With some window managers you may have to set this to non-nil in order
to set the size of a frame in pixels, to maximize frames or to make them
fullscreen.  To resize your initial frame pixelwise, set this option to
a non-nil value in your init file.  */);
  frame_resize_pixelwise = 0;

  DEFVAR_LISP ("frame-inhibit-implied-resize", frame_inhibit_implied_resize,
	       doc: /* Whether frames should be resized implicitly.
If this option is nil, setting font, menu bar, tool bar, tab bar,
internal borders, fringes or scroll bars of a specific frame may resize
the frame in order to preserve the number of columns or lines it
displays.

If this option is t, no such resizing happens once Emacs has agreed with
the window manager on the final initial size of a frame.  That size will
have taken into account the size of the text area requested by the user
and the size of all decorations initially present on the frame.

If this is the symbol `force', no implicit resizing happens even before
a frame has obtained its final initial size.  As a consequence, the
initial frame size may not necessarily be the one requested by the user.
This value can be useful with tiling window managers where the initial
size of a frame is determined by external means.

The value of this option can be also a list of frame parameters.  In
this case, resizing is inhibited once a frame has obtained its final
initial size when changing a parameter that appears in that list.  The
parameters currently handled by this option include `font',
`font-backend', `internal-border-width', `menu-bar-lines',
`tool-bar-lines' and `tab-bar-lines'.

Changing any of the parameters `scroll-bar-width', `scroll-bar-height',
`vertical-scroll-bars', `horizontal-scroll-bars', `left-fringe' and
`right-fringe' is handled as if the frame contained just one live
window.  This means, for example, that removing vertical scroll bars on
a frame containing several side by side windows will shrink the frame
width by the width of one scroll bar provided this option is nil and
keep it unchanged if this option is either t or a list containing
`vertical-scroll-bars'.

In GTK+ and NS that use the external tool bar, the default value is
\\='(tab-bar-lines) which means that adding/removing a tab bar does
not change the frame height.  On all other types of GUI frames, the
default value is \\='(tab-bar-lines tool-bar-lines) which means that
adding/removing a tool bar or tab bar does not change the frame
height.  Otherwise it's t which means the frame size never changes
implicitly when there's no window system support.

Note that the size of fullscreen and maximized frames, the height of
fullheight frames and the width of fullwidth frames never change
implicitly.  Note also that when a frame is not large enough to
accommodate a change of any of the parameters listed above, Emacs may
try to enlarge the frame even if this option is non-nil.  */);
#if defined (HAVE_WINDOW_SYSTEM) && !defined (HAVE_ANDROID)
#if defined (USE_GTK) || defined (HAVE_NS)
  frame_inhibit_implied_resize = list1 (Qtab_bar_lines);
#else
  frame_inhibit_implied_resize = list2 (Qtab_bar_lines, Qtool_bar_lines);
#endif
#else
  frame_inhibit_implied_resize = Qt;
#endif

  DEFVAR_LISP ("frame-size-history", frame_size_history,
               doc: /* History of frame size adjustments.
If non-nil, list recording frame size adjustment.  Adjustments are
recorded only if the first element of this list is a positive number.
Adding an adjustment decrements that number by one.

The remaining elements are the adjustments.  Each adjustment is a list
of four elements `frame', `function', `sizes' and `more'.  `frame' is
the affected frame and `function' the invoking function.  `sizes' is
usually a list of four elements `old-width', `old-height', `new-width'
and `new-height' representing the old and new sizes recorded/requested
by `function'.  `more' is a list with additional information.

The function `frame--size-history' displays the value of this variable
in a more readable form.  */);
    frame_size_history = Qnil;

  DEFVAR_BOOL ("tooltip-reuse-hidden-frame", tooltip_reuse_hidden_frame,
	       doc: /* Non-nil means reuse hidden tooltip frames.
When this is nil, delete a tooltip frame when hiding the associated
tooltip.  When this is non-nil, make the tooltip frame invisible only,
so it can be reused when the next tooltip is shown.

Setting this to non-nil may drastically reduce the consing overhead
incurred by creating new tooltip frames.  However, a value of non-nil
means also that intermittent changes of faces or `default-frame-alist'
are not applied when showing a tooltip in a reused frame.

This variable is effective only with the X toolkit (and there only when
Gtk+ tooltips are not used) and on Windows.  */);
  tooltip_reuse_hidden_frame = false;

  DEFVAR_BOOL ("use-system-tooltips", use_system_tooltips,
	       doc: /* Whether to use the toolkit to display tooltips.
This option is only meaningful when Emacs is built with GTK+, NS or Haiku
windowing support, and, if it's non-nil (the default), it results in
tooltips that look like those displayed by other GTK+/NS/Haiku programs,
but will not be able to display text properties inside tooltip text.  */);
  use_system_tooltips = true;

  DEFVAR_LISP ("iconify-child-frame", iconify_child_frame,
	       doc: /* How to handle iconification of child frames.
This variable tells Emacs how to proceed when it is asked to iconify a
child frame.  If it is nil, `iconify-frame' will do nothing when invoked
on a child frame.  If it is `iconify-top-level' and the child frame is
on a graphical terminal, Emacs will try to iconify the root frame of
this child frame.  If it is `make-invisible', Emacs will try to make
this child frame invisible instead.

Any other value means to try iconifying the child frame on a graphical
terminal.  Since such an attempt is not honored by all window managers
and may even lead to making the child frame unresponsive to user
actions, the default is to iconify the root frame instead.  */);
  iconify_child_frame = Qiconify_top_level;

  DEFVAR_LISP ("expose-hidden-buffer", expose_hidden_buffer,
	       doc: /* Non-nil means to make a hidden buffer more visible.
A buffer is considered "hidden" if its name starts with a space.  By
default, many functions disregard hidden buffers.  In particular,
`make-frame' does not show the current buffer in the new frame's
selected window if that buffer is hidden.  Rather, `make-frame' will
show a buffer that is not hidden instead.

If this variable is non-nil, it will override the default behavior and
allow `make-frame' to show the current buffer even if its hidden.  */);
  expose_hidden_buffer = Qnil;
  DEFSYM (Qexpose_hidden_buffer, "expose-hidden-buffer");
  Fmake_variable_buffer_local (Qexpose_hidden_buffer);

  DEFVAR_LISP ("frame-internal-parameters", frame_internal_parameters,
	       doc: /* Frame parameters specific to every frame.  */);
#ifdef HAVE_X_WINDOWS
  frame_internal_parameters = list4 (Qname, Qparent_id, Qwindow_id, Qouter_window_id);
#else
  frame_internal_parameters = list3 (Qname, Qparent_id, Qwindow_id);
#endif

  defsubr (&Sframep);
  defsubr (&Sframe_live_p);
  defsubr (&Swindow_system);
  defsubr (&Sframe_windows_min_size);
  defsubr (&Smake_terminal_frame);
  defsubr (&Sselect_frame);
  defsubr (&Shandle_switch_frame);
  defsubr (&Sselected_frame);
  defsubr (&Sold_selected_frame);
  defsubr (&Sframe_list);
  defsubr (&Sframe_parent);
  defsubr (&Sframe_ancestor_p);
  defsubr (&Sframe_root_frame);
  defsubr (&Snext_frame);
  defsubr (&Sprevious_frame);
  defsubr (&Slast_nonminibuf_frame);
  defsubr (&Sdelete_frame);
  defsubr (&Smouse_position);
  defsubr (&Smouse_pixel_position);
  defsubr (&Sset_mouse_position);
  defsubr (&Sset_mouse_pixel_position);
#if 0
  defsubr (&Sframe_configuration);
  defsubr (&Srestore_frame_configuration);
#endif
  defsubr (&Smake_frame_visible);
  defsubr (&Smake_frame_invisible);
  defsubr (&Siconify_frame);
  defsubr (&Sframe_visible_p);
  defsubr (&Svisible_frame_list);
  defsubr (&Sraise_frame);
  defsubr (&Slower_frame);
  defsubr (&Sx_focus_frame);
  defsubr (&Sframe_after_make_frame);
  defsubr (&Sredirect_frame_focus);
  defsubr (&Sframe_focus);
  defsubr (&Sframe_parameters);
  defsubr (&Sframe_parameter);
  defsubr (&Smodify_frame_parameters);
  defsubr (&Sframe_char_height);
  defsubr (&Sframe_char_width);
  defsubr (&Sframe_native_height);
  defsubr (&Sframe_native_width);
  defsubr (&Sframe_text_cols);
  defsubr (&Sframe_text_lines);
  defsubr (&Sframe_total_cols);
  defsubr (&Sframe_total_lines);
  defsubr (&Sframe_text_width);
  defsubr (&Sframe_text_height);
  defsubr (&Sscroll_bar_width);
  defsubr (&Sscroll_bar_height);
  defsubr (&Sfringe_width);
  defsubr (&Sframe_child_frame_border_width);
  defsubr (&Sframe_internal_border_width);
  defsubr (&Sright_divider_width);
  defsubr (&Sbottom_divider_width);
  defsubr (&Stool_bar_pixel_width);
  defsubr (&Sset_frame_height);
  defsubr (&Sset_frame_width);
  defsubr (&Sset_frame_size);
  defsubr (&Sframe_position);
  defsubr (&Sset_frame_position);
  defsubr (&Sframe_pointer_visible_p);
  defsubr (&Smouse_position_in_root_frame);
  defsubr (&Sframe__set_was_invisible);
  defsubr (&Sframe_window_state_change);
  defsubr (&Sset_frame_window_state_change);
  defsubr (&Sframe_scale_factor);

#ifdef HAVE_WINDOW_SYSTEM
  defsubr (&Sx_get_resource);
  defsubr (&Sx_parse_geometry);
  defsubr (&Sreconsider_frame_fonts);
#endif

#ifdef HAVE_WINDOW_SYSTEM
  DEFSYM (Qmove_toolbar, "move-toolbar");

  /* The `tool-bar-position' frame parameter is supported on GTK and
     builds using the internal tool bar.  Providing this feature
     causes menu-bar.el to provide `tool-bar-position' as a user
     option.  */

#if !defined HAVE_EXT_TOOL_BAR || defined USE_GTK
  Fprovide (Qmove_toolbar, Qnil);
#endif /* !HAVE_EXT_TOOL_BAR || USE_GTK */
#endif /* HAVE_WINDOW_SYSTEM */
}
