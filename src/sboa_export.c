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
/* sboa exports: the `_sboa` builtin module, the builtin modules built
   from the OCaml Export registry, the single Python -> OCaml trampoline, and
   the heap-type factory for exported OCaml classes.

   Modules: every distinct module name in the registry gets an inittab entry
   (import.html#c.PyImport_AppendInittab). Init functions take no argument,
   so a fixed pool of MAX_MODULES functions maps slot k to module k.

   Functions: one PyMethodDef per export (METH_FASTCALL | METH_KEYWORDS,
   structures.html#c.PyMethodDef) bound with PyCMethod_New to a capsule
   holding the registry index, so a single C function serves every export.
   The docstring carries the `name($module, ...)\n--\n\n` text-signature
   prefix when the registry provides one, which makes inspect.signature work
   on the builtin.

   Trampoline: PyEval_SaveThread -> acquire the OCaml domain lock (if the
   Python call that led here had released it) -> OCaml dispatcher ->
   release -> PyEval_RestoreThread. The dispatcher (Sboa.dispatch,
   registered with Callback.register) re-takes the GIL with with_gil for
   argument and result conversion and translates OCaml exceptions into a
   Python error indicator; it is called with caml_callback_res so an OCaml
   exception never unwinds through CPython frames.

   Classes: PyType_FromSpec heap types (type.html#c.PyType_FromSpec) whose
   instances are { PyObject_HEAD; value *root; int cls; }: slot-less (no
   __dict__, no __weakref__), immutable (tp_setattro raises), not
   instantiable from Python, not subclassable. Methods are instancemethod
   wrappers (PyInstanceMethod_New) around trampoline-bound builtins, so
   `self` arrives as the first positional argument. tp_dealloc releases the
   generational root holding the OCaml value.

   Counter: _sboa.Counter, a final heap type whose instances hold one
   64-bit C11 atomic. Python reads it through the `value` getter (C only,
   so any Python thread may read it without entering OCaml); OCaml updates
   it from any domain through the [@@noalloc] stubs below, which take the
   address of the atomic and never touch Python or the OCaml runtime. Every
   export module re-exports the type as <module>.Counter.

   Record classes (Sboa.Conv.record): plain Python classes that OCaml
   creates; a module that holds some has a hidden __sboa_init__ export,
   which make_module calls with the new module and then deletes. */
#include "sboa_internal.h"

#include <string.h>
#include <sys/stat.h>

#define MAX_MODULES 32
#define FN_CAPSULE "sboa.fn"

PyObject *sboa_ocaml_error_type = NULL;
static PyObject *counter_type = NULL; /* _sboa.Counter */

/* ------------------------------------------------------------------------ */
/* Registry copied from OCaml at init                                         */

struct fn_entry {
  int module;   /* index into modules[], -1 for methods */
  char *name;
  char *doc;
  int fn;       /* OCaml registry index */
  PyMethodDef def;
};

struct class_entry {
  int module;
  char *name;
  char *qualified; /* module.Name */
  char *doc;
  int repr_fn;
  PyTypeObject *type;
};

struct method_entry {
  int cls;
  char *name;
  char *doc;
  int fn;
  PyMethodDef def;
};

static char *modules[MAX_MODULES];
static int n_modules = 0;
static struct fn_entry *functions = NULL;
static int n_functions = 0;
static struct class_entry *classes = NULL;
static int n_classes = 0;
static struct method_entry *methods = NULL;
static int n_methods = 0;

static char *dup_ml(value s) { return caml_stat_strdup(String_val(s)); }

static int module_index(const char *name) {
  for (int i = 0; i < n_modules; i++)
    if (strcmp(modules[i], name) == 0) return i;
  if (n_modules == MAX_MODULES) caml_failwith("sboa: too many exported modules");
  modules[n_modules] = caml_stat_strdup(name);
  return n_modules++;
}

static PyObject *trampoline(PyObject *self, PyObject *const *args,
                            Py_ssize_t nargs, PyObject *kwnames);

