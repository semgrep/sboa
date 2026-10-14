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
/* pyembed: state and helpers shared by the C stubs of pyembed.cpython.

   Thread model (v1, see BRIDGE_DESIGN.md section 3): Python runs only on the
   systhread that called pyembed_init (the "main" thread, domain 0). That
   thread alternates between three states:
     - OCaml:   holds the OCaml domain lock, not the GIL (outside with_gil);
     - bridge:  holds both (OCaml code inside with_gil, stubs converting data);
     - Python:  holds the GIL and has released the domain lock
                (pyembed_runtime_released = 1) so other OCaml systhreads run.
   The globals below describe the main thread only; every other thread is
   refused before it can touch them (pyembed_thread_ok / the trampoline
   check). Lock order: no thread other than the main thread ever holds both
   locks, so blocking on one while holding the other cannot deadlock in v1.

   C-API references: https://docs.python.org/3.13/c-api/ (init_config.html,
   init.html "Thread State and the Global Interpreter Lock", exceptions.html,
   import.html, type.html, refcounting.html); OCaml manual chapter 22
   "Interfacing C with OCaml" (sections 22.5 callbacks, 22.9 custom blocks,
   22.12 parallel execution / threads). */
#ifndef PYEMBED_INTERNAL_H
#define PYEMBED_INTERNAL_H

#define PY_SSIZE_T_CLEAN
#include <Python.h>

#define CAML_NAME_SPACE
#include <caml/alloc.h>
#include <caml/bigarray.h>
#include <caml/callback.h>
#include <caml/custom.h>
#include <caml/fail.h>
#include <caml/memory.h>
#include <caml/mlvalues.h>
#include <caml/printexc.h>
#include <caml/signals.h>
#include <caml/threads.h>

#include <signal.h>
#include <stdatomic.h>

/* ---- main-thread state (pyembed_runtime.c) ---- */

extern int pyembed_initialized;
extern unsigned long pyembed_main_ident;
/* The main thread released the OCaml domain lock around Python code. */
extern int pyembed_runtime_released;
/* with_gil ~keep_domain_lock:true is in effect. */
extern int pyembed_keep_lock;
/* Python owns the main thread: SIGINT/SIGTERM go to PyErr_SetInterruptEx. */
extern volatile sig_atomic_t pyembed_in_python;

/* Process is a fork child of the initializing process (pthread_atfork). */
extern volatile int pyembed_forked_child;

/* Raise Invalid_argument unless the calling thread holds the GIL, i.e. the
   gil token it presents is live (it may not escape its with_gil scope, be
   used inside detach, or be used from another thread). */
void pyembed_check_gil(void);

/* A section of Python execution from an OCaml stub: release the domain lock
   (unless keep mode), mark Python as the signal owner. Must be entered with
   the GIL and the domain lock held; no OCaml value may be touched until
   pyembed_py_leave. */
typedef struct {
  int released;
  sig_atomic_t prev_in_python;
} pyembed_py_section;

pyembed_py_section pyembed_py_enter(void);
void pyembed_py_leave(pyembed_py_section s);

/* ---- deferred queues (pyembed_runtime.c) ---- */

/* Queue a DECREF; safe from any thread, any lock state (finalizers). */
void pyembed_defer_decref(PyObject *o);
/* DECREF everything queued. GIL held; runtime lock state unchanged. */
void pyembed_drain_decrefs(void);
/* A generational global root owned by Python (class instance, capsule). */
value *pyembed_new_root(value v);
/* Remove now if the main thread holds the domain lock, else queue. */
void pyembed_release_root(value *root);
/* Remove queued roots. Domain lock held. */
void pyembed_drain_roots(void);

/* ---- objects (pyembed_object.c) ---- */

/* Allocate an Object.t custom block owning [o] (steals the reference). */
value pyembed_wrap(PyObject *o);
/* The PyObject* of an Object.t; raises Invalid_argument after release. */
PyObject *pyembed_obj(value v);
/* The PyObject* of an Object.t without the GIL check (finalizers, C-only
   paths that already checked). */
#define PYEMBED_OBJ_PTR(v) (*((PyObject **)Data_custom_val(v)))
/* Move the raised Python exception to the pending slot, raise Pending.
   Domain lock held; the GIL state is owned by an enclosing with_gil. */
CAMLnoreturn_start void pyembed_raise_pending(void) CAMLnoreturn_end;

/* ---- exports (pyembed_export.c) ---- */

extern PyObject *pyembed_ocaml_error_type; /* _pyembed.OCamlError */
#define PYEMBED_EXN_CAPSULE "pyembed.ocaml_exn"

/* Copy the export registry and register inittab entries. Before init. */
void pyembed_exports_setup(value functions, value classes, value methods);
/* Copy bundles / importer settings for the _pyembed module. Before init. */
void pyembed_module_setup(value bundles, value libdynload_dir,
                          value dev_overrides);

#endif
