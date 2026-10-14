open! Core
open! Async
open Banking_provider
module Suite = Conformance.Make (Striga_provider.Adapter) (Striga_provider.Adapter)

let config ~run_id =
  let base = Conformance.Config.default ~run_id in
  { base with
    (* EUR accounts appear minutes after a simulated KYC approval. *)
    timeout = Time_ns.Span.of_min 6.
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
        ; (* The suite's timeout should decide, not the adapter's shorter default. *)
          provisioning_timeout = (config ~run_id).timeout
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