/* ------------------------------------------------------------------------ */
/* Module init pool                                                          */

static PyObject *make_module(int k);

#define POOL(k) \
  static PyObject *init_slot_##k(void) { return make_module(k); }
POOL(0) POOL(1) POOL(2) POOL(3) POOL(4) POOL(5) POOL(6) POOL(7)
POOL(8) POOL(9) POOL(10) POOL(11) POOL(12) POOL(13) POOL(14) POOL(15)
POOL(16) POOL(17) POOL(18) POOL(19) POOL(20) POOL(21) POOL(22) POOL(23)
POOL(24) POOL(25) POOL(26) POOL(27) POOL(28) POOL(29) POOL(30) POOL(31)
#undef POOL

static PyObject *(*const init_pool[MAX_MODULES])(void) = {
    init_slot_0,  init_slot_1,  init_slot_2,  init_slot_3,  init_slot_4,
    init_slot_5,  init_slot_6,  init_slot_7,  init_slot_8,  init_slot_9,
    init_slot_10, init_slot_11, init_slot_12, init_slot_13, init_slot_14,
    init_slot_15, init_slot_16, init_slot_17, init_slot_18, init_slot_19,
    init_slot_20, init_slot_21, init_slot_22, init_slot_23, init_slot_24,
    init_slot_25, init_slot_26, init_slot_27, init_slot_28, init_slot_29,
    init_slot_30, init_slot_31};

static PyObject *fn_capsule(int fn) {
  /* Capsule pointers must be non-NULL: store index + 1. */
  return PyCapsule_New((void *)(intptr_t)(fn + 1), FN_CAPSULE, NULL);
}

static PyObject *bind(PyMethodDef *def, int fn, PyObject *modname) {
  PyObject *cap = fn_capsule(fn);
  if (cap == NULL) return NULL;
  PyObject *f = PyCMethod_New(def, cap, modname, NULL);
  Py_DECREF(cap);
  return f;
}

/* ---- class instances ---- */

typedef struct {
  PyObject_HEAD
  value *root;
  int cls;
} instance;

static void instance_dealloc(PyObject *self) {
  instance *o = (instance *)self;
  PyTypeObject *tp = Py_TYPE(self);
  if (o->root != NULL) sboa_release_root(o->root);
  tp->tp_free(self);
  Py_DECREF(tp);
}

static int instance_setattro(PyObject *self, PyObject *name, PyObject *v) {
  PyErr_Format(PyExc_AttributeError, "'%s' object is immutable",
               Py_TYPE(self)->tp_name);
  return -1;
}

static PyObject *call_ocaml(int fn, PyObject *const *args, Py_ssize_t nargs,
                            PyObject *kwnames);
static int check_main_thread(void);

static PyObject *instance_repr(PyObject *self) {
  if (!check_main_thread()) return NULL;
  PyObject *args[1] = {self};
  return call_ocaml(classes[((instance *)self)->cls].repr_fn, args, 1, NULL);
}

