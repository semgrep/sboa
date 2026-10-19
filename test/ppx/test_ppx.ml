(* Tests of [@@deriving sboa] (shapes.ml) and the typed exports, and the
   README's worked example (demo.ml, demo.py, demo.pyi). Python is
   initialized once with the stdlib of the CPython the test is linked with
   on sys.path (SBOA_STDLIB, set by dune). *)

open Sboa
open Shapes

let m = "_shapes"

(* Exports of shapes: an echo per type (the classes reach the module through
   them), a typed function with every kind of parameter, a detached one. *)
let () =
  let open Export in
  def ~module_:m ~name:"echo_nested"
    (pos "n" nested_conv @-> returning nested_conv)
    Fun.id;
  def ~module_:m ~name:"echo_scalars"
    (pos "s" scalars_conv @-> returning scalars_conv)
    Fun.id;
  def ~module_:m ~name:"echo_containers"
    (pos "c" containers_conv @-> returning containers_conv)
    Fun.id;
  def ~module_:m ~name:"describe" ~doc:"All kinds of parameters."
    (pos "a" Conv.int @-> pos "b" Conv.string @-> kw "c" Conv.bool
   @-> kw_opt "d" Counter.conv @-> returning Conv.string)
    (fun a b c d ->
      Option.iter (fun d -> Counter.add d a) d;
      Printf.sprintf "%d %s %b %b" a b c (Option.is_some d));
  def ~module_:m ~name:"nothing"
    (unit @-> returning Conv.(option string))
    (fun () -> None);
  def ~module_:m ~name:"detached" ~detach:true
    (pos "n" Conv.int @-> returning Conv.int)
    (fun n ->
      (* the GIL is released: taking it again works *)
      with_gil (fun gil -> ignore (eval gil "1"));
      n * 2);
  def ~module_:m ~name:"fail"
    (pos "reason" Conv.string @-> returning Conv.unit)
    (fun reason -> raise (Failed { reason; code = 3 }));
  (* untyped registrations, for the stub *)
  register ~module_:m ~name:"raw" ~signature:"x, /" ~doc:"Untyped."
    (fun _ _ _ -> Object.none);
  ignore
    (register_class ~module_:m ~name:"Handle" ~doc:"An OCaml value."
       ~methods:[ ("get", fun (n : int) gil _ _ -> Conv.to_py Conv.int gil n) ]
       ()
      : int Class.t);
  register_exception ~module_:m failure_conv (function
    | Failed f -> Some f
    | _ -> None)

let stdlib = Sys.getenv "SBOA_STDLIB"
let read path = In_channel.with_open_bin path In_channel.input_all

let contains s sub =
  let n = String.length sub in
  let rec go i =
    i + n <= String.length s
    && (String.equal (String.sub s i n) sub || go (i + 1))
  in
  go 0

let py gil code = exec gil code
let ev gil code = eval gil code

let check_py name code =
  with_gil (fun gil ->
      match py gil code with
      | () -> ()
      | exception Python_error e ->
          Alcotest.failf "%s: %s" name (Python_error.to_string e))

(* OCaml -> Python -> OCaml is the identity. *)
let round_trip (type a) name (c : a Conv.t) (v : a) =
  with_gil (fun gil ->
      match Conv.of_py c gil (Conv.to_py c gil v) with
      | Ok v' -> Alcotest.(check bool) name true (v = v')
      | Error e -> Alcotest.failf "%s: %s" name (Conv.error_to_string e))

let error_of (type a) (c : a Conv.t) code =
  with_gil (fun gil ->
      match Conv.of_py c gil (ev gil code) with
      | Ok _ -> "no error"
      | Error e -> Conv.error_to_string e)

let scalars =
  {
    i = -3;
    f = 1.5;
    b = true;
    s = "h\xc3\xa9";
    raw = "\x00\xff";
    buf = Bytes.of_string "ab";
    u = ();
  }

let containers =
  {
    opt = Some 1;
    xs = [ "a"; "b" ];
    arr = [| 1.; 2. |];
    pair = (1, "x");
    triple = (1, 2, false);
    quad = (1, 2, 3, "q");
    renamed = 7;
  }

let test_round_trips () =
  round_trip "scalars" scalars_conv scalars;
  round_trip "containers" containers_conv containers;
  round_trip "containers None" containers_conv
    { containers with opt = None; xs = []; arr = [||] };
  round_trip "point" Point.conv { Point.x = 1; y = 2 };
  List.iter
    (fun s -> round_trip "shape" shape_conv s)
    [
      Empty;
      Circle 2.5;
      Rect ({ x = 0; y = 0 }, { x = 1; y = 1 });
      Labelled [ "a" ];
    ];
  round_trip "box" (box_conv Conv.int) { value = 1; tag = "t" };
  round_trip "box of shape" (box_conv shape_conv)
    { value = Circle 1.; tag = "t" };
  round_trip "choice" (choice_conv Conv.int Conv.string) (Left 1);
  round_trip "choice" (choice_conv Conv.int Conv.string) (Right "r");
  round_trip "points" points_conv [ { x = 1; y = 2 } ];
  round_trip "failure" failure_conv { reason = "r"; code = 1 }

