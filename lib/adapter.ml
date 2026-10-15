open! Core
open Async
open Banking_provider
open Payments_core
module Sc = Striga_client
module Card = Card_core.Card
module Ids = Card_core.Ids
module Pan_display_token = Card_core.Pan_display_token
module Response_code = Card_core.Response_code
module Transfer_record = Store.Transfer_record
module Challenge_record = Store.Challenge_record
module Swap_record = Store.Swap_record

module Config = struct
  type t =
    { poll_interval : Time_ns.Span.t
    ; account_retry : Time_ns.Span.t
    ; deposit_timeout : Time_ns.Span.t
    ; sandbox_code : string
    ; auto_session : unit -> bool
    ; payment_account_consent : [ `Record of string option | `By_application ]
    ; statement_window : Time_ns.Span.t
    ; end_user_ip : string
    ; email_for : Kyc_core.Customer_id.t -> email:string -> string
    ; sandbox_settlement : [ `Immediate | `Manual ]
    ; card_3ds_password : unit -> string
    ; bic_for : Iban.t -> Bic.t option
    }

  (* [local+tag@domain]: Striga refuses a second user with the same e-mail, and test runs
     reuse one synthetic person. Tags keep only characters every mail system accepts. A
     local part over 64 characters is refused ([00002] "Invalid e-mail ID"), so a long tag
     is cut and ends in a digest of the whole customer id to stay unique. *)
  let tagged_email customer_id ~email =
    let id = Kyc_core.Customer_id.to_string customer_id in
    let tag =
      String.filter_map id ~f:(fun c ->
        if Char.is_alphanum c || Char.equal c '-' then Some (Char.lowercase c) else None)
    in
    match String.lsplit2 email ~on:'@' with
    | Some (local, domain) ->
      let local = List.hd_exn (String.split local ~on:'+') in
      let room = 64 - String.length local - 1 in
      let tag =
        if String.length tag <= room
        then tag
        else (
          let digest = String.prefix (Md5.to_hex (Md5.digest_string id)) 12 in
          String.prefix tag (Int.max 0 (room - 13)) ^ "-" ^ digest)
      in
      sprintf "%s+%s@%s" local tag domain
    | None -> email
  ;;

  (* Striga's documented 3-D Secure charset: no hyphen, underscore, at sign or space. *)
  let three_ds_symbols = "!\"#;:?&*()+=/\\,.[]{}"

  let valid_3ds_password p =
    let len = String.length p in
    len >= 8
    && len <= 36
    && String.for_all p ~f:(fun c -> Char.is_alphanum c || String.mem three_ds_symbols c)
    && String.exists p ~f:Char.is_uppercase
    && String.exists p ~f:Char.is_lowercase
    && String.exists p ~f:Char.is_digit
    && String.exists p ~f:(fun c -> String.mem three_ds_symbols c)
  ;;

  let random_password () =
    (* Upper, lower, digit and symbol. The UUID's hyphens are outside Striga's charset,
       which is why the first version of this default was refused; keep hex digits only. *)
    let hex = String.filter (Sc.Transport.uuid_v4 ()) ~f:Char.is_alphanum in
    sprintf "Wc#%s9z!" (String.prefix hex 14)
  ;;

  let default =
    { poll_interval = Time_ns.Span.of_sec 3.
    ; (* Crypto accounts are listed seconds after KYC approval; EUR and USDC as soon as
         the user has an SCA session. A short retry covers both. *)
      account_retry = Time_ns.Span.of_sec 30.
    ; (* The simulator credits a deposit asynchronously, within seconds. *)
      deposit_timeout = Time_ns.Span.of_min 1.
    ; sandbox_code = "123456"
    ; auto_session = (fun () -> true)
    ; payment_account_consent = `Record None
    ; statement_window = Time_ns.Span.day
    ; (* The address the striga-client sandbox runs used; Striga only checks that it is
         outside restricted regions. A service passes its customer's real IP. *)
      end_user_ip = "185.46.212.10"
    ; email_for = tagged_email
    ; sandbox_settlement = `Manual
    ; card_3ds_password = random_password
    ; bic_for = (fun _ -> None)
    }
  ;;
end

type t =
  { config : Config.t
  ; tr : Sc.Transport.t
  ; store : Store.t
  ; subscribers : Event.t Pipe.Writer.t Bag.t
  ; published : Event_id.t Hash_set.t
  ; kyc_seen : (string, Customer.Kyc_status.t) Hashtbl.t (** by user id *)
  ; accounts_seen : Account_ref.t Hash_set.t
  ; cards_seen : (string, string) Hashtbl.t (** card id to user id *)
  ; ibans : (string, Iban.t) Hashtbl.t (** by account id, for SEPA deposits *)
  ; mutable captures : Event.t Queue.t list
  (** webhook ingestion collects what one delivery publishes *)
  ; mutable polling : bool
  ; mutable errors : Error.t list
  }

let transport t = t.tr
let background_errors t = List.rev t.errors
let name _ = "striga"
let now () = Time_ns.now ()
let note_error t e = t.errors <- e :: t.errors

let is_sandbox t =
  match Uri.host (Sc.Transport.config t.tr).base_url with
  | Some host -> Sc.Config.is_sandbox_host host
  | None -> false
;;

let create ?(config = Config.default) ?(store = Store.memory ()) tr =
  { config
  ; tr
  ; store
  ; subscribers = Bag.create ()
  ; published = Hash_set.create (module Event_id)
  ; kyc_seen = Hashtbl.create (module String)
  ; accounts_seen = Hash_set.create (module Account_ref)
  ; cards_seen = Hashtbl.create (module String)
  ; ibans = Hashtbl.create (module String)
  ; captures = []
  ; polling = false
  ; errors = []
  }
;;

let of_env ?config ?store () =
  Or_error.map (Sc.Config.of_env ()) ~f:(fun c ->
    create ?config ?store (Sc.Transport.create c))
;;

(* {2 Events} *)

let publish t (e : Event.t) =
  if not (Hash_set.mem t.published e.id)
  then (
    Hash_set.add t.published e.id;
    List.iter t.captures ~f:(fun q -> Queue.enqueue q e);
    Bag.iter t.subscribers ~f:(fun w ->
      if not (Pipe.is_closed w) then Pipe.write_without_pushback w e))
;;

let event ~id ~at kind = { Event.id = Event_id.of_string id; at; kind }

(* {2 KYC} *)

let observe_kyc t ~user_id (k : Sc.User.Kyc.t) =
  let customer = Refs.customer ~user_id in
  let at = now () in
  let previous =
    Hashtbl.find t.kyc_seen user_id
    |> Option.value ~default:(Customer.Kyc_status.initial customer)
  in
  let current = Kyc_map.kyc_status customer ~previous k ~at in
  Hashtbl.set t.kyc_seen ~key:user_id ~data:current;
  List.iter (Kyc_map.events ~previous ~current ~at) ~f:(publish t);
  current
;;

let fetch_kyc t ~user_id =
  let%map.Deferred.Or_error k = Sc.User.kyc_status t.tr ~user_id in
  observe_kyc t ~user_id k
;;

(* {2 Transfers} *)

let status_rank (s : Transfer.Status.t) =
  match s with
  | Draft -> 0
  | Awaiting_sca -> 1
  | Submitted -> 2
  | Pending -> 3
  | Timed_out -> 4
  | Settled -> 5
  | Recall_requested _ | Recall_refused _ -> 6
  | Rejected _ | Failed _ | Returned _ | Recalled | Cancelled | Reorged -> 7
;;

let status_of_update (u : Transfer_update.t) : Transfer.Status.t option =
  match u with
  | Submitted -> Some Submitted
  | Pending -> Some Pending
  | Settled | Lightning_paid _ -> Some Settled
  | Rejected r -> Some (Rejected r)
  | Failed f -> Some (Failed f)
  | Timed_out -> Some Timed_out
  | Returned r -> Some (Returned r)
  | Cancelled -> Some Cancelled
  | Recall_requested r -> Some (Recall_requested r)
  | Recall_answer { accepted = true; _ } -> Some Recalled
  | Recall_answer { accepted = false; reason } -> Some (Recall_refused reason)
  | Reorged _ -> Some Reorged
  | Status_report _ | Confirmations _ -> None
;;

(* Applies an update to the stored transfer unless it is already at or past it (Striga
   lists entries newest first, and a poll can see them in any order). *)
let advance t (r : Transfer_record.t) (u : Transfer_update.t) =
  match status_of_update u with
  | Some s when status_rank s > status_rank r.status ->
    let r = { r with status = s; updated_at = now () } in
    let%map () = t.store.set_transfer r in
    r
  | _ -> return r
;;

let transfer_event t (r : Transfer_record.t) ~id ~provider_ref (u : Transfer_update.t) =
  publish
    t
    (event ~id ~at:(now ()) (Transfer { transfer = r.id; provider_ref; update = u }))
;;

let own_iban t ~user_id ~account_id =
  match Hashtbl.find t.ibans account_id with
  | Some i -> return (Some i)
  | None ->
    (match%map Sc.Wallet.enrich_account t.tr ~user_id ~account_id with
     | Ok e ->
       let iban = Option.bind e.iban ~f:(fun s -> Iban.of_string s |> Result.ok) in
       Option.iter iban ~f:(fun data -> Hashtbl.set t.ibans ~key:account_id ~data);
       iban
     | Error _ -> None)
;;

let observe_tx t ~user_id ~account_id (tx : Sc.Transaction.t) =
  let account = Refs.account ~user_id ~account_id in
  match Tx_map.event_id tx with
  | None -> return ()
  | Some id when Hash_set.mem t.published id -> return ()
  | Some id ->
    let at = Tx_map.at tx ~default:(now ()) in
    let%bind () =
      match Tx_map.outgoing_update tx, tx.id with
      | Some u, Some provider_ref ->
        (match%bind t.store.find_transfer_by_ref provider_ref with
         | None -> return ()
         | Some r ->
           let%map (_ : Transfer_record.t) = advance t r u in
           publish
             t
             { id; at; kind = Transfer { transfer = r.id; provider_ref; update = u } })
      | _ -> return ()
    in
    (match Tx_map.direction tx, Tx_map.incoming_rail tx with
     | Some `In, Some rail ->
       let%map own_iban =
         match rail with
         | Sepa_credit | Sepa_instant -> own_iban t ~user_id ~account_id
         | _ -> return None
       in
       (match Tx_map.incoming ~account ~own_iban tx with
        | Ok (Some kind) -> publish t { id; at; kind }
        | Ok None -> ()
        | Error e -> note_error t (Error.tag e ~tag:(Event_id.to_string id)))
     | Some `Out, _ | None, _ ->
       (* Incoming status changes with no credit (a SEPA pay-in denied later). *)
       (match Tx_map.incoming ~account ~own_iban:None tx with
        | Ok (Some (Transfer _ as kind)) -> publish t { id; at; kind }
        | _ -> ());
       return ()
     | Some `In, None -> return ())
;;

let statement_range t =
  let stop = Time_ns.add (now ()) Time_ns.Span.minute in
  let start = Time_ns.sub (now ()) t.config.statement_window in
  start, stop
;;

let read_statement t ~user_id ~account_id ~start ~stop =
  let rec page n acc =
    let%bind.Deferred.Or_error p =
      Sc.Wallet.statement t.tr ~user_id ~account_id ~start ~stop ~page:n ~limit:100 ()
    in
    let acc = acc @ p.transactions in
    let total = Option.value p.total ~default:(List.length acc) in
    if List.is_empty p.transactions || List.length acc >= total || n >= 20
    then return (Ok acc)
    else page (n + 1) acc
  in
  page 1 []
;;

let scan_account t account =
  match Refs.account_parts account with
  | Error _ as e -> return e
  | Ok (user_id, account_id) ->
    let start, stop = statement_range t in
    (match%bind read_statement t ~user_id ~account_id ~start ~stop with
     | Error _ as e -> return e
     | Ok txs ->
       (* Oldest first, so a transfer moves forward through its states. *)
       let txs = List.rev txs in
       let%map () =
         Deferred.List.iter ~how:`Sequential txs ~f:(observe_tx t ~user_id ~account_id)
       in
       Ok txs)
;;

let observe_card_tx t ~card_id (c : Sc.Card.Card_transaction.t) =
  match Card_tx_map.event_id c with
  | None -> ()
  | Some id when Hash_set.mem t.published id -> ()
  | Some id ->
    (match Card_tx_map.update ~card_id c with
     | Ok (Some (card, update)) ->
       publish
         t
         { id
         ; at = Striga_time.parse_or ~default:(now ()) c.created_at
         ; kind = Card { card; update }
         }
     | Ok None -> ()
     | Error e -> note_error t (Error.tag e ~tag:(Event_id.to_string id)))
;;

let card_statement t ~card_id =
  let start, stop = statement_range t in
  let%map.Deferred.Or_error page =
    Sc.Card.statement t.tr ~card_id ~start ~stop ~limit:100 ()
  in
  List.iter (List.rev page.transactions) ~f:(observe_card_tx t ~card_id);
  page.transactions
;;

(* {2 Polling} *)

let poll_once t =
  let users = Hashtbl.keys t.kyc_seen in
  let%bind () =
    Deferred.List.iter ~how:`Sequential users ~f:(fun user_id ->
      match%map fetch_kyc t ~user_id with
      | Ok (_ : Customer.Kyc_status.t) -> ()
      | Error e -> note_error t e)
  in
  let%bind () =
    Deferred.List.iter ~how:`Sequential (Hash_set.to_list t.accounts_seen) ~f:(fun a ->
      match%map scan_account t a with
      | Ok (_ : Sc.Transaction.t list) -> ()
      | Error e -> note_error t e)
  in
  Deferred.List.iter ~how:`Sequential (Hashtbl.keys t.cards_seen) ~f:(fun card_id ->
    match%map card_statement t ~card_id with
    | Ok (_ : Sc.Card.Card_transaction.t list) -> ()
    | Error e -> note_error t e)
;;

let rec poll_loop t =
  if Bag.is_empty t.subscribers
  then (
    t.polling <- false;
    return ())
  else (
    let%bind () = poll_once t in
    let%bind () = Clock_ns.after t.config.poll_interval in
    poll_loop t)
;;

let events t =
  let r, w = Pipe.create () in
  let elt = Bag.add t.subscribers w in
  don't_wait_for
    (let%map () = Pipe.closed w in
     Bag.remove t.subscribers elt);
  if not t.polling
  then (
    t.polling <- true;
    don't_wait_for (poll_loop t));
  r
;;

let track_account t a = Hash_set.add t.accounts_seen a

let track_user t ~user_id =
  if not (Hashtbl.mem t.kyc_seen user_id)
  then
    Hashtbl.set
      t.kyc_seen
      ~key:user_id
      ~data:(Customer.Kyc_status.initial (Refs.customer ~user_id))
;;

(* {2 Helpers} *)

let poll_until ~timeout ~every f =
  let deadline = Time_ns.add (now ()) timeout in
  let rec loop () =
    match%bind f () with
    | Error _ as e -> return e
    | Ok (Some x) -> return (Ok x)
    | Ok None ->
      if Time_ns.( > ) (now ()) deadline
      then return (Or_error.error_string "timed out")
      else (
        let%bind () = Clock_ns.after every in
        loop ())
  in
  loop ()
;;

(* {2 SCA sessions}

   Striga lists a user's EUR and USDC accounts, and answers [/wallets/get/account] on
   them, only while the user has an SCA session (a login confirmed with a one-time code; a
   2FA reset revokes it). Without one the accounts exist but are left out of the listing,
   and reading one answers 403 [30070] [SCA_REQUIRED]. *)

module Session_challenge = struct
  type t =
    { challenge_id : string
    ; expires_at : Time_ns.t option
    }
  [@@deriving sexp_of]
end

let begin_session t customer =
  let user_id = Refs.user_id customer in
  let%bind.Deferred.Or_error (ch : Sc.Sca.Login_challenge.t) =
    Sc.Sca.login_start t.tr ~user_id ~verification_method:Sms
  in
  match ch.challenge_id with
  | Some challenge_id ->
    return
      (Ok
         { Session_challenge.challenge_id
         ; expires_at = Option.bind ch.date_expires ~f:Striga_time.parse
         })
  | None -> return (Or_error.error_string "Striga's SMS login returned no challenge id")
;;

let start_session t customer =
  Deferred.Or_error.map (begin_session t customer) ~f:(fun c -> c.challenge_id)
;;

let complete_session t customer ~challenge_id ~code =
  Sc.Sca.login_complete
    t.tr
    ~user_id:(Refs.user_id customer)
    ~verification_method:Sms
    ~ip:t.config.end_user_ip
    ~challenge_id
    ~code:(Sensitive.reveal code)
    ()
  |> Deferred.Or_error.ignore_m
;;

let session_required_tag = "Striga needs the customer's SCA session"

let is_session_required e =
  Sc.Api_error.is_sca_session_required e
  || String.is_substring (Error.to_string_hum e) ~substring:session_required_tag
;;

(* The adapter can answer its own login only where the code is known (the sandbox) and
   while the application lets it ([auto_session]); otherwise the error says a session is
   needed ({!is_session_required}) and the application asks the customer. *)
let open_session t ~user_id =
  if not (is_sandbox t && t.config.auto_session ())
  then return (Or_error.error_s [%message session_required_tag user_id])
  else
    (let customer = Refs.customer ~user_id in
     let%bind.Deferred.Or_error challenge_id = start_session t customer in
     complete_session
       t
       customer
       ~challenge_id
       ~code:(Sensitive.of_string t.config.sandbox_code))
    |> Deferred.Or_error.tag ~tag:"opening an SCA session"
;;

let with_session t ~user_id f =
  match%bind f () with
  | Error e when Sc.Api_error.is_sca_session_required e ->
    (match%bind open_session t ~user_id with
     | Ok () -> f ()
     | Error e' -> return (Error (Error.of_list [ e; e' ])))
  | r -> return r
;;

let wallet_account t ~user_id ~account_id =
  with_session t ~user_id (fun () -> Sc.Wallet.get_account t.tr ~user_id ~account_id)
;;

let user_created_at (u : Sc.User.t) = Striga_time.parse_or ~default:(now ()) u.created_at
let striga_error_code = Sc.Api_error.code_of_error

(* {2 Customers} *)

(* Splits an E.164 number into Striga's country code and number. The longest calling code
   that matches wins; the table holds the European ones and a few others. *)
let calling_codes =
  [ "1"
  ; "7"
  ; "30"
  ; "31"
  ; "32"
  ; "33"
  ; "34"
  ; "36"
  ; "39"
  ; "40"
  ; "41"
  ; "43"
  ; "44"
  ; "45"
  ; "46"
  ; "47"
  ; "48"
  ; "49"
  ; "351"
  ; "352"
  ; "353"
  ; "354"
  ; "356"
  ; "357"
  ; "358"
  ; "359"
  ; "370"
  ; "371"
  ; "372"
  ; "385"
  ; "386"
  ; "420"
  ; "421"
  ; "423"
  ]
;;

let split_mobile e164 =
  let digits = String.chop_prefix_if_exists e164 ~prefix:"+" in
  match
    List.filter calling_codes ~f:(fun c -> String.is_prefix digits ~prefix:c)
    |> List.max_elt ~compare:(fun a b -> Int.compare (String.length a) (String.length b))
  with
  | Some cc ->
    Ok
      { Sc.Common.Mobile.country_code = "+" ^ cc
      ; number = String.drop_prefix digits (String.length cc)
      }
  | None -> Or_error.error_s [%message "unknown calling code in mobile number"]
;;

let person_fields (person : Kyc_core.Person.t) =
  let open Or_error.Let_syntax in
  let reveal = Kyc_core.Pii.reveal in
  let%map mobile = split_mobile (reveal person.mobile) in
  let dob = reveal person.date_of_birth in
  let a = reveal person.residential_address in
  ( reveal person.given_name
  , reveal person.family_name
  , reveal person.email
  , mobile
  , Sc.Common.Date_of_birth.create
      ~year:(Date.year dob)
      ~month:(Month.to_int (Date.month dob))
      ~day:(Date.day dob)
  , { Sc.Common.Address.address_line1 = a.line1
    ; address_line2 = a.line2
    ; city = a.city
    ; postal_code = Option.value a.postal_code ~default:""
    ; state = a.region
    ; country = Kyc_core.Country.to_string a.country
    } )
;;

let customer_of_user ~customer_id (u : Sc.User.t) =
  { Customer.id = Refs.customer ~user_id:u.user_id
  ; customer_id
  ; created_at = user_created_at u
  }
;;

let create_customer t ~customer_id ~person =
  match%bind t.store.find_customer customer_id with
  | Some id ->
    let user_id = Refs.user_id id in
    track_user t ~user_id;
    (match%map Sc.User.get t.tr ~user_id with
     | Ok u -> Ok (customer_of_user ~customer_id u)
     | Error _ -> Ok { Customer.id; customer_id; created_at = now () })
  | None ->
    (match person_fields person with
     | Error _ as e -> return e
     | Ok (first_name, last_name, email, mobile, date_of_birth, address) ->
       let email = t.config.email_for customer_id ~email in
       (* A lost response may have created the user: look it up by the e-mail, which is
          unique at Striga, before creating another. *)
       let%bind existing = Sc.User.get_by_email t.tr ~email in
       let%bind.Deferred.Or_error user =
         match existing with
         | Ok u -> return (Ok u)
         | Error _ ->
           Sc.User.create
             t.tr
             ~first_name
             ~last_name
             ~email
             ~mobile
             ~date_of_birth
             ~address
             ()
       in
       let id = Refs.customer ~user_id:user.user_id in
       let%map () = t.store.set_customer customer_id id in
       track_user t ~user_id:user.user_id;
       Ok (customer_of_user ~customer_id user))
;;

let update_customer t customer ~person =
  match person_fields person with
  | Error _ as e -> return e
  | Ok (first_name, last_name, _email, mobile, date_of_birth, address) ->
    (* The e-mail stays: Striga's is the tagged unique one, and changing it would send a
       new verification code. *)
    Sc.User.update
      t.tr
      ~user_id:(Refs.user_id customer)
      ~first_name
      ~last_name
      ~mobile
      ~date_of_birth
      ~address
      ()
    |> Deferred.Or_error.ignore_m
;;

let kyc_tier_for (step : Kyc_core.Verification.Step.t) =
  match step with
  | Identity_document | Liveness -> 1
  | Address_proof -> 2
  | Source_of_funds -> 3
  | Email | Mobile -> 0
;;

let start_verification t customer (step : Kyc_core.Verification.Step.t) =
  let user_id = Refs.user_id customer in
  track_user t ~user_id;
  let code_expires = Time_ns.add (now ()) (Time_ns.Span.of_min 10.) in
  match step with
  | Email ->
    let%map.Deferred.Or_error () = Sc.User.resend_email t.tr ~user_id in
    Customer.Verification_session.Code_sent { step; expires_at = code_expires }
  | Mobile ->
    let%map.Deferred.Or_error () = Sc.User.resend_sms t.tr ~user_id in
    Customer.Verification_session.Code_sent { step; expires_at = code_expires }
  | Identity_document | Liveness | Address_proof | Source_of_funds ->
    let tier = kyc_tier_for step in
    let%map.Deferred.Or_error k = Sc.User.start_kyc t.tr ~user_id ~tier () in
    (* The hosted link opens the whole flow; the SDK token is the fallback. *)
    let token = Option.value k.verification_link ~default:k.token in
    Customer.Verification_session.Hosted
      { step
      ; token = Sensitive.of_string token
      ; expires_at = Time_ns.add (now ()) (Time_ns.Span.of_min 20.)
      }
;;

let complete_verification t customer (step : Kyc_core.Verification.Step.t) ~code =
  let user_id = Refs.user_id customer in
  let code = Sensitive.reveal code in
  let verify =
    match step with
    | Email -> Some (Sc.User.verify_email t.tr ~user_id ~code)
    | Mobile -> Some (Sc.User.verify_mobile t.tr ~user_id ~code)
    | _ -> None
  in
  match verify with
  | None ->
    return
      (Or_error.error_s
         [%message
           "this step is decided in Striga's hosted flow, not by a code"
             (step : Kyc_core.Verification.Step.t)])
  | Some d ->
    (match%bind d with
     | Ok () ->
       let%map (_ : Customer.Kyc_status.t Or_error.t) = fetch_kyc t ~user_id in
       Ok (Kyc_core.Verification.State.Verified (now ()))
     | Error e ->
       (match Sc.Api_error.status_of_error e with
        | Some s when s >= 400 && s < 500 ->
          return (Ok (Kyc_core.Verification.State.Failed "wrong or expired code"))
        | _ -> return (Error e)))
;;

let kyc_status t customer =
  let user_id = Refs.user_id customer in
  track_user t ~user_id;
  fetch_kyc t ~user_id
;;

(* {2 Accounts} *)

let all_wallets t ~user_id =
  let%bind.Deferred.Or_error user = Sc.User.get t.tr ~user_id in
  let start = Time_ns.sub (user_created_at user) Time_ns.Span.hour in
  let stop = Time_ns.add (now ()) Time_ns.Span.minute in
  let rec page n acc =
    let%bind.Deferred.Or_error p =
      Sc.Wallet.get_all t.tr ~user_id ~start ~stop ~page:n ()
    in
    let acc = acc @ p.wallets in
    let total = Option.value p.total ~default:(List.length acc) in
    if List.is_empty p.wallets || List.length acc >= total || n >= 20
    then return (Ok acc)
    else page (n + 1) acc
  in
  page 1 []
;;

let striga_accounts t ~user_id =
  let%map.Deferred.Or_error wallets = all_wallets t ~user_id in
  List.concat_map wallets ~f:(fun w -> List.map w.accounts ~f:snd)
;;

let to_account t ~user_id (a : Sc.Wallet.Account.t) =
  let%map.Or_error acc = Account_map.account ~user_id a in
  track_account t acc.id;
  Option.iter (Account.iban acc) ~f:(fun data ->
    Hashtbl.set t.ibans ~key:a.account_id ~data);
  acc
;;

let accounts t customer =
  let user_id = Refs.user_id customer in
  let%map.Deferred.Or_error accounts = striga_accounts t ~user_id in
  (* Currencies Striga holds that money does not know are skipped, not fatal. *)
  List.filter_map accounts ~f:(fun a -> to_account t ~user_id a |> Result.ok)
;;

let get_account t account =
  match Refs.account_parts account with
  | Error _ as e -> return e
  | Ok (user_id, account_id) ->
    let%map.Deferred.Or_error a = wallet_account t ~user_id ~account_id in
    user_id, a
;;

let balance t account =
  track_account t account;
  let%bind.Deferred.Or_error _, a = get_account t account in
  return (Account_map.balance account a ~at:(now ()))
;;

let enrich_account t account =
  match Refs.account_parts account with
  | Error _ as e -> return e
  | Ok (user_id, account_id) ->
    let%bind.Deferred.Or_error e = Sc.Wallet.enrich_account t.tr ~user_id ~account_id in
    let%bind.Deferred.Or_error a = wallet_account t ~user_id ~account_id in
    return
      (let%map.Or_error acc = to_account t ~user_id a in
       let extra =
         List.filter (Account_map.addresses e) ~f:(fun x ->
           not (List.mem acc.addresses x ~equal:Account.Address.equal))
       in
       let acc = { acc with addresses = acc.addresses @ extra } in
       Option.iter (Account.iban acc) ~f:(fun data ->
         Hashtbl.set t.ibans ~key:account_id ~data);
       acc)
;;

(* Striga's EUR account is the Payment Account; its terms are accepted once per user. *)
let record_payment_account_consent t ~user_id =
  match t.config.payment_account_consent with
  | `By_application -> return (Ok ())
  | `Record terms_version ->
    let%bind.Deferred.Or_error current = Sc.User.payment_account_consent t.tr ~user_id in
    (match current.payment_account_consent with
     | Some { Sc.User.Payment_account_consent.accepted = true; _ } -> return (Ok ())
     | Some { accepted = false; _ } | None ->
       Sc.User.set_payment_account_consent
         t.tr
         ~user_id
         ~accepted:true
         ?terms_version
         ~ip:t.config.end_user_ip
         ()
       |> Deferred.Or_error.ignore_m)
    |> Deferred.Or_error.tag ~tag:"recording the Payment Account consent"
;;

let session_gated code = String.equal code "EUR" || String.equal code "USDC"

let open_account t customer currency =
  let user_id = Refs.user_id customer in
  match Units.striga_of_currency currency with
  | Error _ as e -> return e
  | Ok code ->
    (* Striga opens one account per enabled currency itself on KYC approval; opening is
       finding it. EUR and USDC are listed only for a user with an SCA session. *)
    let find () =
      let%map.Deferred.Or_error accounts = striga_accounts t ~user_id in
      List.find accounts ~f:(fun (a : Sc.Wallet.Account.t) ->
        Option.equal String.equal a.currency (Some code))
    in
    let%bind.Deferred.Or_error () =
      if String.equal code "EUR"
      then record_payment_account_consent t ~user_id
      else return (Ok ())
    in
    let%bind.Deferred.Or_error listed = find () in
    let%bind.Deferred.Or_error a =
      match listed with
      | Some a -> return (Ok a)
      | None ->
        let%bind.Deferred.Or_error () =
          if session_gated code then open_session t ~user_id else return (Ok ())
        in
        poll_until ~timeout:t.config.account_retry ~every:(Time_ns.Span.of_sec 2.) find
        |> Deferred.Or_error.tag_s
             ~tag:[%message "Striga lists no account in this currency" code user_id]
    in
    let%bind.Deferred.Or_error acc = return (to_account t ~user_id a) in
    if String.equal code "EUR" then enrich_account t acc.id else return (Ok acc)
;;

let statement t account ~from ~until =
  match Refs.account_parts account with
  | Error _ as e -> return e
  | Ok (user_id, account_id) ->
    let%bind.Deferred.Or_error a = wallet_account t ~user_id ~account_id in
    let%bind.Deferred.Or_error txs =
      read_statement t ~user_id ~account_id ~start:from ~stop:until
    in
    return
      (let open Or_error.Let_syntax in
       let%bind code =
         Or_error.of_option
           a.currency
           ~error:(Error.of_string "account without a currency")
       in
       let%bind currency = Units.currency_of_striga code in
       let money_of (b : Sc.Common.Balance.t option) =
         match b with
         | Some { amount = Some amount; currency = u; _ } ->
           Units.amount_of_striga ?unit:u ~currency:code amount |> Result.ok
         | _ -> None
       in
       let txs =
         List.rev txs
         |> List.filter ~f:(fun (tx : Sc.Transaction.t) ->
           let at = Tx_map.at tx ~default:from in
           Time_ns.( >= ) at from && Time_ns.( < ) at until)
       in
       let%bind lines =
         List.map txs ~f:(fun (tx : Sc.Transaction.t) ->
           let%bind amount = Tx_map.amount tx in
           let amount = Option.value amount ~default:(Money.Amount.zero currency) in
           let signed =
             match Tx_map.direction tx with
             | Some `Out -> Money.Amount.neg amount
             | _ -> amount
           in
           let balance =
             match money_of tx.balance_after with
             | Some b -> b
             | None -> Money.Amount.zero currency
           in
           return
             { Statement.Line.at = Tx_map.at tx ~default:from
             ; amount = signed
             ; code =
                 Option.value_map
                   tx.tx_type
                   ~default:"UNKNOWN"
                   ~f:Sc.Transaction.Tx_type.to_string
             ; reference = Option.value tx.id ~default:""
             ; balance
             })
         |> Or_error.combine_errors
       in
       let current =
         Option.value (money_of a.available_balance) ~default:(Money.Amount.zero currency)
       in
       let opening =
         match txs with
         | first :: _ ->
           Option.value
             (money_of first.balance_before)
             ~default:(Money.Amount.zero currency)
         | [] -> current
       in
       let closing =
         match List.last lines with
         | Some l -> l.balance
         | None -> opening
       in
       return { Statement.account; currency; from; until; opening; lines; closing })
