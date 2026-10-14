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
/* pyembed runtime: interpreter initialization, GIL scopes, deferred
   reference/root queues, signal routing and process exit.

   Initialization follows "Python Initialization Configuration"
   (https://docs.python.org/3.13/c-api/init_config.html): an isolated
   PyConfig with an explicit (normally empty) module search path, no site,
   no bytecode writing, no Python signal handlers, frozen modules enabled.
   After Py_InitializeFromConfig the main thread releases the GIL
   (PyEval_SaveThread) and re-takes it per with_gil scope through the
   PyGILState API (init.html#non-python-created-threads), which nests.

   Deferred DECREF: OCaml custom-block finalizers run without the GIL on any
   thread and must not call back into a runtime (OCaml manual 22.9.1), while
   Py_DECREF can run arbitrary Python code. Finalizers therefore push the
   pointer onto a lock-free stack (Treiber push; the consumer detaches the
   whole list with one atomic exchange, so there is no ABA problem) that is
   drained under the GIL at every bridge entry. Python-held OCaml roots use
   the mirror image: removing a generational global root needs the domain
   lock, so a Python-side dealloc that cannot prove it holds it queues the
   root instead.

   Signals: see setup_signals (POSIX sigaction; CRT signal() on Windows). */
#include "pyembed_internal.h"

#include <errno.h>
#include <string.h>
#ifndef _WIN32
#include <pthread.h>
#include <unistd.h>
#endif

extern const struct _frozen pyembed_frozen_table[];
extern const unsigned char pyembed_frozen_magic[4];

int pyembed_initialized = 0;
unsigned long pyembed_main_ident = 0;
int pyembed_runtime_released = 0;
int pyembed_keep_lock = 0;
volatile sig_atomic_t pyembed_in_python = 0;
volatile int pyembed_forked_child = 0;

/* Set by the signal handler when it hands a signal to Python
   (PyErr_SetInterruptEx); see hand_late_signal_to_ocaml. */
static volatile sig_atomic_t routed_to_python = 0;
static volatile sig_atomic_t routed_signal = 0;
/* Set when the handler chained a signal to OCaml's handler: the OCaml
   handler has not necessarily run yet (it runs at a poll point of whichever
   systhread holds the domain lock), so the main thread must not release the
   lock until it has polled. Cleared by pyembed_py_leave, after which the
   main thread runs OCaml code holding the lock. (OCaml's own pending-signal
   state is not public API.) */
static volatile sig_atomic_t ocaml_signal_hint = 0;

/* Init failure, kept so later init/with_gil calls re-raise it instead of
   retrying Py_InitializeFromConfig (which must run at most once). */
static char *init_error = NULL;

void pyembed_check_gil(void) {
  /* A thread holds the GIL iff it has a current thread state
     (init.html#c.PyThreadState_GetUnchecked). A TLS read. */
  if (PyThreadState_GetUnchecked() == NULL)
    caml_invalid_argument(
        "Pyembed: a gil token was used without holding the GIL (outside its "
        "with_gil scope, inside detach, or on another thread)");
}

static void hand_late_signal_to_ocaml(void);

/* ------------------------------------------------------------------------ */
/* Python sections                                                           */

/* Release the domain lock (main thread, held) so other systhreads run while
   this one waits for or runs Python. _no_pending: OCaml signal handlers
   (which may raise) are not run here. If a signal was just handed to OCaml
   (ocaml_signal_hint), keep the lock instead: released, its handler would
   run on whichever systhread takes the lock next, and Sys.Break belongs to
   this thread; it runs at this thread's next poll point. */
static int release_runtime(void) {
  if (pyembed_runtime_released || ocaml_signal_hint) return 0;
  caml_enter_blocking_section_no_pending();
  pyembed_runtime_released = 1;
  return 1;
}

static void reacquire_runtime(int released) {
  if (released) {
    caml_leave_blocking_section();
    pyembed_runtime_released = 0;
  }
}

