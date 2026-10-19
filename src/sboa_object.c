/*
   Copyright (c) 2026 Semgrep Inc.

   This library is free software; you can redistribute it and/or
   modify it under the terms of the GNU Lesser General Public License
   version 2.1 as published by the Free Software Foundation.

   This library is distributed in the hope that it will be useful, but
   WITHOUT ANY WARRANTY; without even the implied warranty of
   MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the file
   LICENSE for more details.
*/
/* sboa objects: the Object.t custom block, object operations,
   conversions between OCaml and Python values, and the Python -> OCaml
   exception crossing (pending slot + classification).

   Object.t is a custom block holding one owned PyObject* and nothing else
   (blocks move; the pointer does not). It is allocated with
   caml_alloc_custom_mem so the OCaml GC paces itself on an estimate of the
   Python-side size (OCaml manual 22.9.3). The finalizer queues the DECREF
   (see sboa_runtime.c). There is no compare/hash/serialize: those would
   have to call Python from GC or marshal contexts.

   Every stub here runs with the GIL held (guaranteed by the gil token of the
   OCaml API) and the domain lock held. Stubs that may run arbitrary Python
   code (calls, attribute access, str/repr, import, eval) first move their
   inputs into C/Python, INCREF the objects they borrow from OCaml handles,
   then run the Python part inside sboa_py_enter/leave, and only build
   OCaml values afterwards. Pure constructors/readers of builtin types run no
   Python code and keep the domain lock. */
#include "sboa_internal.h"

#include <string.h>

/* ------------------------------------------------------------------------ */
/* Custom block                                                              */

#define Obj_ptr(v) SBOA_OBJ_PTR(v)

static void obj_finalize(value v) {
  PyObject *o = Obj_ptr(v);
  if (o != NULL) sboa_defer_decref(o);
}

static struct custom_operations obj_ops = {
    "sboa.object.v1",      obj_finalize,
    custom_compare_default,   custom_hash_default,
    custom_serialize_default, custom_deserialize_default,
    custom_compare_ext_default, custom_fixed_length_default};

static mlsize_t size_estimate(PyObject *o) {
  PyTypeObject *t = Py_TYPE(o);
  Py_ssize_t n = t->tp_basicsize;
  /* Py_SIZE is not meaningful for ints since 3.12 (tagged digit count). */
  if (PyLong_Check(o)) {
    n += sizeof(digit);
  } else if (t->tp_itemsize != 0) {
    Py_ssize_t k = Py_SIZE(o);
    n += (k < 0 ? -k : k) * t->tp_itemsize;
  } else if (PyUnicode_Check(o)) {
    n += PyUnicode_GET_LENGTH(o) * PyUnicode_KIND(o);
  }
  return (mlsize_t)n;
}

value sboa_wrap(PyObject *o) {
  value v = caml_alloc_custom_mem(&obj_ops, sizeof(PyObject *), size_estimate(o));
  Obj_ptr(v) = o;
  return v;
}

/* Every stub that dereferences a handle goes through here, which makes it
   the natural place to check that the caller's gil token is live. */
PyObject *sboa_obj(value v) {
  sboa_check_gil();
  PyObject *o = Obj_ptr(v);
  if (o == NULL) caml_invalid_argument("Sboa.Object: used after release");
  return o;
}

/* ------------------------------------------------------------------------ */
/* Pending Python exception                                                  */

static PyObject *pending_exc = NULL;
static const value *pending_exn = NULL;
static const value *overflow_exn = NULL;

void sboa_raise_pending(void) {
  PyObject *e = PyErr_GetRaisedException();
  if (e == NULL) {
    PyErr_SetString(PyExc_SystemError,
                    "sboa: Python API call failed without an exception");
    e = PyErr_GetRaisedException();
  }
  if (pending_exc != NULL) sboa_defer_decref(pending_exc);
  pending_exc = e;
  if (pending_exn == NULL) pending_exn = caml_named_value("sboa.pending");
  caml_raise_constant(*pending_exn);
}

static void raise_overflow(void) {
  if (overflow_exn == NULL) overflow_exn = caml_named_value("sboa.overflow");
  caml_raise_constant(*overflow_exn);
}

