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
(** Embed CPython in an OCaml program.

    [sboa] links a CPython 3.13 shared library into the executable and
    exposes a small, explicit bridge:

    - a {!gil} token proving the calling thread holds the GIL, obtained only
      from {!with_gil} or inside exported functions;
    - {!Object.t}, an owned handle on a Python object whose reference is
      released through a deferred queue (OCaml finalizers never call Python);
    - {!Conv}, fallible conversions with an error path;
    - {!Export}, which publishes OCaml functions and classes as builtin
      Python modules (registered before {!init}, as top-level effects);
    - {!Counter}, 64-bit atomic counters that OCaml updates from any domain
      while Python threads read them (progress reporting);
    - exception translation in both directions ({!Python_error},
      {!System_exit}, and [_sboa.OCamlError], which resurrects the
      original OCaml exception when it crosses back).

    {b Thread rules (v1).} Python is initialized and used only from the
    systhread of domain 0 that calls {!init}. {!with_gil} raises
    [Invalid_argument] elsewhere and in fork children; Python threads calling
    an export get [RuntimeError]. Around every call into Python the OCaml
    domain lock is released, so other OCaml systhreads keep running while
    Python works (opt out per scope with [~keep_domain_lock:true]); while an
    exported OCaml function runs, the GIL is released, so Python threads keep
    running.

    {b Tokens.} A {!gil} value is only valid inside the {!with_gil} scope (or
    export call) that produced it, outside {!detach}, on the same thread.
    Every primitive checks that the calling thread holds the GIL and raises
    [Invalid_argument] otherwise, so an escaped token fails loudly instead of
    corrupting the interpreter.

    {b Signals.} If the program handles SIGINT/SIGTERM in OCaml (e.g.
    [Sys.catch_break true]) {e before} {!init}, a signal that arrives while
    Python runs becomes [KeyboardInterrupt] in Python and [Sys.Break] when it
    reaches OCaml; one that arrives while OCaml runs goes to the OCaml
    handler. Each signal is seen by exactly one runtime, and a signal that
    Python received just as control returned to OCaml is re-raised in OCaml
    on the main thread. Python code that installs its own handler with
    [signal.signal] (asyncio does) keeps that handler for signals arriving
    during Python code; routing is re-asserted immediately. SIGPIPE is
    ignored once Python is initialized (as in a normal CPython process); the
    disposition is inherited by child processes, so code that spawns
    programs expecting the default should reset it in the child.

    This library knows nothing about any particular application. *)

type gil
(** Proof that the calling thread holds the GIL. See "Tokens" above. *)

(** Interpreter configuration. What is not configurable: [sys.executable]
    and the program name are [Sys.executable_name], [sys.argv] starts as
    [[Sys.executable_name]] (the application sets the real one), the bundle
    importer loads C extension modules from
    [<dir of executable>/libs/python3.X/lib-dynload] on unix and from the
    directory of the executable on Windows (the runtime files are installed
    flat next to the [.exe]; the importer gets [None] if the directory does
    not exist), and SIGINT/SIGTERM are routed as described above. *)