static PyTypeObject *make_class(struct class_entry *c, PyObject *modname) {
  PyType_Slot slots[5];
  int n = 0;
  slots[n++] = (PyType_Slot){Py_tp_dealloc, instance_dealloc};
  slots[n++] = (PyType_Slot){Py_tp_setattro, instance_setattro};
  if (c->repr_fn >= 0) slots[n++] = (PyType_Slot){Py_tp_repr, instance_repr};
  if (c->doc[0] != '\0') slots[n++] = (PyType_Slot){Py_tp_doc, c->doc};
  slots[n] = (PyType_Slot){0, NULL};
  PyType_Spec spec = {
      .name = c->qualified,
      .basicsize = sizeof(instance),
      .itemsize = 0,
      .flags = Py_TPFLAGS_DEFAULT | Py_TPFLAGS_IMMUTABLETYPE |
               Py_TPFLAGS_DISALLOW_INSTANTIATION,
      .slots = slots,
  };
  PyTypeObject *t = (PyTypeObject *)PyType_FromSpec(&spec);
  if (t == NULL) return NULL;
  /* The type is immutable through setattr; populate its dict directly and
     invalidate the method cache (type.html#c.PyType_Modified). */
  PyObject *dict = PyType_GetDict(t);
  for (int i = 0; dict != NULL && i < n_methods; i++) {
    struct method_entry *m = &methods[i];
    if (&classes[m->cls] != c) continue;
    PyObject *f = bind(&m->def, m->fn, modname);
    PyObject *im = f ? PyInstanceMethod_New(f) : NULL;
    Py_XDECREF(f);
    if (im == NULL || PyDict_SetItemString(dict, m->name, im) != 0) {
      Py_XDECREF(im);
      Py_CLEAR(dict);
      Py_CLEAR(t);
      return NULL;
    }
    Py_DECREF(im);
  }
  Py_XDECREF(dict);
  PyType_Modified(t);
  return t;
}

static struct PyModuleDef *module_defs[MAX_MODULES];

static PyObject *make_module(int k) {
  if (module_defs[k] == NULL) {
    struct PyModuleDef tmpl = {PyModuleDef_HEAD_INIT, modules[k], NULL, -1,
                               NULL, NULL, NULL, NULL, NULL};
    module_defs[k] = malloc(sizeof tmpl);
    if (module_defs[k] == NULL) return PyErr_NoMemory();
    *module_defs[k] = tmpl;
  }
  PyObject *m = PyModule_Create(module_defs[k]);
  if (m == NULL) return NULL;
  PyObject *modname = PyUnicode_FromString(modules[k]);
  if (modname == NULL) goto fail;
  for (int i = 0; i < n_functions; i++) {
    if (functions[i].module != k) continue;
    PyObject *f = bind(&functions[i].def, functions[i].fn, modname);
    if (f == NULL || PyModule_Add(m, functions[i].name, f) != 0) goto fail;
  }
  for (int i = 0; i < n_classes; i++) {
    if (classes[i].module != k) continue;
    if (classes[i].type == NULL) classes[i].type = make_class(&classes[i], modname);
    if (classes[i].type == NULL ||
        PyModule_AddObjectRef(m, classes[i].name, (PyObject *)classes[i].type) != 0)
      goto fail;
  }
  if (!PyObject_HasAttrString(m, "OCamlError") &&
      PyModule_AddObjectRef(m, "OCamlError", sboa_ocaml_error_type) != 0)
    goto fail;
  if (counter_type != NULL && !PyObject_HasAttrString(m, "Counter") &&
      PyModule_AddObjectRef(m, "Counter", counter_type) != 0)
    goto fail;
  /* The record classes of the module: set by its hidden init function
     (Sboa's __sboa_init__, registered with them), called once and removed. */
  PyObject *hook = NULL;
  if (PyObject_GetOptionalAttrString(m, "__sboa_init__", &hook) < 0) goto fail;
  if (hook != NULL) {
    PyObject *r = PyObject_CallOneArg(hook, m);
    Py_DECREF(hook);
    if (r == NULL) goto fail;
    Py_DECREF(r);
    if (PyObject_DelAttrString(m, "__sboa_init__") != 0) goto fail;
  }
  Py_DECREF(modname);
  return m;
fail:
  Py_XDECREF(modname);
  Py_DECREF(m);
  return NULL;
}

