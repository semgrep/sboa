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
(* The [@@deriving sboa] deriver (see the .mli for what it supports).

   One value per type declaration, built from Sboa.Conv combinators: a type
   expression maps to a converter expression ([conv_of_type]); a record to
   Sboa.Conv.record over a class created once, outside the function of the
   type parameters (so every instantiation shares the Python class); a
   variant to Sboa.Conv.make with a match per direction. The generated code
   refers to Sboa only through fully qualified names. *)

open Ppxlib
module A = Ast_builder.Default

let deriver = "sboa"

(* ------------------------------------------------------------------------ *)
(* Attributes *)
(* ------------------------------------------------------------------------ *)

let string_payload = Ast_pattern.(single_expr_payload (estring __))

let td_name =
  Attribute.declare "sboa.name" Attribute.Context.type_declaration
    string_payload Fun.id

let td_exception =
  Attribute.declare "sboa.exception" Attribute.Context.type_declaration
    Ast_pattern.(pstr nil)
    ()

let ld_name =
  Attribute.declare "sboa.name" Attribute.Context.label_declaration
    string_payload Fun.id

let cd_name =
  Attribute.declare "sboa.name" Attribute.Context.constructor_declaration
    string_payload Fun.id

let ct_conv =
  Attribute.declare "sboa.conv" Attribute.Context.core_type
    Ast_pattern.(single_expr_payload __)
    Fun.id

let ct_bytes =
  Attribute.declare "sboa.bytes" Attribute.Context.core_type
    Ast_pattern.(pstr nil)
    ()

let ld_conv =
  Attribute.declare "sboa.conv" Attribute.Context.label_declaration
    Ast_pattern.(single_expr_payload __)
    Fun.id

let ld_bytes =
  Attribute.declare "sboa.bytes" Attribute.Context.label_declaration
    Ast_pattern.(pstr nil)
    ()

(* The doc comment of a declaration, trimmed. *)
let doc_of attrs =
  List.find_map
    (fun a ->
      match a.attr_name.txt with
      | "ocaml.doc"
      | "doc" -> (
          match a.attr_payload with
          | PStr
              [
                {
                  pstr_desc =
                    Pstr_eval
                      ( {
                          pexp_desc = Pexp_constant (Pconst_string (s, _, _));
                          _;
                        },
                        _ );
                  _;
                };
              ] ->
              Some (String.trim s)
          | _ -> None)
      | _ -> None)
    attrs
  |> Option.value ~default:""

(* ------------------------------------------------------------------------ *)
(* Names *)
(* ------------------------------------------------------------------------ *)

let conv_name = function
  | "t" -> "conv"
  | name -> name ^ "_conv"

let param_name v = "sboa_" ^ v

(* The record class, a separate binding so that the converter of a
   parameterized type stays a (generalizable) function. *)
let class_var td = "_sboa_class_" ^ td.ptype_name.txt

(* scan_result -> ScanResult *)
let camel s =
  String.split_on_char '_' s
  |> List.filter (fun w -> not (String.equal w ""))
  |> List.map String.capitalize_ascii
  |> String.concat ""

let class_name ~path td =
  match Attribute.get td_name td with
  | Some n -> n
  | None -> (
      match td.ptype_name.txt with
      | "t" -> (
          match List.rev (Code_path.submodule_path path) with
          | m :: _ -> camel m
          | [] -> camel (Code_path.main_module_name path))
      | n -> camel n)

let unsupported ~loc what =
  Location.raise_errorf ~loc "ppx_sboa: %s is not supported" what

(* ------------------------------------------------------------------------ *)
(* Type expressions -> converters *)
(* ------------------------------------------------------------------------ *)

