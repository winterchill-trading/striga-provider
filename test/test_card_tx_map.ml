open! Core
open Striga_provider
open Banking_provider

let show ?card_id (t : Striga_client.Card.Card_transaction.t) =
  print_s
    [%sexp
      (Card_tx_map.event_id t : Event_id.t option)
      , (Card_tx_map.update ?card_id t
         : (Card_core.Ids.Card_id.t * Card_update.t) option Or_error.t)]
;;

let%expect_test "a declined simulator payment from a card statement" =
  let page =
    Fixture.load
      "card-statement.json"
      Striga_client.Card.Card_transaction.Page.t_of_yojson
  in
  List.iter page.transactions ~f:(show ~card_id:"00000000-0000-4000-8000-000000000057");
  [%expect
    {|
    ((card:00000000-0000-4000-8000-000000000058:CARD_AUTHORIZATION_DECLINED)
     (Ok
      ((00000000-0000-4000-8000-000000000057
        (Auth_advice
         ((auth 00000000-0000-4000-8000-000000000058)
          (network_txn 00000000-0000-4000-8000-000000000058) (amount "12.34 EUR")
          (approved "0.00 EUR")
          (merchant
           ((name "Striga Simulator") (mcc 5812) (country EE)
            (amount "12.34 EUR")))
          (entry_mode Ecommerce) (response 51) (decided_by Provider_default)))))))
    |}]
;;

let%expect_test "an approved authorization from the card webhook" =
  show
    (Fixture.load
       "docs-webhook-card-auth.json"
       Striga_client.Card.Card_transaction.t_of_yojson);
  [%expect
    {|
    ((card:00000000-0000-4000-8000-000000000061:CARD_AUTHORIZATION)
     (Ok
      ((00000000-0000-4000-8000-000000000060
        (Auth_advice
         ((auth 00000000-0000-4000-8000-000000000061)
          (network_txn 00000000-0000-4000-8000-000000000061)
          (amount "1000.00 EUR") (approved "1000.00 EUR")
          (merchant
           ((name "Striga Simulator") (mcc 5812) (country EE)
            (amount "1000.00 EUR")))
          (entry_mode Ecommerce) (response 00) (decided_by Provider_default)))))))
    |}]
;;

let%expect_test "decline reasons and countries" =
  List.iter
    [ Some "Not Sufficient Funds"
    ; Some "Card is blocked"
    ; Some "Daily limit exceeded"
    ; Some "Card expired"
    ; Some "Suspected fraud"
    ; None
    ]
    ~f:(fun d ->
      print_s
        [%sexp
          (d : string option)
          , (Card_tx_map.response_of_decline d : Card_core.Response_code.t)]);
  List.iter [ "EST"; "DEU"; "DE"; "XYZ" ] ~f:(fun c ->
    print_s
      [%sexp (c : string), (Card_tx_map.country_of_alpha3 c : Card_core.Country.t option)]);
  [%expect
    {|
    (("Not Sufficient Funds") 51)
    (("Card is blocked") 57)
    (("Daily limit exceeded") 61)
    (("Card expired") 54)
    (("Suspected fraud") 05)
    (() 05)
    (EST (EE))
    (DEU (DE))
    (DE (DE))
    (XYZ ())
    |}]
;;
