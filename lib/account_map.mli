(** Striga accounts as {!Banking_provider.Account.t}.

    A Striga wallet holds one account per enabled currency; each is one
    {!Banking_provider.Account.t}. Enrichment gives a EUR account its IBAN and a crypto
    account its deposit address. Sandbox addresses live on test networks: BTC on testnet3
    ([tb1...], {!Payments_core.Network.Bitcoin_testnet}), ETH on Sepolia, which shares
    Ethereum's address format and maps to {!Payments_core.Network.Ethereum}. An address on
    a network payments-core does not model (BSC) is left out rather than mislabelled. *)

open! Core
open Banking_provider

(** Network of a Striga [blockchainNetwork] ([name] "Bitcoin Testnet 3", [network]
    "Bitcoin"). *)
val network : Striga_client.Common.Blockchain_network.t -> Payments_core.Network.t option

(** [ACTIVE] is open, [BLOCKED]/[FROZEN]/[SUSPENDED] frozen, [CLOSED] closed. *)
val status : string option -> Ledger.Account_status.t

val account : user_id:string -> Striga_client.Wallet.Account.t -> Account.t Or_error.t

(** The addresses an enrichment returned. *)
val addresses : Striga_client.Wallet.Enrichment.t -> Account.Address.t list

(** [available] from Striga; nothing is reported as held, because Striga takes outgoing
    payments and card authorizations off the available balance at once (the [balanceAfter]
    of a [SEPA_PAYOUT_INITIATED] entry is already lower), so [posted = available]. *)
val balance
  :  Account_ref.t
  -> Striga_client.Wallet.Account.t
  -> at:Time_ns.t
  -> Account.Balance.t Or_error.t