let rec conv_of_type (ct : core_type) : expression =
  let loc = ct.ptyp_loc in
  match Attribute.get ct_conv ct with
  | Some e -> e
  | None -> (
      match Attribute.get ct_bytes ct with
      | Some () -> [%expr Sboa.Conv.bytes]
      | None -> (
          match ct.ptyp_desc with
          | Ptyp_var v -> A.evar ~loc (param_name v)
          | Ptyp_tuple [ a; b ] ->
              [%expr Sboa.Conv.pair [%e conv_of_type a] [%e conv_of_type b]]
          | Ptyp_tuple [ a; b; c ] ->
              [%expr
                Sboa.Conv.tuple3 [%e conv_of_type a] [%e conv_of_type b]
                  [%e conv_of_type c]]
          | Ptyp_tuple [ a; b; c; d ] ->
              [%expr
                Sboa.Conv.tuple4 [%e conv_of_type a] [%e conv_of_type b]
                  [%e conv_of_type c] [%e conv_of_type d]]
          | Ptyp_tuple _ -> unsupported ~loc "a tuple of more than 4 elements"
          | Ptyp_constr ({ txt = Lident "int"; _ }, []) -> [%expr Sboa.Conv.int]
          | Ptyp_constr ({ txt = Lident "float"; _ }, []) ->
              [%expr Sboa.Conv.float]
          | Ptyp_constr ({ txt = Lident "bool"; _ }, []) ->
              [%expr Sboa.Conv.bool]
          | Ptyp_constr ({ txt = Lident "string"; _ }, []) ->
              [%expr Sboa.Conv.string]
          | Ptyp_constr ({ txt = Lident "bytes"; _ }, []) ->
              [%expr
                Sboa.Conv.map Bytes.of_string Bytes.to_string Sboa.Conv.bytes]
          | Ptyp_constr ({ txt = Lident "unit"; _ }, []) ->
              [%expr Sboa.Conv.unit]
          | Ptyp_constr ({ txt = Lident "option"; _ }, [ a ]) ->
              [%expr Sboa.Conv.option [%e conv_of_type a]]
          | Ptyp_constr ({ txt = Lident "list"; _ }, [ a ]) ->
              [%expr Sboa.Conv.list [%e conv_of_type a]]
          | Ptyp_constr ({ txt = Lident "array"; _ }, [ a ]) ->
              [%expr Sboa.Conv.array [%e conv_of_type a]]
          | Ptyp_constr ({ txt = lid; loc }, args) ->
              let lid =
                match lid with
                | Lident n -> Lident (conv_name n)
                | Ldot (m, n) -> Ldot (m, conv_name n)
                | Lapply _ -> unsupported ~loc "a functor application"
              in
              A.eapply ~loc
                (A.pexp_ident ~loc { txt = lid; loc })
                (List.map conv_of_type args)
          | _ -> unsupported ~loc "this type expression"))

(* ------------------------------------------------------------------------ *)
(* Declarations *)
(* ------------------------------------------------------------------------ *)