(* What Python sees. *)
let test_python_view () =
  check_py "python view"
    {|
import _shapes, pickle, copy
s = _shapes.echo_scalars(_shapes.Scalars(-3, 1.5, True, "hé", b"\x00\xff", b"ab", None))
assert s.raw == b"\x00\xff" and s.buf == b"ab" and s.u is None
c = _shapes.echo_containers(_shapes.Containers(None, ("a",), [1, 2.5], (1, "x"), [1, 2, False], (1, 2, 3, "q"), 7))
assert c.opt is None and c.xs == ["a"] and c.arr == [1.0, 2.5] and c.pair == (1, "x")
assert c.py_name == 7 and not hasattr(c, "renamed")
P = _shapes.Point
assert P.__module__ == "_shapes" and P.__doc__ == "A point."
p = P(1, y=2)
assert repr(p) == "Point(x=1, y=2)" and p == P(1, 2) and p != P(2, 1)
assert hash(p) == hash(P(1, 2)) and p != (1, 2)
assert pickle.loads(pickle.dumps(p)) == p and copy.copy(p) == p
try:
    p.x = 3
    raise AssertionError("mutable")
except AttributeError:
    pass
for bad in [lambda: P(1), lambda: P(1, 2, 3), lambda: P(1, z=2)]:
    try:
        bad()
        raise AssertionError("accepted")
    except TypeError:
        pass
n = _shapes.echo_nested(_shapes.Nested(
    ["Empty", ("Circle", 2.0), ("Rect", P(0, 0), P(1, 1)), ("labelled", ["l"])],
    _shapes.Box(5, "t"),
    ("Right", "r"),
    [P(3, 4)],
    _shapes.Counter(),
    {"any": "object"}))
assert n.shapes == ["Empty", ("Circle", 2.0), ("Rect", P(0, 0), P(1, 1)), ("labelled", ["l"])]
assert n.boxed == _shapes.Box(5, "t") and n.choice == ("Right", "r")
assert n.points == [P(3, 4)] and n.obj == {"any": "object"}
assert isinstance(n.counter, _shapes.Counter)
# any object with the attributes converts
class Duck:
    x = 10
    y = 20
assert _shapes.echo_nested(_shapes.Nested([], None, ("Left", 1), [Duck()], None, 0)).points == [P(10, 20)]
|}

let test_errors () =
  let check name expected got = Alcotest.(check string) name expected got in
  check "wrong field type" "x: expected int, got str"
    (error_of Point.conv "__import__('_shapes').Point('a', 2)");
  check "missing attribute"
    "y: expected an attribute, got nothing (missing on SimpleNamespace)"
    (error_of Point.conv "__import__('types').SimpleNamespace(x=1)");
  check "nested path" "[1].y: expected int, got NoneType"
    (error_of points_conv
       "[__import__('_shapes').Point(1, 2), \
        __import__('types').SimpleNamespace(x=1, y=None)]");
  check "unknown constructor"
    {|expected Literal["Empty"] | tuple[Literal["Circle"], float] | tuple[Literal["Rect"], Point, Point] | tuple[Literal["labelled"], list[str]], got "Square"|}
    (error_of shape_conv "'Square'");
  check "constructor arity"
    {|expected Literal["Empty"] | tuple[Literal["Circle"], float] | tuple[Literal["Rect"], Point, Point] | tuple[Literal["labelled"], list[str]], got "Circle" with 2 arguments|}
    (error_of shape_conv "('Circle', 1.0, 2.0)");
  check "constructor argument" "[2].x: expected int, got str"
    (error_of shape_conv
       "('Rect', __import__('_shapes').Point(0, 0), \
        __import__('_shapes').Point('a', 0))");
  check "not a constructor"
    {|expected Literal["Empty"] | tuple[Literal["Circle"], float] | tuple[Literal["Rect"], Point, Point] | tuple[Literal["labelled"], list[str]], got int|}
    (error_of shape_conv "3");
  check_py "export errors"
    {|
import _shapes
def type_error(f, msg):
    try:
        f()
    except TypeError as e:
        assert str(e) == msg, str(e)
    else:
        raise AssertionError("no error")
type_error(lambda: _shapes.describe(1, 2, c=True), "argument 'b': expected str, got int")
type_error(lambda: _shapes.describe(1, "b"), "argument 'c': expected a value, got nothing (missing)")
type_error(lambda: _shapes.describe(1, "b", 3, c=True), "expected at most 2 positional arguments, got 3")
type_error(lambda: _shapes.describe(1, "b", c=True, e=1), "expected keyword arguments among [c, d], got 'e'")
type_error(lambda: _shapes.echo_nested(_shapes.Point(1, 2)), "argument 'n'.shapes: expected an attribute, got nothing (missing on Point)")
|}

