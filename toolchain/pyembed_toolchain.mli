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
(** Facts about the CPython toolchain an executable was built with, from
    the [cpython-embed.config] that [toolchain/fetch.sh] generated (the
    values are compiled in).

    The point is the external-prefix build ([PYEMBED_PREFIX], e.g. a
    Homebrew [python@3.13]): such a CPython keeps C extension modules
    ([math], [_socket], [_ssl], ...) as shared objects in its own
    [lib-dynload] instead of compiling them into libpython, and nothing
    copies them next to the executable. {!libdynload_dir} lets the embedding
    application fall back to that directory. *)

val version : string
(** The CPython version, e.g. ["3.13.16"]. *)

val platform : string
(** The toolchain's platform id, e.g. ["linux-gnu-x86_64"]. *)

val external_libdynload_dir : string option
(** The [lib-dynload] directory of the external CPython, as an absolute
    path on the build machine; [None] for the downloaded
    python-build-standalone runtime (its extension modules are in
    libpython). *)

val libdynload_dir : unit -> string option
(** The value for [Pyembed.Config.libdynload_dir]: [None] (pyembed's
    default, [<dir of executable>/libs/python3.X/lib-dynload]) when that
    directory exists or when there is no {!external_libdynload_dir};
    otherwise {!external_libdynload_dir}. *)