(* [[@sboa.conv]] and [[@sboa.bytes]] also apply after the field's [;]. *)
let field_conv ld =
  let loc = ld.pld_loc in
  match (Attribute.get ld_conv ld, Attribute.get ld_bytes ld) with
  | Some e, _ -> e
  | None, Some () -> [%expr Sboa.Conv.bytes]
  | None, None -> conv_of_type ld.pld_type

let any ~loc c = [%expr Sboa.Conv.Any [%e c]]
let elist ~loc l = A.elist ~loc l
let estring ~loc s = A.estring ~loc s

(* The type itself with wildcard parameters, for annotations. *)
let self_type ~loc td =
  A.ptyp_constr ~loc
    { txt = Lident td.ptype_name.txt; loc }
    (List.map (fun _ -> A.ptyp_any ~loc) td.ptype_params)

let params td =
  List.map
    (fun (ct, _) ->
      match ct.ptyp_desc with
      | Ptyp_var v -> v
      | _ -> unsupported ~loc:ct.ptyp_loc "an anonymous type parameter")
    td.ptype_params

(* [fun sboa_a sboa_b -> body] *)
let abstract_params ~loc td body =
  List.fold_right
    (fun v body -> [%expr fun [%p A.pvar ~loc (param_name v)] -> [%e body]])
    (params td) body

(* let c0 = conv0 and ... in body *)
let bind_convs ~loc convs body =
  match convs with
  | [] -> body
  | _ ->
      A.pexp_let ~loc Nonrecursive
        (List.map
           (fun (name, c) ->
             A.value_binding ~loc ~pat:(A.pvar ~loc name) ~expr:c)
           convs)
        body

(* match e with Error e -> Error e | Ok p -> k *)
let bind_ok ~loc e p k =
  [%expr
    match [%e e] with
    | Error e -> Error e
    | Ok [%p p] -> [%e k]]

let record_conv ~loc ~path td (labels : label_declaration list) =
  let fields =
    List.mapi
      (fun i ld ->
        let py =
          Option.value (Attribute.get ld_name ld) ~default:ld.pld_name.txt
        in
        (i, ld, py, Printf.sprintf "c%d" i, Printf.sprintf "v%d" i))
      labels
  in
  let self = self_type ~loc td in
  let to_fields =
    A.pexp_array ~loc
      (List.map
         (fun (_, ld, _, c, _) ->
           [%expr
             Sboa.Conv.to_py [%e A.evar ~loc c] gil
               [%e
                 A.pexp_field ~loc [%expr r]
                   { txt = Lident ld.pld_name.txt; loc }]])
         fields)
  in
  let build =
    A.pexp_constraint ~loc
      (A.pexp_record ~loc
         (List.map
            (fun (_, ld, _, _, v) ->
              ({ txt = Lident ld.pld_name.txt; loc }, A.evar ~loc v))
            fields)
         None)
      self
  in
  let of_py =
    List.fold_right
      (fun (_, _, py, c, v) k ->
        bind_ok ~loc
          [%expr
            Sboa.Conv.attr gil o [%e estring ~loc py]
              (Sboa.Conv.of_py [%e A.evar ~loc c])]
          (A.pvar ~loc v) k)
      fields
      [%expr Ok [%e build]]
  in
  let exception_ =
    match Attribute.get td_exception td with
    | Some () -> [%expr true]
    | None -> [%expr false]
  in
  let cls = A.evar ~loc (class_var td) in
  ( Some
      [%expr
        Sboa.Conv.record_class
          ~doc:[%e estring ~loc (doc_of td.ptype_attributes)]
          ~exception_:[%e exception_]
          ~name:[%e estring ~loc (class_name ~path td)]
          [%e
            elist ~loc
              (List.map (fun (_, _, py, _, _) -> estring ~loc py) fields)]],
    abstract_params ~loc td
      (bind_convs ~loc
         (List.map (fun (_, ld, _, c, _) -> (c, field_conv ld)) fields)
         [%expr
           Sboa.Conv.record [%e cls]
             [%e
               elist ~loc
                 (List.map
                    (fun (_, _, _, c, _) -> any ~loc (A.evar ~loc c))
                    fields)]
             ~to_fields:(fun gil (r : [%t self]) -> [%e to_fields])
             ~of_py:(fun gil o -> [%e of_py])]) )

let variant_conv ~loc td (cds : constructor_declaration list) =
  let ctors =
    List.mapi
      (fun i cd ->
        (match cd.pcd_res with
        | Some _ -> unsupported ~loc:cd.pcd_loc "a GADT constructor"
        | None -> ());
        let args =
          match cd.pcd_args with
          | Pcstr_tuple args -> args
          | Pcstr_record _ -> unsupported ~loc:cd.pcd_loc "an inline record"
        in
        let tag =
          Option.value (Attribute.get cd_name cd) ~default:cd.pcd_name.txt
        in
        let convs =
          List.mapi (fun j a -> (Printf.sprintf "c%d_%d" i j, a)) args
        in
        (cd, tag, convs))
      cds
  in
  let self = self_type ~loc td in
  let ty_name c =
    [%expr Option.value ~default:"object" (Sboa.Conv.ty [%e c])]
  in
  let quoted tag = Printf.sprintf "%S" tag in
  let constants =
    List.filter_map
      (fun (_, tag, convs) -> if List.is_empty convs then Some tag else None)
      ctors
  in
  let ty =
    let lit =
      match constants with
      | [] -> []
      | l ->
          [
            estring ~loc
              (Printf.sprintf "Literal[%s]"
                 (String.concat ", " (List.map quoted l)));
          ]
    in
    let tuples =
      List.filter_map
        (fun (_, tag, convs) ->
          match convs with
          | [] -> None
          | _ ->
              Some
                [%expr
                  String.concat ""
                    [%e
                      elist ~loc
                        ([
                           estring ~loc
                             (Printf.sprintf "tuple[Literal[%s]" (quoted tag));
                         ]
                        @ List.concat_map
                            (fun (c, _) ->
                              [ estring ~loc ", "; ty_name (A.evar ~loc c) ])
                            convs
                        @ [ estring ~loc "]" ])]])
        ctors
    in
    [%expr String.concat " | " [%e elist ~loc (lit @ tuples)]]
  in
  let to_py =
    A.pexp_match ~loc
      [%expr (x : [%t self])]
      (List.map
         (fun (cd, tag, convs) ->
           let vars = List.mapi (fun j _ -> Printf.sprintf "a%d" j) convs in
           let pat =
             A.pconstruct cd
               (match vars with
               | [] -> None
               | [ v ] -> Some (A.pvar ~loc v)
               | vs -> Some (A.ppat_tuple ~loc (List.map (A.pvar ~loc) vs)))
           in
           A.case ~lhs:pat ~guard:None
             ~rhs:
               [%expr
                 Sboa.Conv.constructor gil [%e estring ~loc tag]
                   [%e
                     A.pexp_array ~loc
                       (List.map2
                          (fun (c, _) v ->
                            [%expr
                              Sboa.Conv.to_py [%e A.evar ~loc c] gil
                                [%e A.evar ~loc v]])
                          convs vars)]])
         ctors)
  in
  let of_py =
    A.pexp_match ~loc
      [%expr Sboa.Conv.constructor_of_py ~expected:ty gil o]
      ([ A.case ~lhs:[%pat? Error e] ~guard:None ~rhs:[%expr Error e] ]
      @ List.map
          (fun (cd, tag, convs) ->
            let objs = List.mapi (fun j _ -> Printf.sprintf "o%d" j) convs in
            let vars = List.mapi (fun j _ -> Printf.sprintf "a%d" j) convs in
            let value =
              A.pexp_construct ~loc
                { txt = Lident cd.pcd_name.txt; loc }
                (match vars with
                | [] -> None
                | [ v ] -> Some (A.evar ~loc v)
                | vs -> Some (A.pexp_tuple ~loc (List.map (A.evar ~loc) vs)))
            in
            let body =
              List.fold_right
                (fun ((j, (c, _)), (o, v)) k ->
                  bind_ok ~loc
                    [%expr
                      Sboa.Conv.with_path
                        (Sboa.Conv.Index [%e A.eint ~loc (j + 1)])
                        (Sboa.Conv.of_py [%e A.evar ~loc c])
                        gil [%e A.evar ~loc o]]
                    (A.pvar ~loc v) k)
                (List.combine
                   (List.mapi (fun j c -> (j, c)) convs)
                   (List.combine objs vars))
                [%expr Ok ([%e value] : [%t self])]
            in
            A.case
              ~lhs:
                [%pat?
                  Ok
                    ( [%p A.pstring ~loc tag],
                      [%p A.ppat_array ~loc (List.map (A.pvar ~loc) objs)] )]
              ~guard:None ~rhs:body)
          ctors
      @ [
          A.case
            ~lhs:[%pat? Ok (tag, args)]
            ~guard:None
            ~rhs:[%expr Sboa.Conv.bad_constructor ~expected:ty tag args];
        ])
  in
  let convs = List.concat_map (fun (_, _, convs) -> convs) ctors in
  ( None,
    abstract_params ~loc td
      (bind_convs ~loc
         (List.map (fun (c, a) -> (c, conv_of_type a)) convs)
         [%expr
           let ty = [%e ty] in
           Sboa.Conv.make ~ty
             ~parts:
               [%e
                 elist ~loc
                   (List.map (fun (c, _) -> any ~loc (A.evar ~loc c)) convs)]
             ~to_py:(fun gil x -> [%e to_py])
             ~of_py:(fun gil o -> [%e of_py])
             ()]) )

let conv_of_decl ~path td =
  let loc = td.ptype_loc in
  match td.ptype_kind with
  | Ptype_record labels -> record_conv ~loc ~path td labels
  | Ptype_variant cds -> variant_conv ~loc td cds
  | Ptype_open -> unsupported ~loc "an extensible variant"
  | Ptype_abstract -> (
      match td.ptype_manifest with
      | Some ct -> (None, abstract_params ~loc td (conv_of_type ct))
      | None -> unsupported ~loc "an abstract type")

let generate_impl ~ctxt (_rec_flag, tds) =
  let path = Expansion_context.Deriver.code_path ctxt in
  List.concat_map
    (fun td ->
      let loc = td.ptype_loc in
      let value name expr =
        A.pstr_value ~loc Nonrecursive
          [ A.value_binding ~loc ~pat:(A.pvar ~loc name) ~expr ]
      in
      let cls, conv = conv_of_decl ~path td in
      Option.to_list (Option.map (value (class_var td)) cls)
      @ [ value (conv_name td.ptype_name.txt) conv ])
    tds

let generate_intf ~ctxt:_ (_rec_flag, tds) =
  List.map
    (fun td ->
      let loc = td.ptype_loc in
      let conv t = [%type: [%t t] Sboa.Conv.t] in
      let self =
        A.ptyp_constr ~loc
          { txt = Lident td.ptype_name.txt; loc }
          (List.map fst td.ptype_params)
      in
      let ty =
        List.fold_right
          (fun (p, _) t -> [%type: [%t conv p] -> [%t t]])
          td.ptype_params (conv self)
      in
      A.psig_value ~loc
        (A.value_description ~loc
           ~name:{ txt = conv_name td.ptype_name.txt; loc }
           ~type_:ty ~prim:[]))
    tds

let () =
  ignore
    (Deriving.add deriver
       ~str_type_decl:(Deriving.Generator.V2.make_noarg generate_impl)
       ~sig_type_decl:(Deriving.Generator.V2.make_noarg generate_intf))
