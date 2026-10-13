open! Core
open Banking_provider
open Kyc_core
module Striga_kyc = Striga_client.User.Kyc
module S = Striga_client.User.Kyc_status
module Event = Banking_provider.Event
module Event_id = Banking_provider.Event_id

let tier_state (s : S.t) ~at : Verification.State.t =
  match s with
  | Not_started -> Pending
  | Initiated | Pending_review | On_hold -> Sent
  | Approved -> Verified at
  | Rejected -> Failed "rejected, may resubmit"
  | Rejected_final -> Failed "rejected"
  | Other s -> Failed s
;;

let tier_status (k : Striga_kyc.t) n =
  let tier =
    match n with
    | 1 -> k.tier1
    | 2 -> k.tier2
    | 3 -> k.tier3
    | _ -> k.tier0
  in
  Option.bind tier ~f:(fun (t : Striga_client.User.Tier.t) -> t.status)
;;

let any_tier_approved k =
  List.exists [ 1; 2; 3 ] ~f:(fun n ->
    Option.equal S.equal (tier_status k n) (Some Approved))
;;

let fields_of_labels labels : Person.Field.t list =
  (* Whole words only: a substring test would read "DAMAGED" as an age problem. *)
  let words = List.concat_map labels ~f:(String.split ~on:'_') in
  let has w = List.mem words w ~equal:String.equal in
  let fields =
    List.concat
      [ (if has "ADDRESS" then [ Person.Field.Residential_address ] else [])
      ; (if has "BIRTH" || has "AGE" || has "UNDERAGE" then [ Date_of_birth ] else [])
      ; (if has "NAME" then [ Given_name; Family_name ] else [])
      ; (if has "NATIONALITY" || has "CITIZENSHIP" then [ Nationality ] else [])
      ]
    |> List.dedup_and_sort ~compare:Person.Field.compare
  in
  (* Anything else (a blurry or expired document, a selfie mismatch) means the identity
     document has to be done again, which re-submits the identity fields. *)
  if List.is_empty fields
  then [ Given_name; Family_name; Date_of_birth; Nationality ]
  else fields
;;

let status (k : Striga_kyc.t) : Status.t =
  if any_tier_approved k
  then Approved
  else (
    match k.status with
    | None | Some Not_started -> Created
    | Some (Initiated | Pending_review | On_hold) -> Verifying
    | Some Approved -> Approved
    | Some Rejected ->
      Needs_resubmission (fields_of_labels (Option.value k.details ~default:[]))
    | Some Rejected_final ->
      let reason =
        match k.rejection_comments with
        | Some { user_comment = Some c; _ } -> c
        | _ ->
          (match k.details with
           | Some (_ :: _ as d) -> String.concat ~sep:"," d
           | _ -> "rejected")
      in
      Rejected reason
    | Some (Other s) -> Rejected s)
;;

let same_kind (a : Verification.State.t) (b : Verification.State.t) =
  match a, b with
  | Pending, Pending | Sent, Sent | Verified _, Verified _ | Expired, Expired -> true
  | Failed x, Failed y -> String.equal x y
  | _ -> false
;;

let kyc_status customer ?previous (k : Striga_kyc.t) ~at =
  let flag b : Verification.State.t =
    if Option.value b ~default:false then Verified at else Pending
  in
  let tier n =
    Option.value_map
      (tier_status k n)
      ~default:Verification.State.Pending
      ~f:(tier_state ~at)
  in
  let observed : (Verification.Step.t * Verification.State.t) list =
    [ Email, flag k.email_verified
    ; Mobile, flag k.mobile_verified
    ; Identity_document, tier 1
    ; Liveness, tier 1
    ; Address_proof, tier 2
    ; Source_of_funds, tier 3
    ]
  in
  let base = Customer.Kyc_status.initial customer in
  let keep step state =
    match previous with
    | None -> state
    | Some (p : Customer.Kyc_status.t) ->
      (match List.Assoc.find p.steps step ~equal:Verification.Step.equal with
       | Some old when same_kind old state -> old
       | _ -> state)
  in
  let with_steps =
    List.fold observed ~init:base ~f:(fun acc (step, state) ->
      Customer.Kyc_status.with_step acc step (keep step state))
  in
  { with_steps with status = status k }
;;

let transitions ~(from : Status.t) ~(to_ : Status.t) : Status.Transition.t list =
  match from, to_ with
  | Created, Verifying | Needs_resubmission _, Verifying -> [ Submit ]
  | (Created | Needs_resubmission _), Approved -> [ Submit; Approve ]
  | Verifying, Approved -> [ Approve ]
  | Created, Needs_resubmission fs -> [ Submit; Request_resubmission fs ]
  | (Verifying | Approved), Needs_resubmission fs -> [ Request_resubmission fs ]
  | Created, Rejected r -> [ Submit; Reject r ]
  | (Verifying | Needs_resubmission _), Rejected r -> [ Reject r ]
  | _ -> []
;;

let status_name (s : Status.t) =
  match s with
  | Created -> "Created"
  | Verifying -> "Verifying"
  | Approved -> "Approved"
  | Rejected _ -> "Rejected"
  | Needs_resubmission _ -> "Needs_resubmission"
  | Blocked _ -> "Blocked"
  | Closed _ -> "Closed"
;;

let transition_name (t : Status.Transition.t) =
  match t with
  | Submit -> "Submit"
  | Approve -> "Approve"
  | Reject _ -> "Reject"
  | Request_resubmission _ -> "Request_resubmission"
  | Block _ -> "Block"
  | Unblock -> "Unblock"
  | Close _ -> "Close"
;;

let state_name (s : Verification.State.t) =
  match s with
  | Pending -> "Pending"
  | Sent -> "Sent"
  | Verified _ -> "Verified"
  | Failed _ -> "Failed"
  | Expired -> "Expired"
;;

let events ~(previous : Customer.Kyc_status.t) ~(current : Customer.Kyc_status.t) ~at =
  let user = Customer_ref.to_string current.customer in
  let event id update : Event.t =
    { id = Event_id.of_string (sprintf "kyc:%s:%s" user id)
    ; at
    ; kind = Kyc { customer = current.customer; update }
    }
  in
  let steps =
    List.filter_map current.steps ~f:(fun (step, state) ->
      let before =
        List.Assoc.find previous.steps step ~equal:Verification.Step.equal
        |> Option.value ~default:Verification.State.Pending
      in
      if same_kind before state
      then None
      else
        Some
          (event
             (sprintf
                "step:%s:%s"
                (Sexp.to_string [%sexp (step : Verification.Step.t)])
                (state_name state))
             (Step { step; state })))
  in
  let _, statuses =
    List.fold_map
      (transitions ~from:previous.status ~to_:current.status)
      ~init:previous.status
      ~f:(fun from tr ->
        let next = Status.apply from tr ~actor:(Provider "striga") |> Result.ok in
        ( Option.value next ~default:from
        , event (sprintf "%s:%s" (status_name from) (transition_name tr)) (Status tr) ))
  in
  steps @ statuses
;;
