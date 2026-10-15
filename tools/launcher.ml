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
(* sboa-bundle: runs sboa_bundle.py under the CPython sboa was built
   against (Build_python.path, written by ../config/discover.ml), so that
   dune rules need no Python of their own: [(run %{bin:sboa-bundle} ...)].
   The script re-runs itself under the interpreter of [--config] when that
   is another one.

   The script is lib/sboa/sboa_bundle.py next to bin/ (an installed sboa),
   else sboa_bundle.py next to the real executable (inside a dune workspace,
   where the [link_deps] of the executable put it). *)

let script () =
  let exe = Sys.executable_name in
  let installed =
    Filename.concat
      (Filename.dirname (Filename.dirname exe))
      (Filename.concat "lib" (Filename.concat "sboa" "sboa_bundle.py"))
  in
  let sibling () =
    match Unix.realpath exe with
    | real -> [ Filename.concat (Filename.dirname real) "sboa_bundle.py" ]
    | exception Unix.Unix_error _ -> []
  in
  List.find_opt Sys.file_exists (installed :: sibling ())

let () =
  match script () with
  | None ->
      prerr_endline
        "sboa-bundle: cannot find sboa_bundle.py (lib/sboa/ of the \
         installation)";
      exit 2
  | Some script -> (
      let python = Build_python.path in
      let args =
        Array.append [| python; "-I"; script |]
          (Array.sub Sys.argv 1 (Array.length Sys.argv - 1))
      in
      if Sys.win32 then (
        match
          Unix.create_process python args Unix.stdin Unix.stdout Unix.stderr
        with
        | pid -> (
            match snd (Unix.waitpid [] pid) with
            | Unix.WEXITED n -> exit n
            | Unix.WSIGNALED _
            | Unix.WSTOPPED _ ->
                exit 2)
        | exception Unix.Unix_error (e, _, _) ->
            prerr_endline
              ("sboa-bundle: cannot run " ^ python ^ ": " ^ Unix.error_message e);
            exit 2)
      else
        try Unix.execv python args with
        | Unix.Unix_error (e, _, _) ->
            prerr_endline
              ("sboa-bundle: cannot run " ^ python ^ ": " ^ Unix.error_message e);
            exit 2)
