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

let stdlib = Sys.getenv "PYEMBED_STDLIB"

let fail fmt =
  Printf.ksprintf
    (fun s ->
      prerr_endline ("importer: " ^ s);
      Stdlib.exit 1)
    fmt

let check_ok () =
  let r =
    Pyembed.with_gil (fun gil ->
        Pyembed.exec gil
          "import sys, demopkg, demopkg.mod\n\
           finder = [f for f in sys.meta_path if type(f).__name__ == \
           'PyembedFinder']\n\
           result = '|'.join([demopkg.GREETING, demopkg.mod.where(), \
           str(len(finder))])\n";
        Pyembed.Conv.of_py_exn Pyembed.Conv.string gil
          (Pyembed.eval gil "result"))
  in
  let expected = "hello from the bundle|<pyembed:demo>/demopkg/mod.py|1" in
  if String.equal r expected then print_endline ("importer: ok: " ^ r)
  else fail "expected %S, got %S" expected r

let check_refused mode =
  match
    Pyembed.init
      { (Pyembed.Config.default ()) with extra_sys_path = [ stdlib ] }
  with
  | () -> fail "%s bundle accepted" mode
  | exception Failure first -> (
      match Pyembed.with_gil (fun _ -> ()) with
      | () -> fail "%s: Python usable after a failed init" mode
      | exception Failure again when String.equal first again ->
          let line =
            match String.split_on_char '\n' first with
            | l :: _ -> l
            | [] -> first
          in
          Printf.printf "importer: %s bundle refused: %s\n" mode line
      | exception e -> fail "%s: %s" mode (Printexc.to_string e))

(* The external-prefix fallback for C extension modules: the stdlib alone is
   on sys.path (not its lib-dynload), so an extension module can only come
   from the bundle importer's libdynload_dir, here
   Pyembed_toolchain.libdynload_dir (). Only meaningful when the toolchain
   is an external CPython (PYEMBED_PREFIX) with extension modules. *)
let check_dynload () =
  match Pyembed_toolchain.external_libdynload_dir with
  | None ->
      print_endline
        "importer: dynload: skipped (the toolchain has no external lib-dynload)"
  | Some ext -> (
      let candidates =
        Sys.readdir ext |> Array.to_list
        |> List.filter (fun f ->
            String.starts_with ~prefix:"_dbm." f
            || String.starts_with ~prefix:"math." f)
        |> List.sort String.compare
      in
      match candidates with
      | [] ->
          print_endline
            ("importer: dynload: skipped (no _dbm or math extension in " ^ ext
           ^ ")")
      | f :: _ ->
          let modname =
            match String.index_opt f '.' with
            | Some i -> String.sub f 0 i
            | None -> f
          in
          (match Pyembed_toolchain.libdynload_dir () with
          | Some d when String.equal d ext -> ()
          | _ -> fail "dynload: libdynload_dir () is not %s" ext);
          Pyembed.init
            {
              (Pyembed.Config.default ()) with
              extra_sys_path = [ stdlib ];
              libdynload_dir = Pyembed_toolchain.libdynload_dir ();
            };
          let file =
            Pyembed.with_gil (fun gil ->
                Pyembed.exec gil
                  (Printf.sprintf "import %s\nresult = %s.__file__\n" modname
                     modname);
                Pyembed.Conv.of_py_exn Pyembed.Conv.string gil
                  (Pyembed.eval gil "result"))
          in
          if String.starts_with ~prefix:ext file then
            Printf.printf "importer: dynload: ok: %s from %s\n" modname file
          else fail "dynload: %s loaded from %s, not %s" modname file ext)

let () =
  assert (String.equal (Pyembed.Bundle.name Demo_bundle.bundle) "demo");
  let demo = Pyembed.Bundle.data Demo_bundle.bundle in
  match Sys.argv with
  | [| _; "empty" |] ->
      Pyembed.Bundle.register
        (Pyembed.Bundle.of_incbin ~symbol:"none" ~name:"empty"
           (Bigarray.Array1.create Bigarray.char Bigarray.c_layout 0));
      check_refused "empty"
  | [| _; "truncated" |] ->
      Pyembed.Bundle.register
        (Pyembed.Bundle.of_incbin ~symbol:"demo_bundle" ~name:"truncated"
           (Bigarray.Array1.sub demo 0 (Bigarray.Array1.dim demo / 2)));
      check_refused "truncated"
  | [| _; "dynload" |] -> check_dynload ()
  | _ ->
      Pyembed.init
        { (Pyembed.Config.default ()) with extra_sys_path = [ stdlib ] };
      check_ok ()