;;

(* {2 SCA challenges} *)

let factors_of (m : Sc.Common.Verification_method.t option) : Sca.Kind.t list =
  match m with
  | Some Totp -> [ Totp ]
  | Some Passkey -> [ Passkey ]
  | Some Sms | Some (Other _) | None -> [ Otp ]
;;

(* Striga allows five attempts per challenge and does not report how many are left. *)
let striga_attempts = 5

let new_challenge t ~user_id ~purpose ~striga_challenge ~meth ~expires =
  let challenge =
    { Sca_challenge.id = Sca.Id.of_string ("striga:" ^ striga_challenge)
    ; purpose
    ; factors = factors_of meth
    ; expires_at =
        Option.bind expires ~f:Striga_time.parse
        |> Option.value ~default:(Time_ns.add (now ()) (Time_ns.Span.of_min 5.))
    ; attempts_left = striga_attempts
    }
  in
  let record =
    { Challenge_record.challenge
    ; user_id
    ; striga_challenge
    ; striga_method = Option.map meth ~f:Sc.Common.Verification_method.to_string
    ; settled = false
    }
  in
  let%map () = t.store.set_challenge record in
  challenge
;;

(* {2 Transfers} *)

let info_of (r : Transfer_record.t) =
  { Transfer_info.transfer = r.id
  ; provider_ref =
      Option.first_some r.provider_ref r.challenge |> Option.value ~default:""
  ; status = r.status
  ; fee = r.fee
  ; details = r.details
  ; updated_at = r.updated_at
  }