pyembed_py_section pyembed_py_enter(void) {
  pyembed_py_section s;
  s.prev_in_python = pyembed_in_python;
  /* Python owns the signals from before the lock is released. */
  pyembed_in_python = 1;
  s.released = !pyembed_keep_lock && release_runtime();
  return s;
}

static _Atomic(void *) root_queue; /* forward: see roots below */

/* Re-take the domain lock first, then give the signals back to OCaml: a
   signal that arrives while this thread waits for the lock still goes to
   Python, never to an OCaml handler that another systhread (holding the
   lock meanwhile) would run. Such a late signal is handed to OCaml on this
   thread right after (hand_late_signal_to_ocaml). */
void pyembed_py_leave(pyembed_py_section s) {
  reacquire_runtime(s.released);
  ocaml_signal_hint = 0;
  pyembed_in_python = s.prev_in_python;
  if (!s.prev_in_python && routed_to_python) hand_late_signal_to_ocaml();
  if (!pyembed_runtime_released && atomic_load(&root_queue) != NULL)
    pyembed_drain_roots();
}

/* ------------------------------------------------------------------------ */
/* Deferred DECREF queue                                                     */

struct decref_node {
  PyObject *obj;
  struct decref_node *next;
};

static _Atomic(struct decref_node *) decref_queue;
static atomic_long decref_count;

void pyembed_defer_decref(PyObject *o) {
  struct decref_node *n = malloc(sizeof *n);
  if (n == NULL) return; /* out of memory: leak the reference rather than crash */
  n->obj = o;
  struct decref_node *head = atomic_load(&decref_queue);
  do {
    n->next = head;
  } while (!atomic_compare_exchange_weak(&decref_queue, &head, n));
  atomic_fetch_add(&decref_count, 1);
}

void pyembed_drain_decrefs(void) {
  /* A DECREF may run __del__, which may queue more; loop until empty. */
  struct decref_node *n;
  while ((n = atomic_exchange(&decref_queue, NULL)) != NULL) {
    while (n != NULL) {
      struct decref_node *next = n->next;
      atomic_fetch_sub(&decref_count, 1);
      Py_DECREF(n->obj);
      free(n);
      n = next;
    }
  }
}

/* Drains run __del__ methods (Python code) while OCaml owns the signals
   (pyembed_in_python == 0) and with the domain lock held: a KeyboardInterrupt
   raised inside __del__ would be swallowed as "unraisable", so signals must
   not be routed to Python there. */

/* ------------------------------------------------------------------------ */
/* Python-held OCaml roots                                                   */

struct root_node {
  value *root;
  struct root_node *next;
};

static atomic_long live_roots;

value *pyembed_new_root(value v) {
  value *r = malloc(sizeof *r);
  if (r == NULL) caml_raise_out_of_memory();
  *r = v;
  caml_register_generational_global_root(r);
  atomic_fetch_add(&live_roots, 1);
  return r;
}

static void remove_root(value *r) {
  caml_remove_generational_global_root(r);
  free(r);
  atomic_fetch_sub(&live_roots, 1);
}

void pyembed_release_root(value *r) {
  /* The main-thread flags are only meaningful on the main thread. */
  if (pyembed_initialized && PyThread_get_thread_ident() == pyembed_main_ident &&
      !pyembed_runtime_released) {
    remove_root(r);
    return;
  }
  struct root_node *n = malloc(sizeof *n);
  if (n == NULL) return; /* leak the root */
  n->root = r;
  void *head = atomic_load(&root_queue);
  do {
    n->next = head;
  } while (!atomic_compare_exchange_weak(&root_queue, &head, n));
}

void pyembed_drain_roots(void) {
  struct root_node *n = atomic_exchange(&root_queue, NULL);
  while (n != NULL) {
    struct root_node *next = n->next;
    remove_root(n->root);
    free(n);
    n = next;
  }
}