void sboa_exports_setup(value v_functions, value v_classes, value v_methods) {
  n_functions = Wosize_val(v_functions);
  n_classes = Wosize_val(v_classes);
  n_methods = Wosize_val(v_methods);
  functions = calloc(n_functions + 1, sizeof *functions);
  classes = calloc(n_classes + 1, sizeof *classes);
  methods = calloc(n_methods + 1, sizeof *methods);
  if (!functions || !classes || !methods) caml_raise_out_of_memory();
  for (int i = 0; i < n_functions; i++) {
    value f = Field(v_functions, i);
    struct fn_entry *e = &functions[i];
    e->module = module_index(String_val(Field(f, 0)));
    e->name = dup_ml(Field(f, 1));
    e->doc = dup_ml(Field(f, 2));
    e->fn = Int_val(Field(f, 3));
    e->def = (PyMethodDef){e->name, (PyCFunction)(void (*)(void))trampoline,
                           METH_FASTCALL | METH_KEYWORDS,
                           e->doc[0] ? e->doc : NULL};
  }
  for (int i = 0; i < n_classes; i++) {
    value c = Field(v_classes, i);
    struct class_entry *e = &classes[i];
    e->module = module_index(String_val(Field(c, 0)));
    e->name = dup_ml(Field(c, 1));
    size_t len = strlen(modules[e->module]) + strlen(e->name) + 2;
    e->qualified = caml_stat_alloc(len);
    snprintf(e->qualified, len, "%s.%s", modules[e->module], e->name);
    e->doc = dup_ml(Field(c, 2));
    e->repr_fn = Int_val(Field(c, 3));
  }
  for (int i = 0; i < n_methods; i++) {
    value m = Field(v_methods, i);
    struct method_entry *e = &methods[i];
    e->cls = Int_val(Field(m, 0));
    e->name = dup_ml(Field(m, 1));
    e->doc = dup_ml(Field(m, 2));
    e->fn = Int_val(Field(m, 3));
    e->def = (PyMethodDef){e->name, (PyCFunction)(void (*)(void))trampoline,
                           METH_FASTCALL | METH_KEYWORDS,
                           e->doc[0] ? e->doc : NULL};
  }
  for (int k = 0; k < n_modules; k++)
    if (PyImport_AppendInittab(modules[k], init_pool[k]) != 0)
      caml_failwith("sboa: PyImport_AppendInittab failed");
}

/* ------------------------------------------------------------------------ */
/* Trampoline                                                                */

static int check_main_thread(void) {
  if (sboa_forked_child) {
    PyErr_SetString(PyExc_RuntimeError,
                    "sboa: Python cannot call OCaml in a forked child");
    return 0;
  }
  if (PyThread_get_thread_ident() != sboa_main_ident) {
    PyErr_SetString(PyExc_RuntimeError,
                    "sboa: OCaml functions may only be called from the "
                    "thread that initialized Python");
    return 0;
  }
  return 1;
}

/* The call being dispatched, read by the dispatcher through frame_args /
   frame_kwnames (main thread only; nested calls stack). */
struct frame {
  PyObject *const *args;
  Py_ssize_t nargs;
  PyObject *kwnames;
  struct frame *prev;
};
static struct frame *current_frame = NULL;

/* Run the dispatcher; needs the domain lock. Returns the result object
   (borrowed from the Object.t, see call_ocaml) or NULL; *err is set to a
   formatted OCaml exception if the dispatcher itself raised. */
static PyObject *run_dispatcher(int fn, char **err) {
  CAMLparam0();
  CAMLlocal1(r);
  static const value *dispatch = NULL;
  PyObject *ret = NULL;
  if (dispatch == NULL) dispatch = caml_named_value("sboa.dispatch");
  caml_result res = caml_callback_res(*dispatch, Val_int(fn));
  if (caml_result_is_exception(res)) {
    *err = caml_format_exception(res.data);
  } else {
    r = res.data;
    if (Is_some(r)) ret = *((PyObject **)Data_custom_val(Some_val(r)));
  }
  CAMLreturnT(PyObject *, ret);
}

