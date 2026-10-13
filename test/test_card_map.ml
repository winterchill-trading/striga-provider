open! Core
open Striga_provider
open Banking_provider

let card () = Fixture.load "card-get.json" Striga_client.Card.t_of_yojson

let%expect_test "a virtual card linked to a BTC account" =
  print_s [%sexp (Card_map.card_info (card ()) |> ok_exn : Card_info.t)];
  [%expect
    {|
    ((id 00000000-0000-4000-8000-000000000057)
     (customer 00000000-0000-4000-8000-000000000001)
     (account
      00000000-0000-4000-8000-000000000001/ffff0000000000000000000000000003)
     (kind Virtual) (status Active)
     (masked_pan (((last4 2932) (expiry ((month 10) (year 2028))))))
     (limits
      ((currency EUR) (per_transaction ("10000.00 EUR")) (daily ("10000.00 EUR"))
       (monthly ("15000.00 EUR")) (atm_daily ("350.00 EUR")) (atm_daily_count ())
       (online true) (contactless true) (atm true) (blocked_mccs ())
       (blocked_countries ())))
     (created_at "2026-10-13 22:05:30Z"))
    |}]
;;

let%expect_test "statuses" =
  List.iter
    Striga_client.Card.Status.
      [ Created; Dispatched; Active; Activated; Blocked; Closed; Expired; Other "LOST" ]
    ~f:(fun s ->
      printf
        "%-10s %s\n"
        (Striga_client.Card.Status.to_string s)
        (Sexp.to_string [%sexp (Card_map.status (Some s) : Card_core.Card.Status.t)]));
  [%expect
    {|
    CREATED    Requested
    DISPATCHED Requested
    ACTIVE     Active
    ACTIVATED  Active
    BLOCKED    Frozen
    CLOSED     Destroyed
    EXPIRED    Expired
    LOST       Blocked
    |}]
;;

let%expect_test "limits back to Striga, refusing what it cannot hold" =
  let show l =
    print_s
      [%sexp
        (Card_map.limits_to_striga l
         : ((string * int) list
           * [ `Contactless of bool ]
           * [ `Withdrawal of bool ]
           * [ `Online of bool ])
             Or_error.t)]
  in
  let eur s = Money.Amount.of_string (s ^ " EUR") in
  show
    (Card_core.Limits.create
       ~daily:(eur "500.00")
       ~per_transaction:(eur "100.00")
       ~contactless:false
       Money.Currency.eur
     |> ok_exn);
  show (Card_core.Limits.create ~daily:(eur "500.50") Money.Currency.eur |> ok_exn);
  show (Card_core.Limits.create ~atm_daily_count:3 Money.Currency.eur |> ok_exn);
  show
    (Card_core.Limits.create ~blocked_mccs:[ Card_core.Mcc.gambling ] Money.Currency.eur
     |> ok_exn);
  show (Card_core.Limits.unlimited Money.Currency.btc);
  [%expect
    {|
    (Ok
     (((transactionPurchase 100) (dailyPurchase 500)) (Contactless false)
      (Withdrawal true) (Online true)))
    (Error
     ("Striga card limits are whole euros" dailyPurchase (amount "500.50 EUR")))
    (Error "Striga has no ATM withdrawal count")
    (Error "Striga has no merchant category or country block lists")
    (Error ("Striga card limits are in EUR" (l.currency BTC)))
    |}]
;;