value pyembed_pending_decrefs(value unit) {
  return Val_long(atomic_load(&decref_count));
}

value pyembed_live_roots(value unit) {
  return Val_long(atomic_load(&live_roots));
}

/* ------------------------------------------------------------------------ */
/* Thread checks and GIL scopes                                              */

#ifndef _WIN32 /* no fork on Windows */
static void on_fork_child(void) { pyembed_forked_child = 1; }
#endif

value pyembed_is_initialized(value unit) {
  return Val_bool(pyembed_initialized);
}

value pyembed_thread_ok(value unit) {
  if (!pyembed_initialized) return Val_true;
  return Val_bool(!pyembed_forked_child &&
                  PyThread_get_thread_ident() == pyembed_main_ident);
}

value pyembed_init_failed(value unit) { return Val_bool(init_error != NULL); }

value pyembed_init_error(value unit) {
  return caml_copy_string(init_error != NULL ? init_error : "");
}

/* PyGILState_Ensure, releasing the domain lock while it may block, then
   drain the queues. Returns (PyGILState_STATE | previous keep flag << 1). */
value pyembed_gil_ensure(value v_keep) {
  PyGILState_STATE st;
  if (PyThreadState_GetUnchecked() != NULL) {
    /* This thread already holds the GIL: Ensure only bumps a counter. */
    st = PyGILState_Ensure();
  } else {
    /* While waiting for the GIL, signals go to Python (and are handed back
       below), never to an OCaml handler another systhread would run. */
    sig_atomic_t prev_in_python = pyembed_in_python;
    pyembed_in_python = 1;
    int released = release_runtime();
    st = PyGILState_Ensure();
    reacquire_runtime(released);
    pyembed_in_python = prev_in_python;
  }
  /* Main thread, both locks held, OCaml about to run. */
  if (!pyembed_in_python && routed_to_python) hand_late_signal_to_ocaml();
  pyembed_drain_decrefs();
  pyembed_drain_roots();
  int prev_keep = pyembed_keep_lock;
  pyembed_keep_lock = Bool_val(v_keep);
  return Val_int((st == PyGILState_LOCKED ? 1 : 0) | (prev_keep << 1));
}

value pyembed_gil_release(value v_st) {
  int st = Int_val(v_st);
  pyembed_keep_lock = (st >> 1) & 1;
  PyGILState_Release((st & 1) ? PyGILState_LOCKED : PyGILState_UNLOCKED);
  return Val_unit;
}

/* detach: PyEval_SaveThread; the saved state is found again through
   PyGILState_GetThisThreadState (init.html#c.PyGILState_GetThisThreadState). */
value pyembed_save_thread(value unit) {
  pyembed_check_gil();
  (void)PyEval_SaveThread();
  return Val_unit;
}

value pyembed_restore_thread(value unit) {
  PyThreadState *ts = PyGILState_GetThisThreadState();
  sig_atomic_t prev_in_python = pyembed_in_python;
  pyembed_in_python = 1;
  int released = release_runtime();
  PyEval_RestoreThread(ts);
  reacquire_runtime(released);
  pyembed_in_python = prev_in_python;
  if (!pyembed_in_python && routed_to_python) hand_late_signal_to_ocaml();
  pyembed_drain_decrefs();
  pyembed_drain_roots();
  return Val_unit;
}

value pyembed_drain(value unit) {
  pyembed_check_gil();
  pyembed_drain_decrefs();
  pyembed_drain_roots();
  return Val_unit;
}

value pyembed_gc_collect(value unit) {
  pyembed_check_gil();
  pyembed_py_section s = pyembed_py_enter();
  Py_ssize_t n = PyGC_Collect();
  pyembed_py_leave(s);
  return Val_long(n);
}

/* ------------------------------------------------------------------------ */
/* Signals                                                                   */

