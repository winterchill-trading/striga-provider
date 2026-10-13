open! Core
open Striga_provider
open Banking_provider

let user_id = "00000000-0000-4000-8000-000000000001"

let%expect_test "timestamps in both of Striga's forms" =
  let show s = print_s [%sexp (Striga_time.parse s : Time_ns.Alternate_sexp.t option)] in
  show "2026-10-13T22:04:04.574Z";
  show "1791929027997";
  show "yesterday";
  [%expect
    {|
    ("2026-10-13 22:04:04.574Z")
    ("2026-10-13 22:03:47.997Z")
    ()
    |}]
;;

let%expect_test "a BTC account on testnet with its deposit address and balance" =
  let a = Fixture.load "account-get.json" Striga_client.Wallet.Account.t_of_yojson in
  let account = Account_map.account ~user_id a |> ok_exn in
  print_s [%sexp (account : Account.t)];
  print_s
    [%sexp
      (Account_map.balance account.id a ~at:Fixture.at |> ok_exn : Account.Balance.t)];
  [%expect
    {|
    ((id 00000000-0000-4000-8000-000000000001/ffff0000000000000000000000000003)
     (customer 00000000-0000-4000-8000-000000000001) (currency BTC) (status Open)
     (addresses
      ((Crypto
        (address
         ((network Bitcoin_testnet)
          (address tb1qw508d6qejxtdg4y5r3zarvary0c5xw7kxpjzsx)))
        (memo ()))))
     (opened_at "2026-10-13 22:04:04.574Z"))
    ((account
      00000000-0000-4000-8000-000000000001/ffff0000000000000000000000000003)
     (available "0.00000000 BTC") (held "0.00000000 BTC")
     (posted "0.00000000 BTC") (as_of "2026-10-13 22:00:00Z"))
    |}]
;;

let%expect_test "enrichment gives an IBAN or a deposit address" =
  List.iter [ "enrich-eur.json"; "enrich-eth.json"; "enrich-btc.json" ] ~f:(fun f ->
    let e = Fixture.load f Striga_client.Wallet.Enrichment.t_of_yojson in
    print_s [%sexp (Account_map.addresses e : Account.Address.t list)]);
  [%expect
    {|
    ((Iban (iban GB29NWBK60161331926819) (bic (NWBKGB2L))))
    ((Crypto
      (address
       ((network Ethereum) (address 0x0000000000000000000000000000000000000030)))
      (memo ())))
    ((Crypto
      (address
       ((network Bitcoin_testnet)
        (address tb1qw508d6qejxtdg4y5r3zarvary0c5xw7kxpjzsx)))
      (memo ())))
    |}]
;;

let%expect_test "a new wallet's accounts, one per currency" =
  let w = Fixture.load "wallet-create.json" Striga_client.Wallet.t_of_yojson in
  List.iter w.accounts ~f:(fun (code, a) ->
    match Account_map.account ~user_id a with
    | Ok acc ->
      printf
        "%s -> %s %s\n"
        code
        (Money.Currency.to_string acc.currency)
        (Sexp.to_string [%sexp (acc.status : Ledger.Account_status.t)])
    | Error e -> printf "%s -> %s\n" code (Error.to_string_hum e));
  [%expect
    {|
    BTC -> BTC Open
    SOL -> SOL Open
    POL -> POL Open
    ETH -> ETH Open
    BNB -> BNB Open
    |}]
;;