static PyObject *call_ocaml(int fn, PyObject *const *args, Py_ssize_t nargs,
                            PyObject *kwnames) {
  /* Each crossing nests a C eval loop, a callback and an OCaml frame; bound
     the depth by CPython's C recursion counter so deep Python <-> OCaml
     recursion ends in RecursionError rather than a stack overflow
     (exceptions.html#c.Py_EnterRecursiveCall). */
  if (Py_EnterRecursiveCall(" while calling an OCaml function")) return NULL;
  /* Signals Python received before this call are Python's: raise them here
     (KeyboardInterrupt), with Python frames still on the stack. */
  if (PyErr_CheckSignals() < 0) {
    Py_LeaveRecursiveCall();
    return NULL;
  }
  /* (The deferred DECREF queue is drained by the dispatcher's with_gil.) */
  struct frame fr = {args, nargs, kwnames, current_frame};
  current_frame = &fr;
  sig_atomic_t prev_in_python = sboa_in_python;
  int was_released = sboa_runtime_released;
  char *err = NULL;

  PyThreadState *ts = PyEval_SaveThread();
  if (was_released) {
    caml_leave_blocking_section();
    sboa_runtime_released = 0;
  }
  /* Only now, holding the domain lock, does OCaml own the signals: one
     arriving while this thread waited for the lock went to Python and is
     handed back to OCaml on this thread by the dispatcher's with_gil
     (gil_ensure -> hand_late_signal_to_ocaml). */
  sboa_in_python = 0;
  sboa_drain_roots();
  /* The result object stays alive until the INCREF below: its Object.t can
     at worst be finalized, which only queues a DECREF, and the queue is
     drained by this thread at a later bridge entry. */
  PyObject *ret = run_dispatcher(fn, &err);
  sboa_in_python = prev_in_python;
  if (was_released) {
    sboa_runtime_released = 1;
    caml_enter_blocking_section_no_pending();
  }
  PyEval_RestoreThread(ts);
  current_frame = fr.prev;
  Py_LeaveRecursiveCall();

  if (ret != NULL) return Py_NewRef(ret);
  if (err != NULL) {
    if (!PyErr_Occurred())
      PyErr_Format(PyExc_SystemError, "sboa: OCaml dispatcher raised %s", err);
    caml_stat_free(err);
  } else if (!PyErr_Occurred()) {
    PyErr_SetString(PyExc_SystemError,
                    "sboa: OCaml export failed without an exception");
  }
  return NULL;
}

static PyObject *trampoline(PyObject *self, PyObject *const *args,
                            Py_ssize_t nargs, PyObject *kwnames) {
  if (!check_main_thread()) return NULL;
  void *p = PyCapsule_GetPointer(self, FN_CAPSULE);
  if (p == NULL) return NULL;
  return call_ocaml((int)((intptr_t)p - 1), args, nargs, kwnames);
}

value sboa_frame_args(value unit) {
  CAMLparam0();
  CAMLlocal2(arr, x);
  sboa_check_gil();
  struct frame *f = current_frame;
  if (f == NULL) caml_failwith("sboa: no export call in progress");
  Py_ssize_t nk = f->kwnames ? PyTuple_GET_SIZE(f->kwnames) : 0;
  Py_ssize_t n = f->nargs + nk;
  arr = caml_alloc(n, 0);
  for (Py_ssize_t i = 0; i < n; i++) {
    x = sboa_wrap(Py_NewRef(f->args[i]));
    Store_field(arr, i, x);
  }
  CAMLreturn(arr);
}

value sboa_frame_kwnames(value unit) {
  CAMLparam0();
  CAMLlocal2(arr, s);
  sboa_check_gil();
  struct frame *f = current_frame;
  if (f == NULL) caml_failwith("sboa: no export call in progress");
  Py_ssize_t nk = f->kwnames ? PyTuple_GET_SIZE(f->kwnames) : 0;
  arr = caml_alloc(nk, 0);
  for (Py_ssize_t i = 0; i < nk; i++) {
    Py_ssize_t len;
    const char *p = PyUnicode_AsUTF8AndSize(PyTuple_GET_ITEM(f->kwnames, i), &len);
    if (p == NULL) sboa_raise_pending();
    s = caml_alloc_initialized_string(len, p);
    Store_field(arr, i, s);
  }
  CAMLreturn(arr);
}

