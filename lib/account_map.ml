open! Core
open Banking_provider
open Payments_core

let network (n : Striga_client.Common.Blockchain_network.t) : Network.t option =
  let name = String.lowercase n.name in
  let family = Option.value_map n.network ~default:name ~f:String.lowercase in
  let has s sub = String.is_substring s ~substring:sub in
  if has family "bitcoin" || has name "bitcoin"
  then if has name "test" || has name "signet" then Some Bitcoin_testnet else Some Bitcoin
  else if has family "ethereum" || has name "ethereum"
  then Some Ethereum
  else if has family "polygon" || has name "polygon"
  then Some Polygon
  else if has family "solana" || has name "solana"
  then Some Solana
  else if has family "tron" || has name "tron"
  then Some Tron
  else None
;;

let status s : Ledger.Account_status.t =
  match Option.map s ~f:String.uppercase with
  | None | Some "ACTIVE" -> Open
  | Some "CLOSED" -> Closed
  | Some _ -> Frozen
;;

let iban_address ~iban ~bic =
  match Option.map iban ~f:Iban.of_string with
  | Some (Ok iban) ->
    let bic = Option.bind bic ~f:(fun b -> Bic.of_string b |> Result.ok) in
    [ Account.Address.Iban { iban; bic } ]
  | Some (Error _) | None -> []
;;

let crypto_addresses
  ~networks
  ~deposit_address
  ~(deposit_addresses : Striga_client.Wallet.Deposit_address.t list)
  =
  let net = List.find_map networks ~f:network in
  let from_list =
    List.filter_map deposit_addresses ~f:(fun d ->
      let n =
        match d.network with
        | Some name ->
          (* The list names only the family ("Bitcoin"); the account's network says
             whether it is a test chain. *)
          (match net with
           | Some n -> Some n
           | None ->
             network
               { name
               ; network = Some name
               ; type_ = None
               ; contract_address = None
               ; blockchain_deposit_address = None
               })
        | None -> net
      in
      match n, d.address with
      | Some n, Some a -> Some (n, a)
      | _ -> None)
  in
  let all =
    match from_list, net, deposit_address with
    | [], Some n, Some a -> [ n, a ]
    | l, _, _ -> l
  in
  List.filter_map all ~f:(fun (n, a) ->
    match Crypto_address.create n a with
    | Ok address -> Some (Account.Address.Crypto { address; memo = None })
    | Error _ -> None)
  |> List.dedup_and_sort ~compare:Account.Address.compare
;;

let networks_of ~one ~many = Option.to_list one @ Option.value many ~default:[]

let addresses (e : Striga_client.Wallet.Enrichment.t) =
  iban_address ~iban:e.iban ~bic:e.bic
  @ crypto_addresses
      ~networks:(networks_of ~one:e.blockchain_network ~many:e.blockchain_networks)
      ~deposit_address:e.blockchain_deposit_address
      ~deposit_addresses:(Option.value e.deposit_addresses ~default:[])
;;

let account ~user_id (a : Striga_client.Wallet.Account.t) =
  let open Or_error.Let_syntax in
  let%bind code =
    Or_error.of_option a.currency ~error:(Error.of_string "account without a currency")
  in
  let%map currency = Units.currency_of_striga code in
  let banking =
    match a.banking_details with
    | Some b -> iban_address ~iban:b.iban ~bic:b.bic
    | None -> []
  in
  { Account.id = Refs.account ~user_id ~account_id:a.account_id
  ; customer = Refs.customer ~user_id
  ; currency
  ; status = status a.status
  ; addresses =
      banking
      @ crypto_addresses
          ~networks:(networks_of ~one:a.blockchain_network ~many:a.blockchain_networks)
          ~deposit_address:a.blockchain_deposit_address
          ~deposit_addresses:(Option.value a.deposit_addresses ~default:[])
  ; opened_at = Striga_time.parse_or ~default:Time_ns.epoch a.created_at
  }
;;

let balance account_ref (a : Striga_client.Wallet.Account.t) ~at =
  let open Or_error.Let_syntax in
  let%bind code =
    Or_error.of_option a.currency ~error:(Error.of_string "account without a currency")
  in
  let%bind currency = Units.currency_of_striga code in
  let%map available =
    match a.available_balance with
    | Some { amount = Some amount; currency = unit; _ } ->
      Units.amount_of_striga ?unit ~currency:code amount
    | _ -> return (Money.Amount.zero currency)
  in
  { Account.Balance.account = account_ref
  ; available
  ; held = Money.Amount.zero currency
  ; posted = available
  ; as_of = at
  }
;;
