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
(* pyembed.cpython implementation of the [Backend] primitives: every value is
   a C stub in pyembed_{runtime,object,export}.c. See backend.mli for the
   contract. *)

type obj

type data =
  (char, Bigarray.int8_unsigned_elt, Bigarray.c_layout) Bigarray.Array1.t

exception Pending
exception Overflow
exception Not_available

let () =
  Callback.register_exception "pyembed.pending" Pending;
  Callback.register_exception "pyembed.overflow" Overflow

type fn_spec = {
  fn_module : string;
  fn_name : string;
  fn_doc : string;
  fn_index : int;
}

type class_spec = {
  cls_module : string;
  cls_name : string;
  cls_doc : string;
  cls_repr : int;
}

type method_spec = {
  meth_class : int;
  meth_name : string;
  meth_doc : string;
  meth_index : int;
}

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
  bundles : (string * data) array;
}

type kind =
  | K_none
  | K_bool
  | K_int
  | K_float
  | K_str
  | K_bytes
  | K_list
  | K_tuple
  | K_dict
  | K_other

type exc_class =
  | Exc_other
  | Exc_system_exit
  | Exc_keyboard_interrupt
  | Exc_ocaml

external init : init_args -> unit = "pyembed_init"
external is_initialized : unit -> bool = "pyembed_is_initialized" [@@noalloc]
external init_failed : unit -> bool = "pyembed_init_failed" [@@noalloc]
external init_error : unit -> string = "pyembed_init_error"
external thread_ok : unit -> bool = "pyembed_thread_ok" [@@noalloc]
external gil_ensure : bool -> int = "pyembed_gil_ensure"
external gil_release : int -> unit = "pyembed_gil_release"
external save_thread : unit -> unit = "pyembed_save_thread"
external restore_thread : unit -> unit = "pyembed_restore_thread"
external drain : unit -> unit = "pyembed_drain"
external pending_decrefs : unit -> int = "pyembed_pending_decrefs" [@@noalloc]
external live_roots : unit -> int = "pyembed_live_roots" [@@noalloc]
external gc_collect : unit -> int = "pyembed_gc_collect"
external finish : unit -> bool = "pyembed_finish"
external none_ : unit -> obj = "pyembed_none"

let none = none_ ()

external is_none : obj -> bool = "pyembed_is_none" [@@noalloc]
external release : obj -> unit = "pyembed_release"
external release_args : obj array -> obj -> unit = "pyembed_release_args"
external refcount : obj -> int = "pyembed_refcount"
external type_name : obj -> string = "pyembed_type_name"
external is_callable : obj -> bool = "pyembed_is_callable"
external import : string -> obj = "pyembed_import"
external get_attr : obj -> string -> obj = "pyembed_get_attr"
external set_attr : obj -> string -> obj -> unit = "pyembed_set_attr"

external call : obj -> obj array -> string array -> obj array -> obj
  = "pyembed_call"

external repr : obj -> string = "pyembed_repr"
external str : obj -> string = "pyembed_str"
external eval : string -> obj = "pyembed_eval"
external exec : string -> unit = "pyembed_exec"
external kind : obj -> kind = "pyembed_kind"
external of_int : int -> obj = "pyembed_of_int"
external to_int : obj -> int = "pyembed_to_int"
external of_float : float -> obj = "pyembed_of_float"
external to_float : obj -> float = "pyembed_to_float"
external of_bool : bool -> obj = "pyembed_of_bool"
external to_bool : obj -> bool = "pyembed_to_bool"
external of_string : string -> obj = "pyembed_of_string"
external to_string : obj -> string = "pyembed_to_string"
external of_bytes : string -> obj = "pyembed_of_bytes"
external to_bytes : obj -> string = "pyembed_to_bytes"
external list_of_array : obj array -> obj = "pyembed_list_of_array"
external tuple_of_array : obj array -> obj = "pyembed_tuple_of_array"
external seq_items : obj -> obj array = "pyembed_seq_items"

external dict_of_arrays : string array -> obj array -> obj
  = "pyembed_dict_of_arrays"

external dict_items : obj -> (obj * obj) array = "pyembed_dict_items"
external take_pending : unit -> obj = "pyembed_take_pending"
external exc_classify : obj -> exc_class = "pyembed_exc_classify"
external exc_info : obj -> string * string * string = "pyembed_exc_info"
external exit_code : obj -> int = "pyembed_exit_code"
external resurrect : obj -> exn * Printexc.raw_backtrace = "pyembed_resurrect"
external set_error_obj : obj -> unit = "pyembed_set_error_obj"

external set_error_builtin : string -> string -> unit
  = "pyembed_set_error_builtin"

external set_error_class : obj -> obj -> unit = "pyembed_set_error_class"
external set_error_system_exit : int -> unit = "pyembed_set_error_system_exit"

external set_error_ocaml : string -> exn * Printexc.raw_backtrace -> unit
  = "pyembed_set_error_ocaml"

external frame_args : unit -> obj array = "pyembed_frame_args"
external frame_kwnames : unit -> string array = "pyembed_frame_kwnames"
external class_wrap : int -> Obj.t -> obj = "pyembed_class_wrap"
external class_unwrap : int -> obj -> Obj.t option = "pyembed_class_unwrap"
external counter_ptr : obj -> nativeint = "pyembed_counter_ptr"
external new_ref : obj -> obj = "pyembed_new_ref"

external counter_add : (nativeint[@unboxed]) -> (int[@untagged]) -> unit
  = "pyembed_counter_add" "pyembed_counter_add_native"
[@@noalloc]

external counter_set : (nativeint[@unboxed]) -> (int[@untagged]) -> unit
  = "pyembed_counter_set" "pyembed_counter_set_native"
[@@noalloc]

external counter_get : (nativeint[@unboxed]) -> (int[@untagged])
  = "pyembed_counter_get" "pyembed_counter_get_native"
[@@noalloc]
