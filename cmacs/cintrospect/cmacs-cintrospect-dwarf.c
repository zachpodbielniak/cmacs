/*
 * cmacs-cintrospect-dwarf.c — libdw/libdwfl DWARF reader
 *
 * Copyright (C) 2026 Zach Podbielniak
 * SPDX-License-Identifier: AGPL-3.0-or-later
 *
 * Wraps elfutils libdwfl to give us symbol lookup, address-to-source
 * resolution, and recursive type DIE walking across the running
 * binary plus every loaded shared object.  libdw is not thread-safe,
 * so a single coarse lock guards the Dwfl handle.
 */

#include <config.h>

#ifdef HAVE_CMACS_CINTROSPECT

#include "lisp.h"
#include "cmacs-cintrospect-dwarf.h"

#include <elfutils/libdw.h>
#include <elfutils/libdwfl.h>
#include <dwarf.h>
#include <gelf.h>

#include <fnmatch.h>
#include <string.h>
#include <stdlib.h>
#include <unistd.h>
#include <pthread.h>
#include <sys/stat.h>
#include <libgen.h>
#include <errno.h>

/* ── Static state ─────────────────────────────────────────────────── */

static Dwfl *cintrospect_dwfl;
static pthread_mutex_t cintrospect_dwfl_mtx = PTHREAD_MUTEX_INITIALIZER;
static char *debuginfo_path_buf;

static const Dwfl_Callbacks proc_callbacks =
{
  .find_elf       = dwfl_linux_proc_find_elf,
  .find_debuginfo = dwfl_standard_find_debuginfo,
  .debuginfo_path = &debuginfo_path_buf,
};

static inline void
cintrospect_lock (void)
{
  pthread_mutex_lock (&cintrospect_dwfl_mtx);
}

static inline void
cintrospect_unlock (void)
{
  pthread_mutex_unlock (&cintrospect_dwfl_mtx);
}

/* ── Init / shutdown ──────────────────────────────────────────────── */

bool
cmacs_cintrospect_dwarf_init (void)
{
  cintrospect_lock ();
  if (cintrospect_dwfl != NULL)
    {
      cintrospect_unlock ();
      return true;
    }

  cintrospect_dwfl = dwfl_begin (&proc_callbacks);
  if (cintrospect_dwfl == NULL)
    {
      cintrospect_unlock ();
      return false;
    }

  /* Report all currently-loaded modules in our own process.  This
   * walks /proc/self/maps and is cheap; it does NOT load DWARF DIEs
   * eagerly --- those come on-demand. */
  if (dwfl_linux_proc_report (cintrospect_dwfl, getpid ()) != 0
      || dwfl_report_end (cintrospect_dwfl, NULL, NULL) != 0)
    {
      dwfl_end (cintrospect_dwfl);
      cintrospect_dwfl = NULL;
      cintrospect_unlock ();
      return false;
    }

  cintrospect_unlock ();
  return true;
}

void
cmacs_cintrospect_dwarf_shutdown (void)
{
  cintrospect_lock ();
  if (cintrospect_dwfl != NULL)
    {
      dwfl_end (cintrospect_dwfl);
      cintrospect_dwfl = NULL;
    }
  cintrospect_unlock ();
}

/* ── Helpers ─────────────────────────────────────────────────────── */

static char *
xstrdup_or_null (const char *s)
{
  if (s == NULL)
    return NULL;
  size_t len = strlen (s);
  char *r = xmalloc (len + 1);
  memcpy (r, s, len + 1);
  return r;
}

static const char *
basename_of (const char *path)
{
  if (path == NULL)
    return "?";
  const char *slash = strrchr (path, '/');
  return slash != NULL ? slash + 1 : path;
}

static CmacsCintroTypeKind
dwtag_to_kind (int tag)
{
  switch (tag)
    {
    case DW_TAG_base_type:        return CMACS_CINTRO_TYPE_BASE;
    case DW_TAG_pointer_type:
    case DW_TAG_reference_type:   return CMACS_CINTRO_TYPE_POINTER;
    case DW_TAG_array_type:       return CMACS_CINTRO_TYPE_ARRAY;
    case DW_TAG_structure_type:   return CMACS_CINTRO_TYPE_STRUCT;
    case DW_TAG_union_type:       return CMACS_CINTRO_TYPE_UNION;
    case DW_TAG_enumeration_type: return CMACS_CINTRO_TYPE_ENUM;
    case DW_TAG_typedef:          return CMACS_CINTRO_TYPE_TYPEDEF;
    case DW_TAG_subroutine_type:
    case DW_TAG_subprogram:       return CMACS_CINTRO_TYPE_FUNCTION;
    default:                      return CMACS_CINTRO_TYPE_UNKNOWN;
    }
}