/* SIGINT and SIGTERM have one owner at a time. If OCaml had installed a
   handler for the signal before init (e.g. Sys.catch_break true), pyembed
   installs its own C handler which, while Python owns the main thread
   (pyembed_in_python), calls PyErr_SetInterruptEx (async-signal-safe,
   exceptions.html#c.PyErr_SetInterruptEx) so Python raises KeyboardInterrupt
   at its next bytecode boundary or EINTR; otherwise it chains to the saved
   OCaml handler, which only records the signal for the next OCaml poll
   point. Signals OCaml left at SIG_DFL/SIG_IGN are not touched, so their
   behaviour is the same in both runtimes. The handler reads a plain
   sig_atomic_t flag and calls only async-signal-safe functions. */

#define N_ROUTED 2
static const int routed_signals[N_ROUTED] = {SIGINT, SIGTERM};
static int routed[N_ROUTED];

/* The owner decision, shared by both platforms: hand the signal to Python if
   Python owns the main thread (PyErr_SetInterruptEx is async-signal-safe and
   exists on Windows too), else tell the caller to chain to OCaml. */
static int route_to_python(int sig) {
  if (pyembed_in_python) {
    routed_signal = sig;
    routed_to_python = 1;
    (void)PyErr_SetInterruptEx(sig);
    return 1;
  }
  ocaml_signal_hint = 1;
  return 0;
}

#ifdef _WIN32
/* Windows: the CRT signal() API (no sigaction, no siginfo_t, no SA_*). The
   CRT resets a disposition to SIG_DFL before calling the handler, so the
   handler re-installs itself, and again after chaining to OCaml's handler
   (which re-installs *itself* the same way). SIGINT handlers run on a
   thread the console creates; SIGTERM is never raised by the OS but is
   routed anyway (raise()). */
typedef void (*pyembed_sighandler)(int);
static pyembed_sighandler saved_handlers[N_ROUTED];

static void route_signal(int sig) {
  int saved_errno = errno;
  int i = (sig == SIGINT) ? 0 : 1;
  signal(sig, route_signal);
  if (!route_to_python(sig)) {
    pyembed_sighandler h = saved_handlers[i];
    if (h != SIG_DFL && h != SIG_IGN && h != SIG_ERR) {
      h(sig);
      signal(sig, route_signal);
    }
  }
  errno = saved_errno;
}

static void install_route(int i) {
  if (signal(routed_signals[i], route_signal) != SIG_ERR) routed[i] = 1;
}

/* Record OCaml's handler for signal [i]; false if OCaml does not handle it
   (then the disposition is left as it was). signal() can only read the
   current handler by replacing it, so it is put back. */
static int save_ocaml_handler(int i) {
  pyembed_sighandler cur = signal(routed_signals[i], SIG_DFL);
  if (cur == SIG_ERR) return 0;
  signal(routed_signals[i], cur);
  if (cur == SIG_DFL || cur == SIG_IGN || cur == route_signal) return 0;
  saved_handlers[i] = cur;
  return 1;
}
#else
static struct sigaction saved_actions[N_ROUTED];

static void route_signal(int sig, siginfo_t *info, void *ctx) {
  int saved_errno = errno;
  int i = (sig == SIGINT) ? 0 : 1;
  if (!route_to_python(sig)) {
    if (saved_actions[i].sa_flags & SA_SIGINFO)
      saved_actions[i].sa_sigaction(sig, info, ctx);
    else if (saved_actions[i].sa_handler != SIG_DFL &&
             saved_actions[i].sa_handler != SIG_IGN)
      saved_actions[i].sa_handler(sig);
  }
  errno = saved_errno;
}

static void install_route(int i) {
  struct sigaction sa;
  memset(&sa, 0, sizeof sa);
  sa.sa_sigaction = route_signal;
  sa.sa_flags = SA_SIGINFO | SA_ONSTACK; /* no SA_RESTART: sleeps see EINTR */
  sigemptyset(&sa.sa_mask);
  if (sigaction(routed_signals[i], &sa, NULL) == 0) routed[i] = 1;
}