;;

let quote_fee _t ~from:_ ~(rail : Rail.t) amount =
  let zero = Money.Amount.zero (Money.Amount.currency amount) in
  match rail with
  | Sepa_credit | Sepa_instant | Intraledger ->
    (* Striga reports a payout's fee only in the initiation's [feeEstimate]; the sandbox
       application charges none for SEPA or between users. *)
    return (Ok { Transfer_info.Fee_quote.rail; amount; fee = zero; total = amount })
  | Onchain _ | Lightning ->
    return
      (Or_error.error_s
         [%message
           "Striga estimates network fees only for a whitelisted destination; initiate \
            the transfer to see the fee"
             (rail : Rail.t)])
  | Card_scheme -> return (Or_error.error_string "not a transfer rail")
  | Faster_payments | Chaps | Bacs | Ach _ | Rtp | Fedwire ->
    return
      (Or_error.error_s
         [%message "Striga does not pay on UK or US rails" (rail : Rail.t)])
;;

let network_code (n : Network.t) =
  match n with
  | Bitcoin | Bitcoin_testnet -> Ok "BTC"
  | Ethereum -> Ok "ETH"
  | Polygon -> Ok "POLYGON"
  | Solana -> Ok "SOL"
  | Tron -> Or_error.error_string "Striga does not withdraw to Tron"
  | (Base | Arbitrum | Plasma | Spark) as n ->
    Or_error.error_s [%message "Striga does not withdraw to this network" (n : Network.t)]
