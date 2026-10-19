type run_result = { output : string; exit_code : int; log : string }
[@@deriving sboa]
(** What run did. *)

type run_error = { message : string; exit_code : int }
[@@deriving sboa] [@@sboa.exception]
(** Why run failed. *)

exception Run_error of run_error

(* The other direction: Python's os.path.basename as an OCaml function. *)
let basename =
  Sboa.Import.(
    def ~module_:"os.path" ~name:"basename"
      (pos "path" Sboa.Conv.string @-> returning Sboa.Conv.string))

let run argv verbose =
  match argv with
  | [] -> raise (Run_error { message = "nothing to run"; exit_code = 2 })
  | cmd :: _ ->
      let log = if verbose = Some true then "ran " ^ basename cmd else "" in
      { output = String.concat " " argv; exit_code = 0; log }

let () =
  let open Sboa.Export in
  def ~module_:"_demo" ~name:"run" ~doc:"Run argv."
    (pos "argv" Sboa.Conv.(list string)
    @-> kw_opt "verbose" Sboa.Conv.bool
    @-> returning run_result_conv)
    run;
  register_exception ~module_:"_demo" run_error_conv (function
    | Run_error e -> Some e
    | _ -> None)
