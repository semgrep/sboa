(*
   Copyright (c) 2026 Semgrep Inc.

   This library is free software; you can redistribute it and/or
   modify it under the terms of the GNU Lesser General Public License
   version 2.1 as published by the Free Software Foundation.

   This library is distributed in the hope that it will be useful, but
   WITHOUT ANY WARRANTY; without even the implied warranty of
   MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the file
   LICENSE for more details.
*)
(** Primitive layer of [sboa] (virtual module).

    This is the boundary between the OCaml bridge logic in {!Sboa} and an
    implementation: [sboa.cpython] binds each value to a C stub against
    [Python.h]; [sboa.disabled] raises {!Not_available} from every
    primitive that needs an interpreter. Nothing outside [sboa] should use
    this module: it is unsafe by design (it trusts {!Sboa} to call it on
    the right thread with the right locks).

    Conventions for the cpython implementation:
    - Every primitive that touches Python checks that the calling thread
      holds the GIL and raises [Invalid_argument] otherwise (a [gil] token
      used outside its scope).
    - Primitives that can run arbitrary Python code release the OCaml domain
      lock around that code (unless the enclosing {!gil_ensure} asked to keep
      it), so other OCaml systhreads keep running.
    - When a Python API call fails, the stub moves the raised Python exception
      into a pending slot and raises {!Pending}; {!Sboa} then calls
      {!take_pending} and translates it. Stubs never raise while holding a GIL
      state they acquired themselves.
    - [set_error_*] primitives set the Python error indicator (for the export
      trampoline to return [NULL]); they do not raise. *)

type obj
(** An owned reference to a Python object: a custom block that stores only
    the [PyObject*]. Its finalizer never touches Python; it pushes the pointer
    onto a lock-free queue drained under the GIL ({!gil_ensure}, the export
    trampoline, {!drain}). *)

type data =
  (char, Bigarray.int8_unsigned_elt, Bigarray.c_layout) Bigarray.Array1.t
(** Read-only bytes of an embedded bundle. *)

exception Pending
(** A Python exception is pending; fetch it with {!take_pending}. *)

exception Overflow
(** A Python int does not fit in an OCaml [int]. *)

exception Not_available
(** Raised by the disabled implementation. *)

