open! Core
open Async_kernel
open Banking_provider
open Payments_core

module Transfer_record = struct
  type t =
    { id : Transfer.Id.Stable.V1.t
    ; account : Account_ref.Stable.V1.t
    ; rail : Rail.Stable.V1.t
    ; amount : Money.Amount.Stable.V1.t
    ; fee : Money.Amount.Stable.V1.t
    ; details : Transfer.Details.t
    ; challenge : string option
    ; provider_ref : string option
    ; status : Transfer.Status.t
    ; updated_at : Utc_time.Stable.V1.t
    }
  [@@deriving bin_io, sexp, compare, equal]
end

module Challenge_record = struct
  type t =
    { challenge : Sca_challenge.t
    ; user_id : string
    ; striga_challenge : string
    ; striga_method : string option
    ; settled : bool
    }
  [@@deriving sexp, compare, equal]
end

module Swap_record = struct
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
  ; find_card_token :
      Card_core.Ids.Card_id.t -> Card_core.Pan_display_token.t option Deferred.t
  ; set_card_token :
      Card_core.Ids.Card_id.t -> Card_core.Pan_display_token.t -> unit Deferred.t
  }

let memory () =
  let customers = Hashtbl.create (module Kyc_core.Customer_id) in
  let transfers = Hashtbl.create (module Transfer.Id) in
  let by_ref = Hashtbl.create (module String) in
  let challenges = Hashtbl.create (module Sca.Id) in
  let swaps = Hashtbl.create (module Swap.Id) in
  let cards = Hashtbl.create (module String) in
  let card_tokens = Hashtbl.create (module Card_core.Ids.Card_id) in
  let set tbl key data = Hashtbl.set tbl ~key ~data in
  { find_customer = (fun k -> return (Hashtbl.find customers k))
  ; set_customer = (fun k v -> return (set customers k v))
  ; find_transfer = (fun k -> return (Hashtbl.find transfers k))
  ; find_transfer_by_ref =
      (fun r -> return (Option.bind (Hashtbl.find by_ref r) ~f:(Hashtbl.find transfers)))
  ; set_transfer =
      (fun (r : Transfer_record.t) ->
        set transfers r.id r;
        Option.iter r.provider_ref ~f:(fun p -> set by_ref p r.id);
        return ())
  ; find_challenge = (fun k -> return (Hashtbl.find challenges k))
  ; set_challenge =
      (fun (r : Challenge_record.t) -> return (set challenges r.challenge.id r))
  ; find_swap = (fun k -> return (Hashtbl.find swaps k))
  ; set_swap = (fun (r : Swap_record.t) -> return (set swaps r.id r))
  ; find_card_request = (fun k -> return (Hashtbl.find cards k))
  ; set_card_request = (fun k v -> return (set cards k v))
  ; find_card_token = (fun k -> return (Hashtbl.find card_tokens k))
  ; set_card_token = (fun k v -> return (set card_tokens k v))
  }
;;
