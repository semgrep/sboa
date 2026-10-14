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
(* Tests for pyembed.cpython.

   One process initializes Python once (with Sys.catch_break set first so
   SIGINT/SIGTERM are routed) and runs every scenario in order; the exit test
   runs in a child process because Pyembed.exit ends the process. A
   micro-benchmark runs last and prints round-trip costs.

   The interpreter has no bundles here: extra_sys_path points at the stdlib
   of the CPython the test is linked with (PYEMBED_STDLIB, set by dune). *)

open Pyembed

(* The stdlib directory of the CPython the test is linked with, from the
   dune rule (probe.sh --print-stdlib). *)
let stdlib = Sys.getenv "PYEMBED_STDLIB"

let config () =
  {
    (Config.default ()) with
    extra_sys_path = [ stdlib; Filename.concat stdlib "lib-dynload" ];
  }

(* ------------------------------------------------------------------------ *)
(* Exports used by the tests *)
(* ------------------------------------------------------------------------ *)

exception My_error of int
exception Mapped_error of string

let m = "_pyembed_test"
let int_ = Conv.int
let ret_int gil i = Conv.to_py Conv.int gil i

let () =
  Export.register ~module_:m ~name:"add" ~doc:"Add two ints."
    ~signature:"a, b, /" (fun gil args kwargs ->
      Conv.check_arity ~max_positional:2 ~keywords:[] args kwargs;
      let a = Conv.positional gil ~name:"a" (Conv.of_py int_) args 0 in
      let b = Conv.positional gil ~name:"b" (Conv.of_py int_) args 1 in
      ret_int gil (a + b));
  Export.register ~module_:m ~name:"noop" (fun _ _ _ -> Object.none);
  Export.register ~module_:m ~name:"sum_list" ~signature:"xs, /, *, scale=1"
    (fun gil args kwargs ->
      Conv.check_arity ~max_positional:1 ~keywords:[ "scale" ] args kwargs;
      let xs =
        Conv.positional gil ~name:"xs" (Conv.of_py Conv.(list int)) args 0
      in
      let scale =
        Option.value ~default:1
          (Conv.keyword_opt gil ~name:"scale" (Conv.of_py int_) kwargs)
      in
      ret_int gil (scale * List.fold_left ( + ) 0 xs));
  Export.register ~module_:m ~name:"fail" (fun gil args _ ->
      match
        Conv.positional gil ~name:"kind" (Conv.of_py Conv.string) args 0
      with
      | "custom" -> raise (My_error 42)
      | "failure" -> failwith "boom from OCaml"
      | "exit" -> raise (System_exit 7)
      | "mapped" -> raise (Mapped_error "mapped message")
      | "break" -> raise Sys.Break
      | k -> invalid_arg k);
  (* GIL released for the body, as generated wrappers do. *)
  Export.register ~module_:m ~name:"sleep_ms" (fun gil args _ ->
      let ms = Conv.positional gil ~name:"ms" (Conv.of_py int_) args 0 in
      detach gil (fun () -> Unix.sleepf (float ms /. 1000.));
      Object.none);
  (* Busy OCaml loop (polls for signals) with the GIL released. *)
  Export.register ~module_:m ~name:"spin_ms" (fun gil args _ ->
      let ms = Conv.positional gil ~name:"ms" (Conv.of_py int_) args 0 in
      detach gil (fun () ->
          let t0 = Unix.gettimeofday () in
          let r = ref [] in
          while Unix.gettimeofday () -. t0 < float ms /. 1000. do
            r := [ Unix.gettimeofday () ]
          done);
      Object.none);
  (* call f(x) through a typed callable, from a detached body. *)
  Export.register ~module_:m ~name:"apply" (fun gil args _ ->
      let f = Conv.positional gil ~name:"f" Conv.(func1 int int) args 0 in
      let x = Conv.positional gil ~name:"x" (Conv.of_py int_) args 1 in
      let r = detach gil (fun () -> f x) in
      ret_int gil r);
  (* call a Python function with no conversion of its error. *)
  Export.register ~module_:m ~name:"call0" (fun gil args _ ->
      let f = Conv.positional gil ~name:"f" (Conv.of_py Conv.object_) args 0 in
      Object.call gil f ())

let () =
  Export.register_exn_mapping (fun gil -> function
    | Mapped_error s ->
        Some ("builtins.ValueError", [| Conv.to_py Conv.string gil s |])
    | _ -> None)

type counter = { mutable n : int }

let counter_class =
  Export.register_class ~module_:m ~name:"Counter" ~doc:"An OCaml counter."
    ~methods:
      [
        ("get", fun c gil _ _ -> ret_int gil c.n);
        ( "incr",
          fun c gil args _ ->
            let by =
              if Array.length args > 0 then
                Conv.positional gil ~name:"by" (Conv.of_py int_) args 0
              else 1
            in
            c.n <- c.n + by;
            Object.none );
      ]
    ~repr:(fun _ c -> Printf.sprintf "<Counter %d>" c.n)
    ()

let () =
  Export.register ~module_:m ~name:"make_counter" (fun gil args _ ->
      let n = Conv.positional gil ~name:"n" (Conv.of_py int_) args 0 in
      Class.wrap gil counter_class { n })

let () =
  Export.register ~module_:m ~name:"counter_value" (fun gil args _ ->
      let c =
        Conv.positional gil ~name:"c" (Class.unwrap counter_class) args 0
      in
      ret_int gil c.n)

(* Callables kept beyond the export call that received them (scope test). *)
let kept_callable : (int -> int) option Atomic.t = Atomic.make None
let kept_nested : (int -> int) list Atomic.t = Atomic.make []

