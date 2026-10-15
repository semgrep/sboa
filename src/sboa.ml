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
(* sboa: the OCaml side of the CPython bridge.

   All bridge logic lives here; [Backend] is the primitive layer (C stubs in
   the C stubs). The pieces:

   - GIL scopes: [with_gil] -> Backend.gil_ensure/gil_release (which also
     drain the deferred DECREF/root queues); [detach] -> save/restore thread.
   - Python -> OCaml exceptions: stubs raise [Backend.Pending]; every wrapper
     here turns that into [raise_pending ()], which classifies the pending
     Python exception (SystemExit, KeyboardInterrupt, resurrectable
     OCamlError, anything else) and raises the matching OCaml exception.
   - Exports: [Export.*] append to process-global registries (they run as
     top-level effects before [init], which freezes them into [table]). The
     C trampoline calls [dispatch idx] (registered under "sboa.dispatch")
     with the GIL released; [dispatch] re-takes it, reads the call's
     arguments, runs the entry inside a fresh callable scope, and on any
     OCaml exception sets the Python error indicator ([set_python_error]) and
     returns [None].

   The registries, the [Import.cached] table and the current callable scope
   are global mutable state by necessity (registration is a link-time
   effect; the cache is per process); registration is restricted to the main
   domain and everything else runs on the thread that initialized Python. *)

module B = Backend

type gil = unit

(* [Fun.protect] without its [Finally_raised] wrapping (the repo's rules
   forbid Fun.protect; sboa depends on no other library). *)
let protect ~finally f =
  match f () with
  | v ->
      finally ();
      v
  | exception e ->
      let bt = Printexc.get_raw_backtrace () in
      finally ();
      Printexc.raise_with_backtrace e bt

(* ------------------------------------------------------------------------ *)
(* Configuration *)
(* ------------------------------------------------------------------------ *)

module Config = struct
  type t = { extra_sys_path : string list; dev_overrides : string list }

  let default () = { extra_sys_path = []; dev_overrides = [] }

  let equal a b =
    List.equal String.equal a.extra_sys_path b.extra_sys_path
    && List.equal String.equal a.dev_overrides b.dev_overrides
end

(* ------------------------------------------------------------------------ *)
(* Errors *)
(* ------------------------------------------------------------------------ *)

module Python_error = struct
  type t = { ty : string; msg : string; traceback : string; exn : B.obj }

  let to_string t =
    if not (String.equal t.traceback "") then t.traceback
    else Printf.sprintf "%s: %s" t.ty t.msg
end

type path_elt = Field of string | Index of int | Arg of string | Key of string
type conv_error = { path : path_elt list; expected : string; got : string }

exception Python_error of Python_error.t
exception Conversion_error of conv_error
exception System_exit of int

let path_to_string path =
  path
  |> List.mapi (fun i elt ->
      match elt with
      | Arg a -> Printf.sprintf "argument '%s'" a
      | Field f -> if i = 0 then f else "." ^ f
      | Index n -> Printf.sprintf "[%d]" n
      | Key k -> Printf.sprintf "['%s']" k)
  |> String.concat ""

let conv_error_to_string e =
  match e.path with
  | [] -> Printf.sprintf "expected %s, got %s" e.expected e.got
  | path ->
      Printf.sprintf "%s: expected %s, got %s" (path_to_string path) e.expected
        e.got

let () =
  Printexc.register_printer (function
    | Python_error e -> Some ("Sboa.Python_error: " ^ Python_error.to_string e)
    | Conversion_error e ->
        Some ("Sboa.Conversion_error: " ^ conv_error_to_string e)
    | System_exit n -> Some (Printf.sprintf "Sboa.System_exit %d" n)
    | _ -> None)

(* Translate the Python exception a stub left pending. *)
let raise_pending () =
  let e = B.take_pending () in
  match B.exc_classify e with
  | Exc_system_exit -> raise (System_exit (B.exit_code e))
  | Exc_keyboard_interrupt -> raise Sys.Break
  | Exc_ocaml ->
      let exn, bt = B.resurrect e in
      Printexc.raise_with_backtrace exn bt
  | Exc_other ->
      let ty, msg, traceback = B.exc_info e in
      raise (Python_error { ty; msg; traceback; exn = e })

(* Drop a pending Python exception that a conversion turns into a
   [conv_error] instead. *)
let discard_pending () = ignore (B.take_pending ())

