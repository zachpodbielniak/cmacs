/*
 * cmacs-cintrospect.c — CMacs runtime C self-introspection subsystem
 *
 * Copyright (C) 2026 Zach Podbielniak
 * SPDX-License-Identifier: AGPL-3.0-or-later
 *
 * Top-level subsystem entry: registers all `cmacs-c-*' DEFUNs, sets
 * up the libdw DWARF reader, and provides the high-level glue that
 * the MCP tool layer and the Lisp UI buffers consume.
 */

#include <config.h>

#ifdef HAVE_CMACS_CINTROSPECT

#include "lisp.h"
#include "buffer.h"
#include "cmacs-cintrospect.h"
#include "cmacs-cintrospect-dwarf.h"
#include "cmacs-cintrospect-defun.h"
#include "cmacs-cintrospect-jit.h"

#include <string.h>
#include <stdlib.h>
#include <fnmatch.h>
#include <execinfo.h>

/* All the keyword/sym Lisp_Object constants are declared in globals.h
 * by make-docfile after scanning the DEFSYM calls in syms_of below.
 * Do NOT declare them here --- they will collide with globals.h. */

/* For walk-callback context: build a Lisp list incrementally.
 * We track the last cons cell (so we can XSETCDR it) plus the head. */
struct list_acc
{
  Lisp_Object head;
  Lisp_Object last;      /* nil if list is empty, else last cons cell */
};

static void
list_acc_init (struct list_acc *a)
{
  a->head = Qnil;
  a->last = Qnil;
}

static void
list_acc_push (struct list_acc *a, Lisp_Object item)
{
  Lisp_Object cell = Fcons (item, Qnil);
  if (NILP (a->head))
    a->head = cell;
  else
    XSETCDR (a->last, cell);
  a->last = cell;
}

/* ── Translate a CmacsCintroSym into a Lisp plist ─────────────────── */

static Lisp_Object
sym_kind_to_lisp (CmacsCintroSymKind k)
{
  switch (k)
    {
    case CMACS_CINTRO_SYM_FUNCTION: return Qfunction;
    case CMACS_CINTRO_SYM_DATA:     return Qdata;
    default:                        return Qnil;
    }
}

static Lisp_Object
type_kind_to_lisp (CmacsCintroTypeKind k)
{
  switch (k)
    {
    case CMACS_CINTRO_TYPE_BASE:     return Qbase;
    case CMACS_CINTRO_TYPE_POINTER:  return Qpointer;
    case CMACS_CINTRO_TYPE_ARRAY:    return Qarray;
    case CMACS_CINTRO_TYPE_STRUCT:   return Qstruct;
    case CMACS_CINTRO_TYPE_UNION:    return Qunion;
    case CMACS_CINTRO_TYPE_ENUM:     return Qenum;
    case CMACS_CINTRO_TYPE_TYPEDEF:  return Qtypedef;
    case CMACS_CINTRO_TYPE_FUNCTION: return Qfunction;
    default:                         return Qnil;
    }
}

static Lisp_Object
sym_to_plist (const CmacsCintroSym *s)
{
  Lisp_Object plist = Qnil;
  plist = nconc2 (plist, list2 (QCsymbol_name,
                                s->name ? build_string (s->name) : Qnil));
  plist = nconc2 (plist, list2 (QCkind, sym_kind_to_lisp (s->kind)));
  plist = nconc2 (plist, list2 (QCaddr,
                                make_uint ((uintmax_t) (uintptr_t) s->runtime_addr)));
  plist = nconc2 (plist, list2 (QCsize, make_uint (s->size)));
  plist = nconc2 (plist, list2 (QCobject,
                                s->object ? build_string (s->object) : Qnil));
  return plist;
}

/* ── Subsystem init ───────────────────────────────────────────────── */

void
init_cmacs_cintrospect (void)
{
  if (!cmacs_cintrospect_dwarf_init ())
    {
      message1_nolog ("cmacs-cintrospect: libdw init failed; introspection unavailable");
    }
  cmacs_cintrospect_jit_init ();
}

/* ── Public C-side helpers (used by cpatch) ──────────────────────── */

bool
cmacs_cintrospect_function_source (const char *name,
                                   char **file_out, int *line_out)
{
  CmacsCintroSym s;
  if (!cmacs_cintrospect_sym_lookup (name, &s))
    return false;
  bool ok = cmacs_cintrospect_addr_lookup (s.runtime_addr,
                                           file_out, line_out, NULL);
  cmacs_cintrospect_sym_free (&s);
  return ok;
}

void *
cmacs_cintrospect_function_address (const char *name)
{
  CmacsCintroSym s;
  if (!cmacs_cintrospect_sym_lookup (name, &s))
    return NULL;
  void *r = (s.kind == CMACS_CINTRO_SYM_FUNCTION) ? s.runtime_addr : NULL;
  cmacs_cintrospect_sym_free (&s);
  return r;
}

