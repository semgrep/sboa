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
(* Finds the CPython 3.13 sboa builds against, the way ocurl finds libcurl:
   a dune-configurator program run by the rule in ./dune. sboa never
   downloads CPython; the interpreter is the first of:

   1. SBOA_PYTHON, an interpreter (a path, or a name looked up on PATH);
   2. the interpreter of the installation at SBOA_PREFIX (absolute):
      bin/python3.13, bin/python3, or python.exe (Windows);
   3. python3.13 on PATH;
   4. what `uv python find --system 3.13` prints, when uv is on PATH (after
      `uv python install 3.13`);
   5. python3 on PATH, if it is 3.13.

   An interpreter named by 1 or 2 must do; 3 to 5 are tried in turn. The
   checks (CPython 3.13, a shared libpython, no free threading, no Py_DEBUG)
   and the description of the installation are `sboa_bundle.py describe`,
   run under the candidate interpreter (standard library only), which writes
   sboa.config. `sboa_bundle.py flags` then turns the config into
   cflags.sexp (the library's C flags) and link.sexp (the link flags of
   sboa's own tests and examples: linking libpython is the application's
   business, since it must link the CPython it ships; clibs.sexp is empty
   except on Windows, see below). build_python.ml
   records the interpreter for the sboa-bundle launcher (../tools). *)

module C = Configurator.V1

type candidate = {
  python : string;
  prefix : string option;
  origin : string;  (** how it was found, for messages *)
  explicit : bool;  (** named by SBOA_PYTHON / SBOA_PREFIX: no fallback *)
}

let five_ways =
  "Point sboa at a CPython 3.13 (shared libpython, not free-threaded, not \
   Py_DEBUG) in one of five ways:\n\
  \  SBOA_PYTHON=<interpreter>\n\
  \  SBOA_PREFIX=<installation prefix>\n\
  \  a python3.13 on PATH (e.g. the distribution's python3.13-dev package, or \
   Homebrew's python@3.13)\n\
  \  uv on PATH and `uv python install 3.13` (found with `uv python find`)\n\
  \  a python3 on PATH that is 3.13"

let getenv name =
  match Sys.getenv_opt name with
  | Some ""
  | None ->
      None
  | Some v -> Some v

let is_absolute p =
  (not (Filename.is_relative p))
  || (String.length p >= 3 && p.[1] = ':' && (p.[2] = '/' || p.[2] = '\\'))

let first_line s =
  match String.split_on_char '\n' (String.trim s) with
  | l :: _ -> l
  | [] -> ""