/* ------------------------------------------------------------------------ */
/* Class instances from OCaml                                                */

static PyTypeObject *class_type(value v_cls) {
  int c = Int_val(v_cls);
  if (c < 0 || c >= n_classes || classes[c].type == NULL)
    caml_invalid_argument("Sboa.Class: class not created yet (import its module first)");
  return classes[c].type;
}

value sboa_class_wrap(value v_cls, value v) {
  CAMLparam2(v_cls, v);
  sboa_check_gil();
  PyTypeObject *t = class_type(v_cls);
  instance *o = PyObject_New(instance, t); /* INCREFs the heap type */
  if (o == NULL) sboa_raise_pending();
  o->root = NULL;
  o->cls = Int_val(v_cls);
  o->root = sboa_new_root(v);
  CAMLreturn(sboa_wrap((PyObject *)o));
}

value sboa_class_unwrap(value v_cls, value v_o) {
  CAMLparam2(v_cls, v_o);
  int c = Int_val(v_cls);
  PyObject *o = sboa_obj(v_o);
  if (c < 0 || c >= n_classes || classes[c].type == NULL ||
      Py_TYPE(o) != classes[c].type || ((instance *)o)->root == NULL)
    CAMLreturn(Val_none);
  CAMLreturn(caml_alloc_some(*((instance *)o)->root));
}

/* ------------------------------------------------------------------------ */
/* _sboa.Counter                                                          */

typedef struct {
  PyObject_HEAD
  _Atomic long long count;
} counter;

static PyObject *counter_new(PyTypeObject *type, PyObject *args,
                             PyObject *kwds) {
  if (PyTuple_GET_SIZE(args) != 0 || (kwds != NULL && PyDict_GET_SIZE(kwds) != 0)) {
    PyErr_SetString(PyExc_TypeError, "Counter() takes no arguments");
    return NULL;
  }
  counter *c = (counter *)type->tp_alloc(type, 0);
  if (c == NULL) return NULL;
  atomic_init(&c->count, 0);
  return (PyObject *)c;
}

static PyObject *counter_value(PyObject *self, void *closure) {
  return PyLong_FromLongLong(
      atomic_load_explicit(&((counter *)self)->count, memory_order_relaxed));
}

static PyObject *counter_repr(PyObject *self) {
  return PyUnicode_FromFormat(
      "Counter(value=%lld)",
      atomic_load_explicit(&((counter *)self)->count, memory_order_relaxed));
}

static PyGetSetDef counter_getset[] = {
    {"value", counter_value, NULL,
     "The current count (read atomically; never enters OCaml).", NULL},
    {NULL, NULL, NULL, NULL, NULL}};

static PyObject *make_counter_type(void) {
  PyType_Slot slots[] = {
      {Py_tp_new, counter_new},
      {Py_tp_getset, counter_getset},
      {Py_tp_repr, counter_repr},
      {Py_tp_doc,
       "Counter()\n--\n\nA 64-bit atomic counter, starting at 0, that OCaml "
       "code updates from any domain while Python threads read `value`."},
      {0, NULL}};
  PyType_Spec spec = {
      .name = "_sboa.Counter",
      .basicsize = sizeof(counter),
      .itemsize = 0,
      .flags = Py_TPFLAGS_DEFAULT | Py_TPFLAGS_IMMUTABLETYPE,
      .slots = slots,
  };
  return PyType_FromSpec(&spec);
}

/* Address of the atomic of a Counter instance (as a nativeint), or 0 if [v]
   is not exactly a Counter. GIL held. */
value sboa_counter_ptr(value v) {
  PyObject *o = sboa_obj(v);
  if (counter_type == NULL || Py_TYPE(o) != (PyTypeObject *)counter_type)
    return caml_copy_nativeint(0);
  return caml_copy_nativeint((intnat) & ((counter *)o)->count);
}