/* Record OCaml's action for signal [i]; false if OCaml does not handle it. */
static int save_ocaml_handler(int i) {
  struct sigaction cur;
  if (sigaction(routed_signals[i], NULL, &cur) != 0) return 0;
  int ocaml_handles = (cur.sa_flags & SA_SIGINFO) ||
                      (cur.sa_handler != SIG_DFL && cur.sa_handler != SIG_IGN);
  if (!ocaml_handles) return 0;
  saved_actions[i] = cur;
  return 1;
}
#endif

/* A signal was handed to Python (routed_to_python) but the main thread has
   left Python since, so Python may never look at it. Main thread, GIL and
   domain lock held, pyembed_in_python == 0. If the Python handler is still
   pending, run it now (PyErr_CheckSignals, exceptions.html) without
   disturbing the current error indicator, and if it raised (the default
   handler raises KeyboardInterrupt) re-deliver the signal to this thread
   with raise(3): route_signal runs synchronously, sees pyembed_in_python ==
   0 and chains to OCaml's handler, which records it for this thread's next
   poll point, so Sys.Break is raised on the main thread exactly once. If Python
   already handled the signal (KeyboardInterrupt in the call that just
   returned), nothing is pending and nothing happens. */
static void hand_late_signal_to_ocaml(void) {
  routed_to_python = 0;
  int sig = routed_signal;
  PyObject *prev = PyErr_GetRaisedException();
  int rc = PyErr_CheckSignals();
  if (rc < 0) PyErr_Clear();
  PyErr_SetRaisedException(prev);
  if (rc < 0) raise(sig);
}

/* Python code that changes the handler of a routed signal through
   signal.signal (asyncio.Runner does so on every run, and restores
   default_int_handler at the end) makes CPython install its own C handler,
   which would steal the signal from OCaml. _signal.signal is replaced by
   this wrapper: it calls the original, then re-installs route_signal when
   the new handler is a Python callable (the callable is still what runs
   when the signal arrives during Python code). SIG_DFL/SIG_IGN set from
   Python are honoured as is. */
static PyObject *original_signal = NULL;

static PyObject *signal_wrapper(PyObject *self, PyObject *const *args,
                                Py_ssize_t nargs) {
  PyObject *r = PyObject_Vectorcall(original_signal, args, nargs, NULL);
  if (r == NULL || nargs != 2 || !PyLong_Check(args[0]) || !PyCallable_Check(args[1]))
    return r;
  long sig = PyLong_AsLong(args[0]);
  for (int i = 0; i < N_ROUTED; i++)
    if (routed[i] && routed_signals[i] == sig) install_route(i);
  PyErr_Clear();
  return r;
}

static PyMethodDef signal_wrapper_def = {
    "signal", (PyCFunction)(void (*)(void))signal_wrapper, METH_FASTCALL,
    "signal($module, signalnum, handler, /)\n--\n\n"
    "Set the action for the given signal (pyembed keeps routing SIGINT and "
    "SIGTERM between OCaml and Python)."};

/* Called with the GIL held, right after Py_InitializeFromConfig. Returns 0
   or -1 with a Python exception set. */
