open! Core
open Striga_provider

let show r = print_s [%sexp (r : Money.Amount.t Or_error.t)]

let%expect_test "Striga amounts become Money amounts" =
  show (Units.amount_of_striga ~currency:"EUR" "10000");
  show (Units.amount_of_striga ~currency:"USDC" "2197");
  show (Units.amount_of_striga ~unit:"satoshis" ~currency:"BTC" "4193529");
  (* 5 ETH in wei: wider than 63 bits, kept exact. *)
  show (Units.amount_of_striga ~unit:"wei" ~currency:"ETH" "5000000000000000000");
  show (Units.amount_of_striga ~currency:"SOL" "1500000000");
  show (Units.amount_of_striga ~currency:"DOGE" "1");
  show (Units.amount_of_striga ~currency:"EUR" "12.5");
  show (Units.amount_of_major ~currency:"EUR" "12.34");
  [%expect
    {|
    (Ok "100.00 EUR")
    (Ok "21.970000 USDC")
    (Ok "0.04193529 BTC")
    (Ok "5.000000000000000000 ETH")
    (Ok "1.500000000 SOL")
    (Error ("currency not held at Striga" DOGE))
    (Error ("not an integer amount" 12.5))
    (Ok "12.34 EUR")
    |}]
;;

let%expect_test "Money amounts become Striga strings, never rounded" =
  let show a = print_s [%sexp (Units.amount_to_striga a : string Or_error.t)] in
  show (Money.Amount.of_string "30.00 EUR");
  show (Money.Amount.of_string "21.970000 USDC");
  show (Money.Amount.of_string "0.000001 USDC");
  show (Money.Amount.of_string "0.00000001 BTC");
  show (Money.Amount.of_string "1 JPY");
  print_s [%sexp (Units.eur_cents (Money.Amount.of_string "1.00 EUR") : int Or_error.t)];
  [%expect
    {|
    (Ok 3000)
    (Ok 2197)
    (Error ("Striga cannot hold this many digits" (amount "0.000001 USDC")))
    (Ok 1)
    (Error ("currency not held at Striga" (currency JPY)))
    (Ok 100)
    |}]
;;

let%test_unit "EUR and BTC amounts round-trip" =
  Quickcheck.test
    (Quickcheck.Generator.both (Int.gen_incl 0 1_000_000_000) Bool.quickcheck_generator)
    ~f:(fun (minor, btc) ->
      let currency = if btc then Money.Currency.btc else Money.Currency.eur in
      let a = Money.Amount.of_minor_units_int currency minor in
      let code = Units.striga_of_currency currency |> ok_exn in
      let back =
        Units.amount_to_striga a
        |> ok_exn
        |> Units.amount_of_striga ~currency:code
        |> ok_exn
      in
      [%test_result: Money.Amount.t] back ~expect:a)
;;