/* ── Symbol free ──────────────────────────────────────────────────── */

void
cmacs_cintrospect_sym_free (CmacsCintroSym *s)
{
  if (s == NULL) return;
  xfree (s->name);
  xfree (s->object);
  s->name = s->object = NULL;
}

/* ── Symbol lookup ────────────────────────────────────────────────── */

struct sym_lookup_ctx
{
  const char *target;
  CmacsCintroSym *out;
  bool found;
};

static int
sym_lookup_module_cb (Dwfl_Module *mod,
                      void **userdata,
                      const char *name,
                      Dwarf_Addr start,
                      void *arg)
{
  (void) userdata; (void) name; (void) start;
  struct sym_lookup_ctx *ctx = arg;

  int n = dwfl_module_getsymtab (mod);
  if (n <= 0)
    return DWARF_CB_OK;

  for (int i = 0; i < n; i++)
    {
      GElf_Sym sym;
      GElf_Addr addr = 0;
      const char *sname = dwfl_module_getsym_info (mod, i, &sym, &addr,
                                                   NULL, NULL, NULL);
      if (sname == NULL || sname[0] == '\0')
        continue;
      if (strcmp (sname, ctx->target) != 0)
        continue;

      ctx->out->name = xstrdup_or_null (sname);
      const char *modname = dwfl_module_info (mod, NULL, NULL, NULL,
                                              NULL, NULL, NULL, NULL);
      ctx->out->object = xstrdup_or_null (basename_of (modname));
      ctx->out->runtime_addr = (void *) (uintptr_t) addr;
      ctx->out->size = sym.st_size;
      ctx->out->kind = (GELF_ST_TYPE (sym.st_info) == STT_FUNC)
                       ? CMACS_CINTRO_SYM_FUNCTION
                       : (GELF_ST_TYPE (sym.st_info) == STT_OBJECT)
                         ? CMACS_CINTRO_SYM_DATA
                         : CMACS_CINTRO_SYM_UNKNOWN;
      ctx->found = true;
      return DWARF_CB_ABORT;
    }
  return DWARF_CB_OK;
}

bool
cmacs_cintrospect_sym_lookup (const char *name, CmacsCintroSym *out)
{
  if (cintrospect_dwfl == NULL || name == NULL || out == NULL)
    return false;
  memset (out, 0, sizeof *out);

  struct sym_lookup_ctx ctx = { .target = name, .out = out, .found = false };
  cintrospect_lock ();
  dwfl_getmodules (cintrospect_dwfl, sym_lookup_module_cb, &ctx, 0);
  cintrospect_unlock ();
  return ctx.found;
}

/* ── Symbol walk (with glob filter) ──────────────────────────────── */

struct sym_walk_ctx
{
  const char *glob;
  CmacsCintroSymIterFn fn;
  void *user_data;
  bool stop;
  /* Two-pass mode: pass 1 = only globals (STB_GLOBAL/STB_WEAK).
   * Pass 2 = locals.  This way a small per-call limit still
   * surfaces user-relevant globals like cmacs_cintrospection_* even
   * if the binary has many internal locals. */
  bool current_pass_globals;
};

