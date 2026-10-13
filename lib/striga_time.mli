(** Striga's timestamps: ISO 8601 text in most bodies (["2026-10-13T22:04:04.574Z"]),
    epoch milliseconds in others ([createdAt] of a user, the [ts] of a KYC webhook). *)

open! Core

val parse : string -> Time_ns.t option

(** [parse], or [default] when absent or unreadable. *)
val parse_or : default:Time_ns.t -> string option -> Time_ns.t
