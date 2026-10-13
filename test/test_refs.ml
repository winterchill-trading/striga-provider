open! Core
open Striga_provider
open Banking_provider

let%expect_test "an account reference carries the user id" =
  let r =
    Refs.account
      ~user_id:"00000000-0000-4000-8000-000000000001"
      ~account_id:"ffff0000000000000000000000000065"
  in
  print_s [%sexp (r : Account_ref.t)];
  print_s [%sexp (Refs.account_parts r : (string * string) Or_error.t)];
  print_s
    [%sexp
      (Refs.account_parts (Account_ref.of_string "acc_000001")
       : (string * string) Or_error.t)];
  [%expect
    {|
    00000000-0000-4000-8000-000000000001/ffff0000000000000000000000000065
    (Ok (00000000-0000-4000-8000-000000000001 ffff0000000000000000000000000065))
    (Error ("not a Striga reference" account acc_000001))
    |}]
;;