static int
sym_walk_module_cb (Dwfl_Module *mod,
                    void **userdata,
                    const char *modname,
                    Dwarf_Addr start,
                    void *arg)
{
  (void) userdata; (void) modname; (void) start;
  struct sym_walk_ctx *ctx = arg;
  if (ctx->stop)
    return DWARF_CB_ABORT;

  int n = dwfl_module_getsymtab (mod);
  if (n <= 0)
    return DWARF_CB_OK;

  const char *mname = dwfl_module_info (mod, NULL, NULL, NULL,
                                        NULL, NULL, NULL, NULL);
  const char *bn = basename_of (mname);

  for (int i = 0; i < n && !ctx->stop; i++)
    {
      GElf_Sym sym;
      GElf_Addr addr = 0;
      const char *sname = dwfl_module_getsym_info (mod, i, &sym, &addr,
                                                   NULL, NULL, NULL);
      if (sname == NULL || sname[0] == '\0')
        continue;
      int t = GELF_ST_TYPE (sym.st_info);
      int b = GELF_ST_BIND (sym.st_info);
      if (t != STT_FUNC && t != STT_OBJECT)
        continue;
      bool is_global = (b == STB_GLOBAL || b == STB_WEAK);
      if (ctx->current_pass_globals != is_global)
        continue;
      if (ctx->glob != NULL && ctx->glob[0] != '\0'
          && fnmatch (ctx->glob, sname, 0) != 0)
        continue;

      CmacsCintroSym one =
        {
          .name = (char *) sname,
          .object = (char *) bn,
          .runtime_addr = (void *) (uintptr_t) addr,
          .size = sym.st_size,
          .kind = (t == STT_FUNC)
                  ? CMACS_CINTRO_SYM_FUNCTION
                  : CMACS_CINTRO_SYM_DATA,
        };
      if (!ctx->fn (&one, ctx->user_data))
        ctx->stop = true;
    }
  return ctx->stop ? DWARF_CB_ABORT : DWARF_CB_OK;
}

void
cmacs_cintrospect_sym_walk (const char *glob,
                            CmacsCintroSymIterFn fn,
                            void *user_data)
{
  if (cintrospect_dwfl == NULL || fn == NULL)
    return;
  cintrospect_lock ();
  /* Pass 1: globals across all modules (the user-relevant set). */
  struct sym_walk_ctx ctx =
    { glob, fn, user_data, false, /* current_pass_globals */ true };
  dwfl_getmodules (cintrospect_dwfl, sym_walk_module_cb, &ctx, 0);
  /* Pass 2: locals across all modules.  The callback's per-result
   * limit may have already been reached --- if so, ctx.stop is set
   * and this pass does nothing. */
  ctx.current_pass_globals = false;
  if (!ctx.stop)
    dwfl_getmodules (cintrospect_dwfl, sym_walk_module_cb, &ctx, 0);
  cintrospect_unlock ();
}

/* ── Address → source ────────────────────────────────────────────── */

bool
cmacs_cintrospect_addr_lookup (void *addr,
                               char **file_out,
                               int *line_out,
                               char **fn_out)
{
  if (cintrospect_dwfl == NULL || addr == NULL)
    return false;

  bool ok = false;
  cintrospect_lock ();
  Dwarf_Addr a = (Dwarf_Addr) (uintptr_t) addr;
  Dwfl_Module *mod = dwfl_addrmodule (cintrospect_dwfl, a);
  if (mod != NULL)
    {
      const char *fn_name = dwfl_module_addrname (mod, a);
      Dwfl_Line *line = dwfl_module_getsrc (mod, a);
      if (line != NULL)
        {
          int lineno = 0;
          const char *src = dwfl_lineinfo (line, NULL, &lineno,
                                           NULL, NULL, NULL);
          if (file_out) *file_out = xstrdup_or_null (src);
          if (line_out) *line_out = lineno;
          if (fn_out)   *fn_out  = xstrdup_or_null (fn_name);
          ok = true;
        }
      else if (fn_name != NULL && fn_out)
        {
          *fn_out = xstrdup_or_null (fn_name);
          if (file_out) *file_out = NULL;
          if (line_out) *line_out = 0;
          ok = true;
        }
    }
  cintrospect_unlock ();
  return ok;
}

/* ── Source → address ────────────────────────────────────────────── */

struct src2addr_ctx
{
  const char *file;
  int line;
  void *result;
};