let candidates c =
  match (getenv "SBOA_PYTHON", getenv "SBOA_PREFIX") with
  | Some p, _ ->
      let python =
        if is_absolute p then p
        else
          match C.which c p with
          | Some p -> p
          | None -> C.die "SBOA_PYTHON=%s: not found on PATH\n%s" p five_ways
      in
      if not (Sys.file_exists python) then
        C.die "SBOA_PYTHON: no file %s\n%s" python five_ways;
      [
        { python; prefix = None; origin = "SBOA_PYTHON=" ^ p; explicit = true };
      ]
  | None, Some prefix ->
      (* absolute: the rule runs inside dune's build directory *)
      if not (is_absolute prefix) then
        C.die "SBOA_PREFIX must be an absolute path, got %S\n%s" prefix
          five_ways;
      if not (Sys.file_exists prefix && Sys.is_directory prefix) then
        C.die "SBOA_PREFIX: no directory %s\n%s" prefix five_ways;
      let python =
        List.find_map
          (fun rel ->
            let p = Filename.concat prefix rel in
            if Sys.file_exists p then Some p else None)
          [ "bin/python3.13"; "bin/python3"; "python.exe" ]
      in
      let python =
        match python with
        | Some p -> p
        | None ->
            C.die
              "SBOA_PREFIX=%s has no bin/python3.13, bin/python3 or python.exe\n\
               %s"
              prefix five_ways
      in
      [
        {
          python;
          prefix = Some prefix;
          origin = "SBOA_PREFIX=" ^ prefix;
          explicit = true;
        };
      ]
  | None, None ->
      let on_path name origin =
        match C.which c name with
        | Some python -> [ { python; prefix = None; origin; explicit = false } ]
        | None -> []
      in
      let uv () =
        match C.which c "uv" with
        | None -> []
        | Some uv -> (
            (* --system: never a virtual environment of the current
               directory's parents *)
            let r =
              C.Process.run c uv [ "python"; "find"; "--system"; "3.13" ]
            in
            match (r.exit_code, String.trim r.stdout) with
            | 0, python when python <> "" ->
                [
                  {
                    python;
                    prefix = None;
                    origin = "uv python find";
                    explicit = false;
                  };
                ]
            | _ -> [])
      in
      on_path "python3.13" "python3.13 on PATH"
      @ uv ()
      @ on_path "python3" "python3 on PATH"

(* `sboa_bundle.py describe` under the candidate: Ok () when it wrote
   sboa.config, Error reason otherwise. *)
let describe c ~tool cand =
  let args =
    [ "-I"; "-B"; tool; "describe"; "--python"; cand.python ]
    @ (match cand.prefix with
      | Some p -> [ "--prefix"; p ]
      | None -> [])
    @ [ "--out"; "sboa.config" ]
  in
  let r = C.Process.run c cand.python args in
  if r.exit_code = 0 then Ok ()
  else
    let error = "sboa-bundle: error: " in
    let reason =
      String.split_on_char '\n' r.stderr
      |> List.filter_map (fun l ->
          if String.starts_with ~prefix:error l then
            Some
              (String.sub l (String.length error)
                 (String.length l - String.length error))
          else None)
    in
    Error
      (match reason with
      | [] ->
          Printf.sprintf "exit code %d%s" r.exit_code
            (match first_line r.stderr with
            | "" -> ""
            | l -> ": " ^ l)
      | l -> String.concat "; " l)

let flags c ~tool ~python ~what ~out =
  let r =
    C.Process.run c python
      [
        "-I"; "-B"; tool; "flags"; "--config"; "sboa.config"; what; "--out"; out;
      ]
  in
  if r.exit_code <> 0 then
    C.die "sboa_bundle.py flags %s failed:\n%s" what (String.trim r.stderr)

let () =
  let tool = ref "" in
  C.main ~name:"sboa"
    ~args:[ ("-tool", Arg.Set_string tool, "PATH the sboa_bundle.py to run") ]
    (fun c ->
      if !tool = "" then C.die "usage: discover -tool sboa_bundle.py";
      let tool = !tool in
      let rec go tried = function
        | [] ->
            let tried =
              match List.rev tried with
              | [] ->
                  "  none found: no SBOA_PYTHON or SBOA_PREFIX, no python3.13 \
                   or python3 on PATH, no uv-managed 3.13"
              | l -> String.concat "\n" l
            in
            C.die "no usable CPython 3.13:\n%s\n%s" tried five_ways
        | cand :: rest -> (
            match describe c ~tool cand with
            | Ok () -> cand
            | Error reason when cand.explicit ->
                C.die "%s (%s): %s\n%s" cand.python cand.origin reason five_ways
            | Error reason ->
                go
                  (Printf.sprintf "  %s (%s): %s" cand.python cand.origin reason
                  :: tried)
                  rest)
      in
      let cand = go [] (candidates c) in
      flags c ~tool ~python:cand.python ~what:"--cflags" ~out:"cflags.sexp";
      flags c ~tool ~python:cand.python ~what:"--link" ~out:"link.sexp";
      (* Windows: a DLL (the bytecode stub library) cannot have undefined
         symbols, so the library links the import library, which binds by
         DLL name (python313.dll, found next to the .exe), not by path. *)
      if Sys.win32 then
        flags c ~tool ~python:cand.python ~what:"--clibs" ~out:"clibs.sexp"
      else C.Flags.write_sexp "clibs.sexp" [];
      let oc = open_out_bin "build_python.ml" in
      Printf.fprintf oc
        "(* Generated by config/discover.ml: the CPython sboa was built \
         against. *)\n\n\
         let path = %S\n"
        cand.python;
      close_out oc)