value sboa_take_pending(value unit) {
  sboa_check_gil();
  PyObject *e = pending_exc;
  pending_exc = NULL;
  return sboa_wrap(e != NULL ? e : Py_NewRef(Py_None));
}

/* ------------------------------------------------------------------------ */
/* Basic object operations                                                   */

value sboa_none(value unit) { return sboa_wrap(Py_NewRef(Py_None)); }

value sboa_is_none(value v) { return Val_bool(Obj_ptr(v) == Py_None); }

value sboa_release(value v) {
  sboa_check_gil();
  PyObject *o = Obj_ptr(v);
  Obj_ptr(v) = NULL;
  if (o != NULL) {
    sboa_py_section s = sboa_py_enter();
    Py_DECREF(o);
    sboa_py_leave(s);
  }
  return Val_unit;
}

value sboa_refcount(value v) { return Val_long(Py_REFCNT(sboa_obj(v))); }

/* Short type name (tp_name after the last dot), no Python code. */
value sboa_type_name(value v) {
  const char *n = Py_TYPE(sboa_obj(v))->tp_name;
  const char *dot = strrchr(n, '.');
  return caml_copy_string(dot ? dot + 1 : n);
}

value sboa_is_callable(value v) {
  return Val_bool(PyCallable_Check(sboa_obj(v)));
}

static PyObject *unicode_of_ml(value s) {
  sboa_check_gil();
  PyObject *u = PyUnicode_DecodeUTF8(String_val(s), caml_string_length(s), NULL);
  if (u == NULL) sboa_raise_pending();
  return u;
}

value sboa_import(value v_name) {
  PyObject *name = unicode_of_ml(v_name);
  sboa_py_section s = sboa_py_enter();
  PyObject *m = PyImport_Import(name);
  Py_DECREF(name);
  sboa_py_leave(s);
  if (m == NULL) sboa_raise_pending();
  return sboa_wrap(m);
}

value sboa_get_attr(value v_o, value v_name) {
  PyObject *o = Py_NewRef(sboa_obj(v_o));
  PyObject *name = PyUnicode_DecodeUTF8(String_val(v_name),
                                        caml_string_length(v_name), NULL);
  sboa_py_section s = sboa_py_enter();
  PyObject *r = name ? PyObject_GetAttr(o, name) : NULL;
  Py_XDECREF(name);
  Py_DECREF(o);
  sboa_py_leave(s);
  if (r == NULL) sboa_raise_pending();
  return sboa_wrap(r);
}

value sboa_set_attr(value v_o, value v_name, value v_x) {
  PyObject *o = Py_NewRef(sboa_obj(v_o));
  PyObject *x = Py_NewRef(sboa_obj(v_x));
  PyObject *name = PyUnicode_DecodeUTF8(String_val(v_name),
                                        caml_string_length(v_name), NULL);
  sboa_py_section s = sboa_py_enter();
  int rc = name ? PyObject_SetAttr(o, name, x) : -1;
  Py_XDECREF(name);
  Py_DECREF(o);
  Py_DECREF(x);
  sboa_py_leave(s);
  if (rc != 0) sboa_raise_pending();
  return Val_unit;
}

#define SMALL_ARGS 8

/* sboa_call f args kwnames kwvalues: PyObject_Vectorcall with keyword
   names in a tuple (call.html#c.PyObject_Vectorcall). */
