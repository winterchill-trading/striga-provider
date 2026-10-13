open! Core

let parse s =
  if (not (String.is_empty s)) && String.for_all s ~f:Char.is_digit
  then
    Option.try_with (fun () ->
      Time_ns.of_int_ns_since_epoch (Int.of_string s * 1_000_000))
  else Option.try_with (fun () -> Time_ns.of_string_with_utc_offset s)
;;

let parse_or ~default s = Option.bind s ~f:parse |> Option.value ~default