static int
src2addr_cu_cb (Dwfl_Module *mod, void **userdata,
                const char *modname, Dwarf_Addr start,
                void *arg)
{
  (void) userdata; (void) modname; (void) start;
  struct src2addr_ctx *ctx = arg;
  if (ctx->result != NULL)
    return DWARF_CB_ABORT;

  Dwarf_Die *cu = NULL;
  Dwarf_Addr bias = 0;
  while ((cu = dwfl_module_nextcu (mod, cu, &bias)) != NULL)
    {
      Dwarf_Lines *lines = NULL;
      size_t nlines = 0;
      if (dwarf_getsrclines (cu, &lines, &nlines) != 0 || lines == NULL)
        continue;
      for (size_t i = 0; i < nlines; i++)
        {
          Dwarf_Line *l = dwarf_onesrcline (lines, i);
          if (l == NULL) continue;
          int lineno = 0;
          const char *src = dwarf_linesrc (l, NULL, NULL);
          if (src == NULL) continue;
          if (dwarf_lineno (l, &lineno) != 0) continue;
          if (lineno != ctx->line) continue;
          if (strcmp (src, ctx->file) != 0
              && strcmp (basename_of (src), basename_of (ctx->file)) != 0)
            continue;
          Dwarf_Addr a = 0;
          if (dwarf_lineaddr (l, &a) == 0)
            {
              ctx->result = (void *) (uintptr_t) (a + bias);
              return DWARF_CB_ABORT;
            }
        }
    }
  return DWARF_CB_OK;
}

void *
cmacs_cintrospect_source_to_addr (const char *file, int line)
{
  if (cintrospect_dwfl == NULL || file == NULL || line <= 0)
    return NULL;
  struct src2addr_ctx ctx = { file, line, NULL };
  cintrospect_lock ();
  dwfl_getmodules (cintrospect_dwfl, src2addr_cu_cb, &ctx, 0);
  cintrospect_unlock ();
  return ctx.result;
}

/* ── Type lookup (recursive) ─────────────────────────────────────── */

void
cmacs_cintrospect_type_free (CmacsCintroType *t)
{
  if (t == NULL) return;
  xfree (t->name);
  for (size_t i = 0; i < t->n_fields; i++)
    {
      xfree (t->fields[i].name);
      xfree (t->fields[i].type_name);
    }
  xfree (t->fields);
  memset (t, 0, sizeof *t);
}

/* Resolve TYPE attribute on DIE down through typedefs, etc.,
 * returning the underlying tag of the eventual base type and its
 * name (in NAME_OUT, xmalloc'd).  *SIZE_OUT gets DW_AT_byte_size if
 * available. */
static void
type_attr_describe (Dwarf_Die *die,
                    CmacsCintroTypeKind *kind_out,
                    char **name_out,
                    size_t *size_out)
{
  *kind_out = CMACS_CINTRO_TYPE_UNKNOWN;
  if (name_out) *name_out = NULL;
  if (size_out) *size_out = 0;

  Dwarf_Attribute attr_mem;
  Dwarf_Attribute *type_attr = dwarf_attr_integrate (die, DW_AT_type, &attr_mem);
  if (type_attr == NULL)
    return;

  Dwarf_Die ref;
  if (dwarf_formref_die (type_attr, &ref) == NULL)
    return;

  int tag = dwarf_tag (&ref);
  *kind_out = dwtag_to_kind (tag);
  const char *n = dwarf_diename (&ref);
  if (name_out)
    *name_out = xstrdup_or_null (n);

  if (size_out)
    {
      Dwarf_Word bsz;
      Dwarf_Attribute sz_mem;
      Dwarf_Attribute *sz = dwarf_attr_integrate (&ref, DW_AT_byte_size, &sz_mem);
      if (sz != NULL && dwarf_formudata (sz, &bsz) == 0)
        *size_out = (size_t) bsz;
    }
}

