/* cmacs-cad-assembly.c --- Assembly DEFUNs (mates, joints, BOM, clash).
 *
 * Copyright (C) 2026 Zach Podbielniak
 * SPDX-License-Identifier: AGPL-3.0-or-later
 *
 * A thin Lisp bridge to cad-glib's assembly layer.  Assemblies are
 * defined in the part source with `defassembly' and built/solved during
 * evaluation, so these primitives operate on the assembly stored in the
 * already-evaluated CadDocument (cmacs-cad-eval populates it).  The one
 * mutating path, `cmacs-cad-assembly-set-joint', drives a joint on the
 * LIVE assembly and re-solves WITHOUT re-evaluating the source, so joint
 * motion does not reset the mechanism.
 */

#include <config.h>

#ifdef HAVE_CMACS_CAD

#include "lisp.h"
#include "cmacs-cad.h"
#include "cmacs-cad-internal.h"

#include <string.h>

/* Open + cache the document at PATH (signals on failure). */
static CadDocument *
cmacs_cad_asm_doc (Lisp_Object path)
{
  GError *error = NULL;
  CadDocument *document;
  CHECK_STRING (path);
  document = cmacs_cad_doc_open (SSDATA (path), &error);
  if (document == NULL)
    cmacs_cad_signal (error);
  return document;
}

/* Look up the named assembly in the (already-evaluated) document. */
static CadAssembly *
cmacs_cad_asm_require (CadDocument *document, Lisp_Object name)
{
  CadAssembly *assembly;
  CHECK_STRING (name);
  assembly = cad_document_get_assembly (document, SSDATA (name));
  if (assembly == NULL)
    cmacs_cad_error_str ("no such assembly (evaluate the part first?)");
  return assembly;
}

static Lisp_Object
cmacs_cad_constraint_state_sym (CadConstraintState state)
{
  switch (state)
    {
    case CAD_CONSTRAINT_WELL_CONSTRAINED:  return intern ("well-constrained");
    case CAD_CONSTRAINT_UNDER_CONSTRAINED: return intern ("under-constrained");
    case CAD_CONSTRAINT_OVER_CONSTRAINED:  return intern ("over-constrained");
    default:                               return intern ("unsolved");
    }
}

/* Build (ID NAME [m0 .. m11]) for one instance. */
static Lisp_Object
cmacs_cad_instance_entry (CadAssemblyInstance *inst)
{
  gdouble m[12];
  Lisp_Object vec;
  int i;

  cad_assembly_instance_get_transform (inst, m);
  vec = make_vector (12, Qnil);
  for (i = 0; i < 12; i++)
    ASET (vec, i, make_float (m[i]));

  return list3 (make_fixnum (cad_assembly_instance_get_id (inst)),
                build_string (cad_assembly_instance_get_name (inst)
                              ? cad_assembly_instance_get_name (inst) : ""),
                vec);
}

static Lisp_Object
cmacs_cad_instances_list (CadAssembly *assembly)
{
  GPtrArray *instances = cad_assembly_get_instances (assembly);
  Lisp_Object result = Qnil;
  guint i;

  for (i = 0; i < instances->len; i++)
    result = Fcons (cmacs_cad_instance_entry
                    (g_ptr_array_index (instances, i)), result);
  return Fnreverse (result);
}

DEFUN ("cmacs-cad-assembly-names", Fcmacs_cad_assembly_names,
       Scmacs_cad_assembly_names, 1, 1, 0,
       doc: /* Return the assembly names defined by the last eval of PATH.  */)
  (Lisp_Object path)
{
  CadDocument *document = cmacs_cad_asm_doc (path);
  GPtrArray *names = cad_document_get_assembly_names (document);
  Lisp_Object result = Qnil;
  guint i;

  for (i = 0; i < names->len; i++)
    result = Fcons (build_string (g_ptr_array_index (names, i)), result);
  g_ptr_array_unref (names);

  return Fnreverse (result);
}

DEFUN ("cmacs-cad-assembly-info", Fcmacs_cad_assembly_info,
       Scmacs_cad_assembly_info, 2, 2, 0,
       doc: /* Return info on assembly NAME in PATH.
A plist (:state SYM :dof N :instances ((ID NAME [m0..m11]) ...)).  */)
  (Lisp_Object path, Lisp_Object name)
{
  CadDocument *document = cmacs_cad_asm_doc (path);
  CadAssembly *assembly = cmacs_cad_asm_require (document, name);
  Lisp_Object plist = Qnil;

  plist = Fcons (intern (":instances"),
                 Fcons (cmacs_cad_instances_list (assembly), plist));
  plist = Fcons (intern (":dof"),
                 Fcons (make_fixnum (cad_assembly_get_dof (assembly)),
                        plist));
  plist = Fcons (intern (":state"),
                 Fcons (cmacs_cad_constraint_state_sym
                        (cad_assembly_get_state (assembly)), plist));
  return plist;
}

DEFUN ("cmacs-cad-assembly-bom", Fcmacs_cad_assembly_bom,
       Scmacs_cad_assembly_bom, 2, 2, 0,
       doc: /* Return the bill of materials for assembly NAME in PATH.
A list of plists (:part NAME :quantity N :volume V :mass M).  */)
  (Lisp_Object path, Lisp_Object name)
{
  CadDocument *document = cmacs_cad_asm_doc (path);
  CadAssembly *assembly = cmacs_cad_asm_require (document, name);
  GPtrArray *bom = cad_assembly_get_bom (assembly);
  Lisp_Object result = Qnil;
  guint i;

  for (i = 0; i < bom->len; i++)
    {
      CadBomEntry *e = g_ptr_array_index (bom, i);
      Lisp_Object plist = Qnil;

      plist = Fcons (intern (":mass"),
                     Fcons (make_float (e->unit_mass * e->quantity), plist));
      plist = Fcons (intern (":volume"),
                     Fcons (make_float (e->unit_volume * e->quantity),
                            plist));
      plist = Fcons (intern (":quantity"),
                     Fcons (make_fixnum (e->quantity), plist));
      plist = Fcons (intern (":part"),
                     Fcons (build_string (e->part_name ? e->part_name : ""),
                            plist));
      result = Fcons (plist, result);
    }
  g_ptr_array_unref (bom);

  return Fnreverse (result);
}

