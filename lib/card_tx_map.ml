open! Core
open Banking_provider
module Card_tx = Striga_client.Card.Card_transaction

let alpha3 =
  [ "AUT", "AT"
  ; "BEL", "BE"
  ; "BGR", "BG"
  ; "HRV", "HR"
  ; "CYP", "CY"
  ; "CZE", "CZ"
  ; "DNK", "DK"
  ; "EST", "EE"
  ; "FIN", "FI"
  ; "FRA", "FR"
  ; "DEU", "DE"
  ; "GRC", "GR"
  ; "HUN", "HU"
  ; "IRL", "IE"
  ; "ITA", "IT"
  ; "LVA", "LV"
  ; "LTU", "LT"
  ; "LUX", "LU"
  ; "MLT", "MT"
  ; "NLD", "NL"
  ; "POL", "PL"
  ; "PRT", "PT"
  ; "ROU", "RO"
  ; "SVK", "SK"
  ; "SVN", "SI"
  ; "ESP", "ES"
  ; "SWE", "SE"
  ; "ISL", "IS"
  ; "LIE", "LI"
  ; "NOR", "NO"
  ; "GBR", "GB"
  ; "CHE", "CH"
  ; "USA", "US"
  ; "CAN", "CA"
  ; "AUS", "AU"
  ; "JPN", "JP"
  ; "SGP", "SG"
  ; "HKG", "HK"
  ; "ARE", "AE"
  ; "TUR", "TR"
  ; "UKR", "UA"
  ; "BRA", "BR"
  ; "MEX", "MX"
  ; "IND", "IN"
  ; "CHN", "CN"
  ; "KOR", "KR"
  ; "NZL", "NZ"
  ; "ZAF", "ZA"
  ]
;;

let country_of_alpha3 code =
  let code = String.uppercase code in
  let two =
    if String.length code = 2
    then Some code
    else List.Assoc.find alpha3 code ~equal:String.equal
  in
  Option.bind two ~f:(fun c -> Card_core.Country.of_string_or_error c |> Result.ok)
;;

let response_of_decline (d : string option) : Card_core.Response_code.t =
  match Option.map d ~f:String.lowercase with
  | None -> Do_not_honor
  | Some d ->
    let has s = String.is_substring d ~substring:s in
    if has "insufficient" || has "sufficient funds"
    then Insufficient_funds
    else if has "limit"
    then Exceeds_amount_limit
    else if has "block" || has "frozen" || has "inactive" || has "not active"
    then Not_permitted
    else if has "expired"
    then Expired_card
    else Do_not_honor
;;

let type_name (t : Card_tx.t) =
  Option.value_map
    t.type_
    ~default:"UNKNOWN"
    ~f:Striga_client.Transaction.Tx_type.to_string
;;

let auth_ref (t : Card_tx.t) =
  Option.first_some t.related_card_transaction_id t.account_transaction_id
;;

let event_id (t : Card_tx.t) =
  Option.map (auth_ref t) ~f:(fun id ->
    Event_id.of_string (sprintf "card:%s:%s" id (type_name t)))
;;

(* Merchants charge in any ISO currency, not only the ones Striga holds. *)
let major ~currency text =
  let open Or_error.Let_syntax in
  let%bind c = Money.Currency.of_string_or_error (String.uppercase currency) in
  Money.Amount.of_decimal_string c text
;;

let required what =
  Or_error.of_option ~error:(Error.of_string ("card entry without " ^ what))
;;

let merchant (t : Card_tx.t) =
  let open Or_error.Let_syntax in
  let%bind mcc =
    required "a merchant category" t.merchant_category_code
    >>= Card_core.Mcc.of_string_or_error
  in
  let%bind country =
    required
      "a merchant country"
      (Option.bind t.merchant_country_code ~f:country_of_alpha3)
  in
  let%bind currency = required "an original currency" t.original_currency in
  let%bind amount = required "an original amount" t.original_amount >>= major ~currency in
  Card_core.Merchant.create
    ~name:(Option.value t.merchant_name ~default:"unknown merchant")
    ~mcc
    ~country
    ~amount
;;

let billing (t : Card_tx.t) =
  let open Or_error.Let_syntax in
  let currency = Option.first_some t.transaction_currency t.original_currency in
  let amount = Option.first_some t.transaction_amount t.original_amount in
  let%bind currency = required "a transaction currency" currency in
  let%bind amount = required "a transaction amount" amount in
  major ~currency amount
;;

let update ?card_id (t : Card_tx.t) =
  let open Or_error.Let_syntax in
  match t.type_ with
  | None -> return None
  | Some ty ->
    let card () =
      required "a card id" (Option.first_some t.card_id card_id)
      >>| Card_core.Ids.Card_id.of_string
    in
    let auth () =
      required "an authorization id" (auth_ref t) >>| Card_core.Ids.Auth_id.of_string
    in
    let advice ~approved =
      let%bind card = card () in
      let%bind auth = auth () in
      let%bind merchant = merchant t in
      let%bind amount = billing t in
      let response : Card_core.Response_code.t =
        if approved then Approved else response_of_decline t.decline_details
      in
      return
        (Some
           ( card
           , Card_update.Auth_advice
               { auth
               ; network_txn =
                   Card_core.Ids.Network_txn_id.of_string
                     (Card_core.Ids.Auth_id.to_string auth)
               ; amount
               ; approved =
                   (if approved
                    then amount
                    else Money.Amount.zero (Money.Amount.currency amount))
               ; merchant
               ; entry_mode = Ecommerce
               ; response
               ; decided_by = Provider_default
               } ))
    in
    (match ty with
     | Card_authorization -> advice ~approved:true
     | Card_authorization_declined -> advice ~approved:false
     | Card_authorization_reversal | Card_authorization_release ->
       let%bind card = card () in
       let%bind auth = auth () in
       let%bind amount = billing t in
       return (Some (card, Card_update.Reversal { auth; amount }))
     | Card_authorization_settlement_confirmed ->
       let%bind card = card () in
       let%bind auth = auth () in
       let%bind merchant = merchant t in
       let%bind amount = billing t in
       let at = Striga_time.parse_or ~default:Time_ns.epoch t.created_at in
       let%bind clearing =
         Card_core.Settlement.Clearing.create
           ~id:
             (Card_core.Ids.Clearing_id.of_string
                (Option.value
                   t.account_transaction_id
                   ~default:(Card_core.Ids.Auth_id.to_string auth)))
           ~card_id:card
           ~auth_id:auth
           ~direction:Debit
           ~merchant
           ~billing_currency:(Money.Amount.currency amount)
           ~billing:amount
           ~at
           ()
       in
       return (Some (card, Card_update.Clearing clearing))
     | _ -> return None)
;;
