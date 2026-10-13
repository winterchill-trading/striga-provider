open! Core

let register code exponent =
  Money.Currency.register ~code ~exponent ~kind:Crypto () |> Or_error.ok_exn
;;

(* Not built into [Money]; registering is idempotent, so another library registering the
   same code with the same exponent is fine. *)
let bnb = lazy (register "BNB" 18)
let pol = lazy (register "POL" 18)
let sol = lazy (register "SOL" 9)

let table =
  lazy
    [ "EUR", Money.Currency.eur, 2
    ; "BTC", Money.Currency.btc, 8
    ; "ETH", Money.Currency.eth, 18
    ; (* Striga counts USDC in cents: a swap of 20.00 EUR credited "2197" for 21.97 USDC.
         USDT is assumed to match (its operations are stopped on the sandbox). *)
      "USDC", Money.Currency.usdc, 2
    ; "USDT", Money.Currency.usdt, 2
    ; "BNB", force bnb, 18
    ; "POL", force pol, 18
    ; "SOL", force sol, 9
    ]
;;

let currency_of_striga code =
  match
    List.find (force table) ~f:(fun (c, _, _) -> String.equal c (String.uppercase code))
  with
  | Some (_, currency, _) -> Ok currency
  | None -> Or_error.error_s [%message "currency not held at Striga" code]
;;

let striga_of_currency currency =
  match List.find (force table) ~f:(fun (_, c, _) -> Money.Currency.equal c currency) with
  | Some (code, _, _) -> Ok code
  | None ->
    Or_error.error_s
      [%message "currency not held at Striga" (currency : Money.Currency.t)]
;;

let striga_exponent code =
  List.find_map (force table) ~f:(fun (c, _, e) ->
    Option.some_if (String.equal c (String.uppercase code)) e)
;;

let unit_exponent = function
  | "cents" -> Some 2
  | "satoshis" | "sats" -> Some 8
  | "wei" -> Some 18
  | "lamports" -> Some 9
  | _ -> None
;;

let pow10 n = Z.pow (Z.of_int 10) n

let amount_of_striga ?unit ~currency digits =
  let open Or_error.Let_syntax in
  let%bind money = currency_of_striga currency in
  let%bind striga =
    match Option.bind unit ~f:unit_exponent with
    | Some e -> Ok e
    | None ->
      Or_error.of_option
        (striga_exponent currency)
        ~error:(Error.create_s [%message "no unit for currency" currency])
  in
  let%bind minor =
    let body = String.chop_prefix_if_exists digits ~prefix:"-" in
    if (not (String.is_empty body)) && String.for_all body ~f:Char.is_digit
    then Ok (Z.of_string digits)
    else Or_error.error_s [%message "not an integer amount" digits]
  in
  let ours = Money.Currency.exponent money in
  if ours >= striga
  then return (Money.Amount.of_minor_units money (Z.mul minor (pow10 (ours - striga))))
  else (
    let q, r = Z.div_rem minor (pow10 (striga - ours)) in
    if Z.equal r Z.zero
    then return (Money.Amount.of_minor_units money q)
    else
      Or_error.error_s
        [%message "amount has more digits than the currency" digits currency])
;;

let amount_of_major ~currency text =
  let open Or_error.Let_syntax in
  let%bind money = currency_of_striga currency in
  Money.Amount.of_decimal_string money text
;;

let amount_to_striga amount =
  let open Or_error.Let_syntax in
  let currency = Money.Amount.currency amount in
  let%bind code = striga_of_currency currency in
  let%bind striga =
    Or_error.of_option
      (striga_exponent code)
      ~error:(Error.create_s [%message "no unit for currency" code])
  in
  let ours = Money.Currency.exponent currency in
  let minor = Money.Amount.minor_units amount in
  if striga >= ours
  then return (Z.to_string (Z.mul minor (pow10 (striga - ours))))
  else (
    let q, r = Z.div_rem minor (pow10 (ours - striga)) in
    if Z.equal r Z.zero
    then return (Z.to_string q)
    else
      Or_error.error_s
        [%message "Striga cannot hold this many digits" (amount : Money.Amount.t)])
;;

let eur_cents amount =
  if not (Money.Currency.equal (Money.Amount.currency amount) Money.Currency.eur)
  then Or_error.error_s [%message "not a EUR amount" (amount : Money.Amount.t)]
  else
    Or_error.of_option
      (Money.Amount.minor_units_int amount)
      ~error:(Error.of_string "EUR amount too large")
;;
