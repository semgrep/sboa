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
(* The [Backend] primitives: every value is a C stub in
   sboa_{runtime,object,export}.c. See backend.mli for the contract. *)

type obj

type data =
  (char, Bigarray.int8_unsigned_elt, Bigarray.c_layout) Bigarray.Array1.t

exception Pending
exception Overflow

let () =
  Callback.register_exception "sboa.pending" Pending;
  Callback.register_exception "sboa.overflow" Overflow

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
  sys_path : string array;
  dev_overrides : string array;
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

external init : init_args -> unit = "sboa_init"
external is_initialized : unit -> bool = "sboa_is_initialized" [@@noalloc]
external init_failed : unit -> bool = "sboa_init_failed" [@@noalloc]
external init_error : unit -> string = "sboa_init_error"
external thread_ok : unit -> bool = "sboa_thread_ok" [@@noalloc]
external gil_ensure : bool -> int = "sboa_gil_ensure"
external gil_release : int -> unit = "sboa_gil_release"
external save_thread : unit -> unit = "sboa_save_thread"
external restore_thread : unit -> unit = "sboa_restore_thread"
external drain : unit -> unit = "sboa_drain"
external pending_decrefs : unit -> int = "sboa_pending_decrefs" [@@noalloc]
external live_roots : unit -> int = "sboa_live_roots" [@@noalloc]
external gc_collect : unit -> int = "sboa_gc_collect"
external finish : unit -> bool = "sboa_finish"
external none_ : unit -> obj = "sboa_none"

let none = none_ ()

external is_none : obj -> bool = "sboa_is_none" [@@noalloc]
external release : obj -> unit = "sboa_release"
external release_args : obj array -> obj -> unit = "sboa_release_args"
external refcount : obj -> int = "sboa_refcount"
external type_name : obj -> string = "sboa_type_name"
external is_callable : obj -> bool = "sboa_is_callable"
external import : string -> obj = "sboa_import"
external get_attr : obj -> string -> obj = "sboa_get_attr"
external set_attr : obj -> string -> obj -> unit = "sboa_set_attr"

external call : obj -> obj array -> string array -> obj array -> obj
  = "sboa_call"

external repr : obj -> string = "sboa_repr"
external str : obj -> string = "sboa_str"
external eval : string -> obj = "sboa_eval"
external exec : string -> unit = "sboa_exec"
external kind : obj -> kind = "sboa_kind"
external of_int : int -> obj = "sboa_of_int"
external to_int : obj -> int = "sboa_to_int"
external of_float : float -> obj = "sboa_of_float"
external to_float : obj -> float = "sboa_to_float"
external of_bool : bool -> obj = "sboa_of_bool"
external to_bool : obj -> bool = "sboa_to_bool"
external of_string : string -> obj = "sboa_of_string"
external to_string : obj -> string = "sboa_to_string"
external of_bytes : string -> obj = "sboa_of_bytes"
external to_bytes : obj -> string = "sboa_to_bytes"
external list_of_array : obj array -> obj = "sboa_list_of_array"
external tuple_of_array : obj array -> obj = "sboa_tuple_of_array"
external seq_items : obj -> obj array = "sboa_seq_items"

external dict_of_arrays : string array -> obj array -> obj
  = "sboa_dict_of_arrays"

external dict_items : obj -> (obj * obj) array = "sboa_dict_items"
external take_pending : unit -> obj = "sboa_take_pending"
external exc_classify : obj -> exc_class = "sboa_exc_classify"
external exc_info : obj -> string * string * string = "sboa_exc_info"
external exit_code : obj -> int = "sboa_exit_code"
external resurrect : obj -> exn * Printexc.raw_backtrace = "sboa_resurrect"
external set_error_obj : obj -> unit = "sboa_set_error_obj"
external set_error_builtin : string -> string -> unit = "sboa_set_error_builtin"
external set_error_class : obj -> obj -> unit = "sboa_set_error_class"
external set_error_system_exit : int -> unit = "sboa_set_error_system_exit"

external set_error_ocaml : string -> exn * Printexc.raw_backtrace -> unit
  = "sboa_set_error_ocaml"

external set_error_ocaml_obj : obj -> exn * Printexc.raw_backtrace -> unit
  = "sboa_set_error_ocaml_obj"

external frame_args : unit -> obj array = "sboa_frame_args"
external frame_kwnames : unit -> string array = "sboa_frame_kwnames"
external class_wrap : int -> Obj.t -> obj = "sboa_class_wrap"
external class_unwrap : int -> obj -> Obj.t option = "sboa_class_unwrap"
external counter_ptr : obj -> nativeint = "sboa_counter_ptr"
external new_ref : obj -> obj = "sboa_new_ref"

external counter_add : (nativeint[@unboxed]) -> (int[@untagged]) -> unit
  = "sboa_counter_add" "sboa_counter_add_native"
[@@noalloc]

external counter_set : (nativeint[@unboxed]) -> (int[@untagged]) -> unit
  = "sboa_counter_set" "sboa_counter_set_native"
[@@noalloc]

external counter_get : (nativeint[@unboxed]) -> (int[@untagged])
  = "sboa_counter_get" "sboa_counter_get_native"
[@@noalloc]
