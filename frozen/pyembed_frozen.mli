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
(** The frozen-module table of the embedding executable.

    Linking the [pyembed.frozen] library is all that is needed: it is built
    with [-linkall] and its initialization references the C object holding
    [pyembed_frozen_table] (the bundle importer and the [encodings] package),
    so that table replaces the empty default of [pyembed.cpython] and
    {!Pyembed.init} installs the importer over the registered bundles. *)

val linked : bool
(** Always [true]; evaluating the module forces the C table to be linked. *)
