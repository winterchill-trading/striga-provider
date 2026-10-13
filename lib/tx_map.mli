(** Striga ledger transactions as transfer updates and deposits.

    One Striga transaction id appears under several [txType]s as it progresses
    ([SEPA_PAYOUT_INITIATED] then [SEPA_PAYOUT_COMPLETED]), so an event id is the pair:
    [tx:<id>:<txType>]. A poll of the statement and a [/tx] webhook about the same entry
    give the same id, and the inbox applies it once.

    {v
      outgoing (debit)                      Transfer_update
      *_INITIATED (confirmed)               Submitted
      ON_CHAIN_WITHDRAWAL_PENDING           Pending
      SEPA_PAYOUT_COMPLETED,
      LN_OUTGOING_CONFIRMED,
      ON_CHAIN_WITHDRAWAL_CONFIRMED,
      INTRA_LEDGER_SEND                     Settled
      SEPA_PAYOUT_DENIED                    Rejected MS03
      SEPA_PAYOUT_REVERTED                  Returned MS03
      *_FAILED, other *_DENIED              Failed (Provider_error)

      incoming (credit)                     Event
      SEPA_PAYIN_COMPLETED                  Incoming_transfer, settled
      LN_INCOMING_CONFIRMED                 Incoming_transfer, settled
      ON_CHAIN_DEPOSIT_PENDING              nothing (the entry has no amount)
      ON_CHAIN_DEPOSIT_CONFIRMED            Incoming_transfer, settled
      INTRA_LEDGER_SEND (credit)            Incoming_transfer, settled
      SEPA_PAYIN_DENIED / FAILED            Transfer Rejected MS03
      SEPA_PAYIN_REVERTED                   Transfer Returned MS03
    v}

    Striga gives no ISO 20022 reason with a denial or revert; [MS03] ("reason not
    specified, agent generated") stands in for it. *)

open! Core
open Banking_provider
open Payments_core
module Tx := Striga_client.Transaction

val event_id : Tx.t -> Event_id.t option

(** [`In] for a credit, [`Out] for a debit; [None] for entries that move nothing
    ([SEPA_PAYOUT_COMPLETED] carries no amount: the debit was at initiation). *)
val direction : Tx.t -> [ `In | `Out ] option

(** How an outgoing transfer moves on this entry. [None] for entries of other kinds and
    for an initiation still waiting for its OTP ([PENDING_2FA_CONFIRMATION]). *)
val outgoing_update : Tx.t -> Transfer_update.t option

(** The rail a deposit came in on. *)
val incoming_rail : Tx.t -> Rail.t option

(** The event for an entry on [account] about money coming in: a new deposit
    ([Incoming_transfer], with our id {!Event.incoming_transfer_id} of the Striga id) or a
    later change to one ([Transfer]). [own_iban] is the account's IBAN, the creditor of a
    SEPA deposit. [None] for entries that are not about incoming money. *)
val incoming
  :  account:Account_ref.t
  -> own_iban:Iban.t option
  -> Tx.t
  -> Event.Kind.t option Or_error.t

(** The amount of a credit or debit, in the account's currency. *)
val amount : Tx.t -> Money.Amount.t option Or_error.t

(** The entry's time ([timestamp], else [datetime]), or [default]. *)
val at : Tx.t -> default:Time_ns.t -> Time_ns.t