value sboa_call(value v_f, value v_args, value v_kwnames, value v_kwvals) {
  mlsize_t na = Wosize_val(v_args), nk = Wosize_val(v_kwnames);
  if (Wosize_val(v_kwvals) != nk)
    caml_invalid_argument("Sboa.Object.call: keyword arity");
  /* Validate every handle before taking any reference. */
  PyObject *f = sboa_obj(v_f);
  for (mlsize_t i = 0; i < na; i++) (void)sboa_obj(Field(v_args, i));
  for (mlsize_t i = 0; i < nk; i++) (void)sboa_obj(Field(v_kwvals, i));
  PyObject *small[SMALL_ARGS];
  PyObject **argv = small;
  /* argv[0] is scratch so we can pass PY_VECTORCALL_ARGUMENTS_OFFSET. */
  if (na + nk + 1 > SMALL_ARGS) {
    argv = PyMem_Malloc((na + nk + 1) * sizeof(PyObject *));
    if (argv == NULL) {
      PyErr_NoMemory();
      sboa_raise_pending();
    }
  }
  PyObject *kwnames = NULL;
  if (nk > 0) {
    kwnames = PyTuple_New(nk);
    for (mlsize_t i = 0; kwnames != NULL && i < nk; i++) {
      value k = Field(v_kwnames, i);
      PyObject *u = PyUnicode_DecodeUTF8(String_val(k), caml_string_length(k), NULL);
      if (u == NULL) {
        Py_CLEAR(kwnames);
        break;
      }
      PyTuple_SET_ITEM(kwnames, i, u);
    }
    if (kwnames == NULL) {
      if (argv != small) PyMem_Free(argv);
      sboa_raise_pending();
    }
  }
  Py_INCREF(f);
  for (mlsize_t i = 0; i < na; i++) argv[1 + i] = Py_NewRef(Obj_ptr(Field(v_args, i)));
  for (mlsize_t i = 0; i < nk; i++)
    argv[1 + na + i] = Py_NewRef(Obj_ptr(Field(v_kwvals, i)));

  sboa_py_section s = sboa_py_enter();
  PyObject *r = PyObject_Vectorcall(f, argv + 1, na | PY_VECTORCALL_ARGUMENTS_OFFSET,
                                    kwnames);
  for (mlsize_t i = 0; i < na + nk; i++) Py_DECREF(argv[1 + i]);
  Py_XDECREF(kwnames);
  Py_DECREF(f);
  sboa_py_leave(s);
  if (argv != small) PyMem_Free(argv);
  if (r == NULL) sboa_raise_pending();
  return sboa_wrap(r);
}

static value string_of_unicode(PyObject *u) {
  Py_ssize_t n;
  const char *p = PyUnicode_AsUTF8AndSize(u, &n);
  if (p == NULL) {
    Py_DECREF(u);
    sboa_raise_pending();
  }
  value r = caml_alloc_initialized_string(n, p);
  Py_DECREF(u);
  return r;
}

static value str_or_repr(value v_o, int repr) {
  PyObject *o = Py_NewRef(sboa_obj(v_o));
  sboa_py_section s = sboa_py_enter();
  PyObject *u = repr ? PyObject_Repr(o) : PyObject_Str(o);
  Py_DECREF(o);
  sboa_py_leave(s);
  if (u == NULL) sboa_raise_pending();
  return string_of_unicode(u);
}

value sboa_repr(value v) { return str_or_repr(v, 1); }
value sboa_str(value v) { return str_or_repr(v, 0); }

static PyObject *run_main(value v_code, int start) {
  sboa_check_gil();
  char *code = caml_stat_strdup(String_val(v_code));
  sboa_py_section s = sboa_py_enter();
  PyObject *r = NULL;
  PyObject *main = PyImport_AddModuleRef("__main__");
  if (main != NULL) {
    PyObject *g = PyModule_GetDict(main); /* borrowed */
    r = PyRun_String(code, start, g, g);
    Py_DECREF(main);
  }
  sboa_py_leave(s);
  caml_stat_free(code);
  if (r == NULL) sboa_raise_pending();
  return r;
}

value sboa_eval(value v_code) {
  return sboa_wrap(run_main(v_code, Py_eval_input));
}

value sboa_exec(value v_code) {
  PyObject *r = run_main(v_code, Py_file_input);
  sboa_defer_decref(r); /* None; keep DECREFs out of OCaml context */
  return Val_unit;
}

/* ------------------------------------------------------------------------ */
/* Conversions (no Python code runs here)                                    */

value sboa_kind(value v) {
  PyObject *o = sboa_obj(v);
  int k;
  if (o == Py_None) k = 0;
  else if (PyBool_Check(o)) k = 1;
  else if (PyLong_Check(o)) k = 2;
  else if (PyFloat_Check(o)) k = 3;
  else if (PyUnicode_Check(o)) k = 4;
  else if (PyBytes_Check(o) || PyByteArray_Check(o)) k = 5;
  else if (PyList_Check(o)) k = 6;
  else if (PyTuple_Check(o)) k = 7;
  else if (PyDict_Check(o)) k = 8;
  else k = 9;
  return Val_int(k);
}

