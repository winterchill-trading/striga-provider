open! Core
open Banking_provider

let customer ~user_id = Customer_ref.of_string user_id
let user_id = Customer_ref.to_string
let join a b = a ^ "/" ^ b

let split ~what s =
  match String.lsplit2 s ~on:'/' with
  | Some (a, b) when (not (String.is_empty a)) && not (String.is_empty b) -> Ok (a, b)
  | _ -> Or_error.error_s [%message "not a Striga reference" what s]
;;

let account ~user_id ~account_id = Account_ref.of_string (join user_id account_id)
let account_parts r = split ~what:"account" (Account_ref.to_string r)

let standing_order ~user_id ~order_id =
  Standing_order_ref.of_string (join user_id order_id)
;;

let standing_order_parts r = split ~what:"standing order" (Standing_order_ref.to_string r)
