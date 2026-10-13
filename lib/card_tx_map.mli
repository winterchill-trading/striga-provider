(** Striga card transactions (card statements and card webhooks) as
    {!Banking_provider.Card_update.t}.

    Striga decides every authorization itself against the linked account, so each one is
    an advice decided by [Provider_default], never a request for us to answer. The card's
    billing currency is the transaction currency Striga reports (EUR for the simulator);
    the merchant's amount is [originalAmount] in whole units of [originalCurrency].

    {v
      CARD_AUTHORIZATION                       Auth_advice, approved
      CARD_AUTHORIZATION_DECLINED              Auth_advice, declined (code from declineDetails)
      CARD_AUTHORIZATION_REVERSAL, _RELEASE    Reversal
      CARD_AUTHORIZATION_SETTLEMENT_CONFIRMED  Clearing (debit)
    v}

    The authorization id is [relatedCardTransactionId] (shared by every message about one
    authorization); event ids are [card:<that id>:<type>]. Entry mode is not reported and
    is taken as [Ecommerce] (the simulator's card-not-present payment). *)

open! Core
open Banking_provider
module Card_tx := Striga_client.Card.Card_transaction

(** Striga sends ISO 3166 alpha-3 ([EST]); card-core wants alpha-2. Covers the EEA, the
    UK, Switzerland and the larger card markets. *)
val country_of_alpha3 : string -> Card_core.Country.t option

(** ["Not Sufficient Funds"] is 51; limits 61; a blocked, frozen or inactive card 57; an
    expired card 54; anything else 05. *)
val response_of_decline : string option -> Card_core.Response_code.t

val event_id : Card_tx.t -> Event_id.t option

(** The card and the message; [None] for types that are not card messages. [card_id] names
    the card when the entry does not (statements omit it). *)
val update
  :  ?card_id:string
  -> Card_tx.t
  -> (Card_core.Ids.Card_id.t * Card_update.t) option Or_error.t
