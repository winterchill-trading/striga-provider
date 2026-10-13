(** What the adapter remembers between calls, in domain types.

    Striga has no idempotency keys and no field for our ids, so the adapter keeps the
    links itself: our customer id to the Striga user, our transfer id to the Striga
    challenge and transaction, an SCA challenge to the Striga challenge it answers, a swap
    quote until it is executed, a card request id to the card it issued.

    A service persists these in its own database by implementing {!t} (the records have
    stable binary forms); {!memory} serves tests, the CLI and the conformance run, and
    forgets everything when the process exits. Every write is keyed, so repeating one is
    harmless. *)

open! Core
open Async_kernel
open Banking_provider
open Payments_core

module Transfer_record : sig
  type t =
    { id : Transfer.Id.Stable.V1.t
    ; account : Account_ref.Stable.V1.t
    ; rail : Rail.Stable.V1.t
    ; amount : Money.Amount.Stable.V1.t
    ; fee : Money.Amount.Stable.V1.t
    ; details : Transfer.Details.t
    ; challenge : string option (** Striga's challenge id, until confirmed *)
    ; provider_ref : string option (** Striga's transaction id, once known *)
    ; status : Transfer.Status.t
    ; updated_at : Utc_time.Stable.V1.t
    }
  [@@deriving bin_io, sexp, compare, equal]
end

module Challenge_record : sig
  type t =
    { challenge : Sca_challenge.t
    ; user_id : string
    ; striga_challenge : string
    ; striga_method : string option (** [sms], [totp], ... as Striga named it *)
    ; settled : bool (** answered (accepted, or failed for good) *)
    }
  [@@deriving sexp, compare, equal]
end

module Swap_record : sig
  type t =
    { id : Swap.Id.Stable.V1.t
    ; from : Account_ref.Stable.V1.t
    ; to_ : Account_ref.Stable.V1.t
    ; sell : Money.Amount.Stable.V1.t
    ; fee : Money.Amount.Stable.V1.t
    ; buy : Money.Amount.Stable.V1.t
    ; expires_at : Utc_time.Stable.V1.t
    ; executed : bool
    }
  [@@deriving bin_io, sexp, compare, equal]
end

type t =
  { find_customer : Kyc_core.Customer_id.t -> Customer_ref.t option Deferred.t
  ; set_customer : Kyc_core.Customer_id.t -> Customer_ref.t -> unit Deferred.t
  ; find_transfer : Transfer.Id.t -> Transfer_record.t option Deferred.t
  ; find_transfer_by_ref : string -> Transfer_record.t option Deferred.t
  ; set_transfer : Transfer_record.t -> unit Deferred.t
  ; find_challenge : Sca.Id.t -> Challenge_record.t option Deferred.t
  ; set_challenge : Challenge_record.t -> unit Deferred.t
  ; find_swap : Swap.Id.t -> Swap_record.t option Deferred.t
  ; set_swap : Swap_record.t -> unit Deferred.t
  ; find_card_request : string -> Card_core.Ids.Card_id.t option Deferred.t
  ; set_card_request : string -> Card_core.Ids.Card_id.t -> unit Deferred.t
  }

(** Hash tables in this process. *)
val memory : unit -> t
