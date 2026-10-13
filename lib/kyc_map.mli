(** Striga's KYC object in kyc-core terms.

    Striga runs KYC per tier: tier 0 is the verified e-mail and mobile, tier 1 the
    identity document and selfie (SumSub), tier 2 adds proof of address, tier 3 source of
    funds. Its top-level [status] follows the latest tier the user attempted, so a
    rejected upgrade to tier 2 reports [REJECTED] for a user who is still approved at
    tier 1. Here the customer stays [Approved] while any tier from 1 up is approved, and
    the failed upgrade shows on its steps.

    {v
      Striga                        kyc-core
      emailVerified                 Email verified
      mobileVerified                Mobile verified
      tier1 status                  Identity_document, Liveness
      tier2 status                  Address_proof
      tier3 status                  Source_of_funds

      NOT_STARTED                   Created
      INITIATED, PENDING_REVIEW,
      ON_HOLD                       Verifying
      APPROVED (any tier >= 1)      Approved
      REJECTED                      Needs_resubmission (fields from the labels)
      REJECTED_FINAL                Rejected
    v} *)

open! Core
open Banking_provider
module Striga_kyc := Striga_client.User.Kyc

(** The state of one tier's steps. *)
val tier_state
  :  Striga_client.User.Kyc_status.t
  -> at:Time_ns.t
  -> Kyc_core.Verification.State.t

(** The customer status. *)
val status : Striga_kyc.t -> Kyc_core.Status.t

(** Fields to submit again for Striga's rejection labels (e.g. [BAD_PROOF_OF_ADDRESS] is
    the residential address). Labels about the document itself ask for the identity fields
    again. Never empty. *)
val fields_of_labels : string list -> Kyc_core.Person.Field.t list

(** The status and steps as {!Customer.Kyc_status.t}. A step whose state has not changed
    kind since [previous] keeps its earlier value (and so its verification time); new
    verifications are stamped [at], since Striga does not say when they happened. *)
val kyc_status
  :  Customer_ref.t
  -> ?previous:Customer.Kyc_status.t
  -> Striga_kyc.t
  -> at:Time_ns.t
  -> Customer.Kyc_status.t

(** The transitions that take a case from [from] to [to_] ([Created] to [Approved] is
    [Submit] then [Approve]); empty when they are equal or no transition leads there. *)
val transitions
  :  from:Kyc_core.Status.t
  -> to_:Kyc_core.Status.t
  -> Kyc_core.Status.Transition.t list

(** The events between two observations of one customer: each step that changed kind, then
    the status transitions. Event ids are derived from the change
    ([kyc:<user>:step:<Step>:<State>], [kyc:<user>:<From>:<Transition>]) so the same
    change seen by a poll and by a webhook is the same event. *)
val events
  :  previous:Customer.Kyc_status.t
  -> current:Customer.Kyc_status.t
  -> at:Time_ns.t
  -> Event.t list