;;

(* The account of this application that holds [iban], if the adapter has seen it. *)
let own_account_of_iban t iban =
  Hashtbl.to_alist t.ibans
  |> List.find_map ~f:(fun (account, i) -> Option.some_if (Iban.equal i iban) account)
;;

(* The rail the money actually moves on: a SEPA payout to one of this application's own
   IBANs goes intraledger (see [initiate_striga]). *)
let effective_rail t (draft : Transfer.t) =
  match draft.counterparty, draft.rail with
  | Beneficiary { destination = Bank_account { iban; _ }; _ }, (Sepa_credit | Sepa_instant)
    when Option.is_some (own_account_of_iban t iban) -> Rail.Intraledger
  | _ -> draft.rail
;;

let initiate_striga t ~user_id ~account_id (draft : Transfer.t) ~amount =
  let module B = Beneficiary in
  match draft.counterparty, draft.rail with
  | Beneficiary b, (Sepa_credit | Sepa_instant) ->
    (match b.destination with
     | Bank_account { iban; bic } ->
       let memo =
         Option.some_if (not (String.is_empty draft.reference)) draft.reference
       in
       let own = own_account_of_iban t iban in
       (match own with
        | Some destination_account_id ->
          (* Striga refuses SEPA to an IBAN of its own application (31003 "use the
             inter/intra methods"); move the money on its ledger instead. *)
          Sc.Payment.intraledger
            t.tr
            ~user_id
            ~source_account_id:account_id
            ~destination_account_id
            ~amount
            ?memo
            ()
        | None ->
          let bic =
            match bic, draft.details with
            | Some bic, _ -> Some bic
            | None, Sepa { creditor = { bic = Some bic; _ }; _ } -> Some bic
            | None, _ -> t.config.bic_for iban
          in
          (match bic with
           | None ->
             (* Without one Striga answers 400 00002 "Invalid BIC". *)
             return
               (Or_error.error_string
                  "Striga needs the payee's BIC for a SEPA payout: put it on the \
                   beneficiary or answer it from Config.bic_for")
           | Some bic ->
             Sc.Payment.sepa
               t.tr
               ~user_id
               ~source_account_id:account_id
               ~amount
               ~iban:(Iban.to_string iban)
               ~bic:(Bic.to_string bic)
               ?memo
               ()))
     | _ -> return (Or_error.error_string "SEPA needs a bank account beneficiary"))
  | Beneficiary b, Intraledger ->
    (match b.destination with
     | Internal { account } ->
       (match Refs.account_parts (Account_ref.of_string account) with
        | Error _ as e -> return e
        | Ok (_, destination_account_id) ->
          Sc.Payment.intraledger
            t.tr
            ~user_id
            ~source_account_id:account_id
            ~destination_account_id
            ~amount
            ?memo:(Option.some_if (not (String.is_empty draft.reference)) draft.reference)
            ())
     | _ -> return (Or_error.error_string "intraledger needs an internal beneficiary"))
  | Beneficiary b, Onchain network ->
    (match b.destination, network_code network with
     | _, (Error _ as e) -> return e
     | Crypto { address; memo = _ }, Ok net ->
       let%bind.Deferred.Or_error a = wallet_account t ~user_id ~account_id in
       let currency = Option.value a.currency ~default:"" in
       let%bind.Deferred.Or_error w =
         Sc.Payment.whitelist_address
           t.tr
           ~user_id
           ~address:(Crypto_address.address address)
           ~currency
           ~network:net
           ~label:(String.prefix (Transfer.Id.to_string draft.id) 30)
           ()
       in
       Sc.Payment.onchain_withdrawal
         t.tr
         ~user_id
         ~source_account_id:account_id
         ~whitelisted_address_id:w.id
         ~amount
         ()
     | _ -> return (Or_error.error_string "on-chain needs a crypto address beneficiary"))
  | Beneficiary b, Lightning ->
    (match b.destination with
     | Lightning (Invoice inv) ->
       Sc.Payment.lightning_withdrawal
         t.tr
         ~user_id
         ~source_account_id:account_id
         ~invoice:inv.raw
         ()
     | _ ->
       return
         (Or_error.error_string
            "Striga pays BOLT 11 invoices only; resolve LNURL and addresses first"))
  | _, Card_scheme -> return (Or_error.error_string "not a transfer rail")
  | _, ((Faster_payments | Chaps | Bacs | Ach _ | Rtp | Fedwire) as rail) ->
    return
      (Or_error.error_s
         [%message "Striga does not pay on UK or US rails" (rail : Rail.t)])
  | External _, _ ->
    return (Or_error.error_string "an outgoing transfer needs a beneficiary")
;;

let initiate_transfer t ~from (draft : Transfer.t) =
  match%bind t.store.find_transfer draft.id with
  | Some r ->
    (* A resend: never a second payment. While the first is still waiting for its code,
       the same challenge is handed back. *)
    (match r.status, r.challenge with
     | Awaiting_sca, Some c ->
       (match%map t.store.find_challenge (Sca.Id.of_string ("striga:" ^ c)) with
        | Some cr when not cr.settled ->
          Ok (Sca_challenge.Or_challenge.Challenge cr.challenge)
        | _ -> Ok (Sca_challenge.Or_challenge.Done (info_of r)))
     | _ -> return (Ok (Sca_challenge.Or_challenge.Done (info_of r))))
  | None ->
    (match Refs.account_parts from, Units.amount_to_striga draft.amount with
     | (Error _ as e), _ | _, (Error _ as e) ->
       return (Or_error.map e ~f:(fun _ -> assert false))
     | Ok (user_id, account_id), Ok amount ->
       track_account t from;
       let%bind.Deferred.Or_error (i : Sc.Payment.Initiated.t) =
         initiate_striga t ~user_id ~account_id draft ~amount
       in
       let fee =
         match
           Option.bind i.fee_estimate ~f:(fun f -> f.total_fee)
           |> Option.map ~f:(fun digits ->
             Units.amount_of_striga
               ~currency:(Money.Currency.code (Money.Amount.currency draft.amount))
               digits)
         with
         | Some (Ok f)
           when Money.Currency.equal
                  (Money.Amount.currency f)
                  (Money.Amount.currency draft.amount) -> f
         | _ -> Money.Amount.zero (Money.Amount.currency draft.amount)
       in
       let record =
         { Transfer_record.id = draft.id
         ; account = from
         ; (* The rail used, so the sandbox's SEPA settlement is not asked for a payout
              that went intraledger (500 "No banking tx id found"). *)
           rail = effective_rail t draft
         ; amount = draft.amount
         ; fee
         ; details = draft.details
         ; challenge = Some i.challenge_id
         ; provider_ref = Option.bind i.transaction ~f:(fun tx -> tx.id)
         ; status = Awaiting_sca
         ; updated_at = now ()
         }
       in
       let%bind () = t.store.set_transfer record in
       let%map challenge =
         new_challenge
           t
           ~user_id
           ~purpose:(Transfer draft.id)
           ~striga_challenge:i.challenge_id
           ~meth:i.verification_method
           ~expires:i.date_expires
       in
       Ok (Sca_challenge.Or_challenge.Challenge challenge))
;;

let refresh_transfer t (r : Transfer_record.t) =
  match r.provider_ref, Refs.account_parts r.account with
  | Some tx_id, Ok (user_id, account_id) when not (Transfer.Status.is_final r.status) ->
    (match%bind Sc.Wallet.transactions_by_id t.tr ~user_id ~account_id ~tx_id with
     | Error _ ->
       (* The statement has the same entries; transactions_by_id is only a shortcut. *)
       let%bind (_ : Sc.Transaction.t list Or_error.t) = scan_account t r.account in
       return ()
     | Ok page ->
       Deferred.List.iter
         ~how:`Sequential
         (List.rev page.transactions)
         ~f:(observe_tx t ~user_id ~account_id))
  | _ -> return ()
;;

let transfer t id =
  match%bind t.store.find_transfer id with
  | None -> return (Or_error.error_s [%message "unknown transfer" (id : Transfer.Id.t)])
  | Some r ->
    let%bind () = refresh_transfer t r in
    (match%map t.store.find_transfer id with
     | Some r -> Ok (info_of r)
     | None -> Ok (info_of r))
;;

let cancel_transfer t id =
  match%bind t.store.find_transfer id with
  | None -> return (Or_error.error_s [%message "unknown transfer" (id : Transfer.Id.t)])
  | Some ({ status = Awaiting_sca | Draft; _ } as r) ->
    (* Nothing has moved: the initiation lapses unconfirmed at Striga. *)
    let r = { r with status = Cancelled; updated_at = now () } in
    let%bind () = t.store.set_transfer r in
    let%bind () =
      match r.challenge with
      | None -> return ()
      | Some c ->
        (match%bind t.store.find_challenge (Sca.Id.of_string ("striga:" ^ c)) with
         | Some cr -> t.store.set_challenge { cr with settled = true }
         | None -> return ())
    in
    transfer_event
      t
      r
      ~id:("cancel:" ^ Transfer.Id.to_string id)
      ~provider_ref:""
      Cancelled;
    return (Ok (info_of r))
  | Some r ->
    return
      (Or_error.error_s
         [%message
           "Striga cannot cancel a confirmed payment" (r.status : Transfer.Status.t)])
;;

(* {2 Confirmation} *)

let sandbox_settle t (r : Transfer_record.t) =
  match
    t.config.sandbox_settlement, r.rail, r.provider_ref, Refs.account_parts r.account
  with
  | `Immediate, (Sepa_credit | Sepa_instant), Some transaction_id, Ok (_, account_id)
    when is_sandbox t ->
    (match%map
       Sc.Simulator.sepa_outcome t.tr ~transaction_id ~account_id ~completed:true
     with
     | Ok () -> ()
     | Error e -> note_error t (Error.tag e ~tag:"sandbox settlement"))
  | _ -> return ()
;;

let wrong_code_codes = [ "41009"; "41010" ]

(* A code that is not six digits fails Striga's field validation instead: 400 00002
   "Invalid fields --> Invalid verificationCode". It is a wrong code all the same. *)
let is_wrong_code e =
  match striga_error_code e with
  | Some c when List.mem wrong_code_codes c ~equal:String.equal -> true
  | Some "00002" ->
    String.is_substring (Error.to_string_hum e) ~substring:"verificationCode"
  | _ -> false
;;

let insufficient_codes = [ "61004"; "31090" ]

let order_amount json side =
  match json with
  | `Assoc fields ->
    (match List.Assoc.find fields side ~equal:String.equal with
     | Some (`Assoc leg) ->
       (match
          ( List.Assoc.find leg "currency" ~equal:String.equal
          , List.Assoc.find leg "amount" ~equal:String.equal )
        with
        | Some (`String c), Some (`String a) ->
          Units.amount_of_striga ~currency:c a |> Result.ok
        | _ -> None)
     | _ -> None)
  | _ -> None
;;

let confirm_transfer t (cr : Challenge_record.t) transfer_id ~code =
  match%bind t.store.find_transfer transfer_id with
  | None ->
    return (Or_error.error_s [%message "unknown transfer" (transfer_id : Transfer.Id.t)])
  | Some r ->
    (match%bind
       Sc.Payment.confirm
         t.tr
         ~user_id:cr.user_id
         ~challenge_id:cr.striga_challenge
         ~code
         ~ip:t.config.end_user_ip
         ()
     with
     | Ok tx ->
       (* The confirmation answers with the first ledger entry: SEPA_PAYOUT_INITIATED
          (submitted) or, between Striga users, the final INTRA_LEDGER_SEND (settled).
          Publishing under that entry's id keeps a later poll or webhook from repeating
          it. Without a usable entry the event gets an id of its own, so the entry's
          update is still published when it is seen. *)
       let update, id =
         match Tx_map.outgoing_update tx, Tx_map.event_id tx with
         | Some u, Some id -> u, Event_id.to_string id
         | _ -> Transfer_update.Submitted, "submitted:" ^ Transfer.Id.to_string r.id
       in
       let r =
         { r with
           provider_ref = Option.first_some tx.id r.provider_ref
         ; status = Option.value (status_of_update update) ~default:Submitted
         ; updated_at = now ()
         }
       in
       let%bind () = t.store.set_transfer r in
       transfer_event
         t
         r
         ~id
         ~provider_ref:(Option.value r.provider_ref ~default:"")
         update;
       let%map () = sandbox_settle t r in
       Ok `Accepted
     | Error e ->
       (match striga_error_code e with
        | _ when is_wrong_code e -> return (Ok `Wrong_code)
        | Some c when List.mem insufficient_codes c ~equal:String.equal ->
          let r = { r with status = Failed Insufficient_funds; updated_at = now () } in
          let%map () = t.store.set_transfer r in
          transfer_event
            t
            r
            ~id:("failed:" ^ Transfer.Id.to_string r.id)
            ~provider_ref:(Option.value r.provider_ref ~default:"")
            (Failed Insufficient_funds);
          Ok `Accepted
        | _ -> return (Error e)))
;;

let confirm_swap t (cr : Challenge_record.t) swap_id ~code =
  match%bind t.store.find_swap swap_id with
  | None -> return (Or_error.error_s [%message "unknown swap" (swap_id : Swap.Id.t)])
  | Some s ->
    (match%bind
       Sc.Payment.confirm
         t.tr
         ~user_id:cr.user_id
         ~challenge_id:cr.striga_challenge
         ~code
         ~ip:t.config.end_user_ip
         ()
     with
     | Ok tx ->
       let%bind () = t.store.set_swap { s with executed = true } in
       let sell =
         Option.bind tx.order ~f:(fun o -> order_amount o "debit")
         |> Option.value ~default:s.sell
       in
       let buy =
         Option.bind tx.order ~f:(fun o -> order_amount o "credit")
         |> Option.value ~default:s.buy
       in
       let id =
         Option.value_map
           (Tx_map.event_id tx)
           ~default:("swap:" ^ Swap.Id.to_string swap_id)
           ~f:Event_id.to_string
       in
       publish
         t
         (event
            ~id
            ~at:(Tx_map.at tx ~default:(now ()))
            (Swap_executed { swap = swap_id; sell; fee = s.fee; buy }));
       return (Ok `Accepted)
     | Error e ->
       (match striga_error_code e with
        | _ when is_wrong_code e -> return (Ok `Wrong_code)
        | _ ->
          let%map () = t.store.set_swap { s with executed = true } in
          publish
            t
            (event
               ~id:("swap-failed:" ^ Swap.Id.to_string swap_id)
               ~at:(now ())
               (Swap_failed { swap = swap_id; reason = Error.to_string_hum e }));
          Ok `Accepted))
