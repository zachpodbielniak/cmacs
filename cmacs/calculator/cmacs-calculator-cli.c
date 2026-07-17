/* cmacs-calculator-cli.c --- `emacs --calc' command-line entry

Copyright (C) 2026 Zach Podbielniak

SPDX-License-Identifier: AGPL-3.0-or-later

This file is part of CMacs.  */

/* `emacs --calc' drops into a calculator REPL on the terminal:
 *
 *   emacs --calc            interactive REPL (also reads piped stdin)
 *   emacs --calc EXPR       evaluate EXPR, print the result, exit
 *
 * Implemented by REWRITING argv before Emacs parses it, rather than by the
 * `--bacon' / `--crispy' pattern of taking over main() and never returning.
 * Those subsystems can do that because their engines are C; the calculator's
 * engine is GNU Calc, which is Elisp, so the Lisp VM has to be up before a
 * single expression can be evaluated.
 *
 * So --calc becomes the equivalent standard arguments:
 *
 *   emacs --calc        ->  emacs --batch --eval "(progn (require 'cmacs-calculator-repl)
 *                                                        (cmacs-calculator-repl))"
 *   emacs --calc EXPR   ->  emacs --batch --eval "(progn (require 'cmacs-calculator-repl)
 *                                                        (cmacs-calculator-cli \"EXPR\"))"
 *
 * which reuses Emacs's existing argument machinery end to end.  Because
 * --calc never survives into the rewritten vector, it needs no standard_args[]
 * entry and no change to lisp/startup.el (which errors on options it does not
 * recognise).  --batch and --eval already exist and already work.  */

#include <config.h>

#ifdef HAVE_CMACS_CALCULATOR

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "cmacs-calculator-cli.h"

/* A growable byte buffer.  Deliberately tiny and self-contained: this code
   runs before Emacs is initialised, so none of xmalloc/xstrdup and no Lisp
   allocation is available yet.  */
typedef struct
{
  char  *data;
  size_t len;
  size_t cap;
} CalcBuf;

static void
buf_init (CalcBuf *b)
{
  b->cap = 256;
  b->len = 0;
  b->data = malloc (b->cap);
  if (b->data == NULL)
    {
      fprintf (stderr, "emacs --calc: out of memory\n");
      exit (EXIT_FAILURE);
    }
  b->data[0] = '\0';
}

static void
buf_reserve (CalcBuf *b, size_t extra)
{
  if (b->len + extra + 1 <= b->cap)
    return;
  while (b->len + extra + 1 > b->cap)
    b->cap *= 2;
  b->data = realloc (b->data, b->cap);
  if (b->data == NULL)
    {
      fprintf (stderr, "emacs --calc: out of memory\n");
      exit (EXIT_FAILURE);
    }
}

/* Append S verbatim -- for Lisp code we control.  */
static void
buf_add (CalcBuf *b, const char *s)
{
  size_t n = strlen (s);

  buf_reserve (b, n);
  memcpy (b->data + b->len, s, n);
  b->len += n;
  b->data[b->len] = '\0';
}

/* Append S escaped for use INSIDE a Lisp string literal -- for user input.
   Backslash and double-quote are the only characters that can terminate or
   escape out of the literal, and an unescaped quote in a shell argument would
   otherwise let the caller close the string and inject a form.  */
static void
buf_add_escaped (CalcBuf *b, const char *s)
{
  size_t i;

  for (i = 0; s[i] != '\0'; i++)
    {
      buf_reserve (b, 2);
      if (s[i] == '\\' || s[i] == '"')
        b->data[b->len++] = '\\';
      b->data[b->len++] = s[i];
    }
  b->data[b->len] = '\0';
}

/* Build the --eval form: the REPL, or a one-shot evaluation of EXPR when it
   is non-NULL.  Returned malloc'd and never freed -- it has to outlive this
   call as an argv entry, and the process runs to exit from there.  */
static char *
build_eval_form (const char *expr)
{
  CalcBuf b;

  buf_init (&b);
  /* `require' lives inside the form so a load failure surfaces as a normal
     Lisp error on stderr rather than a silent no-op.  */
  buf_add (&b, "(progn (require 'cmacs-calculator-repl) ");
  if (expr == NULL)
    buf_add (&b, "(cmacs-calculator-repl))");
  else
    {
      buf_add (&b, "(cmacs-calculator-cli \"");
      buf_add_escaped (&b, expr);
      buf_add (&b, "\"))");
    }
  return b.data;
}

char **
cmacs_calculator_rewrite_args (int *argcp, char **argv)
{
  int argc = *argcp;
  int i, calc_idx = -1;
  const char *expr = NULL;
  int consumed;
  char **out;
  int n = 0;

  /* Find --calc, stopping at `--' so `emacs -- --calc' still passes it
     through as an ordinary argument.  */
  for (i = 1; i < argc; i++)
    {
      if (strcmp (argv[i], "--") == 0)
        break;
      if (strcmp (argv[i], "--calc") == 0 || strcmp (argv[i], "-calc") == 0)
        {
          calc_idx = i;
          break;
        }
    }
  if (calc_idx < 0)
    return argv;

  /* A following argument is the one-shot expression, unless it looks like
     another option.  A leading `-' is ambiguous -- "-5+3" is a valid
     expression -- but treating it as an option is the safer reading, and
     `emacs --calc "(-5+3)"' says it unambiguously.  */
  consumed = 1;
  if (calc_idx + 1 < argc && argv[calc_idx + 1][0] != '-')
    {
      expr = argv[calc_idx + 1];
      consumed = 2;
    }

  /* argv[0], everything before --calc, our two substituted arguments, then
     everything after --calc (and its expression).  */
  out = malloc (sizeof *out * (size_t) (argc - consumed + 4));
  if (out == NULL)
    {
      fprintf (stderr, "emacs --calc: out of memory\n");
      exit (EXIT_FAILURE);
    }

  for (i = 0; i < calc_idx; i++)
    out[n++] = argv[i];
  out[n++] = (char *) "--batch";
  out[n++] = (char *) "--eval";
  out[n++] = build_eval_form (expr);
  for (i = calc_idx + consumed; i < argc; i++)
    out[n++] = argv[i];
  out[n] = NULL;

  *argcp = n;
  return out;
}

#endif /* HAVE_CMACS_CALCULATOR */