static value wrap_or_raise(PyObject *o) {
  if (o == NULL) sboa_raise_pending();
  return sboa_wrap(o);
}

value sboa_of_int(value v) {
  sboa_check_gil();
  return wrap_or_raise(PyLong_FromLongLong(Long_val(v))); }

/* PyLong subclasses are converted without calling __index__
   (long.html#c.PyLong_AsLongLongAndOverflow). */
value sboa_to_int(value v) {
  PyObject *o = sboa_obj(v);
  int overflow = 0;
  long long x = PyLong_AsLongLongAndOverflow(o, &overflow);
  if (x == -1 && PyErr_Occurred()) sboa_raise_pending();
  if (overflow != 0 || x > Max_long || x < Min_long) raise_overflow();
  return Val_long(x);
}

value sboa_of_float(value v) {
  sboa_check_gil();
  return wrap_or_raise(PyFloat_FromDouble(Double_val(v))); }

value sboa_to_float(value v) {
  double d = PyFloat_AsDouble(sboa_obj(v));
  if (d == -1.0 && PyErr_Occurred()) sboa_raise_pending();
  return caml_copy_double(d);
}

value sboa_of_bool(value v) {
  sboa_check_gil();
  return sboa_wrap(Py_NewRef(Bool_val(v) ? Py_True : Py_False));
}

value sboa_to_bool(value v) { return Val_bool(sboa_obj(v) == Py_True); }

value sboa_of_string(value v) { return sboa_wrap(unicode_of_ml(v)); }

value sboa_to_string(value v) {
  Py_ssize_t n;
  const char *p = PyUnicode_AsUTF8AndSize(sboa_obj(v), &n);
  if (p == NULL) sboa_raise_pending();
  return caml_alloc_initialized_string(n, p);
}

value sboa_of_bytes(value v) {
  sboa_check_gil();
  return wrap_or_raise(PyBytes_FromStringAndSize(String_val(v), caml_string_length(v)));
}

value sboa_to_bytes(value v) {
  PyObject *o = sboa_obj(v);
  if (PyBytes_Check(o))
    return caml_alloc_initialized_string(PyBytes_GET_SIZE(o), PyBytes_AS_STRING(o));
  if (PyByteArray_Check(o))
    return caml_alloc_initialized_string(PyByteArray_GET_SIZE(o),
                                         PyByteArray_AS_STRING(o));
  caml_invalid_argument("Sboa: expected bytes");
}

static value seq_of_array(value arr, int tuple) {
  sboa_check_gil();
  mlsize_t n = Wosize_val(arr);
  for (mlsize_t i = 0; i < n; i++) (void)sboa_obj(Field(arr, i));
  PyObject *r = tuple ? PyTuple_New(n) : PyList_New(n);
  if (r == NULL) sboa_raise_pending();
  for (mlsize_t i = 0; i < n; i++) {
    PyObject *x = Py_NewRef(Obj_ptr(Field(arr, i)));
    if (tuple) PyTuple_SET_ITEM(r, i, x);
    else PyList_SET_ITEM(r, i, x);
  }
  return sboa_wrap(r);
}

value sboa_list_of_array(value a) { return seq_of_array(a, 0); }
value sboa_tuple_of_array(value a) { return seq_of_array(a, 1); }

value sboa_seq_items(value v) {
  CAMLparam1(v);
  CAMLlocal2(arr, x);
  PyObject *o = sboa_obj(v);
  if (!PyList_Check(o) && !PyTuple_Check(o))
    caml_invalid_argument("Sboa: expected list or tuple");
  /* Hold the sequence: the GC may run while we allocate. */
  Py_INCREF(o);
  Py_ssize_t n = PySequence_Fast_GET_SIZE(o);
  arr = caml_alloc(n, 0);
  for (Py_ssize_t i = 0; i < n; i++) {
    x = sboa_wrap(Py_NewRef(PySequence_Fast_GET_ITEM(o, i)));
    Store_field(arr, i, x);
  }
  sboa_defer_decref(o);
  CAMLreturn(arr);
}

