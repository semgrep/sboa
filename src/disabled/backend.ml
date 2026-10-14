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
(* pyembed.disabled implementation of the [Backend] primitives: no
   interpreter; every primitive that would need one raises [Not_available].
   [is_initialized] is always false, so [Pyembed.exit] falls back to
   [Stdlib.exit] and [Pyembed.gc_flush] does nothing. *)

type obj = unit

type data =
  (char, Bigarray.int8_unsigned_elt, Bigarray.c_layout) Bigarray.Array1.t

exception Pending
exception Overflow
exception Not_available

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

let na _ = raise Not_available
let init _ = raise Not_available
let is_initialized () = false
let init_failed () = false
let init_error () = ""
let thread_ok () = true
let gil_ensure _ = raise Not_available
let gil_release _ = raise Not_available
let save_thread = na
let restore_thread = na
let drain () = ()
let pending_decrefs () = 0
let live_roots () = 0
let gc_collect = na
let finish = na
let none = ()
let is_none () = true
let release = na
let release_args _ _ = raise Not_available
let refcount = na
let type_name = na
let is_callable = na
let import = na
let get_attr _ _ = raise Not_available
let set_attr _ _ _ = raise Not_available
let call _ _ _ _ = raise Not_available
let repr = na
let str = na
let eval = na
let exec = na
let kind = na
let of_int = na
let to_int = na
let of_float = na
let to_float = na
let of_bool = na
let to_bool = na
let of_string = na
let to_string = na
let of_bytes = na
let to_bytes = na
let list_of_array = na
let tuple_of_array = na
let seq_items = na
let dict_of_arrays _ _ = raise Not_available
let dict_items = na
let take_pending = na
let exc_classify = na
let exc_info = na
let exit_code = na
let resurrect = na
let set_error_obj = na
let set_error_builtin _ _ = raise Not_available
let set_error_class _ _ = raise Not_available
let set_error_system_exit = na
let set_error_ocaml _ _ = raise Not_available
let frame_args = na
let frame_kwnames = na
let class_wrap _ _ = raise Not_available
let class_unwrap _ _ = raise Not_available
