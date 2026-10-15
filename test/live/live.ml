open! Core
open! Async
open Banking_provider
module Suite = Conformance.Make (Striga_provider.Adapter) (Striga_provider.Adapter)

(* An Estonian resident with an Estonian mobile, as in striga-client's live walk. Names
   stay synthetic. *)
let person ~run_id =
  let open Kyc_core in
  let stamp = String.filter run_id ~f:Char.is_digit in
  { Person.given_name = Pii.create "Ada"
  ; family_name = Pii.create "Sandbox"
  ; date_of_birth = Pii.create (Date.create_exn ~y:1990 ~m:Jan ~d:15)
  ; nationality = Pii.create (Country.of_string "EE")
  ; residential_address =
      Pii.create
        { Address.line1 = "Sepapaja 6"
        ; line2 = None
        ; city = "Tallinn"
        ; region = None
        ; postal_code = Some "11415"
        ; country = Country.of_string "EE"
        }
  ; email = Pii.create "hello@winterchill.xyz"
  ; mobile = Pii.create ("+3725" ^ String.suffix (String.make 7 '0' ^ stamp) 7)
  }
;;

(* [hello+striga-<customer id>@winterchill.xyz]: unique per customer, as Striga wants. *)
let email_for customer_id ~email:_ =
  let tag =
    String.filter_map (Kyc_core.Customer_id.to_string customer_id) ~f:(fun c ->
      if Char.is_alphanum c || Char.equal c '-' then Some (Char.lowercase c) else None)
  in
  sprintf "hello+striga-%s@winterchill.xyz" tag
;;

let config ~run_id =
  let base = Conformance.Config.default ~run_id in
  { base with
    person = person ~run_id
  ; (* Accounts are listed within seconds of KYC approval (EUR and USDC once the adapter
       has opened an SCA session) and simulated credits land within seconds. *)
    timeout = Time_ns.Span.of_min 2.
  ; poll_interval = Time_ns.Span.of_sec 3.
  ; (* The sandbox's fixed OTP. *)
    sca_code = Sensitive.of_string "123456"
  ; (* The sandbox accepts the textbook German example IBAN for payouts (the striga-client
       walk used it). *)
    payee_iban = "DE89370400440532013000"
  }
;;

let run () =
  let run_id =
    sprintf "sp%d" (Time_ns.to_int_ns_since_epoch (Time_ns.now ()) / 1_000_000_000)
  in
  match
    Striga_provider.Adapter.of_env
      ~config:
        { Striga_provider.Adapter.Config.default with
          sandbox_settlement = `Immediate
        ; email_for
        }
      ()
  with
  | Error e ->
    Core.eprint_s [%sexp (e : Error.t)];
    Stdlib.exit 1
  | Ok adapter ->
    let only = Sys.getenv "STRIGA_CONFORMANCE_ONLY" in
    let scenarios =
      Suite.scenarios (config ~run_id)
      |> List.filter ~f:(fun (s : Suite.scenario) ->
        match only with
        | None -> true
        | Some sub -> String.is_substring s.name ~substring:sub)
    in
    let%map results =
      Deferred.List.map ~how:`Sequential scenarios ~f:(fun s ->
        let started = Time_ns.now () in
        let%map result =
          Monitor.try_with_or_error ~extract_exn:true (fun () -> s.run adapter)
          >>| Or_error.join
        in
        let took = Time_ns.diff (Time_ns.now ()) started in
        (match result with
         | Ok () ->
           Core.printf "ok    %s (%s)\n%!" s.name (Time_ns.Span.to_short_string took)
         | Error e ->
           Core.printf
             "FAIL  %s (%s)\n      %s\n%!"
             s.name
             (Time_ns.Span.to_short_string took)
             (Error.to_string_hum e));
        result)
    in
    List.iter (Striga_provider.Adapter.background_errors adapter) ~f:(fun e ->
      Core.printf "background: %s\n" (Error.to_string_hum e));
    let failed = List.count results ~f:Result.is_error in
    Core.printf
      "conformance on the Striga sandbox: %d passed, %d failed\n%!"
      (List.length results - failed)
      failed;
    if failed > 0 then Stdlib.exit 1
;;

let () =
  let live = Option.equal String.equal (Sys.getenv "STRIGA_LIVE_TESTS") (Some "1") in
  if not (live && Striga_client.Config.env_available ())
  then
    (* Core's printer: the Async scheduler never starts on this path. *)
    Core.print_endline
      "striga-provider conformance skipped (set STRIGA_API_KEY, STRIGA_API_SECRET and \
       STRIGA_LIVE_TESTS=1)"
  else
    Command_unix.run
      (Command.async
         ~summary:"conformance suite on the Striga sandbox"
         (Command.Param.return run))
;;
