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
(* pyembed.disabled: registration is accepted (it runs as a top-level effect
   of linked libraries), anything needing an interpreter raises
   Not_available. *)

let () =
  Pyembed.Export.register ~module_:"_disabled_test" ~name:"f" (fun _ _ _ ->
      Pyembed.Object.none)

let raises_not_available f =
  match f () with
  | _ -> Alcotest.fail "expected Pyembed.Not_available"
  | exception Pyembed.Not_available -> ()

let () =
  Alcotest.run "pyembed.disabled"
    [
      ( "disabled",
        [
          Alcotest.test_case "init" `Quick (fun () ->
              raises_not_available (fun () ->
                  Pyembed.init (Pyembed.Config.default ())));
          Alcotest.test_case "with_gil" `Quick (fun () ->
              raises_not_available (fun () -> Pyembed.with_gil (fun _ -> ())));
          Alcotest.test_case "state" `Quick (fun () ->
              Alcotest.(check bool)
                "not initialized" false
                (Pyembed.is_initialized ());
              Pyembed.gc_flush ();
              Alcotest.(check bool) "none" true Pyembed.Object.(is_none none));
        ] );
    ]