let test_exports () =
  check_py "typed exports"
    {|
import _shapes, inspect
c = _shapes.Counter()
assert _shapes.describe(2, "b", c=False, d=c) == "2 b false true" and c.value == 2
assert _shapes.describe(2, "b", c=True, d=None) == "2 b true false"
assert _shapes.nothing() is None
assert _shapes.detached(21) == 42
assert str(inspect.signature(_shapes.describe)) == "(a, b, /, *, c, d=None)"
assert str(inspect.signature(_shapes.nothing)) == "()"
assert _shapes.describe.__doc__ == "All kinds of parameters."
assert not hasattr(_shapes, "__sboa_init__")
try:
    _shapes.fail("why")
except _shapes.Failure as e:
    assert (e.reason, e.code) == ("why", 3) and e.args == ("why", 3)
    assert repr(e) == "Failure(reason='why', code=3)"
    assert isinstance(e, _shapes.OCamlError)
else:
    raise AssertionError("no exception")
|};
  (* the derived exception resurrects the OCaml one when it crosses back *)
  with_gil (fun gil ->
      match ev gil "__import__('_shapes').fail('back')" with
      | _ -> Alcotest.fail "no exception"
      | exception Failed { reason; code } ->
          Alcotest.(check (pair string int))
            "resurrected" ("back", 3) (reason, code))

let test_stub () =
  let stub = Export.stub m in
  List.iter
    (fun line ->
      if not (contains stub line) then
        Alcotest.failf "stub of %s lacks %S:\n%s" m line stub)
    [
      "\nfrom typing import Literal\n";
      "\nclass Point:\n    \"\"\"A point.\"\"\"\n    x: int\n    y: int\n";
      "\nclass Box:\n    value: object\n    tag: str\n";
      "    shapes: list[Literal[\"Empty\"] | tuple[Literal[\"Circle\"], float] \
       | tuple[Literal[\"Rect\"], Point, Point] | tuple[Literal[\"labelled\"], \
       list[str]]]\n";
      "    counter: Counter | None\n";
      "\nclass Failure(OCamlError):\n";
      "\n\
       def describe(a: int, b: str, /, *, c: bool, d: Counter | None = None) \
       -> str:\n\
      \    \"\"\"All kinds of parameters.\"\"\"\n";
      "\ndef nothing() -> str | None: ...\n";
      "\ndef raw(x, /):\n    \"\"\"Untyped.\"\"\"\n";
      "\n\
       class Handle:\n\
      \    \"\"\"An OCaml value.\"\"\"\n\
      \    def get(self, *args, **kwargs): ...\n";
    ]

let test_register_exception_checks () =
  match Export.register_exception ~module_:m Point.conv (fun _ -> None) with
  | () -> Alcotest.fail "accepted a plain record"
  | exception Invalid_argument _ -> ()

(* The README's worked example. *)
let test_demo () =
  check_py "demo.py" (read "demo.py");
  Alcotest.(check string) "demo.pyi" (read "demo.pyi") (Export.stub "_demo")

let readme_block file =
  (* the stub from its first class of the demo on (the README shows that) *)
  let s = read file in
  if Filename.check_suffix file ".pyi" then
    let rec find i =
      if String.sub s i 15 = "\nclass RunResul" then i + 1 else find (i + 1)
    in
    String.sub s (find 0) (String.length s - find 0)
  else s

let test_readme () =
  let readme = read "../../README.md" in
  List.iter
    (fun f ->
      if not (contains readme (readme_block f)) then
        Alcotest.failf "README.md does not contain test/ppx/%s (as is)" f)
    [ "demo.ml"; "demo.py"; "demo.pyi" ]

let () =
  ignore Demo.run;
  init
    {
      (Config.default ()) with
      extra_sys_path = [ stdlib; Filename.concat stdlib "lib-dynload" ];
    };
  let tc name f = Alcotest.test_case name `Quick f in
  Alcotest.run "sboa.ppx"
    [
      ( "ppx",
        [
          tc "round trips" test_round_trips;
          tc "python view" test_python_view;
          tc "errors" test_errors;
          tc "typed exports" test_exports;
          tc "stub" test_stub;
          tc "register_exception checks" test_register_exception_checks;
          tc "demo" test_demo;
          tc "readme" test_readme;
        ] );
    ]