/* A new owned handle on the same object (keeps a Counter alive while OCaml
   holds the address of its atomic). GIL held. */
value sboa_new_ref(value v) { return sboa_wrap(Py_NewRef(sboa_obj(v))); }

/* The [@@noalloc] counter primitives: any thread, any domain, no lock. */
value sboa_counter_add_native(intnat p, intnat n) {
  atomic_fetch_add_explicit((_Atomic long long *)p, (long long)n,
                            memory_order_relaxed);
  return Val_unit;
}
value sboa_counter_add(value p, value n) {
  return sboa_counter_add_native(Nativeint_val(p), Long_val(n));
}
value sboa_counter_set_native(intnat p, intnat n) {
  atomic_store_explicit((_Atomic long long *)p, (long long)n,
                        memory_order_relaxed);
  return Val_unit;
}
value sboa_counter_set(value p, value n) {
  return sboa_counter_set_native(Nativeint_val(p), Long_val(n));
}
intnat sboa_counter_get_native(intnat p) {
  return (intnat)atomic_load_explicit((_Atomic long long *)p,
                                      memory_order_relaxed);
}
value sboa_counter_get(value p) {
  return Val_long(sboa_counter_get_native(Nativeint_val(p)));
}

/* ------------------------------------------------------------------------ */
/* The _sboa builtin module                                               */

static PyObject *init_sboa_module(void);

struct bundle {
  char *name;
  const char *data;
  Py_ssize_t size;
};
static struct bundle *bundles = NULL;
static int n_bundles = 0;
static char **dev_overrides = NULL;
static int n_dev_overrides = 0;

void sboa_module_setup(value v_bundles, value v_dev) {
  n_bundles = Wosize_val(v_bundles);
  bundles = calloc(n_bundles + 1, sizeof *bundles);
  if (bundles == NULL) caml_raise_out_of_memory();
  for (int i = 0; i < n_bundles; i++) {
    value b = Field(v_bundles, i);
    value ba = Field(b, 1);
    bundles[i].name = dup_ml(Field(b, 0));
    /* Bundle bigarrays wrap static, read-only data: the pointer is stable. */
    bundles[i].data = Caml_ba_data_val(ba);
    bundles[i].size = Caml_ba_array_val(ba)->dim[0];
  }
  n_dev_overrides = Wosize_val(v_dev);
  dev_overrides = calloc(n_dev_overrides + 1, sizeof(char *));
  if (dev_overrides == NULL) caml_raise_out_of_memory();
  for (int i = 0; i < n_dev_overrides; i++)
    dev_overrides[i] = dup_ml(Field(v_dev, i));
  if (PyImport_AppendInittab("_sboa", init_sboa_module) != 0)
    caml_failwith("sboa: PyImport_AppendInittab(_sboa) failed");
}

/* _sboa.bundles() -> list[tuple[str, memoryview]] in search order. */
static PyObject *py_bundles(PyObject *self, PyObject *unused) {
  PyObject *l = PyList_New(n_bundles);
  for (int i = 0; l != NULL && i < n_bundles; i++) {
    PyObject *mv = PyMemoryView_FromMemory((char *)bundles[i].data,
                                           bundles[i].size, PyBUF_READ);
    PyObject *t = mv ? Py_BuildValue("(sN)", bundles[i].name, mv) : NULL;
    if (t == NULL) {
      Py_CLEAR(l);
      break;
    }
    PyList_SET_ITEM(l, i, t);
  }
  return l;
}

/* _sboa.libdynload_dir(): the layout the runtime files are installed in
   next to the executable:
   <dirname(sys.executable)>/libs/pythonX.Y/lib-dynload on unix, and the
   executable's own directory on Windows (python3XY.dll and the *.pyd
   extension modules sit flat next to the .exe, as DLL search requires);
   None if that is not an existing directory. */
