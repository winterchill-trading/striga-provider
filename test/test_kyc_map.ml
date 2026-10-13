open! Core
open Striga_provider
open Banking_provider

let user = Refs.customer ~user_id:"00000000-0000-4000-8000-000000000001"

let%expect_test "a tier 1 approval verifies e-mail, mobile, document and liveness" =
  let k = Fixture.load "kyc-status.json" Striga_client.User.Kyc.t_of_yojson in
  let status = Kyc_map.kyc_status user k ~at:Fixture.at in
  print_s [%sexp (status : Customer.Kyc_status.t)];
  [%expect
    {|
    ((customer 00000000-0000-4000-8000-000000000001) (status Approved) (tier T2)
     (steps
      ((Email (Verified "2026-10-13 22:00:00Z"))
       (Mobile (Verified "2026-10-13 22:00:00Z"))
       (Identity_document (Verified "2026-10-13 22:00:00Z"))
       (Liveness (Verified "2026-10-13 22:00:00Z")) (Address_proof Pending)
       (Source_of_funds Pending))))
    |}]
;;

let%expect_test "a rejected tier 2 upgrade keeps the customer approved" =
  let k = Fixture.load "docs-webhook-kyc.json" Striga_client.User.Kyc.t_of_yojson in
  print_s [%sexp (Kyc_map.status k : Kyc_core.Status.t)];
  let status = Kyc_map.kyc_status user k ~at:Fixture.at in
  print_s
    [%sexp
      (List.Assoc.find status.steps Address_proof ~equal:Kyc_core.Verification.Step.equal
       : Kyc_core.Verification.State.t option)];
  print_s [%sexp (Kyc_map.status { k with tier1 = None } : Kyc_core.Status.t)];
  [%expect
    {|
    Approved
    ((Failed "rejected, may resubmit"))
    (Needs_resubmission (Residential_address))
    |}]
;;

let%expect_test "rejection labels name fields, never an empty list" =
  let show l =
    print_s [%sexp (Kyc_map.fields_of_labels l : Kyc_core.Person.Field.t list)]
  in
  show [ "BAD_PROOF_OF_ADDRESS" ];
  show [ "WRONG_USER_REGION"; "DOCUMENT_DAMAGED" ];
  show [];
  [%expect
    {|
    (Residential_address)
    (Given_name Family_name Date_of_birth Nationality)
    (Given_name Family_name Date_of_birth Nationality)
    |}]
;;

let%expect_test "events between two observations, with stable ids" =
  let k = Fixture.load "kyc-status.json" Striga_client.User.Kyc.t_of_yojson in
  let previous = Customer.Kyc_status.initial user in
  let current = Kyc_map.kyc_status user ~previous k ~at:Fixture.at in
  let events = Kyc_map.events ~previous ~current ~at:Fixture.at in
  List.iter events ~f:(fun (e : Event.t) ->
    print_s [%sexp (e.id : Event_id.t), (e.kind : Event.Kind.t)]);
  (* Seen again later: nothing new, and the verification times stay. *)
  let again =
    Kyc_map.kyc_status
      user
      ~previous:current
      k
      ~at:(Time_ns.add Fixture.at Time_ns.Span.hour)
  in
  print_s [%sexp (Customer.Kyc_status.equal again current : bool)];
  print_s
    [%sexp
      (Kyc_map.events ~previous:current ~current:again ~at:Fixture.at : Event.t list)];
  [%expect
    {|
    (kyc:00000000-0000-4000-8000-000000000001:step:Email:Verified
     (Kyc (customer 00000000-0000-4000-8000-000000000001)
      (update (Step (step Email) (state (Verified "2026-10-13 22:00:00Z"))))))
    (kyc:00000000-0000-4000-8000-000000000001:step:Mobile:Verified
     (Kyc (customer 00000000-0000-4000-8000-000000000001)
      (update (Step (step Mobile) (state (Verified "2026-10-13 22:00:00Z"))))))
    (kyc:00000000-0000-4000-8000-000000000001:step:Identity_document:Verified
     (Kyc (customer 00000000-0000-4000-8000-000000000001)
      (update
       (Step (step Identity_document) (state (Verified "2026-10-13 22:00:00Z"))))))
    (kyc:00000000-0000-4000-8000-000000000001:step:Liveness:Verified
     (Kyc (customer 00000000-0000-4000-8000-000000000001)
      (update (Step (step Liveness) (state (Verified "2026-10-13 22:00:00Z"))))))
    (kyc:00000000-0000-4000-8000-000000000001:Created:Submit
     (Kyc (customer 00000000-0000-4000-8000-000000000001)
      (update (Status Submit))))
    (kyc:00000000-0000-4000-8000-000000000001:Verifying:Approve
     (Kyc (customer 00000000-0000-4000-8000-000000000001)
      (update (Status Approve))))
    true
    ()
    |}]
;;
