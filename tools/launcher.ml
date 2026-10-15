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
(* sboa-bundle: the configurator and the entry point of sboa_bundle.py.

   [sboa-bundle discover] finds the CPython 3.13 to build against, the way
   ocurl finds libcurl, and writes its sboa.config (and, on request, the
   dune flag files). The interpreter is the first of:

   1. SBOA_PYTHON, an interpreter (a path, or a name looked up on PATH);
   2. the interpreter of the installation at SBOA_PREFIX (absolute):
      bin/python3.13, bin/python3, or python.exe (Windows);
   3. python3.13 on PATH;
   4. what `uv python find --system 3.13` prints, when uv is on PATH;
   5. python3 on PATH, if it is 3.13.

   An interpreter named by 1 or 2 must do; 3 to 5 are tried in turn. Each
   candidate runs `sboa_bundle.py describe`, which checks it (CPython 3.13,
   a shared libpython, no free threading, no Py_DEBUG) and writes the
   config; `sboa_bundle.py flags` writes the flag files from it.

   Every other subcommand runs sboa_bundle.py under the [python_exe] of a
   config: the one given with [--config] (the CPython an application ships),
   else the sboa.config next to the script (the CPython sboa was built
   against). The script is lib/sboa/sboa_bundle.py next to bin/ (an
   installed sboa), else the one next to the real executable (a dune
   workspace, where sboa's own build writes sboa.config next to it too). *)

let die fmt =
  Printf.ksprintf
    (fun s ->
      prerr_endline ("sboa-bundle: error: " ^ s);
      exit 1)
    fmt

let script_dir () =
  let exe = Sys.executable_name in
  let installed =
    Filename.concat
      (Filename.dirname (Filename.dirname exe))
      (Filename.concat "lib" "sboa")
  in
  let sibling =
    match Unix.realpath exe with
    | real -> [ Filename.dirname real ]
    | exception Unix.Unix_error _ -> []
  in
  match
    List.find_opt
      (fun d -> Sys.file_exists (Filename.concat d "sboa_bundle.py"))
      (installed :: sibling)
  with
  | Some d -> d
  | None -> die "cannot find sboa_bundle.py (lib/sboa/ of the installation)"

(* Runs [prog args] with stdout and stderr captured (through files: no
   pipe to fill up); [Error] when it cannot be started. *)
let run prog args =
  let capture () =
    let f = Filename.temp_file "sboa-bundle" ".txt" in
    (f, Unix.openfile f [ O_WRONLY; O_TRUNC; O_CLOEXEC ] 0o600)
  in
  let out, out_fd = capture () in
  let err, err_fd = capture () in
  let read f =
    let ic = open_in_bin f in
    let s = really_input_string ic (in_channel_length ic) in
    close_in ic;
    Sys.remove f;
    s
  in
  let status =
    match
      Unix.create_process prog
        (Array.of_list (prog :: args))
        Unix.stdin out_fd err_fd
    with
    | pid -> (
        match snd (Unix.waitpid [] pid) with
        | Unix.WEXITED n -> Ok n
        | Unix.WSIGNALED n
        | Unix.WSTOPPED n ->
            Ok (128 + abs n))
    | exception Unix.Unix_error (e, _, _) -> Error (Unix.error_message e)
  in
  Unix.close out_fd;
  Unix.close err_fd;
  let stdout = read out in
  let stderr = read err in
  Result.map (fun code -> (code, stdout, stderr)) status

let which name =
  let sep = if Sys.win32 then ';' else ':' in
  let exts = if Sys.win32 then [ ".exe"; "" ] else [ "" ] in
  let path = Option.value (Sys.getenv_opt "PATH") ~default:"" in
  List.concat_map
    (fun dir ->
      if dir = "" then []
      else List.map (fun ext -> Filename.concat dir (name ^ ext)) exts)
    (String.split_on_char sep path)
  |> List.find_opt (fun p ->
      Sys.file_exists p
      && (not (Sys.is_directory p))
      && (Sys.win32 || Unix.access p [ X_OK ] = ()))

(* ------------------------------------------------------------------ *)
(* discover *)

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

let candidates () =
  match (getenv "SBOA_PYTHON", getenv "SBOA_PREFIX") with
  | Some p, _ ->
      let python =
        if is_absolute p then p
        else
          match which p with
          | Some p -> p
          | None -> die "SBOA_PYTHON=%s: not found on PATH\n%s" p five_ways
      in
      if not (Sys.file_exists python) then
        die "SBOA_PYTHON: no file %s\n%s" python five_ways;
      [
        { python; prefix = None; origin = "SBOA_PYTHON=" ^ p; explicit = true };
      ]
  | None, Some prefix ->
      if not (is_absolute prefix) then
        die "SBOA_PREFIX must be an absolute path, got %S\n%s" prefix five_ways;
      if not (Sys.file_exists prefix && Sys.is_directory prefix) then
        die "SBOA_PREFIX: no directory %s\n%s" prefix five_ways;
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
            die
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
        match which name with
        | Some python -> [ { python; prefix = None; origin; explicit = false } ]
        | None -> []
      in
      let uv () =
        match which "uv" with
        | None -> []
        | Some uv -> (
            (* --system: never a virtual environment of the current
               directory's parents *)
            match run uv [ "python"; "find"; "--system"; "3.13" ] with
            | Ok (0, out, _) when String.trim out <> "" ->
                [
                  {
                    python = String.trim out;
                    prefix = None;
                    origin = "uv python find";
                    explicit = false;
                  };
                ]
            | Ok _
            | Error _ ->
                [])
      in
      on_path "python3.13" "python3.13 on PATH"
      @ uv ()
      @ on_path "python3" "python3 on PATH"

let error_prefix = "sboa-bundle: error: "

(* The "sboa-bundle: error:" lines of a failed run, else its exit code and
   first line of output. *)
let reason (code, _, stderr) =
  let lines =
    String.split_on_char '\n' stderr
    |> List.filter_map (fun l ->
        if String.starts_with ~prefix:error_prefix l then
          let n = String.length error_prefix in
          Some (String.trim (String.sub l n (String.length l - n)))
        else None)
  in
  match lines with
  | [] -> (
      match String.split_on_char '\n' (String.trim stderr) with
      | l :: _ when l <> "" -> Printf.sprintf "exit code %d: %s" code l
      | _ -> Printf.sprintf "exit code %d" code)
  | l -> String.concat "; " l

let describe ~script ~out cand =
  let args =
    [ "-I"; "-B"; script; "describe"; "--python"; cand.python ]
    @ (match cand.prefix with
      | Some p -> [ "--prefix"; p ]
      | None -> [])
    @ [ "--out"; out ]
  in
  match run cand.python args with
  | Ok (0, _, _) -> Ok ()
  | Ok r -> Error (reason r)
  | Error e -> Error ("cannot run it: " ^ e)

let discover ~script args =
  let usage =
    "usage: sboa-bundle discover [--out sboa.config] [--cflags FILE] [--link \
     FILE] [--clibs FILE]"
  in
  let rec parse ((out, flags) as acc) = function
    | [] -> acc
    | "--out" :: f :: rest -> parse (f, flags) rest
    | (("--cflags" | "--link" | "--clibs") as w) :: f :: rest ->
        parse (out, (w, f) :: flags) rest
    | ("-h" | "--help") :: _ ->
        print_endline usage;
        print_endline five_ways;
        exit 0
    | a :: _ -> die "discover: unexpected argument %S\n%s" a usage
  in
  let out, flags = parse ("sboa.config", []) args in
  let rec go tried = function
    | [] ->
        let tried =
          match List.rev tried with
          | [] ->
              "  none found: no SBOA_PYTHON or SBOA_PREFIX, no python3.13 or \
               python3 on PATH, no uv-managed 3.13"
          | l -> String.concat "\n" l
        in
        die "no usable CPython 3.13:\n%s\n%s" tried five_ways
    | cand :: rest -> (
        match describe ~script ~out cand with
        | Ok () -> cand
        | Error r when cand.explicit ->
            die "%s (%s): %s\n%s" cand.python cand.origin r five_ways
        | Error r ->
            go
              (Printf.sprintf "  %s (%s): %s" cand.python cand.origin r :: tried)
              rest)
  in
  let cand = go [] (candidates ()) in
  List.iter
    (fun (what, file) ->
      match
        run cand.python
          [ "-I"; "-B"; script; "flags"; "--config"; out; what; "--out"; file ]
      with
      | Ok (0, _, _) -> ()
      | Ok r -> die "flags %s: %s" what (reason r)
      | Error e -> die "flags %s: cannot run %s: %s" what cand.python e)
    (List.rev flags)

(* ------------------------------------------------------------------ *)
(* every other subcommand *)

(* The value of [--config] (before any "--"), if given. *)
let rec config_arg = function
  | []
  | "--" :: _ ->
      None
  | "--config" :: c :: _ -> Some c
  | a :: rest when String.starts_with ~prefix:"--config=" a ->
      ignore rest;
      Some (String.sub a 9 (String.length a - 9))
  | _ :: rest -> config_arg rest

(* The [python_exe] field of a config (values never contain a quote). *)
let python_exe config =
  let text =
    match open_in_bin config with
    | ic ->
        let s = really_input_string ic (in_channel_length ic) in
        close_in ic;
        s
    | exception Sys_error e -> die "%s" e
  in
  let key = "(python_exe \"" in
  let rec find i =
    if i + String.length key > String.length text then
      die "%s: no python_exe field" config
    else if String.sub text i (String.length key) = key then
      let start = i + String.length key in
      match String.index_from_opt text start '"' with
      | Some stop -> String.sub text start (stop - start)
      | None -> die "%s: malformed python_exe field" config
    else find (i + 1)
  in
  find 0

let exec_python python args =
  if Sys.win32 then
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
        die "cannot run %s: %s" python (Unix.error_message e)
  else
    try Unix.execv python args with
    | Unix.Unix_error (e, _, _) ->
        die "cannot run %s: %s" python (Unix.error_message e)

let () =
  let dir = script_dir () in
  let script = Filename.concat dir "sboa_bundle.py" in
  match List.tl (Array.to_list Sys.argv) with
  | "discover" :: args -> discover ~script args
  | args ->
      let config =
        match config_arg args with
        | Some c -> c
        | None ->
            let c = Filename.concat dir "sboa.config" in
            if not (Sys.file_exists c) then
              die "no --config, and no %s (run `sboa-bundle discover`)" c;
            c
      in
      let python = python_exe config in
      exec_python python (Array.of_list (python :: "-I" :: script :: args))