let () =
  Export.register ~module_:m ~name:"keep_callable" (fun gil args _ ->
      Atomic.set kept_callable
      @@ Some (Conv.positional gil ~name:"f" Conv.(func1 int int) args 0);
      Object.none);
  (* callables nested in a list: a converter whose decoding half is func1 *)
  let fn_conv =
    Conv.make
      ~to_py:(fun _ _ -> invalid_arg "not encodable")
      ~of_py:Conv.(func1 int int)
      ()
  in
  Export.register ~module_:m ~name:"keep_nested" (fun gil args _ ->
      Atomic.set kept_nested
      @@ Conv.positional gil ~name:"fs" (Conv.of_py (Conv.list fn_conv)) args 0;
      Object.none);
  Export.add_method counter_class ~name:"double" ~doc:"Double the counter."
    ~signature:"" (fun c _gil _ _ ->
      c.n <- 2 * c.n;
      Object.none)

external test_bundle_blob : unit -> Bundle.data = "pyembed_test_bundle_blob"

let () =
  (* registered out of order: lower priority is searched first *)
  Bundle.register ~priority:90
    (Bundle.of_incbin ~symbol:"pyembed_test_bundle" ~name:"later"
       (test_bundle_blob ()));
  Bundle.register ~priority:10
    (Bundle.of_incbin ~symbol:"pyembed_test_bundle" ~name:"test"
       (test_bundle_blob ()))

(* ------------------------------------------------------------------------ *)
(* Helpers *)
(* ------------------------------------------------------------------------ *)

let py_eval_int code =
  with_gil (fun gil -> Conv.of_py_exn Conv.int gil (eval gil code))

let py_eval_str code =
  with_gil (fun gil -> Conv.of_py_exn Conv.string gil (eval gil code))

let py_eval_bool code =
  with_gil (fun gil -> Conv.of_py_exn Conv.bool gil (eval gil code))

let py_exec code = with_gil (fun gil -> exec gil code)

let contains ~sub s =
  let n = String.length sub and m = String.length s in
  let rec go i = i + n <= m && (String.sub s i n = sub || go (i + 1)) in
  go 0

let check_contains what ~sub s =
  if not (contains ~sub s) then
    Alcotest.failf "%s: %S does not contain %S" what s sub