;;

let confirm_card_details t (cr : Challenge_record.t) card ~code =
  match%bind
    Sc.Card.confirm_consent
      t.tr
      ~user_id:cr.user_id
      ~challenge_id:cr.striga_challenge
      ~code
  with
  | Ok consent ->
    (match
       Pan_display_token.of_provider
         ~token:consent.card_auth_token
         ~expires_at:(Time_ns.add (now ()) (Time_ns.Span.of_hr 24.))
     with
     | Ok token ->
       let%map () = t.store.set_card_token card token in
       Ok `Accepted
     | Error _ as e -> return (Or_error.map e ~f:(fun _ -> `Accepted)))
  | Error e ->
    return
      (match striga_error_code e with
       | _ when is_wrong_code e -> Ok `Wrong_code
       | _ -> Error e)
;;

let confirm_sca t id ~code =
  match%bind t.store.find_challenge id with
  | None -> return (Or_error.error_s [%message "unknown challenge" (id : Sca.Id.t)])
  | Some cr when cr.settled -> return (Ok (Sca_challenge.Result.Failed Cancelled))
  | Some cr when Time_ns.( > ) (now ()) cr.challenge.expires_at ->
    let%map () = t.store.set_challenge { cr with settled = true } in
    Ok (Sca_challenge.Result.Failed Expired)
  | Some cr ->
    let code = Sensitive.reveal code in
    let%bind.Deferred.Or_error outcome =
      match cr.challenge.purpose with
      | Transfer id -> confirm_transfer t cr id ~code
      | Swap id -> confirm_swap t cr id ~code
      | Card_details card -> confirm_card_details t cr card ~code
      | Standing_order _ ->
        return (Or_error.error_string "Striga standing orders are not supported")
    in
    (match outcome with
     | `Accepted ->
       let%map () = t.store.set_challenge { cr with settled = true } in
       Ok Sca_challenge.Result.Accepted
     | `Wrong_code ->
       let attempts_left = cr.challenge.attempts_left - 1 in
       if attempts_left <= 0
       then (
         let%map () =
           t.store.set_challenge
             { cr with
               settled = true
             ; challenge = { cr.challenge with attempts_left = 0 }
             }
         in
         Ok (Sca_challenge.Result.Failed Too_many_attempts))
       else (
         let%map () =
           t.store.set_challenge
             { cr with challenge = { cr.challenge with attempts_left } }
         in
         Ok (Sca_challenge.Result.Wrong_code { attempts_left })))
;;

(* {2 Swaps} *)

let quote_swap t ~from ~to_ ~sell =
  match Refs.account_parts from, Refs.account_parts to_ with
  | (Error _ as e), _ | _, (Error _ as e) ->
    return (Or_error.map e ~f:(fun _ -> assert false))
  | Ok (user_a, _), Ok (user_b, _) when not (String.equal user_a user_b) ->
    return (Or_error.error_string "a swap moves between two accounts of one customer")
  | Ok _, Ok (user_id, to_account_id) ->
    let%bind.Deferred.Or_error dest =
      wallet_account t ~user_id ~account_id:to_account_id
    in
    let%bind.Deferred.Or_error rates = Sc.Exchange.rates t.tr in
    return
      (let open Or_error.Let_syntax in
       let%bind buy_code =
         Or_error.of_option
           dest.currency
           ~error:(Error.of_string "account without a currency")
       in
       let%bind buy = Units.currency_of_striga buy_code in
       let%bind sell_code = Units.striga_of_currency (Money.Amount.currency sell) in
       let find base quote =
         Option.bind
           (Sc.Exchange.Rates.find rates ~ticker:(base ^ quote))
           ~f:(fun r -> r.price)
         |> Option.map ~f:(fun p -> base, quote, p)
       in
       let%bind base, quote, price =
         Or_error.of_option
           (Option.first_some (find buy_code sell_code) (find sell_code buy_code))
           ~error:
             (Error.create_s
                [%message "Striga quotes no rate for the pair" sell_code buy_code])
       in
       let%bind price = Money.Rate.price_of_string price in
       let%bind market =
         Money.Rate.create
           ~base:(Units.currency_of_striga base |> ok_exn)
           ~quote:(Units.currency_of_striga quote |> ok_exn)
           ~price
           ~at:(now ())
           ~source:"striga"
       in
       let id = Swap.Id.of_string ("swp-" ^ Sc.Transport.uuid_v4 ()) in
       let%map quote = Swap.Quote.create ~id ~market ~sell ~buy ~now:(now ()) () in
       quote)
    |> Deferred.Or_error.bind ~f:(fun (q : Swap.Quote.t) ->
      let%map () =
        t.store.set_swap
          { Swap_record.id = q.id
          ; from
          ; to_
          ; sell = q.sell
          ; fee = q.fee
          ; buy = q.buy
          ; expires_at = q.expires_at
          ; executed = false
          }
      in
      Ok q)
;;

let execute_swap t id =
  match%bind t.store.find_swap id with
  | None -> return (Or_error.error_s [%message "unknown swap" (id : Swap.Id.t)])
  | Some s when s.executed -> return (Ok (Sca_challenge.Or_challenge.Done ()))
  | Some s when Time_ns.( > ) (now ()) s.expires_at ->
    return (Or_error.error_s [%message "the quote expired" (id : Swap.Id.t)])
  | Some s ->
    (match
       Refs.account_parts s.from, Refs.account_parts s.to_, Units.amount_to_striga s.sell
     with
     | Ok (user_id, source_account_id), Ok (_, destination_account_id), Ok amount ->
       let%bind.Deferred.Or_error i =
         Sc.Exchange.swap
           t.tr
           ~user_id
           ~source_account_id
           ~destination_account_id
           ~amount
           ~ip:t.config.end_user_ip
           ()
       in
       let%map challenge =
         new_challenge
           t
           ~user_id
           ~purpose:(Swap id)
           ~striga_challenge:i.challenge_id
           ~meth:i.verification_method
           ~expires:i.date_expires
       in
       Ok (Sca_challenge.Or_challenge.Challenge challenge)
     | (Error _ as e), _, _ | _, (Error _ as e), _ | _, _, (Error _ as e) ->
       return (Or_error.map e ~f:(fun _ -> assert false)))
;;

(* {2 Cards} *)

let card t card_id =
  let%map.Deferred.Or_error c =
    Sc.Card.get t.tr ~card_id:(Ids.Card_id.to_string card_id)
  in
  Option.iter c.user_id ~f:(fun u -> Hashtbl.set t.cards_seen ~key:c.id ~data:u);
  c
;;

let card_info_of t (c : Sc.Card.t) =
  Option.iter c.user_id ~f:(fun u -> Hashtbl.set t.cards_seen ~key:c.id ~data:u);
  Card_map.card_info c
;;

let issue_virtual_card t ~request_id customer ~account =
  let get id =
    let%bind.Deferred.Or_error c = card t id in
    return (card_info_of t c)
  in
  match%bind t.store.find_card_request request_id with
  | Some id -> get id
  | None ->
    (match Refs.account_parts account with
     | Error _ as e -> return (Or_error.map e ~f:(fun _ -> assert false))
     | Ok (_, account_id) ->
       let user_id = Refs.user_id customer in
       let%bind.Deferred.Or_error user = Sc.User.get t.tr ~user_id in
       let name_on_card =
         (* Card names are embossed in at most 26 characters. *)
         String.prefix
           (String.concat ~sep:" " (List.filter_opt [ user.first_name; user.last_name ]))
           26
       in
       let password = t.config.card_3ds_password () in
       let%bind.Deferred.Or_error () =
         if Config.valid_3ds_password password
         then return (Ok ())
         else
           return
             (Or_error.error_string
                "the configured 3-D Secure password does not meet Striga's rule (8-36 \
                 characters from A-Z a-z 0-9 and !\"#;:?&*()+=/\\,.[]{}, with upper, \
                 lower, digit and symbol)")
       in
       let%bind.Deferred.Or_error c =
         Sc.Card.create
           t.tr
           ~user_id
           ~name_on_card
           ~three_d_secure_password:password
           ~type_:Virtual
           ~account_id_to_link:account_id
           ()
       in
       let%bind () = t.store.set_card_request request_id (Ids.Card_id.of_string c.id) in
       (* The create response omits fields the card has (user id, limits); read it back. *)
       get (Ids.Card_id.of_string c.id))
;;

let card_ t id =
  let%bind.Deferred.Or_error c = card t id in
  return (card_info_of t c)
;;

let cards t customer =
  let user_id = Refs.user_id customer in
  let%map.Deferred.Or_error page = Sc.Card.get_all t.tr ~user_id ~limit:100 () in
  List.filter_map page.cards ~f:(fun c ->
    card_info_of t { c with user_id = Some (Option.value c.user_id ~default:user_id) }
    |> Result.ok)
;;

let set_card_status t id (status : Card.Status.t) =
  let%bind.Deferred.Or_error current = card_ t id in
  let card_id = Ids.Card_id.to_string id in
  if Card.Status.equal current.status status
  then return (Ok current)
  else if not (Card.Status.can_transition ~from:current.status ~to_:status)
  then
    return
      (Or_error.error_s
         [%message
           "card status change not allowed"
             ~from:(current.status : Card.Status.t)
             ~to_:(status : Card.Status.t)])
  else (
    let%bind.Deferred.Or_error () =
      match status with
      | Frozen -> Sc.Card.block t.tr ~card_id
      | Active -> Sc.Card.unblock t.tr ~card_id
      | Destroyed -> Sc.Card.burn t.tr ~card_id |> Deferred.Or_error.ignore_m
      | Blocked | Requested | Expired ->
        return
          (Or_error.error_s
             [%message "Striga cannot set this card status" (status : Card.Status.t)])
    in
    let%map.Deferred.Or_error info = card_ t id in
    publish
      t
      (event
         ~id:
           (sprintf
              "card:%s:status:%s"
              card_id
              (Sexp.to_string [%sexp (info.status : Card.Status.t)]))
         ~at:(now ())
         (Card { card = id; update = Status_changed info.status }));
    info)
;;

let set_card_limits t id limits =
  let card_id = Ids.Card_id.to_string id in
  match Card_map.limits_to_striga limits with
  | Error _ as e -> return (Or_error.map e ~f:(fun _ -> assert false))
  | Ok (caps, `Contactless contactless, `Withdrawal withdrawal, `Online internet_purchase)
    ->
    let%bind.Deferred.Or_error () =
      if List.is_empty caps
      then return (Ok ())
      else Sc.Card.update_limits t.tr ~card_id ~limits:caps |> Deferred.Or_error.ignore_m
    in
    let%bind.Deferred.Or_error (_ : Sc.Card.t) =
      Sc.Card.update_security t.tr ~card_id ~contactless ~withdrawal ~internet_purchase
    in
    card_ t id
