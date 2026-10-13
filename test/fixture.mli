(** Recorded or documented Striga bodies under [test/fixtures]. *)

open! Core

val json : string -> Yojson.Safe.t

(** Decodes a fixture with a ppx_yojson_conv reader. *)
val load : string -> (Yojson.Safe.t -> 'a) -> 'a

(** A fixed instant for expect output: 2026-10-13 22:00:00Z. *)
val at : Time_ns.t