value sboa_dict_of_arrays(value v_keys, value v_vals) {
  mlsize_t n = Wosize_val(v_keys);
  sboa_check_gil();
  if (Wosize_val(v_vals) != n) caml_invalid_argument("Sboa: dict arity");
  for (mlsize_t i = 0; i < n; i++) (void)sboa_obj(Field(v_vals, i));
  PyObject *d = PyDict_New();
  if (d == NULL) sboa_raise_pending();
  for (mlsize_t i = 0; i < n; i++) {
    value k = Field(v_keys, i);
    PyObject *key = PyUnicode_DecodeUTF8(String_val(k), caml_string_length(k), NULL);
    int rc = key ? PyDict_SetItem(d, key, Obj_ptr(Field(v_vals, i))) : -1;
    Py_XDECREF(key);
    if (rc != 0) {
      sboa_defer_decref(d);
      sboa_raise_pending();
    }
  }
  return sboa_wrap(d);
}

value sboa_dict_items(value v) {
  CAMLparam1(v);
  CAMLlocal4(arr, pair, k, x);
  PyObject *d = sboa_obj(v);
  if (!PyDict_Check(d)) caml_invalid_argument("Sboa: expected dict");
  Py_INCREF(d);
  Py_ssize_t n = PyDict_GET_SIZE(d), pos = 0, i = 0;
  PyObject *key, *val;
  arr = caml_alloc(n, 0);
  while (i < n && PyDict_Next(d, &pos, &key, &val)) {
    k = sboa_wrap(Py_NewRef(key));
    x = sboa_wrap(Py_NewRef(val));
    pair = caml_alloc_small(2, 0);
    Field(pair, 0) = k;
    Field(pair, 1) = x;
    Store_field(arr, i, pair);
    i++;
  }
  sboa_defer_decref(d);
  CAMLreturn(arr);
}

/* ------------------------------------------------------------------------ */
/* Python -> OCaml exception crossing                                        */

/* Resurrection capsule of an OCamlError instance, or NULL (no error set). */
static PyObject *ocaml_capsule(PyObject *e) {
  if (sboa_ocaml_error_type == NULL ||
      !PyObject_TypeCheck(e, (PyTypeObject *)sboa_ocaml_error_type))
    return NULL;
  PyObject *cap = NULL;
  if (PyObject_GetOptionalAttrString(e, "ocaml_exn", &cap) < 0) PyErr_Clear();
  if (cap != NULL && !PyCapsule_IsValid(cap, SBOA_EXN_CAPSULE)) Py_CLEAR(cap);
  return cap;
}

value sboa_exc_classify(value v) {
  PyObject *e = Py_NewRef(sboa_obj(v));
  int k = 0;
  sboa_py_section s = sboa_py_enter();
  if (PyErr_GivenExceptionMatches(e, PyExc_SystemExit)) k = 1;
  else if (PyErr_GivenExceptionMatches(e, PyExc_KeyboardInterrupt)) k = 2;
  else {
    PyObject *cap = ocaml_capsule(e);
    if (cap != NULL) k = 3;
    Py_XDECREF(cap);
  }
  Py_DECREF(e);
  sboa_py_leave(s);
  return Val_int(k);
}

value sboa_resurrect(value v) {
  PyObject *e = sboa_obj(v);
  PyObject *cap = ocaml_capsule(e);
  value *root = cap ? PyCapsule_GetPointer(cap, SBOA_EXN_CAPSULE) : NULL;
  if (root == NULL) {
    PyErr_Clear();
    Py_XDECREF(cap);
    caml_invalid_argument("Sboa: not a resurrectable OCamlError");
  }
  value r = *root; /* the capsule (held by e, held by v) keeps the root */
  sboa_defer_decref(cap);
  return r;
}

/* Dotted type name, str(exc), traceback.format_exception(exc). Failures in
   formatting are swallowed: this runs while reporting another error. */