;;

let card_details_token t id =
  match%bind t.store.find_card_token id with
  | Some token when not (Pan_display_token.is_expired token ~now:(now ())) ->
    return (Ok (Sca_challenge.Or_challenge.Done token))
  | _ ->
    return
      (Or_error.error_string
         "Striga starts card consent in the browser: call requestConsent in Striga's UI \
          component, pass its challenge id to card_consent_started, then confirm_sca")
;;

let card_consent_started t id ~challenge_id =
  let%bind.Deferred.Or_error c = card t id in
  match c.user_id with
  | None -> return (Or_error.error_string "card without a user id")
  | Some user_id ->
    let%map challenge =
      new_challenge
        t
        ~user_id
        ~purpose:(Card_details id)
        ~striga_challenge:challenge_id
        ~meth:(Some Sms)
        ~expires:None
    in
    Ok challenge
;;

let card = card_

(* {2 Standing orders} *)

let create_standing_order _t ~from:_ (_ : Standing_order.t) =
  return
    (Or_error.error_string
       "Striga standing orders convert each deposit (and may pay it out); they are not \
        date-scheduled payments, so schedule those in the application")
;;

let cancel_standing_order _t (_ : Standing_order_ref.t) =
  return (Or_error.error_string "Striga standing orders are not supported")