static int setup_signals(int handle) {
  /* Like a default CPython start-up: writing to a closed pipe raises
     BrokenPipeError instead of killing the process. Inherited by child
     processes: spawners that need SIG_DFL must reset it. */
#ifndef _WIN32 /* no SIGPIPE on Windows: a closed pipe is an EPIPE/EINVAL error */
  signal(SIGPIPE, SIG_IGN);
#endif
  if (!handle) return 0;
  PyObject *mod = PyImport_ImportModule("_signal");
  if (mod == NULL) return -1;
  PyObject *py_handler = PyObject_GetAttrString(mod, "default_int_handler");
  PyObject *py_signal = PyObject_GetAttrString(mod, "signal");
  int rc = (py_handler && py_signal) ? 0 : -1;
  int any = 0;
  for (int i = 0; rc == 0 && i < N_ROUTED; i++) {
    if (!save_ocaml_handler(i)) continue;
    /* Give Python a handler for the signal so a tripped signal raises
       KeyboardInterrupt (signal.signal also installs CPython's own C
       handler; ours replaces it just below). */
    PyObject *r = PyObject_CallFunction(py_signal, "iO", routed_signals[i],
                                        py_handler);
    if (r == NULL) {
      rc = -1;
      break;
    }
    Py_DECREF(r);
    install_route(i);
    any = 1;
  }
  if (rc == 0 && any) {
    original_signal = Py_NewRef(py_signal);
    PyObject *w = PyCFunction_New(&signal_wrapper_def, NULL);
    if (w == NULL || PyObject_SetAttrString(mod, "signal", w) != 0) rc = -1;
    Py_XDECREF(w);
  }
  Py_XDECREF(py_handler);
  Py_XDECREF(py_signal);
  Py_DECREF(mod);
  return rc;
}

/* ------------------------------------------------------------------------ */
/* Initialization                                                            */

static int frozen_table_has(const char *name) {
  for (const struct _frozen *p = pyembed_frozen_table; p->name != NULL; p++)
    if (strcmp(p->name, name) == 0) return 1;
  return 0;
}

static PyStatus set_string(PyConfig *c, wchar_t **field, value v) {
  return PyConfig_SetBytesString(c, field, String_val(v));
}

/* Format the pending Python exception as "Type: message" into buf. */
static void format_python_error(char *buf, size_t n, const char *what) {
  PyObject *exc = PyErr_GetRaisedException();
  PyObject *s = exc ? PyObject_Str(exc) : NULL;
  const char *msg = s ? PyUnicode_AsUTF8(s) : NULL;
  if (msg == NULL) PyErr_Clear();
  snprintf(buf, n, "pyembed: %s: %s: %s", what,
           exc ? Py_TYPE(exc)->tp_name : "?", msg ? msg : "?");
  Py_XDECREF(s);
  Py_XDECREF(exc);
}

/* Install the frozen bootstrap importer over the registered bundles. */
static int install_importer(void) {
  if (!frozen_table_has("_pyembed_importer")) return 0;
  PyObject *pyembed = PyImport_ImportModule("_pyembed");
  PyObject *imp = pyembed ? PyImport_ImportModule("_pyembed_importer") : NULL;
  PyObject *r = NULL;
  if (imp != NULL) {
    PyObject *b = PyObject_CallMethod(pyembed, "bundles", NULL);
    PyObject *l = b ? PyObject_CallMethod(pyembed, "libdynload_dir", NULL) : NULL;
    PyObject *d = l ? PyObject_CallMethod(pyembed, "dev_overrides", NULL) : NULL;
    if (d != NULL) r = PyObject_CallMethod(imp, "install", "OOO", b, l, d);
    Py_XDECREF(b);
    Py_XDECREF(l);
    Py_XDECREF(d);
  }
  Py_XDECREF(pyembed);
  Py_XDECREF(imp);
  if (r == NULL) return -1;
  Py_DECREF(r);
  return 0;
}

/* pyembed_init : Backend.init_args -> unit. Field order follows the record
   in backend.mli. Runs on the calling thread, which becomes the main
   thread. */