value sboa_exc_info(value v) {
  CAMLparam1(v);
  CAMLlocal4(r, ty, msg, tb);
  PyObject *e = Py_NewRef(sboa_obj(v));
  PyObject *u_ty = NULL, *u_msg = NULL, *u_tb = NULL;
  sboa_py_section s = sboa_py_enter();
  PyTypeObject *t = Py_TYPE(e);
  PyObject *mod = PyType_GetModuleName(t), *qual = PyType_GetQualName(t);
  if (mod && qual) u_ty = PyUnicode_FromFormat("%U.%U", mod, qual);
  Py_XDECREF(mod);
  Py_XDECREF(qual);
  PyErr_Clear();
  u_msg = PyObject_Str(e);
  PyErr_Clear();
  PyObject *tbmod = PyImport_ImportModule("traceback");
  PyObject *lines = tbmod ? PyObject_CallMethod(tbmod, "format_exception", "O", e) : NULL;
  if (lines != NULL) {
    PyObject *empty = PyUnicode_FromString("");
    if (empty) u_tb = PyUnicode_Join(empty, lines);
    Py_XDECREF(empty);
  }
  Py_XDECREF(lines);
  Py_XDECREF(tbmod);
  PyErr_Clear();
  Py_DECREF(e);
  sboa_py_leave(s);
  const char *p;
  Py_ssize_t n;
#define COPY(dst, u, fallback)                                   \
  p = (u) ? PyUnicode_AsUTF8AndSize((u), &n) : NULL;             \
  if (p == NULL) {                                               \
    PyErr_Clear();                                               \
    p = (fallback);                                              \
    n = strlen(p);                                               \
  }                                                              \
  dst = caml_alloc_initialized_string(n, p);
  COPY(ty, u_ty, Py_TYPE(sboa_obj(v))->tp_name);
  COPY(msg, u_msg, "<unprintable exception>");
  COPY(tb, u_tb, "");
#undef COPY
  Py_XDECREF(u_ty);
  Py_XDECREF(u_msg);
  Py_XDECREF(u_tb);
  r = caml_alloc_tuple(3);
  Store_field(r, 0, ty);
  Store_field(r, 1, msg);
  Store_field(r, 2, tb);
  CAMLreturn(r);
}

/* SystemExit.code -> exit status, as CPython's handle_system_exit does:
   None -> 0, int -> int, anything else is printed to stderr -> 1. */
value sboa_exit_code(value v) {
  PyObject *e = Py_NewRef(sboa_obj(v));
  long code = 1;
  sboa_py_section s = sboa_py_enter();
  PyObject *c = PyObject_GetAttrString(e, "code");
  if (c == NULL || c == Py_None) {
    code = c == NULL ? 1 : 0;
  } else if (PyLong_Check(c)) {
    code = PyLong_AsLong(c);
    if (code == -1 && PyErr_Occurred()) code = 1;
  } else {
    PyObject *err = PySys_GetObject("stderr");
    if (err != NULL && err != Py_None) {
      PyFile_WriteObject(c, err, Py_PRINT_RAW);
      PyFile_WriteString("\n", err);
    }
    code = 1;
  }
  PyErr_Clear();
  Py_XDECREF(c);
  Py_DECREF(e);
  sboa_py_leave(s);
  return Val_long(code);
}

/* ------------------------------------------------------------------------ */
/* OCaml -> Python exception crossing (used by the export dispatcher, inside
   with_gil; they set the error indicator, the trampoline returns NULL).     */

value sboa_set_error_obj(value v) {
  PyErr_SetRaisedException(Py_NewRef(sboa_obj(v)));
  return Val_unit;
}

