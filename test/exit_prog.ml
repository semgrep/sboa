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
(* Child process for the exit and init-failure tests (Pyembed.exit and a
   failed init both end or poison the process). Modes (first argument):
   - exit: leaves unflushed output in Python's sys.stdout and OCaml's stdout,
     registers Python and OCaml exit handlers, exits with code 3;
   - threads: a non-daemon Python thread must finish before the exit;
   - flush-fail: sys.stdout cannot be flushed, so ~code:0 becomes 120;
   - init-fail: start-up fails; later init/with_gil re-raise the same
     failure without retrying. *)

let stdlib = Sys.getenv "PYEMBED_STDLIB"

let config () =
  {
    (Pyembed.Config.default ()) with
    extra_sys_path = [ stdlib; Filename.concat stdlib "lib-dynload" ];
  }

let exec code = Pyembed.with_gil (fun gil -> Pyembed.exec gil code)

let init_fail () =
  (* no stdlib and no frozen encodings: Py_InitializeFromConfig fails *)
  let first =
    match Pyembed.init (Pyembed.Config.default ()) with
    | () -> "initialized"
    | exception Failure m -> m
  in
  let again =
    match Pyembed.with_gil (fun _ -> ()) with
    | () -> "usable"
    | exception Failure m -> m
  in
  let init_again =
    match Pyembed.init (config ()) with
    | () -> "initialized"
    | exception Failure m -> m
  in
  if
    String.equal first again
    && String.equal first init_again
    && not (Pyembed.is_initialized ())
  then print_endline "[same failure, no retry]"
  else Printf.printf "[different] %S %S %S\n" first again init_again;
  Stdlib.exit 0

let () =
  match Array.to_list Sys.argv with
  | [ _; "init-fail" ] -> init_fail ()
  | [ _; "threads" ] ->
      Pyembed.init (config ());
      exec
        "import sys, threading, time\n\
         def late():\n\
        \    time.sleep(0.3)\n\
        \    sys.stdout.write('[thread done]')\n\
         threading.Thread(target=late).start()\n";
      Pyembed.exit ~code:0
  | [ _; "flush-fail" ] ->
      Pyembed.init (config ());
      exec
        "import sys\n\
         sys.stdout = open('/dev/full', 'w')\n\
         sys.stdout.write('x')\n";
      Pyembed.exit ~code:0
  | _ ->
      Pyembed.init (config ());
      at_exit (fun () -> print_string "[ocaml at_exit]");
      print_string "[ocaml buffered]";
      exec
        "import atexit, sys\n\
         atexit.register(lambda: sys.stdout.write('[python atexit]'))\n\
         sys.stdout.write('[python buffered]')\n";
      Pyembed.exit ~code:3