static int
fill_struct_fields (Dwarf_Die *type_die,
                    CmacsCintroField **fields_out,
                    size_t *n_fields_out)
{
  /* First pass: count. */
  Dwarf_Die child;
  if (dwarf_child (type_die, &child) != 0)
    {
      *fields_out = NULL;
      *n_fields_out = 0;
      return 0;
    }
  size_t count = 0;
  do
    {
      if (dwarf_tag (&child) == DW_TAG_member)
        count++;
    }
  while (dwarf_siblingof (&child, &child) == 0);

  if (count == 0)
    {
      *fields_out = NULL;
      *n_fields_out = 0;
      return 0;
    }

  CmacsCintroField *arr = xmalloc (count * sizeof *arr);
  memset (arr, 0, count * sizeof *arr);
  size_t idx = 0;

  if (dwarf_child (type_die, &child) != 0)
    {
      xfree (arr);
      *fields_out = NULL;
      *n_fields_out = 0;
      return 0;
    }
  do
    {
      if (dwarf_tag (&child) != DW_TAG_member)
        continue;
      CmacsCintroField *f = &arr[idx];
      const char *fn = dwarf_diename (&child);
      f->name = xstrdup_or_null (fn);

      Dwarf_Word offset = 0;
      Dwarf_Attribute mem;
      Dwarf_Attribute *off = dwarf_attr_integrate (&child,
                              DW_AT_data_member_location, &mem);
      if (off != NULL && dwarf_formudata (off, &offset) == 0)
        f->offset = (size_t) offset;

      Dwarf_Word bit_size = 0;
      Dwarf_Attribute *bs = dwarf_attr_integrate (&child, DW_AT_bit_size, &mem);
      if (bs != NULL && dwarf_formudata (bs, &bit_size) == 0)
        f->bit_size = (unsigned) bit_size;

      type_attr_describe (&child, &f->type_kind, &f->type_name, &f->size);
      idx++;
    }
  while (dwarf_siblingof (&child, &child) == 0);

  *fields_out = arr;
  *n_fields_out = idx;
  return 0;
}

static int
fill_enum_fields (Dwarf_Die *type_die,
                  CmacsCintroField **fields_out,
                  size_t *n_fields_out)
{
  Dwarf_Die child;
  if (dwarf_child (type_die, &child) != 0)
    {
      *fields_out = NULL;
      *n_fields_out = 0;
      return 0;
    }
  size_t count = 0;
  do
    {
      if (dwarf_tag (&child) == DW_TAG_enumerator)
        count++;
    }
  while (dwarf_siblingof (&child, &child) == 0);
  if (count == 0)
    {
      *fields_out = NULL;
      *n_fields_out = 0;
      return 0;
    }
  CmacsCintroField *arr = xmalloc (count * sizeof *arr);
  memset (arr, 0, count * sizeof *arr);
  size_t idx = 0;
  if (dwarf_child (type_die, &child) != 0)
    { xfree (arr); *fields_out = NULL; *n_fields_out = 0; return 0; }
  do
    {
      if (dwarf_tag (&child) != DW_TAG_enumerator)
        continue;
      CmacsCintroField *f = &arr[idx];
      f->name = xstrdup_or_null (dwarf_diename (&child));
      Dwarf_Word val = 0;
      Dwarf_Attribute mem;
      Dwarf_Attribute *va = dwarf_attr_integrate (&child,
                              DW_AT_const_value, &mem);
      if (va != NULL && dwarf_formudata (va, &val) == 0)
        f->offset = (size_t) val;
      idx++;
    }
  while (dwarf_siblingof (&child, &child) == 0);
  *fields_out = arr;
  *n_fields_out = idx;
  return 0;
}

struct type_lookup_ctx
{
  const char *target;
  CmacsCintroType *out;
  bool found;
};

