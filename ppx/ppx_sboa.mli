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
(** [[@@deriving sboa]]: a two-way {!Sboa.Conv.t} converter for a type
    declaration (registered with ppxlib; nothing to call).

    For [type foo = ...] it defines [foo_conv : foo Sboa.Conv.t] ([conv]
    for a type named [t]); a type parameter ['a] becomes a converter
    argument: [foo_conv : 'a Sboa.Conv.t -> 'a foo Sboa.Conv.t]. In a
    signature it declares the same value.

    Type expressions: [int], [float], [bool], [string] ([str]), [bytes]
    ([bytes]), [unit] ([None]), [option], [list], [array], tuples of 2 to 4
    elements, type variables, and other type constructors by naming
    convention ([M.t] -> [M.conv], [M.foo] -> [M.foo_conv], applied to the
    converters of their arguments, e.g. [Sboa.Counter.t] -> [Sboa.Counter.conv]).
    [[@sboa.conv e]] on a type expression uses converter [e];
    [[@sboa.bytes]] on [string] gives Python [bytes].

    Records become a Python class ({!Sboa.Conv.record}): named after the
    type in CamelCase ([scan_result] -> [ScanResult]; [t] takes the name of
    its module), or [[@@sboa.name "Name"]]; the type's doc comment is its
    docstring; [[@sboa.name "attr"]] renames a field.
    [[@@sboa.exception]] makes it an exception class
    ({!Sboa.Export.register_exception}).

    Variants: a constructor without arguments is its name ([str]), one with
    arguments a tuple [("Name", arg1, ...)] ({!Sboa.Conv.constructor});
    [[@sboa.name "name"]] renames a constructor.

    Not supported (a compile-time error): recursive types, inline records,
    polymorphic variants, GADTs, objects, functions. *)