value sboa_set_error_builtin(value v_name, value v_msg) {
  sboa_check_gil();
  const char *n = String_val(v_name);
  PyObject *t = PyExc_RuntimeError;
  if (strcmp(n, "TypeError") == 0) t = PyExc_TypeError;
  else if (strcmp(n, "ValueError") == 0) t = PyExc_ValueError;
  else if (strcmp(n, "KeyboardInterrupt") == 0) t = PyExc_KeyboardInterrupt;
  else if (strcmp(n, "MemoryError") == 0) t = PyExc_MemoryError;
  else if (strcmp(n, "RecursionError") == 0) t = PyExc_RecursionError;
  else if (strcmp(n, "SystemError") == 0) t = PyExc_SystemError;
  if (caml_string_length(v_msg) == 0) {
    PyErr_SetNone(t);
  } else {
    PyObject *m = PyUnicode_DecodeUTF8(String_val(v_msg), caml_string_length(v_msg),
                                       "replace");
    if (m != NULL) {
      PyErr_SetObject(t, m);
      Py_DECREF(m);
    }
  }
  return Val_unit;
}

value sboa_set_error_class(value v_cls, value v_args) {
  PyErr_SetObject(sboa_obj(v_cls), sboa_obj(v_args));
  return Val_unit;
}

value sboa_set_error_system_exit(value v_code) {
  sboa_check_gil();
  PyObject *c = PyLong_FromLong(Long_val(v_code));
  if (c != NULL) {
    PyErr_SetObject(PyExc_SystemExit, c);
    Py_DECREF(c);
  }
  return Val_unit;
}

static void exn_capsule_destructor(PyObject *cap) {
  value *root = PyCapsule_GetPointer(cap, SBOA_EXN_CAPSULE);
  if (root != NULL) sboa_release_root(root);
  else PyErr_Clear();
}

/* Set exception e (a reference this steals) as raised, with an .ocaml_exn
   capsule rooting the OCaml (exn, raw_backtrace) pair, so crossing back
   resurrects it. */
static void raise_resurrectable(PyObject *e, value v_pair) {
  value *root = sboa_new_root(v_pair);
  PyObject *cap = PyCapsule_New(root, SBOA_EXN_CAPSULE, exn_capsule_destructor);
  if (cap == NULL) {
    sboa_release_root(root);
    Py_DECREF(e);
    return;
  }
  int rc = PyObject_SetAttrString(e, "ocaml_exn", cap);
  Py_DECREF(cap);
  if (rc != 0) {
    Py_DECREF(e);
    return;
  }
  PyErr_SetRaisedException(e);
}

/* Raise _sboa.OCamlError(msg), resurrectable. */
value sboa_set_error_ocaml(value v_msg, value v_pair) {
  CAMLparam2(v_msg, v_pair);
  sboa_check_gil();
  PyObject *m = PyUnicode_DecodeUTF8(String_val(v_msg), caml_string_length(v_msg),
                                     "replace");
  PyObject *e = m ? PyObject_CallOneArg(sboa_ocaml_error_type, m) : NULL;
  Py_XDECREF(m);
  if (e == NULL) CAMLreturn(Val_unit); /* some exception is set */
  raise_resurrectable(e, v_pair);
  CAMLreturn(Val_unit);
}

/* Raise the instance v_exc (of an OCamlError subclass), resurrectable. */
value sboa_set_error_ocaml_obj(value v_exc, value v_pair) {
  CAMLparam2(v_exc, v_pair);
  sboa_check_gil();
  raise_resurrectable(Py_NewRef(sboa_obj(v_exc)), v_pair);
  CAMLreturn(Val_unit);
}

/* Release every handle of [arr] except the block [keep] (the export's
   result, which may be one of its arguments), in one Python section. */
value sboa_release_args(value arr, value keep) {
  sboa_check_gil();
  mlsize_t n = Wosize_val(arr);
  PyObject *small[SMALL_ARGS];
  PyObject **objs = n <= SMALL_ARGS ? small : malloc(n * sizeof(PyObject *));
  mlsize_t k = 0;
  for (mlsize_t i = 0; i < n; i++) {
    value v = Field(arr, i);
    if (v == keep || Obj_ptr(v) == NULL) continue;
    if (objs != NULL) objs[k++] = Obj_ptr(v);
    else sboa_defer_decref(Obj_ptr(v));
    Obj_ptr(v) = NULL;
  }
  if (k > 0) {
    sboa_py_section s = sboa_py_enter();
    for (mlsize_t i = 0; i < k; i++) Py_DECREF(objs[i]);
    sboa_py_leave(s);
  }
  if (objs != small) free(objs);
  return Val_unit;
}