type fn_spec = {
  fn_module : string;
  fn_name : string;
  fn_doc : string;  (** docstring, with the text-signature prefix if any *)
  fn_index : int;  (** index of the entry in the dispatcher's table *)
}
(** An exported function, as passed to C. *)

type class_spec = {
  cls_module : string;
  cls_name : string;
  cls_doc : string;
  cls_repr : int;  (** table index of the [__repr__] entry, or [-1] *)
}
(** An exported class; its class index is its position in
    [init_args.classes]. *)

type method_spec = {
  meth_class : int;  (** class index *)
  meth_name : string;
  meth_doc : string;
  meth_index : int;  (** table index *)
}
(** A method of an exported class. *)

type init_args = {
  program_name : string;
  argv : string array;
  home : string option;
  sys_path : string array;
  libdynload_dir : string option;
  dev_overrides : string array;
  handle_signals : bool;
  functions : fn_spec array;
  classes : class_spec array;
  methods : method_spec array;
  bundles : (string * data) array;  (** in search order *)
}
(** Everything [init] needs, copied to C before the interpreter starts. Field
    order is read by position in C (sboa_init). *)

(** {2 Lifecycle} *)

val init : init_args -> unit
(** Start the interpreter (once). Raises [Failure]; after a failure every
    later call raises the same [Failure] (no retry). *)

val is_initialized : unit -> bool
(** [Py_InitializeFromConfig] succeeded (even if a later start-up step
    failed; see {!init_failed}). *)

val init_failed : unit -> bool
(** A previous {!init} failed. *)

val init_error : unit -> string
(** The message of that failure ([""] if none). *)

val thread_ok : unit -> bool
(** The calling systhread is the one that ran [init] (or Python is not
    initialized), and this process is not a fork child of it. *)

val gil_ensure : bool -> int
(** [gil_ensure keep_domain_lock]: PyGILState_Ensure (releasing the domain
    lock while blocking), drain the deferred queues, hand late signals back to
    OCaml, and set the keep-domain-lock mode for the scope. Returns an opaque
    state for {!gil_release}. *)

val gil_release : int -> unit
(** Undo the matching {!gil_ensure}. *)

val save_thread : unit -> unit
(** PyEval_SaveThread (start of [detach]). *)

val restore_thread : unit -> unit
(** Re-take the GIL saved by {!save_thread} and drain the queues. *)

val drain : unit -> unit
(** Drain the deferred DECREF and root queues now (GIL held). *)

val pending_decrefs : unit -> int
(** Number of queued DECREFs. *)

val live_roots : unit -> int
(** Number of generational roots owned by Python objects. *)

val gc_collect : unit -> int
(** PyGC_Collect. *)

val finish : unit -> bool
(** [threading._shutdown()], [atexit] callbacks, flush of
    [sys.stdout]/[sys.stderr]; [false] if a flush failed. *)

(** {2 Objects} *)

val none : obj
(** Python [None] (usable before init). *)

val is_none : obj -> bool
(** Pointer comparison with [None]; no GIL needed. *)

val release : obj -> unit
(** DECREF now and clear the handle. *)

val release_args : obj array -> obj -> unit
(** Release every handle of the array except the given one (physical
    equality). *)

val refcount : obj -> int
(** [Py_REFCNT]. *)

val type_name : obj -> string
(** Short type name ([tp_name] after the last dot). *)

val is_callable : obj -> bool
(** [PyCallable_Check]. *)

val import : string -> obj
(** [PyImport_Import]. *)

val get_attr : obj -> string -> obj
(** [getattr(o, name)]. *)

val set_attr : obj -> string -> obj -> unit
(** [setattr(o, name, x)]. *)

val call : obj -> obj array -> string array -> obj array -> obj
(** [call f args kwnames kwvalues]: vectorcall. *)

val repr : obj -> string
(** [repr(o)] as UTF-8. *)

val str : obj -> string
(** [str(o)] as UTF-8. *)

val eval : string -> obj
(** Evaluate an expression in [__main__]. *)

val exec : string -> unit
(** Execute statements in [__main__]. *)

(** {2 Conversions} (no Python code runs in these) *)

(** Python type of an object, by C type flag (subclasses included); [bool]
    is reported before [int]. Constant constructors: the C side returns
    [Val_int] of the position. *)
type kind =
  | K_none
  | K_bool
  | K_int
  | K_float
  | K_str
  | K_bytes  (** [bytes] or [bytearray] *)
  | K_list
  | K_tuple
  | K_dict
  | K_other

val kind : obj -> kind
(** See {!type-kind}. *)

val of_int : int -> obj
(** [int] *)

val to_int : obj -> int
(** Of a Python [int]; raises {!Overflow} outside OCaml's range. *)

val of_float : float -> obj
(** [float] *)

val to_float : obj -> float
(** Of a Python [float] or [int]. *)

val of_bool : bool -> obj
(** [True]/[False] *)

val to_bool : obj -> bool
(** [o is True]. *)

val of_string : string -> obj
(** [str] from UTF-8; raises {!Pending} (UnicodeDecodeError) otherwise. *)

val to_string : obj -> string
(** UTF-8 of a [str]; raises {!Pending} on lone surrogates. *)

val of_bytes : string -> obj
(** [bytes] *)

val to_bytes : obj -> string
(** Of [bytes] or [bytearray]. *)

val list_of_array : obj array -> obj
(** New [list]. *)

val tuple_of_array : obj array -> obj
(** New [tuple]. *)

val seq_items : obj -> obj array
(** Items of a [list] or [tuple]. *)

val dict_of_arrays : string array -> obj array -> obj
(** New [dict] from keys and values. *)

val dict_items : obj -> (obj * obj) array
(** Items of a [dict], in order. *)

(** {2 Exceptions} *)

val take_pending : unit -> obj
(** The pending exception ([None] if there is none); clears the slot. *)

(** Classification of a pending exception. Constant constructors, same
    encoding as {!type-kind}. *)
type exc_class =
  | Exc_other
  | Exc_system_exit
  | Exc_keyboard_interrupt
  | Exc_ocaml  (** an [OCamlError] carrying a valid resurrection capsule *)

val exc_classify : obj -> exc_class
(** See {!type-exc_class}. *)

val exc_info : obj -> string * string * string
(** Dotted type name, [str(exc)], formatted traceback. *)

val exit_code : obj -> int
(** Exit status of a [SystemExit], as CPython computes it. *)

val resurrect : obj -> exn * Printexc.raw_backtrace
(** The OCaml exception rooted by an [OCamlError]. *)

val set_error_obj : obj -> unit
(** Raise this exception object (unchanged) in Python. *)

val set_error_builtin : string -> string -> unit
(** [set_error_builtin "TypeError" msg]; empty message means no argument. *)

val set_error_class : obj -> obj -> unit
(** [set_error_class cls args_tuple]. *)

val set_error_system_exit : int -> unit
(** [SystemExit(code)]. *)

val set_error_ocaml : string -> exn * Printexc.raw_backtrace -> unit
(** [_sboa.OCamlError(msg)] carrying a capsule that roots the pair. *)

(** {2 Exports} *)

val frame_args : unit -> obj array
(** Positional then keyword values of the current trampoline call. *)

val frame_kwnames : unit -> string array
(** Keyword names of the current trampoline call. *)

val class_wrap : int -> Obj.t -> obj
(** New instance of class [i] rooting the value. *)

val class_unwrap : int -> obj -> Obj.t option
(** The value of an instance of exactly class [i]. *)

(** {2 Counters} *)

val counter_ptr : obj -> nativeint
(** Address of the atomic of a [_sboa.Counter] instance, or [0n] if the
    object is not exactly a [Counter]. *)

val new_ref : obj -> obj
(** A new owned handle on the same Python object. *)

val counter_add : nativeint -> int -> unit
(** Atomically add to the counter at this address. Any thread, any domain,
    no lock, no allocation. *)

val counter_set : nativeint -> int -> unit
(** Atomically store. Same rules as {!counter_add}. *)

val counter_get : nativeint -> int
(** Atomically load. Same rules as {!counter_add}. *)