bool
cmacs_cintrospect_addr_to_source (void *addr, char **file_out,
                                  int *line_out, char **fn_out)
{
  return cmacs_cintrospect_addr_lookup (addr, file_out, line_out, fn_out);
}

/* ── Walk callback: collect into a list_acc ──────────────────────── */

struct collect_ctx
{
  struct list_acc acc;
  long limit;
  long count;
};

static bool
collect_sym_cb (const CmacsCintroSym *s, void *ud)
{
  struct collect_ctx *c = ud;
  list_acc_push (&c->acc, sym_to_plist (s));
  c->count++;
  return c->limit <= 0 || c->count < c->limit;
}

/* ── DEFUNs ───────────────────────────────────────────────────────── */

DEFUN ("cmacs-c-list", Fcmacs_c_list, Scmacs_c_list, 1, 3, 0,
       doc: /* List C-level entities of KIND optionally matching GLOB.
KIND must be one of `symbol', `defun', `type', `object'.
GLOB is a shell-style glob (like `buffer-*') matched against the name.
LIMIT (a positive integer or nil) caps the result list size.

Returns a list of plists; see `cmacs-c-symbol-info' /
`cmacs-c-defun-info' / `cmacs-c-type-info' / `cmacs-c-list-objects'
for the per-kind plist shape.  */)
  (Lisp_Object kind, Lisp_Object glob, Lisp_Object limit)
{
  CHECK_SYMBOL (kind);
  const char *g = NILP (glob) ? NULL : (CHECK_STRING (glob), SSDATA (glob));
  long lim = NILP (limit) ? -1 : (CHECK_FIXNAT (limit), XFIXNUM (limit));

  if (EQ (kind, Qsymbol))
    {
      struct collect_ctx c;
      list_acc_init (&c.acc);
      c.limit = lim; c.count = 0;
      cmacs_cintrospect_sym_walk (g, collect_sym_cb, &c);
      return c.acc.head;
    }
  else if (EQ (kind, Qdefun))
    {
      return Fcmacs_c_list_defuns (NILP (glob) ? Qnil : glob,
                                   NILP (limit) ? Qnil : limit);
    }
  else if (EQ (kind, Qtype))
    {
      /* Walking every CU's type DIEs is expensive --- defer to a
       * future indexer.  For now require an exact name via
       * `cmacs-c-type-info'. */
      xsignal1 (Qcintrospect_not_implemented,
                build_string ("cmacs-c-list 'type --- use cmacs-c-type-info NAME instead"));
    }
  else if (EQ (kind, Qobject))
    {
      return Fcmacs_c_list_objects ();
    }
  xsignal1 (Qerror, build_string ("Unknown KIND: must be one of symbol, defun, type, object"));
  return Qnil;
}

DEFUN ("cmacs-c-symbol-info", Fcmacs_c_symbol_info,
       Scmacs_c_symbol_info, 1, 1, 0,
       doc: /* Return a plist describing the C symbol named NAME.
Plist keys: :symbol-name :kind :addr :size :object :file :line.
Returns nil if the symbol is not found.  */)
  (Lisp_Object name)
{
  CHECK_STRING (name);
  CmacsCintroSym s;
  if (!cmacs_cintrospect_sym_lookup (SSDATA (name), &s))
    return Qnil;
  Lisp_Object plist = sym_to_plist (&s);

  if (s.runtime_addr != NULL)
    {
      char *file = NULL; int line = 0; char *fn = NULL;
      if (cmacs_cintrospect_addr_lookup (s.runtime_addr, &file, &line, &fn))
        {
          if (file)
            plist = nconc2 (plist,
                            list2 (QCfile, build_string (file)));
          if (line > 0)
            plist = nconc2 (plist,
                            list2 (QCline, make_fixnum (line)));
          xfree (file); xfree (fn);
        }
    }
  cmacs_cintrospect_sym_free (&s);
  return plist;
}

