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
(* Start Python with the generated frozen importer and one generated bundle,
   then import a package that exists only in the bundle (mode "ok"); or add a
   broken bundle (modes "empty", "truncated") and check that init fails
   cleanly and Python stays refused afterwards. Exits non-zero on any
   mismatch. *)

let stdlib = Sys.getenv "SBOA_STDLIB"

let fail fmt =
  Printf.ksprintf
    (fun s ->
      prerr_endline ("importer: " ^ s);
      Stdlib.exit 1)
    fmt

let check_ok () =
  let r =
    Sboa.with_gil (fun gil ->
        Sboa.exec gil
          "import sys, demopkg, demopkg.mod\n\
           finder = [f for f in sys.meta_path if type(f).__name__ == \
           'SboaFinder']\n\
           result = '|'.join([demopkg.GREETING, demopkg.mod.where(), \
           str(len(finder))])\n";
        Sboa.Conv.of_py_exn Sboa.Conv.string gil (Sboa.eval gil "result"))
  in
  let expected = "hello from the bundle|<sboa:demo>/demopkg/mod.py|1" in
  if String.equal r expected then print_endline ("importer: ok: " ^ r)
  else fail "expected %S, got %S" expected r

let check_refused mode =
  match
    Sboa.init { (Sboa.Config.default ()) with extra_sys_path = [ stdlib ] }
  with
  | () -> fail "%s bundle accepted" mode
  | exception Failure first -> (
      match Sboa.with_gil (fun _ -> ()) with
      | () -> fail "%s: Python usable after a failed init" mode
      | exception Failure again when String.equal first again ->
          let line =
            match String.split_on_char '\n' first with
            | l :: _ -> l
            | [] -> first
          in
          Printf.printf "importer: %s bundle refused: %s\n" mode line
      | exception e -> fail "%s: %s" mode (Printexc.to_string e))

let () =
  assert (String.equal (Sboa.Bundle.name Demo_bundle.bundle) "demo");
  let demo = Sboa.Bundle.data Demo_bundle.bundle in
  match Sys.argv with
  | [| _; "empty" |] ->
      Sboa.Bundle.register
        (Sboa.Bundle.of_incbin ~symbol:"none" ~name:"empty"
           (Bigarray.Array1.create Bigarray.char Bigarray.c_layout 0));
      check_refused "empty"
  | [| _; "truncated" |] ->
      Sboa.Bundle.register
        (Sboa.Bundle.of_incbin ~symbol:"demo_bundle" ~name:"truncated"
           (Bigarray.Array1.sub demo 0 (Bigarray.Array1.dim demo / 2)));
      check_refused "truncated"
  | _ ->
      (* The stdlib and, for a CPython that keeps extension modules in
         lib-dynload (zlib among them on nix), that directory come from
         sys.path; only demopkg comes through the importer. *)
      Sboa.init
        {
          (Sboa.Config.default ()) with
          extra_sys_path = [ stdlib; Filename.concat stdlib "lib-dynload" ];
        };
      check_ok ()
