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
(* Forces frozen_anchor.o (and the frozen table it includes) into the link;
   see frozen_anchor.c and the dune file. *)

external anchor : unit -> unit = "sboa_frozen_anchor"

let linked =
  anchor ();
  true