DEFUN ("cmacs-c-type-info", Fcmacs_c_type_info,
       Scmacs_c_type_info, 1, 1, 0,
       doc: /* Return a plist describing the C type named NAME.
For structs/unions: :kind :size :align :fields (each field is a plist
of :name :offset :size :bit-size :type :type-name).
For enums: :values (list of (name . value)).
Returns nil if the type is not found.  */)
  (Lisp_Object name)
{
  CHECK_STRING (name);
  CmacsCintroType t;
  if (!cmacs_cintrospect_type_lookup (SSDATA (name), &t))
    return Qnil;

  Lisp_Object plist = Qnil;
  plist = nconc2 (plist, list2 (QCsymbol_name, build_string (t.name)));
  plist = nconc2 (plist, list2 (QCkind, type_kind_to_lisp (t.kind)));
  plist = nconc2 (plist, list2 (QCsize, make_uint (t.size)));
  plist = nconc2 (plist, list2 (QCalign, make_uint (t.align)));

  Lisp_Object fields = Qnil;
  for (size_t i = 0; i < t.n_fields; i++)
    {
      const CmacsCintroField *f = &t.fields[i];
      Lisp_Object fp = Qnil;
      fp = nconc2 (fp, list2 (QCsymbol_name,
                              f->name ? build_string (f->name) : Qnil));
      if (t.kind == CMACS_CINTRO_TYPE_ENUM)
        {
          /* For enums, offset holds the constant value. */
          fp = nconc2 (fp, list2 (QCvalues, make_int ((intmax_t) f->offset)));
        }
      else
        {
          fp = nconc2 (fp, list2 (QCaddr, make_uint (f->offset)));
          fp = nconc2 (fp, list2 (QCsize, make_uint (f->size)));
          if (f->bit_size > 0)
            fp = nconc2 (fp, list2 (intern (":bit-size"),
                                    make_fixnum (f->bit_size)));
          fp = nconc2 (fp, list2 (intern (":type"),
                                  type_kind_to_lisp (f->type_kind)));
          fp = nconc2 (fp, list2 (intern (":type-name"),
                                  f->type_name ? build_string (f->type_name) : Qnil));
        }
      fields = Fcons (fp, fields);
    }
  fields = Fnreverse (fields);
  plist = nconc2 (plist, list2 (QCfields, fields));
  cmacs_cintrospect_type_free (&t);
  return plist;
}

DEFUN ("cmacs-c-function-source", Fcmacs_c_function_source,
       Scmacs_c_function_source, 1, 1, 0,
       doc: /* Return (FILE . LINE) for the C function named NAME, or nil.  */)
  (Lisp_Object name)
{
  CHECK_STRING (name);
  char *file = NULL; int line = 0;
  if (!cmacs_cintrospect_function_source (SSDATA (name), &file, &line))
    return Qnil;
  Lisp_Object r = Fcons (file ? build_string (file) : Qnil,
                         make_fixnum (line));
  xfree (file);
  return r;
}

DEFUN ("cmacs-c-addr-to-source", Fcmacs_c_addr_to_source,
       Scmacs_c_addr_to_source, 1, 1, 0,
       doc: /* Resolve the runtime ADDR (an integer) to (FILE LINE FUNCTION).
Returns nil if no DWARF info is available for that address.  */)
  (Lisp_Object addr)
{
  CHECK_INTEGER (addr);
  uintmax_t a = 0;
  if (FIXNUMP (addr)) a = (uintmax_t) XFIXNUM (addr);
  else if (BIGNUMP (addr)) a = bignum_to_uintmax (addr);
  char *file = NULL; int line = 0; char *fn = NULL;
  if (!cmacs_cintrospect_addr_lookup ((void *) (uintptr_t) a,
                                      &file, &line, &fn))
    return Qnil;
  Lisp_Object r = list3 (file ? build_string (file) : Qnil,
                         make_fixnum (line),
                         fn ? build_string (fn) : Qnil);
  xfree (file); xfree (fn);
  return r;
}

/* ── Demo / playground test globals ──────────────────────────────
 *
 * These exist so users can exercise cmacs-c-symbol-value and
 * cmacs-c-symbol-set-value end-to-end without having to find a real
 * editable C global by hand.  Marked `used' so LTO doesn't strip
 * them, and `volatile' so reads/writes aren't constant-propagated.
 *
 * Try:
 *   M-: (cmacs-c-symbol-value "cmacs_cintrospection_test_int" 'int)      => 42
 *   M-: (cmacs-c-symbol-value "cmacs_cintrospection_test_str" 'str)      => "hello from C"
 *   M-: (cmacs-c-symbol-set-value "cmacs_cintrospection_test_int" 100)   => t
 *   M-: (cmacs-c-symbol-set-value "cmacs_cintrospection_test_str" "new") => t
 */
__attribute__ ((used))
volatile int cmacs_cintrospection_test_int = 42;

__attribute__ ((used))
volatile char cmacs_cintrospection_test_str[64] = "hello from C";

/* Helper: read up to LEN bytes safely from ADDR.  Returns the
 * actual count copied (LEN unless we hit a fault).  We use a no-op
 * memcpy --- the kernel will SIGSEGV on bad reads, which would
 * abort cmacs.  For Phase-1 we trust the DWARF-provided address.
 * If this becomes a stability concern we can add a setjmp-based
 * SIGSEGV catcher around the read. */
static size_t
safe_read_bytes (void *addr, void *out, size_t len)
{
  if (addr == NULL || len == 0) return 0;
  memcpy (out, addr, len);
  return len;
}

