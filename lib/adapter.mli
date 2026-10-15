(** {!Banking_provider.Provider.S} and {!Banking_provider.Sandbox.S} over the Striga API
    ([striga-client]).

    {b Ids.} A customer is the Striga user, an account [<user id>/<account id>] ({!Refs}),
    a card the Striga card. Striga has no idempotency keys and no field for our ids, so
    the links that make calls idempotent (our customer id, transfer id, card request id)
    live in a {!Store.t}.

    {b Events.} Striga posts webhooks to one URL configured in its dashboard. A service
    that receives them passes each delivery to {!ingest_webhook}. Without a public URL
    (tests, the CLI, the conformance run) the adapter polls instead: while anything is
    subscribed to {!events} it reads, every [poll_interval], the KYC state of the
    customers it has seen, the statements of the accounts it has seen and the statements
    of the cards it has seen, and publishes what changed. Both paths derive the same event
    ids from Striga's data ({!Kyc_map}, {!Tx_map}, {!Card_tx_map}), so an inbox applies
    each change once whichever path saw it first. Calls that observe a change (a
    [kyc_status], a [transfer] query, a confirmed challenge) publish it too.

    {b SCA.} Every outgoing payment and swap at Striga is initiated, then confirmed with
    the customer's one-time code; the initiation's challenge becomes a
    {!Banking_provider.Sca_challenge.t} and {!confirm_sca} answers it. Striga asks for the
    end user's IP address with each confirmation; [Provider.S] carries none, so the
    configured [end_user_ip] is sent.

    {b Sandbox.} Against the sandbox host, [sandbox_settlement = `Immediate] asks the
    simulator to settle each SEPA payout as soon as it is confirmed, the way the fake
    provider's [Immediate] mode does; [`Manual] leaves it to [simulate_transfer_outcome].
    Against any other host the setting is ignored. *)

open! Core
open Async
open Banking_provider

module Config : sig
  type t =
    { poll_interval : Time_ns.Span.t
    ; account_retry : Time_ns.Span.t
    (** how long [open_account] keeps looking for the account Striga opened on KYC
        approval (crypto accounts are listed within seconds; EUR and USDC once the user
        has an SCA session) *)
    ; deposit_timeout : Time_ns.Span.t
    (** how long [simulate_deposit] waits for the asynchronous credit *)
    ; sandbox_code : string
    (** the sandbox's fixed one-time code, with which the adapter answers its own SMS
        login and the e-mail and mobile checks; used only against the sandbox host *)
    ; payment_account_consent : [ `Record of string option | `By_application ]
    (** [`Record terms_version]: before opening the EUR account (Striga's Payment
        Account), record the customer's acceptance of its terms with [end_user_ip] unless
        one is already recorded. [`By_application]: the application records it. *)
    ; statement_window : Time_ns.Span.t (** how far back polls read statements *)
    ; end_user_ip : string (** sent with confirmations; Striga checks its region *)
    ; email_for : Kyc_core.Customer_id.t -> email:string -> string
    (** the e-mail registered at Striga, which must be unique per user *)
    ; sandbox_settlement : [ `Immediate | `Manual ]
    ; card_3ds_password : unit -> string
    (** for new virtual cards; must pass {!valid_3ds_password}, or issuing fails before
        calling Striga *)
    }

  (** Polls every 3 s, looks for a new account for 30 s, waits a minute for a simulated
      deposit, the sandbox code [123456], records the Payment Account consent, reads a day
      of statements, a documentation IP from the sandbox runs, e-mails made unique by a
      [+<customer id>] tag on the person's address, [`Manual] settlement and a random 3-D
      Secure password. *)
  val default : t

  (** Striga's rule for 3-D Secure passwords: 8-36 characters from letters, digits and the
      symbols listed in Striga's card reference (the double quote, backslash and
      [!#;:?&*()+=/,.[]{}]; no hyphen or at sign). Striga also wants a strong one, so this
      asks for an upper-case letter, a lower-case letter, a digit and a symbol. *)
  val valid_3ds_password : string -> bool

  (** The default [card_3ds_password]: a fresh random password that passes
      {!valid_3ds_password}. *)
  val random_password : unit -> string
end

type t

val create : ?config:Config.t -> ?store:Store.t -> Striga_client.Transport.t -> t

(** [create] from [STRIGA_*] environment variables (see striga-client's [Config]). *)
val of_env : ?config:Config.t -> ?store:Store.t -> unit -> t Or_error.t

val transport : t -> Striga_client.Transport.t

include Provider.S with type t := t
include Sandbox.S with type t := t

(** {2 Striga-specific} *)

(** Card numbers are shown by Striga's browser component: the browser calls
    [requestConsent], which sends the cardholder a code and returns a challenge id. Pass
    that id here to get the challenge to answer with {!confirm_sca}; after it is accepted,
    {!card_details_token} returns the token for the component (24 hours). *)
val card_consent_started
  :  t
  -> Card_core.Ids.Card_id.t
  -> challenge_id:string
  -> Sca_challenge.t Or_error.t Deferred.t

(** Striga lists EUR and USDC accounts, and reads them, only while the customer has an SCA
    session (180 days; a 2FA reset revokes it). Against the sandbox the adapter opens one
    itself with [sandbox_code] when it needs it. Elsewhere the application does:
    [start_session] sends the customer an SMS and returns Striga's challenge id, and
    [complete_session] answers it with the customer's code. *)
val start_session : t -> Customer_ref.t -> string Or_error.t Deferred.t

val complete_session
  :  t
  -> Customer_ref.t
  -> challenge_id:string
  -> code:Sensitive.t
  -> unit Or_error.t Deferred.t

(** Failures inside the poller, which has no caller to return them to. *)
val background_errors : t -> Error.t list
