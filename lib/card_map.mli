(** Striga cards in card-core terms.

    {v
      Striga status          card-core
      CREATED, DISPATCHED    Requested
      ACTIVE, ACTIVATED      Active
      BLOCKED                Frozen     (Striga's block is reversible: /card/unblock)
      CLOSED                 Destroyed  (/card/burn)
      EXPIRED                Expired
      anything else          Blocked    (lost, stolen: stopped for good)
    v}

    Limits are whole euros at Striga whatever the linked account's currency, so
    {!Card_core.Limits.t} here is always in EUR: [transactionPurchase] is the
    per-transaction cap, [dailyPurchase] and [monthlyPurchase] the daily and monthly caps,
    [dailyWithdrawal] the ATM cap; the [security] toggles are the online, contactless and
    ATM channels. Striga has no ATM count, MCC or country block lists. *)

open! Core
open Banking_provider

val status : Striga_client.Card.Status.t option -> Card_core.Card.Status.t

(** Last four of [maskedCardNumber] (["474367******2932"]) and the month of [expiryDate]
    (or Striga's misspelt [expiryData]). *)
val masked_pan : Striga_client.Card.t -> Card_core.Masked_pan.t option

val limits : Striga_client.Card.t -> Card_core.Limits.t Or_error.t

(** What to send to [PATCH /card/limits] and [PATCH /card/security]. A cap left at [None]
    is not sent and keeps Striga's current value (Striga has no "no cap"). Fails on what
    Striga cannot hold: a currency other than EUR, cents, an ATM count, MCC or country
    block lists. *)
val limits_to_striga
  :  Card_core.Limits.t
  -> ((string * int) list
     * [ `Contactless of bool ]
     * [ `Withdrawal of bool ]
     * [ `Online of bool ])
       Or_error.t

val card_info : Striga_client.Card.t -> Card_info.t Or_error.t
