open! Core
open Banking_provider
module Card = Card_core.Card
module Limits = Card_core.Limits
module S = Striga_client.Card

let status (s : S.Status.t option) : Card.Status.t =
  match s with
  | None | Some Created | Some Dispatched -> Requested
  | Some (Active | Activated) -> Active
  | Some Blocked -> Frozen
  | Some Closed -> Destroyed
  | Some Expired -> Expired
  | Some (Other _) -> Blocked
;;

let masked_pan (c : S.t) =
  let open Option.Let_syntax in
  let%bind masked = c.masked_card_number in
  let%bind last4 =
    if String.length masked >= 4
    then
      Card_core.Masked_pan.Last4.of_string_or_error (String.suffix masked 4) |> Result.ok
    else None
  in
  let%bind text = Option.first_some c.expiry_date c.expiry_data in
  let%bind time = Striga_time.parse text in
  (* Striga gives the last instant of validity (2028-10-31T23:59:59Z): its month is the
     printed expiry. *)
  let date = Time_ns.to_date time ~zone:Time_float.Zone.utc in
  let%map expiry =
    Card_core.Masked_pan.Expiry.create
      ~month:(Month.to_int (Date.month date))
      ~year:(Date.year date)
    |> Result.ok
  in
  { Card_core.Masked_pan.last4; expiry }
;;

let eur n = Money.Amount.of_minor_units_int Money.Currency.eur (n * 100)

let limits (c : S.t) =
  let find name =
    Option.bind c.limits ~f:(fun l -> S.Limits.find l name)
    |> Option.filter ~f:(fun n -> n > 0)
    |> Option.map ~f:eur
  in
  let toggle f =
    Option.value_map c.security ~default:true ~f:(fun s ->
      Option.value (f s) ~default:true)
  in
  Limits.create
    ?per_transaction:(find "transactionPurchase")
    ?daily:(find "dailyPurchase")
    ?monthly:(find "monthlyPurchase")
    ?atm_daily:(find "dailyWithdrawal")
    ~online:(toggle (fun (s : S.Security.t) -> s.internet_purchase_enabled))
    ~contactless:(toggle (fun (s : S.Security.t) -> s.contactless_enabled))
    ~atm:(toggle (fun (s : S.Security.t) -> s.withdrawal_enabled))
    Money.Currency.eur
;;

let whole_euros name amount =
  match Money.Amount.minor_units_int amount with
  | Some cents when cents % 100 = 0 -> Ok (name, cents / 100)
  | _ ->
    Or_error.error_s
      [%message "Striga card limits are whole euros" name (amount : Money.Amount.t)]
;;

let limits_to_striga (l : Limits.t) =
  let open Or_error.Let_syntax in
  let%bind () =
    if Money.Currency.equal l.currency Money.Currency.eur
    then return ()
    else
      Or_error.error_s
        [%message "Striga card limits are in EUR" (l.currency : Money.Currency.t)]
  in
  let%bind () =
    match l.atm_daily_count with
    | None -> return ()
    | Some _ -> Or_error.error_string "Striga has no ATM withdrawal count"
  in
  let%bind () =
    if Set.is_empty l.blocked_mccs && Set.is_empty l.blocked_countries
    then return ()
    else Or_error.error_string "Striga has no merchant category or country block lists"
  in
  let%map caps =
    [ "transactionPurchase", l.per_transaction
    ; "dailyPurchase", l.daily
    ; "monthlyPurchase", l.monthly
    ; "dailyWithdrawal", l.atm_daily
    ]
    |> List.filter_map ~f:(fun (name, cap) -> Option.map cap ~f:(whole_euros name))
    |> Or_error.combine_errors
  in
  caps, `Contactless l.contactless, `Withdrawal l.atm, `Online l.online
;;

let kind (t : S.Card_type.t option) : Card.Kind.t =
  match t with
  | Some (Physical | Physical_anonymous) -> Physical
  | _ -> Virtual
;;

let card_info (c : S.t) =
  let open Or_error.Let_syntax in
  let%bind user_id =
    Or_error.of_option c.user_id ~error:(Error.of_string "card without a user id")
  in
  let%bind account_id =
    match Option.first_some c.linked_account_id c.last_linked_account_id with
    | Some a when not (String.equal a "UNLINKED") -> Ok a
    | _ -> Or_error.error_s [%message "card is not linked to an account" c.id]
  in
  let%map limits = limits c in
  { Card_info.id = Card_core.Ids.Card_id.of_string c.id
  ; customer = Refs.customer ~user_id
  ; account = Refs.account ~user_id ~account_id
  ; kind = kind c.type_
  ; status = status c.status
  ; masked_pan = masked_pan c
  ; limits
  ; created_at = Striga_time.parse_or ~default:Time_ns.epoch c.created_at
  }
;;
