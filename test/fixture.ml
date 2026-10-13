open! Core

let json name = Yojson.Safe.from_file ("fixtures/" ^ name)
let load name f = f (json name)
let at = Time_ns.of_string_with_utc_offset "2026-10-13 22:00:00Z"