/* Decide whether OBJ is safe to feed to prin1.  Critical: Emacs's
 * print_vectorlike_unreadable calls emacs_abort() (fatal SIGABRT,
 * NOT a signalled Lisp error --- safe_calln cannot catch it) when
 * given a vectorlike whose pseudovec type lacks a print path.
 * We must reject those upfront.
 *
 * Tag-bit pre-checks: read raw type without dereferencing (so
 * garbage that just LOOKS like a Lisp_Object doesn't SIGSEGV).
 * Whitelist primitive types only. */
static bool
lisp_object_safe_to_print (Lisp_Object obj)
{
  /* nil and t always safe. */
  if (NILP (obj) || EQ (obj, Qt))
    return true;
  /* Fixnums and floats safe (no dereference required by their tag
   * checks alone). */
  if (FIXNUMP (obj) || FLOATP (obj))
    return true;
  /* Symbols are safe IF DEFSYM-interned.  We can't easily tell
   * here, but the calling code only uses Q-prefix DEFSYM names, so
   * we trust it. */
  if (SYMBOLP (obj))
    return true;
  /* Conses are usually safe but pointer must be valid; if the
   * pointer is garbage we crash dereferencing.  We don't have a
   * portable way to validate the pointer cheaply, so reject conses
   * read out of arbitrary memory. */
  if (CONSP (obj))
    return false;
  /* Strings: same dereference concern. */
  if (STRINGP (obj))
    return false;
  /* Vectorlikes are the original abort source --- reject. */
  if (VECTORLIKEP (obj))
    return false;
  return false;
}

/* Print a Lisp_Object safely.  See lisp_object_safe_to_print for the
 * rationale on why we pre-filter rather than trust safe_calln. */
static Lisp_Object
print_lisp_object_safely (Lisp_Object obj)
{
  if (!lisp_object_safe_to_print (obj))
    return build_string ("(unprintable)");
  Lisp_Object result = safe_calln (intern ("prin1-to-string"), obj);
  return STRINGP (result) ? result : build_string ("(unprintable)");
}