value pyembed_init(value args) {
  CAMLparam1(args);
  if (init_error != NULL) caml_failwith(init_error);
  if (pyembed_initialized) CAMLreturn(Val_unit);
  value v_prog = Field(args, 0), v_argv = Field(args, 1),
        v_home = Field(args, 2), v_path = Field(args, 3),
        v_dynload = Field(args, 4), v_dev = Field(args, 5),
        v_signals = Field(args, 6), v_functions = Field(args, 7),
        v_classes = Field(args, 8), v_methods = Field(args, 9),
        v_bundles = Field(args, 10);

  /* Builtin modules must be in the inittab before Py_Initialize
     (import.html#c.PyImport_AppendInittab). */
  pyembed_module_setup(v_bundles, v_dynload, v_dev);
  pyembed_exports_setup(v_functions, v_classes, v_methods);

  /* Custom frozen modules are consulted before the stdlib ones
     (import.html#c.PyImport_FrozenModules). */
  if (pyembed_frozen_table[0].name != NULL)
    PyImport_FrozenModules = pyembed_frozen_table;

  /* UTF-8 mode (PEP 540). The isolated configuration does not configure
     the LC_CTYPE locale, which would leave the filesystem, stdio and
     preferred encodings at ASCII (non-ASCII paths and output would fail
     with encoding errors); force UTF-8 for all of them, as `python -X utf8`
     does (init-config.html#c.PyPreConfig.utf8_mode). Must precede the
     Py_DecodeLocale and PyConfig_SetBytesArgv calls below, which decode
     with the pre-configured encoding. */
  PyPreConfig pre;
  PyPreConfig_InitIsolatedConfig(&pre);
  pre.utf8_mode = 1;
  PyStatus st = Py_PreInitialize(&pre);
  if (PyStatus_Exception(st)) {
    char buf[1024];
    snprintf(buf, sizeof buf, "pyembed: Py_PreInitialize: %s%s%s",
             st.func ? st.func : "", st.func ? ": " : "",
             st.err_msg ? st.err_msg : "failed");
    init_error = caml_stat_strdup(buf);
    caml_failwith(buf);
  }

  PyConfig config;
  PyConfig_InitIsolatedConfig(&config);
  config.module_search_paths_set = 1;
  config.site_import = 0;
  config.write_bytecode = 0;
  config.install_signal_handlers = 0;
  config.parse_argv = 0;
  config.pathconfig_warnings = 0;
  config.use_frozen_modules = 1;
  config.user_site_directory = 0;
  st = set_string(&config, &config.program_name, v_prog);
  if (!PyStatus_Exception(st))
    st = set_string(&config, &config.executable, v_prog);
  if (!PyStatus_Exception(st) && Is_some(v_home))
    st = set_string(&config, &config.home, Some_val(v_home));
  for (mlsize_t i = 0; !PyStatus_Exception(st) && i < Wosize_val(v_path); i++) {
    wchar_t *w = Py_DecodeLocale(String_val(Field(v_path, i)), NULL);
    if (w == NULL) {
      st = PyStatus_NoMemory();
      break;
    }
    st = PyWideStringList_Append(&config.module_search_paths, w);
    PyMem_RawFree(w);
  }
  if (!PyStatus_Exception(st)) {
    mlsize_t argc = Wosize_val(v_argv);
    char **argv = calloc(argc + 1, sizeof(char *));
    if (argv == NULL) st = PyStatus_NoMemory();
    for (mlsize_t i = 0; argv && i < argc; i++)
      argv[i] = (char *)String_val(Field(v_argv, i));
    if (argv) {
      st = PyConfig_SetBytesArgv(&config, (Py_ssize_t)argc, argv);
      free(argv);
    }
  }
  if (!PyStatus_Exception(st)) st = Py_InitializeFromConfig(&config);
  PyConfig_Clear(&config);
  if (PyStatus_Exception(st)) {
    char buf[1024];
    snprintf(buf, sizeof buf, "pyembed: Py_InitializeFromConfig: %s%s%s",
             st.func ? st.func : "", st.func ? ": " : "",
             st.err_msg ? st.err_msg : "failed");
    init_error = caml_stat_strdup(buf);
    caml_failwith(buf);
  }

  pyembed_main_ident = PyThread_get_thread_ident();
#ifndef _WIN32
  pthread_atfork(NULL, NULL, on_fork_child);
#endif
  pyembed_initialized = 1;

  char err[2048];
  int failed = 0;
  /* Frozen code must come from this exact interpreter version
     (import.html#c.PyImport_GetMagicNumber: the 4 magic bytes, little
     endian). */
  if (pyembed_frozen_table[0].name != NULL) {
    const unsigned char *mg = pyembed_frozen_magic;
    long want = (long)mg[0] | (long)mg[1] << 8 | (long)mg[2] << 16 | (long)mg[3] << 24;
    long have = PyImport_GetMagicNumber();
    if (have != want) {
      PyErr_Clear();
      snprintf(err, sizeof err,
               "pyembed: frozen modules were compiled for bytecode magic %ld, "
               "this interpreter has %ld",
               want, have);
      failed = 1;
    }
  }
  /* Creates _pyembed.OCamlError; then the bundle importer, then signals. */
  PyObject *m = failed ? NULL : PyImport_ImportModule("_pyembed");
  if (!failed && m == NULL) {
    format_python_error(err, sizeof err, "import _pyembed");
    failed = 1;
  }
  Py_XDECREF(m);
  if (!failed && install_importer() != 0) {
    format_python_error(err, sizeof err, "installing _pyembed_importer");
    failed = 1;
  }
  if (!failed && setup_signals(Bool_val(v_signals)) != 0) {
    format_python_error(err, sizeof err, "signal setup");
    failed = 1;
  }
  /* The main thread now holds the domain lock and not the GIL. */
  (void)PyEval_SaveThread();
  if (failed) {
    /* The interpreter is up but unusable: refuse it from now on. */
    init_error = caml_stat_strdup(err);
    caml_failwith(err);
  }
  CAMLreturn(Val_unit);
}