module Config : sig
  type t = {
    extra_sys_path : string list;
        (** The initial [sys.path] (empty by default: code comes from the
            embedded bundles). For development and tests, e.g. a stdlib
            directory and its [lib-dynload]. *)
    dev_overrides : string list;
        (** Directories whose sources take precedence over the bundles;
            passed to the bundle importer. *)
  }

  val default : unit -> t
  (** The configuration {!with_gil} uses when it initializes Python itself:
      the fields' documented defaults. *)

  val equal : t -> t -> bool
  (** Structural equality. *)
end

(** Owned references to Python objects. *)
module Object : sig
  type t
  (** One owned [PyObject*]. Not comparable, hashable or marshalable. The
      reference is released after the handle becomes unreachable, at the
      next bridge crossing ({!with_gil}, an export call, {!gc_flush}), or
      immediately with {!release}. *)

  val none : t
  (** Python [None]. *)

  val is_none : t -> bool
  (** [o is None]; needs no token. *)

  val type_name : gil -> t -> string
  (** Short name of the object's type, e.g. ["int"], ["OCamlError"]. *)

  val get_attr : gil -> t -> string -> t
  (** [getattr(o, name)]; raises like {!call}. *)

  val set_attr : gil -> t -> string -> t -> unit
  (** [setattr(o, name, x)]; raises like {!call}. *)

  val call : gil -> t -> ?args:t array -> ?kwargs:(string * t) list -> unit -> t
  (** Call a Python callable. A raised Python exception is translated as
      described for {!Python_error}. *)

  val call_method :
    gil ->
    t ->
    string ->
    ?args:t array ->
    ?kwargs:(string * t) list ->
    unit ->
    t
  (** [call_method gil o name] is [call gil (get_attr gil o name)]. *)

  val repr : gil -> t -> string
  (** [repr(o)], UTF-8. *)

  val str : gil -> t -> string
  (** [str(o)], UTF-8. *)

  val release : gil -> t -> unit
  (** Drop the reference now (for large objects); later uses of the handle
      raise [Invalid_argument]. No-op on {!none}. *)

  val with_ : gil -> t -> (t -> 'a) -> 'a
  (** [with_ gil o f] runs [f o] then releases [o], even on exception. *)

  val refcount : gil -> t -> int
  (** The object's reference count, for tests and debugging. *)
end

(** A Python exception that crossed into OCaml. *)
module Python_error : sig
  type t = {
    ty : string;  (** dotted class name, e.g. ["builtins.ValueError"] *)
    msg : string;  (** [str(exc)] *)
    traceback : string;  (** [traceback.format_exception(exc)], joined *)
    exn : Object.t;
        (** the exception object; re-raised unchanged if this OCaml exception
            crosses back into Python *)
  }

  val to_string : t -> string
  (** The formatted traceback, or ["ty: msg"] if there is none. *)
end

(** Fallible typed conversions between OCaml and Python values. *)
module Conv : sig
  type path_elt =
    | Field of string
    | Index of int
    | Arg of string
    | Key of string

  type error = {
    path : path_elt list;  (** outermost first *)
    expected : string;
    got : string;
  }

  val error_to_string : error -> string
  (** e.g. ["argument 'rules'[3]: expected str, got int"] *)

  type 'a to_py = gil -> 'a -> Object.t
  type 'a of_py = gil -> Object.t -> ('a, error) result

  type 'a t
  (** A two-way converter between ['a] and a Python type. *)

  type any =
    | Any : 'a t -> any
        (** A converter of any type, where only its metadata matters: its type
      description and the record classes its values contain. *)

  val make :
    ?ty:string ->
    ?parts:any list ->
    to_py:'a to_py ->
    of_py:'a of_py ->
    unit ->
    'a t
  (** [ty] describes the Python type for messages and stubs, e.g.
      ["list[str]"]. [parts] are the converters it delegates to: an export
      using the result registers their {{!record}record classes} in its
      module. *)

  val to_py : 'a t -> 'a to_py
  val of_py : 'a t -> 'a of_py

  val ty : 'a t -> string option
  (** The Python type description, if known. *)

  val map : ?ty:string -> ('a -> 'b) -> ('b -> 'a) -> 'a t -> 'b t
  (** [map decode encode c]: e.g. [map Fpath.v Fpath.to_string string].
      Exceptions raised by [decode] propagate. *)

  val with_path : path_elt -> 'a of_py -> 'a of_py
  (** Prefix the path of a conversion error. *)

  val int : int t
  (** Python [int] (not [bool]) within OCaml's [int] range. *)

  val float : float t
  (** Python [float]; [int] is accepted on input. *)

  val bool : bool t
  (** Python [bool] only. *)

  val string : string t
  (** [str] <-> UTF-8 [string]. Encoding a non-UTF-8 string raises
      {!Conversion_error}. *)

  val bytes : string t
  (** [bytes] <-> [string]; [bytearray] accepted on input. *)

  val unit : unit t
  (** [None]. *)

  val object_ : Object.t t
  (** Identity. *)

  val json : string t
  (** The unconverted lane for serialized payloads: [bytes] out; [bytes] or
      [str] (UTF-8) in. *)

  val list : 'a t -> 'a list t
  (** [list] out; [list] or [tuple] in. *)

  val option : 'a t -> 'a option t
  (** [None] <-> [None]. ['a option option] is ambiguous; avoid it. *)

  val dict : 'a t -> (string * 'a) list t
  (** [dict] with [str] keys, in insertion order. *)

  val pair : 'a t -> 'b t -> ('a * 'b) t
  (** A 2-tuple ([tuple] out; [tuple] or [list] of length 2 in). *)

  val tuple3 : 'a t -> 'b t -> 'c t -> ('a * 'b * 'c) t
  (** A 3-tuple, like {!pair}. *)

  val tuple4 : 'a t -> 'b t -> 'c t -> 'd t -> ('a * 'b * 'c * 'd) t
  (** A 4-tuple, like {!pair}. *)

  val array : 'a t -> 'a array t
  (** Like {!list}. *)

  (** {2 Records and variants}
      What [[@@deriving sboa]] (the [sboa.ppx] deriver, see the README)
      generates code against; usable by hand as well. *)

  type record_class
  (** A Python class for an OCaml record type: attributes named after the
      fields, a constructor taking them positionally or by keyword, a
      [repr] like [ScanResult(output='', exit_code=0)], [__match_args__].
      Plain records are frozen, compare and hash by value and pickle;
      exception records subclass [_sboa.OCamlError] (see
      {!Export.register_exception}). The class is created once, the first
      time a module that holds it is imported (its [__module__] is the first
      export module it was registered in) or at the first conversion. *)

  val record_class :
    ?doc:string ->
    ?exception_:bool ->
    name:string ->
    string list ->
    record_class
  (** [record_class ~name fields]: [doc] becomes the class docstring. *)

  val record :
    record_class ->
    any list ->
    to_fields:(gil -> 'a -> Object.t array) ->
    of_py:'a of_py ->
    'a t
  (** [record cls field_convs ~to_fields ~of_py]: [to_py] calls the class
      with [to_fields] (the converted fields in order); [field_convs] (in
      field order) give the field types for stubs and the record classes
      nested in the fields. [of_py] is typically a sequence of {!attr}, and
      so accepts any object with the attributes. *)

  val attr : gil -> Object.t -> string -> 'a of_py -> ('a, error) result
  (** [attr gil o name of_a] converts [o.name]; errors have a [Field name]
      path (a missing attribute: ["expected an attribute"]). *)

  val constructor : gil -> string -> Object.t array -> Object.t
  (** The variant encoding: a constructor without arguments is its name
      ([str]); one with arguments is a tuple of its name and the converted
      arguments, e.g. [("Circle", 1.5)]. *)

  val constructor_of_py :
    expected:string ->
    gil ->
    Object.t ->
    (string * Object.t array, error) result
  (** The name and the argument objects of an encoded constructor ([str], or
      [tuple]/[list] starting with a [str]); [expected] is the message for
      anything else. *)

  val bad_constructor :
    expected:string -> string -> Object.t array -> ('a, error) result
  (** The error for an unknown constructor name or a wrong number of
      arguments. *)

  val func0 : 'r t -> (unit -> 'r) of_py
  (** A Python callable as an OCaml closure. Calling the closure re-takes the
      GIL (it may be called from a detached export body), converts, calls,
      and raises {!Python_error} or {!Conversion_error} on failure.

      Callables are call-scoped: one converted while an export call is
      running (directly or nested in a list, dict, ...) raises
      [Invalid_argument] if called after that export call returned.
      Converted outside any export call, it stays valid. *)

  val func1 : 'a t -> 'r t -> ('a -> 'r) of_py
  (** See {!func0}. *)

  val func2 : 'a t -> 'b t -> 'r t -> ('a -> 'b -> 'r) of_py
  (** See {!func0}. *)

  val func3 : 'a t -> 'b t -> 'c t -> 'r t -> ('a -> 'b -> 'c -> 'r) of_py
  (** See {!func0}. *)

  (** {2 Argument helpers for export wrappers}
      They take the decoding half ({!of_py}, a [funcN], {!Class.unwrap}) and
      raise {!Conversion_error} with an [Arg name] path; the export
      trampoline turns that into [TypeError]. *)

  val positional : gil -> name:string -> 'a of_py -> Object.t array -> int -> 'a
  (** The [i]th positional argument, converted. *)

  val keyword : gil -> name:string -> 'a of_py -> (string * Object.t) list -> 'a
  (** A required keyword argument, converted. *)

  val keyword_opt :
    gil -> name:string -> 'a of_py -> (string * Object.t) list -> 'a option
  (** An optional keyword argument: absent or [None] gives [None]. *)

  val check_arity :
    max_positional:int ->
    keywords:string list ->
    Object.t array ->
    (string * Object.t) list ->
    unit
  (** Reject extra positional arguments and unknown keywords. *)

  val to_py_exn : 'a t -> gil -> 'a -> Object.t
  (** [to_py], raising {!Conversion_error} on failure. *)

  val of_py_exn : 'a t -> gil -> Object.t -> 'a
  (** [of_py], raising {!Conversion_error} on failure. *)
end

exception Python_error of Python_error.t
(** Raised when Python code called from OCaml raises (other than the cases
    below). [SystemExit] becomes {!System_exit}; [KeyboardInterrupt] becomes
    [Sys.Break]; an [OCamlError] that originated in OCaml becomes the
    original OCaml exception, re-raised with its backtrace. *)

exception Conversion_error of Conv.error
(** A Python value did not have the expected shape. *)

exception System_exit of int
(** [SystemExit] reached OCaml; the payload is the exit status. *)

(** OCaml values exposed to Python as instances of an exported class. *)
module Class : sig
  type 'a t
  (** An exported class whose instances hold an ['a]. *)

  val wrap : gil -> 'a t -> 'a -> Object.t
  (** A new instance holding the value under a generational global root,
      removed when Python frees the instance. Imports the class's module
      first if needed. *)

  val unwrap : 'a t -> 'a Conv.of_py
  (** The value of an instance of exactly this class. *)

  val conv : 'a t -> 'a Conv.t
  (** {!wrap} and {!unwrap} as a converter. *)

  val name : 'a t -> string
  (** The class name (without the module). *)
end

(** Atomic counters shared with Python: [_sboa.Counter] (re-exported by
    every export module as [<module>.Counter], unless the module registers
    a class of that name itself).

    Python creates one with [Counter()] and reads [counter.value] from any
    thread: the getter is C code that never enters OCaml, so a Python
    background thread can poll it while the main thread is inside a
    detached export. OCaml gets a {!t} from the object (under the GIL) and
    updates it with {!add}/{!incr}/{!set} from any domain or systhread,
    without the GIL or the domain lock: they are [[@@noalloc]] C11 atomic
    operations (relaxed ordering) that never call Python. *)
module Counter : sig
  type t
  (** A counter: the address of the atomic inside a [Counter] instance and
      an owned handle on that instance, so the object stays alive while [t]
      is reachable (also after the export call that received it returned).
      Immutable; safe to share between domains. *)

  val of_py : t Conv.of_py
  (** Of exactly a [_sboa.Counter] instance (no subclass exists: the type
      is final). *)

  val conv : t Conv.t
  (** {!of_py}, and the counter's object back (typed ["Counter"]). *)

  val of_object : gil -> Object.t -> t
  (** {!of_py}, raising {!Conversion_error} on another type. *)

  val add : t -> int -> unit
  (** Atomically add (may be negative). Any domain, no lock, no allocation. *)

  val incr : t -> unit
  (** [add t 1]. *)

  val set : t -> int -> unit
  (** Atomically store. Any domain, no lock, no allocation. *)

  val get : t -> int
  (** Atomically load. Any domain, no lock, no allocation. *)
end

(** Registries that make OCaml callable from Python. Registration must
    happen on the main domain before {!init} (top-level effects of linked
    modules); later registrations raise [Invalid_argument]. *)
module Export : sig
  type fn = gil -> Object.t array -> (string * Object.t) list -> Object.t
  (** Positional arguments, keyword arguments, result. The GIL is held;
      release it around long OCaml work with {!detach}. The argument handles
      are released when the call returns (except one returned as the
      result). *)

  val register :
    module_:string ->
    name:string ->
    ?doc:string ->
    ?signature:string ->
    fn ->
    unit
  (** Add [module_.name] to the builtin module [module_] (created on first
      registration; at most 32 modules). [signature] is the parameter list
      without parentheses (e.g. ["request, /, *, on_progress=None"]); it
      becomes [__text_signature__]. *)

  val register_class :
    module_:string ->
    name:string ->
    ?doc:string ->
    ?methods:(string * ('a -> fn)) list ->
    ?repr:(gil -> 'a -> string) ->
    unit ->
    'a Class.t
  (** A heap type [module_.name]: final, immutable, slot-less instances (no
      [__dict__]), not instantiable from Python. Each method receives the
      unwrapped OCaml value; more can be added with {!add_method}. *)

  val add_method :
    'a Class.t ->
    name:string ->
    ?doc:string ->
    ?signature:string ->
    ('a -> fn) ->
    unit
  (** Add a method to a registered class. [signature] excludes [self]. *)

  (** {2 Typed exports}
      [def] registers an OCaml function with typed parameters: arity
      checks, conversions, the text signature and the stub come from the
      parameter list. For example
      [def ~module_:"m" ~name:"f" (pos "xs" Conv.(list int) @-> kw_opt "scale" Conv.int @-> returning Conv.int) f]
      registers [m.f(xs, /, *, scale=None)] with
      [f : int list -> int option -> int]. *)

  type 'a param
  (** One parameter, giving the function an argument of type ['a]. *)

  type ('f, 'r) params
  (** A parameter list for a function of type ['f] returning ['r]. *)

  val pos : string -> 'a Conv.t -> 'a param
  (** A positional-only parameter. *)

  val kw : string -> 'a Conv.t -> 'a param
  (** A required keyword-only parameter. *)

  val kw_opt : string -> 'a Conv.t -> 'a option param
  (** An optional keyword-only parameter: absent or [None] is [None]. *)

  val unit : unit param
  (** No parameter: [unit @-> returning c] for a function of no argument. *)

  val returning : 'r Conv.t -> ('r, 'r) params
  (** The result. *)

  val ( @-> ) : 'a param -> ('f, 'r) params -> ('a -> 'f, 'r) params
  (** Add a parameter in front. *)

  val def :
    module_:string ->
    name:string ->
    ?doc:string ->
    ?detach:bool ->
    ('f, 'r) params ->
    'f ->
    unit
  (** Register [module_.name] (as {!register} does) with the signature
      [positional, /, *, keywords] (positional parameters first, whatever
      their order in the list). The arguments are converted with the GIL
      held; with [~detach:true] the function runs with the GIL released
      ({!Sboa.detach}; it may still take it with {!Sboa.with_gil}). The
      record classes of the parameters and the result are registered in
      [module_]. *)

  val register_type : module_:string -> 'a Conv.t -> unit
  (** Register the record classes of a converter in [module_] (where no
      export mentions them, e.g. for [isinstance] checks). *)

  val register_exception :
    module_:string -> 'a Conv.t -> (exn -> 'a option) -> unit
  (** [register_exception ~module_ conv extract]: an OCaml exception for
      which [extract] gives a payload escapes an export as the payload's
      class (from an exception record: [[@@sboa.exception]], or
      [Conv.record_class ~exception_:true]), a subclass of [OCamlError]
      registered in [module_]. Like [OCamlError], it re-raises the original
      OCaml exception if it crosses back into OCaml. Consulted before the
      mappings of {!register_exn_mapping}. Raises [Invalid_argument] if
      [conv] is not the converter of an exception record. *)

  val stub : string -> string
  (** The text of a [.pyi] stub for an export module: [OCamlError],
      [Counter], its record and exception classes, the classes of
      {!register_class} with their methods, the functions (annotated for
      {!def}, with the text signature otherwise), with their docs. Call it
      after the registrations (e.g. from a dune rule running a program that
      prints it). *)

  val register_exn_mapping :
    (gil -> exn -> (string * Object.t array) option) -> unit
  (** Map an OCaml exception escaping an export to a Python exception class
      (dotted name, constructor arguments). Mappings are consulted in
      registration order, after the built-in ones ({!Python_error},
      {!System_exit}, {!Conversion_error} -> [TypeError], [Sys.Break] ->
      [KeyboardInterrupt]) and before the fallbacks ([Out_of_memory] ->
      [MemoryError], [Stack_overflow] -> [RecursionError], anything else ->
      [_sboa.OCamlError], also reachable as [<module>.OCamlError]). A
      mapping that raises is skipped, except that [Sys.Break] raised by a
      mapping becomes [KeyboardInterrupt]. *)
end

(** Python modules and attributes. *)
module Import : sig
  val module_ : gil -> string -> Object.t
  (** [import name]. *)

  val cached : gil -> string -> string -> Object.t
  (** [cached gil m a] is [m.a], resolved on first use and kept for the
      lifetime of the process. *)
end

(** Python bytecode bundles embedded in the executable. *)
module Bundle : sig
  type data =
    (char, Bigarray.int8_unsigned_elt, Bigarray.c_layout) Bigarray.Array1.t
  (** Read-only bytes; for an embedded bundle, the [.incbin]'d symbol. *)

  type t
  (** A named bundle. *)

  val of_incbin : symbol:string -> name:string -> data -> t
  (** [of_incbin ~symbol ~name (blob ())]: [blob] is the C primitive emitted
      next to the [.incbin] directive that defines [symbol]; it returns a
      bigarray over the linked bytes without copying. ([symbol] is kept for
      messages; the bytes cannot be looked up from it at run time: an
      unreferenced object would not be linked, and executables do not export
      their symbols.) The data must stay alive and unmodified for the life of
      the process. *)

  val symbol : t -> string
  (** The linker symbol given to {!of_incbin}. *)

  val name : t -> string
  (** The bundle name, as seen by the importer ([<sboa:name>/...]). *)

  val data : t -> data
  (** The bytes. *)

  val register : ?priority:int -> t -> unit
  (** Make the bundle visible to Python as [_sboa.bundles()], which the
      bundle importer searches in order: lower priority first, ties in
      registration order (default 50). On the main domain, before {!init}. *)

  val registered : unit -> t list
  (** In search order. *)
end

val init : Config.t -> unit
(** Start the interpreter: register the {!Export} modules and [_sboa] as
    builtin modules, apply an isolated [PyConfig] ([sys.path] =
    [extra_sys_path], no [site], no bytecode writing, no Python signal
    handlers) in UTF-8 mode (PEP 540: the filesystem, stdio and preferred
    encodings are UTF-8 whatever the locale, as with [python -X utf8]),
    install the frozen bundle importer if it is linked, set up signal
    routing, then release the GIL. Must run on the main systhread of
    domain 0. Python is never finalized; see {!exit}.

    Calling it again with an equal configuration does nothing; with a
    different one (including after {!with_gil} initialized Python with
    [Config.default ()]) it raises [Invalid_argument]. If start-up fails it
    raises [Failure], and so does every later {!init} or {!with_gil} (the
    interpreter is never initialized twice). *)

val is_initialized : unit -> bool
(** Python was started successfully. *)

val with_gil : ?keep_domain_lock:bool -> (gil -> 'a) -> 'a
(** Take the GIL for the duration of the callback (re-entrant), initializing
    Python with [Config.default ()] if needed. Pending deferred releases run
    first. Exceptions propagate after the GIL is released. With
    [~keep_domain_lock:true], Python calls inside this scope keep the OCaml
    domain lock (cheaper for trivial calls; other OCaml threads stall). *)

val detach : gil -> (unit -> 'a) -> 'a
(** Release the GIL around OCaml work that does not touch Python objects;
    the token is invalid inside (nested {!with_gil} is allowed). *)

val exit : code:int -> 'a
(** Leave the process the way CPython's own shutdown would, without
    finalizing: wait for non-daemon Python threads, run Python [atexit]
    callbacks, flush [sys.stdout]/[sys.stderr], run OCaml [at_exit]
    handlers, then [_exit]. A failed flush turns [~code:0] into 120 (as
    CPython does). Falls back to [Stdlib.exit] if Python was never
    initialized or in a fork child. *)

val gc_flush : unit -> unit
(** Release the Python references and roots of collected handles now. *)

val gc_collect : gil -> int
(** Run Python's cycle collector; returns the number of objects collected. *)

val eval : gil -> string -> Object.t
(** Evaluate a Python expression in [__main__]. *)

val exec : gil -> string -> unit
(** Execute Python statements in [__main__]. *)

(** Introspection for tests and debugging. *)
module Debug : sig
  val pending_decrefs : unit -> int
  (** References queued by finalizers, not yet released. *)

  val live_roots : unit -> int
  (** OCaml values currently rooted by Python objects (class instances,
      resurrectable exceptions). *)
end
