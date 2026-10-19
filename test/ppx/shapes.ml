(* One type per shape the deriver supports. *)

type scalars = {
  i : int;
  f : float;
  b : bool;
  s : string;
  raw : string; [@sboa.bytes]
  buf : bytes;
  u : unit;
}
[@@deriving sboa]

type containers = {
  opt : int option;
  xs : string list;
  arr : float array;
  pair : int * string;
  triple : int * int * bool;
  quad : int * int * int * string;
  renamed : int; [@sboa.name "py_name"]
}
[@@deriving sboa]

module Point = struct
  type t = { x : int; y : int } [@@deriving sboa]
  (** A point. *)
end

type shape =
  | Empty
  | Circle of float
  | Rect of Point.t * Point.t
  | Labelled of string list [@sboa.name "labelled"]
[@@deriving sboa]

type 'a box = { value : 'a; tag : string } [@@deriving sboa] [@@sboa.name "Box"]
type ('a, 'b) choice = Left of 'a | Right of 'b [@@deriving sboa]
type points = Point.t list [@@deriving sboa]

type nested = {
  shapes : shape list;
  boxed : int box option;
  choice : (int, string) choice;
  points : points;
  counter : Sboa.Counter.t option;
  obj : Sboa.Object.t; [@sboa.conv Sboa.Conv.object_]
}
[@@deriving sboa]

type failure = { reason : string; code : int }
[@@deriving sboa] [@@sboa.exception]

exception Failed of failure