/* ------------------------------------------------------------------------ */
/* Exit                                                                      */

/* Flush sys.<name> unless it is None or closed; 0 or -1 (CPython's
   flush_std_files: a failure turns the exit status into 120). */
static int flush_std(const char *name) {
  PyObject *f = PySys_GetObject(name); /* borrowed */
  if (f == NULL || f == Py_None) return 0;
  PyObject *closed = PyObject_GetAttrString(f, "closed");
  int is_closed = closed != NULL && PyObject_IsTrue(closed) == 1;
  Py_XDECREF(closed);
  PyErr_Clear();
  if (is_closed) return 0;
  PyObject *r = PyObject_CallMethod(f, "flush", NULL);
  if (r == NULL) {
    if (strcmp(name, "stdout") == 0) PyErr_WriteUnraisable(f);
    PyErr_Clear();
    return -1;
  }
  Py_DECREF(r);
  return 0;
}

/* What Py_FinalizeEx does for user code, in the same order, without tearing
   the interpreter down (it is never finalized; the caller then _exits):
   wait for non-daemon threads (threading._shutdown, only if threading was
   imported), run atexit callbacks, flush sys.stdout/sys.stderr. Returns
   false if a flush failed. */
value pyembed_finish(value unit) {
  pyembed_check_gil();
  pyembed_py_section s = pyembed_py_enter();
  PyObject *modules = PyImport_GetModuleDict(); /* borrowed */
  PyObject *threading = PyDict_GetItemString(modules, "threading"); /* borrowed */
  if (threading != NULL) {
    PyObject *r = PyObject_CallMethod(threading, "_shutdown", NULL);
    if (r == NULL) PyErr_WriteUnraisable(threading);
    Py_XDECREF(r);
    PyErr_Clear();
  }
  PyObject *atexit = PyImport_ImportModule("atexit");
  if (atexit != NULL) {
    PyObject *r = PyObject_CallMethod(atexit, "_run_exitfuncs", NULL);
    if (r == NULL) PyErr_Print();
    Py_XDECREF(r);
    Py_DECREF(atexit);
  } else {
    PyErr_Clear();
  }
  int ok = flush_std("stdout") == 0;
  ok = (flush_std("stderr") == 0) && ok;
  pyembed_py_leave(s);
  return Val_bool(ok);
}