(* ------------------------------------------------------------------------ *)
(* Objects *)
(* ------------------------------------------------------------------------ *)

module Object = struct
  type t = B.obj

  let none = B.none
  let is_none = B.is_none
  let type_name () o = B.type_name o
  let refcount () o = B.refcount o

  let get_attr () o name =
    match B.get_attr o name with
    | r -> r
    | exception B.Pending -> raise_pending ()

  let set_attr () o name x =
    match B.set_attr o name x with
    | () -> ()
    | exception B.Pending -> raise_pending ()

  let call () f ?(args = [||]) ?(kwargs = []) () =
    let kwnames = Array.of_list (List.map fst kwargs) in
    let kwvals = Array.of_list (List.map snd kwargs) in
    match B.call f args kwnames kwvals with
    | r -> r
    | exception B.Pending -> raise_pending ()

  let call_method gil o name ?args ?kwargs () =
    call gil (get_attr gil o name) ?args ?kwargs ()

  let repr () o =
    match B.repr o with
    | s -> s
    | exception B.Pending -> raise_pending ()

  let str () o =
    match B.str o with
    | s -> s
    | exception B.Pending -> raise_pending ()

  (* Physical comparison on purpose: handles are custom blocks without
     structural equality, and only the shared [none] handle must survive
     [release] (other handles to None are released normally). *)
  let release () o =
    (* nosemgrep: physical-inequality *)
    if o != none then B.release o

  let with_ gil o f =
    match f o with
    | v ->
        release gil o;
        v
    | exception e ->
        (* release before anything that may poll (an async exception there
           would skip it) *)
        release gil o;
        Printexc.raise_with_backtrace e (Printexc.get_raw_backtrace ())
end

(* ------------------------------------------------------------------------ *)
(* Registries (frozen by [init]) *)
(* ------------------------------------------------------------------------ *)

type entry_fn = gil -> Object.t array -> (string * Object.t) list -> Object.t

