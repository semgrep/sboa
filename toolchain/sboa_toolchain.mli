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
(** Facts about the CPython an executable was built against, from the
    [sboa.config] that [toolchain/describe.py] generated (the values are
    compiled in).

    The point is a CPython that keeps C extension modules ([math],
    [_socket], [_ssl], ...) as shared objects in its own [lib-dynload]
    instead of compiling them into libpython (Homebrew, nix, distribution
    packages): when the application did not install them next to the
    executable (e.g. an executable run from the build tree),
    {!libdynload_dir} lets it fall back to that directory. *)

val version : string
(** The CPython version, e.g. ["3.13.16"]. *)

val platform : string
(** The toolchain's platform id, e.g. ["linux-gnu-x86_64"]. *)

val external_libdynload_dir : string option
(** The [lib-dynload] directory of the CPython built against, as an
    absolute path on the build machine, when it holds extension modules
    that ship; [None] when there are none (python-build-standalone compiles
    them into libpython) and on Windows. *)

val libdynload_dir : unit -> string option
(** The value for [Sboa.Config.libdynload_dir]: [None] (sboa's
    default, [<dir of executable>/libs/python3.X/lib-dynload]) when that
    directory exists or when there is no {!external_libdynload_dir};
    otherwise {!external_libdynload_dir}. *)
