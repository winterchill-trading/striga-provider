open! Core
open Striga_provider
open Banking_provider

let account =
  Refs.account
    ~user_id:"00000000-0000-4000-8000-000000000001"
    ~account_id:"ffff0000000000000000000000000065"
;;

let own_iban = Some (Payments_core.Iban.of_string_exn "DE89370400440532013000")

let show_page file =
  let page = Fixture.load file Striga_client.Transaction.Page.t_of_yojson in
  List.iter page.transactions ~f:(fun t ->
    let ty =
      Option.value_map
        t.tx_type
        ~default:"-"
        ~f:Striga_client.Transaction.Tx_type.to_string
    in
    print_s
      [%sexp
        (ty : string)
        , (Tx_map.event_id t : Event_id.t option)
        , (Tx_map.direction t : [ `In | `Out ] option)
        , (Tx_map.amount t : Money.Amount.t option Or_error.t)
        , (Tx_map.outgoing_update t : Transfer_update.t option)
        , (Tx_map.incoming ~account ~own_iban t : Event.Kind.t option Or_error.t)])
;;

let%expect_test "a EUR statement: deposit, payout, settlement, card hold" =
  show_page "statement-eur.json";
  [%expect
    {|
    (CARD_AUTHORIZATION
     (tx:00000000-0000-4000-8000-000000000073:CARD_AUTHORIZATION) (Out)
     (Ok ("12.34 EUR")) () (Ok ()))
    (SEPA_PAYOUT_COMPLETED
     (tx:00000000-0000-4000-8000-000000000071:SEPA_PAYOUT_COMPLETED) () (Ok ())
     (Settled) (Ok ()))
    (SEPA_PAYOUT_INITIATED
     (tx:00000000-0000-4000-8000-000000000071:SEPA_PAYOUT_INITIATED) (Out)
     (Ok ("10.00 EUR")) (Submitted) (Ok ()))
    (EXCHANGE_DEBIT (tx:00000000-0000-4000-8000-000000000068:EXCHANGE_DEBIT)
     (Out) (Ok ("20.00 EUR")) () (Ok ()))
    (SEPA_PAYIN_COMPLETED
     (tx:00000000-0000-4000-8000-000000000075:SEPA_PAYIN_COMPLETED) (In)
     (Ok ("100.00 EUR")) ()
     (Ok
      ((Incoming_transfer
        (account
         00000000-0000-4000-8000-000000000001/ffff0000000000000000000000000065)
        (transfer in:00000000-0000-4000-8000-000000000075)
        (provider_ref 00000000-0000-4000-8000-000000000075) (rail Sepa_credit)
        (amount "100.00 EUR") (fee "0.00 EUR")
        (from (External (name "Ada Sandbox") (detail GB29NWBK60161331926819)))
        (reference walk)
        (details
         (Sepa
          ((payment_id
            ((end_to_end_id NOTPROVIDED) (instruction_id ()) (uetr ()) (tx_id ())
             (msg_id ()) (pmt_inf_id ())))
           (debtor
            ((name "Ada Sandbox") (iban GB29NWBK60161331926819) (bic ())
             (address ())))
           (creditor
            ((name "Account holder") (iban DE89370400440532013000) (bic ())
             (address ())))
           (remittance None_given) (charge_bearer SLEV) (purpose ())
           (requested_execution_date ()) (acceptance_time ()) (value_date ())
           (booking_date ()) (last_status ()))))
        (settled true)))))
    |}]
;;

let%expect_test "an on-chain deposit, pending then confirmed" =
  show_page "docs-statement.json";
  [%expect
    {|
    (ON_CHAIN_DEPOSIT_CONFIRMED
     (tx:00000000-0000-4000-8000-000000000018:ON_CHAIN_DEPOSIT_CONFIRMED)
     (In) (Ok ("0.200000000000000000 POL")) ()
     (Ok
      ((Incoming_transfer
        (account
         00000000-0000-4000-8000-000000000001/ffff0000000000000000000000000065)
        (transfer in:00000000-0000-4000-8000-000000000018)
        (provider_ref 00000000-0000-4000-8000-000000000018)
        (rail (Onchain Polygon)) (amount "0.200000000000000000 POL")
        (fee "0.000000000000000000 POL")
        (from
         (External (name "on-chain sender")
          (detail 0x0000000000000000000000000000000000000030)))
        (reference
         "0.2 POL CONFIRMED 0xaf1be0345e8ed30b955fead958df09401eb681f1708e7e304c081b614e6b9012")
        (details
         (Onchain (travel_rule ())
          (tx_hash
           (0xaf1be0345e8ed30b955fead958df09401eb681f1708e7e304c081b614e6b9012))
          (block_hash ()) (confirmations 1) (finalized true)))
        (settled true)))))
    (ON_CHAIN_DEPOSIT_PENDING
     (tx:00000000-0000-4000-8000-000000000018:ON_CHAIN_DEPOSIT_PENDING) ()
     (Ok ()) () (Ok ()))
    |}]
;;

let%expect_test "a Lightning deposit" =
  show_page "docs-transactions-ln.json";
  [%expect
    {|
    (LN_INCOMING_CONFIRMED
     (tx:00000000-0000-4000-8000-000000000021:LN_INCOMING_CONFIRMED) (In)
     (Ok ("0.00000495 BTC")) ()
     (Ok
      ((Incoming_transfer
        (account
         00000000-0000-4000-8000-000000000001/ffff0000000000000000000000000065)
        (transfer in:00000000-0000-4000-8000-000000000021)
        (provider_ref 00000000-0000-4000-8000-000000000021) (rail Lightning)
        (amount "0.00000495 BTC") (fee "0.00000000 BTC")
        (from
         (External (name "Lightning payer")
          (detail
           lntb5u1p30hr9vpp5s7f8sxwxt3njma4mh2tplk3zez8hrmswh9kd8ed9u56yyjw69sjsdplwdukuerfvdshgefqv9c8qmrfvdshg6t0deejqmtfwdekjmmw943hy6t5d93kzmqcqzpgxqzjhsp5cuvar0tv55qf7sh5thf476f8kqg8vuyvnfedtghv4ngxz4tramuq9qyyssqjtmtg0apf99km6d3ndylahkm8lvedv2nuwnsc2sfqme85ey2q8pz0qz9asx7m28s0x3yg3vtr09dpw44u5dekzxc50dua7u4l5en75sqtq05dq)))
        (reference "")
        (details
         (Lightning
          (payment_hash
           (eeee000000000000000000000000000000000000000000000000000000000022))
          (preimage ())))
        (settled true)))))
    |}]
;;

let%expect_test "an initiation waiting for its OTP is not a transfer update yet" =
  let i = Fixture.load "sepa-init.json" Striga_client.Payment.Initiated.t_of_yojson in
  print_s
    [%sexp
      (Option.bind i.transaction ~f:Tx_map.outgoing_update : Transfer_update.t option)];
  let c = Fixture.load "sepa-confirm.json" Striga_client.Transaction.t_of_yojson in
  print_s [%sexp (Tx_map.outgoing_update c : Transfer_update.t option)];
  [%expect {|
    ()
    (Submitted)
    |}]
;;
