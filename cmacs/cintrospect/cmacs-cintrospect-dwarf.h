/*
 * cmacs-cintrospect-dwarf.h — DWARF reader (libdw/libdwfl wrapper)
 *
 * Copyright (C) 2026 Zach Podbielniak
 * SPDX-License-Identifier: AGPL-3.0-or-later
 */

#ifndef CMACS_CINTROSPECT_DWARF_H
#define CMACS_CINTROSPECT_DWARF_H

#include "lisp.h"

#ifdef HAVE_CMACS_CINTROSPECT

#include <stdbool.h>
#include <stddef.h>

/* Initialise the DWARF reader: open /proc/self/exe + every loaded
 * shared object via libdwfl.  Must be called once at subsystem init.
 * Returns true on success. */
extern bool cmacs_cintrospect_dwarf_init (void);

/* Tear down (only used at shutdown for clean valgrind runs). */
extern void cmacs_cintrospect_dwarf_shutdown (void);

/* ── Symbol & address ─────────────────────────────────────────────── */

typedef enum
{
  CMACS_CINTRO_SYM_UNKNOWN = 0,
  CMACS_CINTRO_SYM_FUNCTION,
  CMACS_CINTRO_SYM_DATA,
} CmacsCintroSymKind;

typedef struct
{
  char *name;          /* xmalloc'd */
  char *object;        /* xmalloc'd basename of containing ELF object */
  void *runtime_addr;  /* with load bias added */
  size_t size;
  CmacsCintroSymKind kind;
} CmacsCintroSym;

extern void cmacs_cintrospect_sym_free (CmacsCintroSym *s);

/* Look up a symbol by exact name.  Walks all loaded modules; returns
 * the first match.  *OUT receives a populated struct on success
 * (caller frees with cmacs_cintrospect_sym_free). */
extern bool cmacs_cintrospect_sym_lookup (const char *name,
                                          CmacsCintroSym *out);

/* Walk every Lisp-relevant symbol matching the optional GLOB pattern.
 * For each, CALLBACK is invoked with a stack-allocated CmacsCintroSym
 * whose lifetime ends when the callback returns (do not keep
 * pointers).  Iteration stops if the callback returns false. */
typedef bool (*CmacsCintroSymIterFn) (const CmacsCintroSym *sym,
                                      void *user_data);

extern void cmacs_cintrospect_sym_walk (const char *glob,
                                        CmacsCintroSymIterFn fn,
                                        void *user_data);

/* Resolve a runtime address into (file, line, function name).  *FILE
 * and *FN are xmalloc'd; caller frees. */
extern bool cmacs_cintrospect_addr_lookup (void *addr,
                                           char **file_out,
                                           int *line_out,
                                           char **fn_out);

/* Look up the runtime address corresponding to FILE:LINE.  Returns
 * NULL if no exact match. */
extern void *cmacs_cintrospect_source_to_addr (const char *file, int line);

/* ── Types ────────────────────────────────────────────────────────── */

typedef enum
{
  CMACS_CINTRO_TYPE_UNKNOWN = 0,
  CMACS_CINTRO_TYPE_BASE,        /* int, char, _Bool, etc. */
  CMACS_CINTRO_TYPE_POINTER,
  CMACS_CINTRO_TYPE_ARRAY,
  CMACS_CINTRO_TYPE_STRUCT,
  CMACS_CINTRO_TYPE_UNION,
  CMACS_CINTRO_TYPE_ENUM,
  CMACS_CINTRO_TYPE_TYPEDEF,
  CMACS_CINTRO_TYPE_FUNCTION,
} CmacsCintroTypeKind;

typedef struct CmacsCintroField CmacsCintroField;
struct CmacsCintroField
{
  char *name;                  /* xmalloc'd; NULL for anonymous fields */
  size_t offset;               /* byte offset; for bitfields, low bit position */
  size_t size;                 /* byte size */
  unsigned bit_size;           /* 0 = not a bitfield, >0 = width in bits */
  char *type_name;             /* xmalloc'd, may be NULL for anonymous */
  CmacsCintroTypeKind type_kind;
};

typedef struct
{
  char *name;                  /* xmalloc'd */
  CmacsCintroTypeKind kind;
  size_t size;                 /* byte size; 0 if incomplete */
  size_t align;
  CmacsCintroField *fields;    /* xmalloc'd array */
  size_t n_fields;
  /* For ENUM, fields[].offset holds the enumerator value, name holds
   * the enumerator name, size/align/bit_size unused. */
  /* For TYPEDEF, fields[0].type_name is the underlying type. */
  /* For FUNCTION, fields[0] = return type, fields[1..] = params. */
} CmacsCintroType;

extern void cmacs_cintrospect_type_free (CmacsCintroType *t);

extern bool cmacs_cintrospect_type_lookup (const char *name,
                                           CmacsCintroType *out);

/* ── Loaded objects ───────────────────────────────────────────────── */

typedef struct
{
  char *name;                  /* basename, xmalloc'd */
  char *path;                  /* full path, xmalloc'd */
  unsigned long load_bias;
  bool has_dwarf;
  size_t size;
} CmacsCintroObject;

extern void cmacs_cintrospect_object_free (CmacsCintroObject *o);

typedef bool (*CmacsCintroObjIterFn) (const CmacsCintroObject *obj,
                                      void *user_data);

extern void cmacs_cintrospect_object_walk (CmacsCintroObjIterFn fn,
                                           void *user_data);

#endif /* HAVE_CMACS_CINTROSPECT */
#endif /* CMACS_CINTROSPECT_DWARF_H */
