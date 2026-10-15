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
(* The application of the README recipe: no sys.path at all; the stdlib
   comes from the embedded bundle through the frozen importer, and
   `encodings` from the frozen table. *)

let () =
  Sboa.init (Sboa.Config.default ());
  let r =
    Sboa.with_gil (fun gil ->
        Sboa.exec gil
          "import sys, json, collections, encodings\n\
           result = '|'.join([\n\
          \    str(sys.path),\n\
          \    json.__spec__.origin,\n\
          \    encodings.__spec__.origin,\n\
          \    sys.modules['_sboa_importer'].__spec__.origin,\n\
          \    json.dumps(collections.OrderedDict(a=1)),\n\
           ])\n";
        Sboa.Conv.of_py_exn Sboa.Conv.string gil (Sboa.eval gil "result"))
  in
  let expected = "[]|<sboa:stdlib>/json/__init__.py|frozen|frozen|{\"a\": 1}" in
  if String.equal r expected then print_endline ("recipe: ok: " ^ r)
  else (
    prerr_endline (Printf.sprintf "recipe: expected %S, got %S" expected r);
    exit 1)
