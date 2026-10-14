(** {!Banking_provider.Provider.S} and {!Banking_provider.Sandbox.S} over the
    Striga API ([striga-client]).

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
    ; provisioning_timeout : Time_ns.Span.t
    (** how long [open_account] waits for Striga to provision an account (EUR accounts
        appear up to minutes after KYC approval) and [simulate_deposit] waits for the
        credit *)
    ; statement_window : Time_ns.Span.t (** how far back polls read statements *)
    ; end_user_ip : string (** sent with confirmations; Striga checks its region *)
    ; email_for : Kyc_core.Customer_id.t -> email:string -> string
    (** the e-mail registered at Striga, which must be unique per user *)
    ; sandbox_settlement : [ `Immediate | `Manual ]
    ; card_3ds_password : unit -> string (** 8-36 characters, for new virtual cards *)
    }

  (** Polls every 3 s, waits up to 5 minutes for provisioning, reads a day of statements,
      a documentation IP from the sandbox runs, e-mails made unique by a [+<customer id>]
      tag on the person's address, [`Manual] settlement and a random 3-D Secure password. *)
  val default : t
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

(** Failures inside the poller, which has no caller to return them to. *)
val background_errors : t -> Error.t list