;;

(* {2 Webhooks} *)

let has_field field (json : Yojson.Safe.t) =
  match json with
  | `Assoc fields -> List.Assoc.mem fields field ~equal:String.equal
  | _ -> false
;;

(* Striga names the channel by the URL path ([/kyc], [/tx], [/card/watch], [/ping]), which
   [Webhook.Request.t] does not carry. The receiving server may pass it in
   [x-webhook-path]; otherwise the body's fields tell the channels apart. *)
let channel_path (request : Webhook.Request.t) =
  match Webhook.Request.header request "x-webhook-path" with
  | Some p -> p
  | None ->
    (match Yojson.Safe.from_string request.body with
     | exception _ -> "/ping"
     | json ->
       if has_field "txType" json || has_field "merchantName" json
       then "/tx"
       else if has_field "currentTier" json
               || has_field "tier1" json
               || has_field "emailVerified" json
       then "/kyc"
       else if has_field "cardId" json && has_field "status" json
       then "/card/watch"
       else "/ping")
;;

let body_digest body = Md5.to_hex (Md5.digest_string body)

let events_of_webhook t (e : Sc.Webhook.Event.t) ~body =
  let captured = Queue.create () in
  t.captures <- captured :: t.captures;
  let finish () =
    t.captures <- List.filter t.captures ~f:(fun q -> not (phys_equal q captured));
    (* Ids already published are not published again, so a redelivery yields no events;
       the inbox would have dropped them anyway. *)
    Queue.to_list captured
  in
  let%map result =
    match e with
    | Kyc k ->
      (match k.user_id with
       | None -> return (Or_error.error_string "KYC webhook without a user id")
       | Some user_id ->
         ignore (observe_kyc t ~user_id k : Customer.Kyc_status.t);
         return (Ok ()))
    | Transaction tx ->
      (match tx.synced_owner_id, tx.account_id with
       | Some user_id, Some account_id ->
         let%map () = observe_tx t ~user_id ~account_id tx in
         Ok ()
       | _ -> return (Or_error.error_string "transaction webhook without user or account"))
    | Card_transaction c ->
      observe_card_tx t ~card_id:(Option.value c.card_id ~default:"") c;
      return (Ok ())
    | Card_status json ->
      let field f =
        match json with
        | `Assoc l ->
          (match List.Assoc.find l f ~equal:String.equal with
           | Some (`String s) -> Some s
           | _ -> None)
        | _ -> None
      in
      (match field "cardId", field "status" with
       | Some card, Some s ->
         let status = Card_map.status (Some (Sc.Card.Status.t_of_yojson (`String s))) in
         publish
           t
           (event
              ~id:
                (sprintf
                   "card:%s:status:%s"
                   card
                   (Sexp.to_string [%sexp (status : Card.Status.t)]))
              ~at:(now ())
              (Card { card = Ids.Card_id.of_string card; update = Status_changed status }));
         return (Ok ())
       | _ -> return (Or_error.error_string "card status webhook without card or status"))
    | Ping _ ->
      publish t (event ~id:("ping:" ^ body_digest body) ~at:(now ()) Ping);
      return (Ok ())
    | Other { path; _ } ->
      (* Notices on the known channels (ACCOUNT_ENRICHED and the other [type] bodies on
         /tx, for example) carry no event of their own. Refusing them made Striga
         redeliver each one; they are acknowledged, and an enrichment teaches the adapter
         the IBAN. *)
      (match Sc.Webhook.notice ~path ~body with
       | Ok
           (Some (Account_enriched { account_id = Some account_id; iban = Some iban; _ }))
         ->
         Option.iter
           (Iban.of_string iban |> Result.ok)
           ~f:(fun data -> Hashtbl.set t.ibans ~key:account_id ~data);
         return (Ok ())
       | Ok (Some _) -> return (Ok ())
       | Ok None ->
         if List.exists [ "/kyc"; "/kyb"; "/tx"; "/card/watch"; "/ping" ] ~f:(fun c ->
              String.is_suffix (String.chop_suffix_if_exists path ~suffix:"/") ~suffix:c)
         then return (Ok ())
         else return (Or_error.error_s [%message "unhandled webhook channel" path])
       | Error _ as e -> return e)
  in
  let events = finish () in
  Or_error.map result ~f:(fun () -> events)