DEFUN ("cmacs-cad-assembly-interference", Fcmacs_cad_assembly_interference,
       Scmacs_cad_assembly_interference, 2, 3, 0,
       doc: /* Return interferences in assembly NAME of PATH.
A list of plists (:a IDA :b IDB :volume V).  Optional TOLERANCE ignores
overlaps at or below that volume (default 1e-6).  */)
  (Lisp_Object path, Lisp_Object name, Lisp_Object tolerance)
{
  CadDocument *document = cmacs_cad_asm_doc (path);
  CadAssembly *assembly = cmacs_cad_asm_require (document, name);
  GError *error = NULL;
  gdouble tol = 1e-6;
  GPtrArray *hits;
  Lisp_Object result = Qnil;
  guint i;

  if (!NILP (tolerance))
    {
      CHECK_NUMBER (tolerance);
      tol = XFLOATINT (tolerance);
    }

  hits = cad_assembly_check_interference (assembly, tol, &error);
  if (hits == NULL)
    cmacs_cad_signal (error);

  for (i = 0; i < hits->len; i++)
    {
      CadInterference *h = g_ptr_array_index (hits, i);
      Lisp_Object plist = Qnil;

      plist = Fcons (intern (":volume"),
                     Fcons (make_float (h->overlap_volume), plist));
      plist = Fcons (intern (":b"),
                     Fcons (make_fixnum (h->instance_b), plist));
      plist = Fcons (intern (":a"),
                     Fcons (make_fixnum (h->instance_a), plist));
      result = Fcons (plist, result);
    }
  g_ptr_array_unref (hits);

  return Fnreverse (result);
}

DEFUN ("cmacs-cad-assembly-joints", Fcmacs_cad_assembly_joints,
       Scmacs_cad_assembly_joints, 2, 2, 0,
       doc: /* Return the joints of assembly NAME in PATH.
A list of plists (:id ID :kind SYM :value V :dof N).  */)
  (Lisp_Object path, Lisp_Object name)
{
  CadDocument *document = cmacs_cad_asm_doc (path);
  CadAssembly *assembly = cmacs_cad_asm_require (document, name);
  GPtrArray *joints = cad_assembly_get_joints (assembly);
  Lisp_Object result = Qnil;
  guint i;

  for (i = 0; i < joints->len; i++)
    {
      CadJoint *j = g_ptr_array_index (joints, i);
      GEnumClass *klass = g_type_class_ref (CAD_TYPE_JOINT_KIND);
      GEnumValue *ev = g_enum_get_value (klass, cad_joint_get_kind (j));
      Lisp_Object plist = Qnil;

      plist = Fcons (intern (":dof"),
                     Fcons (make_fixnum (cad_joint_get_dof (j)), plist));
      plist = Fcons (intern (":value"),
                     Fcons (make_float (cad_joint_get_value (j)), plist));
      plist = Fcons (intern (":kind"),
                     Fcons (intern (ev ? ev->value_nick : "fixed"), plist));
      plist = Fcons (intern (":id"),
                     Fcons (make_fixnum (cad_joint_get_id (j)), plist));
      g_type_class_unref (klass);
      result = Fcons (plist, result);
    }

  return Fnreverse (result);
}

DEFUN ("cmacs-cad-assembly-set-joint", Fcmacs_cad_assembly_set_joint,
       Scmacs_cad_assembly_set_joint, 4, 4, 0,
       doc: /* Drive JOINT-ID of assembly NAME in PATH to VALUE and re-solve.
Operates on the live assembly WITHOUT re-evaluating the source (so the
mechanism does not reset).  Returns the updated :instances list, or
signals on a solve failure.  */)
  (Lisp_Object path, Lisp_Object name, Lisp_Object joint_id,
   Lisp_Object value)
{
  CadDocument *document = cmacs_cad_asm_doc (path);
  CadAssembly *assembly = cmacs_cad_asm_require (document, name);
  GPtrArray *joints = cad_assembly_get_joints (assembly);
  GError *error = NULL;
  guint id;
  guint i;
  CadJoint *target = NULL;

  CHECK_FIXNUM (joint_id);
  CHECK_NUMBER (value);
  id = (guint) XFIXNUM (joint_id);

  for (i = 0; i < joints->len; i++)
    {
      CadJoint *j = g_ptr_array_index (joints, i);
      if (cad_joint_get_id (j) == id)
        {
          target = j;
          break;
        }
    }
  if (target == NULL)
    cmacs_cad_error_str ("no such joint");

  cad_joint_set_value (target, XFLOATINT (value));
  if (!cad_assembly_solve (assembly, &error))
    cmacs_cad_signal (error);

  return cmacs_cad_instances_list (assembly);
}

void
syms_of_cmacs_cad_assembly (void)
{
  defsubr (&Scmacs_cad_assembly_names);
  defsubr (&Scmacs_cad_assembly_info);
  defsubr (&Scmacs_cad_assembly_bom);
  defsubr (&Scmacs_cad_assembly_interference);
  defsubr (&Scmacs_cad_assembly_joints);
  defsubr (&Scmacs_cad_assembly_set_joint);
}

#endif /* HAVE_CMACS_CAD */
