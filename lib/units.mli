(** Striga currencies and amounts in {!Money} terms.

    Striga names an account's currency by ticker ([EUR], [BTC], [USDC], ...) and sends
    amounts as strings of the smallest unit it counts in, naming that unit next to
    balances ([cents], [satoshis], [wei], [lamports]). That unit is not always ours: USDC
    is counted in cents at Striga (two digits) and in micro-units in {!Money} (six), so
    every amount is rescaled here and nowhere else. A conversion that would drop digits
    fails rather than rounding. *)

open! Core

(** [EUR], [BTC], [ETH], [USDC], [USDT], [BNB], [POL], [SOL]. Stablecoins map to the
    untagged {!Money.Currency.usdc} and {!Money.Currency.usdt}: Striga holds them in
    custody, not on one chain. BNB, POL and SOL are registered with {!Money.Currency} the
    first time this module is used. *)
val currency_of_striga : string -> Money.Currency.t Or_error.t

(** The Striga ticker of a currency; fails for currencies Striga does not hold (including
    {!Money.Currency.btc_lightning}: Lightning moves the BTC account). *)
val striga_of_currency : Money.Currency.t -> string Or_error.t

(** Digits of Striga's smallest unit for an account currency. *)
val striga_exponent : string -> int option

(** Digits of a unit name from a balance: [cents] 2, [satoshis] 8, [wei] 18, [lamports] 9. *)
val unit_exponent : string -> int option

(** [amount_of_striga ~currency "10000"] is 100.00 EUR. [unit], when Striga named one,
    takes precedence over the per-currency table. *)
val amount_of_striga
  :  ?unit:string
  -> currency:string
  -> string
  -> Money.Amount.t Or_error.t

(** An amount in whole units with a decimal point, as card transactions send it
    (["12.34"]). *)
val amount_of_major : currency:string -> string -> Money.Amount.t Or_error.t

(** The string of Striga's smallest unit; fails when the amount has more digits than
    Striga counts (0.000001 USDC) or the currency is not one Striga holds. *)
val amount_to_striga : Money.Amount.t -> string Or_error.t

(** [amount_to_striga] for a whole number of EUR cents, as the simulator takes it. *)
val eur_cents : Money.Amount.t -> int Or_error.t