;;

let ingest_webhook t (request : Webhook.Request.t) =
  let api_key = (Sc.Transport.config t.tr).api_key in
  match
    Sc.Webhook.verify_and_parse
      ~api_key
      ~path:(channel_path request)
      ~headers:request.headers
      ~body:request.body
  with
  | Error _ as e -> return e
  | Ok e -> events_of_webhook t e ~body:request.body
;;

(* {2 Sandbox} *)

let sandbox_only t f =
  if is_sandbox t
  then f ()
  else return (Or_error.error_string "only on the Striga sandbox")
;;

let deposit_counter = ref 0

let simulate_deposit t ~account ~(rail : Rail.t) amount =
  sandbox_only t (fun () ->
    match rail, Refs.account_parts account, Units.eur_cents amount with
    | (Sepa_credit | Sepa_instant), Ok (user_id, account_id), Ok cents ->
      track_account t account;
      incr deposit_counter;
      (* The reference comes back at the end of the entry's memo, which is how the deposit
         is found again: the simulator answers without a transaction id. *)
      let reference =
        sprintf
          "sim-%d-%d"
          !deposit_counter
          (Time_ns.to_int_ns_since_epoch (now ()) / 1_000_000)
      in
      let%bind.Deferred.Or_error () =
        Sc.Simulator.deposit
          t.tr
          ~account_id
          ~amount_cents:(Int.to_string cents)
          ~reference
          ~instant:(Rail.equal rail Sepa_instant)
          ()
      in
      let%bind.Deferred.Or_error tx =
        poll_until
          ~timeout:t.config.deposit_timeout
          ~every:(Time_ns.Span.of_sec 2.)
          (fun () ->
             let start, stop = statement_range t in
             let%map.Deferred.Or_error txs =
               read_statement t ~user_id ~account_id ~start ~stop
             in
             List.find txs ~f:(fun (tx : Sc.Transaction.t) ->
               Option.exists tx.memo ~f:(fun memo ->
                 (* The sandbox writes "SEPA_PAYIN_COMPLETED 100 EUR <reference>". *)
                 String.equal memo reference
                 || String.is_suffix memo ~suffix:(" " ^ reference))
               && Option.equal
                    Sc.Transaction.Tx_type.equal
                    tx.tx_type
                    (Some Sepa_payin_completed)))
        |> Deferred.Or_error.tag ~tag:"waiting for the simulated deposit"
      in
      let%bind () = observe_tx t ~user_id ~account_id tx in
      (match tx.id with
       | Some provider_ref -> return (Ok (Event.incoming_transfer_id ~provider_ref))
       | None -> return (Or_error.error_string "deposit without an id"))
    | (Sepa_credit | Sepa_instant), Error e, _ | (Sepa_credit | Sepa_instant), _, Error e
      -> return (Error e)
    | _ ->
      return
        (Or_error.error_s
           [%message "the Striga simulator only credits EUR by SEPA" (rail : Rail.t)]))
;;

let simulate_kyc_decision t customer (decision : Sandbox.Kyc_decision.t) =
  sandbox_only t (fun () ->
    let user_id = Refs.user_id customer in
    track_user t ~user_id;
    let code = t.config.sandbox_code in
    let%bind.Deferred.Or_error k = Sc.User.kyc_status t.tr ~user_id in
    (* Striga decides KYC only for a user with a verified e-mail and mobile and a started
       KYC; the sandbox accepts its fixed code for both. *)
    let%bind.Deferred.Or_error () =
      if Option.value k.email_verified ~default:false
      then return (Ok ())
      else Sc.User.verify_email t.tr ~user_id ~code
    in
    let%bind.Deferred.Or_error () =
      if Option.value k.mobile_verified ~default:false
      then return (Ok ())
      else Sc.User.verify_mobile t.tr ~user_id ~code
    in
    let%bind.Deferred.Or_error () =
      match k.status with
      | None | Some Not_started ->
        Sc.User.start_kyc t.tr ~user_id ~tier:1 () |> Deferred.Or_error.ignore_m
      | _ -> return (Ok ())
    in
    let decision, labels =
      match decision with
      | Approve -> Sc.Simulator.Decision.Approved, None
      | Reject _ -> Rejected_final, None
      | Request_resubmission fields ->
        ( Rejected
        , Some
            (List.map fields ~f:(fun (f : Kyc_core.Person.Field.t) ->
               match f with
               | Residential_address -> "BAD_PROOF_OF_ADDRESS"
               | Date_of_birth -> "WRONG_DATE_OF_BIRTH"
               | Given_name | Family_name -> "WRONG_NAME"
               | Nationality -> "WRONG_NATIONALITY"
               | Email | Mobile -> "DOCUMENT_PAGE_MISSING")) )
    in
    let%bind.Deferred.Or_error () =
      Sc.Simulator.kyc t.tr ~user_id ~decision ~tier:1 ?reject_labels:labels ()
    in
    let%map.Deferred.Or_error (_ : Customer.Kyc_status.t) = fetch_kyc t ~user_id in
    ())
;;

let simulate_card_auth t card_id (merchant : Card_core.Merchant.t) =
  sandbox_only t (fun () ->
    let card_id_s = Ids.Card_id.to_string card_id in
    match Units.eur_cents merchant.amount with
    | Error _ as e -> return (Or_error.map e ~f:(fun _ -> assert false))
    | Ok amount_eur_cents ->
      let%bind.Deferred.Or_error r =
        Sc.Simulator.card_authorization
          t.tr
          ~card_id:card_id_s
          ~amount_eur_cents
          ~mcc:(Card_core.Mcc.to_string merchant.mcc)
          ()
      in
      (match r.response with
       | Some "APPROVED" ->
         let%map (_ : Sc.Card.Card_transaction.t list Or_error.t) =
           card_statement t ~card_id:card_id_s
         in
         Ok Response_code.Approved
       | _ ->
         (* The simulator says only DECLINED; the reason is on the card statement. *)
         let%bind.Deferred.Or_error c = card t card_id in
         let%map statement = card_statement t ~card_id:card_id_s in
         let latest =
           Result.ok statement
           |> Option.value ~default:[]
           |> List.filter ~f:(fun (e : Sc.Card.Card_transaction.t) ->
             Option.equal
               Sc.Transaction.Tx_type.equal
               e.type_
               (Some Card_authorization_declined))
           |> List.max_elt ~compare:(fun (a : Sc.Card.Card_transaction.t) b ->
             Option.compare String.compare a.created_at b.created_at)
         in
         (match c.status, latest with
          | Frozen, _ -> Ok Response_code.Not_permitted
          | (Blocked | Destroyed | Expired | Requested), _ ->
            Ok
              (Option.value
                 (Card.Status.decline_code c.status)
                 ~default:Response_code.Do_not_honor)
          | Active, Some e -> Ok (Card_tx_map.response_of_decline e.decline_details)
          | Active, None -> Ok Response_code.Do_not_honor)))
;;

let simulate_transfer_outcome t id (update : Transfer_update.t) =
  sandbox_only t (fun () ->
    match%bind t.store.find_transfer id with
    | None -> return (Or_error.error_s [%message "unknown transfer" (id : Transfer.Id.t)])
    | Some r ->
      (match r.rail, r.provider_ref, Refs.account_parts r.account, update with
       | ( (Sepa_credit | Sepa_instant)
         , Some transaction_id
         , Ok (_, account_id)
         , (Settled | Rejected _ | Failed _ | Returned _) ) ->
         let completed =
           match update with
           | Settled -> true
           | _ -> false
         in
         let%bind.Deferred.Or_error () =
           Sc.Simulator.sepa_outcome t.tr ~transaction_id ~account_id ~completed
         in
         let%map () = refresh_transfer t r in
         Ok ()
       | _ ->
         return
           (Or_error.error_s
              [%message
                "the Striga simulator only settles or fails confirmed SEPA payouts"
                  (update : Transfer_update.t)])))
;;

(* Striga's API has no payee-name check, nor a simulator for one. *)
let verify_payee _t ~customer:_ (_ : Beneficiary.t) =
  return (Or_error.error_string "Striga offers no payee check (verification of payee)")
;;

let simulate_payee_check _t (_ : Beneficiary.Id.t) (_ : Beneficiary.Payee_check.t) =
  return (Or_error.error_string "Striga offers no payee check (verification of payee)")
;;

let ping t =
  sandbox_only t (fun () ->
    let stamp = Int.to_string (Time_ns.to_int_ns_since_epoch (now ())) in
    let%map.Deferred.Or_error () =
      Sc.Simulator.webhook_ping t.tr ~payload:(`Assoc [ "ping", `String stamp ])
    in
    (* Striga posts the test delivery to the dashboard's URL and answers 200 whether or
       not it arrived, so the adapter cannot see it land; it publishes the Ping itself. A
       service that receives the real delivery gets a second Ping through
       [ingest_webhook]. *)
    publish t (event ~id:("ping:local:" ^ stamp) ~at:(now ()) Ping))
;;

(* The provider's sandbox has no switch for automatic KYC outcomes or deposit timing;
   demos drive it with the simulate_* calls instead. *)
let set_kyc_simulation (_ : t) ?customer:_ (_ : Sandbox.Kyc_simulation.t) =
  Sandbox.unsupported ~operation:"set_kyc_simulation"
;;

let set_deposit_simulation (_ : t) ?customer:_ (_ : Sandbox.Deposit_simulation.t) =
  Sandbox.unsupported ~operation:"set_deposit_simulation"
;;
