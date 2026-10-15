open! Core
open! Async
open Striga_provider

(* No request may leave: the token comes from the store alone. *)
let offline_transport () =
  let config =
    Striga_client.Config.create ~api_key:"test-key" ~api_secret:"test-secret" ()
    |> Or_error.ok_exn
  in
  Striga_client.Transport.create
    ~send:(fun ~meth:_ _ ~headers:_ ~body:_ ->
      return (Or_error.error_string "no network in this test"))
    config
;;

let%expect_test "a card display token survives a restart through the store" =
  let store = Store.memory () in
  let card = Card_core.Ids.Card_id.of_string "card-1" in
  let token =
    Card_core.Pan_display_token.of_provider
      ~token:"display-token"
      ~expires_at:(Time_ns.add (Time_ns.now ()) Time_ns.Span.hour)
    |> Or_error.ok_exn
  in
  let%bind () = store.set_card_token card token in
  (* A second adapter over the same store stands for the process after a restart. *)
  let restarted = Adapter.create ~store (offline_transport ()) in
  let%bind result = Adapter.card_details_token restarted card in
  (match result with
   | Ok (Done t) -> print_endline (Card_core.Pan_display_token.reveal_for_ui t)
   | Ok (Challenge _) -> print_endline "challenge"
   | Error e -> print_s [%sexp (e : Error.t)]);
  [%expect {| display-token |}];
  let fresh = Adapter.create ~store:(Store.memory ()) (offline_transport ()) in
  let%map result = Adapter.card_details_token fresh card in
  print_s [%sexp (Result.is_error result : bool)];
  [%expect {| true |}]
;;

let%expect_test "the default 3-D Secure password meets Striga's rule" =
  let ok =
    List.init 200 ~f:(fun _ -> Adapter.Config.random_password ())
    |> List.for_all ~f:Adapter.Config.valid_3ds_password
  in
  print_s [%sexp (ok : bool)];
  List.iter
    [ "Wc#1b4e28ba-2fa19z"
    ; "short1!A"
    ; "Walk#Pass2026"
    ; "nouppercase1!"
    ; "Pass1234Test@!"
    ]
    ~f:(fun p -> printf "%s %b\n" p (Adapter.Config.valid_3ds_password p));
  [%expect
    {|
    true
    Wc#1b4e28ba-2fa19z false
    short1!A true
    Walk#Pass2026 true
    nouppercase1! false
    Pass1234Test@! false
    |}];
  return ()
;;
