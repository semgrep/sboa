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
(* sboa.disabled: registration is accepted (it runs as a top-level effect
   of linked libraries), anything needing an interpreter raises
   Not_available. *)

let () =
  Sboa.Export.register ~module_:"_disabled_test" ~name:"f" (fun _ _ _ ->
      Sboa.Object.none)

let raises_not_available f =
  match f () with
  | _ -> Alcotest.fail "expected Sboa.Not_available"
  | exception Sboa.Not_available -> ()

let () =
  Alcotest.run "sboa.disabled"
    [
      ( "disabled",
        [
          Alcotest.test_case "init" `Quick (fun () ->
              raises_not_available (fun () ->
                  Sboa.init (Sboa.Config.default ())));
          Alcotest.test_case "with_gil" `Quick (fun () ->
              raises_not_available (fun () -> Sboa.with_gil (fun _ -> ())));
          Alcotest.test_case "state" `Quick (fun () ->
              Alcotest.(check bool)
                "not initialized" false (Sboa.is_initialized ());
              Sboa.gc_flush ();
              Alcotest.(check bool) "none" true Sboa.Object.(is_none none));
        ] );
    ]
