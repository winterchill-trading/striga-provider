open! Core
open Banking_provider
open Payments_core
module Tx = Striga_client.Transaction

let event_id (t : Tx.t) =
  match t.id, t.tx_type with
  | Some id, Some ty ->
    Some (Event_id.of_string (sprintf "tx:%s:%s" id (Tx.Tx_type.to_string ty)))
  | _ -> None
;;

let nonzero = function
  | Some s when not (String.equal s "0" || String.is_empty s) -> Some s
  | _ -> None
;;

let direction (t : Tx.t) =
  match nonzero t.credit, nonzero t.debit with
  | Some _, _ -> Some `In
  | None, Some _ -> Some `Out
  | None, None -> None
;;

let pending_otp (t : Tx.t) =
  Option.value_map t.status ~default:false ~f:(String.equal "PENDING_2FA_CONFIRMATION")
;;

let failed what = Transfer_update.Failed (Provider_error what)

let outgoing_update (t : Tx.t) : Transfer_update.t option =
  if pending_otp t
  then None
  else (
    match t.tx_type with
    | None -> None
    | Some ty ->
      (match ty with
       | Sepa_payout_initiated | Ln_outgoing_initiated | On_chain_withdrawal_initiated ->
         Some Submitted
       | On_chain_withdrawal_pending -> Some Pending
       | Sepa_payout_completed | Ln_outgoing_confirmed | On_chain_withdrawal_confirmed ->
         Some Settled
       | Intra_ledger_send | Inter_ledger_send ->
         (match direction t with
          | Some `Out -> Some Settled
          | _ -> None)
       | Sepa_payout_denied -> Some (Rejected MS03)
       | Sepa_payout_reverted -> Some (Returned MS03)
       | Sepa_payout_failed -> Some (failed "SEPA payout failed")
       | Ln_outgoing_failed -> Some (failed "Lightning payment failed")
       | Ln_outgoing_denied -> Some (failed "Lightning payment denied")
       | On_chain_withdrawal_failed -> Some (failed "on-chain withdrawal failed")
       | On_chain_withdrawal_denied -> Some (failed "on-chain withdrawal denied")
       | Intra_ledger_send_denied | Inter_ledger_send_denied ->
         Some (failed "transfer denied")
       | Sepa_payin_completed
       | Sepa_payin_denied
       | Sepa_payin_failed
       | Sepa_payin_reverted
       | Ln_incoming_pending
       | Ln_incoming_confirmed
       | Ln_incoming_expired
       | Ln_incoming_denied
       | On_chain_deposit_pending
       | On_chain_deposit_confirmed
       | On_chain_deposit_denied
       | Swap_currency_initiated
       | Currency_exchange
       | Exchange_debit
       | Exchange_credit
       | Card_authorization
       | Card_authorization_declined
       | Card_authorization_reversal
       | Card_authorization_release
       | Card_authorization_settlement_confirmed
       | Manual_adjustment
       | Other _ -> None))
;;

let network_of_name name =
  Account_map.network
    { name
    ; network = None
    ; type_ = None
    ; contract_address = None
    ; blockchain_deposit_address = None
    }
;;

let incoming_rail (t : Tx.t) : Rail.t option =
  match t.tx_type with
  | Some
      (Sepa_payin_completed | Sepa_payin_denied | Sepa_payin_failed | Sepa_payin_reverted)
    ->
    (match t.banking_payment_type with
     | Some "SEPA_INSTANT" -> Some Sepa_instant
     | _ -> Some Sepa_credit)
  | Some (Ln_incoming_pending | Ln_incoming_confirmed) -> Some Lightning
  | Some (On_chain_deposit_pending | On_chain_deposit_confirmed | On_chain_deposit_denied)
    ->
    Option.bind t.blockchain_network ~f:network_of_name
    |> Option.map ~f:(fun n -> Rail.Onchain n)
  | Some (Intra_ledger_send | Inter_ledger_send) -> Some Intraledger
  | _ -> None
;;

let at (t : Tx.t) ~default =
  Striga_time.parse_or ~default (Option.first_some t.timestamp t.datetime)
;;

let amount (t : Tx.t) =
  let open Or_error.Let_syntax in
  match Option.first_some (nonzero t.credit) (nonzero t.debit) with
  | None -> return None
  | Some digits ->
    let%bind currency =
      match t.currency, t.tx_type with
      | Some c, _ -> return c
      (* Lightning entries name no currency; they always move the BTC account. *)
      | ( None
        , Some
            ( Ln_incoming_pending
            | Ln_incoming_confirmed
            | Ln_outgoing_initiated
            | Ln_outgoing_confirmed
            | Ln_outgoing_failed ) ) -> return "BTC"
      | None, _ -> Or_error.error_string "entry without a currency"
    in
    let unit =
      Option.bind (Option.first_some t.balance_after t.balance_before) ~f:(fun b ->
        b.Striga_client.Common.Balance.currency)
    in
    let%map a = Units.amount_of_striga ?unit ~currency digits in
    Some a
;;

let sepa_details ~own_iban (t : Tx.t) =
  let open Or_error.Let_syntax in
  let%bind creditor =
    Or_error.of_option own_iban ~error:(Error.of_string "account has no IBAN yet")
  in
  let%bind debtor =
    match t.banking_sender_iban with
    | Some s -> Iban.of_string s
    | None -> Or_error.error_string "SEPA deposit without a sender IBAN"
  in
  let party name iban = { Iso20022.Party.name; iban; bic = None; address = None } in
  let%map payment_id =
    (* Striga's ids are 36-character UUIDs, one over the 35 SEPA allows in any id field,
       so the Striga id stays in [provider_ref]; "NOTPROVIDED" is the scheme's end-to-end
       id when the payer gave none. *)
    Iso20022.Payment_id.create ~end_to_end_id:"NOTPROVIDED" ()
  in
  let sender = Option.value t.banking_sender_name ~default:"SEPA sender" in
  ( Transfer.Details.Sepa
      (Sepa.Details.create
         ~payment_id
         ~debtor:(party sender debtor)
         ~creditor:(party "Account holder" creditor)
         ())
  , Transfer.Counterparty.External { name = sender; detail = Iban.to_string debtor } )
;;

let incoming ~account ~own_iban (t : Tx.t) : Event.Kind.t option Or_error.t =
  let open Or_error.Let_syntax in
  match t.id, t.tx_type, incoming_rail t with
  | None, _, _ | _, None, _ | _, _, None -> return None
  | Some provider_ref, Some ty, Some rail ->
    let transfer = Event.incoming_transfer_id ~provider_ref in
    let update u =
      return (Some (Event.Kind.Transfer { transfer; provider_ref; update = u }))
    in
    let deposit ~settled =
      let%bind amount =
        match%bind amount t with
        | Some a -> return a
        | None -> Or_error.error_s [%message "deposit without an amount" provider_ref]
      in
      let%bind details, from =
        match rail with
        | Sepa_credit | Sepa_instant -> sepa_details ~own_iban t
        | Lightning ->
          return
            ( Transfer.Details.Lightning { payment_hash = t.hash; preimage = None }
            , Transfer.Counterparty.External
                { name = "Lightning payer"
                ; detail = Option.value t.other_crypto_identifier ~default:""
                } )
        | Onchain _ ->
          return
            ( Transfer.Details.Onchain
                { travel_rule = None
                ; tx_hash = t.tx_hash
                ; block_hash = None
                ; confirmations = Option.value t.blockchain_confirmations ~default:0
                ; finalized = settled
                }
            , Transfer.Counterparty.External
                { name = "on-chain sender"
                ; detail = Option.value t.blockchain_source_address ~default:""
                } )
        | Faster_payments | Chaps | Bacs | Ach _ | Rtp | Fedwire ->
          Or_error.error_s
            [%message "Striga reports no deposits on UK or US rails" (rail : Rail.t)]
        | Intraledger | Card_scheme ->
          return
            ( Transfer.Details.Intraledger
            , Transfer.Counterparty.External
                { name = "Striga user"
                ; detail = Option.value t.source_account_id ~default:""
                } )
      in
      return
        (Some
           (Event.Kind.Incoming_transfer
              { account
              ; transfer
              ; provider_ref
              ; rail
              ; amount
              ; fee = Money.Amount.zero (Money.Amount.currency amount)
              ; from
              ; reference = Option.value t.memo ~default:""
              ; details
              ; settled
              }))
    in
    (match ty with
     | Sepa_payin_completed | Ln_incoming_confirmed -> deposit ~settled:true
     (* A pending on-chain entry carries no credit (the amount is only in the chain
        fields), so the deposit is reported once, when Striga confirms it. *)
     | On_chain_deposit_pending -> return None
     | On_chain_deposit_confirmed -> deposit ~settled:true
     | Intra_ledger_send | Inter_ledger_send ->
       (match direction t with
        | Some `In -> deposit ~settled:true
        | _ -> return None)
     | Sepa_payin_denied | Sepa_payin_failed -> update (Rejected MS03)
     | Sepa_payin_reverted -> update (Returned MS03)
     | On_chain_deposit_denied -> update (Failed (Provider_error "deposit denied"))
     | _ -> return None)
;;