static PyObject *py_libdynload_dir(PyObject *self, PyObject *unused) {
  PyObject *dir;
  {
    PyObject *exe = PySys_GetObject("executable"); /* borrowed */
    if (exe == NULL || !PyUnicode_Check(exe) || PyUnicode_GET_LENGTH(exe) == 0)
      Py_RETURN_NONE;
    Py_ssize_t n = PyUnicode_GET_LENGTH(exe);
    Py_ssize_t sep = PyUnicode_FindChar(exe, '/', 0, n, -1);
#ifdef _WIN32
    Py_ssize_t bsep = PyUnicode_FindChar(exe, '\\', 0, n, -1);
    if (bsep > sep) sep = bsep;
#endif
    if (sep == -2) return NULL;
    PyObject *base = sep < 0 ? PyUnicode_FromString(".") : PyUnicode_Substring(exe, 0, sep);
    if (base == NULL) return NULL;
#ifdef _WIN32
    dir = base;
#else
    dir = PyUnicode_FromFormat("%U/libs/python%d.%d/lib-dynload", base,
                               PY_MAJOR_VERSION, PY_MINOR_VERSION);
    Py_DECREF(base);
#endif
  }
  if (dir == NULL) return NULL;
  PyObject *bytes = NULL;
  struct stat st;
  int is_dir = PyUnicode_FSConverter(dir, &bytes) &&
               stat(PyBytes_AS_STRING(bytes), &st) == 0 && S_ISDIR(st.st_mode);
  Py_XDECREF(bytes);
  PyErr_Clear();
  if (is_dir) return dir;
  Py_DECREF(dir);
  Py_RETURN_NONE;
}

static PyObject *py_dev_overrides(PyObject *self, PyObject *unused) {
  PyObject *l = PyList_New(n_dev_overrides);
  for (int i = 0; l != NULL && i < n_dev_overrides; i++) {
    PyObject *s = PyUnicode_DecodeFSDefault(dev_overrides[i]);
    if (s == NULL) {
      Py_CLEAR(l);
      break;
    }
    PyList_SET_ITEM(l, i, s);
  }
  return l;
}

static PyMethodDef sboa_module_methods[] = {
    {"bundles", py_bundles, METH_NOARGS,
     "bundles($module, /)\n--\n\nEmbedded bundles as (name, memoryview) pairs, "
     "in search order."},
    {"libdynload_dir", py_libdynload_dir, METH_NOARGS,
     "libdynload_dir($module, /)\n--\n\nDirectory of the C extension modules, "
     "or None."},
    {"dev_overrides", py_dev_overrides, METH_NOARGS,
     "dev_overrides($module, /)\n--\n\nDirectories whose Python sources take "
     "precedence over the bundles (development)."},
    {NULL, NULL, 0, NULL}};

static struct PyModuleDef sboa_module_def = {
    PyModuleDef_HEAD_INIT, "_sboa",
    "Host services of the sboa bridge.", -1, sboa_module_methods,
    NULL, NULL, NULL, NULL};

static PyObject *init_sboa_module(void) {
  PyObject *m = PyModule_Create(&sboa_module_def);
  if (m == NULL) return NULL;
  if (sboa_ocaml_error_type == NULL) {
    sboa_ocaml_error_type = PyErr_NewExceptionWithDoc(
        "_sboa.OCamlError",
        "An OCaml exception that crossed into Python. If it propagates back "
        "into OCaml, the original OCaml exception is re-raised.",
        PyExc_Exception, NULL);
    if (sboa_ocaml_error_type == NULL) {
      Py_DECREF(m);
      return NULL;
    }
  }
  if (PyModule_AddObjectRef(m, "OCamlError", sboa_ocaml_error_type) != 0) {
    Py_DECREF(m);
    return NULL;
  }
  if (counter_type == NULL) counter_type = make_counter_type();
  if (counter_type == NULL ||
      PyModule_AddObjectRef(m, "Counter", counter_type) != 0) {
    Py_DECREF(m);
    return NULL;
  }
  return m;
}