(* Class methods and reprs receive the instance's OCaml value as [Obj.t]:
   the registries are heterogeneous in the class's type parameter. The
   casts back (see [Class]) are safe because the C side only returns the
   value of an instance whose type is exactly the class with that index, and
   only [Class.wrap] at that index (with the matching ['a Class.t]) creates
   such instances. *)
type entry_kind =
  | Function of entry_fn
  | Method of int * string * (Obj.t -> entry_fn)
  | Repr of int * string * (gil -> Obj.t -> string)

type entry = {
  e_module : string;
  e_name : string;
  e_doc : string;
  e_kind : entry_kind;
}

let frozen = Atomic.make false
let entries_rev : entry list Atomic.t = Atomic.make []
let n_entries = Atomic.make 0
let classes_rev : B.class_spec list Atomic.t = Atomic.make []
let n_classes = Atomic.make 0
let table : entry array Atomic.t = Atomic.make [||]

let exn_mappings_rev :
    (gil -> exn -> (string * Object.t array) option) list Atomic.t =
  Atomic.make []

let check_registration what =
  if not (Domain.is_main_domain ()) then
    invalid_arg (Printf.sprintf "Sboa.%s: only on the main domain" what);
  if Atomic.get frozen then
    invalid_arg (Printf.sprintf "Sboa.%s: must be called before Sboa.init" what)

let add_entry e =
  let i = Atomic.get n_entries in
  Atomic.set entries_rev (e :: Atomic.get entries_rev);
  Atomic.incr n_entries;
  i

let doc_with_signature ~name ~self ~doc = function
  | None -> doc
  | Some s ->
      Printf.sprintf "%s(%s%s)\n--\n\n%s" name self
        (if String.equal s "" then "" else ", " ^ s)
        doc

(* ------------------------------------------------------------------------ *)
(* Import *)
(* ------------------------------------------------------------------------ *)

module Pair_map = Map.Make (struct
  type t = string * string

  let compare (a1, b1) (a2, b2) =
    match String.compare a1 a2 with
    | 0 -> String.compare b1 b2
    | c -> c
end)

module Import = struct
  let module_ () name =
    match B.import name with
    | m -> m
    | exception B.Pending -> raise_pending ()

  let cache : Object.t Pair_map.t Atomic.t = Atomic.make Pair_map.empty

  let cached gil m a =
    match Pair_map.find_opt (m, a) (Atomic.get cache) with
    | Some o -> o
    | None ->
        let o = Object.get_attr gil (module_ gil m) a in
        Atomic.set cache (Pair_map.add (m, a) o (Atomic.get cache));
        o
end

(* ------------------------------------------------------------------------ *)
(* Bundles *)
(* ------------------------------------------------------------------------ *)

module Bundle = struct
  type data = B.data
  type t = { symbol : string; name : string; data : data }

  let of_incbin ~symbol ~name data = { symbol; name; data }
  let symbol t = t.symbol
  let name t = t.name
  let data t = t.data

  (* (priority, registration number, bundle) *)
  let registry : (int * int * t) list Atomic.t = Atomic.make []
  let count = Atomic.make 0

  let register ?(priority = 50) t =
    check_registration "Bundle.register";
    Atomic.set registry ((priority, Atomic.get count, t) :: Atomic.get registry);
    Atomic.incr count

  let registered () =
    Atomic.get registry
    |> List.sort (fun (p1, n1, _) (p2, n2, _) ->
        match Int.compare p1 p2 with
        | 0 -> Int.compare n1 n2
        | c -> c)
    |> List.map (fun (_, _, t) -> t)
end

(* ------------------------------------------------------------------------ *)
(* Lifecycle and GIL *)
(* ------------------------------------------------------------------------ *)

let is_initialized () = B.is_initialized () && not (B.init_failed ())

(* The configuration Python was started with (main thread only). *)
let started_with : Config.t option Atomic.t = Atomic.make None

let on_main_thread () =
  Domain.is_main_domain () && Thread.id (Thread.self ()) = 0

let init_args (c : Config.t) : B.init_args =
  let entries = Array.of_list (List.rev (Atomic.get entries_rev)) in
  let select f =
    entries |> Array.to_list |> List.mapi f |> List.filter_map Fun.id
  in
  {
    program_name = Sys.executable_name;
    sys_path = Array.of_list c.extra_sys_path;
    dev_overrides = Array.of_list c.dev_overrides;
    functions =
      select (fun i e ->
          match e.e_kind with
          | Function _ ->
              Some
                {
                  B.fn_module = e.e_module;
                  fn_name = e.e_name;
                  fn_doc = e.e_doc;
                  fn_index = i;
                }
          | Method _
          | Repr _ ->
              None)
      |> Array.of_list;
    classes = Array.of_list (List.rev (Atomic.get classes_rev));
    methods =
      select (fun i e ->
          match e.e_kind with
          | Method (cls, _, _) ->
              Some
                {
                  B.meth_class = cls;
                  meth_name = e.e_name;
                  meth_doc = e.e_doc;
                  meth_index = i;
                }
          | Function _
          | Repr _ ->
              None)
      |> Array.of_list;
    bundles =
      Bundle.registered ()
      |> List.map (fun (b : Bundle.t) -> (b.name, b.data))
      |> Array.of_list;
  }

let init (c : Config.t) =
  if B.init_failed () then failwith (B.init_error ());
  match Atomic.get started_with with
  | Some prev ->
      if not (Config.equal prev c) then
        invalid_arg
          "Sboa.init: Python is already initialized with a different \
           configuration (an earlier init, or with_gil's Config.default ())"
  | None ->
      if not (on_main_thread ()) then
        invalid_arg "Sboa.init: must run on the main thread of the main domain";
      let args = init_args c in
      Atomic.set table @@ Array.of_list (List.rev (Atomic.get entries_rev));
      protect
        ~finally:(fun () ->
          if B.is_initialized () then begin
            Atomic.set frozen true;
            Atomic.set started_with (Some c)
          end)
        (fun () -> B.init args)

let check_thread () =
  if not (Domain.is_main_domain () && B.thread_ok ()) then
    invalid_arg
      "Sboa: Python may only be used from the thread that initialized it (and \
       not in a forked child)"

let with_gil ?(keep_domain_lock = false) f =
  if B.init_failed () then failwith (B.init_error ());
  if not (B.is_initialized ()) then init (Config.default ());
  check_thread ();
  let st = B.gil_ensure keep_domain_lock in
  match f () with
  | v ->
      B.gil_release st;
      v
  | exception e ->
      (* release first: an async exception raised at a poll point before it
         would leave the GIL state unbalanced *)
      B.gil_release st;
      Printexc.raise_with_backtrace e (Printexc.get_raw_backtrace ())

let detach () f =
  B.save_thread ();
  match f () with
  | v ->
      B.restore_thread ();
      v
  | exception e ->
      B.restore_thread ();
      Printexc.raise_with_backtrace e (Printexc.get_raw_backtrace ())

let exit ~code =
  if is_initialized () && Domain.is_main_domain () && B.thread_ok () then begin
    (* Shutdown must reach [_exit] whatever happens in Python: [finish]
       reports Python errors itself (unraisable hook, atexit's own
       printing), and an exception here would leave the process running. *)
    let flushed =
      try with_gil (fun () -> B.finish ()) with
      | _ -> false
    in
    (* What [Stdlib.exit] does before terminating: OCaml at_exit handlers,
       including the flush of the standard channels. *)
    Stdlib.do_at_exit ();
    Unix._exit (if code = 0 && not flushed then 120 else code)
  end
  else Stdlib.exit code

let gc_flush () =
  if is_initialized () && Domain.is_main_domain () && B.thread_ok () then
    with_gil (fun () -> B.drain ())

let gc_collect () =
  match B.gc_collect () with
  | n -> n
  | exception B.Pending -> raise_pending ()

let eval () code =
  match B.eval code with
  | o -> o
  | exception B.Pending -> raise_pending ()

let exec () code =
  match B.exec code with
  | () -> ()
  | exception B.Pending -> raise_pending ()

(* ------------------------------------------------------------------------ *)
(* Callable scopes *)
(* ------------------------------------------------------------------------ *)

(* Each export call runs in a fresh scope, closed when it returns; Python
   callables converted during the call capture it. The root scope (outside
   any export call) is never closed. *)
type scope = { mutable live : bool }

let current_scope = Atomic.make { live = true }

(* ------------------------------------------------------------------------ *)
(* Conversions *)
(* ------------------------------------------------------------------------ *)

module Conv = struct
  type nonrec path_elt = path_elt =
    | Field of string
    | Index of int
    | Arg of string
    | Key of string

  type error = conv_error = {
    path : path_elt list;
    expected : string;
    got : string;
  }

  let error_to_string = conv_error_to_string

  type 'a to_py = gil -> 'a -> Object.t
  type 'a of_py = gil -> Object.t -> ('a, error) result
  type 'a t = { to_py : 'a to_py; of_py : 'a of_py; ty : string option }

  let make ?ty ~to_py ~of_py () = { to_py; of_py; ty }
  let to_py c = c.to_py
  let of_py c = c.of_py
  let ty c = c.ty

  let map ?ty decode encode c =
    {
      to_py = (fun gil x -> c.to_py gil (encode x));
      of_py = (fun gil o -> Result.map decode (c.of_py gil o));
      ty =
        (match ty with
        | Some _ -> ty
        | None -> c.ty);
    }

  let with_path elt (of_a : 'a of_py) : 'a of_py =
   fun gil o ->
    Result.map_error (fun e -> { e with path = elt :: e.path }) (of_a gil o)

  let prefix elt r =
    Result.map_error (fun e -> { e with path = elt :: e.path }) r

  let mismatch expected o = Error { path = []; expected; got = B.type_name o }

  (* Run a constructor stub, translating a pending Python error. *)
  let make_obj f x =
    match f x with
    | o -> o
    | exception B.Pending -> raise_pending ()

  let ty_of c = Option.value c.ty ~default:"object"

  let int =
    {
      ty = Some "int";
      to_py = (fun () i -> make_obj B.of_int i);
      of_py =
        (fun () o ->
          match B.kind o with
          | K_int -> (
              match B.to_int o with
              | i -> Ok i
              | exception B.Overflow ->
                  Error
                    {
                      path = [];
                      expected = "int in OCaml's range";
                      got = "int out of range";
                    })
          | _ -> mismatch "int" o);
    }

  let float =
    {
      ty = Some "float";
      to_py = (fun () f -> make_obj B.of_float f);
      of_py =
        (fun () o ->
          match B.kind o with
          | K_float
          | K_int -> (
              match B.to_float o with
              | f -> Ok f
              | exception B.Pending ->
                  discard_pending ();
                  Error
                    { path = []; expected = "float"; got = "int out of range" })
          | _ -> mismatch "float" o);
    }

  let bool =
    {
      ty = Some "bool";
      to_py = (fun () b -> make_obj B.of_bool b);
      of_py =
        (fun () o ->
          match B.kind o with
          | K_bool -> Ok (B.to_bool o)
          | _ -> mismatch "bool" o);
    }

  let string_of_str o =
    match B.to_string o with
    | s -> Ok s
    | exception B.Pending ->
        discard_pending ();
        Error
          {
            path = [];
            expected = "str encodable as UTF-8";
            got = "str with surrogates";
          }

  let string =
    {
      ty = Some "str";
      to_py =
        (fun () s ->
          match B.of_string s with
          | o -> o
          | exception B.Pending ->
              discard_pending ();
              raise
                (Conversion_error
                   {
                     path = [];
                     expected = "valid UTF-8";
                     got = "invalid UTF-8 bytes";
                   }));
      of_py =
        (fun () o ->
          match B.kind o with
          | K_str -> string_of_str o
          | _ -> mismatch "str" o);
    }

  let bytes =
    {
      ty = Some "bytes";
      to_py = (fun () s -> make_obj B.of_bytes s);
      of_py =
        (fun () o ->
          match B.kind o with
          | K_bytes -> Ok (B.to_bytes o)
          | _ -> mismatch "bytes" o);
    }

  let json =
    {
      ty = Some "bytes";
      to_py = bytes.to_py;
      of_py =
        (fun () o ->
          match B.kind o with
          | K_bytes -> Ok (B.to_bytes o)
          | K_str -> string_of_str o
          | _ -> mismatch "bytes" o);
    }

  let unit =
    {
      ty = Some "None";
      to_py = (fun () () -> Object.none);
      of_py = (fun () o -> if B.is_none o then Ok () else mismatch "None" o);
    }

  let object_ =
    { ty = Some "object"; to_py = (fun () o -> o); of_py = (fun () o -> Ok o) }

  (* Convert every item left to right; the first error wins. *)
  let items gil (of_a : 'a of_py) items =
    let n = Array.length items in
    let rec go i acc =
      if i >= n then Ok (List.rev acc)
      else
        match prefix (Index i) (of_a gil items.(i)) with
        | Ok x -> go (i + 1) (x :: acc)
        | Error e -> Error e
    in
    go 0 []

  let list a =
    {
      ty = Some (Printf.sprintf "list[%s]" (ty_of a));
      to_py =
        (fun gil l ->
          make_obj B.list_of_array (Array.of_list (List.map (a.to_py gil) l)));
      of_py =
        (fun gil o ->
          match B.kind o with
          | K_list
          | K_tuple ->
              items gil a.of_py (B.seq_items o)
          | _ -> mismatch "list" o);
    }

  let option a =
    {
      ty = Some (ty_of a ^ " | None");
      to_py =
        (fun gil -> function
          | None -> Object.none
          | Some x -> a.to_py gil x);
      of_py =
        (fun gil o ->
          if B.is_none o then Ok None
          else Result.map Option.some (a.of_py gil o));
    }

  let dict a =
    {
      ty = Some (Printf.sprintf "dict[str, %s]" (ty_of a));
      to_py =
        (fun gil l ->
          let keys = Array.of_list (List.map fst l) in
          let vals = Array.of_list (List.map (fun (_, v) -> a.to_py gil v) l) in
          match B.dict_of_arrays keys vals with
          | o -> o
          | exception B.Pending -> raise_pending ());
      of_py =
        (fun gil o ->
          match B.kind o with
          | K_dict ->
              let items = B.dict_items o in
              let n = Array.length items in
              let rec go i acc =
                if i >= n then Ok (List.rev acc)
                else
                  let k, v = items.(i) in
                  match B.kind k with
                  | K_str -> (
                      match string_of_str k with
                      | Error e -> Error e
                      | Ok key -> (
                          match prefix (Key key) (a.of_py gil v) with
                          | Ok x -> go (i + 1) ((key, x) :: acc)
                          | Error e -> Error e))
                  | _ ->
                      Error
                        {
                          path = [ Key (B.type_name k) ];
                          expected = "str key";
                          got = B.type_name k;
                        }
              in
              go 0 []
          | _ -> mismatch "dict" o);
    }

  (* Items of a tuple (or list) of exactly [n] elements. *)
  let fixed n gil o =
    match B.kind o with
    | K_tuple
    | K_list ->
        let items = B.seq_items o in
        if Array.length items = n then Ok items
        else
          Error
            {
              path = [];
              expected = Printf.sprintf "tuple of length %d" n;
              got = Printf.sprintf "length %d" (Array.length items);
            }
    | _ -> mismatch (Printf.sprintf "tuple of length %d" n) o
  [@@ocaml.warning "-27"]

  let ( let* ) = Result.bind

  let pair a b =
    {
      ty = Some (Printf.sprintf "tuple[%s, %s]" (ty_of a) (ty_of b));
      to_py =
        (fun gil (x, y) ->
          make_obj B.tuple_of_array [| a.to_py gil x; b.to_py gil y |]);
      of_py =
        (fun gil o ->
          let* it = fixed 2 gil o in
          let* x = prefix (Index 0) (a.of_py gil it.(0)) in
          let* y = prefix (Index 1) (b.of_py gil it.(1)) in
          Ok (x, y));
    }

  let tuple3 a b c =
    {
      ty =
        Some (Printf.sprintf "tuple[%s, %s, %s]" (ty_of a) (ty_of b) (ty_of c));
      to_py =
        (fun gil (x, y, z) ->
          make_obj B.tuple_of_array
            [| a.to_py gil x; b.to_py gil y; c.to_py gil z |]);
      of_py =
        (fun gil o ->
          let* it = fixed 3 gil o in
          let* x = prefix (Index 0) (a.of_py gil it.(0)) in
          let* y = prefix (Index 1) (b.of_py gil it.(1)) in
          let* z = prefix (Index 2) (c.of_py gil it.(2)) in
          Ok (x, y, z));
    }

  let of_py_exn c gil o =
    match c.of_py gil o with
    | Ok x -> x
    | Error e -> raise (Conversion_error e)

  let to_py_exn c gil x = c.to_py gil x

  let result_of gil (r : 'r t) o =
    match r.of_py gil o with
    | Ok x -> x
    | Error e ->
        raise (Conversion_error { e with path = Arg "<return>" :: e.path })

  (* [with_gil] is re-entrant, so these closures work both inside an export
     body that kept the GIL and after [detach]. The scope check makes a
     callable received by an export unusable once that call returned. *)
  let callable (k : Object.t -> 'f) : 'f of_py =
   fun () o -> if B.is_callable o then Ok (k o) else mismatch "callable" o

  let call_in_scope scope o args r =
    if not scope.live then
      invalid_arg
        "Sboa.Conv: Python callable used after the export call that received \
         it returned";
    with_gil (fun gil ->
        result_of gil r (Object.call gil o ~args:(args gil) ()))

  let func0 r =
    callable (fun o ->
        let scope = Atomic.get current_scope in
        fun () -> call_in_scope scope o (fun _ -> [||]) r)

  let func1 a r =
    callable (fun o ->
        let scope = Atomic.get current_scope in
        fun x -> call_in_scope scope o (fun gil -> [| a.to_py gil x |]) r)

  let func2 a b r =
    callable (fun o ->
        let scope = Atomic.get current_scope in
        fun x y ->
          call_in_scope scope o
            (fun gil -> [| a.to_py gil x; b.to_py gil y |])
            r)

  let func3 a b c r =
    callable (fun o ->
        let scope = Atomic.get current_scope in
        fun x y z ->
          call_in_scope scope o
            (fun gil -> [| a.to_py gil x; b.to_py gil y; c.to_py gil z |])
            r)

  let missing name =
    Conversion_error
      { path = [ Arg name ]; expected = "a value"; got = "nothing (missing)" }

  let arg gil name (of_a : 'a of_py) o =
    match prefix (Arg name) (of_a gil o) with
    | Ok x -> x
    | Error e -> raise (Conversion_error e)

  let positional gil ~name of_a args i =
    if i < Array.length args then arg gil name of_a args.(i)
    else raise (missing name)

  let find_kw name kwargs =
    List.find_map
      (fun (k, o) -> if String.equal k name then Some o else None)
      kwargs

  let keyword gil ~name of_a kwargs =
    match find_kw name kwargs with
    | Some o -> arg gil name of_a o
    | None -> raise (missing name)

  let keyword_opt gil ~name of_a kwargs =
    match find_kw name kwargs with
    | None -> None
    | Some o when B.is_none o -> None
    | Some o -> Some (arg gil name of_a o)

  let check_arity ~max_positional ~keywords args kwargs =
    let n = Array.length args in
    if n > max_positional then
      raise
        (Conversion_error
           {
             path = [];
             expected =
               Printf.sprintf "at most %d positional arguments" max_positional;
             got = string_of_int n;
           });
    List.iter
      (fun (k, _) ->
        if not (List.exists (String.equal k) keywords) then
          raise
            (Conversion_error
               {
                 path = [];
                 expected =
                   Printf.sprintf "keyword arguments among [%s]"
                     (String.concat ", " keywords);
                 got = Printf.sprintf "'%s'" k;
               }))
      kwargs
end

(* ------------------------------------------------------------------------ *)
(* Classes and exports *)
(* ------------------------------------------------------------------------ *)

(* See the comment on [entry_kind] for why these casts are safe. *)
let value_of_obj (v : Obj.t) : 'a = Obj.obj v
let obj_of_value (v : 'a) : Obj.t = Obj.repr v

module Class = struct
  type 'a t = {
    index : int;
    module_ : string;
    name : string;
    mutable imported : bool;
  }

  let name c = c.name

  let wrap gil c (v : 'a) =
    if not c.imported then begin
      ignore (Import.module_ gil c.module_);
      c.imported <- true
    end;
    match B.class_wrap c.index (obj_of_value v) with
    | o -> o
    | exception B.Pending -> raise_pending ()

  let unwrap c : 'a Conv.of_py =
   fun () o ->
    match B.class_unwrap c.index o with
    | Some v -> Ok (value_of_obj v : 'a)
    | None ->
        Error
          {
            path = [];
            expected = c.module_ ^ "." ^ c.name;
            got = B.type_name o;
          }

  let conv c : 'a Conv.t =
    Conv.make
      ~ty:(c.module_ ^ "." ^ c.name)
      ~to_py:(fun gil v -> wrap gil c v)
      ~of_py:(unwrap c) ()
end

(* A counter is the address of the atomic inside a [_sboa.Counter]
   instance plus an owned handle on that instance, so the Python object (and
   the address) stays valid as long as the OCaml value is reachable, even
   after the export call that received it returned and released its
   argument handles. The handle is released by its finalizer (deferred,
   safe from any domain). *)
module Counter = struct
  (* [owner] is never read: it only keeps the Python object alive. *)
  type t = { owner : Object.t; ptr : nativeint } [@@warning "-69"]

  let of_py : t Conv.of_py =
   fun () o ->
    match B.counter_ptr o with
    | 0n -> Error { path = []; expected = "Counter"; got = B.type_name o }
    | ptr -> Ok { owner = B.new_ref o; ptr }

  let of_object gil o =
    match of_py gil o with
    | Ok t -> t
    | Error e -> raise (Conversion_error e)

  let add t n = B.counter_add t.ptr n
  let incr t = add t 1
  let set t n = B.counter_set t.ptr n
  let get t = B.counter_get t.ptr
end

module Export = struct
  type fn = entry_fn

  let register ~module_ ~name ?(doc = "") ?signature (f : fn) =
    check_registration "Export.register";
    ignore
      (add_entry
         {
           e_module = module_;
           e_name = name;
           e_doc = doc_with_signature ~name ~self:"$module" ~doc signature;
           e_kind = Function f;
         })

  let add_method (c : 'a Class.t) ~name ?(doc = "") ?signature (m : 'a -> fn) =
    check_registration "Export.add_method";
    ignore
      (add_entry
         {
           e_module = c.module_;
           e_name = name;
           e_doc = doc_with_signature ~name ~self:"$module, self" ~doc signature;
           e_kind =
             Method
               ( c.index,
                 c.module_ ^ "." ^ c.name,
                 fun v -> m (value_of_obj v : 'a) );
         })

  let register_class ~module_ ~name ?(doc = "")
      ?(methods : (string * ('a -> fn)) list = [])
      ?(repr : (gil -> 'a -> string) option) () : 'a Class.t =
    check_registration "Export.register_class";
    let c =
      { Class.index = Atomic.get n_classes; module_; name; imported = false }
    in
    List.iter (fun (mname, m) -> add_method c ~name:mname m) methods;
    let cls_repr =
      match repr with
      | None -> -1
      | Some r ->
          add_entry
            {
              e_module = module_;
              e_name = "__repr__";
              e_doc = "";
              e_kind =
                Repr
                  ( c.index,
                    module_ ^ "." ^ name,
                    fun gil v -> r gil (value_of_obj v : 'a) );
            }
    in
    Atomic.set classes_rev
      ({ B.cls_module = module_; cls_name = name; cls_doc = doc; cls_repr }
      :: Atomic.get classes_rev);
    Atomic.incr n_classes;
    c

  let register_exn_mapping f =
    check_registration "Export.register_exn_mapping";
    Atomic.set exn_mappings_rev (f :: Atomic.get exn_mappings_rev)
end

(* Python class from a dotted name ("pkg.mod.Class"). *)
let class_of_dotted gil dotted =
  match String.rindex_opt dotted '.' with
  | None -> Import.cached gil "builtins" dotted
  | Some i ->
      Import.cached gil (String.sub dotted 0 i)
        (String.sub dotted (i + 1) (String.length dotted - i - 1))

let set_error_ocaml e bt =
  let msg =
    match Printexc.raw_backtrace_to_string bt with
    | "" -> Printexc.to_string e
    | trace -> Printexc.to_string e ^ "\nOCaml backtrace:\n" ^ trace
  in
  B.set_error_ocaml msg (e, bt)

exception Mapping_interrupted

(* The first registered mapping that applies. A mapping that raises is
   skipped; one interrupted by Sys.Break turns the error into
   KeyboardInterrupt (the interrupt must not be lost). *)
let find_mapping gil e =
  List.rev (Atomic.get exn_mappings_rev)
  |> List.find_map (fun f ->
      match f gil e with
      | r -> r
      | exception Sys.Break -> raise Mapping_interrupted
      | exception _ -> None)

(* OCaml exception escaping an export -> Python error indicator. *)
let set_python_error gil e bt =
  match e with
  | Python_error pe -> B.set_error_obj pe.exn
  | System_exit code -> B.set_error_system_exit code
  | Conversion_error ce ->
      B.set_error_builtin "TypeError" (conv_error_to_string ce)
  | Sys.Break -> B.set_error_builtin "KeyboardInterrupt" ""
  | _ -> (
      let mapped =
        match find_mapping gil e with
        | None -> None
        | Some (cls, args) -> (
            match class_of_dotted gil cls with
            | c -> Some (c, args)
            | exception _ -> None)
        | exception Mapping_interrupted ->
            Some (class_of_dotted gil "KeyboardInterrupt", [||])
      in
      match (mapped, e) with
      | Some (c, args), _ -> B.set_error_class c (B.tuple_of_array args)
      | None, Out_of_memory -> B.set_error_builtin "MemoryError" ""
      | None, Stack_overflow ->
          B.set_error_builtin "RecursionError" "OCaml stack overflow"
      | None, _ -> set_error_ocaml e bt)

let unwrap_self cls qualified args =
  if Array.length args = 0 then
    raise
      (Conversion_error
         { path = [ Arg "self" ]; expected = qualified; got = "nothing" })
  else
    match B.class_unwrap cls args.(0) with
    | Some v -> v
    | None ->
        raise
          (Conversion_error
             {
               path = [ Arg "self" ];
               expected = qualified;
               got = B.type_name args.(0);
             })

let run_entry gil entry args kwargs =
  match entry.e_kind with
  | Function f -> f gil args kwargs
  | Method (cls, qualified, m) ->
      let self = unwrap_self cls qualified args in
      m self gil (Array.sub args 1 (Array.length args - 1)) kwargs
  | Repr (cls, qualified, r) ->
      let self = unwrap_self cls qualified args in
      Conv.to_py Conv.string gil (r gil self)

(* Called by the C trampoline (GIL released, domain lock held). Never
   raises: errors become the Python error indicator and [None]. Argument
   handles are released when the entry returns (except one returned as the
   result), so Python objects passed to OCaml do not wait for the OCaml GC;
   the callable scope opened here is closed at the same point. *)
let dispatch (idx : int) : Object.t option =
  with_gil (fun gil ->
      let scope = { live = true } in
      let outer = Atomic.get current_scope in
      Atomic.set current_scope scope;
      let close () =
        scope.live <- false;
        Atomic.set current_scope outer
      in
      match B.frame_args () with
      | exception e ->
          close ();
          set_python_error gil e (Printexc.get_raw_backtrace ());
          None
      | all -> (
          match
            let kwnames = B.frame_kwnames () in
            let nk = Array.length kwnames in
            let np = Array.length all - nk in
            let args = Array.sub all 0 np in
            let kwargs = List.init nk (fun i -> (kwnames.(i), all.(np + i))) in
            run_entry gil (Atomic.get table).(idx) args kwargs
          with
          | r ->
              close ();
              B.release_args all r;
              Some r
          | exception e ->
              close ();
              let bt = Printexc.get_raw_backtrace () in
              B.release_args all Object.none;
              set_python_error gil e bt;
              None))

let () = Callback.register "sboa.dispatch" dispatch

module Debug = struct
  let pending_decrefs = B.pending_decrefs
  let live_roots = B.live_roots
end