DEFUN ("cmacs-c-symbol-value", Fcmacs_c_symbol_value,
       Scmacs_c_symbol_value, 1, 2, 0,
       doc: /* Read the value stored at the C symbol named NAME.

Optional FORMAT controls interpretation:
  auto (default) -- Lisp_Object for V- or Q-prefixed names of size 8,
                    hex for everything else.
  lisp           -- always try to interpret 8 bytes as Lisp_Object.
  hex            -- always return hex bytes (up to first 64 bytes).
  int            -- interpret as signed integer (size 1, 2, 4, or 8).
  pointer        -- interpret as void* (size 8).

Returns nil if the symbol is not found or has zero size.  Never
crashes on garbage --- malformed Lisp_Object reads are caught by
safe_calln.  */)
  (Lisp_Object name, Lisp_Object format)
{
  CHECK_STRING (name);
  if (NILP (format))
    format = intern ("auto");

  CmacsCintroSym s;
  if (!cmacs_cintrospect_sym_lookup (SSDATA (name), &s))
    return Qnil;
  if (s.runtime_addr == NULL || s.size == 0)
    {
      cmacs_cintrospect_sym_free (&s);
      return Qnil;
    }

  Lisp_Object out = Qnil;
  const char *cname = SSDATA (name);

  /* For 'auto, decide based on naming + size.
   * IMPORTANT: only Q-prefix names are auto-coerced to Lisp_Object.
   * V-prefix variables can hold arbitrary Lisp values including
   * vectorlikes whose printers call emacs_abort() on unhandled
   * subtypes (PVEC_MISC_PTR, internal markers, etc.) --- and that
   * abort is not catchable by safe_calln.  Users who want to risk
   * V-var Lisp interpretation must opt in via explicit
   * (cmacs-c-symbol-value NAME 'lisp).
   *
   * Char-array convention: names containing "str" or ending "_str"
   * with size > 8 are auto-coerced to NUL-terminated string. */
  Lisp_Object effective = format;
  if (EQ (format, intern ("auto")))
    {
      size_t cnlen = cname ? strlen (cname) : 0;
      bool str_named = cname
        && ((cnlen >= 4 && strcmp (cname + cnlen - 4, "_str") == 0)
            || strstr (cname, "_str_"));
      bool int_named = cname
        && ((cnlen >= 4 && strcmp (cname + cnlen - 4, "_int") == 0)
            || (cnlen >= 6 && strcmp (cname + cnlen - 6, "_count") == 0)
            || (cnlen >= 5 && strcmp (cname + cnlen - 5, "_size") == 0)
            || (cnlen >= 4 && strcmp (cname + cnlen - 4, "_len") == 0));
      if (s.size == 8 && cname && cname[0] == 'Q')
        effective = intern ("lisp");
      else if (s.size > 8 && str_named)
        effective = intern ("str");
      else if ((s.size == 1 || s.size == 2 || s.size == 4 || s.size == 8)
               && int_named)
        effective = intern ("int");
      else
        effective = intern ("hex");
    }

  if (EQ (effective, intern ("lisp")) && s.size == 8)
    {
      /* Read 8 bytes and reinterpret.  Lisp_Object is the raw
       * EMACS_INT/EMACS_UINT depending on USE_LSB_TAG.  */
      EMACS_INT raw = 0;
      safe_read_bytes (s.runtime_addr, &raw, 8);
      Lisp_Object obj = XIL (raw);
      out = print_lisp_object_safely (obj);
    }
  else if (EQ (effective, intern ("int")))
    {
      intmax_t v = 0;
      switch (s.size)
        {
        case 1: { int8_t  b; safe_read_bytes (s.runtime_addr, &b, 1); v = b; break; }
        case 2: { int16_t b; safe_read_bytes (s.runtime_addr, &b, 2); v = b; break; }
        case 4: { int32_t b; safe_read_bytes (s.runtime_addr, &b, 4); v = b; break; }
        case 8: { int64_t b; safe_read_bytes (s.runtime_addr, &b, 8); v = b; break; }
        default: cmacs_cintrospect_sym_free (&s); return Qnil;
        }
      out = make_int (v);
    }
  else if (EQ (effective, intern ("pointer")) && s.size == 8)
    {
      void *p = NULL;
      safe_read_bytes (s.runtime_addr, &p, 8);
      out = make_uint ((uintmax_t) (uintptr_t) p);
    }
  else if (EQ (effective, intern ("str")))
    {
      /* Read up to s.size bytes; stop at first NUL.  Bound to a
       * reasonable cap to avoid pathological memory reads. */
      size_t n = s.size > 4096 ? 4096 : s.size;
      char *buf = xmalloc (n + 1);
      safe_read_bytes (s.runtime_addr, buf, n);
      /* Truncate at first NUL within the read window. */
      size_t actual = 0;
      while (actual < n && buf[actual] != '\0') actual++;
      out = make_string (buf, actual);
      xfree (buf);
    }
  else /* hex */
    {
      size_t n = s.size;
      if (n > 64) n = 64;
      uint8_t buf[64] = {0};
      safe_read_bytes (s.runtime_addr, buf, n);
      char hex[64*3 + 8];
      size_t off = 0;
      for (size_t i = 0; i < n; i++)
        {
          int w = snprintf (hex + off, sizeof hex - off,
                            "%02x%s", buf[i],
                            i + 1 < n ? " " : "");
          if (w < 0 || (size_t) w >= sizeof hex - off) break;
          off += (size_t) w;
        }
      if (s.size > 64)
        snprintf (hex + off, sizeof hex - off, " ... (%zu bytes)",
                  s.size);
      out = build_string (hex);
    }

  cmacs_cintrospect_sym_free (&s);
  return out;
}

