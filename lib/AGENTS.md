# AGENTS.md: lib/

The `striga_provider` library. Each module has an `.mli`; change it first and keep it documented.

- `adapter.ml`: the `Provider.S` and `Sandbox.S` implementation, webhook ingestion and the poller. This is
  the entry point; everything else is a helper it calls.
- `store.ml`, `refs.ml`: the links the provider cannot hold (our customer, transfer, challenge, swap and
  card request ids) and the account and standing-order references that carry the provider's user id.
- `kyc_map.ml`, `account_map.ml`, `tx_map.ml`, `card_map.ml`, `card_tx_map.ml`: one mapping per concern,
  each documented in `../docs/mapping.md`.
- `units.ml`, `striga_time.ml`: tickers and smallest units to `Money`; ISO and epoch-millisecond timestamps.

Rule: a mapping change updates `../docs/mapping.md` and the matching expect test in the same commit.
