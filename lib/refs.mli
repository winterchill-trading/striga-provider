(** Provider-side ids for Striga objects.

    Most Striga endpoints want the user id next to the object id ([/wallets/get/account]
    takes [userId] and [accountId]), so an account reference carries both, as
    [<user id>/<account id>]: any holder of an {!Account_ref.t} can call Striga without a
    lookup table. Striga's ids are UUIDs and 32-digit hex strings, which never contain a
    slash. A customer is the Striga user id itself, a card the Striga card id. *)

open! Core
open Banking_provider

val customer : user_id:string -> Customer_ref.t
val user_id : Customer_ref.t -> string
val account : user_id:string -> account_id:string -> Account_ref.t

(** [(user_id, account_id)]; fails on a reference this module did not make. *)
val account_parts : Account_ref.t -> (string * string) Or_error.t

val standing_order : user_id:string -> order_id:string -> Standing_order_ref.t
val standing_order_parts : Standing_order_ref.t -> (string * string) Or_error.t