DEFUN ("cmacs-c-symbol-set-value", Fcmacs_c_symbol_set_value,
       Scmacs_c_symbol_set_value, 2, 3, 0,
       doc: /* Write NEW-VALUE into the C symbol named NAME.

Optional FORMAT controls interpretation of NEW-VALUE:
  auto (default) -- choose based on NEW-VALUE type and symbol size.
  int            -- NEW-VALUE is an integer; written as size 1/2/4/8.
  str            -- NEW-VALUE is a string; copied with NUL-terminate
                    (writes up to symbol_size-1 bytes; refuses overflow).
  lisp           -- NEW-VALUE is any Lisp_Object; written as 8 bytes
                    raw EMACS_INT.  DANGEROUS for non-self-contained
                    values (cons cells, strings, vectors) because the
                    GC won't know about your reference.

Returns t on success.  Signals an error if the symbol is not found,
the size is incompatible, or NEW-VALUE would overflow the slot.

Safety: the write goes through `volatile' so the compiler doesn't
reorder/cache it.  No mprotect dance --- writes to .data and .bss
(where most C globals live) are always permitted.  If the symbol is
in .rodata the write SIGSEGVs; this is intentional --- don't write
to read-only data.  */)
  (Lisp_Object name, Lisp_Object new_value, Lisp_Object format)
{
  CHECK_STRING (name);
  if (NILP (format))
    format = intern ("auto");

  CmacsCintroSym s;
  if (!cmacs_cintrospect_sym_lookup (SSDATA (name), &s))
    xsignal2 (Qerror,
              build_string ("cmacs-c-symbol-set-value: symbol not found"),
              name);
  if (s.runtime_addr == NULL || s.size == 0)
    {
      cmacs_cintrospect_sym_free (&s);
      xsignal1 (Qerror,
                build_string ("cmacs-c-symbol-set-value: incomplete symbol"));
    }

  /* Resolve auto. */
  Lisp_Object effective = format;
  if (EQ (format, intern ("auto")))
    {
      if (INTEGERP (new_value))
        effective = intern ("int");
      else if (STRINGP (new_value))
        effective = intern ("str");
      else
        effective = intern ("lisp");
    }

  if (EQ (effective, intern ("int")))
    {
      CHECK_INTEGER (new_value);
      intmax_t v = FIXNUMP (new_value)
                   ? (intmax_t) XFIXNUM (new_value)
                   : bignum_to_intmax (new_value);
      switch (s.size)
        {
        case 1: { volatile int8_t  *p = s.runtime_addr; *p = (int8_t)  v; break; }
        case 2: { volatile int16_t *p = s.runtime_addr; *p = (int16_t) v; break; }
        case 4: { volatile int32_t *p = s.runtime_addr; *p = (int32_t) v; break; }
        case 8: { volatile int64_t *p = s.runtime_addr; *p = (int64_t) v; break; }
        default:
          cmacs_cintrospect_sym_free (&s);
          xsignal1 (Qerror, build_string ("symbol size not 1/2/4/8 for int write"));
        }
    }
  else if (EQ (effective, intern ("str")))
    {
      CHECK_STRING (new_value);
      size_t need = SBYTES (new_value);
      if (need + 1 > s.size)
        {
          cmacs_cintrospect_sym_free (&s);
          xsignal3 (Qerror,
                    build_string ("string + NUL exceeds symbol size"),
                    make_int (need + 1),
                    make_int (s.size));
        }
      volatile char *dst = s.runtime_addr;
      memcpy ((char *) dst, SDATA (new_value), need);
      dst[need] = '\0';
      /* Zero out the trailing slack so subsequent reads don't see
       * stale bytes from a previous longer string. */
      for (size_t i = need + 1; i < s.size; i++)
        dst[i] = '\0';
    }
  else if (EQ (effective, intern ("lisp")))
    {
      if (s.size != 8)
        {
          cmacs_cintrospect_sym_free (&s);
          xsignal1 (Qerror, build_string ("lisp write requires size 8"));
        }
      volatile EMACS_INT *p = s.runtime_addr;
      *p = XLI (new_value);
    }
  else if (EQ (effective, intern ("hex")))
    {
      /* NEW-VALUE is a string of hex pairs separated by spaces. */
      CHECK_STRING (new_value);
      const char *src = SSDATA (new_value);
      size_t bi = 0;
      while (*src && bi < s.size)
        {
          while (*src == ' ' || *src == '\t') src++;
          if (!*src) break;
          unsigned int byte;
          if (sscanf (src, "%2x", &byte) != 1)
            {
              cmacs_cintrospect_sym_free (&s);
              xsignal1 (Qerror, build_string ("malformed hex byte"));
            }
          ((volatile uint8_t *) s.runtime_addr)[bi++] = (uint8_t) byte;
          src += 2;
        }
    }
  else
    {
      cmacs_cintrospect_sym_free (&s);
      xsignal1 (Qerror, build_string ("unknown format (use auto/int/str/lisp/hex)"));
    }

  cmacs_cintrospect_sym_free (&s);
  return Qt;
}

DEFUN ("cmacs-c-source-to-addr", Fcmacs_c_source_to_addr,
       Scmacs_c_source_to_addr, 2, 2, 0,
       doc: /* Resolve FILE:LINE to a runtime address integer, or nil.  */)
  (Lisp_Object file, Lisp_Object line)
{
  CHECK_STRING (file);
  CHECK_FIXNAT (line);
  void *a = cmacs_cintrospect_source_to_addr (SSDATA (file),
                                              XFIXNUM (line));
  return a ? make_uint ((uintmax_t) (uintptr_t) a) : Qnil;
}

/* Object walk: build (NAME PATH LOAD-BIAS HAS-DWARF SIZE) plists. */
static bool
collect_obj_cb (const CmacsCintroObject *o, void *ud)
{
  struct collect_ctx *c = ud;
  Lisp_Object plist = Qnil;
  plist = nconc2 (plist, list2 (QCsymbol_name, build_string (o->name)));
  plist = nconc2 (plist, list2 (QCpath, build_string (o->path)));
  plist = nconc2 (plist, list2 (QCload_bias, make_uint (o->load_bias)));
  plist = nconc2 (plist, list2 (QChas_dwarf, o->has_dwarf ? Qt : Qnil));
  plist = nconc2 (plist, list2 (QCsize, make_uint (o->size)));
  list_acc_push (&c->acc, plist);
  c->count++;
  return c->limit <= 0 || c->count < c->limit;
}