(* Fun.protect without Finally_raised (the repo's rules forbid Fun.protect). *)
let protect ~finally f =
  match f () with
  | v ->
      finally ();
      v
  | exception e ->
      let bt = Printexc.get_raw_backtrace () in
      finally ();
      Printexc.raise_with_backtrace e bt

(* Run [f] while an OCaml thread sends [signal] to this process after
   [delay] seconds. *)
let with_signal_after ?(signal = Sys.sigint) delay f =
  let t =
    Thread.create
      (fun () ->
        Thread.delay delay;
        Unix.kill (Unix.getpid ()) signal)
      ()
  in
  protect ~finally:(fun () -> Thread.join t) f

(* ------------------------------------------------------------------------ *)
(* Tests *)
(* ------------------------------------------------------------------------ *)

(* Reported after the run (alcotest captures test output). *)
let python_thread_ticks = Atomic.make 0
let signal_ordering = Atomic.make (0, 0)
let ocaml_thread_ticks = Atomic.make (0, 0)

let test_init () =
  Alcotest.(check bool) "initialized" true (is_initialized ());
  Alcotest.(check string)
    "sys.path"
    (Printf.sprintf "[%S, %S]" stdlib (Filename.concat stdlib "lib-dynload"))
    (py_eval_str "repr(__import__('sys').path)"
    |> String.map (function
      | '\'' -> '"'
      | c -> c));
  Alcotest.(check bool)
    "isolated" true
    (py_eval_bool "__import__('sys').flags.isolated == 1");
  Alcotest.(check bool)
    "no bytecode writing" true
    (py_eval_bool "__import__('sys').dont_write_bytecode");
  Alcotest.(check bool)
    "no site" true
    (py_eval_bool "'site' not in __import__('sys').modules");
  Alcotest.(check bool)
    "builtin module" true
    (py_eval_bool "'_pyembed_test' in __import__('sys').builtin_module_names");
  Alcotest.(check string)
    "text signature" "(a, b, /)"
    (py_eval_str
       "str(__import__('inspect').signature(__import__('_pyembed_test').add))");
  Alcotest.(check string)
    "doc" "Add two ints."
    (py_eval_str "__import__('_pyembed_test').add.__doc__");
  Alcotest.(check int)
    "call" 5
    (py_eval_int "__import__('_pyembed_test').add(2, 3)");
  Alcotest.(check bool)
    "SIGPIPE ignored" true
    (py_eval_bool
       "__import__('signal').getsignal(__import__('signal').SIGPIPE) == \
        __import__('signal').SIG_IGN");
  (* idempotent with the same configuration, refused with another *)
  init (config ());
  match init (Config.default ()) with
  | () -> Alcotest.fail "init with a different config accepted"
  | exception Invalid_argument _ -> ()

(* Run a child program; its exit status and combined output. *)
let run_child prog args =
  let ic = Unix.open_process_args_in prog (Array.append [| prog |] args) in
  let out = In_channel.input_all ic in
  let status =
    match Unix.close_process_in ic with
    | Unix.WEXITED n -> n
    | Unix.WSIGNALED n
    | Unix.WSTOPPED n ->
        1000 + n
  in
  (status, out)

let test_exit_modes () =
  (let status, out = run_child "./exit_prog.exe" [| "threads" |] in
   Alcotest.(check int) "status" 0 status;
   check_contains "non-daemon thread joined before exit" ~sub:"[thread done]"
     out);
  (let status, out = run_child "./exit_prog.exe" [| "flush-fail" |] in
   Alcotest.(check int) "failed flush -> 120" 120 status;
   ignore out);
  let status, out = run_child "./exit_prog.exe" [| "init-fail" |] in
  Alcotest.(check int) "init failure" 0 status;
  check_contains "init failure" ~sub:"[same failure, no retry]" out

let test_exit () =
  let ic =
    Unix.open_process_args_in "./exit_prog.exe" [| "./exit_prog.exe"; "exit" |]
  in
  let out = In_channel.input_all ic in
  match Unix.close_process_in ic with
  | Unix.WEXITED 3 ->
      List.iter
        (fun sub -> check_contains "exit output" ~sub out)
        [
          "[python buffered]";
          "[python atexit]";
          "[ocaml buffered]";
          "[ocaml at_exit]";
        ]
  | Unix.WEXITED n -> Alcotest.failf "exit status %d, output %S" n out
  | _ -> Alcotest.fail "exit_prog killed"

let test_conversions () =
  with_gil (fun gil ->
      let roundtrip (type a) name (t : a Alcotest.testable) (c : a Conv.t)
          (x : a) =
        match Conv.of_py c gil (Conv.to_py c gil x) with
        | Ok y -> Alcotest.check t name x y
        | Error e -> Alcotest.failf "%s: %s" name (Conv.error_to_string e)
      in
      let open Alcotest in
      roundtrip "int" int Conv.int max_int;
      roundtrip "int" int Conv.int min_int;
      roundtrip "float" (float 0.) Conv.float 1.5;
      roundtrip "bool" bool Conv.bool true;
      roundtrip "string" string Conv.string "h\xc3\xa9llo";
      roundtrip "bytes" string Conv.bytes "\x00\xff";
      roundtrip "unit" unit Conv.unit ();
      roundtrip "json" string Conv.json "{\"a\": 1}";
      roundtrip "list" (list int) Conv.(list int) [ 1; 2; 3 ];
      roundtrip "option none" (option string) Conv.(option string) None;
      roundtrip "option some" (option string) Conv.(option string) (Some "x");
      roundtrip "dict"
        (list (pair string (list bool)))
        Conv.(dict (list bool))
        [ ("b", [ true ]); ("a", []) ];
      roundtrip "pair" (pair int string) Conv.(pair int string) (1, "a");
      roundtrip "tuple3" (triple int string bool)
        Conv.(tuple3 int string bool)
        (1, "a", false);
      (* a mapped converter (how Fpath.t would be done at a call site) *)
      let upper =
        Conv.map String.lowercase_ascii String.uppercase_ascii Conv.string
      in
      Alcotest.(check (option string)) "map ty" (Some "str") (Conv.ty upper);
      Alcotest.(check string)
        "map encode" "'ABC'"
        (Object.repr gil (Conv.to_py upper gil "abc"));
      Alcotest.(check (option string))
        "ty" (Some "dict[str, list[int] | None]")
        (Conv.ty Conv.(dict (option (list int))));
      let of_py c code = Conv.of_py c gil (eval gil code) in
      Alcotest.(check string)
        "tuple length" "expected tuple of length 2, got length 3"
        (match of_py Conv.(pair int int) "(1, 2, 3)" with
        | Ok _ -> "ok"
        | Error e -> Conv.error_to_string e);
      Alcotest.(check string)
        "tuple element path" "[1]: expected int, got str"
        (match of_py Conv.(pair int int) "(1, 'x')" with
        | Ok _ -> "ok"
        | Error e -> Conv.error_to_string e);
      let err c code =
        match of_py c code with
        | Ok _ -> Alcotest.failf "%s: expected a conversion error" code
        | Error e -> Conv.error_to_string e
      in
      Alcotest.(check string)
        "bool is not int" "expected int, got bool" (err Conv.int "True");
      Alcotest.(check string)
        "big int" "expected int in OCaml's range, got int out of range"
        (err Conv.int "2**70");
      Alcotest.(check (result (float 0.) reject))
        "int as float" (Ok 3.)
        (of_py Conv.float "3" |> Result.map_error (fun _ -> ()));
      Alcotest.(check string)
        "nested path" "[1]['k']: expected int, got str"
        (err Conv.(list (dict int)) "[{}, {'k': 'v'}]");
      Alcotest.(check string)
        "tuple accepted" "ok"
        (match of_py Conv.(list int) "(1, 2)" with
        | Ok l when List.equal Int.equal l [ 1; 2 ] -> "ok"
        | _ -> "bad");
      Alcotest.(check string)
        "json from str" "abc"
        (Result.get_ok (of_py Conv.json "'abc'"));
      Alcotest.(check string)
        "surrogates" "expected str encodable as UTF-8, got str with surrogates"
        (err Conv.string "'\\udc80'");
      match Conv.to_py Conv.string gil "\xff" with
      | _ -> Alcotest.fail "invalid UTF-8 accepted"
      | exception Conversion_error _ -> ())

let test_callable () =
  with_gil (fun gil ->
      let f =
        match
          Conv.(func2 int string string) gil (eval gil "lambda n, s: s * n")
        with
        | Ok f -> f
        | Error e -> Alcotest.fail (Conv.error_to_string e)
      in
      Alcotest.(check string) "call" "abab" (f 2 "ab");
      (* the closure re-takes the GIL itself *)
      Alcotest.(check string)
        "detached call" "x"
        (detach gil (fun () -> f 1 "x"));
      let g = Result.get_ok (Conv.(func0 int) gil (eval gil "lambda: 'no'")) in
      match g () with
      | _ -> Alcotest.fail "bad return accepted"
      | exception Conversion_error e ->
          Alcotest.(check string)
            "return path" "argument '<return>': expected int, got str"
            (Conv.error_to_string e))

let test_python_errors () =
  (match py_exec "1/0" with
  | () -> Alcotest.fail "no exception"
  | exception Python_error e ->
      Alcotest.(check string) "ty" "builtins.ZeroDivisionError" e.ty;
      Alcotest.(check string) "msg" "division by zero" e.msg;
      check_contains "traceback" ~sub:"ZeroDivisionError: division by zero"
        e.traceback);
  (match py_exec "class E(Exception): pass\nraise E('x')" with
  | () -> Alcotest.fail "no exception"
  | exception Python_error e ->
      Alcotest.(check string) "user class" "__main__.E" e.ty);
  (match py_exec "raise SystemExit(3)" with
  | () -> Alcotest.fail "no exception"
  | exception System_exit n -> Alcotest.(check int) "SystemExit" 3 n);
  (match py_exec "raise SystemExit" with
  | () -> Alcotest.fail "no exception"
  | exception System_exit n -> Alcotest.(check int) "SystemExit()" 0 n);
  (match py_exec "raise KeyboardInterrupt" with
  | () -> Alcotest.fail "no exception"
  | exception Sys.Break -> ());
  match with_gil (fun gil -> Import.module_ gil "no_such_module_xyz") with
  | _ -> Alcotest.fail "import succeeded"
  | exception Python_error e ->
      Alcotest.(check string) "import" "builtins.ModuleNotFoundError" e.ty

let test_ocaml_errors () =
  py_exec
    "import _pyembed, _pyembed_test as t\n\
     def catch(kind):\n\
    \    try:\n\
    \        t.fail(kind)\n\
    \    except BaseException as e:\n\
    \        return type(e).__name__ + ': ' + str(e).split('\\n')[0]\n";
  let catch kind = py_eval_str (Printf.sprintf "catch(%S)" kind) in
  Alcotest.(check string)
    "failure" "OCamlError: Failure(\"boom from OCaml\")" (catch "failure");
  Alcotest.(check string) "mapped" "ValueError: mapped message" (catch "mapped");
  Alcotest.(check string) "exit" "SystemExit: 7" (catch "exit");
  Alcotest.(check string) "break" "KeyboardInterrupt: " (catch "break");
  Alcotest.(check string)
    "argument" "TypeError: argument 'kind': expected str, got int"
    (with_gil (fun gil ->
         exec gil
           "try:\n\
           \    t.fail(1)\n\
            except TypeError as e:\n\
           \    _r = 'TypeError: ' + str(e)\n";
         Conv.of_py_exn Conv.string gil (eval gil "_r")));
  Alcotest.(check bool)
    "alias" true
    (py_eval_bool "t.OCamlError is _pyembed.OCamlError");
  (* exit crossing back into OCaml *)
  match py_exec "t.fail('exit')" with
  | () -> Alcotest.fail "no exception"
  | exception System_exit n -> Alcotest.(check int) "Exit round trip" 7 n

let test_resurrection () =
  (* OCaml -> Python -> OCaml raising My_error -> Python -> OCaml *)
  (match py_exec "t.fail('custom')" with
  | () -> Alcotest.fail "no exception"
  | exception My_error n -> Alcotest.(check int) "payload" 42 n);
  (* two levels: Python calls an export that calls Python that calls fail *)
  (match py_exec "t.call0(lambda: t.fail('custom'))" with
  | () -> Alcotest.fail "no exception"
  | exception My_error n -> Alcotest.(check int) "nested payload" 42 n);
  (* a Python exception crossing OCaml unchanged *)
  py_exec
    "class Orig(Exception): pass\n\
     orig = Orig('o')\n\
     def raiser():\n\
    \    raise orig\n\
     try:\n\
    \    t.call0(raiser)\n\
     except Orig as e:\n\
    \    same = e is orig\n";
  Alcotest.(check bool)
    "same Python exception object" true (py_eval_bool "same");
  (* the resurrection capsule's root is released with the exception *)
  py_exec "import gc; gc.collect()";
  gc_flush ();
  let before = Debug.live_roots () in
  py_exec "catch('failure')";
  py_exec "gc.collect()";
  gc_flush ();
  Alcotest.(check int) "capsule roots released" before (Debug.live_roots ())

let test_argument_errors () =
  py_exec
    "def err(f):\n\
    \    try:\n\
    \        f()\n\
    \    except TypeError as e:\n\
    \        return str(e)\n\
    \    return 'no error'\n";
  let err code = py_eval_str (Printf.sprintf "err(lambda: %s)" code) in
  Alcotest.(check string)
    "path" "argument 'xs'[1]: expected int, got str"
    (err "t.sum_list([1, 'a'])");
  Alcotest.(check string)
    "missing" "argument 'xs': expected a value, got nothing (missing)"
    (err "t.sum_list()");
  Alcotest.(check string)
    "extra" "expected keyword arguments among [scale], got 'bogus'"
    (err "t.sum_list([1], bogus=2)");
  Alcotest.(check string)
    "too many" "expected at most 2 positional arguments, got 3"
    (err "t.add(1, 2, 3)");
  Alcotest.(check int) "kwarg ok" 6 (py_eval_int "t.sum_list((1, 2), scale=2)");
  Alcotest.(check int)
    "kwarg None" 3
    (py_eval_int "t.sum_list([1, 2], scale=None)")

let test_deferred_decref () =
  with_gil (fun gil ->
      exec gil "import sys\nsentinel = object()";
      let base =
        Conv.of_py_exn Conv.int gil (eval gil "sys.getrefcount(sentinel)")
      in
      let s = eval gil "sentinel" in
      let n = 10_000 in
      (* many handles to the same object, then unreachable *)
      let handles =
        List.init n (fun _ ->
            Object.get_attr gil (Import.module_ gil "__main__") "sentinel")
      in
      Alcotest.(check int) "held" (base + n) (Object.refcount gil s);
      ignore (Sys.opaque_identity handles);
      (* GC with the GIL released, on two threads: finalizers must not touch
         Python; the references wait in the queue until a bridge crossing. *)
      let queued =
        detach gil (fun () ->
            let t =
              Thread.create
                (fun () ->
                  for _ = 1 to 5 do
                    Gc.full_major ()
                  done)
                ()
            in
            Gc.full_major ();
            Thread.join t;
            Debug.pending_decrefs ())
      in
      Alcotest.(check bool) "queued while detached" true (queued >= n);
      (* the end of [detach] is a crossing: drained under the GIL *)
      Alcotest.(check int) "drained" 0 (Debug.pending_decrefs ());
      let now =
        Conv.of_py_exn Conv.int gil (eval gil "sys.getrefcount(sentinel)")
      in
      (* [s] itself may or may not have been collected yet *)
      Alcotest.(check bool) "references released" true (now <= base + 1));
  (* explicit release *)
  with_gil (fun gil ->
      let o = eval gil "object()" in
      Object.release gil o;
      match Object.repr gil o with
      | _ -> Alcotest.fail "use after release"
      | exception Invalid_argument _ -> ())

let test_nested () =
  py_exec "def down(n):\n    return 0 if n == 0 else 1 + t.apply(down, n - 1)\n";
  Alcotest.(check int)
    "OCaml->Python->OCaml->Python... depth 20" 20 (py_eval_int "down(20)");
  with_gil (fun gil ->
      let down = Import.cached gil "__main__" "down" in
      let r = Object.call gil down ~args:[| Conv.to_py Conv.int gil 5 |] () in
      Alcotest.(check int) "from OCaml" 5 (Conv.of_py_exn Conv.int gil r))

let test_python_thread_progress () =
  py_exec
    "import threading\n\
     ticks = 0\n\
     stop = False\n\
     def worker():\n\
    \    global ticks\n\
    \    while not stop:\n\
    \        ticks += 1\n\
     th = threading.Thread(target=worker)\n\
     th.start()\n\
     while ticks == 0:\n\
    \    pass\n\
     before = ticks\n\
     t.sleep_ms(200)\n\
     during = ticks - before\n\
     stop = True\n\
     th.join()\n";
  let during = py_eval_int "during" in
  Atomic.set python_thread_ticks @@ during;
  Alcotest.(check bool) "python thread ran" true (during > 10_000)

let test_off_main_thread () =
  py_exec
    "import threading\n\
     result = None\n\
     def call():\n\
    \    global result\n\
    \    try:\n\
    \        t.add(1, 2)\n\
    \        result = 'called'\n\
    \    except RuntimeError as e:\n\
    \        result = 'RuntimeError: ' + str(e)\n\
     th = threading.Thread(target=call)\n\
     th.start()\n\
     th.join()\n";
  check_contains "rejected"
    ~sub:"RuntimeError: pyembed: OCaml functions may only be called"
    (py_eval_str "result");
  (* and OCaml systhreads cannot use Python *)
  let r = ref "" in
  let th =
    Thread.create
      (fun () ->
        r :=
          match with_gil (fun _ -> ()) with
          | () -> "allowed"
          | exception Invalid_argument _ -> "rejected")
      ()
  in
  Thread.join th;
  Alcotest.(check string) "OCaml thread" "rejected" !r

let test_ocaml_thread_progress () =
  let counter = Atomic.make 0 in
  let stop = Atomic.make false in
  let th =
    Thread.create
      (fun () ->
        while not (Atomic.get stop) do
          Atomic.incr counter;
          Thread.yield ()
        done)
      ()
  in
  Thread.delay 0.05;
  let measure keep_domain_lock =
    with_gil ~keep_domain_lock (fun gil ->
        let before = Atomic.get counter in
        exec gil "import time; time.sleep(0.2)";
        Atomic.get counter - before)
  in
  let released = measure false in
  let kept = measure true in
  Atomic.set stop true;
  Thread.join th;
  Atomic.set ocaml_thread_ticks @@ (released, kept);
  Alcotest.(check bool)
    "progress with domain lock released" true (released > 100);
  Alcotest.(check int) "no progress with domain lock kept" 0 kept

let test_sigint_in_python () =
  let t0 = Unix.gettimeofday () in
  (match
     with_signal_after 0.2 (fun () -> py_exec "import time; time.sleep(5)")
   with
  | () -> Alcotest.fail "sleep not interrupted"
  | exception Sys.Break -> ());
  let dt = Unix.gettimeofday () -. t0 in
  Alcotest.(check bool) "promptly" true (dt < 2.);
  (* exactly once: no second Sys.Break from OCaml's handler, and no tripped
     signal left in Python *)
  let t1 = Unix.gettimeofday () in
  let r = ref [] in
  while Unix.gettimeofday () -. t1 < 0.3 do
    r := [ Unix.gettimeofday () ]
  done;
  py_exec "time.sleep(0.05)";
  (* SIGTERM is routed the same way when OCaml handles it *)
  match
    with_signal_after ~signal:Sys.sigterm 0.1 (fun () ->
        py_exec "time.sleep(5)")
  with
  | () -> Alcotest.fail "SIGTERM did not interrupt"
  | exception Sys.Break -> ()

let test_sigint_in_ocaml () =
  ignore (py_eval_int "1");
  (* plain OCaml code after init *)
  (match
     with_signal_after 0.1 (fun () ->
         let t0 = Unix.gettimeofday () in
         let r = ref [] in
         while Unix.gettimeofday () -. t0 < 3. do
           r := [ Unix.gettimeofday () ]
         done)
   with
  | () -> Alcotest.fail "no Sys.Break"
  | exception Sys.Break -> ());
  (* OCaml export body running under Python: Sys.Break -> KeyboardInterrupt
     -> Sys.Break *)
  match with_signal_after 0.1 (fun () -> py_exec "t.spin_ms(3000)") with
  | () -> Alcotest.fail "no Sys.Break"
  | exception Sys.Break -> ()

let test_class_lifecycle () =
  py_exec "import gc; gc.collect()";
  gc_flush ();
  let base = Debug.live_roots () in
  py_exec "c = t.make_counter(5)";
  Alcotest.(check int) "root held" (base + 1) (Debug.live_roots ());
  py_exec "c.incr(); c.incr(10)";
  Alcotest.(check int) "methods" 16 (py_eval_int "c.get()");
  Alcotest.(check string) "repr" "<Counter 16>" (py_eval_str "repr(c)");
  Alcotest.(check bool)
    "isinstance" true
    (py_eval_bool "isinstance(c, t.Counter)");
  Alcotest.(check string)
    "type name" "_pyembed_test.Counter"
    (py_eval_str "type(c).__module__ + '.' + type(c).__qualname__");
  Alcotest.(check bool)
    "no __dict__" true
    (py_eval_bool "not hasattr(c, '__dict__')");
  py_exec
    "def raises(f, exc):\n\
    \    try:\n\
    \        f()\n\
    \    except exc:\n\
    \        return True\n\
    \    return False\n";
  Alcotest.(check bool)
    "immutable" true
    (py_eval_bool "raises(lambda: setattr(c, 'x', 1), AttributeError)");
  Alcotest.(check bool)
    "methods not replaceable" true
    (py_eval_bool "raises(lambda: setattr(c, 'get', 1), AttributeError)");
  Alcotest.(check bool)
    "type immutable" true
    (py_eval_bool "raises(lambda: setattr(t.Counter, 'get', 1), TypeError)");
  Alcotest.(check bool)
    "not instantiable" true
    (py_eval_bool "raises(lambda: t.Counter(), TypeError)");
  Alcotest.(check bool)
    "final" true
    (py_eval_bool "raises(lambda: type('Sub', (t.Counter,), {}), TypeError)");
  Alcotest.(check bool)
    "bad self" true
    (py_eval_bool "raises(lambda: t.Counter.get(1), TypeError)");
  Alcotest.(check int) "unwrap in OCaml" 16 (py_eval_int "t.counter_value(c)");
  Alcotest.(check bool)
    "unwrap rejects other" true
    (py_eval_bool "raises(lambda: t.counter_value(1), TypeError)");
  (* OCaml-side wrap/unwrap *)
  with_gil (fun gil ->
      let o = Class.wrap gil counter_class { n = 3 } in
      match Class.unwrap counter_class gil o with
      | Ok c -> Alcotest.(check int) "OCaml roundtrip" 3 c.n
      | Error e -> Alcotest.fail (Conv.error_to_string e));
  Gc.full_major ();
  gc_flush ();
  py_exec "del c; gc.collect()";
  gc_flush ();
  Alcotest.(check int) "root removed on dealloc" base (Debug.live_roots ())

let test_bundles () =
  Alcotest.(check (list string))
    "registered" [ "test"; "later" ]
    (List.map Bundle.name (Bundle.registered ()));
  py_exec "import _pyembed\nb = _pyembed.bundles()";
  Alcotest.(check string)
    "bundles()"
    "[('test', b'pyembed test bundle payload\\n'), ('later', b'pyembed test \
     bundle payload\\n')]"
    (py_eval_str "repr([(n, bytes(m)) for n, m in b])");
  Alcotest.(check bool) "read-only" true (py_eval_bool "b[0][1].readonly");
  (* default <exe dir>/libs/python3.X/lib-dynload does not exist in _build *)
  Alcotest.(check bool)
    "libdynload_dir missing -> None" true
    (py_eval_bool "_pyembed.libdynload_dir() is None");
  Alcotest.(check string)
    "dev_overrides" "[]"
    (py_eval_str "repr(_pyembed.dev_overrides())")

let test_frozen () =
  Alcotest.(check string)
    "frozen module" "from the frozen table"
    (py_eval_str "__import__('_pyembed_frozen_probe').VALUE");
  Alcotest.(check bool)
    "loaded by FrozenImporter" true
    (py_eval_bool
       "__import__('_pyembed_frozen_probe').__spec__.origin == 'frozen'")

let test_misc () =
  with_gil (fun gil ->
      ignore (gc_collect gil);
      let o = Import.cached gil "os" "sep" in
      Alcotest.(check bool) "cached" true (o == Import.cached gil "os" "sep");
      Alcotest.(check string) "type_name" "str" (Object.type_name gil o);
      let l =
        Object.call_method gil (eval gil "'a,b'") "split"
          ~args:[| Conv.to_py Conv.string gil "," |]
          ()
      in
      Alcotest.(check (list string))
        "call_method" [ "a"; "b" ]
        (Conv.of_py_exn Conv.(list string) gil l);
      let d =
        Object.call gil (eval gil "dict")
          ~kwargs:[ ("x", Conv.to_py Conv.int gil 1) ]
          ()
      in
      Alcotest.(check string) "kwargs" "{'x': 1}" (Object.repr gil d);
      Object.set_attr gil
        (Import.module_ gil "__main__")
        "from_ocaml"
        (Conv.to_py Conv.int gil 9));
  Alcotest.(check int) "set_attr" 9 (py_eval_int "from_ocaml");
  (* with_gil is re-entrant *)
  Alcotest.(check int)
    "nested with_gil" 2
    (with_gil (fun _ -> with_gil (fun _ -> py_eval_int "2")))

(* ------------------------------------------------------------------------ *)
(* Micro-benchmark *)
(* ------------------------------------------------------------------------ *)

let test_tokens () =
  let escaped = with_gil (fun gil -> gil) in
  (match eval escaped "1" with
  | _ -> Alcotest.fail "escaped token accepted"
  | exception Invalid_argument _ -> ());
  with_gil (fun gil ->
      detach gil (fun () ->
          match eval gil "1" with
          | _ -> Alcotest.fail "token accepted inside detach"
          | exception Invalid_argument _ -> ()))

let test_scopes () =
  py_exec "t.keep_callable(lambda x: x + 1)";
  (match Atomic.get kept_callable with
  | None -> Alcotest.fail "not kept"
  | Some f -> (
      match f 1 with
      | _ -> Alcotest.fail "callable usable after its export returned"
      | exception Invalid_argument _ -> ()));
  py_exec "t.keep_nested([lambda x: x])";
  match Atomic.get kept_nested with
  | [ f ] -> (
      match f 1 with
      | _ -> Alcotest.fail "nested callable usable after its export returned"
      | exception Invalid_argument _ -> ())
  | _ -> Alcotest.fail "nested not kept"

let test_add_method () =
  py_exec "c2 = t.make_counter(4)\nc2.double()";
  Alcotest.(check int) "added method" 8 (py_eval_int "c2.get()");
  Alcotest.(check string)
    "signature" "()"
    (py_eval_str "str(__import__('inspect').signature(c2.double))");
  py_exec "del c2"

let test_fork_child () =
  py_exec
    "import os, warnings\n\
     warnings.simplefilter('ignore', DeprecationWarning)\n\
     pid = os.fork()\n\
     if pid == 0:\n\
    \    try:\n\
    \        t.add(1, 2)\n\
    \        os._exit(1)\n\
    \    except RuntimeError as e:\n\
    \        os._exit(42 if 'forked child' in str(e) else 2)\n\
     fork_status = os.waitstatus_to_exitcode(os.waitpid(pid, 0)[1])\n";
  Alcotest.(check int)
    "RuntimeError in the child" 42
    (py_eval_int "fork_status");
  (* and OCaml refuses Python in a forked child *)
  match Unix.fork () with
  | 0 ->
      let code =
        match with_gil (fun _ -> ()) with
        | () -> 1
        | exception Invalid_argument _ -> 0
      in
      Unix._exit code
  | pid -> (
      match Unix.waitpid [] pid with
      | _, Unix.WEXITED 0 -> ()
      | _ -> Alcotest.fail "with_gil allowed in a forked child")

let test_deep_nesting () =
  py_exec
    "def deep(n):\n\
    \    return 0 if n == 0 else 1 + t.apply(deep, n - 1)\n\
     try:\n\
    \    deep(5000)\n\
    \    deep_result = 'no error'\n\
     except RecursionError:\n\
    \    deep_result = 'RecursionError'\n";
  Alcotest.(check string)
    "5000-deep nesting" "RecursionError"
    (py_eval_str "deep_result");
  (* the bridge still works afterwards *)
  Alcotest.(check int) "after" 3 (py_eval_int "t.add(1, 2)")

let test_asyncio_signals () =
  py_exec "import asyncio, signal\nasyncio.run(asyncio.sleep(0))\n";
  Alcotest.(check bool)
    "asyncio restored the Python handler" true
    (py_eval_bool
       "signal.getsignal(signal.SIGINT) is signal.default_int_handler");
  (* routing is re-asserted: SIGINT during an OCaml export body *)
  (match with_signal_after 0.1 (fun () -> py_exec "t.spin_ms(3000)") with
  | () -> Alcotest.fail "no Sys.Break"
  | exception Sys.Break -> ());
  (* a Python handler installed by Python code still runs for signals that
     arrive during Python code, and OCaml keeps its own *)
  py_exec
    "import time\n\
     got = []\n\
     signal.signal(signal.SIGINT, lambda s, f: got.append(s))\n";
  with_signal_after 0.1 (fun () -> py_exec "time.sleep(0.4)");
  Alcotest.(check bool)
    "Python handler ran" true
    (py_eval_bool "got == [signal.SIGINT]");
  (match
     with_signal_after 0.1 (fun () ->
         let t0 = Unix.gettimeofday () in
         let r = ref [] in
         while Unix.gettimeofday () -. t0 < 3. do
           r := [ Unix.gettimeofday () ]
         done)
   with
  | () -> Alcotest.fail "no Sys.Break in OCaml"
  | exception Sys.Break -> ());
  py_exec "signal.signal(signal.SIGINT, signal.default_int_handler)"

(* SIGINTs while the main thread keeps crossing into Python and another OCaml
   systhread competes for the domain lock: every Sys.Break must be raised on
   the main thread. *)
let test_signal_ordering () =
  let wrong_thread = Atomic.make 0 in
  let stop = Atomic.make false in
  let busy =
    Thread.create
      (fun () ->
        while not (Atomic.get stop) do
          try
            let r = ref [] in
            for i = 1 to 1000 do
              r := [ i ]
            done;
            Thread.yield ()
          with
          | Sys.Break -> Atomic.incr wrong_thread
        done)
      ()
  in
  let main_breaks = ref 0 in
  let n = 20 in
  let sent = Atomic.make false in
  let sender =
    Thread.create
      (fun () ->
        for _ = 1 to n do
          try
            Thread.delay 0.04;
            Unix.kill (Unix.getpid ()) Sys.sigint
          with
          | Sys.Break -> Atomic.incr wrong_thread
        done;
        Atomic.set sent true)
      ()
  in
  (* Cross into Python until every signal was sent, then 0.2 s more so a
     late Sys.Break surfaces; a Sys.Break anywhere on this thread is
     counted. *)
  let settle_until = ref infinity in
  let continue_ = ref true in
  while !continue_ do
    try
      while !continue_ do
        py_exec "pass";
        if Atomic.get sent && Float.equal !settle_until infinity then
          settle_until := Unix.gettimeofday () +. 0.2;
        if Unix.gettimeofday () >= !settle_until then continue_ := false
      done
    with
    | Sys.Break -> incr main_breaks
  done;
  Thread.join sender;
  Atomic.set stop true;
  Thread.join busy;
  Atomic.set signal_ordering @@ (!main_breaks, n);
  Alcotest.(check int)
    "Sys.Break on another systhread" 0 (Atomic.get wrong_thread);
  Alcotest.(check bool) "Sys.Break on the main thread" true (!main_breaks >= 1)

let bench () =
  let time n f =
    let t0 = Unix.gettimeofday () in
    f n;
    (Unix.gettimeofday () -. t0) *. 1e9 /. float n
  in
  let n = 200_000 in
  let ident = with_gil (fun gil -> eval gil "lambda x: x") in
  let with_gil_only =
    time n (fun n ->
        for _ = 1 to n do
          with_gil (fun _ -> ())
        done)
  in
  let call_in_scope =
    with_gil (fun gil ->
        let one = Conv.to_py Conv.int gil 1 in
        time n (fun n ->
            for _ = 1 to n do
              ignore (Object.call gil ident ~args:[| one |] ())
            done))
  in
  let call_keep =
    with_gil ~keep_domain_lock:true (fun gil ->
        let one = Conv.to_py Conv.int gil 1 in
        time n (fun n ->
            for _ = 1 to n do
              ignore (Object.call gil ident ~args:[| one |] ())
            done))
  in
  let call_with_gil =
    time n (fun n ->
        for i = 1 to n do
          ignore
            (with_gil (fun gil ->
                 Conv.of_py_exn Conv.int gil
                   (Object.call gil ident
                      ~args:[| Conv.to_py Conv.int gil i |]
                      ())))
        done)
  in
  let py_to_ocaml =
    with_gil (fun gil ->
        exec gil
          "import time\n\
           def bench(n):\n\
          \    f = t.noop\n\
          \    t0 = time.perf_counter()\n\
          \    for _ in range(n):\n\
          \        f()\n\
          \    return (time.perf_counter() - t0) * 1e9 / n\n\
           def bench_add(n):\n\
          \    f = t.add\n\
          \    t0 = time.perf_counter()\n\
          \    for i in range(n):\n\
          \        f(i, 1)\n\
          \    return (time.perf_counter() - t0) * 1e9 / n\n";
        let f name =
          Object.call gil (eval gil name)
            ~args:[| Conv.to_py Conv.int gil n |]
            ()
        in
        ( Conv.of_py_exn Conv.float gil (f "bench"),
          Conv.of_py_exn Conv.float gil (f "bench_add") ))
  in
  let round_trip =
    with_gil (fun gil ->
        exec gil "def rt(x):\n    return t.add(x, 1)\n";
        let rt = eval gil "rt" in
        time (n / 2) (fun n ->
            for i = 1 to n do
              ignore
                (Conv.of_py_exn Conv.int gil
                   (Object.call gil rt ~args:[| Conv.to_py Conv.int gil i |] ()))
            done))
  in
  Printf.printf
    "\n\
     progress of other threads:\n\
    \  Python thread loop iterations during a 200 ms detached OCaml call: %d\n\
    \  OCaml thread iterations during a 200 ms Python call: %d (with \
     ~keep_domain_lock: %d)\n"
    (Atomic.get python_thread_ticks)
    (fst (Atomic.get ocaml_thread_ticks))
    (snd (Atomic.get ocaml_thread_ticks));
  Printf.printf
    "  SIGINTs sent while crossing into Python with a busy systhread: %d, \
     Sys.Break on the main thread: %d, elsewhere: 0\n"
    (snd (Atomic.get signal_ordering))
    (fst (Atomic.get signal_ordering));
  Printf.printf
    "\n\
     pyembed micro-benchmark (ns per operation, %d iterations):\n\
    \  with_gil (empty scope)                               %8.1f\n\
    \  OCaml->Python call, identity fn, inside one with_gil %8.1f\n\
    \    same with ~keep_domain_lock:true                   %8.1f\n\
    \  with_gil + int conversion + call + int conversion    %8.1f\n\
    \  Python->OCaml call, no args (export noop)            %8.1f\n\
    \  Python->OCaml call, add(i, 1) with conversions       %8.1f\n\
    \  round trip OCaml->Python->OCaml->Python->OCaml       %8.1f\n\
     %!"
    n with_gil_only call_in_scope call_keep call_with_gil (fst py_to_ocaml)
    (snd py_to_ocaml) round_trip

(* ------------------------------------------------------------------------ *)

let () =
  Sys.catch_break true;
  Sys.set_signal Sys.sigterm (Sys.Signal_handle (fun _ -> raise Sys.Break));
  init (config ());
  py_exec "import _pyembed_test as t";
  let tc name f = Alcotest.test_case name `Quick f in
  Alcotest.run ~and_exit:false "pyembed"
    [
      ( "lifecycle",
        [
          tc "init" test_init;
          tc "exit" test_exit;
          tc "exit and init failure modes" test_exit_modes;
          tc "gil tokens" test_tokens;
        ] );
      ( "conversions",
        [
          tc "values" test_conversions;
          tc "callables" test_callable;
          tc "callable scopes" test_scopes;
        ] );
      ( "exceptions",
        [
          tc "python to ocaml" test_python_errors;
          tc "ocaml to python" test_ocaml_errors;
          tc "resurrection" test_resurrection;
          tc "argument TypeError" test_argument_errors;
        ] );
      ( "lifetimes",
        [
          tc "deferred DECREF" test_deferred_decref;
          tc "class instances" test_class_lifecycle;
          tc "add_method" test_add_method;
        ] );
      ( "threads",
        [
          tc "nested calls" test_nested;
          tc "python thread during detached call" test_python_thread_progress;
          tc "off-main-thread calls rejected" test_off_main_thread;
          tc "ocaml thread during python call" test_ocaml_thread_progress;
          tc "fork child" test_fork_child;
          tc "5000-deep nesting" test_deep_nesting;
        ] );
      ( "signals",
        [
          tc "SIGINT in Python" test_sigint_in_python;
          tc "SIGINT in OCaml" test_sigint_in_ocaml;
          tc "asyncio keeps routing" test_asyncio_signals;
          tc "Sys.Break stays on the main thread" test_signal_ordering;
        ] );
      ( "misc",
        [
          tc "bundles" test_bundles;
          tc "frozen table" test_frozen;
          tc "objects" test_misc;
        ] );
    ];
  bench ()