static int
type_lookup_module_cb (Dwfl_Module *mod, void **userdata,
                       const char *name, Dwarf_Addr start, void *arg)
{
  (void) userdata; (void) name; (void) start;
  struct type_lookup_ctx *ctx = arg;
  if (ctx->found)
    return DWARF_CB_ABORT;

  Dwarf_Die *cu = NULL;
  Dwarf_Addr bias = 0;
  while (!ctx->found
         && (cu = dwfl_module_nextcu (mod, cu, &bias)) != NULL)
    {
      Dwarf_Die child;
      if (dwarf_child (cu, &child) != 0)
        continue;
      do
        {
          int tag = dwarf_tag (&child);
          CmacsCintroTypeKind k = dwtag_to_kind (tag);
          if (k == CMACS_CINTRO_TYPE_UNKNOWN
              && tag != DW_TAG_typedef
              && tag != DW_TAG_structure_type
              && tag != DW_TAG_union_type
              && tag != DW_TAG_enumeration_type
              && tag != DW_TAG_base_type)
            continue;
          const char *dname = dwarf_diename (&child);
          if (dname == NULL || strcmp (dname, ctx->target) != 0)
            continue;

          CmacsCintroType *t = ctx->out;
          memset (t, 0, sizeof *t);
          t->name = xstrdup_or_null (dname);
          t->kind = k;
          Dwarf_Word bsz = 0;
          Dwarf_Attribute mem;
          Dwarf_Attribute *sz = dwarf_attr_integrate (&child,
                                  DW_AT_byte_size, &mem);
          if (sz != NULL && dwarf_formudata (sz, &bsz) == 0)
            t->size = (size_t) bsz;
          /* DWARF doesn't carry alignment in v4; v5's DW_AT_alignment may. */
          Dwarf_Attribute *al = dwarf_attr_integrate (&child,
                                  DW_AT_alignment, &mem);
          Dwarf_Word avalw = 0;
          if (al != NULL && dwarf_formudata (al, &avalw) == 0)
            t->align = (size_t) avalw;
          else if (t->size > 0)
            t->align = t->size > 8 ? 8 : t->size;

          if (k == CMACS_CINTRO_TYPE_STRUCT
              || k == CMACS_CINTRO_TYPE_UNION)
            fill_struct_fields (&child, &t->fields, &t->n_fields);
          else if (k == CMACS_CINTRO_TYPE_ENUM)
            fill_enum_fields (&child, &t->fields, &t->n_fields);
          else if (k == CMACS_CINTRO_TYPE_TYPEDEF)
            {
              t->fields = xmalloc (sizeof *t->fields);
              memset (t->fields, 0, sizeof *t->fields);
              type_attr_describe (&child, &t->fields[0].type_kind,
                                  &t->fields[0].type_name,
                                  &t->fields[0].size);
              t->n_fields = 1;
            }

          ctx->found = true;
          break;
        }
      while (dwarf_siblingof (&child, &child) == 0);
    }
  return ctx->found ? DWARF_CB_ABORT : DWARF_CB_OK;
}

bool
cmacs_cintrospect_type_lookup (const char *name, CmacsCintroType *out)
{
  if (cintrospect_dwfl == NULL || name == NULL || out == NULL)
    return false;
  memset (out, 0, sizeof *out);
  struct type_lookup_ctx ctx = { name, out, false };
  cintrospect_lock ();
  dwfl_getmodules (cintrospect_dwfl, type_lookup_module_cb, &ctx, 0);
  cintrospect_unlock ();
  return ctx.found;
}

/* ── Loaded objects walk ─────────────────────────────────────────── */

void
cmacs_cintrospect_object_free (CmacsCintroObject *o)
{
  if (o == NULL) return;
  xfree (o->name);
  xfree (o->path);
  o->name = o->path = NULL;
}

struct obj_walk_ctx
{
  CmacsCintroObjIterFn fn;
  void *user_data;
  bool stop;
};

static int
obj_walk_cb (Dwfl_Module *mod, void **userdata,
             const char *name, Dwarf_Addr start, void *arg)
{
  (void) userdata;
  struct obj_walk_ctx *ctx = arg;
  if (ctx->stop)
    return DWARF_CB_ABORT;

  Dwarf_Addr low_addr = 0, high_addr = 0;
  const char *fname = NULL;
  const char *modname = dwfl_module_info (mod, NULL, &low_addr, &high_addr,
                                          NULL, NULL, &fname, NULL);
  if (modname == NULL) modname = name;

  /* Probe DWARF availability cheaply: ask for the first CU. */
  Dwarf_Die *cu = NULL;
  Dwarf_Addr bias = 0;
  bool has_dwarf = (dwfl_module_nextcu (mod, cu, &bias) != NULL);

  CmacsCintroObject one =
    {
      .name = (char *) basename_of (modname),
      .path = (char *) (fname ? fname : modname),
      .load_bias = (unsigned long) start,
      .has_dwarf = has_dwarf,
      .size = (size_t) (high_addr > low_addr ? high_addr - low_addr : 0),
    };
  if (!ctx->fn (&one, ctx->user_data))
    ctx->stop = true;
  return ctx->stop ? DWARF_CB_ABORT : DWARF_CB_OK;
}

void
cmacs_cintrospect_object_walk (CmacsCintroObjIterFn fn, void *user_data)
{
  if (cintrospect_dwfl == NULL || fn == NULL)
    return;
  struct obj_walk_ctx ctx = { fn, user_data, false };
  cintrospect_lock ();
  dwfl_getmodules (cintrospect_dwfl, obj_walk_cb, &ctx, 0);
  cintrospect_unlock ();
}

#endif /* HAVE_CMACS_CINTROSPECT */