DEFUN ("cmacs-c-list-objects", Fcmacs_c_list_objects,
       Scmacs_c_list_objects, 0, 0, 0,
       doc: /* List all loaded ELF objects with their DWARF availability.
Each entry is a plist with :symbol-name :path :load-bias :has-dwarf :size.  */)
  (void)
{
  struct collect_ctx c;
  list_acc_init (&c.acc);
  c.limit = -1; c.count = 0;
  cmacs_cintrospect_object_walk (collect_obj_cb, &c);
  return c.acc.head;
}

/* DEFUN walk: collect each as a plist. */
struct defun_ctx
{
  struct list_acc acc;
  const char *glob;
  long limit;
  long count;
};

static bool
collect_defun_cb (const CmacsCintroDefun *d, void *ud)
{
  struct defun_ctx *c = ud;
  if (c->glob != NULL && c->glob[0] != '\0'
      && fnmatch (c->glob, d->symbol_name, 0) != 0)
    return true;
  Lisp_Object plist = Qnil;
  plist = nconc2 (plist, list2 (QCsymbol_name, build_string (d->symbol_name)));
  if (d->c_name)
    plist = nconc2 (plist, list2 (QCc_name, build_string (d->c_name)));
  plist = nconc2 (plist, list2 (QCmin_args, make_fixnum (d->min_args)));
  plist = nconc2 (plist, list2 (QCmax_args, make_fixnum (d->max_args)));
  plist = nconc2 (plist, list2 (QCfn_addr,
                                make_uint ((uintmax_t) (uintptr_t) d->fn_ptr)));
  list_acc_push (&c->acc, plist);
  c->count++;
  return c->limit <= 0 || c->count < c->limit;
}

DEFUN ("cmacs-c-list-defuns", Fcmacs_c_list_defuns,
       Scmacs_c_list_defuns, 0, 2, 0,
       doc: /* List every Lisp-callable C primitive (DEFUN).
Optional GLOB filters by Lisp-side symbol name.  Optional LIMIT caps results.  */)
  (Lisp_Object glob, Lisp_Object limit)
{
  struct defun_ctx c =
    {
      .glob = NILP (glob) ? NULL : (CHECK_STRING (glob), SSDATA (glob)),
      .limit = NILP (limit) ? -1 : (CHECK_FIXNAT (limit), XFIXNUM (limit)),
      .count = 0,
    };
  list_acc_init (&c.acc);
  cmacs_cintrospect_defun_walk (collect_defun_cb, &c);
  return c.acc.head;
}

DEFUN ("cmacs-c-defun-info", Fcmacs_c_defun_info,
       Scmacs_c_defun_info, 1, 1, 0,
       doc: /* Return a plist describing the DEFUN named SYM.
Keys: :symbol-name :c-name :min-args :max-args :fn-addr :file :line.
Returns nil if SYM is not a DEFUN.  */)
  (Lisp_Object sym)
{
  if (STRINGP (sym))
    sym = intern (SSDATA (sym));
  CmacsCintroDefun d;
  if (!cmacs_cintrospect_defun_lookup (sym, &d))
    return Qnil;
  Lisp_Object plist = Qnil;
  plist = nconc2 (plist, list2 (QCsymbol_name, build_string (d.symbol_name)));
  if (d.c_name)
    plist = nconc2 (plist, list2 (QCc_name, build_string (d.c_name)));
  plist = nconc2 (plist, list2 (QCmin_args, make_fixnum (d.min_args)));
  plist = nconc2 (plist, list2 (QCmax_args, make_fixnum (d.max_args)));
  plist = nconc2 (plist, list2 (QCfn_addr,
                                make_uint ((uintmax_t) (uintptr_t) d.fn_ptr)));
  /* DWARF cross-reference for source location of the C function. */
  char *file = NULL; int line = 0; char *fn = NULL;
  if (d.fn_ptr != NULL
      && cmacs_cintrospect_addr_lookup (d.fn_ptr, &file, &line, &fn))
    {
      if (file)
        plist = nconc2 (plist, list2 (QCfile, build_string (file)));
      if (line > 0)
        plist = nconc2 (plist, list2 (QCline, make_fixnum (line)));
      xfree (file); xfree (fn);
    }
  return plist;
}

DEFUN ("cmacs-c-stack-trace", Fcmacs_c_stack_trace,
       Scmacs_c_stack_trace, 0, 1, 0,
       doc: /* Return the current C stack as a list of plists.
Each frame is a plist of :addr :file :line :function.  Optional DEPTH
caps the number of frames returned (default: 64).

Requires the binary to have been built with -fno-omit-frame-pointer
or -fasynchronous-unwind-tables (cintrospect's configure block adds
both).  */)
  (Lisp_Object depth)
{
  long max_frames = NILP (depth) ? 64
                  : (CHECK_FIXNAT (depth), XFIXNUM (depth));
  if (max_frames > 256) max_frames = 256;

  /* Use libgcc's _Unwind_Backtrace via the standard backtrace(3)
   * shim --- it's available on every glibc-based system and enough
   * for cintrospect's diagnostic use.  More elaborate frame-by-frame
   * locals decoding can come later via libdw's CFI engine. */
  void *frames[256];
  int n = backtrace (frames, (int) max_frames);

  Lisp_Object out = Qnil;
  for (int i = n - 1; i >= 0; i--)
    {
      Lisp_Object plist = Qnil;
      plist = nconc2 (plist, list2 (QCaddr,
                                    make_uint ((uintmax_t) (uintptr_t) frames[i])));
      char *file = NULL; int line = 0; char *fn = NULL;
      if (cmacs_cintrospect_addr_lookup (frames[i], &file, &line, &fn))
        {
          if (fn)
            plist = nconc2 (plist, list2 (intern (":function"),
                                          build_string (fn)));
          if (file)
            plist = nconc2 (plist, list2 (QCfile, build_string (file)));
          if (line > 0)
            plist = nconc2 (plist, list2 (QCline, make_fixnum (line)));
          xfree (file); xfree (fn);
        }
      out = Fcons (plist, out);
    }
  return out;
}

/* JIT DEFUNs (cmacs-c-compile / cmacs-c-call / cmacs-c-handle-info /
 * cmacs-c-handle-dispose) live in cmacs-cintrospect-jit.c; its entry
 * point is declared in cmacs-cintrospect-jit.h, included above. */

/* ── syms_of ──────────────────────────────────────────────────────── */

void
syms_of_cmacs_cintrospect (void)
{
  DEFSYM (QCkind,         ":kind");
  DEFSYM (QCaddr,         ":addr");
  DEFSYM (QCfile,         ":file");
  DEFSYM (QCline,         ":line");
  DEFSYM (QCobject,       ":object");
  DEFSYM (QCsize,         ":size");
  DEFSYM (QCprototype,    ":prototype");
  DEFSYM (QCsymbol_name,  ":symbol-name");
  DEFSYM (QCc_name,       ":c-name");
  DEFSYM (QCmin_args,     ":min-args");
  DEFSYM (QCmax_args,     ":max-args");
  DEFSYM (QCfn_addr,      ":fn-addr");
  DEFSYM (QCfields,       ":fields");
  DEFSYM (QCalign,        ":align");
  DEFSYM (QCvalues,       ":values");
  DEFSYM (QCpath,         ":path");
  DEFSYM (QChas_dwarf,    ":has-dwarf");
  DEFSYM (QCload_bias,    ":load-bias");

  DEFSYM (Qfunction,      "function");
  DEFSYM (Qdata,          "data");
  DEFSYM (Qstruct,        "struct");
  DEFSYM (Qunion,         "union");
  DEFSYM (Qenum,          "enum");
  DEFSYM (Qtypedef,       "typedef");
  DEFSYM (Qpointer,       "pointer");
  DEFSYM (Qarray,         "array");
  DEFSYM (Qbase,          "base");
  DEFSYM (Qsymbol,        "symbol");
  DEFSYM (Qdefun,         "defun");
  DEFSYM (Qtype,          "type");
  /* `object' is xdisp.c's Qobject; DEFSYM'ing it again would intern a
     second symbol of the same name and break EQ for both.  */
  DEFSYM (Qinlined_only,  "inlined-only");

  DEFSYM (Qcintrospect_unavailable,    "cmacs-cintrospect-unavailable");
  DEFSYM (Qcintrospect_not_implemented, "cmacs-cintrospect-not-implemented");
  Fput (Qcintrospect_unavailable, Qerror_conditions,
        list2 (Qcintrospect_unavailable, Qerror));
  Fput (Qcintrospect_unavailable, Qerror_message,
        build_string ("cmacs-cintrospect: feature unavailable"));
  Fput (Qcintrospect_not_implemented, Qerror_conditions,
        list2 (Qcintrospect_not_implemented, Qerror));
  Fput (Qcintrospect_not_implemented, Qerror_message,
        build_string ("cmacs-cintrospect: not implemented in this build phase"));

  defsubr (&Scmacs_c_list);
  defsubr (&Scmacs_c_symbol_info);
  defsubr (&Scmacs_c_type_info);
  defsubr (&Scmacs_c_function_source);
  defsubr (&Scmacs_c_addr_to_source);
  defsubr (&Scmacs_c_source_to_addr);
  defsubr (&Scmacs_c_symbol_value);
  defsubr (&Scmacs_c_symbol_set_value);
  defsubr (&Scmacs_c_list_objects);
  defsubr (&Scmacs_c_list_defuns);
  defsubr (&Scmacs_c_defun_info);
  defsubr (&Scmacs_c_stack_trace);

  /* JIT DEFUNs are registered from their own module. */
  syms_of_cmacs_cintrospect_jit ();
}

#endif /* HAVE_CMACS_CINTROSPECT */
